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
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")
logger = logging.getLogger("nasmusic")

SAFE_PLAYLIST = re.compile(r"^[\w\-\{\}\.\(\) ]+$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "NASMusic/1.0"

    # ------------------------------------------------------------------ state
    @property
    def state(self):
        return self.server.state

    # ------------------------------------------------------------- plumbing
    def log_message(self, fmt, *args):          # quieter access log
        logger.info("%s - %s", self.address_string(), fmt % args)

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

    def _body_json(self):
        length = int(self.headers.get("Content-Length") or 0)
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

        # strip /staging prefix
        if path == "/staging" or path == "/staging/":
            return self._index()
        if not path.startswith("/staging/"):
            self.send_error(404, "not found")
            return
        rel = path[len("/staging/"):]
        parts = rel.split("/")

        try:
            if parts[0] == "api":
                self._route_api(parts[1:], query)
            elif parts[0] == "file":
                self._serve_file("/".join(parts[1:]), from_playlist=False)
            elif parts[0] == "pl":
                self._serve_file("/".join(parts[1:]), from_playlist=True)
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

        # ---- /api/stage
        if seg == "stage" and parts[1:] == []:
            if self.command == "POST":
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                artist = (body.get("artist") or "").strip()
                title = (body.get("title") or "").strip()
                if not title:
                    return self._error(400, "missing title")
                did, extra = self.state.pipeline.start_stage(
                    artist, title, force=bool(body.get("force")))
                return self._json({"id": did, **extra})

        # ---- /api/jobs
        if seg == "jobs" and parts[1:] == []:
            if self.command == "GET":
                return self._json({"jobs": self.state.pipeline.all_jobs()})

        # ---- /api/downloads
        if seg == "downloads":
            if parts[1:] == []:
                if self.command == "GET":
                    status = (query.get("status") or [None])[0]
                    rows = self.state.db.list_downloads(status)
                    for r in rows:
                        r.pop("url", None)
                    return self._json({"downloads": rows})
            elif len(parts) == 2:
                did = parts[1]
                if self.command == "GET":
                    row = self.state.db.get_download(did)
                    if not row:
                        return self._error(404, "unknown download")
                    cands = self.state.db.candidates_for(did)
                    row.pop("url", None)
                    current = row.get("video_id")
                    for c in cands:
                        c["is_current"] = c["video_id"] == current
                    return self._json({"download": row,
                                       "candidates": cands})
                if self.command == "DELETE":
                    return self._delete_download(did)

        # ---- /api/redownload
        if seg == "redownload" and parts[1:] == []:
            if self.command == "POST":
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                did = body.get("download_id")
                vid = body.get("video_id")
                if not did or not vid:
                    return self._error(400, "need download_id + video_id")
                _id, extra = self.state.pipeline.start_redownload(did, vid)
                return self._json(extra or {"ok": True, "id": did})

        # ---- /api/keep
        if seg == "keep" and parts[1:] == []:
            if self.command == "POST":
                return self._keep()

        # ---- /api/resolve
        if seg == "resolve" and len(parts) == 2:
            if self.command == "GET":
                return self._resolve(parts[1])

        # ---- /api/stream (proxy: resolve + relay so Android can play)
        if seg == "stream" and parts[1:] == []:
            if self.command == "GET":
                vid = (query.get("vid") or [""])[0]
                if not re.fullmatch(r"[A-Za-z0-9_\-]{5,80}", vid):
                    return self._error(400, "bad vid")
                return self._stream_remote(vid)

        # ---- /api/cover
        if seg == "cover" and parts[1:] == []:
            if self.command == "GET":
                f = (query.get("f") or [""])[0]
                if f:
                    return self._cover(f)
                vid = (query.get("vid") or [""])[0]
                if vid:
                    return self._cover_vid(vid)
                return self._error(400, "need f or vid")

        # ---- /api/tracks
        if seg == "tracks" and parts[1:] == []:
            if self.command == "GET":
                return self._tracks()

        # ---- /api/playlists
        if seg == "playlists":
            return self._playlists(parts[1:])

        self.send_error(404, "no such endpoint")

    # ---------------------------------------------------------- search
    def _search(self, q):
        state = self.state
        if " - " in q:
            artist, title = (p.strip() for p in q.split(" - ", 1))
        else:
            artist, title = None, None

        expected_dur = None
        if artist is None:
            meta = state.scorer.deezer_search(q)
            if meta:
                artist, title = meta["artist"], meta["title"]
                expected_dur = meta.get("duration_s")
        if title is None:
            title = q

        token_norms = [self._norm(w) for w in q.split()
                       if len(self._norm(w)) >= 2]
        local = []
        root = state.config.music_root
        for full in state._walk_mp3(root):
            base = os.path.basename(full)[:-4]
            hay = self._norm(base)
            if all(t in hay for t in token_norms):
                rel = state.rel_to_root(full)
                local.append({
                    "kind": "local", "base_name": base,
                    "folder": os.path.dirname(rel),
                    "url": "/staging/file/" + rel,
                })

        virtual = []
        try:
            cands = state.scorer.search(artist or "", title or q)
            artists = [a.strip() for a in
                       (artist or title or q).split(",")]
            scored, _cons = state.scorer.pick(cands, artists, title or q)
            if scored and expected_dur:
                scored.sort(key=lambda c: (
                    abs(c["duration_s"] - expected_dur) > 5
                    if c["duration_s"] else True,
                    -c["score"]))
            for c in scored[:8]:
                virtual.append({
                    "kind": "virtual", "video_id": c["video_id"],
                    "artist": artist or title or q,
                    "title": title or q,
                    "channel": c["channel"],
                    "duration_s": c["duration_s"],
                    "score": c["score"], "tier": c["tier"],
                    "stream_uri": f"staging:yt:{c['video_id']}",
                })
        except Exception:                             # noqa: BLE001
            logger.exception("discovery failed")

        return {"query": q,
                "resolved": {"artist": artist, "title": title},
                "local": sorted(local, key=lambda x: x["base_name"])[:20],
                "discovery": virtual}

    @staticmethod
    def _norm(s):
        import unicodedata
        s = unicodedata.normalize("NFKD", s or "")
        s = "".join(c for c in s if not unicodedata.combining(c)).lower()
        return re.sub(r"[^a-z0-9]+", "", s)

    # ------------------------------------------------------------ resolve
    def _resolve(self, video_id):
        state = self.state
        ttl = state.config.resolve_cache_ttl
        cached = state.db.resolved_cache_get(video_id, ttl)
        if cached:
            return self._json({"url": cached})
        url = state.scorer.resolve_url(video_id)
        if not url:
            return self._error(502, "resolve failed")
        state.db.resolved_cache_put(video_id, url)
        return self._json({"url": url})

    # ---------------------------------------------------------- stream proxy
    def _stream_remote(self, video_id):
        state = self.state
        ttl = state.config.resolve_cache_ttl
        url = state.db.resolved_cache_get(video_id, ttl)
        if not url:
            url = state.scorer.resolve_url(video_id)
            if not url:
                return self._error(502, "resolve failed")
            state.db.resolved_cache_put(video_id, url)
        return self._relay(url)

    def _relay(self, url, timeout=45):
        import shutil
        import urllib.request as u

        headers = {"User-Agent": "Mozilla/5.0", "Accept": "*/*"}
        rng = self.headers.get("Range")
        if rng:
            headers["Range"] = rng
        try:
            req = u.Request(url, headers=headers)
            resp = u.urlopen(req, timeout=timeout)
        except Exception as e:                       # noqa: BLE001
            logger.warning("stream relay open failed: %s", e)
            return self._error(502, "relay failed")
        try:
            status = getattr(resp, "status", 200)
            self.send_response(status if status in (200, 206) else 200)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Access-Control-Allow-Methods",
                             "GET,POST,DELETE,OPTIONS")
            self.send_header("Content-Type", resp.headers.get(
                "Content-Type") or "audio/webm")
            cl = resp.headers.get("Content-Length")
            if cl:
                self.send_header("Content-Length", cl)
            else:
                self.send_header("Connection", "close")
            if resp.headers.get("Content-Range"):
                self.send_header("Content-Range",
                                 resp.headers["Content-Range"])
            if resp.headers.get("Accept-Ranges"):
                self.send_header("Accept-Ranges",
                                 resp.headers["Accept-Ranges"])
            self.end_headers()
            if self.command != "HEAD":
                shutil.copyfileobj(resp, self.wfile, 64 * 1024)
        except Exception as e:                       # noqa: BLE001
            logger.warning("stream relay aborted: %s", e)
        finally:
            resp.close()

    # --------------------------------------------------------------- keep
    def _keep(self):
        from .lifecycle import append_entry, keep_staged
        from .pipeline import split_base

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
                    append_entry(state, playlist, found, keep_basename=True)
                    return self._json({"kept": True,
                                       "promoted_to": found})
                artist, title = (p.strip()
                                 for p in base.split(" - ", 1))
                state.db.create_download(artist, title)
                row = state.db.find_download_by_base(base)
                state.db.update_download(row["id"], keep_to=playlist)
                state.pipeline.start_stage(artist, title)
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
            append_entry(state, playlist, row["path"], keep_basename=True)
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
    def _playlists(self, parts):
        state = self.state

        if parts == []:
            if self.command == "GET":
                state.ensure_playlist_m3us()
                out = []
                for folder, m3u in state.playlist_paths():
                    n = 0
                    try:
                        with open(m3u, encoding="utf-8",
                                  errors="replace") as fh:
                            n = sum(1 for ln in fh
                                    if ln.strip()
                                    and not ln.startswith("#"))
                    except OSError:
                        n = 0
                    out.append({"name": folder, "tracks": n, "path": m3u})
                return self._json({"playlists": out})
            if self.command == "POST":
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                name = (body.get("name") or "").strip()
                if not SAFE_PLAYLIST.match(name):
                    return self._error(400, "bad playlist name")
                m3u = state.m3u_for(name)
                if not os.path.exists(m3u):
                    open(m3u, "w").close()
                if name not in state.config.folders:
                    state.config.folders.append(name)
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
                    state.db.set_added_meta(
                        name, base, ts, row.get("album_image"))
                    n += 1
                return self._json({"imported": n})

        # entry delete
        if len(rest) == 1 and rest[0] == "entries":
            if self.command == "DELETE":
                body = self._body_json()
                if body is None:
                    return self._error(400, "invalid JSON")
                base = (body.get("base_name") or "").strip()
                m3u = state.m3u_for(name)
                if not os.path.exists(m3u):
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

        # detail / delete (playlist itself)
        if rest == []:
            if self.command == "GET":
                return self._json(self._playlist_detail(name))
            if self.command == "DELETE":
                m3u = state.m3u_for(name)
                if os.path.exists(m3u):
                    os.remove(m3u)
                    return self._json({"deleted": name})
                return self._error(404, "no such playlist")

        self.send_error(404, "no such endpoint")

    def _playlist_detail(self, name):
        state = self.state
        m3u = state.m3u_for(name)
        m3u_dir = os.path.dirname(os.path.abspath(m3u))
        root = os.path.normpath(state.config.music_root)
        pldir = os.path.normpath(state.config.playlist_dir)
        entries = []
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
                    url = None
                    if exists:
                        try:
                            rp = os.path.relpath(p, root)
                        except ValueError:
                            rp = None
                        if rp and not rp.startswith(".."):
                            url = "/staging/file/" + rp
                        else:
                            try:
                                rp2 = os.path.relpath(p, pldir)
                            except ValueError:
                                rp2 = None
                            if rp2 and not rp2.startswith(".."):
                                url = "/staging/pl/" + rp2
                    base = os.path.basename(
                        ln[:-4] if ln.endswith(".mp3") else ln)
                    row = state.db.find_download_by_base(base)
                    album_image = None
                    added_at = None
                    if row and row.get("video_id"):
                        album_image = ("https://i.ytimg.com/vi/"
                                       + row["video_id"] + "/hqdefault.jpg")
                    meta = state.db.added_meta_get(name, base)
                    if meta:
                        added_at = meta["added_at"]
                        if meta["album_image"]:
                            album_image = meta["album_image"]
                    entries.append({
                        "base_name": base, "path": p, "exists": exists,
                        "url": url, "added_at": added_at,
                        "album_image": album_image,
                    })
        return {"name": name, "entries": entries}

    # ------------------------------------------------------------ delete
    def _delete_download(self, did):
        state = self.state
        row = state.db.get_download(did)
        if not row:
            return self._error(404, "unknown download")
        base = row["base_name"]
        fname = f"{base}.mp3"
        # remove the actual file wherever it lives (staged or kept)
        for full in state._walk_mp3(state.config.music_root):
            if os.path.basename(full) == fname:
                os.remove(full)
        for full in state._walk_mp3(state.config.staging_dir):
            if os.path.basename(full) == fname:
                os.remove(full)
        for folder, m3u in state.playlist_paths():   # drop references
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
        s = self.state
        return self._json({
            "service": "nasmusic",
            "music_root": s.config.music_root,
            "staging_dir": s.config.staging_dir,
            "folders": s.config.folders,
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
        path = os.path.normpath(os.path.join(base_dir, f))
        allowed = path.startswith(base_dir + os.sep) or path == base_dir
        if not allowed:
            return self._error(400, "bad path")

        data = self._extract_embedded(path) if os.path.exists(path) else None
        if data:
            body, ctype = data
            return self._redirect_or_body(body, ctype)

        base_name = os.path.basename(path)[:-4]
        row = None
        for r in state.db.query(
                "SELECT video_id FROM downloads WHERE base_name=? "
                "AND video_id IS NOT NULL", (base_name,)):
            row = r
            break
        if row and row["video_id"]:
            return self._redirect(
                f"https://i.ytimg.com/vi/{row['video_id']}/hqdefault.jpg")

        img_row = state.db.added_meta_get(
            self._playlist_hint(f), base_name)
        if img_row and img_row.get("album_image"):
            return self._redirect(img_row["album_image"])

        if os.path.exists(path):
            cover = state.scorer._deezer_cover(base_name)
            if cover:
                return self._redirect(cover)
        return self.send_error(404, "no artwork")

    def _playlist_hint(self, f):
        return None

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
        try:
            req = urllib.request.Request(
                f"https://i.ytimg.com/vi/{video_id}/mqdefault.jpg",
                headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read()
                ctype = resp.headers.get("Content-Type", "image/jpeg")
            if len(body) < 64:
                return self.send_error(404, "no artwork")
            with self._cover_cache_lock:
                self._cover_cache[key] = (body, ctype)
            return self._redirect_or_body(body, ctype)
        except Exception as ex:                       # noqa: BLE001
            logger.info("cover vid failed: %s", str(ex)[:80])
            return self.send_error(502, "cover fetch failed")

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
