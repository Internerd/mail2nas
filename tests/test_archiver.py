from __future__ import annotations

import email
import textwrap
from dataclasses import replace
from email.message import EmailMessage

from mail2nas.accounts import Account
from mail2nas.addresses import AddressStore
from mail2nas.archives import ArchiveStore, StorageSet
from mail2nas.archiver import MAX_RECIPIENTS, Archiver, recipients_of
from mail2nas.config import DEFAULT_PRINTABLE_EXTENSIONS, Config
from mail2nas.legacy import LegacyEnv
from mail2nas.mapping import Mapping, RuleStore, rules_from_yaml
from mail2nas.options import Options
from mail2nas.printers import PrinterStore
from mail2nas.printing import (
    PrintError,
    PrintService,
    Spooler,
    parse_extensions,
)
from mail2nas.state import ProcessedStore
from mail2nas.storage import LocalStorage

TEST_ACCOUNT = Account(
    id=1, name="Test", host="imap.example.com", port=993, ssl=True,
    user="u", password="p", folder="INBOX", mode="poll",
    processed_folder="", oversized_folder="", enabled=True,
)


def _account(**overrides) -> Account:
    return replace(TEST_ACCOUNT, **overrides)


def _make_options(**overrides) -> Options:
    """The settings as they would be stored, with test-friendly overrides."""
    return replace(Options(), **overrides)


def _make_config(tmp_path, **overrides) -> Config:
    """The (infrastructure-only) container configuration for a test."""
    defaults = dict(state_db_path=str(tmp_path / "state.db"), web_host="127.0.0.1")
    defaults.update(overrides)
    return Config(**defaults)


def _make_legacy(**overrides) -> LegacyEnv:
    """An old-style .env, as `legacy.py` reads it."""
    return replace(LegacyEnv(), **overrides)


def _seed_config(tmp_path, **overrides):
    """An old .env plus where the database lives - what the seeding tests need.

    The seed functions read the old variable names as attributes, exactly as
    they come out of `LegacyEnv`.
    """
    from dataclasses import fields
    from types import SimpleNamespace

    defaults = dict(
        imap_host="imap.example.com", imap_user="u", imap_password="p", storage_root=str(tmp_path)
    )
    defaults.update(overrides)
    legacy = _make_legacy(**defaults)
    values = {spec.name: getattr(legacy, spec.name) for spec in fields(legacy)}
    return SimpleNamespace(**values, state_db_path=str(tmp_path / "state.db"))


def _make_runtime(tmp_path, with_archive: bool = True, environ=None, **config_overrides):
    """A wired-up service as `main` builds it - with a local archive in tmp_path.

    `environ` is the (old) .env to take over; empty by default, i.e. a fresh
    installation.
    """
    from mail2nas.main import build_runtime

    runtime = build_runtime(_make_config(tmp_path, **config_overrides), environ or {})
    if with_archive:
        runtime.archives.add(name="Test", backend="local", path=str(tmp_path))
    return runtime


def _write_mapping(path, content: str) -> None:
    path.write_text(textwrap.dedent(content), encoding="utf-8")


def _make_mapping(tmp_path, mapping_content: str | None = None, fallback="unsorted") -> Mapping:
    """Rules as the database holds them, written from a YAML snippet."""
    store = RuleStore(str(tmp_path / "state.db"))
    if mapping_content is not None:
        store.save(rules_from_yaml(textwrap.dedent(mapping_content)))
    return Mapping(store, fallback)


def _make_archiver(
    tmp_path,
    mapping_content: str | None = None,
    account: Account | None = None,
    printing=None,
    addresses=None,
    storages=None,
    blocked_extensions=None,
    **option_overrides,
) -> Archiver:
    options = _make_options(**option_overrides)
    mapping = _make_mapping(tmp_path, mapping_content, options.fallback_folder)
    if blocked_extensions is not None:
        # A callable, so a test can change the list between two messages -
        # the way the settings page does while the service runs.
        base = options
        options = lambda: replace(base, blocked_extensions=blocked_extensions())  # noqa: E731
    return Archiver(
        options,
        mapping,
        ProcessedStore(str(tmp_path / "state.db")),
        storages if storages is not None else LocalStorage(str(tmp_path)),
        account or TEST_ACCOUNT,
        printing,
        addresses,
    )


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


