import Foundation

// A model-free typecheck of the actual prepared adapter plus the actual progressive ASR loop.
// ASR and speaker model witnesses record ownership and return synthetic timed words. Canonical
// assembly itself is covered by its existing actual-source word-attribution contract suite.
nonisolated struct ASRWordTiming: Sendable { let word: String; let start: Double; let end: Double }
nonisolated struct ASRSegmentTiming: Codable, Sendable {}
nonisolated struct ASRTranscriptionResult: Sendable { let text: String; var segmentTimings: [ASRSegmentTiming] = [] }
nonisolated struct MeetingAnalysisEpochID: Hashable, Sendable { let trackID: UUID; let ordinal: Int }
nonisolated struct MeetingBackendSpeakerToken: Hashable, Sendable { let analysisEpochID: MeetingAnalysisEpochID; let label: String }
nonisolated struct MeetingBackendSpeakerActivity: Sendable { let token: MeetingBackendSpeakerToken; let start: Double; let end: Double }
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {}
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {}
nonisolated struct MeetingOwnerVoiceProfileSnapshot: Sendable {}
nonisolated struct MeetingMaterializedSpanSamples: Sendable {}
nonisolated struct MeetingNemotronModelArtifact: Sendable {
    struct Profile: Sendable {
        enum Preference { case cpuOnly, devicePreferred }
        var isExperimental = true
        var computePreference = Preference.cpuOnly
    }
    var compiledModelURL: URL? = URL(fileURLWithPath: "/synthetic/model.mlmodelc")
    var profile = Profile()
    var implementationFingerprint = "synthetic-pinned-profile"
}
nonisolated struct MeetingFinalProcessingConfiguration: Sendable {
    enum Mode { case afterRecording, streaming }
    var speakerLabelsEnabled = true
    var speakerAttributionPolicy: Int? = 1
    var effectiveSpeakerProcessingMode = Mode.streaming
    var diarizationFingerprint = "synthetic-pinned-profile"
}
nonisolated struct MeetingSessionSpeaker: Sendable { let id: String }
nonisolated struct MeetingTranscriptSegment: Sendable {
    enum Completeness { case complete, incompleteTrack }
    let id: String; let text: String; let start: Double; let end: Double
    var completeness = Completeness.complete
}
nonisolated struct MeetingPCMTranscriptBatch: Sendable {
    var segments: [MeetingTranscriptSegment]
    var speakers: [MeetingSessionSpeaker] = []
    var isComplete = true
    func mergingSpeakers(into existing: [MeetingSessionSpeaker]) -> [MeetingSessionSpeaker] {
        existing + self.speakers.filter { candidate in !existing.contains { $0.id == candidate.id } }
    }
}
nonisolated enum MeetingPCMRecordingAttribution {
    static func assemble(transcript: MeetingPCMTranscriptBatch, activity: [MeetingBackendSpeakerActivity],
                         epoch: MeetingAnalysisEpochID, attemptID: UUID, duration: Double,
                         speakerNameFormat: String, speakerAttributionPolicy: Int?) throws -> MeetingPCMTranscriptBatch {
        guard activity.allSatisfy({ $0.token.analysisEpochID == epoch && $0.end <= duration }) else { throw FixtureFailure.assembly }
        return transcript
    }
}
typealias MeetingAudioTrackID = UUID
nonisolated enum MeetingModelResidencyError: Error { case unsupportedProvider, staleGrant }
nonisolated enum MeetingParakeetNemotronRuntimeError: Error { case invalidPCMWindow, concurrentPCMWindow }
nonisolated enum PichiLocalization { static func text(_ key: String) -> String { key } }
nonisolated final class DebugLogger: Sendable {
    static let shared = DebugLogger()
    func info(_ text: String, source: String) {}
}
private nonisolated enum FixtureFailure: Error { case assembly, observer, inference, invalid }
private nonisolated func require(_ condition: Bool, _ detail: String) throws {
    if !condition { throw NSError(domain: "PreparedStreaming", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
}
private nonisolated final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var observations: [MeetingStreamingPCMObservation] = []
    func event(_ event: String) { self.lock.withLock { self.events.append(event) } }
    func observation(_ observation: MeetingStreamingPCMObservation) { self.lock.withLock { self.observations.append(observation) } }
    var snapshot: [String] { self.lock.withLock { self.events } }
    var progress: [MeetingStreamingPCMObservation] { self.lock.withLock { self.observations } }
}
private nonisolated final class SyntheticASR: MeetingParakeetASRSession, Sendable {
    let recorder: Recorder
    let silence: Bool
    let fail: Bool
    init(_ recorder: Recorder, silence: Bool = false, fail: Bool = false) { self.recorder = recorder; self.silence = silence; self.fail = fail }
    func transcribeWithTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        self.recorder.event("asr:\(samples.count)")
        if self.fail { throw FixtureFailure.inference }
        return (.init(text: self.silence ? "" : "synthetic"), self.silence ? [] : [ASRWordTiming(word: "synthetic", start: 0, end: Double(samples.count) / 16_000)])
    }
}
private actor SyntheticDiarizer: MeetingIncrementalNemotronDiarizerSession {
    let recorder: Recorder
    private(set) var accepted = 0
    private var retained = 0
    let invalid: Bool
    init(_ recorder: Recorder, invalid: Bool = false) { self.recorder = recorder; self.invalid = invalid }
    func appendStreaming(_ samples: [Float], sourceStartSample: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        guard sourceStartSample == self.accepted else { throw FixtureFailure.invalid }
        self.recorder.event("dia:\(sourceStartSample):\(samples.count)")
        self.accepted += samples.count
        return self.update(final: false)
    }
    func finishStreaming(totalSamples: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        guard totalSamples == self.accepted else { throw FixtureFailure.invalid }
        self.recorder.event("finish:\(totalSamples)")
        return self.update(final: true)
    }
    func discardActivity(beforeSample: Int) async throws { self.retained = beforeSample; self.recorder.event("discard:\(beforeSample)") }
    func cleanupStreaming() async { self.recorder.event("cleanup") }
    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] { throw FixtureFailure.invalid }
    private func update(final: Bool) -> MeetingIncrementalDiarizationUpdate {
        let processed = self.invalid ? self.accepted + 1 : self.accepted
        let intervals: [MeetingNemotronSpeakerSegment] = self.accepted > self.retained
            ? [.init(slotIndex: 0, start: Double(self.retained) / 16_000, end: Double(self.accepted) / 16_000)] : []
        return .init(activity: intervals, acceptedThroughSample: self.accepted, processedThroughSample: processed,
                     retainedFromSample: self.retained, isFinal: final)
    }
}

