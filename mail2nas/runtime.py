"""The objects the archiver and the web UI both work on.

Settings that used to be environment-only can now be changed at runtime, so
something has to hold the live state and let one side tell the other that it
moved. That is all this is: a small container plus the two operations that
need coordinating.
"""
from __future__ import annotations

import logging
import threading

from .mapping import MappingError
from .filenames import safe_relative_parts

logger = logging.getLogger(__name__)

SETTING_MAPPING_PATH = "mapping_path"


class Runtime:
    """Shared handles, plus the mapping-file location that can move."""

    def __init__(self, config, storage, mapping, store, settings, accounts):
        self.config = config
        self.storage = storage
        self.mapping = mapping
        self.store = store
        self.settings = settings
        self.accounts = accounts
        # Set by the web UI, consumed by the supervisor loop: the archiver
        # threads must not read a half-changed path.
        self.mapping_path_changed = threading.Event()

    @property
    def mapping_path(self) -> str:
        """Where the rules live - the stored value wins over the .env one."""
        return self.settings.get(SETTING_MAPPING_PATH) or self.config.mapping_path

    def set_mapping_path(self, new_path: str, move_existing: bool = True) -> None:
        """Point the archiver at a different mapping file, optionally moving it.

        Moving is a copy followed by a delete rather than a rename: the
        storage backends deliberately expose no rename, and a copy that fails
        halfway leaves the original in place, which is the safer direction.
        """
        new_path = (new_path or "").strip().replace("\\", "/")
        try:
            parts = safe_relative_parts(new_path)
        except ValueError as exc:
            raise MappingError(f"Ungueltiger Pfad: {exc}") from None
        new_path = "/".join(parts)

        old_path = self.mapping_path
        if new_path == old_path:
            return

        if move_existing:
            try:
                content = self.storage.read_text(old_path)
            except FileNotFoundError:
                content = None
            if content is not None:
                self.storage.write_text(new_path, content)
                self.storage.remove_file(old_path)
                logger.info("Moved the mapping file from %s to %s", old_path, new_path)

        self.settings.set(SETTING_MAPPING_PATH, new_path)
        self.mapping.set_path(new_path)
        self.mapping_path_changed.set()

    def apply_mapping_path(self) -> None:
        """Re-point the shared Mapping if the stored path changed."""
        wanted = self.mapping_path
        if self.mapping.path != wanted:
            self.mapping.set_path(wanted)
