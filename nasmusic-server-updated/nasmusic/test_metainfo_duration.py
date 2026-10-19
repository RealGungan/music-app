"""The /api/metainfo duration path must never block on Deezer.

A per-track Deezer lookup costs ~0.7s (round trip + a deliberate 0.4s
rate-limit sleep), so a 40-track playlist used to take ~28s and cross the
app's 30s request budget. These tests pin the cache-only read and the
background warm, using the `spawn` seam so nothing is timing-dependent.
"""
import threading
import unittest

from nasmusic.state import State


class _FakeDB:
    def __init__(self, cached=None):
        self.cached = cached
        self.puts = []

    def misc_get(self, key, max_age):
        return self.cached

    def misc_put(self, key, value):
        self.puts.append((key, value))
        self.cached = value


class _FakeScorer:
    def __init__(self, result):
        self.result = result
        self.calls = []

    def deezer_duration(self, key, artist, title):
        self.calls.append((key, artist, title))
        return self.result


class _Noop:
    def start(self):
        pass


class _Spawn:
    """Captures the background target instead of starting a thread."""

    def __init__(self):
        self.targets = []

    def __call__(self, target=None, daemon=None):
        self.targets.append(target)
        return _Noop()

    def run_all(self):
        for t in self.targets:
            t()


def _state(db, scorer):
    # State.__init__ does filesystem work, so build a bare instance and set
    # only what the duration helpers touch (all declared in __slots__).
    st = State.__new__(State)
    st.db = db
    st.scorer = scorer
    st._sd_lock = threading.Lock()
    st._sd_inflight = set()
    return st


KEY = "sd:artist\x00title"


class StudioDurationTests(unittest.TestCase):
    def test_miss_never_blocks_and_schedules_one_warm(self):
        db, sc = _FakeDB(None), _FakeScorer(212)
        spawn = _Spawn()
        st = _state(db, sc)
        self.assertIsNone(
            st.studio_duration_cached(KEY, "artist", "title", spawn=spawn))
        self.assertEqual(sc.calls, [])           # nothing on the request path
        self.assertEqual(len(spawn.targets), 1)  # one background lookup

    def test_inflight_key_does_not_schedule_twice(self):
        db, sc = _FakeDB(None), _FakeScorer(212)
        spawn = _Spawn()
        st = _state(db, sc)
        st.studio_duration_cached(KEY, "artist", "title", spawn=spawn)
        st.studio_duration_cached(KEY, "artist", "title", spawn=spawn)
        self.assertEqual(len(spawn.targets), 1)

    def test_cached_value_returns_without_warming(self):
        db, sc = _FakeDB(212), _FakeScorer(None)
        spawn = _Spawn()
        st = _state(db, sc)
        self.assertEqual(
            st.studio_duration_cached(
                KEY, "artist", "title", spawn=spawn), 212)
        self.assertEqual(spawn.targets, [])

    def test_unknown_caches_zero_and_does_not_retry(self):
        db, sc = _FakeDB(None), _FakeScorer(None)
        spawn = _Spawn()
        st = _state(db, sc)
        st.studio_duration_cached(KEY, "artist", "title", spawn=spawn)
        spawn.run_all()                          # the background lookup runs
        self.assertEqual(db.puts, [(KEY, 0)])    # 0, not None
        # A later request must treat that 0 as resolved, not re-ask Deezer.
        self.assertIsNone(
            st.studio_duration_cached(KEY, "artist", "title", spawn=spawn))
        self.assertEqual(len(spawn.targets), 1)


if __name__ == "__main__":
    unittest.main()
