#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TASK_TMP=$(mktemp -d)
trap 'rm -rf "$TASK_TMP"' EXIT
python3 - "$TASK_TMP/Core.swift" <<'PY'
import sys
s=open('GenPlayerCore/Sources/GenPlayerShell/MacVODSourceSwitchView.swift').read().split('struct MacVODSourceSwitchView: View')[0]
s=s.replace('import SwiftUI','').replace('import GenPlayerCore','')+'\n#endif\n'
open(sys.argv[1],'w').write(s)
PY
swiftc -module-cache-path "$TASK_TMP/cache" -parse-as-library "$TASK_TMP/Core.swift" scripts/check_mac_vod_switch.swift -o "$TASK_TMP/check"
"$TASK_TMP/check"
