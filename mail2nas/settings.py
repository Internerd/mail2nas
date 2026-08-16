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
