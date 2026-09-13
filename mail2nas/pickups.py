"""Folders that devices drop documents into.

Multifunction printers can usually either mail a scan or write it straight
onto an SMB share ("Scan to Folder"). The second way never involves a mailbox
at all, so nothing in the IMAP path sees it - but the documents should end up
filed by exactly the same rules, and optionally printed.

A pickup folder is therefore the third way in, next to mail and delivery
addresses: mail2nas watches it, waits until a file has stopped changing, and
moves it into the archive.

Moving, not copying: the pickup folder is the device's outbox. Leaving the
original behind would re-import it on every single cycle.
"""
from __future__ import annotations

import logging
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

MAX_NAME_LENGTH = 80
# How often the watched folders are listed. Cheap locally, a network round
# trip over SMB - so not on every supervisor pass.
PICKUP_INTERVAL = 30
# Devices like to create one subfolder per user or scan profile; that is worth
# following, an unbounded tree is not.
MAX_DEPTH = 5


class PickupError(ValueError):
    """A pickup folder the user tried to save is not usable."""


@dataclass(frozen=True)
class Pickup:
    """One watched folder, and what happens to what turns up in it."""

    id: int
    name: str
    archive: str  # archive the folder is on ("" = the default one)
    folder: str  # relative path of the watched folder
    target_archive: str  # where the documents go ("" = the default one)
    target_folder: str  # "" = let the keyword rules decide
    print_attachments: bool
    printer: str
    enabled: bool

    @property
    def key(self) -> str:
        return str(self.id)

    def label(self) -> str:
        return f"{self.name} ({self.folder})"

    @property
    def has_fixed_target(self) -> bool:
        return bool(self.target_folder.strip())

    @property
    def parts(self) -> tuple[str, ...]:
        return safe_relative_parts(self.folder)

    def rule_scope(self) -> str:
        """The account id a pickup files under.

        A document dropped into a folder did not arrive through any mailbox,
        so only rules that apply to "all accounts" may claim it. Account ids
        are numbers, so this can never collide with a real one.
        """
        return f"pickup:{self.id}"

    def files_into_itself(self) -> bool:
        """True if the target sits inside the watched folder.

        That would re-import the same document for ever, so it is refused when
        saving and skipped at runtime.
        """
        if not self.has_fixed_target or (self.target_archive or "") != (self.archive or ""):
            return False
        try:
            source = safe_relative_parts(self.folder)
            target = safe_relative_parts(self.target_folder)
        except ValueError:
            return False
        return target[: len(source)] == source


class PickupStore:
    """CRUD for the watched folders."""

    _COLUMNS = (
        "id, name, archive, folder, target_archive, target_folder, "
        "print_attachments, printer, enabled"
    )

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS pickup_folders ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "archive TEXT NOT NULL DEFAULT '', "
                "folder TEXT NOT NULL, "
                "target_archive TEXT NOT NULL DEFAULT '', "
                "target_folder TEXT NOT NULL DEFAULT '', "
                "print_attachments INTEGER NOT NULL DEFAULT 0, "
                "printer TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_pickup(row) -> Pickup:
        return Pickup(
            id=row[0],
            name=row[1],
            archive=row[2] or "",
            folder=row[3],
            target_archive=row[4] or "",
            target_folder=row[5] or "",
            print_attachments=bool(row[6]),
            printer=row[7] or "",
            enabled=bool(row[8]),
        )

    def all(self) -> list[Pickup]:
        with self._connect() as conn:
            rows = conn.execute(
                f"SELECT {self._COLUMNS} FROM pickup_folders ORDER BY id"
            ).fetchall()
        return [self._row_to_pickup(row) for row in rows]

    def enabled(self) -> list[Pickup]:
        return [pickup for pickup in self.all() if pickup.enabled]

    def get(self, pickup_id: int) -> Pickup | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM pickup_folders WHERE id = ?", (pickup_id,)
            ).fetchone()
        return self._row_to_pickup(row) if row else None

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO pickup_folders (name, archive, folder, target_archive, "
                "target_folder, print_attachments, printer, enabled) "
                "VALUES (:name, :archive, :folder, :target_archive, :target_folder, "
                ":print_attachments, :printer, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, pickup_id: int, **fields) -> None:
        current = self.get(pickup_id)
        if current is None:
            raise KeyError(pickup_id)
        values = validate(
            {
                "name": current.name,
                "archive": current.archive,
                "folder": current.folder,
                "target_archive": current.target_archive,
                "target_folder": current.target_folder,
                "print_attachments": current.print_attachments,
                "printer": current.printer,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = pickup_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE pickup_folders SET name = :name, archive = :archive, "
                "folder = :folder, target_archive = :target_archive, "
                "target_folder = :target_folder, print_attachments = :print_attachments, "
                "printer = :printer, enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, pickup_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM pickup_folders WHERE id = ?", (pickup_id,))

    def clear_printer(self, printer_key: str) -> int:
        """Drop references to a printer that was deleted."""
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "UPDATE pickup_folders SET print_attachments = 0, printer = '' "
                "WHERE printer = ?",
                (str(printer_key),),
            )
            return cursor.rowcount or 0


def validate(fields: dict) -> dict:
    """Check and normalise what the UI supplies."""
    name = str(fields.get("name") or "").strip()
    folder = str(fields.get("folder") or "").strip()
    target_folder = str(fields.get("target_folder") or "").strip()

    if len(name) > MAX_NAME_LENGTH:
        raise PickupError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")
    if not folder:
        raise PickupError("Bitte den Ordner angeben, in den das Geraet die Scans legt.")

    cleaned = {}
    for key, value in (("folder", folder), ("target_folder", target_folder)):
        if not value:
            cleaned[key] = ""
            continue
        try:
            cleaned[key] = "/".join(safe_relative_parts(value))
        except ValueError as exc:
            what = "Abholordner" if key == "folder" else "Zielordner"
            raise PickupError(f"Der {what} ist nicht zulaessig: {exc}") from None

    values = {
        "name": name or cleaned["folder"],
        "archive": str(fields.get("archive") or "").strip(),
        "folder": cleaned["folder"],
        "target_archive": str(fields.get("target_archive") or "").strip(),
        "target_folder": cleaned["target_folder"],
        "print_attachments": 1 if fields.get("print_attachments", False) else 0,
        "printer": str(fields.get("printer") or "").strip(),
        "enabled": 1 if fields.get("enabled", True) else 0,
    }

    candidate = Pickup(id=0, **{**values, "print_attachments": bool(values["print_attachments"]),
                                "enabled": bool(values["enabled"])})
    if candidate.files_into_itself():
        raise PickupError(
            "Der Zielordner liegt im Abholordner - die Dokumente wuerden immer wieder "
            "eingelesen. Bitte einen Zielordner ausserhalb waehlen."
        )
    return values
