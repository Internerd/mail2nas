"""Mail to a person when something needs looking at.

A mailbox that cannot log in, an archive that is not writable, a pickup
folder that is gone, a backup that failed: all of that is on the overview
page - which nobody watches. So mail2nas sends a mail, through an SMTP server
set up in the web UI, to the addresses entered there.

Two kinds of message:

* **Problems that last.** A connection that fails once is normal (a server
  restarting); one that has failed for longer than the configured delay is a
  problem. That is reported once, and once more when it is over.
* **Things that went wrong** with a document - a print job refused, a mail
  that could not be processed. They come from the journal and are sent as one
  summary at most every `DIGEST_INTERVAL`, so a printer that is off for a day
  produces a handful of mails, not hundreds.

Sending happens on a thread of its own: an SMTP server that does not answer
must not hold up the supervisor.
"""
from __future__ import annotations

import logging
import queue
import re
import smtplib
import ssl
import threading
import time
from dataclasses import dataclass, fields, replace
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

from . import journal as j

logger = logging.getLogger(__name__)

SECURITY = {
    "starttls": "STARTTLS (meist Port 587)",
    "ssl": "SSL/TLS (meist Port 465)",
    "none": "unverschluesselt (nur im eigenen Netz)",
}
DELAY_LIMITS = (0, 1_440)
DIGEST_INTERVAL = 15 * 60
MAX_DIGEST_LINES = 50
SMTP_TIMEOUT = 30
_ADDRESS = re.compile(r"^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$")


class NotifyError(ValueError):
    """The notification settings cannot be used."""


@dataclass(frozen=True)
class NotifySettings:
    enabled: bool = False
    recipients: str = ""
    smtp_host: str = ""
    smtp_port: int = 587
    smtp_security: str = "starttls"
    smtp_user: str = ""
    smtp_password: str = ""
    sender: str = ""
    # How long a connection problem has to last before it is reported.
    delay_minutes: int = 30
    on_connection: bool = True
    on_failures: bool = True
    on_recovery: bool = True

    @property
    def recipient_list(self) -> list[str]:
        return split_addresses(self.recipients)

    @property
    def from_address(self) -> str:
        return self.sender or self.smtp_user

    @property
    def usable(self) -> bool:
        return bool(self.enabled and self.smtp_host and self.recipient_list and self.from_address)


def split_addresses(text: str) -> list[str]:
    return [part.strip() for part in re.split(r"[,;\s]+", text or "") if part.strip()]


def _key(name: str) -> str:
    return f"notify.{name}"


class NotifyStore:
    """The notification settings, in the key/value settings table."""

    def __init__(self, settings):
        self._settings = settings

    def load(self) -> NotifySettings:
        defaults = NotifySettings()
        values = {}
        for spec in fields(NotifySettings):
            raw = self._settings.get(_key(spec.name))
            if raw is None:
                continue
            default = getattr(defaults, spec.name)
            try:
                if isinstance(default, bool):
                    values[spec.name] = raw == "1"
                elif isinstance(default, int):
                    values[spec.name] = int(raw)
                else:
                    values[spec.name] = raw
            except ValueError:
                logger.warning("Stored notification setting %s=%r is unusable", spec.name, raw)
        return replace(defaults, **values)

    def save(self, value: NotifySettings) -> None:
        for spec in fields(NotifySettings):
            item = getattr(value, spec.name)
            if isinstance(item, bool):
                item = "1" if item else "0"
            self._settings.set(_key(spec.name), str(item))


