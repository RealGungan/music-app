# NASMusicApp — behavior → code map

Goal: in any session about this app, locate the root of any user-reported
behavior directly from this file — no reverse-engineering. Everything here is
verified against the current source.

> **MAINTENANCE:** this table is VERIFIED CURRENT as of 2026-09-21 (funnel
> re-audit: per-IP+per-user rate buckets, token redaction in logs,
> spotify-playlist-order + order-write routes — all deployed + probed live
> over the public URL).
> Whenever `httpd.py` is edited, re-verify the
> refs you touched and update them here:
> `rtk grep -n "def _search\b\|def _preview_album_count\|def _rn_worker\|def _album\b\|def _relay\b\|def _is_playlist_file\|def _checksongs\|def _check_replace\|def _replace_monitor\|def _check_lyrics" nasmusic-server-updated/nasmusic/httpd.py`

## Layout
- `nasmusic-server-updated/nasmusic/` = ACTIVE server source (edit THIS copy).
  `nasmusic-server/`/`.zip`/`.tar.gz` = older snapshots — do not edit.
- `app/` = Flutter client (Android + Linux desktop).
- `app/lib/queue/` = Infinite queue algorithm (pure Dart, unit-tested):
  - `text_norm.dart` — `norm()`, `normCore()`, `normArtist()`, `tokenJaccard()`, `titleSimilarity()`, `artistSimilarity()`, `songSimilarity()`. Mirrors server's `scorer.py norm()`.
  - `nas_matcher.dart` — `NasIndex` (in-memory fuzzy NAS-file matcher), `NasMatch`, `TracksRow`. Strips audio extensions during indexing.
  - `queue_planner.dart` — `QueuePlanner` (keep-ahead/dedup/cooldown/seed-drift), `RelatedCandidate`.
- Deploy = SMB upload `nasmusic/<file>` to the NAS container's `/app`, then
  restart. See "Deploy & verify" at the bottom.

## Server module map
| File | Role |
|---|---|
| `httpd.py` | ALL HTTP: routing, search, artist/album pages, resolve/stream proxy, cache orchestration, cover, lyrics, keep/downloads/playlists, checksongs/identify. 4469 lines, ~175KB. |
| `scorer.py` | Scores & picks the best YouTube candidate (`pick`), plus Deezer/Spotify metadata, yt-dlp wrapper. |
| `state.py` | `Config` (env-overridable, all paths/TTLs) + `State` (library index, playlists, durations, lyrics/spotify-meta bundles). |
| `db.py` | SQLite: downloads, `song_meta`, `resolved_urls`, `webcache` (misc keys), durations, added-meta. |
| `pipeline.py` | Download/stage/redownload job state machine. |
| `lyrics.py` | Lyrics parsing/bundling. |
| `lifecycle.py` | Server boot/shutdown glue. |

## HTTP routing (`httpd.py`, `_route_api` at line 149)
All routes are listed in `httpd.py:158-402`. Table (current line refs):

