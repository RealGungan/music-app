"""Optional yt-dlp cookie wiring (2026-10-16).

YouTube bot-gates some source IPs ("Sign in to confirm you're not a bot"),
which makes EVERY internet resolve/stream 502. A logged-in cookie file is the
fix, so `Scorer.ytdlp` — the single funnel every yt-dlp call goes through
(search, resolve_url, download, httpd._resolve_debug) — appends
`--no-warnings --cookies <path>` when the file exists.

The file is OPTIONAL: when it is absent the argv must be byte-identical to
before, or a NAS that was fine keeps working the same way.

NETWORK-FREE: subprocess.run is captured. Run:
    python3 -m unittest nasmusic.test_ytdlp_cookies -v
"""
import os
import tempfile
import unittest

from . import scorer as _s


class _Capture:
    """Stand in for subprocess.run, recording the argv it was handed."""

    def __init__(self):
        self.cmds = []

    def __call__(self, cmd, **kw):
        self.cmds.append(cmd)
        return type("R", (), {"stdout": "", "stderr": "", "returncode": 0})()


class YtDlpCookies(unittest.TestCase):
    def setUp(self):
        self._real = _s.subprocess.run
        self.cap = _Capture()
        _s.subprocess.run = self.cap
        self.addCleanup(self._real and setattr, _s.subprocess, "run", self._real)

    def _cookie_file(self):
        fd, path = tempfile.mkstemp(suffix=".txt")
        os.write(fd, b"# Netscape HTTP Cookie File\n")
        os.close(fd)
        self.addCleanup(os.unlink, path)
        return path

    def _scorer(self, path):
        return _s.Scorer(yt_dlp_bin="yt-dlp", log_fn=lambda *a: None,
                         yt_cookies=path)

    def test_present_file_adds_cookie_flags(self):
        path = self._cookie_file()
        self._scorer(path).ytdlp(["-g", "https://x/watch?v=1"])
        self.assertEqual(
            self.cap.cmds[0],
            ["yt-dlp", "--no-warnings", "--cookies", path,
             "-g", "https://x/watch?v=1"])

    def test_absent_file_is_byte_identical_to_before(self):
        missing = os.path.join(tempfile.gettempdir(), "definitely-not-here.txt")
        self._scorer(missing).ytdlp(["-g", "https://x/watch?v=1"])
        self.assertEqual(self.cap.cmds[0],
                         ["yt-dlp", "-g", "https://x/watch?v=1"])

    def test_no_cookie_path_configured_is_byte_identical(self):
        self._scorer(None).ytdlp(["-g", "https://x/watch?v=1"])
        self.assertEqual(self.cap.cmds[0],
                         ["yt-dlp", "-g", "https://x/watch?v=1"])

    def test_file_appearing_after_boot_needs_no_restart(self):
        """Existence is checked per call, not cached at construction, so
        scp-ing a fresh cookie file in is picked up immediately."""
        missing = os.path.join(tempfile.gettempdir(), "not-yet-there.txt")
        sc = self._scorer(missing)
        sc.ytdlp(["-g", "u1"])
        self.assertNotIn("--cookies", self.cap.cmds[0])
        path = self._cookie_file()
        sc.yt_cookies = path
        sc.ytdlp(["-g", "u2"])
        self.assertIn("--cookies", self.cap.cmds[1])

    def test_does_not_mutate_callers_argv(self):
        path = self._cookie_file()
        args = ["-f", "ba", "-g", "u"]
        self._scorer(path).ytdlp(args)
        self.assertEqual(args, ["-f", "ba", "-g", "u"])


if __name__ == "__main__":
    unittest.main()