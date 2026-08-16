from __future__ import annotations

import logging
import threading
import time

from .archiver import Archiver
from .config import Config
from .mapping import Mapping
from .settings import Account, Settings
from .state import ProcessedStore

logger = logging.getLogger(__name__)


class AccountWorker(threading.Thread):
    """Runs one mail account's connect/process loop until asked to stop."""

    def __init__(self, config: Config, account: Account, mapping: Mapping, store: ProcessedStore):
        super().__init__(name=f"mail2nas-{account.id}", daemon=True)
        self.config = config
        self.account = account
        self.archiver = Archiver(config, mapping, store)
        self._stop = threading.Event()
        self.last_error: str | None = None

    def stop(self) -> None:
        self._stop.set()

    def run(self) -> None:
        logger.info(
            "[%s] starting: imap=%s folder=%s mode=%s",
            self.account.id,
            self.account.host,
            self.account.folder,
            self.account.mode,
        )
        while not self._stop.is_set():
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
            self._stop.wait(self.config.poll_interval)
        logger.info("[%s] stopped", self.account.id)

    def _process(self, client) -> None:
        count = self.archiver.run_once(client)
        if count:
            logger.info("[%s] processed %d message(s)", self.account.id, count)

    def _loop_poll(self, client) -> None:
        while not self._stop.is_set():
            self._process(client)
            self._stop.wait(self.config.poll_interval)

    def _loop_idle(self, client) -> None:
        self._process(client)
        timeout = self.config.poll_interval or 300
        while not self._stop.is_set():
            client.idle()
            try:
                client.idle_check(timeout=timeout)
            finally:
                client.idle_done()
            self._process(client)


class Runner:
    """Owns one worker per enabled account and can restart them on changes."""

    def __init__(self, config: Config, settings: Settings, mapping: Mapping, store: ProcessedStore):
        self.config = config
        self.settings = settings
        self.mapping = mapping
        self.store = store
        self._workers: list[AccountWorker] = []
        self._lock = threading.Lock()

    def start(self) -> None:
        with self._lock:
            self._start_locked()

    def _start_locked(self) -> None:
        accounts = self.settings.enabled_accounts()
        if not accounts:
            logger.warning("No enabled mail accounts configured - nothing to archive yet")
        for account in accounts:
            worker = AccountWorker(
                self.settings.config_for(self.config, account), account, self.mapping, self.store
            )
            worker.start()
            self._workers.append(worker)

    def stop(self) -> None:
        with self._lock:
            self._stop_locked()

    def _stop_locked(self) -> None:
        for worker in self._workers:
            worker.stop()
        for worker in self._workers:
            worker.join(timeout=10)
        self._workers = []

    def reload(self, settings: Settings) -> None:
        """Apply changed settings by restarting the account workers."""
        with self._lock:
            logger.info("Applying changed settings - restarting account workers")
            self._stop_locked()
            self.settings = settings
            self.mapping.set_path(str(self.mapping_full_path(settings)))
            self._start_locked()

    def mapping_full_path(self, settings: Settings):
        from .filenames import safe_join

        return safe_join(self.config.storage_root, settings.mapping_path)

    def status(self) -> list[dict]:
        with self._lock:
            return [
                {
                    "id": w.account.id,
                    "label": w.account.display_name(),
                    "alive": w.is_alive(),
                    "error": w.last_error,
                }
                for w in self._workers
            ]

    def wait(self) -> None:
        """Block the main thread while the workers do their thing."""
        try:
            while True:
                time.sleep(3600)
        except KeyboardInterrupt:
            self.stop()
