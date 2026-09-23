from __future__ import annotations

import logging
import os
import sys
import threading
import time

from .accounts import AccountStore
from .addresses import AddressStore
from .archiver import Archiver
from .archives import ArchiveStore
from .config import Config
from .legacy import LegacyEnv
from .mapping import RuleStore
from .migrate import migrate_rule_file, rules_settled, seed_from_legacy
from .pickups import PICKUP_INTERVAL, PickupStore
from .printers import PrinterStore
from .runtime import Runtime
from .scanning import PickupRunner
from .state import ProcessedStore, SettingsStore

logger = logging.getLogger("mail2nas")

# How often the supervisor notices that accounts were added, changed or
# removed in the web UI. Short enough to feel immediate, long enough to be
# free.
SUPERVISOR_INTERVAL = 5
# How often an archive that failed its write test is tried again.
ARCHIVE_RETRY = 60
# IMAP IDLE is waited on in short slices, so stopping a worker (because its
# settings changed) takes a few seconds instead of up to a whole interval.
IDLE_SLICE = 5
# RFC 2177: re-issue IDLE before 29 minutes, or the server may drop us.
MAX_IDLE = 29 * 60


def build_runtime(config: Config, environ=None) -> Runtime:
    """Open the database, bring an older installation up to date, wire it up."""
    settings = SettingsStore(config.state_db_path)
    # Before anything is written: the file holds IMAP and SMB passwords.
    _protect_state_file(config.state_db_path)
    printers = PrinterStore(config.state_db_path)
    runtime = Runtime(
        config,
        settings,
        AccountStore(config.state_db_path),
        ProcessedStore(config.state_db_path),
        RuleStore(config.state_db_path),
        printers=printers,
        addresses=AddressStore(config.state_db_path),
        archives=ArchiveStore(config.state_db_path),
        pickups=PickupStore(config.state_db_path),
    )
    seed_from_legacy(runtime, LegacyEnv.from_environ(environ))
    return runtime


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    runtime = build_runtime(config)

    if os.environ.get("WEB_ENABLED", "").strip().lower() in ("0", "false", "no", "off"):
        # The web UI is the only place left to configure anything, so it
        # cannot be switched off any more. Say so instead of silently ignoring.
        logger.warning("WEB_ENABLED=false is ignored - the web UI is where mail2nas is configured")

    # Imported here so the modules above stay importable without Flask.
    from . import web

    web.serve(runtime)

    options = runtime.options
    logger.info(
        "Starting mail2nas: mailboxes=%d archives=%d rules=%d printers=%d addresses=%d "
        "pickups=%d dry_run=%s",
        len(runtime.accounts.enabled()),
        len(runtime.archives.enabled()),
        runtime.rule_store.count(),
        len(runtime.printers.enabled()) if options.printing_enabled else 0,
        len(runtime.addresses.enabled()),
        len(runtime.pickups.enabled()),
        options.dry_run,
    )

    supervisor = Supervisor(runtime)
    try:
        supervisor.run()
    finally:
        supervisor.stop_all()
        runtime.store.close()
        runtime.storages.close()


def _protect_state_file(path: str) -> None:
    """The state database holds passwords, so nobody else may read it."""
    try:
        if not os.path.exists(path):
            open(path, "a").close()
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
        self.key = f"account:{account.id}"
        self._runtime = runtime
        self._stop = threading.Event()
        self._thread = threading.Thread(
            target=self._run, name=f"mail2nas-imap-{account.id}", daemon=True
        )

    def start(self) -> None:
        self._runtime.status.worker(self.key, self.account.name)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def is_alive(self) -> bool:
        return self._thread.is_alive()

    def _interval(self) -> int:
        return self._runtime.options.poll_interval

    def _run(self) -> None:
        runtime = self._runtime
        archiver = Archiver(
            lambda: runtime.options,
            runtime.mapping,
            runtime.store,
            runtime.storages,
            self.account,
            runtime.printing,
            runtime.addresses,
        )
        status = runtime.status
        label = f"{self.account.name} <{self.account.user}>"
        logger.info(
            "Account %s: watching %s on %s (%s mode)",
            label,
            self.account.folder,
            self.account.host,
            self.account.mode,
        )

        while not self._stop.is_set():
            status.set(self.key, "verbindet")
            try:
                client = archiver.connect()
            except Exception as exc:
                logger.exception(
                    "Account %s: IMAP connection failed, retrying in %ss", label, self._interval()
                )
                status.error(self.key, f"Verbindung fehlgeschlagen: {exc}")
                self._stop.wait(self._interval())
                continue

            try:
                if self.account.mode == "idle":
                    self._run_idle(archiver, client, label)
                else:
                    self._run_poll(archiver, client, label)
            except Exception as exc:
                logger.exception(
                    "Account %s: IMAP session failed, reconnecting in %ss", label, self._interval()
                )
                status.error(self.key, f"Sitzung abgebrochen: {exc}")
            finally:
                try:
                    client.logout()
                except Exception:
                    pass
            self._stop.wait(self._interval())

        status.set(self.key, "gestoppt")
        logger.info("Account %s: stopped", label)

    def _cycle(self, archiver: Archiver, client, label: str) -> None:
        count = archiver.run_once(client)
        status = self._runtime.status
        if count:
            logger.info("Account %s: processed %d message(s)", label, count)
            status.processed(self.key, count)
        status.set(self.key, "verbunden", "IDLE" if self.account.mode == "idle" else "Polling")

    def _run_poll(self, archiver: Archiver, client, label: str) -> None:
        while not self._stop.is_set():
            self._cycle(archiver, client, label)
            self._stop.wait(self._interval())

    def _run_idle(self, archiver: Archiver, client, label: str) -> None:
        self._cycle(archiver, client, label)
        while not self._stop.is_set():
            deadline = time.monotonic() + min(max(self._interval(), IDLE_SLICE), MAX_IDLE)
            client.idle()
            try:
                while not self._stop.is_set() and time.monotonic() < deadline:
                    if client.idle_check(timeout=IDLE_SLICE):
                        break
            finally:
                client.idle_done()
            if not self._stop.is_set():
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
            # Settings changed or the account is gone. The worker notices
            # within a few seconds (see IDLE_SLICE).
            if account is not None:
                logger.info("Account %s: configuration changed, restarting", account.name)
            worker.stop()
            del workers[account_id]
            if account is None:
                runtime.status.forget(f"account:{account_id}")
        elif not worker.is_alive():
            del workers[account_id]

    for account_id, account in wanted.items():
        if account_id not in workers:
            worker = factory(account)
            workers[account_id] = worker
            worker.start()

    return workers


