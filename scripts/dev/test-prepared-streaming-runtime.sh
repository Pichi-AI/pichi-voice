#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/prepared-streaming-runtime"
mkdir -p "$pichi_build"
python3 - "$pichi_build/ActualPCMWindow.swift" "$pichi_build/ActualASRLoop.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingProcessingPipeline+MemoryAudio.swift').read_text()
start = source.index('nonisolated enum MeetingMemoryAudioError')
end = source.index('/// Bounded PCM transport')
helper = '''
extension MeetingPCMProgressiveWindow {
    nonisolated static func fixture(samples: [Float] = [], final: Bool = false) -> MeetingPCMProgressiveWindow {
        let window = MeetingPCMProgressiveWindow(initialFrames: 1, intervalFrames: 1)
        window.fixtureAppend(samples, final: final)
        return window
    }
    nonisolated func fixtureAppend(_ samples: [Float], final: Bool) {
        if !samples.isEmpty { samples.withUnsafeBufferPointer { self.append($0, isFinal: final) } }
        else if final { self.seal() }
    }
}
'''
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end] + helper)
runtime = Path('Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift').read_text()
start = runtime.index('nonisolated struct MeetingPCMPreviewPacing')
end = runtime.index('/// Small attempt-local identity evidence')
start_loop = runtime.index('    func recognizeProgressivePCMPhase(')
end_loop = runtime.index('    func pcmSpeechObservation(', start_loop)
# The ASR loop itself is the production source. The two downstream assembly methods are small
# witnesses because canonical assembly has its own actual-source regression suite.
assembly = '''
    func pcmSpeechObservation(output: MeetingParakeetEpochOutput, epoch: MeetingAnalysisEpochID,
        offset: Double, duration: Double, attemptID: UUID, isFinal: Bool) throws -> MeetingPCMTranscriptBatch {
        self.batch(output, epoch: epoch, offset: offset)
    }
    func attributePCMSpeech(samples: [Float], output: MeetingParakeetEpochOutput, epoch: MeetingAnalysisEpochID,
        offset: Double, attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        priorProfiles: [MeetingSpeakerVoiceProfile], priorSpeakers: [MeetingSessionSpeaker]) async throws -> MeetingPCMTranscriptBatch {
        self.batch(output, epoch: epoch, offset: offset)
    }
    private func batch(_ output: MeetingParakeetEpochOutput, epoch: MeetingAnalysisEpochID, offset: Double) -> MeetingPCMTranscriptBatch {
        .init(segments: output.words.enumerated().map { index, word in
            .init(id: "\\(epoch.ordinal):\\(index)", text: word.word, start: offset + word.start, end: offset + word.end)
        })
    }
'''
start_validation = runtime.index('    static func validateStreamingSelection(')
end_validation = runtime.index('    /// Retain one prepared ASR', start_validation)
Path(sys.argv[2]).write_text('import Foundation\n' + runtime[start:end] +
    '\nfinal nonisolated class MeetingParakeetNemotronRuntime: Sendable {\n' + runtime[start_loop:end_loop] +
    runtime[start_validation:end_validation] + assembly + '\n}\n')
PY
swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
    -module-cache-path "$pichi_build/ModuleCache" \
    "$pichi_build/ActualPCMWindow.swift" "$pichi_build/ActualASRLoop.swift" \
    Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronRuntime.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingIncrementalNemotronDiarizerSession.swift \
    Sources/Fluid/Services/Meeting/MeetingStreamingPCMController.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPreparedStreamingRuntime.swift \
    Tests/MeetingPreparedStreamingRuntimeTests.swift -o "$pichi_build/tests"
"$pichi_build/tests"
