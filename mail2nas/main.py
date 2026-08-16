from __future__ import annotations

import logging
import os
import sys
import threading
from pathlib import Path

from .config import Config
from .filenames import safe_join
from .mapping import Mapping
from .runner import Runner
from .settings import Settings
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


def _start_web(config: Config, settings: Settings, mapping: Mapping, runner: Runner) -> None:
    """Serve the configuration UI in a background thread, if it is configured."""
    if not config.web_enabled:
        logger.info("Web UI disabled (WEB_ENABLED=false)")
        return
    if not config.web_password:
        # The page shows and edits IMAP credentials, so refuse to serve it
        # without authentication rather than defaulting to something weak.
        logger.warning(
            "Web UI not started: WEB_PASSWORD is empty. Set it to enable the configuration page."
        )
        return

    try:
        from waitress import serve

        from .web import create_app
    except ImportError:
        logger.warning("Web UI not started: Flask/waitress are not installed")
        return

    app = create_app(config, settings, mapping, runner)

    def _serve() -> None:
        logger.info("Web UI on http://%s:%s", config.web_host, config.web_port)
        serve(app, host=config.web_host, port=config.web_port, threads=4, _quiet=True)

    threading.Thread(target=_serve, name="mail2nas-web", daemon=True).start()


def main() -> None:
    logging.basicConfig(
        level=os.environ.get("LOG_LEVEL", "INFO"),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
        stream=sys.stdout,
    )

    config = Config.from_env()
    _check_storage_root(config)

    settings = Settings.load(config)
    try:
        mapping_full_path = safe_join(config.storage_root, settings.mapping_path)
    except ValueError as exc:
        raise SystemExit(f"Configured mapping path is not usable: {exc}") from None
    mapping = Mapping(str(mapping_full_path), settings.fallback_folder)
    store = ProcessedStore(config.state_db_path)

    logger.info(
        "Starting mail2nas: %d account(s), storage=%s dry_run=%s",
        len(settings.enabled_accounts()),
        config.storage_root,
        config.dry_run,
    )

    runner = Runner(config, settings, mapping, store)
    _start_web(config, settings, mapping, runner)
    runner.start()

    try:
        runner.wait()
    finally:
        runner.stop()
        store.close()


if __name__ == "__main__":
    main()
