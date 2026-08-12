from __future__ import annotations

import logging
from pathlib import Path

import yaml

logger = logging.getLogger(__name__)


class Mapping:
    """Keyword -> target-subfolder mapping, reloaded from disk on demand.

    The mapping file is expected to live on the same SMB share the
    attachments are archived to, so it can be edited by anyone with
    access to the share without touching the container/deployment.
    """

    def __init__(self, path: str, fallback_folder: str):
        self._path = Path(path)
        self._fallback_folder = fallback_folder
        self._rules: list[tuple[str, str]] = []
        self._mtime: float | None = None
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

        with self._path.open("r", encoding="utf-8") as fh:
            raw = yaml.safe_load(fh) or {}

        if not isinstance(raw, dict):
            raise ValueError(f"Mapping file {self._path} must contain a mapping of keyword -> folder")

        # Longest keyword first, so "Rechnungskorrektur" is checked before "RE".
        self._rules = sorted(
            ((str(keyword), str(folder)) for keyword, folder in raw.items()),
            key=lambda kv: len(kv[0]),
            reverse=True,
        )
        self._mtime = mtime
        logger.info("Loaded %d mapping rule(s) from %s", len(self._rules), self._path)

    def resolve(self, *texts: str) -> tuple[str, str | None]:
        """Return (target_folder, matched_keyword). Falls back if nothing matches."""
        haystack = " ".join(t for t in texts if t).lower()
        for keyword, folder in self._rules:
            if keyword.lower() in haystack:
                return folder, keyword
        return self._fallback_folder, None
