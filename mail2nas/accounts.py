"""IMAP accounts, stored locally so the web UI can edit them.

Until now there was exactly one mailbox and it came from the environment.
Editing it in the UI - and having more than one - means the configuration has
to live somewhere writable, so it goes into the same SQLite file as the rest
of the local state.

The environment still seeds the first account on a fresh install, so an
existing `.env` keeps working and nothing has to be re-entered. After that the
database wins: changes made in the UI survive restarts and updates, and the
IMAP_* variables are ignored.

Note this means the state database now holds IMAP passwords in clear text.
It needs the same protection as the `.env` file - see the README.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
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
        )

    _COLUMNS = (
        "id, name, host, port, ssl, user, password, folder, mode, "
        "processed_folder, oversized_folder, enabled"
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
                "mode, processed_folder, oversized_folder, enabled) "
                "VALUES (:name, :host, :port, :ssl, :user, :password, :folder, :mode, "
                ":processed_folder, :oversized_folder, :enabled)",
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
                **fields,
            }
        )
        values["id"] = account_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE imap_accounts SET name = :name, host = :host, port = :port, ssl = :ssl, "
                "user = :user, password = :password, folder = :folder, mode = :mode, "
                "processed_folder = :processed_folder, oversized_folder = :oversized_folder, "
                "enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, account_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM imap_accounts WHERE id = ?", (account_id,))


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
    }


def seed_from_config(store: AccountStore, settings, config) -> None:
    """Create the first account from the environment, once.

    Guarded by a flag rather than by "is the table empty", so deleting the
    last account in the UI does not resurrect it from the .env on the next
    restart.
    """
    if settings.get(SETTING_ACCOUNTS_SEEDED):
        return
    if store.all():
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
