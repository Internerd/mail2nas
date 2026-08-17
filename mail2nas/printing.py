"""Sending attachments to a printer.

Printing goes through the `lp` client from CUPS rather than through a Python
IPP library: every NAS-adjacent printer setup already has a CUPS server (or a
printer that speaks IPP and can be added to one), `lp` handles the driver and
format conversion side, and it means no long-lived printer connection has to
be maintained inside a service whose real job is archiving mail.

Two rules the rest of the code depends on:

* **Nothing is printed that was quarantined.** That decision is made in the
  archiver; this module only ever sees what it is handed. What it does check
  is the file type: an unknown format sent to a queue produces a stack of
  garbage paper, so only known-printable extensions are spooled.
* **A failing printer never fails the archiving.** Paper is the copy, the
  share is the archive. Every error is logged and swallowed by
  `PrintService.send`, so an offline printer cannot stop mail from being
  filed - or, worse, cause the same mail to be processed again and again.
"""
from __future__ import annotations

import logging
import os
import subprocess
import tempfile

from .config import DEFAULT_PRINTABLE_EXTENSIONS
from .filenames import extension_of, sanitize_filename
from .printers import Printer, PrinterStore

logger = logging.getLogger(__name__)

# The job title shows up in the CUPS queue. Keep it short and free of control
# characters - it is built from an attacker-supplied filename.
MAX_TITLE_LENGTH = 80


class PrintError(RuntimeError):
    """A print job could not be handed to CUPS."""


def parse_extensions(raw: str) -> frozenset[str]:
    return frozenset(ext.strip().lower().lstrip(".") for ext in raw.split(",") if ext.strip())


def job_title(prefix: str, filename: str) -> str:
    title = f"{prefix}: {filename}" if prefix else filename
    title = "".join(char for char in title if char.isprintable())
    return title[:MAX_TITLE_LENGTH] or "mail2nas"


def build_command(printer: Printer, path: str, title: str, lp_binary: str = "lp") -> list[str]:
    """Build the `lp` invocation for one job.

    Split out from the call so the command can be asserted on in tests without
    a printer anywhere near. Note the arguments are passed to `lp` directly -
    there is no shell involved, so nothing here needs quoting.
    """
    command = [lp_binary]
    if printer.server:
        command += ["-h", printer.server]
    command += ["-d", printer.destination, "-t", title]
    if printer.copies > 1:
        command += ["-n", str(printer.copies)]
    for option in printer.option_list:
        command += ["-o", option]
    # "--" so a filename can never be read as an option, whatever it is called.
    return [*command, "--", path]


