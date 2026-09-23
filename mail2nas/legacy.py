"""Reading the configuration of an older installation, once.

Up to this version mail2nas was configured through the `.env`: mailbox, NAS
credentials, folders, limits, even the first printer. All of that now lives in
the local database and is edited in the web UI - but an installation that is
updated must come up exactly as it was, without anyone re-typing a password.

So on the first start of this version the old variables are read one last
time, here, and written into the database (see `migrate.py`). After that they
are ignored, and the update script removes them from the `.env`.

Three generations of `.env` exist in the wild, and they differ in the one
thing that matters most - where attachments go:

1. **Docker cifs volume** (the very first versions): `SMB_HOST`, `SMB_SHARE`,
   `SMB_USER`, `SMB_PASSWORD` in the `.env`, no `STORAGE_BACKEND`. Docker
   mounted the share itself. Current compose files no longer do that, so the
   only way to keep filing onto that share is to talk SMB directly.
2. **Mount on the Proxmox host**: no SMB credentials in the `.env` (they were
   in a file on the host), `NAS_PATH`, no `STORAGE_BACKEND`. The share is a
   bind mount at `/mnt/nas` inside the container.
3. **Direct SMB**: `STORAGE_BACKEND=smb` or `local`, stated explicitly.

Unlike the old parser this one never refuses to start: a value that does not
parse falls back to its default and is logged. A typo in a variable that is
about to be retired must not keep the service from coming up.
"""
from __future__ import annotations

import logging
import os
from collections.abc import Mapping
from dataclasses import dataclass, field

from .config import DEFAULT_BLOCKED_EXTENSIONS, DEFAULT_PRINTABLE_EXTENSIONS, parse_extension_list

logger = logging.getLogger(__name__)

# Every variable an older version read. `update.sh` keeps only what is not in
# this list (plus NAS_PATH where a mount is still in use) when it tidies up.
LEGACY_VARIABLES = (
    "IMAP_HOST", "IMAP_PORT", "IMAP_SSL", "IMAP_USER", "IMAP_PASSWORD", "IMAP_FOLDER",
    "IMAP_PROCESSED_FOLDER", "IMAP_OVERSIZED_FOLDER", "IMAP_MODE", "POLL_INTERVAL_SECONDS",
    "STORAGE_BACKEND", "STORAGE_ROOT", "SMB_HOST", "SMB_SHARE", "SMB_USER", "SMB_PASSWORD",
    "SMB_DOMAIN", "SMB_PORT", "SMB_ROOT", "SMB_ENCRYPT", "MAPPING_PATH", "FALLBACK_FOLDER",
    "MATCH_BODY", "FILENAME_PREFIX", "MAX_ATTACHMENT_SIZE_MB", "MAX_MESSAGE_SIZE_MB",
    "MAX_ATTACHMENTS_PER_MESSAGE", "BLOCKED_EXTENSIONS", "QUARANTINE_FOLDER", "DRY_RUN",
    "PRINTING_ENABLED", "PRINT_TIMEOUT_SECONDS", "PRINTABLE_EXTENSIONS", "PRINTER_NAME",
    "PRINTER_DESTINATION", "PRINTER_SERVER", "PRINTER_OPTIONS", "PRINTER_COPIES",
    "WEB_ENABLED", "WEB_PASSWORD",
)


def _text(env: Mapping[str, str], name: str, default: str = "") -> str:
    value = env.get(name)
    return default if value is None else value.strip()


def _flag(env: Mapping[str, str], name: str, default: bool) -> bool:
    value = env.get(name)
    if value is None or not value.strip():
        return default
    return value.strip().lower() in ("1", "true", "yes", "on", "ja")


def _number(env: Mapping[str, str], name: str, default: int, minimum: int = 1,
            maximum: int | None = None) -> int:
    raw = env.get(name)
    if raw is None or not raw.strip():
        return default
    try:
        value = int(raw.strip())
    except ValueError:
        logger.warning("%s=%r is not a number - using %d", name, raw, default)
        return default
    if value < minimum or (maximum is not None and value > maximum):
        logger.warning("%s=%d is out of range - using %d", name, value, default)
        return default
    return value


def _choice(env: Mapping[str, str], name: str, default: str, allowed: tuple[str, ...]) -> str:
    value = _text(env, name, default).lower() or default
    if value not in allowed:
        logger.warning("%s=%r is not one of %s - using %r", name, value, allowed, default)
        return default
    return value


