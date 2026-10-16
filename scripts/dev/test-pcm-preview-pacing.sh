#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/pcm-preview-pacing"
mkdir -p "$pichi_build"
# Compile the actual runtime's pure pacing/timing owners. No native model, personal
# profile, log service or microphone is initialized by these deterministic tests.
python3 - "$pichi_build/MeetingPCMPreviewPacing.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift').read_text()
start = source.index('/// Buffered providers decode each growing prefix again.')
end = source.index('/// Small attempt-local identity evidence', start)
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end])
PY
swiftc -swift-version 6 -parse-as-library -module-cache-path "$pichi_build/ModuleCache" \
    "$pichi_build/MeetingPCMPreviewPacing.swift" Tests/MeetingPCMPreviewPacingTests.swift \
    -o "$pichi_build/tests"
"$pichi_build/tests"
