"""Minimal web UI for editing the keyword -> folder mapping.

Deliberately small: one password, one page for the rules, one page for
changing that password. No user accounts, no JavaScript, no external assets.

It edits `mapping.yaml` on the share through the same storage backend the
archiver uses, so the file stays the single source of truth and the archiver
picks up changes on its next cycle without a restart.

This is a LAN tool. It authenticates with a single password over whatever
transport it is put behind - see the README for why it should not be exposed
to the internet without a TLS-terminating reverse proxy in front.
"""
from __future__ import annotations

import logging
import secrets
import threading
import time
from datetime import timedelta
from functools import wraps

from flask import (
    Flask,
    abort,
    flash,
    get_flashed_messages,
    redirect,
    render_template_string,
    request,
    session,
    url_for,
)
from markupsafe import Markup
from werkzeug.security import check_password_hash, generate_password_hash

from .mapping import (
    MappingError,
    load_rules,
    save_rules,
    validate_folder,
    validate_keyword,
)

logger = logging.getLogger(__name__)

SETTING_PASSWORD_HASH = "web_password_hash"
SETTING_SECRET_KEY = "web_secret_key"
SETTING_SESSION_VERSION = "web_session_version"

MIN_PASSWORD_LENGTH = 8
SESSION_HOURS = 12

# Login throttling. Single-password auth is only as good as the number of
# guesses an attacker gets, so failures cost time after the first few.
MAX_FAILED_LOGINS = 5
LOCKOUT_SECONDS = 60


class LoginThrottle:
    """Per-client failure counter with a fixed lockout window."""

    def __init__(self, max_failures: int = MAX_FAILED_LOGINS, lockout: int = LOCKOUT_SECONDS):
        self._max_failures = max_failures
        self._lockout = lockout
        self._lock = threading.Lock()
        self._state: dict[str, tuple[int, float]] = {}

    def seconds_blocked(self, client: str) -> int:
        with self._lock:
            failures, blocked_until = self._state.get(client, (0, 0.0))
        remaining = blocked_until - time.monotonic()
        return int(remaining) + 1 if failures >= self._max_failures and remaining > 0 else 0

    def record_failure(self, client: str) -> None:
        with self._lock:
            failures, blocked_until = self._state.get(client, (0, 0.0))
            if blocked_until and blocked_until < time.monotonic():
                failures = 0  # previous lockout expired, start over
            failures += 1
            self._state[client] = (failures, time.monotonic() + self._lockout)

    def reset(self, client: str) -> None:
        with self._lock:
            self._state.pop(client, None)


