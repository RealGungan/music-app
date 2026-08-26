#!/usr/bin/env bash
# Build (if needed) and launch the desktop app with a fresh BUILD_ID.
set -e
cd "$(dirname "$0")/app"
export PATH="$HOME/flutter-sdk/bin:$HOME/.local/bin:$PATH"
BUILD_ID=$(date -u +%Y%m%d-%H%M%S)
flutter build linux --release --dart-define=BUILD_ID="$BUILD_ID" "$@"
exec ./build/linux/x64/release/bundle/music_app
