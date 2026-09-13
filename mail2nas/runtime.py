"""The objects the archiver and the web UI both work on.

Settings that used to be environment-only can now be changed at runtime, so
something has to hold the live state and let one side tell the other that it
moved. That is all this is: a small container plus the two operations that
need coordinating.
"""
from __future__ import annotations

import logging
import threading

from .archives import StorageSet
from .config import parse_extension_list
from .filenames import safe_relative_parts
from .mapping import Mapping, MappingError

logger = logging.getLogger(__name__)

SETTING_MAPPING_PATH = "mapping_path"
SETTING_BLOCKED_EXTENSIONS = "blocked_extensions"
SETTING_PICKUP_MIN_AGE = "pickup_min_age_seconds"

# How long a file in a pickup folder has to have been untouched before it is
# treated as finished. Long enough for a slow scan over SMB, short enough that
# nobody waits for their document.
DEFAULT_PICKUP_MIN_AGE = 20


class Runtime:
    """Shared handles, plus the mapping-file location that can move."""

    def __init__(
        self,
        config,
        storage,
        mapping,
        store,
        settings,
        accounts,
        printers=None,
        printing=None,
        addresses=None,
        archives=None,
        pickups=None,
    ):
        self.config = config
        # The archive described by the .env. It stays the fallback for an
        # installation that has not (yet) configured any archive of its own.
        self.env_storage = storage
        self.mapping = mapping
        self.store = store
        self.settings = settings
        self.accounts = accounts
        # Optional so a caller that does not care about printing (tests, and
        # the archiver before printers existed) can leave them out.
        self.printers = printers
        self.printing = printing
        self.addresses = addresses
        self.archives = archives
        self.pickups = pickups
        self.storages = StorageSet(archives, storage)
        # Set by the web UI, consumed by the supervisor loop: the archiver
        # threads must not read a half-changed path.
        self.mapping_path_changed = threading.Event()

    def attach_mapping(self, relative_path: str) -> Mapping:
        """Create the rule-file view, once the default archive is known.

        The mapping lives on the default archive, which only exists after the
        archive store has been read - so it is set here rather than passed in.
        """
        self.mapping = Mapping(self.storage, relative_path, self.config.fallback_folder)
        return self.mapping

    @property
    def storage(self):
        """The default archive - where the mapping file and anything without
        its own archive lives."""
        return self.storages.default()

    @property
    def blocked_extensions(self) -> frozenset[str]:
        """The quarantined file extensions, as edited in the web UI.

        The .env value is only the starting point: it seeds the stored list on
        first start, and is used as long as nothing has been stored.
        """
        raw = self.settings.get(SETTING_BLOCKED_EXTENSIONS)
        if raw is None:
            return self.config.blocked_extensions
        return parse_extension_list(raw)

    def set_blocked_extensions(self, raw: str) -> frozenset[str]:
        """Store a new list; takes effect on the next message, no restart."""
        extensions = parse_extension_list(raw)
        self.settings.set(SETTING_BLOCKED_EXTENSIONS, ",".join(sorted(extensions)))
        return extensions

    @property
    def pickup_min_age(self) -> int:
        raw = self.settings.get(SETTING_PICKUP_MIN_AGE)
        try:
            return max(0, int(raw)) if raw is not None else DEFAULT_PICKUP_MIN_AGE
        except (TypeError, ValueError):
            return DEFAULT_PICKUP_MIN_AGE

    def set_pickup_min_age(self, seconds) -> int:
        value = max(0, int(seconds))
        self.settings.set(SETTING_PICKUP_MIN_AGE, str(value))
        return value

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
        """Re-point the shared Mapping if the path or the default archive moved.

        Both can change while the service runs: the path from the mapping
        form, the archive from someone editing the first archive's password.
        """
        self.mapping.set_storage(self.storage)
        wanted = self.mapping_path
        if self.mapping.path != wanted:
            self.mapping.set_path(wanted)
