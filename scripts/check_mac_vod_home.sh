#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/genplayer-mac-vod-home.XXXXXX)
# Compile production state logic with a suspended, cancellation-resistant API fixture.
sed '/^import GenPlayerCore$/d' GenPlayerCore/Sources/GenPlayerShell/MacVODHomeModel.swift > "$test_dir/Home.swift"
sed '/^import GenPlayerCore$/d' GenPlayerCore/Sources/GenPlayerShell/MacVODCategoryPager.swift > "$test_dir/Pager.swift"
sed '/^import GenPlayerCore$/d' GenPlayerCore/Sources/GenPlayerShell/MacVODSearchGrouping.swift > "$test_dir/Grouping.swift"
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/modules" \
    GenPlayerCore/Sources/GenPlayerCore/VODModel.swift "$test_dir/Pager.swift" "$test_dir/Home.swift" "$test_dir/Grouping.swift" \
    scripts/check_mac_vod_home.swift -o "$test_dir/check-home"
"$test_dir/check-home"
