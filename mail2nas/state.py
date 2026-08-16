from __future__ import annotations

import sqlite3
import threading
from pathlib import Path


class ProcessedStore:
    """Tracks Message-IDs that have already been archived.

    IMAP's \\Seen flag alone is not a safe idempotency marker (it can be
    reset by another client, or the folder can be re-synced), so we keep a
    small local record of what has actually been written to the share.

    One instance is shared by all account workers, so every access is
    serialized by a lock and the connection is opened for cross-thread use.
    """

    def __init__(self, db_path: str):
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        with self._lock:
            self._conn.execute(
                "CREATE TABLE IF NOT EXISTS processed_messages ("
                "message_id TEXT PRIMARY KEY, "
                "processed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
            )
            self._conn.commit()

    def is_processed(self, message_id: str) -> bool:
        with self._lock:
            cur = self._conn.execute(
                "SELECT 1 FROM processed_messages WHERE message_id = ?", (message_id,)
            )
            return cur.fetchone() is not None

    def mark_processed(self, message_id: str) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT OR IGNORE INTO processed_messages (message_id) VALUES (?)", (message_id,)
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()
