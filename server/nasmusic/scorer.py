"""Candidate search + scoring for finding the *correct* song.

This is the heart of "search-anything, stream-instantly, save-if-you-like-it".

Search strategy (port of the manual-verification downloader approach, the
same logic the spotify_new/tools use to nail the right recording):

1. Ask Deezer for ground-truth metadata (artist, title, studio duration)
   for free-text queries, so we know which *version* of a song is "correct"
   (the album cut, not a live/remix/acoustic cover).
2. Harvest candidates from YouTube search and YouTube Music.
3. Rank them: reject live/demo/remix/cover uploads, prefer verified-official
   channels (Vevo, Topic, etc.), reward titles that match the target, and
   reward durations that agree with the Deezer ground truth.

The winner is the probe that best matches what you asked for, so streaming
and saving both get the real song.
"""

import json
import re
import subprocess
import threading
import time
import unicodedata
from collections import Counter

# Hard rejects: never the studio album version.
REJECT = re.compile(
    r"\blive\b|\bdemo\b|\bremix\b|\brehearsal\b|\bsession\b|"
    r"\binstrumental\b|\bkaraoke\b|\bcover\b|\bacoustic\b|"
    r"\ba cappella\b|\bacapella\b|\baccapella\b|"
    r"\bnightcore\b|\bslowed\b|\bsped up\b|\breverb\b|\b8d\b|"
    r"\bbass boosted\b|\bloop\b|\bmashup\b|\bmedley\b|\breaction\b|"
    r"\b1 hour\b|\bfull album\b|\bextended\b|\bversion 2\b|second version",
    re.I,
)

# Mild penalty: real audio but often with video intro/outro edits.
VIDEOISH = re.compile(
    r"music video|official video|official hd video|\bmv\b|videoclip|"
    r"visualizer|4k|upgrad",
    re.I,
)

# Bonus: strong signals of a plain album-audio upload.
AUDIOISH = re.compile(
    r"official audio|\(audio\)|\baudio\b|full version|album version|"
    r"topic\b|lyric video|official lyric",
    re.I,
)


def norm(s):
    """Fold text for comparison: NFKD + strip diacritics + lowercase +
    drop non-alphanumerics."""
    s = unicodedata.normalize("NFKD", s or "")
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", "", s)


_REMASTER_PAREN = re.compile(r"\([^)]*remaster[^)]*\)", re.I)


def title_core(raw):
    """Title with ONLY remaster parentheticals stripped:
    "Paranoid (Remastered 2009)" IS "Paranoid" (same studio recording,
    longer title — Deezer lists Sabbath's 2:52 studio cut exactly this
    way while a mislabeled 4:28 track holds the bare title). Live /
    acoustic / remix / etc. parentheticals stay: those are different
    recordings and must never match as studio."""
    return _REMASTER_PAREN.sub("", raw or "")


def _version_kind(name, wanted):
    """Tag a Deezer version title with its type + whether it's the studio cut.

    Clean/censored edits are 'clean'; we keep them only if nothing else
    survives. 'cover' is never the original artist's studio cut.
    """
    is_studio = True
    vt = "studio"
    lower = (" " + (name or "") + " ").lower()
    if re.search(r"\blive\b|xperience|concert|tour edition", lower):
        vt, is_studio = "live", False
    elif re.search(r"\bremix\b|extended|extended mix|dub\b", lower):
        vt, is_studio = "remix", False
    elif re.search(r"\bacoustic\b|unplugged|stripped|piano", lower):
        vt, is_studio = "acoustic", False
    elif re.search(r"\binstrumental\b|karaoke|playback|"
                     r"a cappella|acapella|accapella", lower):
        vt, is_studio = "instrumental", False
    elif re.search(r"\blegacy\b|original\b|radio edit\b", lower):
        vt, is_studio = "studio", True
    norm_name = norm(title_core(name))
    if norm_name != norm(title_core(wanted)) and vt == "studio":
        vt, is_studio = "alt", is_studio
    if is_studio and re.search(r"\bexplicit\b|clean\b|radio\b", lower) \
            and "edit" in lower:
        vt, is_studio = "clean", False
    return vt, is_studio


