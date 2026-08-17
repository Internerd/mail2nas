#!/usr/bin/env bash
#
# mail2nas - Offline-Bootstrap
#
# Baut die komplette Projektstruktur an einem Zielpfad neu auf, ganz ohne
# git oder eine Verbindung zu GitHub. Gedacht fuer Proxmox-Hosts/LXCs ohne
# Zugriff auf git: dieses eine Skript per Copy&Paste in eine SSH-Sitzung
# einfuegen (oder per scp/sftp uebertragen) und ausfuehren:
#
#   bash bootstrap.sh [/opt/mail2nas]
#
# Erzeugt darunter: mail2nas/ (Python-Paket), config/, tests/,
# requirements*.txt, Dockerfile, docker-compose.yml, .env.example,
# .dockerignore. Siehe README.md im Original-Repo fuer die Installation
# im Anschluss.
#
# NICHT VON HAND BEARBEITEN - erzeugt von scripts/regenerate-bootstrap.py.

set -euo pipefail

TARGET="${1:-/opt/mail2nas}"
mkdir -p "$TARGET"/mail2nas "$TARGET"/config "$TARGET"/tests
cd "$TARGET"

echo "Schreibe Projektdateien nach $TARGET ..."

# --- requirements.txt ---
cat > requirements.txt <<'MAIL2NAS_EOF'
imapclient>=3.0,<4.0
PyYAML>=6.0,<7.0
smbprotocol>=1.15,<2.0
Flask>=3.0,<4.0
waitress>=3.0,<4.0
MAIL2NAS_EOF

# --- requirements-dev.txt ---
cat > requirements-dev.txt <<'MAIL2NAS_EOF'
-r requirements.txt
pytest>=8.0,<9.0
MAIL2NAS_EOF

# --- .env.example ---
cat > .env.example <<'MAIL2NAS_EOF'
# Copy to .env and fill in real values. Never commit the real .env file.
#
# QUOTING: Wenn ein Wert (typisch: ein Passwort) Sonderzeichen wie
# Leerzeichen, #, $, ", ' oder ` enthaelt, den Wert in doppelte
# Anfuehrungszeichen setzen und darin \ als \\ , " als \" und $ als $$
# schreiben, z. B.:
#     IMAP_PASSWORD="ab\$\$(x)c\"d'e`f #g"
# Sonst interpretiert docker compose Teile des Werts (oder bricht ab).
# Die Installer-Skripte in scripts/ erledigen das automatisch.

# --- IMAP source mailbox -----------------------------------------------
# STARTWERTE. Beim ersten Start wird daraus das erste Postfach angelegt;
# danach werden Postfaecher in der Weboberflaeche gepflegt (auch mehrere) und
# diese Variablen werden ignoriert. Siehe README, Abschnitt Weboberflaeche.
IMAP_HOST=imap.example.com
IMAP_PORT=993
IMAP_SSL=true
IMAP_USER=archiv@example.com
IMAP_PASSWORD=changeme
IMAP_FOLDER=INBOX
# Optional: move processed mails into this IMAP folder instead of just
# marking them \Seen. Leave empty to just mark as read.
IMAP_PROCESSED_FOLDER=Processed
# Optional: oversized messages (see MAX_MESSAGE_SIZE_MB) are marked \Seen and,
# if set, moved here instead of being touched for attachment extraction.
IMAP_OVERSIZED_FOLDER=
# idle = push via IMAP IDLE (recommended if the server supports it)
# poll = check every POLL_INTERVAL_SECONDS
IMAP_MODE=idle
POLL_INTERVAL_SECONDS=300

# --- Target SMB share ----------------------------------------------------
# smb   = mail2nas spricht SMB direkt (empfohlen). Nichts wird gemountet,
#         weder im Container noch auf dem Host - deshalb funktioniert es in
#         einer unprivilegierten LXC, in der der Kernel CIFS-Mounts verweigert,
#         und die Zugangsdaten bleiben in dieser .env statt auf dem Host.
# local  = in ein bereits gemountetes Verzeichnis schreiben (STORAGE_ROOT).
#         Nur noetig, wenn das Share ohnehin schon vom Betriebssystem
#         eingebunden ist. Siehe docker-compose.local.yml.
STORAGE_BACKEND=smb

# Nur bei STORAGE_BACKEND=smb:
SMB_HOST=nas.local
SMB_SHARE=Belege
SMB_USER=mail2nas
SMB_PASSWORD=changeme
# Domain/Workgroup - leer lassen, wenn der Server keine braucht.
SMB_DOMAIN=
SMB_PORT=445
# Optionaler Unterordner innerhalb der Freigabe, unterhalb dessen alles
# abgelegt wird. Leer = Wurzel der Freigabe.
SMB_ROOT=
# SMB3-Verschluesselung erzwingen. Auf false setzen, wenn der Server sie
# ablehnt (aeltere NAS-Firmware, SMB 2.x).
SMB_ENCRYPT=true

# Nur bei STORAGE_BACKEND=local: Pfad des bereits gemounteten Shares im
# Container. NAS_PATH sagt docker-compose.local.yml, welches Verzeichnis des
# Docker-Hosts dorthin gebunden wird.
STORAGE_ROOT=/mnt/nas
NAS_PATH=/mnt/nas

# --- Mapping & filing behaviour -------------------------------------------
# Pfad zur Mapping-Datei, relativ zur Wurzel des Archivs (Freigabe bzw.
# SMB_ROOT, oder STORAGE_ROOT beim local-Backend). Ebenfalls nur ein
# Startwert: in der Weboberflaeche laesst sich die Datei spaeter verschieben.
# See config/mapping.example.yaml - copy it onto the share as mapping.yaml.
# It is reloaded on every processing cycle, so edits apply without a restart.
MAPPING_PATH=mapping.yaml
# Unterordner, der genutzt wird, wenn kein Stichwort aus mapping.yaml passt.
FALLBACK_FOLDER=unsorted
# Also search the mail body for keywords, not just the subject.
MATCH_BODY=false
# How saved attachment filenames are prefixed: none | date | sender | date_sender
FILENAME_PREFIX=date_sender

# --- Angriffsflaeche eindaemmen (Mail/Anhaenge sind nicht vertrauenswuerdig) --
# Einzelne Anhaenge groesser als dieses Limit werden uebersprungen (geloggt),
# der Rest der Mail wird trotzdem normal verarbeitet.
MAX_ATTACHMENT_SIZE_MB=25
# Ist die GESAMTE Mail groesser als dieses Limit, wird sie nicht mal geladen
# (Schutz vor Memory-/Disk-Exhaustion durch riesige Mails) - nur \Seen markiert
# und optional nach IMAP_OVERSIZED_FOLDER verschoben, zur manuellen Pruefung.
MAX_MESSAGE_SIZE_MB=50
# Mehr Anhaenge als dieses Limit werden nicht mehr verarbeitet (Schutz vor
# Mails mit tausenden Mini-Anhaengen).
MAX_ATTACHMENTS_PER_MESSAGE=20
# Anhaenge mit einer dieser Dateiendungen werden IMMER nach QUARANTINE_FOLDER
# verschoben, auch wenn der Dateiname sonst auf ein Mapping-Stichwort passt
# (verhindert z. B. "Rechnung.exe" im Rechnungsordner). Komma-getrennt, ohne
# Punkt. Leer lassen, um die Pruefung zu deaktivieren.
BLOCKED_EXTENSIONS=exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk
QUARANTINE_FOLDER=quarantaene

# --- Drucken ----------------------------------------------------------------
# Anhaenge koennen zusaetzlich ausgedruckt werden. WAS gedruckt wird, wird in
# der Weboberflaeche festgelegt:
#   * je Postfach: "alle Anhaenge drucken" (optional ohne Ablage im Archiv)
#   * je Zuordnung: nur was die Regel trifft, z. B. nur Rechnungen
# Drucker werden dort einmal angelegt und danach ueberall per Auswahlfeld
# verwendet. Gedruckt wird ueber CUPS (`lp`); im Container steckt nur der
# Client, kein Druckerdienst.
#
# Notausschalter: false schaltet jedes Drucken ab, egal was konfiguriert ist.
PRINTING_ENABLED=true
# Pfad zum lp-Binary, falls es nicht im PATH liegt.
LP_BINARY=lp
# Nach so vielen Sekunden gilt ein Druckauftrag als gescheitert (der Anhang
# ist zu dem Zeitpunkt bereits abgelegt).
PRINT_TIMEOUT_SECONDS=120
# Nur diese Dateiendungen werden an den Drucker gegeben. Alles andere kaeme
# als Zeichensalat heraus. Office-Formate fehlen bewusst: dafuer muesste im
# Container ein Konverter installiert sein.
PRINTABLE_EXTENSIONS=pdf,ps,txt,text,log,csv,png,jpg,jpeg,gif,bmp,tif,tiff
# Optional: EIN Drucker, der beim ersten Start automatisch angelegt wird -
# fuer Installationen, die alles ueber die .env konfigurieren. Danach ist die
# Weboberflaeche die Quelle der Wahrheit. Leer lassen = kein Drucker.
# PRINTER_DESTINATION ist der Name der Warteschlange in CUPS (`lpstat -p`).
PRINTER_DESTINATION=
PRINTER_NAME=
# Leer = lokaler cupsd, sonst z. B. cups.lan:631
PRINTER_SERVER=
# Optionen wie fuer `lp -o`, jeweils ohne -o, durch Leerzeichen getrennt.
PRINTER_OPTIONS=
PRINTER_COPIES=1

# --- Weboberflaeche fuer das Mapping ---------------------------------------
# Kleine Oberflaeche zum Zuordnen von Stichwoertern zu Ordnern, damit die
# mapping.yaml nicht von Hand bearbeitet werden muss. Sie schreibt genau diese
# Datei weiter - sie bleibt also im Notfall auch von Hand editierbar.
WEB_ENABLED=true
WEB_HOST=0.0.0.0
WEB_PORT=8080
# STARTPASSWORT. Wird beim ersten Start gehasht in der State-Datenbank
# abgelegt; danach kann es in der Oberflaeche geaendert werden und dieser
# Wert wird ignoriert. Mindestens 8 Zeichen.
WEB_PASSWORD=changeme-bitte-aendern
# Auf true setzen, wenn die Oberflaeche hinter einem HTTPS-Reverse-Proxy
# laeuft: das Session-Cookie wird dann nur noch ueber TLS gesendet.
WEB_COOKIE_SECURE=false

# --- Misc ------------------------------------------------------------------
STATE_DB_PATH=/data/state.db
LOG_LEVEL=INFO
# Set to true to log what would happen without writing files or touching IMAP flags.
DRY_RUN=false
MAIL2NAS_EOF

# --- .dockerignore ---
cat > .dockerignore <<'MAIL2NAS_EOF'
.git
# .env and the credential-bearing backups update.sh writes next to it must
# never enter the build context.
.env
.env.*
!.env.example
__pycache__
*.pyc
.venv
venv
.pytest_cache
tests
README.md
MAIL2NAS_EOF

# --- Dockerfile ---
cat > Dockerfile <<'MAIL2NAS_EOF'
FROM python:3.12-slim

# cups-client provides `lp`, which is how attachments are printed. It is a
# client only - no printing daemon runs in this container; it talks to the
# CUPS server named per printer (or to the host's, via CUPS_SERVER).
RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
    cups-client \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY mail2nas ./mail2nas

RUN useradd --create-home --uid 1000 mail2nas \
    && mkdir -p /mnt/nas /data \
    && chown -R mail2nas:mail2nas /mnt/nas /data
USER mail2nas

ENV PYTHONUNBUFFERED=1
# Only listened on when WEB_ENABLED=true (mapping web UI).
EXPOSE 8080
ENTRYPOINT ["python", "-m", "mail2nas.main"]
MAIL2NAS_EOF

# --- docker-compose.yml ---
cat > docker-compose.yml <<'MAIL2NAS_EOF'
services:
  mail2nas:
    build: .
    image: mail2nas:latest
    container_name: mail2nas
    restart: unless-stopped
    env_file:
      - .env
    environment:
      STATE_DB_PATH: /data/state.db
    ports:
      # Web UI for the keyword -> folder mapping. Host and container port are
      # kept identical so WEB_PORT alone decides where it answers. Nothing
      # listens here unless WEB_ENABLED=true - drop these two lines if you do
      # not want the port published at all.
      - "${WEB_PORT:-8080}:${WEB_PORT:-8080}"
    volumes:
      # Only local state (processed-message tracking) - the archive itself is
      # reached over SMB by the application, so there is nothing to mount here.
      # For STORAGE_BACKEND=local, add docker-compose.local.yml:
      #   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
      - state:/data

volumes:
  # Local state, no need for this to live on the share.
  state:
MAIL2NAS_EOF

# --- docker-compose.local.yml ---
cat > docker-compose.local.yml <<'MAIL2NAS_EOF'
# Override for STORAGE_BACKEND=local: bind an already-mounted share into the
# container. Use it only if the share is mounted by the OS anyway (host fstab,
# or a Proxmox bind mount into the LXC) - with the default SMB backend no
# mount, and therefore no override, is needed.
#
#   docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
#
# Note this is a plain bind mount of an already-mounted directory, never
# Docker's cifs volume driver: that driver issues the mount() syscall itself,
# which the kernel refuses from inside an unprivileged LXC.
services:
  mail2nas:
    environment:
      STORAGE_BACKEND: local
      STORAGE_ROOT: /mnt/nas
    volumes:
      - ${NAS_PATH:-/mnt/nas}:/mnt/nas
MAIL2NAS_EOF

# --- config/mapping.example.yaml ---
cat > config/mapping.example.yaml <<'MAIL2NAS_EOF'
# Kopiere diese Datei als "mapping.yaml" auf die Wurzel des SMB-Shares
# (bzw. an den Pfad, der in MAPPING_PATH konfiguriert ist).
#
# Der Container laedt die Datei bei jedem Verarbeitungszyklus neu ein -
# Aenderungen wirken also ohne Neustart/Redeploy.
#
# Schluessel = Stichwort, das GEPRUEFT WIRD GEGEN:
#              1. den Dateinamen jedes einzelnen Anhangs (zuerst)
#              2. den Betreff (und optional den Mailtext, siehe MATCH_BODY)
#                 als Fallback, falls der Dateiname selbst nichts hergibt
#              Gross-/Kleinschreibung ist egal.
# Wert       = Zielordner relativ zur Wurzel des SMB-Shares.
#
# Weil zuerst der Dateiname jedes Anhangs geprueft wird, koennen mehrere
# unterschiedlich benannte Anhaenge derselben Mail auch in unterschiedliche
# Ordner einsortiert werden (z. B. eine Mail mit "Rechnung_1.pdf" UND
# "Lieferschein_1.pdf" im Anhang -> beide landen jeweils im richtigen Ordner,
# nicht beide im selben).
#
# Laengere Schluessel werden vor kuerzeren geprueft, damit z. B.
# "Rechnungskorrektur" nicht bereits durch "RE" gematcht wird.

# Sobald die Weboberflaeche einmal speichert, wird die Datei ins ausfuehrliche
# Format ueberfuehrt. Dort ist die Reihenfolge die Prioritaet (die erste
# passende Regel gewinnt), und dort stehen auch die Postfach- und
# Druckeinstellungen je Regel:
#
#   version: 2
#   rules:
#     - keyword: Rechnungskorrektur   # steht VOR "RE", sonst greift "RE" zuerst
#       folder: korrekturen
#     - keyword: "Rechnung*"
#       folder: rechnungen
#       account: "2"                  # nur fuer dieses Postfach (id aus der UI)
#       print: true                   # zusaetzlich ausdrucken, nach der Ablage
#       printer: "1"                  # id eines in der UI angelegten Druckers;
#                                     # weglassen = Drucker des Postfachs
#
# print/printer fehlen = es wird nichts gedruckt. Anhaenge mit gesperrter
# Dateiendung landen immer in der Quarantaene und werden nie gedruckt.

RE: rechnungen
Rechnung: rechnungen
Invoice: rechnungen
LS: lieferscheine
Lieferschein: lieferscheine
Lieferung: lieferscheine
AB: auftragsbestaetigungen
Auftragsbestaetigung: auftragsbestaetigungen
Mahnung: mahnungen
Gutschrift: gutschriften
MAIL2NAS_EOF

# --- mail2nas/config.py ---
cat > mail2nas/config.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
from dataclasses import dataclass

from .filenames import safe_relative_parts

# Executable/script types that are quarantined instead of filed normally,
# even if their filename happens to match a mapping keyword. This is a
# defense-in-depth measure against mail attachments being used to smuggle
# malware onto the archive share - it does not make opening the quarantined
# file safe, it just keeps it out of the regular business-document folders.
DEFAULT_BLOCKED_EXTENSIONS = (
    "exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,"
    "jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk"
)

# Formats CUPS prints without help. Office documents are deliberately absent:
# without a converter installed they come out as pages of raw markup, and
# installing one is a decision for whoever runs the container.
DEFAULT_PRINTABLE_EXTENSIONS = "pdf,ps,txt,text,log,csv,png,jpg,jpeg,gif,bmp,tif,tiff"


def _bool(name: str, default: bool) -> bool:
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


def _extension_set(name: str, default: str) -> frozenset[str]:
    raw = os.environ.get(name, default)
    return frozenset(
        ext.strip().lower().lstrip(".") for ext in raw.split(",") if ext.strip()
    )


def _int(name: str, default: str, minimum: int = 1, maximum: int | None = None) -> int:
    """Read an integer setting, failing with a usable message instead of a traceback."""
    raw = os.environ.get(name, default).strip()
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"{name} must be a whole number, got {raw!r}") from None
    if value < minimum or (maximum is not None and value > maximum):
        allowed = f"{minimum}..{maximum}" if maximum is not None else f">= {minimum}"
        raise SystemExit(f"{name} must be {allowed}, got {value}")
    return value


def _choice(name: str, default: str, allowed: tuple[str, ...]) -> str:
    value = os.environ.get(name, default).strip().lower()
    if value not in allowed:
        raise SystemExit(f"{name} must be one of {', '.join(allowed)}, got {value!r}")
    return value


def _relative(name: str, default: str, allow_empty: bool = False) -> str:
    """Read a setting that must stay inside the archive root."""
    value = os.environ.get(name, default).strip()
    if allow_empty and value in ("", "."):
        return ""
    try:
        safe_relative_parts(value)
    except ValueError as exc:
        raise SystemExit(f"{name} must be a path relative to the archive root: {exc}") from None
    return value


def _required(name: str, because: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"{name} is required {because}")
    return value


@dataclass(frozen=True)
class Config:
    imap_host: str
    imap_port: int
    imap_user: str
    imap_password: str
    imap_ssl: bool
    imap_folder: str
    imap_processed_folder: str | None
    imap_oversized_folder: str | None
    imap_mode: str  # "idle" or "poll"
    poll_interval: int

    # "smb" talks to the NAS directly (nothing mounted anywhere), "local"
    # archives into an already-mounted directory at storage_root.
    storage_backend: str
    storage_root: str
    smb_host: str
    smb_share: str
    smb_user: str
    smb_password: str
    smb_domain: str
    smb_port: int
    smb_root: str
    smb_encrypt: bool

    mapping_path: str
    fallback_folder: str
    match_body: bool
    filename_prefix: str  # "none" | "date" | "sender" | "date_sender"

    # Attack-surface limits for untrusted mail/attachment content.
    max_attachment_size_mb: int
    max_message_size_mb: int
    max_attachments_per_message: int
    blocked_extensions: frozenset[str]
    quarantine_folder: str

    state_db_path: str
    dry_run: bool

    # Printing. Which attachments get printed, and on which printer, is
    # configured per mailbox and per mapping rule in the UI - these are the
    # infrastructure bits behind it plus the optional first printer, so an
    # install that is driven purely from the .env can set one up too.
    printing_enabled: bool
    lp_binary: str
    print_timeout: int
    printable_extensions: frozenset[str]
    printer_name: str
    printer_destination: str
    printer_server: str
    printer_options: str
    printer_copies: int

    # Optional web UI for editing the keyword -> folder mapping.
    web_enabled: bool
    web_host: str
    web_port: int
    web_password: str  # initial password only; the stored hash wins once set
    web_cookie_secure: bool

    @classmethod
    def from_env(cls) -> "Config":
        # Defaults to "local" so an existing install whose .env predates this
        # setting keeps working against its mounted share after an update;
        # every install path writes the value explicitly.
        backend = _choice("STORAGE_BACKEND", "local", ("smb", "local"))
        smb = backend == "smb"
        because = "when STORAGE_BACKEND=smb"
        try:
            return cls(
                imap_host=os.environ["IMAP_HOST"],
                imap_port=_int("IMAP_PORT", "993", minimum=1, maximum=65535),
                imap_user=os.environ["IMAP_USER"],
                imap_password=os.environ["IMAP_PASSWORD"],
                imap_ssl=_bool("IMAP_SSL", True),
                imap_folder=os.environ.get("IMAP_FOLDER", "INBOX"),
                imap_processed_folder=os.environ.get("IMAP_PROCESSED_FOLDER") or None,
                imap_oversized_folder=os.environ.get("IMAP_OVERSIZED_FOLDER") or None,
                imap_mode=_choice("IMAP_MODE", "poll", ("idle", "poll")),
                poll_interval=_int("POLL_INTERVAL_SECONDS", "300", minimum=1),
                storage_backend=backend,
                storage_root=os.environ.get("STORAGE_ROOT", "/mnt/nas"),
                smb_host=_required("SMB_HOST", because) if smb else "",
                smb_share=_required("SMB_SHARE", because) if smb else "",
                smb_user=_required("SMB_USER", because) if smb else "",
                smb_password=_required("SMB_PASSWORD", because) if smb else "",
                smb_domain=os.environ.get("SMB_DOMAIN", "").strip(),
                smb_port=_int("SMB_PORT", "445", minimum=1, maximum=65535),
                smb_root=_relative("SMB_ROOT", "", allow_empty=True),
                smb_encrypt=_bool("SMB_ENCRYPT", True),
                mapping_path=_relative("MAPPING_PATH", "mapping.yaml"),
                fallback_folder=os.environ.get("FALLBACK_FOLDER", "unsorted"),
                match_body=_bool("MATCH_BODY", False),
                filename_prefix=_choice(
                    "FILENAME_PREFIX", "date_sender", ("none", "date", "sender", "date_sender")
                ),
                max_attachment_size_mb=_int("MAX_ATTACHMENT_SIZE_MB", "25"),
                max_message_size_mb=_int("MAX_MESSAGE_SIZE_MB", "50"),
                max_attachments_per_message=_int("MAX_ATTACHMENTS_PER_MESSAGE", "20"),
                blocked_extensions=_extension_set("BLOCKED_EXTENSIONS", DEFAULT_BLOCKED_EXTENSIONS),
                quarantine_folder=os.environ.get("QUARANTINE_FOLDER", "quarantaene"),
                state_db_path=os.environ.get("STATE_DB_PATH", "/data/state.db"),
                dry_run=_bool("DRY_RUN", False),
                printing_enabled=_bool("PRINTING_ENABLED", True),
                lp_binary=os.environ.get("LP_BINARY", "lp").strip() or "lp",
                print_timeout=_int("PRINT_TIMEOUT_SECONDS", "120", minimum=1),
                printable_extensions=_extension_set(
                    "PRINTABLE_EXTENSIONS", DEFAULT_PRINTABLE_EXTENSIONS
                ),
                printer_name=os.environ.get("PRINTER_NAME", "").strip(),
                printer_destination=os.environ.get("PRINTER_DESTINATION", "").strip(),
                printer_server=os.environ.get("PRINTER_SERVER", "").strip(),
                printer_options=os.environ.get("PRINTER_OPTIONS", "").strip(),
                printer_copies=_int("PRINTER_COPIES", "1", minimum=1, maximum=20),
                web_enabled=_bool("WEB_ENABLED", False),
                web_host=os.environ.get("WEB_HOST", "0.0.0.0").strip(),
                web_port=_int("WEB_PORT", "8080", minimum=1, maximum=65535),
                web_password=os.environ.get("WEB_PASSWORD", ""),
                web_cookie_secure=_bool("WEB_COOKIE_SECURE", False),
            )
        except KeyError as exc:
            raise SystemExit(f"Missing required environment variable: {exc.args[0]}") from exc
