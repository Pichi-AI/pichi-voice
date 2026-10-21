#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/retained-diarization-scope"
mkdir -p "$pichi_build"
python3 - "$pichi_build/ActualScope.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift').read_text()
start = source.index('/// Holds the existing native loading scope')
end = source.index('/// Small attempt-local identity evidence', start)
fragment = source[start:end].replace('private final nonisolated class MeetingIdleParakeetNemotronResources',
                                    'final nonisolated class MeetingIdleParakeetNemotronResources')
Path(sys.argv[1]).write_text('import Foundation\n' + fragment)
PY
swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
    -module-cache-path "$pichi_build/ModuleCache" \
    "$pichi_build/ActualScope.swift" Tests/MeetingRetainedDiarizationScopeTests.swift \
    -o "$pichi_build/tests"
"$pichi_build/tests"
