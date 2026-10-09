"""SQLite persistence for the NASMusic server."""

import json
import os
import sqlite3
import threading
import time
import uuid

SCHEMA = """
CREATE TABLE IF NOT EXISTS downloads (
    id TEXT PRIMARY KEY,
    base_name TEXT UNIQUE NOT NULL,
    artist TEXT NOT NULL,
    title TEXT NOT NULL,
    video_id TEXT,
    url TEXT,
    channel TEXT,
    duration_s INTEGER,
    score INTEGER,
    path TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    keep_to TEXT,
    owner TEXT NOT NULL DEFAULT '',
    downloaded_at REAL,
    promoted_at REAL,
    updated_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS candidates (
    download_id TEXT NOT NULL REFERENCES downloads(id),
    video_id TEXT NOT NULL,
    title TEXT NOT NULL,
    channel TEXT NOT NULL,
    duration_s INTEGER,
    score INTEGER,
    tier INTEGER,
    seen_at REAL NOT NULL,
    PRIMARY KEY (download_id, video_id)
);
CREATE TABLE IF NOT EXISTS added_meta (
    playlist TEXT NOT NULL,
    base_name TEXT NOT NULL,
    added_at REAL,
    album_image TEXT,
    PRIMARY KEY (playlist, base_name)
);
CREATE TABLE IF NOT EXISTS resolved_urls (
    video_id TEXT PRIMARY KEY,
    url TEXT NOT NULL,
    seen_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS user_errors (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT NOT NULL,
    section TEXT NOT NULL,
    message TEXT NOT NULL,
    seen_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_user_errors_user ON user_errors(username);
CREATE TABLE IF NOT EXISTS track_durations (
    path TEXT PRIMARY KEY,
    size INTEGER NOT NULL,
    seconds REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS spotify_meta_imports (
    key TEXT PRIMARY KEY,
    fingerprint TEXT NOT NULL,
    imported_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS song_meta (
    base_name TEXT PRIMARY KEY,
    artist TEXT,
    album TEXT,
    album_artist TEXT,
    album_image TEXT
);
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS webcache (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    seen_at REAL NOT NULL
);
"""


def now():
    return time.time()


def new_id():
    return uuid.uuid4().hex[:12]


