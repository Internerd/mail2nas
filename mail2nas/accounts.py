"""IMAP accounts, stored locally so the web UI can edit them.

Until now there was exactly one mailbox and it came from the environment.
Editing it in the UI - and having more than one - means the configuration has
to live somewhere writable, so it goes into the same SQLite file as the rest
of the local state.

Mailboxes are created in the web UI. An installation updated from a version
that configured its mailbox in the `.env` gets that one carried over once (see
`migrate.py`); after that the `.env` is not read for it any more.

Note this means the state database now holds IMAP passwords in clear text.
It is kept at mode 0600 in a Docker volume, never on the share - see the README.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from datetime import date
from pathlib import Path

logger = logging.getLogger(__name__)

SETTING_ACCOUNTS_SEEDED = "imap_accounts_seeded"


@dataclass(frozen=True)
class Account:
    """One mailbox to watch."""

    id: int
    name: str
    host: str
    port: int
    ssl: bool
    user: str
    password: str
    folder: str
    mode: str  # "idle" or "poll"
    processed_folder: str
    oversized_folder: str
    enabled: bool
    # Print every attachment from this mailbox, regardless of the rules.
    print_attachments: bool = False
    # Printer for this mailbox, as a string key ("" = none configured). A rule
    # that names its own printer overrides it.
    printer: str = ""
    # Off means "print only": attachments are not written to the share.
    archive_attachments: bool = True
    # Also process mail that is already marked as read - somebody opened it
    # in their mail client before mail2nas got to it. Only mail that arrived
    # on or after `seen_since` (YYYY-MM-DD) is considered, so ticking the box
    # does not suddenly file years of old correspondence.
    include_seen: bool = False
    seen_since: str = ""

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by a mapping rule."""
        return str(self.id)

    def fingerprint(self) -> tuple:
        """Everything a worker thread needs; a change means restart it."""
        return (
            self.host,
            self.port,
            self.ssl,
            self.user,
            self.password,
            self.folder,
            self.mode,
            self.processed_folder,
            self.oversized_folder,
            self.enabled,
            self.print_attachments,
            self.printer,
            self.archive_attachments,
            self.include_seen,
            self.seen_since,
        )


