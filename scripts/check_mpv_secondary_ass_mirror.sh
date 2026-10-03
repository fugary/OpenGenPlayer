#!/bin/bash
# Real libass + production renderer, synthetic in-memory vector ASS only.
# Does not create libmpv players, windows, simulators or capture any screen.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
framework_dir="${1:?Pass the completed macOS Build/Products/Debug directory}"
source "$root/scripts/mpv_audio_check_linking.sh"
bridge="$root/GenPlayerCore/Sources/GenPlayerMPVBridge"
task_tmp="$(mktemp -d "${TMPDIR:-/tmp}/genplayer-ass-mirror.XXXXXX")"
trap 'rm -rf "$task_tmp"' EXIT
xcrun clang -g -fobjc-arc -fno-modules -fsanitize=address,undefined \
    -I "$bridge/include" -I "$bridge/vendor/mpv" -I "$bridge/vendor" \
    "$root/scripts/fixtures/mpv_secondary_ass_mirror.m" "${mpv_flags[@]}" \
    -L "$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx" \
    -o "$task_tmp/mirror"
"$task_tmp/mirror"