BASE_TEMPLATE = """
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{{ title }} - mail2nas</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f6f7f9; --fg: #1b1d21; --muted: #5c6470; --line: #d7dbe0;
    --card: #ffffff; --accent: #2f6feb; --danger: #b3261e; --ok: #1f7a3d;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #16181c; --fg: #e6e8ea; --muted: #9aa2ad; --line: #2e333a;
      --card: #1e2126; --accent: #6a9bff; --danger: #ef6a63; --ok: #63c98c;
    }
  }
  * { box-sizing: border-box; }
  body { margin: 0; padding: 1.5rem 1rem 3rem; background: var(--bg); color: var(--fg);
         font: 15px/1.5 system-ui, -apple-system, "Segoe UI", Roboto, sans-serif; }
  main { max-width: 52rem; margin: 0 auto; }
  h1 { font-size: 1.35rem; margin: 0; }
  h2 { font-size: 1.05rem; margin: 1.75rem 0 .6rem; }
  header { display: flex; flex-wrap: wrap; gap: .75rem; align-items: baseline;
           justify-content: space-between; margin-bottom: 1.25rem; }
  nav a, nav button { color: var(--muted); font-size: .9rem; }
  .card { background: var(--card); border: 1px solid var(--line); border-radius: 10px;
          padding: 1rem 1.1rem; margin-bottom: 1rem; }
  table { width: 100%; border-collapse: collapse; }
  th, td { text-align: left; padding: .5rem .4rem; border-bottom: 1px solid var(--line);
           vertical-align: middle; }
  th { font-size: .8rem; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
  td.keyword { font-weight: 600; word-break: break-word; }
  .table-wrap { overflow-x: auto; }
  input, select, button { font: inherit; color: inherit; }
  input[type=text], input[type=password], select {
    background: var(--bg); border: 1px solid var(--line); border-radius: 6px;
    padding: .4rem .5rem; width: 100%; max-width: 22rem; }
  button { background: var(--accent); color: #fff; border: 0; border-radius: 6px;
           padding: .45rem .9rem; cursor: pointer; }
  button.secondary { background: transparent; border: 1px solid var(--line); color: var(--fg); }
  button.link { background: none; border: 0; padding: 0; color: var(--muted);
                text-decoration: underline; cursor: pointer; }
  button.danger { background: transparent; border: 1px solid var(--line); color: var(--danger); }
  .row { display: flex; flex-wrap: wrap; gap: .6rem; align-items: flex-end; }
  /* Inside a table cell the select and its button have to stay on one line,
     otherwise every rule takes two rows and the table gets hard to scan. */
  td .row { flex-wrap: nowrap; gap: .4rem; }
  td select { max-width: 18rem; }
  .field { display: flex; flex-direction: column; gap: .25rem; }
  .field label { font-size: .8rem; color: var(--muted); }
  .hint { color: var(--muted); font-size: .85rem; }
  .msg { border-radius: 8px; padding: .6rem .8rem; margin-bottom: .75rem; border: 1px solid; }
  .msg.error { color: var(--danger); border-color: var(--danger); }
  .msg.ok { color: var(--ok); border-color: var(--ok); }
  dl { display: grid; grid-template-columns: auto 1fr; gap: .3rem 1rem; margin: 0; font-size: .88rem; }
  dt { color: var(--muted); }
  dd { margin: 0; word-break: break-all; }
  form.inline { display: inline; }
</style>
</head>
<body>
<main>
  <header>
    <h1>mail2nas</h1>
    {% if logged_in %}
    <nav>
      <a href="{{ url_for('mapping_page') }}">Zuordnungen</a> &middot;
      <a href="{{ url_for('password_page') }}">Passwort</a> &middot;
      <form class="inline" method="post" action="{{ url_for('logout') }}">
        <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
        <button class="link" type="submit">Abmelden</button>
      </form>
    </nav>
    {% endif %}
  </header>
  {% for category, message in messages %}
    <div class="msg {{ category }}">{{ message }}</div>
  {% endfor %}
  {{ body }}
</main>
</body>
</html>
"""

LOGIN_BODY = """
<div class="card">
  <h2 style="margin-top:0">Anmelden</h2>
  <form method="post" class="row">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="field">
      <label for="password">Passwort</label>
      <input id="password" name="password" type="password" autocomplete="current-password"
             autofocus required>
    </div>
    <button type="submit">Anmelden</button>
  </form>
</div>
"""

MAPPING_BODY = """
<div class="card">
  <h2 style="margin-top:0">Stichwort einem Ordner zuordnen</h2>
  <form method="post" action="{{ url_for('add_rule') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="keyword">Stichwort in Betreff oder Dateiname</label>
        <input id="keyword" name="keyword" type="text" placeholder="z. B. Rechnung" required>
      </div>
      <div class="field">
        <label for="folder">Zielordner</label>
        <select id="folder" name="folder">
          <option value="">-- vorhandenen Ordner waehlen --</option>
          {% for folder in folders %}
            <option value="{{ folder }}">{{ folder }}</option>
          {% endfor %}
        </select>
      </div>
      <div class="field">
        <label for="new_folder">oder neuen Ordner anlegen</label>
        <input id="new_folder" name="new_folder" type="text" placeholder="z. B. rechnungen/2026">
      </div>
      <button type="submit">Hinzufuegen</button>
    </div>
  </form>
  <p class="hint">Laengere Stichwoerter gewinnen vor kuerzeren, Gross-/Kleinschreibung
  ist egal. Aenderungen wirken beim naechsten Durchlauf, ein Neustart ist nicht noetig.</p>
</div>

<div class="card">
  <h2 style="margin-top:0">Aktuelle Zuordnungen ({{ rules|length }})</h2>
  {% if rules %}
  <div class="table-wrap">
  <table>
    <tr><th>Stichwort</th><th>Zielordner</th><th></th></tr>
    {% for keyword, folder in rules.items() %}
    <tr>
      <td class="keyword">{{ keyword }}</td>
      <td>
        <form method="post" action="{{ url_for('update_rule') }}" class="row">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="keyword" value="{{ keyword }}">
          <select name="folder">
            {% for option in folder_options(folder) %}
              <option value="{{ option }}" {% if option == folder %}selected{% endif %}>{{ option }}</option>
            {% endfor %}
          </select>
          <button class="secondary" type="submit">Speichern</button>
        </form>
      </td>
      <td>
        <form method="post" action="{{ url_for('delete_rule') }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="keyword" value="{{ keyword }}">
          <button class="danger" type="submit">Loeschen</button>
        </form>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  {% else %}
  <p class="hint">Noch keine Zuordnung. Ohne Treffer landet alles im
  Fallback-Ordner <strong>{{ fallback_folder }}</strong>.</p>
  {% endif %}
</div>

<div class="card">
  <h2 style="margin-top:0">Ablage</h2>
  <dl>
    <dt>Archiv</dt><dd>{{ storage_description }}</dd>
    <dt>Mapping-Datei</dt><dd>{{ mapping_path }}</dd>
    <dt>Ohne Treffer</dt><dd>{{ fallback_folder }}</dd>
    <dt>Gesperrte Dateiendungen</dt><dd>{{ quarantine_folder }}</dd>
  </dl>
</div>
"""

