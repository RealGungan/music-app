"""Best-effort lyrics lookup (stdlib only).

Primary source: LRC Lib (https://lrclib.net) which serves both synced LRC
and plain-text lyrics with no API key. Fallback: lyrics.ovh plain text.

The server fetches on demand (streaming/playlist views) and also writes a
sidecar file next to a song when it is kept, so lyrics survive offline:

    <song>.lrc   -> synced lyrics (LRC timestamped)
    <song>.txt   -> plain-text fallback

Everything degrades gracefully to None on network errors — lyrics are
never fatal.
"""

import json
import logging
import os
import re
import threading
import time
import urllib.parse
import urllib.request

logger = logging.getLogger(__name__)

_UA = {"User-Agent": "Mozilla/5.0 (NASMusic)"}

_lrc_re = re.compile(r"\[(\d{1,2}):(\d{1,2})(?:[.:](\d{1,3}))?\]")

# in-memory cache: key -> (fetched_at, result | None). Negative results
# cached briefly so a missing song isn't hammered on every re-open.
_cache = {}
_cache_lock = threading.Lock()
_POS_TTL = 86400      # keep positive results for a day
_NEG_TTL = 900        # remember "none" for 15 minutes


def _norm(s):
    s = s or ""
    s = s.lower()
    s = re.sub(r"[\[\(].*?[\]\)]", " ", s)   # drop (ft. X), [Remastered],...
    s = re.sub(r"\b(ft\.?|feat\.?|featuring)\b[^,]*", " ", s)
    return re.sub(r"[^a-z0-9]+", "", s)


def _artist_matches(their, ours):
    if not ours:
        return True
    if _norm(their) == _norm(ours):
        return True
    # "2Pac, Big Syke" vs "2Pac & Big Syke" -> any shared artist token
    def parts(s):
        return {_norm(p) for p in re.split(r"[,&+]", s or "") if _norm(p)}
    return bool(parts(their) & parts(ours))


def parse_lrc(lrc_text):
    """Turn LRC text into [(seconds: float, text: str), ...] in order."""
    out = []
    for line in (lrc_text or "").splitlines():
        tags = list(_lrc_re.finditer(line))
        if not tags:
            continue
        text = _lrc_re.sub("", line).strip()
        if not text:
            continue
        for m in tags:
            mm, ss, frac = int(m.group(1)), int(m.group(2)), m.group(3)
            secs = mm * 60 + ss
            if frac:
                n = len(frac)
                secs += int(frac) / (10, 100, 1000)[n - 1]
            out.append((round(secs, 3), text))
    out.sort(key=lambda x: x[0])
    return out


