"""Routing by mail address: what happens to mail sent *to* a given address.

The mapping rules answer "what kind of document is this?" by looking at
keywords. This answers a different question - "who was it sent to, and by
whom?" - and that is what makes a print-by-mail address work: an alias like
`drucker-buero@firma.de` is delivered into the archive mailbox, and everything
addressed to it is printed on the printer that belongs to that alias.

Deliberately independent of the IMAP accounts: aliases usually land in one
mailbox, so a separate account per address would mean a separate IMAP login
per printer. Matching happens on the message instead.

Stored in the same SQLite file as the accounts and printers - the UI has to
be able to edit it, and it references printer ids.
"""
from __future__ import annotations

import fnmatch
import logging
import sqlite3
import threading
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from pathlib import Path

from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

MAX_NAME_LENGTH = 80
MAX_PATTERN_LENGTH = 200
# Same reasoning as the mapping keywords: the text being matched comes from
# outside, so the pattern may not turn into something expensive.
MAX_WILDCARDS = 5


class AddressError(ValueError):
    """An address rule the user tried to save is not usable."""


def matches_address(pattern: str, address: str) -> bool:
    """True if `address` is covered by `pattern`.

    Three notations, in the order people reach for them:

    * `drucker@firma.de` - exactly this address.
    * `@drucker.firma.de` - every address in that domain.
    * `drucker-*@firma.de` - wildcards, `*` and `?` as usual.

    Case is irrelevant, as it is for mail addresses in practice.
    """
    pattern = (pattern or "").strip().lower()
    address = (address or "").strip().lower()
    if not pattern or not address:
        return False
    if "*" in pattern or "?" in pattern:
        if pattern.count("*") > MAX_WILDCARDS:
            logger.warning("Address pattern %r has too many wildcards - ignoring it", pattern)
            return False
        return fnmatch.fnmatchcase(address, pattern)
    if pattern.startswith("@"):
        return address.endswith(pattern)
    return address == pattern


@dataclass(frozen=True)
class AddressRule:
    """One "mail to this address is handled like this" entry."""

    id: int
    name: str
    recipient: str  # empty = any recipient (then `sender` alone decides)
    sender: str  # empty = any sender
    print_attachments: bool
    printer: str  # printer key; "" = whatever the mailbox is set to
    archive_attachments: bool
    folder: str  # "" = let the keyword rules decide
    enabled: bool

    @property
    def key(self) -> str:
        return str(self.id)

    def label(self) -> str:
        where = self.recipient or "(jede Empfaengeradresse)"
        if self.sender:
            where += f" von {self.sender}"
        return f"{self.name} - {where}"

    def matches(self, recipients: Sequence[str], sender: str) -> bool:
        """Does this rule apply to a message?

        Both patterns have to fit when both are set. That is the safe
        direction for something that consumes paper: naming a sender turns
        the rule into "only these people may print here", not into a second,
        independent way to trigger it.
        """
        if self.recipient and not any(matches_address(self.recipient, to) for to in recipients):
            return False
        if self.sender and not matches_address(self.sender, sender):
            return False
        # A rule with neither pattern would match every mail; validate()
        # rejects it, but a hand-edited database must not print everything.
        return bool(self.recipient or self.sender)