class Spooler:
    """Hands bytes to CUPS, one temporary file per job."""

    def __init__(
        self,
        lp_binary: str = "lp",
        timeout: int = 120,
        printable_extensions: frozenset[str] = frozenset(),
        dry_run: bool = False,
    ):
        self._lp_binary = lp_binary
        self._timeout = timeout
        self._printable = printable_extensions or parse_extensions(DEFAULT_PRINTABLE_EXTENSIONS)
        self._dry_run = dry_run

    @property
    def printable_extensions(self) -> frozenset[str]:
        return self._printable

    def can_print(self, filename: str) -> bool:
        return extension_of(sanitize_filename(filename)) in self._printable

    def print_bytes(self, printer: Printer, data: bytes, filename: str, title: str = "") -> str:
        """Spool `data` to `printer`. Returns what `lp` reported, for the log.

        Raises PrintError for anything that went wrong, including a missing
        `lp` binary - which is the most likely failure on a container that was
        built before printing existed.
        """
        extension = extension_of(sanitize_filename(filename))
        return self._spool(printer, data, extension, title or job_title("", filename))

    def print_test_page(self, printer: Printer) -> str:
        """Print a page that says where it came from, to verify a queue."""
        page = (
            "mail2nas - Testseite\n"
            "====================\n\n"
            f"Drucker: {printer.label()}\n"
            f"Optionen: {printer.options or '(keine)'}\n"
            f"Kopien: {printer.copies}\n\n"
            "Kommt diese Seite an, funktioniert die Warteschlange.\n"
        )
        return self._spool(printer, page.encode("utf-8"), "txt", "mail2nas Testseite")

    def _spool(self, printer: Printer, data: bytes, extension: str, title: str) -> str:
        if self._dry_run:
            logger.info("[dry-run] would print %r on %s", title, printer.label())
            return "dry-run"

        suffix = f".{extension}" if extension else ""
        handle, path = tempfile.mkstemp(prefix="mail2nas-print-", suffix=suffix)
        try:
            # The attachment is untrusted content sitting in a shared temp
            # directory until CUPS has picked it up, so nobody else may read it.
            os.chmod(path, 0o600)
            with os.fdopen(handle, "wb") as fh:
                fh.write(data)
            return self._run(build_command(printer, path, title, self._lp_binary))
        finally:
            try:
                os.unlink(path)
            except OSError:  # pragma: no cover - only if something else removed it
                logger.debug("Could not remove the temporary print file %s", path, exc_info=True)

    def _run(self, command: list[str]) -> str:
        try:
            result = subprocess.run(
                command, capture_output=True, text=True, timeout=self._timeout, check=False
            )
        except FileNotFoundError:
            raise PrintError(
                f"{self._lp_binary} nicht gefunden - im Container fehlt das Paket cups-client "
                "(oder LP_BINARY zeigt auf den falschen Pfad)."
            ) from None
        except subprocess.TimeoutExpired:
            raise PrintError(
                f"Der Druckauftrag wurde nach {self._timeout}s abgebrochen - "
                "antwortet der CUPS-Server?"
            ) from None
        except OSError as exc:
            raise PrintError(f"Druckauftrag fehlgeschlagen: {exc}") from exc

        if result.returncode != 0:
            message = (result.stderr or result.stdout or "").strip()
            raise PrintError(message or f"{self._lp_binary} endete mit Code {result.returncode}")
        return (result.stdout or "").strip()


class PrintService:
    """Which printer a job goes to, and the promise that it never raises.

    `printer_for` implements the precedence the UI documents: the most
    specific setting wins. A mapping rule that names a printer beats the
    mailbox default, which beats "no printer configured" (nothing is printed,
    and it is logged - silently dropping paper someone asked for is worse than
    a log line).
    """

    def __init__(self, printers: PrinterStore, spooler: Spooler):
        self._printers = printers
        self._spooler = spooler

    @property
    def spooler(self) -> Spooler:
        return self._spooler

    def configured(self) -> bool:
        return bool(self._printers.enabled())

    def printer_for(self, *keys: str) -> Printer | None:
        """First enabled printer among `keys`, which may contain blanks."""
        for key in keys:
            if not key or str(key) in ("0", "None"):
                continue
            printer = self._printers.by_key(key)
            if printer is None:
                logger.warning("Printer %r is configured somewhere but no longer exists", key)
                continue
            if not printer.enabled:
                logger.warning("Printer %r is paused - not printing on it", printer.label())
                continue
            return printer
        return None

    def send(self, printer: Printer, data: bytes, filename: str, title: str = "") -> bool:
        """Print, reporting failures rather than raising them.

        Returns True if CUPS accepted the job. The archiver treats a False as
        "the paper copy did not happen" and carries on: the attachment is
        already on the share, and re-processing the mail to retry the print
        would duplicate the archived file.
        """
        if not self._spooler.can_print(filename):
            logger.warning(
                "Not printing %r on %s: %s is not in PRINTABLE_EXTENSIONS",
                filename,
                printer.label(),
                extension_of(sanitize_filename(filename)) or "(no extension)",
            )
            return False
        try:
            reply = self._spooler.print_bytes(printer, data, filename, title)
        except PrintError as exc:
            logger.error("Printing %r on %s failed: %s", filename, printer.label(), exc)
            return False
        logger.info("Printed %r on %s%s", filename, printer.label(), f" ({reply})" if reply else "")
        return True


def from_config(config, printers: PrinterStore) -> PrintService:
    """Build the print service described by the configuration."""
    return PrintService(
        printers,
        Spooler(
            lp_binary=config.lp_binary,
            timeout=config.print_timeout,
            printable_extensions=config.printable_extensions,
            dry_run=config.dry_run,
        ),
    )
