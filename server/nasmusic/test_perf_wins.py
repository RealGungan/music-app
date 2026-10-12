"""Funnel-vs-tailnet perf wins (2026-10-11 audit).

- _json gzips bodies >1KB when the client sends Accept-Encoding: gzip.
- _playlist_detail_cached skips the ~110ms per-row SQLite rebuild when
  no m3u changed (sig = own mtime/size + max mtime of the user's set).
- _resolvename returns pending from the job map BEFORE the NAS scans
  (polls were re-scanning the library every 400ms).
- _innas_lenient caches 2h like _innas (same full-library scan).
Run: python3 -m unittest nasmusic.test_perf_wins -v
"""
import gzip
import io
import json
import os
import tempfile
import time
import unittest


def _handler(headers=None):
    from . import httpd as _h
    h = _h.Handler.__new__(_h.Handler)
    h.headers = dict(headers or {})
    h._resp = {}
    h._body = io.BytesIO()

    def _send_response(status, msg=None):
        h._resp["status"] = status
    h.send_response = _send_response

    def _send_header(k, v):
        h._resp.setdefault("headers", {})[k] = v
    h.send_header = _send_header
    h.end_headers = lambda: None
    h.wfile = h._body
    return h


class JsonGzipTest(unittest.TestCase):
    def setUp(self):
        from . import httpd as _h
        self._h = _h

    def _big(self):
        return {"entries": [{"base_name": "Artist - Title %d" % i,
                             "album_image": "https://example.com/img.jpg",
                             "path": "/data/music/x/%d.mp3" % i}
                            for i in range(500)]}

    def test_gzip_when_accepted(self):
        h = _handler({"Accept-Encoding": "gzip, deflate"})
        obj = self._big()
        h._json(obj)
        hdrs = h._resp["headers"]
        self.assertEqual(hdrs.get("Content-Encoding"), "gzip")
        self.assertEqual(hdrs.get("Vary"), "Accept-Encoding")
        raw = gzip.decompress(h._body.getvalue())
        self.assertEqual(json.loads(raw.decode("utf-8")), obj)
        self.assertLess(len(h._body.getvalue()),
                        len(json.dumps(obj).encode("utf-8")) // 2)

    def test_identity_without_accept_encoding(self):
        h = _handler({})
        obj = self._big()
        h._json(obj)
        self.assertNotIn("Content-Encoding", h._resp["headers"])
        self.assertEqual(json.loads(h._body.getvalue().decode("utf-8")), obj)

    def test_small_body_not_compressed(self):
        h = _handler({"Accept-Encoding": "gzip"})
        h._json({"ok": True})
        self.assertNotIn("Content-Encoding", h._resp["headers"])
        self.assertEqual(json.loads(h._body.getvalue().decode("utf-8")),
                         {"ok": True})


class PlaylistDetailCacheTest(unittest.TestCase):
    def setUp(self):
        from . import httpd as _h
        self._h = _h
        self.td = tempfile.TemporaryDirectory()
        self.m3u = os.path.join(self.td.name, "Heavy.m3u")
        with open(self.m3u, "w") as fh:
            fh.write("/data/music/a.mp3\n")
        self.calls = []

        h = _handler({})
        h._user_m3u_path = lambda u, n: self.m3u  # noqa: E731
        h._user_m3us = lambda u: [("Heavy", self.m3u)]  # noqa: E731

        def _detail(u, n):
            self.calls.append((u, n))
            return {"name": n, "entries": [len(self.calls)]}
        h._playlist_detail = _detail
        self.h = h
        _h.Handler._playlist_detail_cache.pop(("tuser", "Heavy"), None)

    def tearDown(self):
        self._h.Handler._playlist_detail_cache.pop(("tuser", "Heavy"), None)
        self.td.cleanup()

    def test_repeat_hit_builds_once(self):
        a = self.h._playlist_detail_cached("tuser", "Heavy")
        b = self.h._playlist_detail_cached("tuser", "Heavy")
        self.assertEqual(a, b)
        self.assertEqual(len(self.calls), 1)

    def test_mtime_change_rebuilds(self):
        self.h._playlist_detail_cached("tuser", "Heavy")
        os.utime(self.m3u, (1000000000, 1000000000))
        with open(self.m3u, "a") as fh:
            fh.write("/data/music/b.mp3\n")
        out = self.h._playlist_detail_cached("tuser", "Heavy")
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(out["entries"], [2])

    def test_other_m3u_change_rebuilds_liked_flags(self):
        self.h._playlist_detail_cached("tuser", "Heavy")
        liked = os.path.join(self.td.name, "Liked.m3u")
        with open(liked, "w") as fh:
            fh.write("/data/music/z.mp3\n")
        self.h._user_m3us = lambda u: [  # noqa: E731
            ("Heavy", self.m3u), ("Liked", liked)]
        self.h._playlist_detail_cached("tuser", "Heavy")
        self.assertEqual(len(self.calls), 2)


class _FakeDb:
    def __init__(self):
        self.store = {}

    def misc_get(self, key, max_age):
        return self.store.get(key)

    def misc_put(self, key, value):
        self.store[key] = value


class _FakeState:
    def __init__(self, index):
        self.db = _FakeDb()
        self._index = index
        self.calls = 0

    def local_mp3_index(self):
        self.calls += 1
        return self._index


def _resolve_handler(index):
    import types
    h = _handler({})
    # Handler.state is a read-only property over self.server.state.
    h.server = types.SimpleNamespace(state=_FakeState(index))
    h._me = lambda: ""  # noqa: E731
    h._per_user_libs = lambda: False  # noqa: E731
    h._lib_visible = lambda b, u: True  # noqa: E731
    return h


class ResolvePendingFastPathTest(unittest.TestCase):
    def test_fresh_job_returns_pending_without_scans(self):
        from . import httpd as _h
        h = _resolve_handler([])
        key = _h.Handler._rn_key("Some Artist", "Some Title")
        _h.Handler._rn_jobs[key] = {"ts": time.time(), "tok": 4242}
        self.addCleanup(_h.Handler._rn_jobs.pop, key, None)
        for name in ("_innas", "_innas_lenient"):
            setattr(h, name,
                    lambda a, t: (_ for _ in ()).throw(
                        AssertionError(name + " ran on poll path")))
        h._resolvename("Some Artist", "Some Title")
        body = json.loads(h._body.getvalue().decode("utf-8"))
        self.assertEqual(body, {"status": "pending", "key": key})

    def test_err_job_returns_502_without_scans(self):
        from . import httpd as _h
        h = _resolve_handler([])
        key = _h.Handler._rn_key("Some Artist", "Some Title")
        _h.Handler._rn_jobs[key] = {"ts": time.time(), "err": True,
                                    "tok": 4243}
        self.addCleanup(_h.Handler._rn_jobs.pop, key, None)
        h._innas = lambda a, t: (_ for _ in ()).throw(  # noqa: E731
            AssertionError("_innas ran on err path"))
        h._resolvename("Some Artist", "Some Title")
        self.assertEqual(h._resp["status"], 502)


class InnasLenientCacheTest(unittest.TestCase):
    def test_hit_scans_once_then_served_from_cache(self):
        h = _resolve_handler(["Artist A - Wanted Song", "Other - Else"])
        first = h._innas_lenient("artist a", "wanted song")
        self.assertEqual(first, "Artist A - Wanted Song")
        self.assertEqual(h.state.calls, 1)
        second = h._innas_lenient("artist a", "wanted song")
        self.assertEqual(second, first)
        self.assertEqual(h.state.calls, 1)

    def test_miss_cached_as_negative(self):
        h = _resolve_handler(["Artist A - Wanted Song"])
        self.assertIsNone(h._innas_lenient("nobody", "nosong"))
        self.assertEqual(h.state.calls, 1)
        self.assertIsNone(h._innas_lenient("nobody", "nosong"))
        self.assertEqual(h.state.calls, 1)


if __name__ == "__main__":
    unittest.main()
