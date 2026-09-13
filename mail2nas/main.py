from __future__ import annotations

import logging
import os
import sys
import threading
import time

from . import printing as printing_module
from . import storage as storage_module
from .accounts import AccountStore, seed_from_config
from .addresses import AddressStore
from .archiver import Archiver
from .archives import ArchiveStore
from .archives import seed_from_config as seed_archive_from_config
from .config import Config
from .pickups import PICKUP_INTERVAL, PickupStore
from .printers import PrinterStore
from .printers import seed_from_config as seed_printer_from_config
from .runtime import SETTING_MAPPING_PATH, Runtime
from .scanning import PickupRunner
from .state import ProcessedStore, SettingsStore

logger = logging.getLogger("mail2nas")

# How often the supervisor notices that accounts were added, changed or
# removed in the web UI. Short enough to feel immediate, long enough to be
# free.
SUPERVISOR_INTERVAL = 5


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    env_storage = storage_module.from_config(config)

    settings = SettingsStore(config.state_db_path)
    accounts = AccountStore(config.state_db_path)
    # Before seeding: from here on the file contains IMAP passwords.
    _protect_state_file(config.state_db_path)
    seed_from_config(accounts, settings, config)

    printers = PrinterStore(config.state_db_path)
    seed_printer_from_config(printers, settings, config)
    printing = printing_module.from_config(config, printers)
    addresses = AddressStore(config.state_db_path)
    archives = ArchiveStore(config.state_db_path)
    seed_archive_from_config(archives, settings, config)
    pickups = PickupStore(config.state_db_path)

    mapping_path = settings.get(SETTING_MAPPING_PATH) or config.mapping_path
    store = ProcessedStore(config.state_db_path)
    runtime = Runtime(
        config,
        env_storage,
        None,  # the mapping needs the default archive, which Runtime resolves
        store,
        settings,
        accounts,
        printers=printers,
        printing=printing,
        addresses=addresses,
        archives=archives,
        pickups=pickups,
    )
    # Fail fast: an unreachable share is otherwise indistinguishable from an
    # empty one, and attachments would land somewhere they silently vanish.
    runtime.storage.check_writable()
    runtime.attach_mapping(mapping_path)
    _check_other_archives(runtime)

    if config.web_enabled:
        # Imported lazily so the archiver still runs if the web dependencies
        # are missing (e.g. an older image built before the UI existed).
        from . import web

        web.serve(runtime)

    logger.info(
        "Starting mail2nas: archive=%s mapping=%s archives=%d printers=%d addresses=%d "
        "pickups=%d dry_run=%s",
        runtime.storage.description,
        mapping_path,
        len(archives.enabled()) or 1,
        len(printers.enabled()) if config.printing_enabled else 0,
        len(addresses.enabled()),
        len(pickups.enabled()),
        config.dry_run,
    )

    try:
        _supervise(runtime)
    finally:
        store.close()
        runtime.storages.close()
        env_storage.close()


def _check_other_archives(runtime: Runtime) -> None:
    """Report archives besides the default one, without refusing to start.

    The default archive is fatal when it is unreachable - nothing can be
    filed at all. A second NAS being down is different: everything else keeps
    working, and the mails meant for it are simply retried until it is back.
    """
    if runtime.archives is None:
        return
    default = runtime.archives.default()
    for archive in runtime.archives.enabled():
        if default is not None and archive.id == default.id:
            continue
        try:
            archive.to_storage().check_writable()
        except SystemExit as exc:
            logger.error("Archive %r is not usable: %s", archive.name, exc)
        except Exception as exc:  # noqa: BLE001 - never fail startup over a second archive
            logger.error("Archive %r is not usable: %s", archive.name, exc)
        else:
            logger.info("Archive %r -> %s", archive.name, archive.location())


def _protect_state_file(path: str) -> None:
    """The state database holds IMAP passwords, so nobody else may read it."""
    try:
        os.chmod(path, 0o600)
    except OSError as exc:
        logger.warning("Could not restrict permissions on %s (%s)", path, exc)