MAIL2NAS_EOF

# --- mail2nas/accounts.py ---
cat > mail2nas/accounts.py <<'MAIL2NAS_EOF'
"""IMAP accounts, stored locally so the web UI can edit them.

Until now there was exactly one mailbox and it came from the environment.
Editing it in the UI - and having more than one - means the configuration has
to live somewhere writable, so it goes into the same SQLite file as the rest
of the local state.

The environment still seeds the first account on a fresh install, so an
existing `.env` keeps working and nothing has to be re-entered. After that the
database wins: changes made in the UI survive restarts and updates, and the
IMAP_* variables are ignored.

Note this means the state database now holds IMAP passwords in clear text.
It needs the same protection as the `.env` file - see the README.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

SETTING_ACCOUNTS_SEEDED = "imap_accounts_seeded"


@dataclass(frozen=True)
class Account:
    """One mailbox to watch."""

    id: int
    name: str
    host: str
    port: int
    ssl: bool
    user: str
    password: str
    folder: str
    mode: str  # "idle" or "poll"
    processed_folder: str
    oversized_folder: str
    enabled: bool
    # Print every attachment from this mailbox, regardless of the rules.
    print_attachments: bool = False
    # Printer for this mailbox, as a string key ("" = none configured). A rule
    # that names its own printer overrides it.
    printer: str = ""
    # Off means "print only": attachments are not written to the share.
    archive_attachments: bool = True

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by a mapping rule."""
        return str(self.id)

    def fingerprint(self) -> tuple:
        """Everything a worker thread needs; a change means restart it."""
        return (
            self.host,
            self.port,
            self.ssl,
            self.user,
            self.password,
            self.folder,
            self.mode,
            self.processed_folder,
            self.oversized_folder,
            self.enabled,
            self.print_attachments,
            self.printer,
            self.archive_attachments,
        )


class AccountStore:
    """CRUD for the configured mailboxes.

    Opens a short-lived connection per call: the web UI answers requests on a
    thread pool and the account workers read from their own threads, and one
    sqlite3 connection must not be shared across threads.
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS imap_accounts ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "host TEXT NOT NULL, "
                "port INTEGER NOT NULL DEFAULT 993, "
                "ssl INTEGER NOT NULL DEFAULT 1, "
                "user TEXT NOT NULL, "
                "password TEXT NOT NULL, "
                "folder TEXT NOT NULL DEFAULT 'INBOX', "
                "mode TEXT NOT NULL DEFAULT 'poll', "
                "processed_folder TEXT NOT NULL DEFAULT '', "
                "oversized_folder TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )
            _add_missing_columns(conn)

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_account(row) -> Account:
        return Account(
            id=row[0],
            name=row[1],
            host=row[2],
            port=row[3],
            ssl=bool(row[4]),
            user=row[5],
            password=row[6],
            folder=row[7],
            mode=row[8],
            processed_folder=row[9],
            oversized_folder=row[10],
            enabled=bool(row[11]),
            print_attachments=bool(row[12]),
            printer=row[13] or "",
            archive_attachments=bool(row[14]),
        )

    _COLUMNS = (
        "id, name, host, port, ssl, user, password, folder, mode, "
        "processed_folder, oversized_folder, enabled, "
        "print_attachments, printer, archive_attachments"
    )

    def all(self) -> list[Account]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM imap_accounts ORDER BY id").fetchall()
        return [self._row_to_account(row) for row in rows]

    def enabled(self) -> list[Account]:
        return [account for account in self.all() if account.enabled]

    def get(self, account_id: int) -> Account | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM imap_accounts WHERE id = ?", (account_id,)
            ).fetchone()
        return self._row_to_account(row) if row else None

    def add(self, **fields) -> int:
        values = _defaults(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO imap_accounts (name, host, port, ssl, user, password, folder, "
                "mode, processed_folder, oversized_folder, enabled, print_attachments, "
                "printer, archive_attachments) "
                "VALUES (:name, :host, :port, :ssl, :user, :password, :folder, :mode, "
                ":processed_folder, :oversized_folder, :enabled, :print_attachments, "
                ":printer, :archive_attachments)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, account_id: int, **fields) -> None:
        current = self.get(account_id)
        if current is None:
            raise KeyError(account_id)
        values = _defaults(
            {
                "name": current.name,
                "host": current.host,
                "port": current.port,
                "ssl": current.ssl,
                "user": current.user,
                "password": current.password,
                "folder": current.folder,
                "mode": current.mode,
                "processed_folder": current.processed_folder,
                "oversized_folder": current.oversized_folder,
                "enabled": current.enabled,
                "print_attachments": current.print_attachments,
                "printer": current.printer,
                "archive_attachments": current.archive_attachments,
                **fields,
            }
        )
        values["id"] = account_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE imap_accounts SET name = :name, host = :host, port = :port, ssl = :ssl, "
                "user = :user, password = :password, folder = :folder, mode = :mode, "
                "processed_folder = :processed_folder, oversized_folder = :oversized_folder, "
                "enabled = :enabled, print_attachments = :print_attachments, "
                "printer = :printer, archive_attachments = :archive_attachments WHERE id = :id",
                values,
            )

    def delete(self, account_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM imap_accounts WHERE id = ?", (account_id,))


def _add_missing_columns(conn: sqlite3.Connection) -> None:
    """Bring an existing database up to date.

    Printing was added after the table existed, and an update must not require
    re-entering every mailbox - so the columns are added in place, with
    defaults that keep an already-configured install behaving exactly as
    before (nothing printed, everything archived).
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(imap_accounts)")}
    for column, definition in (
        ("print_attachments", "INTEGER NOT NULL DEFAULT 0"),
        ("printer", "TEXT NOT NULL DEFAULT ''"),
        ("archive_attachments", "INTEGER NOT NULL DEFAULT 1"),
    ):
        if column not in existing:
            conn.execute(f"ALTER TABLE imap_accounts ADD COLUMN {column} {definition}")
            logger.info("Added the %s column to the account table", column)


def _defaults(fields: dict) -> dict:
    return {
        "name": str(fields.get("name") or "").strip() or "Postfach",
        "host": str(fields.get("host") or "").strip(),
        "port": int(fields.get("port") or 993),
        "ssl": 1 if fields.get("ssl", True) else 0,
        "user": str(fields.get("user") or "").strip(),
        "password": str(fields.get("password") or ""),
        "folder": str(fields.get("folder") or "INBOX").strip() or "INBOX",
        "mode": "idle" if str(fields.get("mode") or "poll").lower() == "idle" else "poll",
        "processed_folder": str(fields.get("processed_folder") or "").strip(),
        "oversized_folder": str(fields.get("oversized_folder") or "").strip(),
        "enabled": 1 if fields.get("enabled", True) else 0,
        "print_attachments": 1 if fields.get("print_attachments", False) else 0,
        "printer": str(fields.get("printer") or "").strip(),
        "archive_attachments": 1 if fields.get("archive_attachments", True) else 0,
    }


def seed_from_config(store: AccountStore, settings, config) -> None:
    """Create the first account from the environment, once.

    Guarded by a flag rather than by "is the table empty", so deleting the
    last account in the UI does not resurrect it from the .env on the next
    restart.
    """
    if settings.get(SETTING_ACCOUNTS_SEEDED):
        return
    if store.all():
        settings.set(SETTING_ACCOUNTS_SEEDED, "1")
        return

    store.add(
        name=config.imap_user or "Postfach",
        host=config.imap_host,
        port=config.imap_port,
        ssl=config.imap_ssl,
        user=config.imap_user,
        password=config.imap_password,
        folder=config.imap_folder,
        mode=config.imap_mode,
        processed_folder=config.imap_processed_folder or "",
        oversized_folder=config.imap_oversized_folder or "",
        enabled=True,
    )
    settings.set(SETTING_ACCOUNTS_SEEDED, "1")
    logger.info("Created the first IMAP account from the configuration (%s)", config.imap_host)
MAIL2NAS_EOF

# --- mail2nas/printers.py ---
cat > mail2nas/printers.py <<'MAIL2NAS_EOF'
"""Printers, stored locally so the web UI can manage them centrally.

A printer is configured once - here - and then only *referenced* everywhere
else: a mailbox picks one from a dropdown, a mapping rule picks one from a
dropdown. That way the queue name, the CUPS server and the paper options live
in exactly one place, and changing them does not mean editing every rule.

Same storage as the IMAP accounts (the SQLite file next to the state), for the
same reason: it has to be writable, survive updates, and be editable from the
UI. Unlike the accounts this holds no credentials - printing goes through the
local CUPS client, which does its own authentication if the server needs any.
"""
from __future__ import annotations

import logging
import shlex
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

SETTING_PRINTERS_SEEDED = "printers_seeded"

MAX_NAME_LENGTH = 80
MAX_DESTINATION_LENGTH = 128
MAX_OPTIONS_LENGTH = 200
MAX_COPIES = 20


class PrinterError(ValueError):
    """A printer the user tried to save is not usable."""


@dataclass(frozen=True)
class Printer:
    """One print queue."""

    id: int
    name: str
    destination: str  # CUPS queue name, i.e. `lp -d <destination>`
    server: str  # optional CUPS server "host" or "host:port"; empty = local cupsd
    options: str  # extra lp options, e.g. "media=A4 sides=two-sided-long-edge"
    copies: int
    enabled: bool

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by an account or a mapping rule."""
        return str(self.id)

    @property
    def option_list(self) -> list[str]:
        """The options as separate `-o` arguments."""
        return shlex.split(self.options) if self.options.strip() else []

    def label(self) -> str:
        where = f" @ {self.server}" if self.server else ""
        return f"{self.name} ({self.destination}{where})"


class PrinterStore:
    """CRUD for the configured printers.

    Opens a short-lived connection per call, like `AccountStore`: the web UI
    answers requests on a thread pool and the account workers read from their
    own threads, and one sqlite3 connection must not be shared across threads.
    """

    _COLUMNS = "id, name, destination, server, options, copies, enabled"

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS printers ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "destination TEXT NOT NULL, "
                "server TEXT NOT NULL DEFAULT '', "
                "options TEXT NOT NULL DEFAULT '', "
                "copies INTEGER NOT NULL DEFAULT 1, "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_printer(row) -> Printer:
        return Printer(
            id=row[0],
            name=row[1],
            destination=row[2],
            server=row[3],
            options=row[4],
            copies=row[5],
            enabled=bool(row[6]),
        )

    def all(self) -> list[Printer]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM printers ORDER BY id").fetchall()
        return [self._row_to_printer(row) for row in rows]

    def enabled(self) -> list[Printer]:
        return [printer for printer in self.all() if printer.enabled]

    def get(self, printer_id: int) -> Printer | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM printers WHERE id = ?", (printer_id,)
            ).fetchone()
        return self._row_to_printer(row) if row else None

    def by_key(self, key: str) -> Printer | None:
        """Look a printer up by the string id an account or rule stores."""
        try:
            printer_id = int(str(key).strip())
        except (TypeError, ValueError):
            return None
        return self.get(printer_id)

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO printers (name, destination, server, options, copies, enabled) "
                "VALUES (:name, :destination, :server, :options, :copies, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, printer_id: int, **fields) -> None:
        current = self.get(printer_id)
        if current is None:
            raise KeyError(printer_id)
        values = validate(
            {
                "name": current.name,
                "destination": current.destination,
                "server": current.server,
                "options": current.options,
                "copies": current.copies,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = printer_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE printers SET name = :name, destination = :destination, "
                "server = :server, options = :options, copies = :copies, "
                "enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, printer_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM printers WHERE id = ?", (printer_id,))


def validate(fields: dict) -> dict:
    """Check and normalise what the UI (or the environment) supplies.

    The values end up as arguments to the `lp` binary. That call never goes
    through a shell, so this is not about quoting - it is about catching typos
    early and refusing values (newlines, leading dashes) that would turn into
    something other than what was typed.
    """
    name = str(fields.get("name") or "").strip()
    destination = str(fields.get("destination") or "").strip()
    server = str(fields.get("server") or "").strip()
    options = " ".join(str(fields.get("options") or "").split())

    if not destination:
        raise PrinterError("Bitte den Namen der Druckerwarteschlange angeben.")
    if len(destination) > MAX_DESTINATION_LENGTH:
        raise PrinterError(f"Die Warteschlange darf hoechstens {MAX_DESTINATION_LENGTH} Zeichen lang sein.")
    if any(char.isspace() for char in destination) or destination.startswith("-"):
        raise PrinterError(
            "Die Warteschlange darf keine Leerzeichen enthalten und nicht mit '-' beginnen "
            "(so heisst sie auch in CUPS)."
        )
    if len(name) > MAX_NAME_LENGTH:
        raise PrinterError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")
    if any(char.isspace() for char in server) or server.startswith("-"):
        raise PrinterError("Der CUPS-Server darf keine Leerzeichen enthalten (z. B. cups.lan:631).")
    if len(options) > MAX_OPTIONS_LENGTH:
        raise PrinterError(f"Die Optionen duerfen hoechstens {MAX_OPTIONS_LENGTH} Zeichen lang sein.")

    try:
        option_list = shlex.split(options) if options else []
    except ValueError as exc:
        raise PrinterError(f"Die Optionen sind nicht lesbar: {exc}") from None
    for option in option_list:
        if option.startswith("-"):
            raise PrinterError(
                f"Option {option!r}: nur der Teil hinter -o angeben, z. B. media=A4."
            )

    try:
        copies = int(fields.get("copies") or 1)
    except (TypeError, ValueError):
        raise PrinterError("Die Anzahl der Kopien muss eine Zahl sein.") from None
    if not 1 <= copies <= MAX_COPIES:
        raise PrinterError(f"Die Anzahl der Kopien muss zwischen 1 und {MAX_COPIES} liegen.")

    return {
        "name": name or destination,
        "destination": destination,
        "server": server,
        "options": options,
        "copies": copies,
        "enabled": 1 if fields.get("enabled", True) else 0,
    }


def seed_from_config(store: PrinterStore, settings, config) -> None:
    """Create the first printer from the environment, once.

    Same deal as the IMAP accounts: an install that configured a printer in
    the `.env` gets it without re-entering anything, and deleting it in the UI
    does not resurrect it on the next restart.
    """
    if settings.get(SETTING_PRINTERS_SEEDED):
        return
    if store.all() or not config.printer_destination:
        settings.set(SETTING_PRINTERS_SEEDED, "1")
        return

    try:
        store.add(
            name=config.printer_name or config.printer_destination,
            destination=config.printer_destination,
            server=config.printer_server,
            options=config.printer_options,
            copies=config.printer_copies,
            enabled=True,
        )
    except PrinterError as exc:
        logger.error("PRINTER_DESTINATION is not usable (%s) - no printer was created", exc)
        return
    settings.set(SETTING_PRINTERS_SEEDED, "1")
    logger.info("Created the first printer from the configuration (%s)", config.printer_destination)
MAIL2NAS_EOF

# --- mail2nas/printing.py ---
cat > mail2nas/printing.py <<'MAIL2NAS_EOF'
"""Sending attachments to a printer.

Printing goes through the `lp` client from CUPS rather than through a Python
IPP library: every NAS-adjacent printer setup already has a CUPS server (or a
printer that speaks IPP and can be added to one), `lp` handles the driver and
format conversion side, and it means no long-lived printer connection has to
be maintained inside a service whose real job is archiving mail.

Two rules the rest of the code depends on:

* **Nothing is printed that was quarantined.** That decision is made in the
  archiver; this module only ever sees what it is handed. What it does check
  is the file type: an unknown format sent to a queue produces a stack of
  garbage paper, so only known-printable extensions are spooled.
* **A failing printer never fails the archiving.** Paper is the copy, the
  share is the archive. Every error is logged and swallowed by
  `PrintService.send`, so an offline printer cannot stop mail from being
  filed - or, worse, cause the same mail to be processed again and again.
"""
from __future__ import annotations

import logging
import os
import subprocess
import tempfile

from .config import DEFAULT_PRINTABLE_EXTENSIONS
from .filenames import extension_of, sanitize_filename
from .printers import Printer, PrinterStore

logger = logging.getLogger(__name__)

# The job title shows up in the CUPS queue. Keep it short and free of control
# characters - it is built from an attacker-supplied filename.
MAX_TITLE_LENGTH = 80


class PrintError(RuntimeError):
    """A print job could not be handed to CUPS."""


def parse_extensions(raw: str) -> frozenset[str]:
    return frozenset(ext.strip().lower().lstrip(".") for ext in raw.split(",") if ext.strip())


def job_title(prefix: str, filename: str) -> str:
    title = f"{prefix}: {filename}" if prefix else filename
    title = "".join(char for char in title if char.isprintable())
    return title[:MAX_TITLE_LENGTH] or "mail2nas"


def build_command(printer: Printer, path: str, title: str, lp_binary: str = "lp") -> list[str]:
    """Build the `lp` invocation for one job.

    Split out from the call so the command can be asserted on in tests without
    a printer anywhere near. Note the arguments are passed to `lp` directly -
    there is no shell involved, so nothing here needs quoting.
    """
    command = [lp_binary]
    if printer.server:
        command += ["-h", printer.server]
    command += ["-d", printer.destination, "-t", title]
    if printer.copies > 1:
        command += ["-n", str(printer.copies)]
    for option in printer.option_list:
        command += ["-o", option]
    # "--" so a filename can never be read as an option, whatever it is called.
    return [*command, "--", path]


class Spooler:
    """Hands bytes to CUPS, one temporary file per job."""

    def __init__(
        self,
        lp_binary: str = "lp",
        timeout: int = 120,
        printable_extensions: frozenset[str] = frozenset(),
        dry_run: bool = False,
    ):
        self._lp_binary = lp_binary
        self._timeout = timeout
        self._printable = printable_extensions or parse_extensions(DEFAULT_PRINTABLE_EXTENSIONS)
        self._dry_run = dry_run

    @property
    def printable_extensions(self) -> frozenset[str]:
        return self._printable

    def can_print(self, filename: str) -> bool:
        return extension_of(sanitize_filename(filename)) in self._printable

    def print_bytes(self, printer: Printer, data: bytes, filename: str, title: str = "") -> str:
        """Spool `data` to `printer`. Returns what `lp` reported, for the log.

        Raises PrintError for anything that went wrong, including a missing
        `lp` binary - which is the most likely failure on a container that was
        built before printing existed.
        """
        extension = extension_of(sanitize_filename(filename))
        return self._spool(printer, data, extension, title or job_title("", filename))

    def print_test_page(self, printer: Printer) -> str:
        """Print a page that says where it came from, to verify a queue."""
        page = (
            "mail2nas - Testseite\n"
            "====================\n\n"
            f"Drucker: {printer.label()}\n"
            f"Optionen: {printer.options or '(keine)'}\n"
            f"Kopien: {printer.copies}\n\n"
            "Kommt diese Seite an, funktioniert die Warteschlange.\n"
        )
        return self._spool(printer, page.encode("utf-8"), "txt", "mail2nas Testseite")

    def _spool(self, printer: Printer, data: bytes, extension: str, title: str) -> str:
        if self._dry_run:
            logger.info("[dry-run] would print %r on %s", title, printer.label())
            return "dry-run"

        suffix = f".{extension}" if extension else ""
        handle, path = tempfile.mkstemp(prefix="mail2nas-print-", suffix=suffix)
        try:
            # The attachment is untrusted content sitting in a shared temp
            # directory until CUPS has picked it up, so nobody else may read it.
            os.chmod(path, 0o600)
            with os.fdopen(handle, "wb") as fh:
                fh.write(data)
            return self._run(build_command(printer, path, title, self._lp_binary))
        finally:
            try:
                os.unlink(path)
            except OSError:  # pragma: no cover - only if something else removed it
                logger.debug("Could not remove the temporary print file %s", path, exc_info=True)

    def _run(self, command: list[str]) -> str:
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=self._timeout, check=False
            )
        except FileNotFoundError:
            raise PrintError(
                f"{self._lp_binary} nicht gefunden - im Container fehlt das Paket cups-client "
                "(oder LP_BINARY zeigt auf den falschen Pfad)."
            ) from None
        except subprocess.TimeoutExpired:
            raise PrintError(
                f"Der Druckauftrag wurde nach {self._timeout}s abgebrochen - "
                "antwortet der CUPS-Server?"
            ) from None
        except OSError as exc:
            raise PrintError(f"Druckauftrag fehlgeschlagen: {exc}") from exc

        if result.returncode != 0:
            message = (result.stderr or result.stdout or "").strip()
            raise PrintError(message or f"{self._lp_binary} endete mit Code {result.returncode}")
        return (result.stdout or "").strip()


class PrintService:
    """Which printer a job goes to, and the promise that it never raises.

    `printer_for` implements the precedence the UI documents: the most
    specific setting wins. A mapping rule that names a printer beats the
    mailbox default, which beats "no printer configured" (nothing is printed,
    and it is logged - silently dropping paper someone asked for is worse than
    a log line).
    """

    def __init__(self, printers: PrinterStore, spooler: Spooler):
        self._printers = printers
        self._spooler = spooler

    @property
    def spooler(self) -> Spooler:
        return self._spooler

    def configured(self) -> bool:
        return bool(self._printers.enabled())

    def printer_for(self, *keys: str) -> Printer | None:
        """First enabled printer among `keys`, which may contain blanks."""
        for key in keys:
            if not key or str(key) in ("0", "None"):
                continue
            printer = self._printers.by_key(key)
            if printer is None:
                logger.warning("Printer %r is configured somewhere but no longer exists", key)
                continue
            if not printer.enabled:
                logger.warning("Printer %r is paused - not printing on it", printer.label())
                continue
            return printer
        return None

    def send(self, printer: Printer, data: bytes, filename: str, title: str = "") -> bool:
        """Print, reporting failures rather than raising them.

        Returns True if CUPS accepted the job. The archiver treats a False as
        "the paper copy did not happen" and carries on: the attachment is
        already on the share, and re-processing the mail to retry the print
        would duplicate the archived file.
        """
        if not self._spooler.can_print(filename):
            logger.warning(
                "Not printing %r on %s: %s is not in PRINTABLE_EXTENSIONS",
                filename,
                printer.label(),
                extension_of(sanitize_filename(filename)) or "(no extension)",
            )
            return False
        try:
            reply = self._spooler.print_bytes(printer, data, filename, title)
        except PrintError as exc:
            logger.error("Printing %r on %s failed: %s", filename, printer.label(), exc)
            return False
        logger.info("Printed %r on %s%s", filename, printer.label(), f" ({reply})" if reply else "")
        return True


def from_config(config, printers: PrinterStore) -> PrintService:
    """Build the print service described by the configuration."""
    return PrintService(
        printers,
        Spooler(
            lp_binary=config.lp_binary,
            timeout=config.print_timeout,
            printable_extensions=config.printable_extensions,
            dry_run=config.dry_run,
        ),
    )
MAIL2NAS_EOF

# --- mail2nas/runtime.py ---
cat > mail2nas/runtime.py <<'MAIL2NAS_EOF'
"""The objects the archiver and the web UI both work on.

