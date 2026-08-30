#!/usr/bin/env python3
"""End-to-end smoke test for the NASMusic server.

Starts the server on a temp library, then exercises every endpoint the
apps rely on: index, search (local + discovery), playlists CRUD,
playlist detail, keep, resolve, cover, file streaming with ranges,
downloads, jobs, tracks. Uses only local/library-dependent behaviour that
can run offline (network discovery is best-effort and reported, not fatal).
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(HERE)
PORT = 6890
BASE = f"http://127.0.0.1:{PORT}/staging"
RESULTS = []


def ok(name, msg=""):
    RESULTS.append((True, name, msg))
    print(f"  PASS  {name} {msg}")


def fail(name, msg):
    RESULTS.append((False, name, msg))
    print(f"  FAIL  {name} {msg}")


def http(method, path, body=None, headers=None):
    url = BASE + urllib.parse.quote(path, safe="/:@?=&%")
    data = None
    hdrs = dict(headers or {})
    if isinstance(body, dict):
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data,
                                 headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, r.headers, raw
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read()


def json_of(status, headers, raw):
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return {"_raw": raw[:200].decode("utf-8", "replace")}


def main():
    tmp = tempfile.mkdtemp(prefix="nasmusic-test-")
    lib = os.path.join(tmp, "music")
    staging = os.path.join(tmp, "staging")
    play = os.path.join(tmp, "playlists")
    os.makedirs(lib, exist_ok=True)
    os.makedirs(staging, exist_ok=True)

    sample = "Test Artist - Demo Song.mp3"
    # generate a real mp3 with embedded art tag so cover extraction works
    cover = os.path.join(tmp, "cover.png")
    subprocess.run([
        "ffmpeg", "-v", "error", "-f", "lavfi",
        "-i", "color=c=red:s=64x64:d=1", "-frames:v", "1", cover,
    ], check=True)
    subprocess.run([
        "ffmpeg", "-v", "error", "-f", "lavfi",
        "-i", "sine=frequency=440:duration=20",
        "-i", cover,
        "-map", "0:a", "-map", "1:v",
        "-c:a", "libmp3lame", "-q:a", "5",
        "-id3v2_version", "3",
        "-metadata:s:v", "title=Album cover",
        "-metadata:s:v", "comment=Cover (front)",
        "-metadata", "artist=Test Artist",
        "-metadata", "title=Demo Song",
        os.path.join(lib, sample),
    ], check=True)

    env = dict(os.environ)
    env["NASMUSIC_MUSIC_ROOT"] = lib
    env["NASMUSIC_STAGING_DIR"] = staging
    env["NASMUSIC_PLAYLIST_DIR"] = play
    env["NASMUSIC_PORT"] = str(PORT)
    env["NASMUSIC_DB_PATH"] = os.path.join(tmp, "nasmusic.db")

    proc = subprocess.Popen(
        [sys.executable, "-m", "nasmusic", "--no-expiry"],
        cwd=SERVER_DIR, env=env,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        for _ in range(40):
            try:
                s, h, raw = http("GET", "/")
                if s == 200:
                    break
            except Exception:
                time.sleep(0.5)
        else:
            fail("server-start", "server did not come up")
            return 1

        # ---- index
        s, h, raw = http("GET", "/")
        idx = json_of(s, h, raw)
        if idx.get("service") == "nasmusic":
            ok("index", f"service={idx['service']}")
        else:
            fail("index", str(idx))

        # ---- local search
        s, h, raw = http("GET", "/api/search?q=" + urllib.parse.quote(
            "Test Artist Demo Song"))
        sr = json_of(s, h, raw)
        local = sr.get("local") or []
        if any("Demo Song" in (x.get("base_name") or "") for x in local):
            ok("search-local", f"{len(local)} local hits")
        else:
            fail("search-local", f"local={local}")

        # ---- discovery (best-effort; requires network/yt-dlp)
        s, h, raw = http("GET", "/api/search?q=" + urllib.parse.quote(
            "Daft Punk Get Lucky"))
        sr2 = json_of(s, h, raw)
        disc = sr2.get("discovery") or []
        print(f"  INFO  discovery returned {len(disc)} candidates "
              f"(network-dependent)")

        # ---- tracks
        s, h, raw = http("GET", "/api/tracks")
        tr = json_of(s, h, raw)
        if any("Demo Song" in (t.get("base_name") or "")
               for t in tr.get("tracks", [])):
            ok("tracks")
        else:
            fail("tracks", str(tr)[:120])

        # capture the library file's stream url from the local search
        local_file_url = None
        for x in sr.get("local") or []:
            if "Demo Song" in (x.get("base_name") or ""):
                local_file_url = x.get("url")
                break

        # ---- stream the local file + Range request (seek)
        if local_file_url:
            fpath = local_file_url[len("/staging"):]   # -> /file/...
            s, h, raw = http("GET", fpath, None)
            size = int(h.get("Content-Length", 0))
            if s == 200 and size > 0:
                ok("file-stream", f"{size} bytes")
            else:
                fail("file-stream", f"{s} size={size}")
            s, h, raw = http("GET", fpath,
                             headers={"Range": "bytes=100-199"})
            if s == 206 and len(raw) == 100:
                ok("file-range", "206, 100 bytes")
            else:
                fail("file-range", f"{s} len={len(raw)}")
            # HEAD request (used by some clients)
            s, h, raw = http("HEAD", fpath, None)
            if s == 200:
                ok("file-head")
            else:
                fail("file-head", f"{s}")
        else:
            fail("stream-url", "no local file url")

        # ---- cover extraction (embedded art -> 200 image or redirect)
        if local_file_url:
            rel_file = local_file_url[len("/staging/file/"):]
            s, h, raw = http("GET", "/api/cover?f=" +
                             urllib.parse.quote(rel_file))
            if s in (200, 302):
                ok("cover", f"status={s}")
            else:
                fail("cover", f"status={s} raw={raw[:100]}")

        # ---- playlists CRUD
        s, h, raw = http("POST", "/api/playlists", {"name": "TestList"})
        if s in (200, 201) and json_of(s, h, raw).get("created"):
            ok("playlist-create")
        else:
            fail("playlist-create", f"{s} {raw[:120]}")
        s, h, raw = http("GET", "/api/playlists")
        pls = json_of(s, h, raw).get("playlists", [])
        if any(p["name"] == "TestList" for p in pls):
            ok("playlist-list")
        else:
            fail("playlist-list", str(pls)[:120])

        # ---- keep a local library file into the playlist
        s, h, raw = http("POST", "/api/keep",
                         {"base_name": "Test Artist - Demo Song",
                          "playlist": "TestList"})
        keep = json_of(s, h, raw)
        if keep.get("kept"):
            ok("keep-local", f"promoted={keep.get('promoted_to')}")
        else:
            fail("keep-local", str(keep))

        # ---- playlist detail now has 1 entry with a streamable url
        s, h, raw = http("GET", "/api/playlists/TestList")
        det = json_of(s, h, raw)
        entries = det.get("entries") or []
        if len(entries) == 1 and entries[0]["exists"]:
            ok("playlist-detail", f"{len(entries)} entry, url={entries[0]['url']}")
        else:
            fail("playlist-detail", str(det)[:150])
        entry_url = entries[0]["url"] if entries else None
        if entry_url:
            ok("playlist-entry-url", entry_url)

        # ---- resolve (best-effort, needs network)
        if disc:
            vid = disc[0]["video_id"]
            s, h, raw = http("GET", f"/api/resolve/{vid}")
            print(f"  INFO  resolve status={s} (network-dependent)")

        # ---- stage a download (best-effort, needs network + yt-dlp)
        s, h, raw = http("POST", "/api/stage",
                         {"artist": "Daft Punk", "title": "Get Lucky"})
        st = json_of(s, h, raw)
        print(f"  INFO  stage id={st.get('id')} skipped={st.get('skipped')} "
              f"(network-dependent)")
        if st.get("id"):
            ok("stage-accepted", st.get("id"))
            s, h, raw = http("GET", "/api/jobs")
            jobs = json_of(s, h, raw).get("jobs", [])
            if any(j["id"] == st["id"] for j in jobs):
                ok("jobs-list")
            else:
                fail("jobs-list", str(jobs)[:120])

        # ---- remove playlist
        s, h, raw = http("DELETE", "/api/playlists/TestList")
        if s == 200:
            ok("playlist-delete")
        else:
            fail("playlist-delete", f"{s}")

        print()
        npass = sum(1 for x in RESULTS if x[0])
        nfail = len(RESULTS) - npass
        print(f"RESULT: {npass} passed, {nfail} failed")
        return 1 if nfail else 0
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
