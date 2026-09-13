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
    load_rules,
    move_rule,
    save_rules,
    set_account,
    set_archive,
    set_printing,
    validate_folder,
    validate_keyword,
)
from .addresses import AddressError
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
  td.keyword { font-weight: 600; overflow-wrap: break-word; min-width: 9rem; }
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
  .row.nowrap { flex-wrap: nowrap; gap: .4rem; }
  td select { max-width: 16rem; min-width: 8rem; }
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
  td.prio { white-space: nowrap; }
  button.arrow { background: transparent; border: 1px solid var(--line); color: var(--fg);
                 padding: .1rem .35rem; line-height: 1.1; }
  button.arrow[disabled] { opacity: .35; cursor: default; }
  code { background: var(--bg); border: 1px solid var(--line); border-radius: 4px;
         padding: 0 .25rem; font-size: .85em; }
  a { color: var(--accent); }
</style>
</head>
<body>
<main>
  <header>
    <h1>mail2nas</h1>
    {% if logged_in %}
    <nav>
      <a href="{{ url_for('mapping_page') }}">Zuordnungen</a> &middot;
      <a href="{{ url_for('config_page') }}">Konfiguration</a> &middot;
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
  <h2 style="margin-top:0">Ablage</h2>
  <dl>
    <dt>Archiv</dt><dd>{{ storage_description }}</dd>
    <dt>Mapping-Datei</dt><dd>{{ mapping_path }}</dd>
    <dt>Ohne Treffer</dt><dd>{{ fallback_folder }}</dd>
    <dt>Gesperrte Dateiendungen</dt><dd>{{ quarantine_folder }}</dd>
  </dl>
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
      <td>{{ account.mode }}</td>
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
  <p class="hint">Drucken ist per <code>PRINTING_ENABLED=false</code> abgeschaltet.</p>
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
  <p class="hint">Das erste aktive Archiv ist das Standard-Archiv: dort liegt die
  Mapping-Datei, dorthin geht alles ohne eigene Angabe. Zuordnungen, Zustelladressen
  und Abholordner koennen jeweils ein anderes waehlen.</p>
  {% else %}
  <p class="hint">Es wird das Archiv aus der .env verwendet: {{ storage_description }}</p>
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
  <h2 style="margin-top:0">Quarantaene und Abholen</h2>
  <form method="post" action="{{ url_for('save_settings') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="field">
      <label for="blocked_extensions">Gesperrte Dateiendungen</label>
      <input id="blocked_extensions" name="blocked_extensions" type="text"
             value="{{ blocked_extensions }}">
    </div>
    <p class="hint">Anhaenge mit einer dieser Endungen landen <strong>immer</strong> im
    Ordner <code>{{ quarantine_folder }}</code> - auch wenn ein Stichwort passt und auch
    wenn sie aus einem Abholordner kommen. So kann „Rechnung.exe" nicht im
    Rechnungsordner landen. Gedruckt wird so etwas nie.
    Komma-, Semikolon- oder Leerzeichen-getrennt, ohne Punkt.
    <strong>Leer heisst: keine Pruefung.</strong></p>
    <div class="row" style="margin-top:.6rem">
      <div class="field">
        <label for="pickup_min_age">Abholordner: Datei gilt als fertig nach (Sekunden)</label>
        <input id="pickup_min_age" name="pickup_min_age" type="text" value="{{ pickup_min_age }}">
      </div>
      <button type="submit">Speichern</button>
    </div>
    <p class="hint" style="margin-bottom:0">Wirkt sofort, ohne Neustart. Die
    <code>.env</code> gibt nur noch den Startwert vor.</p>
  </form>
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
  <h2 style="margin-top:0">Mapping-Datei</h2>
  <form method="post" action="{{ url_for('move_mapping') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token }}">
    <div class="row">
      <div class="field">
        <label for="mapping_path">Pfad relativ zur Archiv-Wurzel</label>
        <input id="mapping_path" name="mapping_path" type="text" value="{{ mapping_path }}" required>
      </div>
      <button type="submit">Verschieben</button>
    </div>
    <p class="hint">Die vorhandene Datei wird an den neuen Ort kopiert und am
    alten geloescht. Archiv: {{ storage_description }}</p>
  </form>
</div>

<div class="card">
  <h2 style="margin-top:0">Feste Einstellungen</h2>
  <p class="hint" style="margin-top:0">Diese kommen aus der .env und brauchen einen
  Neustart des Containers.</p>
  <dl>
    <dt>Archiv</dt><dd>{{ storage_description }} ({{ storage_backend }})</dd>
    <dt>Fallback-Ordner</dt><dd>{{ fallback_folder }}</dd>
    <dt>Quarantaene-Ordner</dt><dd>{{ quarantine_folder }}</dd>
    <dt>Archiv aus der .env</dt><dd>{{ storage_description }} ({{ storage_backend }})</dd>
    <dt>Mailtext durchsuchen</dt><dd>{{ 'ja' if match_body else 'nein' }}</dd>
    <dt>Dateinamen-Praefix</dt><dd>{{ filename_prefix }}</dd>
    <dt>Intervall</dt><dd>{{ poll_interval }} s</dd>
    <dt>Testmodus (DRY_RUN)</dt><dd>{{ 'an' if dry_run else 'aus' }}</dd>
  </dl>
