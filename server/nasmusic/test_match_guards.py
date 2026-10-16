"""False-match guards (2026-10-16 audit) — pure functions, no server.

Each test is the assert for one audited fix:
1. _innas_score q_both: artist agreement + artist-boundary anchor.
2. _innas_lenient: same >=6-char containment floor + artist required.
3. _norm_core: qualifier tags drop, RECORDING VARIANTS stay.
4. _split_base/_title_of: multi-dash bases split on the LAST ' - '.
5. Artist-page rows: row artist must be on the page; a lenient hit may not
   be adopted unless its title core is the row's title.
Plus the cheap duration sanity gate (_dur_ok).

Run: python3 -m unittest nasmusic.test_match_guards -v
"""
import types
import unittest


def _handler():
    from . import httpd as _h
    return _h.Handler.__new__(_h.Handler)


class NormCoreVariantTest(unittest.TestCase):
    """Fix 3: _norm_core must keep variant parentheticals."""

    def setUp(self):
        self.n = _handler()._norm_core

    def test_remaster_parenthetical_still_strips(self):
        self.assertEqual(self.n("Paranoid (2017 Remaster)"), "paranoid")
        self.assertEqual(self.n("Black Dog (Remastered)"), "blackdog")

    def test_bracket_qualifiers_strip(self):
        self.assertEqual(self.n("Song [Deluxe Edition]"), "song")
        self.assertEqual(self.n("Song {2017 Remaster}"), "song")

    def test_variants_survive(self):
        for tag in ("(Live)", "(Remix)", "(Acoustic)", "(Slowed + Reverb)",
                    "(Karaoke Version)", "(Cover)", "(8D Audio)",
                    "(Darwin Remix)", "(Live at Wembley)"):
            with self.subTest(tag=tag):
                self.assertNotEqual(self.n("Song " + tag), self.n("Song"))

    def test_variant_beats_a_bare_title(self):
        # What the matchers see: a live cut can never equal the studio core.
        self.assertNotEqual(self.n("Sandstorm (Darwin Remix)"),
                            self.n("Sandstorm"))
        # Qualifier stripped, variant kept, in the same string.
        self.assertEqual(self.n("Song (Live) (2017 Remaster)"), "songlive")


class InnasScoreQbothTest(unittest.TestCase):
    """Fix 1: the q_both bonus needs artist agreement and an anchored hit."""

    def _score(self, *a):
        from . import httpd as _h
        return _h.Handler._innas_score(*a)

    def test_artist_mismatch_rejects_q_both(self):
        s, ok = self._score("rihanna", "diamonds", "rihannadiamonds",
                            "drake", "ridethedickline", "drake feat x "
                            "rihannadiamonds")
        self.assertFalse(ok)
        self.assertEqual(s, 0)

    def test_q_both_must_start_the_base(self):
        # Containment away from the artist boundary is not a match.
        s, ok = self._score("", "ab", "diamonds", "", "zzzzzz",
                            "zzdiamondszz")
        self.assertFalse(ok)
        self.assertEqual(s, 0)

    def test_dashless_base_needs_dashless_query(self):
        # Same as above but the query HAS an artist: never a wildcard.
        s, ok = self._score("drake", "ab", "drakeab", "", "zzzzzz",
                            "zzdrakeabzz")
        self.assertFalse(ok)
        self.assertEqual(s, 0)

    def test_real_hit_still_scores(self):
        s, ok = self._score("rihanna", "diamonds", "rihannadiamonds",
                            "rihanna", "diamonds", "rihannadiamonds")
        self.assertTrue(ok)
        self.assertGreaterEqual(s, 115)

    def test_real_hit_with_suffix_still_scores(self):
        s, ok = self._score("rihanna", "diamonds", "rihannadiamonds",
                            "rihanna", "diamonds 2017 remaster",
                            "rihannadiamonds2017remaster")
        self.assertTrue(ok)


class SplitBaseTest(unittest.TestCase):
    """Fix 4: multi-dash bases split on the LAST ' - '."""

    def setUp(self):
        from . import httpd as _h
        self.split = _h.Handler._split_base
        self.h = _handler()

    def test_single_dash(self):
        self.assertEqual(self.split("Rihanna - Diamonds"),
                         ("Rihanna", "Diamonds"))

    def test_artist_with_slash_untouched(self):
        self.assertEqual(self.split("AC/DC - T.N.T."),
                         ("AC/DC", "T.N.T."))

    def test_two_dashes_split_on_last(self):
        art, ti = self.split("Travis Scott - Highest in the Room - Remastered")
        self.assertEqual(art, "Travis Scott - Highest in the Room")
        self.assertEqual(ti, "Remastered")
        self.assertEqual(self.h._title_of(
            "Travis Scott - Highest in the Room - Remastered"), "Remastered")

    def test_dashless_base_has_no_artist(self):
        self.assertEqual(self.split("Jóga"), ("", "Jóga"))


