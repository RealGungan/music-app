"""Bounded retry on a bot-gated / empty yt-dlp resolve (2026-10-16).

YouTube egress from this NAS is intermittently bot-gated ("Sign in to confirm
you're not a bot"), which yt-dlp reports as an EMPTY url, not an exception.
`_resolve_try` retries the same video with backoff before the Deezer-preview
fallback, guarded by three anti-throttle limits: NASMUSIC_RESOLVE_RETRY=0,
a 10-min per-vid dead memo, and a process-wide cap of extra attempts/min.

NETWORK-FREE: the scorer and the DB are stubbed, and the backoff is set to 0s.
Run:
    python3 -m unittest nasmusic.test_resolve_retry -v
"""
import os
import types
import unittest

from . import httpd as _h

DEAD = "ImXNU8Kg4H0"        # removed / permanently gated
LIVE = "bPSLIqo__vs"       # resolves fine


class _Scorer:
    """resolve_url that fails while `dead` still has entries, counting
    attempts per video. Nothing else is implemented — a test that needs more
    asks for it explicitly."""

    def __init__(self, dead=(), urls=None):
        self.dead = set(dead)
        self.urls = dict(urls or {})
        self.attempts = []

    def resolve_url(self, vid, timeout=120):
        self.attempts.append(vid)
        if vid in self.dead:
            return None
        return self.urls.get(vid, f"https://rr1.googlevideo.com/{vid}")


def _handler(scorer):
    """A Handler with only `state` faked (no server, no socket)."""
    h = _h.Handler.__new__(_h.Handler)

    class _DB:
        def __init__(self):
            self.rows = {}

        def resolved_cache_get(self, vid, ttl):
            return None

        def resolved_cache_put(self, vid, url):
            self.rows[vid] = url

        def misc_get(self, key, ttl=0):
            return None

        def misc_put(self, key, value):
            self.rows[key] = value

    h.server = types.SimpleNamespace(
        state=types.SimpleNamespace(db=_DB(), scorer=scorer,
                                    config=types.SimpleNamespace(
                                        resolve_cache_ttl=86400)))
    return h


class _RetryBase(unittest.TestCase):
    def setUp(self):
        # no real backoff sleep in tests
        self._real_bf = _h.Handler._RETRY_BACKOFF
        _h.Handler._RETRY_BACKOFF = (0.0, 0.0)
        self.addCleanup(setattr, _h.Handler, "_RETRY_BACKOFF", self._real_bf)
        # per-test isolation of the process-wide memo / window / counters
        self._dead = dict(_h.Handler._resolve_dead)
        self._at = list(_h.Handler._resolve_retry_at)
        self._st = dict(_h.Handler._resolve_retry_stats)
        _h.Handler._resolve_dead = {}
        _h.Handler._resolve_retry_at = []
        _h.Handler._resolve_retry_stats = {"retries": 0, "memo": 0, "cap": 0}
        self.addCleanup(setattr, _h.Handler, "_resolve_dead", self._dead)
        self.addCleanup(setattr, _h.Handler, "_resolve_retry_at", self._at)
        self.addCleanup(setattr, _h.Handler, "_resolve_retry_stats", self._st)

    def flag(self, value):
        self.addCleanup(os.environ.pop, "NASMUSIC_RESOLVE_RETRY", None)
        os.environ["NASMUSIC_RESOLVE_RETRY"] = value


class RetryThenSucceed(_RetryBase):
    def test_empty_answer_is_retried_and_can_win(self):
        sc = _Scorer()
        h = _handler(sc)
        calls = {"n": 0}
        real = sc.resolve_url

        def flaky(vid, timeout=120):
            calls["n"] += 1
            return None if calls["n"] == 1 else real(vid, timeout)
        sc.resolve_url = flaky
        self.assertTrue(h._resolve_try(LIVE))
        self.assertEqual(calls["n"], 2, "must retry an empty url once")
        self.assertEqual(_h.Handler._resolve_retry_stats["retries"], 1)

    def test_bounded_to_three_attempts(self):
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        self.assertIsNone(h._resolve_try(DEAD))
        self.assertEqual(len(sc.attempts), 3, "1 attempt + 2 backoff retries")

    def test_success_clears_the_dead_memo(self):
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        self.assertIsNone(h._resolve_try(DEAD))
        self.assertIn(DEAD, _h.Handler._resolve_dead)
        sc.dead.clear()
        self.assertTrue(h._resolve_try(DEAD))
        self.assertNotIn(DEAD, _h.Handler._resolve_dead)

    def test_live_video_is_never_retried(self):
        """No added traffic on the happy path — the 5 working vids must see
        exactly one yt-dlp call, as before."""
        sc = _Scorer()
        h = _handler(sc)
        self.assertTrue(h._resolve_try(LIVE))
        self.assertEqual(sc.attempts, [LIVE])
        self.assertEqual(_h.Handler._resolve_retry_stats["retries"], 0)


