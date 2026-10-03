#!/bin/bash
# Host-only regression checks. Extract the current loading methods, not copies;
# replace SwiftUI storage/network dependencies without launching an app/simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d /tmp/genplayer-vod-regressions.XXXXXX)
adapter="$test_dir/Adapters.swift"
printf 'import Foundation\n' > "$adapter"
for platform in Mac; do
    case "$platform" in
        IOS) source_file=GenPlayer/Source/Views/VODLibraryView.swift ;;
        Mac) source_file=GenPlayerCore/Sources/GenPlayerShell/MacVODLibraryView.swift ;;
        TV) source_file=GenPlayerCore/Sources/GenPlayerShell/TVVODLibraryView.swift ;;
    esac
    printf '@MainActor final class %sBrowser {\nlet server = ServerConfig()\nlet vodService = VODService.shared\n' "$platform" >> "$adapter"
    awk '/public init|private var selectedCategoryTitle/ {exit} /@State / {sub(/@State private /, ""); print}' "$source_file" >> "$adapter"
    if [ "$platform" = TV ]; then
        awk '/private func reload\(/ {copy=1} /private struct TVVODPosterCard/ {exit} copy {gsub(/private func /, "func "); print}' "$source_file" >> "$adapter"
    else
        awk '/\/\/ MARK: - Data Loading/ {copy=1} /\/\/ MARK: - Mac VOD Grid Card/ {exit} copy {gsub(/private func /, "func "); print}' "$source_file" >> "$adapter"
    fi
done
# Compile the real API search method against an in-memory URLProtocol fixture.
printf 'extension SearchAPI {\n' >> "$adapter"
awk '/public func search\(/ {copy=1} /\/\/ MARK: - Fetch Detail/ {exit} copy {print}' GenPlayerCore/Sources/GenPlayerCore/VODService.swift >> "$adapter"
printf '}\n@MainActor final class SourceSelection {\nvar playSources: [VODPlaySource] = []\nvar selectedSourceIndex = 0\n' >> "$adapter"
awk '/private var currentSource:/ {copy=1} copy {sub(/private var/, "var"); print} copy && /^    }/ {exit}' GenPlayerCore/Sources/GenPlayerShell/MacVODLibraryView.swift >> "$adapter"
printf '}\n' >> "$adapter"
# Exercise the production multi-source request/cancellation logic without SwiftUI.
cat >> "$adapter" <<'SWIFT'
@MainActor final class MultiSearch {
var keyword = ""
var results: [UUID: [VODItem]] = [:]
var errors: [UUID: String] = [:]
var pages: [UUID: Int] = [:]
var totals: [UUID: Int] = [:]
var busy = false
var requestID = UUID()
var work: Task<Void, Never>?
var sources: [ServerConfig] = []
SWIFT
awk '/private func cancel\(\) \{ work\?/ {copy=1} copy && !/^#endif/ {gsub(/private func /, "func "); print}' GenPlayerCore/Sources/GenPlayerShell/MacVODLibraryView.swift >> "$adapter"
# Check the UI wiring that the host-only state harness cannot execute.
rg -q 'selectedSourceIndex = src.index' GenPlayerCore/Sources/GenPlayerShell/MacVODLibraryView.swift
rg -q 'let isSelected = currentSource\?.index == src.index' GenPlayerCore/Sources/GenPlayerShell/MacVODLibraryView.swift
! rg -q 'currentPage < totalPages && searchText.isEmpty' GenPlayerCore/Sources/GenPlayerShell/MacVODLibraryView.swift
rg -Fq 'onDisappear { catalog.cancel() }' GenPlayerCore/Sources/GenPlayerShell/TVVODLibraryView.swift
sed '/^import GenPlayerCore$/d' GenPlayerCore/Sources/GenPlayerShell/MacVODCategoryPager.swift > "$test_dir/Pager.swift"
sed '/^import GenPlayerCore$/d' GenPlayerCore/Sources/GenPlayerShell/MacVODSearchGrouping.swift > "$test_dir/Grouping.swift"
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/modules" \
    GenPlayerCore/Sources/GenPlayerCore/VODModel.swift "$test_dir/Pager.swift" "$test_dir/Grouping.swift" "$adapter" \
    scripts/check_vod_regressions.swift -o "$test_dir/check-vod"
"$test_dir/check-vod"

# iOS and tvOS now share the catalog; exercise its production state machine.
bash scripts/check_vod_catalog.sh
