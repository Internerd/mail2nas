"""Backing up and restoring the one thing that matters: the database.

Since everything is configured in the web UI, the state database *is* the
installation - mailboxes, archives, rules, printers, settings, the journal.
Three ways to keep it:

* **Download** from the web UI, any time.
* **Automatically** once a day into a folder on one of the archives (the
  NAS), keeping the last N copies.
* **Restore** from such a file in the web UI. The current database is saved
  next to it first (`/data/backups`), so a wrong file can be undone.

A copy is taken with SQLite's online backup API: consistent even while the
workers are writing, without stopping anything. It is gzip-compressed; the
journal and the log compress well.

The file contains the IMAP and SMB passwords in clear text - exactly like the
database itself. Whoever can read the backup folder can read those.
"""
from __future__ import annotations

import gzip
import logging
import os
import sqlite3
import tempfile
import time
from dataclasses import dataclass, fields, replace
from datetime import datetime, timezone
from pathlib import Path

from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

PREFIX = "mail2nas-sicherung-"
SUFFIX = ".db.gz"
LOCAL_DIR = "backups"
LOCAL_KEEP = 5
# A restore upload may be this large (compressed or not).
MAX_UPLOAD = 512 * 1024 * 1024
BACKUP_INTERVAL = 24 * 60 * 60
RETRY_INTERVAL = 60 * 60
KEEP_LIMITS = (1, 365)
SQLITE_MAGIC = b"SQLite format 3\x00"
GZIP_MAGIC = b"\x1f\x8b"
# Present in every mail2nas database since the web UI exists.
REQUIRED_TABLES = ("settings",)


class BackupError(ValueError):
    """A backup could not be made or a file cannot be restored."""


def backup_name(now: datetime | None = None) -> str:
    now = now or datetime.now()
    return f"{PREFIX}{now.strftime('%Y-%m-%d_%H%M%S')}{SUFFIX}"


def dump(db_path: str) -> bytes:
    """A consistent, compressed copy of the database."""
    with tempfile.TemporaryDirectory(prefix="mail2nas-backup-") as tmp:
        copy = os.path.join(tmp, "copy.db")
        source = sqlite3.connect(db_path, timeout=30)
        target = sqlite3.connect(copy)
        try:
            source.backup(target)
        finally:
            target.close()
            source.close()
        return gzip.compress(Path(copy).read_bytes(), compresslevel=6)


def _plain(data: bytes) -> bytes:
    if data[:2] == GZIP_MAGIC:
        try:
            return gzip.decompress(data)
        except (OSError, EOFError) as exc:
            raise BackupError(f"Die Datei ist kein gueltiges gzip-Archiv ({exc}).") from None
    return data


def check(data: bytes) -> dict[str, int]:
    """Validate an uploaded backup; returns row counts for a few tables."""
    plain = _plain(data)
    if not plain.startswith(SQLITE_MAGIC):
        raise BackupError("Das ist keine mail2nas-Sicherung (keine SQLite-Datenbank).")
    with tempfile.TemporaryDirectory(prefix="mail2nas-restore-") as tmp:
        path = os.path.join(tmp, "check.db")
        Path(path).write_bytes(plain)
        return _inspect(path)


def _inspect(path: str) -> dict[str, int]:
    conn = sqlite3.connect(path)
    try:
        result = conn.execute("PRAGMA integrity_check").fetchone()
        if not result or result[0] != "ok":
            raise BackupError(f"Die Datenbank in der Sicherung ist beschaedigt ({result}).")
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        missing = [name for name in REQUIRED_TABLES if name not in tables]
        if missing:
            raise BackupError("Das ist keine mail2nas-Sicherung (Tabelle settings fehlt).")
        counts = {}
        for table in ("imap_accounts", "archives", "mapping_rules", "printers", "journal"):
            if table in tables:
                counts[table] = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        return counts
    except sqlite3.DatabaseError as exc:
        raise BackupError(f"Die Datenbank in der Sicherung ist nicht lesbar ({exc}).") from None
    finally:
        conn.close()