def _get(url, timeout=12):
    req = urllib.request.Request(url, headers=_UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read().decode("utf-8", "replace")


def _lrc_lib(artist, title):
    """Try LRC Lib. Returns (raw_text, is_synced) or None."""
    params = {"artist_name": artist or ""}
    if title:
        params["track_name"] = title
    q = urllib.parse.urlencode(params)
    try:
        body = _get(f"https://lrclib.net/api/get?{q}")
    except Exception as ex:                           # noqa: BLE001
        logger.info("lrclib exact failed: %s", str(ex)[:80])
        return None
    try:
        data = json.loads(body)
    except ValueError:
        return None
    if not isinstance(data, dict) or data.get("instrumental"):
        return None
    sync = data.get("syncedLyrics")
    if sync:
        return sync, True
    plain = data.get("plainLyrics")
    if plain:
        return plain, False

    # exact match absent -> broad search, pick best title/artist match
    try:
        q2 = urllib.parse.urlencode(
            {"q": f"{artist or ''} {title or ''}".strip()})
        body = _get(f"https://lrclib.net/api/search?{q2}")
        items = json.loads(body)
    except Exception as ex:                           # noqa: BLE001
        logger.info("lrclib search failed: %s", str(ex)[:80])
        return None
    best = None
    for it in items:
        if not isinstance(it, dict) or it.get("instrumental"):
            continue
        if title and _norm(it.get("name")) != _norm(title):
            continue
        if artist and not _artist_matches(it.get("artistName"), artist):
            continue
        best = it
        break
    if best is None:
        # relaxed: title only (parentheses/strip-feat aware), then any
        for it in items:
            if not isinstance(it, dict) or it.get("instrumental"):
                continue
            if not title or _norm(it.get("name")) != _norm(title):
                continue
            best = it
            break
    if best is None:
        best = next((it for it in items
                     if isinstance(it, dict) and not it.get("instrumental")),
                    None)
    if not best:
        return None
    sync = best.get("syncedLyrics")
    if sync:
        return sync, True
    plain = best.get("plainLyrics")
    if plain:
        return plain, False
    return None


def _lyrics_ovh(artist, title):
    """Plain-text fallback."""
    if not artist:
        return None
    url = f"https://api.lyrics.ovh/v1/{urllib.parse.quote(artist)}/{urllib.parse.quote(title or '')}"
    try:
        body = _get(url)
        data = json.loads(body)
    except Exception as ex:                           # noqa: BLE001
        logger.info("lyrics.ovh failed: %s", str(ex)[:80])
        return None
    text = (data or {}).get("lyrics") or ""
    lines = [ln.strip() for ln in text.splitlines() if ln.strip()]
    if not lines:
        return None
    return lines, False


def split_base(base_name):
    """'Artist - Title' -> (artist, title). Also cleans literal `.ext`."""
    base_name = re.sub(r"\.\{ext\}$", "", base_name or "")
    if " - " in base_name:
        artist, title = base_name.split(" - ", 1)
        return artist.strip(), title.strip()
    return "", (base_name or "").strip()


def fetch_lyrics(base_name, force=False, artist=None, title=None):
    """Return lyrics payload dict for a song (network lookups cached).

    artist/title may be given explicitly (resolved internet identity); when
    omitted they are parsed from base_name ('Artist - Title')."""
    now = time.time()
    fetch_artist = artist if artist is not None and artist.strip() else None
    fetch_title = title
    with _cache_lock:
        hit = _cache.get(base_name)
        if not force and hit:
            fetched, result = hit
            ttl = _POS_TTL if result else _NEG_TTL
            if now - fetched < ttl:
                return result

    if fetch_artist is None or fetch_title is None:
        p_artist, p_title = split_base(base_name)
        if fetch_artist is None:
            fetch_artist = p_artist
        if fetch_title is None:
            fetch_title = p_title
    artist, title = fetch_artist, fetch_title
    result = None
    res = _lrc_lib(artist, title) if artist or title else None
    if res:
        raw, is_synced = res
        result = {
            "base_name": base_name,
            "artist": artist,
            "title": title,
            "source": "lrclib",
            "raw": raw,
            "synced": is_synced,
            "lines": parse_lrc(raw) if is_synced else
                     [ln.strip() for ln in raw.splitlines() if ln.strip()],
        }
    else:
        res = _lyrics_ovh(artist, title) if artist or title else None
        if res:
            lines, _ = res
            result = {
                "base_name": base_name,
                "artist": artist,
                "title": title,
                "source": "lyricsovh",
                "raw": None,
                "synced": False,
                "lines": lines,
            }

    with _cache_lock:
        _cache[base_name] = (now, result)
    return result


def save_sidecar(state, base_name, dest_dir):
    """Fetch lyrics and write <song>.lrc / <song>.txt next to the mp3.

    Best-effort: never raises. Returns the sidecar filename or None.
    """
    try:
        res = fetch_lyrics(base_name)
        if not res:
            return None
        stem = os.path.join(dest_dir, base_name)
        if res["synced"] and res["raw"]:
            path = stem + ".lrc"
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(res["raw"])
            return os.path.basename(path)
        if res["lines"]:
            path = stem + ".txt"
            with open(path, "w", encoding="utf-8") as fh:
                fh.write("\n".join(res["lines"]) + "\n")
            return os.path.basename(path)
    except Exception as ex:                           # noqa: BLE001
        logger.info("lyrics sidecar failed: %s", str(ex)[:80])
    return None