"""Deezer 30s-preview fallback (2026-10-16).

The YouTube egress of this NAS is IP-throttled ("Sign in to confirm you're
not a bot" -> yt-dlp yields no url -> resolve/stream 502 for internet
tracks). api.deezer.com is NOT bot-gated, so a song that YouTube cannot
resolve falls back to Deezer's 30s preview.

NETWORK-FREE: `_deezer_get` and the DB are stubbed. Run:
    python3 -m unittest nasmusic.test_deezer_preview -v
"""
import types
import unittest

from . import scorer as _s

DEEZER_HIT = {
    "id": 1234567,
    "title": "Hollow",
    "title_short": "Hollow",
    "duration": 345,
    "preview": "https://cdnt-preview.dzcdn.net/api/1/1/aa.mp3?hdnea=tok",
    "artist": {"id": 9, "name": "Pantera"},
}


class _Scorer:
    """Scorer with `_deezer_get` stubbed — no network at all."""

    def __init__(self, search=None, track=None):
        self.search_rows = search if search is not None else []
        self.track = track if track is not None else DEEZER_HIT
        self.urls = []

    def _deezer_get(self, url, timeout=12):
        self.urls.append(url)
        if "/track/" in url:
            return self.track
        return {"data": list(self.search_rows)}


class DeezerPreviewLookup(unittest.TestCase):
    """scorer.deezer_preview: confident match only, stable id out."""

    def setUp(self):
        self.rows_data = [DEEZER_HIT]
        self.hits = []

        def stub(_scorer, url, timeout=12):
            self.hits.append(url)
            if "/track/" in url:
                return DEEZER_HIT
            return {"data": list(self.rows_data)}
        self._real = _s.Scorer._deezer_get
        _s.Scorer._deezer_get = stub
        self.addCleanup(setattr, _s.Scorer, "_deezer_get", self._real)

    def _scorer(self):
        sc = _s.Scorer.__new__(_s.Scorer)
        sc._log = lambda *a: None
        return sc

    def test_confident_match_returns_stable_id_and_preview(self):
        out = self._scorer().deezer_preview("Pantera", "Hollow")
        self.assertEqual(out["track_id"], 1234567)
        self.assertEqual(out["seconds"], 30)
        self.assertIn("dzcdn.net", out["preview"])

    def test_artist_only_match_is_rejected(self):
        """strict_title: a wrong preview is a wrong song, not a degraded one.
        Deezer returns an 'Hollow (Live)' row when the exact title is
        missing — that must NOT be served for the studio song."""
        self.rows_data = [dict(DEEZER_HIT, title="Hollow (Live)",
                               title_short="Hollow (Live)")]
        self.assertIsNone(self._scorer().deezer_preview("Pantera", "Hollow"))

    def test_wrong_artist_is_rejected(self):
        self.rows_data = [dict(DEEZER_HIT,
                               artist={"id": 1, "name": "Totally Other"})]
        self.assertIsNone(self._scorer().deezer_preview("Pantera", "Hollow"))

    def test_no_preview_field_is_none(self):
        row = dict(DEEZER_HIT)
        row.pop("preview")
        self.rows_data = [row]
        self.assertIsNone(self._scorer().deezer_preview("Pantera", "Hollow"))

    def test_sting_sharing_the_title_is_rejected(self):
        row = dict(DEEZER_HIT, duration=4)
        self.rows_data = [row]
        self.assertIsNone(self._scorer().deezer_preview("Pantera", "Hollow"))

    def test_empty_identity_is_none(self):
        self.assertIsNone(self._scorer().deezer_preview("", ""))

    def test_preview_url_remints_from_the_cached_id(self):
        """The CDN token dies in ~15 min, so the URL must be re-mintable
        from the stable track id alone."""
        sc = self._scorer()
        self.assertIn("dzcdn.net", sc.deezer_preview_url(1234567))

    def test_preview_url_none_without_an_id(self):
        self.assertIsNone(self._scorer().deezer_preview_url(None))


