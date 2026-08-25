"""Stage / redownload orchestration.

Runs yt-dlp downloads in background threads; every attempt and its
alternatives are persisted so the app can offer ranked redownloads.
"""

import logging
import os
import threading

from .scorer import Scorer, ffprobe_duration

logger = logging.getLogger(__name__)


def split_base(base_name):
    """'Artist1, Artist2 - Title' -> ([artists], title)."""
    artist_part, title = base_name.split(" - ", 1)
    return [a.strip() for a in artist_part.split(",")], title


class Pipeline:
    def __init__(self, state):
        self.state = state
        self.db = state.db
        self.scorer = Scorer(
            yt_dlp_bin=state.yt_dlp_bin,
            node_runtime=state.node_runtime,
            log_fn=lambda m: logger.info(m),
        )
        self._jobs = {}          # download_id -> dict(status, error)
        self._jobs_lock = threading.Lock()
        self._threads = []

    # ------------------------------------------------------------- helpers
    def _target_path(self, base_name):
        return os.path.join(self.state.staging_dir, f"{base_name}.mp3")

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

    def all_jobs(self):
        return [self.job_status(d["id"]) for d in self.db.list_downloads()]

    # ---------------------------------------------------------------- api
    def start_stage(self, artist, title, force=False):
        base = f"{artist} - {title}"
        existing = self.db.find_download_by_base(base)
        target = self._target_path(base)
        if os.path.exists(target) and not force:
            return existing["id"] if existing else None, {"skipped": True}

        did = (existing or {}).get("id") or self.db.create_download(artist, title)
        self.db.update_download(did, status="pending")
        t = threading.Thread(target=self._run_stage, args=(did,),
                             daemon=True)
        with self._jobs_lock:
            self._jobs[did] = {"phase": "queued"}
        self._threads.append(t)
        t.start()
        return did, {}

    def start_redownload(self, did, video_id):
        row = self.db.get_download(did)
        if not row:
            return None, {"error": "unknown download"}
        t = threading.Thread(
            target=self._run_download_candidate,
            args=(did, video_id), daemon=True)
        with self._jobs_lock:
            self._jobs[did] = {"phase": "queued"}
        self._threads.append(t)
        t.start()
        return did, {}

    # -------------------------------------------------------------- internals
    def _set_phase(self, did, phase, error=None):
        with self._jobs_lock:
            self._jobs[did] = {"phase": phase, "error": error}
        self.db.update_download(did, status=phase)

    def _run_stage(self, did):
        try:
            row = self.db.get_download(did)
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
        except Exception as e:                       # noqa: BLE001
            logger.exception("stage failed")
            self._set_phase(did, "failed", error=str(e)[:200])

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
                import time as _t
                self.db.update_download(
                    did, status="staged", path=target, video_id=vid,
                    url=f"https://www.youtube.com/watch?v={vid}",
                    channel=cand["channel"], duration_s=cand["duration_s"],
                    score=cand["score"], downloaded_at=_t.time())
                self.db.event("staged", {"id": did, "base": base_name,
                                         "video_id": vid})
                self._set_phase(did, "staged")
                self._maybe_autokeep(did)
                return True
            self._set_phase(did, "retrying")
        self._set_phase(did, "giveup", error="no candidate verified")
        return False

    def _run_download_candidate(self, did, video_id):
        """Redownload: replace file with a specific alternative, in place."""
        try:
            row = self.db.get_download(did)
            base = row["base_name"]
            artists, title = split_base(base)

            cands = self.db.candidates_for(did)
            meta = next((c for c in cands if c["video_id"] == video_id),
                        None)
            expected = self.scorer.deezer_duration(base, artists[0], title)

            # replace wherever the file currently lives (staged OR kept)
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
            if expected and got and abs(got - expected) > 10:
                logger.warning("redownload duration %.0f vs expected %s",
                               got, expected)
            self.db.update_download(
                did, status="kept" if was_kept else "staged", path=target,
                video_id=video_id,
                url=f"https://www.youtube.com/watch?v={video_id}",
                channel=(meta or {}).get("channel"),
                duration_s=int(got) if got else None,
                score=(meta or {}).get("score"))
            self.db.event("redownloaded",
                          {"id": did, "video_id": video_id})
            self._set_phase(did, "kept" if was_kept else "staged")
            self._maybe_autokeep(did)
        except Exception as e:                       # noqa: BLE001
            logger.exception("redownload failed")
            self._set_phase(did, "failed", error=str(e)[:200])

    def _maybe_autokeep(self, did):
        """If a playlist was requested while downloading, keep it now."""
        from .lifecycle import keep_staged
        row = self.db.get_download(did)
        if row and row.get("keep_to"):
            try:
                keep_staged(self.state, row)
                self.db.update_download(did, keep_to=None)
                self._set_phase(did, "kept")
            except Exception:                        # noqa: BLE001
                logger.exception("auto-keep failed")

    def retry(self, did):
        """Re-run the full stage pipeline for a dead download."""
        self.db.update_download(did, status="pending", keep_to=None)
        t = threading.Thread(target=self._run_stage, args=(did,),
                             daemon=True)
        with self._jobs_lock:
            self._jobs[did] = {"phase": "queued"}
        self._threads.append(t)
        t.start()
        return did
