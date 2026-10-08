"""Multi-user accounts for NASMusic: registration, login, sessions.

Storage lives under <users_dir>/.nasmusic/ as locked JSON files so accounts
survive container recreates (the SQLite DB lives on container-local disk and
does not). Stdlib only: hashlib PBKDF2-HMAC-SHA256 for password hashes,
secrets for opaque session tokens. No plaintext passwords anywhere.

Layout (users_dir defaults to /data/users, env NASMUSIC_USERS_DIR):
  <users_dir>/.nasmusic/users.json      {username: {salt, hash, iters, created}}
  <users_dir>/.nasmusic/sessions.json   {token: {username, device_id,
                                         device_name, created, last_seen}}
  <users_dir>/<username>/Media/Music/Playlists/   per-user private playlists

Username uniqueness: a name is taken when it is already registered, or its
folder carries another name's claim marker. Comparisons are
case-insensitive (Bob == bob on every filesystem, including the
case-sensitive ext4 underneath SMB clients that cannot tell them apart).
A pre-existing NAS folder with no marker is claimable exactly once (the
owner adopts their tree); the claim writes `.nasmusic-owner` so later
attempts 409.
"""

import hashlib
import hmac
import json
import os
import re
import secrets
import threading
import time

PBKDF2_ITERS = 200_000
SALT_BYTES = 16
TOKEN_BYTES = 32
MIN_PASSWORD_LEN = 6
MAX_USERNAME_LEN = 32
USERNAME_RE = re.compile(r"^[\w\- ]+$")
RESERVED_NAMES = {".nasmusic", ".", ".."}
LAST_SEEN_TTL = 60  # seconds between last_seen rewrites (avoid a write per poll)


class UserError(Exception):
    """Carries an HTTP status + message for the route layer."""

    def __init__(self, status, msg):
        super().__init__(msg)
        self.status = status
        self.msg = msg


def valid_username(name):
    """Returns (ok, reason). Filesystem-safe, no path separators/traversal."""
    name = (name or "").strip()
    if not name:
        return False, "missing username"
    if len(name) > MAX_USERNAME_LEN:
        return False, "username too long (max %d)" % MAX_USERNAME_LEN
    if "/" in name or "\\" in name or name in RESERVED_NAMES:
        return False, "invalid username"
    if name.startswith("."):
        return False, "invalid username"
    if not USERNAME_RE.match(name):
        return False, "username may only contain letters, numbers, spaces, - and _"
    return True, ""


def _b64encode(b):
    import base64
    return base64.b64encode(b).decode("ascii")


def _b64decode(s):
    import base64
    return base64.b64decode(s.encode("ascii"))


def hash_password(password, salt=None, iters=PBKDF2_ITERS):
    salt = salt if salt is not None else secrets.token_bytes(SALT_BYTES)
    dk = hashlib.pbkdf2_hmac(
        "sha256", password.encode("utf-8"), salt, iters)
    return {"salt": _b64encode(salt), "hash": _b64encode(dk), "iters": iters}


def verify_password(password, rec):
    try:
        salt = _b64decode(rec["salt"])
        want = _b64decode(rec["hash"])
        iters = int(rec.get("iters") or PBKDF2_ITERS)
    except Exception:
        return False
    got = hashlib.pbkdf2_hmac("sha256", password.encode("utf-8"), salt, iters)
    return hmac.compare_digest(got, want)


