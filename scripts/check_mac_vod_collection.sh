#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/genplayer-vod-collection.XXXXXX)
awk '/struct MacVODSourcesEditor/ {exit} !/^import SwiftUI/ && !/^import GenPlayerCore/ {print}' GenPlayerCore/Sources/GenPlayerShell/MacVODSources.swift > "$test_dir/Sources.swift"
printf '\n#endif\n' >> "$test_dir/Sources.swift"
awk '/struct MacVODCollectionHome: View/ {exit} !/^import SwiftUI/ && !/^import GenPlayerCore/ {print}' GenPlayerCore/Sources/GenPlayerShell/MacVODCollectionHome.swift > "$test_dir/Home.swift"
printf '\n#endif\n' >> "$test_dir/Home.swift"
for name in MacVODCategoryPager MacVODSearchGrouping; do
    sed '/^import GenPlayerCore$/d' "GenPlayerCore/Sources/GenPlayerShell/$name.swift" > "$test_dir/$name.swift"
done
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/modules" \
    GenPlayerCore/Sources/GenPlayerCore/ServerModel.swift GenPlayerCore/Sources/GenPlayerCore/VODModel.swift \
    "$test_dir/Sources.swift" "$test_dir/Home.swift" "$test_dir/MacVODCategoryPager.swift" "$test_dir/MacVODSearchGrouping.swift" \
    scripts/check_mac_vod_collection.swift -o "$test_dir/check"
"$test_dir/check"
