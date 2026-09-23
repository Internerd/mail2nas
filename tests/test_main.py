from __future__ import annotations

import pytest

from mail2nas.main import reconcile
from tests.test_archiver import _make_runtime


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
    return _make_runtime(tmp_path)


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


# --- readiness: nothing is filed before there is somewhere to file to -----------


def _supervisor(runtime):
    from mail2nas.main import Supervisor

    return Supervisor(runtime, FakeWorker)


def test_without_an_archive_no_mailbox_is_watched(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)
    _add(runtime)
    supervisor = _supervisor(runtime)

    supervisor.step()

    assert supervisor.workers == {}
    assert runtime.status.archive.ok is False
    assert "Kein Archiv" in runtime.status.archive.detail


def test_an_archive_that_fails_its_write_test_stops_the_workers(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)
    runtime.archives.add(name="Weg", backend="local", path=str(tmp_path / "gibt-es-nicht"))
    _add(runtime)
    supervisor = _supervisor(runtime)

    supervisor.step()

    assert supervisor.workers == {}
    assert runtime.status.archive.ok is False


def test_once_the_archive_works_the_mailboxes_are_watched(runtime):
    _add(runtime)
    supervisor = _supervisor(runtime)

    supervisor.step()

    assert len(supervisor.workers) == 1
    assert runtime.status.archive.ok is True


def test_an_archive_that_is_not_a_mount_point_is_flagged(runtime):
    """A missing bind mount looks exactly like this - so it is said loudly."""
    _supervisor(runtime).step()

    assert "kein Mountpoint" in runtime.status.archive.detail


def test_the_old_rule_file_is_taken_over_before_the_first_mail(tmp_path):
    (tmp_path / "mapping.yaml").write_text("RE: rechnungen\nLieferschein: lieferscheine\n",
                                           encoding="utf-8")
    runtime = _make_runtime(tmp_path)
    _add(runtime)

    _supervisor(runtime).step()

    assert [r.keyword for r in runtime.mapping.rules] == ["Lieferschein", "RE"]
    assert not (tmp_path / "mapping.yaml").exists()
    assert (tmp_path / "mapping.yaml.migriert").exists()


def test_the_rule_file_is_found_where_the_old_env_said(tmp_path):
    (tmp_path / "config").mkdir()
    (tmp_path / "config" / "regeln.yaml").write_text("RE: rechnungen\n", encoding="utf-8")
    runtime = _make_runtime(tmp_path, environ={"MAPPING_PATH": "config/regeln.yaml"})

    _supervisor(runtime).step()

    assert [r.keyword for r in runtime.mapping.rules] == ["RE"]


def test_a_broken_rule_file_is_left_alone_and_explained(tmp_path):
    (tmp_path / "mapping.yaml").write_text("rules: [kaputt", encoding="utf-8")
    runtime = _make_runtime(tmp_path)

    _supervisor(runtime).step()

    assert (tmp_path / "mapping.yaml").exists()
    from mail2nas.migrate import SETTING_RULES_NOTE

    assert "nicht uebernommen" in runtime.settings.get(SETTING_RULES_NOTE)


def test_rules_already_in_the_database_are_not_overwritten(tmp_path):
    from mail2nas.mapping import Rule

    (tmp_path / "mapping.yaml").write_text("ALT: alt\n", encoding="utf-8")
    runtime = _make_runtime(tmp_path)
    runtime.mapping.save([Rule.create("NEU", "neu")])

    _supervisor(runtime).step()

    assert [r.keyword for r in runtime.mapping.rules] == ["NEU"]


# --- IDLE reacts to a stop within seconds --------------------------------------


class _IdleClient:
    def __init__(self):
        self.idle_calls = 0

    def idle(self):
        self.idle_calls += 1

    def idle_check(self, timeout):
        import time

        time.sleep(0.01)
        return []

    def idle_done(self):
        pass


def test_a_worker_in_idle_stops_without_waiting_for_the_interval(runtime, monkeypatch):
    import threading
    import time

    from mail2nas import main as main_module

    monkeypatch.setattr(main_module, "IDLE_SLICE", 0.05)
    account_id = _add(runtime, mode="idle")
    worker = main_module._Worker(runtime, runtime.accounts.get(account_id))

    class _Archiver:
        def run_once(self, client):
            return 0

    thread = threading.Thread(
        target=worker._run_idle, args=(_Archiver(), _IdleClient(), "test"), daemon=True
    )
    thread.start()
    time.sleep(0.1)
    started = time.monotonic()
    worker.stop()
    thread.join(timeout=2)

    assert not thread.is_alive()
    assert time.monotonic() - started < 1  # not the 300 s poll interval
