#!/usr/bin/env python3
"""Import a Spotify playlist CSV export (Exportify/TuneMyMusic format)
into mopidy-staging: per-track Added At dates + album art URLs.

Usage:
    python3 import_playlist_csv.py <playlist.csv> <PlaylistName> [server]
"""
import csv
import json
import sys
import urllib.parse
import urllib.request

server = sys.argv[3] if len(sys.argv) > 3 else "http://localhost:6680"
csv_path, playlist = sys.argv[1], sys.argv[2]

with open(csv_path, newline="", encoding="utf-8-sig") as fh:
    rows = list(csv.DictReader(fh))

payload = []
for r in rows:
    artists = (r.get("Artist Name(s)") or "").strip()
    title = (r.get("Track Name") or "").strip()
    if not artists or not title:
        continue
    payload.append({
        "base_name": f"{artists} - {title}",
        "added_at": (r.get("Added At") or "").strip(),
        "album_image": (r.get("Album Image URL") or "").strip(),
    })

url = (f"{server}/staging/api/playlists/"
       + urllib.parse.quote(playlist, safe="") + "/meta")
req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="POST")
with urllib.request.urlopen(req, timeout=30) as resp:
    print(json.load(resp))