Settings that used to be environment-only can now be changed at runtime, so
something has to hold the live state and let one side tell the other that it
moved. That is all this is: a small container plus the two operations that
need coordinating.
"""
from __future__ import annotations

import logging
import threading

from .mapping import MappingError
from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

SETTING_MAPPING_PATH = "mapping_path"


class Runtime:
    """Shared handles, plus the mapping-file location that can move."""

    def __init__(
        self, config, storage, mapping, store, settings, accounts, printers=None, printing=None
    ):
        self.config = config
        self.storage = storage
        self.mapping = mapping
        self.store = store
        self.settings = settings
        self.accounts = accounts
        # Optional so a caller that does not care about printing (tests, and
        # the archiver before printers existed) can leave them out.
        self.printers = printers
        self.printing = printing
        # Set by the web UI, consumed by the supervisor loop: the archiver
        # threads must not read a half-changed path.
        self.mapping_path_changed = threading.Event()

    @property
    def mapping_path(self) -> str:
        """Where the rules live - the stored value wins over the .env one."""
        return self.settings.get(SETTING_MAPPING_PATH) or self.config.mapping_path

    def set_mapping_path(self, new_path: str, move_existing: bool = True) -> None:
        """Point the archiver at a different mapping file, optionally moving it.

        Moving is a copy followed by a delete rather than a rename: the
        storage backends deliberately expose no rename, and a copy that fails
        halfway leaves the original in place, which is the safer direction.
        """
        new_path = (new_path or "").strip().replace("\\", "/")
        try:
            parts = safe_relative_parts(new_path)
        except ValueError as exc:
            raise MappingError(f"Ungueltiger Pfad: {exc}") from None
        new_path = "/".join(parts)

        old_path = self.mapping_path
        if new_path == old_path:
            return

        if move_existing:
            try:
                content = self.storage.read_text(old_path)
            except FileNotFoundError:
                content = None
            if content is not None:
                self.storage.write_text(new_path, content)
                self.storage.remove_file(old_path)
                logger.info("Moved the mapping file from %s to %s", old_path, new_path)

        self.settings.set(SETTING_MAPPING_PATH, new_path)
        self.mapping.set_path(new_path)
        self.mapping_path_changed.set()

    def apply_mapping_path(self) -> None:
        """Re-point the shared Mapping if the stored path changed."""
        wanted = self.mapping_path
        if self.mapping.path != wanted:
            self.mapping.set_path(wanted)
MAIL2NAS_EOF

# --- mail2nas/storage.py ---
cat > mail2nas/storage.py <<'MAIL2NAS_EOF'
"""Where archived attachments end up.

Two backends, same interface:

* `LocalStorage` writes into a directory. Something else (host fstab, a
  bind mount from the Proxmox host) has to have mounted the share there.
* `SmbStorage` speaks SMB directly from this process. Nothing is mounted
  anywhere, so it needs no mount privileges - which is what makes it work
  inside an unprivileged LXC, where the kernel refuses to mount CIFS at all.

The interface deliberately works on *path components* rather than on
strings: the target folders come from `mapping.yaml` on the share and are
untrusted, so they are validated once (`safe_relative_parts`) and then joined
by the backend onto its own root - a local path or a UNC path.
"""
from __future__ import annotations

import errno
import logging
import os
import secrets
import threading
from abc import ABC, abstractmethod
from collections.abc import Sequence
from pathlib import Path

from .filenames import safe_relative_parts, unique_path, write_atomic

logger = logging.getLogger(__name__)

TEMP_PREFIX = ".mail2nas-tmp-"


class Storage(ABC):
    """Backend-independent view of the archive target."""

    @property
    @abstractmethod
    def description(self) -> str:
        """Human-readable location, for log lines and error messages."""

    @abstractmethod
    def check_writable(self) -> None:
        """Verify archiving can actually work, or raise SystemExit.

        Called once at startup. Without it, a share that is unreachable or
        read-only is indistinguishable from an empty one, and attachments
        would be written somewhere they silently disappear from.
        """

    @abstractmethod
    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        """Write `data` to `<root>/<parts>/<filename>`, creating directories.

        Never overwrites an existing file (a counter is appended instead) and
        never leaves a partially written file under the final name. Returns
        the full path that was written, for logging.
        """

    @abstractmethod
    def read_text(self, relative: str) -> str:
        """Read a UTF-8 text file relative to the root. Raises FileNotFoundError."""

    @abstractmethod
    def write_text(self, relative: str, text: str) -> None:
        """Overwrite a UTF-8 text file relative to the root, atomically.

        Unlike `save_unique` this replaces an existing file - it is used for
        the mapping file, which the web UI rewrites in place.
        """

    @abstractmethod
    def list_folders(self, max_depth: int = 2) -> list[str]:
        """Existing directories below the root, as relative POSIX paths.

        Feeds the folder picker in the web UI, so people assign keywords to
        folders that actually exist instead of typing a path by hand. Hidden
        directories are skipped.
        """

    @abstractmethod
    def create_folder(self, relative: str) -> None:
        """Create a directory below the root, including parents."""

    @abstractmethod
    def remove_file(self, relative: str) -> None:
        """Delete a file below the root. Missing is not an error."""

    @abstractmethod
    def modified_time(self, relative: str) -> float:
        """Modification time of a file relative to the root. Raises FileNotFoundError."""

    @abstractmethod
    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        """Full path as it would be written, without touching the target."""

    def close(self) -> None:
        """Release connections, if the backend holds any."""


class LocalStorage(Storage):
    """Archive into an already-mounted directory."""

    def __init__(self, root: str):
        self._root = Path(root)

    @property
    def description(self) -> str:
        return str(self._root)

    def check_writable(self) -> None:
        if not self._root.is_dir():
            raise SystemExit(
                f"STORAGE_ROOT {self._root} does not exist or is not a directory - "
                "is the share mounted? (With STORAGE_BACKEND=smb no mount is needed.)"
            )
        if not os.access(self._root, os.W_OK | os.X_OK):
            raise SystemExit(
                f"STORAGE_ROOT {self._root} is not writable by uid {os.getuid()} - "
                "check the mount options (uid/gid/file_mode) and the share permissions."
            )

    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        directory = self._root.joinpath(*parts)
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, filename)
        write_atomic(out_path, data)
        return str(out_path)

    def read_text(self, relative: str) -> str:
        return self._resolve(relative).read_text(encoding="utf-8")

    def write_text(self, relative: str, text: str) -> None:
        path = self._resolve(relative)
        path.parent.mkdir(parents=True, exist_ok=True)
        write_atomic(path, text.encode("utf-8"))

    def list_folders(self, max_depth: int = 2) -> list[str]:
        found: list[str] = []

        def walk(directory: Path, prefix: str, depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(directory.iterdir(), key=lambda e: e.name.lower())
            except OSError:
                return
            for entry in entries:
                if entry.name.startswith(".") or not entry.is_dir():
                    continue
                relative = f"{prefix}{entry.name}"
                found.append(relative)
                walk(entry, f"{relative}/", depth + 1)

        walk(self._root, "", 1)
        return found

    def create_folder(self, relative: str) -> None:
        self._root.joinpath(*safe_relative_parts(relative)).mkdir(parents=True, exist_ok=True)

    def remove_file(self, relative: str) -> None:
        self._resolve(relative).unlink(missing_ok=True)

    def modified_time(self, relative: str) -> float:
        return self._resolve(relative).stat().st_mtime

    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        path = self._root.joinpath(*parts)
        return str(path / filename) if filename else str(path)

    def _resolve(self, relative: str) -> Path:
        return self._root.joinpath(*safe_relative_parts(relative))


class SmbStorage(Storage):
    """Archive over SMB, without mounting the share anywhere.

    Every operation goes through `_with_reconnect`: a NAS that reboots, drops
    idle sessions or gets restarted mid-archive is normal in this deployment,
    and the archiver is a long-running process. A failed call therefore gets
    one retry on a fresh session before it is reported.
    """

    def __init__(
        self,
        host: str,
        share: str,
        user: str,
        password: str,
        domain: str | None = None,
        port: int = 445,
        root: str = "",
        encrypt: bool = True,
    ):
        self._host = host
        self._share = share
        self._user = user
        self._password = password
        self._domain = domain or None
        self._port = port
        self._encrypt = encrypt
        self._root_parts = safe_relative_parts(root) if root.strip() else ()
        self._connected = False
        # smbclient keys its connection pool by "server:port" and defaults to
        # 445 on every single call, so a non-default port has to be passed to
        # each operation - not just to register_session, which would otherwise
        # open a second (failing) connection on 445.
        self._kwargs = {"port": self._port}
        # Several account workers share one storage object. smbclient's own
        # connection pool is thread-safe, but the reconnect dance below is not:
        # two threads resetting the same session at once would fight over it.
        self._lock = threading.RLock()

    @property
    def description(self) -> str:
        # _unc() already prepends the root, so pass no extra components.
        return self._display_unc(())

    # --- session handling ---------------------------------------------------

    def _connect(self) -> None:
        if self._connected:
            return
        import smbclient

        # smbprotocol wants the domain in the username, not as a separate
        # argument. An empty domain must stay absent rather than become
        # "\\user", which some servers reject outright.
        username = f"{self._domain}\\{self._user}" if self._domain else self._user
        smbclient.register_session(
            self._host,
            username=username,
            password=self._password,
            port=self._port,
            encrypt=self._encrypt,
        )
        self._connected = True

    def _reset(self) -> None:
        self._connected = False
        try:
            import smbclient

            # Short timeout: the usual reason for resetting is that the server
            # stopped answering, and the default 60s wait for the logoff reply
            # would stall the retry that is the whole point of resetting.
            smbclient.delete_session(self._host, port=self._port, timeout=5)
        except Exception:  # noqa: BLE001 - tearing down a broken session must not raise
            logger.debug("Could not cleanly close the SMB session to %s", self._host, exc_info=True)

    def _with_reconnect(self, operation: str, func):
        """Run `func`, retrying once on a fresh session if it fails.

        A missing file is a legitimate answer (the mapping file may not exist
        yet), not a broken connection - those propagate without a reconnect,
        so callers can still catch FileNotFoundError.
        """
        with self._lock:
            return self._with_reconnect_locked(operation, func)

    def _with_reconnect_locked(self, operation: str, func):
        self._connect()
        try:
            return func()
        except FileNotFoundError:
            raise
        except OSError as exc:
            if getattr(exc, "errno", None) == errno.ENOENT:
                raise FileNotFoundError(str(exc)) from exc
            logger.warning("SMB %s failed (%s) - reconnecting and retrying once", operation, exc)
        except Exception as exc:  # noqa: BLE001 - smbprotocol raises non-OSError types too
            logger.warning("SMB %s failed (%s) - reconnecting and retrying once", operation, exc)

        self._reset()
        self._connect()
        try:
            return func()
        except OSError as exc:
            if getattr(exc, "errno", None) == errno.ENOENT:
                raise FileNotFoundError(str(exc)) from exc
            raise

    # --- paths ---------------------------------------------------------------

    def _unc(self, parts: Sequence[str], filename: str | None = None) -> str:
        segments = [*self._root_parts, *parts]
        if filename:
            segments.append(filename)
        return "\\".join([f"\\\\{self._host}\\{self._share}", *segments])

    def _display_unc(self, parts: Sequence[str], filename: str | None = None) -> str:
        # Forward slashes in messages, matching how shares are written
        # everywhere else in this project (//nas/Belege/rechnungen).
        return self._unc(parts, filename).replace("\\", "/")

    def display(self, parts: Sequence[str], filename: str | None = None) -> str:
        return self._display_unc(parts, filename)

    # --- operations ----------------------------------------------------------

    def check_writable(self) -> None:
        """Connect and write a probe file, so a broken setup fails at startup.

        Deliberately a single combined check rather than a reachability test
        followed by a write test: Samba refuses `stat` on a bare share root
        even for users who may write to it, so the write is the only probe
        that answers the question we actually care about.
        """
        probe = f"{TEMP_PREFIX}writetest-{os.getpid()}-{secrets.token_hex(4)}"
        try:
            self._with_reconnect("write test", lambda: self._write_probe(probe))
        except Exception as exc:  # noqa: BLE001 - turn any failure into an actionable message
            where = " (below SMB_ROOT)" if self._root_parts else ""
            raise SystemExit(
                f"Cannot archive to {self.description} over SMB: {exc}\n"
                "Check SMB_HOST/SMB_SHARE/SMB_USER/SMB_PASSWORD (and SMB_DOMAIN if your "
                f"server needs one), and that this user may write to the share{where}. "
                "If the server refuses encryption, set SMB_ENCRYPT=false."
            ) from exc

    def _write_probe(self, name: str) -> None:
        import smbclient

        self._ensure_dir(())
        path = self._unc((), name)
        with smbclient.open_file(path, mode="wb", **self._kwargs) as fh:
            fh.write(b"mail2nas write test")
        smbclient.remove(path, **self._kwargs)

    def _ensure_dir(self, parts: Sequence[str]) -> None:
        import smbclient

        if not parts and not self._root_parts:
            # The share root itself always exists - nothing to create.
            return
        smbclient.makedirs(self._unc(parts), exist_ok=True, **self._kwargs)

    def save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        return self._with_reconnect("write", lambda: self._save_unique(parts, filename, data))

    def _save_unique(self, parts: Sequence[str], filename: str, data: bytes) -> str:
        import smbclient
        import smbclient.path

        self._ensure_dir(parts)

        # Pick a free name. Single-writer assumption, same as the local
        # backend: mail2nas is one process per share path.
        target_name = filename
        stem, suffix = Path(filename).stem, Path(filename).suffix
        counter = 0
        while smbclient.path.exists(self._unc(parts, target_name), **self._kwargs):
            counter += 1
            target_name = f"{stem}_{counter}{suffix}"

        # Write to a temporary name and rename into place, so an interrupted
        # transfer can never leave a truncated file under a name that looks
        # like a complete invoice.
        tmp_name = f"{TEMP_PREFIX}{secrets.token_hex(8)}"
        tmp_path = self._unc(parts, tmp_name)
        target_path = self._unc(parts, target_name)
        try:
            with smbclient.open_file(tmp_path, mode="xb", **self._kwargs) as fh:
                fh.write(data)
            smbclient.replace(tmp_path, target_path, **self._kwargs)
        except BaseException:
            try:
                smbclient.remove(tmp_path, **self._kwargs)
            except Exception:  # noqa: BLE001 - cleanup of a failed write is best effort
                logger.debug("Could not remove temporary file %s", tmp_path, exc_info=True)
            raise

        return self._display_unc(parts, target_name)

    def read_text(self, relative: str) -> str:
        parts = safe_relative_parts(relative)
        return self._with_reconnect("read", lambda: self._read_text(parts))

    def _read_text(self, parts: Sequence[str]) -> str:
        import smbclient

        with smbclient.open_file(
            self._unc(parts[:-1], parts[-1]), mode="r", encoding="utf-8", **self._kwargs
        ) as fh:
            return fh.read()

    def write_text(self, relative: str, text: str) -> None:
        parts = safe_relative_parts(relative)
        self._with_reconnect("write", lambda: self._write_text(parts, text))

    def _write_text(self, parts: Sequence[str], text: str) -> None:
        import smbclient

        directory, name = tuple(parts[:-1]), parts[-1]
        self._ensure_dir(directory)
        tmp_path = self._unc(directory, f"{TEMP_PREFIX}{secrets.token_hex(8)}")
        try:
            with smbclient.open_file(tmp_path, mode="xb", **self._kwargs) as fh:
                fh.write(text.encode("utf-8"))
            smbclient.replace(tmp_path, self._unc(directory, name), **self._kwargs)
        except BaseException:
            try:
                smbclient.remove(tmp_path, **self._kwargs)
            except Exception:  # noqa: BLE001 - cleanup of a failed write is best effort
                logger.debug("Could not remove temporary file %s", tmp_path, exc_info=True)
            raise

    def list_folders(self, max_depth: int = 2) -> list[str]:
        return self._with_reconnect("list", lambda: self._list_folders(max_depth))

    def _list_folders(self, max_depth: int) -> list[str]:
        import smbclient

        found: list[str] = []

        def walk(parts: tuple[str, ...], prefix: str, depth: int) -> None:
            if depth > max_depth:
                return
            try:
                entries = sorted(
                    smbclient.scandir(self._unc(parts), **self._kwargs),
                    key=lambda e: e.name.lower(),
                )
            except Exception:  # noqa: BLE001 - an unreadable subfolder must not hide the rest
                logger.debug("Could not list %s", self._unc(parts), exc_info=True)
                return
            for entry in entries:
                if entry.name.startswith(".") or not entry.is_dir():
                    continue
                relative = f"{prefix}{entry.name}"
                found.append(relative)
                walk((*parts, entry.name), f"{relative}/", depth + 1)

        walk((), "", 1)
        return found

    def create_folder(self, relative: str) -> None:
        parts = safe_relative_parts(relative)
        self._with_reconnect("mkdir", lambda: self._ensure_dir(parts))

    def remove_file(self, relative: str) -> None:
        parts = safe_relative_parts(relative)
        try:
            self._with_reconnect("remove", lambda: self._remove_file(parts))
        except FileNotFoundError:
            pass

    def _remove_file(self, parts) -> None:
        import smbclient

        smbclient.remove(self._unc(parts[:-1], parts[-1]), **self._kwargs)

    def modified_time(self, relative: str) -> float:
        parts = safe_relative_parts(relative)
        return self._with_reconnect("stat", lambda: self._modified_time(parts))

    def _modified_time(self, parts: Sequence[str]) -> float:
        import smbclient

        return smbclient.stat(self._unc(parts[:-1], parts[-1]), **self._kwargs).st_mtime

    def close(self) -> None:
        self._reset()


def from_config(config) -> Storage:
    """Build the storage backend described by the configuration."""
    if config.storage_backend == "smb":
        return SmbStorage(
            host=config.smb_host,
            share=config.smb_share,
            user=config.smb_user,
            password=config.smb_password,
            domain=config.smb_domain,
            port=config.smb_port,
            root=config.smb_root,
            encrypt=config.smb_encrypt,
        )
    return LocalStorage(config.storage_root)
MAIL2NAS_EOF

# --- mail2nas/mapping.py ---
cat > mail2nas/mapping.py <<'MAIL2NAS_EOF'
"""Keyword -> folder rules: file format, matching, and editing.

The rules live as YAML on the archive share, so they survive a broken web UI
and stay editable by hand. Two things they have to express beyond the keyword
and the target folder:

* **Order.** The first matching rule wins, and the order is explicit rather
  than derived, so "Rechnungskorrektur" can be placed above "RE" instead of
  relying on it happening to be the longer word.
* **Which mailbox a rule applies to**, once more than one IMAP account is
  configured.
* **Whether the match is printed**, and on which of the configured printers.

Format (version 2)::

    version: 2
    rules:
      - keyword: Rechnungskorrektur
        folder: korrekturen
      - keyword: "RE*"
        folder: rechnungen
        account: "2"
        print: true
        printer: "1"

