"""What happened, kept in the database: the processing journal and the log.

Two tables, both pruned after the retention period (six months by default):

* `journal` - one row per thing that happened to a document: filed,
  quarantined, printed, not printed, skipped, failed. It is what the log page
  shows as "Verarbeitung", it is what an error notification is built from -
  and it is how a mail that failed half-way is retried without filing or
  printing its first attachments a second time (`done`).
* `log_entries` - the service's own log lines (INFO and up), so the web UI
  can show them and they survive a container rebuild. Tracebacks are cut to
  their last line: the full ones are still in `docker compose logs`, and
  keeping hundreds of them for half a year would only grow the database.

Timestamps are stored in UTC ("YYYY-MM-DD HH:MM:SS", SQLite's own format) and
converted to local time for display.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

logger = logging.getLogger(__name__)

DEFAULT_RETENTION_DAYS = 183

# Journal actions, with the words the UI uses for them.
FILED = "abgelegt"
QUARANTINED = "quarantaene"
PRINTED = "gedruckt"
NOT_PRINTED = "nicht_gedruckt"
SKIPPED = "uebersprungen"
TOO_LARGE = "zu_gross"
NO_ATTACHMENTS = "ohne_anhang"
FAILED = "fehler"
DRY_RUN = "testmodus"

ACTIONS = {
    FILED: "abgelegt",
    QUARANTINED: "Quarantaene",
    PRINTED: "gedruckt",
    NOT_PRINTED: "nicht gedruckt",
    SKIPPED: "uebersprungen",
    TOO_LARGE: "Mail zu gross",
    NO_ATTACHMENTS: "ohne Anhang",
    FAILED: "Fehler",
    DRY_RUN: "Testmodus",
}
# What counts as a problem somebody should hear about.
FAILURES = (NOT_PRINTED, FAILED, TOO_LARGE, SKIPPED)
# What makes an attachment "already filed" / "already printed" for a retry.
FILED_ACTIONS = (FILED, QUARANTINED)

LEVELS = {"DEBUG": 10, "INFO": 20, "WARNING": 30, "ERROR": 40, "CRITICAL": 50}
MAX_MESSAGE = 2000
MAX_FIELD = 500


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")


def cutoff(days: int, now: datetime | None = None) -> str:
    """The UTC timestamp before which rows are older than `days`."""
    now = now or datetime.now(timezone.utc)
    return (now - timedelta(days=days)).strftime("%Y-%m-%d %H:%M:%S")


def local_time(stamp: str) -> str:
    """A stored UTC timestamp as local time, for the UI."""
    try:
        value = datetime.strptime(stamp, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except (TypeError, ValueError):
        return stamp or ""
    return value.astimezone().strftime("%d.%m.%Y %H:%M:%S")


def _clip(value, limit: int = MAX_FIELD) -> str:
    text = "" if value is None else str(value)
    return text if len(text) <= limit else text[: limit - 1] + "…"


def _like(text: str) -> str:
    escaped = text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    return f"%{escaped}%"


@dataclass(frozen=True)
class Entry:
    id: int
    at: str
    source: str
    action: str
    message_key: str
    part_key: str
    subject: str
    sender: str
    filename: str
    target: str
    detail: str

    @property
    def action_label(self) -> str:
        return ACTIONS.get(self.action, self.action)

    @property
    def failed(self) -> bool:
        return self.action in FAILURES

    @property
    def local_at(self) -> str:
        return local_time(self.at)


@dataclass(frozen=True)
class LogLine:
    id: int
    at: str
    level: str
    name: str
    message: str

    @property
    def local_at(self) -> str:
        return local_time(self.at)


class _Store:
    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)


class Journal(_Store):
    """The processing journal. Safe to use from any thread."""

    def __init__(self, db_path: str):
        super().__init__(db_path)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS journal ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "at TEXT NOT NULL, "
                "source TEXT NOT NULL DEFAULT '', "
                "action TEXT NOT NULL, "
                "message_key TEXT NOT NULL DEFAULT '', "
                "part_key TEXT NOT NULL DEFAULT '', "
                "subject TEXT NOT NULL DEFAULT '', "
                "sender TEXT NOT NULL DEFAULT '', "
                "filename TEXT NOT NULL DEFAULT '', "
                "target TEXT NOT NULL DEFAULT '', "
                "detail TEXT NOT NULL DEFAULT '')"
            )
            conn.execute("CREATE INDEX IF NOT EXISTS journal_at ON journal (at)")
            conn.execute(
                "CREATE INDEX IF NOT EXISTS journal_part ON journal (message_key, part_key, action)"
            )

    def record(
        self,
        source: str,
        action: str,
        *,
        message_key: str = "",
        part_key: str = "",
        subject: str = "",
        sender: str = "",
        filename: str = "",
        target: str = "",
        detail: str = "",
    ) -> None:
        """Write one row. Never raises: the journal must not stop the archiving."""
        try:
            with self._lock, self._connect() as conn:
                conn.execute(
                    "INSERT INTO journal (at, source, action, message_key, part_key, subject, "
                    "sender, filename, target, detail) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        utc_now(), _clip(source), action, _clip(message_key, 1000),
                        _clip(part_key), _clip(subject), _clip(sender), _clip(filename),
                        _clip(target, 1000), _clip(detail, MAX_MESSAGE),
                    ),
                )
        except sqlite3.Error as exc:
            logger.error("Could not write to the journal: %s", exc)

    def done(self, message_key: str, part_key: str, actions) -> bool:
        """Has this attachment already had one of `actions` happen to it?"""
        if not message_key or not part_key:
            return False
        marks = ",".join("?" for _ in actions)
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT 1 FROM journal WHERE message_key = ? AND part_key = ? "
                f"AND action IN ({marks}) LIMIT 1",
                (message_key, part_key, *actions),
            ).fetchone()
        return row is not None

    @staticmethod
    def _where(search: str = "", source: str = "", problems_only: bool = False,
               after_id: int = 0, since: str = ""):
        clauses, args = [], []
        if search:
            clauses.append(
                "(subject LIKE ? ESCAPE '\\' OR sender LIKE ? ESCAPE '\\' OR filename LIKE ? "
                "ESCAPE '\\' OR target LIKE ? ESCAPE '\\' OR detail LIKE ? ESCAPE '\\')"
            )
            args += [_like(search)] * 5
        if source:
            clauses.append("source = ?")
            args.append(source)
        if problems_only:
            clauses.append(f"action IN ({','.join('?' for _ in FAILURES)})")
            args += list(FAILURES)
        if after_id:
            clauses.append("id > ?")
            args.append(after_id)
        if since:
            clauses.append("at >= ?")
            args.append(since)
        return (" WHERE " + " AND ".join(clauses)) if clauses else "", args

    def entries(self, *, search: str = "", source: str = "", problems_only: bool = False,
                limit: int = 100, offset: int = 0, after_id: int = 0,
                oldest_first: bool = False) -> list[Entry]:
        where, args = self._where(search, source, problems_only, after_id)
        order = "ASC" if oldest_first else "DESC"
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT id, at, source, action, message_key, part_key, subject, sender, "
                f"filename, target, detail FROM journal{where} ORDER BY id {order} "
                "LIMIT ? OFFSET ?",
                (*args, limit, offset),
            ).fetchall()
        return [Entry(*row) for row in rows]

    def count(self, *, search: str = "", source: str = "", problems_only: bool = False,
              since: str = "") -> int:
        where, args = self._where(search, source, problems_only, since=since)
        with self._connect() as conn:
            return conn.execute(f"SELECT COUNT(*) FROM journal{where}", args).fetchone()[0]

    def sources(self) -> list[str]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT DISTINCT source FROM journal WHERE source != '' ORDER BY source"
            ).fetchall()
        return [row[0] for row in rows]

    def last_id(self) -> int:
        with self._connect() as conn:
            return conn.execute("SELECT COALESCE(MAX(id), 0) FROM journal").fetchone()[0]

    def prune(self, before: str) -> int:
        with self._lock, self._connect() as conn:
            return conn.execute("DELETE FROM journal WHERE at < ?", (before,)).rowcount


class LogStore(_Store):
    """The service log, kept for the log page."""

    def __init__(self, db_path: str):
        super().__init__(db_path)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS log_entries ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "at TEXT NOT NULL, "
                "level TEXT NOT NULL, "
                "name TEXT NOT NULL DEFAULT '', "
                "message TEXT NOT NULL)"
            )
            conn.execute("CREATE INDEX IF NOT EXISTS log_entries_at ON log_entries (at)")

    def add(self, level: str, name: str, message: str, at: str | None = None) -> None:
        with self._lock, self._connect() as conn:
            conn.execute(
                "INSERT INTO log_entries (at, level, name, message) VALUES (?, ?, ?, ?)",
                (at or utc_now(), level, _clip(name, 100), _clip(message, MAX_MESSAGE)),
            )

    @staticmethod
    def _where(min_level: str = "INFO", search: str = ""):
        wanted = [name for name, value in LEVELS.items() if value >= LEVELS.get(min_level, 20)]
        clauses = [f"level IN ({','.join('?' for _ in wanted)})"]
        args: list = list(wanted)
        if search:
            clauses.append("message LIKE ? ESCAPE '\\'")
            args.append(_like(search))
        return " WHERE " + " AND ".join(clauses), args

    def entries(self, *, min_level: str = "INFO", search: str = "", limit: int = 200,
                offset: int = 0) -> list[LogLine]:
        where, args = self._where(min_level, search)
        with self._connect() as conn:
            rows = conn.execute(
                f"SELECT id, at, level, name, message FROM log_entries{where} "
                "ORDER BY id DESC LIMIT ? OFFSET ?",
                (*args, limit, offset),
            ).fetchall()
        return [LogLine(*row) for row in rows]

    def count(self, *, min_level: str = "INFO", search: str = "") -> int:
        where, args = self._where(min_level, search)
        with self._connect() as conn:
            return conn.execute(f"SELECT COUNT(*) FROM log_entries{where}", args).fetchone()[0]

    def prune(self, before: str) -> int:
        with self._lock, self._connect() as conn:
            return conn.execute("DELETE FROM log_entries WHERE at < ?", (before,)).rowcount


class DatabaseLogHandler(logging.Handler):
    """Copies the service's log records into `LogStore`.

    Only mail2nas' own loggers, INFO and up: library chatter (SMB, waitress)
    stays in the container log. A record logged while a record is being
    written (from inside sqlite, say) is dropped instead of recursing.
    """

    def __init__(self, store: LogStore, level: int = logging.INFO):
        super().__init__(level)
        self.store = store
        self._busy = threading.local()

    def emit(self, record: logging.LogRecord) -> None:
        if not record.name.startswith("mail2nas") or getattr(self._busy, "on", False):
            return
        self._busy.on = True
        try:
            message = record.getMessage()
            if record.exc_info and record.exc_info[1] is not None:
                exc = record.exc_info[1]
                message += f" - {exc.__class__.__name__}: {exc}"
            self.store.add(record.levelname, record.name, message)
        except Exception:  # noqa: BLE001 - logging must never break the caller
            self.handleError(record)
        finally:
            self._busy.on = False


def prune(runtime, days: int, now: datetime | None = None) -> dict[str, int]:
    """Drop everything older than `days` from the journal, the log and the
    processed-message list. Returns how many rows went, per table."""
    before = cutoff(days, now)
    removed = {}
    if getattr(runtime, "journal", None) is not None:
        removed["journal"] = runtime.journal.prune(before)
    if getattr(runtime, "logs", None) is not None:
        removed["log"] = runtime.logs.prune(before)
    if runtime.store is not None and hasattr(runtime.store, "prune"):
        removed["processed"] = runtime.store.prune(before)
    return removed