class Database:
    def __init__(self, path):
        self.path = path
        self._lock = threading.Lock()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        self._conn = sqlite3.connect(
            path, check_same_thread=False, timeout=30)
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            try:
                self._conn.execute("PRAGMA journal_mode=WAL")
                self._conn.execute("PRAGMA busy_timeout=10000")
            except Exception:                            # noqa: BLE001
                pass
            self._conn.executescript(SCHEMA)
            # Column added after the table existed: backfill once.
            try:
                cols = [r[1] for r in self._conn.execute(
                    "PRAGMA table_info(downloads)")]
                if "owner" not in cols:
                    self._conn.execute(
                        "ALTER TABLE downloads ADD COLUMN owner TEXT "
                        "NOT NULL DEFAULT ''")
                ucols = [r[1] for r in self._conn.execute(
                    "PRAGMA table_info(user_errors)")]
                if "seen" not in ucols:
                    self._conn.execute(
                        "ALTER TABLE user_errors ADD COLUMN seen INTEGER "
                        "NOT NULL DEFAULT 0")
            except Exception:                            # noqa: BLE001
                pass
            self._conn.commit()
        # In-memory overlays so the hot tap path (resolve cache reads) and the
        # generic webcache reads never block on the NAS disk while background
        # jobs are writing. The DB stays the durable backing store.
        self._res_mem = {}
        self._misc_mem = {}

    def execute(self, sql, params=()):
        with self._lock:
            cur = self._conn.execute(sql, params)
            self._conn.commit()
            return cur

    def query(self, sql, params=()):
        with self._lock:
            return [dict(r) for r in self._conn.execute(sql, params)]

    def create_download(self, artist, title, owner=""):
        base = f"{artist} - {title}"
        did = new_id()
        self.execute(
            """INSERT INTO downloads(id, base_name, artist, title, status,
                                     owner, updated_at)
               VALUES(?,?,?,?, 'pending', ?, ?)""",
            (did, base, artist, title, owner or "", now()),
        )
        return did

    def get_download(self, did):
        rows = self.query("SELECT * FROM downloads WHERE id=?", (did,))
        return rows[0] if rows else None

    def find_download_by_base(self, base_name):
        rows = self.query(
            "SELECT * FROM downloads WHERE base_name=?", (base_name,))
        return rows[0] if rows else None

    def update_download(self, did, **fields):
        fields["updated_at"] = now()
        cols = ", ".join(f"{k}=?" for k in fields)
        self.execute(
            f"UPDATE downloads SET {cols} WHERE id=?", (*fields.values(), did))

    def list_downloads(self, status=None, owner=None):
        """All rows (owner=None, the owner view) or STRICTLY one user's rows.
        Legacy owner='' rows are not shared: they are adopted once by the
        stager (pipeline.start_stage) instead of shown to everyone."""
        if owner:
            if status:
                return self.query(
                    "SELECT * FROM downloads "
                    "WHERE status=? AND owner=? "
                    "ORDER BY updated_at DESC", (status, owner))
            return self.query(
                "SELECT * FROM downloads "
                "WHERE owner=? "
                "ORDER BY updated_at DESC", (owner,))
        if status:
            return self.query(
                "SELECT * FROM downloads WHERE status=? "
                "ORDER BY updated_at DESC", (status,))
        return self.query("SELECT * FROM downloads ORDER BY updated_at DESC")

    def owner_map(self):
        """base_name -> owner (uploader) for file-visibility filtering.

        Legacy rows carry owner='' (visible to all when per-user libs
        are on). Single cheap query; callers cache briefly."""
        try:
            return {r["base_name"]: (r["owner"] or "")
                    for r in self.query(
                        "SELECT base_name, owner FROM downloads")}
        except Exception:                                # noqa: BLE001
            return {}

    def flag_get(self, name, default=False):
        """Persistent feature flag (webcache, never expires). OFF unless set."""
        try:
            got = self.misc_get("flag:" + str(name), 0)
        except Exception:                                # noqa: BLE001
            return default
        if got is None:
            return default
        if isinstance(got, dict) and "v" in got:
            return bool(got["v"])
        return bool(got)

    def flag_put(self, name, value):
        self.misc_put("flag:" + str(name), {"v": bool(value)})

    def log_user_error(self, username, section, message):
        """Persist a per-user error row (developer viewer). Cap 200/user."""
        try:
            user = (username or "").strip()
            msg = (message or "").strip()[:2100]
            if not user or not msg:
                return
            self.execute(
                "INSERT INTO user_errors(username, section, message,"
                " seen_at) VALUES(?,?,?,?)",
                (user, (section or "general")[:20], msg, now()))
            self.execute(
                "DELETE FROM user_errors WHERE username=? AND id NOT IN"
                " (SELECT id FROM user_errors WHERE username=?"
                " ORDER BY id DESC LIMIT 200)",
                (user, user))
        except Exception:                                # noqa: BLE001
            pass

    def list_user_errors(self, username=None, section=None, q=None,
                         limit=200, unseen=False):
        """Rows newest-first, optional filters (case-insensitive match)."""
        sql = ("SELECT id, username, section, message, seen, seen_at"
               " FROM user_errors")
        where, params = [], []
        if username:
            where.append("username=?")
            params.append(username)
        if section:
            where.append("section=?")
            params.append(section)
        if q:
            where.append("message LIKE ?")
            params.append("%" + q + "%")
        if unseen:
            where.append("seen=0")
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY id DESC LIMIT ?"
        params.append(max(1, min(int(limit or 200), 500)))
        try:
            return self.query(sql, tuple(params))
        except Exception:                                # noqa: BLE001
            return []

    def mark_user_errors_seen(self, username=None, ids=None):
        """Flag error rows as seen (1). ids limits rows; username scopes."""
        try:
            if ids:
                placeholders = ",".join("?" for _ in ids)
                if username:
                    self.execute(
                        "UPDATE user_errors SET seen=1 WHERE id IN "
                        f"({placeholders}) AND username=?",
                        (*ids, username))
                else:
                    self.execute(
                        "UPDATE user_errors SET seen=1 WHERE id IN "
                        f"({placeholders})", tuple(ids))
                return True
            if username:
                self.execute(
                    "UPDATE user_errors SET seen=1 WHERE username=?",
                    (username,))
                return True
            self.execute("UPDATE user_errors SET seen=1")
            return True
        except Exception:                                # noqa: BLE001
            return False

    def record_candidates(self, download_id, cands):
        for c in cands:
            self.execute(
                """INSERT OR REPLACE INTO candidates
                   (download_id, video_id, title, channel, duration_s,
                    score, tier, seen_at)
                   VALUES(?,?,?,?,?,?,?,?)""",
                (download_id, c["video_id"], c["title"], c["channel"],
                 c.get("duration_s"), c.get("score"), c.get("tier"), now()))

    def candidates_for(self, did):
        return self.query(
            """SELECT * FROM candidates WHERE download_id=?
               ORDER BY score DESC, seen_at ASC""", (did,))

    def resolved_cache_get(self, video_id, max_age):
        m = self._res_mem.get(video_id)
        if m and now() - m[1] <= max_age:
            return m[0]
        rows = self.query(
            "SELECT url, seen_at FROM resolved_urls WHERE video_id=?",
            (video_id,))
        if not rows:
            return None
        r = rows[0]
        if now() - r["seen_at"] > max_age:
            return None
        self._res_mem[video_id] = (r["url"], r["seen_at"])
        return r["url"]

    def resolved_cache_put(self, video_id, url):
        self._res_mem[video_id] = (url, now())
        if len(self._res_mem) > 5000:
            oldest = min(self._res_mem,
                         key=lambda k: self._res_mem[k][1])
            self._res_mem.pop(oldest, None)
        self.execute(
            """INSERT OR REPLACE INTO resolved_urls(video_id, url, seen_at)
               VALUES(?,?,?)""", (video_id, url, now()))

    def duration_get(self, path, size):
        rows = self.query(
            "SELECT seconds FROM track_durations "
            "WHERE path=? AND size=?", (path, size))
        return rows[0]["seconds"] if rows else None

    def duration_put(self, path, size, seconds):
        self.execute(
            """INSERT OR REPLACE INTO track_durations(path, size, seconds)
               VALUES(?,?,?)""", (path, size, seconds))

    def added_meta_get(self, playlist, base_name):
        rows = self.query(
            "SELECT * FROM added_meta WHERE playlist=? AND base_name=?",
            (playlist, base_name))
        return rows[0] if rows else None

    def added_meta_get_any(self, base_name):
        """First album-image/added-date row for a base name, any playlist."""
        rows = self.query(
            "SELECT * FROM added_meta WHERE base_name=? "
            "ORDER BY rowid ASC LIMIT 1", (base_name,))
        return rows[0] if rows else None

    def meta_import_get(self, key):
        rows = self.query(
            "SELECT fingerprint FROM spotify_meta_imports WHERE key=?",
            (key,))
        return rows[0]["fingerprint"] if rows else None

    def meta_import_put(self, key, fingerprint):
        self.execute(
            """INSERT OR REPLACE INTO spotify_meta_imports
               (key, fingerprint, imported_at) VALUES(?,?,?)""",
            (key, fingerprint, now()))

    def song_meta_put(self, base_name, artist, album, album_artist,
                      album_image):
        self.execute(
            """INSERT OR REPLACE INTO song_meta
               (base_name, artist, album, album_artist, album_image)
               VALUES(?,?,?,?,?)""",
            (base_name, artist, album, album_artist, album_image))

    def song_meta_get(self, base_name):
        rows = self.query(
            "SELECT * FROM song_meta WHERE base_name=?", (base_name,))
        return rows[0] if rows else None

    def song_meta_clear(self):
        self.execute("DELETE FROM song_meta")

    def added_meta_for(self, playlist):
        return self.query(
            "SELECT * FROM added_meta WHERE playlist=?", (playlist,))

    def set_added_meta(self, playlist, base_name, added_at, album_image):
        self.execute(
            """INSERT OR REPLACE INTO added_meta
               (playlist, base_name, added_at, album_image)
               VALUES(?,?,?,?)""",
            (playlist, base_name, added_at, album_image))

    def event(self, kind, payload):
        self.execute(
            "INSERT INTO events(kind, payload, created_at) VALUES(?,?,?)",
            (kind, json.dumps(payload, ensure_ascii=False), now()))

    def misc_get(self, key, max_age):
        """JSON value from a small generic cache, or None if missing/stale.
        max_age <= 0 means never expire (persistent rows: playlist order,
        import sources, migration markers)."""
        m = self._misc_mem.get(key)
        if m and (max_age <= 0 or now() - m[0] <= max_age):
            return m[1]
        rows = self.query(
            "SELECT value, seen_at FROM webcache WHERE key=?", (key,))
        if not rows:
            return None
        r = rows[0]
        if max_age > 0 and now() - r["seen_at"] > max_age:
            return None
        try:
            val = json.loads(r["value"])
        except Exception:
            return None
        self._misc_mem[key] = (r["seen_at"], val)
        if len(self._misc_mem) > 4000:
            oldest = min(self._misc_mem,
                         key=lambda k: self._misc_mem[k][0])
            self._misc_mem.pop(oldest, None)
        return val

    def misc_put(self, key, value):
        ts = now()
        self._misc_mem[key] = (ts, value)
        if len(self._misc_mem) > 4000:
            oldest = min(self._misc_mem,
                         key=lambda k: self._misc_mem[k][0])
            self._misc_mem.pop(oldest, None)
        self.execute(
            """INSERT OR REPLACE INTO webcache(key, value, seen_at)
               VALUES(?,?,?)""", (key, json.dumps(value, ensure_ascii=False),
                                  ts))
