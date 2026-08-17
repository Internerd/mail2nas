from __future__ import annotations

import textwrap
from email.message import EmailMessage

from mail2nas.archiver import Archiver
from mail2nas.config import (
    DEFAULT_BLOCKED_EXTENSIONS,
    DEFAULT_PRINTABLE_EXTENSIONS,
    Config,
)
from mail2nas.mapping import Mapping
from mail2nas.state import ProcessedStore
from mail2nas.accounts import Account
from mail2nas.printers import PrinterStore
from mail2nas.printing import (
    PrintError,
    PrintService,
    Spooler,
    parse_extensions,
)
from mail2nas.storage import LocalStorage

TEST_ACCOUNT = Account(
    id=1, name="Test", host="imap.example.com", port=993, ssl=True,
    user="u", password="p", folder="INBOX", mode="poll",
    processed_folder="", oversized_folder="", enabled=True,
)


def _account(**overrides) -> Account:
    from dataclasses import replace
    return replace(TEST_ACCOUNT, **overrides)


def _make_config(tmp_path, **overrides) -> Config:
    defaults = dict(
        imap_host="imap.example.com",
        imap_port=993,
        imap_user="u",
        imap_password="p",
        imap_ssl=True,
        imap_folder="INBOX",
        imap_processed_folder=None,
        imap_oversized_folder=None,
        imap_mode="poll",
        poll_interval=60,
        storage_backend="local",
        storage_root=str(tmp_path),
        smb_host="",
        smb_share="",
        smb_user="",
        smb_password="",
        smb_domain="",
        smb_port=445,
        smb_root="",
        smb_encrypt=True,
        mapping_path="mapping.yaml",
        fallback_folder="unsorted",
        match_body=False,
        filename_prefix="date_sender",
        max_attachment_size_mb=25,
        max_message_size_mb=50,
        max_attachments_per_message=20,
        blocked_extensions=frozenset(
            e.strip() for e in DEFAULT_BLOCKED_EXTENSIONS.split(",")
        ),
        quarantine_folder="quarantaene",
        state_db_path=str(tmp_path / "state.db"),
        dry_run=False,
        printing_enabled=True,
        lp_binary="lp",
        print_timeout=120,
        printable_extensions=frozenset(
            e.strip() for e in DEFAULT_PRINTABLE_EXTENSIONS.split(",")
        ),
        printer_name="",
        printer_destination="",
        printer_server="",
        printer_options="",
        printer_copies=1,
        web_enabled=False,
        web_host="127.0.0.1",
        web_port=8080,
        web_password="",
        web_cookie_secure=False,
    )
    defaults.update(overrides)
    return Config(**defaults)


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _make_archiver(
    tmp_path,
    mapping_content: str | None = None,
    account: Account | None = None,
    printing=None,
    **config_overrides,
) -> Archiver:
    config = _make_config(tmp_path, **config_overrides)
    mapping_path = tmp_path / "mapping.yaml"
    if mapping_content is not None:
        _write_mapping(mapping_path, mapping_content)
    storage = LocalStorage(config.storage_root)
    mapping = Mapping(storage, config.mapping_path, config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    return Archiver(config, mapping, store, storage, account or TEST_ACCOUNT, printing)


class FakeIMAPClient:
    """Minimal stand-in for imapclient.IMAPClient, just enough for _process_message."""

    def __init__(self, uid: int, raw: bytes):
        self._uid = uid
        self._raw = raw
        self.flags_added: list[tuple[list[int], list[bytes]]] = []
        self.moved_to: list[tuple[list[int], str]] = []

    def fetch(self, uids, parts):
        assert uids == [self._uid]
        result: dict = {}
        for uid in uids:
            entry = {}
            if "RFC822.SIZE" in parts:
                entry[b"RFC822.SIZE"] = len(self._raw)
            if "RFC822" in parts:
                entry[b"RFC822"] = self._raw
            result[uid] = entry
        return result

    def add_flags(self, uids, flags):
        self.flags_added.append((list(uids), list(flags)))

    def move(self, uids, folder):
        self.moved_to.append((list(uids), folder))


def _build_message(subject: str, attachments: list[tuple[str, bytes]]) -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = "lieferant@example.com"
    msg.set_content("Hallo")
    for filename, payload in attachments:
        msg.add_attachment(payload, maintype="application", subtype="octet-stream", filename=filename)
    return bytes(msg)


# --- attachment discovery / filename building -------------------------------


def test_iter_attachments_finds_named_parts(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Rechnung 123"
    msg.set_content("Hallo")
    msg.add_attachment(b"%PDF-1.4 fake", maintype="application", subtype="pdf", filename="rechnung.pdf")

    archiver = _make_archiver(tmp_path)
    attachments = list(archiver._iter_attachments(msg))

    assert len(attachments) == 1
    filename, payload = attachments[0]
    assert filename == "rechnung.pdf"
    assert payload.startswith(b"%PDF")


def test_iter_attachments_ignores_plain_body(tmp_path):
    msg = EmailMessage()
    msg["Subject"] = "Newsletter"
    msg.set_content("Nur Text, kein Anhang")

    archiver = _make_archiver(tmp_path)

    assert list(archiver._iter_attachments(msg)) == []


def test_build_filename_date_sender_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date_sender")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_lieferant_example.com_rechnung.pdf"


def test_build_filename_none_prefix_keeps_original_name(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="none")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "rechnung.pdf"


def test_build_filename_date_only_prefix(tmp_path):
    archiver = _make_archiver(tmp_path, filename_prefix="date")

    result = archiver._build_filename("2026-08-12", "lieferant@example.com", "rechnung.pdf")

    assert result == "2026-08-12_rechnung.pdf"


# --- per-attachment folder resolution ----------------------------------------


def test_plan_prefers_attachment_filename_over_mail_subject(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            RE: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    # Mail-level match would be "rechnungen" (subject contains RE), but this
    # specific attachment's own filename literally says "Lieferschein".
    mail_rule = archiver.mapping.match("RE-2024-001 mit Lieferschein")

    plan = archiver._plan_attachment("Lieferschein_4711.pdf", mail_rule)

    assert plan.folder == "lieferscheine"
    assert plan.keyword == "Lieferschein"
    assert plan.quarantined is False


def test_plan_falls_back_to_mail_level_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    mail_rule = archiver.mapping.match("RE-2024-001")

    # "anhang1.pdf" itself does not match any keyword.
    plan = archiver._plan_attachment("anhang1.pdf", mail_rule)

    assert plan.folder == "rechnungen"
    assert plan.keyword == "RE"
    assert plan.quarantined is False


def test_plan_quarantines_blocked_extension_even_with_keyword_match(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")

    plan = archiver._plan_attachment("Rechnung.exe", None)

    assert plan.folder == "quarantaene"
    assert plan.quarantined is True


# --- full message processing (size/count limits, quarantine, mail-level) ----


def test_process_message_splits_multiple_attachments_by_filename(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            Rechnung: rechnungen
            Lieferschein: lieferscheine
        """,
    )
    raw = _build_message(
        "Bestellung 42",
        [("Rechnung_42.pdf", b"invoice-bytes"), ("Lieferschein_42.pdf", b"delivery-bytes")],
    )
    client = FakeIMAPClient(uid=1, raw=raw)

    archiver._process_message(client, 1)

    assert any(p.name.endswith("Rechnung_42.pdf") for p in (tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("Lieferschein_42.pdf") for p in (tmp_path / "lieferscheine").glob("*"))


def test_process_message_skips_oversized_message_without_reading_body(tmp_path):
    archiver = _make_archiver(tmp_path, max_message_size_mb=1)
    huge_raw = _build_message("Rechnung riesig", [("rechnung.pdf", b"x" * (2 * 1024 * 1024))])
    client = FakeIMAPClient(uid=7, raw=huge_raw)

    result = archiver._process_message(client, 7)

    assert result is True
    assert client.flags_added == [([7], [b"\\Seen"])]
    assert not (tmp_path / "rechnungen").exists()


def test_process_message_skips_only_oversized_attachment(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachment_size_mb=1, max_message_size_mb=50
    )
    raw = _build_message(
        "RE-1",
        [("gross.pdf", b"x" * (2 * 1024 * 1024)), ("klein.pdf", b"klein")],
    )
    client = FakeIMAPClient(uid=3, raw=raw)

    archiver._process_message(client, 3)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert any(p.name.endswith("klein.pdf") for p in saved)
    assert not any(p.name.endswith("gross.pdf") for p in saved)


def test_process_message_caps_attachment_count(tmp_path):
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", max_attachments_per_message=2
    )
    raw = _build_message(
        "RE-1",
        [(f"a{i}.pdf", b"data") for i in range(5)],
    )
    client = FakeIMAPClient(uid=4, raw=raw)

    archiver._process_message(client, 4)

    saved = list((tmp_path / "rechnungen").glob("*"))
    assert len(saved) == 2


def test_process_message_quarantines_blocked_attachment(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ...")])
    client = FakeIMAPClient(uid=5, raw=raw)

    archiver._process_message(client, 5)

    assert not (tmp_path / "rechnungen").exists() or not any((tmp_path / "rechnungen").glob("*"))
    quarantined = list((tmp_path / "quarantaene").glob("*"))
    assert len(quarantined) == 1


def test_process_message_is_idempotent_for_already_processed_message_id(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("rechnung.pdf", b"data")])
    client = FakeIMAPClient(uid=6, raw=raw)

    archiver._process_message(client, 6)
    first_run_files = list((tmp_path / "rechnungen").glob("*"))
    archiver._process_message(client, 6)
    second_run_files = list((tmp_path / "rechnungen").glob("*"))

    assert len(first_run_files) == 1
    assert len(second_run_files) == 1


# --- untrusted mapping targets must not escape the storage root -------------


def test_process_message_confines_relative_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside-escape\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert not (tmp_path.parent / "outside-escape").exists()
    # rejected target falls back rather than being written outside
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_process_message_confines_absolute_traversal_target(tmp_path):
    escape = tmp_path.parent / "absolute-escape"
    archiver = _make_archiver(tmp_path, mapping_content=f"RE: {escape}\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=2, raw=raw), 2)

    assert not escape.exists()
    # rejected as a misconfiguration, so it lands in the fallback folder
    assert any(p.is_file() for p in (tmp_path / "unsorted").rglob("*"))


def test_target_parts_reject_escape_and_use_fallback(tmp_path):
    archiver = _make_archiver(tmp_path)

    assert archiver._target_parts("../evil") == ("unsorted",)
    assert archiver._target_parts("rechnungen") == ("rechnungen",)
    assert archiver._target_parts("rechnungen/2026") == ("rechnungen", "2026")


def test_nested_mapping_target_is_supported(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen/2026\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert any((tmp_path / "rechnungen" / "2026").glob("*"))


def test_quarantine_still_wins_over_a_traversal_target(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: ../outside\n")
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=4, raw=raw), 4)

    assert not (tmp_path.parent / "outside").exists()
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_attachments_are_written_atomically_without_temp_leftovers(tmp_path):
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n")
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    names = [p.name for p in (tmp_path / "rechnungen").iterdir()]
    assert len(names) == 1
    assert not any(n.startswith(".mail2nas-tmp-") for n in names)


# --- printing ----------------------------------------------------------------


class RecordingSpooler(Spooler):
    """A spooler that remembers jobs instead of handing them to CUPS."""

    def __init__(self, **kwargs):
        super().__init__(printable_extensions=parse_extensions(DEFAULT_PRINTABLE_EXTENSIONS))
        self.jobs: list[tuple[str, str]] = []

    def print_bytes(self, printer, data, filename, title=""):
        self.jobs.append((printer.destination, filename))
        return "queued"

    @property
    def printed_on(self) -> list[str]:
        return [destination for destination, _ in self.jobs]


def _make_printing(tmp_path, *queues: str):
    """A print service with one printer per given queue name."""
    store = PrinterStore(str(tmp_path / "printers.db"))
    ids = [str(store.add(name=queue, destination=queue)) for queue in queues]
    spooler = RecordingSpooler()
    return PrintService(store, spooler), spooler, ids


def test_a_mailbox_can_print_every_attachment(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
    )
    raw = _build_message("Newsletter", [("prospekt.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=1, raw=raw), 1)

    assert spooler.printed_on == ["drucker_a"]
    # still archived: printing is an addition, not a replacement
    assert any((tmp_path / "unsorted").glob("*"))


def test_a_rule_can_print_only_what_it_matches(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_b")
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
                printer: "{printer_id}"
              - keyword: Lieferschein
                folder: lieferscheine
        """,
        printing=printing,
    )
    raw = _build_message(
        "Bestellung 42",
        [("Rechnung_42.pdf", b"invoice"), ("Lieferschein_42.pdf", b"delivery")],
    )

    archiver._process_message(FakeIMAPClient(uid=2, raw=raw), 2)

    assert [name for _, name in spooler.jobs] == [
        "unknown-date_lieferant_example.com_Rechnung_42.pdf"
    ]
    assert spooler.printed_on == ["drucker_b"]


def test_the_rule_printer_wins_over_the_mailbox_printer(tmp_path):
    printing, spooler, (rule_printer, account_printer) = _make_printing(
        tmp_path, "drucker_regel", "drucker_konto"
    )
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
                printer: "{rule_printer}"
        """,
        account=_account(print_attachments=True, printer=account_printer),
        printing=printing,
    )
    raw = _build_message("Rechnung 1", [("Rechnung_1.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert spooler.printed_on == ["drucker_regel"]


def test_a_rule_without_its_own_printer_uses_the_mailbox_one(tmp_path):
    printing, spooler, (account_printer,) = _make_printing(tmp_path, "drucker_konto")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - keyword: Rechnung
                folder: rechnungen
                print: true
        """,
        account=_account(printer=account_printer),
        printing=printing,
    )
    raw = _build_message("Rechnung 1", [("Rechnung_1.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=4, raw=raw), 4)

    assert spooler.printed_on == ["drucker_konto"]


def test_print_only_mailboxes_do_not_write_to_the_share(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=5, raw=raw), 5)

    assert spooler.printed_on == ["drucker_a"]
    assert not (tmp_path / "rechnungen").exists()


def test_a_blocked_attachment_is_quarantined_and_never_printed(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        # print everything, archive nothing - the executable must still be
        # kept, and must still not reach the printer.
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )
    raw = _build_message("RE-1", [("Rechnung.exe", b"MZ")])

    archiver._process_message(FakeIMAPClient(uid=6, raw=raw), 6)

    assert spooler.jobs == []
    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


def test_nothing_is_printed_without_a_printer(tmp_path, caplog):
    printing, spooler, _ = _make_printing(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True),
        printing=printing,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    with caplog.at_level("WARNING"):
        archiver._process_message(FakeIMAPClient(uid=7, raw=raw), 7)

    assert spooler.jobs == []
    assert "no usable printer" in caplog.text
    # the attachment is still filed - printing is the part that failed
    assert any((tmp_path / "rechnungen").glob("*"))


def test_printing_can_be_switched_off_globally(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
        printing_enabled=False,
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=8, raw=raw), 8)

    assert spooler.jobs == []
    assert any((tmp_path / "rechnungen").glob("*"))


def test_a_failing_printer_does_not_stop_the_archiving(tmp_path):
    class BrokenSpooler(RecordingSpooler):
        def print_bytes(self, printer, data, filename, title=""):
            raise PrintError("Drucker offline")

    store = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = str(store.add(name="Kaputt", destination="drucker_a"))
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id),
        printing=PrintService(store, BrokenSpooler()),
    )
    raw = _build_message("RE-1", [("beleg.pdf", b"DATA")])

    archiver._process_message(FakeIMAPClient(uid=9, raw=raw), 9)

    assert any((tmp_path / "rechnungen").glob("*"))
