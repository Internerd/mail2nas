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

set -euo pipefail

TARGET="${1:-/opt/mail2nas}"
mkdir -p "$TARGET"/mail2nas "$TARGET"/config "$TARGET"/tests
cd "$TARGET"

echo "Schreibe Projektdateien nach $TARGET ..."

# --- requirements.txt --------------------------------------------------
cat > requirements.txt <<'MAIL2NAS_EOF'
imapclient>=3.0,<4.0
PyYAML>=6.0,<7.0
MAIL2NAS_EOF

# --- requirements-dev.txt ------------------------------------------------
cat > requirements-dev.txt <<'MAIL2NAS_EOF'
-r requirements.txt
pytest>=8.0,<9.0
MAIL2NAS_EOF

# --- .env.example --------------------------------------------------------
cat > .env.example <<'MAIL2NAS_EOF'
# Copy to .env and fill in real values. Never commit the real .env file.

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
# Mounted by docker-compose.yml at /mnt/nas inside the container.
SMB_HOST=nas.local
SMB_SHARE=Belege
SMB_USER=mail2nas
SMB_PASSWORD=changeme
# Use an empty string ("") if your SMB server has no domain/workgroup.
SMB_DOMAIN=WORKGROUP

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
BLOCKED_EXTENSIONS=exe,com,scr,bat,cmd,ps1,psm1,vbs,vbe,js,jse,wsf,wsh,msi,msp,msc,jar,cpl,dll,sys,gadget,application,pif,reg,hta,lnk,sh,apk
QUARANTINE_FOLDER=quarantaene

# --- Misc ------------------------------------------------------------------
STATE_DB_PATH=/data/state.db
LOG_LEVEL=INFO
# Set to true to log what would happen without writing files or touching IMAP flags.
DRY_RUN=false
MAIL2NAS_EOF

# --- .dockerignore ---------------------------------------------------------
cat > .dockerignore <<'MAIL2NAS_EOF'
.git
.env
__pycache__
*.pyc
.venv
venv
.pytest_cache
tests
README.md
MAIL2NAS_EOF

# --- Dockerfile --------------------------------------------------------
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

# --- docker-compose.yml -------------------------------------------------
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
      STORAGE_ROOT: /mnt/nas
      STATE_DB_PATH: /data/state.db
    volumes:
      - nas:/mnt/nas
      - state:/data

volumes:
  # Mounted by the Docker daemon on the host via cifs-utils - the container
  # itself never needs SMB credentials or CAP_SYS_ADMIN.
  # Requires cifs-utils to be installed on the Proxmox host/LXC running Docker.
  nas:
    driver: local
    driver_opts:
      type: cifs
      device: "//${SMB_HOST}/${SMB_SHARE}"
      o: "username=${SMB_USER},password=${SMB_PASSWORD},domain=${SMB_DOMAIN},vers=3.0,uid=1000,gid=1000,file_mode=0664,dir_mode=0775"
  # Local state (processed-message tracking), no need for this to live on the share.
  state:
MAIL2NAS_EOF

# --- config/mapping.example.yaml -----------------------------------------
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

# --- mail2nas/__init__.py -------------------------------------------------
touch mail2nas/__init__.py

# --- mail2nas/config.py ---------------------------------------------------
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

    @classmethod
    def from_env(cls) -> "Config":
        try:
            return cls(
                imap_host=os.environ["IMAP_HOST"],
                imap_port=int(os.environ.get("IMAP_PORT", "993")),
                imap_user=os.environ["IMAP_USER"],
                imap_password=os.environ["IMAP_PASSWORD"],
                imap_ssl=_bool("IMAP_SSL", True),
                imap_folder=os.environ.get("IMAP_FOLDER", "INBOX"),
                imap_processed_folder=os.environ.get("IMAP_PROCESSED_FOLDER") or None,
                imap_oversized_folder=os.environ.get("IMAP_OVERSIZED_FOLDER") or None,
                imap_mode=os.environ.get("IMAP_MODE", "poll").lower(),
                poll_interval=int(os.environ.get("POLL_INTERVAL_SECONDS", "300")),
                storage_root=os.environ.get("STORAGE_ROOT", "/mnt/nas"),
                mapping_path=os.environ.get("MAPPING_PATH", "mapping.yaml"),
                fallback_folder=os.environ.get("FALLBACK_FOLDER", "unsorted"),
                match_body=_bool("MATCH_BODY", False),
                filename_prefix=os.environ.get("FILENAME_PREFIX", "date_sender"),
                max_attachment_size_mb=int(os.environ.get("MAX_ATTACHMENT_SIZE_MB", "25")),
                max_message_size_mb=int(os.environ.get("MAX_MESSAGE_SIZE_MB", "50")),
                max_attachments_per_message=int(os.environ.get("MAX_ATTACHMENTS_PER_MESSAGE", "20")),
                blocked_extensions=_extension_set("BLOCKED_EXTENSIONS", DEFAULT_BLOCKED_EXTENSIONS),
                quarantine_folder=os.environ.get("QUARANTINE_FOLDER", "quarantaene"),
                state_db_path=os.environ.get("STATE_DB_PATH", "/data/state.db"),
                dry_run=_bool("DRY_RUN", False),
            )
        except KeyError as exc:
            raise SystemExit(f"Missing required environment variable: {exc.args[0]}") from exc
