"""The web UI - where mail2nas is configured, all of it.

Mailboxes, archives, keyword rules, printers, delivery addresses, pickup
folders and the general settings are all edited here and stored in the local
database; the `.env` only says which port this page listens on. A fresh
installation starts with nothing but a password, and the overview page walks
through what is still missing.

Deliberately plain: one password, no user accounts, no JavaScript, no external
assets - so the Content-Security-Policy can forbid everything but inline CSS.

This is a LAN tool. It authenticates with a single password over whatever
transport it is put behind - see the README for why it should not be exposed
to the internet without a TLS-terminating reverse proxy in front.
"""
from __future__ import annotations

import csv
import io
import logging
import os
import secrets
import threading
import time
from datetime import date, datetime, timedelta
from functools import wraps
from types import SimpleNamespace

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
    ALL_ACCOUNTS,
    MappingError,
    Rule,
    dump_rules,
    move_rule,
    rules_from_yaml,
    set_account,
    set_archive,
    set_printing,
    validate_folder,
    validate_keyword,
)
from .addresses import AddressError
from .migrate import SETTING_RULES_NOTE
from . import backup
from .journal import LEVELS as LOG_LEVELS, cutoff
from .notify import (
    DELAY_LIMITS,
    DIGEST_INTERVAL,
    SECURITY,
    NotifyError,
    NotifyStore,
    send_mail,
)
from .notify import validate as validate_notify
from .options import FILENAME_PREFIXES, LIMITS, OptionsError
from .options import validate as validate_options
from .archives import ArchiveError
from .pickups import PICKUP_INTERVAL, PickupError
from .discovery import discover
from .printers import PrinterError
from .printing import PrintError

logger = logging.getLogger(__name__)

SETTING_PASSWORD_HASH = "web_password_hash"
SETTING_SECRET_KEY = "web_secret_key"
SETTING_SESSION_VERSION = "web_session_version"

