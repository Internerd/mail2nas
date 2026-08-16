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