# --- printing by the address a mail was sent to ------------------------------


def _addressed_message(
    to: str = "drucker@firma.de",
    sender: str = "kollege@firma.de",
    subject: str = "Bitte drucken",
    filename: str = "vertrag.pdf",
    extra_headers: dict | None = None,
) -> bytes:
    msg = EmailMessage()
    msg["Subject"] = subject
    msg["From"] = sender
    msg["To"] = to
    for header, value in (extra_headers or {}).items():
        msg[header] = value
    msg.set_content("Anbei.")
    msg.add_attachment(b"DATA", maintype="application", subtype="pdf", filename=filename)
    return bytes(msg)


def _addresses(tmp_path, **fields) -> AddressStore:
    """An address store holding one rule, with print-to-a-queue defaults."""
    store = AddressStore(str(tmp_path / "addresses.db"))
    values = dict(name="Drucker Buero", recipient="drucker@firma.de", print_attachments=True)
    values.update(fields)
    store.add(**values)
    return store


def test_recipients_are_read_from_the_delivery_headers():
    """An alias only survives in Delivered-To once To: has been rewritten."""
    raw = _addressed_message(
        to="liste@firma.de", extra_headers={"Delivered-To": "drucker@firma.de", "Cc": "chef@firma.de"}
    )

    found = recipients_of(email.message_from_bytes(raw))

    assert "drucker@firma.de" in found
    assert "liste@firma.de" in found
    assert "chef@firma.de" in found


def test_recipient_extraction_is_bounded(tmp_path):
    """A mail with thousands of recipients must not make matching expensive."""
    msg = EmailMessage()
    msg["Subject"] = "Massenmail"
    msg["From"] = "a@b.c"
    msg["To"] = ", ".join(f"user{i}@firma.de" for i in range(200))
    msg.set_content("x")

    assert len(recipients_of(msg)) == MAX_RECIPIENTS


def test_mail_to_the_configured_address_is_printed(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id),
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=_addressed_message()), 1)

    assert spooler.printed_on == ["buero_eg"]


def test_mail_to_another_address_is_not_printed(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id),
    )

    archiver._process_message(
        FakeIMAPClient(uid=2, raw=_addressed_message(to="archiv@firma.de")), 2
    )

    assert spooler.printed_on == []


def test_an_alias_in_delivered_to_is_enough(tmp_path):
    """The usual setup: the alias is delivered into a shared mailbox."""
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id),
    )
    raw = _addressed_message(
        to="archiv@firma.de", extra_headers={"Delivered-To": "drucker@firma.de"}
    )

    archiver._process_message(FakeIMAPClient(uid=3, raw=raw), 3)

    assert spooler.printed_on == ["buero_eg"]


def test_a_sender_restriction_keeps_strangers_from_printing(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id, sender="@firma.de"),
    )

    archiver._process_message(
        FakeIMAPClient(uid=4, raw=_addressed_message(sender="fremder@example.com")), 4
    )

    assert spooler.printed_on == []


def test_the_address_decides_the_folder(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="Vertrag: vertraege\n",
        addresses=_addresses(tmp_path, print_attachments=False, folder="ausdrucke"),
    )

    archiver._process_message(
        FakeIMAPClient(uid=5, raw=_addressed_message(filename="Vertrag_7.pdf")), 5
    )

    assert any((tmp_path / "ausdrucke").glob("*"))
    assert not (tmp_path / "vertraege").exists()