class AccountStore:
    """CRUD for the configured mailboxes.

    Opens a short-lived connection per call: the web UI answers requests on a
    thread pool and the account workers read from their own threads, and one
    sqlite3 connection must not be shared across threads.
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS imap_accounts ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "host TEXT NOT NULL, "
                "port INTEGER NOT NULL DEFAULT 993, "
                "ssl INTEGER NOT NULL DEFAULT 1, "
                "user TEXT NOT NULL, "
                "password TEXT NOT NULL, "
                "folder TEXT NOT NULL DEFAULT 'INBOX', "
                "mode TEXT NOT NULL DEFAULT 'poll', "
                "processed_folder TEXT NOT NULL DEFAULT '', "
                "oversized_folder TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )
            _add_missing_columns(conn)

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_account(row) -> Account:
        return Account(
            id=row[0],
            name=row[1],
            host=row[2],
            port=row[3],
            ssl=bool(row[4]),
            user=row[5],
            password=row[6],
            folder=row[7],
            mode=row[8],
            processed_folder=row[9],
            oversized_folder=row[10],
            enabled=bool(row[11]),
            print_attachments=bool(row[12]),
            printer=row[13] or "",
            archive_attachments=bool(row[14]),
            include_seen=bool(row[15]),
            seen_since=row[16] or "",
        )

    _COLUMNS = (
        "id, name, host, port, ssl, user, password, folder, mode, "
        "processed_folder, oversized_folder, enabled, "
        "print_attachments, printer, archive_attachments, include_seen, seen_since"
    )

    def all(self) -> list[Account]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM imap_accounts ORDER BY id").fetchall()
        return [self._row_to_account(row) for row in rows]

    def enabled(self) -> list[Account]:
        return [account for account in self.all() if account.enabled]

    def get(self, account_id: int) -> Account | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM imap_accounts WHERE id = ?", (account_id,)
            ).fetchone()
        return self._row_to_account(row) if row else None

    def add(self, **fields) -> int:
        values = _defaults(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO imap_accounts (name, host, port, ssl, user, password, folder, "
                "mode, processed_folder, oversized_folder, enabled, print_attachments, "
                "printer, archive_attachments, include_seen, seen_since) "
                "VALUES (:name, :host, :port, :ssl, :user, :password, :folder, :mode, "
                ":processed_folder, :oversized_folder, :enabled, :print_attachments, "
                ":printer, :archive_attachments, :include_seen, :seen_since)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, account_id: int, **fields) -> None:
        current = self.get(account_id)
        if current is None:
            raise KeyError(account_id)
        values = _defaults(
            {
                "name": current.name,
                "host": current.host,
                "port": current.port,
                "ssl": current.ssl,
                "user": current.user,
                "password": current.password,
                "folder": current.folder,
                "mode": current.mode,
                "processed_folder": current.processed_folder,
                "oversized_folder": current.oversized_folder,
                "enabled": current.enabled,
                "print_attachments": current.print_attachments,
                "printer": current.printer,
                "archive_attachments": current.archive_attachments,
                "include_seen": current.include_seen,
                "seen_since": current.seen_since,
                **fields,
            }
        )
        values["id"] = account_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE imap_accounts SET name = :name, host = :host, port = :port, ssl = :ssl, "
                "user = :user, password = :password, folder = :folder, mode = :mode, "
                "processed_folder = :processed_folder, oversized_folder = :oversized_folder, "
                "enabled = :enabled, print_attachments = :print_attachments, "
                "printer = :printer, archive_attachments = :archive_attachments, "
                "include_seen = :include_seen, seen_since = :seen_since WHERE id = :id",
                values,
            )

    def delete(self, account_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM imap_accounts WHERE id = ?", (account_id,))


def _add_missing_columns(conn: sqlite3.Connection) -> None:
    """Bring an existing database up to date.

    Printing was added after the table existed, and an update must not require
    re-entering every mailbox - so the columns are added in place, with
    defaults that keep an already-configured install behaving exactly as
    before (nothing printed, everything archived).
    """
    existing = {row[1] for row in conn.execute("PRAGMA table_info(imap_accounts)")}
    for column, definition in (
        ("print_attachments", "INTEGER NOT NULL DEFAULT 0"),
        ("printer", "TEXT NOT NULL DEFAULT ''"),
        ("archive_attachments", "INTEGER NOT NULL DEFAULT 1"),
        ("include_seen", "INTEGER NOT NULL DEFAULT 0"),
        ("seen_since", "TEXT NOT NULL DEFAULT ''"),
    ):
        if column not in existing:
            conn.execute(f"ALTER TABLE imap_accounts ADD COLUMN {column} {definition}")
            logger.info("Added the %s column to the account table", column)


def _defaults(fields: dict) -> dict:
    return {
        "name": str(fields.get("name") or "").strip() or "Postfach",
        "host": str(fields.get("host") or "").strip(),
        "port": int(fields.get("port") or 993),
        "ssl": 1 if fields.get("ssl", True) else 0,
        "user": str(fields.get("user") or "").strip(),
        "password": str(fields.get("password") or ""),
        "folder": str(fields.get("folder") or "INBOX").strip() or "INBOX",
        "mode": "idle" if str(fields.get("mode") or "poll").lower() == "idle" else "poll",
        "processed_folder": str(fields.get("processed_folder") or "").strip(),
        "oversized_folder": str(fields.get("oversized_folder") or "").strip(),
        "enabled": 1 if fields.get("enabled", True) else 0,
        "print_attachments": 1 if fields.get("print_attachments", False) else 0,
        "printer": str(fields.get("printer") or "").strip(),
        "archive_attachments": 1 if fields.get("archive_attachments", True) else 0,
        "include_seen": 1 if fields.get("include_seen", False) else 0,
        "seen_since": _since(fields.get("include_seen", False), fields.get("seen_since")),
    }


def _since(include_seen, value) -> str:
    """A valid YYYY-MM-DD, or today when read mail is included without one."""
    text = str(value or "").strip()
    if text:
        try:
            return date.fromisoformat(text).isoformat()
        except ValueError:
            raise ValueError(f"Kein gueltiges Datum: {text!r} (erwartet JJJJ-MM-TT)") from None
    return date.today().isoformat() if include_seen else ""


def seed_from_config(store: AccountStore, settings, config) -> None:
    """Carry the mailbox of an older `.env` over, once.

    `config` is a `LegacyEnv`. A fresh installation has no mailbox in its
    `.env` - it is set up in the web UI - so nothing is created then.

    Guarded by a flag rather than by "is the table empty", so deleting the
    last account in the UI does not resurrect it from the .env on the next
    restart.
    """
    if settings.get(SETTING_ACCOUNTS_SEEDED):
        return
    if store.all() or not (config.imap_host and config.imap_user):
        settings.set(SETTING_ACCOUNTS_SEEDED, "1")
        return

    store.add(
        name=config.imap_user or "Postfach",
        host=config.imap_host,
        port=config.imap_port,
        ssl=config.imap_ssl,
        user=config.imap_user,
        password=config.imap_password,
        folder=config.imap_folder,
        mode=config.imap_mode,
        processed_folder=config.imap_processed_folder or "",
        oversized_folder=config.imap_oversized_folder or "",
        enabled=True,
    )
    settings.set(SETTING_ACCOUNTS_SEEDED, "1")
    logger.info("Created the first IMAP account from the configuration (%s)", config.imap_host)