The old flat `keyword: folder` format is still read: it is migrated in
memory, longest keyword first, which is exactly the priority that version
applied implicitly. Nothing is rewritten until the rules are saved.
"""
from __future__ import annotations

import logging
import re
import threading
from dataclasses import dataclass, field, replace

import yaml

from .filenames import safe_relative_parts
from .storage import Storage

logger = logging.getLogger(__name__)

FILE_VERSION = 2
ALL_ACCOUNTS = "all"
MAX_KEYWORD_LENGTH = 100
# A pattern is a chain of ".*?" separated by literals, so matching cost grows
# with (wildcards x text length). Mail subjects and bodies are attacker-
# supplied, so both factors are bounded rather than trusted: without this a
# keyword like "a*a*a*a*a*..." plus a large body (MATCH_BODY=true) would tie
# up an account worker for a very long time.
MAX_WILDCARDS = 5
MAX_MATCH_LENGTH = 100_000


class MappingError(ValueError):
    """A rule the user tried to save is not usable."""


def _compile(keyword: str) -> re.Pattern[str] | None:
    """Build a matcher for a keyword containing `*` / `?`, or None for plain text.

    Wildcards stay *within* the substring search people already know: the
    pattern is not anchored, so "RE*2026" matches a subject that has "RE"
    somewhere followed later by "2026". `*Rechnung*` therefore means the same
    as plain `Rechnung`.
    """
    if "*" not in keyword and "?" not in keyword:
        return None
    if keyword.count("*") > MAX_WILDCARDS:
        # Loaded from a file that may have been edited by hand, so this has to
        # degrade rather than raise: treat it as plain text, which can only
        # match less, never more.
        logger.warning(
            "Keyword %r has more than %d wildcards - treating it as literal text",
            keyword,
            MAX_WILDCARDS,
        )
        return None
    pattern = "".join(
        ".*?" if char == "*" else "." if char == "?" else re.escape(char) for char in keyword
    )
    return re.compile(pattern, re.IGNORECASE | re.DOTALL)


@dataclass(frozen=True)
class Rule:
    """One keyword -> folder assignment."""

    keyword: str
    folder: str
    account: str = ALL_ACCOUNTS  # ALL_ACCOUNTS or an account id as a string
    # Print the attachments this rule matches. The printer is optional: an
    # empty string means "whatever the mailbox is set to".
    print_attachments: bool = False
    printer: str = ""
    _matcher: re.Pattern[str] | None = field(default=None, compare=False, repr=False)

    @classmethod
    def create(
        cls,
        keyword: str,
        folder: str,
        account: str = ALL_ACCOUNTS,
        print_attachments: bool = False,
        printer: str = "",
    ) -> "Rule":
        return cls(
            keyword,
            folder,
            account or ALL_ACCOUNTS,
            bool(print_attachments),
            str(printer or ""),
            _compile(keyword),
        )

    @property
    def has_wildcard(self) -> bool:
        return self._matcher is not None

    def applies_to(self, account_id: str | None) -> bool:
        if self.account == ALL_ACCOUNTS or account_id is None:
            return True
        return self.account == str(account_id)

    def matches(self, haystack_lower: str, haystack: str) -> bool:
        if self._matcher is not None:
            return self._matcher.search(haystack[:MAX_MATCH_LENGTH]) is not None
        return self.keyword.lower() in haystack_lower

    def as_dict(self) -> dict[str, object]:
        # Only what differs from the default is written, so a file that never
        # used printing stays exactly as short as it was.
        data: dict[str, object] = {"keyword": self.keyword, "folder": self.folder}
        if self.account != ALL_ACCOUNTS:
            data["account"] = self.account
        if self.print_attachments:
            data["print"] = True
        if self.printer:
            data["printer"] = self.printer
        return data


def _as_bool(value) -> bool:
    """Read a flag from a file someone may have edited by hand.

    YAML already turns `true`/`yes` into booleans, but `print: "ja"` is the
    kind of thing that gets typed - and silently treating it as false would
    mean paper that never comes out with nothing to explain why.
    """
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on", "ja")


def parse_rules(raw) -> list[Rule]:
    """Turn parsed YAML into rules, accepting both file formats."""
    if not raw:
        return []

    if isinstance(raw, dict) and "rules" in raw:
        entries = raw.get("rules") or []
        if not isinstance(entries, list):
            raise MappingError("'rules' muss eine Liste von Zuordnungen sein.")
        rules = []
        for entry in entries:
            if not isinstance(entry, dict) or "keyword" not in entry or "folder" not in entry:
                raise MappingError("Jede Zuordnung braucht 'keyword' und 'folder'.")
            rules.append(
                Rule.create(
                    str(entry["keyword"]),
                    str(entry["folder"]),
                    str(entry.get("account", ALL_ACCOUNTS)),
                    _as_bool(entry.get("print", False)),
                    str(entry.get("printer", "") or ""),
                )
            )
        return rules

    if isinstance(raw, dict):
        # Legacy flat format. Longest keyword first reproduces the priority the
        # old matcher applied implicitly, so migrating cannot change behaviour.
        pairs = sorted(raw.items(), key=lambda kv: len(str(kv[0])), reverse=True)
        return [Rule.create(str(keyword), str(folder)) for keyword, folder in pairs]

    raise MappingError("Die Datei enthaelt keine Stichwort/Ordner-Zuordnungen.")


def dump_rules(rules: list[Rule]) -> str:
    """Render rules as YAML, preserving their order."""
    document = {"version": FILE_VERSION, "rules": [rule.as_dict() for rule in rules]}
    return yaml.safe_dump(document, allow_unicode=True, default_flow_style=False, sort_keys=False)


class Mapping:
    """The rule list, reloaded from the share when the file changes.

    Shared by every account worker, so reloading is guarded by a lock: each
    worker calls `reload()` at the start of its cycle.
    """

    def __init__(self, storage: Storage, relative_path: str, fallback_folder: str):
        self._storage = storage
        self._fallback_folder = fallback_folder
        self._lock = threading.Lock()
        self._rules: list[Rule] = []
        self._mtime: float | None = None
        self.set_path(relative_path)

    @property
    def path(self) -> str:
        return self._relative_path

    def set_path(self, relative_path: str) -> None:
        """Point at a different mapping file and load it immediately."""
        with self._lock:
            self._relative_path = relative_path
            self._display_path = self._storage.display(safe_relative_parts(relative_path))
            self._mtime = None
        self.reload(force=True)

    def reload(self, force: bool = False) -> None:
        with self._lock:
            relative_path, display_path = self._relative_path, self._display_path
            known_mtime, rule_count = self._mtime, len(self._rules)

        try:
            mtime = self._storage.modified_time(relative_path)
        except FileNotFoundError:
            if force:
                logger.warning(
                    "Mapping file %s not found, all mail will go to the fallback folder",
                    display_path,
                )
                with self._lock:
                    self._rules = []
                    self._mtime = None
            return
        except Exception as exc:  # noqa: BLE001 - a dropped share must not kill the loop
            # With the SMB backend this is a network call, so it can fail for
            # reasons that have nothing to do with the file itself. Keep the
            # rules we already have; the next cycle tries again.
            logger.warning(
                "Could not check mapping file %s (%s) - keeping the previous %d rule(s)",
                display_path,
                exc,
                rule_count,
            )
            return

        if not force and known_mtime == mtime:
            return

        # The file can also be edited by hand on a network share, so a
        # malformed or half-written version is a matter of when, not if. Keep
        # serving the last good rules instead of letting the exception escape:
        # it would propagate out of the IMAP loop and leave the service
        # reconnecting in a tight loop, archiving nothing until someone noticed.
        try:
            rules = parse_rules(yaml.safe_load(self._storage.read_text(relative_path)))
        except Exception as exc:  # noqa: BLE001
            # Remember the mtime anyway, so a persistently broken file is
            # reported once rather than on every single cycle.
            with self._lock:
                self._mtime = mtime
            logger.error(
                "Could not load mapping file %s (%s) - keeping the previous %d rule(s)",
                display_path,
                exc,
                rule_count,
            )
            return

        with self._lock:
            self._rules = rules
            self._mtime = mtime
        logger.info("Loaded %d mapping rule(s) from %s", len(rules), display_path)

    def match(self, *texts: str, account_id: str | None = None) -> Rule | None:
        """Return the first rule that matches, or None.

        The whole rule rather than just its folder: the caller also needs to
        know whether the match should be printed, and on which printer.
        """
        haystack = " ".join(t for t in texts if t)
        haystack_lower = haystack.lower()
        with self._lock:
            rules = self._rules
        for rule in rules:
            if rule.applies_to(account_id) and rule.matches(haystack_lower, haystack):
                return rule
        return None

    def resolve(self, *texts: str, account_id: str | None = None) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword) for the first matching rule."""
        rule = self.match(*texts, account_id=account_id)
        return (rule.folder, rule.keyword) if rule else (self._fallback_folder, None)


# --- editing helpers (used by the web UI) ------------------------------------


def load_rules(storage: Storage, relative_path: str) -> list[Rule]:
    """Read the rule list for editing.

    A missing file is an empty rule list, not an error: that is the state
    right after installation, and the UI is where it gets fixed.
    """
    try:
        return parse_rules(yaml.safe_load(storage.read_text(relative_path)))
    except FileNotFoundError:
        return []


def save_rules(storage: Storage, relative_path: str, rules: list[Rule]) -> None:
    storage.write_text(relative_path, dump_rules(rules))


def validate_keyword(keyword: str, existing: list[Rule], replacing: int | None = None) -> str:
    """Check a keyword the user typed, returning the cleaned version."""
    keyword = keyword.strip()
    if not keyword:
        raise MappingError("Bitte ein Stichwort angeben.")
    if len(keyword) > MAX_KEYWORD_LENGTH:
        raise MappingError(f"Das Stichwort darf hoechstens {MAX_KEYWORD_LENGTH} Zeichen lang sein.")
    if "\n" in keyword or "\r" in keyword:
        raise MappingError("Das Stichwort darf keine Zeilenumbrueche enthalten.")
    if keyword.strip("*? ") == "":
        raise MappingError("Ein Stichwort aus lauter Platzhaltern wuerde auf alles passen.")
    if keyword.count("*") > MAX_WILDCARDS:
        raise MappingError(f"Hoechstens {MAX_WILDCARDS} Platzhalter (*) pro Stichwort.")
    # Matching is case-insensitive, so two rules with the same keyword for the
    # same account would be indistinguishable - the second could never win.
    lowered = keyword.lower()
    for index, rule in enumerate(existing):
        if index == replacing:
            continue
        if rule.keyword.lower() == lowered:
            raise MappingError(f"Das Stichwort {rule.keyword!r} gibt es schon.")
    return keyword


def validate_folder(folder: str) -> str:
    """Check a target folder, returning the cleaned relative path."""
    folder = folder.strip().replace("\\", "/")
    if not folder:
        raise MappingError("Bitte einen Zielordner auswaehlen oder anlegen.")
    try:
        parts = safe_relative_parts(folder)
    except ValueError as exc:
        raise MappingError(f"Ungueltiger Zielordner: {exc}") from None
    return "/".join(parts)


def move_rule(rules: list[Rule], index: int, offset: int) -> list[Rule]:
    """Return the rules with one entry moved up or down."""
    if not 0 <= index < len(rules):
        raise MappingError("Diese Zuordnung gibt es nicht mehr.")
    target = index + offset
    if not 0 <= target < len(rules):
        return rules
    reordered = list(rules)
    reordered.insert(target, reordered.pop(index))
    return reordered


def set_account(rule: Rule, account: str) -> Rule:
    return replace(rule, account=account or ALL_ACCOUNTS)


def set_printing(rule: Rule, print_attachments: bool, printer: str) -> Rule:
    """Change a rule's print settings, dropping the printer when off."""
    print_attachments = bool(print_attachments)
    return replace(
        rule,
        print_attachments=print_attachments,
        printer=str(printer or "") if print_attachments else "",
    )
MAIL2NAS_EOF

# --- mail2nas/filenames.py ---
cat > mail2nas/filenames.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import re
import tempfile
import unicodedata
from pathlib import Path

_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")

# Characters that are path separators, reserved on Windows/SMB, or control
# characters. Folder names keep spaces and non-ASCII letters (people do name
# folders "Rechnungen 2026"), so this is deliberately more permissive than
# the attachment-filename sanitizer.
_UNSAFE_SEGMENT = re.compile(r'[\x00-\x1f\x7f<>:"|?*\\/]+')


def sanitize_filename(name: str) -> str:
    """Strip characters that are awkward on SMB shares / cross-platform filesystems."""
    name = unicodedata.normalize("NFKD", name)
    name = _UNSAFE.sub("_", name).strip("._")
    return name or "attachment"


def extension_of(filename: str) -> str:
    """Lower-cased extension without the dot, or "" if there is none."""
    if "." not in filename:
        return ""
    return filename.rsplit(".", 1)[-1].strip().lower()


def sanitize_path_segment(segment: str) -> str:
    """Sanitize a single folder-name component (never a path)."""
    segment = unicodedata.normalize("NFKC", segment)
    segment = _UNSAFE_SEGMENT.sub("_", segment)
    # Trailing dots/spaces are silently dropped by Windows/SMB, which would
    # make the on-disk name differ from what was configured.
    return segment.strip().rstrip(". ").strip()


def safe_relative_parts(relative: str) -> tuple[str, ...]:
    """Split `relative` into validated, sanitized path components.

    The target folders come from `mapping.yaml`, which lives on the archive
    share itself - so whoever can edit that file could otherwise redirect
    attachments anywhere the process can write, via `../..` or an absolute
    path.

    Absolute paths and `..` components are refused rather than reinterpreted,
    and every remaining component is sanitized. Nested targets such as
    "rechnungen/2026" stay supported. Raises ValueError if nothing usable is
    left, so the caller can fall back to a known-good folder.

    Returning components rather than a joined path keeps this usable for both
    storage backends: the local one joins them onto a filesystem root, the SMB
    one onto a UNC path.
    """
    raw = str(relative).replace("\\", "/")

    if raw.strip().startswith("/"):
        # Confining "/etc/cron.d" to "<root>/etc/cron.d" would be safe but
        # produces a surprising deep tree on the share. An absolute target is
        # always a misconfiguration, so say so and let the caller fall back.
        raise ValueError(f"Target folder must be relative to the storage root: {relative!r}")

    parts: list[str] = []
    for candidate in raw.split("/"):
        candidate = candidate.strip()
        if candidate in ("", "."):
            continue
        if candidate == "..":
            raise ValueError(f"Refusing parent-directory component in target folder: {relative!r}")
        cleaned = sanitize_path_segment(candidate)
        if not cleaned or cleaned == "..":
            raise ValueError(f"Target folder component is empty after sanitizing: {relative!r}")
        parts.append(cleaned)

    if not parts:
        raise ValueError(f"Target folder is empty: {relative!r}")

    return tuple(parts)


def safe_join(root: str | Path, relative: str) -> Path:
    """Join `relative` onto `root`, guaranteeing the result stays under `root`.

    See `safe_relative_parts` for what is accepted. (Note `Path("/mnt/nas") /
    "/etc"` yields `/etc`: an absolute right operand discards the root
    entirely - hence the validation rather than a plain join.)
    """
    root_path = Path(root)
    result = root_path.joinpath(*safe_relative_parts(relative))

    # Belt and braces: the component filtering above already makes escaping
    # impossible, but verify containment lexically so any future change to the
    # parsing cannot silently reopen the hole.
    root_abs = os.path.abspath(root_path)
    result_abs = os.path.abspath(result)
    if result_abs != root_abs and not result_abs.startswith(root_abs.rstrip(os.sep) + os.sep):
        raise ValueError(f"Target folder escapes the storage root: {relative!r}")

    return result


def unique_path(directory: str | Path, filename: str) -> Path:
    """Return a path for `filename` inside `directory`, avoiding overwrites."""
    directory = Path(directory)
    candidate = directory / filename
    if not candidate.exists():
        return candidate

    stem, suffix = Path(filename).stem, Path(filename).suffix
    counter = 1
    while True:
        candidate = directory / f"{stem}_{counter}{suffix}"
        if not candidate.exists():
            return candidate
        counter += 1


def write_atomic(path: str | Path, data: bytes) -> None:
    """Write `data` to `path` via a temporary file plus rename.

    A direct write that is interrupted (container restart, SMB share dropping
    mid-transfer) would leave a truncated file behind that still looks like a
    complete invoice. Renaming into place means the final name only ever
    appears once the bytes are fully written.
    """
    path = Path(path)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".mail2nas-tmp-")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(data)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
MAIL2NAS_EOF

# --- mail2nas/state.py ---
cat > mail2nas/state.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import sqlite3
import threading
from pathlib import Path