class UserStore:
    """Locked JSON-backed user + session store under <root>/.nasmusic/."""

    def __init__(self, root):
        self.root = os.path.abspath(os.path.expanduser(root))
        self._dir = os.path.join(self.root, ".nasmusic")
        self._lock = threading.Lock()

    # -- paths -----------------------------------------------------------
    def _users_path(self):
        return os.path.join(self._dir, "users.json")

    def _sessions_path(self):
        return os.path.join(self._dir, "sessions.json")

    def require_root(self):
        if not os.path.isdir(self.root):
            raise UserError(
                500, "users storage not mounted (expected %s — add the "
                "Users share to the container)" % self.root)

    def usernames(self):
        """All registered names (developer error viewer lists even the
        quiet ones)."""
        self.require_root()
        with self._lock:
            users = self._read(self._users_path())
        return sorted(users.keys())

    def user_home(self, username):
        return self.home_for(username)

    def home_for(self, username, users=None):
        """Home dir for [username]. A preprovisioned account may point at
        an EXISTING NAS folder with another name (e.g. login ka0s lives
        in folder Berta) via rec["home"]; otherwise Users/<username>."""
        try:
            if users is None:
                users = self._read(self._users_path())
            rec = users.get(username) or {}
            home = (rec.get("home") or "").strip()
            if home and "/" not in home and "\\" not in home \
                    and home not in RESERVED_NAMES \
                    and not home.startswith("."):
                return os.path.join(self.root, home)
        except Exception:
            pass
        return os.path.join(self.root, username)

    def user_playlists_dir(self, username):
        return os.path.join(
            self.user_home(username), "Media", "Music", "Playlists")

    def ytmusic_oauth_path(self, username):
        """Per-user YouTube Music OAuth token file (0600 on write).
        Lives in the private home so tokens never mix between users."""
        return os.path.join(self.user_home(username), ".ytmusic-oauth.json")

    def user_homes(self):
        """Existing user home dir names (for cross-user sweeps)."""
        try:
            return [d for d in os.listdir(self.root)
                    if not d.startswith(".")
                    and os.path.isdir(os.path.join(self.root, d))]
        except OSError:
            return []

    # Claim marker: every app-managed home carries `.nasmusic-owner`
    # holding the owning login name. A pre-existing NAS folder has no
    # marker and is claimable exactly once; afterwards the marker (plus
    # the account row) makes re-registration a 409.
    OWNER_MARKER = ".nasmusic-owner"

    def _read_marker(self, home):
        try:
            with open(os.path.join(home, self.OWNER_MARKER),
                      "r", encoding="utf-8") as f:
                return f.read().strip() or None
        except OSError:
            return None

    def _write_marker(self, home, username):
        try:
            with open(os.path.join(home, self.OWNER_MARKER),
                      "w", encoding="utf-8") as f:
                f.write(username + "\n")
        except OSError:
            pass

    # -- json io (caller holds the lock) ----------------------------------
    @staticmethod
    def _read(path):
        try:
            with open(path, "r", encoding="utf-8") as f:
                d = json.load(f)
                return d if isinstance(d, dict) else {}
        except (OSError, ValueError):
            return {}

    def _write(self, path, obj):
        os.makedirs(self._dir, exist_ok=True)
        tmp = path + ".tmp.%d" % os.getpid()
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        try:
            os.chmod(tmp, 0o600)
        except OSError:
            pass
        os.replace(tmp, path)
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    # -- api ---------------------------------------------------------------
    def preprovision(self, username, home=None):
        """Create a PASSWORDLESS account row (dev action, SSH only): the
        login exists but can never log in until a password is set — either
        here later or by the user themselves registering with that exact
        name (claim path, no 409). Optionally ties the login to an
        EXISTING NAS folder with another name (home="Berta" for ka0s).
        Never creates, wipes, or renames any folder: an explicit home must
        already exist; the default Users/<username> home is created empty
        only when missing (makedirs exist_ok — adopt, never overwrite)."""
        username = (username or "").strip()
        ok, reason = valid_username(username)
        if not ok:
            raise UserError(400, reason)
        self.require_root()
        wantfold = username.casefold()
        with self._lock:
            users = self._read(self._users_path())
            if username in users:
                rec = users[username]
                if rec.get("preprovisioned") and not rec.get("hash"):
                    return {"username": username,
                            "preprovisioned": True, "exists": True}
                raise UserError(409, "username is taken")
            for existing in users:
                if existing.casefold() == wantfold:
                    raise UserError(409, "username is taken")
            home_dir = None
            if home:
                home = home.strip()
                if ("/" in home or "\\" in home or home in RESERVED_NAMES
                        or home.startswith(".")):
                    raise UserError(400, "invalid home folder")
                home_dir = os.path.join(self.root, home)
                if not os.path.isdir(home_dir):
                    raise UserError(
                        404, "home folder does not exist: " + home)
                marker = self._read_marker(home_dir)
                if marker is not None and marker.casefold() != wantfold:
                    raise UserError(409, "folder is claimed by another user")
                self._write_marker(home_dir, username)
            else:
                for d in self.user_homes():
                    if d.casefold() == wantfold and d != username:
                        raise UserError(409, "username is taken")
            rec = {"preprovisioned": True, "created": time.time()}
            if home:
                rec["home"] = home
            users[username] = rec
            self._write(self._users_path(), users)
            return {"username": username, "preprovisioned": True,
                    "home": home or username}

    def set_password(self, username, password, verify=""):
        """Dev action: set (or reset) a password. Clears the preprovisioned
        flag and revokes all sessions (password change logs out everywhere)."""
        username = (username or "").strip()
        password = password or ""
        if len(password) < MIN_PASSWORD_LEN:
            raise UserError(
                400, "password too short (min %d)" % MIN_PASSWORD_LEN)
        if verify and password != verify:
            raise UserError(400, "passwords do not match")
        self.require_root()
        with self._lock:
            users = self._read(self._users_path())
            sessions = self._read(self._sessions_path())
            if username not in users:
                raise UserError(404, "no such user")
            rec = users[username]
            rec.update(hash_password(password))
            rec.pop("preprovisioned", None)
            users[username] = rec
            for tok in [t for t, s in sessions.items()
                        if isinstance(s, dict)
                        and s.get("username") == username]:
                del sessions[tok]
            self._write(self._users_path(), users)
            self._write(self._sessions_path(), sessions)
            return {"username": username}

    def delete_user(self, username):
        """Dev action: remove the account row + sessions. The home FOLDER
        (and its claim marker) is NEVER touched — data is never deleted by
        account operations. Re-registering the name 409s until provisioned
        again (or the marker is removed by hand)."""
        username = (username or "").strip()
        self.require_root()
        with self._lock:
            users = self._read(self._users_path())
            sessions = self._read(self._sessions_path())
            if username not in users:
                raise UserError(404, "no such user")
            del users[username]
            for tok in [t for t, s in sessions.items()
                        if isinstance(s, dict)
                        and s.get("username") == username]:
                del sessions[tok]
            self._write(self._users_path(), users)
            self._write(self._sessions_path(), sessions)
            return {"username": username, "deleted": True}

    def register(self, username, password, verify,
                 device_id="", device_name=""):
        username = (username or "").strip()
        password = password or ""
        verify = verify or ""
        ok, reason = valid_username(username)
        if not ok:
            raise UserError(400, reason)
        if password != verify:
            raise UserError(400, "passwords do not match")
        if len(password) < MIN_PASSWORD_LEN:
            raise UserError(
                400, "password too short (min %d)" % MIN_PASSWORD_LEN)
        self.require_root()
        home = self.user_home(username)
        wantfold = username.casefold()
        with self._lock:
            users = self._read(self._users_path())
            sessions = self._read(self._sessions_path())
            if username in users:
                # Passwordless preprovisioned row? This IS the owner
                # claiming it: set their password, no 409.
                rec = users[username]
                if rec.get("preprovisioned") and not rec.get("hash"):
                    if password != verify:
                        raise UserError(400, "passwords do not match")
                    if len(password) < MIN_PASSWORD_LEN:
                        raise UserError(
                            400, "password too short (min %d)"
                            % MIN_PASSWORD_LEN)
                    rec.update(hash_password(password))
                    rec.pop("preprovisioned", None)
                    home = self.home_for(username, users)
                    os.makedirs(
                        self.user_playlists_dir(username), exist_ok=True)
                    self._write_marker(home, username)
                    users[username] = rec
                    token = self._mint_locked(
                        sessions, username, device_id, device_name)
                    self._write(self._users_path(), users)
                    self._write(self._sessions_path(), sessions)
                    return {"username": username, "token": token,
                            "adopted": True}
                raise UserError(409, "username is taken")
            # Case-insensitive reservation: no sibling account or home dir
            # may differ only by case (bob vs Bob), or one login could
            # shadow another on case-insensitive clients.
            for existing in users:
                if existing.casefold() == wantfold:
                    raise UserError(409, "username is taken")
            for d in self.user_homes():
                if d.casefold() == wantfold and d != username:
                    raise UserError(409, "username is taken")
            folder_exists = os.path.isdir(home)
            if folder_exists:
                # Claimed before? Taken — unless this exact name is
                # re-claiming its own marker with no account row left
                # (recovery after manual cleanup). Unmarked folders are
                # NAS-managed trees being claimed for the first time.
                marker = self._read_marker(home)
                if marker is not None and marker.casefold() != wantfold:
                    raise UserError(409, "username is taken")
            os.makedirs(self.user_playlists_dir(username), exist_ok=True)
            self._write_marker(home, username)
            rec = hash_password(password)
            rec["created"] = time.time()
            users[username] = rec
            token = self._mint_locked(
                sessions, username, device_id, device_name)
            self._write(self._users_path(), users)
            self._write(self._sessions_path(), sessions)
            return {"username": username, "token": token,
                    "adopted": bool(folder_exists)}

    def login(self, username, password, device_id="", device_name=""):
        username = (username or "").strip()
        password = password or ""
        if not username or not password:
            raise UserError(400, "missing username or password")
        self.require_root()
        with self._lock:
            users = self._read(self._users_path())
            sessions = self._read(self._sessions_path())
            rec = users.get(username)
            if rec is None or not verify_password(password, rec):
                raise UserError(401, "invalid username or password")
            token = self._mint_locked(
                sessions, username, device_id, device_name)
            self._write(self._sessions_path(), sessions)
            return {"username": username, "token": token}

    def logout(self, token):
        if not token:
            return False
        with self._lock:
            sessions = self._read(self._sessions_path())
            if token in sessions:
                del sessions[token]
                self._write(self._sessions_path(), sessions)
                return True
            return False

    def change_password(self, username, current, new, keep_token=""):
        """User action (needs the CURRENT password): set a new one. Other
        sessions are revoked; the calling session (keep_token) survives so
        the app stays logged in."""
        username = (username or "").strip()
        if len(new or "") < MIN_PASSWORD_LEN:
            raise UserError(
                400, "password too short (min %d)" % MIN_PASSWORD_LEN)
        self.require_root()
        with self._lock:
            users = self._read(self._users_path())
            sessions = self._read(self._sessions_path())
            rec = users.get(username)
            if rec is None or not verify_password(current or "", rec):
                raise UserError(401, "current password is wrong")
            rec.update(hash_password(new))
            rec.pop("preprovisioned", None)
            users[username] = rec
            for tok in [t for t, s in sessions.items()
                        if isinstance(s, dict)
                        and s.get("username") == username
                        and t != keep_token]:
                del sessions[tok]
            self._write(self._users_path(), users)
            self._write(self._sessions_path(), sessions)
            return {"username": username, "changed": True}

    def whoami(self, token):
        """Username for a session token, or None. Throttled last_seen touch."""
        if not token:
            return None
        now = time.time()
        with self._lock:
            sessions = self._read(self._sessions_path())
            s = sessions.get(token)
            if not isinstance(s, dict) or not s.get("username"):
                return None
            if now - float(s.get("last_seen") or 0) > LAST_SEEN_TTL:
                s["last_seen"] = now
                self._write(self._sessions_path(), sessions)
            return s["username"]

    # -- internals -----------------------------------------------------------
    @staticmethod
    def _mint_locked(sessions, username, device_id, device_name):
        token = secrets.token_urlsafe(TOKEN_BYTES)
        while token in sessions:
            token = secrets.token_urlsafe(TOKEN_BYTES)
        now = time.time()
        sessions[token] = {
            "username": username,
            "device_id": device_id or "",
            "device_name": device_name or "",
            "created": now,
            "last_seen": now,
        }
        return token