</div>
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
  <p class="hint">Das <strong>erste aktive</strong> Archiv ist das Standard-Archiv: dort
  liegt die Mapping-Datei, und dorthin geht alles, was kein eigenes Archiv nennt.
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


def create_app(runtime) -> Flask:
    """Build the web UI on top of a Runtime (config, storage, settings, accounts)."""
    config, settings = runtime.config, runtime.settings

    def storage():
        """The default archive - looked up per request, because it is editable."""
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

    def _printers() -> list:
        """The printers offered in the dropdowns, or none if printing is off."""
        if runtime.printers is None or not config.printing_enabled:
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
        return load_rules(storage(), runtime.mapping_path)

    def _save(rules: list[Rule]) -> None:
        save_rules(storage(), runtime.mapping_path, rules)

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

        try:
            folders = storage().list_folders()
        except Exception as exc:  # noqa: BLE001 - the share may be unreachable right now
            folders = []
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
            storage_description=storage().description,
            mapping_path=runtime.mapping_path,
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
            rules = _rules()
            keyword = validate_keyword(request.form.get("keyword", ""), rules)
            folder = validate_folder(chosen)
            account = _account_choice(request.form.get("account", ALL_ACCOUNTS))
            printing, printer = _print_choice(request.form.get("printer", ""))
            archive = _archive_choice(request.form.get("archive", ""))
            if new_folder:
                _archive_storage(archive).create_folder(folder)
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
            blocked_extensions=", ".join(sorted(runtime.blocked_extensions)),
            pickup_min_age=runtime.pickup_min_age,
            printing_enabled=config.printing_enabled,
            mapping_path=runtime.mapping_path,
            storage_description=storage().description,
            storage_backend=config.storage_backend,
            fallback_folder=config.fallback_folder,
            quarantine_folder=config.quarantine_folder,
            match_body=config.match_body,
            filename_prefix=config.filename_prefix,
            poll_interval=config.poll_interval,
            dry_run=config.dry_run,
        )

    @app.post("/config/settings")
    @login_required
    def save_settings():
        require_csrf()
        extensions = runtime.set_blocked_extensions(request.form.get("blocked_extensions", ""))
        try:
            age = runtime.set_pickup_min_age(request.form.get("pickup_min_age", "20").strip() or 0)
        except (TypeError, ValueError):
            age = runtime.pickup_min_age
            flash("Die Wartezeit muss eine Zahl sein - sie blieb unveraendert.", "error")
        logger.info(
            "Web UI: quarantine list set to %d extension(s), pickup age %ss",
            len(extensions),
            age,
        )
        if extensions:
            flash("Einstellungen gespeichert.", "ok")
        else:
            flash(
                "Einstellungen gespeichert. Achtung: ohne gesperrte Endungen wird "
                "nichts mehr in die Quarantaene verschoben.",
                "error",
            )
        return redirect(url_for("config_page"))

    @app.post("/config/mapping-path")
    @login_required
    def move_mapping():
        require_csrf()
        try:
            runtime.set_mapping_path(request.form.get("mapping_path", ""))
        except MappingError as exc:
            flash(str(exc), "error")
        except Exception as exc:  # noqa: BLE001
            logger.exception("Web UI: could not move the mapping file")
            flash(f"Verschieben fehlgeschlagen: {exc}", "error")
        else:
            flash(f"Mapping-Datei liegt jetzt unter {runtime.mapping_path}.", "ok")
        return redirect(url_for("config_page"))

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
                logger.info("Web UI: added IMAP account %r", request.form.get("host"))
                flash("Postfach angelegt.", "ok")
                return redirect(url_for("config_page"))
        return render(ACCOUNT_BODY, "Postfach", account=None, **_printer_context())

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
                logger.info("Web UI: updated IMAP account %s", account_id)
                flash("Postfach gespeichert.", "ok")
                return redirect(url_for("config_page"))
            account = runtime.accounts.get(account_id)
        return render(ACCOUNT_BODY, "Postfach", account=account, **_printer_context())

    @app.post("/config/accounts/<int:account_id>/delete")
    @login_required
    def delete_account(account_id: int):
        require_csrf()
        runtime.accounts.delete(account_id)
        logger.info("Web UI: deleted IMAP account %s", account_id)
        flash("Postfach geloescht.", "ok")
        return redirect(url_for("config_page"))

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
                runtime.mapping_path_changed.set()
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
        runtime.mapping_path_changed.set()
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


def serve(runtime) -> threading.Thread:
    """Bind the port and serve the UI on a daemon thread.

    Binding happens here, in the caller's thread, so a port clash is a startup
    error rather than a stack trace that scrolls past unnoticed while the
    archiver keeps running without a UI.
    """
    from waitress import create_server

    config = runtime.config
    ensure_password(runtime.settings, config.web_password)
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
