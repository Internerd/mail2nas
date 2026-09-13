from __future__ import annotations

import dataclasses
import os
import time
from pathlib import Path

import pytest

from mail2nas.mapping import Mapping
from mail2nas.printers import PrinterPickup
from mail2nas.settings import Printer, Settings, Share
from mail2nas.shares import ShareSet
from tests.test_archiver import _make_config


# --- identifying a device by its mail address --------------------------------


@pytest.mark.parametrize(
    "pattern,address,expected",
    [
        ("scanner@example.com", "scanner@example.com", True),
        ("scanner@example.com", "SCANNER@Example.COM", True),
        ("scanner@example.com", "chef@example.com", False),
        ("@scanner.lan", "kopierer-3@scanner.lan", True),
        ("@scanner.lan", "kopierer-3@example.com", False),
        ("kopierer-*@example.com", "kopierer-flur@example.com", True),
        ("kopierer-*@example.com", "buchhaltung@example.com", False),
        ("", "scanner@example.com", False),
        ("scanner@example.com", "", False),
    ],
)
def test_matches_sender(pattern, address, expected):
    assert Printer(id="p", sender=pattern).matches_sender(address) is expected


# --- picking documents out of a folder on the NAS ----------------------------


def _pickup(tmp_path, printer: Printer, mapping_content: str | None = None, **overrides):
    """A PrinterPickup wired to <tmp_path>/nas1 (+ nas2), like a real deployment."""
    nas1 = tmp_path / "nas1"
    nas2 = tmp_path / "nas2"
    nas1.mkdir(exist_ok=True)
    nas2.mkdir(exist_ok=True)

    config = _make_config(nas1, storage_root=str(nas1), **overrides)
    mapping_path = nas1 / "mapping.yaml"
    if mapping_content is not None:
        mapping_path.write_text(mapping_content, encoding="utf-8")
    mapping = Mapping(str(mapping_path), config.fallback_folder)

    settings = Settings(
        shares=[
            Share(id="nas1", label="NAS 1", path=str(nas1)),
            Share(id="nas2", label="NAS 2", path=str(nas2)),
        ],
        printers=[printer],
        printer_min_age_seconds=0,
    )
    shares = ShareSet.from_settings(settings, config.storage_root)
    return PrinterPickup(config, settings, mapping, shares), nas1, nas2


def _drop(directory: Path, name: str, content: bytes = b"scan", age_seconds: int = 60) -> Path:
    """Write a file into a pickup folder, pretending it finished `age` ago."""
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    path.write_bytes(content)
    stamp = time.time() - age_seconds
    os.utime(path, (stamp, stamp))
    return path