| Endpoint | Method | Handler (line) | Purpose |
|---|---|---|---|
| `/api/search` | GET | `_search` :416 | Local + internet discovery + artists. |
| `/api/suggest` | GET | `_suggest` :892 | Live typeahead (NAS-first + Deezer online). |
| `/api/radio` | GET | deezer radio in-dispatch :180 | Related songs for autoplay (up next). |
| `/api/recommend` | GET | deezer recs in-dispatch :194 | Spotify-style multi-source recs. |
| `/api/artist-photo` | GET | `_artist_photo` :2795 | Just the photo for a name. |
| `/api/diagnostics` | GET | `_diagnostics` :2888 | Debug bundle for an artist. |
| `/api/resolvename` | GET | `_resolvename` :1023 | artist+title → video_id+url (internet). |
| `/api/open-url` | GET | `_open_url` :1150 | Deep-link intel: YouTube/YT-Music/Spotify link → song identity (youtube: video_id+artist+title via `_yt_video_meta` :1199; spotify: artist+title+image via `_spotify_track_meta` :1213 page scrape). Added 2026-09-15 for the Share + deep-link feature. |
| `/api/spotify-link` | GET | `_spotify_link` :1252 | artist+title → a **real** `open.spotify.com/track/<id>` so a shared Spotify link autoplays (not a search page). Mirrors the Spotify **web player**: TOTP-minted anonymous token (`_spotify_totp` :1271 / `_spotify_anon_token` :1285) + `searchDesktop` pathfinder query (`_spotify_search_tracks` :1329; hash `_SPOTIFY_SEARCH_HASH`). Best-match by normalized title/artist; confident hits cached 30d `sps:<a>\x00<t>`; else search-URL fallback. Added 2026-09-15. |
| `/api/spotify-playlist-order` | GET | dispatch :507 / `_spotify_playlist_order` | Spotify playlist link → track sequence. `?full=1` = anonymous `fetchPlaylistContents` pathfinder query (`_spotify_playlist_tracks`, hash `_SPOTIFY_PLAYLIST_HASH`, offset paging, real added-dates, 6h `spf:` cache); else 100-cap embed scrape (6h `spo:`). Added 2026-09-21. |
| `/api/register` | POST | `users.register` via `users.py` | Create account + private home (`{username,password,verify,device_id,device_name}`) — first claim of a pre-existing folder adopts it, else 409 taken. Added 2026-09-18 (multi-user). |
| `/api/login` | POST | `users.login` via `users.py` | username+password → session token for this device. 401 on bad credentials. Added 2026-09-18 (multi-user). |
| `/api/logout` | POST | `users.logout` via `users.py` | Revoke this session token. Added 2026-09-18 (multi-user). |
| `/api/me` | GET | token gate in `_dispatch` | Who owns this session token (`{username}`). Added 2026-09-18 (multi-user). |
| `/api/register` | POST | `users.register` via `users.py` | Create account (username+password+verify, per-device id/name) → `{username, token, adopted}`; 400 validation, 409 name taken (folder exists), 500 users storage not mounted. First claim of a pre-existing folder adopts it (owner claims tree). Added 2026-09-18 for multi-user. |
| `/api/login` | POST | `users.login` via `users.py` | username+password → `{username, token}`; 401 invalid credentials. Token kept by the app until logout. Added 2026-09-18. |
| `/api/logout` | POST | `users.logout` | Revoke this session token → `{ok}`. Needs token (gated). Added 2026-09-18. |
| `/api/me` | GET | token gate | Who owns this session token → `{username}`. Needs token (gated). Added 2026-09-18. |
| `/api/innas` | GET | `_innas` :1689 | Does this artist+title exist on NAS? |
| `/api/stage` | POST | pipeline `start_stage` in-dispatch | Start download job. |
| `/api/jobs` | GET | pipeline `all_jobs` in-dispatch | Job list. |
| `/api/downloads` | GET/DELETE | `db.list_downloads` / `_delete_download` :3379 | Download rows. |
| `/api/redownload` | POST | pipeline `start_redownload` in-dispatch | Force candidate version. |
| `/api/keep` | POST | `_keep` :3094 | Keep file in a playlist. |
| `/api/resolve/<vid>` | GET | `_resolve` :1314 (+`debug` in-dispatch, `speedtest` in-dispatch) | Direct stream URL for a video. |
| `/api/stream?vid=` | GET | `_stream_remote` :1334 | PROXY: resolve+relay the mp4 (Android uses this). |
| `/api/lyrics` | GET | `_lyrics` :1515 | Lyrics for a file. |
| `/api/metainfo` | GET | `_metainfo` :1618 | File meta. |
| `/api/artist/<name>` | GET | `_artist` :2578 | Artist page (albums/songs). |
| `/api/album` | GET | `_album` :3002 | Album page (songs + exists flag). |
| `/api/liked` | GET | `_liked` :3080 | Liked status of a file. |
| `/api/checksongs` | GET | `_checksongs` :2381 | Verify downloads vs studio originals (duration). `?scope=library|playlist:<name>|song:<q>` filters; snapshot carries `scope` (`_check_snapshot` :2370, `_check_scope_items` :2399). |
| `/api/song-versions` | GET | `_song_versions` :2584 | Version picker for a NAS file. |
| `/api/check-replace` | POST | `_check_replace` :2668 | Replace NAS copy with another version (in-place swap same-dir, duration-verified `_replace_monitor` :2720). |
| `/api/identify` | GET | `_identify_song` :2458 | Fingerprint a file (fpcalc/acoustid). |
| `/api/check-lyrics` | GET | `_check_lyrics` :2808 | Verify lyrics coverage. `?scope=` same filtering; snapshot `_lyrics_check_snapshot` :2797 carries `scope`. |
| `/api/cover` | GET | `_cover` :3432 (+`_cover_vid`, `_cover_playlist`) | Album/art image (file / video / playlist). |
| `/api/tracks` | GET | `_tracks` :3409 | Full flat track list. |
| `/api/playlists/...` | GET | `_playlists` :3159 / `_playlist_detail` :3309 | Playlist list/detail. |
| `/api/announcements` | GET/POST/DELETE | `_announcements` :2895 / `_announcements_publish` :2807 / `_announcements_clear` :2874 | Broadcast cards + auto-update notices. GET emits `{wrapped_season, app_updates (default True), app_version (=APP_VERSION), items[]}` (dead-overwrite bug fixed 2026-09-22 — GET used to wipe app_updates/app_version). POST = card `{title,body,url?}` or kill-switch flip `{"app_updates": bool}` (owner-only, 10/h). App `Announcer._checkAppUpdate` notifies once per newer version (id 999, tap → `/staging/app.apk`), skips when a manual update card exists. Added 2026-09-21/22. |
| `/` | GET | `_index` :3421 | App JSON bootstrap (includes `js_bootstrap.ffmpeg_on_path`). |

## Behavior → code (the map)

### Search
1. App `api_client.dart` `search()` :825 → `/api/search` → `_search` (`httpd.py:416`).
2. Artists kicked EARLY: `sa:` cache check :434-442 → `_artists_fetch_async` :802 (background).
3. Discovery cache `sr2:<qkey>` :450 (TTL `_search_cache_ttl` = 12h, `httpd.py:405`). Cold → `_discovery_sync` :691 + **short ≈0.6s block** (`ev.wait(timeout=0.6)` :519); warm → serve cached.
4. **Cold is near-instant now (not ~2s, not the old ~10s):** `_discover_async` :553 writes the `sr2:` cache the moment rows are picked (:682), THEN prewarms their URLs (:687, `wait_sec=6`) in the same worker. The request returns locals@~0.6s with `discovery_pending=true`; the app's `_pollDiscovery` (search_screen.dart:117, ~1.2s) fetches the rows once the cache is written. The cold block size 2s→0.6s was set 2026-09-09 with the tap-lane change.
5. Local matches from `_local_files_map()` :461 (rebuilds every 30s, `state.local_mp3_index` `state.py:253`).
6. Only WARM served rows are re-prewarmed (`_prewarm_resolve(..., wait_sec=0, sync_first=True)` :539) — a just-built cold path skips this so the 0.6s block isn't padded by a second `wait_sec=3`.
7. Artists read back in `_search_artists` :763 — cached `sa:` 6h; per-artist album count via `_preview_album_count` :716, which is **memoized + background-computed** (never blocks the request thread). This fixed the ~2.1s warm-search (now ~0.04s). The `all_songs_by_artist` backend is at :2286.

### Tap-to-play an internet (discovery/artist/album) row
1. App `_streamItem`/`_playDiscovery` → `resolveByName` (`api_client.dart:1168`): polls `/api/resolvename` every 400ms until not pending.
2. Server `_resolvename` :1023 → cache key `_rn_key` :1020 (`ry:<norm(artist)>\x00<norm(title)>`, null-byte separator), 14-day `misc` cache :1033.
3. Cold → one shared worker `_rn_worker` :1065 (single-flight `_rn_jobs`): YTMusic search `scorer.search_ytmusic` :114 of `scorer.py` → `pick` :242 → fallback `scorer.search` :142 (yt-dlp ytsearch15 merge). Result stored `ry:` (`misc_put` :1129).
4. `_rn_worker` also stores url+`video_id`+`resolved_title` (the ACTUAL media identity, :1121-1128).
5. App plays `url` = `_play_url(vid)` :1320 (/api/stream relay).

### Tap-vs-prewarm priority lanes (2026-09-09 — the "30s to play a song" fix)
- There are TWO semaphore lanes so a burst of background prewarm can NEVER
  starve a user tap:
  - `_rn_sem` (tap lane, 4 slots) at :1816 — user taps ONLY.
  - `_rn_sem_bg` (background lane, 4 slots) at :1817 — prewarm only.
