#!/bin/bash
# Loopback CLI protocol checks; no simulator, app, ASR or external server.
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/GenPlayerFileAudioChecks.XXXXXX")"
server_pid=""
trap 'if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi; rm -rf "$build_dir"' EXIT
source_dir="$repo_dir/GenPlayerCore/Sources/GenPlayerCore"
xcrun swiftc -parse-as-library -module-cache-path "$build_dir/modules" "$source_dir/AudioRangeSource.swift" \
    "$source_dir/HTTPAudioRangeSource.swift" "$source_dir/FTPAudioRangeSource.swift" \
    "$source_dir/FileAudioRangeReader.swift" "$repo_dir/scripts/file_audio_factory_stubs.swift" \
    "$repo_dir/scripts/check_file_audio_ranges.swift" -o "$build_dir/checks"
python3 "$repo_dir/scripts/file_audio_fixture_server.py" "$build_dir/ports.json" > "$build_dir/server.log" 2>&1 &
server_pid=$!
for ((i=0; i<100; i++)); do [[ -s "$build_dir/ports.json" ]] && break; sleep 0.05; done
if [[ ! -s "$build_dir/ports.json" ]]; then cat "$build_dir/server.log" >&2; exit 1; fi
"$build_dir/checks" "$build_dir/ports.json"
