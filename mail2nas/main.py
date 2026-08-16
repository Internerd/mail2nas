from __future__ import annotations

import logging
import os
import sys
import time
from pathlib import Path

from .archiver import Archiver
from .config import Config
from .mapping import Mapping
from .state import ProcessedStore

logger = logging.getLogger("mail2nas")


def _check_storage_root(config: Config) -> None:
    """Fail fast if the archive target is missing or read-only.

    Without this, a share that failed to mount is indistinguishable from an
    empty one: attachments would be written into the container's own
    filesystem and quietly vanish with the container.
    """
    root = Path(config.storage_root)
    if not root.is_dir():
        raise SystemExit(
            f"STORAGE_ROOT {config.storage_root} does not exist or is not a directory - "
            "is the SMB share mounted?"
        )
    if not os.access(root, os.W_OK | os.X_OK):
        raise SystemExit(
            f"STORAGE_ROOT {config.storage_root} is not writable by uid {os.getuid()} - "
            "check the mount options (uid/gid/file_mode) and the share permissions."
        )


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    _check_storage_root(config)
    mapping_full_path = os.path.join(config.storage_root, config.mapping_path)
    mapping = Mapping(mapping_full_path, config.fallback_folder)
    store = ProcessedStore(config.state_db_path)
    archiver = Archiver(config, mapping, store)

    logger.info(
        "Starting mail2nas: imap=%s folder=%s mode=%s storage=%s dry_run=%s",
        config.imap_host,
        config.imap_folder,
        config.imap_mode,
        config.storage_root,
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
