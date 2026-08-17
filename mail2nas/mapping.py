"""Keyword -> folder rules: file format, matching, and editing.

The rules live as YAML on the archive share, so they survive a broken web UI
and stay editable by hand. Two things they have to express beyond the keyword
and the target folder:

* **Order.** The first matching rule wins, and the order is explicit rather
  than derived, so "Rechnungskorrektur" can be placed above "RE" instead of
  relying on it happening to be the longer word.
* **Which mailbox a rule applies to**, once more than one IMAP account is
  configured.
* **Whether the match is printed**, and on which of the configured printers.

Format (version 2)::

    version: 2
    rules:
      - keyword: Rechnungskorrektur
        folder: korrekturen
      - keyword: "RE*"
        folder: rechnungen
        account: "2"
        print: true
        printer: "1"

The old flat `keyword: folder` format is still read: it is migrated in
memory, longest keyword first, which is exactly the priority that version
applied implicitly. Nothing is rewritten until the rules are saved.
"""
from __future__ import annotations

import logging
import re
import threading
from dataclasses import dataclass, field, replace

import yaml

from .filenames import safe_relative_parts
from .storage import Storage

logger = logging.getLogger(__name__)

FILE_VERSION = 2
ALL_ACCOUNTS = "all"
MAX_KEYWORD_LENGTH = 100
# A pattern is a chain of ".*?" separated by literals, so matching cost grows
# with (wildcards x text length). Mail subjects and bodies are attacker-
# supplied, so both factors are bounded rather than trusted: without this a
# keyword like "a*a*a*a*a*..." plus a large body (MATCH_BODY=true) would tie
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
    _matcher: re.Pattern[str] | None = field(default=None, compare=False, repr=False)

    @classmethod
    def create(
        cls,
        keyword: str,
        folder: str,
        account: str = ALL_ACCOUNTS,
        print_attachments: bool = False,
        printer: str = "",
    ) -> "Rule":
        return cls(
            keyword,
            folder,
            account or ALL_ACCOUNTS,
            bool(print_attachments),
            str(printer or ""),
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


class Mapping:
    """The rule list, reloaded from the share when the file changes.

    Shared by every account worker, so reloading is guarded by a lock: each
    worker calls `reload()` at the start of its cycle.
    """

    def __init__(self, storage: Storage, relative_path: str, fallback_folder: str):
        self._storage = storage
        self._fallback_folder = fallback_folder
        self._lock = threading.Lock()
        self._rules: list[Rule] = []
        self._mtime: float | None = None
        self.set_path(relative_path)

    @property
    def path(self) -> str:
        return self._relative_path

    def set_path(self, relative_path: str) -> None:
        """Point at a different mapping file and load it immediately."""
        with self._lock:
            self._relative_path = relative_path
            self._display_path = self._storage.display(safe_relative_parts(relative_path))
            self._mtime = None
        self.reload(force=True)

    def reload(self, force: bool = False) -> None:
        with self._lock:
            relative_path, display_path = self._relative_path, self._display_path
            known_mtime, rule_count = self._mtime, len(self._rules)

        try:
            mtime = self._storage.modified_time(relative_path)
        except FileNotFoundError:
            if force:
                logger.warning(
                    "Mapping file %s not found, all mail will go to the fallback folder",
                    display_path,
                )
                with self._lock:
                    self._rules = []
                    self._mtime = None
            return
        except Exception as exc:  # noqa: BLE001 - a dropped share must not kill the loop
            # With the SMB backend this is a network call, so it can fail for
            # reasons that have nothing to do with the file itself. Keep the
            # rules we already have; the next cycle tries again.
            logger.warning(
                "Could not check mapping file %s (%s) - keeping the previous %d rule(s)",
                display_path,
                exc,
                rule_count,
            )
            return

        if not force and known_mtime == mtime:
            return

        # The file can also be edited by hand on a network share, so a
        # malformed or half-written version is a matter of when, not if. Keep
        # serving the last good rules instead of letting the exception escape:
        # it would propagate out of the IMAP loop and leave the service
        # reconnecting in a tight loop, archiving nothing until someone noticed.
        try:
            rules = parse_rules(yaml.safe_load(self._storage.read_text(relative_path)))
        except Exception as exc:  # noqa: BLE001
            # Remember the mtime anyway, so a persistently broken file is
            # reported once rather than on every single cycle.
            with self._lock:
                self._mtime = mtime
            logger.error(
                "Could not load mapping file %s (%s) - keeping the previous %d rule(s)",
                display_path,
                exc,
                rule_count,
            )
            return

        with self._lock:
            self._rules = rules
            self._mtime = mtime
        logger.info("Loaded %d mapping rule(s) from %s", len(rules), display_path)

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

    def resolve(self, *texts: str, account_id: str | None = None) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword) for the first matching rule."""
        rule = self.match(*texts, account_id=account_id)
        return (rule.folder, rule.keyword) if rule else (self._fallback_folder, None)


# --- editing helpers (used by the web UI) ------------------------------------


def load_rules(storage: Storage, relative_path: str) -> list[Rule]:
    """Read the rule list for editing.

    A missing file is an empty rule list, not an error: that is the state
    right after installation, and the UI is where it gets fixed.
    """
    try:
        return parse_rules(yaml.safe_load(storage.read_text(relative_path)))
    except FileNotFoundError:
        return []


def save_rules(storage: Storage, relative_path: str, rules: list[Rule]) -> None:
    storage.write_text(relative_path, dump_rules(rules))


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


def set_printing(rule: Rule, print_attachments: bool, printer: str) -> Rule:
    """Change a rule's print settings, dropping the printer when off."""
    print_attachments = bool(print_attachments)
    return replace(
        rule,
        print_attachments=print_attachments,
        printer=str(printer or "") if print_attachments else "",
    )
