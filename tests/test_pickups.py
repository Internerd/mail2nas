from __future__ import annotations

import pytest

from mail2nas.pickups import Pickup, PickupError, PickupStore


def _store(tmp_path) -> PickupStore:
    return PickupStore(str(tmp_path / "state.db"))


def _pickup(**overrides) -> Pickup:
    values = dict(
        id=1,
        name="Kopierer",
        archive="",
        folder="scans",
        target_archive="",
        target_folder="eingang",
        print_attachments=False,
        printer="",
        enabled=True,
    )
    values.update(overrides)
    return Pickup(**values)


# --- validation ---------------------------------------------------------------


def test_a_folder_is_required(tmp_path):
    with pytest.raises(PickupError, match="Ordner"):
        _store(tmp_path).add(name="Ohne Ordner")


@pytest.mark.parametrize("folder", ["../woanders", "/etc", ""])
def test_a_folder_that_escapes_the_archive_is_rejected(tmp_path, folder):
    with pytest.raises(PickupError):
        _store(tmp_path).add(name="Boese", folder=folder)


def test_a_target_inside_the_pickup_folder_is_refused(tmp_path):
    """Otherwise the same document is imported again on every cycle."""
    with pytest.raises(PickupError, match="immer wieder eingelesen"):
        _store(tmp_path).add(name="Schleife", folder="scans", target_folder="scans/fertig")


def test_the_same_folder_on_another_archive_is_fine(tmp_path):
    """Same path, different NAS - that is a move, not a loop."""
    store = _store(tmp_path)

    pickup_id = store.add(
        name="Kopierer", folder="scans", target_archive="2", target_folder="scans/fertig"
    )

    assert store.get(pickup_id).target_folder == "scans/fertig"


def test_the_name_defaults_to_the_folder(tmp_path):
    store = _store(tmp_path)

    pickup_id = store.add(folder="scans/flur")

    assert store.get(pickup_id).name == "scans/flur"


def test_paths_are_normalised(tmp_path):
    store = _store(tmp_path)

    pickup_id = store.add(folder="scans\\\\flur\\\\", target_folder="eingang/")

    pickup = store.get(pickup_id)
    assert (pickup.folder, pickup.target_folder) == ("scans/flur", "eingang")


# --- the rules a pickup plays by ----------------------------------------------


def test_files_into_itself_detects_the_loop():
    assert _pickup(folder="scans", target_folder="scans/fertig").files_into_itself() is True
    assert _pickup(folder="scans", target_folder="scans").files_into_itself() is True
    assert _pickup(folder="scans", target_folder="eingang").files_into_itself() is False
    # no fixed target: the rules decide, and they cannot point back by name
    assert _pickup(folder="scans", target_folder="").files_into_itself() is False


def test_a_similar_name_is_not_a_loop():
    assert _pickup(folder="scans", target_folder="scans-fertig").files_into_itself() is False


def test_the_rule_scope_can_never_be_a_real_account():
    """Account ids are numbers, so only "all accounts" rules may claim a scan."""
    assert _pickup(id=3).rule_scope() == "pickup:3"


# --- store --------------------------------------------------------------------


def test_add_update_delete(tmp_path):
    store = _store(tmp_path)
    pickup_id = store.add(name="Kopierer", folder="scans", target_folder="eingang")

    store.update(pickup_id, name="Kopierer Flur")
    assert store.get(pickup_id).name == "Kopierer Flur"
    assert store.get(pickup_id).target_folder == "eingang"

    store.delete(pickup_id)
    assert store.get(pickup_id) is None


def test_disabled_folders_are_not_watched(tmp_path):
    store = _store(tmp_path)
    store.add(name="Aus", folder="scans", enabled=False)

    assert store.enabled() == []


def test_deleting_a_printer_stops_the_printing(tmp_path):
    store = _store(tmp_path)
    pickup_id = store.add(name="Kopierer", folder="scans", print_attachments=True, printer="4")

    assert store.clear_printer("4") == 1

    pickup = store.get(pickup_id)
    assert (pickup.print_attachments, pickup.printer) == (False, "")
