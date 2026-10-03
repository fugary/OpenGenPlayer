#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /tmp/genplayer-adaptive-layout.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/modules" \
  GenPlayer/Source/Views/Components/AdaptiveMediaLayout.swift \
  scripts/check_adaptive_media_layout.swift -o "$check_dir/check"
"$check_dir/check"