class ProcessedStore:
    """Tracks Message-IDs that have already been archived.

    IMAP's \\Seen flag alone is not a safe idempotency marker (it can be
    reset by another client, or the folder can be re-synced), so we keep a
    small local record of what has actually been written to the share.

    One connection shared by every account worker, guarded by a lock:
    sqlite3 connections are not safe to use from several threads at once, and
    the writes here are short enough that serialising them costs nothing.
    """

    def __init__(self, db_path: str):
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, timeout=10, check_same_thread=False)
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS processed_messages ("
                "message_id TEXT PRIMARY KEY, "
                "processed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
            )
            self._conn.commit()

    def is_processed(self, message_id: str) -> bool:
        with self._lock:
            cur = self._conn.execute(
                "SELECT 1 FROM processed_messages WHERE message_id = ?", (message_id,)
            )
            return cur.fetchone() is not None

    def mark_processed(self, message_id: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO processed_messages (message_id) VALUES (?)", (message_id,)
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()


class SettingsStore:
    """Small key/value store for things the web UI has to remember.

    Lives in the same SQLite file as the processed-message table, so there is
    still exactly one piece of local state to back up or throw away.

    Unlike `ProcessedStore` this opens a short-lived connection per call: the
    web UI answers requests on a thread pool, and one sqlite3 connection must
    not be shared across threads. The settings are read/written rarely enough
    that the extra connect costs nothing.
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS settings ("
                "key TEXT PRIMARY KEY, "
                "value TEXT NOT NULL, "
                "updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    def get(self, key: str) -> str | None:
        with self._connect() as conn:
            row = conn.execute("SELECT value FROM settings WHERE key = ?", (key,)).fetchone()
        return row[0] if row else None

    def set(self, key: str, value: str) -> None:
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO settings (key, value, updated_at) "
                "VALUES (?, ?, CURRENT_TIMESTAMP) "
                "ON CONFLICT(key) DO UPDATE SET value = excluded.value, "
                "updated_at = CURRENT_TIMESTAMP",
                (key, value),
            )
MAIL2NAS_EOF

# --- mail2nas/archiver.py ---
cat > mail2nas/archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import email
import logging
from dataclasses import dataclass
from email.header import decode_header, make_header
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime

from imapclient import IMAPClient

from .accounts import Account
from .config import Config
from .filenames import extension_of, safe_relative_parts, sanitize_filename
from .mapping import Mapping, Rule
from .printers import Printer
from .printing import PrintService, job_title
from .state import ProcessedStore
from .storage import Storage

logger = logging.getLogger(__name__)


def _decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def _message_id(msg: Message, uid: int, account_key: str) -> str:
    """Idempotency key. Scoped per account: the same message delivered to two
    watched mailboxes is two things to archive, not one."""
    return f"{account_key}:" + (msg.get("Message-ID") or f"<no-message-id-uid-{uid}@mail2nas>")


@dataclass(frozen=True)
class AttachmentPlan:
    """What is to happen with one attachment, decided before anything happens.

    Filing and printing are two independent answers to the same question, and
    both depend on the same rule match - so they are worked out together and
    then carried out, rather than being re-derived at each step.
    """

    folder: str
    keyword: str | None
    quarantined: bool
    archive: bool
    printer: Printer | None


class Archiver:
    def __init__(
        self,
        config: Config,
        mapping: Mapping,
        store: ProcessedStore,
        storage: Storage,
        account: Account,
        printing: PrintService | None = None,
    ):
        self.config = config
        self.mapping = mapping
        self.store = store
        self.storage = storage
        self.account = account
        self.printing = printing

    def connect(self) -> IMAPClient:
        client = IMAPClient(self.account.host, port=self.account.port, ssl=self.account.ssl)
        client.login(self.account.user, self.account.password)
        client.select_folder(self.account.folder)
        return client

    def _match(self, *texts: str) -> Rule | None:
        # Rules can be limited to a single mailbox, so the account has to be
        # part of every lookup.
        return self.mapping.match(*texts, account_id=self.account.key)

    def run_once(self, client: IMAPClient) -> int:
        """Process all currently unseen messages. Returns the number processed."""
        self.mapping.reload()
        uids = client.search(["UNSEEN"])
        if not uids:
            return 0

        processed = 0
        for uid in uids:
            try:
                if self._process_message(client, uid):
                    processed += 1
            except Exception:
                logger.exception("Failed to process message UID %s, leaving it for retry", uid)
        return processed

    def _process_message(self, client: IMAPClient, uid: int) -> bool:
        # Check the message size *before* pulling the full body into memory -
        # a hostile/broken sender could otherwise use an oversized message to
        # exhaust memory/disk on every poll cycle.
        size_reply = client.fetch([uid], ["RFC822.SIZE"])
        message_size = size_reply.get(uid, {}).get(b"RFC822.SIZE", 0)
        max_message_bytes = self.config.max_message_size_mb * 1024 * 1024
        if message_size and message_size > max_message_bytes:
            logger.warning(
                "UID %s is %.1f MB, exceeds MAX_MESSAGE_SIZE_MB=%d - skipping attachment "
                "extraction and flagging for manual review",
                uid,
                message_size / (1024 * 1024),
                self.config.max_message_size_mb,
            )
            if not self.config.dry_run:
                client.add_flags([uid], [b"\\Seen"])
                if self.account.oversized_folder:
                    client.move([uid], self.account.oversized_folder)
            return True

        raw = client.fetch([uid], ["RFC822"])[uid][b"RFC822"]
        msg = email.message_from_bytes(raw)
        message_id = _message_id(msg, uid, self.account.key)

        if self.store.is_processed(message_id):
            logger.info("UID %s (%s) already processed, marking seen and skipping", uid, message_id)
            client.add_flags([uid], [b"\\Seen"])
            return False

        subject = _decode(msg.get("Subject"))
        _, sender_addr = parseaddr(_decode(msg.get("From")))
        body = self._extract_body(msg) if self.config.match_body else ""
        mail_rule = self._match(subject, body)

        attachments = list(self._iter_attachments(msg))
        if len(attachments) > self.config.max_attachments_per_message:
            logger.warning(
                "UID %s '%s' has %d attachments, only processing the first %d "
                "(MAX_ATTACHMENTS_PER_MESSAGE)",
                uid,
                subject,
                len(attachments),
                self.config.max_attachments_per_message,
            )
            attachments = attachments[: self.config.max_attachments_per_message]

        saved: list[str] = []
        if not attachments:
            logger.info("UID %s '%s' has no attachments, nothing to save", uid, subject)
        else:
            date_prefix = self._date_prefix(msg)
            max_attachment_bytes = self.config.max_attachment_size_mb * 1024 * 1024
            for filename, payload in attachments:
                if len(payload) > max_attachment_bytes:
                    logger.warning(
                        "UID %s '%s': attachment '%s' is %.1f MB, exceeds "
                        "MAX_ATTACHMENT_SIZE_MB=%d - skipping this attachment",
                        uid,
                        subject,
                        filename,
                        len(payload) / (1024 * 1024),
                        self.config.max_attachment_size_mb,
                    )
                    continue

                plan = self._plan_attachment(filename, mail_rule)
                out_name = self._build_filename(date_prefix, sender_addr, filename)

                if plan.archive:
                    target_parts = self._target_parts(plan.folder)
                    if self.config.dry_run:
                        logger.info(
                            "[dry-run] would save %s -> %s",
                            out_name,
                            self.storage.display(target_parts),
                        )
                    else:
                        out_path = self.storage.save_unique(target_parts, out_name, payload)
                        saved.append(out_path)
                        logger.info(
                            "UID %s '%s': attachment '%s' matched '%s'%s -> %s",
                            uid,
                            subject,
                            filename,
                            plan.keyword or "<fallback>",
                            " [QUARANTAENE: gesperrte Dateiendung]" if plan.quarantined else "",
                            out_path,
                        )
                elif plan.printer is not None:
                    logger.info(
                        "UID %s '%s': attachment '%s' is printed only, not archived",
                        uid,
                        subject,
                        filename,
                    )
                else:
                    # Neither filed nor printed - that is a configuration
                    # mistake rather than an intention, and the attachment is
                    # gone once the mail is marked as read.
                    logger.warning(
                        "UID %s '%s': attachment '%s' was neither archived nor printed - "
                        "the mailbox is set to print only but nothing prints it",
                        uid,
                        subject,
                        filename,
                    )

                # Printing comes after filing, deliberately: the share is the
                # archive and paper is the copy, so a printer that is offline
                # or out of paper must never be the reason an attachment was
                # not stored.
                if plan.printer is not None:
                    self.printing.send(
                        plan.printer, payload, out_name, job_title(subject, filename)
                    )

        if not self.config.dry_run:
            self.store.mark_processed(message_id)
            client.add_flags([uid], [b"\\Seen"])
            if self.account.processed_folder:
                client.move([uid], self.account.processed_folder)
        return True

    def _target_parts(self, folder_name: str) -> tuple[str, ...]:
        """Map a configured folder name onto path components inside the archive root.

        Folder names come from mapping.yaml on the share and are therefore
        untrusted; anything that would escape the archive root is rejected and
        replaced with the fallback folder rather than being written outside.
        """
        for candidate, note in ((folder_name, None), (self.config.fallback_folder, "fallback"), ("unsorted", "built-in")):
            try:
                target = safe_relative_parts(candidate)
            except ValueError as exc:
                logger.error(
                    "Unsafe target folder %r (%s) - not writing outside the archive root", candidate, exc
                )
                continue
            if note and candidate != folder_name:
                logger.warning("Using %s folder %r instead of %r", note, candidate, folder_name)
            return target
        raise ValueError("No usable target folder inside the archive root")

    def _plan_attachment(self, filename: str, mail_rule: Rule | None) -> AttachmentPlan:
        """Decide where a single attachment is filed, and whether it is printed.

        The attachment's own filename is checked against the mapping first,
        so multiple differently-named attachments on the same mail can land
        in different folders. Falls back to the mail-level (subject/body)
        match when the filename itself gives no hint. Attachments with a
        blocked extension are always quarantined, regardless of any keyword
        match, so a malicious/executable attachment can never be renamed
        into a trusted-looking business folder just by naming it "Rechnung.exe".
        """
        rule = self._match(filename) or mail_rule

        # Check both the name as received and the name actually written to
        # disk: sanitizing can change the trailing extension, and only the
        # latter is what a file manager will act on when someone opens it.
        extensions = {extension_of(filename), extension_of(sanitize_filename(_decode(filename)))}
        quarantined = bool(extensions & self.config.blocked_extensions)

        return AttachmentPlan(
            folder=self.config.quarantine_folder if quarantined else self._folder_of(rule),
            keyword=rule.keyword if rule else None,
            quarantined=quarantined,
            # "Print only" still files anything quarantined: it cannot be
            # printed either, and dropping it without a trace would hide
            # exactly the attachment somebody may need to look at.
            archive=self.account.archive_attachments or quarantined,
            printer=self._printer_for(rule, quarantined),
        )

    def _folder_of(self, rule: Rule | None) -> str:
        return rule.folder if rule else self.config.fallback_folder

    def _printer_for(self, rule: Rule | None, quarantined: bool) -> Printer | None:
        """Which printer this attachment goes to, if any.

        Printing is requested either by the mailbox ("print everything that
        arrives here") or by the matched rule ("print invoices"). The printer
        is then the most specific one configured: the rule's own choice beats
        the mailbox default.
        """
        if self.printing is None or not self.config.printing_enabled:
            return None
        if quarantined:
            # A blocked attachment is a suspected executable. It is neither
            # printable nor something to hand to a printer driver.
            return None

        by_rule = rule is not None and rule.print_attachments
        if not (self.account.print_attachments or by_rule):
            return None

        printer = self.printing.printer_for(
            rule.printer if by_rule else "", self.account.printer
        )
        if printer is None:
            logger.warning(
                "Printing is enabled for %s but no usable printer is configured - "
                "nothing was printed",
                f"rule {rule.keyword!r}" if by_rule else f"mailbox {self.account.name!r}",
            )
        return printer

    @staticmethod
    def _date_prefix(msg: Message) -> str:
        date_header = msg.get("Date")
        if date_header:
            try:
                return parsedate_to_datetime(date_header).strftime("%Y-%m-%d")
            except (TypeError, ValueError):
                pass
        return "unknown-date"

    def _build_filename(self, date_prefix: str, sender_addr: str, filename: str) -> str:
        filename = sanitize_filename(_decode(filename))
        mode = self.config.filename_prefix
        if mode == "none":
            return filename
        if mode == "date":
            return f"{date_prefix}_{filename}"
        sender = sanitize_filename(sender_addr or "unknown")
        if mode == "sender":
            return f"{sender}_{filename}"
        return f"{date_prefix}_{sender}_{filename}"

    @staticmethod
    def _iter_attachments(msg: Message):
        for part in msg.walk():
            if part.get_content_maintype() == "multipart":
                continue
            disposition = part.get_content_disposition()
            filename = part.get_filename()
            if disposition != "attachment" and not filename:
                continue
            payload = part.get_payload(decode=True)
            if payload is None:
                continue
            yield filename or "attachment", payload

    @staticmethod
    def _extract_body(msg: Message) -> str:
        if msg.is_multipart():
            for part in msg.walk():
                if part.get_content_type() == "text/plain" and not part.get_filename():
                    try:
                        return part.get_payload(decode=True).decode(
                            part.get_content_charset() or "utf-8", errors="replace"
                        )
                    except Exception:
                        continue
            return ""
        try:
            return msg.get_payload(decode=True).decode(msg.get_content_charset() or "utf-8", errors="replace")
        except Exception:
            return ""
MAIL2NAS_EOF

# --- mail2nas/web.py ---
cat > mail2nas/web.py <<'MAIL2NAS_EOF'
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
    ALL_ACCOUNTS,
    MappingError,
    Rule,
    load_rules,
    move_rule,
    save_rules,
    set_account,
    set_printing,
    validate_folder,
    validate_keyword,
)
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
  <p style="margin-bottom:0"><a href="{{ url_for('new_printer') }}">
    <button type="button">Drucker hinzufuegen</button></a></p>
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

{% if printer %}
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
    config, storage, settings = runtime.config, runtime.storage, runtime.settings
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
        return load_rules(storage, runtime.mapping_path)

    def _save(rules: list[Rule]) -> None:
        save_rules(storage, runtime.mapping_path, rules)

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
            folders = storage.list_folders()
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
            storage_description=storage.description,
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
            if new_folder:
                storage.create_folder(folder)
            rules.append(Rule.create(keyword, folder, account, printing, printer))
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
            updated = Rule.create(rule.keyword, folder, account, printing, printer)
            rules[index] = set_printing(set_account(updated, account), printing, printer)
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
            printing_enabled=config.printing_enabled,
            mapping_path=runtime.mapping_path,
            storage_description=storage.description,
            storage_backend=config.storage_backend,
            fallback_folder=config.fallback_folder,
            quarantine_folder=config.quarantine_folder,
            match_body=config.match_body,
            filename_prefix=config.filename_prefix,
            poll_interval=config.poll_interval,
            dry_run=config.dry_run,
        )

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
        return render(PRINTER_BODY, "Drucker", printer=None)

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

    @app.post("/config/printers/<int:printer_id>/delete")
    @login_required
    def delete_printer(printer_id: int):
        require_csrf()
        _require_printers().delete(printer_id)
        logger.info("Web UI: deleted printer %s", printer_id)
        flash(
            "Drucker geloescht. Postfaecher und Zuordnungen, die auf ihn zeigten, "
            "drucken nicht mehr.",
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
MAIL2NAS_EOF

# --- mail2nas/main.py ---
cat > mail2nas/main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import os
import sys
import threading

from . import printing as printing_module
from . import storage as storage_module
from .accounts import AccountStore, seed_from_config
from .archiver import Archiver
from .config import Config
from .mapping import Mapping
from .printers import PrinterStore
from .printers import seed_from_config as seed_printer_from_config
from .runtime import SETTING_MAPPING_PATH, Runtime
from .state import ProcessedStore, SettingsStore

logger = logging.getLogger("mail2nas")

# How often the supervisor notices that accounts were added, changed or
# removed in the web UI. Short enough to feel immediate, long enough to be
# free.
SUPERVISOR_INTERVAL = 5


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    storage = storage_module.from_config(config)
    # Fail fast: an unreachable share is otherwise indistinguishable from an
    # empty one, and attachments would land somewhere they silently vanish.
    storage.check_writable()

    settings = SettingsStore(config.state_db_path)
    accounts = AccountStore(config.state_db_path)
    # Before seeding: from here on the file contains IMAP passwords.
    _protect_state_file(config.state_db_path)
    seed_from_config(accounts, settings, config)

    printers = PrinterStore(config.state_db_path)
    seed_printer_from_config(printers, settings, config)
    printing = printing_module.from_config(config, printers)

    mapping_path = settings.get(SETTING_MAPPING_PATH) or config.mapping_path
    mapping = Mapping(storage, mapping_path, config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    runtime = Runtime(
        config, storage, mapping, store, settings, accounts, printers=printers, printing=printing
    )

    if config.web_enabled:
        # Imported lazily so the archiver still runs if the web dependencies
        # are missing (e.g. an older image built before the UI existed).
        from . import web

        web.serve(runtime)

    logger.info(
        "Starting mail2nas: storage=%s (%s) mapping=%s printers=%d dry_run=%s",
        storage.description,
        config.storage_backend,
        mapping_path,
        len(printers.enabled()) if config.printing_enabled else 0,
        config.dry_run,
    )

    try:
        _supervise(runtime)
    finally:
        store.close()
        storage.close()


def _protect_state_file(path: str) -> None:
    """The state database holds IMAP passwords, so nobody else may read it."""
    try:
        os.chmod(path, 0o600)
    except OSError as exc:
        logger.warning("Could not restrict permissions on %s (%s)", path, exc)


class _Worker:
    """One IMAP account, watched on its own thread.

    A thread per account rather than one loop over all of them: IMAP IDLE
    blocks, so a single loop would leave every other mailbox waiting for the
    first one's timeout.
    """

    def __init__(self, runtime: Runtime, account):
        self.account = account
        self.fingerprint = account.fingerprint()
        self._runtime = runtime
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name=f"mail2nas-imap-{account.id}", daemon=True
        )

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def is_alive(self) -> bool:
        return self._thread.is_alive()

    def _run(self) -> None:
        config = self._runtime.config
        archiver = Archiver(
            config,
            self._runtime.mapping,
            self._runtime.store,
            self._runtime.storage,
            self.account,
            self._runtime.printing,
        )
        label = f"{self.account.name} <{self.account.user}>"
        logger.info(
            "Account %s: watching %s on %s (%s mode)",
            label,
            self.account.folder,
            self.account.host,
            self.account.mode,
        )

        while not self._stop.is_set():
            try:
                client = archiver.connect()
            except Exception:
                logger.exception(
                    "Account %s: IMAP connection failed, retrying in %ss",
                    label,
                    config.poll_interval,
                )
                self._stop.wait(config.poll_interval)
                continue

            try:
                if self.account.mode == "idle":
                    self._run_idle(archiver, client, label)
                else:
                    self._run_poll(archiver, client, label)
            except Exception:
                logger.exception(
                    "Account %s: IMAP session failed, reconnecting in %ss",
                    label,
                    config.poll_interval,
                )
            finally:
                try:
                    client.logout()
                except Exception:
                    pass
            self._stop.wait(config.poll_interval)

        logger.info("Account %s: stopped", label)

    def _cycle(self, archiver: Archiver, client, label: str) -> None:
        count = archiver.run_once(client)
        if count:
            logger.info("Account %s: processed %d message(s)", label, count)

    def _run_poll(self, archiver: Archiver, client, label: str) -> None:
        while not self._stop.is_set():
            self._cycle(archiver, client, label)
            self._stop.wait(self._runtime.config.poll_interval)

    def _run_idle(self, archiver: Archiver, client, label: str) -> None:
        self._cycle(archiver, client, label)
        idle_timeout = self._runtime.config.poll_interval or 300
        while not self._stop.is_set():
            client.idle()
            try:
                client.idle_check(timeout=idle_timeout)
            finally:
                client.idle_done()
            self._cycle(archiver, client, label)


def reconcile(runtime: Runtime, workers: dict, factory=None) -> dict:
    """Start, stop and restart workers so they match the configured accounts.

    Split out of the loop below so the decision - which worker survives a
    configuration change - can be tested without real IMAP connections.
    """
    factory = factory or (lambda account: _Worker(runtime, account))
    wanted = {account.id: account for account in runtime.accounts.enabled()}

    for account_id, worker in list(workers.items()):
        account = wanted.get(account_id)
        if account is None or account.fingerprint() != worker.fingerprint:
            # Settings changed or the account is gone. The worker notices at
            # the end of its current cycle, so a reconnect can lag by up to
            # one poll interval.
            if account is not None:
                logger.info("Account %s: configuration changed, restarting", account.name)
            worker.stop()
            del workers[account_id]
        elif not worker.is_alive():
            del workers[account_id]

    for account_id, account in wanted.items():
        if account_id not in workers:
            worker = factory(account)
            workers[account_id] = worker
            worker.start()

    return workers


def _supervise(runtime: Runtime) -> None:
    """Keep one worker per enabled account, following changes made in the UI."""
    workers: dict[int, _Worker] = {}
    idle_warning_shown = False
    try:
        while True:
            reconcile(runtime, workers)

            if not workers and not idle_warning_shown:
                # Once, not on every pass - this loop runs every few seconds.
                logger.warning(
                    "No enabled IMAP account configured - nothing is being watched. "
                    "Add one in the web UI."
                )
            idle_warning_shown = bool(not workers)

            runtime.mapping_path_changed.wait(SUPERVISOR_INTERVAL)
            if runtime.mapping_path_changed.is_set():
                runtime.mapping_path_changed.clear()
                runtime.apply_mapping_path()
    finally:
        for worker in workers.values():
            worker.stop()


if __name__ == "__main__":
    main()
MAIL2NAS_EOF

# --- tests/test_mapping.py ---
cat > tests/test_mapping.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import textwrap

import pytest

from mail2nas.mapping import (
    Mapping,
    MappingError,
    Rule,
    load_rules,
    move_rule,
    save_rules,
    set_printing,
    validate_keyword,
)
from mail2nas.storage import LocalStorage


def _write_rules(tmp_path, rules) -> None:
    """Write rules in the current format, as (keyword, folder[, account])."""
    save_rules(
        LocalStorage(str(tmp_path)),
        "mapping.yaml",
        [Rule.create(*rule) for rule in rules],
    )


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _mapping(tmp_path, fallback_folder="unsorted", relative="mapping.yaml") -> Mapping:
    return Mapping(LocalStorage(str(tmp_path)), relative, fallback_folder=fallback_folder)


def test_resolve_matches_case_insensitive(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        LS: lieferscheine
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Ihre re 12345")

    assert folder == "rechnungen"
    assert keyword == "RE"


def test_resolve_falls_back_when_no_keyword_matches(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Newsletter August")

    assert folder == "unsorted"
    assert keyword is None


def test_resolve_prefers_longer_keyword_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = _mapping(tmp_path)

    folder, keyword = mapping.resolve("Rechnungskorrektur zur RE-2024-01")

    assert folder == "korrekturen"
    assert keyword == "Rechnungskorrektur"


def test_missing_mapping_file_falls_back_to_default(tmp_path):
    mapping = _mapping(tmp_path, relative="does-not-exist.yaml")

    folder, keyword = mapping.resolve("Rechnung 123")

    assert folder == "unsorted"
    assert keyword is None


def test_reload_picks_up_changes(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    _write_mapping(mapping_path, "RE: invoices\n")
    # Nudge mtime forward in case the filesystem has coarse timestamp resolution.
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "invoices"


def test_broken_yaml_keeps_previous_rules_instead_of_raising(tmp_path):
    """A half-written mapping.yaml on the share must not take the service down."""
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()  # must not raise

    assert mapping.resolve("RE 1")[0] == "rechnungen"


def test_non_mapping_yaml_keeps_previous_rules(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    mapping_path.write_text("- just\n- a\n- list\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "rechnungen"


def test_broken_yaml_is_not_re_reported_every_cycle(tmp_path, caplog):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = _mapping(tmp_path)

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    with caplog.at_level("ERROR"):
        mapping.reload()
        mapping.reload()
        mapping.reload()

    assert len([r for r in caplog.records if r.levelname == "ERROR"]) == 1


# --- priority: explicit order, first match wins --------------------------------


def test_first_matching_rule_wins_regardless_of_keyword_length(tmp_path):
    """Order is explicit now - a short keyword placed first beats a longer one."""
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "rechnungen"


def test_moving_a_rule_up_changes_which_one_wins(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen"), ("Rechnungskorrektur", "korrekturen")])
    rules = load_rules(LocalStorage(str(tmp_path)), "mapping.yaml")

    save_rules(LocalStorage(str(tmp_path)), "mapping.yaml", move_rule(rules, 1, -1))

    assert _mapping(tmp_path).resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"


def test_moving_beyond_the_ends_is_a_no_op(tmp_path):
    rules = [Rule.create("A", "a"), Rule.create("B", "b")]

    assert [r.keyword for r in move_rule(rules, 0, -1)] == ["A", "B"]
    assert [r.keyword for r in move_rule(rules, 1, 1)] == ["A", "B"]


# --- legacy format --------------------------------------------------------------


def test_old_flat_file_is_read_with_its_original_priority(tmp_path):
    """The pre-2.0 format matched the longest keyword first; migration must not
    change which folder a mail lands in."""
    _write_mapping(tmp_path / "mapping.yaml", """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)

    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"
    assert mapping.resolve("RE-1")[0] == "rechnungen"


def test_saving_writes_the_versioned_format(tmp_path):
    storage = LocalStorage(str(tmp_path))
    save_rules(storage, "mapping.yaml", [Rule.create("RE", "rechnungen", "2")])

    text = storage.read_text("mapping.yaml")

    assert "version: 2" in text
    assert "keyword: RE" in text
    assert "account: '2'" in text


# --- wildcards --------------------------------------------------------------------


@pytest.mark.parametrize(
    "keyword,subject,expected",
    [
        ("RE*", "Ihre RE-4711", True),
        ("RE*2026", "RE-4711 vom 03.2026", True),
        ("RE*2026", "RE-4711 vom 03.2025", False),
        ("Rechn?ng", "Ihre Rechnung", True),
        ("Rechn?ng", "Ihre Rechnuung", False),
        ("*Rechnung*", "Ihre Rechnung 1", True),
        ("Rechnung", "Ihre RECHNUNG 1", True),
    ],
)
def test_wildcard_and_case_matching(tmp_path, keyword, subject, expected):
    _write_rules(tmp_path, [(keyword, "treffer")])

    folder, _ = _mapping(tmp_path).resolve(subject)

    assert (folder == "treffer") is expected


def test_wildcards_stay_within_substring_search(tmp_path):
    """A pattern is not anchored, so it may match in the middle of a subject."""
    _write_rules(tmp_path, [("RE*47", "treffer")])

    assert _mapping(tmp_path).resolve("Betreff: Ihre RE-4711 anbei")[0] == "treffer"


def test_a_regex_metacharacter_in_a_keyword_is_literal(tmp_path):
    """Only * and ? are wildcards - the rest must not be interpreted."""
    _write_rules(tmp_path, [("RE.*", "treffer")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("RE.4711")[0] == "treffer"
    assert mapping.resolve("REX4711")[0] == "unsorted"


def test_keyword_of_only_wildcards_is_rejected():
    with pytest.raises(MappingError):
        validate_keyword("***", [])


# --- per-account rules --------------------------------------------------------------


def test_a_rule_can_be_limited_to_one_account(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "rechnungen", "2")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung 1", account_id="2")[0] == "rechnungen"
    assert mapping.resolve("Rechnung 1", account_id="1")[0] == "unsorted"


def test_rules_for_all_accounts_match_every_account(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "rechnungen")])
    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung 1", account_id="7")[0] == "rechnungen"


def test_an_account_specific_rule_is_skipped_for_other_accounts(tmp_path):
    _write_rules(tmp_path, [("Rechnung", "nur-konto-2", "2"), ("Rechnung", "alle")])

    mapping = _mapping(tmp_path)

    assert mapping.resolve("Rechnung", account_id="2")[0] == "nur-konto-2"
    assert mapping.resolve("Rechnung", account_id="1")[0] == "alle"


def test_a_pattern_with_too_many_wildcards_is_rejected_in_the_ui():
    with pytest.raises(MappingError, match="Platzhalter"):
        validate_keyword("a*b*c*d*e*f*g", [])


def test_a_hand_written_pattern_with_too_many_wildcards_degrades_to_literal(tmp_path):
    """Loaded from the share it must not raise - and must not be run as a regex."""
    _write_mapping(tmp_path / "mapping.yaml", 'version: 2\nrules:\n- keyword: "a*b*c*d*e*f*g"\n  folder: t\n')

    mapping = _mapping(tmp_path)

    assert mapping.resolve("a" * 200 + "g")[0] == "unsorted"
    assert mapping.resolve("a*b*c*d*e*f*g")[0] == "t"


def test_matching_a_huge_body_stays_bounded(tmp_path):
    """A wildcard pattern must not be run against an unbounded amount of text."""
    import time

    _write_rules(tmp_path, [("Rechnung*Ende", "treffer")])
    mapping = _mapping(tmp_path)

    started = time.monotonic()
    folder, _ = mapping.resolve("Rechnung " + ("x" * 2_000_000))
    assert folder == "unsorted"
    assert time.monotonic() - started < 5


# --- printing per rule ------------------------------------------------------------


def test_a_rule_carries_its_print_settings(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        version: 2
        rules:
          - keyword: Rechnung
            folder: rechnungen
            print: true
            printer: "3"
    """)

    rule = _mapping(tmp_path).match("Rechnung 4711")

    assert (rule.folder, rule.print_attachments, rule.printer) == ("rechnungen", True, "3")


def test_a_rule_without_print_settings_prints_nothing(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])

    rule = _mapping(tmp_path).match("RE-1")

    assert rule.print_attachments is False
    assert rule.printer == ""


def test_print_settings_survive_a_save_and_reload(tmp_path):
    storage = LocalStorage(str(tmp_path))
    save_rules(storage, "mapping.yaml", [Rule.create("RE", "rechnungen", "all", True, "2")])

    reloaded = load_rules(storage, "mapping.yaml")[0]

    assert (reloaded.print_attachments, reloaded.printer) == (True, "2")


def test_a_file_that_never_used_printing_stays_unchanged(tmp_path):
    storage = LocalStorage(str(tmp_path))
    save_rules(storage, "mapping.yaml", [Rule.create("RE", "rechnungen")])

    text = storage.read_text("mapping.yaml")

    assert "print" not in text
    assert "printer" not in text


def test_a_hand_written_yes_is_read_as_printing(tmp_path):
    _write_mapping(tmp_path / "mapping.yaml", """
        version: 2
        rules:
          - keyword: RE
            folder: rechnungen
            print: "ja"
    """)

    assert _mapping(tmp_path).match("RE-1").print_attachments is True


def test_switching_printing_off_drops_the_printer(tmp_path):
    rule = Rule.create("RE", "rechnungen", "all", True, "2")

    assert set_printing(rule, False, "2").printer == ""
    assert set_printing(rule, True, "5").printer == "5"


def test_match_returns_nothing_when_no_rule_applies(tmp_path):
    _write_rules(tmp_path, [("RE", "rechnungen")])

    assert _mapping(tmp_path).match("Newsletter") is None
MAIL2NAS_EOF

# --- tests/test_filenames.py ---
cat > tests/test_filenames.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
from pathlib import Path

import pytest

from mail2nas.filenames import (
    safe_join,
    sanitize_filename,
    sanitize_path_segment,
    unique_path,
    write_atomic,
)


def test_sanitize_filename_replaces_unsafe_characters():
    assert sanitize_filename("Rechnung 12/03 (Kopie).pdf") == "Rechnung_12_03_Kopie_.pdf"


def test_sanitize_filename_handles_umlauts():
    result = sanitize_filename("Lieferschein Übersicht.pdf")

    assert result.endswith(".pdf")
    assert " " not in result


def test_sanitize_filename_never_empty():
    assert sanitize_filename("???") == "attachment"


def test_unique_path_avoids_overwriting_existing_file(tmp_path):
    existing = tmp_path / "invoice.pdf"
    existing.write_bytes(b"first")

    result = unique_path(tmp_path, "invoice.pdf")

    assert result != existing
    assert result.name == "invoice_1.pdf"


def test_unique_path_returns_original_when_free(tmp_path):
    result = unique_path(tmp_path, "invoice.pdf")

    assert result == tmp_path / "invoice.pdf"


# --- path segment sanitizing -------------------------------------------------


def test_sanitize_path_segment_keeps_readable_folder_names():
    assert sanitize_path_segment("Rechnungen 2026") == "Rechnungen 2026"


def test_sanitize_path_segment_strips_separators_and_reserved_chars():
    assert "/" not in sanitize_path_segment("a/b")
    assert "\\" not in sanitize_path_segment("a\\b")
    assert ":" not in sanitize_path_segment("C:name")


def test_sanitize_path_segment_strips_trailing_dot_and_space():
    assert sanitize_path_segment("rechnungen. ") == "rechnungen"


# --- safe_join: the mapping.yaml target folders are untrusted -----------------


def test_safe_join_allows_plain_and_nested_folders(tmp_path):
    assert safe_join(tmp_path, "rechnungen") == tmp_path / "rechnungen"
    assert safe_join(tmp_path, "rechnungen/2026") == tmp_path / "rechnungen" / "2026"


@pytest.mark.parametrize(
    "hostile",
    [
        "../outside",
        "../../../../tmp/pwned",
        "rechnungen/../../outside",
        "..",
    ],
)
def test_safe_join_refuses_parent_directory_escape(tmp_path, hostile):
    with pytest.raises(ValueError):
        safe_join(tmp_path, hostile)


@pytest.mark.parametrize("hostile", ["/etc/cron.d", "/tmp/pwned", "//srv/other"])
def test_safe_join_refuses_absolute_paths(tmp_path, hostile):
    # Path("/mnt/nas") / "/etc" would otherwise yield "/etc" outright.
    with pytest.raises(ValueError):
        safe_join(tmp_path, hostile)


def test_safe_join_refuses_backslash_escape(tmp_path):
    with pytest.raises(ValueError):
        safe_join(tmp_path, r"..\..\outside")


@pytest.mark.parametrize("empty", ["", "   ", "/", "./"])
def test_safe_join_refuses_empty_target(tmp_path, empty):
    with pytest.raises(ValueError):
        safe_join(tmp_path, empty)


# --- atomic writes -----------------------------------------------------------


def test_write_atomic_writes_content(tmp_path):
    target = tmp_path / "invoice.pdf"

    write_atomic(target, b"%PDF-1.4 payload")

    assert target.read_bytes() == b"%PDF-1.4 payload"


def test_write_atomic_leaves_no_temp_files_behind(tmp_path):
    write_atomic(tmp_path / "invoice.pdf", b"data")

    assert [p.name for p in tmp_path.iterdir()] == ["invoice.pdf"]


def test_write_atomic_does_not_leave_partial_file_on_failure(tmp_path, monkeypatch):
    target = tmp_path / "invoice.pdf"

    class Boom(Exception):
        pass

    real_replace = os.replace

    def failing_replace(src, dst):
        raise Boom("simulated crash before rename")

    monkeypatch.setattr(os, "replace", failing_replace)
    with pytest.raises(Boom):
        write_atomic(target, b"partial")
    monkeypatch.setattr(os, "replace", real_replace)

    assert not target.exists()
    assert list(tmp_path.iterdir()) == []
MAIL2NAS_EOF

# --- tests/test_archiver.py ---
cat > tests/test_archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import textwrap
from email.message import EmailMessage

from mail2nas.archiver import Archiver
from mail2nas.config import (
    DEFAULT_BLOCKED_EXTENSIONS,
    DEFAULT_PRINTABLE_EXTENSIONS,
    Config,
)
from mail2nas.mapping import Mapping
from mail2nas.state import ProcessedStore
from mail2nas.accounts import Account
from mail2nas.printers import PrinterStore
from mail2nas.printing import (
    PrintError,
    PrintService,
    Spooler,
    parse_extensions,
)
from mail2nas.storage import LocalStorage

TEST_ACCOUNT = Account(
    id=1, name="Test", host="imap.example.com", port=993, ssl=True,
    user="u", password="p", folder="INBOX", mode="poll",
    processed_folder="", oversized_folder="", enabled=True,
)


def _account(**overrides) -> Account:
    from dataclasses import replace
    return replace(TEST_ACCOUNT, **overrides)


def _make_config(tmp_path, **overrides) -> Config:
    defaults = dict(
        imap_host="imap.example.com",
        imap_port=993,
        imap_user="u",
        imap_password="p",
        imap_ssl=True,
        imap_folder="INBOX",
        imap_processed_folder=None,
        imap_oversized_folder=None,
        imap_mode="poll",
        poll_interval=60,
        storage_backend="local",
        storage_root=str(tmp_path),
        smb_host="",
        smb_share="",
        smb_user="",
        smb_password="",
        smb_domain="",
        smb_port=445,
        smb_root="",
        smb_encrypt=True,
        mapping_path="mapping.yaml",
        fallback_folder="unsorted",
        match_body=False,
        filename_prefix="date_sender",
        max_attachment_size_mb=25,
        max_message_size_mb=50,
        max_attachments_per_message=20,
        blocked_extensions=frozenset(
            e.strip() for e in DEFAULT_BLOCKED_EXTENSIONS.split(",")
        ),
        quarantine_folder="quarantaene",
        state_db_path=str(tmp_path / "state.db"),
        dry_run=False,
        printing_enabled=True,
        lp_binary="lp",
        print_timeout=120,
        printable_extensions=frozenset(
            e.strip() for e in DEFAULT_PRINTABLE_EXTENSIONS.split(",")
        ),
        printer_name="",
        printer_destination="",
        printer_server="",
        printer_options="",
        printer_copies=1,
        web_enabled=False,
        web_host="127.0.0.1",
        web_port=8080,
        web_password="",
        web_cookie_secure=False,
    )
    defaults.update(overrides)
    return Config(**defaults)


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _make_archiver(
    tmp_path,
    mapping_content: str | None = None,
    account: Account | None = None,
    printing=None,
    **config_overrides,
) -> Archiver:
    config = _make_config(tmp_path, **config_overrides)
    mapping_path = tmp_path / "mapping.yaml"
    if mapping_content is not None:
        _write_mapping(mapping_path, mapping_content)
    storage = LocalStorage(config.storage_root)
    mapping = Mapping(storage, config.mapping_path, config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    return Archiver(config, mapping, store, storage, account or TEST_ACCOUNT, printing)


class FakeIMAPClient:
    """Minimal stand-in for imapclient.IMAPClient, just enough for _process_message."""

    def __init__(self, uid: int, raw: bytes):
        self._uid = uid
        self._raw = raw
        self.flags_added: list[tuple[list[int], list[bytes]]] = []
        self.moved_to: list[tuple[list[int], str]] = []

    def fetch(self, uids, parts):
        assert uids == [self._uid]
        result: dict = {}
        for uid in uids:
            entry = {}
            if "RFC822.SIZE" in parts:
                entry[b"RFC822.SIZE"] = len(self._raw)
            if "RFC822" in parts:
                entry[b"RFC822"] = self._raw
            result[uid] = entry
        return result

    def add_flags(self, uids, flags):
        self.flags_added.append((list(uids), list(flags)))

    def move(self, uids, folder):
        self.moved_to.append((list(uids), folder))


def _build_message(subject: str, attachments: list[tuple[str, bytes]]) -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = "lieferant@example.com"
    msg.set_content("Hallo")
    for filename, payload in attachments:
        msg.add_attachment(payload, maintype="application", subtype="octet-stream", filename=filename)
    return bytes(msg)


# --- attachment discovery / filename building -------------------------------


def test_iter_attachments_finds_named_parts(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Rechnung 123"
    msg.set_content("Hallo")
    msg.add_attachment(b"%PDF-1.4 fake", maintype="application", subtype="pdf", filename="rechnung.pdf")

    archiver = _make_archiver(tmp_path)
    attachments = list(archiver._iter_attachments(msg))

    assert len(attachments) == 1
    filename, payload = attachments[0]
    assert filename == "rechnung.pdf"
    assert payload.startswith(b"%PDF")


def test_iter_attachments_ignores_plain_body(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Newsletter"
    msg.set_content("Nur Text, kein Anhang")

    archiver = _make_archiver(tmp_path)

    assert list(archiver._iter_attachments(msg)) == []


def test_build_filename_date_sender_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date_sender")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_lieferant_example.com_rechnung.pdf"


def test_build_filename_none_prefix_keeps_original_name(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="none")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "rechnung.pdf"


def test_build_filename_date_only_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_rechnung.pdf"


# --- per-attachment folder resolution ----------------------------------------


def test_plan_prefers_attachment_filename_over_mail_subject(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            RE: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    # Mail-level match would be "rechnungen" (subject contains RE), but this
    # specific attachment's own filename literally says "Lieferschein".
    mail_rule = archiver.mapping.match("RE-2024-001 mit Lieferschein")

    plan = archiver._plan_attachment("Lieferschein_4711.pdf", mail_rule)

    assert plan.folder == "lieferscheine"
    assert plan.keyword == "Lieferschein"
    assert plan.quarantined is False


def test_plan_falls_back_to_mail_level_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    mail_rule = archiver.mapping.match("RE-2024-001")

    # "anhang1.pdf" itself does not match any keyword.
    plan = archiver._plan_attachment("anhang1.pdf", mail_rule)

    assert plan.folder == "rechnungen"
    assert plan.keyword == "RE"
    assert plan.quarantined is False


def test_plan_quarantines_blocked_extension_even_with_keyword_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")

    plan = archiver._plan_attachment("Rechnung.exe", None)

    assert plan.folder == "quarantaene"
    assert plan.quarantined is True


# --- full message processing (size/count limits, quarantine, mail-level) ----


def test_process_message_splits_multiple_attachments_by_filename(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            Rechnung: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    raw = _build_message(
        "Bestellung 42",
        [("Rechnung_42.pdf", b"invoice-bytes"), ("Lieferschein_42.pdf", b"delivery-bytes")],
    )
    client = FakeIMAPClient(uid=1, raw=raw)

    archiver._process_message(client, 1)

    assert any(p.name.endswith("Rechnung_42.pdf") for p in (tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("Lieferschein_42.pdf") for p in (tmp_path / "lieferscheine").glob("*"))


def test_process_message_skips_oversized_message_without_reading_body(tmp_path):
    archiver = _make_archiver(tmp_path, max_message_size_mb=1)
    huge_raw = _build_message("Rechnung riesig", [("rechnung.pdf", b"x" * (2 * 1024 * 1024))])
    client = FakeIMAPClient(uid=7, raw=huge_raw)

    result = archiver._process_message(client, 7)

    assert result is True
    assert client.flags_added == [([7], [b"\\Seen"])]
    assert not (tmp_path / "rechnungen").exists()


def test_process_message_skips_only_oversized_attachment(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachment_size_mb=1, max_message_size_mb=50
    )
    raw = _build_message(
        "RE-1",
        [("gross.pdf", b"x" * (2 * 1024 * 1024)), ("klein.pdf", b"klein")],
    )
    client = FakeIMAPClient(uid=3, raw=raw)

    archiver._process_message(client, 3)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("klein.pdf") for p in saved)
    assert not any(p.name.endswith("gross.pdf") for p in saved)


def test_process_message_caps_attachment_count(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachments_per_message=2
    )
    raw = _build_message(
        "RE-1",
        [(f"a{i}.pdf", b"data") for i in range(5)],
    )
    client = FakeIMAPClient(uid=4, raw=raw)

    archiver._process_message(client, 4)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert len(saved) == 2


def test_process_message_quarantines_blocked_attachment(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ...")])
    client = FakeIMAPClient(uid=5, raw=raw)

    archiver._process_message(client, 5)

    assert not (tmp_path / "rechnungen").exists() or not any((tmp_path / "rechnungen").glob("*"))
    quarantined = list((tmp_path / "quarantaene").glob("*"))
    assert len(quarantined) == 1


def test_process_message_is_idempotent_for_already_processed_message_id(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("rechnung.pdf", b"data")])
    client = FakeIMAPClient(uid=6, raw=raw)

    archiver._process_message(client, 6)
    first_run_files = list((tmp_path / "rechnungen").glob("*"))
    archiver._process_message(client, 6)
    second_run_files = list((tmp_path / "rechnungen").glob("*"))

    assert len(first_run_files) == 1
    assert len(second_run_files) == 1


# --- untrusted mapping targets must not escape the storage root -------------


def test_process_message_confines_relative_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside-escape\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not (tmp_path.parent / "outside-escape").exists()
    # rejected target falls back rather than being written outside
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_process_message_confines_absolute_traversal_target(tmp_path):
    escape = tmp_path.parent / "absolute-escape"
    archiver = _make_archiver(tmp_path, mapping_content=f"RE: {escape}\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=2, raw=raw), 2)

    assert not escape.exists()
    # rejected as a misconfiguration, so it lands in the fallback folder
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_target_parts_reject_escape_and_use_fallback(tmp_path):
    archiver = _make_archiver(tmp_path)

    assert archiver._target_parts("../evil") == ("unsorted",)
    assert archiver._target_parts("rechnungen") == ("rechnungen",)
    assert archiver._target_parts("rechnungen/2026") == ("rechnungen", "2026")


def test_nested_mapping_target_is_supported(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen/2026\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert any((tmp_path / "rechnungen" / "2026").glob("*"))


def test_quarantine_still_wins_over_a_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=4, raw=raw), 4)

    assert not (tmp_path.parent / "outside").exists()
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_attachments_are_written_atomically_without_temp_leftovers(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    names = [p.name for p in (tmp_path / "rechnungen").iterdir()]
    assert len(names) == 1
    assert not any(n.startswith(".mail2nas-tmp-") for n in names)


# --- printing ----------------------------------------------------------------


class RecordingSpooler(Spooler):
    """A spooler that remembers jobs instead of handing them to CUPS."""

    def __init__(self, **kwargs):
        super().__init__(printable_extensions=parse_extensions(DEFAULT_PRINTABLE_EXTENSIONS))
        self.jobs: list[tuple[str, str]] = []

    def print_bytes(self, printer, data, filename, title=""):
        self.jobs.append((printer.destination, filename))
        return "queued"

    @property
    def printed_on(self) -> list[str]:
        return [destination for destination, _ in self.jobs]


def _make_printing(tmp_path, *queues: str):
    """A print service with one printer per given queue name."""
    store = PrinterStore(str(tmp_path / "printers.db"))
    ids = [str(store.add(name=queue, destination=queue)) for queue in queues]
    spooler = RecordingSpooler()
    return PrintService(store, spooler), spooler, ids


def test_a_mailbox_can_print_every_attachment(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
    )
    raw = _build_message("Newsletter", [("prospekt.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert spooler.printed_on == ["drucker_a"]
    # still archived: printing is an addition, not a replacement
    assert any((tmp_path / "unsorted").glob("*"))


def test_a_rule_can_print_only_what_it_matches(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_b")
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
                printer: "{printer_id}"
              - keyword: Lieferschein
                folder: lieferscheine
        """,
        printing=printing,
    )
    raw = _build_message(
        "Bestellung 42",
        [("Rechnung_42.pdf", b"invoice"), ("Lieferschein_42.pdf", b"delivery")],
    )

    archiver._process_message(FakeIMAPClient(uid=2, raw=raw), 2)

    assert [name for _, name in spooler.jobs] == [
        "unknown-date_lieferant_example.com_Rechnung_42.pdf"
    ]
    assert spooler.printed_on == ["drucker_b"]


def test_the_rule_printer_wins_over_the_mailbox_printer(tmp_path):
    printing, spooler, (rule_printer, account_printer) = _make_printing(
        tmp_path, "drucker_regel", "drucker_konto"
    )
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
                printer: "{rule_printer}"
        """,
        account=_account(print_attachments=True, printer=account_printer),
        printing=printing,
    )
    raw = _build_message("Rechnung 1", [("Rechnung_1.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert spooler.printed_on == ["drucker_regel"]


def test_a_rule_without_its_own_printer_uses_the_mailbox_one(tmp_path):
    printing, spooler, (account_printer,) = _make_printing(tmp_path, "drucker_konto")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
        """,
        account=_account(printer=account_printer),
        printing=printing,
    )
    raw = _build_message("Rechnung 1", [("Rechnung_1.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=4, raw=raw), 4)

    assert spooler.printed_on == ["drucker_konto"]


def test_print_only_mailboxes_do_not_write_to_the_share(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    assert spooler.printed_on == ["drucker_a"]
    assert not (tmp_path / "rechnungen").exists()


def test_a_blocked_attachment_is_quarantined_and_never_printed(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        # print everything, archive nothing - the executable must still be
        # kept, and must still not reach the printer.
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=6, raw=raw), 6)

    assert spooler.jobs == []
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_nothing_is_printed_without_a_printer(tmp_path, caplog):
    printing, spooler, _ = _make_printing(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True),
        printing=printing,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    with caplog.at_level("WARNING"):
        archiver._process_message(FakeIMAPClient(uid=7, raw=raw), 7)

    assert spooler.jobs == []
    assert "no usable printer" in caplog.text
    # the attachment is still filed - printing is the part that failed
    assert any((tmp_path / "rechnungen").glob("*"))


def test_printing_can_be_switched_off_globally(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
        printing_enabled=False,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=8, raw=raw), 8)

    assert spooler.jobs == []
    assert any((tmp_path / "rechnungen").glob("*"))


def test_a_failing_printer_does_not_stop_the_archiving(tmp_path):
    class BrokenSpooler(RecordingSpooler):
        def print_bytes(self, printer, data, filename, title=""):
            raise PrintError("Drucker offline")

    store = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = str(store.add(name="Kaputt", destination="drucker_a"))
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=PrintService(store, BrokenSpooler()),
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=9, raw=raw), 9)

    assert any((tmp_path / "rechnungen").glob("*"))
