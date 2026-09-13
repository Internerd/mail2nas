from __future__ import annotations

import dataclasses
import os
import time
from pathlib import Path

from mail2nas.mapping import Mapping, Rule
from mail2nas.runner import Runner
from mail2nas.settings import Printer, Settings, Share
from mail2nas.state import ProcessedStore
from tests.test_archiver import _make_config


def _wait_for(predicate, timeout: float = 5.0) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def _runner(tmp_path, **settings_overrides):
    """A Runner with no mail accounts, so only the pickup side is exercised."""
    nas1 = tmp_path / "nas1"
    nas2 = tmp_path / "nas2"
    data = tmp_path / "data"
    for directory in (nas1, nas2, data):
        directory.mkdir(exist_ok=True)

    config = _make_config(nas1, storage_root=str(nas1), state_db_path=str(data / "state.db"))
    mapping = Mapping(str(nas1 / "mapping.yaml"), "unsorted")
    mapping.save([Rule(match="Rechnung", folder="rechnungen")])
    settings = Settings(
        shares=[Share(id="nas1", path=str(nas1)), Share(id="nas2", path=str(nas2))],
        printer_min_age_seconds=0,
        poll_interval=1,
        **settings_overrides,
    )
    store = ProcessedStore(config.state_db_path)
    return Runner(config, settings, mapping, store), nas1, nas2


def _drop(directory: Path, name: str) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(b"scan")
    stamp = time.time() - 60
    os.utime(path, (stamp, stamp))
    return path


def test_pickup_worker_files_a_scan_end_to_end(tmp_path):
    runner, nas1, nas2 = _runner(
        tmp_path,
        printers=[
            Printer(id="kopierer", label="Kopierer", source_share="nas1", source_folder="scans",
                    target_share="nas2", target_folder="eingang")
        ],
    )
    _drop(nas1 / "scans", "scan.pdf")

    runner.start()
    try:
        assert _wait_for(lambda: list((nas2 / "eingang").glob("*")))
    finally:
        runner.stop()

    assert not (nas1 / "scans" / "scan.pdf").exists()


def test_pickup_worker_applies_the_keyword_rules(tmp_path):
    runner, nas1, _ = _runner(
        tmp_path, printers=[Printer(id="kopierer", source_folder="scans")]
    )
    _drop(nas1 / "scans", "Rechnung_1.pdf")

    runner.start()
    try:
        assert _wait_for(lambda: list((nas1 / "rechnungen").glob("*")))
    finally:
        runner.stop()


def test_no_pickup_worker_without_a_folder_printer(tmp_path):
    runner, _, _ = _runner(tmp_path, printers=[Printer(id="nur-mail", sender="scan@x.de")])

    runner.start()
    try:
        assert runner.status() == []
    finally:
        runner.stop()


def test_status_reports_the_pickup_worker(tmp_path):
    runner, _, _ = _runner(tmp_path, printers=[Printer(id="kopierer", source_folder="scans")])

    runner.start()
    try:
        assert [s["id"] for s in runner.status()] == ["drucker"]
        assert runner.status()[0]["alive"] is True
    finally:
        runner.stop()


def test_reload_picks_up_a_new_printer_without_a_restart(tmp_path):
    runner, nas1, _ = _runner(tmp_path)
    runner.start()
    try:
        assert runner.status() == []

        runner.reload(
            dataclasses.replace(
                runner.settings,
                printers=[Printer(id="neu", source_folder="scans", target_folder="eingang")],
            )
        )
        _drop(nas1 / "scans", "scan.pdf")

        assert _wait_for(lambda: list((nas1 / "eingang").glob("*")))
    finally:
        runner.stop()


def test_reload_applies_a_changed_fallback_folder(tmp_path):
    runner, nas1, _ = _runner(tmp_path, printers=[Printer(id="kopierer", source_folder="scans")])
    runner.start()
    try:
        runner.reload(dataclasses.replace(runner.settings, fallback_folder="sonstiges"))
        _drop(nas1 / "scans", "ohne-stichwort.pdf")

        assert _wait_for(lambda: list((nas1 / "sonstiges").glob("*")))
    finally:
        runner.stop()


def test_reload_adopts_a_new_share(tmp_path):
    runner, nas1, _ = _runner(
        tmp_path, printers=[Printer(id="kopierer", source_folder="scans", target_share="nas3",
                                    target_folder="eingang")]
    )
    nas3 = tmp_path / "nas3"
    nas3.mkdir()
    runner.start()
    try:
        runner.reload(
            dataclasses.replace(
                runner.settings,
                shares=list(runner.settings.shares) + [Share(id="nas3", path=str(nas3))],
            )
        )
        _drop(nas1 / "scans", "scan.pdf")

        assert _wait_for(lambda: list((nas3 / "eingang").glob("*")))
    finally:
        runner.stop()


def test_stop_ends_the_pickup_worker(tmp_path):
    runner, _, _ = _runner(tmp_path, printers=[Printer(id="kopierer", source_folder="scans")])
    runner.start()
    worker = runner._printer_worker

    runner.stop()

    assert _wait_for(lambda: not worker.is_alive())
    assert runner.status() == []
