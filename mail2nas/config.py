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
                web_enabled=_bool("WEB_ENABLED", False),
                web_host=os.environ.get("WEB_HOST", "0.0.0.0").strip(),
                web_port=_int("WEB_PORT", "8080", minimum=1, maximum=65535),
                web_password=os.environ.get("WEB_PASSWORD", ""),
                web_cookie_secure=_bool("WEB_COOKIE_SECURE", False),
            )
        except KeyError as exc:
            raise SystemExit(f"Missing required environment variable: {exc.args[0]}") from exc
