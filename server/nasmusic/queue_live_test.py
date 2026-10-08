"""Live infinite-queue integration test — REAL code, REAL data, NO mocks.

Exercises the exact server pipeline an autoplay refill uses, per seed:
  recommend() -> resolve (search_ytmusic + pick + resolve_url)
  -> title check (resolved title must evidence-match the request)
  -> stream probe (plain-GET fetch of first bytes, like MediaPlayer)
then chains a second round with excludes (refill behavior).

Run INSIDE the nasmusic container (needs library index, Deezer, yt-dlp):
  docker exec -i nasmusic python3 < nasmusic/queue_live_test.py
Exit 0 only if every check passes.
"""
import sys
import urllib.request

sys.path.insert(0, "/app")

from nasmusic.scorer import Scorer, norm  # noqa: E402

SEEDS = [
    ("Extremoduro", "Puta"),
    ("Marea", "El temblor"),
    ("Marea", "Que se joda el viento"),
    ("Platero y tú", "Cigarrito"),
    ("Celtas Cortos", "20 de abril"),
    ("La Fuga", "Heroína"),
    ("La Fuga", "P'aquí p'allá"),
    ("Joaquín Sabina", "Pacto Entre Caballeros"),
]

ROWS_PER_SEED = 3
PROBE_BYTES = 131072


def title_ok(want_artist, want_title, got_title):
    """Same bar as the resolve gate: exact or containment either way."""
    w = norm(want_title)
    g = norm(got_title or "")
    return bool(w) and (w == g or w in g or g in w)


def probe_stream(url):
    """Plain GET (MediaPlayer shape), first bytes must be real audio."""
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=45) as r:
        if r.status not in (200, 206):
            return False, f"status {r.status}"
        ct = r.headers.get("Content-Type", "")
        if "audio" not in ct and "video" not in ct and "octet" not in ct:
            return False, f"content-type {ct}"
        body = r.read(PROBE_BYTES)
        if len(body) < 65536:
            return False, f"only {len(body)} bytes"
        return True, f"{r.status} {ct} {len(body)}B"


def main():
    s = Scorer()
    passes, fails = 0, []
    seen = set()

    def check(name, cond, detail=""):
        nonlocal passes
        if cond:
            passes += 1
            print(f"  PASS {name} {detail}")
        else:
            fails.append(name)
            print(f"  FAIL {name} {detail}")

    for rnd, (artist, title) in enumerate(SEEDS):
        print(f"== seed {artist} - {title}")
        try:
            rows = s.deezer_recommendations(
                artist, title, limit=15, exclude=list(seen))
        except Exception as e:
            check(f"recommend {artist}-{title}", False, repr(e)[:100])
            continue
        check(f"recommend non-empty {artist}-{title}", len(rows) > 0,
              f"({len(rows)} rows)")
        for r in rows[:ROWS_PER_SEED]:
            ra, rt = r.get("artist") or "", r.get("title") or ""
            tag = f"{ra} - {rt}"
            seen.add(f"{ra} - {rt}")
            try:
                cands = s.search_ytmusic(f"{ra} {rt}")
                scored, _ = s.pick(cands, [ra], rt)
            except Exception as e:
                check(f"resolve {tag}", False, repr(e)[:100])
                continue
            if not scored:
                check(f"resolve {tag}", False, "no pick (gate)")
                continue
            top = None
            for cand in scored[:5]:
                if title_ok(ra, rt, cand.get("title")):
                    top = cand
                    break
            if top is None:
                check(f"resolve {tag}", False, "no evidenced pick")
                continue
            vid = top["video_id"]
            ok_t = True  # evidence already required above
            check(f"title-match {tag}", ok_t,
                  f"got '{top.get('title')}' {vid}")
            # Mirror the worker: top pick sometimes unresolvable
            # (age-restricted) while #2 streams — walk top 5 in order.
            url, uv = None, None
            for cand in scored[:5]:
                if not title_ok(ra, rt, cand.get("title")):
                    continue
                try:
                    u = s.resolve_url(cand["video_id"], timeout=90)
                except Exception:
                    u = None
                if u:
                    url, uv = u, cand["video_id"]
                    break
            if not url:
                check(f"resolve-url {tag}", False, "all evidenced picks dead")
                continue
            check(f"resolve-url {tag}", True, f"winner={uv}")
            # Retry once on transient HTTP errors (mirrors the relay).
            ok, detail = False, ""
            for _ in range(2):
                try:
                    ok, detail = probe_stream(url)
                    break
                except Exception as e:
                    detail = repr(e)[:100]
            check(f"stream {tag}", ok, detail)

    print(f"\nRESULT: {passes} passed, {len(fails)} failed")
    for f in fails:
        print("  FAILED:", f)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
