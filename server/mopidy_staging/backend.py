"""Backend: discovery library + playback provider."""

import logging

import pykka
from mopidy.backend import Backend

from .library import DiscoverLibraryProvider
from .playback import DiscoverPlaybackProvider
from .state import StagingState

logger = logging.getLogger(__name__)


class StagingBackend(pykka.ThreadingActor, Backend):

    uri_schemes = ["staging"]

    def __init__(self, config, audio):
        super().__init__()
        self.state = StagingState.configure(config)
        logger.info("Mopidy-Staging backend ready (root=%s)",
                    self.state.music_root)
        self.library = DiscoverLibraryProvider(backend=self)
        self.playback = DiscoverPlaybackProvider(audio=audio, backend=self)
