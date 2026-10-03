#!/bin/bash
# Headless synthetic regression: unsupported legacy codecs surround a cached AAC track.
# Uses the same framework environment variables as check_audio_subtitles.sh.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerMixedAudio.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
"${1:-ffmpeg}" -v error \
    -f lavfi -i sine=frequency=440:duration=3 \
    -f lavfi -i sine=frequency=880:duration=3 \
    -f lavfi -i sine=frequency=1320:duration=3 \
    -map 0:a -map 1:a -map 2:a -c:a:0 flac -c:a:1 aac -c:a:2 eac3 \
    "$fixture_dir/mixed.mka"
bash "$repo_dir/scripts/check_audio_subtitles.sh" --media "$fixture_dir/mixed.mka"
