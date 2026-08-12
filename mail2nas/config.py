from __future__ import annotations

import os
from dataclasses import dataclass


def _bool(name: str, default: bool) -> bool:
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in ("1", "true", "yes", "on")


@dataclass(frozen=True)
class Config:
    imap_host: str
    imap_port: int
    imap_user: str
    imap_password: str
    imap_ssl: bool
    imap_folder: str
    imap_processed_folder: str | None
    imap_mode: str  # "idle" or "poll"
    poll_interval: int

    storage_root: str
    mapping_path: str
    fallback_folder: str
    match_body: bool
    filename_prefix: str  # "none" | "date" | "sender" | "date_sender"

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
                imap_mode=os.environ.get("IMAP_MODE", "poll").lower(),
                poll_interval=int(os.environ.get("POLL_INTERVAL_SECONDS", "300")),
                storage_root=os.environ.get("STORAGE_ROOT", "/mnt/nas"),
                mapping_path=os.environ.get("MAPPING_PATH", "mapping.yaml"),
                fallback_folder=os.environ.get("FALLBACK_FOLDER", "unsorted"),
                match_body=_bool("MATCH_BODY", False),
                filename_prefix=os.environ.get("FILENAME_PREFIX", "date_sender"),
                state_db_path=os.environ.get("STATE_DB_PATH", "/data/state.db"),
                dry_run=_bool("DRY_RUN", False),
            )
        except KeyError as exc:
            raise SystemExit(f"Missing required environment variable: {exc.args[0]}") from exc
