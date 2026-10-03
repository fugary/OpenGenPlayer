#!/bin/bash
# Production provider with a fake native thumbnailer: no media, App, window or simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
# This directory has no VLC module: public contracts and fallback must compile without it.
mkdir "$TASK_TMP/no-vlc"
xcrun swiftc -emit-module -module-name GenPlayerCore \
    -module-cache-path "$TASK_TMP/cache" scripts/fixtures/playback_metadata_image_stub.swift \
    -emit-module-path "$TASK_TMP/no-vlc/GenPlayerCore.swiftmodule"
xcrun swiftc -typecheck -module-cache-path "$TASK_TMP/cache" -I "$TASK_TMP/no-vlc" \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackPreviewProvider.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackMetadataProvider.swift \
    GenPlayerCore/Sources/GenPlayerShell/FallbackPlaybackPreviewProvider.swift
printf '%s\n' 'PASS: preview/metadata contracts and fallback compile without VLCKit'
xcrun swiftc -emit-library -emit-module -module-name VLCKitSPM \
    -module-cache-path "$TASK_TMP/cache" scripts/fixtures/preview_thumbnailer_stub.swift \
    -emit-module-path "$TASK_TMP/VLCKitSPM.swiftmodule" -o "$TASK_TMP/libVLCKitSPM.dylib"
xcrun swiftc -emit-library -emit-module -module-name GenPlayerCore \
    -module-cache-path "$TASK_TMP/cache" scripts/fixtures/playback_metadata_image_stub.swift \
    -emit-module-path "$TASK_TMP/GenPlayerCore.swiftmodule" -o "$TASK_TMP/libGenPlayerCore.dylib"
xcrun swiftc -parse-as-library -module-cache-path "$TASK_TMP/cache" -I "$TASK_TMP" -L "$TASK_TMP" -lVLCKitSPM \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackPreviewProvider.swift \
    GenPlayerCore/Sources/GenPlayerShell/FallbackPlaybackPreviewProvider.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackMetadataProvider.swift \
    GenPlayerCore/Sources/GenPlayerShell/VLCPlaybackMetadataProvider.swift \
    GenPlayerCore/Sources/GenPlayerShell/VLCPlaybackPreviewProvider.swift \
    scripts/check_playback_preview.swift -o "$TASK_TMP/check"
DYLD_LIBRARY_PATH="$TASK_TMP" "$TASK_TMP/check"
# Compile the UIKit-only provider on the headless macOS host; native engine is a
# command spy, while the production CoreVideo channel and image conversion run.
sed 's/#if os(iOS) || os(tvOS)/#if os(macOS)/' \
    GenPlayerCore/Sources/GenPlayerShell/MPVPlaybackPreviewProvider.swift > "$TASK_TMP/MPVPlaybackPreviewProvider.swift"
xcrun swiftc -parse-as-library -module-cache-path "$TASK_TMP/cache" -I "$TASK_TMP/no-vlc" \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackPreviewProvider.swift \
    GenPlayerCore/Sources/GenPlayerShell/PlaybackFrameDelivery.swift \
    GenPlayerCore/Sources/GenPlayerShell/MPVPixelBufferOutput.swift \
    "$TASK_TMP/MPVPlaybackPreviewProvider.swift" scripts/check_mpv_preview.swift -o "$TASK_TMP/check-mpv"
DYLD_LIBRARY_PATH="$TASK_TMP" "$TASK_TMP/check-mpv"

GENPLAYER_DISABLED_ENGINES=mpv DYLD_LIBRARY_PATH="$TASK_TMP" "$TASK_TMP/check-mpv"
