"""HTTP API served under /staging/.

The Flutter apps talk exclusively to these endpoints; Mopidy's own
JSON-RPC stays available for desktop MPD-style clients.
"""

import json
import shutil
import logging
import os
import re

import tornado.web
from tornado.ioloop import IOLoop

from .lifecycle import promote_if_referenced
from .scorer import norm

logger = logging.getLogger(__name__)

SAFE_PLAYLIST = re.compile(r"^[\w\-\{\}\.\(\) ]+$")


class BaseHandler(tornado.web.RequestHandler):
    def prepare(self):
        self.set_header("Access-Control-Allow-Origin", "*")
        self.set_header("Access-Control-Allow-Headers", "Content-Type")
        self.set_header("Access-Control-Allow-Methods",
                        "GET,POST,DELETE,OPTIONS")

    def options(self, *args, **kwargs):
        self.set_status(204)

    @property
    def state(self):
        from .state import StagingState
        return StagingState.instance()

    async def offload(self, fn, *args):
        return await IOLoop.current().run_in_executor(None, fn, *args)

    def write_json(self, obj, status=200):
        self.set_status(status)
        self.set_header("Content-Type", "application/json")
        self.write(json.dumps(obj, ensure_ascii=False))

    def body_json(self):
        try:
            return json.loads(self.request.body.decode("utf-8") or "{}")
        except json.JSONDecodeError:
            raise tornado.web.HTTPError(400, "invalid JSON body")

    def write_error(self, status_code, **kwargs):
        self.write_json({"error": self._reason}, status=status_code)


class IndexHandler(BaseHandler):
    def get(self):
        s = self.state
        self.write_json({
            "service": "mopidy-staging",
            "music_root": s.music_root,
            "staging_dir": s.staging_dir,
            "folders": s.folders,
            "expiry_days": s.expiry_days,
            "discovery_available": shutil.which(s.yt_dlp_bin) is not None,
        })


class SearchHandler(BaseHandler):
    """Local library matches + discovery candidates for one query."""

    async def get(self):
        q = self.get_argument("q", "").strip()
        if not q:
            raise tornado.web.HTTPError(400, "missing q")
        results = await self.offload(self._search_sync, q)
        self.write_json(results)

    def _search_sync(self, q):
        state = self.state
        if " - " in q:
            artist, title = (p.strip() for p in q.split(" - ", 1))
        else:
            artist, title = None, None

        expected_dur = None
        if artist is None:
            # free text: let Deezer identify the actual song
            meta = state.pipeline.scorer.deezer_search(q)
            if meta:
                artist, title = meta["artist"], meta["title"]
                expected_dur = meta.get("duration_s")
        if title is None:
            title = q

        # ---- local files: every word must appear somewhere in the name
        token_norms = [norm(w) for w in q.split() if len(norm(w)) >= 2]
        local = []
        for root, dirs, files in os.walk(state.music_root):
            dirs[:] = [d for d in dirs if d != "_Staging"]
            for f in files:
                if not f.endswith(".mp3"):
                    continue
                hay = norm(f[:-4])
                if all(t in hay for t in token_norms):
                    full = os.path.join(root, f)
                    rel = os.path.relpath(full, state.music_root)
                    local.append({
                        "kind": "local",
                        "base_name": f[:-4],
                        "folder": os.path.dirname(rel),
                        "url": f"/staging/file/{rel}",
                    })

        # ---- discovery via YouTube scorer
        virtual = []
        try:
            cands = state.pipeline.scorer.search(
                artist or "", title or q)
            artists = [a.strip()
                       for a in (artist or title or q).split(",")]
            scored, _cons = state.pipeline.scorer.pick(
                cands, artists, title or q)
            if scored and expected_dur:
                # pull the true studio version to the front when close
                scored.sort(key=lambda c: (
                    abs(c["duration_s"] - expected_dur) > 5
                    if c["duration_s"] else True,
                    -c["score"]))
            for c in scored[:8]:
                virtual.append({
                    "kind": "virtual",
                    "video_id": c["video_id"],
                    "artist": artist or title or q,
                    "title": title or q,
                    "channel": c["channel"],
                    "duration_s": c["duration_s"],
                    "score": c["score"],
                    "tier": c["tier"],
                    "stream_uri": f"staging:yt:{c['video_id']}",
                })
        except Exception:                            # noqa: BLE001
            logger.exception("discovery failed")
        return {"query": q, "resolved": {"artist": artist, "title": title},
                "local": sorted(local, key=lambda x: x["base_name"])[:20],
                "discovery": virtual}


