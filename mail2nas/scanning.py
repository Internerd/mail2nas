"""Emptying the pickup folders: what a device wrote, filed like a mail.

One pass over every configured folder, run from the supervisor. The rules,
the quarantine and the naming are the same ones the IMAP path uses - a scan
that arrives by mail and the same scan dropped into a folder must not end up
in different places.

Two properties this has to keep:

* **A file is only touched once it is finished.** A scan being transferred
  over SMB is a file that exists, grows, and is worthless until it stops -
  so nothing is picked up before it has been untouched for a while.
* **The original goes away.** The pickup folder is an outbox, not an archive;
  a copy left behind would be imported again on the next cycle.
"""
from __future__ import annotations

import logging
import time
from datetime import datetime

from .filenames import extension_of, sanitize_filename
from .pickups import MAX_DEPTH, Pickup, PickupStore
from .printing import job_title

logger = logging.getLogger(__name__)

# Names that are never a finished document: dotfiles (the archive's own
# temporary files start with one) and the suffixes devices and SMB clients use
# while a file is still being written.
IGNORED_SUFFIXES = (".tmp", ".part", ".partial", ".crdownload", ".filepart", ".lock", ".!ut")


class PickupRunner:
    """Files everything that is ready, in every configured pickup folder."""

    def __init__(
        self,
        config,
        mapping,
        storages,
        pickups: PickupStore,
        printing=None,
        blocked_extensions=None,
        min_age_seconds: int = 20,
    ):
        self.config = config
        self.mapping = mapping
        self.storages = storages
        self.pickups = pickups
        self.printing = printing
        self._blocked_extensions = blocked_extensions
        self.min_age_seconds = min_age_seconds
        # Remembers the last problem reported per folder, so one that stays
        # unreachable is logged once instead of on every cycle.
        self._reported: dict[int, str] = {}

    @property
    def blocked_extensions(self) -> frozenset[str]:
        if self._blocked_extensions is None:
            return self.config.blocked_extensions
        return self._blocked_extensions()

    # --- one pass ------------------------------------------------------------

    def run_once(self) -> int:
        """Import everything that is ready. Returns the number of files filed."""
        folders = self.pickups.enabled()
        if not folders:
            return 0
        self.mapping.reload()
        total = 0
        for pickup in folders:
            try:
                total += self._empty(pickup)
            except Exception:  # noqa: BLE001 - one broken folder must not stop the rest
                self._report(pickup, f"Abholen fehlgeschlagen: {self._short(pickup)}")
                logger.exception("Pickup %s failed, retrying next cycle", pickup.name)
        return total

    def _short(self, pickup: Pickup) -> str:
        return f"{pickup.name} ({pickup.folder})"

    def _report(self, pickup: Pickup, problem: str | None) -> None:
        if problem is None:
            if self._reported.pop(pickup.id, None):
                logger.info("Pickup %s: folder is reachable again", pickup.name)
            return
        if self._reported.get(pickup.id) != problem:
            logger.warning("Pickup %s: %s", pickup.name, problem)
            self._reported[pickup.id] = problem

    def _empty(self, pickup: Pickup) -> int:
        source = self.storages.get(pickup.archive)
        target = self.storages.get(pickup.target_archive)

        if pickup.files_into_itself():
            self._report(
                pickup,
                "Zielordner liegt im Abholordner - es wird nichts abgeholt, "
                "sonst wuerde dasselbe Dokument endlos wieder eingelesen",
            )
            return 0

        if not source.folder_exists(pickup.parts):
            # Far friendlier than an error: the device needs the folder to
            # exist before it can write into it, and someone has just said
            # where it should be.
            source.create_folder(pickup.folder)
            self._report(pickup, f"Abholordner {pickup.folder} angelegt - er war noch nicht da")
            return 0
        self._report(pickup, None)
        files = source.list_files(pickup.parts, MAX_DEPTH)

        deadline = time.time() - max(0, self.min_age_seconds)
        filed = 0
        for entry in files:
            if entry.size == 0 or entry.name.lower().endswith(IGNORED_SUFFIXES):
                continue
            if entry.mtime > deadline:
                logger.debug("%s is still being written, waiting", entry.relative)
                continue
            try:
                if self._file_one(pickup, source, target, entry):
                    filed += 1
            except Exception:  # noqa: BLE001 - leave it in place and try again later
                logger.exception(
                    "Pickup %s: could not file %s, leaving it in place",
                    pickup.name,
                    entry.relative,
                )
        return filed

    # --- one document ---------------------------------------------------------

    def _file_one(self, pickup: Pickup, source, target, entry) -> bool:
        rule = None
        if not pickup.has_fixed_target:
            rule = self.mapping.match(entry.name, account_id=pickup.rule_scope())

        quarantined = bool(
            {extension_of(entry.name), extension_of(sanitize_filename(entry.name))}
            & self.blocked_extensions
        )
        if quarantined:
            folder = self.config.quarantine_folder
        elif pickup.has_fixed_target:
            folder = pickup.target_folder
        elif rule is not None:
            folder = rule.folder
        else:
            folder = self.config.fallback_folder

        parts = self._target_parts(folder)
        out_name = self._build_filename(entry, pickup)

        if self.config.dry_run:
            logger.info(
                "[dry-run] would move %s -> %s",
                source.display(entry.parts),
                target.display(parts),
            )
            return False

        # Printing first, and from the source: the document has to be read
        # anyway, and a printer that is out of paper must not stop the filing
        # (nor leave the scan in the folder to be printed again next cycle).
        printer = self._printer_for(pickup, quarantined)
        if printer is not None:
            self.printing.send(
                printer, source.read_bytes(entry.relative), entry.name,
                job_title(pickup.name, entry.name),
            )

        if source is target:
            out_path = target.move_unique(entry.parts, parts, out_name)
        else:
            # Two different servers: no streamed move, so copy the bytes over
            # and only then remove the original.
            out_path = target.save_unique(parts, out_name, source.read_bytes(entry.relative))
            source.remove_file(entry.relative)

        logger.info(
            "Pickup %s: '%s' matched '%s'%s -> %s",
            pickup.name,
            entry.name,
            (rule.keyword if rule else None) or ("<fest>" if pickup.has_fixed_target else "<fallback>"),
            " [QUARANTAENE: gesperrte Dateiendung]" if quarantined else "",
            out_path,
        )
        return True

    def _printer_for(self, pickup: Pickup, quarantined: bool):
        if self.printing is None or not self.config.printing_enabled:
            return None
        if quarantined or not pickup.print_attachments:
            return None
        printer = self.printing.printer_for(pickup.printer)
        if printer is None:
            logger.warning(
                "Pickup %s should print but no usable printer is configured", pickup.name
            )
        return printer

    def _target_parts(self, folder: str) -> tuple[str, ...]:
        from .filenames import safe_relative_parts

        for candidate, note in (
            (folder, None),
            (self.config.fallback_folder, "fallback"),
            ("unsorted", "built-in"),
        ):
            try:
                parts = safe_relative_parts(candidate)
            except ValueError as exc:
                logger.error("Unsafe target folder %r (%s) - not writing there", candidate, exc)
                continue
            if note:
                logger.warning("Using %s folder %r instead of %r", note, candidate, folder)
            return parts
        raise ValueError("No usable target folder inside the archive root")

    def _build_filename(self, entry, pickup: Pickup) -> str:
        """Same naming as for mail, with the folder standing in for the sender."""
        filename = sanitize_filename(entry.name)
        mode = self.config.filename_prefix
        if mode == "none":
            return filename
        date_prefix = datetime.fromtimestamp(entry.mtime).strftime("%Y-%m-%d")
        if mode == "date":
            return f"{date_prefix}_{filename}"
        source = sanitize_filename(pickup.name or "scan")
        if mode == "sender":
            return f"{source}_{filename}"
        return f"{date_prefix}_{source}_{filename}"
