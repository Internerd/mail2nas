from __future__ import annotations

import logging

import yaml

from .filenames import safe_relative_parts
from .storage import Storage

logger = logging.getLogger(__name__)


class Mapping:
    """Keyword -> target-subfolder mapping, reloaded on demand.

    The mapping file lives on the same share the attachments are archived
    to, so it can be edited by anyone with access to the share without
    touching the container/deployment. It is read through the storage
    backend, so it works the same whether the share is mounted or reached
    over SMB directly.
    """

    def __init__(self, storage: Storage, relative_path: str, fallback_folder: str):
        self._storage = storage
        self._path = storage.display(safe_relative_parts(relative_path))
        self._relative_path = relative_path
        self._fallback_folder = fallback_folder
        self._rules: list[tuple[str, str]] = []
        self._mtime: float | None = None
        self.reload(force=True)

    def reload(self, force: bool = False) -> None:
        try:
            mtime = self._storage.modified_time(self._relative_path)
        except FileNotFoundError:
            if force:
                logger.warning(
                    "Mapping file %s not found, all mail will go to the fallback folder", self._path
                )
                self._rules = []
                self._mtime = None
            return
        except Exception as exc:  # noqa: BLE001 - a dropped share must not kill the loop
            # With the SMB backend this is a network call, so it can fail for
            # reasons that have nothing to do with the file itself. Keep the
            # rules we already have; the next cycle tries again.
            logger.warning(
                "Could not check mapping file %s (%s) - keeping the previous %d rule(s)",
                self._path,
                exc,
                len(self._rules),
            )
            return

        if not force and self._mtime == mtime:
            return

        # The mapping file is edited by hand on a network share, so a malformed
        # or half-written version is a matter of when, not if. Keep serving the
        # last good rules instead of letting the exception escape: it would
        # propagate out of the IMAP loop and leave the service reconnecting in
        # a tight loop, archiving nothing at all until someone noticed.
        try:
            raw = yaml.safe_load(self._storage.read_text(self._relative_path)) or {}
            if not isinstance(raw, dict):
                raise ValueError("file must contain a mapping of keyword -> folder")
            rules = sorted(
                ((str(keyword), str(folder)) for keyword, folder in raw.items()),
                # Longest keyword first, so "Rechnungskorrektur" beats "RE".
                key=lambda kv: len(kv[0]),
                reverse=True,
            )
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

    def resolve(self, *texts: str) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword). Falls back if nothing matches."""
        haystack = " ".join(t for t in texts if t).lower()
        for keyword, folder in self._rules:
            if keyword.lower() in haystack:
                return folder, keyword
        return self._fallback_folder, None


# --- editing helpers (used by the web UI) ------------------------------------
#
# The mapping stays a YAML file on the share rather than moving into a
# database: the archiver already reloads it by mtime, it survives a broken
# web UI, and it remains editable by hand as a fallback. The web UI is the
# normal way to change it, not the only one - so anything written here has to
# stay in the format a human would write.

MAX_KEYWORD_LENGTH = 100


class MappingError(ValueError):
    """A rule the user tried to save is not usable."""


def load_rules(storage: Storage, relative_path: str) -> dict[str, str]:
    """Read the mapping file as an ordered keyword -> folder dict.

    A missing file is an empty mapping, not an error: that is the state right
    after installation, and the UI is exactly where it gets fixed.
    """
    try:
        raw = yaml.safe_load(storage.read_text(relative_path)) or {}
    except FileNotFoundError:
        return {}
    if not isinstance(raw, dict):
        raise MappingError(
            "Die Mapping-Datei enthaelt keine Stichwort/Ordner-Zuordnung und wird "
            "nicht ueberschrieben. Bitte pruefen oder umbenennen."
        )
    return {str(keyword): str(folder) for keyword, folder in raw.items()}


def save_rules(storage: Storage, relative_path: str, rules: dict[str, str]) -> None:
    """Write the mapping file back, sorted by keyword for a stable diff."""
    ordered = dict(sorted(rules.items(), key=lambda kv: kv[0].lower()))
    text = yaml.safe_dump(ordered, allow_unicode=True, default_flow_style=False, sort_keys=False)
    storage.write_text(relative_path, text)


def validate_keyword(keyword: str, existing: dict[str, str], replacing: str | None = None) -> str:
    """Check a keyword the user typed, returning the cleaned version."""
    keyword = keyword.strip()
    if not keyword:
        raise MappingError("Bitte ein Stichwort angeben.")
    if len(keyword) > MAX_KEYWORD_LENGTH:
        raise MappingError(f"Das Stichwort darf hoechstens {MAX_KEYWORD_LENGTH} Zeichen lang sein.")
    if "\n" in keyword or "\r" in keyword:
        raise MappingError("Das Stichwort darf keine Zeilenumbrueche enthalten.")
    # Matching is case-insensitive, so two rules differing only in case would
    # be indistinguishable - the second could never win.
    lowered = keyword.lower()
    for existing_keyword in existing:
        if existing_keyword == replacing:
            continue
        if existing_keyword.lower() == lowered:
            raise MappingError(f"Das Stichwort {existing_keyword!r} gibt es schon.")
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
