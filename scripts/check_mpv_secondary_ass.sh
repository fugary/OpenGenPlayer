#!/bin/bash
# No app, simulator, video, or screen capture. Exercises the production bridge.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
bridge="$root/GenPlayerCore/Sources/GenPlayerMPVBridge"
testdir="$(mktemp -d "${TMPDIR:-/tmp}/genplayer-mpv-ass.XXXXXX")"
trap 'rm -rf "$testdir"' EXIT
xcrun clang -fobjc-arc -fno-modules -fsanitize=address,undefined \
    -I "$bridge/include" -I "$bridge/vendor/mpv" -I "$bridge/vendor" \
    -framework Foundation -framework QuartzCore -framework CoreGraphics \
    "$root/scripts/fixtures/mpv_secondary_ass_geometry.m" -o "$testdir/geometry"
"$testdir/geometry"
