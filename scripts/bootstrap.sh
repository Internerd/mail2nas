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
mkdir -p "$TARGET"/mail2nas "$TARGET"/mail2nas/templates "$TARGET"/config "$TARGET"/tests
cd "$TARGET"

echo "Schreibe Projektdateien nach $TARGET ..."

# --- requirements.txt ---
cat > requirements.txt <<'MAIL2NAS_EOF'
imapclient>=3.0,<4.0
PyYAML>=6.0,<7.0
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
# Das SMB-Share wird NICHT von Docker gemountet, sondern vom Betriebssystem:
# auf dem Proxmox-Host per /etc/fstab und dann per Bind-Mount in die LXC
# (so macht es scripts/proxmox/mail2nas.sh), oder bei einer VM/Bare-Metal
# direkt per /etc/fstab in diesem System.
#
# Grund: Dockers cifs-Volume-Treiber setzt den mount()-Syscall selbst ab. Der
# ist in einer unprivilegierten LXC kernelseitig gesperrt ("invalid argument"),
# und die SMB-Zugangsdaten landen dabei in den Volume-Metadaten des Docker-
# Daemons. Beides entfaellt, wenn das Share eine Ebene hoeher gemountet wird.
#
# Hier steht daher nur noch, WO das bereits gemountete Share liegt:
NAS_PATH=/mnt/nas
# Mehrere Shares/NAS sind moeglich: jedes weitere Share zusaetzlich mounten,
# in docker-compose.yml als Volume eintragen (z. B. NAS2_PATH -> /mnt/nas2)
# und den Pfad dann in der Weboberflaeche unter "Ablagen" anlegen. Jede
# Zuordnung und jeder Drucker waehlt danach eine dieser Ablagen.
# NAS2_PATH=/mnt/nas2

# --- Mapping & filing behaviour -------------------------------------------
# Path to the mapping file, relative to the SMB share root (/mnt/nas).
# See config/mapping.example.yaml - copy it onto the share as mapping.yaml.
# It is reloaded on every processing cycle, so edits apply without a restart.
MAPPING_PATH=mapping.yaml
# Subfolder (under /mnt/nas) used when no keyword in mapping.yaml matches.
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
# NUR VORBELEGUNG: ab dem ersten Start wird die Liste in der Weboberflaeche
# unter "Einstellungen" gepflegt und in der config.yaml gespeichert.
BLOCKED_EXTENSIONS=exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk
QUARANTINE_FOLDER=quarantaene

# --- Weboberflaeche zur Konfiguration ---------------------------------------
# Erreichbar unter http://<container-ip>:<WEB_PORT>. Ohne gesetztes
# WEB_PASSWORD startet sie NICHT - die Seite zeigt und aendert IMAP-
# Zugangsdaten und darf daher nicht ohne Anmeldung laufen.
# Nur im vertrauenswuerdigen LAN veroeffentlichen, nicht ins Internet.
WEB_ENABLED=true
WEB_PORT=8080
WEB_USER=admin
WEB_PASSWORD=

# --- Drucker und Scanner ----------------------------------------------------
# Geraete werden in der Weboberflaeche unter "Drucker" angelegt - entweder
# ueber ihre Absenderadresse (Scan-to-Mail) oder ueber einen Abholordner auf
# einem der Shares (Scan-to-Folder). Dafuer gibt es keine Umgebungsvariablen.

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

RUN apt-get update && apt-get install -y --no-install-recommends \
    tzdata \
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
    ports:
      # Konfigurationsoberflaeche. Nur im LAN veroeffentlichen - die Seite
      # zeigt und aendert IMAP-Zugangsdaten.
      - "${WEB_PORT:-8080}:8080"
    environment:
      STORAGE_ROOT: /mnt/nas
      STATE_DB_PATH: /data/state.db
    volumes:
      # Plain bind mount of an already-mounted directory - the SMB share is
      # mounted by the OS (host fstab, or the Proxmox host bind-mounted into
      # the LXC), NOT by Docker.
      #
      # Docker's local volume driver with type=cifs issues the mount() syscall
      # itself, which the kernel refuses from inside an unprivileged LXC
      # ("invalid argument"), and it would also put the SMB password into the
      # daemon's volume metadata. Mounting one level up avoids both.
      - ${NAS_PATH:-/mnt/nas}:/mnt/nas
      # Weitere Shares/NAS: genauso einhaengen und den Pfad danach unter
      # "Ablagen" in der Weboberflaeche eintragen (hier: /mnt/nas2).
      # Auskommentieren und NAS2_PATH in der .env setzen:
      # - ${NAS2_PATH:-/mnt/nas2}:/mnt/nas2
      - state:/data

volumes:
  # Local state (processed-message tracking), no need for this to live on the share.
  state:
MAIL2NAS_EOF

# --- config/mapping.example.yaml ---
cat > config/mapping.example.yaml <<'MAIL2NAS_EOF'
# Kopiere diese Datei als "mapping.yaml" auf die Wurzel des SMB-Shares
# (bzw. an den Pfad, der in den Einstellungen hinterlegt ist).
#
# Bequemer geht es ueber die Weboberflaeche: dort lassen sich Zuordnungen
# anlegen, mit Pfeilen in der Prioritaet verschieben und einem Mailkonto
# zuordnen. Diese Datei ist einfach das, was dabei gespeichert wird.
#
# Sie wird bei jedem Verarbeitungszyklus neu eingelesen - Aenderungen von Hand
# wirken also ohne Neustart.
#
# --- Wie eine Regel geprueft wird -------------------------------------------
#
# REIHENFOLGE = PRIORITAET: Die erste passende Regel gewinnt. Deshalb steht
# "Rechnungskorrektur" hier vor "RE" - andersherum wuerde bereits "RE" greifen.
#
# match   - Stichwort. Gross-/Kleinschreibung ist immer egal.
#           Enthaelt es * oder ?, wird es als Platzhalter gegen den GANZEN Text
#           geprueft:  *  = beliebig viele Zeichen,  ? = genau ein Zeichen.
#             "Rechnung*"  passt auf "rechnung_4711.pdf", nicht auf "meine rechnung"
#             "*Rechnung*" passt auf beides
#             "RE-????"    passt auf "RE-2024", nicht auf "RE-24"
#           Ohne Platzhalter wird als Teilstring gesucht (wie bisher).
# folder  - Zielordner relativ zur Wurzel des Shares. Unterordner erlaubt
#           ("rechnungen/2026"), ausserhalb des Shares nicht.
# account - "all" oder die id eines einzelnen Mailkontos. Die ids stehen in
#           der Weboberflaeche unter "Mailkonten".
# share   - optional: id der Ablage (NAS/Share), auf die der Zielordner
#           gehoert. Fehlt der Eintrag, gilt die Standard-Ablage (die erste
#           aktive). Die ids stehen in der Weboberflaeche unter "Ablagen".
#
# Geprueft wird zuerst der Dateiname jedes einzelnen Anhangs, danach Betreff
# (und Mailtext, falls MATCH_BODY aktiviert ist). Dadurch koennen mehrere
# unterschiedlich benannte Anhaenge derselben Mail in verschiedenen Ordnern
# landen.

version: 2
rules:
  - match: Rechnungskorrektur
    folder: korrekturen
    account: all
    # share: nas2      # optional, sonst Standard-Ablage
  - match: Gutschrift
    folder: gutschriften
    account: all
  - match: Mahnung
    folder: mahnungen
    account: all
  - match: Lieferschein
    folder: lieferscheine
    account: all
  - match: Auftragsbestaetigung
    folder: auftragsbestaetigungen
    account: all
  - match: Rechnung
    folder: rechnungen
    account: all
  - match: Invoice
    folder: rechnungen
    account: all
  - match: RE
    folder: rechnungen
    account: all
  - match: LS
    folder: lieferscheine
    account: all
  - match: AB
    folder: auftragsbestaetigungen
    account: all
MAIL2NAS_EOF

# --- mail2nas/config.py ---
cat > mail2nas/config.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
from dataclasses import dataclass

# Executable/script types that are quarantined instead of filed normally,
# even if their filename happens to match a mapping keyword. This is a
# defense-in-depth measure against mail attachments being used to smuggle
# malware onto the archive share - it does not make opening the quarantined
# file safe, it just keeps it out of the regular business-document folders.
DEFAULT_BLOCKED_EXTENSIONS = (
    "exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,"
    "jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk"
)


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

    storage_root: str
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

    # Which configured mail account this instance archives for. Rules in
    # mapping.yaml can be limited to a single account by this id.
    account_id: str = "default"

    # Web configuration UI. Disabled unless a password is set, because the
    # page can read and change IMAP credentials.
    web_enabled: bool = False
    web_host: str = "0.0.0.0"
    web_port: int = 8080
    web_user: str = "admin"
    web_password: str = ""

    @classmethod
    def from_env(cls) -> "Config":
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
                storage_root=os.environ.get("STORAGE_ROOT", "/mnt/nas"),
                mapping_path=os.environ.get("MAPPING_PATH", "mapping.yaml"),
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
                web_enabled=_bool("WEB_ENABLED", True),
                web_host=os.environ.get("WEB_HOST", "0.0.0.0"),
                web_port=_int("WEB_PORT", "8080", minimum=1, maximum=65535),
                web_user=os.environ.get("WEB_USER", "admin"),
                web_password=os.environ.get("WEB_PASSWORD", ""),
            )
        except KeyError as exc:
            raise SystemExit(f"Missing required environment variable: {exc.args[0]}") from exc
MAIL2NAS_EOF

# --- mail2nas/settings.py ---
cat > mail2nas/settings.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses
import fnmatch
import logging
import os
import re
import secrets
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from .config import Config

logger = logging.getLogger(__name__)

_ID_SAFE = re.compile(r"[^a-z0-9_-]+")
_LIST_SPLIT = re.compile(r"[,;\s]+")

# Rules, printers and folders refer to a share by its id. The empty string
# means "whatever is currently the default share", which keeps single-NAS
# setups working unchanged and survives renaming the first share.
DEFAULT_SHARE = ""


def make_id(name: str, prefix: str) -> str:
    ident = _ID_SAFE.sub("-", name.strip().lower()).strip("-")
    return ident or f"{prefix}-{secrets.token_hex(3)}"


def make_account_id(name: str) -> str:
    return make_id(name, "konto")


def make_share_id(name: str) -> str:
    return make_id(name, "share")


def make_printer_id(name: str) -> str:
    return make_id(name, "drucker")


def parse_extensions(raw: str | list | None) -> list[str]:
    """Normalize a comma/space separated extension list ('.EXE, com' -> ['exe','com'])."""
    if raw is None:
        return []
    items = raw if isinstance(raw, (list, tuple)) else _LIST_SPLIT.split(str(raw))
    seen: set[str] = set()
    result: list[str] = []
    for item in items:
        ext = str(item).strip().lower().lstrip(".").strip()
        if ext and ext not in seen:
            seen.add(ext)
            result.append(ext)
    return result


@dataclass
class Account:
    """One IMAP mailbox to archive from."""

    id: str
    host: str
    user: str
    password: str
    label: str = ""
    port: int = 993
    ssl: bool = True
    folder: str = "INBOX"
    processed_folder: str = ""
    oversized_folder: str = ""
    mode: str = "poll"  # "idle" or "poll"
    enabled: bool = True

    def display_name(self) -> str:
        return self.label or self.user or self.id


@dataclass
class Share:
    """One archive destination: a directory where a share is already mounted.

    mail2nas never mounts anything itself (see docker-compose.yml for why), so
    a share is just the local path its mount point has - on this machine, in
    the container, or bind-mounted into the LXC.
    """

    id: str
    path: str
    label: str = ""
    enabled: bool = True

    def display_name(self) -> str:
        return self.label or self.id


@dataclass
class Printer:
    """A scanner/multifunction printer that delivers documents to mail2nas.

    Two delivery paths, either or both can be used per device:

    * Scan-to-Mail: the device mails its scans. `sender` identifies it by the
      From address, so its documents can be filed without relying on keywords
      in the (usually meaningless) scan filename.
    * Scan-to-Folder: the device writes into an SMB folder on a NAS that is
      also mounted here. `source_share` + `source_folder` is that pickup
      folder; mail2nas moves finished files out of it into the archive.
    """

    id: str
    label: str = ""
    sender: str = ""  # scan-to-mail: From address, "@domain" or wildcard
    source_share: str = DEFAULT_SHARE
    source_folder: str = ""  # scan-to-folder: pickup folder, empty = unused
    target_share: str = DEFAULT_SHARE
    target_folder: str = ""  # empty = let the normal keyword rules decide
    enabled: bool = True

    def display_name(self) -> str:
        return self.label or self.id

    @property
    def has_pickup(self) -> bool:
        return bool(self.source_folder.strip())

    @property
    def has_fixed_target(self) -> bool:
        return bool(self.target_folder.strip())

    def matches_sender(self, address: str) -> bool:
        """True if `address` is this device's mail address.

        Accepts an exact address, a whole domain ("@scanner.lan") or a
        wildcard pattern ("kopierer-*@example.com").
        """
        pattern = (self.sender or "").strip().lower()
        addr = (address or "").strip().lower()
        if not pattern or not addr:
            return False
        if any(ch in pattern for ch in "*?"):
            return fnmatch.fnmatchcase(addr, pattern)
        if pattern.startswith("@"):
            return addr.endswith(pattern)
        return addr == pattern


def _rows(raw: dict, key: str, cls) -> list:
    """Build dataclass instances from a list of mappings, ignoring stray keys.

    Unknown keys are dropped rather than raising, so a config file written by a
    newer version still loads (minus the fields this version does not know).
    """
    known = {f.name for f in dataclasses.fields(cls)}
    return [
        cls(**{k: v for k, v in entry.items() if k in known})
        for entry in raw.get(key, []) or []
        if isinstance(entry, dict)
    ]


@dataclass
class Settings:
    """Everything the web UI can change, persisted next to the state database.

    Deliberately NOT on the SMB share: it holds IMAP passwords, and the share
    is readable by everyone who can reach it.
    """

    accounts: list[Account] = field(default_factory=list)
    shares: list[Share] = field(default_factory=list)
    printers: list[Printer] = field(default_factory=list)
    mapping_path: str = "mapping.yaml"
    fallback_folder: str = "unsorted"
    quarantine_folder: str = "quarantaene"
    blocked_extensions: list[str] = field(default_factory=list)
    match_body: bool = False
    filename_prefix: str = "date_sender"
    poll_interval: int = 300
    max_attachment_size_mb: int = 25
    max_message_size_mb: int = 50
    max_attachments_per_message: int = 20
    # How long a file in a printer pickup folder must have been untouched
    # before it is imported - a scan still being written is not complete yet.
    printer_min_age_seconds: int = 20

    # --- persistence ---------------------------------------------------

    @staticmethod
    def path_for(config: Config) -> Path:
        return Path(config.state_db_path).parent / "config.yaml"

    @classmethod
    def load(cls, config: Config) -> "Settings":
        path = cls.path_for(config)
        if not path.exists():
            settings = cls.from_env_config(config)
            settings.save(config)
            logger.info("Created %s from the environment configuration", path)
            return settings

        try:
            raw = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
            if not isinstance(raw, dict):
                raise ValueError("config file must contain a mapping")
            known = {f.name for f in dataclasses.fields(cls)} - {"accounts", "shares", "printers"}
            values = {k: v for k, v in raw.items() if k in known}
            settings = cls(
                accounts=_rows(raw, "accounts", Account),
                shares=_rows(raw, "shares", Share),
                printers=_rows(raw, "printers", Printer),
                **values,
            )
        except Exception as exc:
            # Falling back to the environment keeps the archiver running rather
            # than leaving it dead because a hand-edited config file broke.
            logger.error("Could not read %s (%s) - falling back to the environment", path, exc)
            return cls.from_env_config(config)

        if "blocked_extensions" not in raw:
            # Config file from a version where the list only lived in the
            # environment. An empty list means "check disabled", so it must not
            # be what an upgrade silently turns the quarantine into.
            settings.blocked_extensions = sorted(config.blocked_extensions)
        settings.blocked_extensions = parse_extensions(settings.blocked_extensions)
        if not settings.shares:
            # Config file from a version that only knew one static storage root.
            settings.shares = [cls.base_share(config)]
        return settings

    @staticmethod
    def base_share(config: Config) -> Share:
        """The share that STORAGE_ROOT points at - always present, never removable."""
        return Share(id="default", label="NAS", path=config.storage_root)

    @classmethod
    def from_env_config(cls, config: Config) -> "Settings":
        """Seed the file-backed settings from the classic environment variables."""
        return cls(
            accounts=[
                Account(
                    id="default",
                    label="Hauptpostfach",
                    host=config.imap_host,
                    port=config.imap_port,
                    ssl=config.imap_ssl,
                    user=config.imap_user,
                    password=config.imap_password,
                    folder=config.imap_folder,
                    processed_folder=config.imap_processed_folder or "",
                    oversized_folder=config.imap_oversized_folder or "",
                    mode=config.imap_mode,
                )
            ],
            shares=[cls.base_share(config)],
            printers=[],
            mapping_path=config.mapping_path,
            fallback_folder=config.fallback_folder,
            quarantine_folder=config.quarantine_folder,
            blocked_extensions=sorted(config.blocked_extensions),
            match_body=config.match_body,
            filename_prefix=config.filename_prefix,
            poll_interval=config.poll_interval,
            max_attachment_size_mb=config.max_attachment_size_mb,
            max_message_size_mb=config.max_message_size_mb,
            max_attachments_per_message=config.max_attachments_per_message,
        )

    def save(self, config: Config) -> None:
        path = self.path_for(config)
        path.parent.mkdir(parents=True, exist_ok=True)
        payload = dataclasses.asdict(self)
        tmp = path.with_suffix(".yaml.tmp")
        tmp.write_text(
            "# mail2nas - von der Weboberflaeche verwaltet.\n"
            "# Enthaelt IMAP-Passwoerter im Klartext: Dateirechte 0600 beibehalten.\n"
            + yaml.safe_dump(payload, allow_unicode=True, sort_keys=False),
            encoding="utf-8",
        )
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)

    # --- lookups --------------------------------------------------------

    def account(self, account_id: str) -> Account | None:
        return next((a for a in self.accounts if a.id == account_id), None)

    def enabled_accounts(self) -> list[Account]:
        return [a for a in self.accounts if a.enabled and a.host and a.user]

    def share(self, share_id: str) -> Share | None:
        return next((s for s in self.shares if s.id == share_id), None)

    def enabled_shares(self) -> list[Share]:
        return [s for s in self.shares if s.enabled and s.path]

    def default_share(self) -> Share | None:
        """The share used by rules that do not name one explicitly."""
        return next(iter(self.enabled_shares()), None) or next(iter(self.shares), None)

    def printer(self, printer_id: str) -> Printer | None:
        return next((p for p in self.printers if p.id == printer_id), None)

    def enabled_printers(self) -> list[Printer]:
        return [p for p in self.printers if p.enabled]

    def pickup_printers(self) -> list[Printer]:
        return [p for p in self.enabled_printers() if p.has_pickup]

    def mail_printers(self) -> list[Printer]:
        return [p for p in self.enabled_printers() if p.sender.strip()]

    @staticmethod
    def _unique(desired: str, taken: set[str]) -> str:
        if desired not in taken:
            return desired
        for n in range(2, 1000):
            candidate = f"{desired}-{n}"
            if candidate not in taken:
                return candidate
        return f"{desired}-{secrets.token_hex(3)}"

    def unique_id(self, desired: str, ignore: str | None = None) -> str:
        """Return `desired`, suffixed if another account already uses it."""
        return self._unique(desired, {a.id for a in self.accounts if a.id != ignore})

    def unique_share_id(self, desired: str, ignore: str | None = None) -> str:
        return self._unique(desired, {s.id for s in self.shares if s.id != ignore})

    def unique_printer_id(self, desired: str, ignore: str | None = None) -> str:
        return self._unique(desired, {p.id for p in self.printers if p.id != ignore})

    # --- bridging to the archiver ---------------------------------------

    def config_for(self, config: Config, account: Account) -> Config:
        """Build the per-account Config the Archiver works with."""
        return dataclasses.replace(
            self.config_common(config),
            imap_host=account.host,
            imap_port=account.port,
            imap_ssl=account.ssl,
            imap_user=account.user,
            imap_password=account.password,
            imap_folder=account.folder,
            imap_processed_folder=account.processed_folder or None,
            imap_oversized_folder=account.oversized_folder or None,
            imap_mode=account.mode,
            account_id=account.id,
        )

    def config_common(self, config: Config) -> Config:
        """The filing-related settings, without any account-specific fields.

        Used directly by the printer pickup, which files documents with the
        same rules and limits but has no mailbox behind it.
        """
        return dataclasses.replace(
            config,
            poll_interval=self.poll_interval,
            mapping_path=self.mapping_path,
            fallback_folder=self.fallback_folder,
            quarantine_folder=self.quarantine_folder,
            blocked_extensions=frozenset(parse_extensions(self.blocked_extensions)),
            match_body=self.match_body,
            filename_prefix=self.filename_prefix,
            max_attachment_size_mb=self.max_attachment_size_mb,
            max_message_size_mb=self.max_message_size_mb,
            max_attachments_per_message=self.max_attachments_per_message,
        )
