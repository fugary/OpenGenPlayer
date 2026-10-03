#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /tmp/genplayer-plex-filters.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$check_dir/modules" \
  GenPlayer/Source/Models/PlexLibraryFilters.swift \
  scripts/check_plex_library_filters.swift -o "$check_dir/check"
"$check_dir/check"
