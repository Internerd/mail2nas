"""The archives attachments are filed into - one or several.

Until now there was exactly one archive and it came from the environment.
A household or office often has more than one place things belong: invoices
on the NAS in the office, scans on the one in the workshop, private documents
on a second share of the same box. So an archive becomes a configurable
thing, like the mailboxes and printers before it, and everything that points
somewhere - a mapping rule, a delivery address, a pickup folder - names one.

The first archive is seeded from the `.env`, so an existing installation sees
exactly what it had, under a name, and nothing changes until a second one is
added.

`StorageSet` keeps one live `Storage` per archive. Connections are expensive
(SMB sessions) and the configuration can change while the service runs, so
they are built on demand and rebuilt when the entry behind them changes.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_relative_parts
from .storage import LocalStorage, SmbStorage, Storage

logger = logging.getLogger(__name__)

SETTING_ARCHIVES_SEEDED = "archives_seeded"

# An empty key means "the default archive" - the first enabled one. Mapping
# files written before archives existed carry no key at all, and a renamed or
# replaced first archive must not silently redirect every rule.
DEFAULT_ARCHIVE = ""

MAX_NAME_LENGTH = 80
BACKENDS = ("smb", "local")


class ArchiveError(ValueError):
    """An archive the user tried to save is not usable."""


class NoArchiveError(RuntimeError):
    """Nothing to file into yet - no archive is configured (or all are paused)."""


@dataclass(frozen=True)
class Archive:
    """One place to file into: an SMB share, or a directory on this machine."""

    id: int
    name: str
    backend: str  # "smb" or "local"
    host: str
    share: str
    user: str
    password: str
    domain: str
    port: int
    root: str  # subfolder below the share root, optional
    encrypt: bool
    path: str  # local backend only
    enabled: bool

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by rules, addresses and pickups."""
        return str(self.id)

    def location(self) -> str:
        if self.backend == "local":
            return self.path
        where = f"//{self.host}/{self.share}"
        return f"{where}/{self.root}" if self.root else where

    def label(self) -> str:
        return f"{self.name} ({self.location()})"

    def fingerprint(self) -> tuple:
        """Everything the connection depends on; a change means rebuild it."""
        return (
            self.backend,
            self.host,
            self.share,
            self.user,
            self.password,
            self.domain,
            self.port,
            self.root,
            self.encrypt,
            self.path,
        )

    def to_storage(self) -> Storage:
        if self.backend == "local":
            return LocalStorage(self.path)
        return SmbStorage(
            host=self.host,
            share=self.share,
            user=self.user,
            password=self.password,
            domain=self.domain or None,
            port=self.port,
            root=self.root,
            encrypt=self.encrypt,
        )


