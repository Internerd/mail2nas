from __future__ import annotations

import fnmatch
import logging
from dataclasses import dataclass
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)

ALL_ACCOUNTS = "all"


@dataclass(frozen=True)
class Rule:
    """One keyword -> folder rule.

    `account` is either ALL_ACCOUNTS or the id of a single mail account, so a
    rule can be limited to one mailbox when several are configured.
    """

    match: str
    folder: str
    account: str = ALL_ACCOUNTS

    @property
    def is_wildcard(self) -> bool:
        return any(ch in self.match for ch in "*?")

    def applies_to(self, account: str | None) -> bool:
        return self.account == ALL_ACCOUNTS or account is None or self.account == account

    def matches(self, haystack: str) -> bool:
        """Case-insensitive test against already-lowercased `haystack`.

        A pattern containing * or ? is treated as a wildcard matched against
        the whole text; anything else keeps the original substring behaviour,
        so existing mapping files behave exactly as before.
        """
        pattern = self.match.lower()
        if self.is_wildcard:
            return fnmatch.fnmatchcase(haystack, pattern)
        return pattern in haystack


def _coerce_rules(raw: object) -> list[Rule]:
    """Build the rule list from either mapping-file format.

    v2 (ordered, explicit priority - first match wins):
        version: 2
        rules:
          - match: "Rechnung*"
            folder: rechnungen
            account: all

    v1 (legacy plain dict, no ordering information):
        RE: rechnungen
    Sorted longest-keyword-first, which is what v1 always did implicitly so
    that "Rechnungskorrektur" is checked before "RE".
    """
    if isinstance(raw, dict) and "rules" in raw:
        entries = raw.get("rules") or []
        if not isinstance(entries, list):
            raise ValueError("'rules' must be a list")
        rules = []
        for index, entry in enumerate(entries, start=1):
            if not isinstance(entry, dict):
                raise ValueError(f"rule #{index} must be a mapping")
            match = str(entry.get("match", "")).strip()
            folder = str(entry.get("folder", "")).strip()
            if not match or not folder:
                raise ValueError(f"rule #{index} needs both 'match' and 'folder'")
            rules.append(
                Rule(match=match, folder=folder, account=str(entry.get("account") or ALL_ACCOUNTS))
            )
        return rules

    if isinstance(raw, dict):
        return [
            Rule(match=str(keyword), folder=str(folder))
            for keyword, folder in sorted(raw.items(), key=lambda kv: len(str(kv[0])), reverse=True)
        ]

    raise ValueError("file must contain a mapping of keyword -> folder, or a 'rules' list")


def dump_rules(rules: list[Rule]) -> str:
    """Serialize rules back to the v2 format, preserving their order."""
    payload = {
        "version": 2,
        "rules": [{"match": r.match, "folder": r.folder, "account": r.account} for r in rules],
    }
    header = (
        "# mail2nas Zuordnungen\n"
        "#\n"
        "# Die REIHENFOLGE bestimmt die Prioritaet: die erste passende Regel\n"
        "# gewinnt. Ueber die Weboberflaeche laesst sie sich mit den Pfeilen\n"
        "# verschieben.\n"
        "#\n"
        "# match   - Stichwort, Gross-/Kleinschreibung egal. Enthaelt es * oder ?,\n"
        "#           wird es als Platzhalter gegen den ganzen Text geprueft\n"
        "#           (z. B. \"Rechnung*\"), sonst als Teilstring gesucht.\n"
        "# folder  - Zielordner relativ zur Wurzel des Shares.\n"
        "# account - 'all' oder die id eines einzelnen Mailkontos.\n"
        "#\n"
        "# Geprueft wird zuerst der Dateiname jedes Anhangs, dann Betreff/Text.\n"
    )
    return header + yaml.safe_dump(payload, allow_unicode=True, sort_keys=False)


class Mapping:
    """Keyword -> target-subfolder rules, reloaded from disk on demand.

    The mapping file is expected to live on the same SMB share the
    attachments are archived to, so it can be edited by anyone with
    access to the share without touching the container/deployment.
    """

    def __init__(self, path: str, fallback_folder: str):
        self._path = Path(path)
        self._fallback_folder = fallback_folder
        self._rules: list[Rule] = []
        self._mtime: float | None = None
        self.reload(force=True)

    @property
    def path(self) -> Path:
        return self._path

    @property
    def rules(self) -> list[Rule]:
        return list(self._rules)

    def set_path(self, path: str) -> None:
        """Point at a different mapping file and load it immediately."""
        self._path = Path(path)
        self._mtime = None
        self.reload(force=True)

    def reload(self, force: bool = False) -> None:
        try:
            mtime = self._path.stat().st_mtime
        except FileNotFoundError:
            if force:
                logger.warning(
                    "Mapping file %s not found, all mail will go to the fallback folder", self._path
                )
                self._rules = []
                self._mtime = None
            return

        if not force and self._mtime == mtime:
            return

        # The mapping file is edited by hand on a network share, so a malformed
        # or half-written version is a matter of when, not if. Keep serving the
        # last good rules instead of letting the exception escape: it would
        # propagate out of the IMAP loop and leave the service reconnecting in
        # a tight loop, archiving nothing at all until someone noticed.
        try:
            with self._path.open("r", encoding="utf-8") as fh:
                raw = yaml.safe_load(fh) or {}
            rules = _coerce_rules(raw)
        except Exception as exc:
            # Remember the mtime anyway, so a persistently broken file is
            # reported once rather than on every single cycle.
            self._mtime = mtime
            logger.error(
                "Could not load mapping file %s (%s) - keeping the previous %d rule(s)",
                self._path,
                exc,
                len(self._rules),
            )
            return

        self._rules = rules
        self._mtime = mtime
        logger.info("Loaded %d mapping rule(s) from %s", len(self._rules), self._path)

    def save(self, rules: list[Rule]) -> None:
        """Persist a new rule list (used by the web UI) and adopt it."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        self._path.write_text(dump_rules(rules), encoding="utf-8")
        self._rules = list(rules)
        try:
            self._mtime = self._path.stat().st_mtime
        except OSError:
            self._mtime = None
        logger.info("Saved %d mapping rule(s) to %s", len(rules), self._path)

    def resolve(self, *texts: str, account: str | None = None) -> tuple[str, str | None]:
        """Return (target_folder, matched_pattern). Falls back if nothing matches."""
        haystack = " ".join(t for t in texts if t).lower()
        for rule in self._rules:
            if rule.applies_to(account) and rule.matches(haystack):
                return rule.folder, rule.match
        return self._fallback_folder, None