MIN_PASSWORD_LENGTH = 8
LOG_PAGE_SIZE = 100
CSV_LIMIT = 100_000
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
    --card: #ffffff; --accent: #2f6feb; --danger: #b3261e; --ok: #1f7a3d; --warn: #9a6700;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #16181c; --fg: #e6e8ea; --muted: #9aa2ad; --line: #2e333a;
      --card: #1e2126; --accent: #6a9bff; --danger: #ef6a63; --ok: #63c98c; --warn: #e3b341;
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
  td.keyword { font-weight: 600; overflow-wrap: break-word; min-width: 9rem; }
  .table-wrap { overflow-x: auto; }
  input, select, button { font: inherit; color: inherit; }
  input[type=text], input[type=password], input[type=date], input[type=email],
  input[type=file], select {
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
  .row.nowrap { flex-wrap: nowrap; gap: .4rem; }
  td select { max-width: 16rem; min-width: 8rem; }
  .field { display: flex; flex-direction: column; gap: .25rem; }
  .field label { font-size: .8rem; color: var(--muted); }
  .hint { color: var(--muted); font-size: .85rem; }
  .msg { border-radius: 8px; padding: .6rem .8rem; margin-bottom: .75rem; border: 1px solid; }
  .msg.error { color: var(--danger); border-color: var(--danger); }
  .msg.ok { color: var(--ok); border-color: var(--ok); }
  .msg.warn { color: var(--warn); border-color: var(--warn); }
  .state-ok { color: var(--ok); font-weight: 600; }
  .state-bad { color: var(--danger); font-weight: 600; }
  .state-wait { color: var(--warn); font-weight: 600; }
  ol.steps li { margin-bottom: .45rem; }
  ol.steps li.done { color: var(--muted); }
  input[type=number] { background: var(--bg); border: 1px solid var(--line); border-radius: 6px;
    padding: .4rem .5rem; width: 8rem; }
  textarea { font: inherit; }
  dl { display: grid; grid-template-columns: auto 1fr; gap: .3rem 1rem; margin: 0; font-size: .88rem; }
  dt { color: var(--muted); }
  dd { margin: 0; word-break: break-all; }
  form.inline { display: inline; }
  td.prio { white-space: nowrap; }
  button.arrow { background: transparent; border: 1px solid var(--line); color: var(--fg);
                 padding: .1rem .35rem; line-height: 1.1; }
  button.arrow[disabled] { opacity: .35; cursor: default; }
  code { background: var(--bg); border: 1px solid var(--line); border-radius: 4px;
         padding: 0 .25rem; font-size: .85em; }
  a { color: var(--accent); }
  .tabs { display: flex; gap: 1rem; margin-bottom: .8rem; }
  .tabs a { text-decoration: none; padding-bottom: .2rem; }
  .tabs a.active { border-bottom: 2px solid var(--accent); font-weight: 600; }
  table.log td { font-size: .85rem; vertical-align: top; }
  td.when { white-space: nowrap; color: var(--muted); }
  td.detail { overflow-wrap: anywhere; }
  .pager { display: flex; gap: 1rem; align-items: center; margin-top: .6rem; }
</style>
</head>
<body>
<main>
  <header>
    <h1>mail2nas</h1>
    {% if logged_in %}
    <nav>
      <a href="{{ url_for('overview_page') }}">Uebersicht</a> &middot;
      <a href="{{ url_for('mapping_page') }}">Zuordnungen</a> &middot;
      <a href="{{ url_for('config_page') }}">Konfiguration</a> &middot;
      <a href="{{ url_for('settings_page') }}">Einstellungen</a> &middot;
      <a href="{{ url_for('log_page') }}">Protokoll</a> &middot;
      <a href="{{ url_for('backup_page') }}">Sicherung</a> &middot;
      <a href="{{ url_for('password_page') }}">Passwort</a> &middot;
      <form class="inline" method="post" action="{{ url_for('logout') }}">
        <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
        <button class="link" type="submit">Abmelden</button>
      </form>
    </nav>
    {% endif %}
  </header>
  {% if logged_in and setup_hint %}
    <div class="msg warn">{{ setup_hint }}
      <a href="{{ url_for('overview_page') }}">Zur Einrichtung</a></div>
  {% endif %}
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
{% if migration_note %}
<div class="msg warn">{{ migration_note }}
  <form class="inline" method="post" action="{{ url_for('dismiss_migration_note') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="link" type="submit">Ausblenden</button>
  </form>
</div>
{% endif %}
{% if not storage_ok %}
<div class="msg warn">Das Standard-Archiv ist nicht erreichbar oder noch nicht eingerichtet -
  die Ordnerliste bleibt leer. Neue Ordner lassen sich trotzdem eintragen; sie werden
  beim ersten Anhang angelegt.</div>
{% endif %}
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
      {% if accounts|length > 1 %}
      <div class="field">
        <label for="account">Postfach</label>
        <select id="account" name="account">
          <option value="all">alle Postfaecher</option>
          {% for account in accounts %}
            <option value="{{ account.key }}">{{ account.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      {% if archives|length > 1 %}
      <div class="field">
        <label for="archive">Archiv</label>
        <select id="archive" name="archive">
          <option value="">Standard-Archiv</option>
          {% for entry in archives %}
            <option value="{{ entry.key }}">{{ entry.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      {% if printers %}
      <div class="field">
        <label for="printer">Drucken</label>
        <select id="printer" name="printer">
          <option value="">nicht drucken</option>
          <option value="account">drucken, Drucker des Postfachs</option>
          {% for printer in printers %}
            <option value="{{ printer.key }}">drucken auf {{ printer.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      <button type="submit">Hinzufuegen</button>
    </div>
  </form>
  <p class="hint">Gross-/Kleinschreibung ist egal. <code>*</code> steht fuer beliebig
  viele Zeichen, <code>?</code> fuer genau eines - <code>RE*2026</code> passt also auf
  &bdquo;RE-4711 vom 03.2026&ldquo;. Aenderungen wirken beim naechsten Durchlauf,
  ein Neustart ist nicht noetig.</p>
  {% if printers %}
  <p class="hint">Mit <em>Drucken</em> wird jeder Anhang, den diese Zuordnung trifft,
  zusaetzlich ausgedruckt - z. B. nur Rechnungen. Gedruckt wird erst, nachdem der
  Anhang abgelegt wurde. Drucker werden unter
  <a href="{{ url_for('config_page') }}">Konfiguration</a> angelegt.</p>
  {% endif %}
</div>

<div class="card">
  <h2 style="margin-top:0">Aktuelle Zuordnungen ({{ rules|length }})</h2>
  {% if rules %}
  <p class="hint" style="margin-top:0">Von oben nach unten geprueft - die erste
  passende Zuordnung gewinnt. Mit den Pfeilen verschieben.</p>
  <div class="table-wrap">
  <table>
    <tr>
      <th>Prio</th><th>Stichwort</th>
      <th>Ziel{% if accounts|length > 1 %}, Postfach{% endif %}{% if printers %} und Druck{% endif %}</th>
      <th></th>
    </tr>
    {% for rule in rules %}
    <tr>
      <td class="prio">
        <form class="inline" method="post" action="{{ url_for('move_rule_up') }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
          <button class="arrow" type="submit" title="nach oben"
                  {% if loop.first %}disabled{% endif %}>&uarr;</button>
        </form>
        <form class="inline" method="post" action="{{ url_for('move_rule_down') }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
          <button class="arrow" type="submit" title="nach unten"
                  {% if loop.last %}disabled{% endif %}>&darr;</button>
        </form>
        <span class="hint">{{ loop.index }}</span>
      </td>
      <td class="keyword">{{ rule.keyword }}</td>
      <td>
        <form method="post" action="{{ url_for('update_rule') }}" class="row nowrap">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
          <select name="folder">
            {% for option in folder_options(rule.folder) %}
              <option value="{{ option }}" {% if option == rule.folder %}selected{% endif %}>{{ option }}</option>
            {% endfor %}
          </select>
          {% if accounts|length > 1 %}
          <select name="account">
            <option value="all" {% if rule.account == 'all' %}selected{% endif %}>alle Postfaecher</option>
            {% for account in accounts %}
              <option value="{{ account.key }}"
                {% if rule.account == account.key %}selected{% endif %}>{{ account.name }}</option>
            {% endfor %}
            {% if rule.account not in account_keys %}
              <option value="{{ rule.account }}" selected>(geloeschtes Postfach)</option>
            {% endif %}
          </select>
          {% endif %}
          {% if archives|length > 1 %}
          <input type="hidden" name="archive_fields" value="1">
          <select name="archive" title="Archiv, auf dem der Zielordner liegt">
            <option value="" {% if not rule.archive %}selected{% endif %}>Standard-Archiv</option>
            {% for entry in archives %}
              <option value="{{ entry.key }}"
                {% if rule.archive == entry.key %}selected{% endif %}>{{ entry.name }}</option>
            {% endfor %}
            {% if rule.archive and rule.archive not in archive_keys %}
              <option value="{{ rule.archive }}" selected>(geloeschtes Archiv)</option>
            {% endif %}
          </select>
          {% endif %}
          {% if printers %}
          <input type="hidden" name="print_fields" value="1">
          <select name="printer" title="Anhaenge dieser Zuordnung drucken">
            <option value="" {% if not rule.print_attachments %}selected{% endif %}>nicht drucken</option>
            <option value="account"
              {% if rule.print_attachments and not rule.printer %}selected{% endif %}>drucken, Drucker des Postfachs</option>
            {% for printer in printers %}
              <option value="{{ printer.key }}"
                {% if rule.print_attachments and rule.printer == printer.key %}selected{% endif %}>drucken auf {{ printer.name }}</option>
            {% endfor %}
            {% if rule.printer and rule.printer not in printer_keys %}
              <option value="{{ rule.printer }}" selected>(geloeschter Drucker)</option>
            {% endif %}
          </select>
          {% endif %}
          <button class="secondary" type="submit">Speichern</button>
        </form>
      </td>
      <td>
        <form method="post" action="{{ url_for('delete_rule') }}">
          <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
          <input type="hidden" name="index" value="{{ loop.index0 }}">
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
  <h2 style="margin-top:0">Sichern und uebertragen</h2>
  <p class="hint" style="margin-top:0">Die Zuordnungen liegen in der Datenbank des
  Containers. Als Datei exportiert sind sie eine lesbare Sicherung - und lassen sich
  in eine andere Installation uebernehmen.</p>
  <p><a href="{{ url_for('export_rules') }}"><button class="secondary" type="button">
    Als mapping.yaml herunterladen</button></a></p>
  <form method="post" action="{{ url_for('import_rules') }}" enctype="multipart/form-data">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="rules_file">mapping.yaml importieren</label>
        <input id="rules_file" name="rules_file" type="file" accept=".yaml,.yml,.txt" required>
      </div>
      <div class="field">
        <label for="import_mode">Vorhandene Zuordnungen</label>
        <select id="import_mode" name="mode">
          <option value="append">behalten, neue anhaengen</option>
          <option value="replace">ersetzen</option>
        </select>
      </div>
      <button type="submit">Importieren</button>
    </div>
  </form>
  <p class="hint" style="margin-bottom:0">Gelesen werden das aktuelle Format und das alte
  (<code>Stichwort: ordner</code>). Beim Anhaengen werden Stichwoerter, die es schon gibt,
  uebersprungen. Ohne Treffer landet alles in <strong>{{ fallback_folder }}</strong>,
  gesperrte Dateitypen in <strong>{{ quarantine_folder }}</strong>.</p>
</div>
"""

CONFIG_BODY = """
<div class="card">
  <h2 style="margin-top:0">Postfaecher</h2>
  {% if accounts %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Postfach</th><th>Ordner</th><th>Modus</th><th>Status</th><th></th></tr>
    {% for account in accounts %}
    <tr>
      <td class="keyword">{{ account.name }}</td>
      <td>{{ account.user }}<br><span class="hint">{{ account.host }}:{{ account.port }}{%
        if not account.ssl %} &middot; ohne TLS{% endif %}</span></td>
      <td>{{ account.folder }}</td>
      <td>{{ account.mode }}{% if account.include_seen %}<br>
        <span class="hint">auch gelesene ab {{ account.seen_since }}</span>{% endif %}</td>
      <td>{% if account.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_account', account_id=account.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  {% else %}
  <p class="hint">Kein Postfach konfiguriert - es wird nichts abgeholt.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_account') }}">
    <button type="button">Postfach hinzufuegen</button></a></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Drucker</h2>
  {% if printers %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Warteschlange</th><th>Optionen</th><th>Status</th><th></th></tr>
    {% for printer in printers %}
    <tr>
      <td class="keyword">{{ printer.name }}</td>
      <td>{{ printer.destination }}{% if printer.server %}<br>
        <span class="hint">auf {{ printer.server }}</span>{% endif %}</td>
      <td>{{ printer.options or '-' }}{% if printer.copies > 1 %}
        <span class="hint">&middot; {{ printer.copies }} Kopien</span>{% endif %}</td>
      <td>{% if printer.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_printer', printer_id=printer.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Einmal angelegt, dann ueberall per Auswahlfeld verwendbar: je
  Postfach (alles drucken) und je Zuordnung (z. B. nur Rechnungen).</p>
  {% elif printing_enabled %}
  <p class="hint">Kein Drucker angelegt - es wird nichts gedruckt. Ein Drucker ist eine
  CUPS-Warteschlange; der Name ist derselbe wie in CUPS (<code>lpstat -p</code>).</p>
  {% else %}
  <p class="hint">Drucken ist unter <a href="{{ url_for('settings_page') }}">Einstellungen</a>
  abgeschaltet.</p>
  {% endif %}
  <p style="margin-bottom:0">
    <a href="{{ url_for('new_printer') }}">
      <button type="button">Drucker hinzufuegen</button></a>
    <a href="{{ url_for('discover_printers') }}">
      <button class="secondary" type="button">Im Netzwerk suchen</button></a>
  </p>
</div>

<div class="card">
  <h2 style="margin-top:0">Archive</h2>
  {% if archives %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Ort</th><th>Art</th><th>Status</th><th></th></tr>
    {% for entry in archives %}
    <tr>
      <td class="keyword">{{ entry.name }}{% if loop.first %}
        <span class="hint">Standard</span>{% endif %}</td>
      <td>{{ entry.location() }}</td>
      <td>{% if entry.backend == 'smb' %}SMB{% else %}gemountet{% endif %}</td>
      <td>{% if entry.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_archive', archive_id=entry.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Das erste aktive Archiv ist das Standard-Archiv: dorthin geht alles
  ohne eigene Angabe. Zuordnungen, Zustelladressen und Abholordner koennen jeweils ein
  anderes waehlen.</p>
  {% else %}
  <p class="hint"><strong>Noch kein Archiv eingerichtet</strong> - solange wird nichts
  abgeholt. Meist ist das eine SMB-Freigabe auf dem NAS; gemountet werden muss dafuer
  nichts.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_archive') }}">
    <button type="button">Archiv hinzufuegen</button></a></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Abholordner (Scan-to-Folder)</h2>
  {% if pickups %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Ordner</th><th>Ziel</th><th>Drucken</th><th>Status</th><th></th></tr>
    {% for entry in pickups %}
    <tr>
      <td class="keyword">{{ entry.name }}</td>
      <td>{{ entry.folder }}{% if entry.archive_label %}
        <span class="hint">auf {{ entry.archive_label }}</span>{% endif %}</td>
      <td>{{ entry.target_folder or 'nach Stichwoertern' }}{% if entry.target_archive_label %}
        <span class="hint">auf {{ entry.target_archive_label }}</span>{% endif %}</td>
      <td>{% if entry.print_attachments %}{{ entry.printer_label or 'ja' }}{% else %}nein{% endif %}</td>
      <td>{% if entry.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_pickup', pickup_id=entry.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Fertige Dateien werden von dort ins Archiv <em>verschoben</em> -
  ganz ohne Postfach. Geprueft wird alle {{ pickup_interval }} Sekunden.</p>
  {% else %}
  <p class="hint">Kein Abholordner eingerichtet. Fuer Geraete, die Scans per SMB
  ablegen statt sie zu mailen: Ordner eintragen, mail2nas raeumt ihn ab.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_pickup') }}">
    <button type="button">Abholordner hinzufuegen</button></a></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Zustelladressen</h2>
  {% if address_rules %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Empfaenger</th><th>Absender</th><th>Drucken</th><th>Ablegen</th>
      <th>Status</th><th></th></tr>
    {% for entry in address_rules %}
    <tr>
      <td class="keyword">{{ entry.name }}</td>
      <td>{{ entry.recipient or 'alle' }}</td>
      <td>{{ entry.sender or 'alle' }}</td>
      <td>{% if entry.print_attachments %}ja{% if entry.printer_label %}
        <span class="hint">&middot; {{ entry.printer_label }}</span>{% endif %}
        {% else %}nein{% endif %}</td>
      <td>{% if entry.archive_attachments %}ja{% if entry.folder %}
        <span class="hint">&middot; {{ entry.folder }}</span>{% endif %}{% if entry.archive_label %}
        <span class="hint">&middot; {{ entry.archive_label }}</span>{% endif %}
        {% else %}nein{% endif %}</td>
      <td>{% if entry.enabled %}aktiv{% else %}pausiert{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('edit_address', address_id=entry.id) }}">Bearbeiten</a>
      </td>
    </tr>
    {% endfor %}
  </table>
  </div>
  <p class="hint">Die erste passende Zustelladresse gewinnt. Sie entscheidet ueber
  Drucken und Ablegen; die Stichwort-Zuordnungen bestimmen dann nur noch den
  Zielordner, falls hier keiner steht.</p>
  {% else %}
  <p class="hint">Keine Zustelladresse angelegt. Damit wird nur nach Stichwoertern
  sortiert und nur gedruckt, was ein Postfach oder eine Zuordnung verlangt.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('new_address') }}">
    <button type="button">Zustelladresse hinzufuegen</button></a></p>
</div>

<div class="card">
  <h2 style="margin-top:0">Benachrichtigungen</h2>
  {% if notify.enabled %}
  <p style="margin-top:0">Aktiv - Mails gehen an <strong>{{ notify.recipients }}</strong>
  (ueber {{ notify.smtp_host }}).</p>
  {% else %}
  <p class="hint" style="margin-top:0">Aus. Eingerichtet schickt mail2nas eine Mail, wenn ein
  Postfach, Archiv, Abholordner oder die Sicherung laenger nicht funktioniert oder beim
  Verarbeiten etwas schiefgeht.</p>
  {% endif %}
  <p style="margin-bottom:0"><a href="{{ url_for('notifications_page') }}">
    <button type="button">Benachrichtigungen einrichten</button></a></p>
</div>

<p class="hint">Allgemeine Einstellungen - Ordner fuer Unsortiertes und Quarantaene,
Grenzwerte, gesperrte Dateitypen, Abrufintervall, Testmodus - stehen unter
<a href="{{ url_for('settings_page') }}">Einstellungen</a>.</p>
"""

ACCOUNT_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Postfach bearbeiten' if account else 'Postfach hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ account.name if account else '' }}"
               placeholder="z. B. Buchhaltung" required>
      </div>
      <div class="field">
        <label for="host">IMAP-Server</label>
        <input id="host" name="host" type="text" value="{{ account.host if account else '' }}"
               placeholder="imap.example.com" required>
      </div>
      <div class="field">
        <label for="port">Port</label>
        <input id="port" name="port" type="text" value="{{ account.port if account else '993' }}" required>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="user">Benutzer</label>
        <input id="user" name="user" type="text" value="{{ account.user if account else '' }}" required>
      </div>
      <div class="field">
        <label for="password">Passwort</label>
        <input id="password" name="password" type="password" autocomplete="new-password"
               {% if account %}placeholder="unveraendert lassen: leer"{% else %}required{% endif %}>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="folder">Zu ueberwachender Ordner</label>
        <input id="folder" name="folder" type="text"
               value="{{ account.folder if account else 'INBOX' }}" required>
      </div>
      <div class="field">
        <label for="mode">Abrufmodus</label>
        <select id="mode" name="mode">
          <option value="idle" {% if account and account.mode == 'idle' %}selected{% endif %}>IDLE (Push)</option>
          <option value="poll" {% if not account or account.mode == 'poll' %}selected{% endif %}>Polling</option>
        </select>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="processed_folder">Verarbeitete Mails verschieben nach (optional)</label>
        <input id="processed_folder" name="processed_folder" type="text"
               value="{{ account.processed_folder if account else '' }}">
      </div>
      <div class="field">
        <label for="oversized_folder">Zu grosse Mails verschieben nach (optional)</label>
        <input id="oversized_folder" name="oversized_folder" type="text"
               value="{{ account.oversized_folder if account else '' }}">
      </div>
    </div>
    <p style="margin:.8rem 0 .2rem">
      <label><input type="checkbox" name="ssl" value="1"
        {% if not account or account.ssl %}checked{% endif %}> TLS/SSL verwenden</label>
      &nbsp;&nbsp;
      <label><input type="checkbox" name="enabled" value="1"
        {% if not account or account.enabled %}checked{% endif %}> Postfach aktiv</label>
    </p>

    <h2>Bereits gelesene Mails</h2>
    <div class="row">
      <p style="margin:.2rem 0"><label><input type="checkbox" name="include_seen" value="1"
        {% if account and account.include_seen %}checked{% endif %}>
        Auch bereits gelesene Mails verarbeiten</label></p>
      <div class="field">
        <label for="seen_since">Angekommen ab</label>
        <input id="seen_since" name="seen_since" type="date"
               value="{{ account.seen_since if account and account.seen_since else today }}">
      </div>
    </div>
    <p class="hint">Normalerweise holt mail2nas nur ungelesene Mails. Mit Haken auch die,
    die jemand schon geoeffnet hat - etwa in Outlook, bevor mail2nas an der Reihe war.
    Jede Mail wird trotzdem nur einmal verarbeitet. Beruecksichtigt werden Mails ab dem
    Datum, hoechstens so weit zurueck, wie das Protokoll aufbewahrt wird
    ({{ retention_days }} Tage, unter Einstellungen).</p>

    {% if printers %}
    <input type="hidden" name="print_fields" value="1">
    <h2>Drucken und Ablegen</h2>
    <div class="row">
      <div class="field">
        <label for="account_printer">Drucker fuer dieses Postfach</label>
        <select id="account_printer" name="printer">
          <option value="">kein Drucker</option>
          {% for printer in printers %}
            <option value="{{ printer.key }}"
              {% if account and account.printer == printer.key %}selected{% endif %}>{{ printer.name }}</option>
          {% endfor %}
          {% if account and account.printer and account.printer not in printer_keys %}
            <option value="{{ account.printer }}" selected>(geloeschter Drucker)</option>
          {% endif %}
        </select>
      </div>
    </div>
    <p style="margin:.6rem 0 .2rem">
      <label><input type="checkbox" name="print_attachments" value="1"
        {% if account and account.print_attachments %}checked{% endif %}>
        Alle Anhaenge dieses Postfachs drucken</label>
    </p>
    <p style="margin:.2rem 0 .2rem">
      <label><input type="checkbox" name="archive_attachments" value="1"
        {% if not account or account.archive_attachments %}checked{% endif %}>
        Anhaenge im Archiv ablegen</label>
    </p>
    <p class="hint">Ohne Haken bei &bdquo;ablegen&ldquo; wird nur gedruckt und nichts
    gespeichert. Anhaenge mit gesperrter Dateiendung landen trotzdem im
    Quarantaene-Ordner - gedruckt werden sie nie. Einzelne Zuordnungen koennen
    zusaetzlich drucken, auch auf einem anderen Drucker.</p>
    {% endif %}

    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Aenderungen greifen innerhalb weniger Sekunden; eine laufende
  IMAP-Verbindung wird dafuer neu aufgebaut.</p>
</div>

{% if account %}
<div class="card">
  <h2 style="margin-top:0">Verbindung testen</h2>
  <form method="post" action="{{ url_for('test_account', account_id=account.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Anmeldung und Ordner pruefen</button>
    <p class="hint">Meldet sich mit den gespeicherten Daten an und oeffnet den Ordner -
    liest und veraendert keine Mail.</p>
  </form>
</div>

<div class="card">
  <h2 style="margin-top:0">Postfach loeschen</h2>
  <form method="post" action="{{ url_for('delete_account', account_id=account.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Dieses Postfach loeschen</button>
    <p class="hint">Zuordnungen, die nur fuer dieses Postfach gelten, bleiben
    bestehen und greifen dann nicht mehr.</p>
  </form>
</div>
{% endif %}
"""

PRINTER_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Drucker bearbeiten' if printer else 'Drucker hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ printer.name if printer else '' }}"
               placeholder="z. B. Buero EG" required>
      </div>
      <div class="field">
        <label for="destination">Warteschlange in CUPS</label>
        <input id="destination" name="destination" type="text"
               value="{{ printer.destination if printer else '' }}"
               placeholder="z. B. Kyocera_M2540" required>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="server">CUPS-Server (optional)</label>
        <input id="server" name="server" type="text" value="{{ printer.server if printer else '' }}"
               placeholder="leer = lokaler cupsd, sonst z. B. cups.lan:631">
      </div>
      <div class="field">
        <label for="copies">Kopien</label>
        <input id="copies" name="copies" type="text" value="{{ printer.copies if printer else '1' }}">
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="options">Druckoptionen (optional)</label>
        <input id="options" name="options" type="text"
               value="{{ printer.options if printer else '' }}"
               placeholder="z. B. media=A4 sides=two-sided-long-edge">
      </div>
    </div>
    <p style="margin:.8rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not printer or printer.enabled %}checked{% endif %}> Drucker aktiv</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Die Warteschlange ist der Name, unter dem der Drucker in CUPS
  bekannt ist (<code>lpstat -p</code>). Die Optionen sind genau die, die
  <code>lp -o</code> versteht - jeweils ohne <code>-o</code>, mehrere durch
  Leerzeichen getrennt.</p>
</div>

{% if printer and printer.id %}
<div class="card">
  <h2 style="margin-top:0">Testdruck</h2>
  <form method="post" action="{{ url_for('test_printer', printer_id=printer.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Testseite drucken</button>
    <p class="hint">Druckt eine Seite mit den Einstellungen dieses Druckers - so
    laesst sich pruefen, ob die Warteschlange stimmt, bevor die erste Rechnung
    ankommt.</p>
  </form>
</div>

<div class="card">
  <h2 style="margin-top:0">Drucker loeschen</h2>
  <form method="post" action="{{ url_for('delete_printer', printer_id=printer.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Diesen Drucker loeschen</button>
    <p class="hint">Postfaecher und Zuordnungen, die auf ihn zeigen, drucken danach
    nicht mehr - das steht dann im Log.</p>
  </form>
</div>
{% endif %}
"""

ADDRESS_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Zustelladresse bearbeiten' if entry else 'Zustelladresse hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ entry.name if entry else '' }}"
               placeholder="z. B. Drucker Buero">
      </div>
      <div class="field">
        <label for="recipient">Empfaengeradresse</label>
        <input id="recipient" name="recipient" type="text"
               value="{{ entry.recipient if entry else '' }}"
               placeholder="drucker@firma.de, @firma.de oder drucker-*@firma.de">
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="sender">Nur von diesem Absender (optional)</label>
        <input id="sender" name="sender" type="text" value="{{ entry.sender if entry else '' }}"
               placeholder="leer = von jedem; sonst z. B. @firma.de">
      </div>
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="print_attachments" value="1"
        {% if not entry or entry.print_attachments %}checked{% endif %}>
        Anhaenge drucken</label>
    </p>
    <div class="field">
      <label for="printer">Drucker</label>
      <select id="printer" name="printer">
        <option value="">Drucker des Postfachs</option>
        {% for printer in printers %}
        <option value="{{ printer.key }}"
          {% if entry and entry.printer == printer.key %}selected{% endif %}>
          {{ printer.label() }}</option>
        {% endfor %}
        {% if entry and entry.printer and entry.printer not in printer_keys %}
        <option value="{{ entry.printer }}" selected>(geloeschter Drucker)</option>
        {% endif %}
      </select>
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="archive_attachments" value="1"
        {% if not entry or entry.archive_attachments %}checked{% endif %}>
        Anhaenge per SMB ablegen</label>
    </p>
    <div class="row">
      <div class="field">
        <label for="folder">Zielordner (optional)</label>
        <input id="folder" name="folder" type="text" value="{{ entry.folder if entry else '' }}"
               placeholder="leer = nach Stichwort-Zuordnungen">
      </div>
      {% if archives|length > 1 %}
      <div class="field">
        <label for="archive">Archiv</label>
        <select id="archive" name="archive">
          <option value="">Standard-Archiv</option>
          {% for item in archives %}
          <option value="{{ item.key }}"
            {% if entry and entry.archive == item.key %}selected{% endif %}>{{ item.name }}</option>
          {% endfor %}
          {% if entry and entry.archive and entry.archive not in archive_keys %}
          <option value="{{ entry.archive }}" selected>(geloeschtes Archiv)</option>
          {% endif %}
        </select>
      </div>
      {% endif %}
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not entry or entry.enabled %}checked{% endif %}> Aktiv</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Gepruefte Kopfzeilen sind Delivered-To, X-Original-To, Envelope-To,
  To und Cc - ein Alias, das in dieses Postfach zugestellt wird, wird also auch
  dann erkannt, wenn im To: etwas anderes steht. Sind Empfaenger- und
  Absenderadresse gesetzt, muessen beide passen; der Absender wirkt dann als
  Schutz davor, dass Fremde ueber die Adresse drucken koennen.</p>
</div>

{% if entry %}
<div class="card">
  <h2 style="margin-top:0">Zustelladresse loeschen</h2>
  <form method="post" action="{{ url_for('delete_address', address_id=entry.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Diese Zustelladresse loeschen</button>
    <p class="hint">Mail an diese Adresse wird danach wieder wie jede andere
    behandelt.</p>
  </form>
</div>
{% endif %}
"""

DISCOVERY_BODY = """
<div class="card">
  <h2 style="margin-top:0">Drucker im Netzwerk suchen</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="server">CUPS-Server abfragen (optional)</label>
        <input id="server" name="server" type="text" value="{{ server }}"
               placeholder="z. B. cups.lan:631 - leer = lokaler cupsd">
      </div>
      <button type="submit">Suchen</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Zurueck</button></a>
    </div>
    <p class="hint" style="margin-bottom:0">Gefragt werden die Warteschlangen des
    CUPS-Servers und - per mDNS - Geraete, die sich im Netz selbst ankuendigen.</p>
  </form>
</div>

{% if searched %}
<div class="card">
  <h2 style="margin-top:0">Gefunden</h2>
  {% if found %}
  <div class="table-wrap">
  <table>
    <tr><th>Name</th><th>Warteschlange</th><th>Server</th><th>Quelle</th><th></th></tr>
    {% for item in found %}
    <tr>
      <td class="keyword">{{ item.name }}</td>
      <td>{{ item.destination }}<br><span class="hint">{{ item.detail }}</span></td>
      <td>{{ item.server or 'lokal' }}</td>
      <td>{% if item.ready_to_use %}CUPS-Warteschlange{% else %}im Netz gefunden{% endif %}</td>
      <td style="white-space:nowrap">
        <a href="{{ url_for('new_printer', name=item.name, destination=item.destination,
                            server=item.server) }}">Uebernehmen</a>
      </td>
    </tr>
    {% if not item.ready_to_use %}
    <tr><td colspan="5" class="hint">Noch keine Warteschlange. Zuverlaessig wird daraus
      eine mit:<br><code>{{ item.lpadmin_command() }}</code></td></tr>
    {% endif %}
    {% endfor %}
  </table>
  </div>
  <p class="hint">„Uebernehmen" fuellt das Drucker-Formular vor. Danach einmal die
  Testseite drucken - das ist der schnellste Weg zu wissen, ob der Weg stimmt.</p>
  {% else %}
  <p class="hint">Nichts gefunden.</p>
  {% endif %}
  {% for problem in problems %}
  <p class="hint">{{ problem }}</p>
  {% endfor %}
</div>
{% endif %}
"""

ARCHIVE_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Archiv bearbeiten' if archive else 'Archiv hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ archive.name if archive else '' }}"
               placeholder="z. B. NAS Buero">
      </div>
      <div class="field">
        <label for="backend">Art</label>
        <select id="backend" name="backend">
          <option value="smb" {% if not archive or archive.backend == 'smb' %}selected{% endif %}>
            SMB-Freigabe (nichts gemountet)</option>
          <option value="local" {% if archive and archive.backend == 'local' %}selected{% endif %}>
            Gemountetes Verzeichnis</option>
        </select>
      </div>
    </div>

    <p class="hint" style="margin:.9rem 0 .2rem"><strong>Nur fuer SMB:</strong></p>
    <div class="row">
      <div class="field">
        <label for="host">Server (NAS)</label>
        <input id="host" name="host" type="text" value="{{ archive.host if archive else '' }}"
               placeholder="nas.lan oder 192.168.1.10">
      </div>
      <div class="field">
        <label for="share">Freigabe</label>
        <input id="share" name="share" type="text" value="{{ archive.share if archive else '' }}"
               placeholder="z. B. Belege">
      </div>
      <div class="field">
        <label for="root">Unterordner (optional)</label>
        <input id="root" name="root" type="text" value="{{ archive.root if archive else '' }}"
               placeholder="z. B. archiv/2026">
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="user">Benutzer</label>
        <input id="user" name="user" type="text" value="{{ archive.user if archive else '' }}">
      </div>
      <div class="field">
        <label for="password">Passwort{% if archive %}
          <span class="hint">(leer = unveraendert)</span>{% endif %}</label>
        <input id="password" name="password" type="password" autocomplete="new-password">
      </div>
      <div class="field">
        <label for="domain">Domain (optional)</label>
        <input id="domain" name="domain" type="text" value="{{ archive.domain if archive else '' }}">
      </div>
      <div class="field">
        <label for="port">Port</label>
        <input id="port" name="port" type="text" value="{{ archive.port if archive else '445' }}">
      </div>
    </div>
    <p style="margin:.6rem 0 .2rem">
      <label><input type="checkbox" name="encrypt" value="1"
        {% if not archive or archive.encrypt %}checked{% endif %}> Verbindung verschluesseln
        (SMB3; abschalten, wenn der Server das ablehnt)</label>
    </p>

    <p class="hint" style="margin:.9rem 0 .2rem"><strong>Nur fuer ein gemountetes
    Verzeichnis:</strong></p>
    <div class="field">
      <label for="path">Pfad</label>
      <input id="path" name="path" type="text" value="{{ archive.path if archive else '' }}"
             placeholder="/mnt/nas2">
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not archive or archive.enabled %}checked{% endif %}> Archiv aktiv</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Das <strong>erste aktive</strong> Archiv ist das Standard-Archiv: dorthin
  geht alles, was kein eigenes Archiv nennt, und dort liegen der Fallback- und der
  Quarantaene-Ordner.
  Ein gemountetes Verzeichnis muss vom Betriebssystem eingebunden sein - mail2nas
  mountet nichts.</p>
</div>

{% if archive %}
<div class="card">
  <h2 style="margin-top:0">Verbindung testen</h2>
  <form method="post" action="{{ url_for('test_archive', archive_id=archive.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Verbindung testen</button>
    <p class="hint">Schreibt eine winzige Testdatei und loescht sie wieder - so steht
    fest, dass Zugangsdaten und Schreibrechte stimmen, bevor die erste Rechnung
    kommt.</p>
  </form>
</div>

<div class="card">
  <h2 style="margin-top:0">Archiv loeschen</h2>
  <form method="post" action="{{ url_for('delete_archive', archive_id=archive.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Dieses Archiv loeschen</button>
    <p class="hint">Die Dateien darauf bleiben unangetastet. Zuordnungen und Adressen,
    die darauf zeigten, nutzen danach das Standard-Archiv.</p>
  </form>
</div>
{% endif %}
"""

PICKUP_BODY = """
<div class="card">
  <h2 style="margin-top:0">{{ 'Abholordner bearbeiten' if pickup else 'Abholordner hinzufuegen' }}</h2>
  <form method="post">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="name">Anzeigename</label>
        <input id="name" name="name" type="text" value="{{ pickup.name if pickup else '' }}"
               placeholder="z. B. Kopierer Flur">
      </div>
      {% if archives|length > 1 %}
      <div class="field">
        <label for="archive">Archiv, auf dem der Ordner liegt</label>
        <select id="archive" name="archive">
          <option value="">Standard-Archiv</option>
          {% for entry in archives %}
          <option value="{{ entry.key }}"
            {% if pickup and pickup.archive == entry.key %}selected{% endif %}>{{ entry.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      <div class="field">
        <label for="folder">Abholordner</label>
        <input id="folder" name="folder" type="text" value="{{ pickup.folder if pickup else '' }}"
               placeholder="z. B. scans/kopierer-flur" required>
      </div>
    </div>

    <div class="row" style="margin-top:.6rem">
      {% if archives|length > 1 %}
      <div class="field">
        <label for="target_archive">Zielarchiv</label>
        <select id="target_archive" name="target_archive">
          <option value="">Standard-Archiv</option>
          {% for entry in archives %}
          <option value="{{ entry.key }}"
            {% if pickup and pickup.target_archive == entry.key %}selected{% endif %}>
            {{ entry.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      <div class="field">
        <label for="target_folder">Zielordner <span class="hint">(leer = nach Stichwoertern)</span></label>
        <input id="target_folder" name="target_folder" type="text"
               value="{{ pickup.target_folder if pickup else '' }}" placeholder="z. B. scans">
      </div>
      {% if printers %}
      <div class="field">
        <label for="printer">Drucken</label>
        <select id="printer" name="printer">
          <option value="">nicht drucken</option>
          {% for printer in printers %}
          <option value="{{ printer.key }}"
            {% if pickup and pickup.print_attachments and pickup.printer == printer.key %}selected{% endif %}>
            drucken auf {{ printer.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
    </div>

    <p style="margin:.9rem 0 .2rem">
      <label><input type="checkbox" name="enabled" value="1"
        {% if not pickup or pickup.enabled %}checked{% endif %}> Ordner ueberwachen</label>
    </p>
    <div class="row" style="margin-top:.6rem">
      <button type="submit">Speichern</button>
      <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Abbrechen</button></a>
    </div>
  </form>
  <p class="hint">Der Ordner ist ein <strong>Postausgang, kein Archiv</strong>: was
  abgeholt wurde, wird von dort <em>verschoben</em>. Angefasst wird eine Datei erst,
  wenn sie {{ min_age }} Sekunden unveraendert ist - sonst landet eine noch laufende
  Uebertragung im Archiv. Unterordner werden mitgelesen; versteckte und halbfertige
  Dateien (<code>.tmp</code>, <code>.part</code>) bleiben liegen.</p>
  <p class="hint">Ohne Zielordner entscheiden die Stichwort-Zuordnungen - dabei greifen
  nur die fuer „alle Postfaecher", denn eine Datei aus einem Ordner gehoert zu keinem
  Postfach. Gesperrte Dateiendungen kommen auch hier in die Quarantaene.</p>
</div>

{% if pickup %}
<div class="card">
  <h2 style="margin-top:0">Abholordner loeschen</h2>
  <form method="post" action="{{ url_for('delete_pickup', pickup_id=pickup.id) }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="danger" type="submit">Diesen Abholordner loeschen</button>
    <p class="hint">Der Ordner selbst und alles darin bleiben unangetastet - es wird
    nur nicht mehr hineingesehen.</p>
  </form>
</div>
{% endif %}
"""

OVERVIEW_BODY = """
{% if initial_password %}
<div class="msg warn">Angemeldet mit dem automatisch erzeugten Startpasswort. Bitte unter
  <a href="{{ url_for('password_page') }}">Passwort</a> ein eigenes setzen.</div>
{% endif %}

{% if steps_open %}
<div class="card">
  <h2 style="margin-top:0">Einrichtung</h2>
  <ol class="steps">
    {% for step in steps %}
    <li class="{{ 'done' if step.done }}">
      {% if step.done %}&#10003;{% endif %}
      <a href="{{ step.url }}">{{ step.title }}</a> - <span class="hint">{{ step.hint }}</span>
    </li>
    {% endfor %}
  </ol>
  <p class="hint" style="margin-bottom:0">Alles wird hier eingestellt und sofort
  uebernommen - ein Neustart des Containers ist nie noetig.</p>
</div>
{% endif %}

<div class="card">
  <h2 style="margin-top:0">Status</h2>
  <table>
    <tr><th>Was</th><th>Zustand</th><th>Details</th></tr>
    <tr>
      <td class="keyword">Standard-Archiv</td>
      <td>{% if archive_status.ok %}<span class="state-ok">bereit</span>
          {% elif archive_status.ok is none %}<span class="state-wait">wird geprueft</span>
          {% else %}<span class="state-bad">nicht bereit</span>{% endif %}</td>
      <td>{{ archive_status.detail or '-' }}</td>
    </tr>
    {% for row in workers %}
    <tr>
      <td class="keyword">{{ row.label }}</td>
      <td>{% if row.state == 'verbunden' %}<span class="state-ok">verbunden</span>
          {% elif row.state == 'Fehler' %}<span class="state-bad">Fehler</span>
          {% else %}<span class="state-wait">{{ row.state }}</span>{% endif %}</td>
      <td>{% if row.detail %}{{ row.detail }}{% endif %}
          {% if row.processed %}<span class="hint">&middot; {{ row.processed }} verarbeitet</span>{% endif %}
          {% if row.last_ok %}<span class="hint">&middot; zuletzt ok {{ row.last_ok }}</span>{% endif %}
          {% if row.last_error %}<br><span class="state-bad">{{ row.last_error }}</span>
            <span class="hint">({{ row.last_error_at }})</span>{% endif %}</td>
    </tr>
    {% endfor %}
    {% if backup_status.ok is not none %}
    <tr>
      <td class="keyword">Automatische Sicherung</td>
      <td>{% if backup_status.ok %}<span class="state-ok">ok</span>
          {% else %}<span class="state-bad">Fehler</span>{% endif %}</td>
      <td>{{ backup_status.detail }}</td>
    </tr>
    {% endif %}
    {% if recent_problems %}
    <tr>
      <td class="keyword">Verarbeitung</td>
      <td><span class="state-bad">{{ recent_problems }} Problem(e)</span></td>
      <td>in den letzten 24 Stunden -
        <a href="{{ url_for('log_page', problems=1) }}">im Protokoll ansehen</a></td>
    </tr>
    {% endif %}
    {% for problem in pickup_problems %}
    <tr><td class="keyword">Abholordner</td><td><span class="state-bad">Problem</span></td>
      <td>{{ problem }}</td></tr>
    {% endfor %}
  </table>
  {% if not workers and ready %}
  <p class="hint">Kein aktives Postfach - es wird keine Mail abgeholt.</p>
  {% endif %}
  {% if dry_run %}
  <p class="state-wait">Testmodus ist an: es wird nichts abgelegt, gedruckt oder als
  gelesen markiert, nur protokolliert.</p>
  {% endif %}
  <p class="hint" style="margin-bottom:0">Stand {{ now }} &middot; laeuft seit {{ started }}.
  Was mit jeder Mail passiert ist, steht im <a href="{{ url_for('log_page') }}">Protokoll</a>.</p>
</div>

<div class="card">
  <h2 style="margin-top:0">Auf einen Blick</h2>
  <dl>
    <dt>Postfaecher</dt><dd>{{ counts.accounts }}</dd>
    <dt>Archive</dt><dd>{{ counts.archives }}</dd>
    <dt>Zuordnungen</dt><dd>{{ counts.rules }}</dd>
    <dt>Drucker</dt><dd>{{ counts.printers }}</dd>
    <dt>Zustelladressen</dt><dd>{{ counts.addresses }}</dd>
    <dt>Abholordner</dt><dd>{{ counts.pickups }}</dd>
  </dl>
</div>
"""

SETTINGS_BODY = """
<form method="post">
  <input type="hidden" name="csrf_token" value="{{ csrf_token }}">

  <div class="card">
    <h2 style="margin-top:0">Ablage</h2>
    <div class="row">
      <div class="field">
        <label for="fallback_folder">Ordner fuer Anhaenge ohne Treffer</label>
        <input id="fallback_folder" name="fallback_folder" type="text" value="{{ o.fallback_folder }}">
      </div>
      <div class="field">
        <label for="quarantine_folder">Quarantaene-Ordner</label>
        <input id="quarantine_folder" name="quarantine_folder" type="text"
               value="{{ o.quarantine_folder }}">
      </div>
      <div class="field">
        <label for="filename_prefix">Dateiname beginnt mit</label>
        <select id="filename_prefix" name="filename_prefix">
          {% for value, text in prefixes.items() %}
            <option value="{{ value }}" {% if o.filename_prefix == value %}selected{% endif %}>{{ text }}</option>
          {% endfor %}
        </select>
      </div>
    </div>
    <p style="margin:.7rem 0 .2rem"><label><input type="checkbox" name="match_body" value="1"
      {% if o.match_body %}checked{% endif %}> Stichwoerter auch im Mailtext suchen
      (sonst nur Dateiname und Betreff)</label></p>
    <p class="hint" style="margin-bottom:0">Beide Ordner liegen im Standard-Archiv, relativ zu
    dessen Wurzel. Beispiel fuer den Dateinamen:
    <code>2026-03-01_lieferant_example.com_Rechnung.pdf</code>.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Gesperrte Dateitypen</h2>
    <div class="field">
      <label for="blocked_extensions">Endungen, die immer in die Quarantaene gehen</label>
      <input id="blocked_extensions" name="blocked_extensions" type="text" style="max-width:100%"
             value="{{ blocked }}">
    </div>
    <p class="hint" style="margin-bottom:0">Gilt auch, wenn ein Stichwort passt und auch fuer
    Abholordner - so kann &bdquo;Rechnung.exe&ldquo; nie im Rechnungsordner landen. Gedruckt
    wird so etwas nie. Komma-, Semikolon- oder Leerzeichen-getrennt, ohne Punkt.
    <strong>Leer heisst: keine Pruefung.</strong></p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Abruf und Grenzwerte</h2>
    <div class="row">
      <div class="field">
        <label for="poll_interval">Abrufintervall (Sekunden)</label>
        <input id="poll_interval" name="poll_interval" type="number" value="{{ o.poll_interval }}"
               min="{{ limits.poll_interval[0] }}" max="{{ limits.poll_interval[1] }}">
      </div>
      <div class="field">
        <label for="max_attachment_size_mb">Max. Groesse je Anhang (MB)</label>
        <input id="max_attachment_size_mb" name="max_attachment_size_mb" type="number"
               value="{{ o.max_attachment_size_mb }}" min="1">
      </div>
      <div class="field">
        <label for="max_message_size_mb">Max. Groesse je Mail (MB)</label>
        <input id="max_message_size_mb" name="max_message_size_mb" type="number"
               value="{{ o.max_message_size_mb }}" min="1">
      </div>
      <div class="field">
        <label for="max_attachments_per_message">Max. Anhaenge je Mail</label>
        <input id="max_attachments_per_message" name="max_attachments_per_message" type="number"
               value="{{ o.max_attachments_per_message }}" min="1">
      </div>
      <div class="field">
        <label for="pickup_min_age">Abholordner: fertig nach (Sekunden)</label>
        <input id="pickup_min_age" name="pickup_min_age" type="number"
               value="{{ o.pickup_min_age }}" min="0">
      </div>
    </div>
    <p class="hint" style="margin-bottom:0">Das Intervall gilt im Polling-Modus und als
    Erneuerung bei IDLE. Mails ueber der Maximalgroesse werden gar nicht erst geladen,
    sondern nur als gelesen markiert (und ggf. in den Ordner fuer zu grosse Mails
    verschoben). Eine Datei im Abholordner wird erst angefasst, wenn sie so lange
    unveraendert ist - ein Scan, der noch geschrieben wird, bleibt liegen.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Drucken</h2>
    <p style="margin-top:0"><label><input type="checkbox" name="printing_enabled" value="1"
      {% if o.printing_enabled %}checked{% endif %}> Drucken erlaubt</label></p>
    <div class="row">
      <div class="field">
        <label for="printable_extensions">Druckbare Dateitypen</label>
        <input id="printable_extensions" name="printable_extensions" type="text"
               style="max-width:100%" value="{{ printable }}">
      </div>
      <div class="field">
        <label for="print_timeout">Zeitgrenze je Druckauftrag (Sekunden)</label>
        <input id="print_timeout" name="print_timeout" type="number"
               value="{{ o.print_timeout }}" min="5">
      </div>
    </div>
    <p class="hint" style="margin-bottom:0">Ausgeschaltet ist das der Notschalter: es wird
    nichts gedruckt, egal was bei Postfaechern, Zuordnungen und Adressen steht. Nur die
    genannten Formate gehen an einen Drucker (leer = Standardliste) - ein .docx ohne
    Konverter kaeme als Zeichensalat heraus.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Protokoll</h2>
    <div class="field">
      <label for="retention_days">Protokoll aufbewahren (Tage)</label>
      <input id="retention_days" name="retention_days" type="number"
             value="{{ o.retention_days }}" min="{{ limits.retention_days[0] }}"
             max="{{ limits.retention_days[1] }}">
    </div>
    <p class="hint" style="margin-bottom:0">So lange bleiben das Verarbeitungsprotokoll (was
    mit welchem Anhang passiert ist), das Dienstprotokoll und die Liste der verarbeiteten
    Mails erhalten - Standard 183 Tage, also ein halbes Jahr. Aeltere Eintraege werden
    einmal taeglich geloescht; die abgelegten Dateien selbst bleiben natuerlich.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Testmodus</h2>
    <p style="margin-top:0"><label><input type="checkbox" name="dry_run" value="1"
      {% if o.dry_run %}checked{% endif %}> Nur protokollieren - nichts ablegen, nichts
      drucken, keine Mail als gelesen markieren</label></p>
    <p class="hint" style="margin-bottom:0">Zum Ausprobieren neuer Zuordnungen: im
    Container-Log steht dann, was passiert waere. Achtung: im Testmodus wird dieselbe
    Mail bei jedem Durchlauf erneut geprueft.</p>
  </div>

  <button type="submit">Einstellungen speichern</button>
  <span class="hint">&nbsp;Wirkt sofort, ohne Neustart.</span>
</form>
"""

LOG_BODY = """
<div class="tabs">
  <a href="{{ url_for('log_page') }}" class="{{ 'active' if view == 'journal' }}">Verarbeitung</a>
  <a href="{{ url_for('log_page', view='log') }}" class="{{ 'active' if view == 'log' }}">Dienstprotokoll</a>
</div>

{% if view == 'journal' %}
<div class="card">
  <form method="get" class="row">
    <div class="field">
      <label for="q">Suche (Betreff, Absender, Datei, Ziel)</label>
      <input id="q" name="q" type="text" value="{{ q }}">
    </div>
    <div class="field">
      <label for="source">Quelle</label>
      <select id="source" name="source">
        <option value="">alle</option>
        {% for name in sources %}
          <option value="{{ name }}" {% if name == selected_source %}selected{% endif %}>{{ name }}</option>
        {% endfor %}
      </select>
    </div>
    <p style="margin:0 0 .45rem"><label><input type="checkbox" name="problems" value="1"
      {% if problems %}checked{% endif %}> nur Probleme</label></p>
    <button type="submit">Filtern</button>
    <a href="{{ url_for('export_journal', q=q or None, source=selected_source or None, problems=1 if problems else None) }}">
      <button class="secondary" type="button">Als CSV herunterladen</button></a>
  </form>
</div>

<div class="card">
  {% if entries %}
  <div class="table-wrap">
  <table class="log">
    <tr><th>Zeit</th><th>Quelle</th><th>Was</th><th>Mail / Datei</th><th>Ziel / Details</th></tr>
    {% for e in entries %}
    <tr>
      <td class="when">{{ e.local_at }}</td>
      <td>{{ e.source }}</td>
      <td>{% if e.failed %}<span class="state-bad">{{ e.action_label }}</span>
          {% elif e.action == 'quarantaene' %}<span class="state-wait">{{ e.action_label }}</span>
          {% else %}{{ e.action_label }}{% endif %}</td>
      <td class="detail">{% if e.subject %}{{ e.subject }}{% endif %}
        {% if e.sender %}<br><span class="hint">{{ e.sender }}</span>{% endif %}
        {% if e.filename %}<br><strong>{{ e.filename }}</strong>{% endif %}</td>
      <td class="detail">{% if e.target %}{{ e.target }}{% endif %}
        {% if e.detail %}<br><span class="hint">{{ e.detail }}</span>{% endif %}</td>
    </tr>
    {% endfor %}
  </table>
  </div>
  {% else %}
  <p class="hint">Keine Eintraege{% if q or selected_source or problems %} fuer diesen Filter{% endif %}.</p>
  {% endif %}
  {{ pager }}
</div>
{% else %}
<div class="card">
  <form method="get" class="row">
    <input type="hidden" name="view" value="log">
    <div class="field">
      <label for="q">Suche</label>
      <input id="q" name="q" type="text" value="{{ q }}">
    </div>
    <div class="field">
      <label for="level">Mindestens</label>
      <select id="level" name="level">
        {% for name in levels %}
          <option value="{{ name }}" {% if name == level %}selected{% endif %}>{{ name }}</option>
        {% endfor %}
      </select>
    </div>
    <button type="submit">Filtern</button>
  </form>
</div>

<div class="card">
  {% if lines %}
  <div class="table-wrap">
  <table class="log">
    <tr><th>Zeit</th><th>Stufe</th><th>Meldung</th></tr>
    {% for line in lines %}
    <tr>
      <td class="when">{{ line.local_at }}</td>
      <td>{% if line.level in ('ERROR', 'CRITICAL') %}<span class="state-bad">{{ line.level }}</span>
          {% elif line.level == 'WARNING' %}<span class="state-wait">{{ line.level }}</span>
          {% else %}{{ line.level }}{% endif %}</td>
      <td class="detail">{{ line.message }}</td>
    </tr>
    {% endfor %}
  </table>
  </div>
  {% else %}
  <p class="hint">Keine Eintraege.</p>
  {% endif %}
  {{ pager }}
</div>
{% endif %}
<p class="hint">Aufbewahrt werden {{ retention_days }} Tage (einstellbar unter
<a href="{{ url_for('settings_page') }}">Einstellungen</a>). Vollstaendige Fehlermeldungen
mit Stacktrace stehen zusaetzlich im Container-Log (<code>docker compose logs</code>).</p>
"""

PAGER = """
{% if pages > 1 %}
<div class="pager">
  {% if page > 1 %}<a href="{{ prev_url }}">&larr; neuer</a>{% endif %}
  <span class="hint">Seite {{ page }} von {{ pages }} &middot; {{ total }} Eintraege</span>
  {% if page < pages %}<a href="{{ next_url }}">aelter &rarr;</a>{% endif %}
</div>
{% elif total %}
<p class="hint" style="margin-bottom:0">{{ total }} Eintraege</p>
{% endif %}
"""

BACKUP_BODY = """
<div class="card">
  <h2 style="margin-top:0">Sicherung herunterladen</h2>
  <p style="margin-top:0">Die komplette Konfiguration in einer Datei: Postfaecher, Archive,
  Zuordnungen, Drucker, Zustelladressen, Abholordner, Einstellungen, Benachrichtigungen,
  Passwort der Oberflaeche und das Protokoll.</p>
  <p><a href="{{ url_for('download_backup') }}"><button type="button">Jetzt sichern und
    herunterladen</button></a></p>
  <p class="hint" style="margin-bottom:0"><strong>Die Datei enthaelt die Passwoerter der
  Postfaecher und NAS-Freigaben im Klartext</strong> - so sicher aufbewahren wie diese.</p>
</div>

<div class="card">
  <h2 style="margin-top:0">Automatische Sicherung aufs NAS</h2>
  <form method="post" action="{{ url_for('backup_settings') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <p style="margin-top:0"><label><input type="checkbox" name="enabled" value="1"
      {% if b.enabled %}checked{% endif %}> Taeglich sichern</label></p>
    <div class="row">
      {% if archives %}
      <div class="field">
        <label for="archive">Archiv</label>
        <select id="archive" name="archive">
          <option value="">Standard-Archiv</option>
          {% for entry in archives %}
            <option value="{{ entry.key }}" {% if b.archive == entry.key %}selected{% endif %}>{{ entry.name }}</option>
          {% endfor %}
        </select>
      </div>
      {% endif %}
      <div class="field">
        <label for="folder">Ordner</label>
        <input id="folder" name="folder" type="text" value="{{ b.folder }}">
      </div>
      <div class="field">
        <label for="keep">Anzahl aufbewahren</label>
        <input id="keep" name="keep" type="number" value="{{ b.keep }}" min="{{ keep_limits[0] }}"
               max="{{ keep_limits[1] }}">
      </div>
    </div>
    <div class="row" style="margin-top:.8rem">
      <button type="submit">Speichern</button>
    </div>
  </form>
  <form method="post" action="{{ url_for('backup_now') }}" style="margin-top:.6rem">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Jetzt aufs NAS sichern</button>
  </form>
  <p class="hint" style="margin-bottom:0">
    {% if last_when %}Letzte automatische Sicherung: {{ last_when }} &middot; {{ last_path }}<br>{% endif %}
    {% if status.ok is sameas false %}<span class="state-bad">{{ status.detail }}</span><br>{% endif %}
    Einmal am Tag wird eine Datei <code>mail2nas-sicherung-DATUM.db.gz</code> in den Ordner
    geschrieben; aeltere ueber die Anzahl hinaus werden geloescht. Der Ordner sollte nur fuer
    Berechtigte lesbar sein. Bei einem Fehler wird stuendlich neu versucht (und, falls
    eingerichtet, per Mail benachrichtigt).</p>
</div>

<div class="card">
  <h2 style="margin-top:0">Wiederherstellen</h2>
  <form method="post" action="{{ url_for('restore_backup') }}" enctype="multipart/form-data">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="backup_file">Sicherungsdatei (.db.gz oder .db)</label>
        <input id="backup_file" name="backup_file" type="file" accept=".gz,.db" required>
      </div>
    </div>
    <p><label><input type="checkbox" name="confirm" value="1" required> Ja, die aktuelle
      Konfiguration komplett durch die Sicherung ersetzen</label></p>
    <button class="danger" type="submit">Wiederherstellen</button>
  </form>
  <p class="hint" style="margin-bottom:0">Ersetzt alles - auch das Passwort der Oberflaeche:
  danach gilt das aus der Sicherung. Der bisherige Stand wird vorher im Container unter
  <code>/data/backups</code> abgelegt (die letzten {{ local_keep }}). Die Postfaecher
  verbinden sich danach innerhalb weniger Sekunden neu; ein Neustart ist nicht noetig.
  {% if local_backups %}<br>Vorhandene Sicherungen vor Wiederherstellungen:
  {% for name in local_backups %}<code>{{ name }}</code>{% if not loop.last %}, {% endif %}{% endfor %}{% endif %}</p>
</div>
"""

NOTIFY_BODY = """
<form method="post">
  <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
  <div class="card">
    <h2 style="margin-top:0">Benachrichtigungen per Mail</h2>
    <p style="margin-top:0"><label><input type="checkbox" name="enabled" value="1"
      {% if n.enabled %}checked{% endif %}> Benachrichtigungen senden</label></p>
    <div class="field">
      <label for="recipients">Empfaenger (mehrere mit Komma trennen)</label>
      <input id="recipients" name="recipients" type="text" style="max-width:100%"
             value="{{ n.recipients }}" placeholder="it@firma.de, chef@firma.de">
    </div>
    <h2>Wann</h2>
    <p style="margin:.2rem 0"><label><input type="checkbox" name="on_connection" value="1"
      {% if n.on_connection %}checked{% endif %}> Postfach, Archiv, Abholordner oder Sicherung
      funktioniert nicht</label></p>
    <div class="field" style="margin:.4rem 0 .4rem 1.6rem">
      <label for="delay_minutes">... seit mindestens (Minuten)</label>
      <input id="delay_minutes" name="delay_minutes" type="number" value="{{ n.delay_minutes }}"
             min="{{ delay_limits[0] }}" max="{{ delay_limits[1] }}">
    </div>
    <p style="margin:.2rem 0 .2rem 1.6rem"><label><input type="checkbox" name="on_recovery"
      value="1" {% if n.on_recovery %}checked{% endif %}> Entwarnung, wenn es wieder geht</label></p>
    <p style="margin:.2rem 0"><label><input type="checkbox" name="on_failures" value="1"
      {% if n.on_failures %}checked{% endif %}> Probleme bei der Verarbeitung (Druck
      fehlgeschlagen, Mail oder Anhang zu gross, Mail nicht verarbeitbar)</label></p>
    <p class="hint" style="margin-bottom:0">Verarbeitungsprobleme werden gesammelt und
    hoechstens alle {{ digest_minutes }} Minuten als eine Mail verschickt.</p>
  </div>

  <div class="card">
    <h2 style="margin-top:0">Postausgangsserver (SMTP)</h2>
    <div class="row">
      <div class="field">
        <label for="smtp_host">Server</label>
        <input id="smtp_host" name="smtp_host" type="text" value="{{ n.smtp_host }}"
               placeholder="smtp.example.com">
      </div>
      <div class="field">
        <label for="smtp_port">Port</label>
        <input id="smtp_port" name="smtp_port" type="text" value="{{ n.smtp_port }}">
      </div>
      <div class="field">
        <label for="smtp_security">Verschluesselung</label>
        <select id="smtp_security" name="smtp_security">
          {% for value, text in security.items() %}
            <option value="{{ value }}" {% if n.smtp_security == value %}selected{% endif %}>{{ text }}</option>
          {% endfor %}
        </select>
      </div>
    </div>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="smtp_user">Benutzer (leer = ohne Anmeldung)</label>
        <input id="smtp_user" name="smtp_user" type="text" value="{{ n.smtp_user }}">
      </div>
      <div class="field">
        <label for="smtp_password">Passwort</label>
        <input id="smtp_password" name="smtp_password" type="password" autocomplete="new-password"
               {% if n.smtp_password %}placeholder="unveraendert lassen: leer"{% endif %}>
      </div>
      <div class="field">
        <label for="sender">Absender (leer = Benutzer)</label>
        <input id="sender" name="sender" type="text" value="{{ n.sender }}"
               placeholder="mail2nas@firma.de">
      </div>
    </div>
  </div>
  <button type="submit">Speichern</button>
  <a href="{{ url_for('config_page') }}"><button class="secondary" type="button">Zurueck</button></a>
</form>

<div class="card" style="margin-top:1rem">
  <h2 style="margin-top:0">Testmail</h2>
  <form method="post" action="{{ url_for('test_notification') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <button class="secondary" type="submit">Testmail an die Empfaenger senden</button>
  </form>
  <p class="hint" style="margin-bottom:0">Verwendet die gespeicherten Einstellungen - vorher
  speichern. {% if last_sent %}Zuletzt gesendet: {{ last_sent }}.{% endif %}
  {% if last_error %}<br><span class="state-bad">Letzter Fehler: {{ last_error }}</span>{% endif %}</p>
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
  abgemeldet. Passwort vergessen? Auf dem Server:
  <code>docker compose exec mail2nas python -m mail2nas.cli reset-password</code></p>
</div>
"""


def _csv_cell(value: str) -> str:
    """Subjects and file names come from strangers' mail: a cell starting
    with "=" would be a formula to Excel. A leading apostrophe keeps it text."""
    return "'" + value if value[:1] in ("=", "+", "-", "@", "\t", "\r") else value


def test_imap(account, timeout: int = 20) -> int:
    """Log in, open the folder, count unseen mail. Raises on any failure."""
    from imapclient import IMAPClient

    client = IMAPClient(account.host, port=account.port, ssl=account.ssl, timeout=timeout)
    try:
        client.login(account.user, account.password)
        client.select_folder(account.folder, readonly=True)
        return len(client.search(["UNSEEN"]))
    finally:
        try:
            client.logout()
        except Exception:  # noqa: BLE001 - the answer is already known
            pass


def create_app(runtime) -> Flask:
    """Build the web UI on top of a Runtime (config, storage, settings, accounts)."""
    config, settings = runtime.config, runtime.settings

    def storage():
        """The default archive, or None - looked up per request, it is editable."""
        return runtime.storage
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
            setup_hint=_setup_hint() if request.endpoint != "overview_page" else "",
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
        return redirect(url_for("overview_page") if logged_in() else url_for("login"))

    @app.route("/login", methods=["GET", "POST"])
    def login():
        if logged_in():
            return redirect(url_for("overview_page"))

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
                return redirect(url_for("overview_page"))

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

    def _setup_hint() -> str:
        """One line on every page while something essential is missing."""
        if runtime.default_archive() is None:
            return "Noch kein Archiv eingerichtet - es wird nichts abgeholt oder abgelegt."
        if runtime.status.archive.ok is False:
            return "Das Standard-Archiv ist nicht bereit: " + runtime.status.archive.detail
        if not runtime.accounts.enabled() and not (runtime.pickups and runtime.pickups.enabled()):
            return "Noch kein aktives Postfach - es wird keine Mail abgeholt."
        return ""

    def _changed() -> None:
        """Tell the supervisor to look at the configuration now, not in 5 s."""
        runtime.changed.set()

    def _printers() -> list:
        """The printers offered in the dropdowns, or none if printing is off."""
        if runtime.printers is None or not runtime.options.printing_enabled:
            return []
        return runtime.printers.all()

    def _print_choice(value: str) -> tuple[bool, str]:
        """Read the "Drucken" dropdown: off, mailbox printer, or a named one."""
        value = (value or "").strip()
        if not value:
            return False, ""
        if value == "account":
            return True, ""
        if value not in {printer.key for printer in _printers()}:
            raise MappingError("Diesen Drucker gibt es nicht.")
        return True, value

    def _rules() -> list[Rule]:
        return runtime.rule_store.load()

    def _save(rules: list[Rule]) -> None:
        runtime.mapping.save(rules)

    def _index(rules: list[Rule]) -> int:
        try:
            index = int(request.form.get("index", ""))
        except ValueError:
            raise MappingError("Diese Zuordnung gibt es nicht mehr.") from None
        if not 0 <= index < len(rules):
            raise MappingError("Diese Zuordnung gibt es nicht mehr.")
        return index

    @app.get("/mapping")
    @login_required
    def mapping_page():
        try:
            rules = _rules()
        except MappingError as exc:
            rules = []
            flash(str(exc), "error")

        folders, storage_ok = [], False
        if storage() is not None:
            try:
                folders = storage().list_folders()
                storage_ok = True
            except Exception as exc:  # noqa: BLE001 - the share may be unreachable right now
                logger.warning("Web UI: could not list folders (%s)", exc)
                flash(f"Ordnerliste konnte nicht geladen werden: {exc}", "error")

        def folder_options(current: str) -> list[str]:
            # A rule may point at a folder that does not exist yet (it is
            # created on the first attachment), so keep it selectable.
            return sorted({*folders, current}) if current else folders

        accounts = runtime.accounts.all()
        printers = _printers()
        return render(
            MAPPING_BODY,
            "Zuordnungen",
            rules=rules,
            folders=folders,
            folder_options=folder_options,
            accounts=accounts,
            account_keys=[account.key for account in accounts] + [ALL_ACCOUNTS],
            printers=printers,
            printer_keys=[printer.key for printer in printers],
            **_archive_context(),
            storage_ok=storage_ok,
            migration_note=settings.get(SETTING_RULES_NOTE) or "",
            fallback_folder=runtime.options.fallback_folder,
            quarantine_folder=runtime.options.quarantine_folder,
        )

    @app.post("/mapping/note/dismiss")
    @login_required
    def dismiss_migration_note():
        require_csrf()
        settings.set(SETTING_RULES_NOTE, "")
        return redirect(url_for("mapping_page"))

    @app.get("/mapping/export")
    @login_required
    def export_rules():
        stamp = datetime.now().strftime("%Y-%m-%d")
        body = (
            f"# mail2nas - Zuordnungen, exportiert am {stamp}\n"
            "# Import: Weboberflaeche -> Zuordnungen -> Sichern und uebertragen\n"
            + dump_rules(_rules())
        )
        return body, 200, {
            "Content-Type": "application/x-yaml; charset=utf-8",
            "Content-Disposition": f'attachment; filename="mail2nas-mapping-{stamp}.yaml"',
        }

    @app.post("/mapping/import")
    @login_required
    def import_rules():
        require_csrf()
        upload = request.files.get("rules_file")
        try:
            if upload is None or not upload.filename:
                raise MappingError("Bitte eine Datei auswaehlen.")
            try:
                text = upload.read().decode("utf-8-sig")
            except UnicodeDecodeError:
                raise MappingError("Die Datei ist kein UTF-8-Text.") from None
            imported = rules_from_yaml(text)
            replace_all = request.form.get("mode") == "replace"
            rules = [] if replace_all else _rules()
            added = skipped = 0
            for rule in imported:
                try:
                    keyword = validate_keyword(rule.keyword, rules)
                except MappingError:
                    skipped += 1
                    continue
                folder = validate_folder(rule.folder)
                known = {a.key for a in runtime.accounts.all()}
                account = rule.account if rule.account in known else ALL_ACCOUNTS
                printers = {p.key for p in (runtime.printers.all() if runtime.printers else [])}
                archives = {a.key for a in _archives()}
                rules.append(
                    Rule.create(
                        keyword,
                        folder,
                        account,
                        rule.print_attachments,
                        rule.printer if rule.printer in printers else "",
                        rule.archive if rule.archive in archives else "",
                    )
                )
                added += 1
            _save(rules)
        except MappingError as exc:
            flash(f"Import abgebrochen: {exc}", "error")
        else:
            logger.info("Web UI: imported %d rule(s), skipped %d", added, skipped)
            flash(
                f"{added} Zuordnung(en) importiert"
                + (f", {skipped} uebersprungen (Stichwort gab es schon)" if skipped else "")
                + ". Postfaecher, Drucker und Archive, die es hier nicht gibt, wurden auf "
                "den Standard gesetzt.",
                "ok",
            )
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/add")
    @login_required
    def add_rule():
        require_csrf()
        new_folder = request.form.get("new_folder", "").strip()
        chosen = new_folder or request.form.get("folder", "")
        try:
            rules = _rules()
            keyword = validate_keyword(request.form.get("keyword", ""), rules)
            folder = validate_folder(chosen)
            account = _account_choice(request.form.get("account", ALL_ACCOUNTS))
            printing, printer = _print_choice(request.form.get("printer", ""))
            archive = _archive_choice(request.form.get("archive", ""))
            if new_folder:
                try:
                    _archive_storage(archive).create_folder(folder)
                except Exception as exc:  # noqa: BLE001 - the rule is still worth saving
                    flash(f"Ordner konnte noch nicht angelegt werden ({exc}) - das passiert "
                          "beim ersten Anhang.", "error")
            rules.append(Rule.create(keyword, folder, account, printing, printer, archive))
            _save(rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001 - surface storage failures in the UI
            logger.exception("Web UI: could not add rule")
            flash(f"Speichern fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: added mapping %r -> %r", keyword, folder)
            flash(f"{keyword} → {folder} gespeichert.", "ok")
        return redirect(url_for("mapping_page"))

    def _account_choice(value: str) -> str:
        value = (value or ALL_ACCOUNTS).strip()
        if value == ALL_ACCOUNTS:
            return ALL_ACCOUNTS
        if value not in {account.key for account in runtime.accounts.all()}:
            raise MappingError("Dieses Postfach gibt es nicht.")
        return value

    @app.post("/mapping/update")
    @login_required
    def update_rule():
        require_csrf()
        try:
            rules = _rules()
            index = _index(rules)
            rule = rules[index]
            folder = validate_folder(request.form.get("folder", ""))
            account = _account_choice(request.form.get("account", rule.account))
            # The print controls are only rendered when a printer exists, so
            # their absence means "leave as is" rather than "switch off".
            if request.form.get("print_fields"):
                printing, printer = _print_choice(request.form.get("printer", ""))
            else:
                printing, printer = rule.print_attachments, rule.printer
            # Same for the archive: the dropdown only exists once there is
            # more than one archive to choose from.
            archive = (
                _archive_choice(request.form.get("archive", ""))
                if request.form.get("archive_fields")
                else rule.archive
            )
            updated = Rule.create(rule.keyword, folder, account, printing, printer, archive)
            rules[index] = set_archive(
                set_printing(set_account(updated, account), printing, printer), archive
            )
            _save(rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not update rule")
            flash(f"Speichern fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: changed mapping %r -> %r", rule.keyword, folder)
            flash(f"{rule.keyword} → {folder} gespeichert.", "ok")
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/delete")
    @login_required
    def delete_rule():
        require_csrf()
        try:
            rules = _rules()
            index = _index(rules)
            removed = rules.pop(index)
            _save(rules)
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not delete rule")
            flash(f"Loeschen fehlgeschlagen: {exc}", "error")
        else:
            logger.info("Web UI: deleted mapping %r", removed.keyword)
            flash(f"{removed.keyword} geloescht. Der Ordner selbst bleibt bestehen.", "ok")
        return redirect(url_for("mapping_page"))

    def _reorder(offset: int):
        require_csrf()
        try:
            rules = _rules()
            index = _index(rules)
            _save(move_rule(rules, index, offset))
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not reorder rules")
            flash(f"Verschieben fehlgeschlagen: {exc}", "error")
        return redirect(url_for("mapping_page"))

    @app.post("/mapping/up")
    @login_required
    def move_rule_up():
        return _reorder(-1)

    @app.post("/mapping/down")
    @login_required
    def move_rule_down():
        return _reorder(1)

    # --- configuration ---------------------------------------------------

    @app.get("/config")
    @login_required
    def config_page():
        return render(
            CONFIG_BODY,
            "Konfiguration",
            accounts=runtime.accounts.all(),
            printers=_printers(),
            address_rules=_address_rules(),
            archives=_archives(),
            pickups=_pickup_rows(),
            pickup_interval=PICKUP_INTERVAL,
            printing_enabled=runtime.options.printing_enabled,
            notify=NotifyStore(settings).load(),
        )

    # --- general settings ----------------------------------------------------

    @app.route("/settings", methods=["GET", "POST"])
    @login_required
    def settings_page():
        options = runtime.options
        if request.method == "POST":
            require_csrf()
            try:
                new = validate_options(request.form, options)
            except OptionsError as exc:
                flash(str(exc), "error")
            else:
                runtime.set_options(new)
                logger.info("Web UI: settings saved")
                if not new.blocked_extensions:
                    flash("Gespeichert. Achtung: ohne gesperrte Dateiendungen wird nichts mehr "
                          "in die Quarantaene verschoben.", "error")
                elif new.dry_run and not options.dry_run:
                    flash("Gespeichert. Der Testmodus ist jetzt an - es wird nichts abgelegt.",
                          "error")
                else:
                    flash("Einstellungen gespeichert.", "ok")
                return redirect(url_for("settings_page"))
        return render(
            SETTINGS_BODY,
            "Einstellungen",
            o=options,
            prefixes=FILENAME_PREFIXES,
            limits=LIMITS,
            blocked=", ".join(sorted(options.blocked_extensions)),
            printable=", ".join(sorted(options.printable_extensions)),
        )

    # --- overview --------------------------------------------------------------

    def _when(timestamp) -> str:
        if not timestamp:
            return ""
        return datetime.fromtimestamp(timestamp).strftime("%d.%m. %H:%M:%S")

    @app.get("/overview")
    @login_required
    def overview_page():
        archives = _archives()
        accounts = runtime.accounts.all()
        rules = runtime.rule_store.count()
        printers = runtime.printers.all() if runtime.printers else []
        steps = [
            SimpleNamespace(
                title="Archiv einrichten",
                hint="wohin abgelegt wird - SMB-Freigabe auf dem NAS, mit Verbindungstest",
                url=url_for("new_archive") if not archives else url_for(
                    "edit_archive", archive_id=archives[0].id),
                done=bool(archives) and runtime.status.archive.ok is not False,
            ),
            SimpleNamespace(
                title="Postfach anlegen",
                hint="woher die Mails kommen (IMAP), mit Anmeldetest",
                url=url_for("new_account"),
                done=bool(accounts),
            ),
            SimpleNamespace(
                title="Zuordnungen anlegen",
                hint="welches Stichwort in welchen Ordner - oder eine alte mapping.yaml importieren",
                url=url_for("mapping_page"),
                done=rules > 0,
            ),
            SimpleNamespace(
                title="Drucker (optional)",
                hint="einmal anlegen, dann je Postfach, Zuordnung oder Adresse auswaehlen",
                url=url_for("new_printer") if not printers else url_for("config_page"),
                done=bool(printers),
            ),
        ]
        board = runtime.status.workers()
        names = {f"account:{a.id}": a.name for a in accounts}
        workers = []
        for key, row in sorted(board.items()):
            if key.startswith("account:") and key not in names:
                continue
            workers.append(SimpleNamespace(
                label=names.get(key, "Abholordner" if key == "pickups" else row.label),
                state=row.state,
                detail=row.detail,
                processed=row.processed,
                last_ok=_when(row.last_ok),
                last_error=row.last_error,
                last_error_at=_when(row.last_error_at),
            ))
        supervisor = getattr(runtime, "supervisor", None)
        problems = list(supervisor.pickup_problems().values()) if supervisor else []
        return render(
            OVERVIEW_BODY,
            "Uebersicht",
            steps=steps,
            steps_open=not all(step.done for step in steps[:3]),
            archive_status=runtime.status.archive,
            workers=workers,
            pickup_problems=problems,
            ready=runtime.status.archive.ok,
            dry_run=runtime.options.dry_run,
            backup_status=runtime.backup_status,
            recent_problems=runtime.journal.count(problems_only=True, since=cutoff(1))
            if runtime.journal is not None else 0,
            initial_password=read_initial_password(config.data_dir) is not None,
            now=_when(time.time()),
            started=_when(runtime.status.started_at),
            counts=SimpleNamespace(
                accounts=len(accounts),
                archives=len(archives),
                rules=rules,
                printers=len(printers),
                addresses=len(runtime.addresses.all()) if runtime.addresses else 0,
                pickups=len(runtime.pickups.all()) if runtime.pickups else 0,
            ),
        )

    def _account_form(account=None):
        """Read the account form, keeping the stored password if left empty."""
        password = request.form.get("password", "")
        if not password and account is not None:
            password = account.password
        try:
            port = int(request.form.get("port", "993").strip())
        except ValueError:
            raise MappingError("Der Port muss eine Zahl sein.") from None
        if not 1 <= port <= 65535:
            raise MappingError("Der Port muss zwischen 1 und 65535 liegen.")
        if not request.form.get("host", "").strip():
            raise MappingError("Bitte einen IMAP-Server angeben.")
        if not request.form.get("user", "").strip():
            raise MappingError("Bitte einen Benutzernamen angeben.")
        if not password:
            raise MappingError("Bitte ein Passwort angeben.")
        if request.form.get("print_fields"):
            printer = request.form.get("printer", "").strip()
            if printer and printer not in {p.key for p in _printers()}:
                raise MappingError("Diesen Drucker gibt es nicht.")
            printing = {
                "print_attachments": bool(request.form.get("print_attachments")),
                "printer": printer,
                "archive_attachments": bool(request.form.get("archive_attachments")),
            }
        elif account is not None:
            printing = {
                "print_attachments": account.print_attachments,
                "printer": account.printer,
                "archive_attachments": account.archive_attachments,
            }
        else:
            printing = {}
        return {
            **printing,
            "name": request.form.get("name", ""),
            "host": request.form.get("host", ""),
            "port": port,
            "ssl": bool(request.form.get("ssl")),
            "user": request.form.get("user", ""),
            "password": password,
            "folder": request.form.get("folder", "INBOX"),
            "mode": request.form.get("mode", "poll"),
            "processed_folder": request.form.get("processed_folder", ""),
            "oversized_folder": request.form.get("oversized_folder", ""),
            "enabled": bool(request.form.get("enabled")),
            **_seen_fields(account),
        }

    def _seen_fields(account) -> dict:
        """The "also read mail" part of the account form."""
        if "seen_since" not in request.form and account is not None:
            # A form without the field (an older page, a script): unchanged.
            return {"include_seen": account.include_seen, "seen_since": account.seen_since}
        include = bool(request.form.get("include_seen"))
        since = request.form.get("seen_since", "").strip()
        if since:
            try:
                since = date.fromisoformat(since).isoformat()
            except ValueError:
                raise MappingError("Bitte ein gueltiges Datum angeben (JJJJ-MM-TT).") from None
            if since > date.today().isoformat():
                raise MappingError("Das Datum fuer gelesene Mails liegt in der Zukunft.")
        return {"include_seen": include, "seen_since": since}

    def _account_context() -> dict:
        return {
            **_printer_context(),
            "today": date.today().isoformat(),
            "retention_days": runtime.options.retention_days,
        }

    @app.route("/config/accounts/new", methods=["GET", "POST"])
    @login_required
    def new_account():
        if request.method == "POST":
            require_csrf()
            try:
                runtime.accounts.add(**_account_form())
            except MappingError as exc:
                flash(str(exc), "error")
            else:
                _changed()
                logger.info("Web UI: added IMAP account %r", request.form.get("host"))
                flash("Postfach angelegt.", "ok")
                return redirect(url_for("config_page"))
        return render(ACCOUNT_BODY, "Postfach", account=None, **_account_context())

    @app.route("/config/accounts/<int:account_id>", methods=["GET", "POST"])
    @login_required
    def edit_account(account_id: int):
        account = runtime.accounts.get(account_id)
        if account is None:
            flash("Dieses Postfach gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                runtime.accounts.update(account_id, **_account_form(account))
            except MappingError as exc:
                flash(str(exc), "error")
            else:
                _changed()
                logger.info("Web UI: updated IMAP account %s", account_id)
                flash("Postfach gespeichert.", "ok")
                return redirect(url_for("config_page"))
            account = runtime.accounts.get(account_id)
        return render(ACCOUNT_BODY, "Postfach", account=account, **_account_context())

    @app.post("/config/accounts/<int:account_id>/delete")
    @login_required
    def delete_account(account_id: int):
        require_csrf()
        runtime.accounts.delete(account_id)
        _changed()
        logger.info("Web UI: deleted IMAP account %s", account_id)
        flash("Postfach geloescht.", "ok")
        return redirect(url_for("config_page"))

    @app.post("/config/accounts/<int:account_id>/test")
    @login_required
    def test_account(account_id: int):
        require_csrf()
        account = runtime.accounts.get(account_id)
        if account is None:
            flash("Dieses Postfach gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))
        try:
            unseen = test_imap(account)
        except Exception as exc:  # noqa: BLE001 - report every failure in the UI
            logger.info("Web UI: IMAP test for %s failed: %s", account.host, exc)
            flash(f"Anmeldung fehlgeschlagen: {exc}", "error")
        else:
            flash(
                f"Angemeldet, Ordner {account.folder} geoeffnet - "
                f"{unseen} ungelesene Mail(s) warten dort.",
                "ok",
            )
        return redirect(url_for("edit_account", account_id=account_id))

    # --- archives -------------------------------------------------------------

    def _archives() -> list:
        """The archives offered in the dropdowns; empty means "just the one"."""
        if runtime.archives is None:
            return []
        return runtime.archives.all()

    def _archive_context() -> dict:
        archives = _archives()
        return {"archives": archives, "archive_keys": [a.key for a in archives]}

    def _archive_choice(value: str, fallback: str = "") -> str:
        """Read an archive dropdown, refusing one that no longer exists."""
        value = (value or "").strip()
        if not value:
            return ""
        if value not in {archive.key for archive in _archives()}:
            raise MappingError("Dieses Archiv gibt es nicht.")
        return value

    def _archive_storage(key: str):
        return runtime.storages.get(key) if runtime.storages else storage()

    def _require_archives():
        if runtime.archives is None:
            abort(404)
        return runtime.archives

    def _archive_form() -> dict:
        backend = request.form.get("backend", "smb").strip().lower()
        return {
            "name": request.form.get("name", ""),
            "backend": backend,
            "host": request.form.get("host", ""),
            "share": request.form.get("share", ""),
            "user": request.form.get("user", ""),
            "password": request.form.get("password", ""),
            "domain": request.form.get("domain", ""),
            "port": request.form.get("port", "445").strip() or "445",
            "root": request.form.get("root", ""),
            "encrypt": bool(request.form.get("encrypt")),
            "path": request.form.get("path", ""),
            "enabled": bool(request.form.get("enabled")),
        }

    @app.route("/config/archives/new", methods=["GET", "POST"])
    @login_required
    def new_archive():
        archives = _require_archives()
        if request.method == "POST":
            require_csrf()
            try:
                archives.add(**_archive_form())
            except ArchiveError as exc:
                flash(str(exc), "error")
            else:
                _changed()
                logger.info("Web UI: added archive %r", request.form.get("name"))
                flash("Archiv angelegt. Mit „Verbindung testen\" pruefen, ob es erreichbar ist.", "ok")
                return redirect(url_for("config_page"))
        return render(ARCHIVE_BODY, "Archiv", archive=None)

    @app.route("/config/archives/<int:archive_id>", methods=["GET", "POST"])
    @login_required
    def edit_archive(archive_id: int):
        archives = _require_archives()
        archive = archives.get(archive_id)
        if archive is None:
            flash("Dieses Archiv gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            fields = _archive_form()
            # An empty password field means "keep the stored one", like the
            # mailbox form - the page never shows the password back.
            if not fields["password"]:
                fields["password"] = archive.password
            try:
                archives.update(archive_id, **fields)
            except ArchiveError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated archive %s", archive_id)
                flash("Archiv gespeichert.", "ok")
                _changed()
                return redirect(url_for("config_page"))
            archive = archives.get(archive_id)
        return render(ARCHIVE_BODY, "Archiv", archive=archive)

    @app.post("/config/archives/<int:archive_id>/test")
    @login_required
    def test_archive(archive_id: int):
        require_csrf()
        archive = _require_archives().get(archive_id)
        if archive is None:
            flash("Dieses Archiv gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))
        try:
            archive.to_storage().check_writable()
        except SystemExit as exc:
            flash(f"Nicht erreichbar: {exc}", "error")
        except Exception as exc:  # noqa: BLE001 - report anything else too
            logger.exception("Web UI: archive test failed")
            flash(f"Nicht erreichbar: {exc}", "error")
        else:
            flash(f"{archive.location()} ist erreichbar und beschreibbar.", "ok")
        return redirect(url_for("edit_archive", archive_id=archive_id))

    @app.post("/config/archives/<int:archive_id>/delete")
    @login_required
    def delete_archive(archive_id: int):
        require_csrf()
        archives = _require_archives()
        if len(archives.all()) <= 1:
            flash("Das letzte Archiv kann nicht geloescht werden.", "error")
            return redirect(url_for("config_page"))
        archives.delete(archive_id)
        logger.info("Web UI: deleted archive %s", archive_id)
        _changed()
        flash(
            "Archiv geloescht. Zuordnungen, Zustelladressen und Abholordner, die darauf "
            "zeigten, nutzen jetzt das Standard-Archiv.",
            "ok",
        )
        return redirect(url_for("config_page"))

    # --- delivery addresses -------------------------------------------------

    def _require_addresses():
        """The address pages only exist when there is a store behind them."""
        if runtime.addresses is None:
            abort(404)
        return runtime.addresses

    def _address_rules() -> list:
        """The rules plus the label of the printer each one names, for the list."""
        if runtime.addresses is None:
            return []
        labels = {printer.key: printer.label() for printer in _printers()}
        archive_names = {archive.key: archive.name for archive in _archives()}
        rules = []
        for rule in runtime.addresses.all():
            rules.append(
                SimpleNamespace(
                    id=rule.id,
                    name=rule.name,
                    recipient=rule.recipient,
                    sender=rule.sender,
                    print_attachments=rule.print_attachments,
                    printer=rule.printer,
                    printer_label=labels.get(rule.printer, ""),
                    archive_attachments=rule.archive_attachments,
                    folder=rule.folder,
                    archive_label=archive_names.get(rule.archive, ""),
                    enabled=rule.enabled,
                )
            )
        return rules

    def _address_form() -> dict:
        return {
            "name": request.form.get("name", ""),
            "recipient": request.form.get("recipient", ""),
            "sender": request.form.get("sender", ""),
            "print_attachments": bool(request.form.get("print_attachments")),
            "printer": request.form.get("printer", ""),
            "archive_attachments": bool(request.form.get("archive_attachments")),
            "folder": request.form.get("folder", ""),
            "archive": request.form.get("archive", ""),
            "enabled": bool(request.form.get("enabled")),
        }

    @app.route("/config/addresses/new", methods=["GET", "POST"])
    @login_required
    def new_address():
        addresses = _require_addresses()
        if request.method == "POST":
            require_csrf()
            try:
                addresses.add(**_address_form())
            except AddressError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: added address rule %r", request.form.get("recipient"))
                flash("Zustelladresse angelegt.", "ok")
                return redirect(url_for("config_page"))
        return render(
            ADDRESS_BODY, "Zustelladresse", entry=None, **_printer_context(), **_archive_context()
        )

    @app.route("/config/addresses/<int:address_id>", methods=["GET", "POST"])
    @login_required
    def edit_address(address_id: int):
        addresses = _require_addresses()
        entry = addresses.get(address_id)
        if entry is None:
            flash("Diese Zustelladresse gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                addresses.update(address_id, **_address_form())
            except AddressError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated address rule %s", address_id)
                flash("Zustelladresse gespeichert.", "ok")
                return redirect(url_for("config_page"))
            entry = addresses.get(address_id)
        return render(
            ADDRESS_BODY, "Zustelladresse", entry=entry, **_printer_context(), **_archive_context()
        )

    @app.post("/config/addresses/<int:address_id>/delete")
    @login_required
    def delete_address(address_id: int):
        require_csrf()
        _require_addresses().delete(address_id)
        logger.info("Web UI: deleted address rule %s", address_id)
        flash("Zustelladresse geloescht.", "ok")
        return redirect(url_for("config_page"))

    # --- pickup folders -------------------------------------------------------

    def _require_pickups():
        if runtime.pickups is None:
            abort(404)
        return runtime.pickups

    def _pickups() -> list:
        return runtime.pickups.all() if runtime.pickups is not None else []

    def _pickup_rows() -> list:
        """The pickup folders with the names of what they point at."""
        if runtime.pickups is None:
            return []
        archive_names = {archive.key: archive.name for archive in _archives()}
        printer_labels = {printer.key: printer.label() for printer in _printers()}
        rows = []
        for pickup in runtime.pickups.all():
            rows.append(
                SimpleNamespace(
                    id=pickup.id,
                    name=pickup.name,
                    folder=pickup.folder,
                    archive_label=archive_names.get(pickup.archive, ""),
                    target_folder=pickup.target_folder,
                    target_archive_label=archive_names.get(pickup.target_archive, ""),
                    print_attachments=pickup.print_attachments,
                    printer_label=printer_labels.get(pickup.printer, ""),
                    enabled=pickup.enabled,
                )
            )
        return rows

    def _pickup_form() -> dict:
        printing, printer = _print_choice(request.form.get("printer", ""))
        return {
            "name": request.form.get("name", ""),
            "archive": request.form.get("archive", ""),
            "folder": request.form.get("folder", ""),
            "target_archive": request.form.get("target_archive", ""),
            "target_folder": request.form.get("target_folder", ""),
            # "Drucker des Postfachs" makes no sense here - a folder has none.
            "print_attachments": bool(printer),
            "printer": printer,
            "enabled": bool(request.form.get("enabled")),
        }

    def _pickup_context() -> dict:
        return {
            **_archive_context(),
            **_printer_context(),
            "min_age": runtime.pickup_min_age,
        }

    @app.route("/config/pickups/new", methods=["GET", "POST"])
    @login_required
    def new_pickup():
        pickups = _require_pickups()
        if request.method == "POST":
            require_csrf()
            try:
                pickups.add(**_pickup_form())
            except PickupError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: added pickup folder %r", request.form.get("folder"))
                flash("Abholordner angelegt.", "ok")
                return redirect(url_for("config_page"))
        return render(PICKUP_BODY, "Abholordner", pickup=None, **_pickup_context())

    @app.route("/config/pickups/<int:pickup_id>", methods=["GET", "POST"])
    @login_required
    def edit_pickup(pickup_id: int):
        pickups = _require_pickups()
        pickup = pickups.get(pickup_id)
        if pickup is None:
            flash("Diesen Abholordner gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                pickups.update(pickup_id, **_pickup_form())
            except PickupError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated pickup folder %s", pickup_id)
                flash("Abholordner gespeichert.", "ok")
                return redirect(url_for("config_page"))
            pickup = pickups.get(pickup_id)
        return render(PICKUP_BODY, "Abholordner", pickup=pickup, **_pickup_context())

    @app.post("/config/pickups/<int:pickup_id>/delete")
    @login_required
    def delete_pickup(pickup_id: int):
        require_csrf()
        _require_pickups().delete(pickup_id)
        logger.info("Web UI: deleted pickup folder %s", pickup_id)
        flash("Abholordner geloescht.", "ok")
        return redirect(url_for("config_page"))

    # --- printers ---------------------------------------------------------

    def _printer_context() -> dict:
        printers = _printers()
        return {"printers": printers, "printer_keys": [printer.key for printer in printers]}

    def _printer_form() -> dict:
        return {
            "name": request.form.get("name", ""),
            "destination": request.form.get("destination", ""),
            "server": request.form.get("server", ""),
            "options": request.form.get("options", ""),
            "copies": request.form.get("copies", "1").strip() or "1",
            "enabled": bool(request.form.get("enabled")),
        }

    def _require_printers():
        """The printer pages only exist when there is a store behind them."""
        if runtime.printers is None:
            abort(404)
        return runtime.printers

    @app.route("/config/printers/new", methods=["GET", "POST"])
    @login_required
    def new_printer():
        printers = _require_printers()
        if request.method == "POST":
            require_csrf()
            try:
                printers.add(**_printer_form())
            except PrinterError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: added printer %r", request.form.get("destination"))
                flash("Drucker angelegt. Ein Testdruck zeigt, ob er erreichbar ist.", "ok")
                return redirect(url_for("config_page"))
        # A "Uebernehmen" link from the discovery page arrives as query
        # parameters; they only prefill the form, nothing is saved yet.
        suggestion = None
        if request.args.get("destination"):
            suggestion = SimpleNamespace(
                name=request.args.get("name", ""),
                destination=request.args.get("destination", ""),
                server=request.args.get("server", ""),
                options="",
                copies=1,
                enabled=True,
                id=None,
            )
        return render(PRINTER_BODY, "Drucker", printer=suggestion)

    @app.route("/config/printers/<int:printer_id>", methods=["GET", "POST"])
    @login_required
    def edit_printer(printer_id: int):
        printers = _require_printers()
        printer = printers.get(printer_id)
        if printer is None:
            flash("Diesen Drucker gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))

        if request.method == "POST":
            require_csrf()
            try:
                printers.update(printer_id, **_printer_form())
            except PrinterError as exc:
                flash(str(exc), "error")
            else:
                logger.info("Web UI: updated printer %s", printer_id)
                flash("Drucker gespeichert.", "ok")
                return redirect(url_for("config_page"))
            printer = printers.get(printer_id)
        return render(PRINTER_BODY, "Drucker", printer=printer)

    @app.post("/config/printers/<int:printer_id>/test")
    @login_required
    def test_printer(printer_id: int):
        require_csrf()
        printers = _require_printers()
        printer = printers.get(printer_id)
        if printer is None or runtime.printing is None:
            flash("Diesen Drucker gibt es nicht mehr.", "error")
            return redirect(url_for("config_page"))
        try:
            runtime.printing.spooler.print_test_page(printer)
        except PrintError as exc:
            flash(f"Testdruck fehlgeschlagen: {exc}", "error")
        except Exception as exc:  # noqa: BLE001 - surface anything else in the UI too
            logger.exception("Web UI: test print failed")
            flash(f"Testdruck fehlgeschlagen: {exc}", "error")
        else:
            flash("Testseite an die Warteschlange uebergeben.", "ok")
        return redirect(url_for("edit_printer", printer_id=printer_id))

    @app.route("/config/printers/discover", methods=["GET", "POST"])
    @login_required
    def discover_printers():
        _require_printers()
        # Default to the server the printers already use: on a NAS box that is
        # usually the one CUPS runs on, and typing it again is pointless.
        configured = next((p.server for p in _printers() if p.server), "")
        server = request.form.get("server", configured).strip()
        found: list = []
        problems: list[str] = []
        searched = request.method == "POST"
        if searched:
            require_csrf()
            try:
                found, problems = discover(server, lpstat_binary=config.lpstat_binary)
            except Exception as exc:  # noqa: BLE001 - the page reports, never 500s
                logger.exception("Web UI: printer discovery failed")
                problems = [f"Suche fehlgeschlagen: {exc}"]
        return render(
            DISCOVERY_BODY,
            "Drucker suchen",
            server=server,
            found=found,
            problems=problems,
            searched=searched,
        )

    @app.post("/config/printers/<int:printer_id>/delete")
    @login_required
    def delete_printer(printer_id: int):
        require_csrf()
        _require_printers().delete(printer_id)
        # An address rule pointing at a deleted queue would keep asking for a
        # printer that no longer exists; blank it so it falls back to the
        # mailbox printer instead of silently printing nothing.
        unpinned = runtime.addresses.clear_printer(str(printer_id)) if runtime.addresses else 0
        if runtime.pickups is not None:
            unpinned += runtime.pickups.clear_printer(str(printer_id))
        logger.info("Web UI: deleted printer %s", printer_id)
        flash(
            "Drucker geloescht. Postfaecher und Zuordnungen, die auf ihn zeigten, "
            "drucken nicht mehr."
            + (
                f" {unpinned} Zustelladresse(n) nutzen jetzt den Drucker des Postfachs."
                if unpinned
                else ""
            ),
            "ok",
        )
        return redirect(url_for("config_page"))

    # --- log -------------------------------------------------------------------

    def _page_number() -> int:
        try:
            return max(1, int(request.args.get("page", "1")))
        except ValueError:
            return 1

    def _pager(page: int, total: int, endpoint: str, **args) -> Markup:
        args = {key: value for key, value in args.items() if value}
        pages = max(1, -(-total // LOG_PAGE_SIZE))
        return Markup(render_template_string(
            PAGER,
            page=page,
            pages=pages,
            total=total,
            prev_url=url_for(endpoint, page=page - 1, **args),
            next_url=url_for(endpoint, page=page + 1, **args),
        ))

    def _journal_filter() -> dict:
        return {
            "search": request.args.get("q", "").strip()[:200],
            "source": request.args.get("source", "").strip()[:200],
            "problems_only": bool(request.args.get("problems")),
        }

    @app.get("/log")
    @login_required
    def log_page():
        view = "log" if request.args.get("view") == "log" else "journal"
        page = _page_number()
        offset = (page - 1) * LOG_PAGE_SIZE
        context = {"view": view, "retention_days": runtime.options.retention_days}
        if view == "journal":
            wanted = _journal_filter()
            journal = runtime.journal
            total = journal.count(**wanted) if journal else 0
            context.update(
                entries=journal.entries(limit=LOG_PAGE_SIZE, offset=offset, **wanted)
                if journal else [],
                sources=journal.sources() if journal else [],
                q=wanted["search"],
                # Not "source": that is render_template_string's own argument.
                selected_source=wanted["source"],
                problems=wanted["problems_only"],
                pager=_pager(page, total, "log_page", q=wanted["search"],
                             source=wanted["source"],
                             problems=1 if wanted["problems_only"] else None),
            )
        else:
            q = request.args.get("q", "").strip()[:200]
            level = request.args.get("level", "INFO")
            if level not in LOG_LEVELS:
                level = "INFO"
            logs = runtime.logs
            total = logs.count(min_level=level, search=q) if logs else 0
            context.update(
                lines=logs.entries(min_level=level, search=q, limit=LOG_PAGE_SIZE,
                                   offset=offset) if logs else [],
                q=q,
                level=level,
                levels=[name for name in LOG_LEVELS if name != "CRITICAL"],
                pager=_pager(page, total, "log_page", view="log", q=q,
                             level=level if level != "INFO" else None),
            )
        return render(LOG_BODY, "Protokoll", **context)

    @app.get("/log/export.csv")
    @login_required
    def export_journal():
        wanted = _journal_filter()
        buffer = io.StringIO()
        # Semicolons and a BOM: what a German Excel opens without asking.
        buffer.write("﻿")
        writer = csv.writer(buffer, delimiter=";")
        writer.writerow(["Zeit", "Quelle", "Aktion", "Betreff", "Absender", "Datei", "Ziel",
                         "Details"])
        if runtime.journal is not None:
            for e in runtime.journal.entries(limit=CSV_LIMIT, **wanted):
                writer.writerow([_csv_cell(value) for value in (
                    e.local_at, e.source, e.action_label, e.subject, e.sender,
                    e.filename, e.target, e.detail)])
        name = f"mail2nas-protokoll-{datetime.now().strftime('%Y-%m-%d')}.csv"
        return (
            buffer.getvalue().encode("utf-8"),
            200,
            {
                "Content-Type": "text/csv; charset=utf-8",
                "Content-Disposition": f'attachment; filename="{name}"',
            },
        )

    # --- backup ------------------------------------------------------------------

    @app.get("/backup")
    @login_required
    def backup_page():
        when, path = backup.last_success(settings)
        folder = os.path.join(config.data_dir, backup.LOCAL_DIR)
        try:
            local = sorted(
                (name for name in os.listdir(folder) if name.endswith(backup.SUFFIX)),
                reverse=True,
            )
        except OSError:
            local = []
        return render(
            BACKUP_BODY,
            "Sicherung",
            b=backup.BackupStore(settings).load(),
            archives=_archives(),
            keep_limits=backup.KEEP_LIMITS,
            status=runtime.backup_status,
            last_when=when,
            last_path=path,
            local_backups=local,
            local_keep=backup.LOCAL_KEEP,
        )

    @app.get("/backup/download")
    @login_required
    def download_backup():
        try:
            data = backup.dump(config.state_db_path)
        except Exception as exc:  # noqa: BLE001 - report in the UI
            logger.exception("Web UI: backup download failed")
            flash(f"Sicherung fehlgeschlagen: {exc}", "error")
            return redirect(url_for("backup_page"))
        logger.info("Web UI: backup downloaded (%d bytes)", len(data))
        return (
            data,
            200,
            {
                "Content-Type": "application/gzip",
                "Content-Disposition": f'attachment; filename="{backup.backup_name()}"',
                "Cache-Control": "no-store",
            },
        )

    @app.post("/backup/settings")
    @login_required
    def backup_settings():
        require_csrf()
        try:
            value = backup.validate(request.form, [a.key for a in _archives()])
        except backup.BackupError as exc:
            flash(str(exc), "error")
        else:
            backup.BackupStore(settings).save(value)
            logger.info("Web UI: backup settings saved (enabled=%s)", value.enabled)
            flash("Gespeichert." + (" Die erste Sicherung folgt in wenigen Sekunden."
                                    if value.enabled else ""), "ok")
            _changed()
        return redirect(url_for("backup_page"))

    @app.post("/backup/now")
    @login_required
    def backup_now():
        require_csrf()
        if runtime.default_archive() is None:
            flash("Erst ein Archiv einrichten - dorthin wird gesichert.", "error")
            return redirect(url_for("backup_page"))
        try:
            path = backup.BackupScheduler(runtime).run()
        except Exception as exc:  # noqa: BLE001 - report in the UI
            flash(f"Sicherung fehlgeschlagen: {exc}", "error")
        else:
            flash(f"Gesichert nach {path}.", "ok")
        return redirect(url_for("backup_page"))

    @app.post("/backup/restore")
    @login_required
    def restore_backup():
        # The only request that may be large; everything else keeps the
        # small global limit.
        request.max_content_length = backup.MAX_UPLOAD
        require_csrf()
        upload = request.files.get("backup_file")
        if not request.form.get("confirm"):
            flash("Bitte bestaetigen, dass die Konfiguration ersetzt werden soll.", "error")
            return redirect(url_for("backup_page"))
        if upload is None or not upload.filename:
            flash("Bitte eine Sicherungsdatei auswaehlen.", "error")
            return redirect(url_for("backup_page"))
        current_hash = settings.get(SETTING_PASSWORD_HASH)
        try:
            saved, counts = backup.restore(config.state_db_path, upload.read(), config.data_dir)
        except backup.BackupError as exc:
            flash(f"Nicht wiederhergestellt: {exc}", "error")
            return redirect(url_for("backup_page"))
        runtime.after_restore()
        restored_hash = settings.get(SETTING_PASSWORD_HASH)
        if not restored_hash and current_hash:
            settings.set(SETTING_PASSWORD_HASH, current_hash)
            restored_hash = current_hash
        # Sessions stay signed with the key this process started with.
        settings.set(SETTING_SECRET_KEY, app.config["SECRET_KEY"])
        initial = read_initial_password(config.data_dir)
        if initial is not None and not (
            restored_hash and check_password_hash(restored_hash, initial)
        ):
            path = initial_password_path(config.data_dir)
            if path:
                try:
                    os.remove(path)
                except OSError:
                    pass
        session["auth_version"] = session_version()
        logger.warning("Web UI: configuration restored from %s", upload.filename)
        flash(
            "Wiederhergestellt: "
            f"{counts.get('imap_accounts', 0)} Postfach/Postfaecher, "
            f"{counts.get('archives', 0)} Archiv(e), {counts.get('mapping_rules', 0)} "
            f"Zuordnung(en), {counts.get('printers', 0)} Drucker. Ab jetzt gilt das Passwort "
            f"aus der Sicherung. Der vorherige Stand liegt in {saved}.",
            "ok",
        )
        return redirect(url_for("overview_page"))

    # --- notifications -------------------------------------------------------------

    @app.route("/config/notifications", methods=["GET", "POST"])
    @login_required
    def notifications_page():
        store = NotifyStore(settings)
        current = store.load()
        shown = current
        if request.method == "POST":
            require_csrf()
            try:
                value = validate_notify(request.form, current)
            except NotifyError as exc:
                flash(str(exc), "error")
                shown = current
            else:
                store.save(value)
                logger.info("Web UI: notification settings saved (enabled=%s)", value.enabled)
                flash("Benachrichtigungen gespeichert.", "ok")
                return redirect(url_for("notifications_page"))
        notifier = getattr(runtime, "notifier", None)
        return render(
            NOTIFY_BODY,
            "Benachrichtigungen",
            n=shown,
            security=SECURITY,
            delay_limits=DELAY_LIMITS,
            digest_minutes=DIGEST_INTERVAL // 60,
            last_sent=_when(notifier.last_sent) if notifier and notifier.last_sent else "",
            last_error=notifier.last_error if notifier else "",
        )

    @app.post("/config/notifications/test")
    @login_required
    def test_notification():
        require_csrf()
        value = NotifyStore(settings).load()
        if not value.smtp_host or not value.recipient_list or not value.from_address:
            flash("Bitte zuerst Server, Absender und Empfaenger speichern.", "error")
            return redirect(url_for("notifications_page"))
        try:
            send_mail(
                value,
                "mail2nas: Testmail",
                "Diese Mail kommt von mail2nas. Die Benachrichtigungen sind richtig "
                "eingerichtet.\n\nSie wurde ueber die Weboberflaeche ausgeloest "
                f"({datetime.now().strftime('%d.%m.%Y %H:%M')}).",
                timeout=20,
            )
        except Exception as exc:  # noqa: BLE001 - report every failure in the UI
            logger.info("Web UI: test notification failed: %s", exc)
            flash(f"Senden fehlgeschlagen: {exc.__class__.__name__}: {exc}", "error")
        else:
            logger.info("Web UI: test notification sent to %s", value.recipients)
            flash(f"Testmail an {value.recipients} gesendet.", "ok")
        return redirect(url_for("notifications_page"))

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
                # Invalidates every session, including this one; this browser
                # is logged back in below - so a stolen cookie stops working.
                set_password(settings, new, config.data_dir)
                session.clear()
                session.permanent = True
                session["auth_version"] = session_version()
                logger.info("Web UI: password changed")
                flash("Passwort geaendert.", "ok")
                return redirect(url_for("overview_page"))

        return render(PASSWORD_BODY, "Passwort", min_length=MIN_PASSWORD_LENGTH)

    return app


def _secret_key(settings) -> str:
    """Persist the cookie signing key, so restarts do not log everyone out."""
    key = settings.get(SETTING_SECRET_KEY)
    if not key:
        key = secrets.token_urlsafe(48)
        settings.set(SETTING_SECRET_KEY, key)
    return key


INITIAL_PASSWORD_FILE = "initial-password.txt"
# No 0/O, 1/l/I: the password is read off a terminal and typed into a browser.
_PASSWORD_ALPHABET = "abcdefghjkmnpqrstuvwxyz23456789"


def generate_password() -> str:
    """A random password that survives being read aloud: 4 x 4 characters."""
    chars = "".join(secrets.choice(_PASSWORD_ALPHABET) for _ in range(16))
    return "-".join(chars[i : i + 4] for i in range(0, 16, 4))


def initial_password_path(data_dir: str | None) -> str | None:
    return os.path.join(data_dir, INITIAL_PASSWORD_FILE) if data_dir else None


def _write_initial_password(data_dir: str | None, password: str) -> None:
    path = initial_password_path(data_dir)
    if not path:
        return
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(password + "\n")
        os.chmod(path, 0o600)
    except OSError as exc:
        logger.warning("Could not write %s (%s) - the password is only in this log", path, exc)


def read_initial_password(data_dir: str | None) -> str | None:
    path = initial_password_path(data_dir)
    if not path:
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read().strip() or None
    except OSError:
        return None


def set_password(settings, new_password: str, data_dir: str | None = None) -> None:
    """Store a new password and log every session out.

    The generated first password is removed from disk at the same time: once
    somebody chose their own, a readable copy of the old one has no purpose.
    """
    settings.set(SETTING_PASSWORD_HASH, generate_password_hash(new_password))
    version = settings.get(SETTING_SESSION_VERSION) or "1"
    settings.set(SETTING_SESSION_VERSION, str(int(version) + 1))
    path = initial_password_path(data_dir)
    if path:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        except OSError as exc:
            logger.warning("Could not remove %s (%s)", path, exc)


def ensure_password(settings, initial_password: str = "", data_dir: str | None = None) -> str | None:
    """Make sure the UI has a password. Returns it if one was generated.

    Order of preference: a stored hash (the user's own choice, or the first
    password from an earlier start), then WEB_PASSWORD from an older `.env`,
    then a random one. The random one is written to `initial-password.txt`
    next to the database (mode 0600) - that is where the installer reads it
    from to show it - and logged once, so a plain `docker compose logs`
    finds it too. Either way it is meant to be changed after the first login.
    """
    if settings.get(SETTING_PASSWORD_HASH):
        return None
    if initial_password and len(initial_password) >= MIN_PASSWORD_LENGTH:
        settings.set(SETTING_PASSWORD_HASH, generate_password_hash(initial_password))
        logger.info("Web UI: initial password taken from WEB_PASSWORD")
        return None
    if initial_password:
        logger.error(
            "WEB_PASSWORD is shorter than %d characters - generating a random one instead",
            MIN_PASSWORD_LENGTH,
        )

    password = generate_password()
    settings.set(SETTING_PASSWORD_HASH, generate_password_hash(password))
    _write_initial_password(data_dir, password)
    logger.warning(
        "Web UI: no password was set, generated one: %s  (also in %s - "
        "please change it after the first login)",
        password,
        initial_password_path(data_dir) or "nowhere else",
    )
    return password


def serve(runtime) -> threading.Thread:
    """Bind the port and serve the UI on a daemon thread.

    Binding happens here, in the caller's thread, so a port clash is a startup
    error rather than a stack trace that scrolls past unnoticed while the
    archiver keeps running without a UI.
    """
    from waitress import create_server

    config = runtime.config
    ensure_password(runtime.settings, config.web_password, config.data_dir)
    app = create_app(runtime)
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