- `_rn_worker(key, artist, title, bg=False, tok=0)` :1065 acquires the lane by
  flag. Background jobs (`_prewarm_resolvename` :989, `_prewarm_artist_streams`
  :2747) spawn with `bg=True`; direct requests spawn without.
- Each job is `{"ts", "bg"?, "tok"}` in `_rn_jobs` (:1810, lock :1809, counter
  `_rn_tok` :1812). When a TAP arrives for a key whose job is a `bg` prewarm,
  `_resolvename` REPLACES it with a fresh tap job (new `tok`, tap lane) so the
  tap is never queued behind a possible 70+-job prewarm backlog — **song taps
  now resolve in ~3s even under max prewarm load** (was up to 30s).
- Old workers are token-guarded: `_rn_worker` checks `_own_job()` before
  writing/pop, so a stale bg worker can't clobber the promoted tap's cache row
  (:1130).

### Wrong-video / wrong-track (the CAMBIA! bug class)
- Root: `scorer.py pick()` :242. Title-match bonuses now DOMINANT (exact +80, containment +50, :263-267) so same-name upload beats a different song on an official channel (which used to win on channel-tier +30).
- `channel_tier()` :224: tier 0 = artist's own channel/uploader, tier 1 = atomic/records/music keywords, tier 2 = everything else.
- `_rn_worker` :1102-1106 **ACCEPTS a tier-2 first pick from the fast path when its title strongly matches** (exact / one-contains-the-other). Only a tier-2 pick WITHOUT a strong title match falls through to the slower full yt-dlp search. This removed a wasted ~1.5s yt-dlp re-search that used to return the same tier-2 result (2026-09-09).
- If it "still" resolves wrong: suspect the 14-day `ry:<artist>\x00<title>` stale cache (see caches table). Delete the row + retest. NOTE (2026-09-09): truly obscure songs that aren't on YouTube at all legitimately resolve to a tier-0 unrelated result (e.g. "Descartes a Julio" → "Do Vento"): that's scarcity, not a pick bug.

### Streaming / relay
- `/api/stream?vid=` → `_stream_remote` :1334 → resolves via `_resolve_shared` :1220 → `scorer.resolve_url` :197 (yt-dlp -g) → `_relay` :1344 proxies with range/timeout 45s; on open failure RE-RESOLVES once with a fresh URL then retries (stale googlevideo URLs expire in hours).
- `resolved_urls` table (`db.py`: `resolved_cache_get` :170 / `resolved_cache_put` :185) — TTL `config.resolve_cache_ttl` = `RESOLVE_TTL`, default **86400** (`state.py:50`).

### Search preview vs artist-page album count
- Preview uses `_preview_album_count` :716 (memoized, background-computed); the artist page builds via `_artist` :2578 → `_compose_artist_full` :2669 — both share `_merge_albums` :2511 + the same `dz:albums:v2:` discography cache (:2324), so they agree by construction (Metallica 22/22, Jinjer 5/5 verified).

### Album page `exists` / streams vs NAS copies
- `_album` :3002 merges `song_meta` rows + Deezer tracks (`_deezer_album_tracks_cached` :2333).
- `exists` = a real file in `music_root` exists for the row (:3047). **Playlist-dir copies (Liked, etc.) are intentionally treated as NOT owned**: `_is_playlist_file(p)` :1635 (URL prefix `/staging/pl/` via `_entry_url` :1623) → sets `exists=false` so the row STREAMS instead of silently playing the favorited copy (:3044).

### Queue NAS-preference
- App asks `/api/innas` (`_innas` :1689, lenient variant :1760) before playing an internet song; if NAS has it, prefer the local file (queue_player.dart). `_all_songs_by_artist` :2286 builds per-artist entries (local + bundled career rows).
- **Infinite queue (2026-09-16):** `queue_player.dart` `relatedSource` (:146) returns resolved `QueueItem`s with `{int limit, List<String> excludeTitles}`. `QueuePlanner.pick()` runs AFTER resolution. `_fillRelated` converts returned QueueItems to candidates via `_toCandidate`, runs planner, maps back via `_itemKey` → `candMap`. The `_seenKeys` set prevents repeats.

### Multi-user accounts + private playlists (2026-09-18)
- **Store:** `nasmusic/users.py` — locked JSON under `<users_dir>/.nasmusic/` (`users.json` PBKDF2-HMAC-SHA256 hashes 200k iters + `sessions.json` opaque tokens), 0600 files. Stdlib only. MUST live on a mount (`NASMUSIC_USERS_DIR`, default `/data/users` → host `.../Users`) — the SQLite DB does NOT survive Down/Up.
- **Routes:** `POST /api/register|login|logout`, `GET /api/me`. Gate in `_dispatch`: everything except register/login needs `X-NASMusic-Token` header or `?token=` (401). Username uniqueness = registered OR folder `Users/<name>` carries another name's `.nasmusic-owner` claim marker (unmarked NAS folders are claimable exactly once, anytime).
- **Homes:** `LEGACY_USER = "RealGungan"` → legacy `/data/*` mounts (== their folder); others → `Users/<X>/Media/Music/Playlists` (created on register). Migration (once, marker `users_migrated_v1`): prefix `added_meta` + order rows with `RealGungan/`.
- **Playlists are per-user everywhere:** `_playlists` list/PUT/POST, meta, entries DELETE, cover POST/DELETE/GET (`_cover_playlist`), detail, DELETE, `_keep` (via `append_entry(m3u=)`), `_delete_download` sweep (all homes), `_check_scope_items(playlist:)` (owner param), `_playlists_cache` dict keyed by user. Global music library stays shared (phase 1).
- **App:** `AuthStore` (prefs token/username/device id) + `LoginScreen` gate `home:` in main.dart (validates via `/api/me`, revalidates on server switch); `ApiClient.authToken` auto-attached as `?token=` on ALL calls incl. hand-built stream/file/cover/thumb URLs; 401 → `onAuthFailure` → expire → login screen; Account section + Logout in Settings. No playlist-UI changes needed (server filters).

