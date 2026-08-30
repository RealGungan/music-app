"""Process-wide runtime state: config, library walking, playlist helpers."""

import os

from .db import Database
from .scorer import Scorer


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
        self.db_path = os.path.expanduser(
            pick("DB_PATH", os.path.expanduser(
                "~/.local/share/nasmusic/nasmusic.db")))
        folders = pick("FOLDERS", "Heavy,Jazz,OSTs,Saved,Liked")
        self.folders = [f.strip() for f in folders.split(",") if f.strip()]
        self.expiry_days = int(pick("EXPIRY_DAYS", "7"))
        self.yt_dlp_bin = pick("YT_DLP_BIN", "yt-dlp")
        self.host = pick("HOST", "0.0.0.0")
        self.port = int(pick("PORT", "6680"))
        self.resolve_cache_ttl = int(pick("RESOLVE_TTL", "3600"))

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

    __slots__ = ("config", "db", "scorer", "pipeline")

    def __init__(self, config: Config):
        self.config = config
        config.ensure_dirs()
        self.db = Database(config.db_path)
        self.scorer = Scorer(
            yt_dlp_bin=config.yt_dlp_bin,
            log_fn=lambda m: print(m, flush=True),
        )
        from .pipeline import Pipeline
        self.pipeline = Pipeline(self)
        n = self.ensure_playlist_m3us()
        if n:
            print(f"nasmusic: auto-created m3u for {n} playlist folder(s)",
                  flush=True)

    # --------------------------------------------------------- library
    @staticmethod
    def _walk_mp3(root):
        for rpath, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d != "_Staging" and d != ".git"]
            for fn in files:
                if fn.lower().endswith(".mp3"):
                    yield os.path.join(rpath, fn)

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
        Playlists/Saved, Playlists/OSTs) show up as playlists."""
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
            try:
                songs = sorted(
                    f for f in os.listdir(entry.path)
                    if f.lower().endswith(".mp3"))
            except OSError:
                continue
            if not songs:
                continue
            m3u = os.path.join(entry.path, entry.name + ".m3u")
            with open(m3u, "w", encoding="utf-8") as fh:
                for f in songs:
                    fh.write(f + "\n")
            created += 1
        return created

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