class AddressStore:
    """CRUD for the address rules.

    Short-lived connection per call, like the other stores: the web UI and the
    account workers are different threads, and one sqlite3 connection must not
    be shared between them.
    """

    _COLUMNS = (
        "id, name, recipient, sender, print_attachments, printer, "
        "archive_attachments, folder, enabled"
    )

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS address_rules ("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "name TEXT NOT NULL, "
                "recipient TEXT NOT NULL DEFAULT '', "
                "sender TEXT NOT NULL DEFAULT '', "
                "print_attachments INTEGER NOT NULL DEFAULT 1, "
                "printer TEXT NOT NULL DEFAULT '', "
                "archive_attachments INTEGER NOT NULL DEFAULT 1, "
                "folder TEXT NOT NULL DEFAULT '', "
                "enabled INTEGER NOT NULL DEFAULT 1)"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    @staticmethod
    def _row_to_rule(row) -> AddressRule:
        return AddressRule(
            id=row[0],
            name=row[1],
            recipient=row[2],
            sender=row[3],
            print_attachments=bool(row[4]),
            printer=row[5] or "",
            archive_attachments=bool(row[6]),
            folder=row[7] or "",
            enabled=bool(row[8]),
        )

    def all(self) -> list[AddressRule]:
        with self._connect() as conn:
            rows = conn.execute(f"SELECT {self._COLUMNS} FROM address_rules ORDER BY id").fetchall()
        return [self._row_to_rule(row) for row in rows]

    def enabled(self) -> list[AddressRule]:
        return [rule for rule in self.all() if rule.enabled]

    def get(self, rule_id: int) -> AddressRule | None:
        with self._connect() as conn:
            row = conn.execute(
                f"SELECT {self._COLUMNS} FROM address_rules WHERE id = ?", (rule_id,)
            ).fetchone()
        return self._row_to_rule(row) if row else None

    def match(self, recipients: Iterable[str], sender: str) -> AddressRule | None:
        """The first enabled rule that fits, or None.

        First match wins, like the mapping rules: two aliases that both cover
        a mail is a configuration decision, and printing twice because of it
        would be a surprise.
        """
        addresses = [str(a) for a in recipients]
        for rule in self.enabled():
            if rule.matches(addresses, sender):
                return rule
        return None

    def add(self, **fields) -> int:
        values = validate(fields)
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "INSERT INTO address_rules (name, recipient, sender, print_attachments, "
                "printer, archive_attachments, folder, enabled) "
                "VALUES (:name, :recipient, :sender, :print_attachments, :printer, "
                ":archive_attachments, :folder, :enabled)",
                values,
            )
            return int(cursor.lastrowid)

    def update(self, rule_id: int, **fields) -> None:
        current = self.get(rule_id)
        if current is None:
            raise KeyError(rule_id)
        values = validate(
            {
                "name": current.name,
                "recipient": current.recipient,
                "sender": current.sender,
                "print_attachments": current.print_attachments,
                "printer": current.printer,
                "archive_attachments": current.archive_attachments,
                "folder": current.folder,
                "enabled": current.enabled,
                **fields,
            }
        )
        values["id"] = rule_id
        with self._lock, self._connect() as conn:
            conn.execute(
                "UPDATE address_rules SET name = :name, recipient = :recipient, "
                "sender = :sender, print_attachments = :print_attachments, "
                "printer = :printer, archive_attachments = :archive_attachments, "
                "folder = :folder, enabled = :enabled WHERE id = :id",
                values,
            )

    def delete(self, rule_id: int) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM address_rules WHERE id = ?", (rule_id,))

    def clear_printer(self, printer_key: str) -> int:
        """Drop references to a printer that was deleted.

        Without this the rule would keep pointing at a queue that no longer
        exists and quietly stop printing.
        """
        with self._lock, self._connect() as conn:
            cursor = conn.execute(
                "UPDATE address_rules SET printer = '' WHERE printer = ?", (str(printer_key),)
            )
            return cursor.rowcount or 0


def validate(fields: dict) -> dict:
    """Check and normalise what the UI supplies."""
    name = str(fields.get("name") or "").strip()
    recipient = str(fields.get("recipient") or "").strip().lower()
    sender = str(fields.get("sender") or "").strip().lower()
    folder = str(fields.get("folder") or "").strip()

    if not recipient and not sender:
        raise AddressError(
            "Bitte mindestens eine Empfaengeradresse angeben (oder eine Absenderadresse)."
        )
    for pattern, what in ((recipient, "Empfaengeradresse"), (sender, "Absenderadresse")):
        if not pattern:
            continue
        if len(pattern) > MAX_PATTERN_LENGTH:
            raise AddressError(f"Die {what} darf hoechstens {MAX_PATTERN_LENGTH} Zeichen lang sein.")
        if any(char.isspace() for char in pattern) or "," in pattern:
            raise AddressError(
                f"Die {what} darf nur eine einzelne Adresse enthalten "
                "(z. B. drucker@firma.de, @firma.de oder drucker-*@firma.de)."
            )
        if pattern.count("*") > MAX_WILDCARDS:
            raise AddressError(f"Die {what} hat zu viele Platzhalter.")
        if "@" not in pattern:
            raise AddressError(
                f"Die {what} sieht nicht nach einer Adresse aus - das @ fehlt "
                "(eine ganze Domain schreibt man als @firma.de)."
            )
    if len(name) > MAX_NAME_LENGTH:
        raise AddressError(f"Der Name darf hoechstens {MAX_NAME_LENGTH} Zeichen lang sein.")

    if folder:
        try:
            folder = "/".join(safe_relative_parts(folder))
        except ValueError as exc:
            raise AddressError(f"Der Zielordner ist nicht zulaessig: {exc}") from None

    print_attachments = bool(fields.get("print_attachments", False))
    archive_attachments = bool(fields.get("archive_attachments", True))
    if not print_attachments and not archive_attachments:
        raise AddressError(
            "Ohne Drucken und ohne Ablegen wuerde der Anhang verworfen - "
            "bitte mindestens eines auswaehlen."
        )

    return {
        "name": name or recipient or sender,
        "recipient": recipient,
        "sender": sender,
        "print_attachments": 1 if print_attachments else 0,
        "printer": str(fields.get("printer") or "").strip(),
        "archive_attachments": 1 if archive_attachments else 0,
        "folder": folder,
        "enabled": 1 if fields.get("enabled", True) else 0,
    }
