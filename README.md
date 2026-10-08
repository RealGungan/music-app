# NASMusic

Full-stack music app for your NAS: **search anything, stream instantly,
save if you like it.**

A Python server that indexes the music on your NAS **and** can find songs
you don't own yet (YouTube / YouTube Music ground-truthed against Deezer),
stream them instantly, and save the ones you want into your NAS library —
plus Flutter apps for your **Android phone** and **Linux desktop**, all
pointed at `http://music.rg.nig`.

## Layout

```
NASMusicApp/
├── server/          Python server (the /staging/ HTTP API)  → runs on the NAS
│   ├── nasmusic/    package (search, download, playlists, http, db)
│   ├── tests/       test_smoke.py (15 pass) + test_download_flow.py
│   ├── Dockerfile   docker image for the NAS
│   ├── docker-compose.yml
│   └── run_dev.sh   quick local sandbox
└── app/             Flutter app (Android + Linux desktop)
    ├── lib/         api_client, queue player, screens, widgets
    └── build/       app-release.apk  +  linux/x64/release/bundle/nasmusic
```

## How it works

- **Search** hits the server's `/staging/api/search` — it matches your
  on-disk library *and* discovers the correct studio version online,
  rejecting live/remix/cover uploads (Deezer duration/artist ground truth).
- **Stream** — library files are served with `Range` support (seekable);
  discovery tracks stream directly (or download + play).
- **Save** — add a track to a playlist and it's downloaded to a staging
  zone, verified, and promoted into your real NAS music library + `.m3u`
  playlist. Unwanted staged files age out after 7 days.

## Deploy

1. **Server (on the NAS):** copy `server/`, edit the volume paths in
   `docker-compose.yml`, then `docker compose up -d --build`.
   Verify: `curl http://<NAS>:8004/staging/`.
2. **Apps:** install `app/build/app/outputs/flutter-apk/app-release.apk`
   on your phone, and `app/build/linux/x64/release/bundle/nasmusic` on
   desktop. The app defaults to `http://music.rg.nig` (change it in-app
   via the gear / "Change" on the Discover tab, or bake it in with
   `--dart-define=NASMUSIC_SERVER=...`).

## Full docs
- `server/README.md` for server config (env vars, ports, folders).
- `flutter analyze` / `flutter test` inside `app/` for checks.
