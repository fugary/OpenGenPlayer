#!/bin/bash
# Pure file/logic checks: no application, UI, audible playback, or speech model is started.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
framework_dir="${GENPLAYER_VLC_FRAMEWORK_DIR:-$repo_dir/VLCKitPatched/Artifacts/VLCKit-all.xcframework/macos-arm64_x86_64}"
if [[ ! -d "$framework_dir/VLCKit.framework" ]]; then
    echo "Set GENPLAYER_VLC_FRAMEWORK_DIR to the directory containing the macOS VLCKit.framework." >&2
    exit 1
fi
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerAudioChecksBuild.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
bridge_dir="$repo_dir/GenPlayerCore/Sources/GenPlayerVLCBridge"
printf 'module GenPlayerVLCBridge { header "%s/include/GenPlayerVLCAudioReader.h" export * }\n' "$bridge_dir" > "$build_dir/module.modulemap"
xcrun clang -fobjc-arc -F "$framework_dir" -I "$bridge_dir/include" -c "$bridge_dir/GenPlayerVLCAudioReader.m" -o "$build_dir/reader.o"
source_dir="$repo_dir/GenPlayerCore/Sources/GenPlayerShell"
source "$repo_dir/scripts/mpv_audio_check_linking.sh"
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/modules" -I "$build_dir" "${mpv_flags[@]}" -F "$framework_dir" -framework VLCKit \
    "$source_dir/PlaybackEngineCapabilities.swift" "$source_dir/MPVAudioFileReader.swift" "$source_dir/MPVStartupOptionPolicy.swift" \
    "$source_dir"/MacAudioSubtitle{Plan,Engine,Job,Remux}.swift "$source_dir/MacMatroskaAudioOrigin.swift" "$source_dir/MacJellyfinAudioSubtitles.swift" \
    "$source_dir/MP4AudioIndex.swift" "$source_dir/MacMP4AudioSubtitles.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/SMBAudioLogin.swift" \
    "$repo_dir/scripts/check_audio_subtitles.swift" "$repo_dir/scripts/check_remote_audio_subtitles.swift" \
    "$repo_dir/scripts/check_mp4_audio_ranges.swift" "$build_dir/reader.o" -o "$build_dir/checks"
TMPDIR="$build_dir/" DYLD_FRAMEWORK_PATH="$framework_dir" "$build_dir/checks" "$@"
