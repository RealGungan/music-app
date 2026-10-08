#!/usr/bin/env bash
# Container startup for the NASMusic server.
# Runs once inside the container. Depends on the server code being mounted at
# /app (the repo's server/ folder). Honours the NASMUSIC_* env vars set by
# docker-compose; falls back to sane container-internal defaults.
set -u

export DEBIAN_FRONTEND=noninteractive

# Deps (ffmpeg/curl/fpcalc + python packages) live in the container's writable
# layer, which is wiped on every recreate — so every fresh boot needs internet.
# Check first and ONLY install when something is actually missing: a plain
# restart (or a transient network hiccup) then never re-runs apt/pip and never
# loops. Errors are logged to stderr (visible in the container log) instead of
# being swallowed, so the first-boot failure is diagnosable.
NEED=0
command -v ffmpeg >/dev/null 2>&1 || NEED=1
command -v curl  >/dev/null 2>&1 || NEED=1
command -v fpcalc >/dev/null 2>&1 || NEED=1
python - <<'PY' 2>/dev/null || NEED=1
try:
    import ytmusicapi, yt_dlp, mutagen  # noqa: F401
except Exception:
    raise SystemExit(1)
PY

if [ "$NEED" = "1" ]; then
  echo "==> Some python/system deps missing -> installing (first boot / fresh container only)..."
  if ! apt-get update -qq; then
    echo "ERROR: apt-get update FAILED inside the container. Diagnosing..." >&2
    getent hosts deb.debian.org || echo "  -> DNS lookup for deb.debian.org FAILED (check NAS DNS)" >&2
    command -v curl >/dev/null 2>&1 && curl -fsSI --max-time 8 https://deb.debian.org/ >/dev/null 2>&1 \
      && echo "  -> HTTPS to deb.debian.org: OK (so DNS works; apt sources/lock issue)" >&2 \
      || echo "  -> Cannot reach deb.debian.org over HTTPS (routing/firewall?)" >&2
    cat /etc/os-release 2>/dev/null | head -2 >&2
    echo "ERROR: A fresh container cannot install ffmpeg/python deps while apt-get fails," >&2
    echo "ERROR: so the server cannot start. Fix the above, then restart the container." >&2
    exit 1
  fi
  apt-get install -y -qq --no-install-recommends --no-install-suggests \
      ffmpeg curl 1>/dev/null 2>&1 \
    || { echo "ERROR: apt-get install ffmpeg curl FAILED." >&2; exit 1; }
  # fpcalc (Chromaprint) enables AcoustID audio fingerprinting. Install is
  # best-effort: the server still runs if it isn't available.
  if ! command -v fpcalc >/dev/null 2>&1; then
    apt-get install -y -qq --no-install-recommends libchromaprint-tools 1>/dev/null 2>&1 || \
      echo "WARN: fpcalc (libchromaprint-tools) install failed — fingerprinting unavailable" >&2
  fi
  if ! pip install --no-cache-dir -q ytmusicapi yt-dlp mutagen; then
    echo "ERROR: pip install of python deps FAILED." >&2
    exit 1
  fi
else
  echo "==> Deps already present — skipping install (booting straight to server)."
fi

# Locate the nasmusic package (it may sit at /app or /app/server).
if [ -d /app/nasmusic ]; then
  SRC=/app
elif [ -d /app/server/nasmusic ]; then
  SRC=/app/server
else
  echo "ERROR: nasmusic package not found under /app — check the music-app mount." >&2
  exit 1
fi
echo "==> NASMusic source found at $SRC. Starting server on :6680..."

exec env PYTHONPATH="$SRC" python -m nasmusic --host 0.0.0.0 --port 6680