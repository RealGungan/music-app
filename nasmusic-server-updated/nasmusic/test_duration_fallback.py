"""State.duration_for fallback to downloads.duration_s.

Run: python3 -m unittest nasmusic.test_duration_fallback -v
"""
import os
import tempfile
import unittest

from .state import Config, State


class DurationFallbackTest(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory()
        root = self.td.name
        cfg = Config(
            music_root=os.path.join(root, "music"),
            staging_dir=os.path.join(root, "staging"),
            playlist_dir=os.path.join(root, "playlists"),
            users_dir=os.path.join(root, "users"),
            db_path=os.path.join(root, "t.db"),
        )
        self.state = State(cfg)
        self.path = os.path.join(root, "Artist - Song.mp3")
        with open(self.path, "wb") as f:
            f.write(b"\x00")

    def tearDown(self):
        self.td.cleanup()

    def test_falls_back_to_downloads_duration(self):
        did = self.state.db.create_download("Artist", "Song")
        self.state.db.update_download(did, duration_s=187)
        size = os.stat(self.path).st_size
        self.assertIsNone(
            self.state.db.duration_get(self.path, size))  # cache misses
        self.assertEqual(self.state.duration_for(self.path), 187)

    def test_none_when_neither_source_has_it(self):
        self.state.db.create_download("Artist", "Song")  # duration_s NULL
        self.assertIsNone(self.state.duration_for(self.path))

    def test_none_for_missing_file(self):
        missing = os.path.join(self.td.name, "nope.mp3")
        self.assertIsNone(self.state.duration_for(missing))


if __name__ == "__main__":
    unittest.main()
