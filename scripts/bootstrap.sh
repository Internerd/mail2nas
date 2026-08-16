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
      - state:/data

volumes:
  # Local state (processed-message tracking), no need for this to live on the share.
  state:
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
            )
        except KeyError as exc:
            raise SystemExit(f"Missing required environment variable: {exc.args[0]}") from exc
MAIL2NAS_EOF

# --- mail2nas/mapping.py ---
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

        # The mapping file is edited by hand on a network share, so a malformed
        # or half-written version is a matter of when, not if. Keep serving the
        # last good rules instead of letting the exception escape: it would
        # propagate out of the IMAP loop and leave the service reconnecting in
        # a tight loop, archiving nothing at all until someone noticed.
        try:
            with self._path.open("r", encoding="utf-8") as fh:
                raw = yaml.safe_load(fh) or {}
            if not isinstance(raw, dict):
                raise ValueError("file must contain a mapping of keyword -> folder")
            rules = sorted(
                ((str(keyword), str(folder)) for keyword, folder in raw.items()),
                # Longest keyword first, so "Rechnungskorrektur" beats "RE".
                key=lambda kv: len(kv[0]),
                reverse=True,
            )
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

    def resolve(self, *texts: str) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword). Falls back if nothing matches."""
        haystack = " ".join(t for t in texts if t).lower()
        for keyword, folder in self._rules:
            if keyword.lower() in haystack:
                return folder, keyword
        return self._fallback_folder, None
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

# --- mail2nas/archiver.py ---
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
from .filenames import safe_join, sanitize_filename, unique_path, write_atomic
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
                target_dir = self._target_dir(folder_name)
                out_name = self._build_filename(date_prefix, sender_addr, filename)

                if self.config.dry_run:
                    logger.info("[dry-run] would save %s -> %s", out_name, target_dir)
                    continue

                target_dir.mkdir(parents=True, exist_ok=True)
                out_path = unique_path(target_dir, out_name)
                write_atomic(out_path, payload)
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

    def _target_dir(self, folder_name: str) -> Path:
        """Map a configured folder name onto a directory inside the storage root.

        Folder names come from mapping.yaml on the share and are therefore
        untrusted; anything that would escape the storage root is rejected and
        replaced with the fallback folder rather than being written outside.
        """
        for candidate, note in ((folder_name, None), (self.config.fallback_folder, "fallback"), ("unsorted", "built-in")):
            try:
                target = safe_join(self.config.storage_root, candidate)
            except ValueError as exc:
                logger.error(
                    "Unsafe target folder %r (%s) - not writing outside the storage root", candidate, exc
                )
                continue
            if note and candidate != folder_name:
                logger.warning("Using %s folder %r instead of %r", note, candidate, folder_name)
            return target
        raise ValueError("No usable target folder inside the storage root")

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

        # Check both the name as received and the name actually written to
        # disk: sanitizing can change the trailing extension, and only the
        # latter is what a file manager will act on when someone opens it.
        extensions = {_extension_of(filename), _extension_of(sanitize_filename(_decode(filename)))}
        if extensions & self.config.blocked_extensions:
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

# --- mail2nas/main.py ---
cat > mail2nas/main.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import logging
import os
import sys
import time
from pathlib import Path

from .archiver import Archiver
from .config import Config
from .mapping import Mapping
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


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    _check_storage_root(config)
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

# --- tests/test_mapping.py ---
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


def test_broken_yaml_keeps_previous_rules_instead_of_raising(tmp_path):
    """A half-written mapping.yaml on the share must not take the service down."""
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")
    assert mapping.resolve("RE 1")[0] == "rechnungen"

    mapping_path.write_text("RE: [unclosed\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()  # must not raise

    assert mapping.resolve("RE 1")[0] == "rechnungen"


def test_non_mapping_yaml_keeps_previous_rules(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("- just\n- a\n- list\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))

    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "rechnungen"


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

    assert archiver._target_dir("../evil") == tmp_path / "unsorted"
    assert archiver._target_dir("rechnungen") == tmp_path / "rechnungen"


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

# --- mail2nas/__init__.py ---
touch mail2nas/__init__.py

# --- tests/__init__.py ---
touch tests/__init__.py

echo "Fertig: $TARGET enthaelt jetzt das komplette mail2nas-Projekt."
echo "Naechste Schritte:"
echo "  cd $TARGET"
echo "  cp .env.example .env && \$EDITOR .env"
echo "  # siehe README.md (Abschnitt 'Installation, Variante 2') fuer den Rest"
