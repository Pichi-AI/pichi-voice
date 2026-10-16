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
# Whisper signal/token diagnostics are also pure values. Reuse the same native
# diagnostic probe and the hosted test's synthetic scenarios without a model,
# FileLogger initialization, or a second implementation of the measurement.
python3 - "$task_test_dir/WhisperDiagnostics.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/WhisperProvider.swift').read_text()
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path('Tests').resolve()))
from run_meeting_backup_refresh_tests import declaration

diagnostics = '\n\n'.join(declaration(source, marker) for marker in (
    'nonisolated struct WhisperSignalDiagnostics:',
    'nonisolated struct WhisperProbabilityDiagnostics:',
    'nonisolated enum WhisperShortInputPolicy {',
))
Path(sys.argv[1]).write_text('import Foundation\n' + diagnostics + '\n')
PY
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -D PICHI_WHISPER_DIAGNOSTICS_STANDALONE \
    -module-cache-path "$task_test_dir/module-cache" \
    "$task_test_dir/WhisperDiagnostics.swift" Tests/MobileIntegrationTests/WhisperDiagnosticsTests.swift \
    -o "$task_test_dir/whisper-diagnostics-tests"
"$task_test_dir/whisper-diagnostics-tests"