# --------------------------------------------------------------- httpd side
def _handler(db_rows=None, misc=None, preview_tid="1234567", minted=None):
    """A Handler with only `state` faked (no server, no socket)."""
    from . import httpd as _h
    h = _h.Handler.__new__(_h.Handler)
    misc = misc if misc is not None else {}

    class _DB:
        def query(self, sql, args=()):
            return [{"value": v, "seen_at": 9e9} for v in db_rows or []]

        def misc_get(self, key, ttl):
            return misc.get(key)

        def misc_put(self, key, value):
            misc[key] = value

    class _Sc:
        def deezer_preview_url(self, tid):
            if not tid or tid == "none":
                return None
            return minted or f"https://cdnt-preview.dzcdn.net/{tid}.mp3?x=1"

    # `state` is a read-only property (self.server.state) on the real
    # Handler — hand the stub a fake server instead of assigning it.
    h.server = types.SimpleNamespace(
        state=types.SimpleNamespace(db=_DB(), scorer=_Sc(),
                                    config=types.SimpleNamespace(
                                        resolve_cache_ttl=86400)))
    h._deezer_preview_cached = (
        lambda a, t: (preview_tid
                      if a and t and preview_tid != "nomatch" else None))
    h._deezer_cover_cached = lambda base: "cover.jpg"
    h._deezer_album_cached = lambda base: "Album"
    return h


class PreviewFallbackSelection(unittest.TestCase):
    """Which resolve failures fall back, and what they hand back."""

    ROW = ['{"video_id": "ImXNU8Kg4H0", "url": "http://x/stream?vid=v",'
           ' "artist": "Pantera", "title": "Hollow"}']

    def test_no_youtube_url_falls_back_to_the_preview_marker(self):
        h = _handler(db_rows=self.ROW)
        self.assertEqual(h._preview_marker("ImXNU8Kg4H0"), "pz:1234567")

    def test_unknown_song_identity_does_not_fall_back(self):
        """No rz:/ry: row = we do not know artist+title. Guessing a song is
        exactly the failure this fallback must not introduce."""
        h = _handler(db_rows=[])
        self.assertIsNone(h._preview_marker("ImXNU8Kg4H0"))

    def test_deezer_without_a_preview_does_not_fall_back(self):
        h = _handler(db_rows=self.ROW, preview_tid="nomatch")
        self.assertIsNone(h._preview_marker("ImXNU8Kg4H0"))

    def test_marker_is_reminted_per_request(self):
        """The cached marker is NOT a url — each request mints a fresh one
        (the hdnea token expires in minutes)."""
        h = _handler(db_rows=self.ROW)
        self.assertIn("dzcdn.net", h._preview_url("pz:1234567"))

    def test_plain_url_passes_through_unchanged(self):
        h = _handler()
        u = "https://rr1---sn-x.googlevideo.com/videoplayback?expire=1"
        self.assertEqual(h._preview_url(u), u)

    def test_dead_deezer_track_gives_none_not_a_stale_url(self):
        h = _handler(preview_tid="none")
        self.assertIsNone(h._preview_url("pz:none"))

    def test_resolvename_payload_shape_and_preview_flags(self):
        h = _handler(db_rows=self.ROW)
        out = h._resolvename_preview("Pantera", "Hollow")
        self.assertTrue(out["preview"])
        self.assertEqual(out["preview_sec"], 30)
        self.assertEqual(out["duration_s"], 30)
        self.assertEqual(out["video_id"], "")
        self.assertIn("dzcdn.net", out["url"])
        # same shape as a real resolve so the app parses it unchanged
        self.assertEqual(out["artist"], "Pantera")
        self.assertEqual(out["title"], "Hollow")
        self.assertEqual(out["album"], "Album")

    def test_no_deezer_match_keeps_the_honest_502(self):
        h = _handler(db_rows=self.ROW, preview_tid="nomatch")
        self.assertIsNone(h._resolvename_preview("Pantera", "Hollow"))


class PreviewFlagPropagation(unittest.TestCase):
    def test_preview_flag_only_on_the_deezer_preview_cdn(self):
        from . import httpd as _h
        self.assertTrue(_h.Handler._is_preview_url(
            "https://cdnt-preview.dzcdn.net/api/1/1/aa.mp3?hdnea=t"))
        self.assertFalse(_h.Handler._is_preview_url(
            "https://rr1---sn-x.googlevideo.com/videoplayback"))
        self.assertFalse(_h.Handler._is_preview_url(""))

    def test_cached_marker_is_reminted_not_relayed_verbatim(self):
        """_resolve_shared on a warm 'pz:' row must return a real url."""
        h = _handler()

        class _DB:
            def resolved_cache_get(self, vid, ttl):
                return "pz:1234567"
        h.server.state.db = _DB()
        self.assertIn("dzcdn.net",
                      h._resolve_shared("ImXNU8Kg4H0"))


if __name__ == "__main__":
    unittest.main()