"""Process-wide runtime state: config, library walking, playlist helpers."""

import os
import threading
import time

from .db import Database
from .scorer import Scorer
from .users import UserStore


class Config:
    """Resolved server configuration (env-overridable, NAS-friendly)."""

    def __init__(self, **overrides):
        env = os.environ
        norm_ov = {k.lower(): v for k, v in overrides.items()}
        def pick(key, default):
            low = key.lower()
            if low in norm_ov:
                return norm_ov[low]
            if key in norm_ov:
                return norm_ov[key]
            return env.get("NASMUSIC_" + key, default)

        self.music_root = os.path.expanduser(
            pick("MUSIC_ROOT", "/data/music"))
        self.staging_dir = os.path.expanduser(
            pick("STAGING_DIR", "/data/staging"))
        self.playlist_dir = os.path.expanduser(
            pick("PLAYLIST_DIR", "/data/playlists"))
        # Multi-user homes: each login name owns <dir>/<name>/... (private
        # playlists + credentials). MUST be a mounted path (/data/users) so
        # accounts survive container recreates (the SQLite DB does not).
        self.users_dir = os.path.expanduser(
            pick("USERS_DIR", "/data/users"))
        self.db_path = os.path.expanduser(
            pick("DB_PATH", os.path.expanduser(
                "~/.local/share/nasmusic/nasmusic.db")))
        self.spotify_meta = pick(
            "SPOTIFY_META",
            os.path.join("~/.local/share/nasmusic",
                         "spotify_nasmusic_meta.json"))
        self.spotify_meta = os.path.expanduser(self.spotify_meta)
        self.lyrics_bundle = pick(
            "LYRICS_BUNDLE",
            os.path.join("~/.local/share/nasmusic",
                         "lyrics_bundle.json"))
        self.lyrics_bundle = os.path.expanduser(self.lyrics_bundle)
        folders = pick("FOLDERS", "Heavy,Jazz,OSTs,Saved,Liked")
        self.folders = [f.strip() for f in folders.split(",") if f.strip()]
        self.expiry_days = int(pick("EXPIRY_DAYS", "7"))
        self.yt_dlp_bin = pick("YT_DLP_BIN", "yt-dlp")
        self.host = pick("HOST", "0.0.0.0")
        self.port = int(pick("PORT", "6680"))
        # googlevideo URLs expire ~6h after minting: caching them longer
        # serves dead links that fail at tap time (proven live: 6h-old rows
        # failing while fresh rows play). 4h keeps a safe margin.
        self.resolve_cache_ttl = int(pick("RESOLVE_TTL", "14400"))
        self.acoustid_api_key = pick("ACOUSTID_API_KEY", "")
        self.fpcalc_bin = pick("FPCALC_BIN", "fpcalc")
        self.fpcalc_path = pick("FPCALC_PATH", "fpcalc")
        # Invite code gate for open registration (empty = open, as before).
        # Set NASMUSIC_INVITE_CODE in the compose env; friends enter it at
        # signup. Rotate it there to cut off old shares (existing sessions
        # and users are unaffected).
        self.invite_code = pick("INVITE_CODE", "")
        # Per-user libraries (visibility-only split of the shared library).
        # Default OFF; DB flag `flag:per_user_libs` (owner toggle) wins when
        # set. Rollback = flag off (or env 0). Nothing is ever deleted.
        self.per_user_libs = str(
            pick("PER_USER_LIBS", "0")).strip().lower() in (
                "1", "true", "yes", "on")
        # Spotify app credentials (bare SPOTIFY_* names also accepted).
        # Secret never leaves the NAS.
        import os as _os
        self.spotify_client_id = pick("SPOTIFY_CLIENT_ID", "") or \
            _os.environ.get("SPOTIFY_CLIENT_ID", "")
        self.spotify_client_secret = pick("SPOTIFY_CLIENT_SECRET", "") or \
            _os.environ.get("SPOTIFY_CLIENT_SECRET", "")
        # YouTube Music OAuth (TV device flow) for private library/likes.
        # Google Cloud OAuth client of type "TVs and Limited Input"
        # (one-time owner setup). Per-user tokens live in private homes.
        self.ytmusic_client_id = pick("YTMUSIC_CLIENT_ID", "") or \
            _os.environ.get("YTMUSIC_CLIENT_ID", "")
        self.ytmusic_client_secret = pick("YTMUSIC_CLIENT_SECRET", "") or \
            _os.environ.get("YTMUSIC_CLIENT_SECRET", "")

    def ensure_dirs(self):
        for d in (self.playlist_dir,):
            os.makedirs(d, exist_ok=True)
        os.makedirs(os.path.dirname(self.db_path), exist_ok=True)
        for f in ("Saved",):
            os.makedirs(os.path.join(self.music_root, f), exist_ok=True)

    def promote_dest(self, playlist):
        candidate = os.path.join(self.music_root, playlist)
        if os.path.isdir(candidate):
            return candidate
        fallback = os.path.join(self.music_root, "Saved")
        os.makedirs(fallback, exist_ok=True)
        return fallback


