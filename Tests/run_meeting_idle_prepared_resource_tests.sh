#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/meeting-idle-prepared-resource-tests"
mkdir -p "$task_test_dir"
python3 - "$task_test_dir/ActualIdleSpeechRetirement.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/ASRService+iOS.swift').read_text()
retire = source[source.index('    func retireIdleSpeechResidency()'):source.index('    func withMeetingModelResidency<T>(attemptID: UUID, idleResourceIdentity:')]
release = source[source.index('    private func releaseResidentProvider()'):source.index('    func activateModel(')]
pipeline = Path('Sources/Fluid/Services/Meeting/MeetingProcessingPipelineMemoryAttempt.swift').read_text()
prefix = pipeline[pipeline.index('/// Optional prefix resources'):pipeline.index('@MainActor\nfinal class MeetingMemoryProcessingAttempt')]
Path(sys.argv[1]).write_text('import Foundation\n' + prefix + '\nextension IdleSpeechHostWitness {\n' + retire + release + '\n}\n')
PY
# Actual generic lease and residency coordinator; fake native loaders hold no model/audio.
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Services/ASRActivityLease.swift \
    Sources/Fluid/Services/Meeting/MeetingModelResidencyCoordinator.swift \
    "$task_test_dir/ActualIdleSpeechRetirement.swift" \
    Tests/MeetingIdlePreparedResourceTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