@main struct MeetingPreparedStreamingRuntimeTests {
    private nonisolated static func make(_ recorder: Recorder, silence: Bool = false, fail: Bool = false, invalid: Bool = false,
                                refuseProgress: Bool = false) -> MeetingPreparedStreamingRuntime {
        MeetingPreparedStreamingRuntime(runtime: .init(), asr: SyntheticASR(recorder, silence: silence, fail: fail),
            diarizer: SyntheticDiarizer(recorder, invalid: invalid), trackID: UUID(), attemptID: UUID(),
            configuration: .init(), speakerNameFormat: "Speaker %lld", onProgress: {
                recorder.observation($0)
                recorder.event("progress:\($0.acceptedThroughSample)")
                if refuseProgress { throw FixtureFailure.observer }
            })
    }
    /// Runs the production prepared adapter and progressive ASR loop, with inert inference.
    /// Native recognition quality and the diarizer's 200 ms activity floor are separate tests.
    private static func shortAndEmptyFinalizationMatrix() async throws {
        let emptyRecorder = Recorder(), empty = make(emptyRecorder)
        let emptyFinal = try await empty.finishStreaming()
        try require(emptyFinal.isFinal && emptyFinal.acceptedThroughSample == 0
            && emptyFinal.processedThroughSample == 0 && emptyFinal.activity.isEmpty
            && emptyFinal.batch.segments.isEmpty, "No-input Stop finishes without inventing activity or words")
        try empty.requireFinished()
        await empty.cleanup()
        for frames in [1, 47, 48, 159, 160, 255, 400, 16_000, 48_000, 80_000, 320_000] {
            for silence in [false, true] {
                let recorder = Recorder(), runtime = make(recorder, silence: silence)
                let input = Array(repeating: Float(0), count: frames)
                let result = try await runtime.recognize(window: .fixture(samples: input, final: true), offset: 0, preview: nil)
                try require(result.acceptedThroughSample == frames && result.processedThroughSample == frames
                    && result.asrStableThroughSample == frames, "Short Stop dropped physical source samples: \(frames)")
                try require(result.batch.segments.isEmpty == silence, "Silence cannot manufacture timed words")
                let final = try await runtime.finishStreaming()
                try require(final.isFinal && final.acceptedThroughSample == frames
                    && final.asrStableThroughSample == frames, "Finish must preserve exact source length: \(frames)")
                try require(recorder.snapshot.filter { $0 == "finish:\(frames)" }.count == 1,
                            "Each short capture flushes its speaker tail exactly once")
                try runtime.requireFinished()
                await runtime.cleanup()
            }
        }
        print("PASS empty Stop and 22 short/full-window silence/speech adapter cases")
    }