def test_without_a_folder_the_keyword_rules_still_decide(tmp_path):
    archiver = _make_archiver(
        tmp_path,
        mapping_content="Vertrag: vertraege\n",
        addresses=_addresses(tmp_path, print_attachments=False),
    )

    archiver._process_message(
        FakeIMAPClient(uid=6, raw=_addressed_message(filename="Vertrag_7.pdf")), 6
    )

    assert any((tmp_path / "vertraege").glob("*"))


def test_an_address_can_print_without_filing(tmp_path):
    """A print-only alias: paper comes out, the share stays clean."""
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id, archive_attachments=False),
    )

    archiver._process_message(FakeIMAPClient(uid=7, raw=_addressed_message()), 7)

    assert spooler.printed_on == ["buero_eg"]
    assert not any(tmp_path.glob("unsorted/*"))


def test_an_address_can_file_without_printing(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        account=_account(print_attachments=True, printer=printer_id),
        printing=printing,
        addresses=_addresses(tmp_path, print_attachments=False, folder="nur_ablage"),
    )

    archiver._process_message(FakeIMAPClient(uid=8, raw=_addressed_message()), 8)

    # The address is the more specific statement, so it wins over the mailbox.
    assert spooler.printed_on == []
    assert any((tmp_path / "nur_ablage").glob("*"))


def test_the_address_printer_beats_the_rule_and_the_mailbox(tmp_path):
    printing, spooler, (address_printer, rule_printer, mailbox_printer) = _make_printing(
        tmp_path, "per_adresse", "per_regel", "per_postfach"
    )
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: Vertrag
                folder: vertraege
                print: true
                printer: "{rule_printer}"
        """,
        account=_account(print_attachments=True, printer=mailbox_printer),
        printing=printing,
        addresses=_addresses(tmp_path, printer=address_printer),
    )

    archiver._process_message(
        FakeIMAPClient(uid=9, raw=_addressed_message(filename="Vertrag_7.pdf")), 9
    )

    assert spooler.printed_on == ["per_adresse"]


def test_an_address_without_its_own_printer_falls_back_to_the_mailbox(tmp_path):
    printing, spooler, (mailbox_printer,) = _make_printing(tmp_path, "per_postfach")
    archiver = _make_archiver(
        tmp_path,
        account=_account(printer=mailbox_printer),
        printing=printing,
        addresses=_addresses(tmp_path, printer=""),
    )

    archiver._process_message(FakeIMAPClient(uid=10, raw=_addressed_message()), 10)

    assert spooler.printed_on == ["per_postfach"]


def test_a_blocked_attachment_is_never_printed_even_for_an_address(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer=printer_id, archive_attachments=False),
    )

    archiver._process_message(
        FakeIMAPClient(uid=11, raw=_addressed_message(filename="rechnung.exe")), 11
    )

    assert spooler.printed_on == []
    # ... and it is filed despite "print only", so it can be looked at
    assert any((tmp_path / "quarantaene").glob("*"))


def test_a_printer_that_is_gone_does_not_stop_the_filing(tmp_path):
    printing, spooler, _ = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(
        tmp_path,
        printing=printing,
        addresses=_addresses(tmp_path, printer="999"),
    )

    archiver._process_message(FakeIMAPClient(uid=12, raw=_addressed_message()), 12)

    assert spooler.printed_on == []
    assert any((tmp_path / "unsorted").glob("*"))


def test_without_address_rules_nothing_changes(tmp_path):
    """The feature is opt-in: an install with no rules behaves as before."""
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "buero_eg")
    archiver = _make_archiver(tmp_path, printing=printing, addresses=None)

    archiver._process_message(FakeIMAPClient(uid=13, raw=_addressed_message()), 13)

    assert spooler.printed_on == []
    assert any((tmp_path / "unsorted").glob("*"))


def test_end_to_end_a_mail_to_the_address_reaches_the_lp_command(tmp_path):
    """The whole chain with no stub in the middle: message in, `lp` called.

    Everything else here fakes the spooler, which is what makes this worth
    having: it is the only test that proves the address rule, the printer
    record and the real `lp` argument building fit together.
    """
    fake_lp = tmp_path / "lp"
    log = tmp_path / "lp.log"
    fake_lp.write_text(
        "#!/bin/sh\n"
        f'echo "$@" >> {log}\n'
        "exit 0\n",
        encoding="utf-8",
    )
    fake_lp.chmod(0o755)

    printers = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = printers.add(
        name="Buero", destination="Buero_MFP", server="cups.lan:631", options="media=A4"
    )
    printing = PrintService(printers, Spooler(lp_binary=str(fake_lp), timeout=30))

    archiver = Archiver(
        _make_options(),
        _make_mapping(tmp_path),
        ProcessedStore(str(tmp_path / "state.db")),
        LocalStorage(str(tmp_path)),
        TEST_ACCOUNT,
        printing,
        _addresses(tmp_path, printer=str(printer_id)),
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=_addressed_message()), 1)

    called = log.read_text(encoding="utf-8")
    assert "-h cups.lan:631" in called
    assert "-d Buero_MFP" in called
    assert "-o media=A4" in called
    # and the document is on the share as well
    assert any((tmp_path / "unsorted").glob("*"))


# --- several archives ----------------------------------------------------------


def _two_archives(tmp_path):
    """<tmp_path> as the default archive, <tmp_path>/nas2 as the second."""
    second = tmp_path / "nas2"
    second.mkdir(exist_ok=True)
    archives = ArchiveStore(str(tmp_path / "archives.db"))
    archives.add(name="Haupt", backend="local", path=str(tmp_path))
    second_key = str(archives.add(name="NAS 2", backend="local", path=str(second)))
    return StorageSet(archives, LocalStorage(str(tmp_path))), second, second_key


def test_a_rule_files_onto_the_archive_it_names(tmp_path):
    storages, second, second_key = _two_archives(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: RE
                folder: rechnungen
                archive: "{second_key}"
        """,
        storages=storages,
    )

    archiver._process_message(FakeIMAPClient(uid=1, raw=_build_message("RE-1", [("b.pdf", b"D")])), 1)

    assert len(list((second / "rechnungen").glob("*"))) == 1
    assert not (tmp_path / "rechnungen").exists()


