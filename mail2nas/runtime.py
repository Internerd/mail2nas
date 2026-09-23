"""The objects the archiver and the web UI both work on.

Everything is configured in the web UI while the service runs, so something
has to hold the live state: the stores, the current settings snapshot, the
open archive connections, and what each worker is doing right now. That is
this module - a container plus the few operations that need coordinating
between the UI thread and the workers.
"""
from __future__ import annotations

import logging
import threading
import time
from dataclasses import dataclass, field, replace

from .archives import NoArchiveError, StorageSet
from .backup import BackupStatus
from .mapping import Mapping, RuleStore
from .options import Options, OptionsStore
from .printing import PrintService, Spooler

logger = logging.getLogger(__name__)


@dataclass
class WorkerStatus:
    """What the overview page shows for one mailbox (or the pickup folders)."""

    label: str
    state: str = "startet"  # startet | verbunden | wartet | Fehler | gestoppt
    detail: str = ""
    last_ok: float | None = None
    last_error: str = ""
    last_error_at: float | None = None
    processed: int = 0
    # Since when it has been failing without a success in between; what the
    # notifications measure their delay against.
    failing_since: float | None = None


@dataclass
class ArchiveStatus:
    ok: bool | None = None  # None = not checked yet
    detail: str = ""
    checked_at: float | None = None
    fingerprint: tuple = field(default_factory=tuple)
    failing_since: float | None = None


class StatusBoard:
    """Thread-safe notes from the workers, read by the web UI.

    Without it the only way to see whether a mailbox works would be the
    container log - and the whole point of configuring everything in the
    browser is not having to open a shell.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._workers: dict[str, WorkerStatus] = {}
        self.archive = ArchiveStatus()
        self.started_at = time.time()

    def worker(self, key: str, label: str) -> None:
        with self._lock:
            self._workers.setdefault(key, WorkerStatus(label=label))
            self._workers[key].label = label

    def set(self, key: str, state: str, detail: str = "") -> None:
        with self._lock:
            status = self._workers.setdefault(key, WorkerStatus(label=key))
            status.state = state
            status.detail = detail
            if state in ("verbunden", "wartet"):
                status.last_ok = time.time()
                status.failing_since = None

    def error(self, key: str, message: str) -> None:
        with self._lock:
            status = self._workers.setdefault(key, WorkerStatus(label=key))
            status.state = "Fehler"
            status.last_error = message
            status.last_error_at = time.time()
            if status.failing_since is None:
                status.failing_since = status.last_error_at

    def processed(self, key: str, count: int) -> None:
        with self._lock:
            status = self._workers.setdefault(key, WorkerStatus(label=key))
            status.processed += count
            status.last_ok = time.time()
            status.failing_since = None

    def forget(self, key: str) -> None:
        with self._lock:
            self._workers.pop(key, None)

    def workers(self) -> dict[str, WorkerStatus]:
        with self._lock:
            return {key: replace(value) for key, value in self._workers.items()}


class Runtime:
    """Shared handles, plus the current settings snapshot."""

    def __init__(
        self,
        config,
        settings,
        accounts,
        store,
        rules: RuleStore,
        *,
        printers=None,
        printing: PrintService | None = None,
        addresses=None,
        archives=None,
        pickups=None,
        journal=None,
        logs=None,
    ):
        self.config = config
        self.settings = settings  # the key/value store
        self.options_store = OptionsStore(settings)
        self._options: Options | None = None
        self._options_lock = threading.Lock()

        self.accounts = accounts
        self.store = store
        self.rule_store = rules
        self.mapping = Mapping(rules, lambda: self.options.fallback_folder)
        self.printers = printers
        self.addresses = addresses
        self.archives = archives
        self.pickups = pickups
        self.storages = StorageSet(archives, None)
        if printing is None and printers is not None:
            printing = PrintService(
                printers, Spooler(lp_binary=config.lp_binary, options=lambda: self.options)
            )
        self.printing = printing
        self.status = StatusBoard()
        # The processing journal and the stored log (see journal.py). Optional,
        # so a test can build a Runtime without them.
        self.journal = journal
        self.logs = logs
        self.backup_status = BackupStatus()
        # Set by the supervisor: the notifier, for the "test mail" button and
        # the overview page.
        self.notifier = None
        # Set by the web UI after a change the supervisor should act on right
        # away (an archive was added, the settings were saved) instead of at
        # its next regular pass.
        self.changed = threading.Event()
        # The running Supervisor, if any - the overview page asks it about
        # pickup folders with problems.
        self.supervisor = None

    # --- settings -------------------------------------------------------------

    @property
    def options(self) -> Options:
        """The current settings - one immutable snapshot, cheap to ask for."""
        with self._options_lock:
            if self._options is None:
                self._options = self.options_store.load()
            return self._options

    def set_options(self, options: Options) -> None:
        self.options_store.save(options)
        with self._options_lock:
            self._options = options
        self.changed.set()

    def invalidate_options(self) -> None:
        with self._options_lock:
            self._options = None

    @property
    def blocked_extensions(self) -> frozenset[str]:
        return self.options.blocked_extensions

    @property
    def pickup_min_age(self) -> int:
        return self.options.pickup_min_age

    # --- archives -------------------------------------------------------------

    @property
    def storage(self):
        """The default archive, or None while none is configured."""
        try:
            return self.storages.default()
        except NoArchiveError:
            return None

    def after_restore(self) -> None:
        """A restored database may come from an older version and holds
        different settings: bring its tables up to date and drop every cached
        view of the old one."""
        from .accounts import AccountStore
        from .addresses import AddressStore
        from .archives import ArchiveStore
        from .journal import Journal, LogStore
        from .pickups import PickupStore
        from .printers import PrinterStore
        from .state import ProcessedStore, SettingsStore

        path = self.config.state_db_path
        for store in (SettingsStore, AccountStore, ArchiveStore, PrinterStore, AddressStore,
                      PickupStore, RuleStore, Journal, LogStore):
            store(path)
        ProcessedStore(path).close()
        self.invalidate_options()
        self.mapping.reload()
        self.status.archive.checked_at = None
        self.status.archive.fingerprint = ()
        self.changed.set()

    def default_archive(self):
        return self.archives.default() if self.archives is not None else None
