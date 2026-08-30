#!/usr/bin/env bash
# Run the NASMusic server locally (outside Docker) with test paths.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# Create a tiny test library + staging zone in /tmp if they don't exist.
TEST_LIB="${NASMUSIC_MUSIC_ROOT:-/tmp/nasmusic-test/music}"
TEST_STAGE="${NASMUSIC_STAGING_DIR:-/tmp/nasmusic-test/staging}"
TEST_PLAY="${NASMUSIC_PLAYLIST_DIR:-/tmp/nasmusic-test/playlists}"
mkdir -p "$TEST_LIB" "$TEST_STAGE" "$TEST_PLAY"

# Drop a sample file into the library if the library is empty.
if ! find "$TEST_LIB" -name '*.mp3' | grep -q .; then
  echo "No mp3 in $TEST_LIB — generating a sample tone for local-search tests."
  if command -v ffmpeg >/dev/null; then
    ffmpeg -v error -f lavfi -i "sine=frequency=440:duration=20" \
      -q:a 4 -id3v2_version 3 -metadata artist="Test Artist" \
      -metadata title="Demo Song" "$TEST_LIB/Test Artist - Demo Song.mp3" \
      >/dev/null 2>&1 || true
  fi
fi

exec python3 -m nasmusic \
  --music-root "$TEST_LIB" \
  --staging-dir "$TEST_STAGE" \
  --playlist-dir "$TEST_PLAY" \
  --port "${NASMUSIC_PORT:-6680}" \
  "$@"
