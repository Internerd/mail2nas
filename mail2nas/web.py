from __future__ import annotations

import hmac
import logging
import secrets
from functools import wraps
from pathlib import Path

from flask import Flask, abort, flash, redirect, render_template, request, session, url_for

from .config import Config
from .filenames import safe_join
from .mapping import ALL_ACCOUNTS, Mapping, Rule
from .settings import Account, Settings, make_account_id

logger = logging.getLogger(__name__)


def _check_login(config: Config, user: str, password: str) -> bool:
    # compare_digest on both fields so a wrong username is not distinguishable
    # from a wrong password by timing.
    return hmac.compare_digest(user, config.web_user) and hmac.compare_digest(
        password, config.web_password
    )


def create_app(config: Config, settings: Settings, mapping: Mapping, runner=None) -> Flask:
    app = Flask(__name__, template_folder="templates")
    app.secret_key = secrets.token_bytes(32)
    app.config.update(
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Strict",
        MAX_CONTENT_LENGTH=1 * 1024 * 1024,
    )

    state = {"settings": settings}

    def current() -> Settings:
        return state["settings"]

    def persist(new_settings: Settings) -> None:
        new_settings.save(config)
        state["settings"] = new_settings
        if runner is not None:
            runner.reload(new_settings)

    # --- auth + CSRF ----------------------------------------------------

    def login_required(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if not session.get("authenticated"):
                return redirect(url_for("login", next=request.path))
            return view(*args, **kwargs)

        return wrapper

    def csrf_token() -> str:
        if "csrf" not in session:
            session["csrf"] = secrets.token_urlsafe(32)
        return session["csrf"]

    @app.before_request
    def verify_csrf():
        if request.method == "POST" and request.endpoint != "login":
            sent = request.form.get("csrf_token", "")
            if not sent or not hmac.compare_digest(sent, session.get("csrf", "")):
                abort(400, "CSRF-Token ungueltig - bitte die Seite neu laden.")

    @app.context_processor
    def inject():
        return {
            "csrf_token": csrf_token,
            "accounts": current().accounts,
            "ALL_ACCOUNTS": ALL_ACCOUNTS,
        }

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if request.method == "POST":
            if _check_login(config, request.form.get("user", ""), request.form.get("password", "")):
                session.clear()
                session["authenticated"] = True
                return redirect(request.args.get("next") or url_for("index"))
            flash("Anmeldung fehlgeschlagen.", "error")
        return render_template("login.html")

    @app.route("/logout", methods=["POST"])
    def logout():
        session.clear()
        return redirect(url_for("login"))

    # --- mapping rules --------------------------------------------------

    @app.route("/")
    @login_required
    def index():
        mapping.reload()
        return render_template(
            "rules.html",
            rules=mapping.rules,
            mapping_path=str(mapping.path),
            status=runner.status() if runner else [],
        )

    @app.route("/rules/add", methods=["POST"])
    @login_required
    def rule_add():
        match = request.form.get("match", "").strip()
        folder = request.form.get("folder", "").strip()
        account = request.form.get("account", ALL_ACCOUNTS).strip() or ALL_ACCOUNTS
        if not match or not folder:
            flash("Stichwort und Zielordner sind beide erforderlich.", "error")
            return redirect(url_for("index"))
        try:
            safe_join(config.storage_root, folder)
        except ValueError as exc:
            flash(f"Zielordner nicht zulaessig: {exc}", "error")
            return redirect(url_for("index"))

        rules = mapping.rules + [Rule(match=match, folder=folder, account=account)]
        mapping.save(rules)
        flash(f"Zuordnung '{match}' angelegt.", "ok")
        return redirect(url_for("index"))

    @app.route("/rules/<int:index>/move/<direction>", methods=["POST"])
    @login_required
    def rule_move(index: int, direction: str):
        rules = mapping.rules
        if not 0 <= index < len(rules):
            abort(404)
        target = index - 1 if direction == "up" else index + 1
        if 0 <= target < len(rules):
            rules[index], rules[target] = rules[target], rules[index]
            mapping.save(rules)
        return redirect(url_for("index"))

    @app.route("/rules/<int:index>/delete", methods=["POST"])
    @login_required
    def rule_delete(index: int):
        rules = mapping.rules
        if not 0 <= index < len(rules):
            abort(404)
        removed = rules.pop(index)
        mapping.save(rules)
        flash(f"Zuordnung '{removed.match}' geloescht.", "ok")
        return redirect(url_for("index"))

    @app.route("/rules/<int:index>/update", methods=["POST"])
    @login_required
    def rule_update(index: int):
        rules = mapping.rules
        if not 0 <= index < len(rules):
            abort(404)
        match = request.form.get("match", "").strip()
        folder = request.form.get("folder", "").strip()
        account = request.form.get("account", ALL_ACCOUNTS).strip() or ALL_ACCOUNTS
        if not match or not folder:
            flash("Stichwort und Zielordner sind beide erforderlich.", "error")
            return redirect(url_for("index"))
        try:
            safe_join(config.storage_root, folder)
        except ValueError as exc:
            flash(f"Zielordner nicht zulaessig: {exc}", "error")
            return redirect(url_for("index"))
        rules[index] = Rule(match=match, folder=folder, account=account)
        mapping.save(rules)
        flash("Zuordnung gespeichert.", "ok")
        return redirect(url_for("index"))

    # --- mail accounts ---------------------------------------------------

    @app.route("/accounts")
    @login_required
    def accounts_page():
        return render_template("accounts.html", status=runner.status() if runner else [])

    @app.route("/accounts/save", methods=["POST"])
    @login_required
    def account_save():
        settings_now = current()
        existing_id = request.form.get("id", "").strip()
        account = settings_now.account(existing_id) if existing_id else None

        label = request.form.get("label", "").strip()
        host = request.form.get("host", "").strip()
        user = request.form.get("user", "").strip()
        if not host or not user:
            flash("Server und Benutzer sind erforderlich.", "error")
            return redirect(url_for("accounts_page"))

        password = request.form.get("password", "")
        if account is not None and not password:
            password = account.password  # empty field means "keep current"

        try:
            port = int(request.form.get("port", "993"))
        except ValueError:
            flash("Port muss eine Zahl sein.", "error")
            return redirect(url_for("accounts_page"))

        values = dict(
            label=label,
            host=host,
            port=port,
            ssl=request.form.get("ssl") == "on",
            user=user,
            password=password,
            folder=request.form.get("folder", "INBOX").strip() or "INBOX",
            processed_folder=request.form.get("processed_folder", "").strip(),
            oversized_folder=request.form.get("oversized_folder", "").strip(),
            mode="idle" if request.form.get("mode") == "idle" else "poll",
            enabled=request.form.get("enabled") == "on",
        )

        accounts = list(settings_now.accounts)
        if account is None:
            new_id = settings_now.unique_id(make_account_id(label or user))
            accounts.append(Account(id=new_id, **values))
            message = f"Konto '{label or user}' angelegt."
        else:
            accounts = [
                Account(id=a.id, **values) if a.id == account.id else a for a in accounts
            ]
            message = f"Konto '{label or user}' gespeichert."

        import dataclasses

        persist(dataclasses.replace(settings_now, accounts=accounts))
        flash(message, "ok")
        return redirect(url_for("accounts_page"))

    @app.route("/accounts/<account_id>/delete", methods=["POST"])
    @login_required
    def account_delete(account_id: str):
        import dataclasses

        settings_now = current()
        remaining = [a for a in settings_now.accounts if a.id != account_id]
        if len(remaining) == len(settings_now.accounts):
            abort(404)
        persist(dataclasses.replace(settings_now, accounts=remaining))

        # Rules pinned to the removed account would silently never match again.
        orphaned = [r for r in mapping.rules if r.account == account_id]
        if orphaned:
            mapping.save(
                [
                    Rule(match=r.match, folder=r.folder, account=ALL_ACCOUNTS)
                    if r.account == account_id
                    else r
                    for r in mapping.rules
                ]
            )
            flash(
                f"Konto geloescht. {len(orphaned)} Zuordnung(en) waren daran gebunden "
                "und gelten jetzt fuer alle Konten.",
                "ok",
            )
        else:
            flash("Konto geloescht.", "ok")
        return redirect(url_for("accounts_page"))

    # --- general settings -------------------------------------------------

    @app.route("/settings", methods=["GET", "POST"])
    @login_required
    def settings_page():
        import dataclasses

        settings_now = current()
        if request.method == "POST":
            new_mapping_path = request.form.get("mapping_path", "").strip() or "mapping.yaml"
            try:
                # The mapping file must stay inside the share: the path comes
                # from a form field and would otherwise be a way to read/write
                # an arbitrary file on the host.
                resolved = safe_join(config.storage_root, new_mapping_path)
            except ValueError as exc:
                flash(f"Pfad nicht zulaessig: {exc}", "error")
                return redirect(url_for("settings_page"))

            def as_int(name: str, fallback: int) -> int:
                try:
                    return max(1, int(request.form.get(name, fallback)))
                except ValueError:
                    return fallback

            updated = dataclasses.replace(
                settings_now,
                mapping_path=new_mapping_path,
                fallback_folder=request.form.get("fallback_folder", "").strip() or "unsorted",
                quarantine_folder=request.form.get("quarantine_folder", "").strip() or "quarantaene",
                match_body=request.form.get("match_body") == "on",
                filename_prefix=request.form.get("filename_prefix", "date_sender"),
                poll_interval=as_int("poll_interval", settings_now.poll_interval),
                max_attachment_size_mb=as_int(
                    "max_attachment_size_mb", settings_now.max_attachment_size_mb
                ),
                max_message_size_mb=as_int("max_message_size_mb", settings_now.max_message_size_mb),
                max_attachments_per_message=as_int(
                    "max_attachments_per_message", settings_now.max_attachments_per_message
                ),
            )

            moved = False
            old_path = Path(mapping.path)
            if resolved != old_path:
                resolved.parent.mkdir(parents=True, exist_ok=True)
                if old_path.exists() and not resolved.exists():
                    # Move the existing rules along rather than silently
                    # starting from an empty file at the new location.
                    resolved.write_text(old_path.read_text(encoding="utf-8"), encoding="utf-8")
                    old_path.unlink()
                    moved = True
                mapping.set_path(str(resolved))

            persist(updated)
            flash(
                "Einstellungen gespeichert." + (" Mapping-Datei verschoben." if moved else ""),
                "ok",
            )
            return redirect(url_for("settings_page"))

        return render_template(
            "settings.html",
            settings=settings_now,
            storage_root=config.storage_root,
            mapping_full_path=str(mapping.path),
        )

    return app
