#!/bin/bash
# No app launch, screen capture, media or GPU rendering.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
products="${1:?Usage: $0 <macOS Build/Products/Debug>}"
bridge="$root/GenPlayerCore/Sources/GenPlayerMPVBridge"
testdir="$(mktemp -d "${TMPDIR:-/tmp}/genplayer-mpv-resize.XXXXXX")"
trap 'rm -rf "$testdir"' EXIT
xcrun clang -fobjc-arc -fno-modules -I "$bridge/include" -I "$bridge/vendor/mpv" -I "$bridge/vendor" \
    -F "$products" -framework Foundation -framework QuartzCore -framework CoreGraphics \
    "$root/scripts/fixtures/mac_mpv_resize.m" -o "$testdir/resize"
"$testdir/resize"
