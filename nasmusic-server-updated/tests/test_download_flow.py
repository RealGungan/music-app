#!/usr/bin/env python3
"""Integration test for the real staging download + keep flow (network).

Starts the server, stages a well-known track, waits for the download to
finish, then keeps it into a playlist and verifies the file is moved to
the library and the playlist contains it.

This test needs working network + yt-dlp and can take a couple of minutes.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER_DIR = os.path.dirname(HERE)
PORT = 6896
BASE = f"http://127.0.0.1:{PORT}/staging"


def http(method, path, body=None):
    url = BASE + urllib.parse.quote(path, safe="/:@?=&%")
    data = None
    hdrs = {}
    if isinstance(body, dict):
        data = json.dumps(body).encode()
        hdrs["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=hdrs, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def main():
    tmp = tempfile.mkdtemp(prefix="nasmusic-dl-")
    lib = os.path.join(tmp, "music")
    staging = os.path.join(tmp, "staging")
    play = os.path.join(tmp, "playlists")
    os.makedirs(lib); os.makedirs(staging); os.makedirs(play)

    env = dict(os.environ)
    env["NASMUSIC_MUSIC_ROOT"] = lib
    env["NASMUSIC_STAGING_DIR"] = staging
    env["NASMUSIC_PLAYLIST_DIR"] = play
    env["NASMUSIC_PORT"] = str(PORT)
    env["NASMUSIC_DB_PATH"] = os.path.join(tmp, "nasmusic.db")

    srvlog = os.path.join(tmp, "server.log")
    slog = open(srvlog, "w")
    proc = subprocess.Popen(
        [sys.executable, "-m", "nasmusic", "--no-expiry"],
        cwd=SERVER_DIR, env=env,
        stdout=slog, stderr=subprocess.STDOUT)
    try:
        for _ in range(60):
            try:
                if http("GET", "/")[0] == 200:
                    break
            except Exception:
                pass
            time.sleep(0.5)
        else:
            out = proc.stdout.read().decode(errors="replace") \
                if proc.stdout else ""
            fail_server = out
            print("SERVER OUTPUT:\n" + fail_server[-2000:])
            return 1

        s, raw = http("POST", "/api/stage",
                      {"artist": "Daft Punk", "title": "Get Lucky"})
        j = json.loads(raw)
        did = j.get("id")
        print(f"stage accepted id={did}")
        if not did:
            print("FAIL no download id")
            return 1

        # poll until reached a terminal-ish state (staged/kept/failed/...)
        terminal = {"staged", "kept", "expired", "deleted", "failed",
                    "giveup", "no_results", "no_official"}
        seen = {}
        for _ in range(60):
            time.sleep(4)
            s, raw = http("GET", "/api/downloads")
            rows = json.loads(raw).get("downloads", [])
            row = next((r for r in rows if r["id"] == did), None)
            if row is None:
                print("FAIL download gone")
                return 1
            st = row["status"]
            if st != seen.get("last"):
                print(f"  status: {st}")
                seen["last"] = st
            if st in terminal:
                print(f"download reached terminal status: {st}")
                break
        else:
            print("FAIL timed out waiting for download")
            return 1

        # dump server log tail for diagnosis
        slog.flush()
        try:
            txt = open(srvlog).read()
            print("--- server log tail ---")
            print("\n".join(txt.strip().splitlines()[-30:]))
        except Exception:
            pass

        if st != "staged":
            print(f"FAIL expected staged, got {st} :: {row}")
            return 1

        # verify a file landed in staging
        staged_files = os.listdir(staging)
        print(f"staging files: {staged_files}")
        if not staged_files:
            print("FAIL no staged file")
            return 1

        # now keep it into playlist "Liked"
        s, raw = http("POST", "/api/keep",
                      {"download_id": did, "playlist": "Liked"})
        kj = json.loads(raw)
        print(f"keep result: {kj}")

        s, raw = http("GET", "/api/playlists/Liked")
        detail = json.loads(raw)
        entries = detail.get("entries") or []
        print(f"playlist entries: {[(e['base_name'], e['exists'], e['url']) for e in entries]}")
        if not entries:
            print("FAIL playlist has no entry")
            return 1
        if not os.path.exists(entries[0]["path"]):
            print("FAIL kept file missing on disk")
            return 1
        ok = all(e["exists"] for e in entries)
        print("PASS full staging->keep->playlist flow" if ok else "FAIL entry missing")
        return 0 if ok else 1
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except Exception:
            proc.kill()
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