def _cli():
    """Dev user management over SSH (NEVER exposed via HTTP — the app has
    no admin surface by design):
      docker exec nasmusic python -m nasmusic.users list
      docker exec nasmusic python -m nasmusic.users provision <name> [home]
      docker exec nasmusic python -m nasmusic.users set-password <name>
      docker exec nasmusic python -m nasmusic.users delete <name>
    Root defaults to $NASMUSIC_USERS_DIR (/data/users in-container)."""
    import getpass
    import sys
    argv = sys.argv[1:]
    root = os.environ.get("NASMUSIC_USERS_DIR", "/data/users")
    store = UserStore(root)
    try:
        cmd = argv[0] if argv else "list"
        if cmd == "list":
            store.require_root()
            with store._lock:
                users = store._read(store._users_path())
            for name in sorted(users):
                rec = users[name]
                kind = "preprovisioned (no password)" \
                    if rec.get("preprovisioned") and not rec.get("hash") \
                    else "active"
                print("%s [%s] home=%s" % (
                    name, kind,
                    store.home_for(name, users)
                    .replace(store.root + "/", "")))
            if not users:
                print("(no users)")
        elif cmd == "provision" and len(argv) >= 2:
            print(store.preprovision(
                argv[1], argv[2] if len(argv) > 2 else None))
        elif cmd == "set-password" and len(argv) >= 2:
            pw = getpass.getpass("new password: ")
            print(store.set_password(argv[1], pw, pw))
        elif cmd == "delete" and len(argv) >= 2:
            sure = input("delete account '%s' (home folder kept)? [y/N] "
                         % argv[1]).strip().lower()
            if sure == "y":
                print(store.delete_user(argv[1]))
            else:
                print("aborted")
        else:
            print(_cli.__doc__)
            return 2
    except UserError as e:
        print("error %d: %s" % (e.status, e.msg))
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(_cli())