class _Worker:
    """One IMAP account, watched on its own thread.

    A thread per account rather than one loop over all of them: IMAP IDLE
    blocks, so a single loop would leave every other mailbox waiting for the
    first one's timeout.
    """

    def __init__(self, runtime: Runtime, account):
        self.account = account
        self.fingerprint = account.fingerprint()
        self._runtime = runtime
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name=f"mail2nas-imap-{account.id}", daemon=True
        )

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def is_alive(self) -> bool:
        return self._thread.is_alive()

    def _run(self) -> None:
        config = self._runtime.config
        archiver = Archiver(
            config,
            self._runtime.mapping,
            self._runtime.store,
            self._runtime.storage,
            self.account,
            self._runtime.printing,
            self._runtime.addresses,
            self._runtime.storages,
            lambda: self._runtime.blocked_extensions,
        )
        label = f"{self.account.name} <{self.account.user}>"
        logger.info(
            "Account %s: watching %s on %s (%s mode)",
            label,
            self.account.folder,
            self.account.host,
            self.account.mode,
        )

        while not self._stop.is_set():
            try:
                client = archiver.connect()
            except Exception:
                logger.exception(
                    "Account %s: IMAP connection failed, retrying in %ss",
                    label,
                    config.poll_interval,
                )
                self._stop.wait(config.poll_interval)
                continue

            try:
                if self.account.mode == "idle":
                    self._run_idle(archiver, client, label)
                else:
                    self._run_poll(archiver, client, label)
            except Exception:
                logger.exception(
                    "Account %s: IMAP session failed, reconnecting in %ss",
                    label,
                    config.poll_interval,
                )
            finally:
                try:
                    client.logout()
                except Exception:
                    pass
            self._stop.wait(config.poll_interval)

        logger.info("Account %s: stopped", label)

    def _cycle(self, archiver: Archiver, client, label: str) -> None:
        count = archiver.run_once(client)
        if count:
            logger.info("Account %s: processed %d message(s)", label, count)

    def _run_poll(self, archiver: Archiver, client, label: str) -> None:
        while not self._stop.is_set():
            self._cycle(archiver, client, label)
            self._stop.wait(self._runtime.config.poll_interval)

    def _run_idle(self, archiver: Archiver, client, label: str) -> None:
        self._cycle(archiver, client, label)
        idle_timeout = self._runtime.config.poll_interval or 300
        while not self._stop.is_set():
            client.idle()
            try:
                client.idle_check(timeout=idle_timeout)
            finally:
                client.idle_done()
            self._cycle(archiver, client, label)


def reconcile(runtime: Runtime, workers: dict, factory=None) -> dict:
    """Start, stop and restart workers so they match the configured accounts.

    Split out of the loop below so the decision - which worker survives a
    configuration change - can be tested without real IMAP connections.
    """
    factory = factory or (lambda account: _Worker(runtime, account))
    wanted = {account.id: account for account in runtime.accounts.enabled()}

    for account_id, worker in list(workers.items()):
        account = wanted.get(account_id)
        if account is None or account.fingerprint() != worker.fingerprint:
            # Settings changed or the account is gone. The worker notices at
            # the end of its current cycle, so a reconnect can lag by up to
            # one poll interval.
            if account is not None:
                logger.info("Account %s: configuration changed, restarting", account.name)
            worker.stop()
            del workers[account_id]
        elif not worker.is_alive():
            del workers[account_id]

    for account_id, account in wanted.items():
        if account_id not in workers:
            worker = factory(account)
            workers[account_id] = worker
            worker.start()

    return workers


def _make_pickup_runner(runtime: Runtime) -> PickupRunner | None:
    if runtime.pickups is None:
        return None
    return PickupRunner(
        runtime.config,
        runtime.mapping,
        runtime.storages,
        runtime.pickups,
        printing=runtime.printing,
        blocked_extensions=lambda: runtime.blocked_extensions,
        min_age_seconds=runtime.pickup_min_age,
    )


def _supervise(runtime: Runtime) -> None:
    """Keep one worker per enabled account, following changes made in the UI."""
    workers: dict[int, _Worker] = {}
    idle_warning_shown = False
    pickup = _make_pickup_runner(runtime)
    next_pickup = 0.0
    try:
        while True:
            reconcile(runtime, workers)

            # Folders are walked on their own schedule: the supervisor wakes
            # up every few seconds to notice UI changes, which is far more
            # often than a share should be listed over SMB.
            if pickup is not None and time.monotonic() >= next_pickup:
                pickup.min_age_seconds = runtime.pickup_min_age
                try:
                    filed = pickup.run_once()
                    if filed:
                        logger.info("Picked up %d document(s) from the watched folders", filed)
                except Exception:  # noqa: BLE001 - never let this stop the supervisor
                    logger.exception("Pickup cycle failed")
                next_pickup = time.monotonic() + PICKUP_INTERVAL

            if not workers and not idle_warning_shown:
                # Once, not on every pass - this loop runs every few seconds.
                logger.warning(
                    "No enabled IMAP account configured - nothing is being watched. "
                    "Add one in the web UI."
                )
            idle_warning_shown = bool(not workers)

            runtime.mapping_path_changed.wait(SUPERVISOR_INTERVAL)
            if runtime.mapping_path_changed.is_set():
                runtime.mapping_path_changed.clear()
                runtime.apply_mapping_path()
    finally:
        for worker in workers.values():
            worker.stop()


if __name__ == "__main__":
    main()