class Scorer:
    """Search, score and resolve playback URLs for a tune."""

    def __init__(self, yt_dlp_bin="yt-dlp", log_fn=print):
        self.yt_dlp_bin = yt_dlp_bin
        self._log = log_fn
        self._deezer_cache: dict = {}
        self._cache_path = "/tmp/nasmusic/deezer_cache.json"
        try:
            with open(self._cache_path) as fh:
                self._deezer_cache = json.load(fh)
        except Exception:
            pass

    # ------------------------------------------------------------- yt-dlp
    def ytdlp(self, args, timeout=180):
        cmd = [self.yt_dlp_bin, *args]
        try:
            return subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout
            )
        except subprocess.TimeoutExpired:
            return type("R", (), {"stdout": "", "stderr": "timeout",
                                  "returncode": -1})()

    def search_ytmusic(self, query):
        """Structured YouTube Music candidates (no safe-search filter)."""
        try:
            from ytmusicapi import YTMusic
            out = []
            for r in (YTMusic().search(query, filter="songs", limit=15) or []):
                vid = r.get("videoId")
                if not vid:
                    continue
                dur = r.get("duration_seconds")
                if not dur:
                    d = r.get("duration") or ""
                    parts = [int(p) for p in d.split(":") if p.isdigit()]
                    dur = sum(v * 60 ** i for i, v in
                              enumerate(reversed(parts))) if parts else 0
                artists = ", ".join(
                    a.get("name", "") for a in r.get("artists") or []
                )
                out.append(dict(
                    video_id=vid, duration_s=int(dur or 0),
                    title=r.get("title", ""), channel=artists,
                    uploader="", views=0,
                    album=((r.get("album") or {}).get("name") or ""),
                ))
            return out
        except Exception as ex:                       # noqa: BLE001
            self._log(f"ytmusic search failed: {str(ex)[:60]}")
            return []

    def search(self, artist, title, quoted=True):
        """Merge YouTube + YouTube Music candidates for the query.

        With an artist -> quoted pair (exact for a resolved song); free text ->
        either one quoted phrase (quoted=True) or the raw query (quoted=False,
        which keeps more variety for artist/browse-style searches)."""
        if artist:
            q = f'"{artist}" "{title}"'
        elif quoted:
            q = f'"{title}"'
        else:
            q = title or ""
        # Kick the YouTube-Music lookup first and run the (slower) yt-dlp
        # search alongside it, so the two network calls overlap instead of
        # serializing — the cold search path pays roughly max(size) rather
        # than size1+size2. Merge semantics below are unchanged.
        ytm_box = []

        def _ytm():
            try:
                ytm_box[:] = self.search_ytmusic(f"{artist} {title}".strip())
            except Exception:                           # noqa: BLE001
                ytm_box[:] = []

        _ytm_th = threading.Thread(target=_ytm)
        _ytm_th.start()
        r = self.ytdlp(
            ["--flat-playlist", "--print",
             "%(id)s\t%(duration)s\t%(title)s\t%(channel)s\t"
             "%(uploader)s\t%(view_count)s",
             f"ytsearch15:{q}"],
        )
        _ytm_th.join(timeout=30)
        out = []
        for line in (r.stdout or "").splitlines():
            p = line.split("\t")
            if len(p) != 6:
                continue
            vid, dur, t, ch, up, views = p
            try:
                dur = int(float(dur))
            except ValueError:
                dur = 0
            try:
                views = int(float(views))
            except ValueError:
                views = 0
            out.append(dict(video_id=vid, duration_s=dur, title=t,
                            channel=ch, uploader=up, views=views))
        seen = {c["video_id"] for c in out}
        for c in ytm_box:
            if c["video_id"] not in seen:
                out.append(c)
        return out

    def video_album(self, video_id):
        """Best-effort album title for a YouTube video_id (no download).
        YTMusic meta first (fast), yt-dlp %(album)s second. Returns ""."""
        try:
            from ytmusicapi import YTMusic
            s = YTMusic().get_song(video_id) or {}
            for k in ("videoDetails", "microformat", "microFormat"):
                d = s.get(k) or {}
                for ak in ("album", "albumName"):
                    a = d.get(ak)
                    if isinstance(a, dict):
                        a = a.get("name") or a.get("title") or ""
                    if a:
                        return str(a)
        except Exception:                               # noqa: BLE001
            pass
        try:
            r = self.ytdlp(
                ["--skip-download", "--print", "%(album)s",
                 f"https://www.youtube.com/watch?v={video_id}"],
                timeout=30)
            a = (r.stdout or "").strip().splitlines()
            a = a[-1].strip() if a else ""
            return "" if a.lower() in ("", "na", "none") else a
        except Exception:                               # noqa: BLE001
            return ""

    def resolve_url(self, video_id, timeout=120):
        """Direct streamable URL (googlevideo) for instant playback.
        Order m4a/mp4 (AAC — plays everywhere) before webm/opus (which many
        Android players cannot decode and stall on)."""
        r = self.ytdlp(
            ["-f", "ba[ext=m4a]/ba[ext=mp4]/ba[ext=webm]/ba", "-g",
             f"https://www.youtube.com/watch?v={video_id}"],
            timeout=timeout,
        )
        url = (r.stdout or "").strip().splitlines()
        return url[-1] if url else None

    def stream_is_opus(self, url, timeout=15):
        """True when a resolved googlevideo URL serves webm/opus, which
        android.media.MediaPlayer cannot play (instant player-error, no
        duration). One tiny Range probe; unknown (exception) returns False
        so a probe failure never blocks a possibly-good stream."""
        import urllib.request
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0",
                              "Range": "bytes=0-1"})
            with urllib.request.urlopen(req, timeout=timeout) as r:
                ct = (r.headers.get("Content-Type") or "").lower()
                return "webm" in ct or "opus" in ct
        except Exception:                              # noqa: BLE001
            return False

    def download(self, video_id, target_mp3, timeout=300):
        base = (target_mp3[:-4] if target_mp3.endswith(".mp3")
                else target_mp3)
        r = self.ytdlp(
            ["-f", "bestaudio/best", "--extract-audio",
             "--audio-format", "mp3", "--audio-quality", "192K",
             "--max-filesize", "120M",
             "--embed-thumbnail", "--add-metadata",
             "--no-part", "--no-mtime",
             "-o", base + ".%(ext)s",
             f"https://www.youtube.com/watch?v={video_id}"],
            timeout=timeout,
        )
        self._shrink_embedded_art(target_mp3)
        return r

    def _shrink_embedded_art(self, path, max_bytes=200 * 1024,
                             max_dim=640):
        """Replace oversized embedded cover art with a small JPEG.

        yt-dlp --embed-thumbnail stores YouTube's full-size art (often a
        1280x720 PNG, 0.5MB+) at the very head of the file. Players must
        fetch/skip that whole ID3 tag before the first audio frame, which
        reads as "song takes seconds to play" on slow uplinks. Anything
        over max_bytes is re-encoded to a max_dim JPEG in place; the audio
        bytes are never touched. Best-effort: any failure keeps the file
        exactly as downloaded."""
        try:
            import os
            import subprocess
            import tempfile
            from mutagen import File as MFile
            from mutagen.id3 import APIC
        except Exception:                            # noqa: BLE001
            return
        try:
            audio = MFile(path)
            tags = getattr(audio, "tags", None)
            if tags is None or not hasattr(tags, "getall"):
                return
            pics = tags.getall("APIC")
            if not pics or sum(len(p.data) for p in pics) <= max_bytes:
                return
            with tempfile.TemporaryDirectory() as td:
                src = os.path.join(td, "art")
                with open(src, "wb") as fh:
                    fh.write(pics[0].data)
                dst = os.path.join(td, "small.jpg")
                r = subprocess.run(
                    ["ffmpeg", "-y", "-v", "error", "-i", src,
                     "-vf", f"scale={max_dim}:-2", dst],
                    timeout=60)
                if r.returncode != 0 or not os.path.exists(dst):
                    return
                with open(dst, "rb") as fh:
                    small = fh.read()
            tags.delall("APIC")
            tags.add(APIC(encoding=3, mime="image/jpeg", type=3,
                          desc="Album cover", data=small))
            audio.save()
        except Exception as ex:                      # noqa: BLE001
            self._log(f"art shrink skipped: {str(ex)[:80]}")

    # ----------------------------------------------------------- scoring
    @staticmethod
    def channel_tier(channel, uploader, artists):
        text = f"{channel} {uploader}".lower()
        for a in artists:
            an = norm(a)
            if not an:
                continue
            cn, un = norm(channel), norm(uploader)
            if cn == an or un == an:
                return 0
            if (an in cn or an in un) and any(
                    k in text for k in ("vevo", "- topic", "topic",
                                        "official")):
                return 0
        if any(k in text for k in ("vevo", "topic", "records", "recordings",
                                   "music", "entertainment")):
            return 1
        return 2

    def pick(self, cands, artists, title):
        """Rank candidates; returns (scored_list, consensus_duration)."""
        scored = []
        for c in cands:
            vid, dur, t = c["video_id"], c["duration_s"], c["title"]
            ch, up = c.get("channel", ""), c.get("uploader", "")
            if not vid or not t:
                continue
            tier = self.channel_tier(ch, up, artists)
            text = f"{t} {ch} {up}"
            tn = norm(t)
            title_n = norm(title)
            artist_norms = [norm(a) for a in artists]

            sc = 0
            # The single most reliable signal: the candidate title EQUALS or
            # literally CONTAINS the sought title. Dominant — it must outweigh
            # tier(30) + audioish(5) + views(10) + consensus(18) + misc, so a
            # same-name upload on a fan/featured channel beats an official
            # channel that uploaded a DIFFERENT song (which used to win on
            # channel tier because title match was worth only +2).
            # Feat-junk ("Blue (feat. X)") normalizes longer than the bare
            # candidate ("Blue") and can never containment-match — compare
            # feat-stripped cores, both directions.
            title_core = norm(re.sub(
                r"\(feat[^)]*\)|\bfeat\.?\s.*$|\bft\.?\s.*$", "",
                title, flags=re.I))
            tn_core = norm(re.sub(
                r"\(feat[^)]*\)|\bfeat\.?\s.*$|\bft\.?\s.*$", "",
                t, flags=re.I))
            ev = False
            if title_n == tn or title_core == tn_core:
                sc += 80
                ev = True
            elif len(title_n) >= 4 and (title_core in tn_core or tn_core in title_core):
                sc += 50
                ev = True
            tri = sum(2 for i in range(0, len(title_n), 6)
                      if title_n[i:i + 3] in tn)
            sc += tri
            # Trigram soup scores but is NEVER title evidence: shared
            # fragments ("la vida") occur between unrelated Spanish titles
            # and would otherwise bless a different song. Only exact /
            # containment set ev above.
            # Artist agreement (dominant after title): the single most
            # common same-title collision is another ARTIST's song
            # (Kanye West's "Paranoid" for a Black Sabbath request scores
            # exact-title +80 and outscores the real fan upload on views).
            # A same-title/wrong-artist upload must never win, while a
            # fan/tribute upload of the RIGHT song still matches via the
            # artist name in its title/channel/uploader text.
            tn_full = norm(f"{t} {ch} {up}")
            if any(a and a in tn_full for a in artist_norms
                   if len(a) >= 4):
                sc += 60
            if any(a[:10] and a[:10] in tn for a in artist_norms
                   if len(a) >= 4):
                sc += 4
            if REJECT.search(text):
                continue
            sc += {0: 30, 1: 12, 2: 0}[tier]
            if VIDEOISH.search(text):
                sc -= 6
            if AUDIOISH.search(text):
                sc += 5
            sc += min(10, int((c.get("views") or 0) ** 0.25))
            if dur and not (50 <= dur <= 700):
                continue
            scored.append(dict(video_id=vid, title=t, channel=ch,
                               duration_s=dur, score=sc, tier=tier, ev=ev))

        if not scored:
            return [], None

        trusted = {0, 1}
        durs = [d for d in (s["duration_s"] for s in scored)
                if d > 0 and any(
                    s["duration_s"] == d and s["tier"] in trusted
                    for s in scored)]
        consensus = Counter(durs).most_common(1)[0][0] if durs else None
        if consensus:
            for s in scored:
                d = s["duration_s"]
                if d and abs(d - consensus) <= 3:
                    s["score"] += 18
                elif d and abs(d - consensus) <= 6:
                    s["score"] += 8

        scored.sort(key=lambda x: x["score"], reverse=True)
        # No-evidence gate: when NOTHING matches the title (scarcity), the
        # winner would be decided by tier/views alone — a best-wrong-song on
        # an official channel. Refuse instead: the worker _fail()s (502,
        # retried next tap) rather than caching a wrong answer 14 days.
        if scored and not scored[0].get("ev"):
            return [], None
        return scored, consensus

    # ------------------------------------------------------------ deezer
    def deezer_search(self, query):
        """Best-effort metadata for free-text queries.

        Returns {'artist', 'title', 'duration_s'} or None.
        """
        import urllib.parse
        import urllib.request
        try:
            q = urllib.parse.quote(query)
            url = f"https://api.deezer.com/search?q={q}&limit=5"
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0"})
            data = json.load(urllib.request.urlopen(req, timeout=15))
            for e in data.get("data", []):
                artist = (e.get("artist") or {}).get("name")
                title = e.get("title_short") or e.get("title")
                dur = e.get("duration")
                if artist and title:
                    return {"artist": artist, "title": title,
                            "duration_s": int(dur) if dur else None}
        except Exception as ex:                       # noqa: BLE001
            self._log(f"deezer_search failed: {str(ex)[:60]}")
        return None

    def deezer_autocomplete(self, query, limit=6, timeout=4.0):
        """Online autocomplete suggestions (Spotify/YouTube-Music style).

        Returns a list of {kind, artist, title, album, duration_s,
        album_image, url, provider, is_explicit} rows that match the query.
        Falls back to a plain /search when the autocomplete endpoint is
        unavailable. Results are cached briefly (in-memory, keyed by
        normalized query) so typing doesn't block on Deezer on every
        keystroke; the suggest handler caps `timeout` well below the old
        15s so a slow api.deezer.com never stalls the search bar."""
        import urllib.parse
        import urllib.request
        key = "dza:" + norm(query) + ":" + str(limit)
        now = time.time()
        _local = getattr(self, "_deezer_cache_local", None)
        hit = _local.get(key) if _local else None
        if hit and (now - hit[0]) < 180:
            return hit[1]
        out = []
        try:
            q = urllib.parse.quote(query)
            data = json.load(urllib.request.urlopen(
                f"https://api.deezer.com/search?q={q}&limit={limit}",
                timeout=timeout))
            for e in data.get("data", []) or []:
                artist = ((e.get("artist") or {}).get("name") or "").strip()
                title = (e.get("title_short") or e.get("title") or "").strip()
                if not artist or not title:
                    continue
                dur = e.get("duration")
                images = e.get("album") or {}
                imgs = images.get("cover_medium") or images.get("cover")
                out.append({
                    "kind": "song",
                    "artist": artist,
                    "title": title,
                    "album": (images.get("title") or ""),
                    "duration_s": int(dur) if dur else None,
                    "album_image": imgs,
                    "url": None,
                    "provider": "Deezer",
                    "is_explicit": bool(e.get("explicit_lyrics")),
                })
        except Exception as ex:                       # noqa: BLE001
            self._log(f"deezer_autocomplete failed: {str(ex)[:60]}")
        try:
            if not hasattr(self, "_deezer_cache_local"):
                self._deezer_cache_local = {}
            self._deezer_cache_local[key] = (time.time(), out)
            if len(self._deezer_cache_local) > 400:
                old = min(self._deezer_cache_local.keys(),
                          key=lambda k: self._deezer_cache_local[k][0])
                self._deezer_cache_local.pop(old, None)
        except Exception:                               # noqa: BLE001
            pass
        return out

    def deezer_radio_tracks(self, artist, title, limit=8, exclude=None):
        """Related/internet tracks to a given song — Spotify/YouTube-Music
        "up next" autoplay.

        We look up the track's artist on Deezer, then pull that artist's top
        tracks (same-artist related songs — what these apps effectively play
        next in the queue). Tries to avoid the very track we're playing.
        [exclude] = set of norm(title) the caller already has queued/played,
        so consecutive refills for the SAME seed return FRESH rows (that's
        what makes the queue scroll endlessly instead of returning the same
        15 rows and stalling).
        Returns online rows (kind 'song', url None) so the app resolves +
        streams them. Best-effort: [] on any failure."""
        import urllib.parse
        query = (artist or "") + " " + (title or "")
        query = query.strip()
        # Normalize defensively: clients may send raw titles,
        # title-only norms, or full "Artist - Title" strings.
        ex = set(norm(x) for x in (exclude or ()) if isinstance(x, str) and x)
        out = []
        try:
            if not query:
                return out
            q = urllib.parse.quote(query)
            look = self._deezer_get(
                f"https://api.deezer.com/search?q={q}&limit=5")
            entries = (look or {}).get("data", []) or []
            if not entries:
                return out
            artist_id = None
            cur_norm = norm(title or "")
            for e in entries:
                ar = ((e.get("artist") or {}).get("id"))
                if ar:
                    artist_id = ar
                    if cur_norm and cur_norm in norm(e.get("title") or ""):
                        break

            def _row(e):
                ar = ((e.get("artist") or {}).get("name") or "").strip()
                ti = (e.get("title_short") or e.get("title") or "").strip()
                if not ar or not ti:
                    return None
                dur = e.get("duration")
                images = e.get("album") or {}
                return {
                    "kind": "song",
                    "artist": ar,
                    "title": ti,
                    "album": (images.get("title") or ""),
                    "duration_s": int(dur) if dur else None,
                    "album_image": (images.get("cover_medium")
                                    or images.get("cover")),
                    "url": None,
                    "provider": "Deezer",
                    "is_explicit": bool(e.get("explicit_lyrics")),
                }

            def _want(e):
                ti_n = norm(e.get("title") or "")
                if not ti_n or ti_n in ex:
                    return False
                # Containment fallback: older clients send raw
                # "Artist - Title" strings (norm keeps the artist blob),
                # which never equal a title-only norm — but the title is
                # still inside. Catches those without false positives
                # (full normalized titles rarely nest by accident).
                return not any(x in ti_n for x in ex)

            if artist_id:
                top = self._deezer_get(
                    f"https://api.deezer.com/artist/{artist_id}/top?limit={limit + 6}")
                for e in (top or {}).get("data", []) or []:
                    if cur_norm and cur_norm == norm(e.get("title") or ""):
                        continue
                    if not _want(e):
                        continue
                    row = _row(e)
                    if row:
                        out.append(row)
                    if len(out) >= limit:
                        break
            # Fallback: reuse the search rows themselves if the top list was
            # empty (e.g. artist id missing).
            if not out:
                for e in entries:
                    if not _want(e):
                        continue
                    row = _row(e)
                    if row and (not cur_norm
                                or norm(row["title"]) != cur_norm):
                        out.append(row)
                    if len(out) >= limit:
                        break
        except Exception as ex:                       # noqa: BLE001
            self._log(f"deezer_radio_tracks failed: {str(ex)[:60]}")
        return out

    def deezer_recommendations(self, artist, title, limit=15, exclude=None):
        """Cross-artist recommendation engine (Spotify-like "up next").

        Purely Deezer-based (works even when Spotify creds are absent/blocked).
        Blends three discovery signals:
          1. with_same  ~1/3  the artist's own top tracks
          2. with_rel   ~1/3  top tracks from DEEZER-RELATED artists
          3. with_radio ~1/3  the track's Deezer RADIO (genre/mood discovery)

        Also filters out the requested song itself and dedupes. [exclude] is a
        set of norm(title) the caller already has queued/played, so consecutive
        refills for the SAME seed return FRESH rows (that's what keeps the
        queue scrolling infinitely instead of recycling the same 15). Returns
        rows shaped like deezer_radio_tracks (kind 'song', url None) so the
        app can stream them. Best-effort: falls back to deezer_radio_tracks on
        error."""
        import urllib.parse

        out = []
        artist_id = None
        cur_norm = norm(title or "")
        cur_art_norm = norm(artist or "")
        # Normalize defensively: clients may send raw titles,
        # title-only norms, or full "Artist - Title" strings.
        ex = set(norm(x) for x in (exclude or ()) if isinstance(x, str) and x)

        def _row(e):
            ar = ((e.get("artist") or {}).get("name") or "").strip()
            ti = (e.get("title_short") or e.get("title") or "").strip()
            if not ar or not ti:
                return None
            dur = e.get("duration")
            images = e.get("album") or {}
            return {
                "kind": "song",
                "artist": ar,
                "title": ti,
                "album": (images.get("title") or ""),
                "duration_s": int(dur) if dur else None,
                "album_image": (images.get("cover_medium")
                                or images.get("cover")),
                "url": None,
                "provider": "Deezer",
                "is_explicit": bool(e.get("explicit_lyrics")),
            }

        def _add(rows, bucket, cap):
            """Append rows from *bucket* up to *cap* items (enforces diversity).

            Bucket-aware so each signal stays true:
              'same'  keeps ONLY the artist's own tracks (the closest matches,
                      like Spotify/YT putting similar work up next first);
              'rel'/'radio'  keep ONLY OTHER artists (real discovery).
            The same-artist bucket was previously dead because the filter below
            dropped every row whose artist == the current artist; that's what
            made the feed feel random instead of "up next"-like.
            """
            added = 0
            for e in rows or []:
                if added >= cap:
                    break
                r = _row(e)
                if not r:
                    continue
                key = norm(r["title"]) + "\x00" + norm(r["artist"])
                if key in _seen or norm(r["title"]) == cur_norm:
                    continue
                if ex and norm(r["title"]) in ex:
                    continue
                is_same = bool(cur_art_norm) and norm(r["artist"]) == cur_art_norm
                if bucket == "same":
                    if not is_same:
                        continue
                elif is_same:
                    continue
                _seen.add(key)
                out.append(r)
                added += 1

        _seen = {cur_norm}
        try:
            # Resolve the artist id from a search.
            q0 = urllib.parse.quote((artist or "") + " " + (title or ""))
            look = self._deezer_get(
                f"https://api.deezer.com/search?q={q0}&limit=5")
            entries = ((look or {}).get("data") or []) or []
            track_id = None
            for e in entries:
                aid = ((e.get("artist") or {}).get("id"))
                if aid and not artist_id:
                    artist_id = aid
                if cur_norm and cur_norm == norm(e.get("title") or ""):
                    track_id = e.get("id")
                    break
            if not track_id and entries:
                track_id = entries[0].get("id")

            # Bucket mix so the feed opens on-point like Spotify/YT radio
            # (closest matches first) while still drifting into discovery:
            # same-artist ~40%, radio ~35%, related ~25%.
            target_same = max(2, int(limit * 0.4))
            target_radio = max(2, int(limit * 0.35))
            target_rel = max(1, limit - target_same - target_radio)

            # 1) Same artist top tracks.
            if artist_id:
                top = self._deezer_get(
                    f"https://api.deezer.com/artist/{artist_id}/top"
                    f"?limit={target_same + 5}")
                _add((top or {}).get("data") or [], "same", target_same)

            # 2) Related artists -> their top tracks.
            rel_ids = []
            all_rel_ids = []
            if artist_id:
                rel = self._deezer_get(
                    f"https://api.deezer.com/artist/{artist_id}/related")
                for ra in ((rel or {}).get("data") or []):
                    if ra.get("id"):
                        all_rel_ids.append(ra.get("id"))
                for ra in ((rel or {}).get("data") or [])[:3]:
                    rid = ra.get("id")
                    if not rid:
                        continue
                    rel_ids.append(rid)
                    rtop = self._deezer_get(
                        f"https://api.deezer.com/artist/{rid}/top?limit=5")
                    _add((rtop or {}).get("data") or [], "rel", target_rel)

            # 3) Track radio -> genre/mood discovery.
            if track_id:
                radio = self._deezer_get(
                    f"https://api.deezer.com/track/{track_id}/radio?limit=20")
                _add((radio or {}).get("data") or [], "radio", target_radio)

            # 4) Starvation widening: buckets above recycle one small
            # neighborhood, so a long session converges on dupes and the
            # queue stalls (client dedups to nothing). Only when short,
            # BFS outward through the related-artist graph (1st degree
            # already failed, so go 2nd/3rd) until full or the fetch
            # budget is spent. New artists = new songs; exclusion still
            # applies, so nothing repeats.
            if len(out) < limit and all_rel_ids:
                from collections import deque as _dq
                visited = {artist_id, *rel_ids}
                queue = _dq(all_rel_ids)
                fetches = 0
                while queue and len(out) < limit and fetches < 12:
                    aid = queue.popleft()
                    if not aid or aid in visited:
                        continue
                    visited.add(aid)
                    try:
                        r2 = self._deezer_get(
                            f"https://api.deezer.com/artist/{aid}/related")
                        fetches += 1
                        for ra2 in ((r2 or {}).get("data") or []):
                            nid = ra2.get("id")
                            if nid and nid not in visited:
                                queue.append(nid)
                        t2 = self._deezer_get(
                            f"https://api.deezer.com/artist/{aid}"
                            f"/top?limit=5")
                        fetches += 1
                        _add((t2 or {}).get("data") or [], "rel", limit)
                    except Exception:
                        continue

            if not out:
                return self.deezer_radio_tracks(
                    artist, title, limit, exclude=ex)

            # No shuffle: keep same-artist + radio rows in relevance order so
            # the queue opens with the closest matches (Spotify/YT up-next).
            return out[:limit]
        except Exception as ex:                        # noqa: BLE001
            self._log(f"deezer_recommendations failed: {str(ex)[:60]}")
        return out[:limit] or self.deezer_radio_tracks(
            artist, title, limit, exclude=ex)

    # ------------------------------------------------------------ spotify
    def spotify_token(self):
        """Client-credentials OAuth token (cached 50 min). Returns None when
        SPOTIFY_CLIENT_ID / SPOTIFY_CLIENT_SECRET are not set."""
        import os
        import time
        now = time.time()
        if hasattr(self, '_spotify_tok') and self._spotify_tok and now < self._spotify_tok_exp:
            return self._spotify_tok
        cid = os.environ.get("SPOTIFY_CLIENT_ID", "")
        secret = os.environ.get("SPOTIFY_CLIENT_SECRET", "")
        if not cid or not secret:
            return None
        try:
            import urllib.parse
            import urllib.request
            auth = urllib.parse.urlencode({
                "grant_type": "client_credentials",
                "client_id": cid,
                "client_secret": secret,
            }).encode()
            req = urllib.request.Request(
                "https://accounts.spotify.com/api/token", data=auth,
                method="POST",
                headers={"Content-Type":
                         "application/x-www-form-urlencoded"})
            tok = json.load(urllib.request.urlopen(req, timeout=12))
            t = tok.get("access_token")
            if t:
                self._spotify_tok = t
                self._spotify_tok_exp = now + 3000
                return t
        except Exception:
            pass
        return None

    def spotify_artist_image(self, name):
        """Best-effort Spotify artist photo. Returns the image URL or None.
        Uses client-credentials OAuth — only works when creds are set."""
        import urllib.parse
        import urllib.request
        token = self.spotify_token()
        if not token:
            return None
        try:
            q = urllib.parse.quote(name)
            req = urllib.request.Request(
                f"https://api.spotify.com/v1/search?q={q}"
                "&type=artist&limit=5",
                headers={"Authorization": f"Bearer {token}"})
            data = json.load(urllib.request.urlopen(req, timeout=12))
            want = norm(name)
            for a in (data.get("artists") or {}).get("items") or []:
                if norm(a.get("name", "")) != want:
                    continue
                imgs = a.get("images") or []
                if imgs:
                    return imgs[0].get("url")
        except Exception as ex:
            self._log(f"spotify_artist_image failed: {str(ex)[:60]}")
        return None

    def spotify_album_image(self, artist, album):
        """Best-effort Spotify album cover. Returns the image URL or None.
        Uses client-credentials OAuth — only works when creds are set."""
        import urllib.parse
        import urllib.request
        token = self.spotify_token()
        if not token:
            return None
        try:
            q = urllib.parse.quote(f'artist:"{artist}" album:"{album}"')
            req = urllib.request.Request(
                f"https://api.spotify.com/v1/search?q={q}"
                "&type=album&limit=5",
                headers={"Authorization": f"Bearer {token}"})
            data = json.load(urllib.request.urlopen(req, timeout=12))
            want_a = norm(artist)
            want_al = norm(album)
            for al in (data.get("albums") or {}).get("items") or []:
                al_arts = [a.get("name", "") for a in al.get("artists") or []]
                if not any(norm(x) == want_a for x in al_arts):
                    continue
                if norm(al.get("name", "")) != want_al:
                    continue
                imgs = al.get("images") or []
                if imgs:
                    return imgs[0].get("url")
        except Exception as ex:
            self._log(f"spotify_album_image failed: {str(ex)[:60]}")
        return None

    def spotify_search(self, artist, title):
        """Optional live Spotify search (exact studio-version authority).

        Only works when SPOTIFY_CLIENT_ID + SPOTIFY_CLIENT_SECRET are set in
        the environment (client-credentials OAuth, no user login). Returns the
        best Spotify track dict {spotify_id, name, artists, album, duration_s,
        explicit, album_image} or None. Used to pin the *correct* studio
        version before finding it on YouTube to download.
        """
        import urllib.parse
        import urllib.request
        token = self.spotify_token()
        if not token:
            return None
        try:
            q = urllib.parse.quote(f'artist:"{artist}" track:"{title}"')
            req = urllib.request.Request(
                f"https://api.spotify.com/v1/search?q={q}"
                "&type=track&limit=10",
                headers={"Authorization": f"Bearer {token}"})
            data = json.load(urllib.request.urlopen(req, timeout=12))
            t_norm = norm(title)
            for it in (data.get("tracks") or {}).get("items") or []:
                if norm(it.get("name", "")) != t_norm:
                    continue
                arts = it.get("artists") or []
                if not arts:
                    continue
                # Prefer the original studio release: reject explicit-live
                # / remix / acoustic / cover tagged tracks unless nothing else.
                want = it.get("explicit", False)
                alt = re.compile(
                    r"\b(live|acoustic|piano|demo|remix|rehearsal|"
                    r"instrumental|karaoke|mono|cover)\b", re.I)
                if alt.search(it.get("name", "")):
                    continue
                return {
                    "spotify_id": it.get("id"),
                    "name": it.get("name"),
                    "artists": [a.get("name", "") for a in arts],
                    "album": ((it.get("album") or {}).get("name") or ""),
                    "album_image":
                        ((it.get("album") or {}).get("images") or [{}])[0]
                        .get("url") or "",
                    "duration_s": int((it.get("duration_ms") or 0) / 1000),
                    "explicit": want,
                    "is_studio": True,
                }
        except Exception as ex:                       # noqa: BLE001
            self._log(f"spotify_search failed: {str(ex)[:60]}")
        return None

    def spotify_recommendations(self, artist, title, limit=15):
        """Spotify-powered multi-source recommendation engine.

        Uses Spotify's /v1/recommendations with intelligent seed selection:
        - seed_artists: the current artist + related artists (from Deezer)
        - seed_genres: the current artist's genre tags from Spotify
        - seed_tracks: the current track's Spotify ID (keeps it similar)

        Returns up to [limit] suggestion-shaped dicts ready for the app to
        resolve + stream. Falls back to deezer_radio_tracks on any failure."""
        import urllib.parse
        import urllib.request
        import random

        if not (artist or "").strip() or not (title or "").strip():
            return []

        t_norm = norm(title)
        out = []

        try:
            # --- Step 1: Resolve current track + artist on Spotify ---
            token = self.spotify_token()
            if not token:
                self._log("spotify_recommendations: no token, falling back "
                          "to deezer_radio_tracks")
                return self.deezer_recommendations(artist, title, limit)

            q = urllib.parse.quote(f'artist:"{artist}" track:"{title}"')
            req = urllib.request.Request(
                f"https://api.spotify.com/v1/search?q={q}"
                "&type=track,artist&limit=5",
                headers={"Authorization": f"Bearer {token}"})
            data = json.load(urllib.request.urlopen(req, timeout=12))

            # Find the Spotify track ID
            sp_track_id = None
            sp_artist_id = None
            sp_artist_genres = []
            for it in (data.get("tracks") or {}).get("items") or []:
                if norm(it.get("name", "")) != t_norm:
                    continue
                sp_track_id = it.get("id")
                arts = it.get("artists") or []
                if arts:
                    sp_artist_id = arts[0].get("id")
                break

            # Get artist genres from the artist search results
            for a in (data.get("artists") or {}).get("items") or []:
                if norm(a.get("name", "")) == norm(artist or ""):
                    sp_artist_genres = a.get("genres") or []
                    if not sp_artist_id:
                        sp_artist_id = a.get("id")
                    break

            if not sp_track_id and not sp_artist_id:
                self._log("spotify_recommendations: track/artist not found "
                          "on Spotify, falling back")
                return self.deezer_recommendations(artist, title, limit)

            # --- Step 2: Get related artists from Deezer ---
            deezer_related_ids = []
            deezer_related_names = []
            try:
                dq = urllib.parse.quote(artist or "")
                art_data = self._deezer_get(
                    f"https://api.deezer.com/search/artist?q={dq}&limit=1")
                d_artist_id = None
                for a in (art_data or {}).get("data") or []:
                    if norm(a.get("name") or "") == norm(artist or ""):
                        d_artist_id = a.get("id")
                        break
                if d_artist_id:
                    rel = self._deezer_get(
                        f"https://api.deezer.com/artist/{d_artist_id}/related")
                    for ra in (rel or {}).get("data") or []:
                        rn = (ra.get("name") or "").strip()
                        if rn and norm(rn) != norm(artist or ""):
                            deezer_related_ids.append(str(ra.get("id")))
                            deezer_related_names.append(rn)
            except Exception:
                pass

            # --- Step 3: Map related artist names → Spotify IDs ---
            sp_related_ids = []
            for rn in deezer_related_names[:3]:
                try:
                    rq = urllib.parse.quote(rn)
                    rreq = urllib.request.Request(
                        f"https://api.spotify.com/v1/search?q={rq}"
                        "&type=artist&limit=1",
                        headers={"Authorization": f"Bearer {token}"})
                    rdata = json.load(
                        urllib.request.urlopen(rreq, timeout=8))
                    for ra in (rdata.get("artists") or {}).get("items") or []:
                        if norm(ra.get("name", "")) == norm(rn):
                            sp_related_ids.append(ra.get("id"))
                            break
                except Exception:
                    pass

            # --- Step 4: Build seed lists (max 5 total) ---
            seed_artists = []
            if sp_artist_id:
                seed_artists.append(sp_artist_id)
            seed_artists.extend(sp_related_ids)

            seed_genres = sp_artist_genres[:2]

            seed_tracks = [sp_track_id] if sp_track_id else []

            total_seeds = len(seed_artists) + len(seed_genres) + len(seed_tracks)
            if total_seeds == 0:
                return self.deezer_recommendations(artist, title, limit)

            # Trim to 5 if over
            while (len(seed_artists) + len(seed_genres)
                   + len(seed_tracks)) > 5:
                if len(seed_artists) > 1:
                    seed_artists.pop()
                elif len(seed_genres) > 1:
                    seed_genres.pop()
                elif len(seed_tracks) > 1:
                    seed_tracks.pop()
                else:
                    break

            # --- Step 5: Call Spotify /v1/recommendations ---
            params = {"limit": str(limit + 5)}
            if seed_artists:
                params["seed_artists"] = ",".join(seed_artists)
            if seed_genres:
                params["seed_genres"] = ",".join(seed_genres)
            if seed_tracks:
                params["seed_tracks"] = ",".join(seed_tracks)

            qs = urllib.parse.urlencode(params)
            req = urllib.request.Request(
                f"https://api.spotify.com/v1/recommendations?{qs}",
                headers={"Authorization": f"Bearer {token}"})
            recs = json.load(urllib.request.urlopen(req, timeout=15))

            seen = set()
            for t in (recs.get("tracks") or []):
                t_artist = ((t.get("artists") or [{}])[0].get("name")
                            or "").strip()
                t_title = (t.get("name") or "").strip()
                if not t_artist or not t_title:
                    continue
                if norm(t_title) == t_norm:
                    continue
                key = norm(t_title)
                if key in seen:
                    continue
                seen.add(key)
                album_data = t.get("album") or {}
                images = album_data.get("images") or []
                cover = images[0].get("url") if images else ""
                out.append({
                    "kind": "song",
                    "artist": t_artist,
                    "title": t_title,
                    "album": album_data.get("name") or "",
                    "duration_s": int((t.get("duration_ms") or 0) / 1000),
                    "album_image": cover,
                    "url": None,
                    "provider": "Spotify",
                    "is_explicit": bool(t.get("explicit")),
                    "spotify_id": t.get("id"),
                })

            if out:
                random.shuffle(out)
                return out[:limit]

            self._log("spotify_recommendations: empty results from Spotify, "
                      "falling back")

        except Exception as ex:
            self._log(f"spotify_recommendations failed: {str(ex)[:80]}")

        # Fallback to the old same-artist approach
        return self.deezer_recommendations(artist, title, limit)

    # ------------------------------------------------------- version list
    def deezer_versions(self, artist, title):
        """All Deezer versions of a track (studio, live, remix, extended...).

        Returns a list of candidate dicts with a *type* tag and whether each
        is likely the plain studio original. Censored "clean"/edited versions
        are de-prioritized (kept only if nothing else survives).
        """
        import urllib.parse
        out = []
        t_norm = norm(title)
        key_norm = norm(artist) + " " + t_norm
        seen = set()

        def _collect(data, strict_artist):
            for e in (data or []):
                et = e.get("title_short") or e.get("title")
                ea = ((e.get("artist") or {}).get("name") or "")
                if norm(et) != t_norm:
                    continue
                if strict_artist and norm(ea) != norm(artist):
                    continue
                dedupe = norm(ea) + "|" + norm(et) + "|" + \
                    str(e.get("duration"))
                if dedupe in seen:
                    continue
                seen.add(dedupe)
                vt, is_studio = _version_kind(et, title)
                out.append({
                    "id": e.get("id"),
                    "name": et,
                    "artist": ea,
                    "album": (e.get("album") or {}).get("title") or "",
                    "album_image": (e.get("album") or {}).get("cover_big")
                    or "",
                    "duration_s": int(e.get("duration") or 0),
                    "explicit": bool(e.get("explicit_lyrics")),
                    "type": vt,
                    "is_studio": is_studio,
                    "source": "deezer",
                    "preview_url": e.get("preview") or None,
                })

        for q in (
            f'artist:"{artist}" track:"{title}"',
            f'{artist} {title}',
        ):
            try:
                u = urllib.parse.quote(q.encode("utf-8", "replace"))
                data = self._deezer_get(
                    f"https://api.deezer.com/search?q={u}&limit=25",
                    timeout=15)
                _collect(data.get("data") if data else None,
                         strict_artist=(q.startswith("artist:")))
                if out:
                    break
            except Exception as ex:                       # noqa: BLE001
                self._log(f"deezer_versions failed: {str(ex)[:60]}")
        return out


    def _deezer_track_match(self, base_name):
        """First Deezer /search hit matching 'Artist - Title' (same
        suffix-strip + artist-verify as covers). Returns the track dict."""
        import re as _re
        import unicodedata as _ud
        parts = (base_name or "").split(" - ", 1)
        artist = parts[0].strip() if len(parts) == 2 else ""
        title = (parts[1] if len(parts) == 2 else base_name or "").strip()

        def _nx(s):
            s = _ud.normalize("NFKD", s or "")
            s = "".join(c for c in s if not _ud.combining(c)).lower()
            return _re.sub(r"[^a-z0-9]+", "", s)

        # Strip video-suffix noise: "(Official Video)", "[Official Audio]",
        # " - Official ..." tails, "{...}".
        clean = _re.sub(r"\(.*?\)|\[.*?\]|\{.*?\}", " ", title)
        clean = _re.sub(r"\s*[-–—|:]\s*(official|lyric|audio|video|visualizer"
                        r"|mv|m/v|hd|4k).*$", " ", clean, flags=_re.I)
        clean = _re.sub(r"\s+", " ", clean).strip() or title
        queries = ([f'artist:"{artist}" track:"{clean}"', f"{artist} {clean}"]
                   if artist else [clean, title])
        want_a, want_t = _nx(artist), _nx(clean)
        fallback = None
        for q in queries:
            try:
                data = self._deezer_get(
                    "https://api.deezer.com/search?q="
                    + __import__("urllib.parse", fromlist=["quote"]).quote(q)
                    + "&limit=5", timeout=10)
            except Exception:                           # noqa: BLE001
                continue
            for e in (data.get("data") if data else None) or []:
                ea = _nx((e.get("artist") or {}).get("name"))
                et = _nx(e.get("title_short") or e.get("title"))
                if artist and ea != want_a:
                    continue
                if fallback is None:
                    fallback = e
                if et and want_t and (et == want_t or want_t in et
                                      or et in want_t):
                    return e
            if fallback:
                return fallback
        return None

    def _deezer_album(self, base_name):
        """Best-effort Deezer album title for 'Artist - Title' or None."""
        try:
            e = self._deezer_track_match(base_name)
            return ((e.get("album") or {}).get("title") or None) if e else None
        except Exception:                               # noqa: BLE001
            return None

    def _deezer_cover(self, base_name):
        """Best-effort Deezer album art for a track by 'Artist - Title'.

        YouTube candidate titles carry '(Official Video)'-style suffixes
        that make a literal `search?q=<full string>&limit=1` return nothing,
        so clean the title and verify the artist over the top hits instead
        of blindly taking hit #1."""
        try:
            e = self._deezer_track_match(base_name)
            return ((e.get("album") or {}).get("cover_big") or None) \
                if e else None
        except Exception:                               # noqa: BLE001
            return None

    def _deezer_get(self, url, timeout=12):
        import urllib.request
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0"})
            return json.load(urllib.request.urlopen(req, timeout=timeout))
        except Exception as ex:                       # noqa: BLE001
            self._log(f"deezer http failed ({url[:50]}): {str(ex)[:50]}")
            return None

    def deezer_artist_albums(self, artist):
        """Whole discography for an artist: one entry per studio album.

        Deezer's /artist/{id}/albums omits several core studio albums and
        often only serves classic records as "(Remastered)/(Deluxe)" editions,
        so we merge the artist album list with a search, and dedupe by a
        normalization that ignores cosmetic suffixes like "remastered",
        "deluxe", "box set", "(version)". We keep the best available Deezer
        album id for playback.

        Returns: [{album, album_artist, image, tracks, year, album_id}]
        """
        import urllib.parse
        import re as _re
        # Content that is genuinely a DIFFERENT recording we usually don't
        # want in a studio discography.
        reject = ("greatest hits", "live at", " official live", " (live",
                  " - live", "karaoke", "instrumental", "demo",
                  "rehearsal", "acoustic session", "collection",
                  "best of", "the essential", "back to black",
                  "unplugged", "mtv", "live in ", "live from", "live session",
                  "radio city", "at the apollo", "wembley", "en concert",
                  "en direct")

        def core_title(title):
            a = _re.sub(r"\(.*?\)|\[.*?\]|\{.*?\}",
                        " ", title or "")
            a = _re.sub(r"\b(remaster(?:ed)?|deluxe|bonus|box\s*set|"
                        r"anniversary|expanded)\b", " ", a, flags=_re.I)
            return _re.sub(r"\s+", " ", a).strip().lower()

        try:
            data = self._deezer_get(
                "https://api.deezer.com/search/artist?q="
                + urllib.parse.quote(artist) + "&limit=8")
            items = (data or {}).get("data") or []
            if not items:
                return []
            # Deezer's relevance ranking can put impostors/clones first
            # (e.g. "Queen(Ares)" above the real band "Queen", whose exact
            # name the search still returns). Pick the CANONICAL artist:
            # prefer an exact normalized-name match, then the one with the
            # most albums. Ignore non-exact matches entirely when any exist.
            target = norm(artist or "")
            exact = [i for i in items
                     if norm(i.get("name") or "") == target]
            pool = exact if exact else items
            chosen = max(pool, key=lambda i: i.get("nb_album") or 0)
            art_name = chosen["name"]
            aid = chosen["id"]
            art_norm = norm(art_name)

            def ok(album):
                if (album.get("record_type") or "").lower() == "live":
                    return False
                album_artist = (album.get("artist") or {}).get("name") or ""
                if album_artist and norm(album_artist) != art_norm:
                    return False
                title = album.get("title") or ""
                if not title:
                    return False
                ltitle = title.lower()
                for k in reject:
                    if k in ltitle:
                        return False
                return True

            candidates = []   # (priority, core_key, album_dict)
            def add(album, priority):
                if not ok(album):
                    return
                title = album.get("title") or ""
                core = core_title(title)
                if not core:
                    return
                candidates.append((priority, core, dict(
                    album=title,
                    album_artist=(album.get("artist") or {}).get("name")
                    or art_name,
                    image=album.get("cover_xl") or album.get("cover_big"),
                    tracks=int(album.get("nb_tracks") or 0),
                    year=(album.get("release_date") or "")[:4]
                    if album.get("release_date") else None,
                    album_id=album.get("id"),
                    record_type=album.get("record_type") or None,
                )))

            # 1) artist's own album list
            albs = self._deezer_get(
                f"https://api.deezer.com/artist/{aid}/albums?limit=100")
            for a in (albs or {}).get("data") or []:
                add(a, 0)
            # 2) search (finds core albums the artist feed omits)
            try:
                q = urllib.parse.quote(f'artist:"{artist}"')
                resp = self._deezer_get(
                    "https://api.deezer.com/search/album?q=" + q + "&limit=100")
                for a in (resp or {}).get("data") or []:
                    add(a, 1)
            except Exception:                            # noqa: BLE001
                pass

            merged = {}
            for priority, core, d in candidates:
                # priority 0 (plain title from artist feed) beats a search hit
                pri, cur = merged.get(core, (9, None))
                if cur is None or priority < pri:
                    merged[core] = (priority, d)
            out = []
            for _p, d in merged.values():
                rt = (d.get("record_type") or "").lower()
                if rt in ("album", "single"):      # Deezer's own labels
                    dtype = rt
                elif rt in ("ep",):
                    dtype = "ep"
                else:                               # unknown -> treat as album
                    dtype = "album"
                d["type"] = dtype
                d.pop("record_type", None)
                out.append(d)
            return out
        except Exception as ex:                       # noqa: BLE001
            self._log(f"deezer_artist_albums failed: {str(ex)[:60]}")
            return []

    def deezer_album_tracks_by_id(self, album_id):
        """Fetch an album's full track list directly by Deezer album id.

        Returns a list of dicts: {base_name, artist, album, album_image,
        duration_s}. Empty list on any failure or unknown id.
        """
        import urllib.request
        try:
            raw = self._deezer_get(
                f"https://api.deezer.com/album/{album_id}", timeout=15)
            if not raw or not raw.get("id"):
                return []
            cover = raw.get("cover_xl") or raw.get("cover_big")
            album = raw.get("title") or ""
            rows = raw.get("tracks") or {}
            data = rows.get("data") or []
            out = []
            for t in data:
                title = t.get("title") or t.get("title_short") or ""
                if not title:
                    continue
                if re.search(r"\blive\b|\bconcert\b| \(live\)| at \w+\d{4}",
                             title, re.I):
                    continue
                ta = (t.get("artist") or {}).get("name") or ""
                out.append(dict(
                    base_name=f"{ta} - {title}",
                    artist=ta, album=album, album_image=cover,
                    duration_s=int(t.get("duration") or 0) or None,
                ))
            return out
        except Exception as ex:                       # noqa: BLE001
            self._log(f"deezer_album_tracks_by_id failed: {str(ex)[:60]}")
            return []

    def deezer_album_tracks(self, artist, album):
        """Full track list for an album.

        Returns a list of dicts: {base_name, artist, album, album_image,
        duration_s}. Empty list on any failure.
        """
        import urllib.parse
        try:
            q = urllib.parse.quote(f'artist:"{artist}" album:"{album}"')
            data = self._deezer_get(
                "https://api.deezer.com/search/album?q=" + q + "&limit=20")
            art_norm = norm(artist)
            picks = []
            for a in (data or {}).get("data") or []:
                at = a.get("title") or ""
                if not at:
                    continue
                aa = (a.get("artist") or {}).get("name") or ""
                if aa and norm(aa) != art_norm:
                    continue
                picks.append(a)
            pick = None
            for a in picks:
                if norm(a.get("title") or "") == norm(album):
                    pick = a
                    break
            if not pick:
                # No exact title match in the first page — fall back to a
                # best-effort substring match, otherwise give up (don't
                # attach a random track list to the album).
                aq = norm(album)
                for a in picks:
                    at = norm(a.get("title") or "")
                    if aq and at and (aq in at or at in aq):
                        pick = a
                        break
            if not pick:
                return []
            tl = self._deezer_get(pick.get("tracklist"), timeout=15)
            cover = pick.get("cover_xl") or pick.get("cover_big")
            art = (pick.get("artist") or {}).get("name") or artist
            out = []
            for t in (tl or {}).get("data") or []:
                title = t.get("title") or t.get("title_short") or ""
                if not title:
                    continue
                if re.search(r"\blive\b|\bconcert\b| \(live\)| at \w+\d{4}",
                             title, re.I):
                    continue
                ta = (t.get("artist") or {}).get("name") or art
                out.append(dict(
                    base_name=f"{ta} - {title}",
                    artist=ta, album=album, album_image=cover,
                    duration_s=int(t.get("duration") or 0) or None,
                ))
            return out
        except Exception as ex:                       # noqa: BLE001
            self._log(f"deezer_album_tracks failed: {str(ex)[:60]}")
            return []

    def deezer_duration(self, cache_key, artist, title):
        """Ground-truth studio duration from Deezer's public API."""
        if cache_key in self._deezer_cache:
            return self._deezer_cache[cache_key]

        result = self._deezer_search_duration(artist, title)
        self._deezer_cache[cache_key] = result
        try:
            import os
            os.makedirs(os.path.dirname(self._cache_path), exist_ok=True)
            with open(self._cache_path, "w") as fh:
                json.dump(self._deezer_cache, fh)
        except Exception:
            pass
        time.sleep(0.4)
        return result

    def _deezer_search_duration(self, artist, title):
        """Best studio duration for artist+title. Tries the strict Deezer
        'artist:".." track:".."' query first, then falls back to a plain
        'artist title' search — the strict field query returns 0 hits for
        some artists (e.g. Marea - "El temblor")."""
        import urllib.parse
        t_norm = norm(title)
        t_core = norm(title_core(title))
        a_norm = norm(artist)

        def pick(data):
            if not data:
                return None
            alt = re.compile(
                r"\blive\b|\bacoustic\b|\bpiano\b|\bdemo\b|\bremix\b|"
                r"\brehearsal\b|\bmono\b|\binstrumental\b", re.I)
            want_alt = bool(alt.search(title))
            # 1st pass: exact (normalized) title, artist match, prefer the
            # non-alt form that matches what the user asked for. A bare
            # remaster tag ("Paranoid (Remastered 2009)") is the same
            # studio recording under a longer title, so it matches too.
            for e in data:
                et = e.get("title", "")
                if norm(et) != t_norm and norm(title_core(et)) != t_core:
                    continue
                ea = norm((e.get("artist") or {}).get("name") or "")
                if ea and ea != a_norm and a_norm not in ea:
                    continue
                is_alt = bool(alt.search(et))
                if is_alt != want_alt:
                    continue
                d = e.get("duration")
                if d and d > 30:
                    return int(d)
            # 2nd pass: any row whose normalized title matches (same
            # remaster tolerance as above).
            for e in data:
                if (norm(e.get("title", "")) == t_norm
                        or norm(title_core(e.get("title", ""))) == t_core) \
                        and e.get("duration"):
                    return int(e["duration"])
            return None

        for q in (
            f'artist:"{artist}" track:"{title}"',
            f'{artist} {title}',
        ):
            u = urllib.parse.quote(
                q.encode("utf-8", "replace"))
            data = self._deezer_get(
                f"https://api.deezer.com/search?q={u}&limit=25", timeout=15)
            if not data or not data.get("data"):
                continue
            hit = pick(data.get("data"))
            if hit is not None:
                return hit
        return None