class MemoTtl(_RetryBase):
    def test_memo_suppresses_retries_within_ttl(self):
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        h._resolve_try(DEAD)
        self.assertEqual(len(sc.attempts), 3)
        sc.attempts.clear()
        h._resolve_try(DEAD)
        self.assertEqual(sc.attempts, [DEAD], "known-dead vid: one bare attempt")
        self.assertEqual(_h.Handler._resolve_retry_stats["memo"], 1)

    def test_memo_expires_after_ttl(self):
        real_ttl = _h.Handler._RETRY_MEMO_TTL
        _h.Handler._RETRY_MEMO_TTL = 0.0
        self.addCleanup(setattr, _h.Handler, "_RETRY_MEMO_TTL", real_ttl)
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        h._resolve_try(DEAD)
        sc.attempts.clear()
        h._resolve_try(DEAD)
        self.assertEqual(len(sc.attempts), 3, "expired memo retries again")


class RetryCap(_RetryBase):
    def test_cap_is_enforced_process_wide(self):
        real_cap = _h.Handler._RETRY_PER_MIN
        _h.Handler._RETRY_PER_MIN = 2
        self.addCleanup(setattr, _h.Handler, "_RETRY_PER_MIN", real_cap)
        sc = _Scorer(dead=["a", "b", "c", "d"])
        h = _handler(sc)
        for vid in ("a", "b"):
            self.assertIsNone(h._resolve_try(vid))
        spent = len(sc.attempts)
        # budget gone: every further vid gets exactly one bare attempt
        for vid in ("c", "d"):
            self.assertIsNone(h._resolve_try(vid))
        self.assertEqual(len(sc.attempts) - spent, 2)
        self.assertGreaterEqual(_h.Handler._resolve_retry_stats["cap"], 1)

    def test_stale_window_does_not_consume_the_budget(self):
        _h.Handler._resolve_retry_at = [0.0] * 99   # all older than 60s
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        self.assertIsNone(h._resolve_try(DEAD))
        self.assertEqual(_h.Handler._resolve_retry_stats["cap"], 0)


class FlagOff(_RetryBase):
    def test_zero_flag_disables_every_retry(self):
        self.flag("0")
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        self.assertIsNone(h._resolve_try(DEAD))
        self.assertEqual(sc.attempts, [DEAD], "flag=0: one bare attempt")
        self.assertEqual(_h.Handler._resolve_dead, {}, "no memo either")

    def test_flag_on_by_default(self):
        os.environ.pop("NASMUSIC_RESOLVE_RETRY", None)
        sc = _Scorer(dead=[DEAD])
        self.assertIsNone(_handler(sc)._resolve_try(DEAD))
        self.assertEqual(len(sc.attempts), 3)


