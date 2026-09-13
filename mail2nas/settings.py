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