def ffprobe_duration(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=15)
        return float(r.stdout.strip())
    except Exception:
        return None


def fpcalc_fingerprint(path, fpcalc_bin="fpcalc"):
    """Run Chromaprint's `fpcalc` on an audio file and return
    {'fingerprint', 'duration'}, or None on any failure."""
    try:
        r = subprocess.run(
            [fpcalc_bin, "-json", path],
            capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            print(f"[fpcalc] rc={r.returncode} err={r.stderr.strip()!r}",
                  flush=True)
            return None
        data = json.loads(r.stdout)
        fp = (data.get("fingerprint") or "").strip()
        dur = data.get("duration")
        if not fp:
            print("[fpcalc] empty fingerprint", flush=True)
            return None
        return {"fingerprint": fp, "duration": dur}
    except Exception as e:                             # noqa: BLE001
        print(f"[fpcalc] exception: {e!r}", flush=True)
        return None


def acoustid_lookup(fingerprint, duration, api_key, duration_ms=None):
    """Query the AcoustID Web API for the recording that best matches a
    Chromaprint fingerprint. Returns a dict with the top candidate's
    artist/title or None. Needs a free AcoustID API key."""
    import urllib.parse
    import urllib.request
    if not api_key or not fingerprint:
        return None
    try:
        params = {
            "client": api_key,
            "fingerprint": fingerprint,
            "format": "json",
            "meta": "recordings",
        }
        if duration:
            params["duration"] = int(round(duration))
        qs = urllib.parse.urlencode(params)
        req = urllib.request.Request(
            f"https://api.acoustid.org/v2/lookup?{qs}",
            headers={"User-Agent": "gungan.fm/1.0"})
        try:
            data = json.load(urllib.request.urlopen(req, timeout=20))
        except Exception as e:                          # noqa: BLE001
            print(f"[acoustid] NETWORK exception: {e!r}", flush=True)
            return {"_debug": f"network: {e!r}"}
        nres = len(data.get("results") or [])
        print(f"[acoustid] results={nres} duration={duration}", flush=True)
        if "error" in data or data.get("status") != "ok":
            print(f"[acoustid] api error: {data.get('error')}", flush=True)
            return {"_debug": f"api: {data.get('error')}"}
        for r in (data.get("results") or []):
            score = r.get("score") or 0
            for rec in (r.get("recordings") or []):
                artists = [
                    (a.get("name") or "") for a in (rec.get("artists") or [])
                ]
                title = rec.get("title") or ""
                if not title:
                    continue
                return {
                    "score": score,
                    "title": title,
                    "artist": ", ".join(artists),
                    "track_id": rec.get("id"),
                    "duration": rec.get("duration"),
                }
        return {"_debug": f"ok but {nres} results, no titled recording"}
    except Exception as e:                             # noqa: BLE001
        print(f"[acoustid] exception: {e!r}", flush=True)
        return {"_debug": f"exception: {e!r}"}
    return None

