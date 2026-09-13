from __future__ import annotations

import dataclasses
import hmac
import logging
import os
import secrets
from functools import wraps
from pathlib import Path

from flask import Flask, abort, flash, redirect, render_template, request, session, url_for

from .config import Config
from .filenames import safe_join
from .mapping import ALL_ACCOUNTS, Mapping, Rule
from .settings import (
    DEFAULT_SHARE,
    Account,
    Printer,
    Settings,
    Share,
    make_account_id,
    make_printer_id,
    make_share_id,
    parse_extensions,
)
from .shares import ShareSet

logger = logging.getLogger(__name__)

# Handing a whole filesystem to the mapping rules is never a share. Everything
# else is the admin's call: they are configuring mount points, and this page is
# already restricted to whoever may read the IMAP passwords.
_FORBIDDEN_SHARE_PATHS = {"/", "/etc", "/dev", "/proc", "/sys", "/boot", "/bin", "/sbin", "/lib"}


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

    def shares_now() -> ShareSet:
        return ShareSet.from_settings(current(), config.storage_root)

    def persist(new_settings: Settings) -> None:
        new_settings.save(config)
        state["settings"] = new_settings
        if runner is not None:
            runner.reload(new_settings)

    def valid_folder(share_id: str, folder: str) -> str | None:
        """None if `folder` is a usable target on that share, else the reason."""
        try:
            shares_now().resolve(share_id, folder)
        except ValueError as exc:
            return str(exc)
        return None

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
        settings_now = current()
        return {
            "csrf_token": csrf_token,
            "accounts": settings_now.accounts,
            "shares": settings_now.shares,
            "printers": settings_now.printers,
            "ALL_ACCOUNTS": ALL_ACCOUNTS,
            "DEFAULT_SHARE": DEFAULT_SHARE,
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

    def _rule_from_form() -> tuple[Rule | None, str | None]:
        match = request.form.get("match", "").strip()
        folder = request.form.get("folder", "").strip()
        account = request.form.get("account", ALL_ACCOUNTS).strip() or ALL_ACCOUNTS
        share = request.form.get("share", DEFAULT_SHARE).strip()
        if not match or not folder:
            return None, "Stichwort und Zielordner sind beide erforderlich."
        if share and current().share(share) is None:
            return None, "Unbekannte Ablage."
        problem = valid_folder(share, folder)
        if problem:
            return None, f"Zielordner nicht zulaessig: {problem}"
        return Rule(match=match, folder=folder, account=account, share=share), None

    @app.route("/rules/add", methods=["POST"])
    @login_required
    def rule_add():
        rule, problem = _rule_from_form()
        if rule is None:
            flash(problem, "error")
            return redirect(url_for("index"))
        mapping.save(mapping.rules + [rule])
        flash(f"Zuordnung '{rule.match}' angelegt.", "ok")
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
        rule, problem = _rule_from_form()
        if rule is None:
            flash(problem, "error")
            return redirect(url_for("index"))
        rules[index] = rule
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
            accounts = [Account(id=a.id, **values) if a.id == account.id else a for a in accounts]
            message = f"Konto '{label or user}' gespeichert."

        persist(dataclasses.replace(settings_now, accounts=accounts))
        flash(message, "ok")
        return redirect(url_for("accounts_page"))

    @app.route("/accounts/<account_id>/delete", methods=["POST"])
    @login_required
    def account_delete(account_id: str):
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
                    dataclasses.replace(r, account=ALL_ACCOUNTS) if r.account == account_id else r
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

    # --- shares (one or more NAS) -----------------------------------------

    @app.route("/shares")
    @login_required
    def shares_page():
        return render_template(
            "shares.html",
            status=shares_now().status(),
            storage_root=config.storage_root,
        )

    @app.route("/shares/save", methods=["POST"])
    @login_required
    def share_save():
        settings_now = current()
        existing_id = request.form.get("id", "").strip()
        share = settings_now.share(existing_id) if existing_id else None

        label = request.form.get("label", "").strip()
        raw_path = request.form.get("path", "").strip()
        path = os.path.normpath(raw_path) if raw_path else ""
        if not path:
            flash("Der Pfad des Mountpoints ist erforderlich.", "error")
            return redirect(url_for("shares_page"))
        if not os.path.isabs(path) or (path.rstrip("/") or "/") in _FORBIDDEN_SHARE_PATHS:
            flash(
                "Der Pfad muss ein absoluter Mountpoint sein (z. B. /mnt/nas2) "
                "und darf kein Systemverzeichnis sein.",
                "error",
            )
            return redirect(url_for("shares_page"))

        values = dict(label=label, path=path, enabled=request.form.get("enabled") == "on")
        shares = list(settings_now.shares)
        if share is None:
            new_id = settings_now.unique_share_id(make_share_id(label or Path(path).name))
            shares.append(Share(id=new_id, **values))
            message = f"Ablage '{label or path}' angelegt."
        else:
            shares = [Share(id=s.id, **values) if s.id == share.id else s for s in shares]
            message = f"Ablage '{label or path}' gespeichert."

        persist(dataclasses.replace(settings_now, shares=shares))
        flash(message, "ok")

        problem = ShareSet.check_root(path)
        if problem:
            # Saved anyway: the mount may well be set up right after this.
            flash(f"Achtung: {problem}", "error")
        return redirect(url_for("shares_page"))

    @app.route("/shares/<share_id>/delete", methods=["POST"])
    @login_required
    def share_delete(share_id: str):
        settings_now = current()
        remaining = [s for s in settings_now.shares if s.id != share_id]
        if len(remaining) == len(settings_now.shares):
            abort(404)
        if not remaining:
            flash("Die letzte Ablage kann nicht geloescht werden.", "error")
            return redirect(url_for("shares_page"))

        printers = [
            dataclasses.replace(
                p,
                source_share=DEFAULT_SHARE if p.source_share == share_id else p.source_share,
                target_share=DEFAULT_SHARE if p.target_share == share_id else p.target_share,
            )
            for p in settings_now.printers
        ]
        persist(dataclasses.replace(settings_now, shares=remaining, printers=printers))

        # Rules pointing at the removed share would file onto the default one
        # anyway; rewrite them so the mapping file says what actually happens.
        orphaned = [r for r in mapping.rules if r.share == share_id]
        if orphaned:
            mapping.save(
                [
                    dataclasses.replace(r, share=DEFAULT_SHARE) if r.share == share_id else r
                    for r in mapping.rules
                ]
            )
        flash(
            "Ablage geloescht."
            + (
                f" {len(orphaned)} Zuordnung(en) nutzen jetzt die Standard-Ablage."
                if orphaned
                else ""
            ),
            "ok",
        )
        return redirect(url_for("shares_page"))

    # --- printers / scanners ----------------------------------------------

    def _pickup_state(printer: Printer) -> str:
        """Short status line for a device's pickup folder, for the overview."""
        if not printer.has_pickup:
            return "nur per Mail"
        problem = shares_now().problem_with(printer.source_share)
        if problem:
            return f"Ablage nicht verfuegbar: {problem}"
        try:
            directory = shares_now().resolve(printer.source_share, printer.source_folder)
        except ValueError as exc:
            return f"Ordner nicht zulaessig: {exc}"
        if not directory.is_dir():
            return f"{directory} existiert noch nicht"
        return f"{directory} wird ueberwacht"

    @app.route("/printers")
    @login_required
    def printers_page():
        return render_template(
            "printers.html",
            pickup_state=_pickup_state,
            status=runner.status() if runner else [],
        )

    @app.route("/printers/save", methods=["POST"])
    @login_required
    def printer_save():
        settings_now = current()
        existing_id = request.form.get("id", "").strip()
        printer = settings_now.printer(existing_id) if existing_id else None

        label = request.form.get("label", "").strip()
        sender = request.form.get("sender", "").strip()
        source_share = request.form.get("source_share", DEFAULT_SHARE).strip()
        source_folder = request.form.get("source_folder", "").strip()
        target_share = request.form.get("target_share", DEFAULT_SHARE).strip()
        target_folder = request.form.get("target_folder", "").strip()

        def fail(message: str):
            flash(message, "error")
            return redirect(url_for("printers_page"))

        if not label:
            return fail("Eine Bezeichnung ist erforderlich.")
        if not sender and not source_folder:
            return fail(
                "Entweder eine Absenderadresse (Scan-to-Mail) oder ein Abholordner "
                "(Scan-to-Folder) ist erforderlich."
            )
        for share_id in (source_share, target_share):
            if share_id and settings_now.share(share_id) is None:
                return fail("Unbekannte Ablage.")
        for folder, what in ((source_folder, "Abholordner"), (target_folder, "Zielordner")):
            if not folder:
                continue
            share_id = source_share if what == "Abholordner" else target_share
            problem = valid_folder(share_id, folder)
            if problem:
                return fail(f"{what} nicht zulaessig: {problem}")

        candidate = Printer(
            id=printer.id if printer else "",
            label=label,
            sender=sender,
            source_share=source_share,
            source_folder=source_folder,
            target_share=target_share,
            target_folder=target_folder,
            enabled=request.form.get("enabled") == "on",
        )
        if _files_into_itself(shares_now(), candidate):
            return fail(
                "Der Zielordner liegt im Abholordner - die Dokumente wuerden immer "
                "wieder eingelesen."
            )

        printers = list(settings_now.printers)
        if printer is None:
            new_id = settings_now.unique_printer_id(make_printer_id(label))
            printers.append(dataclasses.replace(candidate, id=new_id))
            message = f"Drucker '{label}' angelegt."
        else:
            printers = [candidate if p.id == printer.id else p for p in printers]
            message = f"Drucker '{label}' gespeichert."

        persist(dataclasses.replace(settings_now, printers=printers))
        flash(message, "ok")
        return redirect(url_for("printers_page"))

    @app.route("/printers/<printer_id>/delete", methods=["POST"])
    @login_required
    def printer_delete(printer_id: str):
        settings_now = current()
        remaining = [p for p in settings_now.printers if p.id != printer_id]
        if len(remaining) == len(settings_now.printers):
            abort(404)
        persist(dataclasses.replace(settings_now, printers=remaining))
        flash("Drucker geloescht.", "ok")
        return redirect(url_for("printers_page"))

    # --- general settings -------------------------------------------------

    @app.route("/settings", methods=["GET", "POST"])
    @login_required
    def settings_page():
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

            fallback_folder = request.form.get("fallback_folder", "").strip() or "unsorted"
            quarantine_folder = (
                request.form.get("quarantine_folder", "").strip() or "quarantaene"
            )
            for folder, what in (
                (fallback_folder, "Fallback-Ordner"),
                (quarantine_folder, "Quarantaene-Ordner"),
            ):
                problem = valid_folder(DEFAULT_SHARE, folder)
                if problem:
                    flash(f"{what} nicht zulaessig: {problem}", "error")
                    return redirect(url_for("settings_page"))

            def as_int(name: str, fallback: int, minimum: int = 1) -> int:
                try:
                    return max(minimum, int(request.form.get(name, fallback)))
                except ValueError:
                    return fallback

            updated = dataclasses.replace(
                settings_now,
                mapping_path=new_mapping_path,
                fallback_folder=fallback_folder,
                quarantine_folder=quarantine_folder,
                blocked_extensions=parse_extensions(request.form.get("blocked_extensions", "")),
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
                printer_min_age_seconds=as_int(
                    "printer_min_age_seconds", settings_now.printer_min_age_seconds, minimum=0
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
            mapping.set_fallback_folder(updated.fallback_folder)

            persist(updated)
            flash(
                "Einstellungen gespeichert." + (" Mapping-Datei verschoben." if moved else ""),
                "ok",
            )
            return redirect(url_for("settings_page"))

        return render_template(
            "settings.html",
            settings=settings_now,
            blocked_extensions=", ".join(settings_now.blocked_extensions),
            storage_root=config.storage_root,
            mapping_full_path=str(mapping.path),
        )

    return app


def _files_into_itself(shares: ShareSet, printer: Printer) -> bool:
    """True if this device's target folder sits inside its own pickup folder."""
    if not printer.has_pickup or not printer.has_fixed_target:
        return False
    try:
        source = shares.resolve(printer.source_share, printer.source_folder)
        target = shares.resolve(printer.target_share, printer.target_folder)
        target.relative_to(source)
        return True
    except ValueError:
        return False