class StageHandler(BaseHandler):
    def post(self):
        body = self.body_json()
        artist = (body.get("artist") or "").strip()
        title = (body.get("title") or "").strip()
        if not title:
            raise tornado.web.HTTPError(400, "missing title")
        did, extra = self.state.pipeline.start_stage(
            artist, title, force=bool(body.get("force")))
        self.write_json({"id": did, **extra})


class JobsHandler(BaseHandler):
    def get(self):
        self.write_json({"jobs": self.state.pipeline.all_jobs()})


class DownloadsHandler(BaseHandler):
    def get(self):
        status = self.get_argument("status", None)
        rows = self.state.db.list_downloads(status)
        for r in rows:
            r.pop("url", None)
        self.write_json({"downloads": rows})


class DownloadDetailHandler(BaseHandler):
    def get(self, did):
        row = self.state.db.get_download(did)
        if not row:
            raise tornado.web.HTTPError(404)
        cands = self.state.db.candidates_for(did)
        row.pop("url", None)
        current = row.get("video_id")
        for c in cands:
            c["is_current"] = c["video_id"] == current
        self.write_json({"download": row,
                         "candidates": cands})   # ranked best-first

    def delete(self, did):
        state = self.state
        row = state.db.get_download(did)
        if not row:
            raise tornado.web.HTTPError(404)
        base = row["base_name"]
        fname = f"{base}.mp3"
        for root, _dirs, files in os.walk(state.music_root):
            if fname in files:
                os.remove(os.path.join(root, fname))
        for _folder, m3u in state.playlist_paths():   # drop references
            try:
                lines = open(m3u, encoding="utf-8").readlines()
            except OSError:
                continue
            keep = [ln for ln in lines
                    if os.path.basename(ln.strip()) != fname]
            if len(keep) != len(lines):
                open(m3u, "w", encoding="utf-8").writelines(keep)
        state.db.update_download(did, status="deleted", path=None)
        state.db.event("deleted", {"id": did})
        self.write_json({"ok": True})


class RedownloadHandler(BaseHandler):
    def post(self):
        body = self.body_json()
        did = body.get("download_id")
        vid = body.get("video_id")
        if not did or not vid:
            raise tornado.web.HTTPError(400, "need download_id + video_id")
        _did, extra = self.state.pipeline.start_redownload(did, vid)
        self.write_json(extra or {"ok": True, "id": did})


class KeepHandler(BaseHandler):
    """Spotify-style 'add to playlist' from any state.

    staged file   -> moved out of _Staging now
    downloading   -> queued: auto-kept when the download verifies
    not on server -> download starts, then auto-keep
    already kept  -> entry appended to the playlist
    """

    def _find_in_library(self, filename):
        for root, _dirs, files in os.walk(self.state.music_root):
            if filename in files:
                return os.path.join(root, filename)
        return None

    def post(self):
        from .lifecycle import append_entry, keep_staged
        from .pipeline import split_base

        body = self.body_json()
        playlist = (body.get("playlist") or "").strip()
        if not playlist or not SAFE_PLAYLIST.match(playlist):
            raise tornado.web.HTTPError(400, "bad playlist name")
        did = body.get("download_id")
        base = (body.get("base_name") or "").strip()
        state = self.state

        row = state.db.get_download(did) if did else \
            state.db.find_download_by_base(base or "")

        # never seen before: maybe a library file, else start fresh
        if row is None:
            if base and " - " in base:
                found = self._find_in_library(f"{base}.mp3")
                if found:
                    append_entry(state, playlist, found)
                    return self.write_json(
                        {"kept": True, "promoted_to": found})
                artist, title = (p.strip() for p in base.split(" - ", 1))
                state.db.create_download(artist, title)
                row = state.db.find_download_by_base(base)
                state.db.update_download(row["id"], keep_to=playlist)
                state.pipeline.start_stage(artist, title)
                return self.write_json({"queued": True})
            raise tornado.web.HTTPError(404, "unknown track")

        status = row["status"]
        if status == "staged":
            path = row.get("path") or ""
            if os.path.dirname(path) == state.staging_dir \
                    and os.path.exists(path):
                state.db.update_download(row["id"], keep_to=playlist)
                dest = keep_staged(state, state.db.get_download(row["id"]))
                state.db.update_download(row["id"], keep_to=None)
                return self.write_json({"kept": True, "promoted_to": dest})

        if status == "kept" and row.get("path"):
            append_entry(state, playlist, row["path"])
            return self.write_json({"kept": True, "path": row["path"]})

        if status in ("expired", "deleted", "failed", "giveup",
                      "no_results", "no_official"):
            state.db.update_download(row["id"], keep_to=playlist)
            state.pipeline.retry(row["id"])
            return self.write_json({"queued": True, "retrying": True})

        # actively downloading/pending/searching
        state.db.update_download(row["id"], keep_to=playlist)
        self.write_json({"queued": True})