    static func main() async throws {
        try await shortAndEmptyFinalizationMatrix()
        let r = Recorder(); let s = make(r)
        let w = MeetingPCMProgressiveWindow.fixture()
        let task = Task { try await s.recognize(window: w, offset: 0, preview: nil) }
        w.fixtureAppend([0, 0], final: false)
        while r.snapshot.count < 3 { await Task.yield() }
        w.fixtureAppend([0, 0, 0], final: true)
        let first = try await task.value
        try require(r.snapshot == ["dia:0:2", "progress:2", "asr:2", "dia:2:3", "progress:5", "asr:5"], "Each exact PCM delta must reach one persistent diarizer before its ASR prefix")
        try require(first.asrStableThroughSample == 5 && first.acceptedThroughSample == 5 && !first.isFinal,
                    "Sealed ASR source coverage is exact, independently of speaker finalization")
        try require(first.batch.segments.first?.id == "0:0" && first.batch.segments.first?.end == 5.0 / 16_000,
                    "Native word identity and time must leave the adapter unchanged")
        try require(r.progress.allSatisfy { $0.batch.segments.isEmpty && $0.asrStableThroughSample == nil },
                    "Progress callbacks contain no transcript and cannot advance the ASR watermark")
        try await s.discardActivity(beforeSample: 3)
        let second = try await s.recognize(window: .fixture(samples: [0, 0, 0], final: true), offset: 5.0 / 16_000, preview: nil)
        try require(second.batch.segments.first?.id == "5:0", "Different physical windows retain unique ASR-native word IDs")
        try require(second.activity.allSatisfy { $0.token.analysisEpochID.ordinal == 0 && $0.start == 3.0 / 16_000 }, "One global speaker epoch and acknowledged retained floor survive multiple windows")
        let final = try await s.finishStreaming(); try s.requireFinished()
        try require(final.isFinal && final.processedThroughSample == 8 && final.asrStableThroughSample == 8,
                    "Finish flushes the one physical tail and exposes the exact final watermark")
        do { _ = try await s.finishStreaming(); throw FixtureFailure.invalid } catch MeetingIncrementalDiarizationError.alreadyFinished {}
        await s.cleanup()
        do { _ = try await s.recognize(window: .fixture(), offset: 0, preview: nil); throw FixtureFailure.invalid } catch MeetingIncrementalDiarizationError.closed {}
        print("PASS contiguous deltas, stable IDs, metadata-only progress, retention and exactly-once flush")

        let silenceR = Recorder(); let silent = make(silenceR, silence: true)
        let silentResult = try await silent.recognize(window: .fixture(samples: [0, 0], final: true), offset: 0, preview: nil)
        try require(silentResult.batch.segments.isEmpty && silentResult.asrStableThroughSample == 2, "A sealed silence window advances ASR coverage without inventing words")
        _ = try await silent.finishStreaming(); await silent.cleanup()
        print("PASS sealed silence coverage")

        let gapR = Recorder(); let gap = make(gapR)
        do { _ = try await gap.recognize(window: .fixture(samples: [0], final: true), offset: 1, preview: nil); throw FixtureFailure.invalid }
        catch MeetingIncrementalDiarizationError.nonContiguousInput {}
        try require(gapR.snapshot.isEmpty, "A timeline gap must fail before native inference")
        await gap.cleanup()
        print("PASS timeline discontinuity refuses inference")

        let invalidR = Recorder(); let invalid = make(invalidR, invalid: true)
        do { _ = try await invalid.recognize(window: .fixture(samples: [0], final: true), offset: 0, preview: nil); throw FixtureFailure.invalid }
        catch MeetingIncrementalDiarizationError.invalidWatermark {}
        try require(invalidR.progress.isEmpty && !invalidR.snapshot.contains("asr:1"), "Invalid acoustic coverage cannot be published or sent onward as accepted speech")
        await invalid.cleanup()
        print("PASS invalid watermark fails closed")

        let refusedR = Recorder(); let refused = make(refusedR, refuseProgress: true)
        do { _ = try await refused.recognize(window: .fixture(samples: [0], final: true), offset: 0, preview: nil); throw FixtureFailure.invalid }
        catch FixtureFailure.observer {}
        try require(!refusedR.snapshot.contains("asr:1"), "A refused publication must not start subsequent ASR")
        await refused.cleanup()
        let failedR = Recorder(); let failed = make(failedR, fail: true)
        do { _ = try await failed.recognize(window: .fixture(samples: [0], final: true), offset: 0, preview: nil); throw FixtureFailure.invalid }
        catch FixtureFailure.inference {}
        do { try failed.requireFinished(); throw FixtureFailure.invalid } catch MeetingStreamingPCMControllerError.invalidScope {}
        await failed.cleanup()
        print("PASS progress and inference errors propagate without replay")

        let cancelledR = Recorder(); let cancelled = make(cancelledR)
        let waiting = Task { try await cancelled.recognize(window: .fixture(), offset: 0, preview: nil) }
        await Task.yield(); waiting.cancel()
        do { _ = try await waiting.value; throw FixtureFailure.invalid } catch is CancellationError {}
        await cancelled.cleanup()
        try require(cancelledR.snapshot == ["cleanup"], "Cancellation joins the blocked source before model cleanup")
        print("PASS blocked-source cancellation joins")

        let concurrentR = Recorder(); let concurrent = make(concurrentR)
        let blocked = MeetingPCMProgressiveWindow.fixture()
        let firstCall = Task { try await concurrent.recognize(window: blocked, offset: 0, preview: nil) }
        blocked.fixtureAppend([0], final: false)
        while concurrentR.snapshot.count < 3 { await Task.yield() }
        do { _ = try await concurrent.finishStreaming(); throw FixtureFailure.invalid }
        catch MeetingIncrementalDiarizationError.concurrentOperation {}
        firstCall.cancel(); do { _ = try await firstCall.value; throw FixtureFailure.invalid } catch is CancellationError {}
        await concurrent.cleanup()
        print("PASS concurrent command admission refuses overlapping native ownership")
        try MeetingParakeetNemotronRuntime.validateStreamingSelection(artifact: .init(), configuration: .init())
        for variant in 0..<6 {
            var artifact = MeetingNemotronModelArtifact()
            var configuration = MeetingFinalProcessingConfiguration()
            switch variant {
            case 0: artifact.compiledModelURL = nil
            case 1: artifact.profile.isExperimental = false
            case 2: artifact.profile.computePreference = .devicePreferred
            case 3: configuration.effectiveSpeakerProcessingMode = .afterRecording
            case 4: configuration.diarizationFingerprint = "changed-artifact"
            default: configuration.speakerLabelsEnabled = false
            }
            do {
                try MeetingParakeetNemotronRuntime.validateStreamingSelection(artifact: artifact, configuration: configuration)
                throw FixtureFailure.invalid
            } catch MeetingModelResidencyError.staleGrant {}
        }
        print("PASS pinned streaming profile admission refuses mismatched artifacts, policies and modes")
        print("9 prepared streaming runtime contract groups passed")
    }
}
