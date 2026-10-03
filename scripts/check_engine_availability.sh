#!/bin/bash
# Pure policy checks; no App, native decoder, network, audio or UI.
set -euo pipefail
cd "$(dirname "$0")/.."
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$task_dir/cache" \
  GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift \
  scripts/check_engine_availability.swift -o "$task_dir/check"
GENPLAYER_DISABLED_ENGINES='' "$task_dir/check" ''
GENPLAYER_DISABLED_ENGINES=vlc "$task_dir/check" vlc
GENPLAYER_DISABLED_ENGINES=mpv "$task_dir/check" mpv
GENPLAYER_DISABLED_ENGINES=' VLC , MPV ' "$task_dir/check" vlc,mpv