def test_a_rule_without_an_archive_uses_the_default_one(tmp_path):
    storages, second, _ = _two_archives(tmp_path)
    archiver = _make_archiver(tmp_path, mapping_content="RE: rechnungen\n", storages=storages)

    archiver._process_message(FakeIMAPClient(uid=2, raw=_build_message("RE-1", [("b.pdf", b"D")])), 2)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1
    assert not (second / "rechnungen").exists()


def test_a_deleted_archive_falls_back_instead_of_losing_the_attachment(tmp_path):
    storages, _, _ = _two_archives(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="""
            version: 2
            rules:
              - keyword: RE
                folder: rechnungen
                archive: "999"
        """,
        storages=storages,
    )

    archiver._process_message(FakeIMAPClient(uid=3, raw=_build_message("RE-1", [("b.pdf", b"D")])), 3)

    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1


def test_an_address_rule_can_send_a_document_to_another_archive(tmp_path):
    storages, second, second_key = _two_archives(tmp_path)
    addresses = _addresses(tmp_path, print_attachments=False, folder="ausdrucke",
                           archive=second_key)
    archiver = _make_archiver(tmp_path, addresses=addresses, storages=storages)

    archiver._process_message(FakeIMAPClient(uid=4, raw=_addressed_message()), 4)

    assert len(list((second / "ausdrucke").glob("*"))) == 1


def test_the_address_archive_wins_over_the_rule_folder_archive(tmp_path):
    """"File it where it usually goes, but on that NAS" has to work."""
    storages, second, second_key = _two_archives(tmp_path)
    addresses = _addresses(tmp_path, print_attachments=False, archive=second_key)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="Vertrag: vertraege\n",
        addresses=addresses,
        storages=storages,
    )

    archiver._process_message(
        FakeIMAPClient(uid=5, raw=_addressed_message(filename="Vertrag_7.pdf")), 5
    )

    assert len(list((second / "vertraege").glob("*"))) == 1


