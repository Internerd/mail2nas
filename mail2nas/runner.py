from __future__ import annotations

import logging
import threading
import time

from .archiver import Archiver
from .config import Config
from .mapping import Mapping
from .printers import PrinterPickup
from .settings import Account, Printer, Settings
from .shares import ShareSet
from .state import ProcessedStore

logger = logging.getLogger(__name__)

# A folder a device writes into should be emptied promptly even when mail is
# only polled every few minutes: walking a directory is cheap, an IMAP session
# is not.
MAX_PICKUP_INTERVAL = 60


class AccountWorker(threading.Thread):
    """Runs one mail account's connect/process loop until asked to stop."""

    def __init__(
        self,
        config: Config,
        account: Account,
        mapping: Mapping,
        store: ProcessedStore,
        shares: ShareSet | None = None,
        printers: list[Printer] | None = None,
    ):
        super().__init__(name=f"mail2nas-{account.id}", daemon=True)
        self.config = config
        self.account = account
        self.archiver = Archiver(config, mapping, store, shares=shares, printers=printers)
        self._stop_event = threading.Event()
        self.last_error: str | None = None

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        logger.info(
            "[%s] starting: imap=%s folder=%s mode=%s",
            self.account.id,
            self.account.host,
            self.account.folder,
            self.account.mode,
        )
        while not self._stop_event.is_set():
            client = None
            try:
                client = self.archiver.connect()
                self.last_error = None
                if self.config.imap_mode == "idle":
                    self._loop_idle(client)
                else:
                    self._loop_poll(client)
            except Exception as exc:
                self.last_error = str(exc)
                logger.exception(
                    "[%s] session failed, retrying in %ss", self.account.id, self.config.poll_interval
                )
            finally:
                if client is not None:
                    try:
                        client.logout()
                    except Exception:
                        pass
            # Interruptible sleep, so a reload/shutdown does not wait it out.
            self._stop_event.wait(self.config.poll_interval)
        logger.info("[%s] stopped", self.account.id)

    def _process(self, client) -> None:
        count = self.archiver.run_once(client)
        if count:
            logger.info("[%s] processed %d message(s)", self.account.id, count)

    def _loop_poll(self, client) -> None:
        while not self._stop_event.is_set():
            self._process(client)
            self._stop_event.wait(self.config.poll_interval)

    def _loop_idle(self, client) -> None:
        self._process(client)
        timeout = self.config.poll_interval or 300
        while not self._stop_event.is_set():
            client.idle()
            try:
                client.idle_check(timeout=timeout)
            finally:
                client.idle_done()
            self._process(client)


class PrinterWorker(threading.Thread):
    """Empties the pickup folders of all devices that write to a share."""

    def __init__(self, pickup: PrinterPickup, interval: int):
        super().__init__(name="mail2nas-drucker", daemon=True)
        self.pickup = pickup
        self.interval = max(1, min(interval, MAX_PICKUP_INTERVAL))
        self._stop_event = threading.Event()
        self.last_error: str | None = None
        self.filed = 0

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        names = ", ".join(p.display_name() for p in self.pickup.settings.pickup_printers())
        logger.info("[drucker] watching pickup folders every %ss: %s", self.interval, names)
        while not self._stop_event.is_set():
            try:
                count = self.pickup.run_once()
                self.last_error = None
                if count:
                    self.filed += count
                    logger.info("[drucker] filed %d document(s)", count)
            except Exception as exc:
                self.last_error = str(exc)
                logger.exception("[drucker] pickup cycle failed")
            self._stop_event.wait(self.interval)
        logger.info("[drucker] stopped")


class Runner:
    """Owns one worker per enabled account and can restart them on changes."""

    def __init__(self, config: Config, settings: Settings, mapping: Mapping, store: ProcessedStore):
        self.config = config
        self.settings = settings
        self.mapping = mapping
        self.store = store
        self.shares = ShareSet.from_settings(settings, config.storage_root)
        self._workers: list[AccountWorker] = []
        self._printer_worker: PrinterWorker | None = None
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            self._start_locked()

    def _start_locked(self) -> None:
        printers = self.settings.mail_printers()
        accounts = self.settings.enabled_accounts()
        if not accounts:
            logger.warning("No enabled mail accounts configured - nothing to archive yet")
        for account in accounts:
            worker = AccountWorker(
                self.settings.config_for(self.config, account),
                account,
                self.mapping,
                self.store,
                shares=self.shares,
                printers=printers,
            )
            worker.start()
            self._workers.append(worker)

        if self.settings.pickup_printers():
            pickup = PrinterPickup(
                self.settings.config_common(self.config), self.settings, self.mapping, self.shares
            )
            self._printer_worker = PrinterWorker(pickup, self.settings.poll_interval)
            self._printer_worker.start()

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _stop_locked(self) -> None:
        workers: list[threading.Thread] = list(self._workers)
        if self._printer_worker is not None:
            workers.append(self._printer_worker)
        for worker in workers:
            worker.stop()
        for worker in workers:
            worker.join(timeout=10)
        self._workers = []
        self._printer_worker = None

    def reload(self, settings: Settings) -> None:
        """Apply changed settings by restarting the account workers."""
        with self._lock:
            logger.info("Applying changed settings - restarting workers")
            self._stop_locked()
            self.settings = settings
            self.shares = ShareSet.from_settings(settings, self.config.storage_root)
            self.mapping.set_fallback_folder(settings.fallback_folder)
            self.mapping.set_path(str(self.mapping_full_path(settings)))
            self._start_locked()

    def mapping_full_path(self, settings: Settings):
        from .filenames import safe_join

        # Anchored to STORAGE_ROOT, not to whichever share happens to be the
        # default one: the rules must stay where they are when shares change.
        return safe_join(self.config.storage_root, settings.mapping_path)

    def status(self) -> list[dict]:
        with self._lock:
            entries = [
                {
                    "id": w.account.id,
                    "label": w.account.display_name(),
                    "alive": w.is_alive(),
                    "error": w.last_error,
                }
                for w in self._workers
            ]
            if self._printer_worker is not None:
                entries.append(
                    {
                        "id": "drucker",
                        "label": "Drucker-Abholordner",
                        "alive": self._printer_worker.is_alive(),
                        "error": self._printer_worker.last_error,
                    }
                )
            return entries

    def wait(self) -> None:
        """Block the main thread while the workers do their thing."""
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            self.stop()
