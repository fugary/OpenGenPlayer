#!/bin/bash
# Pure host-side checks. Does not launch an app or simulator.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
framework_dir="${GENPLAYER_VLC_FRAMEWORK_DIR:-$repo_dir/VLCKitPatched/Artifacts/VLCKit-all.xcframework/macos-arm64_x86_64}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerSubtitleBrowserChecks.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
printf '@_exported import SwiftUI\n' > "$build_dir/Exports.swift"
# Build the production support enum without unrelated app/server models.
python3 - "$repo_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
source=(Path(sys.argv[1])/'GenPlayerCore/Sources/GenPlayerCore/MediaModels.swift').read_text()
enum='public enum EmbeddedSubtitleSupportLevel'+source.split('public enum EmbeddedSubtitleSupportLevel',1)[1].split('\n}',1)[0]+'\n}\n'
(Path(sys.argv[2])/'SupportLevel.swift').write_text(enum)
PY
xcrun swiftc -emit-library -emit-module -module-name GenPlayerCore -module-cache-path "$build_dir/modules" \
    "$build_dir/Exports.swift" "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/SubtitleModel.swift" \
    "$build_dir/SupportLevel.swift" "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/LocalEmbeddedSubtitleExtractor.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/CrossPlatform.swift" \
    -emit-module-path "$build_dir/GenPlayerCore.swiftmodule" -o "$build_dir/libGenPlayerCore.dylib"
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/modules" -I "$build_dir" -L "$build_dir" -lGenPlayerCore -F "$framework_dir" -framework VLCKit \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/SubtitleBrowserModel.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/MacRemoteSubtitleReader.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/IOSRemoteSubtitleLoader.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/MacSubtitleBrowserLocalTracks.swift" \
    "$repo_dir/scripts/check_remote_subtitle_reader.swift" \
    "$repo_dir/scripts/check_local_subtitle_tracks.swift" \
    "$repo_dir/scripts/check_subtitle_browser.swift" -o "$build_dir/checks"
DYLD_LIBRARY_PATH="$build_dir" DYLD_FRAMEWORK_PATH="$framework_dir" "$build_dir/checks" "$@"
