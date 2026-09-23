"""Keyword -> folder rules: storage, matching, and editing.

The rules live in the local database, next to the mailboxes and archives,
and are edited in the web UI. They used to be a `mapping.yaml` on the share;
`migrate.py` carries such a file over once, and the YAML format lives on as
the import/export format - a readable backup, and a way to move rules from one
installation to another.

Three things a rule expresses beyond keyword and target folder:

* **Order.** The first matching rule wins, and the order is explicit rather
  than derived, so "Rechnungskorrektur" can be placed above "RE" instead of
  relying on it happening to be the longer word.
* **Which mailbox a rule applies to**, once more than one IMAP account is
  configured.
* **Whether the match is printed**, and on which of the configured printers,
  and on which archive the folder is.

Export format (version 2)::

    version: 2
    rules:
      - keyword: Rechnungskorrektur
        folder: korrekturen
      - keyword: "RE*"
        folder: rechnungen
        account: "2"
        print: true
        printer: "1"

The old flat `keyword: folder` format is still read on import: longest
keyword first, which is exactly the priority that version applied implicitly.
"""
from __future__ import annotations

import logging
import re
import sqlite3
import threading
from collections.abc import Callable
from pathlib import Path
from dataclasses import dataclass, field, replace

import yaml

from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

FILE_VERSION = 2
ALL_ACCOUNTS = "all"
MAX_KEYWORD_LENGTH = 100
# A pattern is a chain of ".*?" separated by literals, so matching cost grows
# with (wildcards x text length). Mail subjects and bodies are attacker-
# supplied, so both factors are bounded rather than trusted: without this a
# keyword like "a*a*a*a*a*..." plus a large body (body matching enabled) would tie
# up an account worker for a very long time.
MAX_WILDCARDS = 5
MAX_MATCH_LENGTH = 100_000


class MappingError(ValueError):
    """A rule the user tried to save is not usable."""


def _compile(keyword: str) -> re.Pattern[str] | None:
    """Build a matcher for a keyword containing `*` / `?`, or None for plain text.

    Wildcards stay *within* the substring search people already know: the
    pattern is not anchored, so "RE*2026" matches a subject that has "RE"
    somewhere followed later by "2026". `*Rechnung*` therefore means the same
    as plain `Rechnung`.
    """
    if "*" not in keyword and "?" not in keyword:
        return None
    if keyword.count("*") > MAX_WILDCARDS:
        # Loaded from a file that may have been edited by hand, so this has to
        # degrade rather than raise: treat it as plain text, which can only
        # match less, never more.
        logger.warning(
            "Keyword %r has more than %d wildcards - treating it as literal text",
            keyword,
            MAX_WILDCARDS,
        )
        return None
    pattern = "".join(
        ".*?" if char == "*" else "." if char == "?" else re.escape(char) for char in keyword
    )
    return re.compile(pattern, re.IGNORECASE | re.DOTALL)


@dataclass(frozen=True)
class Rule:
    """One keyword -> folder assignment."""

    keyword: str
    folder: str
    account: str = ALL_ACCOUNTS  # ALL_ACCOUNTS or an account id as a string
    # Print the attachments this rule matches. The printer is optional: an
    # empty string means "whatever the mailbox is set to".
    print_attachments: bool = False
    printer: str = ""
    # Which archive the folder is on. Empty = the default archive, so a
    # mapping file written before there was more than one keeps working.
    archive: str = ""
    _matcher: re.Pattern[str] | None = field(default=None, compare=False, repr=False)

    @classmethod
    def create(
        cls,
        keyword: str,
        folder: str,
        account: str = ALL_ACCOUNTS,
        print_attachments: bool = False,
        printer: str = "",
        archive: str = "",
    ) -> "Rule":
        return cls(
            keyword,
            folder,
            account or ALL_ACCOUNTS,
            bool(print_attachments),
            str(printer or ""),
            str(archive or ""),
            _compile(keyword),
        )

    @property
    def has_wildcard(self) -> bool:
        return self._matcher is not None

    def applies_to(self, account_id: str | None) -> bool:
        if self.account == ALL_ACCOUNTS or account_id is None:
            return True
        return self.account == str(account_id)

    def matches(self, haystack_lower: str, haystack: str) -> bool:
        if self._matcher is not None:
            return self._matcher.search(haystack[:MAX_MATCH_LENGTH]) is not None
        return self.keyword.lower() in haystack_lower

    def as_dict(self) -> dict[str, object]:
        # Only what differs from the default is written, so a file that never
        # used printing stays exactly as short as it was.
        data: dict[str, object] = {"keyword": self.keyword, "folder": self.folder}
        if self.account != ALL_ACCOUNTS:
            data["account"] = self.account
        if self.print_attachments:
            data["print"] = True
        if self.printer:
            data["printer"] = self.printer
        if self.archive:
            data["archive"] = self.archive
        return data