MAIL2NAS_EOF

# --- tests/test_config.py ---
cat > tests/test_config.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.config import Config

REQUIRED = {
    "IMAP_HOST": "imap.example.com",
    "IMAP_USER": "archiv@example.com",
    "IMAP_PASSWORD": "secret",
}


def _env(monkeypatch, **overrides):
    for key in list(REQUIRED) + [
        "IMAP_PORT", "IMAP_MODE", "POLL_INTERVAL_SECONDS", "FILENAME_PREFIX",
        "MAX_ATTACHMENT_SIZE_MB", "MAX_MESSAGE_SIZE_MB", "MAX_ATTACHMENTS_PER_MESSAGE",
        "STORAGE_BACKEND", "SMB_HOST", "SMB_SHARE", "SMB_USER", "SMB_PASSWORD",
        "SMB_DOMAIN", "SMB_PORT", "SMB_ROOT", "SMB_ENCRYPT", "MAPPING_PATH",
    ]:
        monkeypatch.delenv(key, raising=False)
    for key, value in {**REQUIRED, **overrides}.items():
        monkeypatch.setenv(key, value)


def test_defaults_load(monkeypatch):
    _env(monkeypatch)

    config = Config.from_env()

    assert config.imap_port == 993
    assert config.imap_mode == "poll"
    assert config.filename_prefix == "date_sender"


def test_missing_required_variable_is_reported(monkeypatch):
    _env(monkeypatch)
    monkeypatch.delenv("IMAP_PASSWORD")

    with pytest.raises(SystemExit, match="IMAP_PASSWORD"):
        Config.from_env()


@pytest.mark.parametrize("value", ["not-a-number", "", "12.5"])
def test_non_numeric_int_setting_is_rejected_clearly(monkeypatch, value):
    _env(monkeypatch, MAX_ATTACHMENT_SIZE_MB=value)

    with pytest.raises(SystemExit, match="MAX_ATTACHMENT_SIZE_MB"):
        Config.from_env()


@pytest.mark.parametrize("value", ["0", "-5"])
def test_non_positive_limits_are_rejected(monkeypatch, value):
    _env(monkeypatch, MAX_MESSAGE_SIZE_MB=value)

    with pytest.raises(SystemExit, match="MAX_MESSAGE_SIZE_MB"):
        Config.from_env()


@pytest.mark.parametrize("value", ["0", "70000"])
def test_port_out_of_range_is_rejected(monkeypatch, value):
    _env(monkeypatch, IMAP_PORT=value)

    with pytest.raises(SystemExit, match="IMAP_PORT"):
        Config.from_env()


def test_typo_in_imap_mode_fails_instead_of_silently_polling(monkeypatch):
    _env(monkeypatch, IMAP_MODE="idel")

    with pytest.raises(SystemExit, match="IMAP_MODE"):
        Config.from_env()


def test_typo_in_filename_prefix_fails(monkeypatch):
    _env(monkeypatch, FILENAME_PREFIX="date-sender")

    with pytest.raises(SystemExit, match="FILENAME_PREFIX"):
        Config.from_env()


def test_imap_mode_is_case_insensitive(monkeypatch):
    _env(monkeypatch, IMAP_MODE="IDLE")

    assert Config.from_env().imap_mode == "idle"


# --- storage backend ----------------------------------------------------------

SMB = {
    "STORAGE_BACKEND": "smb",
    "SMB_HOST": "nas.local",
    "SMB_SHARE": "Belege",
    "SMB_USER": "mail2nas",
    "SMB_PASSWORD": "secret",
}


def test_backend_defaults_to_local_so_existing_installs_keep_working(monkeypatch):
    _env(monkeypatch)

    config = Config.from_env()

    assert config.storage_backend == "local"
    assert config.storage_root == "/mnt/nas"


def test_smb_backend_loads_its_settings(monkeypatch):
    _env(monkeypatch, **SMB, SMB_ROOT="archiv/2026", SMB_DOMAIN="WORKGROUP")

    config = Config.from_env()

    assert config.storage_backend == "smb"
    assert (config.smb_host, config.smb_share) == ("nas.local", "Belege")
    assert config.smb_root == "archiv/2026"
    assert config.smb_domain == "WORKGROUP"
    assert config.smb_port == 445
    assert config.smb_encrypt is True


@pytest.mark.parametrize("missing", ["SMB_HOST", "SMB_SHARE", "SMB_USER", "SMB_PASSWORD"])
def test_smb_backend_reports_the_missing_setting(monkeypatch, missing):
    _env(monkeypatch, **SMB)
    monkeypatch.delenv(missing)

    with pytest.raises(SystemExit, match=missing):
        Config.from_env()


def test_local_backend_does_not_require_smb_settings(monkeypatch):
    _env(monkeypatch, STORAGE_BACKEND="local")

    assert Config.from_env().smb_host == ""


def test_unknown_backend_is_rejected(monkeypatch):
    _env(monkeypatch, STORAGE_BACKEND="nfs")

    with pytest.raises(SystemExit, match="STORAGE_BACKEND"):
        Config.from_env()


def test_empty_smb_root_means_the_share_root(monkeypatch):
    _env(monkeypatch, **SMB, SMB_ROOT="")

    assert Config.from_env().smb_root == ""


@pytest.mark.parametrize("value", ["../etc", "/etc", ".."])
def test_smb_root_cannot_escape_the_share(monkeypatch, value):
    _env(monkeypatch, **SMB, SMB_ROOT=value)

    with pytest.raises(SystemExit, match="SMB_ROOT"):
        Config.from_env()


@pytest.mark.parametrize("value", ["../mapping.yaml", "/etc/passwd"])
def test_mapping_path_cannot_escape_the_archive_root(monkeypatch, value):
    _env(monkeypatch, MAPPING_PATH=value)

    with pytest.raises(SystemExit, match="MAPPING_PATH"):
        Config.from_env()
MAIL2NAS_EOF

# --- tests/test_storage.py ---
cat > tests/test_storage.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import errno
import os

import pytest

from mail2nas.storage import LocalStorage, SmbStorage, from_config
from tests.test_archiver import _make_config


# --- local backend ------------------------------------------------------------


def test_accepts_a_writable_storage_root(tmp_path):
    LocalStorage(str(tmp_path)).check_writable()


def test_missing_storage_root_fails_fast(tmp_path):
    """An unmounted share must not be mistaken for an empty one."""
    with pytest.raises(SystemExit, match="does not exist"):
        LocalStorage(str(tmp_path / "not-mounted")).check_writable()