class Supervisor:
    """Keeps the workers in line with what is configured in the UI.

    Nothing is started before the service is *ready*: an archive exists and
    passed its write test, and the rules of an older installation have been
    taken over. Filing mail before that would put it into a directory that
    may not be the share, or file it without its rules.
    """

    def __init__(self, runtime: Runtime, factory=None):
        self.runtime = runtime
        self.workers: dict[int, object] = {}
        self._factory = factory
        self._pickup = (
            PickupRunner(
                lambda: runtime.options,
                runtime.mapping,
                runtime.storages,
                runtime.pickups,
                printing=runtime.printing,
            )
            if runtime.pickups is not None
            else None
        )
        self._next_pickup = 0.0
        self._was_ready: bool | None = None

    # --- readiness -------------------------------------------------------------

    def check_archive(self) -> bool:
        """Write-test the default archive when it changed, or retry a failure."""
        runtime = self.runtime
        status = runtime.status.archive
        archive = runtime.default_archive()
        if archive is None:
            status.ok, status.detail, status.fingerprint = False, "Kein Archiv eingerichtet.", ()
            return False

        fingerprint = (archive.id, *archive.fingerprint())
        due = status.checked_at is None or (
            not status.ok and time.time() - status.checked_at >= ARCHIVE_RETRY
        )
        if fingerprint == status.fingerprint and not due:
            return bool(status.ok)

        status.fingerprint = fingerprint
        status.checked_at = time.time()
        try:
            runtime.storages.get(archive.key).check_writable()
        except BaseException as exc:  # noqa: BLE001 - SystemExit is how check_writable reports
            if isinstance(exc, KeyboardInterrupt):
                raise
            status.ok, status.detail = False, str(exc) or exc.__class__.__name__
            logger.error("Archive %r is not usable: %s", archive.name, status.detail)
            return False

        status.ok = True
        status.detail = f"{archive.location()} ist erreichbar und beschreibbar."
        if archive.backend == "local" and not os.path.ismount(archive.path):
            # Not fatal - a directory on the container's own disk is a valid
            # (if unusual) choice - but it is exactly what a missing bind mount
            # looks like, and then every attachment would vanish with the next
            # rebuild. So it is said loudly.
            status.detail += (
                " Achtung: das Verzeichnis ist kein Mountpoint - ist das Share "
                "wirklich eingebunden?"
            )
            logger.warning("Archive %r: %s is not a mount point", archive.name, archive.path)
        logger.info("Archive %r -> %s", archive.name, archive.location())
        return True

    def ready(self) -> bool:
        runtime = self.runtime
        if not self.check_archive():
            return False
        if not rules_settled(runtime.settings):
            migrate_rule_file(runtime.settings, runtime.rule_store, runtime.storage)
            runtime.mapping.reload()
        return rules_settled(runtime.settings)

    # --- the loop ----------------------------------------------------------------

    def step(self) -> None:
        runtime = self.runtime
        ready = self.ready()
        if ready != self._was_ready:
            if ready:
                logger.info("Ready - watching the configured mailboxes and folders")
            else:
                logger.warning(
                    "Not ready yet (%s) - nothing is archived until the web UI shows an "
                    "archive that works",
                    runtime.status.archive.detail or "rules not taken over yet",
                )
            self._was_ready = ready

        if not ready:
            self.stop_all()
            return

        reconcile(runtime, self.workers, self._factory)

        # Folders are walked on their own schedule: the supervisor wakes up
        # every few seconds to notice UI changes, which is far more often than
        # a share should be listed over SMB.
        if self._pickup is not None and time.monotonic() >= self._next_pickup:
            try:
                filed = self._pickup.run_once()
                if filed:
                    logger.info("Picked up %d document(s) from the watched folders", filed)
                    runtime.status.processed("pickups", filed)
            except Exception:  # noqa: BLE001 - never let this stop the supervisor
                logger.exception("Pickup cycle failed")
            self._next_pickup = time.monotonic() + PICKUP_INTERVAL

    def pickup_problems(self) -> dict[int, str]:
        return self._pickup.problems() if self._pickup is not None else {}

    def run(self) -> None:
        runtime = self.runtime
        runtime.supervisor = self
        while True:
            self.step()
            runtime.changed.wait(SUPERVISOR_INTERVAL)
            if runtime.changed.is_set():
                runtime.changed.clear()
                # An archive may have been edited: test it again right away.
                runtime.status.archive.checked_at = None

    def stop_all(self) -> None:
        for worker in self.workers.values():
            worker.stop()
        self.workers.clear()


if __name__ == "__main__":
    main()
