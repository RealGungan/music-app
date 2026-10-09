"""NASMusic HTTP server exposing the /staging/ API.

Pure-stdlib ThreadingHTTPServer so it runs anywhere Python can, with no
extra framework dependency. Serves:

    GET    /staging/                     index/info
    GET    /staging/api/search?q=        local + discovery results
    POST   /staging/api/stage            start a staging download
    GET    /staging/api/jobs             live job statuses
    GET    /staging/api/downloads        download rows
    GET    /staging/api/downloads/<id>   download detail + candidates
    DELETE /staging/api/downloads/<id>   delete track + history
    POST   /staging/api/redownload       replace a file with another id
    POST   /staging/api/keep             add-to-playlist from any state
    GET    /staging/api/playlists        list playlists
    POST   /staging/api/playlists        create playlist
    GET    /staging/api/playlists/<name> playlist detail
    DELETE /staging/api/playlists/<name> delete playlist
    DELETE /staging/api/playlists/<name>/entries  remove one entry
    POST   /staging/api/playlists/<name>/meta      import added-at/art
    GET    /staging/api/resolve/<vid>    direct streamable URL
    GET    /staging/api/cover?f=         album art for a library file
    GET    /staging/api/tracks           whole-library index
    GET    /staging/file/<rel>           stream a library file (ranges)
    GET    /staging/pl/<rel>             stream a playlist-dir file
"""

import json
import logging
import mimetypes
import os
import posixpath
import re
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from .users import UserError

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("nasmusic")

# ---------------------------------------------------------------- ytmusic auth
# YouTube now wants a 3-part SAPISIDHASH authorization header; ytmusicapi
# 1.12.3 still emits the legacy single part, and authed library calls 400.
# We override the header builder process-wide (registry keyed by SAPISID
# value -> full cookie, fed at YTMusic construction): known cookies get
# the 3-part form, everything else byte-identical legacy output.
_ytm_cookie_lock = threading.Lock()
_ytm_cookies = {}  # sapisid value -> raw cookie header


def _ytm_register_cookie(cookie):
    """Remember a full cookie for 3-part auth building. Returns its
    SAPISID value or ''."""
    try:
        from http.cookies import SimpleCookie
        jar = SimpleCookie()
        jar.load(cookie.replace('"', ""))
        sap = jar["SAPISID"].value if "SAPISID" in jar else ""
    except Exception:                                # noqa: BLE001
        return ""
    if not sap:
        return ""
    with _ytm_cookie_lock:
        _ytm_cookies[sap] = cookie
        while len(_ytm_cookies) > 50:
            _ytm_cookies.pop(next(iter(_ytm_cookies)))
    return sap


def _ytm_auth_header(auth):
    """Drop-in for ytmusicapi.helpers.get_authorization(auth) where auth
    is '<SAPISID> <origin>'. 3-part form when the cookie is registered,
    else the exact legacy single-part output."""
    import hashlib
    import time as _time
    try:
        sap, _, origin = auth.partition(" ")
    except Exception:                                # noqa: BLE001
        sap, origin = "", ""
    ts = str(int(_time.time()))
    import http.cookies as _ck
    full = ""
    with _ytm_cookie_lock:
        full = _ytm_cookies.get(sap, "")
    if full:
        try:
            jar = _ck.SimpleCookie()
            jar.load(full.replace('"', ""))
            vals = {
                "": jar["SAPISID"].value if "SAPISID" in jar else "",
                "1P": jar["__Secure-1PAPISID"].value
                if "__Secure-1PAPISID" in jar else "",
                "3P": jar["__Secure-3PAPISID"].value
                if "__Secure-3PAPISID" in jar else "",
            }
            if vals[""] and vals["1P"] and vals["3P"]:
                parts = []
                for suffix, v in (("", vals[""]),
                                  ("1P", vals["1P"]), ("3P", vals["3P"])):
                    h = hashlib.sha1(
                        f"{ts} {v} {origin}".encode()).hexdigest()
                    parts.append(f"SAPISID{suffix}HASH {ts}_{h}_u")
                return " ".join(parts)
        except Exception:                            # noqa: BLE001
            pass
    h0 = hashlib.sha1(f"{ts} {auth}".encode()).hexdigest()
    return "SAPISIDHASH " + ts + "_" + h0


_ytm_auth_patched = False


def _install_ytm_auth_patch():
    """Point ytmusicapi's per-request auth builder at _ytm_auth_header
    (3-part when registered, legacy otherwise). Once per process."""
    global _ytm_auth_patched
    if _ytm_auth_patched:
        return
    try:
        import ytmusicapi.ytmusic as _ym
        _ym.get_authorization = _ytm_auth_header
        _ytm_auth_patched = True
    except Exception:                                # noqa: BLE001
        pass


def _register_ytm_browser_cookie(path):
    """Feed a browser.json cookie into the 3-part registry."""
    import json as _json
    try:
        with open(path, encoding="utf-8") as fh:
            data = _json.load(fh)
    except Exception:                                # noqa: BLE001
        return
    cookie = ""
    if isinstance(data, dict):
        for k in ("cookie", "Cookie", "headers"):
            v = data.get(k)
            if isinstance(v, dict):
                v = v.get("cookie") or v.get("Cookie") or ""
            if v:
                cookie = v
                break
    if cookie:
        _ytm_register_cookie(cookie)

# ---------------------------------------------------------------- landing
# Public join page (2026-09-18): a browser opening the funnel URL gets
# this HTML (app download + register form) instead of a bare 401, so
# friends can actually join. API clients (curl/app) keep getting JSON.
# Security: fully static, zero user-input reflection (the register form
# uses textContent only, never innerHTML) — no XSS surface. Register
# spam is covered by the existing per-IP rate limit.
APP_VERSION = "1.0.282"

