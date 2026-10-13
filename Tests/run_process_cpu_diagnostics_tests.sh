#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/process-cpu-diagnostics-tests"
mkdir -p "$task_test_dir"
# Compile the owning diagnostic value unchanged, without initializing FileLogger
# or touching the user's log directory. No duplicated counter implementation.
python3 - "$task_test_dir/ProcessCPUTime.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/DebugLogger.swift').read_text()
start = source.index('/// Diagnostic process counters')
end = source.index('final nonisolated class DebugLogger:', start)
imports = 'import Foundation\n#if canImport(Darwin)\nimport Darwin\n#endif\n'
Path(sys.argv[1]).write_text(imports + source[start:end])
PY
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/module-cache" \
    "$task_test_dir/ProcessCPUTime.swift" Tests/ProcessCPUDiagnosticsTests.swift \
    -o "$task_test_dir/process-cpu-diagnostics-tests"
"$task_test_dir/process-cpu-diagnostics-tests"