def test_file_is_moved_into_the_fixed_target_folder(tmp_path):
    printer = Printer(id="kopierer", label="Kopierer", source_share="nas1",
                      source_folder="scans", target_share="nas1", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", "SKM_C250i23081512.pdf")

    assert pickup.run_once() == 1
    assert not source.exists()  # the pickup folder is an outbox, not an archive
    filed = list((nas1 / "eingang").glob("*"))
    assert len(filed) == 1
    assert filed[0].read_bytes() == b"scan"


def test_filename_gets_the_device_and_the_scan_date(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan1.pdf")

    pickup.run_once()

    name = next((nas1 / "eingang").glob("*")).name
    assert name.endswith("_kopierer_scan1.pdf")
    assert name[:4].isdigit()  # date prefix from the file's own mtime


def test_file_still_being_written_is_left_alone(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    pickup.settings.printer_min_age_seconds = 30
    source = _drop(nas1 / "scans", "halb.pdf", age_seconds=0)

    assert pickup.run_once() == 0
    assert source.exists()


@pytest.mark.parametrize("name", [".hidden.pdf", "scan.pdf.tmp", "scan.PART", ".mail2nas-tmp-x"])
def test_incomplete_or_hidden_files_are_ignored(tmp_path, name):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", name)

    assert pickup.run_once() == 0
    assert source.exists()


def test_empty_file_is_ignored(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "leer.pdf", content=b"")

    assert pickup.run_once() == 0


def test_subfolders_of_the_pickup_folder_are_walked(tmp_path):
    """Devices often create one subfolder per user or scan profile."""
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans" / "anna", "a.pdf")
    _drop(nas1 / "scans" / "bert", "b.pdf")

    assert pickup.run_once() == 2
    assert len(list((nas1 / "eingang").glob("*"))) == 2


def test_without_a_fixed_target_the_keyword_rules_decide(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans")
    pickup, nas1, _ = _pickup(tmp_path, printer, mapping_content="Rechnung: rechnungen\n")
    _drop(nas1 / "scans", "Rechnung_4711.pdf")

    pickup.run_once()

    assert len(list((nas1 / "rechnungen").glob("*"))) == 1


def test_without_a_match_the_fallback_folder_is_used(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans")
    pickup, nas1, _ = _pickup(tmp_path, printer, mapping_content="Rechnung: rechnungen\n")
    _drop(nas1 / "scans", "irgendwas.pdf")

    pickup.run_once()

    assert len(list((nas1 / "unsorted").glob("*"))) == 1


def test_rules_pinned_to_a_mail_account_do_not_claim_folder_scans(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans")
    pickup, nas1, _ = _pickup(
        tmp_path,
        printer,
        mapping_content=(
            "version: 2\nrules:\n"
            "  - match: Rechnung\n    folder: privat\n    account: privatkonto\n"
        ),
    )
    _drop(nas1 / "scans", "Rechnung_1.pdf")

    pickup.run_once()

    assert not (nas1 / "privat").exists()
    assert len(list((nas1 / "unsorted").glob("*"))) == 1


def test_blocked_extension_is_quarantined(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "Rechnung.exe", content=b"MZ")

    pickup.run_once()

    assert len(list((nas1 / "quarantaene").glob("*"))) == 1
    assert not (nas1 / "eingang").exists()


def test_document_can_be_filed_onto_another_nas(tmp_path):
    printer = Printer(id="kopierer", source_share="nas1", source_folder="scans",
                      target_share="nas2", target_folder="eingang")
    pickup, nas1, nas2 = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 1
    assert len(list((nas2 / "eingang").glob("*"))) == 1
    assert not (nas1 / "eingang").exists()


def test_target_inside_the_pickup_folder_is_refused(tmp_path):
    """Otherwise the same document would be imported again on every cycle."""
    printer = Printer(id="kopierer", source_folder="scans", target_folder="scans/fertig")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 0
    assert source.exists()


def test_missing_pickup_folder_is_reported_once_and_does_not_raise(tmp_path, caplog):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, _, _ = _pickup(tmp_path, printer)

    with caplog.at_level("WARNING"):
        assert pickup.run_once() == 0
        assert pickup.run_once() == 0

    warnings = [r for r in caplog.records if r.name == "mail2nas.printers"]
    assert len(warnings) == 1
    assert "existiert nicht" in warnings[0].getMessage()


def test_unmounted_source_share_is_not_created_on_the_local_disk(tmp_path):
    printer = Printer(id="kopierer", source_share="weg", source_folder="scans",
                      target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    pickup.shares = ShareSet(
        [Share(id="weg", path=str(tmp_path / "nicht-gemountet"))], fallback_root=str(nas1)
    )
    pickup.filer.shares = pickup.shares

    assert pickup.run_once() == 0
    assert not (tmp_path / "nicht-gemountet").exists()


def test_disabled_printer_is_skipped(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang", enabled=False)
    pickup, nas1, _ = _pickup(tmp_path, printer)
    source = _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 0
    assert source.exists()


def test_dry_run_moves_nothing(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer, dry_run=True)
    source = _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 0
    assert source.exists()
    assert not (nas1 / "eingang").exists()


def test_two_scans_with_the_same_name_do_not_overwrite_each_other(tmp_path):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer, filename_prefix="none")
    _drop(nas1 / "scans", "scan.pdf", content=b"erster")
    pickup.run_once()
    _drop(nas1 / "scans", "scan.pdf", content=b"zweiter")
    pickup.run_once()

    filed = sorted(p.read_bytes() for p in (nas1 / "eingang").glob("*"))
    assert filed == [b"erster", b"zweiter"]


def test_a_broken_printer_does_not_stop_the_others(tmp_path):
    good = Printer(id="gut", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, good)
    pickup.settings = dataclasses.replace(
        pickup.settings,
        printers=[Printer(id="kaputt", source_folder="../ausserhalb"), good],
    )
    _drop(nas1 / "scans", "scan.pdf")

    assert pickup.run_once() == 1
    assert not (tmp_path / "ausserhalb").exists()


@pytest.mark.skipif(os.getuid() == 0, reason="root ignores write permission bits")
def test_pickup_folder_we_cannot_delete_from_is_refused(tmp_path):
    """Copying without deleting would re-import the same scan forever."""
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan.pdf")
    (nas1 / "scans").chmod(0o500)
    try:
        assert pickup.run_once() == 0
        assert not (nas1 / "eingang").exists()
    finally:
        (nas1 / "scans").chmod(0o700)


def test_a_failed_delete_does_not_leave_a_copy_behind(tmp_path, monkeypatch):
    printer = Printer(id="kopierer", source_folder="scans", target_folder="eingang")
    pickup, nas1, _ = _pickup(tmp_path, printer)
    _drop(nas1 / "scans", "scan.pdf")

    original = Path.unlink

    def refuse_in_the_pickup_folder(self, missing_ok=False):
        if self.parent.name == "scans":
            raise OSError("read-only")
        return original(self, missing_ok=missing_ok)

    monkeypatch.setattr(Path, "unlink", refuse_in_the_pickup_folder)

    assert pickup.run_once() == 0
    assert (nas1 / "scans" / "scan.pdf").exists()
    assert list((nas1 / "eingang").glob("*")) == []