LANDING_HTML = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>gungan.fm \u2014 join</title>
<style>:root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#101010;color:#eee;font-family:system-ui,-apple-system,sans-serif;min-height:100vh;display:flex;justify-content:center;padding:24px 16px}h1{color:#1db954;margin:8px 0 4px;font-size:28px}.wrap{width:100%;max-width:480px}.sub{color:#bbb;margin:0 0 16px}.card{background:#1c1c1c;border:1px solid #2a2a2a;border-radius:14px;padding:16px;margin:0 0 12px;line-height:1.5}.step{color:#1db954;margin:8px 0 4px;font-size:28px}.btn{display:inline-block;background:#1db954;color:#06130c;font-weight:700;border-radius:10px;padding:12px 22px;text-decoration:none;margin-top:10px}</style>
</head><body><div class="wrap">
<h1>gungan.fm</h1><p class="sub">Private family music server. To join:</p>
<div class="card"><span class="step">1.</span> <b>Install the app</b><br><a class="btn" href="/staging/app.apk?v=1.0.16">Download gungan.fm 1.0.16 (Android)</a></div>
<div class="card"><span class="step">2.</span> <b>Create an account</b><br>Open the app, tap <b>Create account</b> and enter the invite code.</div>
<div class="card"><span class="step">3.</span> <b>Log in</b><br>Sign in with your new account. Your playlists stay private to you.</div>
</div></body></html>""".replace("1.0.16", APP_VERSION)

# Playlist names: any Unicode incl. emoji, except path separators,
# control chars, dot-only names and ".." (traversal). Length capped.
SAFE_PLAYLIST = re.compile(r"^(?![\s.]*$)(?!.*\.\.)[^\x00-\x1f/\\]{1,120}$")

# db misc key holding the user's custom playlist display order (name list).
_PLAYLIST_ORDER_KEY = "playlist_order"

# ------------------------------------------- public-exposure hardening
# 2026-09-18: served over Tailscale Funnel to the open internet, so every
# sink below assumes registered users may be hostile. Stdlib only.
MAX_JSON_BODY = 2 * 1024 * 1024       # _body_json cap (memory-DoS guard)
VID_RE = re.compile(r"[A-Za-z0-9_\-]{5,80}")   # YouTube video ids
MAX_TRACK_FIELD = 120                 # artist/title length cap
MAX_COVER_CACHE = 200                 # _relay_image entries
MAX_COVER_BYTES = 5 * 1024 * 1024     # single relayed image cap

_RATE_BUCKETS = {}                    # key -> [timestamps]
_RATE_LOCK = threading.Lock()


def _rate_allow(key, max_n, window_s):
    """Sliding-window rate limiter (in-process). True when allowed."""
    now = time.time()
    with _RATE_LOCK:
        b = _RATE_BUCKETS.get(key)
        if b is None:
            b = _RATE_BUCKETS[key] = []
        while b and b[0] <= now - window_s:
            b.pop(0)
        if len(b) >= max_n:
            return False
        b.append(now)
        if len(_RATE_BUCKETS) > 5000:
            for k in [k for k, v in _RATE_BUCKETS.items() if not v]:
                _RATE_BUCKETS.pop(k, None)
        return True


def _safe_track_field(s, what="field"):
    """Artist/title/base validation: no path separators (traversal into
    yt-dlp -o templates / staging paths), no newlines (m3u injection),
    no NUL, bounded length. Raises ValueError (dispatch maps to 400)."""
    s = (s or "").strip()
    if not s:
        raise ValueError("missing %s" % what)
    if len(s) > MAX_TRACK_FIELD:
        raise ValueError("%s too long" % what)
    if ("/" in s or "\\" in s or "\x00" in s or "\n" in s or "\r" in s):
        raise ValueError("bad %s" % what)
    if s in (".", ".."):
        raise ValueError("bad %s" % what)
    return s


def _fetch_public_guards(url):
    """Hostname/scheme/userinfo + DNS->public-IP checks shared by the
    guarded fetchers. Returns the parsed parts. Raises ValueError."""
    import ipaddress
    import socket
    p = urllib.parse.urlparse(url)
    if p.scheme not in ("http", "https"):
        raise ValueError("bad scheme")
    if "@" in (p.netloc or "") or p.hostname is None:
        raise ValueError("bad host")
    try:
        infos = socket.getaddrinfo(
            p.hostname, p.port or (443 if p.scheme == "https" else 80),
            type=socket.SOCK_STREAM)
    except OSError:
        raise ValueError("dns failed")
    ips = {i[4][0] for i in infos}
    if not ips:
        raise ValueError("dns failed")
    for ip in ips:
        a = ipaddress.ip_address(ip)
        if (a.is_private or a.is_loopback or a.is_link_local
                or a.is_multicast or a.is_reserved or a.is_unspecified):
            raise ValueError("private host")
    return p


def _no_redirect_opener():
    import urllib.request
    real = urllib.request.HTTPRedirectHandler

    class _NR(real):
        def redirect_request(self, req, fp, code, msg, headers, newurl):
            return None

    return urllib.request.build_opener(_NR)


def _fetch_public(url, timeout=15, max_bytes=MAX_COVER_BYTES):
    """Fetch url with SSRF guards: http/https only, no userinfo, every
    resolved IP must be public (no LAN/loopback/link-local/reserved),
    redirects are NOT followed, body capped. Returns (body, ctype).
    Raises ValueError/URLError/OSError."""
    import urllib.request
    _fetch_public_guards(url)
    opener = _no_redirect_opener()
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with opener.open(req, timeout=timeout) as resp:
        if resp.status in (301, 302, 303, 307, 308):
            raise ValueError("redirects not followed")
        body = resp.read(max_bytes + 1)
        if len(body) > max_bytes:
            raise ValueError("too large")
        return body, resp.headers.get("Content-Type", "image/jpeg")


def _thumb_url(node):
    """Largest thumbnail URL from a ytmusicapi/Spotify/Data-API node.
    Accepts a thumbnails/sources list, a playlist dict, a shelf
    thumbnailRenderer dict, or a Data-API thumbnails dict
    ({high,medium,default}). Returns "" when absent. Fail-open."""
    try:
        if isinstance(node, dict):
            for k in ("high", "medium", "standard", "default"):
                sub = node.get(k) or {}
                if isinstance(sub, dict) and sub.get("url"):
                    return (sub.get("url") or "").strip()
            node = (node.get("thumbnails") or node.get("sources") or
                    (((node.get("thumbnailRenderer") or {})
                      .get("musicThumbnailRenderer") or {})
                     .get("thumbnail") or {}).get("thumbnails") or [])
        if isinstance(node, list) and node:
            last = node[-1] or {}
            return (last.get("url") or "").strip()
    except Exception:                                        # noqa: BLE001
        pass
    return ""


def _peek_redirect_location(url, timeout=15):
    """GET url without following redirects; return the Location header
    (or None). Same SSRF guards as _fetch_public, but never reads a body
    — used for spotify.link short links."""
    import urllib.request
    _fetch_public_guards(url)
    opener = _no_redirect_opener()
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with opener.open(req, timeout=timeout) as resp:
        if resp.status in (301, 302, 303, 307, 308):
            return resp.headers.get("Location")
        return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "NASMusic/1.0"

    # ------------------------------------------------------------------ state
    @property
    def state(self):
        return self.server.state

    # ------------------------------------------------------------- plumbing
    def log_message(self, fmt, *args):          # quieter access log
        # Session tokens ride in ?token= (players can't set headers) — never
        # let them land in the logs, or any log reader can hijack sessions.
        import re as _re
        try:
            msg = _re.sub(r"token=[^&\s]*", "token=REDACTED", fmt % args)
        except Exception:                                # noqa: BLE001
            msg = fmt % args
        logger.info("%s - %s", self.address_string(), msg)

    def _send(self, status, body=b"", ctype="application/json",
              extra_headers=None, head_only=False):
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods",
                         "GET,POST,DELETE,OPTIONS")
        if extra_headers:
            for k, v in extra_headers.items():
                self.send_header(k, v)
        self.end_headers()
        if not head_only and body:
            self.wfile.write(body)

    def _json(self, obj, status=200):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send(status, body, "application/json; charset=utf-8")

    def _error(self, status, msg):
        self._json({"error": str(msg)}, status=status)

    def _int_param(self, query, name, default, maxv=None):
        """Read an int query param with bounds: ('limit', 15, 60)."""
        raw = (query.get(name) or [""])[0].strip()
        if not raw:
            return default
        try:
            v = int(raw)
        except (TypeError, ValueError):
            return default
        if maxv is not None:
            v = min(v, maxv)
        return v

    def _exclude_param(self, query):
        """Read an 'exclude' (comma-separated norm(title) list) query param.

        Used by /api/radio + /api/recommend so a refill for the SAME seed
        returns FRESH rows instead of the same 15 — the endless-scroll fix.
        Titles are normalized with the same NFKD recipe the scorers apply."""
        import unicodedata, re
        raw = (query.get("exclude") or [""])[0].strip()
        if not raw:
            return None
        def _norm(s):
            s = unicodedata.normalize("NFKD", s or "")
            s = "".join(c for c in s if not unicodedata.combining(c)).lower()
            return re.sub(r"[^a-z0-9]+", "", s)
        out = set()
        for part in raw.split(','):
            part = part.strip()
            if not part:
                continue
            if " - " in part:
                part = part.split(" - ", 1)[1].strip()
            n = _norm(part)
            if n:
                out.add(n)
        return out or None

    def _body_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_JSON_BODY:
            raise ValueError("body too large")
        raw = self.rfile.read(length) if length else b""
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            return None

    def _route(self, method="GET"):
        self._cors(method)

    def _cors(self, method="GET"):
        origin = self.headers.get("Origin")
        self.send_header("Access-Control-Allow-Origin",
                         origin or "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods",
                         "GET,POST,DELETE,OPTIONS")
        self.send_header("Vary", "Origin")

    # -------------------------------------------------------------- routing
    def _dispatch(self):
        parsed = urllib.parse.urlparse(self.path)
        path = urllib.parse.unquote(parsed.path)
        query = urllib.parse.parse_qs(parsed.query)

        # Liveness probe for the compose healthcheck (2026-09-18): the
        # gated /staging/ bootstrap returns 401, which fails `curl -fs`.
        # This returns 200 with zero sensitive info — safe to leave open.
        if path == "/staging/healthz":
            return self._json({"ok": True})

        # Public landing (2026-09-18): funnel root always serves the join
        # page (only humans land here). /staging serves it to browsers
        # (Accept: text/html); API clients keep getting the gated JSON.
        if path == "/":
            return self._send(200, LANDING_HTML.encode("utf-8"),
                              "text/html; charset=utf-8",
                              extra_headers={"Cache-Control": "no-cache"})
        wants_html = "text/html" in (
            self.headers.get("Accept") or "").lower()
        if wants_html and path in ("/staging", "/staging/"):
            return self._send(200, LANDING_HTML.encode("utf-8"),
                              "text/html; charset=utf-8",
                              extra_headers={"Cache-Control": "no-cache"})

        # APK download for the landing page (public by design — the app
        # is useless without an account, and accounts are open anyway).
        if path == "/staging/app.apk":
            return self._serve_apk()
        if path == "/staging/features.html":
            return self._serve_features()

        # Liveness probe for container healthchecks (public by design:
        # it reveals nothing but "the server answers"). The old
        # `curl -fs .../staging/` probe fails with 401 since /staging
        # was gated (2026-09-18) — point the compose healthcheck here.
        if path == "/staging/health":
            return self._json({"ok": True})

        # strip /staging prefix ('/staging' itself is gated like api:
        # it used to leak music_root/staging_dir pre-auth — 2026-09-18)
        if path == "/staging" or path == "/staging/":
            rel = ""
            parts = [""]
        elif not path.startswith("/staging/"):
            self.send_error(404, "not found")
            return
        else:
            rel = path[len("/staging/"):]
            parts = rel.split("/")

        # ---- auth gate (multi-user): everything except register/login
        # needs a valid session token — X-NASMusic-Token header or ?token=
        # query (players/<img> tags can't set headers). "Lock everything":
        # api calls and media/file streams alike. 401, never a redirect.
        self._auth_user = None
        self._auth_token = (
            self.headers.get("X-NASMusic-Token") or "").strip()
        if not self._auth_token and parts[0] in ("api", "file", "pl", "u"):
            toks = query.get("token") or [""]
            self._auth_token = toks[0].strip()
        if not self._auth_token and rel == "":
            toks = query.get("token") or [""]
            self._auth_token = toks[0].strip()
        is_open = (parts[0] == "api" and len(parts) > 1
                   and parts[1] in ("register", "login"))
        if not is_open and (parts[0] in ("api", "file", "pl", "u")
                            or rel == ""):
            authed = None
            if self._auth_token:
                try:
                    authed = self.state.users.whoami(self._auth_token)
                except Exception:
                    authed = None
            if not authed:
                return self._error(401, "auth required")
            self._auth_user = authed
            # Last-seen client av per user (owner diagnosis of "phone taps
            # hang": proves the tap reached the server + when). Keyed by
            # USERNAME only — tokens are never logged or stored here
            # (log_message already redacts ?token=). Best-effort.
            try:
                import time as _t
                _av = (query.get("av") or [""])[0].strip()[:32]
                self.state.db.misc_put(
                    "lastav:" + str(authed),
                    {"seen": int(_t.time()), "av": _av})
            except Exception:                            # noqa: BLE001
                pass

        try:
            if rel == "":
                return self._index()
            if parts[0] == "api":
                self._route_api(parts[1:], query)
            elif parts[0] == "file":
                self._serve_file("/".join(parts[1:]), from_playlist=False)
            elif parts[0] == "pl":
                self._serve_file("/".join(parts[1:]), from_playlist=True)
            elif parts[0] == "u":
                self._serve_user_file("/".join(parts[1:]))
            elif parts[0] == "favicon.ico":
                self.send_error(404)
            else:
                self.send_error(404, "not found")
        except BrokenPipeError:
            pass
        except ValueError as e:
            self._error(400, e)
        except OSError as e:
            err = getattr(e, "errno", None)
            if err == 2:
                self._error(404, "no such file")
            else:
                logger.exception("dispatch error")
                self._error(500, e)
        except Exception as e:                        # noqa: BLE001
            logger.exception("unhandled error")
            try:
                self._error(500, e)
            except Exception:                         # noqa: BLE001
                pass

    def _route_api(self, parts, query):
        seg = parts[0] if parts else ""

        if self.command == "OPTIONS":
            self.send_response(204)
            self._cors()
            self.end_headers()
            return

        # ---- /api/search
        if seg == "search" and parts[1:] == []:
            if self.command == "GET":
                q = (query.get("q") or [""])[0].strip()
                if not q:
                    return self._error(400, "missing q")
                return self._json(self._search(q))

        # ---- /api/suggest (live NAS-only, fast)
        if seg == "suggest" and parts[1:] == []:
            if self.command == "GET":
                q = (query.get("q") or [""])[0].strip()
                return self._json(self._suggest(q))

        # ---- /api/radio (related internet songs for autoplay, after the
        # current track — Spotify/YouTube-Music "up next" behavior)
        if seg == "radio" and parts[1:] == []:
            if self.command == "GET":
                artist = (query.get("artist") or [""])[0].strip()
                title = (query.get("title") or [""])[0].strip()
                if not title:
                    return self._error(400, "missing title")
                limit = self._int_param(query, "limit", 15, 60)
                exclude = self._exclude_param(query)
                rows = self.state.scorer.deezer_radio_tracks(
                    artist, title, limit=limit, exclude=exclude)
                if rows is None:
                    rows = []
                return self._json({"results": self._annotate_nas(rows)})

        # ---- /api/recommend (Spotify-powered multi-source recommendations:
        # genre, similar artists, mood, cross-artist discovery)
        if seg == "recommend" and parts[1:] == []:
            if self.command == "GET":
                artist = (query.get("artist") or [""])[0].strip()
                title = (query.get("title") or [""])[0].strip()
                if not title:
                    return self._error(400, "missing title")
                limit = self._int_param(query, "limit", 15, 60)
                exclude = self._exclude_param(query)
                rows = self.state.scorer.deezer_recommendations(
                    artist, title, limit=limit, exclude=exclude)
                if rows is None:
                    rows = []
                return self._json({"results": self._annotate_nas(rows)})

        # ---- /api/nas-index (full flat NAS library for the app-side fuzzy
        # "is this queued song already on the NAS?" matcher). Same rows as
        # the suggest index (music + staging + playlists), cheap JSON.
        if seg == "nas-index" and parts[1:] == []:
            if self.command == "GET":
                payload = []
                for base, _full, url, meta in self._suggest_index():
                    if not self._lib_visible(base, self._me()):
                        continue
                    payload.append({
                        "base_name": base,
                        "url": url,
                        "folder": "",
                        "artist": base.split(" - ", 1)[0].strip()
                        if " - " in base else "",
                        "album": (meta or {}).get("album"),
                        "album_image": (meta or {}).get("album_image"),
                    })
                return self._json({"tracks": payload})

        # ---- /api/artist-photo (just the photo URL for an artist name)
        if seg == "artist-photo" and parts[1:] == []:
            if self.command == "GET":
                name = (query.get("name") or [""])[0].strip()
                if not name:
                    return self._error(400, "missing name")
                return self._json({"photo": self._artist_photo(name)})

        # ---- /api/diagnostics (artist-photo debugging: creds test + what
        # Spotify/Deezer return for a name — exportable from the app)
        if seg == "diagnostics" and parts[1:] == []:
            if self.command == "GET":
                name = (query.get("name") or [""])[0].strip()
                return self._json(self._diagnostics(name or "Eminem"))

        # ---- /api/resolvename (find+resolve by artist & title)
        if seg == "resolvename" and parts[1:] == []:
            if self.command == "GET":
                artist = (query.get("artist") or [""])[0].strip()
                title = (query.get("title") or [""])[0].strip()
                return self._resolvename(artist, title)

        # ---- /api/open-url (deep link: Spotify / YT-Music link -> the song's
        # playable identity, so the app can open share links in-app)
        if seg == "open-url" and parts[1:] == []:
            if self.command == "GET":
                u = (query.get("url") or [""])[0].strip()
                if not u:
                    return self._error(400, "missing url")
                return self._json(self._open_url(u))

        # ---- /api/spotify-link (artist+title -> a real Spotify TRACK url so a
        # SHARED Spotify link autoplays instead of landing on a search page)
        if seg == "spotify-link" and parts[1:] == []:
            if self.command == "GET":
                artist = (query.get("artist") or [""])[0].strip()
                title = (query.get("title") or [""])[0].strip()
                if not title:
                    return self._error(400, "missing title")
                return self._json(self._spotify_link(artist, title))

        # ---- /api/spotify-playlist-order (Spotify playlist link -> its
        # track sequence via the public embed page, so the app can reorder
        # a NAS playlist to match Spotify. No auth, no API key.)
        # NOTE: handlers _json/_error themselves — never wrap them in
        # self._json() (that sends a second response on one connection).
        if seg == "spotify-playlist-order" and parts[1:] == []:
            if self.command == "GET":
                u = (query.get("url") or [""])[0].strip()
                if not u:
                    return self._error(400, "missing url")
                full = (query.get("full") or [""])[0].strip() == "1"
                res = self._spotify_playlist_order(u, full)
                return self._json(res) if res is not None else None

        # ---- /api/ytmusic-playlist (YouTube Music playlist link ->
        # [{artist,title,duration_s}] via ytmusicapi, public playlists.
        # Private ones need a logged-in browser session — clear 502.)
        if seg == "ytmusic-playlist" and parts[1:] == []:
            if self.command == "GET":
                u = (query.get("url") or [""])[0].strip()
                if not u:
                    return self._error(400, "missing url")
                res = self._ytmusic_playlist_order(u)
                return self._json(res) if res is not None else None

        # ---- YouTube Music login (TV device flow) + private library.
        # No user secret can do this (ported from the plan session):
        # browser cookies are hijack-grade and official OAuth needs
        # verification + still misses liked songs. The owner creates ONE
        # Google Cloud OAuth client (TVs and Limited Input); each user
        # approves at google.com/device; tokens live per-user (0600).
        if seg == "ytm-auth-start" and parts[1:] == []:
            if self.command == "POST":
                res = self._ytm_auth_start()
                return self._json(res) if res is not None else None
        if seg == "ytm-auth-poll" and parts[1:] == []:
            if self.command == "GET":
                res = self._ytm_auth_poll()
                return self._json(res) if res is not None else None
        if seg == "ytm-auth-status" and parts[1:] == []:
            if self.command == "GET":
                import os as _os
                op = self._ytm_token_path()
                bp = self._ytm_browser_path()
                res = {"connected": bool(
                    (op and _os.path.exists(op)) or
                    (bp and _os.path.exists(bp)))}
                return self._json(res)
        if seg == "ytm-auth" and parts[1:] == []:
            if self.command == "DELETE":
                self._ytm_drop_token()
                return self._json({"cleared": True})
        if seg == "ytm-cookie" and parts[1:] == []:
            if self.command == "POST":
                res = self._ytm_cookie()
                return self._json(res) if res is not None else None
        if seg == "ytm-library" and parts[1:] == []:
            if self.command == "GET":
                res = self._ytm_library()
                return self._json(res) if res is not None else None
        if seg == "ytm-library-playlist" and parts[1:] == []:
            if self.command == "GET":
                pid = (query.get("id") or [""])[0].strip()
                if not pid:
                    return self._error(400, "missing id")
                res = self._ytm_library_playlist(pid)
                return self._json(res) if res is not None else None
        if seg == "ytm-channel" and parts[1:] == []:
            if self.command == "GET":
                q = (query.get("q") or [""])[0].strip()
                if not q:
                    return self._error(400, "missing q")
                res = self._ytm_channel(q)
                return self._json(res) if res is not None else None

        # ---- /api/import (bulk playlist import: create the NAS playlist,
        # download every track in order in ONE background worker).
        if seg == "import" and parts[1:] == []:
            if self.command == "POST":
                res = self._import_start(query)
                return self._json(res) if res is not None else None
            if self.command == "GET":
                return self._json(self._import_snapshot(query))

        # ---- /api/playlist-source (remembered import link for a
        # playlist, so the app can verify/retry without asking again)
        if seg == "playlist-source" and parts[1:] == []:
            if self.command == "GET":
                name = (query.get("name") or [""])[0].strip()
                if not name:
                    return self._error(400, "missing name")
                src = self.state.db.misc_get(
                    self._psrc_key(self._me() or "", name), 0) or ""
                return self._json({"name": name, "source": src})

        # ---- /api/register (open self-registration, 2026-09-18+):
        # anyone with the app can create an account (friends join
        # freely). The public landing page offers NO register form
        # (URL stays download-only) — registration lives in the app.
        # Abuse is covered by the rate limits below. Buckets are per-IP
        # AND per-username: funnel/tailnet collapses many users onto one
        # source IP (127.0.0.1 via funnel), so an IP-only bucket lets one
        # attacker lock everybody else out.
        if seg == "register" and parts[1:] == []:
            if self.command == "POST":
                ip = (self.client_address or ["?"])[0]
                if not _rate_allow("register:" + ip, 10, 3600):
                    return self._error(429, "too many registrations")
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                want = self.state.config.invite_code or ""
                if want:
                    import hmac as _hmac
                    got = str(body.get("invite") or "")
                    if not got or not _hmac.compare_digest(got, want):
                        return self._error(403, "invalid invite code")
                try:
                    name = str(body.get("username") or "").strip().lower()
                except Exception:                            # noqa: BLE001
                    name = ""
                if name and not _rate_allow("register-name:" + name, 5, 3600):
                    return self._error(429, "too many registrations")
                try:
                    out = self.state.users.register(
                        body.get("username"), body.get("password"),
                        body.get("verify"),
                        device_id=str(body.get("device_id") or ""),
                        device_name=str(body.get("device_name") or ""))
                except UserError as e:
                    self._log_user_error("login", f"register: {e.msg}",
                                         user=name)
                    return self._error(e.status, e.msg)
                self._maybe_migrate_user(out["username"])
                return self._json(out)

        # ---- /api/login (username+password -> session token for this device;
        # the app keeps the token until logout, so credentials are entered
        # once per device)
        if seg == "login" and parts[1:] == []:
            if self.command == "POST":
                ip = (self.client_address or ["?"])[0]
                if not _rate_allow("login-ip:" + ip, 60, 600):
                    return self._error(429, "too many attempts, try later")
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                try:
                    name = str(body.get("username") or "").strip().lower()
                except Exception:                            # noqa: BLE001
                    name = ""
                if name and not _rate_allow(
                        "login-name:" + name, 15, 600):
                    return self._error(429, "too many attempts, try later")
                try:
                    out = self.state.users.login(
                        body.get("username"), body.get("password"),
                        device_id=str(body.get("device_id") or ""),
                        device_name=str(body.get("device_name") or ""))
                except UserError as e:
                    self._log_user_error("login", f"login: {e.msg}",
                                         user=name)
                    return self._error(e.status, e.msg)
                self._maybe_migrate_user(out["username"])
                return self._json(out)

        # ---- /api/logout (revoke this session token)
        if seg == "logout" and parts[1:] == []:
            if self.command == "POST":
                ok = self.state.users.logout(self._auth_token)
                return self._json({"ok": bool(ok)})

        # ---- /api/announcements (published events: Wrapped season flag +
        # notification cards. Driven by nasmusic/announcements.json on the
        # /app mount — flip wrapped_season when Spotify drops Wrapped, add
        # items to ping every device once. No secrets in this file.)
        # Owner-only POST/DELETE so the owner can broadcast from the app.
        if seg == "announcements" and parts[1:] == []:
            if self.command == "GET":
                return self._json(self._announcements())
            if self.command == "POST":
                return self._json(self._announcements_publish())
            if self.command == "DELETE":
                return self._json(self._announcements_clear())

        # ---- /api/client-log (phone reports a client-side failure so it
        # shows up in NAS logs/events instead of vanishing on the device.
        # Any logged-in user; rate-limited; text capped.)
        if seg == "client-log" and parts[1:] == []:
            if self.command == "POST":
                return self._json(self._client_log())
            return self._error(405, "method not allowed")

        # ---- /api/password (logged-in user changes their own password;
        # needs the current one. Other sessions are revoked, this one
        # survives. Forgot-password = owner resets via SSH CLI to a temp
        # password, user logs in and changes it here.)
        if seg == "password" and parts[1:] == []:
            if self.command == "POST":
                if not _rate_allow(
                        "password:" + (self._auth_user or "?"), 10, 3600):
                    return self._error(429, "too many attempts, try later")
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                try:
                    out = self.state.users.change_password(
                        self._auth_user,
                        body.get("current_password"),
                        body.get("new_password"),
                        keep_token=self._auth_token)
                except UserError as e:
                    self._log_user_error("login", f"password: {e.msg}")
                    return self._error(e.status, e.msg)
                return self._json(out)

        # ---- /api/me (who owns this session token)
        if seg == "me" and parts[1:] == []:
            if self.command == "GET":
                return self._json({"username": self._auth_user})

        # ---- /api/user-errors (per-user error rows, filterable by
        # user/section/text; owner sees all, others see only their own)
        if seg == "user-errors" and parts[1:] == []:
            if self.command == "GET":
                me = self._me()
                if not me:
                    return self._error(401, "auth required")
                user = (query.get("user") or [None])[0]
                if me != self.LEGACY_USER:
                    user = me
                section = (query.get("section") or [None])[0]
                text = (query.get("q") or [None])[0]
                unseen = ((query.get("unseen") or [""])[0] or "").strip() in (
                    "1", "true", "yes")
                try:
                    limit = int((query.get("limit") or ["200"])[0])
                except Exception:                        # noqa: BLE001
                    limit = 200
                rows = self.state.db.list_user_errors(
                    username=user, section=section, q=text, limit=limit,
                    unseen=unseen)
                if me == self.LEGACY_USER:
                    seen = self.state.db.list_user_errors(limit=500)
                    users = sorted(
                        {r["username"] for r in seen} |
                        set(self.state.users.usernames()))
                else:
                    users = [me]
                return self._json({"errors": rows, "users": users})

        # ---- POST /api/user-errors/seen (flag rows seen; owner may mark
        # any user, others only their own). Body: {user?, ids?}.
        if seg == "user-errors" and parts[1:] == ["seen"]:
            if self.command == "POST":
                me = self._me()
                if not me:
                    return self._error(401, "auth required")
                body = self._body_json() or {}
                user = (body.get("user") or "").strip() or None
                if me != self.LEGACY_USER:
                    user = me
                raw_ids = body.get("ids") or []
                try:
                    ids = [int(i) for i in raw_ids]
                except Exception:                        # noqa: BLE001
                    return self._error(400, "bad ids")
                ok = self.state.db.mark_user_errors_seen(user, ids or None)
                return self._json({"ok": ok})

        # ---- /api/flags (feature flags in DB; default OFF; rollback = off).
        # GET: anyone authed reads. POST {per_user_libs: bool}: owner only.
        if seg == "flags" and parts[1:] == []:
            if self.command == "GET":
                return self._json({
                    "per_user_libs": self._per_user_libs()})
            if self.command == "POST":
                if self._me() != self.LEGACY_USER:
                    return self._error(403, "owner only")
                body = self._body_json() or {}
                if "per_user_libs" not in body:
                    return self._error(400, "missing per_user_libs")
                self.state.db.flag_put(
                    "per_user_libs", bool(body.get("per_user_libs")))
                type(self)._owner_map_cache = (0.0, {})
                return self._json({
                    "per_user_libs": self._per_user_libs()})

        # ---- /api/innas (does this artist+title exist on the NAS? — used by
        # the queue to prefer the NAS copy of an internet song, bug O)
        if seg == "innas" and parts[1:] == []:
            if self.command == "GET":
                artist = (query.get("artist") or [""])[0].strip()
                title = (query.get("title") or [""])[0].strip()
                if not title:
                    return self._error(400, "missing title")
                return self._json(self._innas(artist, title))

        # ---- /api/stage
        if seg == "stage" and parts[1:] == []:
            if self.command == "POST":
                if not _rate_allow("stage:" + (self._auth_user or "?"),
                                   30, 3600):
                    self._log_user_error("download_failed", "stage: rate limited")
                    return self._error(429, "too many staged songs")
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                raw_artist = (body.get("artist") or "").strip()
                artist = (_safe_track_field(raw_artist, "artist")
                          if raw_artist else "")
                title = _safe_track_field(body.get("title"), "title")
                try:
                    did, extra = self.state.pipeline.start_stage(
                        artist, title, force=bool(body.get("force")),
                        owner=self._auth_user or "")
                except ValueError as e:
                    self._log_user_error("download_failed", f"stage: {e}")
                    return self._error(400, str(e))
                return self._json({"id": did, **extra})

        # ---- /api/jobs
        if seg == "jobs" and parts[1:] == []:
            if self.command == "GET":
                viewer = None
                if self._auth_user != self.LEGACY_USER:
                    viewer = self._auth_user
                return self._json(
                    {"jobs": self.state.pipeline.all_jobs(owner=viewer)})

        # ---- /api/downloads
        if seg == "downloads":
            if parts[1:] == []:
                if self.command == "GET":
                    status = (query.get("status") or [None])[0]
                    # Personal staging views: the owner sees everything,
                    # everyone else sees ONLY their own rows (strict).
                    viewer = None
                    if self._auth_user != self.LEGACY_USER:
                        viewer = self._auth_user
                    rows = self.state.db.list_downloads(status, viewer)
                    for r in rows:
                        r.pop("url", None)
                    return self._json({"downloads": rows})
            elif len(parts) == 2:
                did = parts[1]
                if self.command == "GET":
                    row = self.state.db.get_download(did)
                    if not row:
                        return self._error(404, "unknown download")
                    if (self._auth_user != self.LEGACY_USER
                            and (row.get("owner") or "") != self._auth_user):
                        return self._error(403, "not your download")
                    cands = self.state.db.candidates_for(did)
                    row.pop("url", None)
                    current = row.get("video_id")
                    for c in cands:
                        c["is_current"] = c["video_id"] == current
                    return self._json({"download": row,
                                       "candidates": cands})
                if self.command == "DELETE":
                    # Owner-only (2026-09-18, public URL): deletes shared
                    # files and scrubs every playlist referencing them.
                    if self._auth_user != self.LEGACY_USER:
                        return self._error(403, "owner only")
                    return self._delete_download(did)

        # ---- /api/redownload
        # Owner-only (2026-09-18, public URL): burns disk + bandwidth on
        # arbitrary YouTube ids; the check-songs fix-up flow is the
        # owner's maintenance tool.
        if seg == "redownload" and parts[1:] == []:
            if self.command == "POST":
                if self._auth_user != self.LEGACY_USER:
                    return self._error(403, "owner only")
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                did = body.get("download_id")
                vid = body.get("video_id")
                if not did or not vid:
                    return self._error(400, "need download_id + video_id")
                if not VID_RE.fullmatch(str(vid)):
                    return self._error(400, "bad video_id")
                _id, extra = self.state.pipeline.start_redownload(did, vid)
                return self._json(extra or {"ok": True, "id": did})

        # ---- /api/keep
        if seg == "keep" and parts[1:] == []:
            if self.command == "POST":
                return self._keep()

        # ---- POST /api/delete-from-every-playlist (owner-only):
        # drop {base} from EVERY playlist incl. per-user Liked scope.
        if seg == "delete-from-every-playlist" and parts[1:] == []:
            if self.command == "POST":
                if self._auth_user != self.LEGACY_USER:
                    return self._error(403, "owner only")
                return self._delete_from_every_playlist()

        # ---- DELETE /api/file?base= (owner-only): move file to trash
        # + sweep every playlist (per-user liked scope included).
        if seg == "file" and parts[1:] == []:
            if self.command == "DELETE":
                if self._auth_user != self.LEGACY_USER:
                    return self._error(403, "owner only")
                return self._delete_file_to_trash(query)

        # ---- /api/resolve
        if seg == "resolve" and len(parts) == 2:
            if self.command == "GET":
                if not VID_RE.fullmatch(parts[1]):
                    return self._error(400, "bad vid")
                if (query.get("debug") or [""])[0] == "1":
                    return self._resolve_debug(parts[1])
                if (query.get("speedtest") or [""])[0] == "1":
                    return self._speedtest(parts[1])
                return self._resolve(parts[1])

        # ---- /api/stream (proxy: resolve + relay so Android can play)
        if seg == "stream" and parts[1:] == []:
            if self.command == "GET":
                vid = (query.get("vid") or [""])[0]
                if not re.fullmatch(r"[A-Za-z0-9_\-]{5,80}", vid):
                    return self._error(400, "bad vid")
                return self._stream_remote(vid)

# ---- /api/lyrics
        if seg == "lyrics" and parts[1:] == []:
            if self.command == "GET":
                base = (query.get("base") or [""])[0].strip()
                artist = (query.get("artist") or [""])[0].strip() or None
                title = (query.get("title") or [""])[0].strip() or None
                return self._lyrics(base, artist=artist, title=title)

        # ---- /api/metainfo
        if seg == "metainfo" and parts[1:] == []:
            if self.command == "GET":
                base = (query.get("base") or [""])[0].strip()
                return self._metainfo(base)

        # ---- /api/artist/:name
        if seg == "artist" and len(parts) == 2:
            if self.command == "GET":
                return self._artist(parts[1])

        # ---- /api/album
        if seg == "album" and parts[1:] == []:
            if self.command == "GET":
                artist = (query.get("artist") or [""])[0].strip()
                album = (query.get("album") or [""])[0].strip()
                album_id = (query.get("album_id") or [""])[0].strip()
                return self._album(artist, album,
                                   album_id=int(album_id) if album_id.isdigit() else None)

        # ---- /api/liked
        if seg == "liked" and parts[1:] == []:
            if self.command == "GET":
                # Batch mode: ONE call per playlist open (newline-separated;
                # base names may contain commas). Single-base ?base= unchanged.
                bases = (query.get("bases") or [""])[0]
                if bases.strip():
                    want = [b.strip() for b in bases.split("\n")
                            if b.strip()][:500]
                    names = self._liked_names(self._me())
                    return self._json({"liked": {
                        b: (b in names or (b + ".mp3") in names)
                        for b in want}})
                base = (query.get("base") or [""])[0].strip()
                return self._liked(base, self._me())

        # ---- /api/checksongs (verify downloaded tracks vs studio originals)
        if seg == "checksongs" and parts[1:] == []:
            if self.command == "GET":
                scope = (query.get("scope") or [""])[0].strip()
                poll = (query.get("poll") or [""])[0].strip() == "1"
                return self._json(self._checksongs(scope, poll=poll))

        # ---- /api/song-versions (version picker for a NAS file)
        if seg == "song-versions" and parts[1:] == []:
            if self.command == "GET":
                f = (query.get("f") or [""])[0].strip()
                if not f:
                    return self._error(400, "missing f")
                return self._json(self._song_versions(f))

        # ---- /api/check-replace (replace a NAS copy with another version)
        # Owner-only (2026-09-18, public URL): it overwrites SHARED
        # library bytes — a stranger must not be able to poison songs.
        if seg == "check-replace" and parts[1:] == []:
            if self.command == "POST":
                if self._auth_user != self.LEGACY_USER:
                    return self._error(403, "owner only")
                return self._check_replace()

        # ---- /api/identify (fingerprint a NAS file -> the real song it holds)
        if seg == "identify" and parts[1:] == []:
            if self.command == "GET":
                f = (query.get("f") or [""])[0].strip()
                if not f:
                    return self._error(400, "missing f")
                full = (self._local_files_map() or {}).get(f)
                if not full:
                    return self._error(404, "no such file")
                return self._json(self._identify_song(f, full))

        # ---- /api/check-lyrics (verify NAS songs have matching lyrics)
        if seg == "check-lyrics" and parts[1:] == []:
            if self.command == "GET":
                scope = (query.get("scope") or [""])[0].strip()
                poll = (query.get("poll") or [""])[0].strip() == "1"
                return self._json(self._check_lyrics(scope, poll=poll))

        # ---- /api/cover
        if seg == "cover" and parts[1:] == []:
            if self.command == "GET":
                f = (query.get("f") or [""])[0]
                if f:
                    return self._cover(f)
                vid = (query.get("vid") or [""])[0]
                if vid:
                    if not VID_RE.fullmatch(vid):
                        return self._error(400, "bad vid")
                    return self._cover_vid(vid)
                pl = (query.get("pl") or [""])[0]
                if pl:
                    return self._cover_playlist(pl)
                u = (query.get("u") or [""])[0]
                if u:
                    # Generic proxied image (Wrapped artist photos): same
                    # SSRF guard + cache as every other relayed byte.
                    if len(u) > 2000:
                        return self._error(400, "bad url")
                    return self._relay_image(u)
                return self._error(400, "need f, vid, pl or u")

        # ---- /api/tracks
        if seg == "tracks" and parts[1:] == []:
            if self.command == "GET":
                return self._tracks()

        # ---- /api/playlists
        if seg == "playlists":
            return self._playlists(parts[1:])

        self.send_error(404, "no such endpoint")

    # ---------------------------------------------------------- search
    _search_cache_ttl = 12 * 3600  # discovery/resolution results, per-query
    # Album-count memo: `_preview_album_count` walks the merged library +
    # discography (costs ~0.1-0.4s per artist), so it must never run on the
    # request thread once per artist per search. Computed in background,
    # memoized (10 min), re-tried quickly when not yet available (15s).
    _album_count_mem_lock = threading.Lock()
    _album_count_mem = {}          # norm(name) -> (ts, count)
    _album_count_inflight = {}     # norm(name) -> True (single-flight)
    _album_count_ttl = 10 * 60
    _album_count_retry = 15        # seconds before retrying a not-ready count

    def _search(self, q):
        """Search returns LOCAL matches instantly from the cached index and,
        for the ONLINE portion, serves a per-query discovery cache. On a cold
        query the response BLOCKS only briefly (~2s) on a background thread;
        the rows are written to the search cache the moment they're picked and
        their direct URLs prewarm in that same worker, so the first response
        usually contains the online hits and they are ready to play (the app
        polls `discovery_pending` for stragglers). Concurrent
        re-searches of the same query join the same running build. Artists are
        non-blocking: a cold search returns artists_pending=true and a
        background job fetches the Deezer matches + warms their discography,
        so tapping an artist is instant and their studio album count appears
        once hydration lands."""
        state = self.state
        # Kick the Deezer-artists fetch EARLY: its ~1-2s (Deezer + hydration)
        # then runs DURING the blocking discovery build below, so the Artists
        # section lands in the SAME first response instead of lagging the whole
        # discovery by another couple of seconds. Single-flight with
        # `_search_artists` (same _sa_inflight map), so no double-fetch.
        akey = "sa:" + self._norm(q)
        if state.db.misc_get(akey, 6 * 3600) is None:
            with type(self)._sa_lock:
                inflight = type(self)._sa_inflight.get(akey)
                if inflight is None or (time.time() - inflight) >= 120:
                    type(self)._sa_inflight[akey] = time.time()
                    threading.Thread(target=self._artists_fetch_async,
                                     args=(q, akey),
                                     daemon=True).start()
        if " - " in q:
            artist, title = (p.strip() for p in q.split(" - ", 1))
        else:
            artist, title = None, None

        qkey = self._norm(q)
        # sr4: album now attached per row (Deezer, like covers) — older
        # album-less sr3: rows are NOT migrated, they rebuild once.
        cached = state.db.misc_get("sr4:" + qkey, self._search_cache_ttl)
        was_cold = cached is None
        pending = cached is None
        if cached:
            art = cached.get("artist") or artist
            ttl = cached.get("title") or title
        else:
            art, ttl = artist, title
        expected_dur = (cached or {}).get("expected_dur") or None
        provider = (cached or {}).get("provider") or None
        if ttl is None:
            ttl = q

        local_idx = self._local_files_map()
        local_core = {self._norm_core(b) for b in local_idx}

        token_norms = [self._norm(w) for w in q.split()
                       if len(self._norm(w)) >= 2]
        local = []
        qnorm = self._norm(q)
        qcore = self._norm_core(q)
        ar_norm = self._norm(art) if art else ""
        scored_local = []
        for base, full in local_idx.items():
            if not self._lib_visible(base, self._me()):
                continue
            hay = self._norm(base)
            hits = sum(1 for t in token_norms if t in hay)
            if not hits:
                # Dotted-abbrev bypass: "msn" vs "M.S.N." — norm_core
                # substring on either side counts as a hit before the
                # token floor, so the Akritud row surfaces with file url.
                _bc = self._norm_core(base)
                if not (qcore and (_bc and (qcore in _bc or _bc in qcore))):
                    continue
                hits = 1
            score = hits * 15 + 500
            if qnorm and qnorm in hay:
                score += 80
            title_part = base.split(" - ", 1)[1] if " - " in base else base
            tlow = self._norm(title_part)
            for t in token_norms:
                if t in tlow:
                    score += 15
            if ar_norm and ar_norm in hay:
                score += 25
            if qnorm and qnorm in tlow:
                score += 40
            scored_local.append((score, base, full))
        scored_local.sort(key=lambda x: -x[0])
        seen_bases = set()
        for _score, base, full in scored_local[:5]:
            if base in seen_bases:
                continue
            seen_bases.add(base)
            meta = state.db.song_meta_get(base)
            url = self._entry_url(full)
            if not url:
                continue
            local.append({
                "kind": "local", "base_name": base,
                "folder": base.split(" - ", 1)[0] if " - " in base else "",
                "url": url,
                "provider": "NAS",
                "album": (meta or {}).get("album"),
                "album_image": (meta or {}).get("album_image"),
            })

        if cache_hit := cached:
            virtual = cache_hit.get("discovery") or []
        else:
            virtual = []
            # Cold query: give the background discovery build a SHORT bounded
            # window to land (single-flight; a concurrent re-search of the same
            # query joins the SAME running build). The worker writes the cache
            # as soon as rows are picked (~1s); anything not ready inside this
            # window returns discovery_pending=true and the app polls it in.
            # ONE pass: songs+artists land in the SAME response (no 0.6s
            # cold + 1.2s poll gap). Discovery gets up to 1.2s; artists
            # get the remaining budget. Caches sr4:/rz: unchanged.
            _t0 = time.time()
            ev = self._discovery_sync(q, qkey)
            ev.wait(timeout=1.2)
            _refetch = state.db.misc_get("sr4:" + qkey,
                                         self._search_cache_ttl)
            if _refetch:
                cached = _refetch
                art = _refetch.get("artist") or artist
                ttl = _refetch.get("title") or title
                expected_dur = _refetch.get("expected_dur") or None
                provider = _refetch.get("provider") or None
                if ttl is None:
                    ttl = q
            pending = cached is None
            virtual = (cached or {}).get("discovery") or []

        # Whatever warm rows we serve, re-warm their direct URLs (the just-built
        # cold path already prewarms in its own worker thread, so only refresh
        # rows that were served from an existing cache whose resolves may have
        # expired). Keeps a warm first tap a cache hit without adding latency
        # to the response itself.
        if virtual and not was_cold:
            self._prewarm_resolve(
                [c.get("video_id") for c in virtual if c.get("video_id")],
                wait_sec=0)

        artists, artists_pending = self._search_artists(q)
        if artists_pending and was_cold:
            # Same-pass artist wait: join the already-running sa: fetch
            # instead of forcing the app's ~1.2s poll to catch it.
            _budget = max(0.0, 1.2 - (time.time() - _t0))
            _end = time.time() + min(0.6, _budget)
            while time.time() < _end:
                time.sleep(0.1)
                artists, artists_pending = self._search_artists(q)
                if not artists_pending and artists:
                    break
        if " - " in q:
            artists = artists[:2]
        return {"query": q,
                "resolved": {"artist": art, "title": ttl,
                             "provider": provider, "expected_dur": expected_dur},
                "local": local,
                "discovery": virtual,
                "discovery_pending": pending,
                "artists": artists,
                "artists_pending": artists_pending}

    def _discover_async(self, q, qkey):
        """Background: run the online provider lookup + candidate pick, cache
        it, and pre-warm the direct-stream URLs for ALL discovery rows BEFORE
        the cache is written — so by the time /staging/api/search actually
        hands back rows, every row is already playable and a tap is a cache
        hit (~0ms) instead of a 3-7s live yt-dlp inside the tap handler.

        On a structured "artist - title" query the Spotify/Deezer metadata
        lookup (used only to re-rank by expected duration) runs in PARALLEL
        with the YouTube candidate search instead of serializing ~4s of
        network calls on the critical cold path."""
        try:
            state = self.state
            if " - " in q:
                artist, title = (p.strip() for p in q.split(" - ", 1))
                structured = True
            else:
                artist, title = None, None
                structured = False
            expected_dur = None
            provider = "YouTube"

            c_artist, c_title = artist, title

            def _meta():
                nonlocal expected_dur, provider, c_artist, c_title
                try:
                    if artist is None:
                        parts = q.split(" - ", 1)
                        part1 = parts[1].strip() if len(parts) == 2 else ""
                        spot = state.scorer.spotify_search(
                            parts[0].strip(), part1) \
                            if " - " in q and q.count(" - ") == 1 and part1 \
                            else None
                        if spot:
                            c_artist = spot["artists"][0] if spot["artists"] \
                                else None
                            c_title = spot["name"]
                            expected_dur = spot["duration_s"]
                            provider = "Spotify"
                            return
                        meta = state.scorer.deezer_search(q)
                        if meta:
                            c_artist = meta["artist"]
                            c_title = meta["title"]
                            expected_dur = meta.get("duration_s")
                            provider = "Deezer"
                    elif artist:
                        spot = state.scorer.spotify_search(artist, title)
                        if spot:
                            expected_dur = spot["duration_s"]
                            provider = "Spotify"
                        else:
                            meta = state.scorer.deezer_search(
                                f"{artist} {title}".strip())
                            if meta:
                                expected_dur = meta.get("duration_s") \
                                    or expected_dur
                                provider = "Deezer"
                except Exception:                    # noqa: BLE001
                    logger.info("provider lookup failed for %r", q)

            meta_thread = None
            if structured:
                meta_thread = threading.Thread(target=_meta)
                meta_thread.start()

            local_idx = self._local_files_map()
            local_core = {self._norm_core(b) for b in local_idx}

            cands = state.scorer.search(
                "" if not structured else (c_artist or ""),
                q if not structured else (c_title or q),
                quoted=structured)
            if meta_thread is not None:
                meta_thread.join(timeout=6)
            if c_title is None:
                c_title = q

            artists = [a.strip() for a in
                       (c_artist or c_title or q).split(",")]
            scored, _cons = state.scorer.pick(
                cands, artists, q if not structured else (c_title or q))
            if scored and expected_dur and structured:
                scored.sort(key=lambda c: (
                    abs(c["duration_s"] - expected_dur) > 5
                    if c["duration_s"] else True,
                    -c["score"]))
            virtual = []
            seen_songs = set()
            ids = []
            for c in scored:
                # Extract artist/title like local files: split "Artist - Title"
                raw_title = c.get("title") or c_title or q
                cand_art = c.get("artist") or ""
                cand_title = raw_title
                if not cand_art and " - " in raw_title:
                    parts = raw_title.split(" - ", 1)
                    cand_art = parts[0].strip()
                    cand_title = parts[1].strip()
                if not cand_art:
                    cand_art = c_artist or raw_title
                # One discovery row per DISTINCT song: a free-text query returns
                # many uploads of the same track, and showing 8 copies of "In the
                # End" was reading as "only NAS results" (they were also owned).
                song = (self._norm_core(cand_art) + " - " +
                        self._norm_core(cand_title))
                if song in seen_songs:
                    continue
                seen_songs.add(song)
                # Skip online results already on the NAS — the local copy
                # wins (ignores " (2017 Remaster)" style suffixes).
                norm_key = (f"{self._norm_core(cand_art)} - "
                            f"{self._norm_core(cand_title)}")
                in_nas = (norm_key in local_core) or \
                         (self._innas_lenient(cand_art, cand_title)
                          is not None)
                virtual.append({
                    "kind": "virtual", "video_id": c["video_id"],
                    "artist": cand_art,
                    "title": cand_title,
                    "channel": c["channel"],
                    "duration_s": c["duration_s"],
                    "score": c["score"], "tier": c["tier"],
                    "stream_uri": f"staging:yt:{c['video_id']}",
                    "provider": provider,
                    "in_nas": in_nas,
                    "library": "nas" if in_nas else None,
                    "album": c.get("album") or "",
                    "album_image": c.get("album_image") or "",
                })
                ids.append(c["video_id"])
                if len(virtual) >= 8:
                    break
            # Inline CACHE HITS first (cheap ms: dz:cover + dz:album +
            # song_meta, no network) so the first sr4 write already carries
            # imgs + albums; only misses background-fetch below then rewrite.
            for r in virtual:
                if not r.get("album"):
                    try:
                        _ab = state.db.misc_get(
                            "dz:album:" + self._norm(
                                "%s - %s" % (r.get("artist") or "",
                                             r.get("title") or "")),
                            7 * 86400)
                        if _ab:
                            r["album"] = _ab
                    except Exception:                   # noqa: BLE001
                        pass
                if r.get("album_image"):
                    continue
                try:
                    _bn = "%s - %s" % (r.get("artist") or "",
                                        r.get("title") or "")
                    _hit = state.db.misc_get(
                        "dz:cover:" + self._norm(_bn), 7 * 86400)
                    if _hit:
                        r["album_image"] = _hit
                        continue
                    _m = state.db.song_meta_get(_bn)
                    if _m and _m.get("album_image"):
                        r["album_image"] = _m["album_image"]
                except Exception:                       # noqa: BLE001
                    pass
            # Per-row Deezer covers (parallel, cached): YouTube candidates
            # carry no album art, so without this every row falls back to a
            # pixelated YT thumb. Rows are written FIRST (see below) so the
            # waiting search poll sees them without cover latency; this fill
            # only upgrades the cached rows afterwards.
            state.db.misc_put("sr4:" + qkey, {
                "artist": c_artist, "title": c_title,
                "provider": provider, "expected_dur": expected_dur,
                "discovery": virtual})
            # Wake the waiting /api/search poll NOW (rows exist); covers +
            # URL prewarm keep running below in this same worker.
            try:
                with type(self)._sr_lock:
                    _ev = type(self)._sr_inflight.get(qkey)
                if _ev is not None:
                    _ev.set()
            except Exception:                           # noqa: BLE001
                pass
            if virtual:
                import concurrent.futures

                def _fill(r):
                    if not r.get("album_image"):
                        try:
                            cov = self._deezer_cover_cached(
                                "%s - %s" % (r.get("artist") or "",
                                             r.get("title") or ""))
                        except Exception:               # noqa: BLE001
                            cov = None
                        if cov:
                            r["album_image"] = cov
                    if not r.get("album"):
                        try:
                            alb = self._deezer_album_cached(
                                "%s - %s" % (r.get("artist") or "",
                                             r.get("title") or ""))
                        except Exception:               # noqa: BLE001
                            alb = None
                        if alb:
                            r["album"] = alb

                with concurrent.futures.ThreadPoolExecutor(
                        max_workers=min(8, len(virtual))) as ex:
                    list(ex.map(_fill, virtual))
            # Re-write the sr3 cache WITH covers (rows are picked, not yet
            # prewarmed): the app only needs the rows to exist to show them,
            # and the poll/refetch path reads this cache directly. The URL
            # prewarm then runs to completion in this same worker afterwards.
            state.db.misc_put("sr4:" + qkey, {
                "artist": c_artist, "title": c_title,
                "provider": provider, "expected_dur": expected_dur,
                "discovery": virtual})
            if ids:
                self._prewarm_resolve(ids, wait_sec=6)
        except Exception:                             # noqa: BLE001
            logger.exception("discovery failed for %r", q)

    def _discovery_sync(self, q, qkey):
        """Dedupe a cold /api/search discovery build. Returns the shared Event
        the caller can wait on: a concurrent re-search of the same query joins
        the SAME running build (plus its prewarm) instead of starting a second
        thread or handing back an empty discovery list."""
        with type(self)._sr_lock:
            ev = type(self)._sr_inflight.get(qkey)
            if ev is not None:
                return ev
            ev = threading.Event()
            type(self)._sr_inflight[qkey] = ev

        def _run():
            try:
                self._discover_async(q, qkey)
            except Exception:                       # noqa: BLE001
                logger.exception("discovery worker failed for %r", q)
            finally:
                ev.set()
                with type(self)._sr_lock:
                    type(self)._sr_inflight.pop(qkey, None)

        threading.Thread(target=_run, daemon=True).start()
        return ev

    def _preview_album_count(self, name):
        """Studio album count shown on the search-preview subtitle: the
        number of DISTINCT core albums when the local NAS library is merged
        with the Deezer studio discography (singles/EPs/live/compilations
        excluded, edition variants collapsed).

        NEVER blocks the request thread for the full merge: the count is
        computed in a single-flight background thread and memoized, so a warm
        search reads O(1) per artist. None (hidden) until the count is ready.
        """
        state = self.state
        key = self._norm(name)
        now = time.time()
        with type(self)._album_count_mem_lock:
            hit = type(self)._album_count_mem.get(key)
            if hit and now - hit[0] < type(self)._album_count_ttl:
                return hit[1]
            if type(self)._album_count_inflight.get(key):
                return None
            type(self)._album_count_inflight[key] = True

        def _compute():
            try:
                disc = state.db.misc_get("dz:albums:v2:" + key, 7 * 86400)
                if disc is None:
                    cnt = None
                else:
                    songs = [s for s in self._all_songs_by_artist(name)
                             if not self._is_live(s.get("title") or "")
                             and not self._is_live(s.get("base_name") or "")]
                    albums, _singles = self._merge_albums(
                        name, songs, disc if isinstance(disc, list) else [])
                    cnt = len(albums) if albums else None
                ttl = type(self)._album_count_ttl if cnt is not None \
                    else type(self)._album_count_retry
                with type(self)._album_count_mem_lock:
                    type(self)._album_count_mem[key] = (time.time(), cnt)
            except Exception:                             # noqa: BLE001
                with type(self)._album_count_mem_lock:
                    type(self)._album_count_inflight.pop(key, None)
                return
            with type(self)._album_count_mem_lock:
                type(self)._album_count_inflight.pop(key, None)

        threading.Thread(target=_compute, daemon=True).start()
        return None

    def _search_artists(self, q):
        """Best-effort Deezer artist matches (name + photo) for the search
        bar, so tapping one opens the artist page. Cached briefly (name/image/
        raw nb_album only); the STUDIO album count is computed per read from
        the discography cache so the preview matches the artist page exactly.

        NON-BLOCKING: on a cache miss this returns (rows=[], pending=True)
        IMMEDIATELY and a background job fetches Deezer + starts hydration,
        so a cold search never waits on api.deezer.com inline (the old code
        blocked the whole search response up to ~12s). `pending` goes False
        as soon as the artist rows exist; the studio album count is shown on
        the next poll once that artist's discography finishes hydrating
        (None until then — the preview never disagrees with the page)."""
        state = self.state
        key = "sa:" + self._norm(q)
        got = state.db.misc_get(key, 6 * 3600)
        if got is None:
            with type(self)._sa_lock:
                inflight = type(self)._sa_inflight.get(key)
                if inflight is not None and \
                        (time.time() - inflight) < 120:
                    return [], True
                type(self)._sa_inflight[key] = time.time()
            threading.Thread(target=self._artists_fetch_async,
                             args=(q, key), daemon=True).start()
            return [], True
        out = []
        pending = False
        for a in got:
            cnt = self._preview_album_count(a.get("name"))
            if cnt is None:
                n = a.get("name")
                if n:
                    self._artist_hydrate_start(n)
            out.append({"name": a.get("name"),
                        "image": a.get("image"),
                        "album_count": cnt})
        return out, pending

    def _artists_fetch_async(self, q, key):
        """Background: fetch Deezer artist matches for /api/search + hydrate
        the top candidates, then fill the `sa:` cache. Runs off the request
        thread so a cold search stays instant."""
        import urllib.parse
        state = self.state
        raw = []
        try:
            data = state.scorer._deezer_get(
                "https://api.deezer.com/search/artist?q="
                + urllib.parse.quote(q) + "&limit=8")
            araw = []
            for a in (data or {}).get("data") or []:
                name = a.get("name")
                if not name:
                    continue
                pic = a.get("picture_medium") or a.get("picture")
                if not pic or pic.endswith(
                        "/artist//250x250-000000-80-0-0.jpg"):
                    pic = None
                araw.append({"name": name, "image": pic,
                             "_nb": a.get("nb_album")})
            # Deezer ranks impostors/clones above the real artist (e.g.
            # "Queen(Ares)" first for a "queen" search). Re-rank so an
            # exact normalized-name match wins the top spot; among those,
            # biggest raw release count first.
            target = self._norm(q)
            araw.sort(key=lambda a: (
                self._norm(a["name"]) != target,
                -((a.get("_nb") or 0))))
            raw = araw
            # Persist EVEN an empty match list: a query with no Deezer artist
            # hits would otherwise never produce an `sa:` row, making
            # `_search_artists` return pending=True forever (re-fetching on
            # every search). An empty result is a settled "no matches".
            state.db.misc_put(key, raw)
            # Prewarm the artist-page caches (Deezer discography + photo)
            # for the top candidates, so tapping an artist is INSTANT: the
            # page is already complete when it opens instead of showing a
            # bare "no songs" frame until hydration finishes. Runs ONE job
            # per artist (the `_artist_hydrate` registry dedupes).
            for a in raw[:2]:
                n = a.get("name")
                if n:
                    self._artist_hydrate_start(n)
        except Exception:                                # noqa: BLE001
            logger.info("artists fetch failed for %s", str(q)[:40])
        finally:
            type(self)._sa_inflight.pop(key, None)

    def _suggest_index(self):
        """Cached (base, full, rel, meta) rows for every mp3, rebuilt when
        the folder set changes or the cache goes stale. This avoids re-walking
        + normalizing the whole library on every keystroke."""
        now = time.time()
        idx = type(self)._suggest_cache
        if idx and (now - idx[0]) < 60:
            return idx[1]
        return type(self)._build_suggest_index(self.state)

    @staticmethod
    def _build_suggest_index(state):
        rows = []
        seen = set()
        music_root = os.path.normpath(state.config.music_root)
        staging_dir = os.path.normpath(state.config.staging_dir)
        pldir = os.path.normpath(state.config.playlist_dir)
        for root in (state.config.music_root, state.config.staging_dir,
                     state.config.playlist_dir):
            if not os.path.isdir(root):
                continue
            for full in state._walk_mp3(root):
                base = os.path.basename(full)[:-4]
                if base in seen:
                    continue
                seen.add(base)
                # Build the correct serving URL prefix per root.
                norm = os.path.normpath(full)
                rp = os.path.relpath(norm, music_root)
                if not rp.startswith(".."):
                    url = "/staging/file/" + rp
                else:
                    rp2 = os.path.relpath(norm, pldir)
                    url = "/staging/pl/" + rp2 if not rp2.startswith("..") \
                        else "/staging/file/" + os.path.relpath(norm, staging_dir)
                meta = state.db.song_meta_get(base) or {}
                rows.append((base, full, url, meta))
        Handler._suggest_cache = (time.time(), rows)
        return rows

    def _suggest(self, q):
        """Live suggestions while the user types: your NAS library matches
        first (guaranteed, offline, so typing "puta" instantly surfaces the
        Extremoduro file) PLUS online Deezer suggestions (Spotify/YouTube-Music
        style). Rows are provider-tagged; NAS rows play the local file, online
        rows stream."""
        if not q or not q.strip():
            return {"results": []}
        qq = q.strip()
        declared = []
        token_norms = [self._norm(w) for w in qq.split()
                       if len(self._norm(w)) >= 2]
        qnorm = self._norm(qq)
        if token_norms:
            scored = []
            ar_norm = self._norm(
                qq.split(" - ", 1)[0].strip()) if " - " in qq else ""
            for base, full, url, meta in self._suggest_index():
                if not self._lib_visible(base, self._me()):
                    continue
                hay = self._norm(base)
                hits = sum(1 for t in token_norms if t in hay)
                if not hits:
                    # Tolerant pass (NAS-first search, bug O): a query like
                    # "D12 Purple Hills" must still surface "Purple Hills
                    # (Poop N Secrets)" even when no single token lands in the
                    # whole base — match artist and title parts separately.
                    continue
                score = hits * 15 + 500
                if qnorm and qnorm in hay:
                    score += 80
                title_part = base.split(" - ", 1)[1] \
                    if " - " in base else base
                tlow = self._norm(title_part)
                for t in token_norms:
                    if t in tlow:
                        score += 15
                if ar_norm and ar_norm in hay:
                    score += 30
                if qnorm and qnorm in tlow:
                    score += 50
                # Artist-exact boost: "bb trickz" surfaces the artist's
                # own files first, not just title-token hits.
                lead = base.split(" - ", 1)[0].strip() \
                    if " - " in base else ""
                if qnorm and lead and self._norm(lead) == qnorm:
                    score += 1000
                scored.append((score, base, full, url, meta))
            # Tolerant suggestions: files the strict pass above skipped but
            # whose core artist/title still matches — e.g. the search typed
            # "Purple Hills" and only "D12 - Purple Hills" exists.
            q_art_core = self._norm_core(
                qq.split(" - ", 1)[0].strip()) if " - " in qq else ""
            q_ti_core = self._norm_core(
                qq.split(" - ", 1)[1]) if " - " in qq else self._norm_core(qq)
            seen_bases = {s[1] for s in scored}
            for base, full, url, meta in self._suggest_index():
                if not self._lib_visible(base, self._me()):
                    continue
                if base in seen_bases:
                    continue
                t = 0
                if " - " in base:
                    b_ar, b_ti = base.split(" - ", 1)
                    b_ar_c = self._norm_core(b_ar)
                    b_ti_c = self._norm_core(b_ti)
                else:
                    b_ar_c, b_ti_c = "", self._norm_core(base)
                if q_art_core and b_ar_c and q_art_core == b_ar_c:
                    t += 45
                if q_ti_core and b_ti_c and q_ti_core in b_ti_c:
                    t += 40
                if q_ti_core and b_ti_c and q_ti_core == b_ti_c:
                    t += 20
                if t >= 60:
                    scored.append((t, base, full, url, meta))
            scored.sort(key=lambda x: -x[0])
            for _score, base, full, url, meta in scored[:2]:
                declared.append({
                    "kind": "local", "base_name": base,
                    "folder": base.split(" - ", 1)[0] if " - " in base else "",
                    "url": url,
                    "artist": meta.get("artist"),
                    "title": (base.split(" - ", 1)[1]
                              if " - " in base else base),
                    "album": meta.get("album"),
                    "album_image": meta.get("album_image"),
                    "provider": "NAS",
                    "is_explicit": False,
                })
        online = []
        try:
            online = self.state.scorer.deezer_autocomplete(qq, limit=6,
                                                           timeout=4.0)
        except Exception as ex:                       # noqa: BLE001
            self._log(f"suggest online failed: {str(ex)[:60]}")
        # YT/pick flavor alongside Deezer autocomplete: fast YTMusic-only
        # lookup, ranked by pick, so online rows aren't Deezer-only.
        try:
            _yt = self.state.scorer.search_ytmusic(qq) or []
            _scored, _ = self.state.scorer.pick(_yt, [qq], qq)
            for c in (_scored or [])[:3]:
                _t = (c.get("title") or "").strip()
                _a = (c.get("artist") or c.get("channel") or "").strip()
                if not _t:
                    continue
                online.append({"kind": "song", "artist": _a, "title": _t,
                               "album": c.get("album") or "",
                               "duration_s": c.get("duration_s"),
                               "album_image": c.get("album_image") or "",
                               "url": None, "provider": "YouTube",
                               "is_explicit": False,
                               "video_id": c.get("video_id")})
        except Exception:                             # noqa: BLE001
            pass
        # Artist-exact first online too (bb trickz first).
        try:
            online.sort(key=lambda o: (
                self._norm(o.get("artist") or "") != qnorm))
        except Exception:                             # noqa: BLE001
            pass
        # Prewarm the resolvename cache for online suggestions so tapping one
        # streams instantly (like the infinite queue) instead of waiting on a
        # live YouTube search + yt-dlp. Background thread; best-effort.
        if online:
            import threading as _th
            _th.Thread(target=self._prewarm_resolvename,
                       args=([(o.get("artist"), o.get("title"))
                              for o in online[:5]],),
                       daemon=True).start()
        return {"results": declared + online}

    def _prewarm_resolvename(self, pairs):
        """Resolve + cache a handful of (artist, title) pairs in the background
        (14-day misc cache used by /api/resolvename), so suggestion taps are
        instant rather than blocking on a slow YouTube search + yt-dlp.
        Dedupes against already-running resolution jobs (same worker registry
        the /api/resolvename pending path uses) so page pre-warm and a tap on
        the same track never launch two yt-dlp processes."""
        state = self.state
        # Bounded concurrency: cap simultaneous yt-dlp across ALL prewarm +
        # tap workers (see _rn_sem). Spawning one thread per pair is fine;
        # they just wait on the semaphore instead of stacking 60 processes.
        for artist, title in pairs:
            if not artist or not title:
                continue
            key = self._rn_key(artist, title)
            if state.db.misc_get(key, 14 * 86400) or state.db.misc_get(
                    "ry:" + key[3:], 14 * 86400):
                continue
            with type(self)._rn_jobs_lock:
                job = type(self)._rn_jobs.get(key)
                if job is not None and job["ts"] >= time.time() - 300:
                    continue
                type(self)._rn_tok += 1
                tok = type(self)._rn_tok
                type(self)._rn_jobs[key] = {
                    "ts": time.time(), "bg": True, "tok": tok}
                threading.Thread(target=self._rn_worker,
                                 args=(key, artist, title),
                                 kwargs={"bg": True, "tok": tok},
                                 daemon=True).start()

    @staticmethod
    def _rn_key(artist, title):
        return "rz:" + Handler._norm(artist) + "\x00" + Handler._norm(title)

    def _resolvename(self, artist, title):
        """Find + resolve a track by artist/title (internet; for career
        pages). Cached so repeated taps are instant. On a COLD miss it never
        blocks the request on yt-dlp: it registers/joins a shared background
        job and returns {"status":"pending"} immediately; the app polls back
        and gets the resolved URL once the worker caches it."""
        state = self.state
        if not artist or not title:
            return self._error(400, "need artist + title")
        key = self._rn_key(artist, title)
        got = state.db.misc_get(key, 14 * 86400)
        if got is None:  # dual-read: pre-rename ry rows stay warm
            old = state.db.misc_get(
                "ry:" + key[3:], 14 * 86400)
            if old is not None:
                got = old
                try:
                    state.db.misc_put(key, old)
                except Exception:                       # noqa: BLE001
                    pass
        if got and isinstance(got, dict) and got.get("url"):
            if not got.get("album"):
                # Pre-album rz:/ry: rows (14d TTL): heal in place via the
                # cached Deezer title so resolve replies carry album now.
                try:
                    _alb = (self._deezer_album_cached(
                        f"{artist} - {title}") or "")
                except Exception:                       # noqa: BLE001
                    _alb = ""
                if _alb:
                    got["album"] = _alb
                    try:
                        state.db.misc_put(key, got)
                    except Exception:                   # noqa: BLE001
                        pass
            return self._json(got)
        # NAS-first on the tap path (exact _innas + lenient fallback):
        # owned songs play the local file instantly, relay only when
        # truly absent.
        try:
            hit = self._innas(artist, title)
        except Exception:                               # noqa: BLE001
            hit = None
        if hit and hit.get("found") and hit.get("url"):
            try:
                _alb0 = (hit.get("album")
                         or self._deezer_album_cached(
                             f"{artist} - {title}") or "")
            except Exception:                               # noqa: BLE001
                _alb0 = ""
            return self._json({
                "url": hit["url"], "in_nas": True,
                "nas_base": hit.get("base_name"),
                "artist": artist, "title": title, "album": _alb0})
        try:
            _base = self._innas_lenient(artist, title)
        except Exception:                               # noqa: BLE001
            _base = None
        if _base:
            _full = (self._local_files_map() or {}).get(_base)
            _url = self._entry_url(_full) if _full else None
            if _url:
                try:
                    _m0 = state.db.song_meta_get(_base) or {}
                    _alb1 = (_m0.get("album")
                             or self._deezer_album_cached(
                                 f"{artist} - {title}") or "")
                except Exception:                           # noqa: BLE001
                    _alb1 = ""
                return self._json({
                    "url": _url, "in_nas": True,
                    "nas_base": _base,
                    "artist": artist, "title": title, "album": _alb1})
        # Cold: one shared worker per key; concurrent taps/albums join it and
        # poll again instead of spawning their own yt-dlp processes. A user
        # TAP always routes through the TAP lane: if a PREWARM background job
        # already holds this key, we replace it with a tap job (new token) so
        # the tap is never queued behind a deep prewarm backlog.
        with type(self)._rn_jobs_lock:
            job = type(self)._rn_jobs.get(key)
            if job is not None and job["ts"] >= time.time() - 300:
                if job.get("err"):
                    return self._error(502, "resolve failed")
                if job.get("bg"):
                    type(self)._rn_tok += 1
                    tok = type(self)._rn_tok
                    type(self)._rn_jobs[key] = {
                        "ts": time.time(), "tok": tok}
                    threading.Thread(target=self._rn_worker,
                                     args=(key, artist, title),
                                     kwargs={"tok": tok},
                                     daemon=True).start()
                return self._json({"status": "pending", "key": key})
            type(self)._rn_tok += 1
            tok = type(self)._rn_tok
            type(self)._rn_jobs[key] = {"ts": time.time(), "tok": tok}
            threading.Thread(target=self._rn_worker,
                             args=(key, artist, title),
                             kwargs={"tok": tok},
                             daemon=True).start()
        return self._json({"status": "pending", "key": key})

    def _rn_worker(self, key, artist, title, bg=False, tok=0):
        # Bounded: cap concurrent yt-dlp search/resolve subprocesses so a big
        # prewarm or burst of taps doesn't overload the NAS. Taps run on the
        # TAP lane (_rn_sem); background prewarm on its own lane (_rn_sem_bg),
        # so a user tap is NEVER queued behind a prewarm backlog.
        sem = (type(self)._rn_sem_bg if bg else type(self)._rn_sem)

        def _own_job():
            with type(self)._rn_jobs_lock:
                return type(self)._rn_jobs.get(key, {}).get("tok") == tok

        def _fail():
            with type(self)._rn_jobs_lock:
                if type(self)._rn_jobs.get(key, {}).get("tok") == tok:
                    type(self)._rn_jobs[key] = {
                        "ts": time.time(), "err": True, "tok": tok}

        with sem:
            try:
                state = self.state
                # Fast path: YTMusic API search (no yt-dlp subprocess, ~1s) —
                # structured official results with video_id + duration. Only
                # fall back to the slower yt-dlp ytsearch15 merge when the
                # fast search gives nothing usable, so the common cold-resolve
                # case is a single HTTP round-trip instead of two subprocesses.
                scored = None
                try:
                    cands = state.scorer.search_ytmusic(
                        f"{artist} {title}".strip())
                    scored, _ = state.scorer.pick(cands, [artist], title)
                    # Trust the fast path only on a strong title match
                    # (exact / one-contains-the-other) — at ANY tier. An
                    # official-channel upload of a DIFFERENT song used to be
                    # accepted blind here and frozen 14 days (Marea case).
                    if scored:
                        want = self._norm(title)
                        got = self._norm(scored[0].get("title"))
                        if not want or (want not in got and got not in want):
                            scored = None
                except Exception:                        # noqa: BLE001
                    scored = None
                if not scored:
                    cands = state.scorer.search(artist, title)
                    scored, _ = state.scorer.pick(cands, [artist], title)
                if not scored:
                    _fail()
                    return
                # Try the top candidates in order: the best pick is sometimes
                # unplayable (age-restricted / region-locked / removed —
                # resolve_url comes back empty — or webm/opus, which
                # MediaPlayer cannot play) while #2 is the same song and
                # streams fine. Identity follows the WINNER, not [0].
                vid, url, winner = None, None, None
                for cand in scored[:5]:
                    v = cand.get("video_id")
                    if not v:
                        continue
                    u = state.scorer.resolve_url(v, timeout=90)
                    if not u:
                        continue
                    if state.scorer.stream_is_opus(u):
                        logger.info("resolvename opus skip %s", v)
                        continue
                    vid, url, winner = v, u, cand
                    break
                if not url:
                    _fail()
                    return
                state.db.resolved_cache_put(vid, url)
                try:
                    album = (winner.get("album") or
                             self._deezer_album_cached(
                                 f"{artist} - {title}") or "")
                except Exception:                       # noqa: BLE001
                    album = ""
                out = {"video_id": vid, "url": self._play_url(vid),
                        "thumb": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
                        "artist": artist, "title": title,
                        "album": album,
                       # The ACTUAL resolved media identity (what will play), so
                       # the app can key lyrics/album by the real video instead of
                       # the discovery identity (metadata fix for internet items).
                       "resolved_artist": winner.get("artist") or artist,
                       "resolved_title": winner.get("title") or title}
                state.db.misc_put(key, out)
                if _own_job():
                    with type(self)._rn_jobs_lock:
                        type(self)._rn_jobs.pop(key, None)
            except Exception:                             # noqa: BLE001
                logger.exception("resolvename worker failed for %s", key[:60])
                _fail()

    def _open_url(self, url):
        """Deep-link intel: turn a YouTube / YT-Music / Spotify link into the
        underlying song identity so the app can open share links in-app.
        Returns (always HTTP 200):
          youtube: {"kind":"youtube","video_id","artist","title","url"}
          spotify: {"kind":"spotify","artist","title","image","url"}
          unknown: {"kind":"unknown","url"}
        No blocking on yt-dlp: a single fast lookup per provider only."""
        try:
            from urllib.parse import urlparse, parse_qs
            p = urlparse(url)
        except Exception:                                  # noqa: BLE001
            return {"kind": "unknown", "url": url}
        host = (p.netloc or "").lower()
        # Exact host sets (2026-09-18, public Funnel URL): the old
        # `"spotify.com" in host` substring test matched attacker domains
        # like evilspotify.com / spotify.link.evil.com, and the redirect
        # follower below fetched them blindly (SSRF into the LAN).
        _YT_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com",
                     "music.youtube.com"}
        _YT_SHORT = {"youtu.be", "www.youtu.be"}
        _SPOT_HOSTS = {"spotify.com", "open.spotify.com", "play.spotify.com",
                       "www.spotify.com"}
        _SPOT_SHORT = {"spotify.link"}
        q = parse_qs(p.query)
        # ---- YouTube / YT Music / youtu.be
        if host in _YT_HOSTS or host in _YT_SHORT:
            if host == "youtu.be" or host == "www.youtu.be":
                vid = (p.path or "/").lstrip("/").split("/")[0]
            else:
                vid = (q.get("v") or [None])[0]
                if not vid:
                    m = re.search(r"/(?:shorts|embed)/([A-Za-z0-9_-]{6,})",
                                  p.path or "")
                    if m:
                        vid = m.group(1)
            if not vid:
                return {"kind": "unknown", "url": url}
            artist, title = self._yt_video_meta(vid)
            try:
                album = (self._deezer_album_cached(
                    f"{artist} - {title}") or "") if artist and title else ""
            except Exception:                           # noqa: BLE001
                album = ""
            return {
                "kind": "youtube", "video_id": vid,
                "artist": artist or "", "title": title or "",
                "album": album,
                "url": f"https://music.youtube.com/watch?v={vid}",
            }
        # ---- Spotify track
        if host in _SPOT_HOSTS or host in _SPOT_SHORT:
            m = re.search(r"/track/([A-Za-z0-9]+)", p.path or "")
            if not m and host in _SPOT_SHORT:
                # Share-button short links (spotify.link/<code>) redirect
                # to the real open.spotify.com/track/<id>. Read ONLY the
                # Location header (never the body) and accept it ONLY when
                # it lands on open.spotify.com — no blind fetch (SSRF).
                try:
                    loc = _peek_redirect_location(url)
                    lp = urlparse(loc or "")
                    if ((lp.scheme in ("http", "https"))
                            and (lp.hostname or "").lower()
                            == "open.spotify.com"):
                        m = re.search(r"/track/([A-Za-z0-9]+)", lp.path or "")
                        if m:
                            url = lp.geturl()
                    else:
                        m = None
                except Exception:                          # noqa: BLE001
                    m = None
            if m:
                tid = m.group(1)
                ck = "spm:" + tid
                got = None
                try:
                    got = self.state.db.misc_get(ck, 7 * 86400)
                except Exception:                            # noqa: BLE001
                    got = None
                if isinstance(got, dict) and got.get("artist") \
                        and got.get("title"):
                    artist, title, image = (got["artist"], got["title"],
                                            got.get("image") or "")
                else:
                    # Page scrape 404s under anti-bot while getTrack needs a
                    # token round-trip — run both at once, first good wins
                    # (cold = max, not sum). Warm hits the spm: cache above.
                    out = {}

                    def _w(which, fn):
                        try:
                            out[which] = fn()
                        except Exception:                    # noqa: BLE001
                            out[which] = ("", "", "")
                    ts = [threading.Thread(
                              target=_w, args=("s", lambda:
                                               self._spotify_track_meta(tid)),
                              daemon=True),
                          threading.Thread(
                              target=_w, args=("a", lambda:
                                               self._spotify_track_meta_api(
                                                   tid)),
                              daemon=True)]
                    for t in ts:
                        t.start()
                    for t in ts:
                        t.join(15)
                    artist = title = image = ""
                    for k in ("a", "s"):
                        a2, t2, i2 = out.get(k) or ("", "", "")
                        if a2 and t2:
                            artist, title, image = a2, t2, i2
                            break
                    if artist and title:
                        try:
                            self.state.db.misc_put(
                                ck, {"artist": artist, "title": title,
                                     "image": image or ""})
                        except Exception:                    # noqa: BLE001
                            pass
                if artist and title:
                    if not image:
                        # Spotify art dead here (scrape 404 + getTrack
                        # GenericError, e.g. bXfP9D6XFNA): Deezer cover
                        # instead of "" so the app isn't left gradient-only.
                        try:
                            image = self._deezer_cover_cached(
                                f"{artist} - {title}") or ""
                        except Exception:                    # noqa: BLE001
                            image = ""
                    try:
                        album = (self._deezer_album_cached(
                            f"{artist} - {title}") or "")
                    except Exception:                        # noqa: BLE001
                        album = ""
                    return {
                        "kind": "spotify", "artist": artist, "title": title,
                        "album": album, "image": image or "",
                        "url": f"https://open.spotify.com/track/{tid}",
                    }
                # Track genuinely unresolvable anonymously (removed / not in
                # this market): tell the app so it can say so, not silently.
                logger.warning("open-url: spotify %s unresolvable", tid)
                return {"kind": "unknown", "url": url,
                        "unresolved": "spotify"}
            return {"kind": "unknown", "url": url}
        return {"kind": "unknown", "url": url}

    def _yt_video_meta(self, video_id):
        """Best-effort artist+title for a video id (one YTMusic get_song call;
        the app can still stream purely from video_id if this fails).
        Cached 7d (ytm:) so repeat opens are instant."""
        try:
            got = self.state.db.misc_get("ytm:" + video_id, 7 * 86400)
            if isinstance(got, dict) and (got.get("artist")
                                          or got.get("title")):
                return got.get("artist") or "", got.get("title") or ""
        except Exception:                                  # noqa: BLE001
            pass
        try:
            from ytmusicapi import YTMusic
            s = YTMusic().get_song(video_id)
            d = s.get("videoDetails") or {}
            title = (d.get("title") or "").strip()
            artist = (d.get("author") or "").strip()
            # Auto-generated Topic videos report "Artist - Topic": strip it
            # so Deezer album/cover lookups verify against the real artist.
            if artist.lower().endswith(" - topic"):
                artist = artist[: -len(" - topic")].strip()
            if artist or title:
                try:
                    self.state.db.misc_put("ytm:" + video_id,
                                            {"artist": artist, "title": title})
                except Exception:                          # noqa: BLE001
                    pass
            return artist, title
        except Exception:                                  # noqa: BLE001
            return "", ""

    @staticmethod
    def _spotify_track_meta(track_id):
        """Artist + title + art for a Spotify track id by scraping the public
        share page (the API requires a Premium owner, so it 403s here — the
        page's <title> "Song - song and lyrics by Artist | Spotify" is the
        source of truth; og:description is the fallback)."""
        import urllib.request as u
        import urllib.error
        url = f"https://open.spotify.com/track/{track_id}"
        req = u.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        try:
            with u.urlopen(req, timeout=15) as resp:
                html = resp.read().decode("utf-8", "ignore")
        except urllib.error.HTTPError as e:
            # 429 (rate limit), 404/410/403 (page not found / removed /
            # blocked scrape) all mean "couldn't get metadata" — NOT a server
            # error. Never raise here: _open_url returns {"kind":"unknown"}
            # and the app falls back or tells the user the link can't play.
            return "", "", ""
        except Exception:                                  # noqa: BLE001
            # Network timeout / DNS / TLS -> same graceful degradation.
            return "", "", ""
        m = re.search(r"<title>(.*?)</title>", html, re.S)
        if m:
            raw = (m.group(1) or "").strip()
            mm = re.match(r"^(.*?) - song and lyrics by (.*?) \| Spotify$",
                          raw)
            if mm:
                mi = re.search(r'property="og:image" content="([^"]+)"', html)
                return (
                    mm.group(2).strip(),
                    mm.group(1).strip(),
                    (mi.group(1).strip() if mi else ""),
                )
        mt = re.search(r'property="og:title" content="([^"]+)"', html)
        md = re.search(r'property="og:description" content="([^"]+)"', html)
        title = mt.group(1).strip() if mt else ""
        artist = ""
        if md:
            parts = [x.strip() for x in md.group(1).split("·")]
            if parts:
                artist = parts[0]
        mi = re.search(r'property="og:image" content="([^"]+)"', html)
        return artist, title, (mi.group(1).strip() if mi else "")

    # ---- Spotify anonymous Web API (pathfinder). Used by /api/spotify-link so
    # a SHARED Spotify link points at the real TRACK (which autoplays), not a
    # search page. The official Web API 403s ("premium subscription required
    # for the owner of the app") and the legacy get_access_token endpoint is
    # Varnish-blocked, so we mirror exactly what the web player itself does: a
    # TOTP-minted anonymous token + the searchDesktop persisted GraphQL query.
    # The TOTP secret/version live in the web player bundle and are ROTATED by
    # Spotify — newest first, tried in order; if all fail we fall back to a
    # search URL (never worse than before this existed).
    _SPOTIFY_TOTP = (
        (',7/*F("rLJ2oxaKL^f+E1xvP@N', 61),
        ('OmE{ZA.J^":0FG\\Uz?[@WW', 60),
        ("{iOFn;4}<1PFYKPV?5{%u14]M>/V0hDH", 59),
    )
    _SPOTIFY_SEARCH_HASH = (
        "1148393611bbc58e84e47aed35ecc731275df9f9eb660956962e352dd3631d89")
    # fetchPlaylistContents — the web player's own playlist query
    # (operation + hash extracted from the CURRENT web-player bundle).
    # Returns the FULL track sequence with real added-dates, anonymously —
    # the public embed page caps at 100. Best-effort: hash rotates per
    # web-player release, caller falls back to the embed order.
    _SPOTIFY_PLAYLIST_HASH = (
        "86dde7b9d9356e2369414647cf6950cfed96e778e129cfdfc99aea6c1613b3b0")
    # getTrack — the single-track lookup the web player uses to render any
    # track page. Persisted-query hash extracted from the CURRENT
    # web-player.2db3c713.js bundle (2026-09-16). Mirrors the web player's
    # market exactly (anonymous token minted from this server), so it resolves
    # tracks the <title> scrape 404s on, and reports NotFound for removed ones.
    _SPOTIFY_TRACK_HASH = (
        "a8ef9e9f02b836feb0da3003c31dbb30decc6f4b473ef89ca88c882386d668de")
    _spotify_tok_lock = threading.Lock()
    _spotify_tok = None
    _spotify_tok_exp = 0.0
    _spotify_app_tok_lock = threading.Lock()
    _spotify_app_tok = None
    _spotify_app_tok_exp = 0.0

    @staticmethod
    def _spotify_totp(secret, ts):
        """TOTP exactly as the Spotify web player derives it: the plaintext
        secret is XOR-scrambled per index (charCode ^ (i % 33 + 9)), the
        resulting code points are concatenated as DECIMAL text, and those
        UTF-8 bytes are the HMAC key (SHA1 / 30s / 6 digits)."""
        import hashlib
        import hmac as _hmac
        raw = "".join(str(ord(c) ^ ((i % 33) + 9))
                      for i, c in enumerate(secret)).encode()
        counter = int(ts // 30).to_bytes(8, "big")
        digest = _hmac.new(raw, counter, hashlib.sha1).digest()
        off = digest[-1] & 0x0F
        code = (int.from_bytes(digest[off:off + 4], "big") & 0x7FFFFFFF)
        return str(code % 1000000).zfill(6)

    def _spotify_anon_token(self):
        """Fresh anonymous web-player access token (cached until it expires,
        ~50 min). Tries each known TOTP version; returns None if all fail."""
        import time
        import urllib.parse
        import urllib.request
        now = time.time()
        with type(self)._spotify_tok_lock:
            if (type(self)._spotify_tok
                    and now < type(self)._spotify_tok_exp):
                return type(self)._spotify_tok
        for secret, ver in type(self)._SPOTIFY_TOTP:
            try:
                code = self._spotify_totp(secret, now)
                qs = urllib.parse.urlencode({
                    "reason": "init", "productType": "web-player",
                    "totp": code, "totpServer": code, "totpVer": str(ver)})
                req = urllib.request.Request(
                    "https://open.spotify.com/api/token?" + qs,
                    headers={"User-Agent": "Mozilla/5.0",
                             "Referer": "https://open.spotify.com/",
                             "App-Platform": "WebPlayer"})
                with urllib.request.urlopen(req, timeout=12) as resp:
                    j = json.load(resp)
                tok = j.get("accessToken")
                if not tok:
                    continue
                exp = 0
                try:
                    exp = int(
                        j.get("accessTokenExpirationTimestampMs") or 0) / 1000.0
                except Exception:                          # noqa: BLE001
                    exp = 0
                with type(self)._spotify_tok_lock:
                    type(self)._spotify_tok = tok
                    type(self)._spotify_tok_exp = (
                        max(now + 60, exp - 30) if exp else now + 3000)
                return tok
            except Exception:                              # noqa: BLE001
                continue
        return None

    def _spotify_search_tracks(self, artist, title):
        """pathfinder searchDesktop → ranked [{id,name,artists}]. Best-effort:
        returns [] on any failure (caller falls back to a search link)."""
        import urllib.request
        tok = self._spotify_anon_token()
        if not tok:
            return []
        term = f"{artist} {title}".strip()
        variables = {
            "searchTerm": term, "offset": 0, "limit": 10,
            "numberOfTopResults": 5, "includeAudiobooks": False,
            "includeArtistHasConcertsField": False, "includePreReleases": False,
            "includeLocalConcertsField": False, "includeAuthors": False,
        }
        body = json.dumps({
            "variables": variables, "operationName": "searchDesktop",
            "extensions": {"persistedQuery": {
                "version": 1,
                "sha256Hash": type(self)._SPOTIFY_SEARCH_HASH}},
        }).encode()
        req = urllib.request.Request(
            "https://api-partner.spotify.com/pathfinder/v1/query",
            data=body,
            headers={"Authorization": "Bearer " + tok,
                     "User-Agent": "Mozilla/5.0",
                     "content-type": "application/json",
                     "App-Platform": "WebPlayer",
                     "Referer": "https://open.spotify.com/"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                d = json.load(resp)
        except Exception:                                  # noqa: BLE001
            return []
        items = (((d.get("data") or {}).get("searchV2") or {})
                 .get("tracksV2") or {}).get("items") or []
        out = []
        for it in items:
            data = (it.get("item") or {}).get("data") or {}
            uri = data.get("uri") or ""
            if not uri.startswith("spotify:track:"):
                continue
            arts = [((a.get("profile") or {}).get("name") or "")
                    for a in ((data.get("artists") or {}).get("items") or [])]
            out.append({"id": uri.rsplit(":", 1)[-1],
                        "name": data.get("name") or "",
                        "artists": [a for a in arts if a]})
        return out

    def _spotify_track_meta_api(self, track_id):
        """Artist + title + art for a Spotify track id via the web player's own
        getTrack persisted query (anonymous pathfinder token). Succeeds where
        the public page scrape 404s (anti-bot / account-gated rendering), and
        returns ("","","") for tracks that genuinely do not exist anonymously
        (removed, or not available in this market). Never raises."""
        import urllib.request
        tok = self._spotify_anon_token()
        if not tok:
            return "", "", ""
        try:
            body = json.dumps({
                "variables": {"uri": f"spotify:track:{track_id}"},
                "operationName": "getTrack",
                "extensions": {"persistedQuery": {
                    "version": 1, "sha256Hash": type(self)._SPOTIFY_TRACK_HASH}},
            }).encode()
        except Exception:                              # noqa: BLE001
            return "", "", ""
        req = urllib.request.Request(
            "https://api-partner.spotify.com/pathfinder/v1/query",
            data=body,
            headers={"Authorization": "Bearer " + tok,
                     "User-Agent": "Mozilla/5.0",
                     "content-type": "application/json",
                     "App-Platform": "WebPlayer",
                     "Referer": "https://open.spotify.com/"})
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                d = json.load(resp)
        except Exception:                              # noqa: BLE001
            return "", "", ""
        tu = ((d.get("data") or {}).get("trackUnion") or {})
        if tu.get("__typename") != "Track":
            return "", "", ""
        title = (tu.get("name") or "").strip()
        fa = ((tu.get("firstArtist") or {}).get("items") or [])
        artist = ""
        if fa:
            artist = (((fa[0].get("profile") or {}).get("name")) or "").strip()
        image = ""
        al = tu.get("albumOfTrack") or {}
        srcs = ((al.get("coverArt") or {}).get("sources") or [])
        for s in srcs:
            u = (s or {}).get("url") or ""
            if u and not u.startswith("data:"):
                image = u
                break
        return artist, title, image

    def _spotify_link(self, artist, title):
        """artist+title → a real open.spotify.com/track/<id> URL so a shared
        link AUTOPLAYS. Best-effort match by title+artist; falls back to the
        search URL when nothing is confident. Confident hits cached 30 days."""
        import urllib.parse
        state = self.state
        q = urllib.parse.quote(f"{artist} {title}".strip())
        fallback = {"url": f"https://open.spotify.com/search/{q}",
                    "track_id": "", "artist": artist, "title": title}
        if not title:
            return fallback
        key = "sps:" + self._norm(artist) + "\x00" + self._norm(title)
        got = state.db.misc_get(key, 30 * 86400)
        if got and isinstance(got, dict) and got.get("url"):
            return got
        nt = self._norm(title)
        na = self._norm(artist)
        best = None
        best_score = -1
        for t in self._spotify_search_tracks(artist, title):
            nn = self._norm(t.get("name") or "")
            score = 0
            if nt and nn == nt:
                score += 100
            elif nt and (nt in nn or nn in nt):
                score += 55
            if na:
                an = self._norm(" ".join(t.get("artists") or []))
                if an and (na in an or an in na):
                    score += 45
            if score > best_score:
                best_score = score
                best = t
        if best and best_score >= 100:
            res = {"url": f"https://open.spotify.com/track/{best['id']}",
                   "track_id": best["id"], "artist": artist, "title": title}
            state.db.misc_put(key, res)
            return res
        return fallback

    def _prewarm_resolve(self, video_ids, sync_first=False, wait_sec=0):
        """Resolve discovery candidates so the stream proxy starts instantly
        when the user taps play. All cold resolves route through
        `_resolve_shared` so a background prewarm and a concurrent tap on the
        same video share a single yt-dlp round-trip.

        wait_sec > 0: block up to wait_sec for ALL rows to finish (8 parallel
        workers, <-40s total), then return; any stragglers keep resolving in
        the background. This is what makes the rows /staging/api/search hands
        the app already playable. wait_sec == 0: fire the whole pool in a
        background thread and return immediately."""
        if not video_ids:
            return
        if sync_first:
            try:
                state = self.state
                ttl = state.config.resolve_cache_ttl
                vid = video_ids[0]
                if not state.db.resolved_cache_get(vid, ttl):
                    url = self._resolve_shared(vid, timeout=30)
                    if url:
                        state.db.resolved_cache_put(vid, url)
                        video_ids = video_ids[1:]
            except Exception:                     # noqa: BLE001
                logger.info("sync resolve failed for %s",
                            str(video_ids[0])[:40])
        if not video_ids:
            return
        _cold = [v for v in video_ids
                 if not self.state.db.resolved_cache_get(
                     v, self.state.config.resolve_cache_ttl)]
        if not _cold:
            return
        if len(_cold) == 1:
            if wait_sec:
                self._prewarm_one(_cold[0])
            else:
                threading.Thread(target=self._prewarm_one,
                                 args=(_cold[0],), daemon=True).start()
            return
        import concurrent.futures as _cf
        ex = _cf.ThreadPoolExecutor(max_workers=min(8, len(_cold)))
        futs = [ex.submit(self._prewarm_one, v) for v in _cold]
        if wait_sec:
            deadline = time.time() + wait_sec
            for f in futs:
                rem = deadline - time.time()
                if rem <= 0:
                    break
                try:
                    f.result(timeout=rem)
                except Exception:                   # noqa: BLE001
                    pass
        ex.shutdown(wait=False)

    def _prewarm_one(self, vid):
        state = self.state
        ttl = state.config.resolve_cache_ttl
        try:
            if state.db.resolved_cache_get(vid, ttl):
                return
            url = self._resolve_shared(vid, timeout=60)
            if url:
                try:
                    state.db.resolved_cache_put(vid, url)
                except Exception:                   # noqa: BLE001
                    pass
        except Exception:                     # noqa: BLE001
            logger.info("prewarm resolve failed: %s", str(vid)[:40])

    @staticmethod
    def _norm(s):
        import unicodedata
        s = unicodedata.normalize("NFKD", s or "")
        s = "".join(c for c in s if not unicodedata.combining(c)).lower()
        return re.sub(r"[^a-z0-9]+", "", s)

    def _norm_core(self, s):
        """norm() but ignoring parentheticals like (2017 Remaster)."""
        import re as _re
        return self._norm(_re.sub(r"\(.*?\)|\[.*?\]|\{.*?\}", "", s or ""))

    # ------------------------------------------------------------ resolve
    def _rz_url_for_vid(self, video_id):
        """Warm URL for a video_id already resolved into an rz:/ry: row
        (tap plays the row video_id verbatim — reuse it instead of a cold
        yt-dlp). Returns the URL or None. Best-effort, never raises."""
        try:
            rows = self.state.db.query(
                "SELECT value, seen_at FROM webcache WHERE key LIKE 'rz:%'"
                " OR key LIKE 'ry:%'")
        except Exception:                               # noqa: BLE001
            return None
        try:
            import time as _t
            for r in rows:
                try:
                    if 14 * 86400 > 0 and _t.time() - r.get("seen_at", 0) > \
                            14 * 86400:
                        continue
                    v = json.loads(r.get("value") or "{}")
                except Exception:                       # noqa: BLE001
                    continue
                if isinstance(v, dict) and v.get("video_id") == video_id \
                        and v.get("url"):
                    _u = v["url"]
                    # ry:/rz: rows store the RELAY url (_play_url), not the
                    # googlevideo direct url — relaying that self-requests
                    # (404/loop -> instant 502 for every vid). Only reuse
                    # real direct urls here; else fall through to fresh yt-dlp.
                    if "googlevideo.com/" in _u:
                        return _u
                    continue
        except Exception:                               # noqa: BLE001
            return None
        return None

    def _resolve_shared(self, video_id, timeout=30):
        """Resolve a video's direct stream URL, coalescing concurrent cold
        requests for the same id into a single yt-dlp round-trip."""
        import concurrent.futures
        state = self.state
        ttl = state.config.resolve_cache_ttl
        cached = state.db.resolved_cache_get(video_id, ttl)
        if cached:
            return cached
        # Row-tap shortcut: a warm rz:/ry: row for this video_id already
        # holds a playable URL — reuse it instead of a cold yt-dlp.
        _rz = self._rz_url_for_vid(video_id)
        if _rz:
            try:
                state.db.resolved_cache_put(video_id, _rz)
            except Exception:                           # noqa: BLE001
                pass
            return _rz
        with type(self)._resolve_inflight_lock:
            fut = type(self)._resolve_inflight.get(video_id)
            if fut is not None:
                try:
                    return fut.result(timeout=timeout + 5)
                except Exception:                       # noqa: BLE001
                    return None
            fut = concurrent.futures.Future()
            type(self)._resolve_inflight[video_id] = fut

        def _do():
            try:
                return state.scorer.resolve_url(video_id, timeout=timeout)
            except Exception:                           # noqa: BLE001
                return None

        def _complete():
            url = _do()
            if not fut.done():
                fut.set_result(url)
            if url:
                try:
                    state.db.resolved_cache_put(video_id, url)
                except Exception:                       # noqa: BLE001
                    pass
            with type(self)._resolve_inflight_lock:
                type(self)._resolve_inflight.pop(video_id, None)

        threading.Thread(target=_complete, daemon=True).start()
        try:
            return fut.result(timeout=timeout + 5)
        except Exception:                               # noqa: BLE001
            return None

    def _resolve_debug(self, video_id):
        """Run a raw yt-dlp -g against the video and return everything
        (stdout + stderr + return code). Only for diagnosing cold-resolve
        failures from outside the container."""
        r = self.state.scorer.ytdlp(
            ["-f", "ba[ext=m4a]/ba[ext=mp4]/ba[ext=webm]/ba", "-g",
             f"https://www.youtube.com/watch?v={video_id}"],
            timeout=60,
        )
        return self._json({
            "video_id": video_id,
            "returncode": r.returncode,
            "stdout": (r.stdout or "")[:2000],
            "stderr": (r.stderr or "")[:4000],
        })

    def _speedtest(self, video_id):
        """Measure NAS->googlevideo throughput (independent of the client
        connection), so we can tell whether slow streams are the relay or the
        NAS's own path to YouTube."""
        import time as _t
        state = self.state
        url = state.db.resolved_cache_get(video_id,
                                          state.config.resolve_cache_ttl)
        if not url:
            url = self._resolve_shared(video_id)
        if not url:
            return self._error(502, "resolve failed")
        import urllib.request as u
        import io
        req = u.Request(url, headers={"User-Agent": "Mozilla/5.0",
                                      "Accept": "*/*", "Range": "bytes=0-8388607"})
        t0 = _t.time()
        try:
            resp = u.urlopen(req, timeout=30)
            got = 0
            while True:
                b = resp.read(65536)
                if not b:
                    break
                got += len(b)
            dt = _t.time() - t0
            return self._json({
                "video_id": video_id,
                "bytes": got,
                "seconds": round(dt, 3),
                "rate_kBps": int(got / dt / 1000) if dt else 0,
            })
        except Exception as exc:                         # noqa: BLE001
            return self._json({"error": str(exc)})

    def _resolve(self, video_id):
        url = self._resolve_shared(video_id)
        if not url:
            return self._error(502, "resolve failed")
        return self._json({"url": self._play_url(video_id)})

    def _play_url(self, video_id):
        """Absolute streamable URL handed to the app for an internet track.

        The phone plays through the NAS relay instead of the raw googlevideo
        URL: Android MediaPlayer's initial probe of an HTTPS redirecting
        googlevideo URL is notoriously slow (~8s to first audio), whereas the
        relay answers from the LAN in <0.1s with a plain partial-range audio
        stream (measured ~16MB/s NAS->client, and the NAS->googlevideo
        refill is equally fast today). The resolved direct URL stays warm in
        the cache anyway, so the relay re-fetches it instantly."""
        host = (self.headers.get("Host") or "").strip() or "127.0.0.1:6680"
        return f"http://{host}/staging/api/stream?vid={video_id}"

    # ---------------------------------------------------------- stream proxy
    def _stream_remote(self, video_id):
        state = self.state
        ttl = state.config.resolve_cache_ttl
        url = state.db.resolved_cache_get(video_id, ttl)
        if not url:
            url = self._resolve_shared(video_id)
            if not url:
                return self._error(502, "resolve failed")
        return self._relay(url, video_id=video_id)

    def _relay(self, url, timeout=45, video_id=None):
        import re as _re
        import socket
        import urllib.error as _ue
        import urllib.request as u

        headers = {"User-Agent": "Mozilla/5.0", "Accept": "*/*"}
        rng = self.headers.get("Range")
        # Absolute origin offset of this response body (for tail-refetch):
        # 0 for plain/rangeless probes, X for client Range X-Y.
        _m = _re.match(r"bytes=(\d+)-", (rng or "").strip())
        client_start = int(_m.group(1)) if _m else 0
        if rng:
            headers["Range"] = rng
        else:
            # googlevideo throttles streams that carry NO Range header: it
            # drips a few hundred KB then stalls (the classic 'song loads then
            # stops' bug). Always ask the upstream for a full Range so it
            # serves at full speed, regardless of what the client asked.
            headers["Range"] = "bytes=0-"
        try:
            req = u.Request(url, headers=headers)
            resp = u.urlopen(req, timeout=timeout)
        except _ue.HTTPError as he:
            # Honest 416 (bad seek) instead of a lying 200/502: the player
            # re-requests correctly.
            if he.code == 416:
                cr = None
                try:
                    cr = (he.headers or {}).get("Content-Range")
                except Exception:                       # noqa: BLE001
                    cr = None
                self.send_response(416)
                self.send_header("Content-Range", cr or "bytes */*")
                self.send_header("Content-Length", "0")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Connection", "close")
                self.end_headers()
                self.close_connection = True
                return
            e = he
            # A cached direct URL can go stale (googlevideo links expire in
            # hours); now that resolve_cache_ttl is long, refresh ONCE and
            # retry before giving up rather than failing the song.
            if video_id is not None:
                try:
                    self.state.db.resolved_cache_put(video_id, None)
                except Exception:                     # noqa: BLE001
                    pass
                url2 = self._resolve_shared(video_id)
                if url2:
                    try:
                        req2 = u.Request(url2, headers=headers)
                        resp = u.urlopen(req2, timeout=timeout)
                        url = url2
                    except Exception as e2:           # noqa: BLE001
                        logger.warning("stream relay retry failed: %s", e2)
                        return self._error(502, "relay failed")
                else:
                    return self._error(502, "relay failed")
            else:
                logger.warning("stream relay open failed: %s", e)
                return self._error(502, "relay failed")
        except Exception as e:                       # noqa: BLE001
            # A cached direct URL can go stale (googlevideo links expire in
            # hours); now that resolve_cache_ttl is long, refresh ONCE and
            # retry before giving up rather than failing the song.
            if video_id is not None:
                try:
                    self.state.db.resolved_cache_put(video_id, None)
                except Exception:                     # noqa: BLE001
                    pass
                url2 = self._resolve_shared(video_id)
                if url2:
                    try:
                        req2 = u.Request(url2, headers=headers)
                        resp = u.urlopen(req2, timeout=timeout)
                        url = url2
                    except Exception as e2:           # noqa: BLE001
                        logger.warning("stream relay retry failed: %s", e2)
                        return self._error(502, "relay failed")
                else:
                    return self._error(502, "relay failed")
            else:
                logger.warning("stream relay open failed: %s", e)
                return self._error(502, "relay failed")
        try:
            status = getattr(resp, "status", 200)
            up_cr = resp.headers.get("Content-Range")
            up_cl = resp.headers.get("Content-Length")
            # Total size from "bytes 0-N/TOTAL" (may be "*" when unknown).
            total = None
            if up_cr and "/" in up_cr:
                total = up_cr.rsplit("/", 1)[1].strip()
                if total == "*" or not total.isdigit():
                    total = None
            if rng is None and status == 206 and total is not None:
                # The phone's plain-GET probe: answer textbook 200 with the
                # FULL length and NO Content-Range. Forwarding the upstream
                # 206 unsolicited kills MediaPlayer at prepare (instant
                # player-error with duration already known).
                down_status, cl, cr = 200, total, None
            elif status not in (200, 206):
                return self._error(502, "relay failed")
            else:
                # Client asked for a Range (0- or X-Y): verbatim 206/200.
                down_status, cl, cr = status, up_cl, (
                    up_cr if status == 206 else None)
            self.send_response(down_status)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Methods",
                             "GET,POST,DELETE,OPTIONS")
            self.send_header("Content-Type", resp.headers.get(
                "Content-Type") or "audio/webm")
            if cl:
                self.send_header("Content-Length", cl)
            # Stream relays always close: EOF is how media players know the
            # song is done. Keeping an HTTP/1.1 keep-alive socket open after
            # the last chunk makes EOF-based players hang.
            self.send_header("Connection", "close")
            if cr:
                self.send_header("Content-Range", cr)
            # Always advertise seekability (upstream sometimes omits it).
            self.send_header("Accept-Ranges", "bytes")
            self.end_headers()
            logger.info("relay vid=%s client_rng=%r up=%s down=%s cl=%s",
                        video_id, rng, status, down_status, cl)
            # Stream relays must terminate the connection: EOF is how media
            # players learn the song is done. An HTTP/1.1 keep-alive socket
            # left open after the last chunk makes EOF-based players hang.
            self.close_connection = True
            if self.command != "HEAD":
                import http.client
                bytes_sent = 0
                stalls = 0
                # Read through http.client's HTTPResponse (and NOT the raw
                # resp.fp socket): it honors Content-Length and buffering, and
                # raises IncompleteRead carrying .partial when the upstream
                # does not deliver its declared length — a condition we can
                # repair with a Range re-request instead of hanging the song.
                try:
                    while True:
                        try:
                            chunk = resp.read(64 * 1024)
                        except http.client.IncompleteRead as e:
                            chunk = e.partial
                            if not chunk:
                                break
                            try:
                                self.wfile.write(chunk)
                                self.wfile.flush()
                            except Exception:       # noqa: BLE001
                                break
                            bytes_sent += len(chunk)
                            logger.info(
                                "relay incomplete read (sent %s bytes), "
                                "refetching tail", bytes_sent)
                            break
                        except (socket.timeout, TimeoutError):
                            stalls += 1
                            # Tolerate several consecutive stalls before
                            # giving up, so a short throttling/network gap
                            # just pauses the stream. Budget raised 6→12:
                            # googlevideo throttling gaps mid-song used to
                            # truncate the relay, and the app's stall
                            # watchdog then healed from a stale position —
                            # heard as a "~15s restart".
                            if stalls >= 12:
                                logger.info(
                                    "relay stalled repeatedly, aborting")
                                break
                            continue
                        except Exception as e:   # noqa: BLE001
                            logger.info("relay read error, aborting: %s", e)
                            break
                        if not chunk:
                            break
                        stalls = 0
                        bytes_sent += len(chunk)
                        try:
                            self.wfile.write(chunk)
                            self.wfile.flush()
                        except Exception:       # noqa: BLE001
                            break
                        if cl and bytes_sent >= int(cl):
                            break
                finally:
                    try:
                        resp.close()
                    except Exception:       # noqa: BLE001
                        pass
                if cl and bytes_sent < int(cl):
                    # The upstream closed short of its Content-Length. Fetch
                    # the missing tail with a fresh Range request so the client
                    # still receives a complete, byte-exact file. Without this,
                    # a player sees a short read against a real Content-Length
                    # and treats the mid-stream EOF as an error.
                    logger.warning(
                        "relay short stream: %s of %s bytes — refetching tail",
                        bytes_sent, cl)
                    while bytes_sent < int(cl):
                        try:
                            # Absolute origin offset: bytes_sent counts from
                            # THIS response's body start, which begins at
                            # client_start for ranged seeks.
                            req2 = u.Request(url, headers={
                                "User-Agent": "Mozilla/5.0",
                                "Accept": "*/*",
                                "Range": f"bytes={client_start + bytes_sent}-"})
                            resp2 = u.urlopen(req2, timeout=timeout)
                            try:
                                while True:
                                    chunk = resp2.read(64 * 1024)
                                    if not chunk:
                                        break
                                    if bytes_sent + len(chunk) > int(cl):
                                        chunk = chunk[: int(cl) - bytes_sent]
                                    try:
                                        self.wfile.write(chunk)
                                        self.wfile.flush()
                                    except Exception:       # noqa: BLE001
                                        break
                                    bytes_sent += len(chunk)
                                    if bytes_sent >= int(cl):
                                        break
                            finally:
                                try:
                                    resp2.close()
                                except Exception:       # noqa: BLE001
                                    pass
                        except Exception as e:           # noqa: BLE001
                            logger.warning("relay tail refetch failed: %s", e)
                            break
        except Exception as e:                       # noqa: BLE001
            logger.warning("stream relay aborted: %s", e)
        finally:
            try:
                resp.close()
            except Exception:       # noqa: BLE001
                pass

    # ------------------------------------------------------------ lyrics
    def _lyrics(self, base, artist=None, title=None):
        if not base and not title:
            return self._error(400, "bad base")
        if len(base) > 300:
            return self._error(400, "bad base")
        from .lyrics import fetch_lyrics, parse_lrc
        state = self.state

        # Artist/title override: for internet queue items the caller passes the
        # RESOLVED identity (the actual YouTube video), not the discovery
        # identity, so lyrics match what is really playing. When absent we
        # parse them from base ('Artist - Title') as before.
        if artist is None:
            artist = base.split(" - ", 1)[0].strip() if " - " in base else ""
        if title is None:
            title = base.split(" - ", 1)[1].strip() if " - " in base else base

        def payload(synced, plain, source):
            return self._json({
                "base_name": base,
                "artist": artist,
                "title": title,
                "source": source,
                "synced": synced,
                "plain": plain,
                "found": True,
            })

        raw = state.lyrics_bundle.get(base) \
            if isinstance(getattr(state, "lyrics_bundle", None), dict) \
            else None
        if raw:
            lines = parse_lrc(raw)
            if lines:
                return payload([{"t": t, "text": tx} for t, tx in lines],
                               [], "bundle")
            flat = [ln.strip() for ln in raw.splitlines() if ln.strip()]
            if flat:
                return payload([], flat, "bundle")

        fname = base + ".mp3"
        found = None
        for root in (state.config.music_root, state.config.playlist_dir):
            if not os.path.isdir(root):
                continue
            for full in state._walk_mp3(root):
                if os.path.basename(full) == fname:
                    found = full
                    break
            if found:
                break

        if found:
            stem = os.path.splitext(found)[0]
            lrc = stem + ".lrc"
            if os.path.exists(lrc):
                try:
                    with open(lrc, encoding="utf-8",
                              errors="replace") as fh:
                        raw = fh.read()
                    return payload(
                        [{"t": t, "text": tx}
                         for t, tx in parse_lrc(raw)], [], "sidecar")
                except OSError:
                    pass
            txt = stem + ".txt"
            if os.path.exists(txt):
                try:
                    with open(txt, encoding="utf-8",
                              errors="replace") as fh:
                        lines = [ln.strip() for ln in fh if ln.strip()]
                    if lines:
                        return payload([], lines, "sidecar")
                except OSError:
                    pass

        res = fetch_lyrics(base, artist=artist, title=title)
        if not res:
            return self._json({
                "base_name": base, "synced": [], "plain": [],
                "found": False, "source": None,
            })
        if res["synced"]:
            return payload(
                [{"t": t, "text": tx} for t, tx in res["lines"]], [],
                res["source"])
        return payload([], res["lines"], res["source"])

    # ---------------------------------------------------------- metainfo
    def _entry_meta(self, base):
        meta = self.state.db.song_meta_get(base)
        if meta:
            return {
                "base_name": base,
                "artist": meta.get("artist"),
                "album": meta.get("album"),
                "album_artist": meta.get("album_artist"),
                "album_image": meta.get("album_image"),
            }
        lead = base.split(" - ", 1)[0].strip() if " - " in base else ""
        return {"base_name": base, "artist": lead or None,
                "album": None, "album_artist": None, "album_image": None}

    def _metainfo(self, base):
        if not base or len(base) > 300:
            return self._error(400, "bad base")
        return self._json(self._entry_meta(base))

    def _entry_url(self, p):
        state = self.state
        root = os.path.normpath(state.config.music_root)
        pldir = os.path.normpath(state.config.playlist_dir)
        rp = os.path.relpath(p, root)
        if not rp.startswith(".."):
            return "/staging/file/" + rp
        rp2 = os.path.relpath(p, pldir)
        if not rp2.startswith(".."):
            return "/staging/pl/" + rp2
        # Per-user homes (friends' imports land here, not in the shared
        # roots): served as /staging/u/... with an ownership check.
        try:
            uroot = os.path.normpath(state.users.root)
            rp3 = os.path.relpath(p, uroot)
        except Exception:                                # noqa: BLE001
            rp3 = ".."
        if not rp3.startswith(".."):
            return "/staging/u/" + rp3
        return None

    def _is_playlist_file(self, p):
        """True when a local file is SERVED from the playlist dir (Liked/
        playlists -> /staging/pl/...): a favorited copy, NOT proof the user
        owns that exact track in their music library. Keys off the same
        `_entry_url` mapping the row itself uses, so it can never disagree
        with what the app sees (a file that streams as /staging/pl/ counts as
        a playlist copy; /staging/file/ is a real library file)."""
        if not p:
            return False
        u = self._entry_url(p)
        return bool(u) and u.startswith("/staging/pl/")

    def _song_dict(self, base, p):
        url = self._entry_url(p) if p and os.path.exists(p) else None
        exists = p is not None and os.path.exists(p)
        meta = self.state.db.song_meta_get(base)
        album_image = None
        if meta and meta.get("album_image"):
            album_image = meta["album_image"]
        else:
            row = None
            for r in self.state.db.query(
                    "SELECT video_id FROM downloads WHERE base_name=? "
                    "AND video_id IS NOT NULL", (base,)):
                row = r
                break
            if row and row["video_id"]:
                album_image = ("https://i.ytimg.com/vi/"
                               + row["video_id"] + "/hqdefault.jpg")
        d = self.state.duration_for(p) if exists else None
        title = None
        artist = None
        if meta and meta.get("title"):
            title = meta.get("title")
            artist = meta.get("artist")
        if not title:
            home = base.split(" - ", 1)[0].strip() if " - " in base else base
            artist = (meta.get("artist") if meta else None) or home
            title = self._title_of(base)
        return {
            "base_name": base, "path": p, "exists": exists,
            "url": url,
            "title": title, "artist": artist,
            "album": (meta or {}).get("album"),
            "album_artist": (meta or {}).get("album_artist") or artist,
            "album_image": album_image,
            "duration_s": int(d) if d is not None else None,
        }

    def _local_files_map(self):
        """base_name -> full path, for every audio file we can play."""
        return self.state.local_mp3_index()

    _owner_map_cache = (0.0, {})

    def _per_user_libs(self):
        """Visibility split on? Env default OFF; DB flag wins when set."""
        try:
            if getattr(self.state.config, "per_user_libs", False):
                return True
            return bool(self.state.db.flag_get("per_user_libs", False))
        except Exception:                                # noqa: BLE001
            return False

    def _cached_owner_map(self):
        now = time.time()
        ts, cached = type(self)._owner_map_cache
        if now - ts < 30 and cached is not None:
            return cached
        try:
            m = self.state.db.owner_map()
        except Exception:                                # noqa: BLE001
            m = {}
        type(self)._owner_map_cache = (now, m)
        return m

    def _lib_visible(self, base, user):
        """Visibility-only gate (never deletes). Flag OFF = all visible.
        Flag ON = legacy owner='' visible to all, else only the uploader."""
        if not self._per_user_libs():
            return True
        try:
            owner = (self._cached_owner_map().get(base) or "")
        except Exception:                                # noqa: BLE001
            return True
        if not owner:
            return True
        return owner == (user or "")

    # ------------------------------------------------ in-nas lookup (O)
    @staticmethod
    def _innas_score(q_ar, q_ti, q_both, b_ar_c, b_ti_c, base_norm):
        """Score one NAS file against a wanted artist/title. Returns
        (score, title_ok). Two independent guards (both learned from real
        mismatches in the wild):
        1. Artist-only agreement NEVER matches (same-artist different song).
        2. Short-substring containment NEVER counts ("eros" ⊂ "caballeros",
           "hoy"/"todo"/"go" inside longer titles). Containment needs the
           shorter side >= 6 chars AND a compatible artist (or no artist
           on the file side, e.g. dash-less bases).
        Pure function — covered by local tests, no server needed."""
        s = 0
        title_ok = False
        # Dot-collapsed so "m.s.n" == "msn" on both sides (_norm already
        # drops dots; this guards raw dotted cores too).
        q_ar_c = (q_ar or "").replace(".", "")
        b_ar_cc = (b_ar_c or "").replace(".", "")
        q_ti_c = (q_ti or "").replace(".", "")
        b_ti_cc = (b_ti_c or "").replace(".", "")
        # Strip artist echo from titles ("Artist Title" rows): a leading
        # or trailing artist core must not break containment nor inflate
        # the len>=6 floor. Affix-only, so "eros" inside "caballeros"
        # can never match through this path.
        for _ar in (q_ar_c, b_ar_cc):
            if _ar and len(_ar) >= 3:
                if q_ti_c.startswith(_ar):
                    q_ti_c = q_ti_c[len(_ar):]
                elif q_ti_c.endswith(_ar):
                    q_ti_c = q_ti_c[:-len(_ar)]
                if b_ti_cc.startswith(_ar):
                    b_ti_cc = b_ti_cc[len(_ar):]
                elif b_ti_cc.endswith(_ar):
                    b_ti_cc = b_ti_cc[:-len(_ar)]
        q_ti_c = Handler._norm(q_ti_c)
        b_ti_cc = Handler._norm(b_ti_cc)
        artist_ok = bool(q_ar_c and b_ar_cc and (
            q_ar_c == b_ar_cc or q_ar_c in b_ar_cc or b_ar_cc in q_ar_c))
        if q_ar_c and b_ar_cc and q_ar_c == b_ar_cc:
            s += 50
        if q_ti_c and b_ti_cc:
            if q_ti_c == b_ti_cc:
                s += 55
                title_ok = True
            elif (min(len(q_ti_c), len(b_ti_cc)) >= 6
                    and (not b_ar_cc or artist_ok)
                    and (q_ti_c in b_ti_cc or b_ti_cc in q_ti_c)):
                s += 40
                title_ok = True
        if q_both and q_both in base_norm:
            s += 60
            title_ok = True
        return s, title_ok

    def _innas(self, artist, title):
        """Best local file for an internet queue track (artist + title).

        The queue uses this to prefer the NAS copy of a song instead of
        streaming it. Tolerant core-normalized match (ignores '(Remaster)',
        '(Live)' tags, feat./multi-artist lines). Cached briefly so an
        infinite queue doesn't hammer it per row."""
        state = self.state
        ar = (artist or "").strip()
        ti = (title or "").strip()
        me = self._me() or ""
        scope = me if self._per_user_libs() else ""
        key = "innas:{}\x00{}\x00{}".format(
            self._norm_core(ar), self._norm_core(ti), scope)
        got = state.db.misc_get(key, 2 * 3600)
        if got is not None:
            return got
        q_ar = self._norm_core(ar)
        q_ti = self._norm_core(ti)
        q_both = self._norm(f"{ar} {ti}")
        best = None
        best_score = -1
        for base, _full, url, meta in self._suggest_index():
            if not self._lib_visible(base, me or None):
                continue
            if " - " in base:
                b_ar, b_ti = base.split(" - ", 1)
                b_ar_c = self._norm_core(b_ar)
                b_ti_c = self._norm_core(b_ti)
            else:
                b_ar_c, b_ti_c = "", self._norm_core(base)
            s, title_ok = self._innas_score(
                q_ar, q_ti, q_both, b_ar_c, b_ti_c, self._norm(base))
            if s <= 0 or not title_ok:
                continue
            if s > best_score:
                best_score = s
                best = (base, url, meta)
        if best is None:
            out = {"found": False}
        else:
            base, url, meta = best
            out = {
                "found": True,
                "base_name": base,
                "url": url,
                "album": (meta or {}).get("album"),
                "album_image": (meta or {}).get("album_image"),
            }
        state.db.misc_put(key, out)
        return out

    def _annotate_nas(self, rows):
        """Attach `in_nas`/`nas_url`/`nas_base` to autoplay rows when the song
        already exists on the NAS, so the app plays the local file instead of
        streaming YouTube (single request, no per-row app round-trips)."""
        if not rows:
            return rows
        for r in rows:
            if not isinstance(r, dict):
                continue
            try:
                hit = self._innas(r.get("artist") or "",
                                  r.get("title") or "")
            except Exception:                         # noqa: BLE001
                hit = None
            if hit and hit.get("found") and hit.get("url"):
                r["in_nas"] = True
                r["nas_url"] = hit.get("url")
                r["nas_base"] = hit.get("base_name")
        return rows

    @staticmethod
    def _title_of(base):
        """True song title from a 'Artist - Title' base_name (or the whole
        string if there is no artist separator)."""
        return base.split(" - ", 1)[1].strip() if " - " in base else base

    @staticmethod
    def _split_artists(raw):
        """Split a possibly multi-artist string into individual artist names,
        handling 'A & B', 'A feat. B', 'A ft B', 'A, B', 'A / B', 'A with B'."""
        import re as _re
        parts = _re.split(r"\s*(?:&|,|\+|/|x\s*feat\b|feat(?:\.|uring)?|ft\.?|with)\s*",
                          raw or "")
        return [p.strip() for p in parts if p and p.strip()]

    def _innas_lenient(self, artist, title):
        """Best single NAS base_name for an artist/title, or None.

        More tolerant than _innas: matches when the artist's core equals and
        the title core is either contained in the NAS title or the NAS title
        is contained in it (catches "In Da Club" vs "In da club (feat.)" and
        similar). Used to set the search-result "in NAS" cloud marker even when
        the exact spelling differs."""
        q_ar = self._norm_core(artist or "")
        q_ti = self._norm_core(title or "")
        if not q_ar or not q_ti:
            return None
        best = None
        best_score = -1
        for base in self.state.local_mp3_index():
            if not self._lib_visible(base, self._me()):
                continue
            if " - " in base:
                b_ar, b_ti = base.split(" - ", 1)
                b_ar_c = self._norm_core(b_ar)
                b_ti_c = self._norm_core(b_ti)
            else:
                b_ar_c, b_ti_c = "", self._norm_core(base)
            if q_ar != b_ar_c and q_ar not in b_ar_c and \
                    b_ar_c not in q_ar:
                continue
            if q_ti == b_ti_c:
                s = 60
            elif q_ti and b_ti_c and (q_ti in b_ti_c or b_ti_c in q_ti):
                s = 45
            else:
                continue
            if s > best_score:
                best_score = s
                best = base
        return best

    # -------------------------------------------------- check songs
    # Verifies each downloaded track against the studio (Spotify/Deezer)
    # original. A clean studio copy has the same duration; edits/censored/
    # live/remix/karoke versions drift. Scan progress + results live on a
    # class-level dict (shared across the single-process handlers) and the
    # scan runs at most one at a time in a background thread, so the HTTP
    # call returns the current snapshot instantly and repeats are cheap.
    _check_lock = threading.Lock()
    _check_progress = None
    _suggest_cache = None
    _playlists_cache = {}            # user -> (timestamp, signature, payload)
    # Shared background-resolution jobs for /api/resolvename cold misses:
    # key -> {"ts": started_at, "err"?: true, "bg"?: true, "tok": int}.
    # One worker per key; the app polls back until the 14-day "rz:" cache is
    # populated. "bg": a prewarm job; a user tap REPLACES it with its own tap
    # job (new "tok") so it never waits behind a deep prewarm queue.
    _rn_jobs = {}
    _rn_jobs_lock = threading.Lock()
    _rn_tok = 0
    # Tap lane: user taps ONLY. Prewarm uses _rn_sem_bg. So a burst of album
    # prewarm (many pairs) fills the background queue and a tap is never
    # queued behind it — the 30s waits were bg jobs grabbing all 4 slots.
    _rn_sem = threading.BoundedSemaphore(4)
    _rn_sem_bg = threading.BoundedSemaphore(4)
    _artist_hydrating = set()
    _artist_hydrating_lock = threading.Lock()
    # Single-flight: dedupe concurrent cold resolutions (video_id -> Future) so
    # a prewarm and a user tap on the same never-played video share ONE yt-dlp
    # call instead of each waiting its own full round-trip.
    _resolve_inflight = {}
    _resolve_inflight_lock = threading.Lock()
    # Single-flight for /api/search artists background fetch (key -> started
    # timestamp). Tracked separately from _artist_hydrating so a cold artist
    # search runs at most one Deezer fetch+hydrate job per query.
    _sa_inflight = {}
    _sa_lock = threading.Lock()
    # Single-flight discovery builds for /api/search (qkey -> Event). Lets a
    # cold search BLOCK (bounded) on the background discovery+prewarm instead
    # of returning an empty discovery list the app must re-search to fill.
    _sr_inflight = {}
    _sr_lock = threading.Lock()

    def _check_snapshot(self):
        snap = type(self)._check_progress
        return {
            "running": bool(snap and snap.get("running")),
            "scanned": snap.get("scanned", 0) if snap else 0,
            "total": snap.get("total", 0) if snap else 0,
            "done": bool(snap and snap.get("done")),
            "reports": (snap or {}).get("reports", []),
            "scope": (snap or {}).get("scope", ""),
        }

    def _checksongs(self, scope=None, poll=False):
        scope = scope or ""
        snap = type(self)._check_progress
        if not poll and (snap is None or snap.get("done")):
            if type(self)._check_lock.acquire(blocking=False):
                try:
                    snap = type(self)._check_progress
                    if snap is None or snap.get("done"):
                        type(self)._check_progress = {
                            "running": True, "scanned": 0, "total": 0,
                            "reports": [], "done": False, "scope": scope}
                        threading.Thread(
                            target=self._check_songs_worker,
                            args=(scope,), daemon=True).start()
                finally:
                    type(self)._check_lock.release()
        return self._check_snapshot()

    def _check_scope_items(self, scope, user=None):
        """Return sorted (base_name, full_path) items filtered by scope.

        scope: "" = full library, "playlist:<name>" = m3u members,
        "song:<query>" = normalized substring match."""
        idx = self._local_files_map()
        if not scope:
            return sorted(idx.items())
        if scope.startswith("playlist:"):
            name = scope[len("playlist:"):].strip()
            if user is not None and user != self.LEGACY_USER:
                m3u = self._user_m3u_path(user, name)
                if m3u is None:
                    return []
            else:
                m3u = self.state.m3u_for(name)
            members = set()
            try:
                with open(m3u, encoding="utf-8", errors="replace") as fh:
                    for ln in fh:
                        s = ln.strip()
                        if s and not s.startswith("#"):
                            bn = os.path.splitext(os.path.basename(s))[0]
                            members.add(bn)
            except OSError:
                pass
            return sorted((bn, full) for bn, full in idx.items()
                          if bn in members)
        if scope.startswith("song:"):
            q = self._norm(scope[len("song:"):])
            return sorted((bn, full) for bn, full in idx.items()
                          if q and q in self._norm(bn))
        return sorted(idx.items())

    def _check_songs_worker(self, scope=None):
        reports = []
        try:
            items = self._check_scope_items(
                scope or "", getattr(self, "_auth_user", None))
            for bn, full in items:
                prog = type(self)._check_progress or {}
                prog["scanned"] = prog.get("scanned", 0) + 1
                prog["total"] = len(items)
                report = self._check_one(bn, full)
                if report is not None:
                    reports.append(report)
                type(self)._check_progress = {
                    "running": True, "scanned": prog["scanned"],
                    "total": prog["total"], "reports": list(reports),
                    "done": False, "scope": scope}
        except Exception:                                # noqa: BLE001
            logger.exception("checksongs scan failed")
        finally:
            prog = type(self)._check_progress or {}
            type(self)._check_progress = {
                "running": False, "scanned": prog.get("scanned", 0),
                "total": prog.get("total", 0),
                "reports": list(reports), "done": True, "scope": scope}

    def _announcements_path(self):
        import os as _os
        here = _os.path.dirname(_os.path.abspath(__file__))
        return _os.path.join(here, "announcements.json")

    def _announcements_publish(self):
        """Owner-only: append a broadcast card (title/body/url?), or flip
        the app_updates kill switch ({"app_updates": bool}). Returns
        the item. Rate-limited; text capped like the reader."""
        if self._me() != self.LEGACY_USER:
            return self._error(403, "owner only")
        if not _rate_allow("announce:" + (self._me() or "?"), 10, 3600):
            return self._error(429, "too many broadcasts")
        body = self._body_json()
        if not isinstance(body, dict):
            return self._error(400, "invalid JSON")
        if "app_updates" in body and "title" not in body:
            try:
                with open(self._announcements_path(),
                          encoding="utf-8") as fh:
                    d = json.load(fh)
                if not isinstance(d, dict):
                    d = {}
            except Exception:                            # noqa: BLE001
                d = {}
            d["app_updates"] = bool(body.get("app_updates"))
            try:
                with open(self._announcements_path(), "w",
                          encoding="utf-8") as fh:
                    json.dump(d, fh, ensure_ascii=False)
            except Exception as e:                       # noqa: BLE001
                return self._error(500, "save failed: %s" % e)
            return {"app_updates": d["app_updates"]}
        title = str(body.get("title") or "").strip()[:120]
        text = str(body.get("body") or "").strip()[:300]
        url = str(body.get("url") or "").strip()[:500]
        if not title or not text:
            return self._error(400, "need title + body")
        if url:
            p = urllib.parse.urlparse(url)
            if p.scheme not in ("http", "https") or not p.hostname:
                return self._error(400, "bad url")
        import time as _time
        import random as _random
        item = {"id": "b%d-%d" % (int(_time.time() * 1000),
                                  _random.randrange(1 << 30)),
                "title": title, "body": text}
        if url:
            item["url"] = url
        try:
            with open(self._announcements_path(),
                      encoding="utf-8") as fh:
                d = json.load(fh)
            if not isinstance(d, dict):
                d = {}
        except Exception:                                # noqa: BLE001
            d = {}
        items = d.get("items")
        if not isinstance(items, list):
            items = []
        items.append(item)
        d["items"] = items[-20:]
        if "wrapped_season" not in d:
            d["wrapped_season"] = False
        try:
            with open(self._announcements_path(), "w",
                      encoding="utf-8") as fh:
                json.dump(d, fh, ensure_ascii=False)
        except Exception as e:                           # noqa: BLE001
            return self._error(500, "save failed: %s" % e)
        return {"published": item}

    def _announcements_clear(self):
        """Owner-only: remove all broadcast cards (season flag untouched)."""
        if self._me() != self.LEGACY_USER:
            return self._error(403, "owner only")
        try:
            with open(self._announcements_path(),
                      encoding="utf-8") as fh:
                d = json.load(fh)
            if not isinstance(d, dict):
                d = {}
        except Exception:                                # noqa: BLE001
            d = {}
        d["items"] = []
        try:
            with open(self._announcements_path(), "w",
                      encoding="utf-8") as fh:
                json.dump(d, fh, ensure_ascii=False)
        except Exception as e:                           # noqa: BLE001
            return self._error(500, "save failed: %s" % e)
        return {"cleared": True}

    def _client_log(self):
        """Any logged-in device reports a client-side failure
        ({"kind", "message"}) so it lands in NAS logs/events instead of
        vanishing on the phone. Rate-limited per user; text capped."""
        me = self._me() or "?"
        if not _rate_allow("clog:" + me, 60, 3600):
            return self._error(429, "too many client logs")
        body = self._body_json()
        if not isinstance(body, dict):
            return self._error(400, "invalid JSON")
        kind = str(body.get("kind") or "error")[:40]
        message = str(body.get("message") or "")[:2000]
        if not message:
            return self._error(400, "empty message")
        try:
            self.state.db.event("client_error",
                                {"user": me, "kind": kind, "message": message,
                                 "av": str(body.get("av") or "")[:16]})
        except Exception as e:                           # noqa: BLE001
            return self._error(500, "log failed: %s" % e)
        # Mirror into user_errors so phone-reported failures actually show
        # in Settings → User errors (which reads that table, not events).
        # Without this every logClientError vanished from the UI.
        try:
            kl = kind.lower()
            if kl.startswith(("playback", "playback-gave-up",
                               "playback-error", "heal", "unplayab",
                               "autoplay", "playing", "resync", "pause-fire",
                               "resume-fire", "stamp-switch", "noisy",
                               "focus", "interrupt")):
                section = "playback"
            elif kl.startswith(("download", "replace", "staging")):
                section = "download_failed"
            elif kl.startswith(("timeout", "slow-start")):
                section = "timeout"
            elif kl.startswith(("import", "missing")):
                section = "import_missing"
            elif kl.startswith("login"):
                section = "login"
            else:
                section = "general"
            self.state.db.log_user_error(
                me, section, f"[{kind}] {message}")
        except Exception:                                # noqa: BLE001
            pass
        return {"ok": True}

    def _announcements(self):
        """Published events for all devices. File lives next to the code
        (nasmusic/announcements.json) so it survives restarts and needs no
        DB. Shape: {"wrapped_season": bool, "app_updates": bool,
        "app_version": str, "items": [{id,title,body,url?}]}."""
        import os as _os
        out = {"wrapped_season": False, "app_updates": True,
               "app_version": APP_VERSION,
               "items": []}
        try:
            here = _os.path.dirname(_os.path.abspath(__file__))
            with open(_os.path.join(here, "announcements.json"),
                      encoding="utf-8") as fh:
                d = json.load(fh)
            if isinstance(d, dict):
                out["wrapped_season"] = bool(d.get("wrapped_season"))
                if "app_updates" in d:
                    out["app_updates"] = bool(d.get("app_updates"))
                items = d.get("items")
                if isinstance(items, list):
                    out["items"] = [
                        {
                            "id": str(it.get("id") or ""),
                            "title": str(it.get("title") or "")[:120],
                            "body": str(it.get("body") or "")[:300],
                            "url": str(it.get("url") or "")[:500],
                        }
                        for it in items
                        if isinstance(it, dict) and it.get("id")]
        except Exception:                                # noqa: BLE001
            pass
        return out

    def _identify_song(self, base_name, full):
        """Fingerprint a NAS audio file (Chromaprint/AcoustID) and return what
        the audio ACTUALLY is — artist + title — regardless of the filename.
        Returns {'track_id','artist','title','score','duration'} on success or
        {'error': msg} on any failure. Results cached by file path so repeated
        mounts don't re-fingerprint.

        Requires fpcalc (Chromaprint) in the container + an ACOUSTID_API_KEY.
        Results cached by file PATH+SIZE (a base_name key would serve the
        pre-replace identity for 60 d after a check-replace swap)."""
        state = self.state
        if not state.config.acoustid_api_key:
            return {"error": "AcoustID API key not configured (ACOUSTID_API_KEY)"}
        try:
            size = os.stat(full).st_size
        except OSError:
            size = -1
        fpkey = "fp:%s:%d" % (full, size)
        cached = state.db.misc_get(fpkey, 60 * 86400)
        if cached and isinstance(cached, dict) and "error" not in cached:
            return cached
        from .scorer import acoustid_lookup, fpcalc_fingerprint
        fpcalc_bin = state.config.fpcalc_path or state.config.fpcalc_bin
        fp = fpcalc_fingerprint(full, fpcalc_bin)
        if not fp:
            return {"error": "fpcalc failed (is Chromaprint installed?)"}
        hit = acoustid_lookup(
            fp["fingerprint"], fp.get("duration"),
            state.config.acoustid_api_key)
        if isinstance(hit, dict) and hit.get("_debug"):
            return {"error": "no match", "debug": hit["_debug"]}
        if not hit:
            return {"error": "no match in AcoustID database"}
        out = {
            "track_id": hit.get("track_id"),
            "artist": hit.get("artist"),
            "title": hit.get("title"),
            "score": hit.get("score"),
            "duration": hit.get("duration"),
            "filename": base_name,
        }
        state.db.misc_put(fpkey, out)
        return out

    def _check_one(self, base_name, full):
        state = self.state
        artist = None
        title = None
        meta = state.db.song_meta_get(base_name)
        if meta:
            artist = meta.get("artist") or None
            title = meta.get("title") or None
        if not title and " - " in base_name:
            artist, title = (x.strip() for x in
                             base_name.split(" - ", 1))
        if not artist or not title:
            return None
        actual = None
        try:
            st = os.stat(full)
            actual = state.db.duration_get(full, st.st_size)
        except OSError:
            return None
        if actual is None:
            from .scorer import ffprobe_duration
            d = ffprobe_duration(full)
            if d is not None:
                try:
                    state.db.duration_put(full, st.st_size, d)
                except Exception:                        # noqa: BLE001
                    pass
                actual = d
        if actual is None:
            return None
        rel = self.state.rel_to_root(full)
        # Only emit a URL the app can actually play: files under
        # staging_dir have no play route (/staging/file|pl cover only
        # music_root/playlist_dir), so they get url=None instead of a
        # bare relpath that 404s in the player (2026-09-18). The row's
        # Play button is gated on this server-side.
        url = self._entry_url(full)
        expected = self._studio_duration(artist, title)
        if expected is None:
            # No Deezer reference: NEVER a pass (2026-09-18). A wrong file
            # with no reference used to read as "ok" — now it is flagged
            # unverified and fingerprinted when possible.
            out = {"base_name": base_name, "rel": rel, "url": url,
                   "status": "unverified",
                   "actual_dur": actual, "expected_dur": None}
            if state.config.acoustid_api_key:
                real = self._identify_song(base_name, full)
                self._attach_identity(out, real, artist, title)
            return out
        drift = actual - expected
        if abs(drift) <= 8:
            status = "ok"
        elif drift < -8:
            status = "too_short"   # possibly censored / edited
        else:
            status = "too_long"    # extended/live/remix
        out = {"base_name": base_name, "rel": rel, "url": url,
               "status": status,
               "actual_dur": actual, "expected_dur": expected,
               "drift_s": round(drift, 1)}
        # When the file doesn't line up with the filename's song, fingerprint
        # the actual audio to catch mislabeled files (e.g. "50 Cent - Dance"
        # that actually contains "In Da Club").
        if status != "ok" and state.config.acoustid_api_key:
            real = self._identify_song(base_name, full)
            self._attach_identity(out, real, artist, title)
        # Clean/explicit twins share ~identical length, so duration alone
        # can never tell them apart ("Can't C Me" case, 2026-09-18). When
        # Deezer lists same-title rows with MIXED explicit flags at ~equal
        # length, an "ok" is really "can't tell" — flag it for a listen.
        if status == "ok":
            twins = self._explicit_twins(artist, title)
            if twins:
                out["status"] = "needs_explicit_check"
                out["explicit_rows"] = twins
        return out

    @staticmethod
    def _attach_identity(out, real, artist, title):
        """Attach a fingerprint result to a check report. A mismatch verdict
        needs a CONFIDENT hit (score >= 0.7): low-confidence AcoustID hits
        are not evidence. Artist is compared too (it never was)."""
        if not real or not real.get("title"):
            return
        try:
            score = float(real.get("score") or 0)
        except (TypeError, ValueError):
            score = 0
        out["real_artist"] = real.get("artist")
        out["real_title"] = real.get("title")
        out["real_score"] = real.get("score")
        if score < 0.7:
            return
        # Compare tag-stripped cores: a filename tag like "(Original)" is
        # not a different song ("Don't Cry (Original)" IS Don't Cry) —
        # but "El trapecio" vs "El temblor" still mismatches.
        # (Inline strip: _norm_core is an instance method and this is a
        # staticmethod, so it can't be called as Handler._norm_core(x).)
        norm = Handler._norm(re.sub(
            r"\(.*?\)|\[.*?\]|\{.*?\}", "", title or ""))
        if norm and norm != Handler._norm(re.sub(
                r"\(.*?\)|\[.*?\]|\{.*?\}", "",
                real.get("title") or "")):
            out["mismatch"] = True
            return
        ra = Handler._norm(artist)
        if ra and norm and ra != Handler._norm(real.get("artist") or ""):
            out["mismatch"] = True

    def _studio_duration(self, artist, title):
        """Cached Deezer studio duration for an artist/title."""
        state = self.state
        key = "sd:" + self._norm(artist) + "\x00" + self._norm(title)
        got = state.db.misc_get(key, 90 * 86400)
        if got is not None:
            return got if isinstance(got, (int, float)) else None
        d = state.scorer.deezer_duration(key, artist, title)
        try:
            state.db.misc_put(key, d)
        except Exception:                                # noqa: BLE001
            pass
        return d

    def _explicit_twins(self, artist, title):
        """Same-title Deezer rows with MIXED explicit flags at ~equal
        length (within 4 s of each other): genuine clean/explicit twins
        the duration check cannot tell apart. Returns the explicit
        variants (for display) or None. Cached 30 d."""
        key = "vx:" + self._norm(artist) + "\x00" + self._norm(title)
        try:
            got = self.state.db.misc_get(key, 30 * 86400)
        except Exception:                                # noqa: BLE001
            got = None
        if isinstance(got, list):
            rows = got
        else:
            try:
                rows = self.state.scorer.deezer_versions(artist, title) or []
            except Exception:                            # noqa: BLE001
                return None
            try:
                self.state.db.misc_put(key, rows)
            except Exception:                            # noqa: BLE001
                pass
        same = [r for r in rows
                if isinstance(r, dict)
                and self._norm(r.get("name") or "") == self._norm(title)]
        flags = {bool(r.get("explicit")) for r in same}
        if len(flags) < 2:
            return None
        durs = [int(r.get("duration_s") or 0) for r in same
                if int(r.get("duration_s") or 0) > 0]
        if durs and max(durs) - min(durs) > 4:
            return None  # different versions, not clean/explicit twins
        return [{"artist": r.get("artist"), "album": r.get("album"),
                 "duration_s": r.get("duration_s")} for r in same
                if r.get("explicit")]

    # --------------------------------------------- check-songs version picker
    def _split_name(self, bn):
        meta = self.state.db.song_meta_get(bn)
        artist = None
        title = None
        if meta:
            artist = meta.get("artist") or None
            title = meta.get("title") or None
        if not title and " - " in bn:
            artist, title = (x.strip() for x in bn.split(" - ", 1))
        return artist, title

    def _song_versions(self, f):
        """Version picker payload for a flagged NAS file:
        current + expected duration, the reason it was flagged, all the Deezer
        versions (studio first), and the authoritative Spotify match if the
        optional Spotify credentials are configured. Censored/alt versions are
        sorted last but still included so they remain selectable."""
        state = self.state
        artist, title = self._split_name(f)
        if not artist or not title:
            return {"base_name": f, "error": "no artist/title"}
        current = None
        full = (self._local_files_map() or {}).get(f)
        if full:
            try:
                st = os.stat(full)
                current = state.db.duration_get(full, st.st_size)
            except OSError:
                current = None
        expected = self._studio_duration(artist, title)
        versions = state.scorer.deezer_versions(artist, title)
        if versions:
            def _key(v):
                studio_rank = 0 if v["is_studio"] else 1
                if not expected:
                    return (studio_rank,)
                return (studio_rank,
                        abs((v["duration_s"] or 0) - expected))
            versions.sort(key=_key)
        spotify = state.scorer.spotify_search(artist, title)
        # Prepend the current NAS copy as its own row so the user always sees
        # the source of the file they already own (picker-only, not playlists).
        nas_rel = None
        nas_url = None
        if full:
            nas_rel = state.rel_to_root(full)
            nas_url = self._entry_url(full) or nas_rel
        nas_entry = {
            "id": None,
            "name": title,
            "artist": artist,
            "album": (state.db.song_meta_get(f) or {}).get("album") or "",
            "album_image": (state.db.song_meta_get(f) or {})
            .get("album_image") or "",
            "duration_s": current,
            "explicit": False,
            "type": "studio",
            "is_studio": current is None or
                        expected is None or
                        abs((current or 0) - expected) <= 8,
            "source": "nas",
            "preview_url": None,
            "nas_rel": nas_rel,
            "nas_url": nas_url,
        }
        versions = [nas_entry] + versions
        return {
            "base_name": f,
            "artist": artist,
            "title": title,
            "current_dur": current,
            "expected_dur": expected,
            "reason": self._check_reason(f, current, expected),
            "versions": versions,
            "spotify": spotify,
        }

    def _check_reason(self, bn, actual, expected):
        """Human-readable reason a NAS file was flagged, for display/tooltip."""
        base = self._split_name(bn)
        if expected is None:
            return "No studio reference found to compare against — verify manually."
        if actual is None:
            return f"Could not read the local duration (studio ≈ {expected} s)."
        drift = actual - expected
        if drift < -8:
            return (f"This is {abs(drift):.0f} s shorter than the studio "
                    f"version ({actual} s vs {expected} s) — likely censored, "
                    "cut, or an edited/karaoke version.")
        if drift > 8:
            return (f"This is {drift:.0f} s longer than the studio version "
                    f"({actual} s vs {expected} s) — likely a live, extended "
                    "or remix version.")
        return f"Close to studio length ({actual} s vs {expected} s)."

    def _check_replace(self):
        """Replace a flagged NAS copy with another version, preserving the
        original's added-date/art metadata.

        Strategy: the chosen version is found on YouTube (search + pick by the
        chosen artist/title identity), downloaded to the staging area under the
        SAME base_name, and only once it is fully staged is the old NAS file
        replaced in place (same directory, same basename). Keeping base_name
        unchanged means every playlist reference and the added_meta
        (added-date + album art) row stays valid, so the original metadata is
        preserved automatically. Returns {id} for job polling.
        """
        state = self.state
        body = self._body_json()
        if body is None:
            return self._error(400, "invalid JSON")
        bn = (body.get("base_name") or "").strip()
        v_artist = (body.get("version_artist") or "").strip()
        v_title = (body.get("version_title") or "").strip()
        if not bn or " - " not in bn:
            return self._error(400, "need base_name ('Artist - Title')")
        current = self._find_replace_target(self._me(), bn)
        if not current or not os.path.exists(current):
            return self._error(
                404, "original not found in library or playlists — "
                     "re-add the song first")
        nas_artist, nas_title = (x.strip() for x in bn.split(" - ", 1))
        v_artist = v_artist or nas_artist
        v_title = v_title or nas_title
        try:
            cands = state.scorer.search(v_artist, v_title)
        except Exception:                            # noqa: BLE001
            logger.exception("replace search failed")
            return self._error(502, "search failed")
        if not cands:
            return self._error(404, "no YouTube result for that version")
        scored, _ = state.scorer.pick(cands, [v_artist], v_title)
        if not scored:
            return self._error(502, "no trusted candidate for that version")
        # Honor the EXACT version the user tapped (explicit vs clean +
        # length). A plain artist/title re-search otherwise converges on
        # the same top pick every retry — e.g. reinstalling the censored
        # cut forever while the user asked for explicit.
        try:
            want_dur = body.get("version_duration")
            want_dur = int(want_dur) if want_dur else None
        except (TypeError, ValueError):
            want_dur = None
        want_explicit = body.get("version_explicit")
        if want_explicit is not True and want_explicit is not False:
            want_explicit = None
        # Title agreement FIRST (hard gate): same-artist/same-length
        # wrong songs (El trapecio installed as El temblor) sail through
        # every duration check. Refuse loudly instead of swapping in a
        # different song.
        want_t = self._norm_core(v_title)
        want_a = self._norm_core(v_artist)
        titled = [c for c in scored
                  if want_t and (want_t in self._norm_core(
                      str(c.get("title") or "")) or self._norm_core(
                      str(c.get("title") or "")) in want_t)
                  # Artist agreement: a same-title song by another artist
                  # (Kanye West's "Paranoid" picked for a Black Sabbath
                  # request) must never enter the download pool, no matter
                  # its views. Fan/tribute uploads of the RIGHT song still
                  # match via the artist name in their title/channel text.
                  and (not want_a or want_a in self._norm_core(
                      str(c.get("title") or "") + " " +
                      str(c.get("channel") or "") + " " +
                      str(c.get("uploader") or "")))]
        if not titled:
            return self._error(
                502, f'no upload titled like "{v_title}" — '
                     'kept the old copy')
        pool = titled
        if want_explicit is not None:
            def _tl(c):
                return str(c.get("title") or "").lower()
            _clean = ("clean", "censored", "radio edit", "radio version",
                      "edited", "kids bop", "kidz bop", "family friendly")
            _xpl = ("(explicit)", "[explicit]", "explicit version",
                    "(dirty)", "[dirty]")
            is_cut = lambda c: any(w in _tl(c) for w in _clean)  # noqa: E731
            is_xpl = lambda c: any(w in _tl(c) for w in _xpl)  # noqa: E731
            if want_explicit:
                # Drop uploads marked as clean edits, then PREFER uploads
                # that declare themselves explicit: an unmarked top pick
                # (e.g. a lyrics re-upload of the radio cut) otherwise wins
                # forever over the real explicit upload sitting at #2.
                uncut = [c for c in scored if not is_cut(c)]
                if uncut:
                    pool = uncut
                marked = [c for c in pool if is_xpl(c)]
                if marked:
                    pool = marked
            else:
                cut = [c for c in scored if is_cut(c)]
                if cut:
                    pool = cut
        if want_dur:
            pool = sorted(
                pool,
                key=lambda c: abs((c.get("duration_s") or want_dur)
                                  - want_dur))
            near = [c for c in pool
                    if c.get("duration_s")
                    and abs(c["duration_s"] - want_dur) <= 10]
            if near:
                pool = near
        vid = pool[0]["video_id"]
        # A reinstall of the exact video already swapped onto the NAS is a
        # no-op that still reports success (El Temblor installed bPSLIqo__vs
        # twice). Refuse loudly so a different version gets picked instead.
        # Only when that video is truly installed (status kept) — a failed
        # earlier attempt must stay retryable.
        try:
            _prev = state.db.find_download_by_base(bn) or {}
            prior = _prev.get("video_id") or ""
            prior_kept = (_prev.get("status") or "") == "kept"
        except Exception:                            # noqa: BLE001
            prior, prior_kept = "", False
        if prior and prior == vid and prior_kept:
            return self._error(
                409, "that exact video is already installed — "
                     "pick a different version")
        dest_dir = os.path.dirname(current)
        existing = state.db.find_download_by_base(bn)
        if existing:
            did = existing["id"]
            state.db.update_download(did, status="pending", path=None,
                                     keep_to=None, video_id=vid)
        else:
            did = state.db.create_download(nas_artist, nas_title)
        state.db.record_candidates(did, scored[:15])
        # Stash the tapped version's cover for the post-swap metadata
        # transfer (cover moves with the song automatically — same SSRF
        # guard as the meta import).
        img = body.get("version_image")
        if not (isinstance(img, str) and len(img) < 500
                and (img.startswith("https://")
                     or img.startswith("http://"))
                and "@" not in (urllib.parse.urlparse(img).netloc
                                or "")):
            img = None
        try:
            state.db.misc_put(f"replace_meta:{did}", {
                "artist": v_artist, "title": v_title, "image": img})
            # The exact version the user tapped: the monitor verifies the
            # staged file against THIS (not always the studio reference —
            # a deliberately picked live/extended cut must verify against
            # its own length). Absent = fall back to studio as before.
            if want_dur:
                state.db.misc_put(f"replace_want:{did}", want_dur)
        except Exception:                            # noqa: BLE001
            pass
        state.pipeline.start_redownload(did, vid)
        threading.Thread(target=self._replace_monitor, daemon=True,
                         args=(did, current, dest_dir,
                               self._me())).start()
        return self._json({"id": did, "video_id": vid})

    def _find_replace_target(self, user, base):
        """Full path of the playable original for [base], preferring the
        music library, then the requester's playlist copies. Staging
        leftovers are NEVER a target: swapping a staged file onto itself
        crashed the monitor (FileNotFoundError on self-move) and froze the
        job at 'verifying' forever — no toast, song unchanged, staged row
        lingering in Downloads asking where to save it."""
        fname = base + ".mp3"
        roots = []
        try:
            roots.append(self.state.config.music_root)
            if user == self.LEGACY_USER or not user:
                roots.append(self.state.config.playlist_dir)
            else:
                roots.append(self.state.users.user_playlists_dir(user))
        except Exception:                            # noqa: BLE001
            pass
        for root in roots:
            if not root or not os.path.isdir(root):
                continue
            for rpath, dirs, files in os.walk(root):
                dirs[:] = [d for d in dirs if d != "_Staging"
                           and d != ".git" and not d.startswith(".")]
                if fname in files:
                    return os.path.join(rpath, fname)
        return None

    def _owner_playlists_with(self, user, base):
        """[(playlist_key, m3u)] for the owner's playlists containing
        [base] (matched by filename stem, like the checker scope)."""
        out = []
        try:
            if user == self.LEGACY_USER or not user:
                lists = self.state.playlist_paths()
                keyed = [(self._am_key(self.LEGACY_USER, n), m)
                         for n, m in lists]
            else:
                d = self.state.users.user_playlists_dir(user)
                keyed = []
                for root, dirs, files in os.walk(d):
                    dirs[:] = [x for x in dirs if not x.startswith(".")]
                    for f in sorted(files):
                        if f.endswith(".m3u"):
                            keyed.append(
                                (self._am_key(user, f[:-4]),
                                 os.path.join(root, f)))
        except Exception:                            # noqa: BLE001
            return []
        for key, m3u in keyed:
            try:
                with open(m3u, encoding="utf-8", errors="replace") as fh:
                    for ln in fh:
                        s = ln.strip()
                        if not s or s.startswith("#"):
                            continue
                        if os.path.splitext(
                                os.path.basename(s))[0] == base:
                            out.append((key, m3u))
                            break
            except OSError:
                pass
        return out

    def _transfer_swap_meta(self, base, dest, v_artist, v_title, img, user):
        """Auto-transfer metadata onto a swapped-in file — cover, identity
        and added-dates move with the song, nothing to re-save by hand.

        Merge-only, never clobbers: existing artist/album/art/dates win
        unless the swap brought something they lack. Best-effort throughout
        (a meta failure must never fail the audio swap)."""
        state = self.state
        try:
            old = state.db.song_meta_get(base) or {}
            state.db.song_meta_put(
                base,
                v_artist or old.get("artist"),
                old.get("album"),
                old.get("album_artist") or v_artist or old.get("artist"),
                img or old.get("album_image"),
            )
        except Exception:                            # noqa: BLE001
            pass
        try:
            for plkey, _m3u in self._owner_playlists_with(user, base):
                meta = state.db.added_meta_get(plkey, base)
                if meta:
                    if img and not meta.get("album_image"):
                        state.db.set_added_meta(plkey, base,
                                                meta.get("added_at"), img)
                else:
                    try:
                        ts = os.path.getmtime(dest)
                    except OSError:
                        ts = time.time()
                    state.db.set_added_meta(plkey, base, ts, img)
        except Exception:                            # noqa: BLE001
            pass

    def _sync_playlist_copies(self, base, src_file, user):
        """Overwrite same-basename favorited COPIES with the fresh swap.

        The checker + swap target the LIBRARY file, but playlists usually
        hold their own copies (kept files are moved into the playlist
        dir). Without this the playlist keeps serving the old audio
        (e.g. the censored version) after a successful replace. Only the
        requesting owner's playlist trees are touched; same-named files
        inside the music library are distinct songs and are never
        overwritten. Returns the number of copies synced."""
        import shutil
        count = 0
        seen = set()
        try:
            if user == self.LEGACY_USER or not user:
                dirs = [self.state.config.playlist_dir]
            else:
                dirs = [self.state.users.user_playlists_dir(user)]
        except Exception:                            # noqa: BLE001
            return 0
        for d in dirs:
            if not d or not os.path.isdir(d):
                continue
            for rpath, _ds, files in os.walk(d):
                if os.path.basename(rpath).startswith("."):
                    continue
                for fn in files:
                    if fn != f"{base}.mp3":
                        continue
                    p = os.path.join(rpath, fn)
                    if os.path.abspath(p) == os.path.abspath(src_file):
                        continue
                    if p in seen:
                        continue
                    seen.add(p)
                    try:
                        shutil.copyfile(src_file, p)
                        count += 1
                    except OSError:
                        pass
        return count

    # One monitor per replace job: retrying the same song starts a second
    # monitor while the first still loops — without the claim the loser
    # would re-verify the already-swapped file and flip kept→failed.
    _replace_claims = set()
    _replace_claims_lock = threading.Lock()

    def _replace_monitor(self, did, old_path, dest_dir, user=None):
        claims = type(self)._replace_claims
        with type(self)._replace_claims_lock:
            if did in claims:
                return
            claims.add(did)
        try:
            self._replace_monitor_guarded(did, old_path, dest_dir, user)
        finally:
            with type(self)._replace_claims_lock:
                claims.discard(did)

    def _replace_monitor_guarded(self, did, old_path, dest_dir, user=None):
        """After the replacement is staged (fully downloaded), verify the
        staged file's duration matches the studio reference, then swap it
        into the old NAS slot (same directory, same basename). If duration
        doesn't match, refuse to swap — the old file stays untouched."""
        import shutil
        from .scorer import ffprobe_duration
        state = self.state
        try:
            for _ in range(900):                     # ~15 min max
                row = state.db.get_download(did)
                if not row:
                    return
                status = row.get("status")
                if status == "staged":
                    base = row["base_name"]
                    # Live phase for the app's progress banner (visible in
                    # /api/jobs with the failure reason on error, and in
                    # /api/downloads as the row status).
                    state.pipeline._set_phase(did, "verifying")
                    src = os.path.join(state.config.staging_dir,
                                       f"{base}.mp3")
                    if not os.path.exists(src):
                        state.pipeline._set_phase(
                            did, "failed",
                            error="staged file missing — kept the old copy")
                        state.db.event("replace_failed",
                                       {"id": did, "base": base,
                                        "error": "staged file missing"})
                        return
                    artists, title = (x.strip()
                                     for x in base.split(" - ", 1))
                    # Verify against the version the user actually tapped
                    # (a deliberate live/extended pick verifies against its
                    # own length); fall back to the studio reference.
                    want = state.db.misc_get(f"replace_want:{did}", 86400)
                    try:
                        want = float(want) if want else None
                    except (TypeError, ValueError):
                        want = None
                    expected = want or state.scorer.deezer_duration(
                        base, artists, title)
                    what = "picked version" if want else "studio"
                    got = (state.db.duration_get(
                               src, os.path.getsize(src))
                           or ffprobe_duration(src))
                    # Proportional tolerance: a fixed ±8s is fine for a
                    # 3-minute song but refuses legitimate masters of
                    # longer songs (10s on 4.5min = 3.7% — silence,
                    # encoder padding, a different master). Scale with
                    # length, floor 8s: wrong-song swaps (usually minutes
                    # apart) still refuse loudly.
                    tol = max(8.0, 0.05 * expected) if expected else 0
                    if expected and got and abs(got - expected) > tol:
                        err = (f"staged {got:.0f}s vs {what} "
                               f"{expected:.0f}s — kept the old copy")
                        state.pipeline._set_phase(did, "failed", error=err)
                        state.db.event(
                            "replace_failed",
                            {"id": did, "base": base, "error": err})
                        return
                    # Audio-identity gate (2026-09-20): a mislabeled upload
                    # ("El temblor" video whose audio is El trapecio) passes
                    # every duration/title check. Fingerprint the staged
                    # bytes and refuse the swap when the audio is
                    # confidently another song. Best-effort: no key / no
                    # match never blocks a replace.
                    if state.config.acoustid_api_key:
                        try:
                            real = self._identify_song(base, src)
                        except Exception:            # noqa: BLE001
                            real = {"error": "identify crashed"}
                        if (isinstance(real, dict) and real.get("title")
                                and not real.get("error")):
                            probe = {}
                            self._attach_identity(
                                probe, real, artists, title)
                            if probe.get("mismatch"):
                                err = (
                                    f'downloaded audio is '
                                    f'"{real.get("artist")} - '
                                    f'{real.get("title")}" — kept the '
                                    f'old copy')
                                state.pipeline._set_phase(
                                    did, "failed", error=err)
                                state.db.event(
                                    "replace_failed",
                                    {"id": did, "base": base,
                                     "error": err})
                                return
                    dest = os.path.join(dest_dir, f"{base}.mp3")
                    if os.path.exists(dest):
                        os.remove(dest)
                    shutil.move(src, dest)
                    copies = self._sync_playlist_copies(base, dest, user)
                    try:
                        want = state.db.misc_get(
                            f"replace_meta:{did}", 30 * 86400) or {}
                    except Exception:                # noqa: BLE001
                        want = {}
                    self._transfer_swap_meta(
                        base, dest, want.get("artist"), want.get("title"),
                        want.get("image"), user)
                    state.db.update_download(did, status="kept", path=dest,
                                             keep_to=None)
                    try:
                        with state._index_lock:
                            state._index_cache = None
                    except Exception:                # noqa: BLE001
                        pass
                    state.db.event(
                        "replaced",
                        {"id": did, "base": base, "to": dest,
                         "copies": copies,
                         "meta": bool(want.get("image"))})
                    return
                if status in ("failed", "giveup", "no_results",
                              "no_official", "deleted", "expired"):
                    state.db.update_download(did, keep_to=None)
                    return
                time.sleep(1)
        except Exception as e:                       # noqa: BLE001
            logger.exception("replace monitor failed")
            # Never freeze at 'verifying': surface the failure with its
            # reason so the app reports it instead of timing out silent.
            try:
                state.pipeline._set_phase(
                    did, "failed",
                    error=(str(e)[-200:] or "swap failed")
                    + " — old copy kept")
            except Exception:                        # noqa: BLE001
                pass
            try:
                state.db.update_download(did, keep_to=None)
            except Exception:                        # noqa: BLE001
                pass

    # ------------------------------------------------ check lyrics (13)
    # Like the song-integrity checker, but verifies each NAS song has lyrics
    # that actually belong to it. Flags: ok / none (no lyrics found) /
    # mismatch (provider returned a different song's lyrics). Same
    # progress-snapshot + single-background-scan pattern as check songs.
    _lyrics_lock = threading.Lock()
    _lyrics_progress = None

    @staticmethod
    def _lyr_norm(s):
        s = s or ""
        s = s.lower()
        s = re.sub(r"[\[\(].*?[\]\)]", " ", s)
        s = re.sub(r"\b(ft\.?|feat(?:\.|uring)?|featuring)\b[^,]*,?", " ", s)
        return re.sub(r"[^a-z0-9]+", "", s)

    def _lyrics_check_snapshot(self):
        snap = type(self)._lyrics_progress
        return {
            "running": bool(snap and snap.get("running")),
            "scanned": snap.get("scanned", 0) if snap else 0,
            "total": snap.get("total", 0) if snap else 0,
            "done": bool(snap and snap.get("done")),
            "reports": (snap or {}).get("reports", []),
            "scope": (snap or {}).get("scope", "library"),
        }

    def _check_lyrics(self, scope=None, poll=False):
        scope = (scope or "library").strip() or "library"
        snap = type(self)._lyrics_progress
        if not poll and (snap is None or snap.get("done")
                or snap.get("scope") != scope):
            if type(self)._lyrics_lock.acquire(blocking=False):
                try:
                    snap = type(self)._lyrics_progress
                    if snap is None or snap.get("done") \
                            or snap.get("scope") != scope:
                        type(self)._lyrics_progress = {
                            "running": True, "scanned": 0, "total": 0,
                            "reports": [], "done": False,
                            "scope": scope}
                        threading.Thread(
                            target=self._check_lyrics_worker,
                            args=(scope,), daemon=True).start()
                finally:
                    type(self)._lyrics_lock.release()
        return self._lyrics_check_snapshot()

    def _check_lyrics_worker(self, scope="library"):
        from .lyrics import fetch_lyrics
        reports = []
        try:
            items = self._check_scope_items(
                scope, getattr(self, "_auth_user", None))
            for bn, full in items:
                prog = type(self)._lyrics_progress or {}
                prog["scanned"] = prog.get("scanned", 0) + 1
                prog["total"] = len(items)
                rep = self._lyrics_check_one(bn, full)
                if rep is not None:
                    reports.append(rep)
                type(self)._lyrics_progress = {
                    "running": True, "scanned": prog["scanned"],
                    "total": prog["total"], "reports": list(reports),
                    "done": False, "scope": scope}
        except Exception:                            # noqa: BLE001
            logger.exception("lyrics check scan failed")
        finally:
            prog = type(self)._lyrics_progress or {}
            type(self)._lyrics_progress = {
                "running": False, "scanned": prog.get("scanned", 0),
                "total": prog.get("total", 0),
                "reports": list(reports), "done": True,
                "scope": scope}

    def _lyrics_check_one(self, base_name, full):
        from .lyrics import fetch_lyrics, split_base
        artist, title = split_base(base_name)
        if not title:
            return None
        # bundled lyrics win; check them first
        raw = self.state.lyrics_bundle.get(base_name) \
            if isinstance(getattr(self.state, "lyrics_bundle", None), dict) \
            else None
        if raw:
            return {"base_name": base_name, "status": "ok",
                    "source": "bundle"}
        # provider lookup (cached, best-effort)
        res = None
        try:
            res = fetch_lyrics(base_name)
        except Exception:                            # noqa: BLE001
            return {"base_name": base_name, "status": "error",
                    "source": None, "reason": "lookup failed"}
        if not res:
            return {"base_name": base_name, "status": "none",
                    "source": None}
        their_title = res.get("title")
        their_artist = res.get("artist")
        good = True
        if title and their_title:
            good = self._lyr_norm(their_title) == self._lyr_norm(title)
        if good and artist and their_artist:
            def _tok(s):
                return {self._lyr_norm(p)
                        for p in re.split(r"[,&+]", s or "") if self._lyr_norm(p)}
            good = bool(_tok(their_artist) & _tok(artist))
        status = "ok" if good else "mismatch"
        return {"base_name": base_name, "status": status,
                "source": res.get("source"),
                "their_title": their_title, "their_artist": their_artist}

    def _all_songs_by_artist(self, artist):
        """Every track by [artist]: local files plus bundled career rows."""
        norm = self._norm
        targets = {norm(a) for a in self._split_artists(artist)}
        targets = {t for t in targets if t}
        idx = self._local_files_map()
        entries = []
        seen = set()

        def fits(meta_artist, meta_aa, lead):
            for cand in (meta_artist, meta_aa, lead):
                if not cand:
                    continue
                for t in self._split_artists(cand):
                    if norm(t) in targets:
                        return True
            return False

        for bn, full in idx.items():
            if not self._lib_visible(bn, self._me()):
                continue
            lead = bn.split(" - ", 1)[0].strip() if " - " in bn else bn
            meta = self.state.db.song_meta_get(bn)
            if not fits((meta or {}).get("artist"),
                        (meta or {}).get("album_artist"), lead):
                continue
            entries.append(self._song_dict(bn, full))
            seen.add(bn)
        for m in self.state.db.query("SELECT * FROM song_meta"):
            bn = m["base_name"]
            if bn in seen:
                continue
            lead = bn.split(" - ", 1)[0].strip() if " - " in bn else bn
            if not fits(m.get("artist"), m.get("album_artist"), lead):
                continue
            seen.add(bn)
            entries.append(self._song_dict(bn, idx.get(bn)))
        entries.sort(key=lambda x: x["base_name"].lower())
        return entries

    def _deezer_discography(self, artist):
        key = "dz:albums:v2:" + self._norm(artist)
        got = self.state.db.misc_get(key, 7 * 86400)
        if got:
            return got
        out = self.state.scorer.deezer_artist_albums(artist) or []
        if out:
            self.state.db.misc_put(key, out)
        return out

    def _deezer_album_tracks_cached(self, artist, album, album_id=None):
        key = ("dz:tracklist:" + self._norm(artist)
               + "\x00" + self._norm(album)
               + ("\x00" + str(album_id) if album_id else ""))
        got = self.state.db.misc_get(key, 7 * 86400)
        if got is not None:
            return got
        out = (self.state.scorer.deezer_album_tracks_by_id(album_id)
               if album_id
               else self.state.scorer.deezer_album_tracks(artist, album)) or []
        self.state.db.misc_put(key, out)
        return out

    def _deezer_cover_cached(self, base_name):
        """Deezer cover_big for one 'Artist - Title', cached 7 days
        (dz:cover:). Misses negative-cache as '' so they don't refetch."""
        key = "dz:cover:" + self._norm(base_name or "")
        got = self.state.db.misc_get(key, 7 * 86400)
        if got is not None:
            return got or None
        try:
            cover = self.state.scorer._deezer_cover(base_name) or ""
        except Exception:                               # noqa: BLE001
            cover = ""
        try:
            self.state.db.misc_put(key, cover)
        except Exception:                               # noqa: BLE001
            pass
        return cover or None

    def _deezer_album_cached(self, base_name):
        """Deezer album title for one 'Artist - Title', cached 7 days
        (dz:album:). Misses negative-cache as '' so they don't refetch."""
        key = "dz:album:" + self._norm(base_name or "")
        got = self.state.db.misc_get(key, 7 * 86400)
        if got is not None:
            return got or None
        try:
            album = self.state.scorer._deezer_album(base_name) or ""
        except Exception:                               # noqa: BLE001
            album = ""
        try:
            self.state.db.misc_put(key, album)
        except Exception:                               # noqa: BLE001
            pass
        return album or None

    def _spotify_album_image_cached(self, artist, album):
        """Spotify album cover, cached 7 days. Returns image URL or None."""
        key = "sa:img:" + self._norm(artist) + "\x00" + self._norm(album)
        got = self.state.db.misc_get(key, 7 * 86400)
        if got is not None:
            return got
        pic = self.state.scorer.spotify_album_image(artist, album)
        self.state.db.misc_put(key, pic)
        return pic

    @staticmethod
    def _is_live(text):
        """Heuristic: is this a live/concert recording title?"""
        t = (text or "").lower()
        # "Live - Lightning Crashes": here "Live" is the ARTIST name in the
        # concatenated "Artist - Title" display form, NOT a live-recording
        # marker. Drop that leading artist token before judging the song.
        m = re.match(r"^live\s+-\s+(.*)$", t)
        if m and m.group(1).strip():
            t = m.group(1)
        if re.search(r"\blive\b|\bconcert\b| \(live\)| at \w+\s*\d{4}"
                     r"| live \d|^\s*live\b", t):
            return True
        for k in ("unplugged", "mtv", "live at", "live in", "live from",
                  "live session", "radio city", "at the apollo", "wembley",
                  "talking to", "(live)", "en concert", "en direct"):
            if k in t:
                return True
        return False

    @staticmethod
    def _is_live_album(d):
        """Is this discography album a live recording (title + Deezer flag)?"""
        rt = (d.get("record_type") or "").lower()
        if rt == "live":
            return True
        if rt in ("single", "ep") and any(
                k in (d.get("album") or "").lower()
                for k in ("live", "concert", "unplugged")):
            return True
        return False

    @staticmethod
    def _is_blank_art_url(url):
        """Deezer "no image" placeholder URLs (empty-content hash or the
        /artist//250x250-000000-80-0-0.jpg suffix)."""
        if not url:
            return True
        return ("/d41d8cd98f00b204e9800998ecf8427e/" in url
                or url.endswith("/artist//250x250-000000-80-0-0.jpg"))

    @staticmethod
    def _album_core(title):
        """Invariant key for an album across edition variants: strips
        parentheticals + edition words (deluxe/remaster/box set/anniversary/
        collector/mix) + trailing years so 'A Night At The Opera (2011
        Remaster)' and 'A Night At The Opera (Deluxe Edition)' fold into ONE
        row. Queen's 2024 rerelease of the debut is 'Queen I (2024 Mix)' ->
        still 'queen'."""
        t = re.sub(r"[\(\[].*?[\)\]]", " ", title or "")
        t = re.sub(r"\b(remaster(?:ed)?|deluxe|bonus|box\s*set|anniversary|"
                   r"expanded|collector|mix(?:es)?|edition|reissue|version)\b",
                   " ", t, flags=re.I)
        t = re.sub(r"\s+", " ", t).strip().lower()
        # A standalone year in a variant title is a reissue marker
        # ("Queen I 2024 Mix"), but an album literally titled "1984" must not
        # collapse to an empty core, so only strip years when something
        # remains.
        short = re.sub(r"\s*(?:19|20)\d{2}\s*", " ", " " + t + " ")
        short = re.sub(r"\s+", " ", short).strip()
        if short:
            t = short
        if t == "queen i":
            t = "queen"
        return t

    @staticmethod
    def _clean_album_title(title):
        """Display title: strip edition-only parentheticals and trailing
        ' - Deluxe Edition' style suffixes, but KEEP meaningful ones like
        '(What's The Story)'."""

        def _ed(m):
            s = m.group(0).lstrip("([").rstrip(")]").lower()
            if any(w in s for w in ("remaster", "deluxe", "bonus", "box",
                                    "anniversary", "expanded", "collector",
                                    "mix", "edition", "reissue", "version",
                                    "digital", "limited")):
                return " "
            return m.group(0)

        t = re.sub(r"[\(\[][^\(\)\[]*?[\)\]]", _ed, title or "")
        t = re.sub(r"\s*[-,]\s*(?:remaster(?:ed)?|deluxe|bonus|anniversary|"
                   r"expanded|collector['']?s?\s*edition|edition|reissue|"
                   r"version).*$", "", t, flags=re.I)
        t = re.sub(r"\s+", " ", t).strip()
        return t if t else (title or "")

    @staticmethod
    def _studio_album_row(cleaned_title):
        """Is a cleaned album title OK to show as a studio-album row? Drops
        local compilations (Greatest Hits, box sets, various-artist samplers)
        whose tracks still appear under the page's songs list."""
        t = (cleaned_title or "").strip().lower()
        if not t:
            return False
        markers = ("greatest hits", "best of", "collection", "platinum",
                   "box set", "boxset", "compilation", "b-sides",
                   "the singles", "demos", "demo ", "deep cuts", "classic rock",
                   "essential", "karaoke", "instrumental", "rehearsal",
                   "acoustic session", "tribute", "forever", "the very best")
        if re.search(r"\b(live|concert|unplugged|mtv|wembley|apollo|"
                     r"radio city|odeon|montreal|champions|fire fight|"
                     r"budapest|rainbow|on air)\b", t):
            return False
        return not any(k in t for k in markers)

    def _studio_disc_ok(self, d):
        """Deezer discography entry OK as a STUDIO album? Drops singles/EPs,
        live/concert titles, soundtracks (except Queen's Flash Gordon), recent
        single-word genre-compilation boxes (Queen Resurrection 2024-26), and
        older greatest-hits/compilation re-releases."""
        dtype = (d.get("type") or "").lower()
        if dtype in ("single", "ep", "live"):
            return False
        title = (d.get("album") or "").strip()
        if not title:
            return False
        lt = title.lower()
        live = ("live", "concert", "unplugged", "mtv", "wembley", "apollo",
                "radio city", "odeon", "montreal", "champions", "fire fight",
                "budapest", "rainbow", "on air", "killers", "en concert",
"en direct", "at the bowl")
        if any(re.search(r"\b" + re.escape(k) + r"\b", lt) for k in live):
            return False
        comp = ("greatest hits", "best of", "collection", "platinum",
                "box set", "boxset", "compilation", "b-sides", "the singles",
                "demos", "demo ", "deep cuts", "essential", "karaoke",
                "instrumental", "rehearsal", "acoustic session", "tribute",
                "an evening with", "symphonic", "soundtrack")
        for k in comp:
            if k in lt:
                if k == "soundtrack" and "flash gordon" in lt:
                    continue
                return False
        # "X Forever" is almost always a hits compilation (Queen Forever,
        # Mariah's Greatest Hits "Forever" style); but a bare album literally
        # titled "Forever" (Kool & the Gang, Spice Girls) is a real studio
        # record, so only drop when the title has OTHER words too.
        if "forever" in lt and len(lt.strip().split()) > 1:
            return False
        # 2024-26 single-word genre compilations (Queen Resurrection series:
        # Acoustic/Anthems/Ballads/B-Sides/Epic/Funk/Heavy/Pop/Riffs/Rock N
        # Roll/Slightly Mad) -> not studio albums.
        m = re.match(r"^([a-z0-9' ]{1,40})$", lt.strip())
        if m:
            year = d.get("year")
            if year and year.isdigit() and int(year) >= 2024:
                word = lt.strip()
                if word in ("acoustic", "anthems", "ballads", "b-sides",
                            "epic", "funk", "heavy", "pop", "riffs",
                            "rock n roll", "slightly mad", "greatest"):
                    return False
        return True

    def _artist_disc_songs(self, name, disc, songs, fetch=False):
        """Merge Deezer FULL discography tracks into the songs list (not
        albums-only). Each track carries owned=True/False; owned rows keep
        their local url, the rest resolve via resolvename on tap."""
        for s in songs:
            s["owned"] = True
        seen = {(self._norm_core(s.get("artist") or ""),
                 self._norm_core(s.get("title") or s.get("base_name") or ""))
                for s in songs}
        local_idx = self._local_files_map()
        done_keys = set()

        def _add(t, alb, aa, fallback_img=None):
            base = (t.get("base_name") or "").strip()
            ti = (t.get("title") or
                  (base.split(" - ", 1)[1] if " - " in base else base)
                  or "").strip()
            ar = (t.get("artist") or
                  (base.split(" - ", 1)[0] if " - " in base else "")
                  or aa).strip()
            if not ti or self._is_live(ti) or self._is_live(base):
                return
            ck = (self._norm_core(ar), self._norm_core(ti))
            if ck in seen:
                return
            seen.add(ck)
            bn = base or f"{ar} - {ti}"
            full = local_idx.get(bn)
            if full is not None and not self._lib_visible(bn, self._me()):
                full = None
            owned = full is not None or (
                self._innas_lenient(ar, ti) is not None)
            if full is None and owned:
                hit = self._innas_lenient(ar, ti)
                full = local_idx.get(hit) if hit else None
                if hit:
                    bn = hit
            songs.append({
                "base_name": bn, "path": full,
                "exists": owned and full is not None,
                "url": self._entry_url(full) if full else None,
                "title": ti, "artist": ar,
                "album": t.get("album") or alb,
                "album_artist": aa,
                "album_image": t.get("album_image") or fallback_img,
                "duration_s": t.get("duration_s"),
                "owned": bool(owned), "provider": "Deezer",
                "kind": "virtual" if not owned else "local",
            })

        for d in disc or []:
            alb = (d.get("album") or "").strip()
            if not alb:
                continue
            aa = (d.get("album_artist") or name).strip() or name
            key = ("dz:tracklist:" + self._norm(aa)
                   + "\x00" + self._norm(alb)
                   + ("\x00" + str(d.get("album_id"))
                      if d.get("album_id") else ""))
            done_keys.add(key)
            tl = self.state.db.misc_get(key, 7 * 86400)
            if tl is None and fetch:
                try:
                    tl = self._deezer_album_tracks_cached(
                        aa, alb, album_id=d.get("album_id")) or []
                except Exception:                     # noqa: BLE001
                    continue
            for t in tl or []:
                _add(t, alb, aa, d.get("image"))
        # Cache-only sweep: every already-cached tracklist for this artist
        # merges too — even when the discography itself isn't cached (or
        # lists different editions), so the fast page shows career tracks
        # instantly instead of owned-only. Never hits network; missing
        # sections still report pending + hydrate in the background.
        try:
            prefix = "dz:tracklist:" + self._norm(name) + "\x00"
            rows = self.state.db.query(
                "SELECT key FROM webcache WHERE key LIKE ?",
                (prefix + "%",))
        except Exception:                             # noqa: BLE001
            rows = []
        for r in rows or []:
            key = r["key"] if isinstance(r, dict) else r[0]
            if key in done_keys:
                continue
            done_keys.add(key)
            tl = self.state.db.misc_get(key, 7 * 86400)
            for t in tl or []:
                _add(t, t.get("album") or "",
                     (t.get("artist") or "").strip() or name)
        songs.sort(key=lambda x: (not x.get("owned", True),
                                  (x.get("base_name") or "").lower()))
        return songs

    def _merge_albums(self, name, songs, disc):
        """Merge local NAS album rows with the Deezer studio discography into
        ONE row per core album title. Local tracks fold into their matching
        studio album (owned count kept); remaster/deluxe/mix variants collapse.
        Returns (albums dict keyed by core, singles list)."""
        norm = self._norm
        albums = {}
        singles = []
        for s in songs:
            alb = (s.get("album") or "").strip()
            aa = (s.get("album_artist") or "").strip()
            if not alb:
                singles.append(s)
                continue
            core = self._album_core(alb)
            if not self._studio_album_row(self._clean_album_title(alb)):
                continue
            g = albums.setdefault(core, {
                "album": alb, "album_artist": aa,
                "image": s["album_image"], "tracks": 0, "owned": 0,
                "year": None, "source": "library", "type": "album",
                "album_id": None})
            if not g["image"]:
                g["image"] = s["album_image"]
            g["tracks"] += 1
            g["owned"] += 1
            if aa and not g["album_artist"]:
                g["album_artist"] = aa
            cand = self._clean_album_title(alb)
            if len(cand) < len(g["album"]):
                g["album"] = cand
        for d in disc or []:
            if not self._studio_disc_ok(d):
                continue
            dname = (d.get("album") or "").strip()
            core = self._album_core(dname)
            owned = sum(1 for sng in songs
                        if sng.get("album")
                        and self._album_core(sng.get("album")) == core)
            g = albums.get(core)
            if g is not None:
                if d.get("album_id"):
                    g["album_id"] = d["album_id"]
                if d.get("tracks"):
                    g["tracks"] = d["tracks"]
                g["owned"] = owned
                if not g["year"]:
                    g["year"] = d.get("year")
                if not g["image"]:
                    g["image"] = d.get("image")
                cand = self._clean_album_title(dname)
                if len(cand) < len(g["album"]):
                    g["album"] = cand
            else:
                albums[core] = {
                    "album": self._clean_album_title(dname) or dname,
                    "album_artist": (d.get("album_artist") or name).strip(),
                    "image": d.get("image"),
                    "tracks": d.get("tracks") or 0,
                    "owned": owned,
                    "year": d.get("year"),
                    "source": "online",
                    "album_id": d.get("album_id"),
                    "type": "album",
                }
        return albums, singles

    def _artist(self, name):
        """Artist page, CACHE-FIRST: local songs + every already-cached part
        (Deezer discography, album tracklists, artist photo) are returned
        INSTANTLY; any section that isn't cached yet is listed in "pending"
        and hydrated in ONE shared background job. The app repolls /api/artist
        and gets the complete page as soon as the caches are warmed."""
        if not name or len(name) > 200:
            return self._error(400, "bad artist")
        norm = self._norm
        state = self.state
        songs = [s for s in self._all_songs_by_artist(name)
                 if not self._is_live(s.get("title") or "")
                 and not self._is_live(s.get("base_name") or "")]
        pending = []
        # Deezer discography (cached? else pending). An EMPTY cache row
        # (earlier fetch found nothing) counts as missing too, so the
        # background hydrate refetches instead of serving 2 songs forever.
        disc = state.db.misc_get("dz:albums:v2:" + norm(name), 7 * 86400)
        if not disc:
            disc = []
            pending.append("discography")
        albums, singles = self._merge_albums(name, songs, disc)
        songs = self._artist_disc_songs(name, disc, songs)

        def _bf_key(g):
            return ("dz:tracklist:" + norm(g.get("album_artist") or name)
                    + "\x00" + norm(g["album"])
                    + ("\x00" + str(g.get("album_id"))
                       if g.get("album_id") else ""))

        def _needs_bf(g):
            if g["source"] == "library":
                return g.get("tracks", 0) == g.get("owned", 0)
            return g.get("tracks", 0) <= 0

        # Album track-count backfills: only apply ones already cached; the
        # rest stay pending so the first page render never waits on network.
        for g in albums.values():
            if not _needs_bf(g):
                continue
            tl = state.db.misc_get(_bf_key(g), 7 * 86400)
            if tl is None:
                pending.append("tracklists")
                continue
            if tl:
                g["tracks"] = len(tl)
                if not g["image"] and any(t.get("album_image") for t in tl):
                    g["image"] = next(
                        (t["album_image"] for t in tl
                         if t.get("album_image")), g["image"])
        photo = state.db.misc_get("ap:" + norm(name), 7 * 86400)
        if photo is None or self._is_blank_art_url(photo):
            photo = None
            pending.append("photo")
        if pending:
            self._artist_hydrate_start(name)
        albums_list = sorted(
            albums.values(),
            key=lambda x: (x["source"] == "online", x["album"].lower()))
        # Every visit (cached or cold) re-warms the stream URL cache for the
        # page's top albums in the background, so tapping a song stays instant.
        # Uses only already-cached tracklists — never triggers network.
        self._prewarm_artist_streams(name, albums_list)
        return self._json({
            "name": name,
            "songs": songs,
            "albums": albums_list,
            "singles": singles,
            "photo": photo,
            "pending": pending,
        })

    def _artist_hydrate_start(self, name):
        """Dedupe + spawn ONE background job that hydrates the missing artist
        sections (Deezer discography, album tracklists, photo) so they land in
        the 7-day cache. The app's re-poll of /api/artist then serves the
        complete page instantly."""
        key = self._norm(name)
        with type(self)._artist_hydrating_lock:
            if key in type(self)._artist_hydrating:
                return
            type(self)._artist_hydrating.add(key)
        threading.Thread(target=self._artist_hydrate,
                         args=(name, key), daemon=True).start()

    def _artist_hydrate(self, name, key):
        try:
            self._compose_artist_full(name)
        except Exception:                               # noqa: BLE001
            logger.exception("artist hydrate failed for %s", name)
        finally:
            with type(self)._artist_hydrating_lock:
                type(self)._artist_hydrating.discard(key)

    def _compose_artist_full(self, name):
        """The FULL artist page compose, used only by the background hydrate
        job: it runs any network fetches (Deezer discography, album tracklists,
        photo) that the cache-first `_artist` deliberately skips, and lets the
        7-day caches soak them up."""
        norm = self._norm
        songs = [s for s in self._all_songs_by_artist(name)
                 if not self._is_live(s.get("title") or "")
                 and not self._is_live(s.get("base_name") or "")]
        # Deezer discography completes the career AND backfills the true total
        # track count on NAS-owned albums (NAS takes priority for existence).
        _disc = self._deezer_discography(name)
        albums, singles = self._merge_albums(name, songs, _disc)
        songs = self._artist_disc_songs(name, _disc, songs, fetch=True)
        # For any LOCAL album still showing only the NAS-owned count (i.e. the
        # Deezer discography above didn't cover it), try to fetch the album's
        # real total so "owned/total" is accurate. Cached, so this only costs a
        # network call once per album. Also backfills online-only albums whose
        # discography returned no track count, so the artist tile never shows
        # "0/0" while the album page shows the real number.
        # Fetched in PARALLEL so a fresh artist page isn't held up by many
        # sequential Deezer calls (big speed win on first visit).
        import concurrent.futures

        def _needs_bf(g):
            if g["source"] == "library":
                return g.get("tracks", 0) == g.get("owned", 0)
            return g.get("tracks", 0) <= 0

        def _fetch(g):
            return self._deezer_album_tracks_cached(
                g.get("album_artist") or name, g["album"],
                album_id=g.get("album_id"))

        to_bf = [g for g in albums.values() if _needs_bf(g)]
        if to_bf:
            with concurrent.futures.ThreadPoolExecutor(
                    max_workers=min(8, len(to_bf))) as ex:
                futures = {ex.submit(_fetch, g): g for g in to_bf}
                for fut in concurrent.futures.as_completed(futures):
                    g = futures[fut]
                    try:
                        tl = fut.result() or []
                    except Exception:                       # noqa: BLE001
                        continue
                    if not tl:
                        continue
                    if g["source"] == "library":
                        g["tracks"] = len(tl)
                    else:
                        g["tracks"] = len(tl)
                    if not g["image"] and any(t.get("album_image")
                                              for t in tl):
                        g["image"] = next(
                            (t["album_image"] for t in tl
                             if t.get("album_image")), g["image"])
        albums_list = sorted(
            albums.values(),
            key=lambda x: (x["source"] == "online", x["album"].lower()))
        # Warm the streaming cache (resolvename, 14-day) for the top few albums'
        # online tracks in the background, so tapping a song on the artist page
        # (or one of these albums' pages) starts instantly instead of waiting on
        # a cold YouTube search + yt-dlp per track. `_prewarm_resolvename`
        # dedupes against running jobs + the cache, so this stays cheap. Runs
        # inside the hydrate worker, so fetching missing tracklists is fine.
        self._prewarm_artist_streams(name, albums_list, fetch_if_missing=True)
        # NOTE: must NOT call self._json() here. This method runs inside
        # background hydration threads (via _artist_hydrate); writing a
        # response from a background thread corrupts the request's socket
        # stream (the caller — /api/search — sees trailing HTTP responses).
        return {
            "name": name,
            "songs": songs,
            "albums": albums_list,
            "singles": singles,
            "photo": self._artist_photo(name),
            "pending": [],
        }

    def _prewarm_artist_streams(self, name, albums_list, fetch_if_missing=False):
        """Best-effort background prewarm of the resolvename (stream URL)
        14-day cache for the artist page's top few albums' tracks. Runs in a
        daemon thread; dedupes against running resolve jobs. When the hydrate
        job calls this it may fetch tracklists it needs anyway
        (fetch_if_missing); the responsive fast path uses only already-cached
        tracklists so a page visit NEVER triggers network in-line."""
        def _go():
            try:
                # Only online-source albums need stream URLs: owned library
                # tracks resolve to local files, so prewarming them is wasted
                # work. Warm the internet discography first and more broadly.
                warmed = 0
                online = [g for g in albums_list
                          if g.get("source") == "online"]
                for g in online:
                    if warmed >= 6:
                        break
                    key = ("dz:tracklist:"
                           + self._norm(g.get("album_artist") or name)
                           + "\x00" + self._norm(g["album"])
                           + ("\x00" + str(g.get("album_id"))
                              if g.get("album_id") else ""))
                    tl = self.state.db.misc_get(key, 7 * 86400)
                    if tl is None and fetch_if_missing:
                        try:
                            tl = self._deezer_album_tracks_cached(
                                g.get("album_artist") or name, g["album"],
                                album_id=g.get("album_id")) or []
                        except Exception:                       # noqa: BLE001
                            continue
                    if not tl:
                        continue
                    pairs = [(t.get("artist") or g.get("album_artist")
                              or name, t.get("title"))
                             for t in tl if t.get("title")
                             and (t.get("artist")
                                  or g.get("album_artist") or name)]
                    if pairs:
                        self._prewarm_resolvename(pairs[:12])
                    warmed += 1
            except Exception:                                   # noqa: BLE001
                pass
        try:
            threading.Thread(target=_go, daemon=True).start()
        except Exception:                                       # noqa: BLE001
            pass

    def _artist_photo(self, name, force=False):
        """Best-effort artist photo URL, cached 7 days. Tries Spotify first
        (higher quality), falls back to Deezer. Requires a strong name match
        before trusting the photo."""
        key = "ap:" + self._norm(name)
        if not force:
            got = self.state.db.misc_get(key, 7 * 86400)
            # A cached blank-photo URL means the earlier resolution found only
            # placeholders — never trust it; re-resolve (a better result may
            # now exist or the filter has improved).
            if got is not None and not self._is_blank_art_url(got):
                return got
        # --- Spotify first (higher-res, more accurate) ---
        pic = self.state.scorer.spotify_artist_image(name)
        if pic:
            self.state.db.misc_put(key, pic)
            return pic
        # --- Deezer fallback ---
        import urllib.parse
        want = {self._norm(x) for x in self._split_artists(name) if self._norm(x)}
        want = {w for w in want if len(w) >= 3}
        # Case-insensitive RAW names, used to prefer a genuine spelling match
        # (e.g. "Eminem") over a near-lookalike that only equals after
        # punctuation stripping (e.g. "Emine'm" -> "eminem").
        raw_want = {x.lower() for x in self._split_artists(name)}

        def _decoy(an):
            """Skip obvious tribute/cover/karaoke/backing decoys unless the
            Deezer artist name is an exact normalized match of what we want."""
            low = an.lower()
            for d in ("tribute", "cover band", "karaoke", "backing",
                      "trio", "quartet", "beatles tribute", "easiest way"):
                if d in low:
                    return True
            return False

        def _match(an):
            anorm = self._norm(an)
            # Raw case-insensitive equality is the strongest signal.
            if an.lower() in raw_want:
                return 4
            if anorm in want:
                return 3
            # Whole-word containment score across the wanted tokens. Built to
            # accept real artists even when Deezer spells them slightly
            # differently, without letting an obviously-unrelated account in.
            tokens = sorted(want, key=len, reverse=True)
            hits = sum(
                1 for w in tokens
                if re.search(r"(^|\W)" + re.escape(w) + r"(\W|$)", anorm))
            if not tokens:
                return 0
            # Single-token names (e.g. "Eminem") contain no distinguishing
            # extra token, so only a full-token containment pass — never a
            # partial one — is safe.
            if len(want) == 1:
                return 1 if hits == 1 else 0
            # Multi-token: require a strong majority so a near-miss spelling
            # still resolves, but a weakly-related result is rejected.
            return 1 if (hits / len(tokens)) >= 0.75 and hits >= 1 else 0

        try:
            data = self.state.scorer._deezer_get(
                "https://api.deezer.com/search/artist?q="
                + urllib.parse.quote(name) + "&limit=10")
            cands = []
            for a in (data or {}).get("data") or []:
                an = a.get("name") or ""
                if not an or _decoy(an):
                    continue
                score = _match(an)
                if score <= 0:
                    continue
                p = a.get("picture_xl") or a.get("picture_medium")
                # Deezer serves two kinds of "no image" placeholders: the
                # /artist//250x250-000000-80-0-0.jpg suffix and the blank
                # artwork whose CDN hash is the MD5 of the empty string
                # (d41d8cd98f00b204e9800998ecf8427e). Skip BOTH so an exact
                # match with a real picture wins.
                if (not p
                        or p.endswith("/artist//250x250-000000-80-0-0.jpg")
                        or "/d41d8cd98f00b204e9800998ecf8427e/" in p):
                    continue
                cands.append((score, p))
            # Prefer an exact-normalized match first (score 3); only fall back
            # to a partial containment (score 1) if nothing exact matched.
            cands.sort(key=lambda c: c[0], reverse=True)
            pic = cands[0][1] if cands else None
            self.state.db.misc_put(key, pic)
            return pic
        except Exception:                                # noqa: BLE001
            return None

    def _diagnostics(self, name):
        """Debug report for the artist-photo pipeline. Tests whether Spotify
        creds are configured + working, dumps what Spotify and Deezer return
        for [name], and reports what _artist_photo would choose. This can be
        exported from the app and handed back to fix artist matching."""
        import urllib.parse
        import os
        scorer = self.state.scorer
        norm = self._norm
        want = {norm(x) for x in self._split_artists(name) if norm(x)}
        want = {w for w in want if len(w) >= 3}
        report = {
            "name": name,
            "want_norm": sorted(want),
            # Absolute server paths are not exposed (public URL, 2026-09-18).
            "spotify_creds_configured": bool(
                os.environ.get("SPOTIFY_CLIENT_ID") and
                os.environ.get("SPOTIFY_CLIENT_SECRET")),
            "spotify": self._diag_spotify(scorer, name),
            "deezer": self._diag_deezer(name),
            "js_bootstrap": self._js_bootstrap_report(),
            # Bust the 7-day photo cache so this reports the FRESH choice
            # (a stale cached wrong photo would otherwise hide the fix).
            "chosen_photo": self._artist_photo(name, force=True),
        }
        return report

    def _js_bootstrap_report(self):
        from . import __main__ as main_mod
        holder = getattr(main_mod._ensure_ytdlp_js_runtime, "_holder", None)
        import shutil
        import subprocess

        def _ver(cmd):
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                return (r.stdout or r.stderr).strip().splitlines()[0]
            except Exception:                            # noqa: BLE001
                return None
        deno = shutil.which("deno")
        yt = shutil.which("yt-dlp")
        ffp = shutil.which("ffmpeg")
        ffprobe = shutil.which("ffprobe")
        return {
            "holder": holder,
            "deno_on_path": deno,
            "deno_version": _ver([deno, "--version"]) if deno else None,
            "yt_dlp_on_path": yt,
            "yt_dlp_version": _ver([yt, "--version"]) if yt else None,
            "ffmpeg_on_path": ffp,
            "ffmpeg_version": _ver([ffp, "-version"]) if ffp else None,
            "ffprobe_on_path": ffprobe,
        }

    def _diag_spotify(self, scorer, name):
        import urllib.parse
        import urllib.request
        token = scorer.spotify_token()
        if not token:
            return {"token_ok": False, "via_spotify_image": None,
                    "error": "no token (creds missing or rejected)"}
        out = {"token_ok": True, "via_spotify_image": None,
               "error": None, "items": []}
        try:
            q = urllib.parse.quote(name)
            req = urllib.request.Request(
                f"https://api.spotify.com/v1/search?q={q}"
                "&type=artist&limit=5",
                headers={"Authorization": f"Bearer {token}"})
            data = json.load(urllib.request.urlopen(req, timeout=12))
            for a in (data.get("artists") or {}).get("items") or []:
                imgs = a.get("images") or []
                out["items"].append({
                    "name": a.get("name"), "followers":
                        (a.get("followers") or {}).get("total"),
                    "exact": self._norm(a.get("name", "")) ==
                    self._norm(name),
                    "has_image": bool(imgs),
                })
        except Exception as ex:                          # noqa: BLE001
            out["error"] = str(ex)[:120]
        out["via_spotify_image"] = scorer.spotify_artist_image(name)
        return out

    def _diag_deezer(self, name):
        import urllib.parse
        scorer = self.state.scorer

        def decoy(an):
            low = (an or "").lower()
            for d in ("tribute", "cover band", "karaoke", "backing",
                      "trio", "quartet", "beatles tribute", "easiest way"):
                if d in low:
                    return True
            return False

        results = []
        try:
            data = scorer._deezer_get(
                "https://api.deezer.com/search/artist?q="
                + urllib.parse.quote(name) + "&limit=8")
            for a in (data or {}).get("data") or []:
                results.append({
                    "name": a.get("name"),
                    "exact": self._norm(a.get("name", "")) ==
                    self._norm(name),
                    "decoy": decoy(a.get("name")),
                    "has_pic": bool(a.get("picture_xl")
                                   or a.get("picture_medium")),
                })
        except Exception as ex:                          # noqa: BLE001
            return {"error": str(ex)[:120]}
        return {"items": results}

    def _album(self, artist, album, album_id=None):
        if not album or len(album) > 200:
            return self._error(400, "bad album")
        norm = self._norm
        art_targets = {norm(a) for a in self._split_artists(artist)} if artist else set()
        idx = self._local_files_map()
        rows = self.state.db.query("SELECT * FROM song_meta")
        bundled = {}
        for m in rows:
            if norm(m.get("album")) != norm(album):
                continue
            aa = (m.get("album_artist") or "").strip()
            ar = (m.get("artist") or "").strip()
            if artist and not any(
                    norm(t) in art_targets
                    for c in (aa, ar) for t in self._split_artists(c)):
                continue
            bn = m["base_name"]
            if bn in bundled:
                continue
            p = idx.get(bn)
            bundled[bn] = self._song_dict(bn, p) if p else {
                "base_name": bn, "path": None, "exists": False,
                "url": None,
                "title": self._title_of(bn),
                "artist": ar or (artist or "") or None,
                "album": album,
                "album_artist": aa or (artist or "") or None,
                "album_image": m.get("album_image"),
                "duration_s": None,
            }
        merged = dict(bundled)
        if artist:
            for t in self._deezer_album_tracks_cached(
                    artist, album, album_id=album_id):
                bn = t["base_name"]
                if bn in merged:
                    continue
                p = idx.get(bn)
                # A copy in the playlist dir (Liked, etc.) is a favorited
                # file, not an owned copy of this album track — the row should
                # STREAM from the internet, not silently play the Liked file.
                if self._is_playlist_file(p):
                    p = None
                title = t.get("title") or self._title_of(bn)
                merged[bn] = self._song_dict(bn, p) if p else {
                    "base_name": bn, "path": None, "exists": False,
                    "url": None,
                    "title": title,
                    "artist": t.get("artist") or artist or None,
                    "album": album,
                    "album_artist": artist,
                    "album_image": t.get("album_image"),
                    "duration_s": t.get("duration_s"),
                }
        out = list(merged.values())
        out.sort(key=lambda x: (x["album_image"] is None,
                                x["base_name"].lower()))
        # Pre-warm the online stream URLs for tracks that aren't on the NAS, so
        # tapping play (which uses /api/resolvename) starts instantly instead
        # of blocking on a live YouTube search + yt-dlp per track.
        pairs = []
        for t in out:
            if t["exists"]:
                continue
            ttl = t.get("title") or self._title_of(t["base_name"])
            art = t.get("artist") or artist
            if not art or not ttl:
                continue
            pairs.append((art, ttl))
        if pairs:
            threading.Thread(target=self._prewarm_resolvename,
                             args=(pairs,), daemon=True).start()
        return self._json({
            "album": album, "artist": artist, "songs": out,
            "image": (out[0]["album_image"] if out else None),
        })

    def _liked_names(self, user):
        """All liked base names for this user (single playlist-tree scan).

        Per-user: one user's Liked must never light up another user's
        heart. Legacy reads the shared tree; everyone else reads only
        their own home."""
        state = self.state
        names = set()
        try:
            if user == self.LEGACY_USER or not user:
                paths = [p for _, p in state.playlist_paths()]
            else:
                paths = []
                udir = state.users.user_playlists_dir(user)
                for root, dirs, files in os.walk(udir):
                    dirs[:] = [d for d in dirs if not d.startswith(".")]
                    for f in files:
                        if f.endswith(".m3u"):
                            paths.append(os.path.join(root, f))
            for path in paths:
                try:
                    with open(path, encoding="utf-8",
                              errors="replace") as fh:
                        for line in fh:
                            line = line.strip()
                            if line and not line.startswith("#"):
                                names.add(os.path.basename(line))
                except OSError:
                    continue
        except Exception:                                # noqa: BLE001
            pass
        return names

    def _liked(self, base, user):
        if not base or len(base) > 300:
            return self._error(400, "bad base")
        state = self.state
        names = self._liked_names(user)
        liked = base in names or (base + ".mp3") in names
        downloaded = False
        for full in state._walk_mp3(state.config.music_root):
            if os.path.basename(full) == base + ".mp3":
                downloaded = True
                break
        return self._json({"liked": liked, "downloaded": downloaded})

    # -------------------------------------------------------- multi-user
    # Every login name owns a private home; the pre-existing single-user
    # install IS the RealGungan home (served from the legacy /data/*
    # mounts, which are that same folder on the NAS host). RealGungan maps
    # to the legacy paths so it works with or without the Users share
    # mounted; everyone else resolves under the users dir (created on
    # register). Playlist names can never contain "/" (SAFE_PLAYLIST), so
    # "user/playlist" keys are collision-free for per-user DB/webcache rows.
    LEGACY_USER = "RealGungan"

    def _me(self):
        """Authenticated username for this request (None → caller 401s)."""
        return getattr(self, "_auth_user", None)

    def _log_user_error(self, section, msg, user=None):
        """Persist a per-user error row for the developer viewer.
        Fire-and-forget: never breaks the request."""
        try:
            u = user or self._me() or self._auth_user
            if u:
                self.state.db.log_user_error(u, section, msg)
        except Exception:                                # noqa: BLE001
            pass

    def _user_pldir(self, user):
        """Private playlists dir for a user (created on demand)."""
        if user == self.LEGACY_USER:
            return self.state.config.playlist_dir
        d = self.state.users.user_playlists_dir(user)
        os.makedirs(d, exist_ok=True)
        return d

    def _user_m3u_path(self, user, name):
        """m3u path inside the caller's OWN scope. Like the legacy
        m3u_for(), this searches the user's walk FIRST (folder-based lists
        live in subfolders: Heavy/Heavy.m3u) and only falls back to the
        flat path for creation. Names from another user's list can never
        resolve here (404, not 403). Returns None for invalid names."""
        if not SAFE_PLAYLIST.match(name):
            return None
        if user == self.LEGACY_USER:
            for pname, p in self.state.playlist_paths():
                if pname == name:
                    return p
            return os.path.join(self.state.config.playlist_dir,
                                name + ".m3u")
        d = self._user_pldir(user)
        for root, dirs, files in os.walk(d):
            dirs[:] = [x for x in dirs if not x.startswith(".")]
            for f in sorted(files):
                if f.endswith(".m3u") and f[:-4] == name:
                    return os.path.join(root, f)
        return os.path.join(d, name + ".m3u")

    def _user_m3us(self, user):
        """(name, path) for this user's explicit .m3u playlists. Legacy
        owner keeps the exact historical listing (playlist dir + music
        root); everyone else sees only their own dir."""
        if user == self.LEGACY_USER:
            return self.state.playlist_paths()
        out = []
        try:
            for f in sorted(os.listdir(self._user_pldir(user))):
                if f.endswith(".m3u"):
                    out.append((f[:-4], os.path.join(
                        self._user_pldir(user), f)))
        except OSError:
            pass
        return out

    def _am_key(self, user, playlist):
        return user + "/" + playlist

    def _order_key(self, user):
        return _PLAYLIST_ORDER_KEY + ":" + user

    def _psrc_key(self, user, playlist):
        """misc key holding the import link a playlist came from."""
        return "psrc:" + user + "/" + playlist

    def _user_cover_path(self, user, name):
        m3u = self._user_m3u_path(user, name)
        if m3u is None:
            return None
        return os.path.splitext(m3u)[0] + ".jpg"

    def _maybe_migrate_user(self, username):
        """One-time: adopt the pre-multi-user install as RealGungan's
        private set (prefix added_meta + playlist-order rows). .m3u files
        need no move — the legacy dir IS their home dir. Marker-guarded
        and idempotent."""
        if username != self.LEGACY_USER:
            return
        db = self.state.db
        try:
            if db.misc_get("users_migrated_v1", 0):
                return
        except Exception:                            # noqa: BLE001
            pass
        try:
            db.execute(
                "UPDATE added_meta SET playlist=?||'/'||playlist "
                "WHERE playlist NOT LIKE '%/%'", (username,))
        except Exception:                            # noqa: BLE001
            logger.exception("user migration: added_meta prefix failed")
        try:
            legacy = db.misc_get(_PLAYLIST_ORDER_KEY, 0)
            if isinstance(legacy, list) and legacy:
                db.misc_put(self._order_key(username), legacy)
        except Exception:                            # noqa: BLE001
            logger.exception("user migration: order copy failed")
        try:
            db.misc_put("users_migrated_v1", 1)
        except Exception:                            # noqa: BLE001
            pass

    # --------------------------------------------------------------- keep
    def _keep(self):
        from .lifecycle import append_entry, keep_staged
        from .pipeline import split_base

        user = self._me()
        if not user:
            return self._error(401, "auth required")
        body = self._body_json()
        if body is None:
            return self._error(400, "invalid JSON")
        state = self.state
        playlist = (body.get("playlist") or "").strip()
        if not playlist or not SAFE_PLAYLIST.match(playlist):
            return self._error(400, "bad playlist name")
        did = body.get("download_id")
        base = (body.get("base_name") or "").strip()

        row = state.db.get_download(did) if did else \
            state.db.find_download_by_base(base or "")

        if row is None:
            if base and " - " in base:
                # maybe it's already a library file -> just reference it
                found = self._find_in_library(base + ".mp3")
                if found:
                    append_entry(state, playlist, found, keep_basename=True,
                                 m3u=self._user_m3u_path(user, playlist))
                    return self._json({"kept": True,
                                       "promoted_to": found})
                artist, title = (p.strip()
                                 for p in base.split(" - ", 1))
                state.db.create_download(artist, title, user)
                row = state.db.find_download_by_base(base or "")
                state.db.update_download(row["id"], keep_to=playlist)
                state.pipeline.start_stage(artist, title, owner=user)
                return self._json({"queued": True})
            return self._error(404, "unknown track")

        status = row["status"]
        if status == "staged":
            path = row.get("path") or ""
            if os.path.dirname(path) == state.config.staging_dir \
                    and os.path.exists(path):
                state.db.update_download(row["id"], keep_to=playlist)
                dest = keep_staged(state,
                                   state.db.get_download(row["id"]))
                state.db.update_download(row["id"], keep_to=None)
                return self._json({"kept": True, "promoted_to": dest})

        if status == "kept" and row.get("path"):
            append_entry(state, playlist, row["path"], keep_basename=True,
                         m3u=self._user_m3u_path(user, playlist))
            return self._json({"kept": True, "path": row["path"]})

        if status in ("expired", "deleted", "failed", "giveup",
                      "no_results", "no_official"):
            state.db.update_download(row["id"], keep_to=playlist)
            state.pipeline.retry(row["id"])
            return self._json({"queued": True, "retrying": True})

        state.db.update_download(row["id"], keep_to=playlist)
        return self._json({"queued": True})

    def _find_in_library(self, filename):
        for full in self.state._walk_mp3(self.state.config.music_root):
            if os.path.basename(full) == filename:
                return full
        return None

    # ---------------------------------------------------------- playlists
    def _spotify_oembed_cover(self, url):
        """Playlist image with no auth: oEmbed answers thumbnail_url for
        public Spotify URLs. Used for the full-playlist path (no embed
        entity art there). Fail-open."""
        try:
            body, _ = _fetch_public(
                "https://open.spotify.com/oembed?url=" +
                urllib.parse.quote((url or "").strip(), safe=""),
                timeout=10, max_bytes=64 * 1024)
            import json as _json
            return (_json.loads(body.decode("utf-8", errors="replace"))
                    .get("thumbnail_url") or "")
        except Exception:                                    # noqa: BLE001
            return ""

    def _spotify_playlist_order(self, url, full=False):
        """Spotify playlist link -> its track sequence (title/artist/uri/
        duration, in order) via the public EMBED page's __NEXT_DATA__.
        No auth, no API key. Cached 6h per playlist id. Raises _HTTPError
        (via _error) on bad/private/unparseable input."""
        import json as _json
        import re as _re
        p = urllib.parse.urlparse((url or "").strip())
        if p.scheme not in ("http", "https"):
            return self._error(400, "need a Spotify playlist link")
        if (p.hostname or "").lower() not in (
                "open.spotify.com", "www.open.spotify.com"):
            return self._error(400, "need a Spotify playlist link")
        m = _re.search(r"/(?:embed/)?playlist/([A-Za-z0-9]{10,40})",
                        p.path or "")
        if not m:
            return self._error(400, "need a Spotify playlist link")
        pid = m.group(1)
        state = self.state
        if full:
            # Never serve the 100-cap embed cache for a full request.
            try:
                cached = state.db.misc_get("spf:" + pid, 6 * 3600)
            except Exception:                            # noqa: BLE001
                cached = None
            if isinstance(cached, dict) and cached.get("tracks"):
                return cached
        else:
            try:
                cached = state.db.misc_get("spo:" + pid, 6 * 3600)
            except Exception:                            # noqa: BLE001
                cached = None
            if isinstance(cached, dict) and cached.get("tracks"):
                return cached
        if full:
            tracks = self._spotify_playlist_tracks(pid)
            if tracks:
                out = {"id": pid, "name": "", "tracks": tracks,
                       "full": True, "total": len(tracks),
                       "cover": self._spotify_oembed_cover(url)}
                try:
                    state.db.misc_put("spf:" + pid, out)
                except Exception:                        # noqa: BLE001
                    pass
                return out
            # else: fall through to the embed (hash may have rotated)
        embed = "https://open.spotify.com/embed/playlist/" + pid
        try:
            body, _ = _fetch_public(embed, timeout=20,
                                    max_bytes=2 * 1024 * 1024)
            html = body.decode("utf-8", errors="replace")
        except Exception as e:                           # noqa: BLE001
            return self._error(502, f"playlist fetch failed: {e}")
        m = _re.search(
            r'<script id="__NEXT_DATA__" type="application/json">(.*?)'
            r"</script>", html, _re.S)
        if not m:
            return self._error(502, "no track data (private playlist?)")
        try:
            data = _json.loads(m.group(1))
            ent = (data.get("props", {}).get("pageProps", {}).get(
                "state", {}).get("data", {}).get("entity", {}))
            tracks = [{
                "artist": (t.get("subtitle") or "").strip(),
                "title": (t.get("title") or "").strip(),
                "uri": t.get("uri") or "",
                "duration_ms": t.get("duration"),
            } for t in (ent.get("trackList") or [])]
            tracks = [t for t in tracks if t["title"]]
            cover = _thumb_url((ent.get("coverArt") or {}).get("sources"))
            out = {"id": pid, "name": ent.get("title") or "",
                   "tracks": tracks, "cover": cover}
        except Exception:                                # noqa: BLE001
            return self._error(502, "track data unreadable")
        if not tracks:
            return self._error(502, "no track data (private playlist?)")
        try:
            state.db.misc_put("spo:" + pid, out)
        except Exception:                                # noqa: BLE001
            pass
        return out

    def _spotify_playlist_tracks(self, pid):
        """FULL playlist sequence via the anonymous pathfinder
        fetchPlaylistContents query (same TOTP token as searchDesktop):
        [{artist,title,uri,duration_ms,added_at}] in playlist order, with
        the REAL Spotify added-dates. Best-effort: [] on any failure
        (caller falls back to the 100-cap embed order)."""
        import urllib.request
        tok = self._spotify_anon_token()
        if not tok:
            return []
        out = []
        offset = 0
        while True:
            body = json.dumps({
                "variables": {"uri": "spotify:playlist:" + pid,
                              "offset": offset, "limit": 100},
                "operationName": "fetchPlaylistContents",
                "extensions": {"persistedQuery": {
                    "version": 1,
                    "sha256Hash": type(self)._SPOTIFY_PLAYLIST_HASH}},
            }).encode()
            req = urllib.request.Request(
                "https://api-partner.spotify.com/pathfinder/v1/query",
                data=body,
                headers={"Authorization": "Bearer " + tok,
                         "User-Agent": "Mozilla/5.0",
                         "content-type": "application/json",
                         "App-Platform": "WebPlayer",
                         "Referer": "https://open.spotify.com/"})
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:
                    d = json.load(resp)
            except Exception:                            # noqa: BLE001
                return []
            content = ((d.get("data") or {}).get("playlistV2") or {}
                       ).get("content") or {}
            items = content.get("items") or []
            if not items:
                break
            for it in items:
                data = ((it.get("itemV2") or {}).get("data") or {})
                if not isinstance(data, dict):
                    continue
                name = data.get("name") or ""
                if not name:
                    continue
                arts = data.get("artists") or {}
                names = [((a.get("profile") or {}).get("name") or "")
                         for a in (arts.get("items") or [])]
                dur = data.get("trackDuration") or {}
                ms = dur.get("totalMilliseconds") if isinstance(
                    dur, dict) else (dur if isinstance(dur, int) else None)
                out.append({
                    "artist": ", ".join(a for a in names if a),
                    "title": name,
                    "uri": data.get("uri") or "",
                    "duration_ms": ms,
                    "added_at": (it.get("addedAt") or {}).get("isoString"),
                })
            total = content.get("totalCount") or 0
            offset += len(items)
            if len(items) < 100 or (total and offset >= total):
                break
            if offset > 5000:
                break
        return out

    # ---- YouTube Music login (TV device flow): pending grants + token
    # helpers. Per-user tokens (0600 files in private homes); nothing
    # global, nothing in the DB (which doesn't survive Down/Up).
    _ytm_pending_lock = threading.Lock()
    _ytm_pending = {}  # user -> {device_code, exp}

    def _ytm_oauth_creds(self):
        """OAuthCredentials or None (owner env missing)."""
        from ytmusicapi.auth.oauth.credentials import OAuthCredentials
        cid = (getattr(self.state.config, "ytmusic_client_id", "") or "")
        sec = (getattr(self.state.config, "ytmusic_client_secret", "")
               or "")
        if not cid or not sec:
            return None
        return OAuthCredentials(client_id=cid, client_secret=sec)

    def _ytm_token_path(self):
        user = self._me()
        if not user:
            return None
        try:
            return self.state.users.ytmusic_oauth_path(user)
        except Exception:                                # noqa: BLE001
            return None

    def _ytm_has_token(self):
        import os as _os
        p = self._ytm_token_path()
        return bool(p) and _os.path.exists(p)

    def _ytm_drop_token(self):
        import os as _os
        for p in (self._ytm_token_path(), self._ytm_browser_path()):
            if p:
                try:
                    if _os.path.exists(p):
                        _os.remove(p)
                except Exception:                        # noqa: BLE001
                    pass

    def _ytm_browser_path(self):
        """Per-user browser-cookie credential file (alternative to OAuth
        when Google rejects TV-client library calls)."""
        user = self._me()
        if not user:
            return None
        try:
            home = self.state.users.user_home(user)
        except Exception:                                # noqa: BLE001
            return None
        import os as _os
        return _os.path.join(home, ".ytmusic-browser.json")

    @staticmethod
    def _curl_headers(raw):
        """Extract {Header: value} from a pasted `curl ... -H 'K: V' ...`
        command. Ignores URL/method/data flags. Returns {} if nothing.
        shlex first, regex fallback (ANSI-C $'...' blobs with binary
        escapes can choke the shell lexer)."""
        import re as _re
        import shlex
        try:
            parts = shlex.split(raw or "", posix=True)
            out = {}
            for i, p in enumerate(parts):
                if p in ("-H", "--header") and i + 1 < len(parts):
                    h = parts[i + 1]
                    if ":" in h:
                        k, v = h.split(":", 1)
                        k, v = k.strip(), v.strip()
                        if k and v and k.lower() not in (
                                "content-length", "content-type"):
                            out[k] = v
            if any("cookie" in k.lower() for k in out):
                return out
        except Exception:                                # noqa: BLE001
            pass
        # Fallback: raw -H 'K: V' scan (quote-safe for header values,
        # which never contain raw single quotes). Tolerates backslash
        # line-continuations (Firefox copy format) after the closing quote.
        out = {}
        for m in _re.finditer(r"-H\s+'([^':]+):\s*(.*?)'\s*(?:\\\s*)*(?=-|\Z)",
                              raw or "", re.S):
            k, v = m.group(1).strip(), m.group(2).strip()
            if k and v and k.lower() not in (
                    "content-length", "content-type"):
                out[k] = v
        return out

    def _ytm_cookie(self):
        """Store a pasted browser login (curl of an authed music.youtube.com
        /youtubei/v1/browse request) as this user's credential file, then
        validate with a 1-item library read. 0600, per-user home."""
        import json as _json
        import os as _os
        user = self._me()
        if not user:
            return self._error(401, "auth required")
        body = self._body_json()
        if not isinstance(body, dict):
            return self._error(400, "invalid JSON")
        headers = self._curl_headers(body.get("curl") or "")
        lowering = {k.lower(): v for k, v in headers.items()}
        logger.info("ytm-cookie paste: headers=%s sapisid=%s authuser=%s "
                    "visitor=%s origin=%s ua=%s",
                    sorted(lowering),
                    "__Secure-3PAPISID" in headers.get("cookie", ""),
                    "x-goog-authuser" in lowering,
                    "x-goog-visitor-id" in lowering,
                    "origin" in lowering or "x-origin" in lowering,
                    "user-agent" in lowering)
        cookie = headers.get("cookie") or headers.get("Cookie") or ""
        if "__Secure-3PAPISID" not in cookie:
            return self._error(
                400, "no login cookie found — copy a music.youtube.com "
                     "youtubei/v1/browse request as cURL (it must carry "
                     "a Cookie header)")
        lowering = {k.lower(): v for k, v in headers.items()}
        if "origin" not in lowering and "x-origin" not in lowering:
            return self._error(
                400, "no origin header found — copy the FULL request "
                     "as cURL, not just the URL")
        if "user-agent" not in lowering:
            return self._error(
                400, "no user-agent found — copy the FULL request as cURL")
        try:
            from ytmusicapi.setup import setup_browser
            from ytmusicapi import YTMusic
        except Exception:                                # noqa: BLE001
            return self._error(500, "ytmusicapi missing")
        p = self._ytm_browser_path()
        if not p:
            return self._error(500, "no home directory")
        raw = "\n".join(f"{k}: {v}" for k, v in headers.items())
        # Diagnostic crumb (cookie NAMES only, never values): tells a bad
        # paste (missing SIDs) apart from a Google-side rejection.
        lowering = {k.lower(): v for k, v in headers.items()}
        ck = lowering.get("cookie", "")
        diag = "sids=[%s]" % ",".join(
            s for s in ("3PAPISID", "1PAPISID", "3PSID") if s in ck)
        logger.warning("ytm-cookie paste: %s authuser=%s visitor=%s", diag,
                       lowering.get("x-goog-authuser", "?"),
                       "yes" if "x-goog-visitor-id" in lowering else "no")
        try:
            setup_browser(filepath=p, headers_raw=raw)
            _os.chmod(p, 0o600)
            _install_ytm_auth_patch()
            _register_ytm_browser_cookie(p)
            yt = YTMusic(auth=p)
            # Discriminator ladder (council finding): account-level vs
            # library-level failure need different fixes. Try cheapest
            # identity probe first, then the library read.
            try:
                acct = yt.get_account_info() or {}
                logger.warning("ytm cookie validation: account_info=%s",
                               str(acct)[:160])
            except Exception as ae:                        # noqa: BLE001
                logger.warning("ytm cookie validation: account_info "
                               "failed: %s", str(ae)[:160])
            pls = yt.get_library_playlists(limit=1) or []
            _ = len(pls)
        except (KeyError, TypeError) as e:               # noqa: BLE001
            # Auth is valid but the YT-Music library shelves are empty
            # (singleColumn + messageRenderer instead of playlist grids).
            # The session stays: channel playlists + liked still work.
            logger.warning("ytm cookie accepted, empty library: %s",
                           str(e)[:120])
            return {"connected": True, "empty": True}
        except Exception as e:                           # noqa: BLE001
            body = str(e)
            if "400" in body or "invalid argument" in body.lower():
                logger.warning("ytm cookie validation failed %s: %s",
                               diag, body[:200])
            try:
                # Keep the file only if it looks like a real session
                # (transients shouldn't cost another DevTools round-trip).
                # A bad paste (no SIDs) is deleted to avoid confusion.
                if "3PAPISID" not in ck and _os.path.exists(p):
                    _os.remove(p)
            except Exception:                            # noqa: BLE001
                pass
            return self._error(
                502, f"cookie rejected {diag}: {type(e).__name__}")
        return {"connected": True}

    def _ytm_save_token(self, tok):
        import json as _json
        import os as _os
        p = self._ytm_token_path()
        if not p:
            return False
        try:
            _os.makedirs(_os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                _json.dump(tok, fh)
            _os.chmod(p, 0o600)
            return True
        except Exception:                                # noqa: BLE001
            return False

    def _ytm_client(self):
        """Authed YTMusic or None (with WHY in the second element).
        Browser-cookie file first (it survives Google's TV-client
        library rejection); OAuth token as fallback. Either may be
        missing per-user."""
        import json as _json
        import os as _os
        from ytmusicapi import YTMusic
        bp = self._ytm_browser_path()
        if bp and _os.path.exists(bp):
            try:
                _install_ytm_auth_patch()
                _register_ytm_browser_cookie(bp)
                return YTMusic(auth=bp), None
            except Exception:                            # noqa: BLE001
                pass  # fall through to OAuth below
        p = self._ytm_token_path()
        if p and _os.path.exists(p):
            try:
                with open(p, encoding="utf-8") as fh:
                    tok = _json.load(fh)
            except Exception:                            # noqa: BLE001
                tok = None
            if isinstance(tok, dict) and tok.get("access_token"):
                creds = self._ytm_oauth_creds()
                try:
                    return YTMusic(auth=dict(tok),
                                   oauth_credentials=creds), None
                except Exception:                        # noqa: BLE001
                    pass
                if creds is not None and tok.get("refresh_token"):
                    try:
                        fresh = creds.refresh_token(tok["refresh_token"])
                        if isinstance(fresh, dict):
                            if "refresh_token" not in fresh:
                                fresh["refresh_token"] = tok["refresh_token"]
                            if self._ytm_save_token(fresh):
                                return YTMusic(
                                    auth=dict(fresh),
                                    oauth_credentials=creds), None
                    except Exception:                    # noqa: BLE001
                        pass
        return None, "not connected"

    # (end _ytm_client)

    def _ytm_auth_start(self):
        """Begin a device grant for THIS user. Returns
        {url, user_code, expires_in} or an _error dict."""
        import time
        user = self._me()
        if not user:
            return self._error(401, "auth required")
        creds = self._ytm_oauth_creds()
        if creds is None:
            return self._error(
                501, "YouTube login not configured on this server")
        try:
            code = creds.get_code()
        except Exception:                                # noqa: BLE001
            return self._error(502, "Google device flow failed to start")
        with type(self)._ytm_pending_lock:
            type(self)._ytm_pending[user] = {
                "device_code": code.get("device_code"),
                "exp": time.time() + int(code.get("expires_in") or 900),
            }
        return {"url": code.get("verification_url")
                or "https://www.google.com/device",
                "user_code": code.get("user_code"),
                "expires_in": code.get("expires_in")}

    def _ytm_auth_poll(self):
        """One approval check (app polls every few seconds). Single-shot
        exchange: approved -> token saved -> {connected:true}; waiting ->
        {connected:false}; denied/expired -> {connected:false, error}."""
        import time
        user = self._me()
        if not user:
            return self._error(401, "auth required")
        with type(self)._ytm_pending_lock:
            pend = type(self)._ytm_pending.get(user)
        if not pend:
            return {"connected": self._ytm_has_token()}
        if time.time() > pend.get("exp", 0):
            with type(self)._ytm_pending_lock:
                type(self)._ytm_pending.pop(user, None)
            return {"connected": False,
                    "error": "code expired — start again"}
        creds = self._ytm_oauth_creds()
        if creds is None:
            return self._error(
                501, "YouTube login not configured on this server")
        try:
            tok = creds.token_from_code(pend.get("device_code") or "")
        except Exception as e:                           # noqa: BLE001
            msg = str(e).lower()
            if "denied" in msg or "access_denied" in msg:
                with type(self)._ytm_pending_lock:
                    type(self)._ytm_pending.pop(user, None)
                return {"connected": False,
                        "error": "denied in the browser"}
            return {"connected": False}
        if not isinstance(tok, dict) or not tok.get("access_token"):
            return {"connected": False}
        if not self._ytm_save_token(tok):
            with type(self)._ytm_pending_lock:
                type(self)._ytm_pending.pop(user, None)
            return {"connected": False,
                    "error": "could not store the login — try again"}
        with type(self)._ytm_pending_lock:
            type(self)._ytm_pending.pop(user, None)
        # Prove the token works for library reads before claiming success:
        # Google rejects some TV-client grants while the browser still
        # shows "Success!". Without this the app loops back to login.
        try:
            yt, why = self._ytm_client()
            if yt is None:
                raise ValueError(why or "not connected")
            yt.get_library_playlists(limit=1)
        except Exception:                                # noqa: BLE001
            return {"connected": False,
                    "error": "YouTube rejected this login — use "
                             "'paste a browser login' instead"}
        return {"connected": True}

    @staticmethod
    def _ytm_track_row(t):
        if not isinstance(t, dict):
            return None
        arts = t.get("artists")
        if isinstance(arts, list):
            an = ", ".join(
                (a.get("name") or "" for a in arts if isinstance(a, dict)))
        else:
            an = ""
        title = (t.get("title") or "").strip()
        if not title:
            return None
        return {"artist": an.strip(), "title": title}

    def _ytm_channel(self, q):
        """Public channel -> its playlists. No login needed: resolves a
        handle/@name via unauth search, browses the channel's featured
        tab, and reads the playlist shelves (VLPL ids -> PL ids).
        q="mine" resolves the LOGGED-IN user's own channel via the
        OAuth token (no typing needed)."""
        import re as _re
        from ytmusicapi import YTMusic
        q = (q or "").strip()
        if q.lower() == "mine":
            cid, name = self._ytm_own_channel()
            if not cid:
                return self._error(
                    404, name or "own channel unknown "
                    "(Google login needed for 'mine')")
        elif q.startswith("@"):
            q = q[1:]  # search chokes on the @ prefix (400); handles
            cid, name = "", q
        else:
            cid, name = "", q
        if not cid:
            if _re.fullmatch(r"UC[\w\-]{22}", q):
                cid = q
                name = q
            else:
                try:
                    res = YTMusic().search(q, limit=10) or []
                except Exception:                        # noqa: BLE001
                    return self._error(502, "YouTube search failed")
                for r in res:
                    if (isinstance(r, dict) and r.get("browseId", "")
                            .startswith("UC")):
                        cid = r["browseId"]
                        name = (r.get("artist") or r.get("title")
                                or q)
                        break
                if not cid:
                    return self._error(404, "channel not found")
        try:
            yt = YTMusic()
            page = yt._send_request(
                "browse", dict(yt.context, browseId=cid,
                               params="EghmZWF0dXJlZA%3D%3D"))
            body = page.get("contents", {})
            ren = (body.get("singleColumnBrowseResultsRenderer")
                   or body.get("twoColumnBrowseResultsRenderer") or {})
            tabs = ren.get("tabs", [])
            secs = tabs[0]["tabRenderer"]["content"][
                "sectionListRenderer"]["contents"]
        except Exception as e:                           # noqa: BLE001
            return self._error(502, f"channel unreadable: {e}"[:200])
        out = []
        for s in secs:
            shelf = s.get("musicCarouselShelfRenderer") or {}
            for it in shelf.get("contents") or []:
                mtr = it.get("musicTwoRowItemRenderer") or {}
                bid = (mtr.get("navigationEndpoint", {})
                       .get("browseEndpoint", {}).get("browseId") or "")
                if not bid.startswith("VL"):
                    continue
                title = mtr.get("title", {}) or {}
                title = "".join(
                    x.get("text", "") for x in title.get("runs", []))
                sub = mtr.get("subtitle", {}) or {}
                sub = "".join(
                    x.get("text", "") for x in sub.get("runs", []))
                # Shelf thumbnail — carried through so an import can
                # auto-set the playlist cover (no extra fetch).
                cover = _thumb_url(mtr)
                total = 0
                m = _re.search(r"(\d[\d,]*)\s+tracks?", sub,
                               _re.IGNORECASE)
                if m:
                    try:
                        total = int(m.group(1).replace(",", ""))
                    except ValueError:                       # noqa: BLE001
                        total = 0
                out.append({"id": bid[2:], "name": title or "Untitled",
                            "subtitle": sub, "total": total,
                            "cover": cover})
        # Channel shelves carry views, not counts — one header read per
        # playlist gives the real trackCount. Parallel (6 workers) with a
        # 24h cache: serial reads made channel loads take 5-15s.
        need = [p for p in out if not p["total"]]
        if need:
            import concurrent.futures as _cf

            def _count(pid):
                try:
                    hit = self.state.db.misc_get("ytc:" + pid, 24 * 3600)
                    if isinstance(hit, int) and hit > 0:
                        return hit
                except Exception:                            # noqa: BLE001
                    pass
                try:
                    from ytmusicapi import YTMusic as _YT
                    hdr = _YT().get_playlist(pid, limit=1) or {}
                    n = int(hdr.get("trackCount") or 0)
                except Exception:                            # noqa: BLE001
                    n = 0
                try:
                    self.state.db.misc_put("ytc:" + pid, n)
                except Exception:                            # noqa: BLE001
                    pass
                return n

            with _cf.ThreadPoolExecutor(max_workers=6) as ex:
                for p, n in zip(need, ex.map(
                        _count, [p["id"] for p in need])):
                    p["total"] = n
        return {"channel": name, "channel_id": cid, "playlists": out}

    @staticmethod
    def _ytm_api_disabled(exc):
        """True when a googleapis call failed because YouTube Data API
        v3 is not enabled in the user's Cloud project (HTTP 403 +
        accessNotConfigured). Fail-open False on anything else."""
        try:
            if type(exc).__name__ != "HTTPError":
                return False
            if getattr(exc, "code", 0) != 403:
                return False
            body = exc.read().decode("utf-8", errors="replace")
            return "accessNotConfigured" in body
        except Exception:                                    # noqa: BLE001
            return False

    def _ytm_own_channel(self):
        """(channel_id, name) for the logged-in user via the OAuth
        token (YouTube Data API channels.list mine=true; that API
        accepts the token even though youtubei rejects it). Returns
        ("", why) when unusable."""
        import json as _json
        import os as _os
        import urllib.request as _url
        p = self._ytm_token_path()
        if not p or not _os.path.exists(p):
            return "", "no Google login on file"
        try:
            with open(p, encoding="utf-8") as fh:
                tok = _json.load(fh)
        except Exception:                                # noqa: BLE001
            return "", "unreadable Google login"
        at = (tok or {}).get("access_token") or ""
        if not at:
            return "", "unreadable Google login"
        try:
            rq = _url.Request(
                "https://www.googleapis.com/youtube/v3/channels"
                "?part=id,snippet&mine=true",
                headers={"Authorization": "Bearer " + at})
            data = _json.load(_url.urlopen(rq, timeout=20))
            item = (data.get("items") or [{}])[0]
            cid = item.get("id") or ""
            name = ((item.get("snippet") or {}).get("title") or cid)
            if cid:
                return cid, name
        except Exception as e:                               # noqa: BLE001
            if self._ytm_api_disabled(e):
                return "", ("YouTube Data API v3 is OFF in your Google "
                            "Cloud project — enable it under APIs & "
                            "Services > Library, then look up 'mine' again")
            pass
        # Stale access token: single refresh retry.
        try:
            creds = self._ytm_oauth_creds()
            rt = (tok or {}).get("refresh_token") or ""
            if creds is not None and rt:
                fresh = creds.refresh_token(rt)
                if isinstance(fresh, dict):
                    nat = fresh.get("access_token") or ""
                    if nat:
                        if "refresh_token" not in fresh:
                            fresh["refresh_token"] = rt
                        self._ytm_save_token(fresh)
                        rq = _url.Request(
                            "https://www.googleapis.com/youtube/v3/"
                            "channels?part=id,snippet&mine=true",
                            headers={"Authorization": "Bearer " + nat})
                        data = _json.load(_url.urlopen(rq, timeout=20))
                        item = (data.get("items") or [{}])[0]
                        cid = item.get("id") or ""
                        name = ((item.get("snippet") or {}).get("title")
                                or cid)
                        if cid:
                            return cid, name
        except Exception as e:                               # noqa: BLE001
            if self._ytm_api_disabled(e):
                return "", ("YouTube Data API v3 is OFF in your Google "
                            "Cloud project — enable it under APIs & "
                            "Services > Library, then look up 'mine' again")
            pass
        return "", "Google login expired (re-log in)"

    def _ytm_data_get(self, path, params):
        """YouTube Data API v3 GET with the user's OAuth token (single
        refresh retry on 401). Returns parsed JSON. Raises on failure.
        This is the path that works when Google rejects the same token
        for ytmusicapi (TV-client) calls."""
        import json as _json
        import os as _os
        import urllib.parse as _up
        import urllib.request as _url
        p = self._ytm_token_path()
        if not p or not _os.path.exists(p):
            raise ValueError("no Google login on file")
        with open(p, encoding="utf-8") as fh:
            tok = _json.load(fh)
        at = (tok or {}).get("access_token") or ""
        if not at:
            raise ValueError("unreadable Google login")

        def _call(token):
            qs = _up.urlencode(dict(params))
            rq = _url.Request(
                "https://www.googleapis.com/youtube/v3/" + path + "?" + qs,
                headers={"Authorization": "Bearer " + token})
            return _json.load(_url.urlopen(rq, timeout=20))

        try:
            return _call(at)
        except Exception as e:                            # noqa: BLE001
            if type(e).__name__ != "HTTPError" or getattr(e, "code", 0) != 401:
                raise
        creds = self._ytm_oauth_creds()
        rt = (tok or {}).get("refresh_token") or ""
        if creds is None or not rt:
            raise ValueError("Google login expired (re-log in)")
        fresh = creds.refresh_token(rt)
        if not isinstance(fresh, dict) or not fresh.get("access_token"):
            raise ValueError("Google login expired (re-log in)")
        if "refresh_token" not in fresh:
            fresh["refresh_token"] = rt
        self._ytm_save_token(fresh)
        return _call(fresh["access_token"])

    def _ytm_library_data(self):
        """Own playlists + liked count via Data API (same shapes as
        _ytm_library). Used when ytmusicapi shelves reject the token."""
        out = []
        page = ""
        while True:
            params = {"part": "snippet,contentDetails", "mine": "true",
                      "maxResults": "50"}
            if page:
                params["pageToken"] = page
            data = self._ytm_data_get("playlists", params)
            for it in data.get("items") or []:
                if not isinstance(it, dict):
                    continue
                sn = it.get("snippet") or {}
                cd = it.get("contentDetails") or {}
                pid = it.get("id") or ""
                if not pid:
                    continue
                try:
                    total = int(cd.get("itemCount") or 0)
                except Exception:                        # noqa: BLE001
                    total = 0
                out.append({"id": pid,
                            "name": sn.get("title") or "Untitled",
                            "total": total,
                            "cover": _thumb_url(sn.get("thumbnails"))})
            page = data.get("nextPageToken") or ""
            if not page:
                break
        ltot = 0
        try:
            ll = self._ytm_data_get("playlistItems", {
                "part": "snippet", "playlistId": "LL", "maxResults": "1"})
            ltot = int((ll.get("pageInfo") or {}).get("totalResults") or 0)
        except Exception:                                # noqa: BLE001
            ltot = 0
        # Own channel's public YTM shelves (the Data listing is the
        # YouTube side; featured shelves are the Music side). Merge any
        # ids the listing missed — this is what makes both worlds match.
        # Shelf art (the Music CDN) wins over Data art for shared ids.
        try:
            chan = self._ytm_channel("mine") or {}
            by_id = {p["id"]: p for p in out}
            for p in chan.get("playlists") or []:
                if not isinstance(p, dict) or not p.get("id"):
                    continue
                if p["id"] in by_id:
                    if p.get("cover"):
                        by_id[p["id"]]["cover"] = p["cover"]
                else:
                    by_id[p["id"]] = p
                    out.append(p)
        except Exception:                                # noqa: BLE001
            pass
        return {"playlists": out, "liked": ltot}

    def _ytm_playlist_items_data(self, pid, limit=5000):
        """Track rows [{artist,title}] for any readable playlist via Data
        API (same shape as the ytmusicapi path). Used when ytmusicapi
        cannot parse the page (system/private/YT-side lists). 'LL' =
        Liked. Raises on failure."""
        out = []
        page = ""
        while len(out) < limit:
            params = {"part": "snippet", "playlistId": pid,
                      "maxResults": "50"}
            if page:
                params["pageToken"] = page
            data = self._ytm_data_get("playlistItems", params)
            for it in data.get("items") or []:
                sn = (it.get("snippet") or {})
                title = (sn.get("title") or "").strip()
                if not title or title in ("Deleted video", "Private video"):
                    continue
                out.append({
                    "artist": (sn.get("videoOwnerChannelTitle") or "")
                    .strip(), "title": title})
                if len(out) >= limit:
                    break
            page = data.get("nextPageToken") or ""
            if not page:
                break
        return out

    def _ytm_liked_data(self, limit=5000):
        """Liked-songs track rows via Data API (LL playlist). Same
        [{artist,title}] shape as the ytmusicapi path."""
        return self._ytm_playlist_items_data("LL", limit)

    def _ytm_library(self):
        """Authed user's playlists + liked count. Private included —
        that's the point."""
        yt, why = self._ytm_client()
        if yt is None:
            # 401 ONLY when no token exists (genuinely logged out).
            # Broken-token failures are 502: a 401 here makes the app
            # nuke its OWN login session for YouTube's problem.
            if (why or "") == "not connected":
                return self._error(401, why)
            return self._error(502, why or "YouTube read failed")
        try:
            try:
                pls = yt.get_library_playlists(limit=500) or []
            except (KeyError, TypeError):               # noqa: BLE001
                pls = []  # valid session, empty YT-Music library shelves
            out = []
            for p in pls:
                if not isinstance(p, dict):
                    continue
                pid = p.get("playlistId") or ""
                if not pid:
                    continue
                try:
                    total = int(p.get("count") or 0)
                except Exception:                        # noqa: BLE001
                    total = 0
                out.append({"id": pid,
                            "name": p.get("title") or "Untitled",
                            "total": total,
                            "cover": _thumb_url(p)})
            try:
                liked = yt.get_liked_songs(limit=1) or {}
                ltot = liked.get("total") or len(
                    liked.get("tracks") or [])
            except Exception:                            # noqa: BLE001
                ltot = 0
            if not out and not ltot and self._ytm_has_token():
                # Shelves came back empty but a login exists: try the
                # Data API before calling it empty.
                try:
                    return self._ytm_library_data()
                except Exception:                        # noqa: BLE001
                    pass
            return {"playlists": out, "liked": ltot}
        except Exception as e:                           # noqa: BLE001
            # ytmusicapi rejected the token (the common Google-side
            # TV-client rejection): same data via the Data API instead.
            if self._ytm_has_token():
                try:
                    return self._ytm_library_data()
                except Exception as e2:                  # noqa: BLE001
                    self._log_user_error(
                        "download_failed", f"library read failed: {e2}"[:200])
                    return self._error(
                        502, f"YouTube read failed: {e2}"[:200])
            self._log_user_error(
                "download_failed", f"library read failed: {e}"[:200])
            return self._error(502, f"YouTube read failed: {e}"[:200])

    def _ytm_library_playlist(self, pid):
        """Full track order [{artist,title}] for a library playlist id,
        or 'liked' for Liked Songs. Public ids also work logged-out
        (unauthenticated fallback) — only 'liked' truly needs login."""
        yt, why = self._ytm_client()
        if yt is None and pid != "liked":
            try:
                from ytmusicapi import YTMusic
                yt, why = YTMusic(), None
            except Exception:                            # noqa: BLE001
                yt, why = None, why
        if yt is None:
            # 401 ONLY when no token exists (genuinely logged out).
            # Broken-token failures are 502: a 401 here makes the app
            # nuke its OWN login session for YouTube's problem.
            if (why or "") == "not connected":
                return self._error(401, why)
            return self._error(502, why or "YouTube read failed")
        try:
            if pid == "liked":
                try:
                    data = yt.get_liked_songs(limit=5000) or {}
                    tracks = data.get("tracks") or []
                except Exception:                        # noqa: BLE001
                    if not self._ytm_has_token():
                        raise
                    return {"tracks": self._ytm_liked_data(),
                            "cover": ""}
            else:
                try:
                    data = yt.get_playlist(pid, limit=5000) or {}
                    tracks = data.get("tracks") or []
                except Exception:                        # noqa: BLE001
                    # ytmusicapi cannot parse this page (system, private
                    # or YT-side list): same tracks via the Data API.
                    if not self._ytm_has_token():
                        raise
                    return {"tracks": self._ytm_playlist_items_data(pid),
                            "cover": ""}
            out = []
            for t in tracks:
                r = self._ytm_track_row(t)
                if r:
                    out.append(r)
            return {"tracks": out, "cover": _thumb_url(data)}
        except Exception as e:                           # noqa: BLE001
            self._log_user_error(
                "download_failed", f"playlist read failed: {e}"[:200])
            return self._error(502, f"YouTube read failed: {e}"[:200])

    def _ytmusic_playlist_order(self, url):
        """YouTube Music playlist link -> [{artist,title,duration_s}] in
        playlist order, via ytmusicapi (unauthenticated: public playlists
        only). Raises _HTTPError (via _error) on bad/private input."""
        import re as _re
        p = urllib.parse.urlparse((url or "").strip())
        if p.scheme not in ("http", "https"):
            return self._error(400, "need a YouTube Music playlist link")
        if (p.hostname or "").lower() not in (
                "music.youtube.com", "www.youtube.com", "youtube.com",
                "youtu.be"):
            return self._error(400, "need a YouTube Music playlist link")
        qs = urllib.parse.parse_qs(p.query or "")
        pid = (qs.get("list") or [""])[0].strip()
        if not pid or not _re.fullmatch(r"[A-Za-z0-9_\-]{5,80}", pid):
            return self._error(400, "need a YouTube Music playlist link")
        try:
            cached = self.state.db.misc_get("spyt:" + pid, 6 * 3600)
        except Exception:                                # noqa: BLE001
            cached = None
        if isinstance(cached, dict) and cached.get("tracks"):
            return cached
        try:
            from ytmusicapi import YTMusic
            pl = YTMusic().get_playlist(pid, limit=None)
        except Exception:                                # noqa: BLE001
            return self._error(
                502, "playlist unreadable (private or unavailable?)")
        tracks = []
        try:
            items = pl.get("tracks") or []
        except Exception:                                # noqa: BLE001
            items = []
        for t in items:
            if not isinstance(t, dict):
                continue
            title = (t.get("title") or "").strip()
            if not title:
                continue
            arts = t.get("artists") or []
            artist = ", ".join(
                (a.get("name") or "").strip() for a in arts
                if isinstance(a, dict) and a.get("name")) or ""
            dur = (t.get("duration_seconds") or
                   t.get("duration") or None)
            try:
                dur = int(dur) if dur is not None else None
            except (TypeError, ValueError):
                dur = None
            tracks.append({"artist": artist, "title": title,
                           "duration_s": dur})
        if not tracks:
            return self._error(502, "no tracks (private playlist?)")
        out = {"id": pid, "name": (pl.get("title") or "").strip(),
               "tracks": tracks, "cover": _thumb_url(pl)}
        try:
            self.state.db.misc_put("spyt:" + pid, out)
        except Exception:                                # noqa: BLE001
            pass
        return out

    _import_lock = threading.Lock()
    _import_progress = {}          # user -> {playlist,total,done,failed}

    def _import_snapshot(self, query):
        user = self._me()
        snap = type(self)._import_progress.get(user) or {}
        if (query.get("playlist") or [""])[0].strip():
            pass  # snapshot is per-user (single flight); name rides along
        return {
            "running": bool(snap.get("running")),
            "playlist": snap.get("playlist") or "",
            "total": snap.get("total", 0),
            "done": snap.get("done", 0),
            "failed": snap.get("failed", 0),
            "skipped": snap.get("skipped", 0),
            "batch_total": snap.get("batch_total", 0),
            "batch_done": snap.get("batch_done", 0),
            "queued": snap.get("queued") or [],
            "missing": snap.get("missing") or [],
        }

    @staticmethod
    def _clean_import_tracks(raw):
        """Validate/clean one track list. Returns (tracks, skipped).
        Raises ValueError with the exact single-import error strings."""
        if not isinstance(raw, list) or not raw:
            raise ValueError("need {name, tracks:[{artist,title}]}")
        if len(raw) > 2000:
            raise ValueError("too many tracks (max 2000)")
        tracks = []
        seen = set()
        skipped = 0
        for t in raw:
            if not isinstance(t, dict):
                continue
            try:
                artist = _safe_track_field(
                    t.get("artist") or "", "artist")
                title = _safe_track_field(
                    t.get("title") or "", "title")
            except ValueError:
                skipped += 1
                continue
            if (artist, title) in seen:
                skipped += 1
                continue
            seen.add((artist, title))
            tracks.append((artist, title))
        if not tracks:
            raise ValueError("no usable tracks")
        return tracks, skipped

    def _import_start(self, query):
        state = self.state
        user = self._me()
        if not user:
            return self._error(401, "auth required")
        if not _rate_allow("import:" + user, 3, 3600):
            return self._error(
                429, "too many imports — one every 20 minutes")
        body = self._body_json()
        if not isinstance(body, dict):
            return self._error(400, "invalid JSON")
        name = (body.get("name") or "").strip()
        lists = body.get("playlists")
        if isinstance(lists, list) and lists:
            # Batch form: many playlists, ONE rate-limit hit. The worker
            # runs them in order with the app closed (fire-and-forget).
            jobs = []
            covers = {}
            sources = {}
            idmap = {}
            skipped_lists = 0
            for entry in lists:
                if not isinstance(entry, dict):
                    skipped_lists += 1
                    continue
                nm = (entry.get("name") or "").strip()
                if not nm or not SAFE_PLAYLIST.match(nm):
                    skipped_lists += 1
                    continue
                pid = (entry.get("id") or "").strip()
                raw = entry.get("tracks")
                if pid and not raw:
                    # ID form: the worker resolves tracks server-side, so
                    # the app can leave right after this POST.
                    jobs.append((nm, None, 0))
                    idmap[nm] = pid[:120]
                else:
                    try:
                        tr, sk = self._clean_import_tracks(raw)
                    except ValueError:
                        skipped_lists += 1
                        continue
                    jobs.append((nm, tr, sk))
                cv = (entry.get("cover") or "").strip()
                if cv.startswith(("http://", "https://")):
                    covers[nm] = cv[:2000]
                sv = (entry.get("source") or entry.get("url") or "").strip()
                if sv.startswith(("http://", "https://")):
                    sources[nm] = sv[:2000]
                if len(jobs) >= 100:
                    break
            if not jobs:
                return self._error(400, "no usable playlists")
            with type(self)._import_lock:
                cur = type(self)._import_progress.get(user) or {}
                if cur.get("running"):
                    return self._error(
                        409, "an import is already running — wait for it")
                type(self)._import_progress[user] = {
                    "running": True, "playlist": jobs[0][0],
                    "total": len(jobs[0][1] or []), "done": 0, "failed": 0,
                    "skipped": jobs[0][2], "batch_total": len(jobs),
                    "batch_done": 0,
                    "queued": [nm for nm, _, _ in jobs[1:]],
                    "skipped_lists": skipped_lists}
            try:
                m3u0 = self._user_m3u_path(user, jobs[0][0])
                if m3u0 is None:
                    raise ValueError("bad playlist name")
                if not os.path.exists(m3u0):
                    open(m3u0, "w").close()
                type(self)._playlists_cache.pop(user, None)
                for snm, slink in sources.items():
                    try:
                        state.db.misc_put(
                            self._psrc_key(user, snm), slink)
                    except Exception:                      # noqa: BLE001
                        pass
                threading.Thread(
                    target=self._import_batch_worker, daemon=True,
                    args=(user, jobs, covers, idmap)).start()
            except Exception as e:                       # noqa: BLE001
                with type(self)._import_lock:
                    type(self)._import_progress.pop(user, None)
                return self._error(500, "import failed to start: %s" % str(e))
            return {"started": jobs[0][0], "batch_total": len(jobs),
                    "total_tracks": sum(len(tr or []) for _, tr, _ in jobs),
                    "skipped_lists": skipped_lists}
        if not name or not SAFE_PLAYLIST.match(name):
            return self._error(400, "bad playlist name")
        try:
            tracks, skipped = self._clean_import_tracks(body.get("tracks"))
        except ValueError as e:
            return self._error(400, str(e))
        cover = (body.get("cover") or "").strip()
        if not cover.startswith(("http://", "https://")):
            cover = ""
        src = (body.get("source") or body.get("url") or "").strip()
        if not src.startswith(("http://", "https://")):
            src = ""
        with type(self)._import_lock:
            cur = type(self)._import_progress.get(user) or {}
            if cur.get("running"):
                return self._error(
                    409, "an import is already running — wait for it")
            type(self)._import_progress[user] = {
                "running": True, "playlist": name,
                "total": len(tracks), "done": 0, "failed": 0,
                "skipped": skipped}
        try:
            m3u = self._user_m3u_path(user, name)
            if m3u is None:
                raise ValueError("bad playlist name")
            if not os.path.exists(m3u):
                open(m3u, "w").close()
            type(self)._playlists_cache.pop(user, None)
            if src:
                try:
                    state.db.misc_put(
                        self._psrc_key(user, name), src[:2000])
                except Exception:                          # noqa: BLE001
                    pass
            threading.Thread(target=self._import_worker, daemon=True,
                             args=(user, name, tracks,
                                   cover[:2000])).start()
        except Exception as e:                           # noqa: BLE001
            with type(self)._import_lock:
                type(self)._import_progress.pop(user, None)
            return self._error(500, "import failed to start: %s" % str(e))
        return {"started": name, "total": len(tracks)}

    def _import_worker(self, user, playlist, tracks, cover=""):
        """Single-playlist import: setup + shared track loop + teardown."""
        snap = type(self)._import_progress.get(user) or {}
        lock = type(self)._import_lock
        m3u = self._user_m3u_path(user, playlist)
        try:
            self._save_cover_url(user, playlist, cover)
            self._import_run_tracks(user, playlist, m3u, tracks, snap, lock)
            requested, failed = len(tracks), snap.get("failed", 0) or 0
            if failed > 0:
                missing = snap.get("missing") or []
                self._log_user_error(
                    "import_missing",
                    f"import '{playlist}': {requested - failed}/{requested}"
                    f" added, missing: {', '.join(missing[:10])}"[:500],
                    user=user)
        except Exception:                                # noqa: BLE001
            logger.exception("import failed")
            self._log_user_error(
                "download_failed",
                f"import '{playlist}' failed, see server log",
                user=user)
            raise
        finally:
            snap["running"] = False
            try:
                type(self)._playlists_cache.pop(user, None)
            except Exception:                            # noqa: BLE001
                pass

    def _ytm_import_tracks(self, pid):
        """(tracks, cover) for an import entry id: ytmusicapi first,
        Data API fallback. Raises ValueError when unreadable."""
        try:
            res = self._ytm_library_playlist(pid)
            if isinstance(res, dict) and not res.get("error"):
                tracks = res.get("tracks") or []
                if tracks:
                    return tracks, (res.get("cover") or "")
        except Exception:                                # noqa: BLE001
            pass
        if self._ytm_has_token():
            try:
                rows = self._ytm_playlist_items_data(pid)
                if rows:
                    return ([{"artist": t["artist"], "title": t["title"]}
                             for t in rows], "")
            except Exception:                            # noqa: BLE001
                pass
        raise ValueError("playlist unreadable")

    def _import_batch_worker(self, user, jobs, covers=None, idmap=None):
        """Run many playlists in order (fire-and-forget batch import).
        Same per-track machinery as the single import; the progress
        snapshot tracks overall position (batch_done/batch_total/queued)
        plus the current list's counters. Jobs with tracks=None carry a
        playlist id (idmap) resolved here, so the app can leave right
        after the single POST."""
        snap = type(self)._import_progress.get(user) or {}
        lock = type(self)._import_lock
        total_lists = len(jobs)
        try:
            for i, (name, tracks, skipped) in enumerate(jobs):
                if tracks is None:
                    # ID form: resolve now (worker thread, app long gone).
                    pid = (idmap or {}).get(name) or ""
                    try:
                        trk, cov = self._ytm_import_tracks(pid)
                        tracks, skipped = self._clean_import_tracks(trk)
                        if cov and covers is not None and \
                                name not in covers:
                            covers[name] = cov
                    except ValueError:
                        self._log_user_error(
                            "import_missing",
                            f"import '{name}' unreadable, skipped",
                            user=user)
                        continue
                snap.update({
                    "playlist": name, "total": len(tracks),
                    "done": 0, "failed": 0, "skipped": skipped,
                    "missing": [],
                    "batch_total": total_lists, "batch_done": i,
                    "queued": [nm for nm, _, _ in jobs[i + 1:]]})
                try:
                    m3u = self._user_m3u_path(user, name)
                    if m3u is None:
                        raise ValueError("bad playlist name")
                    if not os.path.exists(m3u):
                        open(m3u, "w").close()
                    type(self)._playlists_cache.pop(user, None)
                    self._save_cover_url(
                        user, name, (covers or {}).get(name) or "")
                    self._import_run_tracks(
                        user, name, m3u, tracks, snap, lock)
                    if (snap.get("failed", 0) or 0) > 0:
                        missing = snap.get("missing") or []
                        self._log_user_error(
                            "import_missing",
                            f"import '{name}': {len(tracks) - snap['failed']}/"
                            f"{len(tracks)} added, missing: "
                            f"{', '.join(missing[:10])}"[:500],
                            user=user)
                except Exception:                        # noqa: BLE001
                    logger.exception("import list failed")
                    self._log_user_error(
                        "download_failed",
                        f"import '{name}' failed, see server log",
                        user=user)
                with lock:
                    snap["batch_done"] = i + 1
        finally:
            snap["running"] = False
            try:
                type(self)._playlists_cache.pop(user, None)
            except Exception:                            # noqa: BLE001
                pass

    def _import_run_tracks(self, user, playlist, m3u, tracks, snap, lock):
        """The per-track import loop shared by single + batch workers.
        Never touches running/cache flags — the calling worker owns those."""
        from .lifecycle import append_entry
        state = self.state
        try:
            local_idx = self.state.local_mp3_index()
        except Exception:                                # noqa: BLE001
            local_idx = None
        for artist, title in tracks:
            base = f"{artist} - {title}"
            try:
                placed = False
                row = state.db.find_download_by_base(base)
                if row is None:
                    found = None
                    if local_idx is not None:
                        found = local_idx.get(base)
                    else:
                        found = self._find_in_library(base + ".mp3")
                    if found:
                        append_entry(
                            state, playlist, found, keep_basename=True,
                            m3u=m3u)
                        placed = True
                    elif local_idx:
                        import re as _re2
                        import unicodedata as _ud2
                        want = _re2.sub(
                            r"[^a-z0-9]+", "",
                            "".join(c for c in _ud2.normalize(
                                "NFKD", base) if not _ud2.combining(c)).lower())
                        for _bn, _full in local_idx.items():
                            got = _re2.sub(
                                r"[^a-z0-9]+", "",
                                "".join(c for c in _ud2.normalize(
                                    "NFKD", _bn) if not _ud2.combining(c)).lower())
                            if got == want:
                                append_entry(
                                    state, playlist, _full,
                                    keep_basename=True, m3u=m3u)
                                placed = True
                                break
                    if not placed:
                        state.db.create_download(artist, title)
                        row = state.db.find_download_by_base(base)
                        state.pipeline._run_stage(row["id"])
                        row = state.db.get_download(row["id"])
                        placed = self._import_promote(
                            state, playlist, m3u, row)
                else:
                    try:
                        live = state.pipeline.job_status(
                            row["id"]) or {}
                    except Exception:                    # noqa: BLE001
                        live = {}
                    if (live.get("status") or "") in (
                            "queued", "downloading", "searching"):
                        placed = False
                    else:
                        placed = self._import_promote(
                            state, playlist, m3u, row)
                with lock:
                    snap["done"] = snap.get("done", 0) + 1
                    if not placed:
                        snap["failed"] = snap.get("failed", 0) + 1
                        self._import_note_missing(snap, base)
            except Exception:                            # noqa: BLE001
                logger.exception("import track failed")
                with lock:
                    snap["done"] = snap.get("done", 0) + 1
                    snap["failed"] = snap.get("failed", 0) + 1
                self._import_note_missing(
                    snap, locals().get("base") or "?")

    @staticmethod
    def _import_note_missing(snap, base):
        """Remember a failed track label (bounded) for the end-of-import
        requested-vs-added summary. Lock-free append is fine (GIL)."""
        try:
            missing = snap.setdefault("missing", [])
            if len(missing) < 20:
                missing.append(str(base)[:120])
        except Exception:                                # noqa: BLE001
            pass

    @staticmethod
    def _import_promote(state, playlist, m3u, row):
        """Fold a download row into the USER's playlist file. Deliberately
        NOT keep_staged: that promotes into the shared library tree +
        global m3u (legacy behavior) — imports must land next to the
        user's own m3u. Returns True when the song landed in the list."""
        from .lifecycle import append_entry
        import shutil
        import time as _time
        if not row or not m3u:
            return False
        status = row.get("status")
        if status == "staged":
            src = os.path.join(
                state.config.staging_dir, f"{row['base_name']}.mp3")
            if os.path.exists(src):
                dest = os.path.join(
                    os.path.dirname(os.path.abspath(m3u)),
                    f"{row['base_name']}.mp3")
                if os.path.exists(dest):
                    os.remove(src)
                else:
                    shutil.move(src, dest)
                append_entry(state, playlist, dest, keep_basename=True,
                             m3u=m3u)
                state.db.update_download(
                    row["id"], status="kept", path=dest, keep_to=None)
                state.db.event(
                    "promoted", {"id": row["id"], "base": row["base_name"],
                                 "to": dest})
                return True
            return False
        if status == "kept" and row.get("path"):
            append_entry(state, playlist, row["path"], keep_basename=True,
                         m3u=m3u)
            return True
        return False

    def _playlists(self, parts):
        state = self.state
        user = self._me()
        if not user:
            return self._error(401, "auth required")

        if parts == []:
            if self.command == "GET":
                now = time.time()
                cached = type(self)._playlists_cache.get(user)
                if cached and (now - cached[0]) < 15:
                    return self._json({"playlists": cached[2]})
                if user == self.LEGACY_USER:
                    state.ensure_playlist_m3us()
                out = []
                for folder, m3u in self._user_m3us(user):
                    n = 0
                    try:
                        with open(m3u, encoding="utf-8",
                                  errors="replace") as fh:
                            n = sum(1 for ln in fh
                                    if ln.strip()
                                    and not ln.startswith("#"))
                    except OSError:
                        n = 0
                    added = os.path.getmtime(m3u) \
                        if os.path.exists(m3u) else 0
                    cover = os.path.splitext(m3u)[0] + ".jpg"
                    out.append({
                        "name": folder, "tracks": n, "path": m3u,
                        "added_at": added,
                        "has_cover": os.path.exists(cover),
                    })
                # Apply any persisted custom order (drag-reorder in the app);
                # playlists not listed (e.g. freshly added) keep alphabetical.
                # The order is per-user: nobody sees anyone else's layout.
                order = state.db.misc_get(self._order_key(user), 0)
                if isinstance(order, list) and order:
                    pos = {name: i for i, name in enumerate(order)}
                    out.sort(key=lambda p: (pos.get(p["name"], 10**9),
                                            p["name"].lower()))
                type(self)._playlists_cache[user] = (now, None, out)
                return self._json({"playlists": out})
            if self.command == "PUT":
                # Persist a new playlist order (drag-reorder in the app).
                body = self._body_json()
                if body is None or not isinstance(
                        body.get("order"), list):
                    return self._error(400, "expected {'order': [names...]}")
                names = [str(n).strip() for n in body["order"] if str(n).strip()]
                state.db.misc_put(self._order_key(user), names)
                type(self)._playlists_cache.pop(user, None)
                return self._json({"ok": True})
            if self.command == "POST":
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                name = (body.get("name") or "").strip()
                if not SAFE_PLAYLIST.match(name):
                    return self._error(400, "bad playlist name")
                m3u = self._user_m3u_path(user, name)
                if m3u is None:
                    return self._error(400, "bad playlist name")
                if not os.path.exists(m3u):
                    open(m3u, "w").close()
                # NOTE: deliberately NOT appended to config.folders — that
                # list is global library hints; user playlists stay private.
                type(self)._playlists_cache.pop(user, None)
                return self._json({"created": name})

        name = parts[0]
        rest = parts[1:]

        if name.endswith("/"):
            name = name[:-1]

        # meta import
        if len(rest) == 1 and rest[0] == "meta":
            if self.command == "POST":
                body = self._body_json()
                if not isinstance(body, list):
                    return self._error(400, "expected a list")
                n = 0
                for row in body:
                    base = (row.get("base_name") or "").strip()
                    added = row.get("added_at")
                    ts = None
                    if added:
                        import datetime as _dt
                        try:
                            iso = str(added).replace("Z", "+00:00")
                            ts = _dt.datetime.fromisoformat(iso).timestamp()
                        except ValueError:
                            ts = None
                    # album_image is fetched server-side by _relay_image:
                    # only accept sane http(s) URLs (SSRF guard, 2026-09-18).
                    img = row.get("album_image")
                    if not (isinstance(img, str) and len(img) < 500
                            and (img.startswith("https://")
                                 or img.startswith("http://"))
                            and "@" not in (urllib.parse.urlparse(img).netloc
                                            or "")):
                        img = None
                    state.db.set_added_meta(
                        self._am_key(user, name), base, ts, img)
                    n += 1
                return self._json({"imported": n})

        # rename playlist (new name, same songs): rename the m3u (+ its
        # cover jpg), carry added_meta rows to the new key, bust caches.
        if len(rest) == 1 and rest[0] == "rename":
            if self.command == "POST":
                body = self._body_json()
                if not isinstance(body, dict):
                    return self._error(400, "invalid JSON")
                new = (body.get("name") or "").strip()
                if not new or not SAFE_PLAYLIST.match(new):
                    return self._error(400, "bad playlist name")
                if new == name:
                    return self._json({"renamed": name})
                m3u = self._user_m3u_path(user, name)
                if m3u is None or not os.path.exists(m3u):
                    return self._error(404, "no such playlist")
                dest = os.path.join(os.path.dirname(m3u), new + ".m3u")
                if os.path.exists(dest):
                    return self._error(409, "a playlist with that name exists")
                try:
                    os.rename(m3u, dest)
                except OSError as e:
                    return self._error(500, "rename failed: %s" % e)
                old_cover = os.path.splitext(m3u)[0] + ".jpg"
                if os.path.exists(old_cover):
                    try:
                        os.rename(old_cover,
                                  os.path.splitext(dest)[0] + ".jpg")
                    except OSError:
                        pass
                try:
                    state.db.execute(
                        "UPDATE added_meta SET playlist=? WHERE playlist=?",
                        (self._am_key(user, new),
                         self._am_key(user, name)))
                except Exception:                            # noqa: BLE001
                    pass
                type(self)._playlists_cache.pop(user, None)
                return self._json({"renamed": new})
            return self._error(405, "method not allowed")

        # entry delete
        if len(rest) == 1 and rest[0] == "entries":
            if self.command == "DELETE":
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                base = (body.get("base_name") or "").strip()
                m3u = self._user_m3u_path(user, name)
                if m3u is None or not os.path.exists(m3u):
                    return self._error(404, "no such playlist")
                kept = []
                with open(m3u, encoding="utf-8", errors="replace") as fh:
                    for ln in fh:
                        s = ln.strip()
                        if not s or s.startswith("#"):
                            continue
                        bn = os.path.basename(s)
                        stem = bn[:-4] if bn.endswith(".mp3") else bn
                        if base not in (bn, stem):
                            kept.append(s)
                with open(m3u, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(kept) + ("\n" if kept else ""))
                return self._json({"removed": base,
                                   "remaining": len(kept)})

        # song reorder (match-Spotify-order from the app): rewrite the m3u
        # in the given base_name sequence. Entries NOT listed keep their
        # old relative order at the end — never drop music by accident.
        if len(rest) == 1 and rest[0] == "order":
            if self.command == "POST":
                body = self._body_json()
                if not isinstance(body, dict) or not isinstance(
                        body.get("order"), list):
                    return self._error(400, "need {order:[base_name]}")
                m3u = self._user_m3u_path(user, name)
                if m3u is None or not os.path.exists(m3u):
                    return self._error(404, "no such playlist")
                want = [str(b).strip() for b in body["order"]
                        if str(b).strip()]
                lines = []
                with open(m3u, encoding="utf-8", errors="replace") as fh:
                    for ln in fh:
                        s = ln.strip()
                        if not s or s.startswith("#"):
                            continue
                        lines.append(s)
                by_base = {}
                for s in lines:
                    bn = os.path.basename(s)
                    stem = bn[:-4] if bn.endswith(".mp3") else bn
                    by_base.setdefault(bn, s)
                    by_base.setdefault(stem, s)
                seen = set()
                out = []
                for b in want:
                    s = by_base.get(b)
                    if s is not None and s not in seen:
                        seen.add(s)
                        out.append(s)
                unlisted = [s for s in lines if s not in seen]
                out.extend(unlisted)
                with open(m3u, "w", encoding="utf-8") as fh:
                    fh.write("\n".join(out) + ("\n" if out else ""))
                return self._json({"reordered": len(out) - len(unlisted),
                                   "total": len(out),
                                   "unlisted_kept": len(unlisted)})
            return self._error(405, "method not allowed")

        # detail / delete / cover (playlist itself)
        if len(rest) == 1 and rest[0] == "cover":
            if self.command == "POST":
                length = int(self.headers.get("Content-Length") or 0)
                data = self.rfile.read(length) if length else b""
                if not data:
                    return self._error(400, "empty body")
                if len(data) > 5 * 1024 * 1024:
                    return self._error(400, "cover too large")
                cover = self._user_cover_path(user, name)
                if cover is None:
                    return self._error(400, "bad playlist name")
                with open(cover, "wb") as fh:
                    fh.write(data)
                return self._json({"ok": True})
            if self.command == "DELETE":
                cover = self._user_cover_path(user, name)
                if cover is not None and os.path.exists(cover):
                    os.remove(cover)
                return self._json({"ok": True})
            return self._error(405, "method not allowed")

        if rest == []:
            if self.command == "GET":
                return self._json(self._playlist_detail(user, name))
            if self.command == "DELETE":
                m3u = self._user_m3u_path(user, name)
                if m3u is not None and os.path.exists(m3u):
                    os.remove(m3u)
                    if user == self.LEGACY_USER:
                        state.tombstone_playlist_folder(m3u, name)
                    return self._json({"deleted": name})
                return self._error(404, "no such playlist")

        self.send_error(404, "no such endpoint")

    def _playlist_detail(self, user, name):
        state = self.state
        m3u = self._user_m3u_path(user, name)
        if m3u is None:
            return {"name": name, "entries": [], "total_seconds": None,
                    "source": state.db.misc_get(
                        self._psrc_key(user, name), 0) or ""}
        m3u_dir = os.path.dirname(os.path.abspath(m3u))
        root = os.path.normpath(state.config.music_root)
        pldir = os.path.normpath(state.config.playlist_dir)
        entries = []
        # Single-payload open (funnel): liked scanned ONCE per user here —
        # never per row — so one playlist open costs one call total.
        liked_names = self._liked_names(user)
        if os.path.exists(m3u):
            with open(m3u, encoding="utf-8", errors="replace") as fh:
                for ln in fh:
                    ln = ln.strip()
                    if not ln or ln.startswith("#"):
                        continue
                    p = ln
                    if not os.path.isabs(p):
                        cand = os.path.normpath(os.path.join(m3u_dir, p))
                        alt = os.path.normpath(os.path.join(root, p))
                        p = cand if os.path.exists(cand) else alt
                    exists = os.path.exists(p)
                    # Single mapping (music root -> /staging/file/,
                    # playlist dir -> /staging/pl/, user homes ->
                    # /staging/u/) so rows can never disagree on URLs.
                    url = self._entry_url(p) if exists else None
                    base = os.path.basename(
                        ln[:-4] if ln.endswith(".mp3") else ln)
                    row = state.db.find_download_by_base(base)
                    album_image = None
                    added_at = None
                    if row and row.get("video_id"):
                        album_image = ("https://i.ytimg.com/vi/"
                                       + row["video_id"] + "/hqdefault.jpg")
                    meta = state.db.added_meta_get(
                        self._am_key(user, name), base)
                    if not meta:
                        meta = state.db.added_meta_get_any(base)
                    if not meta and ".{ext}" in base:
                        cb = base.replace(".{ext}", "")
                        meta = state.db.added_meta_get_any(cb)
                    if meta:
                        added_at = meta["added_at"]
                        if meta["album_image"]:
                            album_image = meta["album_image"]
                    if not album_image:
                        try:
                            _sm = state.db.song_meta_get(base)
                            if _sm and _sm.get("album_image"):
                                album_image = _sm["album_image"]
                            else:
                                _hit = state.db.misc_get(
                                    "dz:cover:" + self._norm(base),
                                    7 * 86400)
                                if _hit:
                                    album_image = _hit
                        except Exception:               # noqa: BLE001
                            pass
                    entries.append({
                        "base_name": base, "path": p, "exists": exists,
                        "url": url, "added_at": added_at,
                        "album_image": album_image,
                        # Direct CDN art (ytimg/dzcdn): the phone fetches it
                        # straight off the CDN instead of NAS-proxied bytes
                        # (proxy doubles the funnel uplink). in_nas == exists
                        # for playlist rows (they ARE nas files); liked is
                        # batched above — no per-row roundtrips.
                        "cover_direct": (album_image if isinstance(
                            album_image, str) and album_image.startswith(
                                ("http://", "https://")) else None),
                        "liked": (base in liked_names
                                  or (base + ".mp3") in liked_names),
                        "in_nas": exists,
                        "duration_s": None,
                    })
        total = 0.0
        for e in entries:
            if e["exists"] and e["path"]:
                d = state.duration_for(e["path"])
                if d is not None:
                    e["duration_s"] = int(d)
                    total += d
        state.ensure_duration_warm()
        return {"name": name, "entries": entries,
                "total_seconds": round(total, 1) if total else None,
                "source": state.db.misc_get(
                    self._psrc_key(user, name), 0) or ""}

    def _all_m3us_every_user(self):
        """Every .m3u: shared roots + all private homes (Liked scope)."""
        state = self.state
        m3us = list(state.playlist_paths())
        for home in self.state.users.user_homes():
            if home == self.LEGACY_USER:
                continue
            udir = self.state.users.user_playlists_dir(home)
            for root, dirs, files in os.walk(udir):
                dirs[:] = [d for d in dirs if not d.startswith(".")]
                for f in sorted(files):
                    if f.endswith(".m3u"):
                        m3us.append((f[:-4], os.path.join(root, f)))
        return m3us

    @staticmethod
    def _clean_base(v):
        v = (v or "").strip()
        if v.endswith(".mp3"):
            v = v[:-4]
        if not v or len(v) > 300 or "/" in v or "\\" in v \
                or ".." in v or "\x00" in v:
            return None
        return v

    def _sweep_base_from_playlists(self, base):
        """Remove {base} from every playlist; returns (playlists_touched)."""
        fname = base + ".mp3"
        touched = 0
        for _folder, m3u in self._all_m3us_every_user():
            try:
                with open(m3u, encoding="utf-8",
                          errors="replace") as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            keep = [ln for ln in lines
                    if os.path.basename(ln.strip()) != fname
                    and os.path.basename(ln.strip()) != base]
            if len(keep) != len(lines):
                try:
                    with open(m3u, "w", encoding="utf-8") as fh:
                        fh.writelines(keep)
                    touched += 1
                except OSError:
                    pass
        type(self)._playlists_cache.clear()
        return touched

    def _delete_from_every_playlist(self):
        body = self._body_json()
        if body is None:
            return self._error(400, "invalid JSON")
        base = self._clean_base(body.get("base"))
        if not base:
            return self._error(400, "need {base}")
        n = self._sweep_base_from_playlists(base)
        return self._json({"removed": base, "playlists": n})

    def _delete_file_to_trash(self, query):
        import shutil
        base = self._clean_base(
            (query.get("base") or [""])[0]
            if query.get("base") else (self._body_json() or {}).get("base"))
        if not base:
            return self._error(400, "need {base}")
        fname = base + ".mp3"
        found = None
        for root in (self.state.config.music_root,
                     self.state.config.staging_dir):
            for full in self.state._walk_mp3(root):
                if os.path.basename(full) == fname:
                    found = full
                    break
            if found:
                break
        if not found:
            for home in self.state.users.user_homes():
                udir = os.path.join(self.state.users.root, home)
                for r, dirs, files in os.walk(udir):
                    dirs[:] = [d for d in dirs if not d.startswith(".")]
                    if fname in files:
                        found = os.path.join(r, fname)
                        break
                if found:
                    break
        if not found:
            return self._error(404, "no such file")
        trash = os.path.join(self.state.config.staging_dir, ".trash")
        os.makedirs(trash, exist_ok=True)
        try:
            shutil.move(found, os.path.join(trash, fname))
        except OSError as e:
            return self._error(500, f"trash failed: {e}")
        n = self._sweep_base_from_playlists(base)
        return self._json({"trashed": base, "playlists": n})

    # ------------------------------------------------------------ delete
    def _delete_download(self, did):
        state = self.state
        row = state.db.get_download(did)
        if not row:
            return self._error(404, "unknown download")
        base = row["base_name"]
        fname = f"{base}.mp3"
        # remove the actual file wherever it lives (staged, kept, or any
        # user home — imports land next to per-user m3us, not just the
        # shared roots)
        for full in state._walk_mp3(state.config.music_root):
            if os.path.basename(full) == fname:
                os.remove(full)
        for full in state._walk_mp3(state.config.staging_dir):
            if os.path.basename(full) == fname:
                os.remove(full)
        for home in self.state.users.user_homes():
            udir = os.path.join(self.state.users.root, home)
            for root, dirs, files in os.walk(udir):
                dirs[:] = [d for d in dirs if not d.startswith(".")]
                if fname in files:
                    try:
                        os.remove(os.path.join(root, fname))
                    except OSError:
                        pass
        m3us = list(state.playlist_paths())
        # ... plus every private home, walked recursively (subfolder lists
        # like Heavy/Heavy.m3u live below the top level).
        for home in self.state.users.user_homes():
            if home == self.LEGACY_USER:
                continue
            udir = self.state.users.user_playlists_dir(home)
            for root, dirs, files in os.walk(udir):
                dirs[:] = [d for d in dirs if not d.startswith(".")]
                for f in sorted(files):
                    if f.endswith(".m3u"):
                        m3us.append((f[:-4], os.path.join(root, f)))
        for folder, m3u in m3us:   # drop references
            try:
                with open(m3u, encoding="utf-8", errors="replace") as fh:
                    lines = fh.readlines()
            except OSError:
                continue
            keep = [ln for ln in lines
                    if os.path.basename(ln.strip()) != fname]
            if len(keep) != len(lines):
                with open(m3u, "w", encoding="utf-8") as fh:
                    fh.writelines(keep)
        state.db.update_download(did, status="deleted", path=None)
        state.db.event("deleted", {"id": did})
        return self._json({"ok": True})

    # ------------------------------------------------------------------ tracks
    def _tracks(self):
        state = self.state
        items = []
        for full in state._walk_mp3(state.config.music_root):
            base = os.path.basename(full)[:-4]
            rel = state.rel_to_root(full)
            artist = base.split(" - ")[0].strip() if " - " in base else ""
            items.append({"base_name": base, "folder": os.path.dirname(rel),
                          "url": "/staging/file/" + rel, "artist": artist})
        return self._json({"tracks": items})

    # ----------------------------------------------------------------- index
    def _index(self):
        # Gated (see _dispatch). Absolute server paths are deliberately
        # NOT exposed — recon fuel on a public URL (2026-09-18).
        s = self.state
        return self._json({
            "service": "gungan.fm",
            "expiry_days": s.config.expiry_days,
        })

    # ----------------------------------------------------------------- cover
    def _cover(self, f):
        state = self.state
        import hashlib
        root = os.path.normpath(state.config.music_root)
        base_dir = root
        if f.startswith("pl:"):
            f = f[3:]
            base_dir = os.path.normpath(state.config.playlist_dir)
        elif f.startswith("u:"):
            f = f[2:]
            base_dir = os.path.normpath(state.users.root)
        # The downloads list carries absolute in-container paths
        # (/data/...); accept those when contained in a known root.
        if os.path.isabs(f):
            cand = os.path.normpath(f)
            roots = [root,
                     os.path.normpath(state.config.playlist_dir),
                     os.path.normpath(state.users.root)]
            if not any(cand == r or cand.startswith(r + os.sep)
                       for r in roots):
                return self._error(400, "bad path")
            path = cand
        else:
            path = os.path.normpath(os.path.join(base_dir, f))
            allowed = path.startswith(base_dir + os.sep) or path == base_dir
            if not allowed:
                return self._error(400, "bad path")

        base_name = os.path.splitext(os.path.basename(path))[0]
        # Curated meta art FIRST: the embedded bytes of a fresh download
        # are usually just the YouTube video's still frame (16:9), while
        # the library holds the real (square) album art. Serving embedded
        # first made every replaced song show the video frame in Now
        # Playing even though the playlist rows showed the album cover.
        meta = state.db.song_meta_get(base_name)
        if meta and meta.get("album_image"):
            return self._relay_image(meta["album_image"])
        meta = state.db.added_meta_get_any(base_name)
        if meta and meta.get("album_image"):
            return self._relay_image(meta["album_image"])
        if ".{ext}" in base_name:
            cb = base_name.replace(".{ext}", "")
            meta = state.db.added_meta_get_any(cb)
            if meta and meta.get("album_image"):
                return self._relay_image(meta["album_image"])

        data = self._extract_embedded(path) if os.path.exists(path) else None
        if data:
            body, ctype = data
            return self._redirect_or_body(body, ctype)

        row = None
        for r in state.db.query(
                "SELECT video_id FROM downloads WHERE base_name=? "
                "AND video_id IS NOT NULL", (base_name,)):
            row = r
            break
        if row and row["video_id"]:
            return self._relay_image(
                f"https://i.ytimg.com/vi/{row['video_id']}/hqdefault.jpg")

        if os.path.exists(path):
            cover = state.scorer._deezer_cover(base_name)
            if cover:
                return self._relay_image(cover)
        return self.send_error(404, "no artwork")

    def _playlist_hint(self, f):
        return None

    def _relay_image(self, url):
        """Fetch an external image and relay the bytes (with cache) so the
        phone never has to reach i.ytimg/Deezer/scdn directly — mobile
        networks here block direct external image CDNs.

        SSRF-guarded (2026-09-18, public Funnel URL): the URL may come
        from client-stored playlist meta, so it goes through _fetch_public
        (public-IP only, no redirects, size-capped)."""
        key = "img:" + url
        with self._cover_cache_lock:
            cached = self._cover_cache.get(key)
        if cached:
            return self._redirect_or_body(*cached)
        try:
            body, ctype = _fetch_public(url)
            if len(body) < 64:
                return self.send_error(404, "no artwork")
            with self._cover_cache_lock:
                self._cover_cache[key] = (body, ctype)
                while len(self._cover_cache) > MAX_COVER_CACHE:
                    self._cover_cache.pop(next(iter(self._cover_cache)))
            return self._redirect_or_body(body, ctype)
        except ValueError as ex:
            logger.info("relay image refused: %s", str(ex)[:80])
            return self.send_error(400, "bad image url")
        except Exception as ex:                       # noqa: BLE001
            logger.info("relay image failed: %s", str(ex)[:80])
            return self.send_error(502, "cover fetch failed")

    _cover_cache = {}
    _cover_cache_lock = threading.Lock()

    def _cover_vid(self, video_id):
        """Proxy a YouTube thumbnail through the server so the phone only
        talks to the NAS (avoids direct i.ytimg.com access that mobile
        networks may block)."""
        import urllib.request
        key = "vid:" + video_id
        with self._cover_cache_lock:
            cached = self._cover_cache.get(key)
        if cached:
            return self._redirect_or_body(*cached)
        # Fallback chain: hq -> mq -> default (deleted/private videos 404
        # some qualities but still serve others; never fail on first miss).
        err = ""
        for qual in ("hqdefault", "mqdefault", "default"):
            try:
                req = urllib.request.Request(
                    f"https://i.ytimg.com/vi/{video_id}/{qual}.jpg",
                    headers={"User-Agent": "Mozilla/5.0"})
                with urllib.request.urlopen(req, timeout=15) as resp:
                    body = resp.read(MAX_COVER_BYTES + 1)
                    ctype = resp.headers.get("Content-Type", "image/jpeg")
                if len(body) < 64 or len(body) > MAX_COVER_BYTES:
                    err = f"{qual} bad size {len(body)}"
                    continue
                with self._cover_cache_lock:
                    self._cover_cache[key] = (body, ctype)
                    while len(self._cover_cache) > MAX_COVER_CACHE:
                        self._cover_cache.pop(next(iter(self._cover_cache)))
                return self._redirect_or_body(body, ctype)
            except Exception as ex:                       # noqa: BLE001
                err = str(ex)[:80]
                continue
        logger.warning("cover vid %s failed all qualities: %s", video_id,
                       err)
        return self.send_error(502, "cover fetch failed")

    def _save_cover_url(self, user, name, url):
        """Auto-cover on import: fetch url (SSRF-guarded) into the
        playlist .jpg — only when no cover is set yet, so a manually
        picked cover is never clobbered. Fail-open."""
        if not url or not str(url).startswith(("http://", "https://")):
            return
        try:
            cover = self._user_cover_path(user, name)
        except Exception:                                    # noqa: BLE001
            return
        if cover is None or os.path.exists(cover):
            return
        try:
            body, _ = _fetch_public(url, timeout=20,
                                    max_bytes=5 * 1024 * 1024)
        except Exception:                                    # noqa: BLE001
            return
        if not (body[:4] == b"\x89PNG" or body[:2] == b"\xff\xd8"):
            return
        try:
            with open(cover, "wb") as fh:
                fh.write(body)
            type(self)._playlists_cache.pop(user, None)
        except OSError:
            pass

    def _cover_playlist(self, name):
        """Serve the user-set playlist cover (saved as <name>.jpg)."""
        if not SAFE_PLAYLIST.match(name):
            return self._error(400, "bad playlist name")
        cover = self._user_cover_path(self._me(), name)
        if cover is None:
            return self._error(400, "bad playlist name")
        if not os.path.exists(cover):
            return self.send_error(404, "no artwork")
        try:
            with open(cover, "rb") as fh:
                data = fh.read()
        except OSError:
            return self.send_error(404, "no artwork")
        ctype = "image/png" if data[:4] == b"\x89PNG" else "image/jpeg"
        return self._redirect_or_body(data, ctype)

    def _extract_embedded(self, path):
        import hashlib
        try:
            from mutagen import File as MFile
        except Exception:
            return None
        cache = os.path.expanduser("~/.cache/nasmusic/covers")
        os.makedirs(cache, exist_ok=True)
        key = hashlib.sha1(
            f"{path}|{int(os.path.getmtime(path))}".encode()).hexdigest()
        cached = os.path.join(cache, key)
        if os.path.exists(cached):
            with open(cached, "rb") as fh:
                return fh.read(), "image/jpeg"
        try:
            audio = MFile(path)
            tags = getattr(audio, "tags", None)
            data = mime = None
            if tags is None:
                return None
            if hasattr(tags, "getall"):
                for pic in tags.getall("APIC"):
                    data, mime = pic.data, pic.mime
                    break
            elif "METADATA_BLOCK_PICTURE" in tags:
                import base64
                from mutagen.flac import Picture
                pics = Picture()
                _ = pics.parse(base64.b64decode(
                    tags["METADATA_BLOCK_PICTURE"][0]))
                data, mime = pics.data, pics.mime
            else:
                return None
        except Exception:                             # noqa: BLE001
            return None
        if not data:
            return None
        ext = ".png" if "png" in (mime or "") else ".jpg"
        try:
            with open(cached + ext, "wb") as fh:
                fh.write(data)
            os.replace(cached + ext, cached)
        except OSError:
            pass
        return data, ("image/png" if ext == ".png" else "image/jpeg")

    def _redirect_or_body(self, body, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "max-age=86400")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _redirect(self, url):
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()

    # ------------------------------------------------------------- file
    def _serve_features(self):
        """Serve the public features page (no auth, like landing)."""
        import os as _os
        p = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                          "static", "features.html")
        try:
            with open(p, "rb") as fh:
                body = fh.read()
        except OSError:
            return self.send_error(404, "features not published yet")
        return self._send(200, body, "text/html; charset=utf-8")

    def _serve_apk(self):
        """Serve the Android APK for the landing page (public by design).
        File lives at <server-dir>/static/nasmusic.apk (uploaded via SMB
        on each release). Streamed in chunks, never fully in RAM."""
        import os as _os
        apk = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)),
                            "static", "nasmusic.apk")
        try:
            size = _os.path.getsize(apk)
        except OSError:
            return self.send_error(404, "app not published yet")
        self.send_response(200)
        self.send_header("Content-Type",
                         "application/vnd.android.package-archive")
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Disposition",
                         'attachment; filename="gungan.fm.apk"')
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(apk, "rb") as fh:
            while True:
                chunk = fh.read(65536)
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    break
        return

    def _serve_user_file(self, rel):
        """Serve a file under the users root (/staging/u/...). Callers may
        only read inside their OWN home dir (ka0s -> Berta via override) —
        anything else is a 403. Same containment + range machinery."""
        state = self.state
        base = os.path.normpath(state.users.root)
        rel = posixpath.normpath(rel)
        if rel.startswith("../") or os.path.isabs(rel):
            return self._error(400, "bad path")
        try:
            home = os.path.basename(os.path.normpath(
                state.users.user_home(self._auth_user or "")))
        except Exception:                                # noqa: BLE001
            home = ""
        first = rel.split("/", 1)[0]
        if not home or first != home:
            return self._error(403, "not your file")
        path = os.path.normpath(os.path.join(base, rel))
        if not (path.startswith(base + os.sep) or path == base):
            return self._error(400, "bad path")
        if not os.path.isfile(path):
            return self._error(404, "no such file")
        self._stream_file(path)

    def _serve_file(self, rel, from_playlist=False):
        state = self.state
        base = (state.config.playlist_dir if from_playlist
                else state.config.music_root)
        base = os.path.normpath(base)
        rel = posixpath.normpath(rel)
        if rel.startswith("../") or os.path.isabs(rel):
            return self._error(400, "bad path")
        path = os.path.normpath(os.path.join(base, rel))
        if not (path.startswith(base + os.sep) or path == base):
            return self._error(400, "bad path")
        if not os.path.isfile(path):
            return self._error(404, "no such file")
        self._stream_file(path)

    def _stream_file(self, path):
        size = os.path.getsize(path)
        rng = self.headers.get("Range")
        ctype = mimetypes.guess_type(path)[0] or "audio/mpeg"
        cors = [
            ("Access-Control-Allow-Origin",
             self.headers.get("Origin") or "*"),
            ("Access-Control-Allow-Headers", "Content-Type"),
            ("Access-Control-Allow-Methods", "GET,POST,DELETE,OPTIONS"),
        ]
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng)
            start = end = None
            if m:
                if m.group(1):
                    start = int(m.group(1))
                if m.group(2):
                    end = int(m.group(2))
            if start is None and end is not None:
                start = max(0, size - end)
                end = size - 1
            if start is None:
                start = 0
            if end is None or end >= size:
                end = size - 1
            if start > end or start >= size:
                self.send_response(416)
                for k, v in cors:
                    self.send_header(k, v)
                self.send_header("Content-Range", f"bytes */{size}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            length = end - start + 1
            self.send_response(206)
            for k, v in cors:
                self.send_header(k, v)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Range",
                             f"bytes {start}-{end}/{size}")
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(length))
            self.end_headers()
            if self.command == "HEAD":
                return
            with open(path, "rb") as fh:
                fh.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = fh.read(min(64 * 1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            return
        self.send_response(200)
        for k, v in cors:
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(size))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as fh:
            while True:
                chunk = fh.read(64 * 1024)
                if not chunk:
                    break
                self.wfile.write(chunk)

    # ------------------------------------------------------------- verbs
    def do_GET(self):
        self._dispatch()

    def do_HEAD(self):
        self._dispatch()

    def do_POST(self):
        self._dispatch()

    def do_DELETE(self):
        self._dispatch()

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()


class NASMusicServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, addr, state):
        self.state = state
        super().__init__(addr, Handler)


def make_state(config=None):
    from .state import Config, State
    if config is None:
        config = Config()
    return State(config)