MAIL2NAS_EOF

# --- mail2nas/mapping.py ---
cat > mail2nas/mapping.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import fnmatch
import logging
from dataclasses import dataclass
from pathlib import Path

import yaml

from .settings import DEFAULT_SHARE

logger = logging.getLogger(__name__)

ALL_ACCOUNTS = "all"


@dataclass(frozen=True)
class Target:
    """Where a document goes: a folder on one of the configured shares."""

    folder: str
    share: str = DEFAULT_SHARE
    keyword: str | None = None  # the rule that matched, None = fallback


@dataclass(frozen=True)
class Rule:
    """One keyword -> folder rule.

    `account` is either ALL_ACCOUNTS or the id of a single mail account, so a
    rule can be limited to one mailbox when several are configured.
    `share` is the id of the share to file on, or "" for the default one.
    """

    match: str
    folder: str
    account: str = ALL_ACCOUNTS
    share: str = DEFAULT_SHARE

    @property
    def is_wildcard(self) -> bool:
        return any(ch in self.match for ch in "*?")

    def applies_to(self, account: str | None) -> bool:
        return self.account == ALL_ACCOUNTS or account is None or self.account == account

    def matches(self, haystack: str) -> bool:
        """Case-insensitive test against already-lowercased `haystack`.

        A pattern containing * or ? is treated as a wildcard matched against
        the whole text; anything else keeps the original substring behaviour,
        so existing mapping files behave exactly as before.
        """
        pattern = self.match.lower()
        if self.is_wildcard:
            return fnmatch.fnmatchcase(haystack, pattern)
        return pattern in haystack

    def target(self) -> Target:
        return Target(folder=self.folder, share=self.share, keyword=self.match)


def _coerce_rules(raw: object) -> list[Rule]:
    """Build the rule list from either mapping-file format.

    v2 (ordered, explicit priority - first match wins):
        version: 2
        rules:
          - match: "Rechnung*"
            folder: rechnungen
            account: all
            share: nas2      # optional, default = the default share

    v1 (legacy plain dict, no ordering information):
        RE: rechnungen
    Sorted longest-keyword-first, which is what v1 always did implicitly so
    that "Rechnungskorrektur" is checked before "RE".
    """
    if isinstance(raw, dict) and "rules" in raw:
        entries = raw.get("rules") or []
        if not isinstance(entries, list):
            raise ValueError("'rules' must be a list")
        rules = []
        for index, entry in enumerate(entries, start=1):
            if not isinstance(entry, dict):
                raise ValueError(f"rule #{index} must be a mapping")
            match = str(entry.get("match", "")).strip()
            folder = str(entry.get("folder", "")).strip()
            if not match or not folder:
                raise ValueError(f"rule #{index} needs both 'match' and 'folder'")
            rules.append(
                Rule(
                    match=match,
                    folder=folder,
                    account=str(entry.get("account") or ALL_ACCOUNTS),
                    share=str(entry.get("share") or DEFAULT_SHARE),
                )
            )
        return rules

    if isinstance(raw, dict):
        return [
            Rule(match=str(keyword), folder=str(folder))
            for keyword, folder in sorted(raw.items(), key=lambda kv: len(str(kv[0])), reverse=True)
        ]

    raise ValueError("file must contain a mapping of keyword -> folder, or a 'rules' list")


def dump_rules(rules: list[Rule]) -> str:
    """Serialize rules back to the v2 format, preserving their order."""
    entries = []
    for rule in rules:
        entry = {"match": rule.match, "folder": rule.folder, "account": rule.account}
        # Only written when it is actually used, so single-NAS mapping files
        # stay exactly as they were before shares existed.
        if rule.share:
            entry["share"] = rule.share
        entries.append(entry)
    payload = {"version": 2, "rules": entries}
    header = (
        "# mail2nas Zuordnungen\n"
        "#\n"
        "# Die REIHENFOLGE bestimmt die Prioritaet: die erste passende Regel\n"
        "# gewinnt. Ueber die Weboberflaeche laesst sie sich mit den Pfeilen\n"
        "# verschieben.\n"
        "#\n"
        "# match   - Stichwort, Gross-/Kleinschreibung egal. Enthaelt es * oder ?,\n"
        "#           wird es als Platzhalter gegen den ganzen Text geprueft\n"
        "#           (z. B. \"Rechnung*\"), sonst als Teilstring gesucht.\n"
        "# folder  - Zielordner relativ zur Wurzel des Shares.\n"
        "# account - 'all' oder die id eines einzelnen Mailkontos.\n"
        "# share   - id der Ablage (NAS/Share). Fehlt der Eintrag, gilt die\n"
        "#           Standard-Ablage. Die ids stehen in der Weboberflaeche\n"
        "#           unter 'Ablagen'.\n"
        "#\n"
        "# Geprueft wird zuerst der Dateiname jedes Anhangs, dann Betreff/Text.\n"
    )
    return header + yaml.safe_dump(payload, allow_unicode=True, sort_keys=False)


class Mapping:
    """Keyword -> target-subfolder rules, reloaded from disk on demand.

    The mapping file is expected to live on the same SMB share the
    attachments are archived to, so it can be edited by anyone with
    access to the share without touching the container/deployment.
    """

    def __init__(self, path: str, fallback_folder: str):
        self._path = Path(path)
        self._fallback_folder = fallback_folder
        self._rules: list[Rule] = []
        self._mtime: float | None = None
        self.reload(force=True)

    @property
    def path(self) -> Path:
        return self._path

    @property
    def rules(self) -> list[Rule]:
        return list(self._rules)

    @property
    def fallback_folder(self) -> str:
        return self._fallback_folder

    def set_path(self, path: str) -> None:
        """Point at a different mapping file and load it immediately."""
        self._path = Path(path)
        self._mtime = None
        self.reload(force=True)

    def set_fallback_folder(self, folder: str) -> None:
        """Adopt a fallback folder changed in the web UI without a restart."""
        self._fallback_folder = folder

    def reload(self, force: bool = False) -> None:
        try:
            mtime = self._path.stat().st_mtime
        except (FileNotFoundError, NotADirectoryError, PermissionError, OSError):
            if force:
                logger.warning(
                    "Mapping file %s not found, all mail will go to the fallback folder", self._path
                )
                self._rules = []
                self._mtime = None
            return

        if not force and self._mtime == mtime:
            return

        # The mapping file is edited by hand on a network share, so a malformed
        # or half-written version is a matter of when, not if. Keep serving the
        # last good rules instead of letting the exception escape: it would
        # propagate out of the IMAP loop and leave the service reconnecting in
        # a tight loop, archiving nothing at all until someone noticed.
        try:
            with self._path.open("r", encoding="utf-8") as fh:
                raw = yaml.safe_load(fh) or {}
            rules = _coerce_rules(raw)
        except Exception as exc:
            # Remember the mtime anyway, so a persistently broken file is
            # reported once rather than on every single cycle.
            self._mtime = mtime
            logger.error(
                "Could not load mapping file %s (%s) - keeping the previous %d rule(s)",
                self._path,
                exc,
                len(self._rules),
            )
            return

        self._rules = rules
        self._mtime = mtime
        logger.info("Loaded %d mapping rule(s) from %s", len(self._rules), self._path)

    def save(self, rules: list[Rule]) -> None:
        """Persist a new rule list (used by the web UI) and adopt it."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(dump_rules(rules), encoding="utf-8")
        self._rules = list(rules)
        try:
            self._mtime = self._path.stat().st_mtime
        except OSError:
            self._mtime = None
        logger.info("Saved %d mapping rule(s) to %s", len(rules), self._path)

    def resolve(self, *texts: str, account: str | None = None) -> Target:
        """Return the Target for these texts, or the fallback if nothing matches."""
        haystack = " ".join(t for t in texts if t).lower()
        for rule in self._rules:
            if rule.applies_to(account) and rule.matches(haystack):
                return rule.target()
        return Target(folder=self._fallback_folder)
MAIL2NAS_EOF

# --- mail2nas/filenames.py ---
cat > mail2nas/filenames.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import re
import shutil
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


def sanitize_path_segment(segment: str) -> str:
    """Sanitize a single folder-name component (never a path)."""
    segment = unicodedata.normalize("NFKC", segment)
    segment = _UNSAFE_SEGMENT.sub("_", segment)
    # Trailing dots/spaces are silently dropped by Windows/SMB, which would
    # make the on-disk name differ from what was configured.
    return segment.strip().rstrip(". ").strip()


def safe_join(root: str | Path, relative: str) -> Path:
    """Join `relative` onto `root`, guaranteeing the result stays under `root`.

    The target folders come from `mapping.yaml`, which lives on the archive
    share itself - so whoever can edit that file could otherwise redirect
    attachments anywhere the process can write, via `../..` or an absolute
    path. (Note `Path("/mnt/nas") / "/etc"` yields `/etc`: an absolute right
    operand discards the root entirely.)

    Absolute paths and `..` components are refused rather than reinterpreted,
    and every remaining component is sanitized. Nested targets such as
    "rechnungen/2026" stay supported. Raises ValueError if nothing usable is
    left, so the caller can fall back to a known-good folder.
    """
    root_path = Path(root)
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

    result = root_path.joinpath(*parts)

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


def copy_atomic(source: str | Path, path: str | Path) -> None:
    """Copy `source` to `path` via a temporary file plus rename.

    Same reasoning as write_atomic, but streamed: files picked up from a
    printer's folder are already on disk and can be arbitrarily large, so
    there is no reason to pull them through memory. Works across shares,
    where os.replace() would fail with EXDEV.
    """
    path = Path(path)
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".mail2nas-tmp-")
    try:
        with open(source, "rb") as src, os.fdopen(fd, "wb") as dst:
            shutil.copyfileobj(src, dst)
            dst.flush()
            os.fsync(dst.fileno())
        os.replace(tmp_name, path)
    except BaseException:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


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

# --- mail2nas/shares.py ---
cat > mail2nas/shares.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_join
from .settings import DEFAULT_SHARE, Share

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ShareStatus:
    id: str
    label: str
    path: str
    enabled: bool
    ok: bool
    problem: str | None


class ShareSet:
    """The configured archive destinations, resolved to directories on disk.

    One mail2nas instance can file onto several shares (typically several NAS
    boxes mounted at different paths). Rules, printers and folders address a
    share by id; the empty id means "the default share", so a mapping file
    written before multi-share support keeps working unchanged.

    Nothing here mounts anything: a share is a directory that the operating
    system has already mounted. That is also why every write re-checks the
    mount point - if a NAS goes away, its mount point usually stays behind as
    an empty local directory, and writing into it would put invoices into the
    container's own filesystem where nobody looks for them.
    """

    def __init__(self, shares: list[Share] | None, fallback_root: str | Path):
        self._shares = [s for s in (shares or []) if s.path]
        self._fallback_root = str(fallback_root)

    @classmethod
    def from_settings(cls, settings, fallback_root: str | Path) -> "ShareSet":
        return cls(settings.shares, fallback_root)

    # --- lookups --------------------------------------------------------

    @property
    def shares(self) -> list[Share]:
        return list(self._shares)

    def _enabled(self) -> list[Share]:
        return [s for s in self._shares if s.enabled]

    def default(self) -> Share | None:
        return next(iter(self._enabled()), None) or next(iter(self._shares), None)

    def get(self, share_id: str) -> Share | None:
        """The share with this id, or the default share for '' / unknown ids."""
        if share_id and share_id != DEFAULT_SHARE:
            share = next((s for s in self._shares if s.id == share_id), None)
            if share is not None and share.enabled:
                return share
            if share is not None:
                logger.warning("Share %r is disabled - using the default share instead", share_id)
            else:
                logger.warning("Unknown share %r - using the default share instead", share_id)
        return self.default()

    def root_for(self, share_id: str) -> Path:
        share = self.get(share_id)
        return Path(share.path if share is not None else self._fallback_root)

    def label_for(self, share_id: str) -> str:
        share = self.get(share_id)
        return share.display_name() if share is not None else "NAS"

    def resolve(self, share_id: str, folder: str) -> Path:
        """Directory for `folder` on `share_id`. Raises ValueError if unsafe."""
        return safe_join(self.root_for(share_id), folder)

    # --- mount checks ---------------------------------------------------

    @staticmethod
    def check_root(root: str | Path) -> str | None:
        """Return a problem description for this mount point, or None if it is fine."""
        path = Path(root)
        if not str(path).strip():
            return "kein Pfad hinterlegt"
        if not path.exists():
            return f"{path} existiert nicht - ist das Share gemountet?"
        if not path.is_dir():
            return f"{path} ist kein Verzeichnis"
        if not os.access(path, os.W_OK | os.X_OK):
            return f"{path} ist fuer uid {os.getuid()} nicht beschreibbar"
        return None

    def problem_with(self, share_id: str) -> str | None:
        share = self.get(share_id)
        if share is None:
            return self.check_root(self._fallback_root)
        return self.check_root(share.path)

    def status(self) -> list[ShareStatus]:
        default = self.default()
        if not self._shares:
            # Nothing configured yet: STORAGE_ROOT is the archive target.
            return [
                ShareStatus(
                    id=DEFAULT_SHARE,
                    label="Standard-Ablage (STORAGE_ROOT)",
                    path=self._fallback_root,
                    enabled=True,
                    ok=self.check_root(self._fallback_root) is None,
                    problem=self.check_root(self._fallback_root),
                )
            ]
        result = []
        for share in self._shares:
            problem = self.check_root(share.path) if share.enabled else None
            result.append(
                ShareStatus(
                    id=share.id,
                    label=share.display_name() + (" (Standard)" if share is default else ""),
                    path=share.path,
                    enabled=share.enabled,
                    ok=problem is None,
                    problem=problem,
                )
            )
        return result
MAIL2NAS_EOF

# --- mail2nas/filing.py ---
cat > mail2nas/filing.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
from email.header import decode_header, make_header
from pathlib import Path

from .config import Config
from .filenames import copy_atomic, sanitize_filename, unique_path, write_atomic
from .mapping import Mapping, Target
from .shares import ShareSet

logger = logging.getLogger(__name__)


def decode_mime_words(value: str | None) -> str:
    """Decode RFC 2047 encoded words ("=?utf-8?B?...?=") to plain text."""
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def extension_of(filename: str) -> str:
    if "." not in filename:
        return ""
    return filename.rsplit(".", 1)[-1].strip().lower()


class Filer:
    """Decides where a document goes and puts it there.

    Shared by the mail archiver and the printer pickup so both apply exactly
    the same rules, quarantine and naming - a scan that arrives by mail and
    the same scan dropped into a NAS folder must not end up in different
    places.
    """

    def __init__(self, config: Config, mapping: Mapping, shares: ShareSet):
        self.config = config
        self.mapping = mapping
        self.shares = shares

    # --- where does it go -------------------------------------------------

    def classify(
        self,
        filename: str,
        fallback_target: Target,
        account: str | None = None,
        forced_target: Target | None = None,
    ) -> tuple[Target, bool]:
        """Return (target, quarantined) for a single document.

        The document's own filename is checked against the mapping first, so
        several differently-named attachments of one mail can land in
        different folders. `fallback_target` is used when the filename itself
        gives no hint (for mail: the subject/body match). `forced_target`
        short-circuits both - that is a device with a fixed folder, which
        knows better than a keyword found in a scanner's filename.

        A blocked extension always wins: an executable can never be renamed
        into a trusted-looking business folder just by calling it
        "Rechnung.exe".
        """
        readable = decode_mime_words(filename)
        if forced_target is not None:
            target = forced_target
        else:
            target = self.mapping.resolve(readable, account=account)
            if target.keyword is None:
                target = fallback_target

        # Check both the name as received and the name actually written to
        # disk: sanitizing can change the trailing extension, and only the
        # latter is what a file manager will act on when someone opens it.
        extensions = {extension_of(readable), extension_of(sanitize_filename(readable))}
        if extensions & self.config.blocked_extensions:
            return (
                Target(
                    folder=self.config.quarantine_folder,
                    share=target.share,
                    keyword=target.keyword,
                ),
                True,
            )
        return target, False

    def directory_for(self, target: Target, quarantined: bool = False) -> Path:
        """Map a Target onto a directory on a mounted share.

        Folder names come from mapping.yaml on the share and are therefore
        untrusted; anything that would escape the share root is rejected and
        replaced with the fallback folder rather than being written outside.
        A share whose mount point is gone is skipped as well, so a NAS that is
        down diverts documents to the default share instead of quietly filling
        up the local disk behind the mount point.

        A quarantined document falls back to a quarantine folder only: a
        misconfigured quarantine path must never drop an executable into the
        folder people open invoices from.
        """
        if quarantined:
            candidates = [
                (target.share, target.folder, None),
                ("", self.config.quarantine_folder, "built-in quarantine"),
                ("", "quarantaene", "built-in quarantine"),
            ]
        else:
            candidates = [
                (target.share, target.folder, None),
                ("", self.config.fallback_folder, "fallback"),
                ("", "unsorted", "built-in"),
            ]
        for share_id, folder, note in candidates:
            try:
                directory = self.shares.resolve(share_id, folder)
            except ValueError as exc:
                logger.error(
                    "Unsafe target folder %r (%s) - not writing outside the share root", folder, exc
                )
                continue
            problem = self.shares.problem_with(share_id)
            if problem:
                logger.error("Share %r is not usable (%s)", self.shares.label_for(share_id), problem)
                continue
            if note:
                logger.warning("Using %s folder %r instead of %r", note, folder, target.folder)
            return directory
        raise ValueError("No usable target folder on any mounted share")

    # --- how is it named --------------------------------------------------

    def build_filename(self, date_prefix: str, sender: str, filename: str) -> str:
        filename = sanitize_filename(decode_mime_words(filename))
        mode = self.config.filename_prefix
        if mode == "none":
            return filename
        if mode == "date":
            return f"{date_prefix}_{filename}"
        sender = sanitize_filename(sender or "unknown")
        if mode == "sender":
            return f"{sender}_{filename}"
        return f"{date_prefix}_{sender}_{filename}"

    # --- writing ----------------------------------------------------------

    def save_bytes(self, directory: Path, name: str, payload: bytes) -> Path:
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, name)
        write_atomic(out_path, payload)
        return out_path

    def move_file(self, source: Path, directory: Path, name: str) -> Path:
        """Copy `source` into `directory` and remove it afterwards.

        Copy-then-delete rather than a rename: source and target can be on
        different shares, and the original must only disappear once the copy
        is complete and flushed.
        """
        directory.mkdir(parents=True, exist_ok=True)
        out_path = unique_path(directory, name)
        copy_atomic(source, out_path)
        try:
            source.unlink()
        except OSError:
            # The copy is only legitimate if the original goes away: a pickup
            # folder we cannot delete from would otherwise hand us the same
            # document again on every cycle.
            out_path.unlink(missing_ok=True)
            raise
        return out_path
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

    One instance is shared by all account workers, so every access is
    serialized by a lock and the connection is opened for cross-thread use.
    """

    def __init__(self, db_path: str):
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
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
MAIL2NAS_EOF