### Multi-user accounts + private playlists (2026-09-18)
- **Store:** `nasmusic/users.py` — locked JSON under `<users_dir>/.nasmusic/` (`users.json` PBKDF2-HMAC-SHA256 hashes 200k iters + `sessions.json` opaque tokens), 0600 files. Stdlib only. MUST live on a mount (`NASMUSIC_USERS_DIR`, default `/data/users` → host `.../Users`) — the SQLite DB does NOT survive Down/Up.
- **Routes:** `POST /api/register|login|logout`, `GET /api/me`. Gate in `_dispatch`: everything except register/login needs `X-NASMusic-Token` header or `?token=` (401). Username uniqueness = registered OR folder `Users/<name>` carries another name's `.nasmusic-owner` claim marker (unmarked NAS folders are claimable exactly once, anytime).
- **Homes:** `LEGACY_USER = "RealGungan"` → legacy `/data/*` mounts (== their folder); others → `Users/<X>/Media/Music/Playlists` (created on register). Migration (once, marker `users_migrated_v1`): prefix `added_meta` + order rows with `RealGungan/`.
- **Playlists are per-user everywhere:** `_playlists` list/PUT/POST, meta, entries DELETE, cover POST/DELETE/GET (`_cover_playlist`), detail, DELETE, `_keep` (via `append_entry(m3u=)`), `_delete_download` sweep (all homes), `_check_scope_items(playlist:)` (owner param), `_playlists_cache` dict keyed by user. Global music library stays shared (phase 1).
- **App:** `AuthStore` (prefs token/username/device id) + `LoginScreen` gate `home:` in main.dart (validates via `/api/me`, revalidates on server switch); `ApiClient.authToken` auto-attached as `?token=` on ALL calls incl. hand-built stream/file/cover/thumb URLs; 401 → `onAuthFailure` → expire → login screen; Account section + Logout in Settings. No playlist-UI changes needed (server filters).

### Public funnel hardening (2026-09-18 — deployed + verified live)
- Served at `https://naboo.taildfeb4f.ts.net/staging/` (funnel → host :8004 → container :6680; TLS by funnel). Funnel exposes ONLY this port.
- Gate `_dispatch` :265: `/staging` bootstrap now needs a token too (was leaking `music_root`/`staging_dir` pre-auth); `_index` :4339 returns `{service, expiry_days}` only. `_diagnostics` no longer reports `music_root`.
- Rate limits (in-process, per IP AND per username — funnel/tailnet collapse
  many users onto one source IP, so IP-only buckets let one attacker lock
  everyone out): register 10/h/IP + 5/h/name, login 60/10min/IP + 15/10min/name,
  stage 30/h per user → 429. `_body_json` capped 2MB. `log_message` redacts
  `?token=` (session theft via logs).
- Traversal: `_safe_track_field` (httpd.py :81) on stage artist/title; `Pipeline._target_path` + `start_stage` containment (pipeline.py :32/:61). All subprocess is list-argv (no shell anywhere).
- SSRF: `_fetch_public_guards`/`_fetch_public`/`_peek_redirect_location` (httpd.py :97/:135/:153) — http(s) only, no userinfo, resolved IPs must be public, no redirects, body capped. `_open_url` :1449 uses exact host sets + Location-only peek for spotify.link (only accepts landing on open.spotify.com). `_relay_image` :4396 fetches via `_fetch_public`; meta-write validates scheme/userinfo; cover cache capped 200 entries × 5MB.
- Vid allowlist `VID_RE` on resolve/redownload/cover-vid/stream. yt-dlp `--max-filesize 120M` (scorer.py). New passwords min 8 (users.py).
- Owner-only (401→403 for others, `LEGACY_USER`): `check-replace`, `DELETE downloads/<id>`, `redownload`. Friends keep stage/keep/play.
- Residual: DNS-rebinding TOCTOU on the fetch guard; per-IP limits are global if funnel masks IPs (all seen as one); no anti-DDoS (ThreadingHTTPServer); `?token=` in URLs can land in logs.
- **Join page (2026-09-18):** browsers (`Accept: text/html`) get a landing page on `/` and `/staging` (app download + register form, `LANDING_HTML` in `httpd.py`, `APP_VERSION` const); API clients keep JSON 401s. APK served at `/staging/app.apk` from `nasmusic/static/nasmusic.apk` (uploaded via SMB per release). Register form uses `textContent` only (no XSS); register rate limit applies.
### Infinite queue algorithm (2026-09-17)
- **Modules:** `app/lib/queue/text_norm.dart`, `nas_matcher.dart`, `queue_planner.dart` — 62 unit tests in `app/test/queue/`.
- **Flow:** `_wireAutoplay` (main.dart :577) → `_fillRelated` (queue_player.dart) → server `/api/radio|recommend?limit=&exclude=` → `QueuePlanner.pick(keepAhead=30, refillWhen=30, recentWindow=50)` → `NasIndex.findBestMatch(artist, title)` → resolved items → play.
- **Continuous refill (never "+N when you reach the Nth"):** `queue_player.dart:159` builds the planner with `refillWhen == keepAhead` (both 30), so `_maybeAutoplay` tops the queue back up to the horizon after EVERY track advance — the tail never drains to a low refill line and then jumps in a visible batch. `_fillRelated` adds exactly `deficit = keepAhead - remaining` rows (bails out early when already full). `addMore()` (scroll / "Add more") still tops up a full keep-ahead batch with a 2s cooldown (`now_playing.dart:1772`).
- **Bounded 30-song queue (2026-09-17, v1.0.7+9):** the total queue is capped at `maxQueue = 30` (`queue_player.dart`). `_fillRelated` bails out whenever `headroom = maxQueue - items.length <= 0` (covers BOTH the per-song top-up AND the scroll/addMore path — no `clamp(1, 0)` crash), and a defensive append-point guard `roomLeft = maxQueue - items.length` caps the final `items.addAll(...)` so concurrent refills can't overshoot. The server is asked for a bigger pool than we append (`batch = max(need, _requestBatch=20)`) so `pick()` can randomize.
- **Randomized refills (2026-09-17):** `QueuePlanner.pick()` now shuffles BOTH the lead (closest-to-seed, score ≥ mean*0.7) AND rest (novelty) tiers, then interleaves them ~3:1 lead:rest (`preferLead = leadPool.isNotEmpty && (restPool.isEmpty || leadTaken < 3 || random < 0.25)`, `leadTaken` resets when it dips into rest) — a same-seed refill no longer returns the same few closest tracks in the same order (the "6, AUTOPLAY, 4, AUTOPLAY, 5, AUTOPLAY, 5 — and that's it" stall). Artist-run cap, relax-fallback, and exact-seed demotion are preserved. The AUTOPLAY divider was removed from the queue sheet UI (`now_playing.dart` `_QueueSheet`).
- **NasIndex:** built from `/api/nas-index` rows; strips audio extensions (.mp3/.flac/etc) during indexing; `findBestMatch(artist, title, minScore=0.72)` uses `songSimilarity` (title 0.6 + artist 0.4) + artist bonus.
- **Norm recipe (mirrors server):** `norm()` = NFKD diacritics → lowercase → strip `[^a-z0-9 ]` → collapse whitespace → trim. `normCore()` = strip `(…)[…]{…}` tags first. `normArtist()` = split on `feat|ft|with|&` first.

