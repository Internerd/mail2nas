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

# --- Weboberflaeche zur Konfiguration ---------------------------------------
# Erreichbar unter http://<container-ip>:<WEB_PORT>. Ohne gesetztes
# WEB_PASSWORD startet sie NICHT - die Seite zeigt und aendert IMAP-
# Zugangsdaten und darf daher nicht ohne Anmeldung laufen.
# Nur im vertrauenswuerdigen LAN veroeffentlichen, nicht ins Internet.
WEB_ENABLED=true
WEB_PORT=8080
WEB_USER=admin
WEB_PASSWORD=

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

# --- mail2nas/mapping.py ---
cat > mail2nas/mapping.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import fnmatch
import logging
from dataclasses import dataclass
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)

ALL_ACCOUNTS = "all"


@dataclass(frozen=True)
class Rule:
    """One keyword -> folder rule.

    `account` is either ALL_ACCOUNTS or the id of a single mail account, so a
    rule can be limited to one mailbox when several are configured.
    """

    match: str
    folder: str
    account: str = ALL_ACCOUNTS

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


def _coerce_rules(raw: object) -> list[Rule]:
    """Build the rule list from either mapping-file format.

    v2 (ordered, explicit priority - first match wins):
        version: 2
        rules:
          - match: "Rechnung*"
            folder: rechnungen
            account: all

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
                Rule(match=match, folder=folder, account=str(entry.get("account") or ALL_ACCOUNTS))
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
    payload = {
        "version": 2,
        "rules": [{"match": r.match, "folder": r.folder, "account": r.account} for r in rules],
    }
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

    def set_path(self, path: str) -> None:
        """Point at a different mapping file and load it immediately."""
        self._path = Path(path)
        self._mtime = None
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

    def resolve(self, *texts: str, account: str | None = None) -> tuple[str, str | None]:
        """Return (target_folder, matched_pattern). Falls back if nothing matches."""
        haystack = " ".join(t for t in texts if t).lower()
        for rule in self._rules:
            if rule.applies_to(account) and rule.matches(haystack):
                return rule.folder, rule.match
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
        mail_folder, mail_keyword = self.mapping.resolve(subject, body, account=self.config.account_id)

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
        folder_name, matched_keyword = self.mapping.resolve(filename, account=self.config.account_id)
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

# --- mail2nas/settings.py ---
cat > mail2nas/settings.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses
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


def make_account_id(name: str) -> str:
    ident = _ID_SAFE.sub("-", name.strip().lower()).strip("-")
    return ident or f"konto-{secrets.token_hex(3)}"


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
class Settings:
    """Everything the web UI can change, persisted next to the state database.

    Deliberately NOT on the SMB share: it holds IMAP passwords, and the share
    is readable by everyone who can reach it.
    """

    accounts: list[Account] = field(default_factory=list)
    mapping_path: str = "mapping.yaml"
    fallback_folder: str = "unsorted"
    quarantine_folder: str = "quarantaene"
    match_body: bool = False
    filename_prefix: str = "date_sender"
    poll_interval: int = 300
    max_attachment_size_mb: int = 25
    max_message_size_mb: int = 50
    max_attachments_per_message: int = 20

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
            accounts = [
                Account(**{k: v for k, v in entry.items() if k in {f.name for f in dataclasses.fields(Account)}})
                for entry in raw.get("accounts", [])
                if isinstance(entry, dict)
            ]
            known = {f.name for f in dataclasses.fields(cls)} - {"accounts"}
            values = {k: v for k, v in raw.items() if k in known}
            return cls(accounts=accounts, **values)
        except Exception as exc:
            # Falling back to the environment keeps the archiver running rather
            # than leaving it dead because a hand-edited config file broke.
            logger.error("Could not read %s (%s) - falling back to the environment", path, exc)
            return cls.from_env_config(config)

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
            mapping_path=config.mapping_path,
            fallback_folder=config.fallback_folder,
            quarantine_folder=config.quarantine_folder,
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

    def unique_id(self, desired: str, ignore: str | None = None) -> str:
        """Return `desired`, suffixed if another account already uses it."""
        taken = {a.id for a in self.accounts if a.id != ignore}
        if desired not in taken:
            return desired
        for n in range(2, 1000):
            candidate = f"{desired}-{n}"
            if candidate not in taken:
                return candidate
        return f"{desired}-{secrets.token_hex(3)}"

    # --- bridging to the archiver ---------------------------------------

    def config_for(self, config: Config, account: Account) -> Config:
        """Build the per-account Config the Archiver works with."""
        return dataclasses.replace(
            config,
            imap_host=account.host,
            imap_port=account.port,
            imap_ssl=account.ssl,
            imap_user=account.user,
            imap_password=account.password,
            imap_folder=account.folder,
            imap_processed_folder=account.processed_folder or None,
            imap_oversized_folder=account.oversized_folder or None,
            imap_mode=account.mode,
            poll_interval=self.poll_interval,
            mapping_path=self.mapping_path,
            fallback_folder=self.fallback_folder,
            quarantine_folder=self.quarantine_folder,
            match_body=self.match_body,
            filename_prefix=self.filename_prefix,
            max_attachment_size_mb=self.max_attachment_size_mb,
            max_message_size_mb=self.max_message_size_mb,
            max_attachments_per_message=self.max_attachments_per_message,
            account_id=account.id,
        )
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
from .settings import Account, Settings
from .state import ProcessedStore

logger = logging.getLogger(__name__)


class AccountWorker(threading.Thread):
    """Runs one mail account's connect/process loop until asked to stop."""

    def __init__(self, config: Config, account: Account, mapping: Mapping, store: ProcessedStore):
        super().__init__(name=f"mail2nas-{account.id}", daemon=True)
        self.config = config
        self.account = account
        self.archiver = Archiver(config, mapping, store)
        self._stop = threading.Event()
        self.last_error: str | None = None

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        logger.info(
            "[%s] starting: imap=%s folder=%s mode=%s",
            self.account.id,
            self.account.host,
            self.account.folder,
            self.account.mode,
        )
        while not self._stop.is_set():
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
            self._stop.wait(self.config.poll_interval)
        logger.info("[%s] stopped", self.account.id)

    def _process(self, client) -> None:
        count = self.archiver.run_once(client)
        if count:
            logger.info("[%s] processed %d message(s)", self.account.id, count)

    def _loop_poll(self, client) -> None:
        while not self._stop.is_set():
            self._process(client)
            self._stop.wait(self.config.poll_interval)

    def _loop_idle(self, client) -> None:
        self._process(client)
        timeout = self.config.poll_interval or 300
        while not self._stop.is_set():
            client.idle()
            try:
                client.idle_check(timeout=timeout)
            finally:
                client.idle_done()
            self._process(client)


