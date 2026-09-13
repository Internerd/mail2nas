from __future__ import annotations

import logging
import os
import time
from datetime import datetime
from pathlib import Path

from .config import Config
from .filing import Filer
from .mapping import Mapping, Target
from .settings import Printer, Settings
from .shares import ShareSet

logger = logging.getLogger(__name__)

# Names that are never a finished document: dotfiles (including our own
# ".mail2nas-tmp-*"), plus the suffixes printers and SMB clients use while a
# file is still being written.
_IGNORED_SUFFIXES = (".tmp", ".part", ".partial", ".crdownload", ".filepart", ".lock")
_MAX_DEPTH = 8


class PrinterPickup:
    """Imports documents that devices drop into a folder on a share.

    Multifunction printers can usually either mail their scans or write them
    straight onto an SMB share ("Scan to Folder"). The second way never
    involves a mailbox, so this walks each device's pickup folder and files
    what it finds with exactly the same rules the mail path uses.

    Files are moved out of the pickup folder, not copied: it is the device's
    outbox, and leaving the original behind would re-import it forever. A file
    is only touched once it has been untouched for `printer_min_age_seconds`,
    so a scan that is still being transferred is left alone.

    No size limit applies here (unlike mail attachments): the file is already
    on a local mount, and it is streamed rather than read into memory.
    """

    def __init__(
        self,
        config: Config,
        settings: Settings,
        mapping: Mapping,
        shares: ShareSet,
        filer: Filer | None = None,
    ):
        self.config = config
        self.settings = settings
        self.mapping = mapping
        self.shares = shares
        self.filer = filer or Filer(config, mapping, shares)
        # Remembers the last problem reported per printer, so a folder that
        # stays unreachable is logged once instead of on every cycle.
        self._reported: dict[str, str] = {}

    # --- public ----------------------------------------------------------

    def run_once(self) -> int:
        """Import everything that is ready. Returns the number of files filed."""
        printers = self.settings.pickup_printers()
        if not printers:
            return 0
        self.mapping.reload()
        total = 0
        for printer in printers:
            try:
                total += self._import(printer)
            except Exception:
                logger.exception("[%s] pickup failed, retrying next cycle", printer.id)
        return total

    # --- internals -------------------------------------------------------

    def _report(self, printer: Printer, problem: str | None) -> None:
        if problem is None:
            if self._reported.pop(printer.id, None):
                logger.info("[%s] pickup folder is reachable again", printer.id)
            return
        if self._reported.get(printer.id) != problem:
            logger.warning("[%s] %s", printer.id, problem)
            self._reported[printer.id] = problem

    def source_dir(self, printer: Printer) -> Path | None:
        """The device's pickup folder, or None if it is not usable right now."""
        problem = self.shares.problem_with(printer.source_share)
        if problem:
            self._report(printer, f"Quell-Ablage nicht verfuegbar: {problem}")
            return None
        try:
            directory = self.shares.resolve(printer.source_share, printer.source_folder)
        except ValueError as exc:
            self._report(printer, f"Abholordner nicht zulaessig: {exc}")
            return None
        if not directory.is_dir():
            self._report(printer, f"Abholordner {directory} existiert nicht")
            return None
        if not os.access(directory, os.W_OK | os.X_OK):
            # Importing means removing the original, which needs write access
            # to the folder it is in - not just to the file.
            self._report(
                printer,
                f"Abholordner {directory} ist nicht beschreibbar - abgeholte Dateien "
                "koennten nicht entfernt werden",
            )
            return None
        self._report(printer, None)
        return directory

    def _ready_files(self, directory: Path) -> list[Path]:
        """Files in the pickup folder that are complete enough to be moved."""
        min_age = max(0, self.settings.printer_min_age_seconds)
        deadline = time.time() - min_age
        ready: list[Path] = []
        root_depth = len(directory.parts)
        for dirpath, dirnames, filenames in os.walk(directory):
            here = Path(dirpath)
            if len(here.parts) - root_depth >= _MAX_DEPTH:
                dirnames[:] = []
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for name in sorted(filenames):
                if name.startswith(".") or name.lower().endswith(_IGNORED_SUFFIXES):
                    continue
                path = here / name
                try:
                    stat = path.stat()
                except OSError:
                    continue  # vanished between listing and stat
                if not path.is_file() or stat.st_size == 0:
                    continue
                if stat.st_mtime > deadline:
                    logger.debug("%s is still being written, waiting", path)
                    continue
                ready.append(path)
        return ready

    def _import(self, printer: Printer) -> int:
        directory = self.source_dir(printer)
        if directory is None:
            return 0

        forced: Target | None = None
        if printer.has_fixed_target:
            forced = Target(
                folder=printer.target_folder,
                share=printer.target_share,
                keyword=f"drucker:{printer.id}",
            )
        fallback = Target(folder=self.config.fallback_folder, share=printer.target_share)

        filed = 0
        for path in self._ready_files(directory):
            try:
                target, quarantined = self.filer.classify(
                    path.name, fallback, account=self.rule_scope(printer), forced_target=forced
                )
                target_dir = self.filer.directory_for(target, quarantined)
                if self._would_loop(directory, target_dir):
                    logger.error(
                        "[%s] target folder %s is inside the pickup folder - skipping %s",
                        printer.id,
                        target_dir,
                        path.name,
                    )
                    continue

                date_prefix = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d")
                out_name = self.filer.build_filename(date_prefix, printer.id, path.name)

                if self.config.dry_run:
                    logger.info("[dry-run] [%s] would move %s -> %s", printer.id, path, target_dir)
                    continue

                out_path = self.filer.move_file(path, target_dir, out_name)
                filed += 1
                logger.info(
                    "[%s] '%s' matched '%s'%s -> %s",
                    printer.id,
                    path.name,
                    target.keyword or "<fallback>",
                    " [QUARANTAENE: gesperrte Dateiendung]" if quarantined else "",
                    out_path,
                )
            except Exception:
                logger.exception("[%s] could not file %s, leaving it in place", printer.id, path)
        return filed

    @staticmethod
    def rule_scope(printer: Printer) -> str:
        """The account id a pickup files under.

        A document dropped into a folder did not arrive through any mailbox,
        so only rules that apply to "all accounts" may claim it. Account ids
        never contain a colon, so this never collides with a real one.
        """
        return f"drucker:{printer.id}"

    @staticmethod
    def _would_loop(pickup_dir: Path, target_dir: Path) -> bool:
        """True if filing would leave the document inside the pickup folder."""
        try:
            target_dir.resolve().relative_to(pickup_dir.resolve())
            return True
        except (ValueError, OSError):
            return False