def _as_bool(value) -> bool:
    """Read a flag from a file someone may have edited by hand.

    YAML already turns `true`/`yes` into booleans, but `print: "ja"` is the
    kind of thing that gets typed - and silently treating it as false would
    mean paper that never comes out with nothing to explain why.
    """
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on", "ja")


def parse_rules(raw) -> list[Rule]:
    """Turn parsed YAML into rules, accepting both file formats."""
    if not raw:
        return []

    if isinstance(raw, dict) and "rules" in raw:
        entries = raw.get("rules") or []
        if not isinstance(entries, list):
            raise MappingError("'rules' muss eine Liste von Zuordnungen sein.")
        rules = []
        for entry in entries:
            if not isinstance(entry, dict) or "keyword" not in entry or "folder" not in entry:
                raise MappingError("Jede Zuordnung braucht 'keyword' und 'folder'.")
            rules.append(
                Rule.create(
                    str(entry["keyword"]),
                    str(entry["folder"]),
                    str(entry.get("account", ALL_ACCOUNTS)),
                    _as_bool(entry.get("print", False)),
                    str(entry.get("printer", "") or ""),
                    str(entry.get("archive", "") or ""),
                )
            )
        return rules

    if isinstance(raw, dict):
        # Legacy flat format. Longest keyword first reproduces the priority the
        # old matcher applied implicitly, so migrating cannot change behaviour.
        pairs = sorted(raw.items(), key=lambda kv: len(str(kv[0])), reverse=True)
        return [Rule.create(str(keyword), str(folder)) for keyword, folder in pairs]

    raise MappingError("Die Datei enthaelt keine Stichwort/Ordner-Zuordnungen.")


def dump_rules(rules: list[Rule]) -> str:
    """Render rules as YAML, preserving their order."""
    document = {"version": FILE_VERSION, "rules": [rule.as_dict() for rule in rules]}
    return yaml.safe_dump(document, allow_unicode=True, default_flow_style=False, sort_keys=False)


def rules_from_yaml(text: str) -> list[Rule]:
    """Parse an exported (or old on-share) rule file."""
    try:
        raw = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        raise MappingError(f"Die Datei ist kein gueltiges YAML: {exc}") from None
    return parse_rules(raw)


class RuleStore:
    """The rule list in the database, in priority order.

    Saved as a whole: the UI always edits the complete, ordered list (moving
    one rule changes the position of two), and replacing it in one
    transaction means a reader never sees a list that is half old, half new.
    """

    def __init__(self, db_path: str):
        self._db_path = db_path
        self._lock = threading.Lock()
        Path(db_path).parent.mkdir(parents=True, exist_ok=True)
        with self._connect() as conn:
            conn.execute(
                "CREATE TABLE IF NOT EXISTS mapping_rules ("
                "position INTEGER PRIMARY KEY, "
                "keyword TEXT NOT NULL, "
                "folder TEXT NOT NULL, "
                "account TEXT NOT NULL DEFAULT 'all', "
                "print INTEGER NOT NULL DEFAULT 0, "
                "printer TEXT NOT NULL DEFAULT '', "
                "archive TEXT NOT NULL DEFAULT '')"
            )

    def _connect(self) -> sqlite3.Connection:
        return sqlite3.connect(self._db_path, timeout=10)

    def load(self) -> list[Rule]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT keyword, folder, account, print, printer, archive "
                "FROM mapping_rules ORDER BY position"
            ).fetchall()
        return [
            Rule.create(keyword, folder, account, bool(printing), printer, archive)
            for keyword, folder, account, printing, printer, archive in rows
        ]

    def save(self, rules: list[Rule]) -> None:
        with self._lock, self._connect() as conn:
            conn.execute("DELETE FROM mapping_rules")
            conn.executemany(
                "INSERT INTO mapping_rules (position, keyword, folder, account, print, "
                "printer, archive) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [
                    (
                        position,
                        rule.keyword,
                        rule.folder,
                        rule.account or ALL_ACCOUNTS,
                        1 if rule.print_attachments else 0,
                        rule.printer,
                        rule.archive,
                    )
                    for position, rule in enumerate(rules)
                ],
            )

    def count(self) -> int:
        with self._connect() as conn:
            return int(conn.execute("SELECT COUNT(*) FROM mapping_rules").fetchone()[0])


