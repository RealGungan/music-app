"""Library provider: unified local + discovery search.

Local results come from mopidy-local through the core proxy at query
time; discovery candidates come from the YouTube scorer. Virtual tracks
use the staging:yt:<video_id> scheme and stream without downloading.
"""

import logging
import re

from mopidy.backend import LibraryProvider
from mopidy.models import Artist, SearchResult, Track

from .scorer import norm

logger = logging.getLogger(__name__)

QUERY_SPLIT = re.compile(r"^(?P<artist>.+?)\s+-\s+(?P<title>.+)$")


def parse_query(q):
    m = QUERY_SPLIT.match(q.strip())
    if m:
        return m.group("artist").strip(), m.group("title").strip()
    return "", q.strip()


class DiscoverLibraryProvider(LibraryProvider):

    def __init__(self, backend):
        super().__init__(backend)
        self._cache = {}          # norm_query -> (ts, [tracks])
        self._cache_ttl = 1800

    @property
    def root_directory(self):
        from mopidy.models import Ref
        return Ref.directory(uri="staging:root", name="Discover")

    def browse(self, uri):
        return []

    def _virtual_track(self, artist, title, cand):
        return Track(
            uri=f"staging:yt:{cand['video_id']}",
            name=title,
            artists=[Artist(name=artist)] if artist else [],
            length=(cand.get("duration_s") or 0) * 1000 or None,
        )

    def search(self, query=None, uris=None, exact=False):
        import time as _t

        from .state import StagingState

        state = StagingState.instance()
        raw = " ".join(query.get("any", [])).strip() if query else ""
        if not raw:
            return SearchResult(uri="staging:search")
        artist, title = parse_query(raw)
        key = norm(raw)
        hit = self._cache.get(key)
        if hit and _t.time() - hit[0] < self._cache_ttl:
            return SearchResult(uri="staging:search", tracks=hit[1])

        state.db.log_search(raw)
        try:
            cands = state.pipeline.scorer.search(artist or title, title)
            scored, _ = state.pipeline.scorer.pick(
                cands, [artist] if artist else [], title)
            if scored:
                state.db.record_candidates("discovery", scored[:15])
        except Exception:                            # noqa: BLE001
            logger.exception("discovery search failed")
            scored = []
        tracks = [self._virtual_track(artist or title, title, c)
                  for c in (scored or [])]
        self._cache[key] = (_t.time(), tracks)
        return SearchResult(uri="staging:search", tracks=tracks)

    def lookup(self, uri):
        """Rebuild a playable Track for a staging:yt:<id> URI.

        Candidate metadata is looked up in the DB when available so the
        player shows proper titles after restarts.
        """
        from .state import StagingState

        if not uri.startswith("staging:yt:"):
            return []
        vid = uri.rsplit(":", 1)[-1]
        state = StagingState.instance()
        rows = state.db.query(
            """SELECT * FROM candidates WHERE video_id=? LIMIT 1""", (vid,))
        row = rows[0] if rows else {}
        return [Track(uri=uri,
                      name=row.get("title") or vid,
                      artists=[Artist(name=row["channel"])]
                      if row.get("channel") else [],
                      length=(row.get("duration_s") or 0) * 1000 or None)]
