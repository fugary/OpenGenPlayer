#!/bin/bash
# Pure routing/time checks. Does not launch an app, simulator, or media player.
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -module-cache-path "$TASK_TMP/cache" -parse-as-library \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackSessionSnapshot.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackTransportState.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackSubtitleAutoSelection.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVSecondarySubtitleRendering.swift \
    GenPlayerCore/Sources/GenPlayerShell/MacMPVPlaybackPolicy.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVUIKitPlaybackPolicy.swift \
    GenPlayerCore/Sources/GenPlayerShell/TVMPVPlaybackPolicy.swift \
    GenPlayerCore/Sources/GenPlayerShell/TVPlaybackBackPolicy.swift \
    GenPlayerCore/Sources/GenPlayerShell/TVPlaybackDrawerLayout.swift \
    GenPlayerCore/Sources/GenPlayerShell/TVMPVSubtitleLoader.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVSoftwareRenderSize.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVStartupOptionPolicy.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVPlaybackCache.swift \
    GenPlayerCore/Sources/GenPlayerShell/MacMPVDiskCache.swift \
    GenPlayerCore/Sources/GenPlayerShell/IOSSubtitleTypography.swift \
    GenPlayerCore/Sources/GenPlayerShell/IOSPlaybackTrackSelection.swift \
    GenPlayerCore/Sources/GenPlayerShell/IOSMPVRemoteSubtitleSelection.swift \
    GenPlayerCore/Sources/GenPlayerShell/MacMPVTrack.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVReadAheadByteCache.swift \
    GenPlayerCore/Sources/GenPlayerShell/MacMPVStream.swift \
    GenPlayerCore/Sources/GenPlayerShell/MacMPVDecodedSubtitles.swift \
    GenPlayerCore/Sources/GenPlayerShell/MacMPVCaptureFrame.swift \
    scripts/check_mac_mpv.swift -o "$TASK_TMP/check"
"$TASK_TMP/check"
