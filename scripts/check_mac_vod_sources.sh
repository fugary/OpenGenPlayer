#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/genplayer-vod-sources.XXXXXX)
awk '/struct MacVODSourcesEditor/ {exit} !/^import SwiftUI/ && !/^import GenPlayerCore/ {print}' GenPlayerCore/Sources/GenPlayerShell/MacVODSources.swift > "$test_dir/Sources.swift"
printf '\n#endif\n' >> "$test_dir/Sources.swift"
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/modules" GenPlayerCore/Sources/GenPlayerCore/ServerModel.swift "$test_dir/Sources.swift" scripts/check_mac_vod_sources.swift -o "$test_dir/check"
"$test_dir/check"
