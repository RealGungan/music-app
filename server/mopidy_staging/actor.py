"""Frontend actor: configures state, runs the periodic expiry loop."""

import logging
import threading
import time

import pykka
from mopidy.core import CoreListener

from .lifecycle import run_expiry
from .state import StagingState

logger = logging.getLogger(__name__)


class StagingFrontend(pykka.ThreadingActor, CoreListener):

    def __init__(self, config, core):
        super().__init__()
        self.state = StagingState.configure(config)
        self.core = core

    def on_start(self):
        logger.info("Staging lifecycle active (expiry=%sd, dir=%s)",
                    self.state.expiry_days, self.state.staging_dir)
        removed = run_expiry(self.state)
        if removed:
            logger.info("startup expiry removed %d files", len(removed))
        t = threading.Thread(target=self._loop, daemon=True)
        t.start()

    def _loop(self):
        while True:
            time.sleep(3600)
            try:
                removed = run_expiry(self.state)
                if removed:
                    logger.info("expired %d staging files", len(removed))
            except Exception:                        # noqa: BLE001
                logger.exception("expiry loop failed")

    def on_event(self, name, **data):
        # Reserved: once playlists are mutated through Mopidy's core API
        # (future integration), playlist_changed lands here.
        pass