class ResolvenameCandidates(_RetryBase):
    """`_rn_worker`: a dead top pick must fall through to the next scorer
    candidate, and to the Deezer preview only when they are all dead."""

    def _worker(self, scored, dead, preview=None):
        h = _handler(_Scorer(dead=dead, urls={}))
        h.state_db = h.server.state.db
        rows = h.server.state.db.rows

        class _Sc(_Scorer):
            pass
        h.server.state.scorer.search_ytmusic = lambda q: scored
        h.server.state.scorer.search = lambda a, t: scored
        h.server.state.scorer.pick = lambda c, ar, t: (scored, scored)
        h.server.state.scorer.stream_is_opus = lambda u, timeout=15: False
        h.server.state.scorer.video_album = lambda v: ""
        h._deezer_album_cached = lambda base: ""
        h._play_url = lambda v: f"http://x/staging/api/stream?vid={v}"
        h._resolvename_preview = lambda a, t: preview
        with _h.Handler._rn_jobs_lock:
            _h.Handler._rn_jobs.clear()
            _h.Handler._rn_jobs["rz:k"] = {"ts": 9e9, "tok": 7}
        h._rn_worker("rz:k", "Pantera", "Hollow", tok=7)
        return rows.get("rz:k"), h.server.state.scorer

    def test_next_candidate_wins_when_the_top_pick_is_dead(self):
        cands = [{"video_id": DEAD, "title": "Hollow"},
                 {"video_id": LIVE, "title": "Hollow"}]
        out, sc = self._worker(cands, dead=[DEAD], preview=None)
        self.assertEqual(out["video_id"], LIVE)
        self.assertEqual(sc.attempts[-1], LIVE)

    def test_all_candidates_dead_falls_back_to_the_preview(self):
        cands = [{"video_id": DEAD, "title": "Hollow"},
                 {"video_id": "x", "title": "Hollow"},
                 {"video_id": "y", "title": "Hollow"}]
        preview = {"preview": True, "url": "https://cdnt-preview.dzcdn.net/a.mp3"}
        out, _ = self._worker(cands, dead=[DEAD, "x", "y"], preview=preview)
        self.assertEqual(out, preview)

    def test_no_candidate_at_all_falls_back_to_the_preview(self):
        preview = {"preview": True, "url": "https://cdnt-preview.dzcdn.net/a.mp3"}
        out, sc = self._worker([], dead=[], preview=preview)
        self.assertEqual(out, preview)
        self.assertEqual(sc.attempts, [], "no candidate, no yt-dlp call")


class ResolveSharedWiring(unittest.TestCase):
    """`_resolve_shared` (the /api/resolve + /api/stream path) must go
    through the retry helper, and still return the preview marker when the
    retries come back empty."""

    def setUp(self):
        self._dead = dict(_h.Handler._resolve_dead)
        self._at = list(_h.Handler._resolve_retry_at)
        self._st = dict(_h.Handler._resolve_retry_stats)
        _h.Handler._resolve_dead = {}
        _h.Handler._resolve_retry_at = []
        _h.Handler._resolve_retry_stats = {"retries": 0, "memo": 0, "cap": 0}
        self._bf = _h.Handler._RETRY_BACKOFF
        _h.Handler._RETRY_BACKOFF = (0.0, 0.0)
        self.addCleanup(setattr, _h.Handler, "_resolve_dead", self._dead)
        self.addCleanup(setattr, _h.Handler, "_resolve_retry_at", self._at)
        self.addCleanup(setattr, _h.Handler, "_resolve_retry_stats", self._st)
        self.addCleanup(setattr, _h.Handler, "_RETRY_BACKOFF", self._bf)

    def test_dead_video_retries_then_returns_the_preview_marker(self):
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        h._preview_marker = lambda vid: "pz:1234567"
        h._preview_url = lambda m: (None if not m else
                                    "https://cdnt-preview.dzcdn.net/1234567.mp3")
        h._rz_url_for_vid = lambda vid: None
        url = h._resolve_shared(DEAD, timeout=5)
        self.assertIn("dzcdn.net", url)
        self.assertEqual(len(sc.attempts), 3, "retried before the fallback")

    def test_retry_wins_so_no_preview_is_needed(self):
        sc = _Scorer()
        h = _handler(sc)
        h._preview_marker = lambda vid: "pz:1234567"
        h._rz_url_for_vid = lambda vid: None
        n = {"i": 0}
        real = sc.resolve_url

        def flaky(vid, timeout=120):
            n["i"] += 1
            return None if n["i"] < 3 else real(vid, timeout)
        sc.resolve_url = flaky
        url = h._resolve_shared(LIVE, timeout=5)
        self.assertIn("googlevideo.com", url)
        self.assertEqual(n["i"], 3)

    def test_nothing_resolvable_still_honours_the_502_contract(self):
        sc = _Scorer(dead=[DEAD])
        h = _handler(sc)
        h._preview_marker = lambda vid: None      # Deezer has no preview
        h._preview_url = lambda m: m
        h._rz_url_for_vid = lambda vid: None
        self.assertIsNone(h._resolve_shared(DEAD, timeout=5))


if __name__ == "__main__":
    unittest.main()
