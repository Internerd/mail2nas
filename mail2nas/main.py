from __future__ import annotations

import logging
import os
import sys
import time

from . import storage as storage_module
from .archiver import Archiver
from .config import Config
from .mapping import Mapping
from .state import ProcessedStore

logger = logging.getLogger("mail2nas")


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    storage = storage_module.from_config(config)
    # Fail fast: an unreachable share is otherwise indistinguishable from an
    # empty one, and attachments would land somewhere they silently vanish.
    storage.check_writable()
    mapping = Mapping(storage, config.mapping_path, config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    archiver = Archiver(config, mapping, store, storage)

    logger.info(
        "Starting mail2nas: imap=%s folder=%s mode=%s storage=%s (%s) dry_run=%s",
        config.imap_host,
        config.imap_folder,
        config.imap_mode,
        storage.description,
        config.storage_backend,
        config.dry_run,
    )

    try:
        while True:
            try:
                client = archiver.connect()
            except Exception:
                logger.exception("IMAP connection failed, retrying in %ss", config.poll_interval)
                time.sleep(config.poll_interval)
                continue

            try:
                if config.imap_mode == "idle":
                    _run_idle(archiver, client, config)
                else:
                    _run_poll(archiver, client, config)
            except Exception:
                logger.exception("IMAP session failed, reconnecting in %ss", config.poll_interval)
            finally:
                try:
                    client.logout()
                except Exception:
                    pass
            time.sleep(config.poll_interval)
    finally:
        store.close()
        storage.close()


def _run_poll(archiver: Archiver, client, config: Config) -> None:
    while True:
        count = archiver.run_once(client)
        if count:
            logger.info("Processed %d message(s)", count)
        time.sleep(config.poll_interval)


def _run_idle(archiver: Archiver, client, config: Config) -> None:
    count = archiver.run_once(client)
    if count:
        logger.info("Processed %d message(s)", count)

    idle_timeout = config.poll_interval or 300
    while True:
        client.idle()
        try:
            client.idle_check(timeout=idle_timeout)
        finally:
            client.idle_done()
        count = archiver.run_once(client)
        if count:
            logger.info("Processed %d message(s)", count)


if __name__ == "__main__":
    main()
