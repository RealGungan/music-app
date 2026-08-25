"""Resolves staging:yt:<id> URIs to direct googlevideo stream URLs."""

import logging

from mopidy.backend import PlaybackProvider

logger = logging.getLogger(__name__)

URL_TTL = 3 * 3600  # googlevideo links live ~6h; refresh early


class DiscoverPlaybackProvider(PlaybackProvider):

    def translate_uri(self, uri):
        from .state import StagingState

        if not uri.startswith("staging:yt:"):
            return None
        vid = uri.rsplit(":", 1)[-1]
        state = StagingState.instance()
        url = state.db.resolved_cache_get(vid, URL_TTL)
        if url:
            return url
        url = state.pipeline.scorer.resolve_url(vid)
        if not url:
            logger.warning("could not resolve %s", uri)
            return None
        state.db.resolved_cache_put(vid, url)
        return url
