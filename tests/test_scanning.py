from __future__ import annotations

import os
import time
from pathlib import Path

import pytest

from mail2nas.archives import ArchiveStore, StorageSet
from mail2nas.config import parse_extension_list
from dataclasses import replace

from mail2nas.mapping import Mapping, Rule, RuleStore
from mail2nas.pickups import PickupStore
from mail2nas.printers import PrinterStore
from mail2nas.printing import PrintService
from mail2nas.scanning import PickupRunner
from tests.test_archiver import RecordingSpooler, _make_options


def _env(tmp_path, rules=None, **option_overrides):
    """A runner over <tmp_path> as the default archive, plus a second one."""
    second = tmp_path / "nas2"
    second.mkdir(exist_ok=True)

    archives = ArchiveStore(str(tmp_path / "state.db"))
    archives.add(name="Haupt", backend="local", path=str(tmp_path))
    second_id = archives.add(name="NAS 2", backend="local", path=str(second))
    storages = StorageSet(archives)

    store = RuleStore(str(tmp_path / "state.db"))
    if rules:
        store.save(rules)
    mapping = Mapping(store)

    pickups = PickupStore(str(tmp_path / "state.db"))
    options = _make_options(pickup_min_age=0, **option_overrides)
    runner = PickupRunner(options, mapping, storages, pickups)
    return runner, pickups, second, str(second_id)


