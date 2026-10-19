"""Import link parsing: `_ytm_link_target` must tell playlists from albums."""
import unittest


class ImportLinkTest(unittest.TestCase):
    def test_album_browse_url(self):
        from . import httpd
        self.assertEqual(
            httpd._ytm_link_target(
                "https://music.youtube.com/browse/MPREb_abc123_-X"),
            ("album", "MPREb_abc123_-X"))

    def test_playlist_url(self):
        from . import httpd
        self.assertEqual(
            httpd._ytm_link_target(
                "https://music.youtube.com/playlist?list=OLAK5uy_xyz12"),
            ("playlist", "OLAK5uy_xyz12"))

    def test_plain_video_url(self):
        from . import httpd
        self.assertEqual(
            httpd._ytm_link_target(
                "https://www.youtube.com/watch?v=c_LmaIy5dv8"), ("", ""))

    def test_wrong_host(self):
        from . import httpd
        self.assertEqual(
            httpd._ytm_link_target("https://example.com/browse/MPREb_abc"),
            ("", ""))

    def test_empty(self):
        from . import httpd
        self.assertEqual(httpd._ytm_link_target(""), ("", ""))


class SpotifyLinkTest(unittest.TestCase):
    def test_album_url(self):
        from . import httpd
        self.assertEqual(
            httpd._spotify_link_target(
                "https://open.spotify.com/album/0ETFjACtuP2ADo6LFhL6HN"),
            ("album", "0ETFjACtuP2ADo6LFhL6HN"))

    def test_playlist_url(self):
        from . import httpd
        self.assertEqual(
            httpd._spotify_link_target(
                "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M"),
            ("playlist", "37i9dQZF1DXcBWIGoYBM5M"))

    def test_embed_album_url(self):
        from . import httpd
        self.assertEqual(
            httpd._spotify_link_target(
                "https://open.spotify.com/embed/album/0ETFjACtuP2ADo6LFhL6HN"),
            ("album", "0ETFjACtuP2ADo6LFhL6HN"))

    def test_wrong_host(self):
        from . import httpd
        self.assertEqual(
            httpd._spotify_link_target(
                "https://example.com/album/0ETFjACtuP2ADo6LFhL6HN"), ("", ""))


class VariantsSearchTest(unittest.TestCase):
    def _run(self, variants):
        from . import scorer as _s
        filters = []

        class _YTM:
            def __init__(self, *a, **k):
                pass

            def search(self, q, filter="songs", limit=15):  # noqa: A002
                filters.append(filter)
                if filter == "videos":
                    return [{"videoId": "dup", "title": "L", "artists": []},
                            {"videoId": "vidV", "title": "V", "artists": []}]
                return [{"videoId": "dup", "title": "S", "artists": []},
                        {"videoId": "vidS", "title": "S2", "artists": []}]

        sc = _s.Scorer(log_fn=lambda *a: None)
        sc._ytm_cache_local = {}
        import ytmusicapi
        real = ytmusicapi.YTMusic
        ytmusicapi.YTMusic = _YTM
        try:
            out = sc.search_ytmusic("q", variants=variants)
        finally:
            ytmusicapi.YTMusic = real
        return filters, out

    def test_variants_off_only_songs(self):
        filters, _ = self._run(False)
        self.assertEqual(filters, ["songs"])

    def test_variants_on_songs_and_videos(self):
        filters, _ = self._run(True)
        self.assertEqual(filters, ["songs", "videos"])

    def test_variants_dedupes_duplicate_videoid(self):
        _, out = self._run(True)
        vids = [r["video_id"] for r in out]
        self.assertEqual(vids.count("dup"), 1)


if __name__ == "__main__":
    unittest.main()
