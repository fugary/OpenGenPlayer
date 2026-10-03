#!/bin/bash
# Pure request checks through URLProtocol; no server, app, or simulator is contacted.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerReportingChecks.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
python3 - "$repo_dir" "$build_dir" <<'PY'
from pathlib import Path
import sys
repo, build = map(Path, sys.argv[1:])
source = (repo / 'GenPlayerCore/Sources/GenPlayerCore/RemotePlaybackStateStore.swift').read_text()
payload = source.split('public struct MacServerPlaybackSyncPayload {', 1)[1].split('\npublic enum PlaybackRefreshCenter', 1)[0]
(build / 'Payload.swift').write_text('import Foundation\npublic struct MacServerPlaybackSyncPayload {' + payload)
PY
xcrun swiftc -emit-library -emit-module -module-name GenPlayerCore -module-cache-path "$build_dir/modules" \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerCore/ServerModel.swift" "$build_dir/Payload.swift" \
    -emit-module-path "$build_dir/GenPlayerCore.swiftmodule" -o "$build_dir/libGenPlayerCore.dylib"
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/modules" -I "$build_dir" -L "$build_dir" -lGenPlayerCore \
    "$repo_dir/GenPlayerCore/Sources/GenPlayerShell/MacMediaReportingService.swift" \
    "$repo_dir/scripts/check_mac_media_reporting.swift" -o "$build_dir/checks"
DYLD_LIBRARY_PATH="$build_dir" "$build_dir/checks"
