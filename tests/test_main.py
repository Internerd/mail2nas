from __future__ import annotations

import pytest

from mail2nas.accounts import AccountStore
from mail2nas.main import reconcile
from mail2nas.mapping import Mapping
from mail2nas.runtime import Runtime
from mail2nas.state import ProcessedStore, SettingsStore
from mail2nas.storage import LocalStorage
from tests.test_archiver import _make_config


class FakeWorker:
    """Stands in for a real IMAP worker thread."""

    def __init__(self, account):
        self.account = account
        self.fingerprint = account.fingerprint()
        self.started = False
        self.stopped = False

    def start(self):
        self.started = True

    def stop(self):
        self.stopped = True

    def is_alive(self):
        return self.started and not self.stopped


@pytest.fixture
def runtime(tmp_path):
    config = _make_config(tmp_path)
    storage = LocalStorage(config.storage_root)
    return Runtime(
        config,
        storage,
        Mapping(storage, config.mapping_path, config.fallback_folder),
        ProcessedStore(config.state_db_path),
        SettingsStore(config.state_db_path),
        AccountStore(config.state_db_path),
    )


def _add(runtime, **fields):
    defaults = dict(name="A", host="imap.example.com", user="u", password="p")
    defaults.update(fields)
    return runtime.accounts.add(**defaults)


def test_one_worker_is_started_per_enabled_account(runtime):
    _add(runtime, name="Eins")
    _add(runtime, name="Zwei")

    workers = reconcile(runtime, {}, FakeWorker)

    assert len(workers) == 2
    assert all(worker.started for worker in workers.values())


def test_disabled_accounts_get_no_worker(runtime):
    _add(runtime, name="Aus", enabled=False)

    assert reconcile(runtime, {}, FakeWorker) == {}


def test_an_unchanged_account_keeps_its_worker(runtime):
    """A reconnect on every pass would mean reconnecting every few seconds."""
    _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = next(iter(workers.values()))

    reconcile(runtime, workers, FakeWorker)

    assert next(iter(workers.values())) is first
    assert not first.stopped


def test_changing_the_password_restarts_the_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.update(account_id, password="neu")
    reconcile(runtime, workers, FakeWorker)

    assert first.stopped
    assert workers[account_id] is not first


def test_renaming_an_account_does_not_restart_the_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.update(account_id, name="Neuer Name")
    reconcile(runtime, workers, FakeWorker)

    assert not first.stopped
    assert workers[account_id] is first


def test_deleting_an_account_stops_its_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    first = workers[account_id]

    runtime.accounts.delete(account_id)
    reconcile(runtime, workers, FakeWorker)

    assert first.stopped
    assert workers == {}


def test_disabling_an_account_stops_its_worker(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)

    runtime.accounts.update(account_id, enabled=False)
    reconcile(runtime, workers, FakeWorker)

    assert workers == {}


def test_a_dead_worker_is_replaced(runtime):
    account_id = _add(runtime)
    workers = reconcile(runtime, {}, FakeWorker)
    workers[account_id].stopped = True

    reconcile(runtime, workers, FakeWorker)

    assert workers[account_id].is_alive()
