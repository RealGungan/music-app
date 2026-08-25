"""Lifecycle rules: 7-day staging expiry + playlist promotion.

A staged file is deleted once it is older than expiry_days AND its
filename appears in no playlist m3u. Adding a file to any managed
playlist promotes it out of _Staging into that playlist's folder.
"""

import os
import shutil
import time


def promote_if_referenced(state, base_name):
    """If <base_name>.mp3 sits in a playlist, move it next to that m3u."""
    filename = f"{base_name}.mp3"
    src = os.path.join(state.staging_dir, filename)
    if not os.path.exists(src):
        return None
    for folder, m3u in state.playlist_paths():
        try:
            with open(m3u, encoding="utf-8", errors="replace") as fh:
                entries = [ln.strip() for ln in fh
                           if ln.strip() and not ln.strip().startswith("#")]
        except OSError:
            continue
        if any(os.path.basename(e) == filename for e in entries):
            dest_dir = state.promote_dest(folder)
            dest = os.path.join(dest_dir, filename)
            shutil.move(src, dest)
            row = state.db.find_download_by_base(base_name)
            if row:
                state.db.update_download(
                    row["id"], status="kept", path=dest,
                    promoted_at=time.time())
                state.db.event("promoted",
                               {"id": row["id"], "base": base_name,
                                "to": dest})
            return dest
    return None


def append_entry(state, playlist, abs_path):
    """Append an absolute path to <playlist>.m3u if not already there."""
    m3u = state.m3u_for(playlist)
    existing = []
    if os.path.exists(m3u):
        with open(m3u, encoding="utf-8", errors="replace") as fh:
            existing = [ln.strip() for ln in fh
                        if ln.strip() and not ln.strip().startswith("#")]
    fname = os.path.basename(abs_path)
    if fname not in (os.path.basename(e) for e in existing):
        with open(m3u, "a", encoding="utf-8") as fh:
            fh.write(os.path.abspath(abs_path) + "\n")
        return True
    return False


def keep_staged(state, row):
    """Move a staged file to its keep_to destination and record the m3u."""
    playlist = row.get("keep_to")
    src = os.path.join(state.staging_dir, f"{row['base_name']}.mp3")
    dest_dir = state.promote_dest(playlist)
    dest = os.path.join(dest_dir, f"{row['base_name']}.mp3")
    if os.path.exists(src) and not os.path.exists(dest):
        shutil.move(src, dest)
    append_entry(state, playlist, dest)
    state.db.update_download(row["id"], status="kept", path=dest,
                             promoted_at=time.time())
    state.db.event("promoted", {"id": row["id"], "base": row["base_name"],
                                "to": dest})
    return dest


def run_expiry(state):
    """Delete expired, unreferenced staging files. Returns removed list."""
    cutoff = time.time() - state.expiry_days * 86400
    referenced = state.all_playlist_entries()
    removed = []
    try:
        names = os.listdir(state.staging_dir)
    except OSError:
        return removed
    for name in names:
        if not name.endswith(".mp3"):
            continue
        path = os.path.join(state.staging_dir, name)
        try:
            age = os.path.getmtime(path)
        except OSError:
            continue
        if age > cutoff or name in referenced:
            continue
        os.remove(path)
        removed.append(name)
        row = state.db.find_download_by_base(name[:-4])
        if row and row["status"] in ("staged", "pending"):
            state.db.update_download(row["id"], status="expired")
        state.db.event("expired", {"file": name})
    return removed