MAIL2NAS_EOF

# --- mail2nas/mapping.py ---------------------------------------------------
cat > mail2nas/mapping.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)


class Mapping:
    """Keyword -> target-subfolder mapping, reloaded from disk on demand.

    The mapping file is expected to live on the same SMB share the
    attachments are archived to, so it can be edited by anyone with
    access to the share without touching the container/deployment.
    """

    def __init__(self, path: str, fallback_folder: str):
        self._path = Path(path)
        self._fallback_folder = fallback_folder
        self._rules: list[tuple[str, str]] = []
        self._mtime: float | None = None
        self.reload(force=True)

    def reload(self, force: bool = False) -> None:
        try:
            mtime = self._path.stat().st_mtime
        except FileNotFoundError:
            if force:
                logger.warning(
                    "Mapping file %s not found, all mail will go to the fallback folder", self._path
                )
                self._rules = []
                self._mtime = None
            return

        if not force and self._mtime == mtime:
            return

        with self._path.open("r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}

        if not isinstance(raw, dict):
            raise ValueError(f"Mapping file {self._path} must contain a mapping of keyword -> folder")

        # Longest keyword first, so "Rechnungskorrektur" is checked before "RE".
        self._rules = sorted(
            ((str(keyword), str(folder)) for keyword, folder in raw.items()),
            key=lambda kv: len(kv[0]),
            reverse=True,
        )
        self._mtime = mtime
        logger.info("Loaded %d mapping rule(s) from %s", len(self._rules), self._path)

    def resolve(self, *texts: str) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword). Falls back if nothing matches."""
        haystack = " ".join(t for t in texts if t).lower()
        for keyword, folder in self._rules:
            if keyword.lower() in haystack:
                return folder, keyword
        return self._fallback_folder, None
MAIL2NAS_EOF

# --- mail2nas/filenames.py --------------------------------------------------
cat > mail2nas/filenames.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import re
import unicodedata
from pathlib import Path

_UNSAFE = re.compile(r"[^A-Za-z0-9._-]+")


def sanitize_filename(name: str) -> str:
    """Strip characters that are awkward on SMB shares / cross-platform filesystems."""
    name = unicodedata.normalize("NFKD", name)
    name = _UNSAFE.sub("_", name).strip("._")
    return name or "attachment"


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
MAIL2NAS_EOF

# --- mail2nas/state.py -------------------------------------------------------
cat > mail2nas/state.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import sqlite3
from pathlib import Path


class ProcessedStore:
    """Tracks Message-IDs that have already been archived.

    IMAP's \\Seen flag alone is not a safe idempotency marker (it can be
    reset by another client, or the folder can be re-synced), so we keep a
    small local record of what has actually been written to the share.
    """

    def __init__(self, db_path: str):
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._conn = sqlite3.connect(db_path)
        self._conn.execute(
            "CREATE TABLE IF NOT EXISTS processed_messages ("
            "message_id TEXT PRIMARY KEY, "
            "processed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
        )
        self._conn.commit()

    def is_processed(self, message_id: str) -> bool:
        cur = self._conn.execute(
            "SELECT 1 FROM processed_messages WHERE message_id = ?", (message_id,)
        )
        return cur.fetchone() is not None

    def mark_processed(self, message_id: str) -> None:
        self._conn.execute(
            "INSERT OR IGNORE INTO processed_messages (message_id) VALUES (?)", (message_id,)
        )
        self._conn.commit()

    def close(self) -> None:
        self._conn.close()
MAIL2NAS_EOF

# --- mail2nas/archiver.py -----------------------------------------------------
cat > mail2nas/archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import email
import logging
from email.header import decode_header, make_header
from email.message import Message
from email.utils import parseaddr, parsedate_to_datetime
from pathlib import Path

from imapclient import IMAPClient

from .config import Config
from .filenames import sanitize_filename, unique_path
from .mapping import Mapping
from .state import ProcessedStore

logger = logging.getLogger(__name__)


def _decode(value: str | None) -> str:
    if not value:
        return ""
    try:
        return str(make_header(decode_header(value)))
    except Exception:
        return value


def _message_id(msg: Message, uid: int) -> str:
    return msg.get("Message-ID") or f"<no-message-id-uid-{uid}@mail2nas>"


def _extension_of(filename: str) -> str:
    if "." not in filename:
        return ""
    return filename.rsplit(".", 1)[-1].strip().lower()


class Archiver:
    def __init__(self, config: Config, mapping: Mapping, store: ProcessedStore):
        self.config = config
        self.mapping = mapping
        self.store = store

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

        subject = _decode(msg.get("Subject"))
        _, sender_addr = parseaddr(_decode(msg.get("From")))
        body = self._extract_body(msg) if self.config.match_body else ""
        mail_folder, mail_keyword = self.mapping.resolve(subject, body)

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

                folder_name, matched_keyword, quarantined = self._resolve_attachment_folder(
                    filename, mail_folder, mail_keyword
                )
                target_dir = Path(self.config.storage_root) / folder_name
                out_name = self._build_filename(date_prefix, sender_addr, filename)

                if self.config.dry_run:
                    logger.info("[dry-run] would save %s -> %s", out_name, target_dir)
                    continue

                target_dir.mkdir(parents=True, exist_ok=True)
                out_path = unique_path(target_dir, out_name)
                out_path.write_bytes(payload)
                saved.append(str(out_path))
                logger.info(
                    "UID %s '%s': attachment '%s' matched '%s'%s -> %s",
                    uid,
                    subject,
                    filename,
                    matched_keyword or "<fallback>",
                    " [QUARANTAENE: gesperrte Dateiendung]" if quarantined else "",
                    out_path,
                )

        if not self.config.dry_run:
            self.store.mark_processed(message_id)
            client.add_flags([uid], [b"\\Seen"])
            if self.config.imap_processed_folder:
                client.move([uid], self.config.imap_processed_folder)
        return True

    def _resolve_attachment_folder(
        self, filename: str, mail_folder: str, mail_keyword: str | None
    ) -> tuple[str, str | None, bool]:
        """Decide the target folder for a single attachment.

        The attachment's own filename is checked against the mapping first,
        so multiple differently-named attachments on the same mail can land
        in different folders. Falls back to the mail-level (subject/body)
        match when the filename itself gives no hint. Attachments with a
        blocked extension are always quarantined, regardless of any keyword
        match, so a malicious/executable attachment can never be renamed
        into a trusted-looking business folder just by naming it "Rechnung.exe".
        """
        folder_name, matched_keyword = self.mapping.resolve(filename)
        if matched_keyword is None:
            folder_name, matched_keyword = mail_folder, mail_keyword

        if _extension_of(filename) in self.config.blocked_extensions:
            return self.config.quarantine_folder, matched_keyword, True
        return folder_name, matched_keyword, False

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

# --- mail2nas/main.py ---------------------------------------------------------
cat > mail2nas/main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import os
import sys
import time

from .archiver import Archiver
from .config import Config
from .mapping import Mapping
from .state import ProcessedStore

logger = logging.getLogger("mail2nas")


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    mapping_full_path = os.path.join(config.storage_root, config.mapping_path)
    mapping = Mapping(mapping_full_path, config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    archiver = Archiver(config, mapping, store)

    logger.info(
        "Starting mail2nas: imap=%s folder=%s mode=%s storage=%s dry_run=%s",
        config.imap_host,
        config.imap_folder,
        config.imap_mode,
        config.storage_root,
        config.dry_run,
    )

    try:
        while True:
            try:
                client = archiver.connect()
            except Exception:
                logger.exception("IMAP connection failed, retrying in %ss", config.poll_interval)
                time.sleep(config.poll_interval)
                continue

            try:
                if config.imap_mode == "idle":
                    _run_idle(archiver, client, config)
                else:
                    _run_poll(archiver, client, config)
            except Exception:
                logger.exception("IMAP session failed, reconnecting in %ss", config.poll_interval)
            finally:
                try:
                    client.logout()
                except Exception:
                    pass
            time.sleep(config.poll_interval)
    finally:
        store.close()


def _run_poll(archiver: Archiver, client, config: Config) -> None:
    while True:
        count = archiver.run_once(client)
        if count:
            logger.info("Processed %d message(s)", count)
        time.sleep(config.poll_interval)


def _run_idle(archiver: Archiver, client, config: Config) -> None:
    count = archiver.run_once(client)
    if count:
        logger.info("Processed %d message(s)", count)

    idle_timeout = config.poll_interval or 300
    while True:
        client.idle()
        try:
            client.idle_check(timeout=idle_timeout)
        finally:
            client.idle_done()
        count = archiver.run_once(client)
        if count:
            logger.info("Processed %d message(s)", count)


if __name__ == "__main__":
    main()
MAIL2NAS_EOF

# --- tests/__init__.py ---------------------------------------------------
touch tests/__init__.py

# --- tests/test_mapping.py ------------------------------------------------
cat > tests/test_mapping.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import os
import textwrap

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

    folder, keyword = mapping.resolve("Ihre re 12345")

    assert folder == "rechnungen"
    assert keyword == "RE"


def test_resolve_falls_back_when_no_keyword_matches(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    folder, keyword = mapping.resolve("Newsletter August")

    assert folder == "unsorted"
    assert keyword is None


def test_resolve_prefers_longer_keyword_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    folder, keyword = mapping.resolve("Rechnungskorrektur zur RE-2024-01")

    assert folder == "korrekturen"
    assert keyword == "Rechnungskorrektur"


def test_missing_mapping_file_falls_back_to_default(tmp_path):
    mapping = Mapping(str(tmp_path / "does-not-exist.yaml"), fallback_folder="unsorted")

    folder, keyword = mapping.resolve("Rechnung 123")

    assert folder == "unsorted"
    assert keyword is None


def test_reload_picks_up_changes(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    _write_mapping(mapping_path, "RE: invoices\n")
    # Nudge mtime forward in case the filesystem has coarse timestamp resolution.
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "invoices"
MAIL2NAS_EOF

# --- tests/test_filenames.py ----------------------------------------------
cat > tests/test_filenames.py <<'MAIL2NAS_EOF'
from __future__ import annotations

from mail2nas.filenames import sanitize_filename, unique_path


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
MAIL2NAS_EOF

# --- tests/test_archiver.py -------------------------------------------------
cat > tests/test_archiver.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import textwrap
from email.message import EmailMessage

from mail2nas.archiver import Archiver
from mail2nas.config import DEFAULT_BLOCKED_EXTENSIONS, Config
from mail2nas.mapping import Mapping
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


def _make_archiver(tmp_path, mapping_content: str | None = None, **config_overrides) -> Archiver:
    config = _make_config(tmp_path, **config_overrides)
    mapping_path = tmp_path / "mapping.yaml"
    if mapping_content is not None:
        _write_mapping(mapping_path, mapping_content)
    mapping = Mapping(str(mapping_path), config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    return Archiver(config, mapping, store)


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
    mail_folder, mail_keyword = archiver.mapping.resolve("RE-2024-001 mit Lieferschein")

    folder, keyword, quarantined = archiver._resolve_attachment_folder(
        "Lieferschein_4711.pdf", mail_folder, mail_keyword
    )

    assert folder == "lieferscheine"
    assert keyword == "Lieferschein"
    assert quarantined is False


def test_resolve_attachment_folder_falls_back_to_mail_level_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    mail_folder, mail_keyword = archiver.mapping.resolve("RE-2024-001")

    # "anhang1.pdf" itself does not match any keyword.
    folder, keyword, quarantined = archiver._resolve_attachment_folder(
        "anhang1.pdf", mail_folder, mail_keyword
    )

    assert folder == "rechnungen"
    assert keyword == "RE"
    assert quarantined is False


def test_resolve_attachment_folder_quarantines_blocked_extension_even_with_keyword_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")

    folder, keyword, quarantined = archiver._resolve_attachment_folder(
        "Rechnung.exe", "unsorted", None
    )

    assert folder == "quarantaene"
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
MAIL2NAS_EOF

echo "Fertig: $TARGET enthaelt jetzt das komplette mail2nas-Projekt."
echo "Naechste Schritte:"
echo "  cd $TARGET"
echo "  cp .env.example .env && \$EDITOR .env"
echo "  # siehe README.md (Abschnitt 'Installation auf Proxmox ohne Git') fuer den Rest"