@dataclass(frozen=True)
class LegacyEnv:
    """The variables of an older `.env`, parsed leniently.

    The attribute names are those of the old `Config`, so the seeding code
    reads the same as it did when it was fed from there.
    """

    imap_host: str = ""
    imap_port: int = 993
    imap_user: str = ""
    imap_password: str = ""
    imap_ssl: bool = True
    imap_folder: str = "INBOX"
    imap_processed_folder: str = ""
    imap_oversized_folder: str = ""
    imap_mode: str = "poll"
    poll_interval: int = 300

    # "smb", "local" or "" (= no archive described at all).
    storage_backend: str = ""
    storage_root: str = "/mnt/nas"
    smb_host: str = ""
    smb_share: str = ""
    smb_user: str = ""
    smb_password: str = ""
    smb_domain: str = ""
    smb_port: int = 445
    smb_root: str = ""
    smb_encrypt: bool = True

    mapping_path: str = "mapping.yaml"
    fallback_folder: str = "unsorted"
    quarantine_folder: str = "quarantaene"
    match_body: bool = False
    filename_prefix: str = "date_sender"
    max_attachment_size_mb: int = 25
    max_message_size_mb: int = 50
    max_attachments_per_message: int = 20
    blocked_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_BLOCKED_EXTENSIONS)
    )
    dry_run: bool = False

    printing_enabled: bool = True
    print_timeout: int = 120
    printable_extensions: frozenset[str] = field(
        default_factory=lambda: parse_extension_list(DEFAULT_PRINTABLE_EXTENSIONS)
    )
    printer_name: str = ""
    printer_destination: str = ""
    printer_server: str = ""
    printer_options: str = ""
    printer_copies: int = 1

    # Which of the old variables were set at all - "the .env says nothing
    # about it" and "the .env says the default" are different things when
    # deciding whether there is anything to carry over.
    present: frozenset[str] = frozenset()

    @property
    def has_mailbox(self) -> bool:
        return bool(self.imap_host and self.imap_user)

    @property
    def has_archive(self) -> bool:
        return self.storage_backend in ("smb", "local")

    @property
    def has_options(self) -> bool:
        """True if any general setting was set in the `.env`."""
        return bool(self.present - {"WEB_ENABLED", "WEB_PASSWORD"})

    @classmethod
    def from_environ(cls, env: Mapping[str, str] | None = None) -> "LegacyEnv":
        env = os.environ if env is None else env
        present = frozenset(
            name for name in LEGACY_VARIABLES if (env.get(name) or "").strip()
        )

        smb = {
            "smb_host": _text(env, "SMB_HOST"),
            "smb_share": _text(env, "SMB_SHARE").strip("/\\"),
            "smb_user": _text(env, "SMB_USER"),
            "smb_password": env.get("SMB_PASSWORD") or "",
        }
        return cls(
            imap_host=_text(env, "IMAP_HOST"),
            imap_port=_number(env, "IMAP_PORT", 993, 1, 65535),
            imap_user=_text(env, "IMAP_USER"),
            imap_password=env.get("IMAP_PASSWORD") or "",
            imap_ssl=_flag(env, "IMAP_SSL", True),
            imap_folder=_text(env, "IMAP_FOLDER", "INBOX") or "INBOX",
            imap_processed_folder=_text(env, "IMAP_PROCESSED_FOLDER"),
            imap_oversized_folder=_text(env, "IMAP_OVERSIZED_FOLDER"),
            imap_mode=_choice(env, "IMAP_MODE", "poll", ("idle", "poll")),
            poll_interval=_number(env, "POLL_INTERVAL_SECONDS", 300, 1),
            storage_backend=_storage_backend(env, smb),
            storage_root=_text(env, "STORAGE_ROOT", "/mnt/nas") or "/mnt/nas",
            smb_domain=_text(env, "SMB_DOMAIN"),
            smb_port=_number(env, "SMB_PORT", 445, 1, 65535),
            smb_root=_text(env, "SMB_ROOT").strip("/"),
            smb_encrypt=_flag(env, "SMB_ENCRYPT", True),
            mapping_path=_text(env, "MAPPING_PATH", "mapping.yaml") or "mapping.yaml",
            fallback_folder=_text(env, "FALLBACK_FOLDER", "unsorted") or "unsorted",
            quarantine_folder=_text(env, "QUARANTINE_FOLDER", "quarantaene") or "quarantaene",
            match_body=_flag(env, "MATCH_BODY", False),
            filename_prefix=_choice(
                env, "FILENAME_PREFIX", "date_sender", ("none", "date", "sender", "date_sender")
            ),
            max_attachment_size_mb=_number(env, "MAX_ATTACHMENT_SIZE_MB", 25),
            max_message_size_mb=_number(env, "MAX_MESSAGE_SIZE_MB", 50),
            max_attachments_per_message=_number(env, "MAX_ATTACHMENTS_PER_MESSAGE", 20),
            blocked_extensions=parse_extension_list(
                env.get("BLOCKED_EXTENSIONS", DEFAULT_BLOCKED_EXTENSIONS)
            ),
            dry_run=_flag(env, "DRY_RUN", False),
            printing_enabled=_flag(env, "PRINTING_ENABLED", True),
            print_timeout=_number(env, "PRINT_TIMEOUT_SECONDS", 120),
            printable_extensions=parse_extension_list(
                env.get("PRINTABLE_EXTENSIONS") or DEFAULT_PRINTABLE_EXTENSIONS
            ),
            printer_name=_text(env, "PRINTER_NAME"),
            printer_destination=_text(env, "PRINTER_DESTINATION"),
            printer_server=_text(env, "PRINTER_SERVER"),
            printer_options=_text(env, "PRINTER_OPTIONS"),
            printer_copies=_number(env, "PRINTER_COPIES", 1, 1, 20),
            present=present,
            **smb,
        )


def _storage_backend(env: Mapping[str, str], smb: dict) -> str:
    """Where the old installation filed to - see the module docstring.

    Getting this wrong is the one mistake an update must not make: a
    generation-1 install treated as "mounted at /mnt/nas" would write every
    attachment into an empty directory inside the container, and lose it with
    the next rebuild.
    """
    explicit = _text(env, "STORAGE_BACKEND").lower()
    if explicit in ("smb", "local"):
        if explicit == "smb" and not (smb["smb_host"] and smb["smb_share"]):
            logger.warning("STORAGE_BACKEND=smb without SMB_HOST/SMB_SHARE - no archive taken over")
            return ""
        return explicit
    if explicit:
        logger.warning("STORAGE_BACKEND=%r is unknown - guessing from the other variables", explicit)

    if all(smb.values()):
        # Generation 1: Docker mounted //SMB_HOST/SMB_SHARE itself.
        return "smb"
    if _text(env, "NAS_PATH") or _text(env, "IMAP_HOST"):
        # Generation 2: the share is bind-mounted into the container.
        return "local"
    # A fresh installation: nothing to take over, the UI sets it up.
    return ""