class PlaylistsHandler(BaseHandler):
    def get(self):
        out = []
        for folder, m3u in self.state.playlist_paths():
            try:
                n = sum(1 for ln in open(m3u, encoding="utf-8")
                        if ln.strip() and not ln.startswith("#"))
            except OSError:
                n = 0
            out.append({"name": folder, "tracks": n, "path": m3u})
        self.write_json({"playlists": out})

    def post(self):
        name = self.body_json().get("name", "").strip()
        if not SAFE_PLAYLIST.match(name):
            raise tornado.web.HTTPError(400, "bad playlist name")
        m3u = self.state.m3u_for(name)
        if not os.path.exists(m3u):
            open(m3u, "w").close()
        if name not in self.state.folders:
            self.state.folders.append(name)
        self.write_json({"created": name})


class ResolveHandler(BaseHandler):
    """Direct streamable URL for a discovery candidate (phone playback)."""

    async def get(self, video_id):
        url = await self.offload(
            self.state.pipeline.scorer.resolve_url, video_id)
        if not url:
            raise tornado.web.HTTPError(502, "resolve failed")
        self.state.db.resolved_cache_put(video_id, url)
        self.write_json({"url": url})


class PlaylistDetailHandler(BaseHandler):
    def get(self, name):
        m3u = self.state.m3u_for(name)
        m3u_dir = os.path.dirname(os.path.abspath(m3u))
        root = os.path.normpath(self.state.music_root)
        entries = []
        if os.path.exists(m3u):
            with open(m3u, encoding="utf-8", errors="replace") as fh:
                for ln in fh:
                    ln = ln.strip()
                    if not ln or ln.startswith("#"):
                        continue
                    # resolve: absolute | relative-to-m3u (m3u spec) |
                    # relative-to-library-root
                    p = ln
                    if not os.path.isabs(p):
                        cand = os.path.normpath(os.path.join(m3u_dir, p))
                        alt = os.path.normpath(os.path.join(root, p))
                        p = cand if os.path.exists(cand) else alt
                    exists = os.path.exists(p)
                    url = None
                    pldir = os.path.normpath(self.state.playlist_dir)
                    if exists:
                        try:
                            rp = os.path.relpath(p, root)
                        except ValueError:
                            rp = None
                        if rp and not rp.startswith("..") \
                                and not rp.startswith(".." + os.sep):
                            url = "/staging/file/" + rp
                        else:
                            try:
                                rp2 = os.path.relpath(p, pldir)
                            except ValueError:
                                rp2 = None
                            if rp2 and not rp2.startswith("."):
                                url = "/staging/pl/" + rp2
                    base = os.path.basename(ln[:-4]
                                            if ln.endswith(".mp3")
                                            else ln)
                    entries.append({
                        "base_name": base,
                        "path": p,
                        "exists": exists,
                        "url": url,
                    })
        meta = {}
        for r in self.state.db.query(
                "SELECT * FROM added_meta WHERE playlist=?", (name,)):
            meta[r["base_name"]] = r
        for e in entries:
            m = meta.get(e["base_name"])
            if m:
                e["added_at"] = m["added_at"]
                e["album_image"] = m["album_image"]
        self.write_json({"name": name, "entries": entries})


