"""YTMusic artist-track fetching (2026-10-16).

Artist pages were Deezer-ONLY, and Deezer's catalogue under-covers several
artists: its Tame Impala "Currents" tracklist has no "That's All for
Everyone", and it lists Bb Trickz "Trickstar" as an EP with no such track —
so those real tracks never appeared. ytmusicapi's get_artist is the second
source, but it is not usable on its own:

  * InnerTube answers the artist page under `singleColumnBrowseResultsRenderer`
    while ytmusicapi's last-resort parse path names `twoColumnBrowseResultsRenderer`
    -> hard KeyError (which is what got misread as "HTTP 400 / API drift").
  * Plenty of channels (Bb Trickz) return a /browse response with NO contents
    at all, 0-for-8, so there is nothing to re-root and nothing to parse.

So `ytm_artist_rows` tries the artist page (with `_reroot_single_column` so
ytmusicapi's own parsers work again) and falls back to YTM album search for
artists with no browsable page.

NETWORK-FREE: everything below runs off `fixture_artist_browse.json`, a real
captured /browse response (trimmed). Run:
    python3 -m unittest nasmusic.test_ytm_artist -v
"""
import copy
import json
import os
import unittest

_FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                         "fixture_artist_browse.json")


def _fixture():
    with open(_FIXTURE, encoding="utf-8") as fh:
        return json.load(fh)


class _StubYTMusic:
    """Stands in for YTMusic: serves the fixture for /browse, and records
    which filters were asked for so we can assert the fallback path."""

    def __init__(self, browse_ok=True, albums=None):
        self._browse_ok = browse_ok
        self._albums = albums or []
        self.searches = []

    def search(self, query, filter=None, limit=None):
        self.searches.append(filter)
        if filter == "artists":
            return [{"artist": "Tame Impala", "browseId": "UCfixture"}]
        if filter == "albums":
            return copy.deepcopy(self._albums)
        return []

    def get_artist(self, browse_id):
        if not self._browse_ok:
            # Exactly what ytmusicapi does when the page has no contents.
            raise KeyError(
                "Unable to find 'contents' using path "
                "['contents', 'twoColumnBrowseResultsRenderer', 'tabs', 0, "
                "'tabRenderer', 'content', 'sectionListRenderer', 'contents']")
        from ytmusicapi import YTMusic
        from .scorer import _reroot_single_column
        yt = YTMusic()
        yt._send_request = lambda endpoint, body: _reroot_single_column(
            copy.deepcopy(_fixture()))
        return yt.get_artist(browse_id)

    def get_album(self, browse_id):
        return {"title": "Fixture Album",
                "artists": [{"name": "Tame Impala"}],
                "tracks": [{"title": "Let It Happen",
                            "artists": [{"name": "Tame Impala"}],
                            "duration_seconds": 306,
                            "thumbnails": [{"url": "https://i/lp.jpg"}]}]}


class YtmReroot(unittest.TestCase):
    def test_reroot_single_column_response(self):
        from .scorer import _reroot_single_column
        r = _reroot_single_column(_fixture())
        self.assertIn("twoColumnBrowseResultsRenderer", r["contents"])

    def test_reroot_leaves_two_column_alone(self):
        from .scorer import _reroot_single_column
        resp = {"contents": {"twoColumnBrowseResultsRenderer": {"tabs": []}}}
        out = _reroot_single_column(copy.deepcopy(resp))
        self.assertEqual(out, resp)

    def test_reroot_tolerates_contentless_response(self):
        from .scorer import _reroot_single_column
        resp = {"responseContext": {}, "trackingParams": "x"}
        self.assertEqual(_reroot_single_column(resp), resp)


