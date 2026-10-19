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
    nonisolated static func fixture(samples: [Float] = [], final: Bool = false,
        confidentlyNonSpeech: MeetingConfidentNonSpeechQuery? = nil) -> MeetingPCMProgressiveWindow {
        let window = MeetingPCMProgressiveWindow(initialFrames: 1, intervalFrames: 1,
                                                 confidentlyNonSpeech: confidentlyNonSpeech)
        window.fixtureAppend(samples, final: final)
        return window
    }
    nonisolated func fixtureAppend(_ samples: [Float], final: Bool) {
        if !samples.isEmpty { samples.withUnsafeBufferPointer { self.append($0, isFinal: final) } }
        else if final { self.seal() }
    }
}
'''
query = next(line for line in source.splitlines() if line.startswith('typealias MeetingConfidentNonSpeechQuery'))
Path(sys.argv[1]).write_text('import Foundation\n' + query + '\n' + source[start:end] + helper)
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
        var result = self.batch(output, epoch: epoch, offset: offset)
        result.speechObservationIsFinal = isFinal
        return result
    }
    func attributePCMSpeech(samples: [Float], output: MeetingParakeetEpochOutput, epoch: MeetingAnalysisEpochID,
        offset: Double, attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        priorProfiles: [MeetingSpeakerVoiceProfile], priorSpeakers: [MeetingSessionSpeaker]) async throws -> MeetingPCMTranscriptBatch {
        self.batch(output, epoch: epoch, offset: offset)
    }
    private func batch(_ output: MeetingParakeetEpochOutput, epoch: MeetingAnalysisEpochID, offset: Double) -> MeetingPCMTranscriptBatch {
        .init(segments: output.words.enumerated().map { index, word in
            .init(id: "\\(epoch.ordinal):\\(index)", text: word.text, start: offset + word.start, end: offset + word.end)
        }, speakers: output.words.isEmpty ? [] : [.init(id: "synthetic-speaker")])
    }
'''
start_scope = runtime.index('    private final nonisolated class StreamingOwnerEvidenceBox:')
start_prepared = runtime.index('    func withPreparedStreamingPCM(', start_scope)
end_prepared = runtime.index('    /// The strict privacy capture', start_prepared)
end_box = runtime.index('    /// Retain one prepared ASR', start_scope)
start_validation = runtime.index('    static func validateStreamingSelection(')
end_validation = runtime.index('    private final nonisolated class StreamingOwnerEvidenceBox:', start_validation)
matcher = Path('Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceMatcher.swift').read_text()
first_latest = matcher[matcher.rindex('extension MeetingSpeakerVoiceSamples {'):]
native_source = Path('Sources/Fluid/Services/Meeting/Backend/MeetingFast32NemotronDiarizer.swift').read_text()
native_intervals = native_source[native_source.index('nonisolated struct MeetingFast32SpeakerIntervals:'):]
checkpoint = Path('Sources/Fluid/Services/Meeting/Backend/MeetingResumableNemotronDiarizerSession.swift').read_text()
checkpoint_decoding = checkpoint[checkpoint.index('nonisolated enum MeetingDiarizerCheckpointDecoding {'):]
factory = Path('Sources/Fluid/Services/Meeting/PichiMeetingProviderFactory.swift').read_text()
start_preflight = factory.index('    static func prepareSpeakerResources(')
end_preflight = factory.index('    static func registerBackends', start_preflight)
preflight = '@MainActor enum PichiMeetingProviderFactory {\n' + factory[start_preflight:end_preflight] + '''
    static func modelLocator(for configuration: MeetingFinalProcessingConfiguration) throws -> StreamingSpeakerLocatorWitness {
        .init()
    }
}
'''
streamingWitnesses = r'''
    var ownerVoiceProfileSnapshot: MeetingOwnerVoiceProfileSnapshot? { self.scope == nil ? nil : .init() }
    var pcmIdentityState: StreamingPinWitness { .init() }
    var pcmSpeakerNameFormat: String { "Speaker %lld" }
    func takeIdleResources() -> MeetingIdleParakeetNemotronResources? {
        self.idleResources
    }
    func withPreparedASR(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        preparedProvider: MeetingASRPreparedProvider? = nil,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult) async throws -> MeetingParakeetPhaseResult {
        if preparedProvider != nil { self.scope?.event("asr-provider-adopted") }
        self.scope?.event("asr-scope-open")
        defer { self.scope?.event("asr-scope-closed") }
        return try await body(StreamingASRWitness())
    }
    func withNemotronDiarization(artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult) async throws -> MeetingNemotronPhaseResult {
        self.scope?.event("speaker-scope-open")
        defer { self.scope?.event("speaker-scope-closed") }
        return try await body(StreamingFactoryWitness())
    }
    func speakerVoiceProfiles(samples: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        self.scope?.event("voice-encode")
        self.scope?.recordClipFrames(samples.map { $0.clips.map(\.count) })
        guard let scope = self.scope else { return [] }
        if scope.failEncoder { throw StreamingScopeFailure.encoder }
        await scope.waitForEncoderRelease()
        return [.init()]
    }
'''
provider = Path('Sources/Fluid/Services/TranscriptionProvider.swift').read_text()
word_start = provider.index('nonisolated struct ASRWordTiming:')
word_end = provider.index('/// A provider', word_start)
scopeHelpers = runtime[start:end].replace('private final nonisolated class MeetingIdleParakeetNemotronResources',
    'final nonisolated class MeetingIdleParakeetNemotronResources')
Path(sys.argv[2]).write_text('import Foundation\n' + provider[word_start:word_end] + scopeHelpers + preflight +
    '\nfinal nonisolated class MeetingParakeetNemotronRuntime: Sendable {\n' +
    '    let scope: StreamingScopeFixture?\n    let idleResources: MeetingIdleParakeetNemotronResources?\n' +
    '    init(scope: StreamingScopeFixture? = nil, idleResources: MeetingIdleParakeetNemotronResources? = nil) { self.scope = scope; self.idleResources = idleResources }\n' +
    runtime[start_loop:end_loop] + runtime[start_scope:end_box] + runtime[start_prepared:end_prepared] +
    runtime[start_validation:end_validation] + assembly + streamingWitnesses + '\n}\n' + first_latest + native_intervals + checkpoint_decoding)
PY
swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
    -module-cache-path "$pichi_build/ModuleCache" \
    "$pichi_build/ActualPCMWindow.swift" "$pichi_build/ActualASRLoop.swift" \
    Sources/Fluid/Services/Meeting/MeetingTimelineTrace.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronRuntime.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingIncrementalNemotronDiarizerSession.swift \
    Sources/Fluid/Services/Meeting/MeetingStreamingPCMController.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPreparedStreamingRuntime.swift \
    Tests/MeetingPreparedStreamingRuntimeTests.swift -o "$pichi_build/tests"
"$pichi_build/tests"