def save_local(db_path: str, data_dir: str, label: str = "vor-wiederherstellung") -> str:
    """Keep a copy of the current database in `<data_dir>/backups`."""
    folder = Path(data_dir) / LOCAL_DIR
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    stamp = datetime.now().strftime("%Y-%m-%d_%H%M%S")
    path = folder / f"{label}-{stamp}{SUFFIX}"
    path.write_bytes(dump(db_path))
    os.chmod(path, 0o600)
    old = sorted(folder.glob(f"{label}-*{SUFFIX}"))
    for stale in old[:-LOCAL_KEEP]:
        stale.unlink(missing_ok=True)
    return str(path)


def restore(db_path: str, data: bytes, data_dir: str) -> tuple[str, dict[str, int]]:
    """Replace the live database with the uploaded one.

    Checked first, the current state saved next; then copied in with the
    backup API, page by page into the open database file, so connections that
    other threads hold simply see the new content. Returns the path of the
    saved previous state and the row counts of the restored one.
    """
    plain = _plain(data)
    if not plain.startswith(SQLITE_MAGIC):
        raise BackupError("Das ist keine mail2nas-Sicherung (keine SQLite-Datenbank).")
    with tempfile.TemporaryDirectory(prefix="mail2nas-restore-") as tmp:
        path = os.path.join(tmp, "restore.db")
        Path(path).write_bytes(plain)
        counts = _inspect(path)
        saved = save_local(db_path, data_dir)
        processed = _processed(db_path)
        source = sqlite3.connect(path)
        target = sqlite3.connect(db_path, timeout=30)
        try:
            source.backup(target)
            # Mail processed since the backup was taken stays processed: an
            # older configuration must not mean filing those mails again.
            if processed:
                target.execute(
                    "CREATE TABLE IF NOT EXISTS processed_messages ("
                    "message_id TEXT PRIMARY KEY, "
                    "processed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
                )
                target.executemany(
                    "INSERT OR IGNORE INTO processed_messages (message_id, processed_at) "
                    "VALUES (?, ?)",
                    processed,
                )
                target.commit()
        finally:
            target.close()
            source.close()
    logger.warning("Database restored from an uploaded backup (previous state saved to %s)", saved)
    return saved, counts


def _processed(db_path: str) -> list[tuple[str, str]]:
    conn = sqlite3.connect(db_path, timeout=30)
    try:
        return conn.execute("SELECT message_id, processed_at FROM processed_messages").fetchall()
    except sqlite3.OperationalError:
        return []
    finally:
        conn.close()


# --- automatic backups onto an archive ----------------------------------------


@dataclass(frozen=True)
class BackupSettings:
    enabled: bool = False
    archive: str = ""  # archive key, "" = the default archive
    folder: str = "mail2nas-sicherung"
    keep: int = 14


def _key(name: str) -> str:
    return f"backup.{name}"


class BackupStore:
    def __init__(self, settings):
        self._settings = settings

    def load(self) -> BackupSettings:
        defaults = BackupSettings()
        values = {}
        for spec in fields(BackupSettings):
            raw = self._settings.get(_key(spec.name))
            if raw is None:
                continue
            default = getattr(defaults, spec.name)
            if isinstance(default, bool):
                values[spec.name] = raw == "1"
            elif isinstance(default, int):
                try:
                    values[spec.name] = int(raw)
                except ValueError:
                    continue
            else:
                values[spec.name] = raw
        return replace(defaults, **values)

    def save(self, value: BackupSettings) -> None:
        for spec in fields(BackupSettings):
            item = getattr(value, spec.name)
            if isinstance(item, bool):
                item = "1" if item else "0"
            self._settings.set(_key(spec.name), str(item))


