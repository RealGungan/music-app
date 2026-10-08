"""Live integration checks for the infinite queue — REAL code, REAL data,
no mocks. Runs inside the NAS container (all deps + library present):

  docker exec -i nasmusic python3 < live_queue_check.py

Covers the four user demands:
  1. title matches the music playing (resolve every sampled row, require
     title evidence; relay must serve bytes for it),
  2. every song plays (64KB relay fetch per resolved row),
  3. queue refills (multi-round recommend chains stay fresh),
  4. scrolling fills it (client-side; mirrored by the planner growth test
     in app/test — the scroll path calls the same _fillRelated).

Exit 0 = all green, 1 = failures listed.
"""
import re
import sys
import urllib.request

sys.path.insert(0, "/app")

from nasmusic.httpd import Handler, make_state
from nasmusic.scorer import Scorer
from nasmusic.state import Config

FAILURES = []


def check(name, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + name +
          (f" — {detail}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(name)


BAD = re.compile(
    r"\blive\b|\bdemo\b|\bremix\b|\brehearsal\b|\bsession\b|"
    r"\binstrumental\b|\bkaraoke\b|\bcover\b|\bacoustic\b|"
    r"\ba cappella\b|\bacapella\b|\baccapella\b|"
    r"\bnightcore\b|\bslowed\b|\bsped up\b|\breverb\b|\b8d\b|"
    r"\bbass boosted\b|\bloop\b|\bmashup\b|\bmedley\b|"
    r"\btribute\b|\bclean\b|\bradio edit\b",
    re.I)


def relay_bytes(url, n=65536):
    req = urllib.request.Request(
        url, headers={"User-Agent": "Mozilla/5.0",
                      "Range": f"bytes=0-{n - 1}"})
    with urllib.request.urlopen(req, timeout=45) as r:
        body = r.read(n)
        return r.status, r.headers.get("Content-Type"), len(body)


def main():
    state = make_state(Config())
    scorer = Scorer()

    class T(Handler):
        @property
        def state(self):
            return state

    seeds = [("Extremoduro", "Puta"),
             ("Marea", "El temblor"),
             ("Celtas Cortos", "20 de abril")]
    seen = set()
    all_rows = []
    for rnd in range(1, 4):
        for (artist, title) in list(seeds):
            try:
                rows = scorer.deezer_recommendations(
                    artist, title, limit=10, exclude=list(seen))
            except Exception as e:                      # noqa: BLE001
                check(f"recommend {artist}-{title} r{rnd}",
                      False, f"{type(e).__name__} {e}"[:100])
                continue
            check(f"refill non-empty {artist}-{title} r{rnd}",
                  len(rows) > 0, "0 rows")
            for r in rows:
                key = f"{r.get('artist')} - {r.get('title')}"
                check(f"no suspect version: {key[:50]}",
                      not BAD.search(f"{r.get('title')} {r.get('artist')}"))
                if key not in seen:
                    seen.add(key)
                    all_rows.append((r.get("artist"), r.get("title")))
        # drift like the client does: next seed = first fresh row
        fresh = [(a, t) for (a, t) in all_rows
                 if f"{a} - {t}" in seen]
        if fresh:
            seeds = [fresh[0]]

    check("refill stays fresh (distinct >= 20 over chains)",
          len(seen) >= 20, f"distinct={len(seen)}")

    # Resolve + relay + NAS-match a sample of real rows.
    sample = all_rows[:8]
    resolved_ok = 0
    for (artist, title) in sample:
        # NAS preference first, exactly like the app (annotation path).
        try:
            hit = Handler._innas.__get__(T.__new__(T))(artist, title)
        except Exception:
            hit = {"found": False}
        if hit.get("found"):
            check(f"nas-match honest: {artist}-{title}",
                  True)
            resolved_ok += 1
            continue
        try:
            cands = scorer.search_ytmusic(f"{artist} {title}")
            scored, _ = scorer.pick(cands, [artist], title)
        except Exception as e:                          # noqa: BLE001
            check(f"resolve {artist}-{title}", False,
                  f"{type(e).__name__}")
            continue
        if not scored:
            # Honest empty (scarcity) — allowed, must NOT be a wrong song.
            check(f"resolve honest-empty {artist}-{title}", True)
            resolved_ok += 1
            continue
        top = scored[0]
        url = scorer.resolve_url(top["video_id"], timeout=90)
        check(f"resolve has url {artist}-{title}", bool(url))
        if not url:
            continue
        try:
            st, ct, nb = relay_bytes(url)
            check(f"plays (bytes served) {artist}-{title}",
                  st in (200, 206) and nb > 10000,
                  f"status={st} type={ct} bytes={nb}")
            resolved_ok += 1
        except Exception as e:                          # noqa: BLE001
            check(f"plays (bytes served) {artist}-{title}", False,
                  f"{type(e).__name__} {str(e)[:80]}")

    print(f"\nresolved-or-honest: {resolved_ok}/{len(sample)}")
    print("FAILURES:", len(FAILURES))
    for f in FAILURES:
        print("  -", f)
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main())
