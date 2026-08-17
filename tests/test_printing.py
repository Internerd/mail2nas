from __future__ import annotations

import subprocess

import pytest

from mail2nas.printers import Printer, PrinterStore
from mail2nas.printing import (
    PrintError,
    PrintService,
    Spooler,
    build_command,
    job_title,
    parse_extensions,
)

PRINTABLE = parse_extensions("pdf,txt,png")


def _printer(**overrides) -> Printer:
    fields = dict(
        id=1, name="Buero", destination="Kyocera_M2540", server="", options="", copies=1,
        enabled=True,
    )
    fields.update(overrides)
    return Printer(**fields)


class FakeRun:
    """Stands in for subprocess.run, recording what it was asked to run."""

    def __init__(self, returncode: int = 0, stdout: str = "request id is q-1", stderr: str = ""):
        self.calls: list[list[str]] = []
        self._result = subprocess.CompletedProcess([], returncode, stdout, stderr)

    def __call__(self, command, **kwargs):
        self.calls.append(list(command))
        self.kwargs = kwargs
        return self._result


def _spooler(monkeypatch, run=None, **overrides) -> tuple[Spooler, FakeRun]:
    run = run or FakeRun()
    monkeypatch.setattr(subprocess, "run", run)
    options = dict(printable_extensions=PRINTABLE)
    options.update(overrides)
    return Spooler(**options), run


# --- the lp command -----------------------------------------------------------


def test_the_command_names_the_queue_and_the_job():
    command = build_command(_printer(), "/tmp/x.pdf", "Rechnung 4711")

    assert command[0] == "lp"
    assert command[command.index("-d") + 1] == "Kyocera_M2540"
    assert command[command.index("-t") + 1] == "Rechnung 4711"
    assert command[-2:] == ["--", "/tmp/x.pdf"]


def test_a_remote_cups_server_is_passed_with_h():
    command = build_command(_printer(server="cups.lan:631"), "/tmp/x.pdf", "t")

    assert command[command.index("-h") + 1] == "cups.lan:631"


def test_each_option_becomes_its_own_o_argument():
    command = build_command(
        _printer(options="media=A4 sides=two-sided-long-edge"), "/tmp/x.pdf", "t"
    )

    assert command.count("-o") == 2
    assert "media=A4" in command and "sides=two-sided-long-edge" in command


def test_a_single_copy_needs_no_n_argument():
    assert "-n" not in build_command(_printer(), "/tmp/x.pdf", "t")
    assert build_command(_printer(copies=3), "/tmp/x.pdf", "t").count("-n") == 1


def test_the_binary_can_be_pointed_somewhere_else():
    assert build_command(_printer(), "/tmp/x.pdf", "t", lp_binary="/usr/bin/lp")[0] == "/usr/bin/lp"


def test_the_job_title_stays_short_and_printable():
    title = job_title("Betreff\nmit Umbruch", "rechnung.pdf")

    assert "\n" not in title
    assert len(title) <= 80
    assert "rechnung.pdf" in title


# --- spooling ------------------------------------------------------------------


def test_printing_writes_the_payload_and_calls_lp(monkeypatch, tmp_path):
    seen = {}
    run = FakeRun()

    def record(command, **kwargs):
        # The temporary file must still exist - and hold the payload - at the
        # moment lp is called.
        with open(command[-1], "rb") as fh:
            seen["data"] = fh.read()
        seen["suffix"] = command[-1].rsplit(".", 1)[-1]
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)
    spooler = Spooler(printable_extensions=PRINTABLE)

    spooler.print_bytes(_printer(), b"%PDF-1.4 fake", "rechnung.pdf")

    assert seen["data"] == b"%PDF-1.4 fake"
    assert seen["suffix"] == "pdf"


def test_the_temporary_file_is_removed_afterwards(monkeypatch):
    paths = []
    run = FakeRun()

    def record(command, **kwargs):
        paths.append(command[-1])
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)

    Spooler(printable_extensions=PRINTABLE).print_bytes(_printer(), b"x", "a.pdf")

    import os

    assert paths and not os.path.exists(paths[0])


