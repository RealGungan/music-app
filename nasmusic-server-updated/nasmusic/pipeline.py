"""Stage / redownload orchestration in background threads.

Every attempt and its alternatives are persisted so the app can offer
ranked redownloads, mirroring the search-correctness flow.
"""

import logging
import os
import threading
import time

from .scorer import ffprobe_duration

logger = logging.getLogger(__name__)


def split_base(base_name):
    """'Artist1, Artist2 - Title' -> ([artists], title)."""
    artist_part, title = base_name.split(" - ", 1)
    return [a.strip() for a in artist_part.split(",")], title


class Pipeline:
    def __init__(self, state):
        self.state = state
        self.db = state.db
        self.scorer = state.scorer
        self._jobs = {}           # download_id -> dict(phase, error)
        self._jobs_lock = threading.Lock()
        self._threads = []

    def _target_path(self, base_name):
        # Containment (2026-09-18, public URL): base_name reaches the
        # filesystem via yt-dlp -o templates, so never let it escape the
        # staging dir even if a caller forgets to validate.
        staging = os.path.normpath(self.state.config.staging_dir)
        target = os.path.normpath(os.path.join(staging, f"{base_name}.mp3"))
        if target != staging and not target.startswith(staging + os.sep):
            raise ValueError("bad base_name")
        return target

    # ------------------------------------------------------------ status
    def job_status(self, did):
        row = self.db.get_download(did)
        if not row:
            return None
        with self._jobs_lock:
            live = self._jobs.get(did, {})
        return {
            "id": did,
            "base_name": row["base_name"],
            "status": live.get("phase", row["status"]),
            "error": live.get("error"),
            "path": row["path"],
        }

    def all_jobs(self, owner=None):
        return [self.job_status(d["id"])
                for d in self.db.list_downloads(owner=owner)]

    # ------------------------------------------------------------ api
    def start_stage(self, artist, title, force=False, owner=""):
        # Validate before spawning (public URL — artist/title are
        # attacker-controlled; 2026-09-18). ValueError -> HTTP 400.
        for what, v in (("artist", artist or ""), ("title", title or "")):
            v = (v or "").strip()
            if what == "title" and not v:
                raise ValueError("missing title")
            if ("/" in v or "\\" in v or "\x00" in v or "\n" in v
                    or "\r" in v or len(v) > 120 or v in (".", "..")):
                raise ValueError("bad %s" % what)
        base = f"{artist} - {title}"
        existing = self.db.find_download_by_base(base)
        target = self._target_path(base)
        if os.path.exists(target) and not force:
            return (existing["id"] if existing else None), {"skipped": True}

        did = ((existing or {}).get("id")
               or self.db.create_download(artist, title, owner))
        if existing and not (existing.get("owner") or "") and owner:
            # Adopt unattributed legacy rows for their stager.
            self.db.update_download(did, owner=owner)
        self.db.update_download(did, status="pending")
        self._spawn(did, self._do_stage, did)
        return did, {}

    def start_redownload(self, did, video_id):
        row = self.db.get_download(did)
        if not row:
            return None, {"error": "unknown download"}
        self._spawn(did, self._do_candidate, did, video_id)
        return did, {}

    def retry(self, did):
        self.db.update_download(did, status="pending", keep_to=None)
        self._spawn(did, self._do_stage, did)
        return did

    def _do_stage(self, did):
        self._run_stage(did)

    def _do_candidate(self, did, video_id):
        self._run_download_candidate(did, video_id)

    def _spawn(self, did, fn, *args):
        with self._jobs_lock:
            self._jobs[did] = {"phase": "queued", "error": None}
        t = threading.Thread(target=self._guard,
                             args=(did, fn) + args, daemon=True)
        self._threads.append(t)
        t.start()

    def _guard(self, did, fn, *args):
        try:
            fn(*args)
        except Exception as e:                        # noqa: BLE001
            logger.exception("stage failed")
            if did:
                self._set_phase(did, "failed", error=str(e)[:200])

    # ----------------------------------------------------------- internals
    def _set_phase(self, did, phase, error=None):
        with self._jobs_lock:
            self._jobs[did] = {"phase": phase, "error": error}
        self.db.update_download(did, status=phase)

    def _run_stage(self, did):
        row = self.db.get_download(did)
        if not row:
            return
        artists, title = split_base(row["base_name"])
        self._set_phase(did, "searching")

        cands = self.scorer.search(artists[0], title)
        if not cands:
            self._set_phase(did, "no_results",
                            error="youtube returned nothing")
            return
        self.db.record_candidates(did, cands[:15])

        scored, consensus = self.scorer.pick(cands, artists, title)
        self.db.record_candidates(did, scored)
        if not scored:
            self._set_phase(did, "no_official",
                            error="no trusted candidate survived filters")
            return

        expected = self.scorer.deezer_duration(
            row["base_name"], artists[0], title)
        ref = expected or consensus

        self._download_until_match(did, row["base_name"], scored, ref)

    def _download_until_match(self, did, base_name, scored, ref):
        target = self._target_path(base_name)
        for cand in scored[:6]:
            vid, dur = cand["video_id"], cand["duration_s"]
            if ref and dur and abs(dur - ref) > 5:
                continue
            self._set_phase(did, "downloading")
            self.scorer.download(vid, target)
            if os.path.exists(target):
                got = ffprobe_duration(target)
                if ref and got and abs(got - ref) > 6:
                    logger.info("%s: duration off (%.0fs vs %ss)",
                                base_name, got, ref)
                    os.remove(target)
                    continue
                self.db.update_download(
                    did, status="staged", path=target, video_id=vid,
                    url=f"https://www.youtube.com/watch?v={vid}",
                    channel=cand["channel"], duration_s=cand["duration_s"],
                    score=cand["score"], downloaded_at=time.time())
                self.db.event("staged", {"id": did, "base": base_name,
                                         "video_id": vid})
                self._set_phase(did, "staged")
                self._maybe_autokeep(did)
                return True
            self._set_phase(did, "retrying")
        self._set_phase(did, "giveup", error="no candidate verified")
        return False

    def _run_download_candidate(self, did, video_id):
        row = self.db.get_download(did)
        if not row:
            return
        base = row["base_name"]
        artists, title = split_base(base)

        cands = self.db.candidates_for(did)
        meta = next((c for c in cands if c["video_id"] == video_id), None)
        expected = self.scorer.deezer_duration(base, artists[0], title)

        target = row.get("path")
        if not target or not os.path.exists(target):
            target = self._target_path(base)
        was_kept = row["status"] == "kept"

        if os.path.exists(target):
            os.remove(target)
        self._set_phase(did, "downloading")
        self.scorer.download(video_id, target)
        if not os.path.exists(target):
            self._set_phase(did, "failed",
                            error="download produced no file")
            return
        got = ffprobe_duration(target)
        self.db.update_download(
            did, status="kept" if was_kept else "staged", path=target,
            video_id=video_id,
            url=f"https://www.youtube.com/watch?v={video_id}",
            channel=(meta or {}).get("channel"),
            duration_s=int(got) if got else None,
            score=(meta or {}).get("score"))
        self.db.event("redownloaded", {"id": did, "video_id": video_id})
        self._set_phase(did, "kept" if was_kept else "staged")
        self._maybe_autokeep(did)

    def _maybe_autokeep(self, did):
        from .lifecycle import keep_staged
        row = self.db.get_download(did)
        if row and row.get("keep_to"):
            try:
                keep_staged(self.state, row)
                self.db.update_download(did, keep_to=None)
                self._set_phase(did, "kept")
            except Exception:                         # noqa: BLE001
                logger.exception("auto-keep failed")