def validate(form, current: NotifySettings) -> NotifySettings:
    """The submitted form as settings. An empty password keeps the stored one."""
    recipients = split_addresses(form.get("recipients", ""))
    bad = [address for address in recipients if not _ADDRESS.match(address)]
    if bad:
        raise NotifyError(f"Keine gueltige Mailadresse: {', '.join(bad)}")
    sender = (form.get("sender") or "").strip()
    if sender and not _ADDRESS.match(sender):
        raise NotifyError(f"Keine gueltige Absenderadresse: {sender}")
    security = (form.get("smtp_security") or "starttls").strip()
    if security not in SECURITY:
        raise NotifyError("Unbekannte Verschluesselung.")
    try:
        port = int((form.get("smtp_port") or "").strip())
    except ValueError:
        raise NotifyError("Der SMTP-Port muss eine Zahl sein.") from None
    if not 1 <= port <= 65535:
        raise NotifyError("Der SMTP-Port muss zwischen 1 und 65535 liegen.")
    try:
        delay = int((form.get("delay_minutes") or "0").strip())
    except ValueError:
        raise NotifyError("Die Wartezeit muss eine ganze Zahl sein.") from None
    if not DELAY_LIMITS[0] <= delay <= DELAY_LIMITS[1]:
        raise NotifyError(
            f"Die Wartezeit muss zwischen {DELAY_LIMITS[0]} und {DELAY_LIMITS[1]} Minuten liegen."
        )
    host = (form.get("smtp_host") or "").strip()
    user = (form.get("smtp_user") or "").strip()
    password = form.get("smtp_password") or ""
    if not password and user == current.smtp_user:
        password = current.smtp_password
    value = NotifySettings(
        enabled=bool(form.get("enabled")),
        recipients=", ".join(recipients),
        smtp_host=host,
        smtp_port=port,
        smtp_security=security,
        smtp_user=user,
        smtp_password=password,
        sender=sender,
        delay_minutes=delay,
        on_connection=bool(form.get("on_connection")),
        on_failures=bool(form.get("on_failures")),
        on_recovery=bool(form.get("on_recovery")),
    )
    if value.enabled:
        if not host:
            raise NotifyError("Bitte einen SMTP-Server angeben.")
        if not recipients:
            raise NotifyError("Bitte mindestens eine Empfaengeradresse angeben.")
        if not value.from_address or not _ADDRESS.match(value.from_address):
            raise NotifyError(
                "Bitte eine Absenderadresse angeben (oder einen Benutzer, der eine Mailadresse ist)."
            )
    return value


def send_mail(settings: NotifySettings, subject: str, body: str,
              timeout: int = SMTP_TIMEOUT, smtp_factory=None) -> None:
    """Send one plain-text mail. Raises on any failure."""
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = settings.from_address
    message["To"] = ", ".join(settings.recipient_list)
    message["Date"] = formatdate(localtime=True)
    message["Message-ID"] = make_msgid(domain="mail2nas.local")
    message["Auto-Submitted"] = "auto-generated"
    message.set_content(body)

    context = ssl.create_default_context()
    if smtp_factory is not None:
        client = smtp_factory(settings)
    elif settings.smtp_security == "ssl":
        client = smtplib.SMTP_SSL(settings.smtp_host, settings.smtp_port, timeout=timeout,
                                  context=context)
    else:
        client = smtplib.SMTP(settings.smtp_host, settings.smtp_port, timeout=timeout)
    try:
        if settings.smtp_security == "starttls" and smtp_factory is None:
            client.starttls(context=context)
        if settings.smtp_user:
            client.login(settings.smtp_user, settings.smtp_password)
        client.send_message(message)
    finally:
        try:
            client.quit()
        except Exception:  # noqa: BLE001 - the mail is out, or the error is already known
            pass


@dataclass
class _Problem:
    label: str
    detail: str
    since: float
    notified: bool = False


