"""Ported from tools/download_manual.py (manual-verification downloader).

Same candidate search / channel-tiering / duration-consensus logic,
refactored into reusable functions with injectable yt-dlp binary and
node runtime. The Deezer lookup supplies ground-truth studio durations
so we can tell the album version from uploads with intros/outros.
"""

import json
import re
import subprocess
import time
import unicodedata
from collections import Counter

# hard rejects on title/channel text (never the album version)
REJECT = re.compile(
    r"\blive\b|\bdemo\b|\bremix\b|\brehearsal\b|\bsession\b|"
    r"\binstrumental\b|\bkaraoke\b|\bcover\b|\bacoustic\b|"
    r"\bnightcore\b|\bslowed\b|\bsped up\b|\breverb\b|\b8d\b|"
    r"\bbass boosted\b|\bloop\b|\bmashup\b|\bmedley\b|\breaction\b|"
    r"\b1 hour\b|\bfull album\b|\bextended\b|\bversion 2\b|second version",
    re.I)

# mild penalty: real audio but often has video intro/outro edits
VIDEOISH = re.compile(
    r"music video|official video|official hd video|\bmv\b|videoclip|"
    r"visualizer|4k|upgrad", re.I)

# bonus: strong signals of a plain album-audio upload
AUDIOISH = re.compile(
    r"official audio|\(audio\)|\baudio\b|full version|album version|"
    r"topic\b|lyric video|official lyric", re.I)


def norm(s):
    s = unicodedata.normalize("NFKD", s)
    s = "".join(c for c in s if not unicodedata.combining(c)).lower()
    return re.sub(r"[^a-z0-9]+", "", s)


class Scorer:
    def __init__(self, yt_dlp_bin="yt-dlp", node_runtime="",
                 log_fn=print):
        self.yt_dlp_bin = yt_dlp_bin
        self.node_runtime = node_runtime
        self._log = log_fn
        self._deezer_cache = {}
        self._cache_path = "/tmp/opencode/staging_deezer_cache.json"
        try:
            with open(self._cache_path) as fh:
                self._deezer_cache = json.load(fh)
        except Exception:
            pass

    # ------------------------------------------------------------------ yt
    def ytdlp(self, args, timeout=180):
        cmd = [self.yt_dlp_bin]
        if self.node_runtime:
            cmd += ["--js-runtimes", f"node:{self.node_runtime}"]
        cmd += args
        try:
            return subprocess.run(
                cmd, capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            class R:
                stdout, stderr, returncode = "", "timeout", -1
            return R()

    def search_ytmusic(self, query):
        """YouTube Music candidates (no safe-search filter, structured)."""
        try:
            from ytmusicapi import YTMusic
            out = []
            for r in (YTMusic().search(query, filter="songs", limit=15)
                      or []):
                vid = r.get("videoId")
                if not vid:
                    continue
                dur = r.get("duration_seconds")
                if not dur:
                    d = r.get("duration") or ""
                    parts = [int(p) for p in d.split(":") if p.isdigit()]
                    dur = sum(v * 60 ** i for i, v in
                              enumerate(reversed(parts))) if parts else 0
                artists = ", ".join(a.get("name", "")
                                    for a in r.get("artists") or [])
                out.append(dict(video_id=vid, duration_s=int(dur or 0),
                                title=r.get("title", ""), channel=artists,
                                uploader="", views=0))
            return out
        except Exception as ex:                      # noqa: BLE001
            self._log(f"ytmusic search failed: {str(ex)[:60]}")
            return []

    def search(self, artist, title):
        """Candidates merged from YouTube + YouTube Music.

        With both parts -> 'quoted artist' 'quoted title'.
        Free text (no artist) -> one quoted phrase.
        """
        if artist:
            q = f'"{artist}" "{title}"'
        else:
            q = f'"{title}"'
        r = self.ytdlp(["--flat-playlist", "--print",
                        "%(id)s\t%(duration)s\t%(title)s\t%(channel)s\t"
                        "%(uploader)s\t%(view_count)s",
                        f"ytsearch15:{q}"])
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
        for c in self.search_ytmusic(f"{artist} {title}".strip()):
            if c["video_id"] not in seen:
                out.append(c)
        return out

    def resolve_url(self, video_id, timeout=120):
        """Direct streamable URL (googlevideo) for playback."""
        r = self.ytdlp(
            ["-f", "bestaudio/best", "-g",
             f"https://www.youtube.com/watch?v={video_id}"],
            timeout=timeout)
        url = (r.stdout or "").strip().splitlines()
        return url[-1] if url else None

    def download(self, video_id, target_mp3, timeout=300):
        base = target_mp3[: -(len(".mp3"))] if target_mp3.endswith(".mp3") \
            else target_mp3
        return self.ytdlp(
            ["-f", "bestaudio/best", "--extract-audio",
             "--audio-format", "mp3", "--audio-quality", "192K",
             "--embed-thumbnail", "--add-metadata",
             "--no-part", "--no-mtime",
             "-o", base + ".%(ext)s",
             f"https://www.youtube.com/watch?v={video_id}"],
            timeout=timeout)

    # -------------------------------------------------------------- scoring
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
        """Score & sort; returns (scored_list, consensus_duration).

        scored items: dict(video_id, title, channel, duration_s, score, tier)
        """
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
            sc += sum(2 for i in range(0, len(title_n), 6)
                      if title_n[i:i + 3] in tn)
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
                               duration_s=dur, score=sc, tier=tier))

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
        return scored, consensus

    # --------------------------------------------------------------- deezer
    def deezer_search(self, query):
        """Best-effort metadata for free-text queries.

        Returns {'artist','title','duration_s'} or None.
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
        except Exception as ex:
            self._log(f"deezer_search failed: {str(ex)[:60]}")
        return None

    def deezer_duration(self, cache_key, artist, title):
        """Ground-truth studio duration from Deezer's public API."""
        if cache_key in self._deezer_cache:
            return self._deezer_cache[cache_key]

        import urllib.parse
        import urllib.request
        result = None
        try:
            q = urllib.parse.quote(f'artist:"{artist}" track:"{title}"')
            url = f"https://api.deezer.com/search?q={q}&limit=20"
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0"})
            data = json.load(urllib.request.urlopen(req, timeout=15))

            alt = re.compile(
                r"\blive\b|\bacoustic\b|\bpiano\b|\bdemo\b|\bremix\b|"
                r"\brehearsal\b|\bmono\b|\binstrumental\b", re.I)
            want_alt = bool(alt.search(title))
            t_norm = norm(title)

            best = None
            for e in data.get("data", []):
                et = e.get("title", "")
                if norm(et) != t_norm:
                    continue
                is_alt = bool(alt.search(et))
                if is_alt != want_alt:
                    continue
                d = e.get("duration")
                if d and d > 30:
                    best = int(d)
                    break
            if best is None:
                for e in data.get("data", []):
                    if norm(e.get("title", "")) == t_norm \
                            and e.get("duration"):
                        best = int(e["duration"])
                        break
            result = best
        except Exception as ex:
            self._log(f"deezer lookup failed: {str(ex)[:60]}")

        self._deezer_cache[cache_key] = result
        try:
            with open(self._cache_path, "w") as fh:
                json.dump(self._deezer_cache, fh)
        except Exception:
            pass
        time.sleep(0.4)
        return result


def ffprobe_duration(path):
    try:
        r = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "default=noprint_wrappers=1:nokey=1", path],
            capture_output=True, text=True, timeout=15)
        return float(r.stdout.strip())
    except Exception:
        return None
