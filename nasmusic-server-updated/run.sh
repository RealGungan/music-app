#!/usr/bin/env bash
# Container startup for the NASMusic server.
# Runs once inside the container. Depends on the server code being mounted at
# /app (the repo's server/ folder). Honours the NASMUSIC_* env vars set by
# docker-compose; falls back to sane container-internal defaults.
set -e

export DEBIAN_FRONTEND=noninteractive

echo "==> Installing system + python deps (first boot only)..."
apt-get update -qq 2>/dev/null
apt-get install -y -qq --no-install-recommends --no-install-suggests ffmpeg curl 1>/dev/null 2>&1
pip install --no-cache-dir -q ytmusicapi yt-dlp mutagen

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