class Mapping:
    """The rule list as the archiver sees it.

    Shared by every account worker and the pickup runner. `reload()` is called
    at the start of each cycle and re-reads the table - a handful of rows from
    a local file, cheaper than any cleverness about noticing changes.
    """

    def __init__(self, store: RuleStore, fallback_folder: str | Callable[[], str] = "unsorted"):
        self._store = store
        self._fallback_folder = fallback_folder
        self._lock = threading.Lock()
        self._rules: list[Rule] = []
        self.reload()

    @property
    def store(self) -> RuleStore:
        return self._store

    @property
    def rules(self) -> list[Rule]:
        with self._lock:
            return list(self._rules)

    def reload(self) -> None:
        try:
            rules = self._store.load()
        except Exception as exc:  # noqa: BLE001 - keep the last good rules
            logger.error("Could not read the mapping rules (%s) - keeping the previous %d",
                         exc, len(self._rules))
            return
        with self._lock:
            self._rules = rules

    def save(self, rules: list[Rule]) -> None:
        self._store.save(rules)
        with self._lock:
            self._rules = list(rules)

    def match(self, *texts: str, account_id: str | None = None) -> Rule | None:
        """Return the first rule that matches, or None.

        The whole rule rather than just its folder: the caller also needs to
        know whether the match should be printed, and on which printer.
        """
        haystack = " ".join(t for t in texts if t)
        haystack_lower = haystack.lower()
        with self._lock:
            rules = self._rules
        for rule in rules:
            if rule.applies_to(account_id) and rule.matches(haystack_lower, haystack):
                return rule
        return None

    def fallback_folder(self) -> str:
        value = self._fallback_folder
        return value() if callable(value) else value

    def resolve(self, *texts: str, account_id: str | None = None) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword) for the first matching rule."""
        rule = self.match(*texts, account_id=account_id)
        return (rule.folder, rule.keyword) if rule else (self.fallback_folder(), None)


# --- editing helpers (used by the web UI) ------------------------------------


def validate_keyword(keyword: str, existing: list[Rule], replacing: int | None = None) -> str:
    """Check a keyword the user typed, returning the cleaned version."""
    keyword = keyword.strip()
    if not keyword:
        raise MappingError("Bitte ein Stichwort angeben.")
    if len(keyword) > MAX_KEYWORD_LENGTH:
        raise MappingError(f"Das Stichwort darf hoechstens {MAX_KEYWORD_LENGTH} Zeichen lang sein.")
    if "\n" in keyword or "\r" in keyword:
        raise MappingError("Das Stichwort darf keine Zeilenumbrueche enthalten.")
    if keyword.strip("*? ") == "":
        raise MappingError("Ein Stichwort aus lauter Platzhaltern wuerde auf alles passen.")
    if keyword.count("*") > MAX_WILDCARDS:
        raise MappingError(f"Hoechstens {MAX_WILDCARDS} Platzhalter (*) pro Stichwort.")
    # Matching is case-insensitive, so two rules with the same keyword for the
    # same account would be indistinguishable - the second could never win.
    lowered = keyword.lower()
    for index, rule in enumerate(existing):
        if index == replacing:
            continue
        if rule.keyword.lower() == lowered:
            raise MappingError(f"Das Stichwort {rule.keyword!r} gibt es schon.")
    return keyword


def validate_folder(folder: str) -> str:
    """Check a target folder, returning the cleaned relative path."""
    folder = folder.strip().replace("\\", "/")
    if not folder:
        raise MappingError("Bitte einen Zielordner auswaehlen oder anlegen.")
    try:
        parts = safe_relative_parts(folder)
    except ValueError as exc:
        raise MappingError(f"Ungueltiger Zielordner: {exc}") from None
    return "/".join(parts)


def move_rule(rules: list[Rule], index: int, offset: int) -> list[Rule]:
    """Return the rules with one entry moved up or down."""
    if not 0 <= index < len(rules):
        raise MappingError("Diese Zuordnung gibt es nicht mehr.")
    target = index + offset
    if not 0 <= target < len(rules):
        return rules
    reordered = list(rules)
    reordered.insert(target, reordered.pop(index))
    return reordered


def set_account(rule: Rule, account: str) -> Rule:
    return replace(rule, account=account or ALL_ACCOUNTS)


def set_archive(rule: Rule, archive: str) -> Rule:
    """Move a rule's target folder to another archive ("" = the default one)."""
    return replace(rule, archive=str(archive or ""))


def set_printing(rule: Rule, print_attachments: bool, printer: str) -> Rule:
    """Change a rule's print settings, dropping the printer when off."""
    print_attachments = bool(print_attachments)
    return replace(
        rule,
        print_attachments=print_attachments,
        printer=str(printer or "") if print_attachments else "",
    )
