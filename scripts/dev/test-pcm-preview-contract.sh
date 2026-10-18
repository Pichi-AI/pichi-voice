#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/pcm-preview-contract"
mkdir -p "$pichi_build"
swiftc -swift-version 6 -parse-as-library -module-cache-path "$pichi_build/ModuleCache" \
    Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronRuntime.swift \
    Tests/MeetingPCMPreviewContractTests.swift -o "$pichi_build/tests"
"$pichi_build/tests"

# Exercise the actual scoped controller and cancellable PCM window without native models.
# The helper only opens the production window's fileprivate constructor for this test module.
python3 - "$pichi_build/ActualPCMWindow.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingProcessingPipeline+MemoryAudio.swift').read_text()
start = source.index('nonisolated enum MeetingMemoryAudioError')
end = source.index('/// Bounded PCM transport')
helper = '''
extension MeetingPCMProgressiveWindow {
    nonisolated static func controllerTestWindow(samples: [Float], sealed: Bool) -> MeetingPCMProgressiveWindow {
        let window = MeetingPCMProgressiveWindow(initialFrames: 1, intervalFrames: 1)
        if !samples.isEmpty { samples.withUnsafeBufferPointer { window.append($0, isFinal: sealed) } }
        else if sealed { window.seal() }
        return window
    }
}
'''
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end] + helper)
PY
swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
    -module-cache-path "$pichi_build/ModuleCache" "$pichi_build/ActualPCMWindow.swift" \
    Sources/Fluid/Services/Meeting/MeetingStreamingPCMController.swift \
    Tests/MeetingStreamingPCMControllerTests.swift -o "$pichi_build/streaming-tests"
"$pichi_build/streaming-tests"

# Compile the whole production attempt owner with inert external resource types. This verifies
# deferred NER ownership without starting a native model or creating an audio file.
python3 - "$pichi_build/ActualMemoryAttempt.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingProcessingPipelineMemoryAttempt.swift').read_text()
Path(sys.argv[1]).write_text(source[:source.index('extension MeetingProcessingPipeline {')])
PY
swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
    -module-cache-path "$pichi_build/ModuleCache" "$pichi_build/ActualMemoryAttempt.swift" \
    Sources/Fluid/Services/Privacy/TranscriptTextRedacting.swift \
    Tests/MeetingMemoryPreparationTests.swift -o "$pichi_build/preparation-tests"
"$pichi_build/preparation-tests"
