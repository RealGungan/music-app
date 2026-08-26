"""SQLite persistence: searches, downloads, candidates, events."""

import json
import os
import sqlite3
import threading
import time
import uuid

SCHEMA = """
CREATE TABLE IF NOT EXISTS searches (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    query TEXT NOT NULL,
    created_at REAL NOT NULL
);
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
CREATE TABLE IF NOT EXISTS events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    kind TEXT NOT NULL,
    payload TEXT NOT NULL,
    created_at REAL NOT NULL
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
            path, check_same_thread=False, timeout=30
        )
        self._conn.row_factory = sqlite3.Row
        with self._lock:
            self._conn.executescript(SCHEMA)
            try:
                self._conn.execute(
                    "ALTER TABLE downloads ADD COLUMN keep_to TEXT")
            except sqlite3.OperationalError:
                pass
            self._conn.commit()

    def execute(self, sql, params=()):
        with self._lock:
            cur = self._conn.execute(sql, params)
            self._conn.commit()
            return cur

    def query(self, sql, params=()):
        with self._lock:
            return [dict(r) for r in self._conn.execute(sql, params)]

    def log_search(self, q):
        self.execute(
            "INSERT INTO searches(query, created_at) VALUES(?,?)",
            (q, now()),
        )

    def record_candidates(self, download_id, cands):
        for c in cands:
            self.execute(
                """INSERT OR REPLACE INTO candidates
                   (download_id, video_id, title, channel, duration_s,
                    score, tier, seen_at)
                   VALUES(?,?,?,?,?,?,?,?)""",
                (
                    download_id, c["video_id"], c["title"], c["channel"],
                    c.get("duration_s"), c.get("score"), c.get("tier"),
                    now(),
                ),
            )

    def create_download(self, artist, title):
        base = f"{artist} - {title}"
        did = new_id()
        self.execute(
            """INSERT INTO downloads(id, base_name, artist, title, status,
                                     updated_at)
               VALUES(?,?,?,?, 'pending', ?)""",
            (did, base, artist, title, now()),
        )
        return did

    def get_download(self, did):
        rows = self.query("SELECT * FROM downloads WHERE id=?", (did,))
        return rows[0] if rows else None

    def find_download_by_base(self, base_name):
        rows = self.query(
            "SELECT * FROM downloads WHERE base_name=?", (base_name,)
        )
        return rows[0] if rows else None

    def update_download(self, did, **fields):
        fields["updated_at"] = now()
        cols = ", ".join(f"{k}=?" for k in fields)
        self.execute(
            f"UPDATE downloads SET {cols} WHERE id=?",
            (*fields.values(), did),
        )

    def list_downloads(self, status=None):
        if status:
            return self.query(
                "SELECT * FROM downloads WHERE status=? ORDER BY updated_at DESC",
                (status,),
            )
        return self.query("SELECT * FROM downloads ORDER BY updated_at DESC")

    def candidates_for(self, did):
        return self.query(
            """SELECT * FROM candidates WHERE download_id=?
               ORDER BY score DESC, seen_at ASC""",
            (did,),
        )

    def resolved_cache_get(self, video_id, max_age):
        rows = self.query(
            "SELECT url, seen_at FROM resolved_urls WHERE video_id=?",
            (video_id,),
        )
        if not rows:
            return None
        r = rows[0]
        if now() - r["seen_at"] > max_age:
            return None
        return r["url"]

    def resolved_cache_put(self, video_id, url):
        self.execute(
            """INSERT OR REPLACE INTO resolved_urls(video_id, url, seen_at)
               VALUES(?,?,?)""",
            (video_id, url, now()),
        )

    def event(self, kind, payload):
        self.execute(
            "INSERT INTO events(kind, payload, created_at) VALUES(?,?,?)",
            (kind, json.dumps(payload, ensure_ascii=False), now()),
        )