def validate(form, archive_keys) -> BackupSettings:
    folder = (form.get("folder") or "").strip().replace("\\", "/")
    if not folder:
        raise BackupError("Bitte einen Ordner fuer die Sicherungen angeben.")
    try:
        folder = "/".join(safe_relative_parts(folder))
    except ValueError as exc:
        raise BackupError(f"Ordner: {exc}") from None
    try:
        keep = int((form.get("keep") or "").strip())
    except ValueError:
        raise BackupError("Die Anzahl muss eine ganze Zahl sein.") from None
    if not KEEP_LIMITS[0] <= keep <= KEEP_LIMITS[1]:
        raise BackupError(f"Es koennen {KEEP_LIMITS[0]} bis {KEEP_LIMITS[1]} Sicherungen "
                          "aufbewahrt werden.")
    archive = (form.get("archive") or "").strip()
    if archive and archive not in set(archive_keys):
        raise BackupError("Dieses Archiv gibt es nicht.")
    return BackupSettings(enabled=bool(form.get("enabled")), archive=archive, folder=folder,
                          keep=keep)


@dataclass
class BackupStatus:
    ok: bool | None = None
    detail: str = ""
    last_run: float | None = None
    failing_since: float | None = None


def write_to_archive(runtime, settings: BackupSettings | None = None) -> str:
    """Write one backup into the configured archive folder and rotate. Returns the path."""
    settings = settings or BackupStore(runtime.settings).load()
    storage = runtime.storages.get(settings.archive) if settings.archive else runtime.storages.default()
    parts = safe_relative_parts(settings.folder)
    path = storage.save_unique(parts, backup_name(), dump(runtime.config.state_db_path))
    existing = sorted(
        (entry for entry in storage.list_files(parts, max_depth=1)
         if entry.name.startswith(PREFIX) and entry.name.endswith(SUFFIX)),
        key=lambda entry: entry.name,
    )
    for stale in existing[:-settings.keep]:
        storage.remove_file(stale.relative)
        logger.info("Removed old backup %s", stale.relative)
    return path


class BackupScheduler:
    """Runs the automatic backup once a day, from the supervisor."""

    def __init__(self, runtime, clock=time.time):
        self.runtime = runtime
        self.store = BackupStore(runtime.settings)
        self._clock = clock
        self.status: BackupStatus = runtime.backup_status

    def _last_success(self) -> float | None:
        raw = self.runtime.settings.get("backup.last_success")
        try:
            return float(raw) if raw else None
        except ValueError:
            return None

    def due(self) -> bool:
        settings = self.store.load()
        if not settings.enabled:
            self.status.ok, self.status.detail, self.status.failing_since = None, "", None
            return False
        now = self._clock()
        last = self._last_success()
        if self.status.ok is False and self.status.last_run is not None:
            return now - self.status.last_run >= RETRY_INTERVAL
        return last is None or now - last >= BACKUP_INTERVAL

    def run(self) -> str:
        """Back up now. Raises on failure, after noting it in the status."""
        now = self._clock()
        self.status.last_run = now
        try:
            path = write_to_archive(self.runtime, self.store.load())
        except Exception as exc:  # noqa: BLE001 - reported on the overview page and by mail
            self.status.ok = False
            self.status.detail = f"Sicherung fehlgeschlagen: {exc.__class__.__name__}: {exc}"
            if self.status.failing_since is None:
                self.status.failing_since = now
            logger.error("Automatic backup failed: %s", exc)
            raise
        self.status.ok = True
        self.status.detail = f"Letzte Sicherung: {path}"
        self.status.failing_since = None
        self.runtime.settings.set("backup.last_success", str(now))
        self.runtime.settings.set("backup.last_path", path)
        logger.info("Backup written to %s", path)
        return path

    def maybe_run(self) -> None:
        if self.due():
            try:
                self.run()
            except Exception:  # noqa: BLE001 - already reported
                pass


def last_success(settings) -> tuple[str, str]:
    """(local time, path) of the last automatic backup, for the UI."""
    raw = settings.get("backup.last_success")
    try:
        when = datetime.fromtimestamp(float(raw), tz=timezone.utc).astimezone() if raw else None
    except ValueError:
        when = None
    return (when.strftime("%d.%m.%Y %H:%M") if when else "", settings.get("backup.last_path") or "")
