#!/bin/bash
set -euo pipefail
# Use the patched native VLC source/build directories; this never opens audio.
source_dir="${1:?Pass the patched VLC source directory}"
build_dir="${2:?Pass its native macOS build directory}"
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
check_dir="$(mktemp -d /tmp/genplayer-vlc-clock.XXXXXX)"
xcrun clang -I"$build_dir" -I"$source_dir/include" -I"$source_dir/src/input" \
    "$repo_dir/VLCKitPatched/tests/clock.c" "$build_dir/src/input/.libs/clock.o" \
    -L"$build_dir/src/.libs" -lvlccore -Wl,-rpath,"$build_dir/src/.libs" \
    -o "$check_dir/check"
"$check_dir/check"
