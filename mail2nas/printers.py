"""Printers, stored locally so the web UI can manage them centrally.

A printer is configured once - here - and then only *referenced* everywhere
else: a mailbox picks one from a dropdown, a mapping rule picks one from a
dropdown. That way the queue name, the CUPS server and the paper options live
in exactly one place, and changing them does not mean editing every rule.

Same storage as the IMAP accounts (the SQLite file next to the state), for the
same reason: it has to be writable, survive updates, and be editable from the
UI. Unlike the accounts this holds no credentials - printing goes through the
local CUPS client, which does its own authentication if the server needs any.
"""
from __future__ import annotations

import logging
import shlex
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger(__name__)

SETTING_PRINTERS_SEEDED = "printers_seeded"

MAX_NAME_LENGTH = 80
MAX_DESTINATION_LENGTH = 128
MAX_OPTIONS_LENGTH = 200
MAX_COPIES = 20


class PrinterError(ValueError):
    """A printer the user tried to save is not usable."""


@dataclass(frozen=True)
class Printer:
    """One print queue."""

    id: int
    name: str
    destination: str  # CUPS queue name, i.e. `lp -d <destination>`
    server: str  # optional CUPS server "host" or "host:port"; empty = local cupsd
    options: str  # extra lp options, e.g. "media=A4 sides=two-sided-long-edge"
    copies: int
    enabled: bool

    @property
    def key(self) -> str:
        """Stable identifier, as referenced by an account or a mapping rule."""
        return str(self.id)

    @property
    def option_list(self) -> list[str]:
        """The options as separate `-o` arguments."""
        return shlex.split(self.options) if self.options.strip() else []

    def label(self) -> str:
        where = f" @ {self.server}" if self.server else ""
        return f"{self.name} ({self.destination}{where})"


class PrinterStore:
    """CRUD for the configured printers.

    Opens a short-lived connection per call, like `AccountStore`: the web UI
    answers requests on a thread pool and the account workers read from their
    own threads, and one sqlite3 connection must not be shared across threads.
    """

    _COLUMNS = "id, name, destination, server, options, copies, enabled"

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS printers ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "destination TEXT NOT NULL, "
                "server TEXT NOT NULL DEFAULT '', "
                "options TEXT NOT NULL DEFAULT '', "
                "copies INTEGER NOT NULL DEFAULT 1, "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_printer(row) -> Printer:
        return Printer(
            id=row[0],
            name=row[1],
            destination=row[2],
            server=row[3],
            options=row[4],
            copies=row[5],
            enabled=bool(row[6]),
        )

    def all(self) -> list[Printer]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM printers ORDER BY id").fetchall()
        return [self._row_to_printer(row) for row in rows]

    def enabled(self) -> list[Printer]:
        return [printer for printer in self.all() if printer.enabled]

    def get(self, printer_id: int) -> Printer | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM printers WHERE id = ?", (printer_id,)
            ).fetchone()
        return self._row_to_printer(row) if row else None

    def by_key(self, key: str) -> Printer | None:
        """Look a printer up by the string id an account or rule stores."""
        try:
            printer_id = int(str(key).strip())
        except (TypeError, ValueError):
            return None
        return self.get(printer_id)

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO printers (name, destination, server, options, copies, enabled) "
                "VALUES (:name, :destination, :server, :options, :copies, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, printer_id: int, **fields) -> None:
        current = self.get(printer_id)
        if current is None:
            raise KeyError(printer_id)
        values = validate(
            {
                "name": current.name,
                "destination": current.destination,
                "server": current.server,
                "options": current.options,
                "copies": current.copies,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = printer_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE printers SET name = :name, destination = :destination, "
                "server = :server, options = :options, copies = :copies, "
                "enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, printer_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM printers WHERE id = ?", (printer_id,))


def validate(fields: dict) -> dict:
    """Check and normalise what the UI (or the environment) supplies.

    The values end up as arguments to the `lp` binary. That call never goes
    through a shell, so this is not about quoting - it is about catching typos
    early and refusing values (newlines, leading dashes) that would turn into
    something other than what was typed.
    """
    name = str(fields.get("name") or "").strip()
    destination = str(fields.get("destination") or "").strip()
    server = str(fields.get("server") or "").strip()
    options = " ".join(str(fields.get("options") or "").split())

    if not destination:
        raise PrinterError("Bitte den Namen der Druckerwarteschlange angeben.")
    if len(destination) > MAX_DESTINATION_LENGTH:
        raise PrinterError(f"Die Warteschlange darf hoechstens {MAX_DESTINATION_LENGTH} Zeichen lang sein.")
    if any(char.isspace() for char in destination) or destination.startswith("-"):
        raise PrinterError(
            "Die Warteschlange darf keine Leerzeichen enthalten und nicht mit '-' beginnen "
            "(so heisst sie auch in CUPS)."
        )
    if len(name) > MAX_NAME_LENGTH:
        raise PrinterError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")
    if any(char.isspace() for char in server) or server.startswith("-"):
        raise PrinterError("Der CUPS-Server darf keine Leerzeichen enthalten (z. B. cups.lan:631).")
    if len(options) > MAX_OPTIONS_LENGTH:
        raise PrinterError(f"Die Optionen duerfen hoechstens {MAX_OPTIONS_LENGTH} Zeichen lang sein.")

    try:
        option_list = shlex.split(options) if options else []
    except ValueError as exc:
        raise PrinterError(f"Die Optionen sind nicht lesbar: {exc}") from None
    for option in option_list:
        if option.startswith("-"):
            raise PrinterError(
                f"Option {option!r}: nur der Teil hinter -o angeben, z. B. media=A4."
            )

    try:
        copies = int(fields.get("copies") or 1)
    except (TypeError, ValueError):
        raise PrinterError("Die Anzahl der Kopien muss eine Zahl sein.") from None
    if not 1 <= copies <= MAX_COPIES:
        raise PrinterError(f"Die Anzahl der Kopien muss zwischen 1 und {MAX_COPIES} liegen.")

    return {
        "name": name or destination,
        "destination": destination,
        "server": server,
        "options": options,
        "copies": copies,
        "enabled": 1 if fields.get("enabled", True) else 0,
    }


def seed_from_config(store: PrinterStore, settings, config) -> None:
    """Create the first printer from the environment, once.

    Same deal as the IMAP accounts: an install that configured a printer in
    the `.env` gets it without re-entering anything, and deleting it in the UI
    does not resurrect it on the next restart.
    """
    if settings.get(SETTING_PRINTERS_SEEDED):
        return
    if store.all() or not config.printer_destination:
        settings.set(SETTING_PRINTERS_SEEDED, "1")
        return

    try:
        store.add(
            name=config.printer_name or config.printer_destination,
            destination=config.printer_destination,
            server=config.printer_server,
            options=config.printer_options,
            copies=config.printer_copies,
            enabled=True,
        )
    except PrinterError as exc:
        logger.error("PRINTER_DESTINATION is not usable (%s) - no printer was created", exc)
        return
    settings.set(SETTING_PRINTERS_SEEDED, "1")
    logger.info("Created the first printer from the configuration (%s)", config.printer_destination)
