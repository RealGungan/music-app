"""Per-user import rate limit (2026-10-18: "remove the 20 minutes delay,
let me import as much as I want").

`_import_start` gated every import POST on `_rate_allow("import:<user>", 3,
3600)` — 3 imports/hour/user, and the 429 literally said "one every 20
minutes". Import is the only write path that bypasses the 30/h `stage:`
limiter (`_import_run_tracks` calls `state.pipeline.start_stage`
directly), so the limiter is kept but raised to 60/hour as the abuse
ceiling; the real anti-runaway guard is the per-user `_import_lock` 409.

Drives the REAL `_rate_allow` (real sliding window, empty buckets) through
4 consecutive `_import_start` calls and asserts none of them 429s, and that
the limiter was called with the raised ceiling.
Run: python3 -m unittest nasmusic.test_import_rate_limit -v
"""
import types
import unittest

USER = "ratelimit-tester"
CALLS = 5          # > the old 3/hour threshold


class ImportRateLimitTest(unittest.TestCase):
    def setUp(self):
        from . import httpd
        self.seen = []
        real_allow = httpd._rate_allow

        def spy(key, max_n, window_s):
            self.seen.append((key, max_n, window_s))
            return real_allow(key, max_n, window_s)

        self.httpd = httpd
        self._real_allow = httpd._rate_allow
        httpd._rate_allow = spy
        httpd._RATE_BUCKETS.pop("import:" + USER, None)

        h = httpd.Handler.__new__(httpd.Handler)             # no __init__
        self.codes = []
        h.server = types.SimpleNamespace(          # `state` is a read-only
            state=types.SimpleNamespace())         # property -> self.server.state
        h._me = lambda: USER
        h._body_json = lambda: {}             # empty name -> 400, not 429
        h._error = lambda code, msg, **kw: (
            self.codes.append((code, msg)) or {"error": msg})
        self.h = h

    def tearDown(self):
        self.httpd._rate_allow = self._real_allow
        self.httpd._RATE_BUCKETS.pop("import:" + USER, None)

    def test_more_than_three_imports_per_hour_are_accepted(self):
        for _ in range(CALLS):
            self.h._import_start(None)
        self.assertEqual(self.seen[0], ("import:" + USER, 60, 3600))
        self.assertGreater(self.seen[0][1], 3, "ceiling must exceed the old 3/h")
        self.assertEqual(len(self.seen), CALLS, "every call hit the limiter")
        self.assertNotIn(429, [c for c, _ in self.codes],
                         "429 fired at the old 3/hour threshold")

    def test_ceiling_still_exists(self):
        self.assertFalse(all(self.httpd._rate_allow(
            "import:ceiling-probe", 60, 3600) for _ in range(61)))


if __name__ == "__main__":
    unittest.main()
