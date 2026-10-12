"""Suggest typeahead cache (2026-10-12: ~0.9s/keystroke = Deezer live +
YTMusic live, sequential, uncached per prefix).

- Full suggest payload cached in-memory 60s keyed by (user, norm(query)).
- YTMusic skipped for <3-char prefixes.
- Responses echo `q` (+`cached` flag) so the app drops stale rows.
Run: python3 -m unittest nasmusic.test_suggest_cache -v
"""
import types
import unittest


def _handler(rows, user=""):
    from . import httpd as _h
    h = _h.Handler.__new__(_h.Handler)
    h.server = types.SimpleNamespace(state=types.SimpleNamespace(
        scorer=_FakeScorer()))
    h._suggest_index = lambda: rows  # noqa: E731
    h._me = lambda: user  # noqa: E731
    h._lib_visible = lambda b, u: True  # noqa: E731
    h._log = lambda *a: None  # noqa: E731
    h._prewarm_resolvename = lambda pairs: None  # noqa: E731
    return h


class _FakeScorer:
    def __init__(self):
        self.dz_calls = 0
        self.yt_calls = 0

    def deezer_autocomplete(self, q, limit=6, timeout=2.0):
        self.dz_calls += 1
        return [{"kind": "song", "artist": "ACDC",
                 "title": "Thunderstruck " + q, "album": "",
                 "duration_s": 292, "album_image": "", "url": None,
                 "provider": "Deezer", "is_explicit": False}]

    def search_ytmusic(self, q):
        self.yt_calls += 1
        return [{"video_id": "vid123", "duration_s": 292,
                 "title": "Thunderstruck", "channel": "ACDC",
                 "uploader": "", "views": 0, "album": ""}]

    def pick(self, cands, artists, title):
        return (cands, None)


_ROWS = [("ACDC - Thunderstruck", "/m/ACDC - Thunderstruck.mp3",
         "/staging/file/ACDC - Thunderstruck.mp3", {})]


class SuggestCacheTest(unittest.TestCase):
    def setUp(self):
        from . import httpd as _h
        self._saved = _h.Handler._suggest_resp_cache
        _h.Handler._suggest_resp_cache = {}

    def tearDown(self):
        from . import httpd as _h
        _h.Handler._suggest_resp_cache = self._saved

    def test_repeat_served_from_cache(self):
        h = _handler(_ROWS)
        first = h._suggest("thunderstruck")
        self.assertEqual(first["q"], "thunderstruck")
        self.assertFalse(first["cached"])
        self.assertTrue(first["results"])
        dz, yt = h.state.scorer.dz_calls, h.state.scorer.yt_calls
        self.assertEqual((dz, yt), (1, 1))
        second = h._suggest("thunderstruck")
        self.assertTrue(second["cached"])
        self.assertEqual(second["results"], first["results"])
        self.assertEqual(second["q"], "thunderstruck")
        self.assertEqual(
            (h.state.scorer.dz_calls, h.state.scorer.yt_calls), (dz, yt))

    def test_distinct_query_misses(self):
        h = _handler(_ROWS)
        h._suggest("thunderstruck")
        out = h._suggest("thunderstruck live")
        self.assertFalse(out["cached"])
        self.assertEqual(h.state.scorer.dz_calls, 2)

    def test_stale_entry_rebuilds(self):
        from . import httpd as _h
        h = _handler(_ROWS)
        h._suggest("thunderstruck")
        key = list(_h.Handler._suggest_resp_cache)[0]
        ts, payload = _h.Handler._suggest_resp_cache[key]
        _h.Handler._suggest_resp_cache[key] = (ts - 61, payload)
        out = h._suggest("thunderstruck")
        self.assertFalse(out["cached"])
        self.assertEqual(h.state.scorer.dz_calls, 2)

    def test_per_user_isolation(self):
        h = _handler(_ROWS, user="alice")
        h._suggest("thunderstruck")
        h2 = _handler(_ROWS, user="bob")
        h2._suggest("thunderstruck")
        out = h2._suggest("thunderstruck")
        self.assertTrue(out["cached"])
        ha = _handler(_ROWS, user="alice")
        again = ha._suggest("thunderstruck")
        self.assertTrue(again["cached"])

    def test_short_query_skips_ytmusic(self):
        h = _handler(_ROWS)
        out = h._suggest("ac")
        self.assertEqual(h.state.scorer.yt_calls, 0)
        self.assertEqual(h.state.scorer.dz_calls, 1)
        self.assertTrue(out["results"])

    def test_empty_query_shape(self):
        h = _handler(_ROWS)
        out = h._suggest("   ")
        self.assertEqual(out, {"q": "   ", "results": [], "cached": False})
        self.assertEqual(
            (h.state.scorer.dz_calls, h.state.scorer.yt_calls), (0, 0))


class YtmCacheTest(unittest.TestCase):
    def test_search_ytmusic_caches_60s(self):
        from . import scorer as _s

        calls = []

        class _Resp:
            def __enter__(self):
                return self

            def __exit__(self, *a):
                return False

        real_search = None
        try:
            import ytmusicapi
            real_search = ytmusicapi.YTMusic.search

            def _fake(self, q, filter="songs", limit=15):  # noqa: A002
                calls.append(q)
                return [{"videoId": "vid9", "title": "T",
                         "artists": [{"name": "A"}],
                         "duration_seconds": 10, "album": {"name": ""}}]

            ytmusicapi.YTMusic.search = _fake
            sc = _s.Scorer(log_fn=lambda *a: None)
            sc._ytm_cache_local = {}
            first = sc.search_ytmusic("Thunderstruck")
            second = sc.search_ytmusic("Thunderstruck")
            self.assertEqual(len(calls), 1)
            self.assertEqual(first, second)
            self.assertEqual(first[0]["video_id"], "vid9")
        finally:
            if real_search is not None:
                ytmusicapi.YTMusic.search = real_search


if __name__ == "__main__":
    unittest.main()
