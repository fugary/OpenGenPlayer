#!/bin/bash
# Compile the real adapters against native command spies; no player or media opened.
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
# Check the common contract and mpv adapter without a VLC module or VLC command spies.
sed -n '/^public final class MPVPlaybackEngine {/,/^}/p' scripts/check_playback_transport.swift > "$TASK_TMP/MPVEngine.swift"
xcrun swiftc -module-cache-path "$TASK_TMP/cache" -typecheck \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackTransportState.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackTransport.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVPlaybackTransport.swift "$TASK_TMP/MPVEngine.swift"
printf '%s\n' 'PASS: transport contract/state/mpv adapter compile without VLC'
sed '/^import VLCKitSPM$/d' GenPlayerCore/Sources/GenPlayerShell/VLCPlaybackTransport.swift > "$TASK_TMP/VLCPlaybackTransport.swift"
xcrun swiftc -module-cache-path "$TASK_TMP/cache" -parse-as-library \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackTransportState.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackTransport.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVPlaybackTransport.swift \
    "$TASK_TMP/VLCPlaybackTransport.swift" scripts/check_playback_transport.swift -o "$TASK_TMP/check"
"$TASK_TMP/check"

GENPLAYER_DISABLED_ENGINES=vlc "$TASK_TMP/check"