# --- mail2nas/archiver.py ---
cat > mail2nas/archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import email
import logging
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime

from imapclient import IMAPClient

from .config import Config
from .filing import Filer, decode_mime_words
from .mapping import Mapping, Target
from .settings import Printer
from .shares import ShareSet
from .state import ProcessedStore

logger = logging.getLogger(__name__)


def _message_id(msg: Message, uid: int) -> str:
    return msg.get("Message-ID") or f"<no-message-id-uid-{uid}@mail2nas>"


class Archiver:
    def __init__(
        self,
        config: Config,
        mapping: Mapping,
        store: ProcessedStore,
        shares: ShareSet | None = None,
        printers: list[Printer] | None = None,
    ):
        self.config = config
        self.mapping = mapping
        self.store = store
        self.shares = shares if shares is not None else ShareSet(None, config.storage_root)
        self.printers = list(printers or [])
        self.filer = Filer(config, mapping, self.shares)

    def connect(self) -> IMAPClient:
        client = IMAPClient(self.config.imap_host, port=self.config.imap_port, ssl=self.config.imap_ssl)
        client.login(self.config.imap_user, self.config.imap_password)
        client.select_folder(self.config.imap_folder)
        return client

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

    def _printer_for(self, sender_addr: str) -> Printer | None:
        """The configured device this mail came from, if any (scan-to-mail)."""
        return next((p for p in self.printers if p.matches_sender(sender_addr)), None)

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
                if self.config.imap_oversized_folder:
                    client.move([uid], self.config.imap_oversized_folder)
            return True

        raw = client.fetch([uid], ["RFC822"])[uid][b"RFC822"]
        msg = email.message_from_bytes(raw)
        message_id = _message_id(msg, uid)

        if self.store.is_processed(message_id):
            logger.info("UID %s (%s) already processed, marking seen and skipping", uid, message_id)
            client.add_flags([uid], [b"\\Seen"])
            return False

        subject = decode_mime_words(msg.get("Subject"))
        _, sender_addr = parseaddr(decode_mime_words(msg.get("From")))
        body = self._extract_body(msg) if self.config.match_body else ""
        mail_target = self.mapping.resolve(subject, body, account=self.config.account_id)

        # A mail from a known device (scan-to-mail) with a fixed folder goes
        # there regardless of keywords: scanner filenames like "SKM_C250i.pdf"
        # carry no information, and a chance keyword hit would be worse than
        # no match at all.
        printer = self._printer_for(sender_addr)
        forced_target: Target | None = None
        if printer is not None:
            logger.info("UID %s '%s' comes from device '%s'", uid, subject, printer.display_name())
            if printer.has_fixed_target:
                forced_target = Target(
                    folder=printer.target_folder,
                    share=printer.target_share,
                    keyword=f"drucker:{printer.id}",
                )

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

                target, quarantined = self.filer.classify(
                    filename,
                    mail_target,
                    account=self.config.account_id,
                    forced_target=forced_target,
                )
                target_dir = self.filer.directory_for(target, quarantined)
                out_name = self.filer.build_filename(date_prefix, sender_addr, filename)

                if self.config.dry_run:
                    logger.info("[dry-run] would save %s -> %s", out_name, target_dir)
                    continue

                out_path = self.filer.save_bytes(target_dir, out_name, payload)
                logger.info(
                    "UID %s '%s': attachment '%s' matched '%s'%s -> %s",
                    uid,
                    subject,
                    filename,
                    target.keyword or "<fallback>",
                    " [QUARANTAENE: gesperrte Dateiendung]" if quarantined else "",
                    out_path,
                )

        if not self.config.dry_run:
            self.store.mark_processed(message_id)
            client.add_flags([uid], [b"\\Seen"])
            if self.config.imap_processed_folder:
                client.move([uid], self.config.imap_processed_folder)
        return True

    @staticmethod
    def _date_prefix(msg: Message) -> str:
        date_header = msg.get("Date")
        if date_header:
            try:
                return parsedate_to_datetime(date_header).strftime("%Y-%m-%d")
            except (TypeError, ValueError):
                pass
        return "unknown-date"

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

# --- mail2nas/printers.py ---
cat > mail2nas/printers.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import os
import time
from datetime import datetime
from pathlib import Path

from .config import Config
from .filing import Filer
from .mapping import Mapping, Target
from .settings import Printer, Settings
from .shares import ShareSet

logger = logging.getLogger(__name__)

# Names that are never a finished document: dotfiles (including our own
# ".mail2nas-tmp-*"), plus the suffixes printers and SMB clients use while a
# file is still being written.
_IGNORED_SUFFIXES = (".tmp", ".part", ".partial", ".crdownload", ".filepart", ".lock")
_MAX_DEPTH = 8


class PrinterPickup:
    """Imports documents that devices drop into a folder on a share.

    Multifunction printers can usually either mail their scans or write them
    straight onto an SMB share ("Scan to Folder"). The second way never
    involves a mailbox, so this walks each device's pickup folder and files
    what it finds with exactly the same rules the mail path uses.

    Files are moved out of the pickup folder, not copied: it is the device's
    outbox, and leaving the original behind would re-import it forever. A file
    is only touched once it has been untouched for `printer_min_age_seconds`,
    so a scan that is still being transferred is left alone.

    No size limit applies here (unlike mail attachments): the file is already
    on a local mount, and it is streamed rather than read into memory.
    """

    def __init__(
        self,
        config: Config,
        settings: Settings,
        mapping: Mapping,
        shares: ShareSet,
        filer: Filer | None = None,
    ):
        self.config = config
        self.settings = settings
        self.mapping = mapping
        self.shares = shares
        self.filer = filer or Filer(config, mapping, shares)
        # Remembers the last problem reported per printer, so a folder that
        # stays unreachable is logged once instead of on every cycle.
        self._reported: dict[str, str] = {}

    # --- public ----------------------------------------------------------

    def run_once(self) -> int:
        """Import everything that is ready. Returns the number of files filed."""
        printers = self.settings.pickup_printers()
        if not printers:
            return 0
        self.mapping.reload()
        total = 0
        for printer in printers:
            try:
                total += self._import(printer)
            except Exception:
                logger.exception("[%s] pickup failed, retrying next cycle", printer.id)
        return total

    # --- internals -------------------------------------------------------

    def _report(self, printer: Printer, problem: str | None) -> None:
        if problem is None:
            if self._reported.pop(printer.id, None):
                logger.info("[%s] pickup folder is reachable again", printer.id)
            return
        if self._reported.get(printer.id) != problem:
            logger.warning("[%s] %s", printer.id, problem)
            self._reported[printer.id] = problem

    def source_dir(self, printer: Printer) -> Path | None:
        """The device's pickup folder, or None if it is not usable right now."""
        problem = self.shares.problem_with(printer.source_share)
        if problem:
            self._report(printer, f"Quell-Ablage nicht verfuegbar: {problem}")
            return None
        try:
            directory = self.shares.resolve(printer.source_share, printer.source_folder)
        except ValueError as exc:
            self._report(printer, f"Abholordner nicht zulaessig: {exc}")
            return None
        if not directory.is_dir():
            self._report(printer, f"Abholordner {directory} existiert nicht")
            return None
        if not os.access(directory, os.W_OK | os.X_OK):
            # Importing means removing the original, which needs write access
            # to the folder it is in - not just to the file.
            self._report(
                printer,
                f"Abholordner {directory} ist nicht beschreibbar - abgeholte Dateien "
                "koennten nicht entfernt werden",
            )
            return None
        self._report(printer, None)
        return directory

    def _ready_files(self, directory: Path) -> list[Path]:
        """Files in the pickup folder that are complete enough to be moved."""
        min_age = max(0, self.settings.printer_min_age_seconds)
        deadline = time.time() - min_age
        ready: list[Path] = []
        root_depth = len(directory.parts)
        for dirpath, dirnames, filenames in os.walk(directory):
            here = Path(dirpath)
            if len(here.parts) - root_depth >= _MAX_DEPTH:
                dirnames[:] = []
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for name in sorted(filenames):
                if name.startswith(".") or name.lower().endswith(_IGNORED_SUFFIXES):
                    continue
                path = here / name
                try:
                    stat = path.stat()
                except OSError:
                    continue  # vanished between listing and stat
                if not path.is_file() or stat.st_size == 0:
                    continue
                if stat.st_mtime > deadline:
                    logger.debug("%s is still being written, waiting", path)
                    continue
                ready.append(path)
        return ready

    def _import(self, printer: Printer) -> int:
        directory = self.source_dir(printer)
        if directory is None:
            return 0

        forced: Target | None = None
        if printer.has_fixed_target:
            forced = Target(
                folder=printer.target_folder,
                share=printer.target_share,
                keyword=f"drucker:{printer.id}",
            )
        fallback = Target(folder=self.config.fallback_folder, share=printer.target_share)

        filed = 0
        for path in self._ready_files(directory):
            try:
                target, quarantined = self.filer.classify(
                    path.name, fallback, account=self.rule_scope(printer), forced_target=forced
                )
                target_dir = self.filer.directory_for(target, quarantined)
                if self._would_loop(directory, target_dir):
                    logger.error(
                        "[%s] target folder %s is inside the pickup folder - skipping %s",
                        printer.id,
                        target_dir,
                        path.name,
                    )
                    continue

                date_prefix = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d")
                out_name = self.filer.build_filename(date_prefix, printer.id, path.name)

                if self.config.dry_run:
                    logger.info("[dry-run] [%s] would move %s -> %s", printer.id, path, target_dir)
                    continue

                out_path = self.filer.move_file(path, target_dir, out_name)
                filed += 1
                logger.info(
                    "[%s] '%s' matched '%s'%s -> %s",
                    printer.id,
                    path.name,
                    target.keyword or "<fallback>",
                    " [QUARANTAENE: gesperrte Dateiendung]" if quarantined else "",
                    out_path,
                )
            except Exception:
                logger.exception("[%s] could not file %s, leaving it in place", printer.id, path)
        return filed

    @staticmethod
    def rule_scope(printer: Printer) -> str:
        """The account id a pickup files under.

        A document dropped into a folder did not arrive through any mailbox,
        so only rules that apply to "all accounts" may claim it. Account ids
        never contain a colon, so this never collides with a real one.
        """
        return f"drucker:{printer.id}"

    @staticmethod
    def _would_loop(pickup_dir: Path, target_dir: Path) -> bool:
        """True if filing would leave the document inside the pickup folder."""
        try:
            target_dir.resolve().relative_to(pickup_dir.resolve())
            return True
        except (ValueError, OSError):
            return False
MAIL2NAS_EOF

# --- mail2nas/runner.py ---
cat > mail2nas/runner.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import threading
import time

from .archiver import Archiver
from .config import Config
from .mapping import Mapping
from .printers import PrinterPickup
from .settings import Account, Printer, Settings
from .shares import ShareSet
from .state import ProcessedStore

logger = logging.getLogger(__name__)

# A folder a device writes into should be emptied promptly even when mail is
# only polled every few minutes: walking a directory is cheap, an IMAP session
# is not.
MAX_PICKUP_INTERVAL = 60


class AccountWorker(threading.Thread):
    """Runs one mail account's connect/process loop until asked to stop."""

    def __init__(
        self,
        config: Config,
        account: Account,
        mapping: Mapping,
        store: ProcessedStore,
        shares: ShareSet | None = None,
        printers: list[Printer] | None = None,
    ):
        super().__init__(name=f"mail2nas-{account.id}", daemon=True)
        self.config = config
        self.account = account
        self.archiver = Archiver(config, mapping, store, shares=shares, printers=printers)
        self._stop_event = threading.Event()
        self.last_error: str | None = None

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        logger.info(
            "[%s] starting: imap=%s folder=%s mode=%s",
            self.account.id,
            self.account.host,
            self.account.folder,
            self.account.mode,
        )
        while not self._stop_event.is_set():
            client = None
            try:
                client = self.archiver.connect()
                self.last_error = None
                if self.config.imap_mode == "idle":
                    self._loop_idle(client)
                else:
                    self._loop_poll(client)
            except Exception as exc:
                self.last_error = str(exc)
                logger.exception(
                    "[%s] session failed, retrying in %ss", self.account.id, self.config.poll_interval
                )
            finally:
                if client is not None:
                    try:
                        client.logout()
                    except Exception:
                        pass
            # Interruptible sleep, so a reload/shutdown does not wait it out.
            self._stop_event.wait(self.config.poll_interval)
        logger.info("[%s] stopped", self.account.id)

    def _process(self, client) -> None:
        count = self.archiver.run_once(client)
        if count:
            logger.info("[%s] processed %d message(s)", self.account.id, count)

    def _loop_poll(self, client) -> None:
        while not self._stop_event.is_set():
            self._process(client)
            self._stop_event.wait(self.config.poll_interval)

    def _loop_idle(self, client) -> None:
        self._process(client)
        timeout = self.config.poll_interval or 300
        while not self._stop_event.is_set():
            client.idle()
            try:
                client.idle_check(timeout=timeout)
            finally:
                client.idle_done()
            self._process(client)


class PrinterWorker(threading.Thread):
    """Empties the pickup folders of all devices that write to a share."""

    def __init__(self, pickup: PrinterPickup, interval: int):
        super().__init__(name="mail2nas-drucker", daemon=True)
        self.pickup = pickup
        self.interval = max(1, min(interval, MAX_PICKUP_INTERVAL))
        self._stop_event = threading.Event()
        self.last_error: str | None = None
        self.filed = 0

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        names = ", ".join(p.display_name() for p in self.pickup.settings.pickup_printers())
        logger.info("[drucker] watching pickup folders every %ss: %s", self.interval, names)
        while not self._stop_event.is_set():
            try:
                count = self.pickup.run_once()
                self.last_error = None
                if count:
                    self.filed += count
                    logger.info("[drucker] filed %d document(s)", count)
            except Exception as exc:
                self.last_error = str(exc)
                logger.exception("[drucker] pickup cycle failed")
            self._stop_event.wait(self.interval)
        logger.info("[drucker] stopped")