def _drop(directory: Path, name: str, content: bytes = b"scan", age: int = 60) -> Path:
    """Write a file into a pickup folder, pretending it finished `age` ago."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(content)
    stamp = time.time() - age
    os.utime(path, (stamp, stamp))
    return path


# --- the basic move -----------------------------------------------------------


def test_a_ready_file_is_moved_into_the_target_folder(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", "SKM_C250i.pdf")

    assert runner.run_once() == 1

    assert not source.exists()  # the folder is an outbox, not an archive
    filed = list((tmp_path / "eingang").glob("*"))
    assert len(filed) == 1
    assert filed[0].read_bytes() == b"scan"


def test_the_name_gets_the_date_and_the_folder_it_came_from(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "scan.pdf")

    runner.run_once()

    name = next((tmp_path / "eingang").glob("*")).name
    assert name.endswith("_Kopierer_scan.pdf")
    assert name[:4].isdigit()


def test_subfolders_are_walked(tmp_path):
    """Devices create one folder per user or scan profile."""
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans" / "anna", "a.pdf")
    _drop(tmp_path / "scans" / "bert", "b.pdf")

    assert runner.run_once() == 2
    assert len(list((tmp_path / "eingang").glob("*"))) == 2


def test_two_scans_of_the_same_name_do_not_overwrite_each_other(tmp_path):
    runner, pickups, _, _ = _env(tmp_path, filename_prefix="none")
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "scan.pdf", b"erster")
    runner.run_once()
    _drop(tmp_path / "scans", "scan.pdf", b"zweiter")
    runner.run_once()

    assert sorted(p.read_bytes() for p in (tmp_path / "eingang").glob("*")) == [
        b"erster",
        b"zweiter",
    ]


# --- what is not ready --------------------------------------------------------


def test_a_file_still_being_written_is_left_alone(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    runner._options = replace(runner.options, pickup_min_age=30)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", "halb.pdf", age=0)

    assert runner.run_once() == 0
    assert source.exists()


@pytest.mark.parametrize("name", ["scan.pdf.tmp", "scan.PART", "scan.crdownload", ".versteckt.pdf"])
def test_half_written_or_hidden_files_are_ignored(tmp_path, name):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", name)

    assert runner.run_once() == 0
    assert source.exists()


def test_an_empty_file_is_ignored(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "leer.pdf", b"")

    assert runner.run_once() == 0


def test_a_folder_that_does_not_exist_yet_is_created(tmp_path, caplog):
    """The device has to be able to write there - so make it, and say so once."""
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")

    with caplog.at_level("WARNING"):
        assert runner.run_once() == 0
        assert runner.run_once() == 0

    assert (tmp_path / "scans").is_dir()
    warnings = [r for r in caplog.records if r.name == "mail2nas.scanning"]
    assert len(warnings) == 1


def test_a_disabled_folder_is_not_touched(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang", enabled=False)
    source = _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 0
    assert source.exists()


def test_dry_run_moves_nothing(tmp_path):
    runner, pickups, _, _ = _env(tmp_path, dry_run=True)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    source = _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 0
    assert source.exists()


# --- where the document goes ---------------------------------------------------


def test_without_a_fixed_target_the_keyword_rules_decide(tmp_path):
    runner, pickups, _, _ = _env(
        tmp_path, rules=[Rule.create("Rechnung", "rechnungen")]
    )
    pickups.add(name="Kopierer", folder="scans")
    _drop(tmp_path / "scans", "Rechnung_4711.pdf")

    runner.run_once()

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1


def test_without_a_match_the_fallback_folder_is_used(tmp_path):
    runner, pickups, _, _ = _env(tmp_path, rules=[Rule.create("Rechnung", "rechnungen")])
    pickups.add(name="Kopierer", folder="scans")
    _drop(tmp_path / "scans", "irgendwas.pdf")

    runner.run_once()

    assert len(list((tmp_path / "unsorted").glob("*"))) == 1


def test_rules_pinned_to_a_mailbox_do_not_claim_folder_scans(tmp_path):
    """A file from a folder arrived through no mailbox at all."""
    runner, pickups, _, _ = _env(
        tmp_path, rules=[Rule.create("Rechnung", "privat", account="2")]
    )
    pickups.add(name="Kopierer", folder="scans")
    _drop(tmp_path / "scans", "Rechnung_1.pdf")

    runner.run_once()

    assert not (tmp_path / "privat").exists()
    assert len(list((tmp_path / "unsorted").glob("*"))) == 1


def test_a_blocked_extension_is_quarantined(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "Rechnung.exe", b"MZ")

    runner.run_once()

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1
    assert not (tmp_path / "eingang").exists()


def test_the_quarantine_list_is_read_live(tmp_path):
    """Editing it in the web UI has to take effect without a restart."""
    runner, pickups, _, _ = _env(tmp_path)
    blocked = {"value": parse_extension_list("exe")}
    base = runner.options
    runner._options = lambda: replace(base, blocked_extensions=blocked["value"])
    pickups.add(name="Kopierer", folder="scans", target_folder="eingang")

    blocked["value"] = parse_extension_list("pdf")
    _drop(tmp_path / "scans", "scan.pdf")
    runner.run_once()

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_a_target_inside_the_pickup_folder_is_skipped(tmp_path):
    """Configuration refuses it, a hand-edited database must not loop either."""
    runner, pickups, _, _ = _env(tmp_path)
    pickup_id = pickups.add(name="Kopierer", folder="scans", target_folder="eingang")
    import sqlite3

    with sqlite3.connect(str(tmp_path / "state.db")) as conn:
        conn.execute(
            "UPDATE pickup_folders SET target_folder = 'scans/fertig' WHERE id = ?", (pickup_id,)
        )
    source = _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 0
    assert source.exists()


# --- several archives ----------------------------------------------------------


def test_a_scan_can_be_filed_onto_another_archive(tmp_path):
    runner, pickups, second, second_key = _env(tmp_path)
    pickups.add(
        name="Kopierer", folder="scans", target_archive=second_key, target_folder="eingang"
    )
    _drop(tmp_path / "scans", "scan.pdf", b"inhalt")

    assert runner.run_once() == 1

    filed = list((second / "eingang").glob("*"))
    assert len(filed) == 1 and filed[0].read_bytes() == b"inhalt"
    assert not (tmp_path / "scans" / "scan.pdf").exists()


def test_the_folder_can_live_on_the_second_archive(tmp_path):
    runner, pickups, second, second_key = _env(tmp_path)
    pickups.add(
        name="Kopierer", archive=second_key, folder="scans", target_folder="eingang"
    )
    _drop(second / "scans", "scan.pdf")

    assert runner.run_once() == 1
    assert len(list((tmp_path / "eingang").glob("*"))) == 1


# --- printing ------------------------------------------------------------------


def _printing(tmp_path, queue="drucker_a"):
    store = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = str(store.add(name=queue, destination=queue))
    spooler = RecordingSpooler()
    return PrintService(store, spooler), spooler, printer_id


def test_a_pickup_can_print_what_it_files(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    printing, spooler, printer_id = _printing(tmp_path)
    runner.printing = printing
    pickups.add(
        name="Kopierer", folder="scans", target_folder="eingang",
        print_attachments=True, printer=printer_id,
    )
    _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 1

    assert spooler.printed_on == ["drucker_a"]
    assert len(list((tmp_path / "eingang").glob("*"))) == 1


def test_a_quarantined_scan_is_never_printed(tmp_path):
    runner, pickups, _, _ = _env(tmp_path)
    printing, spooler, printer_id = _printing(tmp_path)
    runner.printing = printing
    pickups.add(
        name="Kopierer", folder="scans", target_folder="eingang",
        print_attachments=True, printer=printer_id,
    )
    _drop(tmp_path / "scans", "boese.exe", b"MZ")

    runner.run_once()

    assert spooler.printed_on == []
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_one_broken_folder_does_not_stop_the_others(tmp_path, monkeypatch):
    runner, pickups, _, _ = _env(tmp_path)
    broken = pickups.add(name="Kaputt", folder="fehlt", target_folder="eingang")
    original = runner._empty

    def explode(pickup):
        if pickup.id == broken:
            raise OSError("Share weg")
        return original(pickup)

    monkeypatch.setattr(runner, "_empty", explode)
    pickups.add(name="Gut", folder="scans", target_folder="eingang")
    _drop(tmp_path / "scans", "scan.pdf")

    assert runner.run_once() == 1
