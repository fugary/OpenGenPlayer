#!/bin/bash
# Production request/credential checks with URLProtocol; no App, simulator or real server.
set -euo pipefail
cd "$(dirname "$0")/.."
task_dir=$(mktemp -d)
trap 'rm -rf "$task_dir"' EXIT
python3 - "$task_dir" <<'PY'
from pathlib import Path
import sys
core = Path('GenPlayerCore/Sources/GenPlayerCore')
out = Path(sys.argv[1])
history = (core / 'HistoryService.swift').read_text()
(out / 'Progress.swift').write_text(history.split('public class HistoryService', 1)[0])
network = (core / 'NetworkHelpers.swift').read_text()
(out / 'Network.swift').write_text(network.split('public struct ServerBackupPayload', 1)[0])
PY
xcrun swiftc -parse-as-library -module-cache-path "$task_dir/modules" \
  GenPlayerCore/Sources/GenPlayerCore/ServerModel.swift \
  GenPlayerCore/Sources/GenPlayerCore/JellyfinModels.swift \
  GenPlayerCore/Sources/GenPlayerCore/EmbyModels.swift \
  GenPlayerCore/Sources/GenPlayerCore/PlexModels.swift \
  GenPlayerCore/Sources/GenPlayerCore/JellyfinHomeCarousel.swift \
  GenPlayerCore/Sources/GenPlayerCore/FilePlaybackCredentials.swift \
  "$task_dir/Progress.swift" "$task_dir/Network.swift" \
  scripts/check_home_playback.swift -o "$task_dir/check"
"$task_dir/check"
