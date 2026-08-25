"""Process-wide runtime state, configured once from Mopidy config."""

import json
import os
import sqlite3
import threading

from .db import Database
from .pipeline import Pipeline


class StagingState:
    """Holds resolved config, database, and the download pipeline.

    Configured by whichever component first sees validated config
    (the backend actor); everything else fetches the singleton.
    """

    _instance = None
    _lock = threading.Lock()

    def __init__(self, config):
        staging = config["staging"]
        self.music_root = staging["music_root"]
        self.staging_dir = staging["staging_dir"]
        self.playlist_dir = staging.get("playlist_dir") or os.path.join(
            staging["staging_dir"], "playlists")
        self.folders = list(staging["folders"] or [])
        self.expiry_days = staging["expiry_days"] or 7
        self.yt_dlp_bin = staging["yt_dlp_bin"]
        self.node_runtime = staging.get("node_runtime") or ""
        db_path = staging.get("db_path")
        if not db_path:
            data_dir = os.path.expanduser("~/.local/share/mopidy-staging")
            os.makedirs(data_dir, exist_ok=True)
            db_path = os.path.join(data_dir, "staging.db")
        os.makedirs(self.staging_dir, exist_ok=True)
        os.makedirs(self.playlist_dir, exist_ok=True)
        for f in self.folders:
            os.makedirs(os.path.join(self.music_root, f), exist_ok=True)
        self.db = Database(db_path)
        self.pipeline = Pipeline(self)

    @classmethod
    def configure(cls, config):
        with cls._lock:
            if cls._instance is None:
                cls._instance = cls(config)
            return cls._instance

    @classmethod
    def instance(cls):
        if cls._instance is None:
            raise RuntimeError("StagingState not configured yet")
        return cls._instance

    def _walk_m3us(self, base):
        """All *.m3u anywhere under base."""
        found = {}
        for root, dirs, files in os.walk(base):
            dirs[:] = [d for d in dirs if d != "_Staging"
                       and d != ".git"]
            for f in files:
                if f.endswith(".m3u"):
                    found.setdefault(f[:-4], os.path.join(root, f))
        return found

    def playlist_paths(self):
        """Every known playlist: playlist_dir (recursive) + library."""
        out = {}
        out.update(self._walk_m3us(self.playlist_dir))
        for name, p in self._walk_m3us(self.music_root).items():
            out.setdefault(name, p)
        yield from sorted(out.items())

    def m3u_for(self, name):
        """Existing m3u for a playlist, or where a new one goes."""
        for pname, p in self.playlist_paths():
            if pname == name:
                return p
        return os.path.join(self.playlist_dir, f"{name}.m3u")

    def promote_dest(self, playlist):
        """Where a kept track moves: same-name library folder if it
        exists under music_root, else the Saved folder."""
        candidate = os.path.join(self.music_root, playlist)
        if os.path.isdir(candidate) and playlist != "_Staging":
            return candidate
        fallback = os.path.join(self.music_root, "Saved")
        os.makedirs(fallback, exist_ok=True)
        return fallback

    def all_playlist_entries(self):
        """Set of bare filenames referenced by any playlist m3u."""
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