### Autoplay (spotify/yt-music "up next")
- App `queue_player.dart`: `_autoplay` ~:383-454 → `/api/radio` (`deezer_radio_tracks` `scorer.py:388`) / `/api/recommend` (`deezer_recommendations` :464).

### Car head-unit / AVRCP now-playing (2026-09-15)
- Symptom class (Opel Astra): car shows BLANK title/artist, steering-wheel controls dead, car says "Audio Bluetooth not provided" — while the phone's own notification shows the song fine AND Spotify/YT-Music work on the same car.
- Root cause: AVRCP head units read `PlaybackStateCompat.getActiveQueueItemId()`; audio_handler.dart published `PlaybackState` WITHOUT `queueIndex` → native `setActiveQueueItemId()` never ran → session had no active queue item → head unit refused to render metadata/accept transport. It is NOT an A2DP problem (audio can still stream).
- Fix (audio_handler.dart): `_publishMedia` now also `queue.add([same MediaItem])` (session queue, index 0) and `_publishPlayback` sets `queueIndex: _hasMedia ? 0 : null`. Also stop publishing a fake idle `MediaItem('nasmusic', 'NASMusic')` (first item AVRCP latches can get stuck forever) and `AudioService.init()` errors are now debugPrint'd (not silently swallowed — a silent init failure = local fallback player with NO MediaSession = same blank-car symptom).
- Diagnostic ladder if car display still broken: (1) phone notification shows song? (2) `adb shell dumpsys media_session` → does our pkg have an active session with PLAYING state + metadata + queue? (3) AVRCP version 1.4/1.5/1.6 in Developer Options + re-pair. Changes at Spotify/YT level not needed.

