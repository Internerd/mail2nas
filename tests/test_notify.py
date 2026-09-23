"""Mail notifications: settings, sending, and when something is worth a mail."""
from __future__ import annotations

import time

import pytest

from mail2nas import journal as j
from mail2nas.notify import (
    NotifyError,
    Notifier,
    NotifySettings,
    NotifyStore,
    send_mail,
    validate,
)
from tests.test_archiver import _make_runtime

FORM = {
    "enabled": "1",
    "recipients": "it@firma.de; chef@firma.de",
    "smtp_host": "smtp.firma.de",
    "smtp_port": "587",
    "smtp_security": "starttls",
    "smtp_user": "mail2nas@firma.de",
    "smtp_password": "geheim",
    "sender": "",
    "delay_minutes": "30",
    "on_connection": "1",
    "on_failures": "1",
    "on_recovery": "1",
}


def test_validate_reads_the_form():
    value = validate(FORM, NotifySettings())

    assert value.recipient_list == ["it@firma.de", "chef@firma.de"]
    assert value.from_address == "mail2nas@firma.de"
    assert value.usable


def test_an_empty_password_keeps_the_stored_one():
    current = validate(FORM, NotifySettings())

    value = validate({**FORM, "smtp_password": ""}, current)

    assert value.smtp_password == "geheim"


@pytest.mark.parametrize(
    "change, message",
    [
        ({"recipients": "kein-mail"}, "Keine gueltige Mailadresse"),
        ({"recipients": ""}, "Empfaenger"),
        ({"smtp_host": ""}, "SMTP-Server"),
        ({"smtp_port": "abc"}, "Port"),
        ({"delay_minutes": "-1"}, "Wartezeit"),
        ({"smtp_security": "xyz"}, "Verschluesselung"),
        ({"smtp_user": "", "sender": ""}, "Absenderadresse"),
    ],
)
def test_validate_rejects_unusable_settings(change, message):
    with pytest.raises(NotifyError, match=message):
        validate({**FORM, **change}, NotifySettings())


def test_disabled_settings_may_be_incomplete():
    value = validate({**FORM, "enabled": "", "smtp_host": "", "recipients": ""}, NotifySettings())

    assert not value.usable


def test_settings_round_trip_through_the_database(tmp_path):
    runtime = _make_runtime(tmp_path)
    store = NotifyStore(runtime.settings)
    value = validate(FORM, NotifySettings())

    store.save(value)

    assert store.load() == value


class FakeSMTP:
    sent: list = []

    def __init__(self, settings):
        self.settings = settings
        self.logged_in = None

    def login(self, user, password):
        self.logged_in = (user, password)

    def send_message(self, message):
        FakeSMTP.sent.append((self.logged_in, message))

    def quit(self):
        pass


def test_send_mail_builds_a_plain_message():
    FakeSMTP.sent = []
    settings = validate(FORM, NotifySettings())

    send_mail(settings, "Betreff", "Text", smtp_factory=FakeSMTP)

    ((login, message),) = FakeSMTP.sent
    assert login == ("mail2nas@firma.de", "geheim")
    assert message["To"] == "it@firma.de, chef@firma.de"
    assert message["Auto-Submitted"] == "auto-generated"
    assert message.get_content().strip() == "Text"


# --- the notifier ------------------------------------------------------------------


def _notifier(tmp_path, **form_changes):
    runtime = _make_runtime(tmp_path)
    NotifyStore(runtime.settings).save(validate({**FORM, **form_changes}, NotifySettings()))
    sent: list[tuple[str, str]] = []
    now = {"t": time.time()}
    notifier = Notifier(
        runtime,
        sender=lambda settings, subject, body: sent.append((subject, body)),
        clock=lambda: now["t"],
    )
    return runtime, notifier, sent, now


