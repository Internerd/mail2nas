"""Bringing an installation of any older version up to this one.

Two steps, both idempotent and both guarded by a flag in the database, so
they run exactly once no matter how often the container restarts:

1. **The `.env`** (`seed_from_legacy`): mailbox, archive, first printer and
   the general settings are written into the database. Runs at startup,
   before anything else; it needs nothing but the environment.

2. **The rule file on the share** (`migrate_rule_file`): an older version kept
   the keyword rules as `mapping.yaml` on the NAS. It is read once, stored in
   the database and renamed on the share to `<name>.migriert`, so nobody keeps
   editing a file that no longer does anything. This needs the archive to be
   reachable, so it is retried until it has happened - and the archiver waits
   for it: filing mail with an empty rule list would put every attachment of
   the first minutes into the fallback folder.
"""
from __future__ import annotations

import logging

from . import accounts as accounts_module
from . import archives as archives_module
from . import printers as printers_module
from .filenames import safe_relative_parts
from .legacy import LegacyEnv
from .mapping import MappingError, RuleStore, rules_from_yaml

logger = logging.getLogger(__name__)

SETTING_MAPPING_PATH = "mapping_path"
SETTING_RULES_MIGRATED = "rules_migrated"
SETTING_RULES_NOTE = "rules_migration_note"
MIGRATED_SUFFIX = ".migriert"


def seed_from_legacy(runtime, legacy: LegacyEnv) -> None:
    """Step 1: carry every value of an older `.env` into the database."""
    settings = runtime.settings
    runtime.options_store.seed(legacy)
    accounts_module.seed_from_config(runtime.accounts, settings, legacy)
    if runtime.printers is not None:
        printers_module.seed_from_config(runtime.printers, settings, legacy)
    if runtime.archives is not None:
        archives_module.seed_from_config(runtime.archives, settings, legacy)
    # Where the old rule file was, for step 2. A path already stored (the old
    # UI could move the file) is the newer statement and wins.
    if not settings.get(SETTING_MAPPING_PATH):
        settings.set(SETTING_MAPPING_PATH, legacy.mapping_path or "mapping.yaml")
    runtime.invalidate_options()


def rules_settled(settings) -> bool:
    """True once there is nothing (left) to take over from the share."""
    return bool(settings.get(SETTING_RULES_MIGRATED))


def migrate_rule_file(settings, store: RuleStore, storage) -> bool:
    """Step 2: take the rule file over from the share. True when settled.

    `storage` is the default archive, or None while there is none. Returns
    False if it should be tried again later (share unreachable), True once
    it has happened or there turned out to be nothing to do.
    """
    if rules_settled(settings):
        return True

    if store.count():
        # Rules already exist in the database (e.g. imported by hand before
        # the share came back). They are the newer statement.
        _settle(settings, "")
        return True

    if storage is None:
        # No archive configured: then there is no share an old file could be
        # on either - this is a fresh installation.
        _settle(settings, "")
        return True

    relative = settings.get(SETTING_MAPPING_PATH) or "mapping.yaml"
    try:
        relative = "/".join(safe_relative_parts(relative))
    except ValueError:
        _settle(settings, f"Der gespeicherte Pfad {relative!r} der alten Mapping-Datei ist ungueltig.")
        return True

    try:
        text = storage.read_text(relative)
    except FileNotFoundError:
        logger.info("No rule file %s on the archive - nothing to take over", relative)
        _settle(settings, "")
        return True
    except Exception as exc:  # noqa: BLE001 - the share may simply be down right now
        logger.warning("Rule file %s not readable yet (%s) - retrying", relative, exc)
        return False

    try:
        rules = rules_from_yaml(text)
    except MappingError as exc:
        # Nothing is lost: the file stays where it is, and the UI says why it
        # was not taken over and offers the import form.
        logger.error("Rule file %s could not be taken over: %s", relative, exc)
        _settle(
            settings,
            f"Die alte Mapping-Datei {relative} konnte nicht uebernommen werden ({exc}). "
            "Sie liegt unveraendert auf der Freigabe - korrigieren und unter "
            "Zuordnungen importieren.",
        )
        return True

    store.save(rules)
    target = relative + MIGRATED_SUFFIX
    try:
        storage.write_text(target, text)
        storage.remove_file(relative)
        where = f"umbenannt in {target}"
    except Exception as exc:  # noqa: BLE001 - the rules are safe, the rename is cosmetics
        logger.warning("Could not rename %s after taking it over (%s)", relative, exc)
        where = "auf der Freigabe liegen geblieben (wird nicht mehr gelesen)"
    logger.info("Took over %d rule(s) from %s", len(rules), relative)
    _settle(
        settings,
        f"{len(rules)} Zuordnung(en) aus {relative} uebernommen. Die Datei wurde {where}; "
        "Zuordnungen werden ab jetzt nur noch hier gepflegt.",
    )
    return True


def _settle(settings, note: str) -> None:
    settings.set(SETTING_RULES_MIGRATED, "1")
    if note:
        settings.set(SETTING_RULES_NOTE, note)


def migration_status(runtime) -> dict:
    """What the update script and the CLI want to know."""
    settings = runtime.settings
    return {
        "options_seeded": runtime.options_store.seeded(),
        "accounts_seeded": bool(settings.get(accounts_module.SETTING_ACCOUNTS_SEEDED)),
        "archives_seeded": bool(settings.get(archives_module.SETTING_ARCHIVES_SEEDED)),
        "printers_seeded": bool(settings.get(printers_module.SETTING_PRINTERS_SEEDED)),
        "rules_migrated": rules_settled(settings),
    }