class Notifier:
    """Decides what is worth a mail; a background thread sends it."""

    def __init__(self, runtime, sender=send_mail, clock=time.time):
        self.runtime = runtime
        self.store = NotifyStore(runtime.settings)
        self._send = sender
        self._clock = clock
        self._problems: dict[str, _Problem] = {}
        journal = getattr(runtime, "journal", None)
        # Only what happens from now on; old failures were before our time.
        self._last_journal_id = journal.last_id() if journal is not None else 0
        self._pending: list[j.Entry] = []
        self._last_digest = 0.0
        self._queue: queue.Queue = queue.Queue()
        self._lock = threading.Lock()
        self._thread: threading.Thread | None = None
        self.last_sent: float | None = None
        self.last_error: str = ""

    # --- what is wrong right now --------------------------------------------

    def current_problems(self) -> dict[str, tuple[str, str, float | None]]:
        """key -> (label, detail, failing since or None)."""
        runtime = self.runtime
        found: dict[str, tuple[str, str, float | None]] = {}
        archive = runtime.status.archive
        # "No archive configured yet" is a setup step, not an outage.
        if archive.ok is False and runtime.default_archive() is not None:
            found["archive"] = ("Standard-Archiv", archive.detail, archive.failing_since)
        names = {f"account:{a.id}": a.name for a in runtime.accounts.enabled()}
        for key, row in runtime.status.workers().items():
            if key in names and row.failing_since is not None:
                found[key] = (f"Postfach {names[key]}", row.last_error, row.failing_since)
        supervisor = getattr(runtime, "supervisor", None)
        if supervisor is not None:
            for pickup_id, text in supervisor.pickup_problems().items():
                found[f"pickup:{pickup_id}"] = ("Abholordner", text, None)
        backup = getattr(runtime, "backup_status", None)
        if backup is not None and backup.ok is False:
            found["backup"] = ("Automatische Sicherung", backup.detail, backup.failing_since)
        return found

    # --- one supervisor step ---------------------------------------------------

    def evaluate(self) -> None:
        settings = self.store.load()
        now = self._clock()
        current = self.current_problems()

        for key, (label, detail, since) in current.items():
            problem = self._problems.get(key)
            if problem is None:
                problem = self._problems[key] = _Problem(label, detail, since or now)
            problem.detail = detail or problem.detail
            if not problem.notified and now - problem.since >= settings.delay_minutes * 60:
                problem.notified = True
                if settings.on_connection:
                    self._queue_mail(
                        settings,
                        f"mail2nas: {label} - Problem",
                        f"{label} funktioniert seit {_minutes(now - problem.since)} nicht.\n\n"
                        f"{problem.detail}\n\n"
                        "Solange bleibt dort alles liegen; nichts geht verloren. Details in der "
                        "Weboberflaeche unter Uebersicht und Protokoll.",
                    )

        for key in list(self._problems):
            if key in current:
                continue
            problem = self._problems.pop(key)
            if problem.notified and settings.on_connection and settings.on_recovery:
                self._queue_mail(
                    settings,
                    f"mail2nas: {problem.label} - wieder in Ordnung",
                    f"{problem.label} funktioniert wieder (Problem seit "
                    f"{_minutes(now - problem.since)}). Was in der Zwischenzeit angekommen "
                    "ist, wird jetzt verarbeitet.",
                )

        journal = getattr(self.runtime, "journal", None)
        if journal is not None:
            new = journal.entries(after_id=self._last_journal_id, problems_only=True,
                                  limit=500, oldest_first=True)
            if new:
                self._last_journal_id = new[-1].id
                if settings.on_failures:
                    self._pending.extend(new)
            if self._pending and now - self._last_digest >= DIGEST_INTERVAL:
                self._queue_mail(settings, *self._digest(self._pending))
                self._pending = []
                self._last_digest = now

    @staticmethod
    def _digest(entries) -> tuple[str, str]:
        lines = []
        for entry in entries[:MAX_DIGEST_LINES]:
            what = " - ".join(part for part in (entry.subject, entry.filename) if part)
            lines.append(
                f"{entry.local_at}  {entry.source}: {entry.action_label}"
                + (f" ({what})" if what else "")
                + (f"\n    {entry.detail}" if entry.detail else "")
            )
        if len(entries) > MAX_DIGEST_LINES:
            lines.append(f"... und {len(entries) - MAX_DIGEST_LINES} weitere.")
        subject = f"mail2nas: {len(entries)} Problem(e) bei der Verarbeitung"
        body = (
            "Bei der Verarbeitung ist Folgendes schiefgegangen:\n\n"
            + "\n".join(lines)
            + "\n\nDas vollstaendige Protokoll steht in der Weboberflaeche unter Protokoll."
        )
        return subject, body

    # --- sending --------------------------------------------------------------

    def _queue_mail(self, settings: NotifySettings, subject: str, body: str) -> None:
        # Labels come from names typed in the UI; a line break in a header
        # would make the mail unsendable (or worse).
        subject = " ".join(subject.split())
        if not settings.usable:
            logger.info("Notification not sent (notifications are off): %s", subject)
            return
        with self._lock:
            self._queue.put((settings, subject, body))
            if self._thread is None:
                self._thread = threading.Thread(target=self._drain, name="mail2nas-notify",
                                                daemon=True)
                self._thread.start()

    def _drain(self) -> None:
        while True:
            # Under the lock, so a mail queued right now either is seen here
            # or starts a new thread - never neither.
            with self._lock:
                try:
                    settings, subject, body = self._queue.get_nowait()
                except queue.Empty:
                    self._thread = None
                    return
            try:
                self._send(settings, subject, body)
            except Exception as exc:  # noqa: BLE001 - report, never crash the thread
                self.last_error = f"{exc.__class__.__name__}: {exc}"
                logger.error("Could not send the notification %r: %s", subject, self.last_error)
            else:
                self.last_sent = self._clock()
                self.last_error = ""
                logger.info("Sent notification: %s", subject)

    def flush(self, timeout: float = 10) -> None:
        """Wait for queued mails to be sent (for tests)."""
        thread = self._thread
        if thread is not None:
            thread.join(timeout)


def _minutes(seconds: float) -> str:
    minutes = int(seconds // 60)
    if minutes < 1:
        return "weniger als einer Minute"
    if minutes < 120:
        return f"{minutes} Minute(n)"
    return f"{minutes // 60} Stunde(n)"
