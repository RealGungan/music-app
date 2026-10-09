"""Per-user library visibility (PER_USER_LIBS, default OFF).

Visibility only — nothing is ever deleted. File ownership = uploader
(downloads.owner); legacy owner='' stays visible to all (no silent hiding).
Rollback = flag off.
Run: python3 -m unittest nasmusic.test_per_user_libs -v
"""
import os
import tempfile
import types
import unittest

from .db import Database


def _handler(db, env_off=True):
    from . import httpd as _h
    st = types.SimpleNamespace(
        config=types.SimpleNamespace(per_user_libs=False), db=db)
    h = _h.Handler.__new__(_h.Handler)
    h.server = types.SimpleNamespace(state=st)
    h._auth_user = None
    _h.Handler._owner_map_cache = (0.0, {})
    return h


class PerUserLibsTest(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.db = Database(os.path.join(self.td.name, "t.db"))
        self.db.create_download("Legacy Artist", "Legacy Song")  # owner ''
        self.db.create_download("Alice", "Alice Song", owner="alice")
        self.db.create_download("Bob", "Bob Song", owner="bob")

    def tearDown(self):
        self.td.cleanup()

    def test_flag_default_off(self):
        self.assertFalse(self.db.flag_get("per_user_libs", False))

    def test_flag_off_everyone_sees_all(self):
        h = _handler(self.db)
        for u in ("alice", "bob", "carol"):
            for b in ("Legacy Artist - Legacy Song", "Alice - Alice Song",
                      "Bob - Bob Song"):
                self.assertTrue(h._lib_visible(b, u), (u, b))

    def test_flag_on_owner_sees_own_plus_legacy(self):
        self.db.flag_put("per_user_libs", True)
        h = _handler(self.db)
        self.assertTrue(h._lib_visible("Legacy Artist - Legacy Song", "alice"))
        self.assertTrue(h._lib_visible("Alice - Alice Song", "alice"))
        self.assertFalse(h._lib_visible("Bob - Bob Song", "alice"))
        self.assertTrue(h._lib_visible("Bob - Bob Song", "bob"))
        self.assertFalse(h._lib_visible("Alice - Alice Song", "bob"))
        self.assertTrue(h._lib_visible("Legacy Artist - Legacy Song", "carol"))
        self.assertFalse(h._lib_visible("Alice - Alice Song", "carol"))

    def test_rollback_flag_off_restores_all(self):
        self.db.flag_put("per_user_libs", True)
        self.db.flag_put("per_user_libs", False)
        h = _handler(self.db)
        self.assertTrue(h._lib_visible("Bob - Bob Song", "alice"))

    def test_owner_map(self):
        m = self.db.owner_map()
        self.assertEqual(m.get("Legacy Artist - Legacy Song"), "")
        self.assertEqual(m.get("Alice - Alice Song"), "alice")
        self.assertEqual(m.get("Bob - Bob Song"), "bob")


if __name__ == "__main__":
    unittest.main()