def test_a_failing_lp_reports_what_it_said(monkeypatch):
    spooler, _ = _spooler(monkeypatch, run=FakeRun(returncode=1, stderr="lp: Kein Drucker"))

    with pytest.raises(PrintError, match="Kein Drucker"):
        spooler.print_bytes(_printer(), b"x", "a.pdf")


def test_a_missing_lp_binary_says_which_package_is_missing(monkeypatch):
    def missing(command, **kwargs):
        raise FileNotFoundError(command[0])

    monkeypatch.setattr(subprocess, "run", missing)

    with pytest.raises(PrintError, match="cups-client"):
        Spooler(printable_extensions=PRINTABLE).print_bytes(_printer(), b"x", "a.pdf")


def test_a_hanging_printer_is_given_up_on(monkeypatch):
    def hang(command, **kwargs):
        raise subprocess.TimeoutExpired(command, 1)

    monkeypatch.setattr(subprocess, "run", hang)

    with pytest.raises(PrintError, match="abgebrochen"):
        Spooler(printable_extensions=PRINTABLE, timeout=1).print_bytes(_printer(), b"x", "a.pdf")


def test_dry_run_does_not_touch_the_printer(monkeypatch):
    spooler, run = _spooler(monkeypatch, dry_run=True)

    spooler.print_bytes(_printer(), b"x", "a.pdf")

    assert run.calls == []


def test_the_test_page_says_where_it_came_from(monkeypatch):
    printed = {}
    run = FakeRun()

    def record(command, **kwargs):
        with open(command[-1], encoding="utf-8") as fh:
            printed["text"] = fh.read()
        return run(command, **kwargs)

    monkeypatch.setattr(subprocess, "run", record)

    Spooler(printable_extensions=PRINTABLE).print_test_page(_printer())

    assert "Kyocera_M2540" in printed["text"]


@pytest.mark.parametrize(
    "filename,printable",
    [("rechnung.pdf", True), ("BELEG.PDF", True), ("notiz.txt", True),
     ("rechnung.docx", False), ("ohne-endung", False)],
)
def test_only_known_formats_are_spooled(filename, printable):
    assert Spooler(printable_extensions=PRINTABLE).can_print(filename) is printable


# --- routing --------------------------------------------------------------------


@pytest.fixture
def service(tmp_path, monkeypatch):
    store = PrinterStore(str(tmp_path / "state.db"))
    run = FakeRun()
    monkeypatch.setattr(subprocess, "run", run)
    service = PrintService(store, Spooler(printable_extensions=PRINTABLE))
    return service, store, run


def test_the_first_configured_printer_in_the_chain_wins(service):
    printing, store, _ = service
    rule_printer = store.add(name="Regel", destination="q1")
    account_printer = store.add(name="Konto", destination="q2")

    chosen = printing.printer_for(str(rule_printer), str(account_printer))

    assert chosen.name == "Regel"


def test_an_empty_choice_falls_through_to_the_next(service):
    printing, store, _ = service
    account_printer = store.add(name="Konto", destination="q2")

    assert printing.printer_for("", str(account_printer)).name == "Konto"


def test_a_deleted_printer_falls_through_instead_of_failing(service):
    printing, store, _ = service
    account_printer = store.add(name="Konto", destination="q2")

    assert printing.printer_for("9999", str(account_printer)).name == "Konto"


def test_a_paused_printer_is_skipped(service):
    printing, store, _ = service
    paused = store.add(name="Pausiert", destination="q1", enabled=False)

    assert printing.printer_for(str(paused)) is None


def test_nothing_configured_means_no_printer(service):
    printing, _, _ = service

    assert printing.printer_for("", "") is None
    assert printing.configured() is False


def test_sending_reports_failures_instead_of_raising(tmp_path, monkeypatch):
    store = PrinterStore(str(tmp_path / "state.db"))
    monkeypatch.setattr(subprocess, "run", FakeRun(returncode=1, stderr="offline"))
    printing = PrintService(store, Spooler(printable_extensions=PRINTABLE))

    # A dead printer must never take the archiving down with it.
    assert printing.send(_printer(), b"x", "rechnung.pdf") is False


def test_an_unprintable_format_is_not_sent(service):
    printing, _, run = service

    assert printing.send(_printer(), b"MZ", "setup.docx") is False
    assert run.calls == []