class CoverHandler(BaseHandler):
    """Album art for a library file: embedded -> YouTube thumb -> Deezer."""

    CACHE = os.path.expanduser("~/.cache/mopidy-staging/covers")
    _deezer_urls = {}

    def _extract(self, path):
        import hashlib
        os.makedirs(self.CACHE, exist_ok=True)
        key = hashlib.sha1(
            f"{path}|{int(os.path.getmtime(path))}".encode()).hexdigest()
        cached = os.path.join(self.CACHE, key)
        if os.path.exists(cached):
            with open(cached, "rb") as fh:
                return fh.read(), "image/jpeg"
        try:
            from mutagen import File as MFile
            audio = MFile(path)
            data = mime = None
            tags = getattr(audio, "tags", None)
            if tags is None:
                return None
            if hasattr(tags, "getall"):          # ID3 (mp3)
                for pic in tags.getall("APIC"):
                    data, mime = pic.data, pic.mime
                    break
            elif "METADATA_BLOCK_PICTURE" in tags:   # flac/ogg
                import base64
                from mutagen.flac import Picture
                pics = Picture()
                pics.parse(base64.b64decode(tags["METADATA_BLOCK_PICTURE"][0]))
                data, mime = pics.data, pics.mime
        except Exception:                            # noqa: BLE001
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
        ctype = "image/png" if ext == ".png" else "image/jpeg"
        return data, ctype

    def _deezer_cover_url(self, base_name):
        if base_name in self._deezer_urls:
            return self._deezer_urls[base_name]
        try:
            import json as _json
            import urllib.parse
            import urllib.request
            q = urllib.parse.quote(base_name)
            url = f"https://api.deezer.com/search?q={q}&limit=1"
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0"})
            data = _json.load(urllib.request.urlopen(req, timeout=10))
            items = data.get("data") or []
            cover = ((items[0].get("album") or {}).get("cover_big")
                     if items else None)
            self._deezer_urls[base_name] = cover
            return cover
        except Exception:                            # noqa: BLE001
            return None

    async def get(self):
        f = self.get_argument("f")
        root = os.path.normpath(self.state.music_root)
        base_dir = root
        if f.startswith("pl:"):
            f = f[3:]
            base_dir = os.path.normpath(self.state.playlist_dir)
        path = os.path.normpath(os.path.join(base_dir, f))
        allowed = path.startswith(base_dir + os.sep) or path == base_dir
        if not allowed:
            raise tornado.web.HTTPError(400, "bad path")

        got = await self.offload(self._extract, path) \
            if os.path.exists(path) else None
        if got:
            data, ctype = got
            self.set_header("Content-Type", ctype)
            self.set_header("Cache-Control", "max-age=86400")
            self.write(data)
            return

        # fallback 1: our download DB knows the YouTube source
        base_name = os.path.basename(path)[:-4]
        row = state_row = None
        for r in self.state.db.query(
                "SELECT video_id FROM downloads WHERE base_name=? "
                "AND video_id IS NOT NULL", (base_name,)):
            state_row = r
            break
        if state_row:
            self.redirect(
                "https://i.ytimg.com/vi/"
                + state_row["video_id"] + "/hqdefault.jpg", permanent=False)
            return

        # fallback 2: imported album image from playlist exports
        img_row = None
        for r in self.state.db.query(
                "SELECT album_image FROM added_meta WHERE base_name=? "
                "AND album_image IS NOT NULL", (base_name,)):
            img_row = r
            break
        if img_row and img_row["album_image"]:
            self.redirect(img_row["album_image"], permanent=False)
            return

        # fallback 3: Deezer album art by artist - title
        if os.path.exists(path):
            cover = await self.offload(self._deezer_cover_url, base_name)
            if cover:
                self.redirect(cover, permanent=False)
                return
        raise tornado.web.HTTPError(404, "no artwork")


class SimilarHandler(BaseHandler):
    """Seed tracks for the endless queue: same-artist songs."""

    async def get(self):
        artist = self.get_argument("artist", "").strip()
        genre = self.get_argument("genre", "").strip()
        exclude = [x for x in
                   self.get_argument("exclude", "").split("||") if x]
        n = int(self.get_argument("n", "8"))
        query = f"{genre} music" if genre else f"{artist} songs"
        if not query.strip():
            raise tornado.web.HTTPError(400, "missing query")
        cands = await self.offload(
            self.state.pipeline.scorer.search_ytmusic, query)
        from .scorer import norm as _norm
        excl = {_norm(t) for t in exclude}
        out = []
        for c in cands:
            if _norm(c["title"]) in excl:
                continue
            if any(_norm(f"{artist} - {c['title']}") == _norm(e)
                   for e in exclude):
                continue
            out.append({
                "video_id": c["video_id"],
                "title": c["title"],
                "channel": c["channel"],
                "duration_s": c["duration_s"],
            })
            if len(out) >= n:
                break
        self.write_json({"similar": out})