class Runner:
    """Owns one worker per enabled account and can restart them on changes."""

    def __init__(self, config: Config, settings: Settings, mapping: Mapping, store: ProcessedStore):
        self.config = config
        self.settings = settings
        self.mapping = mapping
        self.store = store
        self.shares = ShareSet.from_settings(settings, config.storage_root)
        self._workers: list[AccountWorker] = []
        self._printer_worker: PrinterWorker | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            self._start_locked()

    def _start_locked(self) -> None:
        printers = self.settings.mail_printers()
        accounts = self.settings.enabled_accounts()
        if not accounts:
            logger.warning("No enabled mail accounts configured - nothing to archive yet")
        for account in accounts:
            worker = AccountWorker(
                self.settings.config_for(self.config, account),
                account,
                self.mapping,
                self.store,
                shares=self.shares,
                printers=printers,
            )
            worker.start()
            self._workers.append(worker)

        if self.settings.pickup_printers():
            pickup = PrinterPickup(
                self.settings.config_common(self.config), self.settings, self.mapping, self.shares
            )
            self._printer_worker = PrinterWorker(pickup, self.settings.poll_interval)
            self._printer_worker.start()

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _stop_locked(self) -> None:
        workers: list[threading.Thread] = list(self._workers)
        if self._printer_worker is not None:
            workers.append(self._printer_worker)
        for worker in workers:
            worker.stop()
        for worker in workers:
            worker.join(timeout=10)
        self._workers = []
        self._printer_worker = None

    def reload(self, settings: Settings) -> None:
        """Apply changed settings by restarting the account workers."""
        with self._lock:
            logger.info("Applying changed settings - restarting workers")
            self._stop_locked()
            self.settings = settings
            self.shares = ShareSet.from_settings(settings, self.config.storage_root)
            self.mapping.set_fallback_folder(settings.fallback_folder)
            self.mapping.set_path(str(self.mapping_full_path(settings)))
            self._start_locked()

    def mapping_full_path(self, settings: Settings):
        from .filenames import safe_join

        # Anchored to STORAGE_ROOT, not to whichever share happens to be the
        # default one: the rules must stay where they are when shares change.
        return safe_join(self.config.storage_root, settings.mapping_path)

    def status(self) -> list[dict]:
        with self._lock:
            entries = [
                {
                    "id": w.account.id,
                    "label": w.account.display_name(),
                    "alive": w.is_alive(),
                    "error": w.last_error,
                }
                for w in self._workers
            ]
            if self._printer_worker is not None:
                entries.append(
                    {
                        "id": "drucker",
                        "label": "Drucker-Abholordner",
                        "alive": self._printer_worker.is_alive(),
                        "error": self._printer_worker.last_error,
                    }
                )
            return entries

    def wait(self) -> None:
        """Block the main thread while the workers do their thing."""
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            self.stop()
MAIL2NAS_EOF

# --- mail2nas/web.py ---
cat > mail2nas/web.py <<'MAIL2NAS_EOF'
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
MAIL2NAS_EOF

# --- mail2nas/main.py ---
cat > mail2nas/main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import os
import sys
import threading
from pathlib import Path

from .config import Config
from .filenames import safe_join
from .mapping import Mapping
from .runner import Runner
from .settings import Settings
from .shares import ShareSet
from .state import ProcessedStore

logger = logging.getLogger("mail2nas")


def _check_storage_root(config: Config) -> None:
    """Fail fast if the archive target is missing or read-only.

    Without this, a share that failed to mount is indistinguishable from an
    empty one: attachments would be written into the container's own
    filesystem and quietly vanish with the container.
    """
    root = Path(config.storage_root)
    if not root.is_dir():
        raise SystemExit(
            f"STORAGE_ROOT {config.storage_root} does not exist or is not a directory - "
            "is the SMB share mounted?"
        )
    if not os.access(root, os.W_OK | os.X_OK):
        raise SystemExit(
            f"STORAGE_ROOT {config.storage_root} is not writable by uid {os.getuid()} - "
            "check the mount options (uid/gid/file_mode) and the share permissions."
        )


def _check_shares(settings: Settings, config: Config) -> None:
    """Report additional shares that are not mounted, without refusing to start.

    STORAGE_ROOT is fatal when it is missing (see _check_storage_root) because
    nothing can be archived at all. A second NAS being down is different: the
    rest keeps working, and documents for the missing share are diverted to
    the default one rather than written into an empty mount point.
    """
    shares = ShareSet.from_settings(settings, config.storage_root)
    for status in shares.status():
        if not status.enabled:
            logger.info("Share '%s' (%s) is disabled", status.label, status.path)
        elif status.problem:
            logger.error("Share '%s' is not usable: %s", status.label, status.problem)
        else:
            logger.info("Share '%s' -> %s", status.label, status.path)


def _start_web(config: Config, settings: Settings, mapping: Mapping, runner: Runner) -> None:
    """Serve the configuration UI in a background thread, if it is configured."""
    if not config.web_enabled:
        logger.info("Web UI disabled (WEB_ENABLED=false)")
        return
    if not config.web_password:
        # The page shows and edits IMAP credentials, so refuse to serve it
        # without authentication rather than defaulting to something weak.
        logger.warning(
            "Web UI not started: WEB_PASSWORD is empty. Set it to enable the configuration page."
        )
        return

    try:
        from waitress import serve

        from .web import create_app
    except ImportError:
        logger.warning("Web UI not started: Flask/waitress are not installed")
        return

    app = create_app(config, settings, mapping, runner)

    def _serve() -> None:
        logger.info("Web UI on http://%s:%s", config.web_host, config.web_port)
        serve(app, host=config.web_host, port=config.web_port, threads=4, _quiet=True)

    threading.Thread(target=_serve, name="mail2nas-web", daemon=True).start()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    _check_storage_root(config)

    settings = Settings.load(config)
    _check_shares(settings, config)
    try:
        mapping_full_path = safe_join(config.storage_root, settings.mapping_path)
    except ValueError as exc:
        raise SystemExit(f"Configured mapping path is not usable: {exc}") from None
    mapping = Mapping(str(mapping_full_path), settings.fallback_folder)
    store = ProcessedStore(config.state_db_path)

    logger.info(
        "Starting mail2nas: %d account(s), %d device(s), %d share(s), dry_run=%s",
        len(settings.enabled_accounts()),
        len(settings.enabled_printers()),
        len(settings.enabled_shares()),
        config.dry_run,
    )

    runner = Runner(config, settings, mapping, store)
    _start_web(config, settings, mapping, runner)
    runner.start()

    try:
        runner.wait()
    finally:
        runner.stop()
        store.close()


if __name__ == "__main__":
    main()
MAIL2NAS_EOF