def test_storage_root_that_is_a_file_fails_fast(tmp_path):
    a_file = tmp_path / "afile"
    a_file.write_text("x", encoding="utf-8")

    with pytest.raises(SystemExit, match="does not exist or is not a directory"):
        LocalStorage(str(a_file)).check_writable()


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_read_only_storage_root_fails_fast(tmp_path):
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)
    try:
        with pytest.raises(SystemExit, match="not writable"):
            LocalStorage(str(readonly)).check_writable()
    finally:
        readonly.chmod(0o700)


def test_local_save_unique_creates_directories_and_avoids_overwriting(tmp_path):
    storage = LocalStorage(str(tmp_path))

    first = storage.save_unique(("rechnungen", "2026"), "beleg.pdf", b"one")
    second = storage.save_unique(("rechnungen", "2026"), "beleg.pdf", b"two")

    assert first != second
    assert (tmp_path / "rechnungen" / "2026" / "beleg.pdf").read_bytes() == b"one"
    assert (tmp_path / "rechnungen" / "2026" / "beleg_1.pdf").read_bytes() == b"two"


def test_local_read_text_and_modified_time(tmp_path):
    storage = LocalStorage(str(tmp_path))
    (tmp_path / "mapping.yaml").write_text("RE: rechnungen\n", encoding="utf-8")

    assert storage.read_text("mapping.yaml") == "RE: rechnungen\n"
    assert storage.modified_time("mapping.yaml") > 0

    with pytest.raises(FileNotFoundError):
        storage.modified_time("nope.yaml")


# --- SMB backend: path building (no server involved) --------------------------


def _smb(**overrides) -> SmbStorage:
    defaults = dict(host="nas.local", share="Belege", user="mail2nas", password="secret")
    defaults.update(overrides)
    return SmbStorage(**defaults)


def test_smb_builds_unc_paths():
    storage = _smb()

    assert storage._unc(("rechnungen", "2026"), "beleg.pdf") == (
        "\\\\nas.local\\Belege\\rechnungen\\2026\\beleg.pdf"
    )
    assert storage._unc(()) == "\\\\nas.local\\Belege"


def test_smb_root_prefixes_every_path():
    storage = _smb(root="archiv/2026")

    assert storage._unc(("rechnungen",)) == "\\\\nas.local\\Belege\\archiv\\2026\\rechnungen"
    assert storage.description == "//nas.local/Belege/archiv/2026"


def test_smb_display_uses_forward_slashes():
    assert _smb().display(("rechnungen",), "beleg.pdf") == "//nas.local/Belege/rechnungen/beleg.pdf"


def test_smb_root_cannot_escape_the_share():
    with pytest.raises(ValueError):
        _smb(root="../../etc")


# --- SMB backend: reconnect behaviour -----------------------------------------


def test_smb_retries_once_on_a_failed_call(monkeypatch):
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    monkeypatch.setattr(storage, "_reset", lambda: None)
    attempts = []

    def flaky():
        attempts.append(1)
        if len(attempts) == 1:
            raise OSError(errno.ECONNRESET, "connection reset")
        return "ok"

    assert storage._with_reconnect("write", flaky) == "ok"
    assert len(attempts) == 2


def test_smb_missing_file_is_reported_as_filenotfound_without_retrying(monkeypatch):
    """The mapping file may legitimately not exist - that is not a broken session."""
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    attempts = []

    def missing():
        attempts.append(1)
        raise OSError(errno.ENOENT, "no such file")

    with pytest.raises(FileNotFoundError):
        storage._with_reconnect("stat", missing)
    assert len(attempts) == 1


def test_smb_reraises_when_the_retry_also_fails(monkeypatch):
    storage = _smb()
    monkeypatch.setattr(storage, "_connect", lambda: None)
    monkeypatch.setattr(storage, "_reset", lambda: None)

    def always_broken():
        raise OSError(errno.EACCES, "permission denied")

    with pytest.raises(OSError, match="permission denied"):
        storage._with_reconnect("write", always_broken)


# --- backend selection ---------------------------------------------------------


def test_from_config_selects_the_configured_backend(tmp_path):
    local = from_config(_make_config(tmp_path, storage_backend="local"))
    assert isinstance(local, LocalStorage)

    smb = from_config(
        _make_config(
            tmp_path,
            storage_backend="smb",
            smb_host="nas.local",
            smb_share="Belege",
            smb_user="u",
            smb_password="p",
        )
    )
    assert isinstance(smb, SmbStorage)
    assert smb.description == "//nas.local/Belege"
MAIL2NAS_EOF

# --- tests/test_web.py ---
cat > tests/test_web.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import re

import pytest

from mail2nas.accounts import AccountStore
from mail2nas.mapping import Mapping, Rule, load_rules, save_rules
from mail2nas.printers import PrinterStore
from mail2nas.printing import from_config as printing_from_config
from mail2nas.runtime import Runtime
from mail2nas.state import ProcessedStore, SettingsStore
from mail2nas.storage import LocalStorage
from mail2nas.web import (
    SETTING_PASSWORD_HASH,
    LoginThrottle,
    create_app,
    ensure_password,
)
from tests.test_archiver import _make_config

PASSWORD = "geheim1234"


@pytest.fixture
def env(tmp_path):
    """A configured app plus the storage and settings behind it."""
    config = _make_config(tmp_path, web_enabled=True, web_password=PASSWORD)
    storage = LocalStorage(config.storage_root)
    settings = SettingsStore(config.state_db_path)
    accounts = AccountStore(config.state_db_path)
    mapping = Mapping(storage, config.mapping_path, config.fallback_folder)
    printers = PrinterStore(config.state_db_path)
    runtime = Runtime(
        config,
        storage,
        mapping,
        ProcessedStore(config.state_db_path),
        settings,
        accounts,
        printers=printers,
        printing=printing_from_config(config, printers),
    )
    ensure_password(settings, config.web_password)
    app = create_app(runtime)
    app.config.update(TESTING=True)
    return app, storage, settings, config, runtime


@pytest.fixture
def client(env):
    app = env[0]
    with app.test_client() as client:
        yield client


def _csrf(client, path="/login") -> str:
    """Fetch a page and pull the CSRF token out of it, like a browser would."""
    html = client.get(path).get_data(as_text=True)
    match = re.search(r'name="csrf_token" value="([^"]+)"', html)
    assert match, f"no CSRF token on {path}"
    return match.group(1)


def _login(client, password=PASSWORD):
    return client.post(
        "/login",
        data={"password": password, "csrf_token": _csrf(client)},
        follow_redirects=False,
    )


# --- authentication -----------------------------------------------------------


def test_mapping_page_requires_login(client):
    response = client.get("/mapping")

    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_login_with_correct_password_reaches_the_mapping_page(client):
    assert _login(client).status_code == 302

    page = client.get("/mapping")
    assert page.status_code == 200
    assert "Zuordnungen" in page.get_data(as_text=True)


def test_login_with_wrong_password_is_rejected(client):
    response = client.post(
        "/login", data={"password": "falsch", "csrf_token": _csrf(client)}
    )

    assert response.status_code == 401
    assert client.get("/mapping").status_code == 302


def test_post_without_csrf_token_is_refused(client):
    _login(client)

    response = client.post("/mapping/add", data={"keyword": "RE", "folder": "rechnungen"})

    assert response.status_code == 400


def test_logout_ends_the_session(client):
    _login(client)
    token = _csrf(client, "/mapping")

    client.post("/logout", data={"csrf_token": token})

    assert client.get("/mapping").status_code == 302


def test_healthz_needs_no_login(client):
    response = client.get("/healthz")

    assert response.status_code == 200
    assert response.get_data(as_text=True).strip() == "ok"


def test_security_headers_are_set(client):
    headers = client.get("/login").headers

    assert "default-src 'none'" in headers["Content-Security-Policy"]
    assert headers["X-Frame-Options"] == "DENY"


# --- editing the mapping -------------------------------------------------------


def test_adding_a_rule_writes_it_to_the_share(client, env):
    _, storage, _, config, runtime = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "Rechnung", "folder": "", "new_folder": "rechnungen",
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert [(r.keyword, r.folder) for r in load_rules(storage, config.mapping_path)] == [
        ("Rechnung", "rechnungen")
    ]


def test_a_new_folder_is_created_on_the_share(client, env, tmp_path):
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "RE", "new_folder": "rechnungen/2026",
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert (tmp_path / "rechnungen" / "2026").is_dir()


def test_existing_folders_are_offered_for_selection(client, tmp_path):
    (tmp_path / "lieferscheine").mkdir()
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert '<option value="lieferscheine">' in html


def test_duplicate_keyword_is_rejected_case_insensitively(client, env):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    response = client.post(
        "/mapping/add",
        data={"keyword": "re", "new_folder": "woanders",
              "csrf_token": _csrf(client, "/mapping")},
        follow_redirects=True,
    )

    assert "gibt es schon" in response.get_data(as_text=True)
    assert [(r.keyword, r.folder) for r in load_rules(storage, config.mapping_path)] == [
        ("RE", "rechnungen")
    ]


@pytest.mark.parametrize("folder", ["../ausbruch", "/etc", ""])
def test_target_folder_cannot_escape_the_archive_root(client, env, folder, tmp_path):
    _, storage, _, config, runtime = env
    _login(client)

    client.post(
        "/mapping/add",
        data={"keyword": "RE", "new_folder": folder,
              "csrf_token": _csrf(client, "/mapping")},
    )

    assert load_rules(storage, config.mapping_path) == []
    assert not (tmp_path.parent / "ausbruch").exists()