def test_a_lasting_mailbox_problem_is_reported_once_and_its_end_too(tmp_path):
    runtime, notifier, sent, now = _notifier(tmp_path)
    account_id = runtime.accounts.add(name="Buchhaltung", host="h", user="u", password="p")
    key = f"account:{account_id}"
    runtime.status.error(key, "Login fehlgeschlagen")

    notifier.evaluate()
    notifier.flush()
    assert sent == []

    now["t"] += 31 * 60
    notifier.evaluate()
    notifier.evaluate()
    notifier.flush()
    assert len(sent) == 1
    assert "Postfach Buchhaltung" in sent[0][0]
    assert "Login fehlgeschlagen" in sent[0][1]

    runtime.status.set(key, "verbunden")
    notifier.evaluate()
    notifier.flush()
    assert len(sent) == 2
    assert "wieder in Ordnung" in sent[1][0]


def test_a_short_problem_is_not_reported(tmp_path):
    runtime, notifier, sent, now = _notifier(tmp_path)
    account_id = runtime.accounts.add(name="A", host="h", user="u", password="p")
    runtime.status.error(f"account:{account_id}", "kurz weg")
    notifier.evaluate()

    runtime.status.set(f"account:{account_id}", "verbunden")
    now["t"] += 60 * 60
    notifier.evaluate()
    notifier.flush()

    assert sent == []


def test_processing_failures_are_sent_as_one_digest(tmp_path):
    runtime, notifier, sent, now = _notifier(tmp_path)
    runtime.journal.record("Postfach A", j.NOT_PRINTED, subject="RE-1", filename="a.pdf",
                           detail="Drucker aus")
    runtime.journal.record("Postfach A", j.FILED, subject="RE-2")
    runtime.journal.record("Postfach A", j.FAILED, detail="kaputt")

    notifier.evaluate()
    runtime.journal.record("Postfach A", j.FAILED, detail="noch eins")
    notifier.evaluate()
    notifier.flush()

    assert len(sent) == 1
    subject, body = sent[0]
    assert "2 Problem" in subject
    assert "Drucker aus" in body and "kaputt" in body and "RE-2" not in body

    now["t"] += 16 * 60
    notifier.evaluate()
    notifier.flush()
    assert len(sent) == 2
    assert "noch eins" in sent[1][1]


def test_failures_from_before_the_start_are_not_sent(tmp_path):
    runtime = _make_runtime(tmp_path)
    NotifyStore(runtime.settings).save(validate(FORM, NotifySettings()))
    runtime.journal.record("Postfach A", j.FAILED, detail="alt")
    sent = []

    notifier = Notifier(runtime, sender=lambda *args: sent.append(args))
    notifier.evaluate()
    notifier.flush()

    assert sent == []


def test_nothing_is_sent_when_switched_off(tmp_path):
    runtime, notifier, sent, now = _notifier(tmp_path, enabled="")
    runtime.journal.record("Postfach A", j.FAILED, detail="kaputt")

    notifier.evaluate()
    notifier.flush()

    assert sent == []


def test_a_missing_archive_is_a_setup_step_not_an_outage(tmp_path):
    runtime = _make_runtime(tmp_path, with_archive=False)
    NotifyStore(runtime.settings).save(validate({**FORM, "delay_minutes": "0"}, NotifySettings()))
    runtime.status.archive.ok = False
    sent = []

    notifier = Notifier(runtime, sender=lambda *args: sent.append(args))
    notifier.evaluate()
    notifier.flush()

    assert sent == []


def test_a_broken_archive_is_reported(tmp_path):
    runtime, notifier, sent, now = _notifier(tmp_path, delay_minutes="0")
    runtime.status.archive.ok = False
    runtime.status.archive.detail = "SMB: Zugriff verweigert"
    runtime.status.archive.failing_since = now["t"]

    notifier.evaluate()
    notifier.flush()

    assert len(sent) == 1
    assert "Standard-Archiv" in sent[0][0]


def test_a_failing_smtp_server_is_remembered(tmp_path):
    runtime = _make_runtime(tmp_path)
    NotifyStore(runtime.settings).save(validate({**FORM, "delay_minutes": "0"}, NotifySettings()))

    def broken(*args):
        raise OSError("Verbindung abgelehnt")

    notifier = Notifier(runtime, sender=broken)
    runtime.status.archive.ok = False
    runtime.status.archive.failing_since = time.time()
    notifier.evaluate()
    notifier.flush()

    assert "Verbindung abgelehnt" in notifier.last_error
