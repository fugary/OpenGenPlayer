#!/bin/bash
# Pure diagnostics checks; does not open media, an app or a simulator.
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
xcrun swiftc -module-cache-path "$TASK_TMP/cache" -parse-as-library \
    GenPlayerCore/Sources/GenPlayerShell/MPVHDRInfo.swift \
    scripts/check_mpv_hdr_info.swift -o "$TASK_TMP/check"
"$TASK_TMP/check"