class YtmArtistRows(unittest.TestCase):
    """The whole extraction path, off the fixture, no network."""

    def test_artist_page_yields_albums_and_songs(self):
        from .scorer import Scorer
        stub = _StubYTMusic()
        albums, songs = Scorer().ytm_artist_rows("Tame Impala", client=stub)
        self.assertTrue(albums, "expected albums from the artist page")
        self.assertTrue(songs, "expected songs from the artist page")
        titles = [a["album"] for a in albums]
        self.assertIn("Currents", titles)
        self.assertIn("The Slow Rush", titles)
        self.assertIn("Loser", [s["base_name"].split(" - ", 1)[-1]
                            for s in songs])

    def test_rows_are_deezer_shaped(self):
        """Must match deezer_artist_albums / deezer_album_tracks_by_id so
        _merge_albums and _artist_disc_songs need no changes."""
        from .scorer import Scorer
        albums, songs = Scorer().ytm_artist_rows(
            "Tame Impala", client=_StubYTMusic())
        for a in albums:
            self.assertEqual(
                {"album", "album_artist", "image", "tracks", "year",
                 "album_id", "type"}, set(a))
            # tagged so _deezer_album_tracks_cached routes to YTMusic
            self.assertTrue(a["album_id"].startswith("ytm:"), a["album_id"])
        for s in songs:
            self.assertEqual(
                {"base_name", "artist", "album", "album_image",
                 "duration_s"}, set(s))
            self.assertTrue(s["base_name"])

    def test_album_ids_are_unique_and_typed(self):
        from .scorer import Scorer
        albums, _ = Scorer().ytm_artist_rows("Tame Impala",
                                             client=_StubYTMusic())
        ids = [a["album_id"] for a in albums]
        self.assertEqual(len(ids), len(set(ids)), "duplicate album ids")
        self.assertTrue(all(a["type"] == "album" for a in albums))

    def test_album_search_is_merged_even_when_page_succeeds(self):
        """The artist page's carousels are a partial, popularity-ranked view;
        album search reaches further (Bb Trickz "Trickstar" lives only there),
        so it is merged always — not only as an empty-page fallback."""
        from .scorer import Scorer
        stub = _StubYTMusic(albums=[
            {"title": "Deep Cut Only In Search", "year": "2014",
             "browseId": "MPREb_deep",
             "artists": [{"name": "Tame Impala"}]},
            {"title": "Someone Else", "browseId": "MPREb_other",
             "artists": [{"name": "Charli xcx"}]}])
        albs, _ = Scorer().ytm_artist_rows("Tame Impala", client=stub)
        self.assertIn("albums", stub.searches)
        titles = [a["album"] for a in albs]
        # merged in despite the artist page already succeeding
        self.assertIn("Deep Cut Only In Search", titles)
        self.assertIn("Currents", titles)          # from the artist page
        self.assertNotIn("Someone Else", titles)   # artist doesn't match

    def test_falls_back_to_album_search_when_page_has_no_contents(self):
        """The Bb Trickz case: /browse returns no contents, get_artist raises."""
        from .scorer import Scorer
        stub = _StubYTMusic(
            browse_ok=False,
            albums=[{"title": "Trickstar", "year": "2024",
                     "browseId": "MPREb_pSnqhx3P357",
                     "artists": [{"name": "Bb Trickz"}],
                     "thumbnails": [{"url": "https://i/trickstar.jpg"}]},
                    {"title": "Unrelated", "browseId": "MPREb_other",
                     "artists": [{"name": "Someone Else"}]},
                    {"title": "Wrong Artist", "browseId": "MPREb_wrong",
                     "artists": [{"name": "Charli xcx"}]}])
        albums, songs = Scorer().ytm_artist_rows("Bb Trickz", client=stub)
        self.assertIn("albums", stub.searches, "must try album search")
        self.assertEqual([a["album"] for a in albums], ["Trickstar"])
        self.assertEqual(albums[0]["album_id"], "ytm:MPREb_pSnqhx3P357")
        self.assertEqual(albums[0]["year"], "2024")
        self.assertEqual(albums[0]["album_artist"], "Bb Trickz")
        self.assertEqual(songs, [])

    def test_ytm_album_tracks_row_shape(self):
        from .scorer import Scorer
        rows = Scorer().ytm_album_tracks("ytm:MPREb_x", client=_StubYTMusic())
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["base_name"], "Tame Impala - Let It Happen")
        self.assertEqual(rows[0]["album"], "Fixture Album")
        self.assertEqual(rows[0]["duration_s"], 306)

    def test_ytm_album_tracks_accepts_bare_and_tagged_id(self):
        from .scorer import Scorer
        s = Scorer()
        bare = s.ytm_album_tracks("MPREb_x", client=_StubYTMusic())
        tagged = s.ytm_album_tracks("ytm:MPREb_x", client=_StubYTMusic())
        self.assertEqual(bare, tagged)
        self.assertTrue(bare)

    def test_empty_artist_is_cheap_noop(self):
        from .scorer import Scorer
        stub = _StubYTMusic()
        self.assertEqual(Scorer().ytm_artist_rows("", client=stub),
                         ([], []))
        self.assertEqual(stub.searches, [], "must not hit the network")


if __name__ == "__main__":
    unittest.main()