class LyricsHandler(BaseHandler):
    """Parsed .lrc for a library file, when present."""

    async def get(self):
        import re as _re
        f = self.get_argument("f")
        root = os.path.normpath(self.state.music_root)
        path = os.path.normpath(os.path.join(root, f))
        if not path.startswith(root + os.sep):
            raise tornado.web.HTTPError(400, "bad path")
        lrc = os.path.splitext(path)[0] + ".lrc"
        if not os.path.exists(lrc):
            raise tornado.web.HTTPError(404, "no lyrics")
        out = []
        ts = _re.compile(r"\[(\d+):(\d+)(?:[.:](\d+))?\]")
        plain = []
        with open(lrc, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                m = ts.findall(line)
                text = ts.sub("", line).strip()
                if not text:
                    continue
                if m:
                    for mm in m:
                        mins, secs, frac = int(mm[0]), int(mm[1]), mm[2]
                        ms = (mins * 60 + secs) * 1000 +                              int((frac or "0").ljust(3, "0")[:3])
                        out.append({"t": ms, "text": text})
                else:
                    plain.append(text)
        out.sort(key=lambda x: x["t"])
        self.write_json({"synced": out,
                         "plain": None if out else "\n".join(plain)})


class TracksHandler(BaseHandler):
    """Whole-library index for Artists browse mode."""

    async def get(self):
        root = self.state.music_root
        items = []
        for rpath, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d != "_Staging"]
            for fn in files:
                if not fn.endswith(".mp3"):
                    continue
                base = fn[:-4]
                rel = os.path.relpath(os.path.join(rpath, fn), root)
                artist = base.split(" - ")[0].strip() if " - " in base else ""
                items.append({"base_name": base, "folder":
                              os.path.dirname(rel), "url":
                              "/staging/file/" + rel, "artist": artist})
        self.write_json({"tracks": items})


class ImportMetaHandler(BaseHandler):
    """Ingest Spotify-export metadata: added-at dates + album art."""

    async def post(self, name):
        import datetime as _dt
        body = self.body_json()
        if not isinstance(body, list):
            raise tornado.web.HTTPError(400, "expected a list")
        n = 0
        for row in body:
            base = (row.get("base_name") or "").strip()
            if not base:
                continue
            added = row.get("added_at")
            ts = None
            if added:
                try:
                    iso = str(added).replace("Z", "+00:00")
                    ts = _dt.datetime.fromisoformat(iso).timestamp()
                except ValueError:
                    ts = None
            self.state.db.execute(
                """INSERT OR REPLACE INTO added_meta
                   (playlist, base_name, added_at, album_image)
                   VALUES(?,?,?,?)""",
                (name, base, ts, row.get("album_image")))
            n += 1
        self.write_json({"imported": n})


class PlaylistEntryHandler(BaseHandler):
    """DELETE an entry from a playlist m3u."""

    def delete(self, name):
        body = self.body_json()
        base = (body.get("base_name") or "").strip()
        m3u = self.state.m3u_for(name)
        if not os.path.exists(m3u):
            raise tornado.web.HTTPError(404, "no such playlist")
        kept = []
        with open(m3u, encoding="utf-8", errors="replace") as fh:
            for ln in fh:
                s = ln.strip()
                if not s or s.startswith("#"):
                    continue
                bn = os.path.basename(s)
                stem = bn[:-4] if bn.endswith('.mp3') else bn
                if base not in (bn, stem):
                    kept.append(s)
        with open(m3u, "w", encoding="utf-8") as fh:
            fh.write("\n".join(kept) + ("\n" if kept else ""))
        self.write_json({"removed": base, "remaining": len(kept)})


class PlaylistDeleteHandler(BaseHandler):
    """DELETE a whole playlist file."""

    def delete(self, name):
        m3u = self.state.m3u_for(name)
        if os.path.exists(m3u):
            os.remove(m3u)
            self.write_json({"deleted": name})
        else:
            raise tornado.web.HTTPError(404, "no such playlist")


def make_staging_app_factory():
    def factory(config, core):
        from .state import StagingState
        StagingState.configure(config)
        music_root = StagingState.instance().music_root
        return [
            (r"/", IndexHandler),
            (r"/api/search", SearchHandler),
            (r"/api/stage", StageHandler),
            (r"/api/jobs", JobsHandler),
            (r"/api/downloads", DownloadsHandler),
            (r"/api/downloads/([^/]+)", DownloadDetailHandler),
            (r"/api/redownload", RedownloadHandler),
            (r"/api/keep", KeepHandler),
            (r"/api/cover", CoverHandler),
            (r"/api/playlists", PlaylistsHandler),
            (r"/api/playlists/([^/]+)/meta", ImportMetaHandler),
            (r"/api/playlists/([^/]+)/entries", PlaylistEntryHandler),
            (r"/api/playlists/([^/]+)", PlaylistDetailHandler),
            (r"/api/resolve/([^/]+)", ResolveHandler),
            (r"/api/similar", SimilarHandler),
            (r"/api/lyrics", LyricsHandler),
            (r"/api/tracks", TracksHandler),
            (r"/file/(.*)", tornado.web.StaticFileHandler,
             {"path": music_root}),
            (r"/pl/(.*)", tornado.web.StaticFileHandler,
             {"path": StagingState.instance().playlist_dir}),
        ]
    return factory
