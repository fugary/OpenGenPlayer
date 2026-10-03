#!/bin/bash
# Host-side adapter/model checks: no app, simulator, SpeechAnalyzer or TranslationSession runs.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerIOSSubtitleChecks.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
framework_dir="${GENPLAYER_VLC_FRAMEWORK_DIR:-$repo_dir/VLCKitPatched/Artifacts/VLCKit-all.xcframework/macos-arm64_x86_64}"
bridge_dir="$repo_dir/GenPlayerCore/Sources/GenPlayerVLCBridge"
source_dir="$repo_dir/GenPlayerCore/Sources/GenPlayerShell"
printf 'module GenPlayerVLCBridge { header "%s/include/GenPlayerVLCAudioReader.h" export * }\n' "$bridge_dir" > "$build_dir/module.modulemap"
xcrun clang -fobjc-arc -F "$framework_dir" -I "$bridge_dir/include" -c "$bridge_dir/GenPlayerVLCAudioReader.m" -o "$build_dir/reader.o"
printf '@_exported import SwiftUI\n' > "$build_dir/Exports.swift"
xcrun swiftc -emit-library -emit-module -module-name GenPlayerCore -module-cache-path "$build_dir/modules" \
    "$build_dir/Exports.swift" "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/SubtitleModel.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/CrossPlatform.swift" \
    "$repo_dir/scripts/ios_smb_audio_test_transport.swift" \
    -emit-module-path "$build_dir/GenPlayerCore.swiftmodule" -o "$build_dir/libGenPlayerCore.dylib"
# Compile the production adapter model on the host, leaving the iOS SwiftUI presentation to xcodebuild.
python3 - "$source_dir/IOSSubtitleIntelligence.swift" "$build_dir/Adapter.swift" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text().split('/// This stays attached to the player;')[0]
assert source.startswith('#if os(iOS)\n')
Path(sys.argv[2]).write_text(source.replace('#if os(iOS)\n', '', 1))
PY
source "$repo_dir/scripts/mpv_audio_check_linking.sh"
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/modules" -I "$build_dir" -L "$build_dir" -lGenPlayerCore \
    "${mpv_flags[@]}" -F "$framework_dir" -framework VLCKit \
    "$source_dir/PlaybackEngineCapabilities.swift" "$source_dir/MPVAudioFileReader.swift" "$source_dir/MPVStartupOptionPolicy.swift" \
    "$source_dir"/MacAudioSubtitle{Plan,Engine,Job,Remux}.swift "$source_dir/MacMatroskaAudioOrigin.swift" "$source_dir/MacJellyfinAudioSubtitles.swift" \
    "$source_dir/MP4AudioIndex.swift" "$source_dir/MacMP4AudioSubtitles.swift" \
    "$source_dir/MacSubtitleTranslationPlan.swift" "$source_dir/MacSubtitleTranslation.swift" "$build_dir/Adapter.swift" \
    "$source_dir/SubtitleBrowserModel.swift" \
    "$source_dir/MacMPVDecodedSubtitles.swift" \
    "$repo_dir/scripts/check_ios_subtitle_intelligence.swift" "$repo_dir/scripts/check_ios_smb_audio.swift" \
    "$build_dir/reader.o" -o "$build_dir/checks"
if [[ "${1:-}" == --smb ]]; then
    ffmpeg_bin="${GENPLAYER_FFMPEG:-$(command -v ffmpeg || true)}"
    if [[ -z "$ffmpeg_bin" && -x /Applications/EmbyServer.app/Contents/MacOS/ffmpeg ]]; then
        ffmpeg_bin=/Applications/EmbyServer.app/Contents/MacOS/ffmpeg
    fi
    if [[ ! -x "$ffmpeg_bin" ]]; then
        echo 'Set GENPLAYER_FFMPEG to generate the SMB adapter fixture.' >&2
        exit 1
    fi
    "$ffmpeg_bin" -v error -y -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=65' \
        -f lavfi -i 'sine=frequency=880:sample_rate=48000:duration=65' -map 0:a -map 1:a \
        -c:a aac -b:a 128k -metadata:s:a:0 language=eng -metadata:s:a:1 language=jpn "$build_dir/smb.mp4"
    set -- --smb-fixture "$build_dir/smb.mp4"
fi
DYLD_LIBRARY_PATH="$build_dir" DYLD_FRAMEWORK_PATH="$framework_dir" "$build_dir/checks" "$@"