class _FakeDb:
    def __init__(self):
        self.store = {}

    def misc_get(self, key, max_age):
        return self.store.get(key)

    def misc_put(self, key, value):
        self.store[key] = value


class _FakeState:
    def __init__(self, index, durations=None):
        self.db = _FakeDb()
        self._index = index
        self._durations = durations or {}
        self.calls = 0

    def local_mp3_index(self):
        self.calls += 1
        return {b: "/music/" + b + ".mp3" for b in self._index}

    def duration_for(self, path):
        return self._durations.get(path)


def _lenient_handler(index, durations=None):
    h = _handler()
    h.server = types.SimpleNamespace(
        state=_FakeState(index, durations))
    h._me = lambda: ""            # noqa: E731
    h._lib_visible = lambda b, u: True   # noqa: E731
    h._staging_hidden = lambda b, f, u: False  # noqa: E731
    return h


class InnasLenientGuardTest(unittest.TestCase):
    """Fix 2 (+ the duration gate)."""

    def test_short_containment_rejected(self):
        h = _lenient_handler(["Yo Yo Ma - Goyou"])
        self.assertIsNone(h._innas_lenient("Yo Yo Ma", "go"))

    def test_artist_required(self):
        h = _lenient_handler(["Artist A - Wanted Song"])
        self.assertIsNone(h._innas_lenient("Artist B", "Wanted Song"))

    def test_dashless_base_never_matches(self):
        h = _lenient_handler(["Wanted Song"])
        self.assertIsNone(h._innas_lenient("Artist A", "Wanted Song"))

    def test_real_hit_still_matches(self):
        h = _lenient_handler(["Artist A - Wanted Song"])
        self.assertEqual(h._innas_lenient("artist a",
                                          "Wanted Song (feat. X)"),
                         "Artist A - Wanted Song")

    def test_live_base_not_taken_as_studio(self):
        h = _lenient_handler(["Artist A - Wanted Song (Live)"])
        self.assertIsNone(h._innas_lenient("Artist A", "Wanted Song"))

    def test_duration_gate_rejects_clip(self):
        h = _lenient_handler(["Artist A - Wanted Song"],
                             {"/music/Artist A - Wanted Song.mp3": 12.0})
        self.assertIsNone(h._innas_lenient("Artist A", "Wanted Song", 200))
        # No duration from the caller -> guard inert (old behaviour).
        self.assertEqual(h._innas_lenient("Artist A", "Wanted Song"),
                         "Artist A - Wanted Song")
        ok = _lenient_handler(["Artist A - Wanted Song"],
                              {"/music/Artist A - Wanted Song.mp3": 196.0})
        self.assertEqual(ok._innas_lenient("Artist A", "Wanted Song", 200),
                         "Artist A - Wanted Song")

    def test_duration_gate_limits(self):
        from . import httpd as _h
        d = _h.Handler._dur_ok
        self.assertTrue(d(200, None))            # file duration unknown
        self.assertTrue(d(None, 900))            # caller duration unknown
        self.assertTrue(d(200, 196))            # 2% drift
        self.assertTrue(d(200, 170))            # 15% drift, inside the 20%
        self.assertFalse(d(200, 30))            # under 45s
        self.assertFalse(d(200, 7500))          # over 2h
        self.assertFalse(d(200, 900))           # 5x drift


class ArtistPageRowGuardTest(unittest.TestCase):
    """Fix 5: discography rows stay on their page."""

    def setUp(self):
        self.h = _handler()

    def test_row_artist_must_be_on_page(self):
        self.assertTrue(self.h._artist_on_page("Metallica", "Metallica"))
        self.assertFalse(self.h._artist_on_page("Metallica", "Megadeth"))
        self.assertTrue(self.h._artist_on_page("Metallica",
                                               "Metallica & Lou Reed"))
        self.assertTrue(self.h._artist_on_page("Metallica",
                                               "Lou Reed, Metallica"))
        self.assertFalse(self.h._artist_on_page("Metallica",
                                                "Various Artists"))
        self.assertTrue(self.h._artist_on_page("", "Anyone At All"))

    def test_lenient_hit_must_be_that_title(self):
        self.assertTrue(self.h._hit_title_ok(
            "Artist A - Wanted Song", "wantedsong"))
        self.assertTrue(self.h._hit_title_ok(
            "Artist A - Wanted Song (2017 Remaster)", "wantedsong"))
        self.assertFalse(self.h._hit_title_ok(
            "Artist A - Wanted Song (Live)", "wantedsong"))
        self.assertFalse(self.h._hit_title_ok("Artist B - Other", "song"))


if __name__ == "__main__":
    unittest.main()