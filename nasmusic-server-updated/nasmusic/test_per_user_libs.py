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


def _handler(db, env_off=True, staging_dir="/stg"):
    from . import httpd as _h
    st = types.SimpleNamespace(
        config=types.SimpleNamespace(
            per_user_libs=False, staging_dir=staging_dir), db=db)
    h = _h.Handler.__new__(_h.Handler)
    h.server = types.SimpleNamespace(state=st)
    h._auth_user = None
    _h.Handler._owner_map_cache = (0.0, {})
    _h.Handler._per_user_libs_cache = (0.0, None)
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


class StagingHiddenTest(unittest.TestCase):
    """Another user's STAGED file never marks in_nas for me (flag OFF).

    Shared library (music_root/playlist_dir) + legacy owner='' + own
    files stay visible. Run: python3 -m unittest nasmusic.test_per_user_libs -v
    """

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.db = Database(os.path.join(self.td.name, "t.db"))
        self.db.create_download("Legacy Artist", "Legacy Song")  # owner ''
        self.db.create_download("Alice", "Alice Song", owner="alice")
        self.db.create_download("Bob", "Bob Song", owner="bob")
        self.h = _handler(self.db, staging_dir="/stg")

    def tearDown(self):
        self.td.cleanup()

    def test_other_users_staged_file_hidden(self):
        self.assertTrue(self.h._staging_hidden(
            "Bob - Bob Song", "/stg/Bob - Bob Song.mp3", "alice"))

    def test_own_staged_file_visible(self):
        self.assertFalse(self.h._staging_hidden(
            "Bob - Bob Song", "/stg/Bob - Bob Song.mp3", "bob"))

    def test_legacy_staged_file_hidden_from_non_owners(self):
        # Explicit-download legacy rows are per-user: hidden from everyone
        # except the owner account (library legacy stays shared elsewhere).
        self.assertTrue(self.h._staging_hidden(
            "Legacy Artist - Legacy Song",
            "/stg/Legacy Artist - Legacy Song.mp3", "alice"))
        self.assertFalse(self.h._staging_hidden(
            "Legacy Artist - Legacy Song",
            "/stg/Legacy Artist - Legacy Song.mp3", "RealGungan"))

    def test_shared_library_unaffected_by_owner(self):
        # A kept (music_root) file stays visible even when another user
        # uploaded it — only staging_dir entries are scoped.
        self.assertFalse(self.h._staging_hidden(
            "Bob - Bob Song", "/music/Bob - Bob Song.mp3", "alice"))
        self.assertFalse(self.h._staging_hidden(
            "Bob - Bob Song", "/playlists/Bob - Bob Song.mp3", "alice"))

    def test_unknown_base_fail_open(self):
        self.assertFalse(self.h._staging_hidden(
            "Nobody - Nope", "/stg/Nobody - Nope.mp3", "alice"))
    def test_scoped_map_drops_only_other_users_staged(self):
        st = self.h.server.state
        st.local_mp3_index = lambda: {
            "Bob - Bob Song": "/stg/Bob - Bob Song.mp3",
            "Alice - Alice Song": "/stg/Alice - Alice Song.mp3",
            "Legacy Artist - Legacy Song":
                "/stg/Legacy Artist - Legacy Song.mp3",
            "Bob - Kept Song": "/music/Bob - Kept Song.mp3",
        }
        self.h._auth_user = "alice"
        scoped = self.h._scoped_local_map()
        self.assertNotIn("Bob - Bob Song", scoped)
        self.assertIn("Alice - Alice Song", scoped)
        self.assertNotIn("Legacy Artist - Legacy Song", scoped)
        self.assertIn("Bob - Kept Song", scoped)


class OwnedBadgeTest(unittest.TestCase):
    """The /api/liked `downloaded` badge is per-user (explicit downloads).

    Legacy owner='' rows count for NOBODY here — another user's (or an
    ownerless) staged file must never badge my row. The shared music_root
    library stays visible to all elsewhere (_lib_visible).
    Run: python3 -m unittest nasmusic.test_per_user_libs -v
    """

    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        self.db = Database(os.path.join(self.td.name, "t.db"))
        self.db.create_download("Legacy Artist", "Legacy Song")  # owner ''
        self.db.create_download("Alice", "Alice Song", owner="alice")
        self.db.create_download("Bob", "Bob Song", owner="bob")

    def tearDown(self):
        self.td.cleanup()

    def test_owned_download_is_strict(self):
        self.assertTrue(
            self.db.owned_download("Alice - Alice Song", "alice"))
        self.assertFalse(
            self.db.owned_download("Alice - Alice Song", "bob"))
        self.assertFalse(self.db.owned_download(
            "Legacy Artist - Legacy Song", "alice"))
        self.assertFalse(self.db.owned_download(
            "Legacy Artist - Legacy Song", "bob"))
        self.assertFalse(
            self.db.owned_download("Nobody - Nope", "alice"))

    def test_list_downloads_hides_ownerless_from_non_owners(self):
        alice = self.db.list_downloads(owner="alice")
        self.assertEqual(
            [r["base_name"] for r in alice], ["Alice - Alice Song"])
        staged = self.db.list_downloads(status="pending", owner="bob")
        self.assertEqual(
            [r["base_name"] for r in staged], ["Bob - Bob Song"])
        owner_view = self.db.list_downloads()
        self.assertEqual(len(owner_view), 3)


if __name__ == "__main__":
    unittest.main()