# --- mail2nas/templates/base.html ---
cat > mail2nas/templates/base.html <<'MAIL2NAS_EOF'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>mail2nas</title>
<style>
  :root { --bg:#f5f6f8; --fg:#1d2129; --muted:#6b7280; --line:#d8dbe0;
          --card:#fff; --accent:#2d6cdf; --err:#b3261e; --ok:#1b6b3a; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#16181c; --fg:#e6e8eb; --muted:#9aa0a6; --line:#333840;
            --card:#1e2126; --accent:#6ea3ff; --err:#f2a9a2; --ok:#7bd3a0; }
  }
  * { box-sizing:border-box; }
  body { margin:0; background:var(--bg); color:var(--fg); font:15px/1.5 system-ui,sans-serif; }
  header { background:var(--card); border-bottom:1px solid var(--line); padding:0 16px;
           display:flex; align-items:center; gap:20px; flex-wrap:wrap; }
  header h1 { font-size:17px; margin:14px 0; }
  nav a { color:var(--fg); text-decoration:none; padding:16px 4px; display:inline-block;
          border-bottom:2px solid transparent; }
  nav a.active { border-bottom-color:var(--accent); }
  main { max-width:960px; margin:0 auto; padding:20px 16px 60px; }
  .card { background:var(--card); border:1px solid var(--line); border-radius:8px;
          padding:16px; margin-bottom:18px; }
  h2 { font-size:16px; margin:0 0 12px; }
  table { width:100%; border-collapse:collapse; }
  th,td { text-align:left; padding:7px 8px; border-bottom:1px solid var(--line);
          vertical-align:middle; }
  th { color:var(--muted); font-weight:600; font-size:13px; }
  input[type=text],input[type=password],input[type=number],select {
    width:100%; padding:6px 8px; border:1px solid var(--line); border-radius:5px;
    background:var(--bg); color:var(--fg); font:inherit; }
  button { font:inherit; padding:6px 12px; border-radius:5px; border:1px solid var(--line);
           background:var(--card); color:var(--fg); cursor:pointer; }
  button.primary { background:var(--accent); border-color:var(--accent); color:#fff; }
  button.icon { padding:4px 9px; line-height:1.1; }
  button.danger { color:var(--err); }
  .row { display:flex; gap:10px; flex-wrap:wrap; align-items:flex-end; }
  .row > div { flex:1 1 160px; }
  label { display:block; font-size:13px; color:var(--muted); margin-bottom:3px; }
  .flash { padding:9px 12px; border-radius:6px; margin-bottom:12px; }
  .flash.error { background:rgba(179,38,30,.12); color:var(--err); }
  .flash.ok { background:rgba(27,107,58,.12); color:var(--ok); }
  .hint { color:var(--muted); font-size:13px; }
  code { background:var(--bg); padding:1px 5px; border-radius:4px; font-size:13px; }
  .dot { display:inline-block; width:8px; height:8px; border-radius:50%; margin-right:6px; }
  .dot.up { background:var(--ok); } .dot.down { background:var(--err); }
  .inline { display:inline; }
  .prio { color:var(--muted); font-variant-numeric:tabular-nums; width:2em; }
  @media (max-width:640px) { table, thead, tbody, th, td, tr { display:block; }
    thead { display:none; } td { border:none; padding:4px 0; }
    tr { border-bottom:1px solid var(--line); padding:10px 0; } }
</style>
</head>
<body>
<header>
  <h1>mail2nas</h1>
  <nav>
    <a href="{{ url_for('index') }}" class="{{ 'active' if request.endpoint=='index' }}">Zuordnungen</a>
    <a href="{{ url_for('accounts_page') }}" class="{{ 'active' if request.endpoint=='accounts_page' }}">Mailkonten</a>
    <a href="{{ url_for('printers_page') }}" class="{{ 'active' if request.endpoint=='printers_page' }}">Drucker</a>
    <a href="{{ url_for('shares_page') }}" class="{{ 'active' if request.endpoint=='shares_page' }}">Ablagen</a>
    <a href="{{ url_for('settings_page') }}" class="{{ 'active' if request.endpoint=='settings_page' }}">Einstellungen</a>
  </nav>
  <form method="post" action="{{ url_for('logout') }}" style="margin-left:auto">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    <button>Abmelden</button>
  </form>
</header>
<main>
  {% with messages = get_flashed_messages(with_categories=true) %}
    {% for category, message in messages %}
      <div class="flash {{ category }}">{{ message }}</div>
    {% endfor %}
  {% endwith %}
  {% block content %}{% endblock %}
</main>
</body>
</html>
MAIL2NAS_EOF

# --- mail2nas/templates/macros.html ---
cat > mail2nas/templates/macros.html <<'MAIL2NAS_EOF'
{# Shared form snippets. Imported "with context" so the injected share list
   and DEFAULT_SHARE are available inside. #}
{% macro share_select(name, selected, default_label='Standard-Ablage') -%}
  <select name="{{ name }}">
    <option value="{{ DEFAULT_SHARE }}" {{ 'selected' if not selected }}>{{ default_label }}</option>
    {% for s in shares %}
      <option value="{{ s.id }}" {{ 'selected' if selected == s.id }}>{{ s.display_name() }}{{ '' if s.enabled else ' (inaktiv)' }}</option>
    {% endfor %}
  </select>
{%- endmacro %}
MAIL2NAS_EOF

# --- mail2nas/templates/login.html ---
cat > mail2nas/templates/login.html <<'MAIL2NAS_EOF'
<!doctype html>
<html lang="de">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>mail2nas - Anmeldung</title>
<style>
  :root { --bg:#f5f6f8; --fg:#1d2129; --muted:#6b7280; --line:#d8dbe0; --card:#fff;
          --accent:#2d6cdf; --err:#b3261e; }
  @media (prefers-color-scheme: dark) {
    :root { --bg:#16181c; --fg:#e6e8eb; --muted:#9aa0a6; --line:#333840; --card:#1e2126;
            --accent:#6ea3ff; --err:#f2a9a2; }
  }
  * { box-sizing:border-box; }
  body { margin:0; min-height:100vh; display:flex; align-items:center; justify-content:center;
         background:var(--bg); color:var(--fg); font:15px/1.5 system-ui,sans-serif; padding:20px; }
  form { background:var(--card); border:1px solid var(--line); border-radius:8px;
         padding:24px; width:100%; max-width:340px; }
  h1 { font-size:17px; margin:0 0 18px; }
  label { display:block; font-size:13px; color:var(--muted); margin:12px 0 3px; }
  input { width:100%; padding:8px; border:1px solid var(--line); border-radius:5px;
          background:var(--bg); color:var(--fg); font:inherit; }
  button { width:100%; margin-top:18px; padding:9px; border-radius:5px; border:none;
           background:var(--accent); color:#fff; font:inherit; cursor:pointer; }
  .flash { margin-top:14px; padding:8px 10px; border-radius:6px;
           background:rgba(179,38,30,.12); color:var(--err); font-size:14px; }
</style>
</head>
<body>
<form method="post">
  <h1>mail2nas</h1>
  <label for="user">Benutzer</label>
  <input id="user" type="text" name="user" autocomplete="username" autofocus required>
  <label for="password">Passwort</label>
  <input id="password" type="password" name="password" autocomplete="current-password" required>
  <button>Anmelden</button>
  {% with messages = get_flashed_messages() %}
    {% for message in messages %}<div class="flash">{{ message }}</div>{% endfor %}
  {% endwith %}
</form>
</body>
</html>
MAIL2NAS_EOF

# --- mail2nas/templates/rules.html ---
cat > mail2nas/templates/rules.html <<'MAIL2NAS_EOF'
{% extends "base.html" %}
{% import "macros.html" as m with context %}
{% set multi_share = shares|length > 1 %}
{% block content %}

{% if status %}
<div class="card">
  <h2>Status</h2>
  {% for s in status %}
    <div><span class="dot {{ 'up' if s.alive else 'down' }}"></span>{{ s.label }}
      {% if s.error %}<span class="hint">- letzter Fehler: {{ s.error }}</span>{% endif %}
    </div>
  {% endfor %}
</div>
{% endif %}

<div class="card">
  <h2>Zuordnungen</h2>
  <p class="hint">
    Die <strong>Reihenfolge bestimmt die Prioritaet</strong>: die erste passende Regel gewinnt.
    Mit den Pfeilen verschieben. Gross-/Kleinschreibung ist egal.
    Platzhalter moeglich: <code>*</code> (beliebig viele Zeichen), <code>?</code> (ein Zeichen) -
    z. B. <code>Rechnung*</code>. Ohne Platzhalter wird als Teilstring gesucht.
    Geprueft wird zuerst der Dateiname jedes Anhangs, dann Betreff (und Mailtext, falls aktiviert).
  </p>
  {% if multi_share %}
  <p class="hint">
    <strong>Ablage</strong> bestimmt, auf welches NAS/Share der Zielordner gehoert.
    „Standard-Ablage“ ist die erste aktive Ablage.
  </p>
  {% endif %}
  <p class="hint">Datei: <code>{{ mapping_path }}</code></p>

  <table>
    <thead>
      <tr><th></th><th>Stichwort / Muster</th><th>Zielordner</th>{% if multi_share %}<th>Ablage</th>{% endif %}<th>Konto</th><th></th></tr>
    </thead>
    <tbody>
    {% for rule in rules %}
      <tr>
        <td class="prio">{{ loop.index }}</td>
        <td colspan="{{ 4 if multi_share else 3 }}">
          <form method="post" action="{{ url_for('rule_update', index=loop.index0) }}" class="row">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <div><input type="text" name="match" value="{{ rule.match }}" required></div>
            <div><input type="text" name="folder" value="{{ rule.folder }}" required></div>
            {% if multi_share %}
              <div>{{ m.share_select('share', rule.share) }}</div>
            {% else %}
              <input type="hidden" name="share" value="{{ rule.share }}">
            {% endif %}
            <div>
              <select name="account">
                <option value="{{ ALL_ACCOUNTS }}" {{ 'selected' if rule.account == ALL_ACCOUNTS }}>Alle Konten</option>
                {% for a in accounts %}
                  <option value="{{ a.id }}" {{ 'selected' if rule.account == a.id }}>{{ a.display_name() }}</option>
                {% endfor %}
              </select>
            </div>
            <div style="flex:0 0 auto"><button class="primary">Speichern</button></div>
          </form>
        </td>
        <td style="white-space:nowrap">
          <form method="post" action="{{ url_for('rule_move', index=loop.index0, direction='up') }}" class="inline">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <button class="icon" title="Nach oben" {{ 'disabled' if loop.first }}>&uarr;</button>
          </form>
          <form method="post" action="{{ url_for('rule_move', index=loop.index0, direction='down') }}" class="inline">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <button class="icon" title="Nach unten" {{ 'disabled' if loop.last }}>&darr;</button>
          </form>
          <form method="post" action="{{ url_for('rule_delete', index=loop.index0) }}" class="inline"
                onsubmit="return confirm('Zuordnung „{{ rule.match }}“ wirklich loeschen?')">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <button class="icon danger" title="Loeschen">&times;</button>
          </form>
        </td>
      </tr>
    {% else %}
      <tr><td colspan="6" class="hint">Noch keine Zuordnungen. Alle Anhaenge landen im Fallback-Ordner.</td></tr>
    {% endfor %}
    </tbody>
  </table>
</div>

<div class="card">
  <h2>Neue Zuordnung</h2>
  <form method="post" action="{{ url_for('rule_add') }}" class="row">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    <div>
      <label>Stichwort / Muster</label>
      <input type="text" name="match" placeholder="z. B. Rechnung*" required>
    </div>
    <div>
      <label>Zielordner</label>
      <input type="text" name="folder" placeholder="z. B. rechnungen" required>
    </div>
    {% if multi_share %}
    <div>
      <label>Ablage</label>
      {{ m.share_select('share', '') }}
    </div>
    {% endif %}
    <div>
      <label>Gilt fuer</label>
      <select name="account">
        <option value="{{ ALL_ACCOUNTS }}">Alle Konten</option>
        {% for a in accounts %}<option value="{{ a.id }}">{{ a.display_name() }}</option>{% endfor %}
      </select>
    </div>
    <div style="flex:0 0 auto"><button class="primary">Hinzufuegen</button></div>
  </form>
  <p class="hint">Neue Zuordnungen landen am Ende der Liste, also mit der niedrigsten Prioritaet.</p>
</div>

{% endblock %}
MAIL2NAS_EOF

# --- mail2nas/templates/accounts.html ---
cat > mail2nas/templates/accounts.html <<'MAIL2NAS_EOF'
{% extends "base.html" %}
{% macro account_form(a=None, title='Neues Mailkonto') %}
  <form method="post" action="{{ url_for('account_save') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    <input type="hidden" name="id" value="{{ a.id if a else '' }}">
    <div class="row">
      <div>
        <label>Bezeichnung</label>
        <input type="text" name="label" value="{{ a.label if a else '' }}" placeholder="z. B. Buchhaltung">
      </div>
      <div>
        <label>IMAP-Server</label>
        <input type="text" name="host" value="{{ a.host if a else '' }}" placeholder="imap.example.com" required>
      </div>
      <div style="flex:0 0 90px">
        <label>Port</label>
        <input type="number" name="port" value="{{ a.port if a else 993 }}" min="1" max="65535">
      </div>
    </div>
    <div class="row">
      <div>
        <label>Benutzer</label>
        <input type="text" name="user" value="{{ a.user if a else '' }}" required>
      </div>
      <div>
        <label>Passwort {% if a %}<span class="hint">(leer = unveraendert)</span>{% endif %}</label>
        <input type="password" name="password" autocomplete="new-password" {{ 'required' if not a }}>
      </div>
    </div>
    <div class="row">
      <div>
        <label>Zu ueberwachender Ordner</label>
        <input type="text" name="folder" value="{{ a.folder if a else 'INBOX' }}">
      </div>
      <div>
        <label>Verarbeitete Mails verschieben nach</label>
        <input type="text" name="processed_folder" value="{{ a.processed_folder if a else '' }}" placeholder="leer = nur als gelesen markieren">
      </div>
      <div>
        <label>Zu grosse Mails verschieben nach</label>
        <input type="text" name="oversized_folder" value="{{ a.oversized_folder if a else '' }}" placeholder="optional">
      </div>
    </div>
    <div class="row">
      <div style="flex:0 0 150px">
        <label>Abrufmodus</label>
        <select name="mode">
          <option value="poll" {{ 'selected' if not a or a.mode == 'poll' }}>Polling</option>
          <option value="idle" {{ 'selected' if a and a.mode == 'idle' }}>IDLE (Push)</option>
        </select>
      </div>
      <div style="flex:0 0 auto; padding-bottom:6px">
        <label>&nbsp;</label>
        <label class="hint"><input type="checkbox" name="ssl" {{ 'checked' if not a or a.ssl }}> TLS/SSL</label>
      </div>
      <div style="flex:0 0 auto; padding-bottom:6px">
        <label>&nbsp;</label>
        <label class="hint"><input type="checkbox" name="enabled" {{ 'checked' if not a or a.enabled }}> Aktiv</label>
      </div>
      <div style="flex:0 0 auto"><button class="primary">Speichern</button></div>
    </div>
  </form>
{% endmacro %}

{% block content %}

{% for a in accounts %}
  <div class="card">
    <h2>
      {% for s in status %}{% if s.id == a.id %}<span class="dot {{ 'up' if s.alive else 'down' }}"></span>{% endif %}{% endfor %}
      {{ a.display_name() }}
      <span class="hint">- id: <code>{{ a.id }}</code></span>
    </h2>
    {{ account_form(a) }}
    <form method="post" action="{{ url_for('account_delete', account_id=a.id) }}" style="margin-top:10px"
          onsubmit="return confirm('Konto „{{ a.display_name() }}“ wirklich loeschen? Daran gebundene Zuordnungen gelten danach fuer alle Konten.')">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <button class="danger">Konto loeschen</button>
    </form>
  </div>
{% endfor %}

<div class="card">
  <h2>Neues Mailkonto</h2>
  {{ account_form() }}
  <p class="hint">
    Nach dem Speichern kannst du jede Zuordnung ueber das Dropdown auf ein einzelnes
    Konto begrenzen - oder auf „Alle Konten“ stehen lassen.
  </p>
</div>

{% endblock %}
MAIL2NAS_EOF

# --- mail2nas/templates/printers.html ---
cat > mail2nas/templates/printers.html <<'MAIL2NAS_EOF'
{% extends "base.html" %}
{% import "macros.html" as m with context %}
{% macro printer_form(p=None) %}
  <form method="post" action="{{ url_for('printer_save') }}">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    <input type="hidden" name="id" value="{{ p.id if p else '' }}">
    <div class="row">
      <div>
        <label>Bezeichnung</label>
        <input type="text" name="label" value="{{ p.label if p else '' }}" placeholder="z. B. Kopierer Flur" required>
      </div>
      <div>
        <label>Absenderadresse (Scan-to-Mail)</label>
        <input type="text" name="sender" value="{{ p.sender if p else '' }}" placeholder="scanner@example.com, @scanner.lan oder kopierer-*@example.com">
      </div>
    </div>
    <div class="row">
      <div style="flex:0 0 200px">
        <label>Abholordner liegt auf</label>
        {{ m.share_select('source_share', p.source_share if p else '') }}
      </div>
      <div>
        <label>Abholordner (Scan-to-Folder)</label>
        <input type="text" name="source_folder" value="{{ p.source_folder if p else '' }}" placeholder="z. B. scans/kopierer-flur">
      </div>
    </div>
    <div class="row">
      <div style="flex:0 0 200px">
        <label>Ablage fuer die Dokumente</label>
        {{ m.share_select('target_share', p.target_share if p else '') }}
      </div>
      <div>
        <label>Zielordner <span class="hint">(leer = nach Stichwortregeln)</span></label>
        <input type="text" name="target_folder" value="{{ p.target_folder if p else '' }}" placeholder="z. B. scans">
      </div>
      <div style="flex:0 0 auto; padding-bottom:6px">
        <label>&nbsp;</label>
        <label class="hint"><input type="checkbox" name="enabled" {{ 'checked' if not p or p.enabled }}> Aktiv</label>
      </div>
      <div style="flex:0 0 auto"><button class="primary">Speichern</button></div>
    </div>
  </form>
{% endmacro %}

{% block content %}

{% if status %}
<div class="card">
  <h2>Status</h2>
  {% for s in status %}
    {% if s.id == 'drucker' %}
      <div><span class="dot {{ 'up' if s.alive else 'down' }}"></span>{{ s.label }}
        {% if s.error %}<span class="hint">- letzter Fehler: {{ s.error }}</span>{% endif %}
      </div>
    {% endif %}
  {% endfor %}
</div>
{% endif %}

<div class="card">
  <h2>Drucker und Scanner</h2>
  <p class="hint">
    Multifunktionsgeraete liefern Scans auf zwei Wegen - beide lassen sich hier anlegen,
    einzeln oder zusammen:
  </p>
  <p class="hint">
    <strong>Scan-to-Mail:</strong> das Geraet schickt den Scan per Mail. Die
    <em>Absenderadresse</em> erkennt es wieder, sodass seine Dokumente unabhaengig vom
    (meist nichtssagenden) Dateinamen abgelegt werden. Die Mail muss ueber eines der
    Mailkonten hereinkommen.
  </p>
  <p class="hint">
    <strong>Scan-to-Folder:</strong> das Geraet legt den Scan direkt auf dem lokalen NAS ab.
    Der <em>Abholordner</em> wird ueberwacht und fertige Dateien werden von dort in den
    Zielordner <em>verschoben</em> - dafuer braucht es kein Mailkonto.
    Eine Datei wird erst angefasst, wenn sie eine Weile unveraendert ist, damit kein halb
    uebertragener Scan abgelegt wird (Wartezeit siehe Einstellungen).
  </p>
  <p class="hint">
    Ohne Zielordner entscheiden die normalen Stichwortregeln. Dabei greifen nur Regeln,
    die fuer „Alle Konten“ gelten - ein Scan aus einem Ordner gehoert zu keinem Postfach.
    Gesperrte Dateiendungen landen auch hier in der Quarantaene.
  </p>
</div>

{% for p in printers %}
  <div class="card">
    <h2>{{ p.display_name() }} <span class="hint">- id: <code>{{ p.id }}</code></span></h2>
    <p class="hint">
      {% if p.sender %}Mail von <code>{{ p.sender }}</code>. {% endif %}
      {{ pickup_state(p) }}{% if not p.enabled %} - <strong>inaktiv</strong>{% endif %}
    </p>
    {{ printer_form(p) }}
    <form method="post" action="{{ url_for('printer_delete', printer_id=p.id) }}" style="margin-top:10px"
          onsubmit="return confirm('Drucker „{{ p.display_name() }}“ wirklich loeschen?')">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <button class="danger">Drucker loeschen</button>
    </form>
  </div>
{% endfor %}

<div class="card">
  <h2>Neuer Drucker / Scanner</h2>
  {{ printer_form() }}
</div>

{% endblock %}
MAIL2NAS_EOF

# --- mail2nas/templates/shares.html ---
cat > mail2nas/templates/shares.html <<'MAIL2NAS_EOF'
{% extends "base.html" %}
{% macro share_form(s=None) %}
  <form method="post" action="{{ url_for('share_save') }}" class="row">
    <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
    <input type="hidden" name="id" value="{{ s.id if s else '' }}">
    <div>
      <label>Bezeichnung</label>
      <input type="text" name="label" value="{{ s.label if s else '' }}" placeholder="z. B. NAS Buero">
    </div>
    <div style="flex:2 1 260px">
      <label>Mountpoint (Pfad, an dem das Share bereits gemountet ist)</label>
      <input type="text" name="path" value="{{ s.path if s else '' }}" placeholder="/mnt/nas2" required>
    </div>
    <div style="flex:0 0 auto; padding-bottom:6px">
      <label>&nbsp;</label>
      <label class="hint"><input type="checkbox" name="enabled" {{ 'checked' if not s or s.enabled }}> Aktiv</label>
    </div>
    <div style="flex:0 0 auto"><button class="primary">Speichern</button></div>
  </form>
{% endmacro %}

{% block content %}

<div class="card">
  <h2>Ablagen (NAS / Shares)</h2>
  <p class="hint">
    Anhaenge koennen auf mehrere Shares verteilt werden - auch auf verschiedene NAS.
    Jede Zuordnung und jeder Drucker waehlt eine dieser Ablagen; die <strong>erste
    aktive</strong> ist die Standard-Ablage fuer alles, was keine eigene nennt.
  </p>
  <p class="hint">
    mail2nas mountet nichts selbst. Das Share muss vom Betriebssystem gemountet sein
    (z. B. per <code>/etc/fstab</code> und Bind-Mount in den Container), hier steht nur der Pfad,
    unter dem es hier erreichbar ist. Ist ein Mountpoint nicht da oder nicht beschreibbar,
    wird auf die Standard-Ablage ausgewichen, statt ins leere Verzeichnis zu schreiben.
  </p>
  <p class="hint">
    <code>STORAGE_ROOT</code> dieser Instanz: <code>{{ storage_root }}</code> -
    dort liegt auch die Mapping-Datei.
  </p>

  <table>
    <thead><tr><th>Ablage</th><th>Pfad</th><th>Status</th></tr></thead>
    <tbody>
    {% for st in status %}
      <tr>
        <td><span class="dot {{ 'up' if st.ok and st.enabled else 'down' }}"></span>{{ st.label }}
            <span class="hint">- id: <code>{{ st.id }}</code></span></td>
        <td><code>{{ st.path }}</code></td>
        <td class="hint">
          {% if not st.enabled %}inaktiv
          {% elif st.problem %}{{ st.problem }}
          {% else %}gemountet und beschreibbar{% endif %}
        </td>
      </tr>
    {% endfor %}
    </tbody>
  </table>
</div>

{% for s in shares %}
  <div class="card">
    <h2>{{ s.display_name() }} <span class="hint">- id: <code>{{ s.id }}</code></span></h2>
    {{ share_form(s) }}
    {% if shares|length > 1 %}
    <form method="post" action="{{ url_for('share_delete', share_id=s.id) }}" style="margin-top:10px"
          onsubmit="return confirm('Ablage „{{ s.display_name() }}“ wirklich loeschen? Daran gebundene Zuordnungen nutzen danach die Standard-Ablage.')">
      <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
      <button class="danger">Ablage loeschen</button>
    </form>
    {% endif %}
  </div>
{% endfor %}

<div class="card">
  <h2>Neue Ablage</h2>
  {{ share_form() }}
  <p class="hint">
    Beispiel: ein zweites NAS liegt auf dem Host unter <code>/mnt/nas2</code> und ist in den
    Container gemountet - dann hier <code>/mnt/nas2</code> eintragen.
  </p>
</div>

{% endblock %}
MAIL2NAS_EOF

# --- mail2nas/templates/settings.html ---
cat > mail2nas/templates/settings.html <<'MAIL2NAS_EOF'
{% extends "base.html" %}
{% block content %}
<form method="post">
  <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">

  <div class="card">
    <h2>Mapping-Datei</h2>
    <div class="row">
      <div>
        <label>Pfad, relativ zur Wurzel des Shares</label>
        <input type="text" name="mapping_path" value="{{ settings.mapping_path }}">
      </div>
    </div>
    <p class="hint">
      Aktuell: <code>{{ mapping_full_path }}</code><br>
      Wurzel des Shares: <code>{{ storage_root }}</code>. Unterordner wie
      <code>config/mapping.yaml</code> sind erlaubt; die Datei muss innerhalb des Shares
      bleiben. Beim Aendern wird eine vorhandene Datei an den neuen Ort verschoben.
    </p>
  </div>

  <div class="card">
    <h2>Ablage</h2>
    <div class="row">
      <div>
        <label>Fallback-Ordner (kein Treffer)</label>
        <input type="text" name="fallback_folder" value="{{ settings.fallback_folder }}">
      </div>
      <div>
        <label>Quarantaene-Ordner (gesperrte Dateitypen)</label>
        <input type="text" name="quarantine_folder" value="{{ settings.quarantine_folder }}">
      </div>
      <div>
        <label>Praefix im Dateinamen</label>
        <select name="filename_prefix">
          {% for value, text in [('date_sender','Datum + Absender'),('date','Nur Datum'),('sender','Nur Absender'),('none','Kein Praefix')] %}
            <option value="{{ value }}" {{ 'selected' if settings.filename_prefix == value }}>{{ text }}</option>
          {% endfor %}
        </select>
      </div>
    </div>
    <p style="margin-top:10px">
      <label class="hint">
        <input type="checkbox" name="match_body" {{ 'checked' if settings.match_body }}>
        Auch den Mailtext nach Stichwoertern durchsuchen (sonst nur Dateiname und Betreff)
      </label>
    </p>
    <p class="hint">
      Die Ordner liegen auf der Standard-Ablage bzw. auf der Ablage, die die passende
      Zuordnung nennt. Mehrere NAS/Shares werden unter „Ablagen“ verwaltet.
    </p>
  </div>

  <div class="card">
    <h2>Quarantaene: gesperrte Dateiendungen</h2>
    <div class="row">
      <div>
        <label>Endungen, komma- oder leerzeichengetrennt (ohne Punkt)</label>
        <input type="text" name="blocked_extensions" value="{{ blocked_extensions }}"
               placeholder="exe, com, scr, bat, ...">
      </div>
    </div>
    <p class="hint">
      Anhaenge mit einer dieser Endungen landen <strong>immer</strong> im Quarantaene-Ordner
      „<code>{{ settings.quarantine_folder }}</code>“ - auch wenn der Dateiname auf ein
      Stichwort passt. So kann „Rechnung.exe“ nicht im Rechnungsordner landen.
      Leer lassen schaltet die Pruefung ab (nicht empfohlen).
      Gilt fuer Mailanhaenge und fuer Dateien aus Drucker-Abholordnern.
    </p>
    <p class="hint">
      Diese Liste ersetzt die Umgebungsvariable <code>BLOCKED_EXTENSIONS</code>; die wird nur
      noch beim allerersten Start als Vorbelegung gelesen.
    </p>
  </div>

  <div class="card">
    <h2>Abruf und Grenzwerte</h2>
    <div class="row">
      <div>
        <label>Abrufintervall (Sekunden)</label>
        <input type="number" name="poll_interval" value="{{ settings.poll_interval }}" min="1">
      </div>
      <div>
        <label>Max. Groesse je Anhang (MB)</label>
        <input type="number" name="max_attachment_size_mb" value="{{ settings.max_attachment_size_mb }}" min="1">
      </div>
      <div>
        <label>Max. Groesse je Mail (MB)</label>
        <input type="number" name="max_message_size_mb" value="{{ settings.max_message_size_mb }}" min="1">
      </div>
      <div>
        <label>Max. Anhaenge je Mail</label>
        <input type="number" name="max_attachments_per_message" value="{{ settings.max_attachments_per_message }}" min="1">
      </div>
      <div>
        <label>Scan gilt als fertig nach (Sekunden)</label>
        <input type="number" name="printer_min_age_seconds" value="{{ settings.printer_min_age_seconds }}" min="0">
      </div>
    </div>
    <p class="hint">
      Die Grenzwerte begrenzen, was eine einzelne Mail an Speicher und Plattenplatz
      verursachen kann; fuer Dateien aus Drucker-Abholordnern gelten sie nicht, die
      liegen bereits auf dem NAS und werden gestreamt.
      Die Wartezeit sorgt dafuer, dass ein Scan erst abgeholt wird, wenn er eine Weile
      unveraendert ist - sonst wird eine noch laufende Uebertragung abgelegt.
      Abholordner werden mindestens einmal pro Minute geprueft, auch wenn das
      Abrufintervall groesser ist.
    </p>
  </div>

  <button class="primary">Einstellungen speichern</button>
</form>
{% endblock %}
MAIL2NAS_EOF

# --- tests/test_mapping.py ---
cat > tests/test_mapping.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import textwrap

import pytest

from mail2nas.mapping import Mapping


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def test_resolve_matches_case_insensitive(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        LS: lieferscheine
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    target = mapping.resolve("Ihre re 12345")

    assert target.folder == "rechnungen"
    assert target.keyword == "RE"


def test_resolve_falls_back_when_no_keyword_matches(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    target = mapping.resolve("Newsletter August")

    assert target.folder == "unsorted"
    assert target.keyword is None


def test_resolve_prefers_longer_keyword_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    target = mapping.resolve("Rechnungskorrektur zur RE-2024-01")

    assert target.folder == "korrekturen"
    assert target.keyword == "Rechnungskorrektur"


def test_missing_mapping_file_falls_back_to_default(tmp_path):
    mapping = Mapping(str(tmp_path / "does-not-exist.yaml"), fallback_folder="unsorted")

    target = mapping.resolve("Rechnung 123")

    assert target.folder == "unsorted"
    assert target.keyword is None


def test_reload_picks_up_changes(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")
    assert mapping.resolve("RE 1").folder == "rechnungen"

    _write_mapping(mapping_path, "RE: invoices\n")
    # Nudge mtime forward in case the filesystem has coarse timestamp resolution.
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1").folder == "invoices"


def test_broken_yaml_keeps_previous_rules_instead_of_raising(tmp_path):
    """A half-written mapping.yaml on the share must not take the service down."""
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")
    assert mapping.resolve("RE 1").folder == "rechnungen"

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()  # must not raise

    assert mapping.resolve("RE 1").folder == "rechnungen"


def test_non_mapping_yaml_keeps_previous_rules(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("- just\n- a\n- list\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1").folder == "rechnungen"


def test_broken_yaml_is_not_re_reported_every_cycle(tmp_path, caplog):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    with caplog.at_level("ERROR"):
        mapping.reload()
        mapping.reload()
        mapping.reload()

    assert len([r for r in caplog.records if r.levelname == "ERROR"]) == 1


# --- v2 format: explicit order, wildcards, per-account rules -----------------

from mail2nas.mapping import ALL_ACCOUNTS, Rule, dump_rules  # noqa: E402


def test_v2_order_defines_priority_not_keyword_length(tmp_path):
    """The first matching rule wins, even if a longer keyword matches later."""
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: RE
            folder: rechnungen
          - match: Rechnungskorrektur
            folder: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnungskorrektur zur RE-1").folder == "rechnungen"


def test_v2_reordering_changes_the_winner(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: Rechnungskorrektur
            folder: korrekturen
          - match: RE
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnungskorrektur zur RE-1").folder == "korrekturen"


def test_v1_dict_format_still_works_with_length_priority(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnungskorrektur zur RE-1").folder == "korrekturen"


@pytest.mark.parametrize(
    "pattern,text,expected",
    [
        ("Rechnung*", "rechnung_4711.pdf", True),
        ("Rechnung*", "meine rechnung", False),   # anchored at the start
        ("*Rechnung*", "meine rechnung 1", True),
        ("RE-????", "re-2024", True),
        ("RE-????", "re-24", False),
        ("*.pdf", "beleg.pdf", True),
        ("*.pdf", "beleg.exe", False),
    ],
)
def test_wildcards(tmp_path, pattern, text, expected):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, f"""
        version: 2
        rules:
          - match: "{pattern}"
            folder: treffer
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert (mapping.resolve(text).folder == "treffer") is expected


def test_plain_keyword_stays_a_substring_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: Rechnung
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Ihre Rechnung 4711").folder == "rechnungen"


def test_wildcards_are_case_insensitive(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: "RECHNUNG*"
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("rechnung_1.pdf").folder == "rechnungen"


def test_rule_limited_to_one_account_is_skipped_for_others(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: Rechnung
            folder: privat
            account: privatkonto
          - match: Rechnung
            folder: firma
            account: all
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnung 1", account="privatkonto").folder == "privat"
    assert mapping.resolve("Rechnung 1", account="firmenkonto").folder == "firma"


def test_dump_rules_roundtrips_through_the_loader(tmp_path):
    rules = [
        Rule(match="Rechnung*", folder="rechnungen", account=ALL_ACCOUNTS),
        Rule(match="LS", folder="lieferscheine", account="konto2"),
    ]
    mapping_path = tmp_path / "mapping.yaml"
    mapping_path.write_text(dump_rules(rules), encoding="utf-8")

    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.rules == rules


def test_save_persists_order_and_is_reloaded(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "version: 2\nrules: []\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping.save([Rule(match="LS", folder="lieferscheine"), Rule(match="RE", folder="rechnungen")])

    assert Mapping(str(mapping_path), "unsorted").rules == mapping.rules
    assert mapping.resolve("RE und LS").folder == "lieferscheine"


def test_rule_missing_folder_is_rejected_and_previous_rules_kept(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("version: 2\nrules:\n  - match: RE\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))
    mapping.reload()

    assert mapping.resolve("RE 1").folder == "rechnungen"
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

# --- tests/test_shares.py ---
cat > tests/test_shares.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os

import pytest

from mail2nas.settings import Settings, Share
from mail2nas.shares import ShareSet


def _two_shares(tmp_path):
    first = tmp_path / "nas1"
    second = tmp_path / "nas2"
    first.mkdir()
    second.mkdir()
    return ShareSet(
        [Share(id="nas1", label="NAS 1", path=str(first)), Share(id="nas2", path=str(second))],
        fallback_root=str(first),
    )


# --- picking the right root --------------------------------------------------


def test_named_share_is_used(tmp_path):
    shares = _two_shares(tmp_path)

    assert shares.root_for("nas2") == tmp_path / "nas2"


def test_empty_id_means_the_default_share(tmp_path):
    shares = _two_shares(tmp_path)

    assert shares.root_for("") == tmp_path / "nas1"


def test_unknown_share_falls_back_to_the_default_instead_of_failing(tmp_path):
    """A rule may name a share that was deleted - file it, do not lose it."""
    shares = _two_shares(tmp_path)

    assert shares.root_for("geloescht") == tmp_path / "nas1"


def test_disabled_share_falls_back_to_the_default(tmp_path):
    first = tmp_path / "nas1"
    second = tmp_path / "nas2"
    first.mkdir()
    second.mkdir()
    shares = ShareSet(
        [Share(id="nas1", path=str(first)), Share(id="nas2", path=str(second), enabled=False)],
        fallback_root=str(first),
    )

    assert shares.root_for("nas2") == first


def test_first_enabled_share_is_the_default(tmp_path):
    first = tmp_path / "nas1"
    second = tmp_path / "nas2"
    first.mkdir()
    second.mkdir()
    shares = ShareSet(
        [Share(id="nas1", path=str(first), enabled=False), Share(id="nas2", path=str(second))],
        fallback_root=str(tmp_path),
    )

    assert shares.default().id == "nas2"


def test_without_configured_shares_the_storage_root_is_used(tmp_path):
    """Deployments that never opened the shares page keep working."""
    shares = ShareSet(None, fallback_root=str(tmp_path))

    assert shares.root_for("") == tmp_path
    assert shares.root_for("irgendwas") == tmp_path


def test_from_settings_uses_the_configured_shares(tmp_path):
    settings = Settings(shares=[Share(id="a", path=str(tmp_path / "a"))])

    assert ShareSet.from_settings(settings, tmp_path).root_for("a") == tmp_path / "a"


# --- resolving folders -------------------------------------------------------


def test_resolve_joins_below_the_share_root(tmp_path):
    shares = _two_shares(tmp_path)

    assert shares.resolve("nas2", "rechnungen/2026") == tmp_path / "nas2" / "rechnungen" / "2026"


@pytest.mark.parametrize("folder", ["../outside", "/etc", ""])
def test_resolve_refuses_to_leave_the_share(tmp_path, folder):
    shares = _two_shares(tmp_path)

    with pytest.raises(ValueError):
        shares.resolve("nas2", folder)


# --- mount checks ------------------------------------------------------------


def test_missing_mount_point_is_reported(tmp_path):
    problem = ShareSet.check_root(tmp_path / "not-mounted")

    assert "existiert nicht" in problem


def test_a_file_is_not_a_share(tmp_path):
    a_file = tmp_path / "file"
    a_file.write_text("x", encoding="utf-8")

    assert "kein Verzeichnis" in ShareSet.check_root(a_file)


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_read_only_mount_point_is_reported(tmp_path):
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)
    try:
        assert "nicht beschreibbar" in ShareSet.check_root(readonly)
    finally:
        readonly.chmod(0o700)


def test_usable_share_reports_no_problem(tmp_path):
    assert ShareSet.check_root(tmp_path) is None


def test_status_flags_the_broken_share(tmp_path):
    ok = tmp_path / "nas1"
    ok.mkdir()
    shares = ShareSet(
        [Share(id="nas1", path=str(ok)), Share(id="nas2", path=str(tmp_path / "gone"))],
        fallback_root=str(ok),
    )

    status = {s.id: s for s in shares.status()}

    assert status["nas1"].ok is True
    assert "(Standard)" in status["nas1"].label
    assert status["nas2"].ok is False
MAIL2NAS_EOF

# --- tests/test_archiver.py ---
cat > tests/test_archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import textwrap
from email.message import EmailMessage

from mail2nas.archiver import Archiver
from mail2nas.config import DEFAULT_BLOCKED_EXTENSIONS, Config
from mail2nas.mapping import Mapping, Target
from mail2nas.settings import Printer, Share
from mail2nas.shares import ShareSet
from mail2nas.state import ProcessedStore


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
        storage_root=str(tmp_path),
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
    )
    defaults.update(overrides)
    return Config(**defaults)


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _make_archiver(
    tmp_path,
    mapping_content: str | None = None,
    shares=None,
    printers=None,
    **config_overrides,
) -> Archiver:
    config = _make_config(tmp_path, **config_overrides)
    mapping_path = tmp_path / "mapping.yaml"
    if mapping_content is not None:
        _write_mapping(mapping_path, mapping_content)
    mapping = Mapping(str(mapping_path), config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    return Archiver(config, mapping, store, shares=shares, printers=printers)


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

    result = archiver.filer.build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_lieferant_example.com_rechnung.pdf"


def test_build_filename_none_prefix_keeps_original_name(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="none")

    result = archiver.filer.build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "rechnung.pdf"


def test_build_filename_date_only_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date")

    result = archiver.filer.build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_rechnung.pdf"


# --- per-attachment folder resolution ----------------------------------------


def test_resolve_attachment_folder_prefers_attachment_filename_over_mail_subject(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            RE: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    # Mail-level match would be "rechnungen" (subject contains RE), but this
    # specific attachment's own filename literally says "Lieferschein".
    mail_target = archiver.mapping.resolve("RE-2024-001 mit Lieferschein")

    target, quarantined = archiver.filer.classify("Lieferschein_4711.pdf", mail_target)

    assert target.folder == "lieferscheine"
    assert target.keyword == "Lieferschein"
    assert quarantined is False


def test_resolve_attachment_folder_falls_back_to_mail_level_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    mail_target = archiver.mapping.resolve("RE-2024-001")

    # "anhang1.pdf" itself does not match any keyword.
    target, quarantined = archiver.filer.classify("anhang1.pdf", mail_target)

    assert target.folder == "rechnungen"
    assert target.keyword == "RE"
    assert quarantined is False


def test_resolve_attachment_folder_quarantines_blocked_extension_even_with_keyword_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")

    target, quarantined = archiver.filer.classify("Rechnung.exe", Target(folder="unsorted"))

    assert target.folder == "quarantaene"
    assert quarantined is True


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


def test_target_dir_rejects_escape_and_uses_fallback(tmp_path):
    archiver = _make_archiver(tmp_path)

    assert archiver.filer.directory_for(Target(folder="../evil")) == tmp_path / "unsorted"
    assert archiver.filer.directory_for(Target(folder="rechnungen")) == tmp_path / "rechnungen"


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


# --- several shares / several NAS -------------------------------------------


def _two_share_set(tmp_path):
    """<tmp_path> is the default share, <tmp_path>/nas2-share the second one."""
    second = tmp_path / "nas2-share"
    second.mkdir(exist_ok=True)
    return (
        ShareSet(
            [Share(id="nas1", path=str(tmp_path)), Share(id="nas2", path=str(second))],
            fallback_root=str(tmp_path),
        ),
        second,
    )


def test_rule_files_onto_the_share_it_names(tmp_path):
    shares, second = _two_share_set(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - match: RE
                folder: rechnungen
                share: nas2
        """,
        shares=shares,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((second / "rechnungen").glob("*"))) == 1
    assert not (tmp_path / "rechnungen").exists()


def test_rule_without_a_share_uses_the_default_one(tmp_path):
    shares, second = _two_share_set(tmp_path)
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n", shares=shares)
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1
    assert not (second / "rechnungen").exists()


def test_unmounted_share_diverts_to_the_default_share(tmp_path):
    """A NAS that is down must not turn its mount point into a local folder."""
    gone = tmp_path / "nicht-gemountet"
    shares = ShareSet(
        [Share(id="nas1", path=str(tmp_path)), Share(id="weg", path=str(gone))],
        fallback_root=str(tmp_path),
    )
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - match: RE
                folder: rechnungen
                share: weg
        """,
        shares=shares,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not gone.exists()
    assert len(list((tmp_path / "unsorted").glob("*"))) == 1


def test_quarantine_stays_on_the_share_the_rule_named(tmp_path):
    shares, second = _two_share_set(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - match: RE
                folder: rechnungen
                share: nas2
        """,
        shares=shares,
    )
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((second / "quarantaene").glob("*"))) == 1


# --- mail from a known device (scan-to-mail) ---------------------------------


def _scan_message(sender: str, subject: str, filename: str = "SKM_C250i.pdf") -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg.set_content("Scan")
    msg.add_attachment(b"scan", maintype="application", subtype="pdf", filename=filename)
    return bytes(msg)


def test_device_with_a_fixed_folder_beats_a_keyword_in_the_subject(tmp_path):
    """A scanner's subject line is boilerplate - it must not steer the filing."""
    printer = Printer(id="kopierer", sender="scanner@example.com", target_folder="scans")
    archiver = _make_archiver(tmp_path, mapping_content="Scan: irgendwo\n", printers=[printer])
    raw = _scan_message("scanner@example.com", "Scan vom Kopierer")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "scans").glob("*"))) == 1
    assert not (tmp_path / "irgendwo").exists()


def test_device_without_a_fixed_folder_leaves_the_rules_in_charge(tmp_path):
    printer = Printer(id="kopierer", sender="scanner@example.com")
    archiver = _make_archiver(tmp_path, mapping_content="Rechnung: rechnungen\n", printers=[printer])
    raw = _scan_message("scanner@example.com", "Rechnung 4711")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1


def test_mail_from_someone_else_is_not_treated_as_a_device(tmp_path):
    printer = Printer(id="kopierer", sender="scanner@example.com", target_folder="scans")
    archiver = _make_archiver(tmp_path, mapping_content="Rechnung: rechnungen\n", printers=[printer])
    raw = _scan_message("lieferant@example.com", "Rechnung 4711")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1
    assert not (tmp_path / "scans").exists()


def test_device_can_file_onto_another_nas(tmp_path):
    shares, second = _two_share_set(tmp_path)
    printer = Printer(
        id="kopierer", sender="scanner@example.com", target_share="nas2", target_folder="scans"
    )
    archiver = _make_archiver(tmp_path, printers=[printer], shares=shares)
    raw = _scan_message("scanner@example.com", "Scan")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((second / "scans").glob("*"))) == 1


def test_blocked_extension_from_a_device_is_still_quarantined(tmp_path):
    printer = Printer(id="kopierer", sender="scanner@example.com", target_folder="scans")
    archiver = _make_archiver(tmp_path, printers=[printer])
    raw = _scan_message("scanner@example.com", "Scan", filename="scan.exe")

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1
    assert not (tmp_path / "scans").exists()


# --- encoded filenames -------------------------------------------------------


def test_keyword_in_an_rfc2047_encoded_filename_is_found(tmp_path):
    """Mail clients encode non-ASCII filenames - the keyword is in there too."""
    archiver = _make_archiver(tmp_path, mapping_content="Angebot: angebote\n")
    msg = EmailMessage()
    msg["Subject"] = "ohne Stichwort"
    msg["From"] = "lieferant@example.com"
    msg.set_content("Hallo")
    msg.add_attachment(
        b"DATA",
        maintype="application",
        subtype="pdf",
        filename=("utf-8", "", "Angebot_Grün.pdf"),
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=bytes(msg)), 1)

    assert len(list((tmp_path / "angebote").glob("*"))) == 1


def test_unusable_quarantine_folder_never_lands_in_a_business_folder(tmp_path):
    """A broken quarantine path must not put an .exe next to the invoices."""
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", quarantine_folder="../raus"
    )
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not (tmp_path / "rechnungen").exists()
    assert not (tmp_path / "unsorted").exists()
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1
MAIL2NAS_EOF

# --- tests/test_printers.py ---
cat > tests/test_printers.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses
import os
import time
from pathlib import Path

import pytest

from mail2nas.mapping import Mapping
from mail2nas.printers import PrinterPickup
from mail2nas.settings import Printer, Settings, Share
from mail2nas.shares import ShareSet
from tests.test_archiver import _make_config


# --- identifying a device by its mail address --------------------------------


@pytest.mark.parametrize(
    "pattern,address,expected",
    [
        ("scanner@example.com", "scanner@example.com", True),
        ("scanner@example.com", "SCANNER@Example.COM", True),
        ("scanner@example.com", "chef@example.com", False),
        ("@scanner.lan", "kopierer-3@scanner.lan", True),
        ("@scanner.lan", "kopierer-3@example.com", False),
        ("kopierer-*@example.com", "kopierer-flur@example.com", True),
        ("kopierer-*@example.com", "buchhaltung@example.com", False),
        ("", "scanner@example.com", False),
        ("scanner@example.com", "", False),
    ],
)
def test_matches_sender(pattern, address, expected):
    assert Printer(id="p", sender=pattern).matches_sender(address) is expected


# --- picking documents out of a folder on the NAS ----------------------------


def _pickup(tmp_path, printer: Printer, mapping_content: str | None = None, **overrides):
    """A PrinterPickup wired to <tmp_path>/nas1 (+ nas2), like a real deployment."""
    nas1 = tmp_path / "nas1"
    nas2 = tmp_path / "nas2"
    nas1.mkdir(exist_ok=True)
    nas2.mkdir(exist_ok=True)

    config = _make_config(nas1, storage_root=str(nas1), **overrides)
    mapping_path = nas1 / "mapping.yaml"
    if mapping_content is not None:
        mapping_path.write_text(mapping_content, encoding="utf-8")
    mapping = Mapping(str(mapping_path), config.fallback_folder)

    settings = Settings(
        shares=[
            Share(id="nas1", label="NAS 1", path=str(nas1)),
            Share(id="nas2", label="NAS 2", path=str(nas2)),
        ],
        printers=[printer],
        printer_min_age_seconds=0,
    )
    shares = ShareSet.from_settings(settings, config.storage_root)
    return PrinterPickup(config, settings, mapping, shares), nas1, nas2


def _drop(directory: Path, name: str, content: bytes = b"scan", age_seconds: int = 60) -> Path:
    """Write a file into a pickup folder, pretending it finished `age` ago."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(content)
    stamp = time.time() - age_seconds
    os.utime(path, (stamp, stamp))
    return path


def test_file_is_moved_into_the_fixed_target_folder(tmp_path):
    printer = Printer(id="kopierer", label="Kopierer", source_share="nas1",
                      source_folder="scans", target_share="nas1", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", "SKM_C250i23081512.pdf")

    assert pickup.run_once() == 1
    assert not source.exists()  # the pickup folder is an outbox, not an archive
    filed = list((nas1 / "eingang").glob("*"))
    assert len(filed) == 1
    assert filed[0].read_bytes() == b"scan"


def test_filename_gets_the_device_and_the_scan_date(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan1.pdf")

    pickup.run_once()

    name = next((nas1 / "eingang").glob("*")).name
    assert name.endswith("_kopierer_scan1.pdf")
    assert name[:4].isdigit()  # date prefix from the file's own mtime


def test_file_still_being_written_is_left_alone(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    pickup.settings.printer_min_age_seconds = 30
    source = _drop(nas1 / "scans", "halb.pdf", age_seconds=0)

    assert pickup.run_once() == 0
    assert source.exists()


@pytest.mark.parametrize("name", [".hidden.pdf", "scan.pdf.tmp", "scan.PART", ".mail2nas-tmp-x"])
def test_incomplete_or_hidden_files_are_ignored(tmp_path, name):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", name)

    assert pickup.run_once() == 0
    assert source.exists()


def test_empty_file_is_ignored(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "leer.pdf", content=b"")

    assert pickup.run_once() == 0


def test_subfolders_of_the_pickup_folder_are_walked(tmp_path):
    """Devices often create one subfolder per user or scan profile."""
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans" / "anna", "a.pdf")
    _drop(nas1 / "scans" / "bert", "b.pdf")

    assert pickup.run_once() == 2
    assert len(list((nas1 / "eingang").glob("*"))) == 2


def test_without_a_fixed_target_the_keyword_rules_decide(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans")
    pickup, nas1, _ = _pickup(tmp_path, printer, mapping_content="Rechnung: rechnungen\n")
    _drop(nas1 / "scans", "Rechnung_4711.pdf")

    pickup.run_once()

    assert len(list((nas1 / "rechnungen").glob("*"))) == 1


def test_without_a_match_the_fallback_folder_is_used(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans")
    pickup, nas1, _ = _pickup(tmp_path, printer, mapping_content="Rechnung: rechnungen\n")
    _drop(nas1 / "scans", "irgendwas.pdf")

    pickup.run_once()

    assert len(list((nas1 / "unsorted").glob("*"))) == 1


def test_rules_pinned_to_a_mail_account_do_not_claim_folder_scans(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans")
    pickup, nas1, _ = _pickup(
        tmp_path,
        printer,
        mapping_content=(
            "version: 2\nrules:\n"
            "  - match: Rechnung\n    folder: privat\n    account: privatkonto\n"
        ),
    )
    _drop(nas1 / "scans", "Rechnung_1.pdf")

    pickup.run_once()

    assert not (nas1 / "privat").exists()
    assert len(list((nas1 / "unsorted").glob("*"))) == 1


def test_blocked_extension_is_quarantined(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "Rechnung.exe", content=b"MZ")

    pickup.run_once()

    assert len(list((nas1 / "quarantaene").glob("*"))) == 1
    assert not (nas1 / "eingang").exists()


def test_document_can_be_filed_onto_another_nas(tmp_path):
    printer = Printer(id="kopierer", source_share="nas1", source_folder="scans",
                      target_share="nas2", target_folder="eingang")
    pickup, nas1, nas2 = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 1
    assert len(list((nas2 / "eingang").glob("*"))) == 1
    assert not (nas1 / "eingang").exists()


def test_target_inside_the_pickup_folder_is_refused(tmp_path):
    """Otherwise the same document would be imported again on every cycle."""
    printer = Printer(id="kopierer", source_folder="scans", target_folder="scans/fertig")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 0
    assert source.exists()


def test_missing_pickup_folder_is_reported_once_and_does_not_raise(tmp_path, caplog):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, _, _ = _pickup(tmp_path, printer)

    with caplog.at_level("WARNING"):
        assert pickup.run_once() == 0
        assert pickup.run_once() == 0

    warnings = [r for r in caplog.records if r.name == "mail2nas.printers"]
    assert len(warnings) == 1
    assert "existiert nicht" in warnings[0].getMessage()


def test_unmounted_source_share_is_not_created_on_the_local_disk(tmp_path):
    printer = Printer(id="kopierer", source_share="weg", source_folder="scans",
                      target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    pickup.shares = ShareSet(
        [Share(id="weg", path=str(tmp_path / "nicht-gemountet"))], fallback_root=str(nas1)
    )
    pickup.filer.shares = pickup.shares

    assert pickup.run_once() == 0
    assert not (tmp_path / "nicht-gemountet").exists()


def test_disabled_printer_is_skipped(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang", enabled=False)
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 0
    assert source.exists()


def test_dry_run_moves_nothing(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer, dry_run=True)
    source = _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 0
    assert source.exists()
    assert not (nas1 / "eingang").exists()


def test_two_scans_with_the_same_name_do_not_overwrite_each_other(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer, filename_prefix="none")
    _drop(nas1 / "scans", "scan.pdf", content=b"erster")
    pickup.run_once()
    _drop(nas1 / "scans", "scan.pdf", content=b"zweiter")
    pickup.run_once()

    filed = sorted(p.read_bytes() for p in (nas1 / "eingang").glob("*"))
    assert filed == [b"erster", b"zweiter"]


def test_a_broken_printer_does_not_stop_the_others(tmp_path):
    good = Printer(id="gut", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, good)
    pickup.settings = dataclasses.replace(
        pickup.settings,
        printers=[Printer(id="kaputt", source_folder="../ausserhalb"), good],
    )
    _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 1
    assert not (tmp_path / "ausserhalb").exists()


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_pickup_folder_we_cannot_delete_from_is_refused(tmp_path):
    """Copying without deleting would re-import the same scan forever."""
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan.pdf")
    (nas1 / "scans").chmod(0o500)
    try:
        assert pickup.run_once() == 0
        assert not (nas1 / "eingang").exists()
    finally:
        (nas1 / "scans").chmod(0o700)


def test_a_failed_delete_does_not_leave_a_copy_behind(tmp_path, monkeypatch):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan.pdf")

    original = Path.unlink

    def refuse_in_the_pickup_folder(self, missing_ok=False):
        if self.parent.name == "scans":
            raise OSError("read-only")
        return original(self, missing_ok=missing_ok)

    monkeypatch.setattr(Path, "unlink", refuse_in_the_pickup_folder)

    assert pickup.run_once() == 0
    assert (nas1 / "scans" / "scan.pdf").exists()
    assert list((nas1 / "eingang").glob("*")) == []
MAIL2NAS_EOF

# --- tests/test_runner.py ---
cat > tests/test_runner.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses
import os
import time
from pathlib import Path

from mail2nas.mapping import Mapping, Rule
from mail2nas.runner import Runner
from mail2nas.settings import Printer, Settings, Share
from mail2nas.state import ProcessedStore
from tests.test_archiver import _make_config


def _wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def _runner(tmp_path, **settings_overrides):
    """A Runner with no mail accounts, so only the pickup side is exercised."""
    nas1 = tmp_path / "nas1"
    nas2 = tmp_path / "nas2"
    data = tmp_path / "data"
    for directory in (nas1, nas2, data):
        directory.mkdir(exist_ok=True)

    config = _make_config(nas1, storage_root=str(nas1), state_db_path=str(data / "state.db"))
    mapping = Mapping(str(nas1 / "mapping.yaml"), "unsorted")
    mapping.save([Rule(match="Rechnung", folder="rechnungen")])
    settings = Settings(
        shares=[Share(id="nas1", path=str(nas1)), Share(id="nas2", path=str(nas2))],
        printer_min_age_seconds=0,
        poll_interval=1,
        **settings_overrides,
    )
    store = ProcessedStore(config.state_db_path)
    return Runner(config, settings, mapping, store), nas1, nas2


def _drop(directory: Path, name: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(b"scan")
    stamp = time.time() - 60
    os.utime(path, (stamp, stamp))
    return path


def test_pickup_worker_files_a_scan_end_to_end(tmp_path):
    runner, nas1, nas2 = _runner(
        tmp_path,
        printers=[
            Printer(id="kopierer", label="Kopierer", source_share="nas1", source_folder="scans",
                    target_share="nas2", target_folder="eingang")
        ],
    )
    _drop(nas1 / "scans", "scan.pdf")

    runner.start()
    try:
        assert _wait_for(lambda: list((nas2 / "eingang").glob("*")))
    finally:
        runner.stop()

    assert not (nas1 / "scans" / "scan.pdf").exists()


def test_pickup_worker_applies_the_keyword_rules(tmp_path):
    runner, nas1, _ = _runner(
        tmp_path, printers=[Printer(id="kopierer", source_folder="scans")]
    )
    _drop(nas1 / "scans", "Rechnung_1.pdf")

    runner.start()
    try:
        assert _wait_for(lambda: list((nas1 / "rechnungen").glob("*")))
    finally:
        runner.stop()


def test_no_pickup_worker_without_a_folder_printer(tmp_path):
    runner, _, _ = _runner(tmp_path, printers=[Printer(id="nur-mail", sender="scan@x.de")])

    runner.start()
    try:
        assert runner.status() == []
    finally:
        runner.stop()


def test_status_reports_the_pickup_worker(tmp_path):
    runner, _, _ = _runner(tmp_path, printers=[Printer(id="kopierer", source_folder="scans")])

    runner.start()
    try:
        assert [s["id"] for s in runner.status()] == ["drucker"]
        assert runner.status()[0]["alive"] is True
    finally:
        runner.stop()


def test_reload_picks_up_a_new_printer_without_a_restart(tmp_path):
    runner, nas1, _ = _runner(tmp_path)
    runner.start()
    try:
        assert runner.status() == []

        runner.reload(
            dataclasses.replace(
                runner.settings,
                printers=[Printer(id="neu", source_folder="scans", target_folder="eingang")],
            )
        )
        _drop(nas1 / "scans", "scan.pdf")

        assert _wait_for(lambda: list((nas1 / "eingang").glob("*")))
    finally:
        runner.stop()


def test_reload_applies_a_changed_fallback_folder(tmp_path):
    runner, nas1, _ = _runner(tmp_path, printers=[Printer(id="kopierer", source_folder="scans")])
    runner.start()
    try:
        runner.reload(dataclasses.replace(runner.settings, fallback_folder="sonstiges"))
        _drop(nas1 / "scans", "ohne-stichwort.pdf")

        assert _wait_for(lambda: list((nas1 / "sonstiges").glob("*")))
    finally:
        runner.stop()


def test_reload_adopts_a_new_share(tmp_path):
    runner, nas1, _ = _runner(
        tmp_path, printers=[Printer(id="kopierer", source_folder="scans", target_share="nas3",
                                    target_folder="eingang")]
    )
    nas3 = tmp_path / "nas3"
    nas3.mkdir()
    runner.start()
    try:
        runner.reload(
            dataclasses.replace(
                runner.settings,
                shares=list(runner.settings.shares) + [Share(id="nas3", path=str(nas3))],
            )
        )
        _drop(nas1 / "scans", "scan.pdf")

        assert _wait_for(lambda: list((nas3 / "eingang").glob("*")))
    finally:
        runner.stop()


def test_stop_ends_the_pickup_worker(tmp_path):
    runner, _, _ = _runner(tmp_path, printers=[Printer(id="kopierer", source_folder="scans")])
    runner.start()
    worker = runner._printer_worker

    runner.stop()

    assert _wait_for(lambda: not worker.is_alive())
    assert runner.status() == []
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
MAIL2NAS_EOF

# --- tests/test_main.py ---
cat > tests/test_main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os

import pytest

from mail2nas.main import _check_storage_root
from tests.test_archiver import _make_config


def test_accepts_a_writable_storage_root(tmp_path):
    _check_storage_root(_make_config(tmp_path, storage_root=str(tmp_path)))


def test_missing_storage_root_fails_fast(tmp_path):
    """An unmounted share must not be mistaken for an empty one."""
    missing = tmp_path / "not-mounted"

    with pytest.raises(SystemExit, match="does not exist"):
        _check_storage_root(_make_config(tmp_path, storage_root=str(missing)))


def test_storage_root_that_is_a_file_fails_fast(tmp_path):
    a_file = tmp_path / "afile"
    a_file.write_text("x", encoding="utf-8")

    with pytest.raises(SystemExit, match="does not exist or is not a directory"):
        _check_storage_root(_make_config(tmp_path, storage_root=str(a_file)))


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_read_only_storage_root_fails_fast(tmp_path):
    readonly = tmp_path / "readonly"
    readonly.mkdir()
    readonly.chmod(0o500)
    try:
        with pytest.raises(SystemExit, match="not writable"):
            _check_storage_root(_make_config(tmp_path, storage_root=str(readonly)))
    finally:
        readonly.chmod(0o700)
MAIL2NAS_EOF

# --- tests/test_settings.py ---
cat > tests/test_settings.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses

import pytest

from mail2nas.settings import (
    Account,
    Printer,
    Settings,
    Share,
    make_account_id,
    parse_extensions,
)
from tests.test_archiver import _make_config


def _config(tmp_path):
    data = tmp_path / "data"
    data.mkdir(exist_ok=True)
    return _make_config(tmp_path, storage_root=str(tmp_path), state_db_path=str(data / "state.db"))


def test_first_start_migrates_the_environment_configuration(tmp_path):
    """An existing single-account .env deployment must keep working."""
    config = dataclasses.replace(
        _config(tmp_path), imap_host="imap.example.com", imap_user="archiv@x", imap_password="pw"
    )

    settings = Settings.load(config)

    assert len(settings.accounts) == 1
    account = settings.accounts[0]
    assert (account.id, account.host, account.user) == ("default", "imap.example.com", "archiv@x")
    assert Settings.path_for(config).exists()


def test_settings_roundtrip_through_the_file(tmp_path):
    config = _config(tmp_path)
    settings = Settings(
        accounts=[Account(id="a", host="h", user="u", password="p")],
        fallback_folder="sonstiges",
        match_body=True,
    )
    settings.save(config)

    loaded = Settings.load(config)

    assert loaded.fallback_folder == "sonstiges"
    assert loaded.match_body is True
    assert loaded.accounts[0].password == "p"


def test_unreadable_config_falls_back_to_the_environment(tmp_path):
    config = dataclasses.replace(_config(tmp_path), imap_host="fallback.example.com")
    Settings.path_for(config).write_text("this: [is not: valid", encoding="utf-8")

    settings = Settings.load(config)

    assert settings.accounts[0].host == "fallback.example.com"


def test_enabled_accounts_skips_disabled_and_incomplete_ones(tmp_path):
    settings = Settings(
        accounts=[
            Account(id="ok", host="h", user="u", password="p"),
            Account(id="off", host="h", user="u", password="p", enabled=False),
            Account(id="incomplete", host="", user="", password=""),
        ]
    )

    assert [a.id for a in settings.enabled_accounts()] == ["ok"]


def test_unique_id_avoids_collisions(tmp_path):
    settings = Settings(accounts=[Account(id="buchhaltung", host="h", user="u", password="p")])

    assert settings.unique_id("buchhaltung") == "buchhaltung-2"
    assert settings.unique_id("buchhaltung", ignore="buchhaltung") == "buchhaltung"
    assert settings.unique_id("anderes") == "anderes"


def test_make_account_id_is_filesystem_and_yaml_safe():
    assert make_account_id("Buchhaltung Müller & Co.") == "buchhaltung-m-ller-co"
    assert make_account_id("   ") .startswith("konto-")


def test_config_for_maps_account_fields_onto_the_archiver_config(tmp_path):
    config = _config(tmp_path)
    settings = Settings(
        accounts=[],
        fallback_folder="sonstiges",
        max_attachment_size_mb=7,
    )
    account = Account(
        id="zweit", host="imap.z", user="u@z", password="pw", port=143, ssl=False,
        folder="Archiv", processed_folder="Erledigt", mode="idle",
    )

    per_account = settings.config_for(config, account)

    assert per_account.imap_host == "imap.z"
    assert per_account.imap_port == 143
    assert per_account.imap_ssl is False
    assert per_account.imap_folder == "Archiv"
    assert per_account.imap_processed_folder == "Erledigt"
    assert per_account.imap_mode == "idle"
    assert per_account.account_id == "zweit"
    # general settings come from Settings, not from the environment defaults
    assert per_account.fallback_folder == "sonstiges"
    assert per_account.max_attachment_size_mb == 7
    # infrastructure settings stay untouched
    assert per_account.storage_root == config.storage_root


def test_empty_processed_folder_becomes_none(tmp_path):
    config = _config(tmp_path)
    account = Account(id="a", host="h", user="u", password="p", processed_folder="")

    assert Settings().config_for(config, account).imap_processed_folder is None


# --- shares -----------------------------------------------------------------


def test_first_start_creates_the_share_for_the_storage_root(tmp_path):
    config = dataclasses.replace(
        _config(tmp_path), imap_host="imap.example.com", imap_user="u", imap_password="p"
    )

    settings = Settings.load(config)

    assert [(s.id, s.path) for s in settings.shares] == [("default", config.storage_root)]


def test_config_written_before_shares_existed_gets_the_base_share(tmp_path):
    """Upgrading must not leave an installation without any archive target."""
    config = _config(tmp_path)
    Settings.path_for(config).write_text(
        "accounts:\n- {id: a, host: h, user: u, password: p}\nfallback_folder: sonstiges\n",
        encoding="utf-8",
    )

    settings = Settings.load(config)

    assert settings.fallback_folder == "sonstiges"
    assert [s.path for s in settings.shares] == [config.storage_root]


def test_shares_and_printers_survive_a_roundtrip(tmp_path):
    config = _config(tmp_path)
    Settings(
        shares=[Share(id="nas2", label="NAS 2", path="/mnt/nas2")],
        printers=[
            Printer(id="kopierer", label="Kopierer", sender="scan@x.de",
                    source_folder="scans", target_share="nas2", target_folder="eingang")
        ],
    ).save(config)

    loaded = Settings.load(config)

    assert loaded.share("nas2").path == "/mnt/nas2"
    printer = loaded.printer("kopierer")
    assert (printer.sender, printer.source_folder, printer.target_share) == (
        "scan@x.de", "scans", "nas2"
    )


def test_default_share_is_the_first_enabled_one(tmp_path):
    settings = Settings(
        shares=[
            Share(id="alt", path="/mnt/alt", enabled=False),
            Share(id="neu", path="/mnt/neu"),
        ]
    )

    assert settings.default_share().id == "neu"


def test_enabled_shares_skips_disabled_and_pathless_ones():
    settings = Settings(
        shares=[
            Share(id="ok", path="/mnt/ok"),
            Share(id="off", path="/mnt/off", enabled=False),
            Share(id="leer", path=""),
        ]
    )

    assert [s.id for s in settings.enabled_shares()] == ["ok"]


# --- printers ---------------------------------------------------------------


def test_printer_selection_by_delivery_path():
    settings = Settings(
        printers=[
            Printer(id="mail", sender="scan@x.de"),
            Printer(id="ordner", source_folder="scans"),
            Printer(id="beides", sender="a@b.c", source_folder="scans"),
            Printer(id="aus", source_folder="scans", enabled=False),
        ]
    )

    assert [p.id for p in settings.pickup_printers()] == ["ordner", "beides"]
    assert [p.id for p in settings.mail_printers()] == ["mail", "beides"]


def test_unique_ids_do_not_collide_per_kind():
    settings = Settings(
        shares=[Share(id="nas", path="/mnt/nas")],
        printers=[Printer(id="kopierer")],
    )

    assert settings.unique_share_id("nas") == "nas-2"
    assert settings.unique_printer_id("kopierer") == "kopierer-2"
    assert settings.unique_printer_id("kopierer", ignore="kopierer") == "kopierer"


# --- blocked extensions -----------------------------------------------------


@pytest.mark.parametrize(
    "raw,expected",
    [
        ("exe,com", ["exe", "com"]),
        (".EXE, .Com", ["exe", "com"]),
        ("exe com\nbat", ["exe", "com", "bat"]),
        ("exe, exe, ,", ["exe"]),
        ("", []),
        (None, []),
        (["EXE", ".bat"], ["exe", "bat"]),
    ],
)
def test_parse_extensions_normalizes(raw, expected):
    assert parse_extensions(raw) == expected


def test_blocked_extensions_are_seeded_from_the_environment(tmp_path):
    config = dataclasses.replace(
        _config(tmp_path), blocked_extensions=frozenset({"exe", "bat"})
    )

    settings = Settings.load(config)

    assert sorted(settings.blocked_extensions) == ["bat", "exe"]


def test_blocked_extensions_reach_the_archiver_config(tmp_path):
    config = _config(tmp_path)
    settings = Settings(blocked_extensions=[".EXE", "com"])

    per_account = settings.config_for(config, Account(id="a", host="h", user="u", password="p"))

    assert per_account.blocked_extensions == frozenset({"exe", "com"})


def test_empty_extension_list_disables_the_check(tmp_path):
    config = _config(tmp_path)

    assert Settings(blocked_extensions=[]).config_common(config).blocked_extensions == frozenset()


def test_upgrade_keeps_the_quarantine_extensions_from_the_environment(tmp_path):
    """An old config file has no list - falling back to [] would disable it."""
    config = dataclasses.replace(_config(tmp_path), blocked_extensions=frozenset({"exe", "bat"}))
    Settings.path_for(config).write_text(
        "accounts:\n- {id: a, host: h, user: u, password: p}\n", encoding="utf-8"
    )

    settings = Settings.load(config)

    assert sorted(settings.blocked_extensions) == ["bat", "exe"]


def test_an_explicitly_empty_list_stays_empty(tmp_path):
    config = dataclasses.replace(_config(tmp_path), blocked_extensions=frozenset({"exe"}))
    Settings.path_for(config).write_text("blocked_extensions: []\n", encoding="utf-8")

    assert Settings.load(config).blocked_extensions == []
MAIL2NAS_EOF

# --- tests/test_web.py ---
cat > tests/test_web.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses

import pytest

from mail2nas.mapping import ALL_ACCOUNTS, Mapping, Rule
from mail2nas.settings import Account, Printer, Settings, Share
from mail2nas.web import create_app
from tests.test_archiver import _make_config

PASSWORD = "s3cret"


@pytest.fixture
def env(tmp_path):
    share = tmp_path / "share"
    share.mkdir()
    nas2 = tmp_path / "nas2"
    nas2.mkdir()
    data = tmp_path / "data"
    data.mkdir()

    config = dataclasses.replace(
        _make_config(share, storage_root=str(share), state_db_path=str(data / "state.db")),
        web_enabled=True,
        web_user="admin",
        web_password=PASSWORD,
    )
    settings = Settings(
        accounts=[
            Account(id="haupt", label="Hauptpostfach", host="imap.x", user="a@x", password="pw"),
            Account(id="zweit", label="Zweitkonto", host="imap.y", user="b@y", password="pw"),
        ],
        shares=[
            Share(id="default", label="NAS", path=str(share)),
            Share(id="nas2", label="NAS 2", path=str(nas2)),
        ],
        printers=[
            Printer(id="kopierer", label="Kopierer Flur", sender="scan@example.com",
                    source_folder="scans", target_folder="eingang")
        ],
        blocked_extensions=["exe", "bat"],
    )
    settings.save(config)
    mapping = Mapping(str(share / "mapping.yaml"), "unsorted")
    mapping.save([Rule("RE", "rechnungen"), Rule("LS", "lieferscheine")])

    app = create_app(config, settings, mapping)
    app.config.update(TESTING=True)
    return {
        "app": app,
        "config": config,
        "settings": settings,
        "mapping": mapping,
        "share": share,
        "nas2": nas2,
    }


@pytest.fixture
def client(env):
    return env["app"].test_client()


def login(client):
    client.post("/login", data={"user": "admin", "password": PASSWORD})
    with client.session_transaction() as sess:
        sess["csrf"] = "test-token"
    return "test-token"


# --- authentication ----------------------------------------------------------


@pytest.mark.parametrize("path", ["/", "/accounts", "/settings", "/shares", "/printers"])
def test_pages_require_login(client, path):
    response = client.get(path)

    assert response.status_code == 302
    assert "/login" in response.headers["Location"]


def test_login_rejects_wrong_password(client):
    client.post("/login", data={"user": "admin", "password": "wrong"})

    assert client.get("/").status_code == 302


def test_login_accepts_correct_password(client):
    login(client)

    assert client.get("/").status_code == 200


def test_logout_ends_the_session(client):
    token = login(client)
    client.post("/logout", data={"csrf_token": token})

    assert client.get("/").status_code == 302


# --- CSRF --------------------------------------------------------------------


def test_post_without_csrf_token_is_rejected(client):
    login(client)

    response = client.post("/rules/add", data={"match": "AB", "folder": "ab"})

    assert response.status_code == 400


def test_post_with_wrong_csrf_token_is_rejected(client):
    login(client)

    response = client.post("/rules/add", data={"csrf_token": "nope", "match": "AB", "folder": "ab"})

    assert response.status_code == 400


# --- rule ordering (the arrows) ---------------------------------------------


def test_move_rule_down_changes_priority(client, env):
    token = login(client)

    client.post("/rules/0/move/down", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["LS", "RE"]


def test_move_rule_up_changes_priority(client, env):
    token = login(client)

    client.post("/rules/1/move/up", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["LS", "RE"]


def test_move_beyond_the_ends_is_a_no_op(client, env):
    token = login(client)

    client.post("/rules/0/move/up", data={"csrf_token": token})
    client.post("/rules/1/move/down", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["RE", "LS"]


def test_reordering_survives_a_reload_from_disk(client, env):
    token = login(client)
    client.post("/rules/0/move/down", data={"csrf_token": token})

    reloaded = Mapping(str(env["mapping"].path), "unsorted")

    assert [r.match for r in reloaded.rules] == ["LS", "RE"]


# --- rule CRUD ---------------------------------------------------------------


def test_add_rule_with_wildcard_and_account(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "Mahnung*", "folder": "mahnungen", "account": "zweit"},
    )

    added = env["mapping"].rules[-1]
    assert (added.match, added.folder, added.account) == ("Mahnung*", "mahnungen", "zweit")


def test_add_rule_rejects_folder_escaping_the_share(client, env):
    token = login(client)

    client.post(
        "/rules/add", data={"csrf_token": token, "match": "X", "folder": "../../etc"}
    )

    assert all(r.folder != "../../etc" for r in env["mapping"].rules)


def test_update_rule_changes_pattern_and_account(client, env):
    token = login(client)

    client.post(
        "/rules/0/update",
        data={"csrf_token": token, "match": "RE-*", "folder": "rechnungen", "account": "haupt"},
    )

    assert env["mapping"].rules[0] == Rule("RE-*", "rechnungen", "haupt")


def test_delete_rule(client, env):
    token = login(client)

    client.post("/rules/0/delete", data={"csrf_token": token})

    assert [r.match for r in env["mapping"].rules] == ["LS"]


# --- accounts ----------------------------------------------------------------


def test_add_account(client, env):
    token = login(client)

    client.post(
        "/accounts/save",
        data={
            "csrf_token": token, "id": "", "label": "Drittkonto", "host": "imap.z",
            "user": "c@z", "password": "geheim", "port": "993", "ssl": "on",
            "folder": "INBOX", "mode": "poll", "enabled": "on",
        },
    )

    saved = Settings.load(env["config"])
    assert any(a.label == "Drittkonto" and a.password == "geheim" for a in saved.accounts)


def test_editing_an_account_with_empty_password_keeps_the_old_one(client, env):
    token = login(client)

    client.post(
        "/accounts/save",
        data={
            "csrf_token": token, "id": "haupt", "label": "Umbenannt", "host": "imap.x",
            "user": "a@x", "password": "", "port": "993", "folder": "INBOX",
            "mode": "poll", "enabled": "on",
        },
    )

    saved = Settings.load(env["config"])
    account = saved.account("haupt")
    assert account.label == "Umbenannt"
    assert account.password == "pw"


def test_deleting_an_account_unpins_its_rules(client, env):
    token = login(client)
    client.post(
        "/rules/0/update",
        data={"csrf_token": token, "match": "RE", "folder": "rechnungen", "account": "zweit"},
    )

    client.post("/accounts/zweit/delete", data={"csrf_token": token})

    saved = Settings.load(env["config"])
    assert saved.account("zweit") is None
    # the rule must not silently stop matching for ever
    assert all(r.account == ALL_ACCOUNTS for r in env["mapping"].rules)


# --- settings, including moving the mapping file -----------------------------


def test_moving_the_mapping_file_carries_the_rules_along(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "config/mapping.yaml",
            "fallback_folder": "unsorted", "quarantine_folder": "quarantaene",
            "blocked_extensions": "exe, bat",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    new_path = env["share"] / "config" / "mapping.yaml"
    assert new_path.exists()
    assert not (env["share"] / "mapping.yaml").exists()
    assert [r.match for r in Mapping(str(new_path), "unsorted").rules] == ["RE", "LS"]


@pytest.mark.parametrize("hostile", ["../../etc/passwd", "/etc/passwd"])
def test_mapping_path_cannot_escape_the_share(client, env, hostile):
    token = login(client)
    before = str(env["mapping"].path)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": hostile,
            "fallback_folder": "unsorted", "quarantine_folder": "quarantaene",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20",
        },
    )

    assert str(env["mapping"].path) == before
    assert Settings.load(env["config"]).mapping_path == "mapping.yaml"


def test_settings_are_persisted(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml",
            "fallback_folder": "sonstiges", "quarantine_folder": "quarantaene",
            "match_body": "on", "filename_prefix": "date", "poll_interval": "60",
            "max_attachment_size_mb": "10", "max_message_size_mb": "20",
            "max_attachments_per_message": "5",
        },
    )

    saved = Settings.load(env["config"])
    assert saved.fallback_folder == "sonstiges"
    assert saved.match_body is True
    assert saved.filename_prefix == "date"
    assert saved.max_attachment_size_mb == 10


def test_config_file_is_written_with_restrictive_permissions(env):
    path = Settings.path_for(env["config"])

    assert oct(path.stat().st_mode & 0o777) == "0o600"


# --- shares (several NAS) ----------------------------------------------------


def test_add_share(client, env, tmp_path):
    token = login(client)
    nas3 = tmp_path / "nas3"
    nas3.mkdir()

    client.post(
        "/shares/save",
        data={"csrf_token": token, "id": "", "label": "NAS 3", "path": str(nas3), "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    assert any(s.label == "NAS 3" and s.path == str(nas3) for s in saved.shares)


def test_edit_share_keeps_its_id(client, env, tmp_path):
    token = login(client)
    moved = tmp_path / "verschoben"
    moved.mkdir()

    client.post(
        "/shares/save",
        data={"csrf_token": token, "id": "nas2", "label": "NAS 2", "path": str(moved),
              "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    assert saved.share("nas2").path == str(moved)


@pytest.mark.parametrize("path", ["relativ/pfad", "/", "/etc", ""])
def test_share_path_must_be_an_absolute_non_system_mount_point(client, env, path):
    token = login(client)

    client.post(
        "/shares/save", data={"csrf_token": token, "id": "", "label": "Boese", "path": path}
    )

    saved = Settings.load(env["config"])
    assert all(s.label != "Boese" for s in saved.shares)


def test_share_that_is_not_mounted_yet_is_saved_with_a_warning(client, env, tmp_path):
    token = login(client)

    response = client.post(
        "/shares/save",
        data={"csrf_token": token, "id": "", "label": "Spaeter", "path": str(tmp_path / "kommt-noch"),
              "enabled": "on"},
        follow_redirects=True,
    )

    assert "Achtung" in response.get_data(as_text=True)
    assert any(s.label == "Spaeter" for s in Settings.load(env["config"]).shares)


def test_deleting_a_share_moves_its_rules_to_the_default_one(client, env):
    token = login(client)
    client.post(
        "/rules/0/update",
        data={"csrf_token": token, "match": "RE", "folder": "rechnungen", "share": "nas2",
              "account": ALL_ACCOUNTS},
    )
    assert env["mapping"].rules[0].share == "nas2"

    client.post("/shares/nas2/delete", data={"csrf_token": token})

    assert Settings.load(env["config"]).share("nas2") is None
    assert all(r.share == "" for r in env["mapping"].rules)


def test_deleting_a_share_unpins_the_printers_using_it(client, env):
    token = login(client)
    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "kopierer", "label": "Kopierer Flur",
              "sender": "scan@example.com", "source_share": "nas2", "source_folder": "scans",
              "target_share": "nas2", "target_folder": "eingang", "enabled": "on"},
    )

    client.post("/shares/nas2/delete", data={"csrf_token": token})

    printer = Settings.load(env["config"]).printer("kopierer")
    assert (printer.source_share, printer.target_share) == ("", "")


def test_the_last_share_cannot_be_deleted(client, env):
    token = login(client)
    client.post("/shares/nas2/delete", data={"csrf_token": token})

    client.post("/shares/default/delete", data={"csrf_token": token})

    assert len(Settings.load(env["config"]).shares) == 1


# --- rules on a share --------------------------------------------------------


def test_add_rule_for_a_specific_share(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "Angebot", "folder": "angebote", "share": "nas2"},
    )

    assert env["mapping"].rules[-1].share == "nas2"


def test_rule_for_an_unknown_share_is_rejected(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "Angebot", "folder": "angebote", "share": "gibtsnicht"},
    )

    assert all(r.match != "Angebot" for r in env["mapping"].rules)


def test_rule_folder_is_checked_against_the_share_it_names(client, env):
    token = login(client)

    client.post(
        "/rules/add",
        data={"csrf_token": token, "match": "X", "folder": "../raus", "share": "nas2"},
    )

    assert all(r.folder != "../raus" for r in env["mapping"].rules)


# --- printers ----------------------------------------------------------------


def test_add_printer(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Scanner Lager",
              "sender": "lager@scanner.lan", "source_share": "", "source_folder": "scans/lager",
              "target_share": "nas2", "target_folder": "lager", "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    printer = next(p for p in saved.printers if p.label == "Scanner Lager")
    assert printer.sender == "lager@scanner.lan"
    assert printer.source_folder == "scans/lager"
    assert printer.target_share == "nas2"


def test_printer_needs_a_mail_address_or_a_pickup_folder(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Leer", "sender": "",
              "source_folder": "", "target_folder": "irgendwo", "enabled": "on"},
    )

    assert all(p.label != "Leer" for p in Settings.load(env["config"]).printers)


def test_printer_needs_a_label(client, env):
    token = login(client)

    before = len(Settings.load(env["config"]).printers)
    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "", "sender": "x@y.z", "enabled": "on"},
    )

    assert len(Settings.load(env["config"]).printers) == before


def test_printer_target_inside_its_pickup_folder_is_rejected(client, env):
    """That would re-import the same document on every single cycle."""
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Schleife", "sender": "",
              "source_share": "", "source_folder": "scans",
              "target_share": "", "target_folder": "scans/fertig", "enabled": "on"},
    )

    assert all(p.label != "Schleife" for p in Settings.load(env["config"]).printers)


def test_printer_folder_cannot_escape_the_share(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "", "label": "Boese", "sender": "",
              "source_folder": "../../etc", "target_folder": "eingang", "enabled": "on"},
    )

    assert all(p.label != "Boese" for p in Settings.load(env["config"]).printers)


def test_edit_printer_keeps_its_id(client, env):
    token = login(client)

    client.post(
        "/printers/save",
        data={"csrf_token": token, "id": "kopierer", "label": "Kopierer Flur (neu)",
              "sender": "scan@example.com", "source_folder": "scans",
              "target_folder": "eingang", "enabled": "on"},
    )

    saved = Settings.load(env["config"])
    assert saved.printer("kopierer").label == "Kopierer Flur (neu)"
    assert len(saved.printers) == 1


def test_delete_printer(client, env):
    token = login(client)

    client.post("/printers/kopierer/delete", data={"csrf_token": token})

    assert Settings.load(env["config"]).printers == []


# --- quarantine extensions ---------------------------------------------------


def test_blocked_extensions_are_editable(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "unsorted",
            "quarantine_folder": "quarantaene", "blocked_extensions": ".EXE, com; bat\nps1",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    assert Settings.load(env["config"]).blocked_extensions == ["exe", "com", "bat", "ps1"]


def test_blocked_extensions_can_be_emptied(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "unsorted",
            "quarantine_folder": "quarantaene", "blocked_extensions": "",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    assert Settings.load(env["config"]).blocked_extensions == []


def test_changed_fallback_folder_takes_effect_without_a_restart(client, env):
    token = login(client)

    client.post(
        "/settings",
        data={
            "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "sonstiges",
            "quarantine_folder": "quarantaene", "blocked_extensions": "exe",
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
        },
    )

    assert env["mapping"].resolve("xyz").folder == "sonstiges"


@pytest.mark.parametrize("field", ["fallback_folder", "quarantine_folder"])
def test_settings_reject_a_folder_that_leaves_the_share(client, env, field):
    token = login(client)
    data = {
        "csrf_token": token, "mapping_path": "mapping.yaml", "fallback_folder": "unsorted",
        "quarantine_folder": "quarantaene", "blocked_extensions": "exe",
        "filename_prefix": "date_sender", "poll_interval": "300",
        "max_attachment_size_mb": "25", "max_message_size_mb": "50",
        "max_attachments_per_message": "20", "printer_min_age_seconds": "20",
    }
    data[field] = "../raus"

    client.post("/settings", data=data)

    saved = Settings.load(env["config"])
    assert getattr(saved, field) != "../raus"
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
