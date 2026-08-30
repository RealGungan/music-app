# NASMusic server

The backend that powers the phone **and** Linux desktop apps. It runs on
the NAS and serves the `/staging/` HTTP API at
`http://<NAS-IP>:6680/staging/` (your endpoint: `http://music.rg.nig`).

It is the "search-anything, stream-instantly, save-if-you-like-it" engine
that Navidrome can't do: it knows how to **find** songs you don't own yet
(YouTube / YouTube Music + Deezer ground-truth matching, the same
search-correctness technique as `spotify_new/tools`), stream them instantly,
download them to a staging zone, and — if you add them to a playlist —
promote them into your real NAS music library. It also indexes and streams
the music already stored on your NAS.

## What it does

- **Search**: matches against your on-disk library *and* discovers the
  "correct" studio version from YouTube/YTMusic, using Deezer metadata to
  reject live/remix/cover uploads (see `nasmusic/scorer.py`).
- **Stream**: serves library files over HTTP with `Range` support (so the
  apps can seek), and returns direct stream URLs for discovery tracks.
- **Stage & save**: downloads a candidate to `/data/staging`, verifies it
  against the ground-truth duration, and keeps unused files for 7 days.
  Adding a track to a playlist moves it into the NAS library folder and
  records it in the `.m3u` playlist (saved to your NAS).
- **Playlists**: create/list/detail/delete `.m3u` playlists, import
  added-at/art metadata from Spotify exports.
- **Covers**: embedded art -> YouTube thumb -> Deezer album art fallback.

## Run it

### In Docker (recommended for the NAS)

Copy this `server/` folder to the NAS, then:

```
docker compose up -d --build
```

Edit `docker-compose.yml` so the three `/data/...` volumes point at your
real NAS music folders. First start builds (~2–4 min).

Verify the API:

```
curl http://<std-NAS>:8004/staging/
```

### Without Docker (Python 3.9+)

```
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
NASMUSIC_MUSIC_ROOT=/data/music \
NASMUSIC_STAGING_DIR=/data/staging \
NASMUSIC_PLAYLIST_DIR=/data/playlists \
.venv/bin/python -m nasmusic --host 0.0.0.0 --port 6680
```

Or for a quick local sandbox (auto-generates a sample file):

```
./run_dev.sh
```

## Configuration

All settings are env vars (`NASMUSIC_*`) or CLI flags. See
`nasmusic/__main__.py` for the full list.

| Variable | Default | Meaning |
|---|---|---|
| `NASMUSIC_MUSIC_ROOT` | `/data/music` | your NAS music library |
| `NASMUSIC_STAGING_DIR` | `/data/staging` | 7-day staged-download zone |
| `NASMUSIC_PLAYLIST_DIR` | `/data/playlists` | `.m3u` playlists |
| `NASMUSIC_FOLDERS` | `Heavy,Jazz,OSTs,Saved,Liked` | library folder hints |
| `NASMUSIC_EXPIRY_DAYS` | `7` | staged files older than this are deleted unless referenced by a playlist |
| `NASMUSIC_PORT` | `6680` | HTTP port |
| `NASMUSIC_YT_DLP_BIN` | `yt-dlp` | path to yt-dlp |

## Tests

```
.venv/bin/python tests/test_smoke.py          # offline-capable API tests
.venv/bin/python tests/test_download_flow.py  # real download + keep (needs network)
```