### Share button + deep links (2026-09-15)
- Share button lives in NowPlaying's secondary row (`'share'`, Icons.share_outlined) — `now_playing.dart` `_secondaryButtons` + `_buildEditableRow`; registered in `PlayerButtons.catalog`/`defaultOrder` (`theme.dart`).
- `_prewarmShare` runs on every `qp.currentTitle` change (and once in initState) → `_resolveShare` resolves BOTH links in one shot; the tap opens an INSTANT chooser (YouTube Music / Spotify, "Direct track link").
- YT Music link = `music.youtube.com/watch?v=<videoId>` (videoId from `cur.videoId` or `api.resolveByName`); fallback search link.
- Spotify link = `api.spotifyLink(artist,title)` → `/api/spotify-link` (real track, autoplays); fallback `open.spotify.com/search/<q>`.
- Native Android share sheet via MethodChannel `com.nasmusic.nasmusic/share` (`shareText` → ACTION_SEND); desktop falls back to Clipboard + snackbar.
- Deep links: `main.dart` `_openDeepLink` (from channel `com.nasmusic.nasmusic/deep_links`); youtube → `api.resolve(video_id)` → playOne; spotify → `/api/open-url` (or `/search/<q>` path) → NAS-first `inNas` else `resolveByName` → playOne → push `NowPlayingRoute` (MainActivity `pendingUrl` + manifest VIEW/BROWSABLE filters for spotify/youtube hosts).
- **CRITICAL cold-start race (FIXED 2026-09-16):** MainActivity's `onCreate` used to store `pendingUrl` from `intent?.data` AFTER `super.onCreate()` returned — but FlutterActivity runs `configureFlutterEngine` INSIDE `super.onCreate`, and the Dart engine fires `getInitialLink` as soon as it boots (inside that call). So on a real cold start the deep link raced and was LOST: the app opened, `_openDeepLink` never ran, nothing played, no toast (the `toast(ctx,…)` calls silently no-op while the navigator isn't built). Fix: capture `intent?.data` at the TOP of `configureFlutterEngine` (before Dart can query), and in the `getInitialLink` handler only `pendingUrl = null` when it actually returned something (so an early query can't swallow a link that lands a tick later). Symptom to recognize: "links open the app but the song doesn't appear/autoplay".
- Registered as a link handler: Settings → **"Deep links → Open links by default"** (`settings_screen.dart` `_openSupportedLinks` → channel `com.nasmusic.nasmusic/system` method `openSupportedLinks`, `MainActivity.kt` `openSupportedLinks()` → `Settings.ACTION_APP_OPEN_BY_DEFAULT_SETTINGS` + `package:NASMusic` data URI). From there the user can flick on all four hosts (open.spotify.com / music.youtube.com / www.youtube.com / youtu.be) at once, or do the one-time "Always" confirmation when tapping a link. NOTE: Android App Links verification (`assetlinks.json`) is impossible for these domains — we don't own them — so a genuine auto-open with zero dialogs is NOT available to any third-party app.
- Make the app the DEFAULT handler for Spotify/YT-Music links: Settings → "Deep links" → "Open links by default" opens the system page (Settings `ACTION_APP_OPEN_BY_DEFAULT_SETTINGS`, method channel `com.nasmusic.nasmusic/system` → MainActivity `openSupportedLinks()`). System default-app selection is per HOST (open.spotify.com / music.youtube.com / www.youtube.com / youtu.be), Android 12+ only allows it for apps that declare those VIEW/BROWSABLE filters (we do); the system page lets the user enable them in one stop instead of hunting a link per host. Android cannot verify these third-party domains (we don't own spotify.com/youtube.com), so there's no "silent" auto-open without the user's one-time consent.
- **Dead Spotify track → `unknown` not 500 (2026-09-16):** `_spotify_track_meta` (httpd.py :1223) now returns `("","","")` on ANY exception (incl. HTTPError 404/403/429 + network errors) instead of re-raising — a deleted Spotify track used to crash the whole request into a 500. Verified live: dead track → `{"kind":"unknown","url":...}` HTTP 200 (0.1s); live track → `{"kind":"spotify","artist","title"}`. App must fall through to "Can't play that link" when `kind:unknown` and the path is `/track/...`.
- **On-device deep-link diagnosis without adb (2026-09-16, DEBUG BOX REMOVED 2026-09-16):** release debugPrint is invisible; the red on-screen "DL-TRACE" banner (main.dart `_DeepLinkTraceOverlay`) was the only visibility WHILE debugging, and has been REMOVED now that deep links work (BUILD=V7). Remaining diagnostic surface: `_traceDl(msg)` (main.dart :307) is now debugPrint-only (`[deeplink] ...`); the deep-link flow no longer renders anything on-screen. Build markers: a `_traceDl('BUILD=VX')` line still prints via debugPrint on `_wireDeepLinks`. Markers survive as strings in the AOT binary (verified via `unzip -p <apk> lib/arm64-v8a/libapp.so | grep BUILD=V7`); the flow's `openUrl BEFORE` / `openUrl AFTER: kind=...` and `.timeout(12s)`, split catches `TimeoutException` / `ApiException(statusCode,msg)` / generic + `UNHANDLED (openUrl event):` from the handler's `catchError`.
- **`toast()` on the ROOT NAVIGATOR's context KILLED every deep link silently (ROOT CAUSE, 2026-09-16):** `_openDeepLink` called `toast(_navigatorKey.currentContext, …)` with the Navigator's OWN context — which is an ANCESTOR of the Overlay (the Navigator builds the Overlay as its child), so `Overlay.of(context, rootOverlay: true)` finds NO Overlay walking up and the release `result!` throws a null-check TypeError. That throw sat BEFORE the try/catch and the caller was fire-and-forget (no await/catch) → `_openDeepLink` died as an unhandled async error and the DL-TRACE froze right after `host=... isSpotify=true isYt=true` — NO `openUrl BEFORE`, not even a timeout. THIS is the "signature" I wrongly attributed to a stale APK. FIX: `toast.dart` now has `toastInOverlay(OverlayState overlay, msg, …)` targeting the navigator's real overlay (`_navigatorKey.currentState?.overlay`); `toast(ctx,…)` itself uses `Overlay.maybeOf` (null-safe). `_openDeepLink` now traces `openUrl BEFORE` BEFORE any toast, wraps the toast in try/catch, and the channel handler does `_openDeepLink(url).catchError(...)`. Any future deep-link freeze that stops between `openUrl BEFORE` and `openUrl AFTER`= a REAL throw captured by the new `UNHANDLED`/`ERROR:` line.
- **Same-versionCode APK install trap (2026-09-16):** delivering an APK with the SAME `versionCode` (pubspec `version:`, gradle.kts uses `flutter.versionCode`) makes Android REJECT the sideload and keep the old build — reproduces "still the same message" forever. Bump `version:` before each delivery (`1.0.0+2`→`1.0.1+3`→`1.0.2+4`→`1.0.3+5`); tell the user to UNINSTALL-then-install, since update-in-place can also be skipped silently.
- Spotify `/track/<id>` NO-fallback rule (2026-09-16): the "else isSpotify → resolveByName search" branch only applies when the URL path contains `search` — a `/track/<id>` returning `kind:unknown` must NOT be fed to `resolveByName` (raw Spotify IDs aren't song queries) so it falls through to `item == null` → "Can't play that link" toast.
- **`spotify.link` short links — THE "it plays in Spotify but our app does nothing" bug class (2026-09-16):** the Spotify mobile app's Share button emits `spotify.link/<code>` SHORT links (not `open.spotify.com/track/...`). THREE places must each accept the host, and a missing one silently drops the share:
  1. **Android manifest** (`app/android/app/src/main/AndroidManifest.xml` ~:36-52): the VIEW/BROWSABLE intent filters originally registered ONLY `open.spotify.com` — a `spotify.link` URL was never routed to the app at all (OS hands it to Spotify/browser), so the app showed nothing. FIXED: https+http filters now also carry `*.spotify.com`, `spotify.link`, `*.spotify.link`. NOTE `*.spotify.com` matches `open.spotify.com` already, and wildcard hosts are valid in `<data>`.
  2. **Server `_open_url`** (`httpd.py` :1195): the host check was `"spotify.com" in host` → `spotify.link` fell through to `{"kind":"unknown"}` with ZERO resolution. FIXED: `"spotify.com" in host or "spotify.link" in host`; when no `/track/` is in the path and the host is `spotify.link`, follow the redirect (`urllib.urlopen`, UA Mozilla/5.0, 15s) back to the real `open.spotify.com/track/<id>` and re-parse.
  3. **App `_openDeepLink`** (main.dart :390-393 + `_api.openUrl(rawUrl)`): ALREADY handled `spotify.link` (host==`spotify.link` / endsWith `.spotify.link`), sends the raw URL to the server → resolution falls out of the now-fixed `/api/open-url`. No app change needed here.
- **Dead YouTube video → `{"error":"resolve failed"}` on `/api/resolve/<vid>` (verified 2026-09-16):** the user's shared YT link `mly2TUWnAyA` fails because the VIDEO IS GONE from YouTube (`yt-dlp` → "This video is unavailable"), NOT a server bug. `/api/resolve/<vid>?debug=1` (`_resolve_debug` :1642) proves it: healthy video (`bPSLIqo__vs`) returns a valid googlevideo URL (rc 0), the dead one returns rc 1 + the ERROR line. When the app hits this, V6+ now surfaces it as a visible `APIERROR:` trace + toast instead of silent death. Rule: a YT deep link can be dead ≤ the song's YouTube listing; retest with a fresh share link before suspecting the pipeline.
- Current delivered APK `NASMusicApp-NASMusic-App.apk` = version **1.0.16+18** (versionCode 18), marker `BUILD=V11`. Verified: `unzip -p <apk> lib/arm64-v8a/libapp.so | grep -oE "BUILD=V[0-9]+"` = BUILD=V11, dex contains `android.media.AUDIO_BECOMING_NOISY` + `com.nasmusic.nasmusic/audio_events` + `becomingNoisy` (native noisy-receiver present). Before EVERY delivery, bump `version:` (`1.0.15+17`→`1.0.16+18`...) so the trace's first line proves the installed build AND Android accepts the sideload.
- **Headphone/car unplug auto-pause (2026-09-18):** becoming-noisy receiver moved to the APPLICATION context (`MainActivity.kt` `registerNoisyReceiver()`): it must NOT be Activity-scoped, because while music plays with the screen locked the foreground service keeps the process alive but Android destroys the Activity — an Activity-scoped receiver would be torn down with it and `ACTION_AUDIO_BECOMING_NOISY` would never reach Dart (symptom: "turning off headphones doesn't stop the music"). Now registered on `applicationContext` + NOT unregistered in `onDestroy`; the receiver + channel live in the companion object so they survive Activity recreation.

## Caches & TTLs (staleness AND the "still broken after my fix" gotchas)
| Key | Where written | TTL | Notes |
|---|---|---|---|
| `ry:<artist>\x00<title>` | `_rn_worker` :1129 | 14 days | resolvename result dict. **Stale wrong picks live here ~14d.** |
| `sps:<artist>\x00<title>` | `_spotify_link` :1362 | 30 days | artist+title → real Spotify track URL (only cached on a CONFIDENT match). |
| `sr2:<qkey>` | `_discover_async`/`_discovery_sync` (:553/:691) | 12h (`httpd.py:405`) | Search discovery cache. Written immediately on cold, prewarm follows. |
| `sa:<qkey>` | `_artists_fetch_async` :837 | 6h | Deezer artist rows for search. |
| `dz:albums:v2:<artist>` | `_deezer_discography` :2324 | 7 days | Deezer studio discography (`v2` = iteration marker). |
| `resolved_urls` | `resolved_cache_put` | `RESOLVE_TTL` (86400, `state.py:50`) | vid → direct stream URL (expires faster than key! hence relay re-resolve). |
| `song_meta` | `db.song_meta_put` | — | file → {artist,album,album_artist,image}. |
| suggest index | `_suggest_cache` (in `_suggest` :892) | 60s in-memory | `(base,full,url,meta)` rows. |
| `lastav:<user>` | `_dispatch` auth gate | persistent | Last-seen taps per user (`{seen: epoch}`, username-keyed, tokens never stored/logged — proves a phone tap reached the server). |
| album-count memo | `_preview_album_count` :716 | 10min (None: 15s retry) | in-process background computed. |

## Error classes → root
- **Wrong track streams (mine: CAMBIA!/Comerte Entera as Demasiadas Mujeres):** pick() scoring / stale `ry:` row → `scorer.py:242`, cache key `ry:`.
- **Search slow / "takes seconds":** cold discovery block is now ≈0.6s (`_search` :519, `ev.wait(timeout=0.6)`, pending→app polls ~1.2s); warm ~0.04s (memoized `_preview_album_count`). Previously ~2s cold / ~2.1s warm / ~10s pre-fix.
- **Slow tap-to-play (up to 30s):** was `_rn_worker` queued behind up to 70+ background prewarm jobs on the SAME `_rn_sem` (4 slots). Now prewarm uses its own `_rn_sem_bg` (:1817) and a tap promotes its key to the tap lane (:1046-1062) found in `_resolvename` :1023 → tap resolves ≈3s even mid-prewarm (2026-09-09, measured).
- **Wrong-track cache contamination (all artists):** old broken `pick` could map MANY titles → ONE wrong video. On 2026-09-09 I cleared collision clusters from `webcache` `ry:*` (16 `ry:ctangana*` rows + 14 others: Guns N' Roses/Celtas Cortos/Linkin Park/Limp Bizkit), and the fixed pick re-resolved them correctly. If "wrong track" reappears, dump `webcache LIKE 'ry:%'`, find rows whose `resolved_title` ≠ requested song, delete, retest.
- **Album row plays the wrong NAS file:** `_is_playlist_file` :1635 / `_album` exists logic :3044.
- **Stream 502 / dead after a while:** stale `resolved_urls` → `_relay` re-resolve retry :1344.
- **"Artist page shows no songs / wrong count":** `dz:albums:v2:` stale or `_merge_albums`/`_studio_disc_ok` :2463.
- **"Exists but should stream" / reverse:** `_album` exists flags + playlist-file rule above.
- **Resolve never completes:** `_rn_worker` weak-title tier-2 → slow yt-dlp fallback :1109-1112, or `_rn_jobs` 300s single-flight.

## Deploy & verify
1. Edit files under `nasmusic-server-updated/nasmusic/`.
2. Upload via SMB:
   `smbclient //100.89.94.101/Music-app-oc -U 'Opencode-folders%opencode-admin' -c 'put <abs-local-path> nasmusic/<file>'`
   (share maps to the container's `/app`.)
3. Restart (restart.txt is NOT watched): `rtk ssh nas "docker restart nasmusic"`.
4. Verify the NEW code is live via a distinguishing response — e.g. a cold search returns in ≈0.6s with `discovery_pending:true` + locals, then rows at ~1.2s (the poll). First 200 poll may still be the old container.
5. App loopback: apps point at `http://music.rg.nig:8004`. API prefix is `/staging` (so `/staging/api/search?q=` etc.).
6. **Public URL is live (2026-09-18):** `https://naboo.taildfeb4f.ts.net/staging/` via Tailscale Funnel (`/ → 127.0.0.1:8004`, TLS auto). NEVER expose anything else via funnel (no OMV/admin).

### Public-funnel hardening (2026-09-18, deployed + verified live)
- **Join page (download-only URL, open registration in app — 2026-09-18):**
  browsers on `/`/`/staging` (Accept: text/html) get `LANDING_HTML` — APK
  button + "create an account in the app" note, NO register form on the
  URL. Anonymous `POST /api/register` is OPEN (rate limit 10/h/IP); the
  app login screen has a Sign in / Create account toggle (verify field,
  min 8). APK served as `gungan.fm.apk` (`_serve_apk`, chunked,
  `nasmusic/static/nasmusic.apk` — re-upload + bump `APP_VERSION` per release).
- **Brand is gungan.fm** (user-visible strings only: app label/titles,
  login, landing, `_index` service, AcoustID UA). Technical IDs UNCHANGED
  (package `com.nasmusic.nasmusic`, provider authority, `nasmusic/` module,
  `X-NASMusic-Token`, `.nasmusic` markers) — renaming those strands
  existing installs/users.
- **Checker hardened:** `no_ref` → `unverified` + fingerprint attempt;
  window ±12→±8 (`_check_one`, `is_studio`, replace monitor, reason
  strings); explicit twins (`_explicit_twins`, Deezer `vx:` cache 30d)
  → `needs_explicit_check`; fingerprint verdicts need score ≥0.7 +
  title AND artist agreement (`_attach_identity`); `fp:` cache rekeyed
  path+size. App renders both new statuses. NOTE: `ACOUSTID_API_KEY`
  is SET but EMPTY in the container — fingerprint ID is inert until the
  owner pastes a key (free, acoustid.org); duration-only until then.
  register form (fetch POSTs `/api/register`, textContent-only, no XSS).
  API clients keep getting JSON 401. APK served at `/staging/app.apk`
  (`_serve_apk`, chunked, from `nasmusic/static/nasmusic.apk` on the
  /app mount — re-upload on each release, bump `APP_VERSION`). Verified
  live: HTML 200 / curl 401 / apk 56.7MB / register+cleanup round-trip.
  register form (fetch POSTs `/api/register`, textContent-only, no XSS).
  API clients keep getting JSON 401. APK served at `/staging/app.apk`
  (`_serve_apk`, chunked, from `nasmusic/static/nasmusic.apk` on the
  /app mount — re-upload on each release, bump `APP_VERSION`). Verified
  live: HTML 200 / curl 401 / apk 56.7MB / register+cleanup round-trip.
  text/html) get `LANDING_HTML` (httpd.py) — APK download button +
  register form (fetch POSTs `/api/register`, textContent-only, no XSS).
  API clients keep getting JSON 401. APK served at `/staging/app.apk`
  (`_serve_apk`, chunked, from `nasmusic/static/nasmusic.apk` on the
  /app mount — re-upload on each release, bump `APP_VERSION`). Verified
  live: HTML 200 / curl 401 / apk 56.7MB / register+cleanup round-trip.
Open registration stays (friends join freely), but registered users are
treated as potentially hostile. All in `httpd.py` (+`pipeline.py`,
`scorer.py`, `users.py`):
- **Gate:** `_dispatch` :265 — `/staging` index now requires a token too
  (was leaking `music_root`/`staging_dir` pre-auth); `_index` :4339 no
  longer returns absolute paths. Only `register`/`login` are open.
- **Rate limits:** `_rate_allow` :63 — register 10/h/IP, login 15/10min/IP,
  stage 30/h/user; `_body_json` capped 2MB (cover upload uses its own 5MB
  raw-body cap, unaffected).
- **Traversal:** `_safe_track_field` :81 (no `/ \ NUL newline`, ≤120 chars)
  on `/api/stage`; `pipeline._target_path` + `start_stage` validate the
  same (yt-dlp `-o` honours `/`); read paths were already contained.
- **SSRF:** `_fetch_public_guards` :97 (http/https only, no userinfo,
  DNS must resolve to public IPs only) + `_no_redirect_opener` :124.
  `_open_url` :1449 uses EXACT host sets (old substring test matched
  `evilspotify.com`); spotify.link follows ONLY the Location header and
  only onto `open.spotify.com`. `_relay_image` :4396 fetches via
  `_fetch_public` (cache capped at 200); `album_image` write-time check
  (http(s), no `@`).
- **vid allowlist** `VID_RE` everywhere: `/api/resolve`, redownload,
  `/api/cover?vid=` (stream already had it).
- **Owner-only** (`LEGACY_USER` RealGungan, 403 otherwise):
  check-replace, downloads DELETE, redownload. Everyone keeps
  search/play/stage/keep/playlists.
- `scorer.download` caps at `--max-filesize 120M`; `users.py`
  MIN_PASSWORD_LEN 8 (new accounts); `_diagnostics` drops `music_root`.
- Known residual: DNS-rebinding TOCTOU on the fetch guard (resolve≠connect),
  `?token=` in URLs (TLS-protected, may land in logs), no anti-DDoS —
  funnel has none, ThreadingHTTPServer is unbounded.

## Host facts
- NAS SSH alias `nas` → `Opencode@100.89.94.101` (Tailscale) via `rtk ssh nas "<cmd>"`.
- DB inside container: `/root/.local/share/nasmusic/nasmusic.db` (tables: `downloads`, `candidates`, `added_meta`, `resolved_urls`, `track_durations`, `spotify_meta_imports`, `song_meta`, `events`, `webcache`). Survives `docker restart`.
- Compose: `…/Docker_Configs/music-app/music-app.yml` (image `python:3.12-slim`); run's container name `nasmusic`.
- Container mounts: `/app`=App/music-app, `/data/music`, `/data/playlists`, `/data/staging`. Env: `NASMUSIC_FOLDERS="Heavy,Jazz,OSTs,Saved,Liked"` etc.
- ffmpeg 7.1.5 + ffprobe exist at `/usr/bin` inside the container.

## Debugging workflow (for future agents)

**1. Use the behavior→code map FIRST**
- Every user-visible behavior is mapped to exact `file:line` in this document
- Don't reverse-engineer — grep the mapped location first

**2. Trace execution path with grep, not speculation**
- Bug: "playlist covers offline" → map says "covers offline" → `library_screen.dart:_art()` + `offline_store.dart`
- grep the mapped function → read 50 lines around it → find the read/write path mismatch in 30s

**3. Root-cause over symptom-chasing**
- Don't add fallbacks. Find why the write path never runs.
- "Covers don't work" → write path (`maybeCachePlaylistCover`) called with wrong args, key mismatch, never triggered on download

**4. Minimal surgical fixes**
- Fix the write path, not the read path
- Fix the ping-before-load ordering, not add more offline checks
- Add health timer to detect isolate death, not more position stream guards

**4. Verify before ship**
- `flutter test` (89 tests green)
- `flutter analyze` (0 errors)
- Byte-identical APK: `md5sum local.apk served.apk`
- Landing page version matches

**5. Skip council for traceable bugs**
- Council = for genuine architectural uncertainty (multiple valid approaches)
- Traceable execution-path bugs: grep → read → fix → verify is 10x faster
- Only escalate when fix doesn't work or root cause is genuinely ambiguous