PASSWORD_BODY = """
<div class="card">
  <h2 style="margin-top:0">Passwort aendern</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="field" style="margin-bottom:.6rem">
      <label for="current">Aktuelles Passwort</label>
      <input id="current" name="current" type="password" autocomplete="current-password" required>
    </div>
    <div class="field" style="margin-bottom:.6rem">
      <label for="new">Neues Passwort (mindestens {{ min_length }} Zeichen)</label>
      <input id="new" name="new" type="password" autocomplete="new-password" required>
    </div>
    <div class="field" style="margin-bottom:.9rem">
      <label for="confirm">Neues Passwort wiederholen</label>
      <input id="confirm" name="confirm" type="password" autocomplete="new-password" required>
    </div>
    <button type="submit">Passwort aendern</button>
  </form>
  <p class="hint">Nach der Aenderung werden alle anderen angemeldeten Sitzungen
  abgemeldet. Ein in der .env gesetztes WEB_PASSWORD wird ab dann ignoriert.</p>
</div>
"""


def create_app(config, storage, settings) -> Flask:
    """Build the web UI. `settings` is a SettingsStore, `storage` a Storage."""
    app = Flask(__name__)
    app.config.update(
        SECRET_KEY=_secret_key(settings),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=config.web_cookie_secure,
        PERMANENT_SESSION_LIFETIME=timedelta(hours=SESSION_HOURS),
        MAX_CONTENT_LENGTH=64 * 1024,
    )
    throttle = LoginThrottle()

    # --- helpers ---------------------------------------------------------

    def session_version() -> str:
        return settings.get(SETTING_SESSION_VERSION) or "1"

    def logged_in() -> bool:
        return session.get("auth_version") == session_version()

    def csrf_token() -> str:
        token = session.get("csrf")
        if not token:
            token = secrets.token_urlsafe(32)
            session["csrf"] = token
        return token

    def require_csrf() -> None:
        sent = request.form.get("csrf_token", "")
        expected = session.get("csrf", "")
        if not expected or not secrets.compare_digest(sent, expected):
            abort(400, "Ungueltiges oder abgelaufenes Formular - bitte neu laden.")

    def render(body_template: str, title: str, **context):
        # Markup, not str: the inner template is ours and already escaped its
        # own values, so it must be inserted as markup rather than escaped a
        # second time. Everything user-supplied went through the inner render.
        body = Markup(render_template_string(body_template, csrf_token=csrf_token(), **context))
        return render_template_string(
            BASE_TEMPLATE,
            title=title,
            body=body,
            logged_in=logged_in(),
            csrf_token=csrf_token(),
            messages=get_flashed_messages(with_categories=True),
        )

    def login_required(view):
        @wraps(view)
        def wrapper(*args, **kwargs):
            if not logged_in():
                return redirect(url_for("login"))
            return view(*args, **kwargs)

        return wrapper

    @app.after_request
    def security_headers(response):
        # No scripts, no external resources - so the policy can be strict.
        response.headers.setdefault(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'",
        )
        response.headers.setdefault("X-Content-Type-Options", "nosniff")
        response.headers.setdefault("Referrer-Policy", "no-referrer")
        response.headers.setdefault("X-Frame-Options", "DENY")
        return response

    # --- routes ----------------------------------------------------------

    @app.get("/healthz")
    def healthz():
        return "ok\n", 200, {"Content-Type": "text/plain; charset=utf-8"}

    @app.get("/")
    def index():
        return redirect(url_for("mapping_page") if logged_in() else url_for("login"))

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if logged_in():
            return redirect(url_for("mapping_page"))

        if request.method == "POST":
            require_csrf()
            client = request.remote_addr or "unknown"
            blocked = throttle.seconds_blocked(client)
            if blocked:
                flash(f"Zu viele Fehlversuche. Bitte {blocked} Sekunden warten.", "error")
                return render(LOGIN_BODY, "Anmelden"), 429

            stored_hash = settings.get(SETTING_PASSWORD_HASH) or ""
            if stored_hash and check_password_hash(stored_hash, request.form.get("password", "")):
                throttle.reset(client)
                # New session id material on login, so a token someone else
                # obtained before does not stay valid.
                session.clear()
                session.permanent = True
                session["auth_version"] = session_version()
                logger.info("Web UI: successful login from %s", client)
                return redirect(url_for("mapping_page"))

            throttle.record_failure(client)
            logger.warning("Web UI: failed login from %s", client)
            flash("Falsches Passwort.", "error")
            return render(LOGIN_BODY, "Anmelden"), 401

        return render(LOGIN_BODY, "Anmelden")

    @app.post("/logout")
    def logout():
        require_csrf()
        session.clear()
        flash("Abgemeldet.", "ok")
        return redirect(url_for("login"))

    @app.get("/mapping")
    @login_required
    def mapping_page():
        try:
            rules = load_rules(storage, config.mapping_path)
        except MappingError as exc:
            rules = {}
            flash(str(exc), "error")

        try:
            folders = storage.list_folders()
        except Exception as exc:  # noqa: BLE001 - the share may be unreachable right now
            folders = []
            logger.warning("Web UI: could not list folders (%s)", exc)
            flash(f"Ordnerliste konnte nicht geladen werden: {exc}", "error")

        def folder_options(current: str) -> list[str]:
            # A rule may point at a folder that does not exist yet (it is
            # created on the first attachment), so keep it selectable.
            return sorted({*folders, current}) if current else folders

        return render(
            MAPPING_BODY,
            "Zuordnungen",
            rules=rules,
            folders=folders,
            folder_options=folder_options,
            storage_description=storage.description,
            mapping_path=config.mapping_path,
            fallback_folder=config.fallback_folder,
            quarantine_folder=config.quarantine_folder,
        )

    @app.post("/mapping/add")
    @login_required
    def add_rule():
        require_csrf()
        new_folder = request.form.get("new_folder", "").strip()
        chosen = new_folder or request.form.get("folder", "")
        try:
            rules = load_rules(storage, config.mapping_path)
            keyword = validate_keyword(request.form.get("keyword", ""), rules)
            folder = validate_folder(chosen)
            if new_folder:
                storage.create_folder(folder)
            rules[keyword] = folder
            save_rules(storage, config.mapping_path, rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001 - surface storage failures in the UI
            logger.exception("Web UI: could not add rule")
            flash(f"Speichern fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: added mapping %r -> %r", keyword, folder)
            flash(f"{keyword} → {folder} gespeichert.", "ok")
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/update")
    @login_required
    def update_rule():
        require_csrf()
        keyword = request.form.get("keyword", "")
        try:
            rules = load_rules(storage, config.mapping_path)
            if keyword not in rules:
                raise MappingError(f"Das Stichwort {keyword!r} gibt es nicht mehr.")
            folder = validate_folder(request.form.get("folder", ""))
            rules[keyword] = folder
            save_rules(storage, config.mapping_path, rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not update rule")
            flash(f"Speichern fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: changed mapping %r -> %r", keyword, folder)
            flash(f"{keyword} → {folder} gespeichert.", "ok")
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/delete")
    @login_required
    def delete_rule():
        require_csrf()
        keyword = request.form.get("keyword", "")
        try:
            rules = load_rules(storage, config.mapping_path)
            if rules.pop(keyword, None) is None:
                raise MappingError(f"Das Stichwort {keyword!r} gibt es nicht mehr.")
            save_rules(storage, config.mapping_path, rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not delete rule")
            flash(f"Loeschen fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: deleted mapping %r", keyword)
            flash(f"{keyword} geloescht. Der Ordner selbst bleibt bestehen.", "ok")
        return redirect(url_for("mapping_page"))

    @app.route("/password", methods=["GET", "POST"])
    @login_required
    def password_page():
        if request.method == "POST":
            require_csrf()
            current = request.form.get("current", "")
            new = request.form.get("new", "")
            confirm = request.form.get("confirm", "")
            stored_hash = settings.get(SETTING_PASSWORD_HASH) or ""

            if not check_password_hash(stored_hash, current):
                flash("Aktuelles Passwort stimmt nicht.", "error")
            elif len(new) < MIN_PASSWORD_LENGTH:
                flash(f"Das neue Passwort braucht mindestens {MIN_PASSWORD_LENGTH} Zeichen.", "error")
            elif new != confirm:
                flash("Die beiden neuen Passwoerter stimmen nicht ueberein.", "error")
            elif new == current:
                flash("Das neue Passwort ist mit dem alten identisch.", "error")
            else:
                settings.set(SETTING_PASSWORD_HASH, generate_password_hash(new))
                # Invalidate every session, including this one, then log this
                # browser back in - so a stolen cookie stops working.
                settings.set(SETTING_SESSION_VERSION, str(int(session_version()) + 1))
                session.clear()
                session.permanent = True
                session["auth_version"] = session_version()
                logger.info("Web UI: password changed")
                flash("Passwort geaendert.", "ok")
                return redirect(url_for("mapping_page"))

        return render(PASSWORD_BODY, "Passwort", min_length=MIN_PASSWORD_LENGTH)

    return app


def _secret_key(settings) -> str:
    """Persist the cookie signing key, so restarts do not log everyone out."""
    key = settings.get(SETTING_SECRET_KEY)
    if not key:
        key = secrets.token_urlsafe(48)
        settings.set(SETTING_SECRET_KEY, key)
    return key


def ensure_password(settings, initial_password: str) -> None:
    """Take the initial password from the configuration, once.

    Raises SystemExit if there is neither a stored password nor one in the
    configuration - starting a password-protected UI without a password would
    either lock the user out or, worse, not.
    """
    if settings.get(SETTING_PASSWORD_HASH):
        return
    if not initial_password:
        raise SystemExit(
            "WEB_ENABLED=true, but no password is set. Put an initial password in "
            "WEB_PASSWORD (it is hashed on first start and can be changed in the UI)."
        )
    if len(initial_password) < MIN_PASSWORD_LENGTH:
        raise SystemExit(
            f"WEB_PASSWORD must be at least {MIN_PASSWORD_LENGTH} characters long."
        )
    settings.set(SETTING_PASSWORD_HASH, generate_password_hash(initial_password))
    logger.info("Web UI: initial password taken from WEB_PASSWORD")


def serve(config, storage, settings) -> threading.Thread:
    """Bind the port and serve the UI on a daemon thread.

    Binding happens here, in the caller's thread, so a port clash is a startup
    error rather than a stack trace that scrolls past unnoticed while the
    archiver keeps running without a UI.
    """
    from waitress import create_server

    ensure_password(settings, config.web_password)
    app = create_app(config, storage, settings)
    try:
        server = create_server(app, host=config.web_host, port=config.web_port, threads=4)
    except OSError as exc:
        raise SystemExit(
            f"Web UI cannot listen on {config.web_host}:{config.web_port}: {exc}"
        ) from exc

    thread = threading.Thread(target=server.run, name="mail2nas-web", daemon=True)
    thread.start()
    logger.info("Web UI listening on http://%s:%d", config.web_host, config.web_port)
    return thread