def test_changing_the_folder_of_an_existing_rule(client, env):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    client.post(
        "/mapping/update",
        data={"index": "0", "folder": "belege", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [(r.keyword, r.folder) for r in load_rules(storage, config.mapping_path)] == [
        ("RE", "belege")
    ]


def test_deleting_a_rule_keeps_the_others(client, env):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path,
               [Rule.create("RE", "rechnungen"), Rule.create("LS", "lieferscheine")])
    _login(client)

    client.post(
        "/mapping/delete",
        data={"index": "0", "csrf_token": _csrf(client, "/mapping")},
    )

    assert [r.keyword for r in load_rules(storage, config.mapping_path)] == ["LS"]


def test_unreadable_share_does_not_break_the_page(client, env, monkeypatch):
    """A NAS that is briefly away must still render, with an explanation."""
    _, storage, _, _, runtime = env
    _login(client)
    monkeypatch.setattr(
        storage, "list_folders", lambda *a, **k: (_ for _ in ()).throw(OSError("NAS weg"))
    )

    response = client.get("/mapping")

    assert response.status_code == 200
    assert "NAS weg" in response.get_data(as_text=True)


# --- password handling ----------------------------------------------------------


def test_password_can_be_changed_and_the_old_one_stops_working(client, env):
    _, _, settings, _, runtime = env
    _login(client)

    response = client.post(
        "/password",
        data={"current": PASSWORD, "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(client, "/password")},
        follow_redirects=True,
    )

    assert "Passwort geaendert" in response.get_data(as_text=True)
    client.post("/logout", data={"csrf_token": _csrf(client, "/mapping")})
    assert _login(client, PASSWORD).status_code == 401
    assert _login(client, "neuesGeheim1").status_code == 302


def test_wrong_current_password_does_not_change_anything(client, env):
    _, _, settings, _, runtime = env
    before = settings.get(SETTING_PASSWORD_HASH)
    _login(client)

    client.post(
        "/password",
        data={"current": "falsch", "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(client, "/password")},
    )

    assert settings.get(SETTING_PASSWORD_HASH) == before


@pytest.mark.parametrize(
    "new,confirm,expected",
    [("kurz", "kurz", "mindestens"), ("langgenug1", "andersrum", "ueberein")],
)
def test_weak_or_mistyped_new_password_is_rejected(client, env, new, confirm, expected):
    _, _, settings, _, runtime = env
    before = settings.get(SETTING_PASSWORD_HASH)
    _login(client)

    response = client.post(
        "/password",
        data={"current": PASSWORD, "new": new, "confirm": confirm,
              "csrf_token": _csrf(client, "/password")},
        follow_redirects=True,
    )

    assert expected in response.get_data(as_text=True)
    assert settings.get(SETTING_PASSWORD_HASH) == before


def test_changing_the_password_logs_other_sessions_out(env):
    """A stolen session cookie must not survive a password change."""
    app = env[0]
    # Two plain clients rather than nested `with` blocks: overlapping request
    # contexts confuse Flask's teardown, and no session inspection is needed.
    first, second = app.test_client(), app.test_client()
    _login(first)
    _login(second)
    assert second.get("/mapping").status_code == 200

    first.post(
        "/password",
        data={"current": PASSWORD, "new": "neuesGeheim1", "confirm": "neuesGeheim1",
              "csrf_token": _csrf(first, "/password")},
    )

    assert second.get("/mapping").status_code == 302
    assert first.get("/mapping").status_code == 200


def test_password_is_not_stored_in_clear_text(env):
    _, _, settings, _, runtime = env

    stored = settings.get(SETTING_PASSWORD_HASH)

    assert PASSWORD not in stored
    assert stored.startswith("scrypt:") or stored.startswith("pbkdf2:")


def test_enabling_the_ui_without_a_password_fails_fast(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))

    with pytest.raises(SystemExit, match="WEB_PASSWORD"):
        ensure_password(settings, "")


def test_too_short_initial_password_fails_fast(tmp_path):
    settings = SettingsStore(str(tmp_path / "state.db"))

    with pytest.raises(SystemExit, match="at least"):
        ensure_password(settings, "kurz")


def test_stored_password_wins_over_the_configured_one(env):
    """WEB_PASSWORD is the initial value only - a later change must survive restarts."""
    _, _, settings, _, runtime = env
    settings.set(SETTING_PASSWORD_HASH, "scrypt:already-set")

    ensure_password(settings, "eineAndere123")

    assert settings.get(SETTING_PASSWORD_HASH) == "scrypt:already-set"


# --- login throttling -------------------------------------------------------------


def test_throttle_blocks_after_repeated_failures():
    throttle = LoginThrottle(max_failures=3, lockout=60)

    for _ in range(2):
        throttle.record_failure("10.0.0.1")
    assert throttle.seconds_blocked("10.0.0.1") == 0

    throttle.record_failure("10.0.0.1")
    assert throttle.seconds_blocked("10.0.0.1") > 0
    assert throttle.seconds_blocked("10.0.0.2") == 0


def test_successful_login_clears_the_throttle():
    throttle = LoginThrottle(max_failures=1, lockout=60)
    throttle.record_failure("10.0.0.1")

    throttle.reset("10.0.0.1")

    assert throttle.seconds_blocked("10.0.0.1") == 0


def test_locked_out_client_is_refused_even_with_the_right_password(client, env):
    for _ in range(6):
        client.post("/login", data={"password": "falsch", "csrf_token": _csrf(client)})

    response = client.post(
        "/login", data={"password": PASSWORD, "csrf_token": _csrf(client)}
    )

    assert response.status_code == 429
    assert client.get("/mapping").status_code == 302


# --- rule order ------------------------------------------------------------------


def _keywords(storage, config):
    return [rule.keyword for rule in load_rules(storage, config.mapping_path)]


def test_moving_a_rule_up_reorders_the_file(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path,
               [Rule.create("A", "a"), Rule.create("B", "b"), Rule.create("C", "c")])
    _login(client)

    client.post("/mapping/up", data={"index": "2", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A", "C", "B"]


def test_moving_a_rule_down_reorders_the_file(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/down", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["B", "A"]


def test_moving_the_top_rule_up_is_harmless(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    client.post("/mapping/up", data={"index": "0", "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A", "B"]


@pytest.mark.parametrize("index", ["7", "-1", "keineZahl"])
def test_a_bogus_row_index_is_refused(client, env, index):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/delete", data={"index": index, "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A"]


def test_new_rules_are_appended_at_the_bottom(client, env):
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a")])
    _login(client)

    client.post("/mapping/add", data={"keyword": "B", "new_folder": "b",
                                      "csrf_token": _csrf(client, "/mapping")})

    assert _keywords(storage, config) == ["A", "B"]


# --- accounts ---------------------------------------------------------------------


def _add_account(runtime, **fields):
    defaults = dict(name="Buchhaltung", host="imap.example.com", user="u", password="p")
    defaults.update(fields)
    return runtime.accounts.add(**defaults)


def test_config_page_lists_the_accounts(client, env):
    _, _, _, _, runtime = env
    _add_account(runtime)
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Buchhaltung" in html
    assert "imap.example.com" in html


def test_creating_an_account_through_the_form(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/accounts/new", data={
        "name": "Zweitpostfach", "host": "imap2.example.com", "port": "143",
        "user": "zwei", "password": "geheim", "folder": "INBOX", "mode": "poll",
        "processed_folder": "", "oversized_folder": "", "enabled": "1",
        "csrf_token": _csrf(client, "/config/accounts/new")})

    accounts = runtime.accounts.all()
    assert [a.name for a in accounts] == ["Zweitpostfach"]
    assert accounts[0].port == 143 and accounts[0].ssl is False


def test_editing_an_account_keeps_the_password_when_left_empty(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime, password="altesGeheim")
    _login(client)

    client.post(f"/config/accounts/{account_id}", data={
        "name": "Neuer Name", "host": "imap.example.com", "port": "993",
        "user": "u", "password": "", "folder": "INBOX", "mode": "idle",
        "ssl": "1", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")})

    account = runtime.accounts.get(account_id)
    assert account.password == "altesGeheim"
    assert account.name == "Neuer Name" and account.mode == "idle"


def test_an_invalid_port_is_rejected(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}", data={
        "name": "A", "host": "h", "port": "keinPort", "user": "u", "password": "",
        "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")},
        follow_redirects=True)

    assert "Port" in response.get_data(as_text=True)
    assert runtime.accounts.get(account_id).host == "imap.example.com"


def test_deleting_an_account(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime)
    _login(client)

    client.post(f"/config/accounts/{account_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.accounts.all() == []


def test_a_rule_can_be_bound_to_an_account(client, env):
    _, storage, _, config, runtime = env
    account_id = _add_account(runtime)
    _add_account(runtime, name="Zweites")
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "account": str(account_id),
        "csrf_token": _csrf(client, "/mapping")})

    assert load_rules(storage, config.mapping_path)[0].account == str(account_id)


def test_a_rule_cannot_reference_an_unknown_account(client, env):
    _, storage, _, config, runtime = env
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "account": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert load_rules(storage, config.mapping_path) == []


# --- moving the mapping file --------------------------------------------------------


def test_moving_the_mapping_file_takes_the_rules_along(client, env, tmp_path):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    client.post("/config/mapping-path",
                data={"mapping_path": "config/regeln.yaml", "csrf_token": _csrf(client, "/config")})

    assert runtime.mapping_path == "config/regeln.yaml"
    assert [r.keyword for r in load_rules(storage, "config/regeln.yaml")] == ["RE"]
    assert not (tmp_path / "mapping.yaml").exists()


def test_the_mapping_path_cannot_escape_the_archive_root(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/mapping-path",
                data={"mapping_path": "../woanders.yaml", "csrf_token": _csrf(client, "/config")})

    assert runtime.mapping_path == "mapping.yaml"


def test_moving_to_the_same_path_is_a_no_op(client, env):
    _, storage, _, config, runtime = env
    save_rules(storage, config.mapping_path, [Rule.create("RE", "rechnungen")])
    _login(client)

    client.post("/config/mapping-path",
                data={"mapping_path": "mapping.yaml", "csrf_token": _csrf(client, "/config")})

    assert [r.keyword for r in load_rules(storage, "mapping.yaml")] == ["RE"]


def test_reordering_without_a_csrf_token_is_refused(client, env):
    """The arrows go through a helper, so their CSRF check needs its own test."""
    _, storage, _, config, _ = env
    save_rules(storage, config.mapping_path, [Rule.create("A", "a"), Rule.create("B", "b")])
    _login(client)

    response = client.post("/mapping/up", data={"index": "1"})

    assert response.status_code == 400
    assert _keywords(storage, config) == ["A", "B"]


def test_the_stored_account_password_is_never_sent_to_the_browser(client, env):
    _, _, _, _, runtime = env
    account_id = _add_account(runtime, password="streng-geheim")
    _login(client)

    html = client.get(f"/config/accounts/{account_id}").get_data(as_text=True)

    assert "streng-geheim" not in html


# --- printers -----------------------------------------------------------------------


def _add_printer(runtime, **fields):
    defaults = dict(name="Buero EG", destination="Kyocera_M2540")
    defaults.update(fields)
    return runtime.printers.add(**defaults)


def test_config_page_lists_the_printers(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime, server="cups.lan:631")
    _login(client)

    html = client.get("/config").get_data(as_text=True)

    assert "Buero EG" in html
    assert "Kyocera_M2540" in html
    assert "cups.lan:631" in html


def test_creating_a_printer_through_the_form(client, env):
    _, _, _, _, runtime = env
    _login(client)

    client.post("/config/printers/new", data={
        "name": "Buchhaltung", "destination": "HP_LJ", "server": "", "copies": "2",
        "options": "media=A4 sides=two-sided-long-edge", "enabled": "1",
        "csrf_token": _csrf(client, "/config/printers/new")})

    printers = runtime.printers.all()
    assert [(p.name, p.destination, p.copies) for p in printers] == [("Buchhaltung", "HP_LJ", 2)]
    assert printers[0].option_list == ["media=A4", "sides=two-sided-long-edge"]


def test_an_unusable_queue_name_is_rejected_with_a_message(client, env):
    _, _, _, _, runtime = env
    _login(client)

    response = client.post("/config/printers/new", data={
        "name": "Kaputt", "destination": "zwei woerter", "copies": "1", "enabled": "1",
        "csrf_token": _csrf(client, "/config/printers/new")}, follow_redirects=True)

    assert "Leerzeichen" in response.get_data(as_text=True)
    assert runtime.printers.all() == []


def test_editing_a_printer(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post(f"/config/printers/{printer_id}", data={
        "name": "Buero OG", "destination": "Kyocera_M2540", "copies": "1", "enabled": "",
        "csrf_token": _csrf(client, f"/config/printers/{printer_id}")})

    printer = runtime.printers.get(printer_id)
    assert printer.name == "Buero OG"
    assert printer.enabled is False


def test_deleting_a_printer(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post(f"/config/printers/{printer_id}/delete",
                data={"csrf_token": _csrf(client, "/config")})

    assert runtime.printers.all() == []


def test_a_test_print_reports_a_failing_queue(client, env, monkeypatch):
    import subprocess

    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)
    monkeypatch.setattr(
        subprocess,
        "run",
        lambda *a, **k: subprocess.CompletedProcess([], 1, "", "lp: Kein Drucker"),
    )

    response = client.post(
        f"/config/printers/{printer_id}/test",
        data={"csrf_token": _csrf(client, f"/config/printers/{printer_id}")},
        follow_redirects=True,
    )

    assert "Testdruck fehlgeschlagen" in response.get_data(as_text=True)


def test_a_test_print_confirms_a_working_queue(client, env, monkeypatch):
    import subprocess

    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)
    monkeypatch.setattr(
        subprocess, "run", lambda *a, **k: subprocess.CompletedProcess([], 0, "request id is q-1", "")
    )

    response = client.post(
        f"/config/printers/{printer_id}/test",
        data={"csrf_token": _csrf(client, f"/config/printers/{printer_id}")},
        follow_redirects=True,
    )

    assert "Testseite" in response.get_data(as_text=True)


def test_the_print_settings_of_a_mailbox_are_saved(client, env):
    _, _, _, _, runtime = env
    printer_id = _add_printer(runtime)
    account_id = _add_account(runtime)
    _login(client)

    client.post(f"/config/accounts/{account_id}", data={
        "name": "Buchhaltung", "host": "imap.example.com", "port": "993", "user": "u",
        "password": "", "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "print_fields": "1", "print_attachments": "1", "printer": str(printer_id),
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")})

    account = runtime.accounts.get(account_id)
    assert account.print_attachments is True
    assert account.printer == str(printer_id)
    # the "archive" box was not ticked, so this mailbox prints only
    assert account.archive_attachments is False


def test_a_mailbox_cannot_reference_an_unknown_printer(client, env):
    _, _, _, _, runtime = env
    _add_printer(runtime)
    account_id = _add_account(runtime)
    _login(client)

    response = client.post(f"/config/accounts/{account_id}", data={
        "name": "Buchhaltung", "host": "imap.example.com", "port": "993", "user": "u",
        "password": "", "folder": "INBOX", "mode": "poll", "ssl": "1", "enabled": "1",
        "print_fields": "1", "print_attachments": "1", "printer": "999",
        "csrf_token": _csrf(client, f"/config/accounts/{account_id}")}, follow_redirects=True)

    assert "Drucker" in response.get_data(as_text=True)
    assert runtime.accounts.get(account_id).print_attachments is False


def test_a_rule_can_be_set_to_print_on_a_specific_printer(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": str(printer_id),
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.print_attachments is True
    assert rule.printer == str(printer_id)


def test_a_rule_can_print_on_the_mailbox_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "account",
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.print_attachments is True
    assert rule.printer == ""


def test_a_rule_cannot_reference_an_unknown_printer(client, env):
    _, storage, _, config, runtime = env
    _add_printer(runtime)
    _login(client)

    client.post("/mapping/add", data={
        "keyword": "Rechnung", "new_folder": "rechnungen", "printer": "999",
        "csrf_token": _csrf(client, "/mapping")})

    assert load_rules(storage, config.mapping_path) == []


def test_changing_a_rules_folder_keeps_its_print_settings(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    save_rules(storage, config.mapping_path,
               [Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "belege", "print_fields": "1", "printer": str(printer_id),
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.folder == "belege"
    assert (rule.print_attachments, rule.printer) == (True, str(printer_id))


def test_printing_can_be_switched_off_for_a_rule(client, env):
    _, storage, _, config, runtime = env
    printer_id = _add_printer(runtime)
    save_rules(storage, config.mapping_path,
               [Rule.create("RE", "rechnungen", "all", True, str(printer_id))])
    _login(client)

    client.post("/mapping/update", data={
        "index": "0", "folder": "rechnungen", "print_fields": "1", "printer": "",
        "csrf_token": _csrf(client, "/mapping")})

    rule = load_rules(storage, config.mapping_path)[0]
    assert rule.print_attachments is False
    assert rule.printer == ""


def test_without_a_printer_the_print_controls_stay_hidden(client, env):
    _login(client)

    html = client.get("/mapping").get_data(as_text=True)

    assert "nicht drucken" not in html
MAIL2NAS_EOF

# --- tests/test_accounts.py ---
cat > tests/test_accounts.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.accounts import SETTING_ACCOUNTS_SEEDED, AccountStore, seed_from_config
from mail2nas.state import SettingsStore
from tests.test_archiver import _make_config


@pytest.fixture
def store(tmp_path):
    return AccountStore(str(tmp_path / "state.db"))


def test_add_and_read_back_an_account(store):
    account_id = store.add(name="Buchhaltung", host="imap.example.com", user="u", password="p")

    account = store.get(account_id)

    assert account.name == "Buchhaltung"
    assert account.port == 993 and account.ssl is True
    assert account.folder == "INBOX" and account.enabled is True
    assert account.key == str(account_id)


def test_update_changes_only_what_is_passed(store):
    account_id = store.add(name="A", host="h", user="u", password="p", folder="Archiv")

    store.update(account_id, name="B")

    account = store.get(account_id)
    assert account.name == "B"
    assert account.folder == "Archiv" and account.password == "p"


def test_disabled_accounts_are_not_watched(store):
    store.add(name="An", host="h", user="u", password="p")
    store.add(name="Aus", host="h", user="u", password="p", enabled=False)

    assert [a.name for a in store.enabled()] == ["An"]
    assert len(store.all()) == 2


def test_delete_removes_the_account(store):
    account_id = store.add(name="A", host="h", user="u", password="p")

    store.delete(account_id)

    assert store.get(account_id) is None


def test_an_unknown_mode_falls_back_to_polling(store):
    account_id = store.add(name="A", host="h", user="u", password="p", mode="bogus")

    assert store.get(account_id).mode == "poll"


def test_fingerprint_changes_when_settings_change(store):
    account_id = store.add(name="A", host="h", user="u", password="p")
    before = store.get(account_id).fingerprint()

    store.update(account_id, password="neu")

    assert store.get(account_id).fingerprint() != before


def test_renaming_does_not_restart_the_worker(store):
    """The name is cosmetic - changing it must not drop an IMAP connection."""
    account_id = store.add(name="A", host="h", user="u", password="p")
    before = store.get(account_id).fingerprint()

    store.update(account_id, name="Anders")

    assert store.get(account_id).fingerprint() == before


# --- seeding from the environment ------------------------------------------------


def test_the_first_account_is_created_from_the_configuration(tmp_path):
    config = _make_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)

    seed_from_config(store, settings, config)

    accounts = store.all()
    assert len(accounts) == 1
    assert accounts[0].host == config.imap_host
    assert accounts[0].user == config.imap_user


def test_seeding_happens_only_once(tmp_path):
    config = _make_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)

    seed_from_config(store, settings, config)

    assert len(store.all()) == 1


def test_deleting_the_last_account_does_not_resurrect_it_from_the_env(tmp_path):
    """Otherwise removing a mailbox in the UI would silently come back."""
    config = _make_config(tmp_path)
    store = AccountStore(config.state_db_path)
    settings = SettingsStore(config.state_db_path)
    seed_from_config(store, settings, config)
    store.delete(store.all()[0].id)

    seed_from_config(store, settings, config)

    assert store.all() == []
    assert settings.get(SETTING_ACCOUNTS_SEEDED) == "1"
MAIL2NAS_EOF

# --- tests/test_printers.py ---
cat > tests/test_printers.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import sqlite3

import pytest

from mail2nas.accounts import AccountStore
from mail2nas.printers import (
    PrinterError,
    PrinterStore,
    seed_from_config,
)
from mail2nas.state import SettingsStore
from tests.test_archiver import _make_config


@pytest.fixture
def store(tmp_path):
    return PrinterStore(str(tmp_path / "state.db"))


def _add(store, **overrides) -> int:
    fields = {"name": "Buero", "destination": "Kyocera_M2540"}
    fields.update(overrides)
    return store.add(**fields)


# --- storage ------------------------------------------------------------------


def test_add_and_read_back_a_printer(store):
    printer_id = _add(store, server="cups.lan:631", options="media=A4", copies=2)

    printer = store.get(printer_id)

    assert (printer.name, printer.destination) == ("Buero", "Kyocera_M2540")
    assert (printer.server, printer.options, printer.copies) == ("cups.lan:631", "media=A4", 2)
    assert printer.enabled is True


def test_update_changes_only_what_is_passed(store):
    printer_id = _add(store, options="media=A4")

    store.update(printer_id, name="Buchhaltung")

    printer = store.get(printer_id)
    assert printer.name == "Buchhaltung"
    assert printer.options == "media=A4"


def test_paused_printers_are_kept_but_not_offered(store):
    _add(store, name="Aktiv")
    _add(store, name="Pausiert", enabled=False)

    assert [p.name for p in store.all()] == ["Aktiv", "Pausiert"]
    assert [p.name for p in store.enabled()] == ["Aktiv"]


def test_delete_removes_the_printer(store):
    printer_id = _add(store)

    store.delete(printer_id)

    assert store.get(printer_id) is None


def test_lookup_by_the_key_a_rule_stores(store):
    printer_id = _add(store)

    assert store.by_key(str(printer_id)).id == printer_id
    assert store.by_key("") is None
    assert store.by_key("keine-zahl") is None
    assert store.by_key("9999") is None


def test_options_are_split_into_separate_arguments(store):
    printer = store.get(_add(store, options="media=A4  sides=two-sided-long-edge"))

    assert printer.option_list == ["media=A4", "sides=two-sided-long-edge"]


# --- validation ---------------------------------------------------------------


def test_a_queue_name_is_required(store):
    with pytest.raises(PrinterError):
        store.add(name="Ohne Ziel", destination="")


@pytest.mark.parametrize("destination", ["zwei woerter", "-d"])
def test_an_unusable_queue_name_is_refused(store, destination):
    with pytest.raises(PrinterError):
        _add(store, destination=destination)


def test_an_option_that_looks_like_a_flag_is_refused(store):
    # "-o media=A4" would be passed on as two arguments and silently do
    # something else than what was typed.
    with pytest.raises(PrinterError):
        _add(store, options="-o media=A4")


@pytest.mark.parametrize("copies", ["null", "0", "999"])
def test_an_unusable_copy_count_is_refused(store, copies):
    with pytest.raises(PrinterError):
        _add(store, copies=copies)


def test_the_name_defaults_to_the_queue(store):
    printer = store.get(_add(store, name=""))

    assert printer.name == "Kyocera_M2540"


# --- seeding from the environment ---------------------------------------------


def _seed_env(tmp_path, **overrides):
    config = _make_config(tmp_path, **overrides)
    settings = SettingsStore(config.state_db_path)
    store = PrinterStore(config.state_db_path)
    seed_from_config(store, settings, config)
    return store


def test_the_first_printer_is_created_from_the_configuration(tmp_path):
    store = _seed_env(
        tmp_path, printer_destination="Kyocera_M2540", printer_name="Buero", printer_copies=2
    )

    assert [(p.name, p.destination, p.copies) for p in store.all()] == [
        ("Buero", "Kyocera_M2540", 2)
    ]


def test_nothing_is_created_without_a_configured_queue(tmp_path):
    assert _seed_env(tmp_path).all() == []


def test_deleting_the_seeded_printer_does_not_resurrect_it(tmp_path):
    config = _make_config(tmp_path, printer_destination="Kyocera_M2540")
    settings = SettingsStore(config.state_db_path)
    store = PrinterStore(config.state_db_path)
    seed_from_config(store, settings, config)
    store.delete(store.all()[0].id)

    seed_from_config(store, settings, config)

    assert store.all() == []


# --- upgrading an existing installation ---------------------------------------


def test_printing_columns_are_added_to_an_existing_account_table(tmp_path):
    """An update must not require re-entering every mailbox."""
    db_path = str(tmp_path / "state.db")
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            "CREATE TABLE imap_accounts ("
            "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, host TEXT NOT NULL, "
            "port INTEGER NOT NULL DEFAULT 993, ssl INTEGER NOT NULL DEFAULT 1, "
            "user TEXT NOT NULL, password TEXT NOT NULL, folder TEXT NOT NULL DEFAULT 'INBOX', "
            "mode TEXT NOT NULL DEFAULT 'poll', processed_folder TEXT NOT NULL DEFAULT '', "
            "oversized_folder TEXT NOT NULL DEFAULT '', enabled INTEGER NOT NULL DEFAULT 1)"
        )
        conn.execute(
            "INSERT INTO imap_accounts (name, host, user, password) VALUES ('Alt', 'h', 'u', 'p')"
        )

    account = AccountStore(db_path).all()[0]

    assert account.name == "Alt"
    # Defaults keep the existing behaviour: nothing printed, everything filed.
    assert account.print_attachments is False
    assert account.printer == ""
    assert account.archive_attachments is True
MAIL2NAS_EOF

# --- tests/test_printing.py ---
cat > tests/test_printing.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import subprocess

import pytest

from mail2nas.printers import Printer, PrinterStore
from mail2nas.printing import (
    PrintError,
    PrintService,
    Spooler,
    build_command,
    job_title,
    parse_extensions,
)

PRINTABLE = parse_extensions("pdf,txt,png")


def _printer(**overrides) -> Printer:
    fields = dict(
        id=1, name="Buero", destination="Kyocera_M2540", server="", options="", copies=1,
        enabled=True,
    )
    fields.update(overrides)
    return Printer(**fields)


class FakeRun:
    """Stands in for subprocess.run, recording what it was asked to run."""

    def __init__(self, returncode: int = 0, stdout: str = "request id is q-1", stderr: str = ""):
        self.calls: list[list[str]] = []
        self._result = subprocess.CompletedProcess([], returncode, stdout, stderr)

    def __call__(self, command, **kwargs):
        self.calls.append(list(command))
        self.kwargs = kwargs
        return self._result


def _spooler(monkeypatch, run=None, **overrides) -> tuple[Spooler, FakeRun]:
    run = run or FakeRun()
    monkeypatch.setattr(subprocess, "run", run)
    options = dict(printable_extensions=PRINTABLE)
    options.update(overrides)
    return Spooler(**options), run


# --- the lp command -----------------------------------------------------------


def test_the_command_names_the_queue_and_the_job():
    command = build_command(_printer(), "/tmp/x.pdf", "Rechnung 4711")

    assert command[0] == "lp"
    assert command[command.index("-d") + 1] == "Kyocera_M2540"
    assert command[command.index("-t") + 1] == "Rechnung 4711"
    assert command[-2:] == ["--", "/tmp/x.pdf"]


def test_a_remote_cups_server_is_passed_with_h():
    command = build_command(_printer(server="cups.lan:631"), "/tmp/x.pdf", "t")

    assert command[command.index("-h") + 1] == "cups.lan:631"


def test_each_option_becomes_its_own_o_argument():
    command = build_command(
        _printer(options="media=A4 sides=two-sided-long-edge"), "/tmp/x.pdf", "t"
    )

    assert command.count("-o") == 2
    assert "media=A4" in command and "sides=two-sided-long-edge" in command


def test_a_single_copy_needs_no_n_argument():
    assert "-n" not in build_command(_printer(), "/tmp/x.pdf", "t")
    assert build_command(_printer(copies=3), "/tmp/x.pdf", "t").count("-n") == 1


def test_the_binary_can_be_pointed_somewhere_else():
    assert build_command(_printer(), "/tmp/x.pdf", "t", lp_binary="/usr/bin/lp")[0] == "/usr/bin/lp"


def test_the_job_title_stays_short_and_printable():
    title = job_title("Betreff\nmit Umbruch", "rechnung.pdf")

    assert "\n" not in title
    assert len(title) <= 80
    assert "rechnung.pdf" in title


# --- spooling ------------------------------------------------------------------


def test_printing_writes_the_payload_and_calls_lp(monkeypatch, tmp_path):
    seen = {}
    run = FakeRun()

    def record(command, **kwargs):
        # The temporary file must still exist - and hold the payload - at the
        # moment lp is called.
        with open(command[-1], "rb") as fh:
            seen["data"] = fh.read()
        seen["suffix"] = command[-1].rsplit(".", 1)[-1]
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)
    spooler = Spooler(printable_extensions=PRINTABLE)

    spooler.print_bytes(_printer(), b"%PDF-1.4 fake", "rechnung.pdf")

    assert seen["data"] == b"%PDF-1.4 fake"
    assert seen["suffix"] == "pdf"


def test_the_temporary_file_is_removed_afterwards(monkeypatch):
    paths = []
    run = FakeRun()

    def record(command, **kwargs):
        paths.append(command[-1])
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)

    Spooler(printable_extensions=PRINTABLE).print_bytes(_printer(), b"x", "a.pdf")

    import os

    assert paths and not os.path.exists(paths[0])


def test_a_failing_lp_reports_what_it_said(monkeypatch):
    spooler, _ = _spooler(monkeypatch, run=FakeRun(returncode=1, stderr="lp: Kein Drucker"))

    with pytest.raises(PrintError, match="Kein Drucker"):
        spooler.print_bytes(_printer(), b"x", "a.pdf")


def test_a_missing_lp_binary_says_which_package_is_missing(monkeypatch):
    def missing(command, **kwargs):
        raise FileNotFoundError(command[0])

    monkeypatch.setattr(subprocess, "run", missing)

    with pytest.raises(PrintError, match="cups-client"):
        Spooler(printable_extensions=PRINTABLE).print_bytes(_printer(), b"x", "a.pdf")


def test_a_hanging_printer_is_given_up_on(monkeypatch):
    def hang(command, **kwargs):
        raise subprocess.TimeoutExpired(command, 1)

    monkeypatch.setattr(subprocess, "run", hang)

    with pytest.raises(PrintError, match="abgebrochen"):
        Spooler(printable_extensions=PRINTABLE, timeout=1).print_bytes(_printer(), b"x", "a.pdf")


def test_dry_run_does_not_touch_the_printer(monkeypatch):
    spooler, run = _spooler(monkeypatch, dry_run=True)

    spooler.print_bytes(_printer(), b"x", "a.pdf")

    assert run.calls == []


def test_the_test_page_says_where_it_came_from(monkeypatch):
    printed = {}
    run = FakeRun()

    def record(command, **kwargs):
        with open(command[-1], encoding="utf-8") as fh:
            printed["text"] = fh.read()
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)

    Spooler(printable_extensions=PRINTABLE).print_test_page(_printer())

    assert "Kyocera_M2540" in printed["text"]


@pytest.mark.parametrize(
    "filename,printable",
    [("rechnung.pdf", True), ("BELEG.PDF", True), ("notiz.txt", True),
     ("rechnung.docx", False), ("ohne-endung", False)],
)
def test_only_known_formats_are_spooled(filename, printable):
    assert Spooler(printable_extensions=PRINTABLE).can_print(filename) is printable


# --- routing --------------------------------------------------------------------


@pytest.fixture
def service(tmp_path, monkeypatch):
    store = PrinterStore(str(tmp_path / "state.db"))
    run = FakeRun()
    monkeypatch.setattr(subprocess, "run", run)
    service = PrintService(store, Spooler(printable_extensions=PRINTABLE))
    return service, store, run


def test_the_first_configured_printer_in_the_chain_wins(service):
    printing, store, _ = service
    rule_printer = store.add(name="Regel", destination="q1")
    account_printer = store.add(name="Konto", destination="q2")

    chosen = printing.printer_for(str(rule_printer), str(account_printer))

    assert chosen.name == "Regel"


def test_an_empty_choice_falls_through_to_the_next(service):
    printing, store, _ = service
    account_printer = store.add(name="Konto", destination="q2")

    assert printing.printer_for("", str(account_printer)).name == "Konto"


def test_a_deleted_printer_falls_through_instead_of_failing(service):
    printing, store, _ = service
    account_printer = store.add(name="Konto", destination="q2")

    assert printing.printer_for("9999", str(account_printer)).name == "Konto"


def test_a_paused_printer_is_skipped(service):
    printing, store, _ = service
    paused = store.add(name="Pausiert", destination="q1", enabled=False)

    assert printing.printer_for(str(paused)) is None


def test_nothing_configured_means_no_printer(service):
    printing, _, _ = service

    assert printing.printer_for("", "") is None
    assert printing.configured() is False


def test_sending_reports_failures_instead_of_raising(tmp_path, monkeypatch):
    store = PrinterStore(str(tmp_path / "state.db"))
    monkeypatch.setattr(subprocess, "run", FakeRun(returncode=1, stderr="offline"))
    printing = PrintService(store, Spooler(printable_extensions=PRINTABLE))

    # A dead printer must never take the archiving down with it.
    assert printing.send(_printer(), b"x", "rechnung.pdf") is False


def test_an_unprintable_format_is_not_sent(service):
    printing, _, run = service

    assert printing.send(_printer(), b"MZ", "setup.docx") is False
    assert run.calls == []
MAIL2NAS_EOF

# --- tests/test_main.py ---
cat > tests/test_main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import pytest

from mail2nas.accounts import AccountStore
from mail2nas.main import reconcile
from mail2nas.mapping import Mapping
from mail2nas.runtime import Runtime
from mail2nas.state import ProcessedStore, SettingsStore
from mail2nas.storage import LocalStorage
from tests.test_archiver import _make_config


class FakeWorker:
    """Stands in for a real IMAP worker thread."""

    def __init__(self, account):
        self.account = account
        self.fingerprint = account.fingerprint()
        self.started = False
        self.stopped = False

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def is_alive(self):
        return self.started and not self.stopped


@pytest.fixture
def runtime(tmp_path):
    config = _make_config(tmp_path)
    storage = LocalStorage(config.storage_root)
    return Runtime(
        config,
        storage,
        Mapping(storage, config.mapping_path, config.fallback_folder),
        ProcessedStore(config.state_db_path),
        SettingsStore(config.state_db_path),
        AccountStore(config.state_db_path),
    )


def _add(runtime, **fields):
    defaults = dict(name="A", host="imap.example.com", user="u", password="p")
    defaults.update(fields)
    return runtime.accounts.add(**defaults)


def test_one_worker_is_started_per_enabled_account(runtime):
    _add(runtime, name="Eins")
    _add(runtime, name="Zwei")

    workers = reconcile(runtime, {}, FakeWorker)

    assert len(workers) == 2
    assert all(worker.started for worker in workers.values())


def test_disabled_accounts_get_no_worker(runtime):
    _add(runtime, name="Aus", enabled=False)

    assert reconcile(runtime, {}, FakeWorker) == {}


def test_an_unchanged_account_keeps_its_worker(runtime):
    """A reconnect on every pass would mean reconnecting every few seconds."""
    _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = next(iter(workers.values()))

    reconcile(runtime, workers, FakeWorker)

    assert next(iter(workers.values())) is first
    assert not first.stopped


def test_changing_the_password_restarts_the_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.update(account_id, password="neu")
    reconcile(runtime, workers, FakeWorker)

    assert first.stopped
    assert workers[account_id] is not first


def test_renaming_an_account_does_not_restart_the_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.update(account_id, name="Neuer Name")
    reconcile(runtime, workers, FakeWorker)

    assert not first.stopped
    assert workers[account_id] is first


def test_deleting_an_account_stops_its_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.delete(account_id)
    reconcile(runtime, workers, FakeWorker)

    assert first.stopped
    assert workers == {}


def test_disabling_an_account_stops_its_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)

    runtime.accounts.update(account_id, enabled=False)
    reconcile(runtime, workers, FakeWorker)

    assert workers == {}


def test_a_dead_worker_is_replaced(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    workers[account_id].stopped = True

    reconcile(runtime, workers, FakeWorker)

    assert workers[account_id].is_alive()
MAIL2NAS_EOF

# --- mail2nas/__init__.py ---
touch mail2nas/__init__.py

# --- tests/__init__.py ---
touch tests/__init__.py

echo "Fertig: $TARGET enthaelt jetzt das komplette mail2nas-Projekt."
echo "Naechste Schritte:"
echo "  cd $TARGET"
echo "  cp .env.example .env && \$EDITOR .env"
echo "  # siehe README.md (Abschnitt 'Installation, Variante 2') fuer den Rest"