class Runner:
    """Owns one worker per enabled account and can restart them on changes."""

    def __init__(self, config: Config, settings: Settings, mapping: Mapping, store: ProcessedStore):
        self.config = config
        self.settings = settings
        self.mapping = mapping
        self.store = store
        self._workers: list[AccountWorker] = []
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            self._start_locked()

    def _start_locked(self) -> None:
        accounts = self.settings.enabled_accounts()
        if not accounts:
            logger.warning("No enabled mail accounts configured - nothing to archive yet")
        for account in accounts:
            worker = AccountWorker(
                self.settings.config_for(self.config, account), account, self.mapping, self.store
            )
            worker.start()
            self._workers.append(worker)

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _stop_locked(self) -> None:
        for worker in self._workers:
            worker.stop()
        for worker in self._workers:
            worker.join(timeout=10)
        self._workers = []

    def reload(self, settings: Settings) -> None:
        """Apply changed settings by restarting the account workers."""
        with self._lock:
            logger.info("Applying changed settings - restarting account workers")
            self._stop_locked()
            self.settings = settings
            self.mapping.set_path(str(self.mapping_full_path(settings)))
            self._start_locked()

    def mapping_full_path(self, settings: Settings):
        from .filenames import safe_join

        return safe_join(self.config.storage_root, settings.mapping_path)

    def status(self) -> list[dict]:
        with self._lock:
            return [
                {
                    "id": w.account.id,
                    "label": w.account.display_name(),
                    "alive": w.is_alive(),
                    "error": w.last_error,
                }
                for w in self._workers
            ]

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
    try:
        mapping_full_path = safe_join(config.storage_root, settings.mapping_path)
    except ValueError as exc:
        raise SystemExit(f"Configured mapping path is not usable: {exc}") from None
    mapping = Mapping(str(mapping_full_path), settings.fallback_folder)
    store = ProcessedStore(config.state_db_path)

    logger.info(
        "Starting mail2nas: %d account(s), storage=%s dry_run=%s",
        len(settings.enabled_accounts()),
        config.storage_root,
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
  <p class="hint">Datei: <code>{{ mapping_path }}</code></p>

  <table>
    <thead>
      <tr><th></th><th>Stichwort / Muster</th><th>Zielordner</th><th>Konto</th><th></th></tr>
    </thead>
    <tbody>
    {% for rule in rules %}
      <tr>
        <td class="prio">{{ loop.index }}</td>
        <td colspan="3">
          <form method="post" action="{{ url_for('rule_update', index=loop.index0) }}" class="row">
            <input type="hidden" name="csrf_token" value="{{ csrf_token() }}">
            <div><input type="text" name="match" value="{{ rule.match }}" required></div>
            <div><input type="text" name="folder" value="{{ rule.folder }}" required></div>
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
      <tr><td colspan="5" class="hint">Noch keine Zuordnungen. Alle Anhaenge landen im Fallback-Ordner.</td></tr>
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
    </div>
    <p class="hint">
      Die Grenzwerte begrenzen, was eine einzelne Mail an Speicher und Plattenplatz
      verursachen kann. Die Liste gesperrter Dateiendungen wird ueber die
      Umgebungsvariable <code>BLOCKED_EXTENSIONS</code> gesetzt.
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

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "rechnungen"


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

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"


def test_v1_dict_format_still_works_with_length_priority(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        RE: rechnungen
        Rechnungskorrektur: korrekturen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Rechnungskorrektur zur RE-1")[0] == "korrekturen"


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

    assert (mapping.resolve(text)[0] == "treffer") is expected


def test_plain_keyword_stays_a_substring_match(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: Rechnung
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("Ihre Rechnung 4711")[0] == "rechnungen"


def test_wildcards_are_case_insensitive(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, """
        version: 2
        rules:
          - match: "RECHNUNG*"
            folder: rechnungen
    """)
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    assert mapping.resolve("rechnung_1.pdf")[0] == "rechnungen"


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

    assert mapping.resolve("Rechnung 1", account="privatkonto")[0] == "privat"
    assert mapping.resolve("Rechnung 1", account="firmenkonto")[0] == "firma"


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
    assert mapping.resolve("RE und LS")[0] == "lieferscheine"


def test_rule_missing_folder_is_rejected_and_previous_rules_kept(tmp_path):
    mapping_path = tmp_path / "mapping.yaml"
    _write_mapping(mapping_path, "RE: rechnungen\n")
    mapping = Mapping(str(mapping_path), fallback_folder="unsorted")

    mapping_path.write_text("version: 2\nrules:\n  - match: RE\n", encoding="utf-8")
    stat = mapping_path.stat()
    os.utime(mapping_path, (stat.st_atime, stat.st_mtime + 5))
    mapping.reload()

    assert mapping.resolve("RE 1")[0] == "rechnungen"
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

# --- tests/test_settings.py ---
cat > tests/test_settings.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses

from mail2nas.settings import Account, Settings, make_account_id
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
MAIL2NAS_EOF

# --- tests/test_web.py ---
cat > tests/test_web.py <<'MAIL2NAS_EOF'
from __future__ import annotations

import dataclasses

import pytest

from mail2nas.mapping import ALL_ACCOUNTS, Mapping, Rule
from mail2nas.settings import Account, Settings
from mail2nas.web import create_app
from tests.test_archiver import _make_config

PASSWORD = "s3cret"


@pytest.fixture
def env(tmp_path):
    share = tmp_path / "share"
    share.mkdir()
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
        ]
    )
    settings.save(config)
    mapping = Mapping(str(share / "mapping.yaml"), "unsorted")
    mapping.save([Rule("RE", "rechnungen"), Rule("LS", "lieferscheine")])

    app = create_app(config, settings, mapping)
    app.config.update(TESTING=True)
    return {"app": app, "config": config, "settings": settings, "mapping": mapping, "share": share}


@pytest.fixture
def client(env):
    return env["app"].test_client()


def login(client):
    client.post("/login", data={"user": "admin", "password": PASSWORD})
    with client.session_transaction() as sess:
        sess["csrf"] = "test-token"
    return "test-token"


# --- authentication ----------------------------------------------------------


@pytest.mark.parametrize("path", ["/", "/accounts", "/settings"])
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
            "filename_prefix": "date_sender", "poll_interval": "300",
            "max_attachment_size_mb": "25", "max_message_size_mb": "50",
            "max_attachments_per_message": "20",
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