class State:
    """Holds config, database, scorer and the staging pipeline."""

    __slots__ = ("config", "db", "scorer", "pipeline", "users",
                 "_warm_lock", "_warm_started", "lyrics_bundle",
                 "_index_lock", "_index_cache", "_index_ts", "_index_ttl")

    def __init__(self, config: Config):
        self.config = config
        config.ensure_dirs()
        self.db = Database(config.db_path)
        self.users = UserStore(config.users_dir)
        self.scorer = Scorer(
            yt_dlp_bin=config.yt_dlp_bin,
            log_fn=lambda m: print(m, flush=True),
        )
        from .pipeline import Pipeline
        self.pipeline = Pipeline(self)
        self._warm_lock = threading.Lock()
        self._warm_started = False
        self._index_lock = threading.Lock()
        self._index_cache = None
        self._index_ts = 0.0
        self._index_ttl = 30.0
        n = self.ensure_playlist_m3us()
        if n:
            print(f"nasmusic: auto-created m3u for {n} playlist folder(s)",
                  flush=True)
        self.ensure_duration_warm()
        self.import_spotify_meta()
        self.load_lyrics_bundle()

    # ---------------------------------------------------- lyrics bundle
    def _find_lyrics_bundle(self):
        candidates = [
            os.path.expanduser(self.config.lyrics_bundle),
            os.path.join(os.path.dirname(self.config.db_path),
                         "lyrics_bundle.json"),
            "/app/lyrics_bundle.json",
        ]
        for c in candidates:
            if os.path.exists(c) and os.path.getsize(c) > 16:
                return c
        return None

    def load_lyrics_bundle(self):
        """Load shipped <song>.lrc lyrics so sidecar/network failures never
        matter — lyrics appear even with no NAS internet."""
        path = self._find_lyrics_bundle()
        self.lyrics_bundle = {}
        if not path:
            return 0
        import json
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                blob = json.load(fh)
        except (OSError, ValueError):
            return 0
        self.lyrics_bundle = {
            str(k): v for k, v in (blob or {}).items() if isinstance(v, str)}
        return len(self.lyrics_bundle)

    # ----------------------------------------------------- spotify meta
    def _find_spotify_meta(self):
        candidates = [
            os.path.expanduser(self.config.spotify_meta),
            os.path.join(os.path.dirname(self.config.db_path),
                         "spotify_nasmusic_meta.json"),
            "/app/spotify_nasmusic_meta.json",
        ]
        for c in candidates:
            if os.path.exists(c) and os.path.getsize(c) > 16:
                return c
        return None

    def import_spotify_meta(self):
        """Idempotently import Spotify exported added-dates/album-art into
        `added_meta` (keyed by playlist + base_name) so playlists can be
        ordered the way Spotify shows them and songs get real covers."""
        path = self._find_spotify_meta()
        if not path:
            return 0
        import hashlib, json, time as _t
        try:
            with open(path, "rb") as fh:
                data = fh.read()
        except OSError:
            return 0
        fingerprint = hashlib.sha1(data).hexdigest()[:16]
        if self.db.meta_import_get("spotify") == fingerprint:
            return 0
        try:
            blob = json.loads(data.decode("utf-8", "replace"))
        except ValueError:
            return 0
        n = 0
        self.db.song_meta_clear()
        for playlist, rows in (blob or {}).items():
            if not isinstance(rows, list):
                continue
            for row in rows or []:
                base = (row.get("base_name") or "").strip()
                if not base:
                    continue
                ts = row.get("added_at") or row.get("added")
                if isinstance(ts, str):
                    try:
                        import datetime as _dt
                        ts = float(_dt.datetime.fromisoformat(
                            ts.replace("Z", "+00:00")).timestamp())
                    except ValueError:
                        ts = None
                self.db.set_added_meta(
                    playlist, base,
                    float(ts) if ts is not None else None,
                    row.get("album_image"))
                artist, _, title = base.partition(" - ")
                self.db.song_meta_put(
                    base,
                    row.get("artist") or (artist.strip() if artist else None),
                    row.get("album"),
                    row.get("album_artist"),
                    row.get("album_image"))
                n += 1
        self.db.meta_import_put("spotify", fingerprint)
        print(f"nasmusic: imported Spotify meta ({n} tracks) from {path}",
              flush=True)
        return n

    # --------------------------------------------------------- durations
    def duration_for(self, abs_path):
        """Cached mp3 duration in seconds (None until ffprobe has run)."""
        try:
            st = os.stat(abs_path)
        except OSError:
            return None
        return self.db.duration_get(abs_path, st.st_size)

    def warm_duration_cache(self, limit=30000):
        """Compute missing mp3 durations in the background (best-effort)."""
        from .scorer import ffprobe_duration
        done = 0
        seen = set()
        for base in (self.config.music_root, self.config.playlist_dir):
            if not os.path.isdir(base):
                continue
            for full in self._walk_mp3(base):
                if full in seen or done >= limit:
                    continue
                seen.add(full)
                try:
                    sz = os.stat(full).st_size
                except OSError:
                    continue
                if self.db.duration_get(full, sz) is not None:
                    continue
                d = ffprobe_duration(full)
                if d is not None:
                    self.db.duration_put(full, sz, d)
                    done += 1

    def ensure_duration_warm(self):
        """Start the background duration scan exactly once per process."""
        with self._warm_lock:
            if self._warm_started:
                return
            self._warm_started = True
        threading.Thread(target=self.warm_duration_cache,
                         daemon=True).start()

    def playlist_cover_path(self, name):
        m3u = self.m3u_for(name)
        return os.path.splitext(m3u)[0] + ".jpg"

    # --------------------------------------------------------- library
    @staticmethod
    def _walk_mp3(root):
        for rpath, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d != "_Staging" and d != ".git"]
            for fn in files:
                if fn.lower().endswith(".mp3"):
                    yield os.path.join(rpath, fn)

    def local_mp3_index(self):
        """base_name -> full path for every playable MP3 across the music +
        playlist folders. Cached briefly so a search request that touches it
        many times doesn't re-walk the (slow, remote) filesystem each time."""
        now = time.monotonic()
        with self._index_lock:
            if self._index_cache is not None and \
                    now - self._index_ts < self._index_ttl:
                return self._index_cache
        idx = {}
        for base in (self.config.music_root, self.config.staging_dir,
                     self.config.playlist_dir):
            if not os.path.isdir(base):
                continue
            for full in self._walk_mp3(base):
                bn = os.path.basename(full)[:-4]
                idx.setdefault(bn, full)
        with self._index_lock:
            self._index_cache = idx
            self._index_ts = time.monotonic()
        return idx

    def _walk_m3us(self, base):
        found = {}
        for root, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d != "_Staging" and d != ".git"]
            for f in files:
                if f.endswith(".m3u"):
                    found.setdefault(f[:-4], os.path.join(root, f))
        return found

    def playlist_paths(self):
        out = {}
        out.update(self._walk_m3us(self.config.playlist_dir))
        for name, p in self._walk_m3us(self.config.music_root).items():
            out.setdefault(name, p)
        return sorted(out.items())

    def m3u_for(self, name):
        for pname, p in self.playlist_paths():
            if pname == name:
                return p
        return os.path.join(self.config.playlist_dir, f"{name}.m3u")

    def ensure_playlist_m3us(self):
        """Auto-create <name>.m3u inside any mp3 subfolder of the playlist
        dir that has no playlist m3u yet, so folder-based libraries (e.g.
        Playlists/Saved, Playlists/OSTs) show up as playlists. Folders marked
        with a `.nom3u` tombstone (deleted from the app) are skipped."""
        pld = self.config.playlist_dir
        if not os.path.isdir(pld):
            return 0
        existing = {name for name, _ in self.playlist_paths()}
        created = 0
        for entry in sorted(os.scandir(pld), key=lambda e: e.name):
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            if entry.name in existing:
                continue
            if os.path.exists(os.path.join(entry.path, ".nom3u")):
                continue
            try:
                files = sorted(os.listdir(entry.path))
            except OSError:
                continue
            # A folder holding ANY .m3u is already covered (e.g. a renamed
            # <folder>/<new>.m3u) — recreating <folder>.m3u would resurrect
            # the old name as a duplicate playlist.
            if any(f.lower().endswith(".m3u") for f in files):
                continue
            songs = sorted(
                f for f in files
                if f.lower().endswith(".mp3"))
            if not songs:
                continue
            m3u = os.path.join(entry.path, entry.name + ".m3u")
            with open(m3u, "w", encoding="utf-8") as fh:
                for f in songs:
                    fh.write(f + "\n")
            created += 1
        return created

    def tombstone_playlist_folder(self, m3u_path, name=None):
        """Mark a folder-derived playlist as deleted so auto-creation won't
        bring it back; the music in the folder is left untouched."""
        folder = os.path.dirname(os.path.abspath(m3u_path))
        if os.path.normpath(folder) == os.path.normpath(
                self.config.playlist_dir):
            return False
        with open(os.path.join(folder, ".nom3u"), "w") as fh:
            fh.write((name or os.path.basename(folder)) + "\n")
        return True

    def rel_to_root(self, abs_path):
        root = os.path.normpath(self.config.music_root)
        return os.path.relpath(abs_path, root)

    def all_playlist_entries(self):
        names = set()
        for _, path in self.playlist_paths():
            try:
                with open(path, encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        line = line.strip()
                        if line and not line.startswith("#"):
                            names.add(os.path.basename(line))
            except OSError:
                continue
        return names