def test_a_quarantined_attachment_stays_on_the_archive_it_was_meant_for(tmp_path):
    storages, second, second_key = _two_archives(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content=f"""
            version: 2
            rules:
              - keyword: RE
                folder: rechnungen
                archive: "{second_key}"
        """,
        storages=storages,
    )

    archiver._process_message(
        FakeIMAPClient(uid=6, raw=_build_message("RE-1", [("Rechnung.exe", b"MZ")])), 6
    )

    assert len(list((second / "quarantaene").glob("*"))) == 1


# --- the quarantine list is read live -------------------------------------------


def test_the_blocked_extension_list_is_read_per_message(tmp_path):
    """Editing it in the web UI must not need a restart."""
    blocked = {"value": frozenset()}
    archiver = _make_archiver(
        tmp_path, mapping_content="RE: rechnungen\n", blocked_extensions=lambda: blocked["value"]
    )

    archiver._process_message(
        FakeIMAPClient(uid=7, raw=_build_message("RE-1", [("a.exe", b"MZ")])), 7
    )
    assert len(list((tmp_path / "rechnungen").glob("*"))) == 1

    blocked["value"] = frozenset({"exe"})
    archiver._process_message(
        FakeIMAPClient(uid=8, raw=_build_message("RE-2", [("b.exe", b"MZ")])), 8
    )

    assert len(list((tmp_path / "quarantaene").glob("*"))) == 1


# --- "print only" never loses an attachment ----------------------------------


def test_print_only_files_the_attachment_when_the_printer_fails(tmp_path):
    class BrokenSpooler(RecordingSpooler):
        def print_bytes(self, printer, data, filename, title=""):
            raise PrintError("Drucker offline")

    store = PrinterStore(str(tmp_path / "printers.db"))
    printer_id = str(store.add(name="Kaputt", destination="drucker_a"))
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=PrintService(store, BrokenSpooler()),
    )

    archiver._process_message(
        FakeIMAPClient(uid=11, raw=_build_message("RE-1", [("beleg.pdf", b"DATA")])), 11
    )

    assert any((tmp_path / "rechnungen").glob("*"))


def test_print_only_without_any_printer_files_the_attachment(tmp_path):
    printing, spooler, _ = _make_printing(tmp_path)
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, archive_attachments=False),
        printing=printing,
    )

    archiver._process_message(
        FakeIMAPClient(uid=12, raw=_build_message("RE-1", [("beleg.pdf", b"DATA")])), 12
    )

    assert spooler.jobs == []
    assert any((tmp_path / "rechnungen").glob("*"))


def test_print_only_with_an_unprintable_format_files_it(tmp_path):
    printing, spooler, (printer_id,) = _make_printing(tmp_path, "drucker_a")
    archiver = _make_archiver(
        tmp_path,
        mapping_content="RE: rechnungen\n",
        account=_account(print_attachments=True, printer=printer_id, archive_attachments=False),
        printing=printing,
    )

    archiver._process_message(
        FakeIMAPClient(uid=13, raw=_build_message("RE-1", [("tabelle.xlsx", b"PK")])), 13
    )

    assert spooler.jobs == []
    assert any((tmp_path / "rechnungen").glob("*tabelle.xlsx"))


def test_settings_changed_in_the_ui_apply_to_the_next_message(tmp_path):
    current = {"options": _make_options()}
    archiver = Archiver(
        lambda: current["options"],
        _make_mapping(tmp_path),
        ProcessedStore(str(tmp_path / "state.db")),
        LocalStorage(str(tmp_path)),
        TEST_ACCOUNT,
    )

    current["options"] = _make_options(fallback_folder="sonstiges")
    archiver._process_message(
        FakeIMAPClient(uid=14, raw=_build_message("Hallo", [("a.pdf", b"x")])), 14
    )

    assert any((tmp_path / "sonstiges").glob("*"))
