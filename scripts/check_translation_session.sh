#!/bin/bash
# Pure model checks. Does not launch an app or create a system TranslationSession/download sheet.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerTranslationChecks.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
printf '@_exported import SwiftUI\n' > "$build_dir/Exports.swift"
xcrun swiftc -emit-library -emit-module -module-name GenPlayerCore -module-cache-path "$build_dir/modules" \
    "$build_dir/Exports.swift" "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/SubtitleModel.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/CrossPlatform.swift" \
    -emit-module-path "$build_dir/GenPlayerCore.swiftmodule" -o "$build_dir/libGenPlayerCore.dylib"
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/modules" -I "$build_dir" -L "$build_dir" -lGenPlayerCore \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/MacAudioSubtitlePlan.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/MacSubtitleTranslationPlan.swift" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/MacSubtitleTranslation.swift" \
    "$repo_dir/scripts/check_translation_session.swift" -o "$build_dir/checks"
DYLD_LIBRARY_PATH="$build_dir" "$build_dir/checks"
