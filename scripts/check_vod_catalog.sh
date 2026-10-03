#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/genplayer-vod-catalog.XXXXXX)
# Compile the production summary extension without SwiftUI or network calls.
printf 'import Foundation\nimport CryptoKit\npublic extension ServerConfig {\n' > "$test_dir/Summaries.swift"
awk '/    var mobileVODSummaryEndpoints:/ {copy=1} copy && /^#endif/ {exit} copy {print}' GenPlayerCore/Sources/GenPlayerShell/VODSourceEditor.swift >> "$test_dir/Summaries.swift"
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/modules" \
  GenPlayerCore/Sources/GenPlayerCore/ServerModel.swift \
  GenPlayerCore/Sources/GenPlayerCore/VODModel.swift \
  GenPlayerCore/Sources/GenPlayerCore/VODCatalog.swift \
  "$test_dir/Summaries.swift" scripts/check_vod_catalog.swift -o "$test_dir/check"
"$test_dir/check"