class ArchiveStore:
    """CRUD for the configured archives.

    Short-lived connection per call, like the other stores: the web UI and the
    workers are different threads, and one sqlite3 connection must not be
    shared between them.
    """

    _COLUMNS = (
        "id, name, backend, host, share, user, password, domain, port, root, "
        "encrypt, path, enabled"
    )

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS archives ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "backend TEXT NOT NULL DEFAULT 'smb', "
                "host TEXT NOT NULL DEFAULT '', "
                "share TEXT NOT NULL DEFAULT '', "
                "user TEXT NOT NULL DEFAULT '', "
                "password TEXT NOT NULL DEFAULT '', "
                "domain TEXT NOT NULL DEFAULT '', "
                "port INTEGER NOT NULL DEFAULT 445, "
                "root TEXT NOT NULL DEFAULT '', "
                "encrypt INTEGER NOT NULL DEFAULT 1, "
                "path TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_archive(row) -> Archive:
        return Archive(
            id=row[0],
            name=row[1],
            backend=row[2],
            host=row[3],
            share=row[4],
            user=row[5],
            password=row[6],
            domain=row[7],
            port=row[8],
            root=row[9],
            encrypt=bool(row[10]),
            path=row[11],
            enabled=bool(row[12]),
        )

    def all(self) -> list[Archive]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM archives ORDER BY id").fetchall()
        return [self._row_to_archive(row) for row in rows]

    def enabled(self) -> list[Archive]:
        return [archive for archive in self.all() if archive.enabled]

    def get(self, archive_id: int) -> Archive | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM archives WHERE id = ?", (archive_id,)
            ).fetchone()
        return self._row_to_archive(row) if row else None

    def by_key(self, key: str) -> Archive | None:
        try:
            return self.get(int(str(key).strip()))
        except (TypeError, ValueError):
            return None

    def default(self) -> Archive | None:
        """The archive used by everything that does not name one."""
        return next(iter(self.enabled()), None)

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO archives (name, backend, host, share, user, password, domain, "
                "port, root, encrypt, path, enabled) VALUES (:name, :backend, :host, :share, "
                ":user, :password, :domain, :port, :root, :encrypt, :path, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, archive_id: int, **fields) -> None:
        current = self.get(archive_id)
        if current is None:
            raise KeyError(archive_id)
        values = validate(
            {
                "name": current.name,
                "backend": current.backend,
                "host": current.host,
                "share": current.share,
                "user": current.user,
                "password": current.password,
                "domain": current.domain,
                "port": current.port,
                "root": current.root,
                "encrypt": current.encrypt,
                "path": current.path,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = archive_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE archives SET name = :name, backend = :backend, host = :host, "
                "share = :share, user = :user, password = :password, domain = :domain, "
                "port = :port, root = :root, encrypt = :encrypt, path = :path, "
                "enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, archive_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM archives WHERE id = ?", (archive_id,))


def validate(fields: dict) -> dict:
    """Check and normalise what the UI (or the environment) supplies."""
    name = str(fields.get("name") or "").strip()
    backend = str(fields.get("backend") or "smb").strip().lower()
    if backend not in BACKENDS:
        raise ArchiveError("Unbekannte Art von Archiv.")
    if len(name) > MAX_NAME_LENGTH:
        raise ArchiveError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")

    host = str(fields.get("host") or "").strip()
    share = str(fields.get("share") or "").strip().strip("/\\")
    user = str(fields.get("user") or "").strip()
    password = str(fields.get("password") or "")
    domain = str(fields.get("domain") or "").strip()
    path = str(fields.get("path") or "").strip()
    root = str(fields.get("root") or "").strip()

    if root:
        try:
            root = "/".join(safe_relative_parts(root))
        except ValueError as exc:
            raise ArchiveError(f"Der Unterordner ist nicht zulaessig: {exc}") from None

    try:
        port = int(fields.get("port") or 445)
    except (TypeError, ValueError):
        raise ArchiveError("Der Port muss eine Zahl sein.") from None
    if not 1 <= port <= 65535:
        raise ArchiveError("Der Port muss zwischen 1 und 65535 liegen.")

    if backend == "smb":
        if not host:
            raise ArchiveError("Bitte den Server (NAS) angeben.")
        if not share:
            raise ArchiveError("Bitte den Namen der Freigabe angeben.")
        if not user:
            raise ArchiveError("Bitte den SMB-Benutzer angeben.")
        if not password:
            raise ArchiveError("Bitte das SMB-Passwort angeben.")
    else:
        if not path:
            raise ArchiveError("Bitte das Verzeichnis angeben, in dem das Share gemountet ist.")
        if not path.startswith("/"):
            raise ArchiveError("Das Verzeichnis muss ein absoluter Pfad sein (z. B. /mnt/nas).")

    default_name = share or Path(path).name or host or "Archiv"
    return {
        "name": name or default_name,
        "backend": backend,
        "host": host,
        "share": share,
        "user": user,
        "password": password,
        "domain": domain,
        "port": port,
        "root": root,
        "encrypt": 1 if fields.get("encrypt", True) else 0,
        "path": path,
        "enabled": 1 if fields.get("enabled", True) else 0,
    }


def seed_from_config(store: ArchiveStore, settings, config) -> None:
    """Carry the archive of an older `.env` over, once.

    `config` is a `LegacyEnv`, which has already worked out which generation
    of installation this is (see `legacy.py`). A fresh installation describes
    no archive at all - it is set up in the web UI - so nothing is created.

    Guarded by a flag rather than by "is the table empty", so deleting the
    last archive in the UI does not resurrect it from the .env on the next
    restart.
    """
    if settings.get(SETTING_ARCHIVES_SEEDED):
        return
    if store.all() or config.storage_backend not in BACKENDS:
        settings.set(SETTING_ARCHIVES_SEEDED, "1")
        return

    try:
        if config.storage_backend == "smb":
            store.add(
                name=config.smb_share or config.smb_host,
                backend="smb",
                host=config.smb_host,
                share=config.smb_share,
                user=config.smb_user,
                password=config.smb_password,
                domain=config.smb_domain,
                port=config.smb_port,
                root=config.smb_root,
                encrypt=config.smb_encrypt,
            )
        else:
            store.add(name="Archiv", backend="local", path=config.storage_root)
    except ArchiveError as exc:
        # E.g. an SMB password that was never filled in. The UI shows that no
        # archive exists; better than a half-configured one.
        logger.error("The archive from the .env is not usable (%s) - set it up in the web UI", exc)
    settings.set(SETTING_ARCHIVES_SEEDED, "1")
    logger.info("Took the archive over from the .env")


class StorageSet:
    """Live `Storage` objects for the configured archives.

    Built on demand and cached: an SMB session is not something to set up per
    attachment. The cache key includes the archive's settings, so changing a
    password in the UI takes effect on the next write instead of after a
    restart.
    """

    def __init__(self, archives: ArchiveStore | None, fallback: Storage | None = None):
        self._archives = archives
        self._fallback = fallback
        self._cache: dict[str, tuple[tuple, Storage]] = {}
        self._lock = threading.Lock()

    @property
    def fallback(self) -> Storage | None:
        """A fixed storage used when no archive store is attached (tests)."""
        return self._fallback

    def archive_for(self, key: str) -> Archive | None:
        """The archive a key refers to, or the default one."""
        if self._archives is None:
            return None
        if key and key != DEFAULT_ARCHIVE:
            archive = self._archives.by_key(key)
            if archive is None:
                logger.warning("Archive %r is configured somewhere but no longer exists", key)
            elif not archive.enabled:
                logger.warning("Archive %r is paused - filing into the default archive", archive.name)
            else:
                return archive
        return self._archives.default()

    def get(self, key: str = DEFAULT_ARCHIVE) -> Storage:
        """The storage behind `key`, falling back to the default archive."""
        archive = self.archive_for(key)
        if archive is None:
            if self._fallback is None:
                raise NoArchiveError("Es ist noch kein (aktives) Archiv eingerichtet.")
            return self._fallback
        with self._lock:
            cached = self._cache.get(archive.key)
            if cached is not None and cached[0] == archive.fingerprint():
                return cached[1]
            if cached is not None:
                logger.info("Archive %r changed - reconnecting", archive.name)
                self._close(cached[1])
            storage = archive.to_storage()
            self._cache[archive.key] = (archive.fingerprint(), storage)
            return storage

    def default(self) -> Storage:
        return self.get(DEFAULT_ARCHIVE)

    def label_for(self, key: str) -> str:
        archive = self.archive_for(key)
        if archive is not None:
            return archive.name
        return self._fallback.description if self._fallback is not None else "-"

    def close(self) -> None:
        with self._lock:
            for _, storage in self._cache.values():
                self._close(storage)
            self._cache.clear()

    @staticmethod
    def _close(storage: Storage) -> None:
        try:
            storage.close()
        except Exception:  # noqa: BLE001 - closing a broken session must not raise
            logger.debug("Could not close a storage connection", exc_info=True)
