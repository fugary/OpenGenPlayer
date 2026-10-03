#!/bin/bash
# Headless buffers and delivery only. Does not initialize mpv or open media/App/UI.
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -module-cache-path "$TASK_TMP/cache" -parse-as-library \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackFrameDelivery.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVPixelBufferOutput.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackPixelBufferCompositor.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVStartupOptionPolicy.swift \
    scripts/check_playback_frames.swift -o "$TASK_TMP/check"
"$TASK_TMP/check"
