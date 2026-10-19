import Foundation

// A model-free typecheck of the actual prepared adapter plus the actual progressive ASR loop.
// ASR and speaker model witnesses record ownership and return synthetic timed words. Canonical
// assembly itself is covered by its existing actual-source word-attribution contract suite.
nonisolated struct ASRWordTiming: Sendable { let word: String; let start: Double; let end: Double }
nonisolated struct ASRSegmentTiming: Codable, Sendable {}
nonisolated struct ASRTranscriptionResult: Sendable { let text: String; var confidence: Double = 0; var segmentTimings: [ASRSegmentTiming] = [] }
nonisolated struct MeetingAnalysisEpochID: Hashable, Sendable { let trackID: UUID; let ordinal: Int }
nonisolated struct MeetingBackendSpeakerToken: Hashable, Sendable { let analysisEpochID: MeetingAnalysisEpochID; let label: String }
nonisolated struct MeetingBackendSpeakerActivity: Sendable { let token: MeetingBackendSpeakerToken; let start: Double; let end: Double }
nonisolated struct MeetingSpeakerVoiceSamples: Sendable { let token: MeetingBackendSpeakerToken; let clips: [[Float]] }
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {}
nonisolated struct MeetingOwnerVoiceProfileSnapshot: Sendable {}
nonisolated struct MeetingMaterializedSpanSamples: Sendable {}
nonisolated struct MeetingNemotronModelArtifact: Sendable {
    struct Profile: Sendable {
        enum Preference { case cpuOnly, devicePreferred }
        var streamingImplementationFingerprint = "synthetic-pinned-profile"
        func acceptsStreamingImplementationFingerprint(_ value: String) -> Bool {
            value == self.streamingImplementationFingerprint || value == "synthetic-legacy-anonymous" || value == "synthetic-owner-v1"
        }
        func verifiesStreamingOwner(implementationFingerprint value: String) -> Bool {
            value == self.streamingImplementationFingerprint || value == "synthetic-owner-v1"
        }
        func usesAdaptiveStreamingOwnerEvidence(implementationFingerprint value: String) -> Bool {
            value == self.streamingImplementationFingerprint
        }
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
    var identityFingerprint: String { self.diarizationFingerprint }
}
nonisolated struct MeetingSessionSpeaker: Sendable { let id: String; var isLocalUser = false }
nonisolated struct MeetingTranscriptSegment: Sendable {
    enum Completeness { case complete, incompleteTrack }
    let id: String; let text: String; let start: Double; let end: Double
    var completeness = Completeness.complete
}
nonisolated struct MeetingPCMTranscriptBatch: Sendable {
    var segments: [MeetingTranscriptSegment]
    var speakers: [MeetingSessionSpeaker] = []
    var isComplete = true
    var speechObservationIsFinal = true
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
nonisolated enum MeetingProviderOptions {
    static func resolve(_ configuration: MeetingFinalProcessingConfiguration) throws -> Int { 0 }
}
nonisolated enum MeetingModelResidencyError: Error { case unsupportedProvider, staleGrant }
nonisolated enum MeetingParakeetNemotronRuntimeError: Error { case invalidPCMWindow, concurrentPCMWindow }
nonisolated enum PichiLocalization { static func text(_ key: String) -> String { key } }
nonisolated final class DebugLogger: Sendable {
    static let shared = DebugLogger()
    func info(_ text: String, source: String) {}
}
nonisolated enum MeetingTranscriptAssembler {
    static func applyingLocalUserTokens(to speakers: [MeetingSessionSpeaker], attemptID: UUID,
                                       tokens: Set<MeetingBackendSpeakerToken>) -> [MeetingSessionSpeaker] {
        speakers.map { source in var result = source; result.isLocalUser = !tokens.isEmpty; return result }
    }
}
nonisolated enum MeetingOwnerVoiceVerifier {
    enum Policy: Sendable { case legacy, streamingV2 }
    struct Diagnostics: Sendable {}
    static func confirmedTokens(owner: MeetingOwnerVoiceProfileSnapshot?, profiles: [MeetingSpeakerVoiceProfile], policy: Policy = .legacy,
        diagnostics: ((Diagnostics) -> Void)? = nil) -> Set<MeetingBackendSpeakerToken> {
        profiles.isEmpty ? [] : [.init(analysisEpochID: .init(trackID: UUID(), ordinal: 0), label: "slot-0")]
    }
}
nonisolated enum MeetingPCMRuntimeDiagnostics {
    static func ownerVerificationObserver(samples: [MeetingSpeakerVoiceSamples], profiles: [MeetingSpeakerVoiceProfile],
        streaming: Bool) -> ((MeetingOwnerVoiceVerifier.Diagnostics) -> Void)? { nil }
}
nonisolated enum StreamingScopeFailure: Error { case encoder }
nonisolated final class StreamingScopeFixture: @unchecked Sendable {
    let failEncoder: Bool
    let blockEncoder: Bool
    private var encoderReleased = false
    private var encoderWaiter: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var events: [String] = []
    private var encoded: [[Int]] = []
    func recordClipFrames(_ frames: [[Int]]) { self.lock.withLock { self.encoded = frames } }
    var encodedClipFrames: [[Int]] { self.lock.withLock { self.encoded } }
    init(failEncoder: Bool = false, blockEncoder: Bool = false) {
        self.failEncoder = failEncoder; self.blockEncoder = blockEncoder
    }
    func waitForEncoderRelease() async {
        guard self.blockEncoder else { return }
        await withCheckedContinuation { continuation in
            let ready = self.lock.withLock {
                if self.encoderReleased { return true }
                self.encoderWaiter = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func releaseEncoder() {
        let waiter = self.lock.withLock {
            self.encoderReleased = true
            let value = self.encoderWaiter; self.encoderWaiter = nil; return value
        }
        waiter?.resume()
    }
    func event(_ value: String) { self.lock.withLock { self.events.append(value) } }
    var snapshot: [String] { self.lock.withLock { self.events } }
}
nonisolated enum MeetingDiarizationDependency: Hashable { case speakerSeparation, voiceMatching }
nonisolated struct StreamingSpeakerLocatorWitness { let profile = 0; let supportsOwnerVoiceVerification = true }
@MainActor final class MeetingDiarizationModelStore {
    static let witness = MeetingDiarizationModelStore()
    var requests: [Set<MeetingDiarizationDependency>] = []
    static func shared(for profile: Int) -> MeetingDiarizationModelStore { self.witness }
    func prepare(dependencies: Set<MeetingDiarizationDependency>) async throws {
        self.requests.append(dependencies)
        if dependencies.contains(.voiceMatching) { throw StreamingScopeFailure.encoder }
    }
}
nonisolated struct StreamingPinWitness: Sendable {
    func pinnedArtifact(attemptID: UUID, configuration: String) throws -> MeetingNemotronModelArtifact? { .init() }
    func begin(attemptID: UUID) throws {}
    func end() {}
}
nonisolated struct StreamingASRWitness: MeetingParakeetASRSession {
    func transcribeWithTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        (.init(text: "synthetic"), [.init(word: "synthetic", start: 0, end: Double(samples.count) / 16_000)])
    }
}
nonisolated struct StreamingFactoryWitness: MeetingNemotronDiarizerFactory {
    func makeDiarizer(epoch: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
        SyntheticDiarizer(Recorder())
    }
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

private actor LifecycleASR: MeetingParakeetASRSession {
    let recorder: Recorder
    let decisions: [Bool]
    let gate: StreamingScopeFixture?
    private(set) var capabilityChecks = 0
    init(_ recorder: Recorder, decisions: [Bool], gate: StreamingScopeFixture? = nil) {
        self.recorder = recorder; self.decisions = decisions; self.gate = gate
    }
    func allowsIntermediatePCMObservations() async -> Bool {
        let index = min(self.capabilityChecks, self.decisions.count - 1)
        self.capabilityChecks += 1
        return self.decisions[index]
    }
    func transcribeWithTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        self.recorder.event("asr:\(samples.count)")
        if let gate { await gate.waitForEncoderRelease() }
        return (.init(text: "synthetic"), [.init(word: "synthetic", start: 0, end: Double(samples.count) / 16_000)])
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

private nonisolated final class OwnerReplayFixture: MeetingPCMReplaySource, @unchecked Sendable {
    let totalSampleCount: Int
    let ranges: [Range<Int>]
    let changesAt: Int?
    let clipped: [Range<Int>]
    let overlaps: [Range<Int>]
    let failAfterReads: Int?
    let cancelRead: Bool
    private let lock = NSLock()
    private var reads: [Range<Int>] = []
    init(frames: Int, ranges: [Range<Int>] = [], changesAt: Int? = nil, clipped: [Range<Int>] = [],
         overlaps: [Range<Int>] = [], failAfterReads: Int? = nil, cancelRead: Bool = false) {
        self.totalSampleCount = frames; self.ranges = ranges; self.changesAt = changesAt; self.clipped = clipped
        self.overlaps = overlaps; self.failAfterReads = failAfterReads; self.cancelRead = cancelRead
    }
    func signal(_ range: Range<Int>) -> [Float] {
        range.map { index in
            if self.clipped.contains(where: { $0.contains(index) }) { return 1 }
            if self.overlaps.contains(where: { $0.contains(index) }) { return 0.9 }
            if !self.ranges.isEmpty, !self.ranges.contains(where: { $0.contains(index) }) { return 0 }
            let offset: Float = self.changesAt.map { index < $0 ? 0.2 : -0.2 } ?? 0
            return offset + 0.1 * Float(sin(Double(index) * 0.031))
        }
    }
    func readSamples(in range: Range<Int>) async throws -> [Float] {
        guard range.lowerBound >= 0, range.upperBound <= self.totalSampleCount else { throw FixtureFailure.invalid }
        let count = self.lock.withLock { self.reads.append(range); return self.reads.count }
        if self.cancelRead { throw CancellationError() }
        if let failAfterReads, count > failAfterReads { throw FixtureFailure.invalid }
        return self.signal(range)
    }
    var requests: [Range<Int>] { self.lock.withLock { self.reads } }
}

private actor NativeBoundaryOwnerDiarizer: MeetingIncrementalNemotronDiarizerSession {
    private var accepted = 0
    private var scoredFrames = 0
    private var retained = 0
    private var intervals = MeetingFast32SpeakerIntervals(speakerCount: 8)
    func appendStreaming(_ samples: [Float], sourceStartSample: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        guard sourceStartSample == accepted else { throw FixtureFailure.invalid }
        accepted += samples.count
        return try update(final: false)
    }
    func finishStreaming(totalSamples: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        guard totalSamples == accepted else { throw FixtureFailure.invalid }
        return try update(final: true)
    }
    func discardActivity(beforeSample: Int) async throws {
        guard beforeSample >= retained else { throw FixtureFailure.invalid }
        retained = beforeSample
        intervals.discard(beforeFrame: beforeSample / 160)
    }
    func cleanupStreaming() async {}
    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] { throw FixtureFailure.invalid }
    private func update(final: Bool) throws -> MeetingIncrementalDiarizationUpdate {
        let frames = final ? accepted / 160 : accepted / 163_840 * 1_024
        let probabilities = (scoredFrames..<frames).flatMap { frame in (0..<8).map { slot -> Float in
            slot == 0 || (slot == 1 && (1_005..<1_060).contains(frame)) ? 0.9 : 0.1
        } }
        try intervals.append(probabilities: probabilities, frameCount: frames - scoredFrames)
        scoredFrames = frames
        let duration = Double(frames) / 100
        if final { _ = intervals.finish(duration: duration) }
        return .init(activity: intervals.snapshot(duration: duration, startingAt: Double(retained) / 16_000),
            acceptedThroughSample: accepted, processedThroughSample: frames * 160,
            retainedFromSample: retained, isFinal: final)
    }
}

private actor LaggedOwnerDiarizer: MeetingIncrementalNemotronDiarizerSession {
    private var accepted = 0
    let voice = 12.0..<19.0
    func appendStreaming(_ samples: [Float], sourceStartSample: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        guard sourceStartSample == accepted, samples.count <= 16_000 else { throw FixtureFailure.invalid }
        accepted += samples.count
        return update(final: false)
    }
    func finishStreaming(totalSamples: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        guard totalSamples == accepted else { throw FixtureFailure.invalid }
        return update(final: true)
    }
    func discardActivity(beforeSample: Int) async throws {}
    func cleanupStreaming() async {}
    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] { throw FixtureFailure.invalid }
    private func update(final: Bool) -> MeetingIncrementalDiarizationUpdate {
        let processed = final ? accepted : accepted / 163_840 * 163_840
        let end = min(voice.upperBound, Double(processed) / 16_000)
        let rows: [MeetingNemotronSpeakerSegment] = end > voice.lowerBound
            ? [.init(slotIndex: 0, start: voice.lowerBound, end: end)] : []
        return .init(activity: rows, acceptedThroughSample: accepted, processedThroughSample: processed,
            retainedFromSample: 0, isFinal: final)
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
                try require(result.sealedEmptyASRRange == (silence ? 0..<frames : nil),
                    "Only a complete sealed empty decoder result can declare the exact source interval")
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
        try await lifecyclePreviewAdmission()
        try await streamingPreviewDoesNotRepeatSealedPrivacy()
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
        try require(r.progress.allSatisfy { $0.batch.segments.isEmpty && $0.asrStableThroughSample == nil && $0.sealedEmptyASRRange == nil },
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
        try ownerEvidenceBoundsAndQuality()
        try await adaptiveOwnerEvidence()
        try await ownerScopeRetiresModelsBeforeEncoder()
        try await optionalOwnerPreflightAndCancellation()
        print("15 prepared streaming runtime contract groups passed")
    }

    private static func streamingPreviewDoesNotRepeatSealedPrivacy() async throws {
        for emptyFinal in [false, true] {
            let recorder = Recorder(), asr = LifecycleASR(recorder, decisions: [true])
            let runtime = MeetingPreparedStreamingRuntime(runtime: .init(), asr: asr,
                diarizer: SyntheticDiarizer(recorder), trackID: UUID(), attemptID: UUID(),
                configuration: .init(), speakerNameFormat: "Speaker %lld", onProgress: { _ in })
            let window = MeetingPCMProgressiveWindow.fixture()
            let operation = Task {
                try await runtime.recognize(window: window, offset: 0, preview: { batch in
                    try require(!batch.speechObservationIsFinal,
                        "The streaming adapter must not repeat final-window privacy as a preview")
                    recorder.event("preview-privacy:\(batch.segments.first?.end ?? -1)")
                })
            }
            for (index, frames) in [48_000, 160_000, 112_000].enumerated() {
                window.fixtureAppend(Array(repeating: Float(0.1), count: frames),
                                     final: index == 2 && !emptyFinal)
                for _ in 0..<10_000 {
                    if recorder.snapshot.filter({ $0.hasPrefix("asr:") }).count >= index + 1 { break }
                    await Task.yield()
                }
                try require(recorder.snapshot.filter { $0.hasPrefix("asr:") }.count >= index + 1,
                            "Each growing source update must still reach ASR")
                if index < 2 || emptyFinal {
                    for _ in 0..<10_000 {
                        if recorder.snapshot.filter({ $0.hasPrefix("preview-privacy:") }).count >= index + 1 { break }
                        await Task.yield()
                    }
                    try require(recorder.snapshot.filter { $0.hasPrefix("preview-privacy:") }.count == index + 1,
                                "Genuinely growing observations retain the protected preview gate")
                }
            }
            if emptyFinal { window.fixtureAppend([], final: true) }
            let result = try await operation.value
            let expected = ["preview-privacy:3.0", "preview-privacy:13.0"]
                + (emptyFinal ? ["preview-privacy:20.0"] : [])
            try require(recorder.snapshot.filter { $0.hasPrefix("preview-privacy:") } == expected,
                "Only nonfinal growing observations may run preview privacy")
            try require(result.batch.segments.map(\.text) == ["synthetic"]
                && result.batch.segments.first?.end == 20
                && result.asrStableThroughSample == 320_000,
                "The complete native final text and timing still reach the canonical privacy owner")
            let final = try await runtime.finishStreaming()
            try require(final.isFinal && final.asrStableThroughSample == 320_000,
                        "Stop must flush the exact final source cursor without a preview")
            await runtime.cleanup()
        }
        print("PASS growing protected previews, no duplicate sealed privacy, final native words and Stop coverage")
    }

    private static func lifecyclePreviewAdmission() async throws {
        // The production loop sees each boundary separately, including a no-PCM final seal.
        for (decisions, emptyFinal, expected) in [
            ([false], false, [320_000]),
            ([true], false, [48_000, 208_000, 320_000]),
            ([false, false, false, true], true, [320_000]),
            ([true, true, false, true], true, [48_000, 208_000, 320_000]),
            ([true], true, [48_000, 208_000, 320_000])
        ] {
            let recorder = Recorder(), asr = LifecycleASR(recorder, decisions: decisions)
            let window = MeetingPCMProgressiveWindow.fixture()
            let operation = Task {
                try await MeetingParakeetNemotronRuntime().recognizeProgressivePCMPhase(
                    session: asr, window: window, offset: 0,
                    epoch: .init(trackID: UUID(), ordinal: 0), attemptID: UUID(),
                    timing: .init(), permitsIntermediateObservations: true,
                    preview: { batch in recorder.event("preview:\(batch.segments.first?.end ?? -1)") },
                    consumePCM: { samples, start in
                        let expectedValue: Float = start == 0 ? 0.1 : start == 48_000 ? 0.2 : 0.3
                        try require(samples.allSatisfy { $0 == expectedValue }, "PCM deltas preserve distinct source values")
                        recorder.event("pcm:\(start):\(samples.count)")
                    })
            }
            for (index, delta) in [48_000, 160_000, 112_000].enumerated() {
                window.fixtureAppend(Array(repeating: Float(index + 1) / 10, count: delta),
                                     final: index == 2 && !emptyFinal)
                for _ in 0..<10_000 {
                    if await asr.capabilityChecks >= index + 1 { break }
                    await Task.yield()
                }
                try require(await asr.capabilityChecks >= index + 1, "Each PCM boundary must reach the dynamic capability")
            }
            if emptyFinal { window.fixtureAppend([], final: true) }
            let result = try await operation.value
            let calls = recorder.snapshot.filter { $0.hasPrefix("asr:") }
            try require(calls == expected.map { "asr:\($0)" }, "Optional prefixes and full-window final inference must follow lifecycle capability: \(calls)")
            let previews = recorder.snapshot.filter { $0.hasPrefix("preview:") }
            if decisions.first == true {
                try require(previews.prefix(2) == ["preview:3.0", "preview:13.0"],
                            "Foreground capability must retain growing-prefix observations")
            } else {
                try require(previews == ["preview:20.0"], "Suppressed prefixes publish only the canonical whole window")
            }
            try require(result.outputs.first?.sampleCount == 320_000 && result.boundedPCMSourceSampleCount == 320_000,
                        "A lifecycle transition cannot accept a stale 13-second prefix as the complete 20-second window")
            try require(recorder.snapshot.filter { $0.hasPrefix("pcm:") } ==
                ["pcm:0:48000", "pcm:48000:160000", "pcm:208000:112000"],
                "Every delta reaches the speaker consumer exactly once despite skipped preview inference")
        }

        let recorder = Recorder(), gate = StreamingScopeFixture(blockEncoder: true)
        let asr = LifecycleASR(recorder, decisions: [false], gate: gate)
        let operation = Task {
            defer { recorder.event("scope-closed") }
            return try await MeetingParakeetNemotronRuntime().recognizeProgressivePCMPhase(
                session: asr, window: .fixture(samples: [0.1], final: true), offset: 0,
                epoch: .init(trackID: UUID(), ordinal: 0), attemptID: UUID(),
                timing: .init(), permitsIntermediateObservations: true,
                preview: { _ in recorder.event("unexpected-preview") })
        }
        for _ in 0..<10_000 {
            if recorder.snapshot.contains("asr:1") { break }
            await Task.yield()
        }
        try require(recorder.snapshot.contains("asr:1"), "The noncooperative synthetic native inference must start")
        operation.cancel()
        for _ in 0..<20 { await Task.yield() }
        try require(!recorder.snapshot.contains("scope-closed"), "Cancellation cannot retire an in-flight ASR session")
        gate.releaseEncoder()
        do { _ = try await operation.value; throw FixtureFailure.invalid } catch is CancellationError {}
        try require(recorder.snapshot.contains("scope-closed") && !recorder.snapshot.contains("unexpected-preview"),
                    "Joined cancellation must prevent speculative publication")
        print("PASS lifecycle preview admission, exact PCM deltas, full-window final seals and joined native cancellation")
    }
    private nonisolated static func adaptiveOwnerEvidence() async throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        for frames in [95_999, 96_000, 101_119, 101_120, 128_000, 192_000, 320_000] {
            let source = OwnerReplayFixture(frames: frames)
            let activity = [MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0, end: Double(frames) / 16_000)]
            var collector = MeetingStreamingOwnerVoiceSamples(epoch: epoch, useAdaptiveOwnerEvidence: true)
            for start in stride(from: 0, to: frames, by: 16_000) {
                let end = min(frames, start + 16_000)
                collector.append(source.signal(start..<end), sourceStartSample: start)
                collector.collect(activity: [.init(slotIndex: 0, start: 0, end: Double(end) / 16_000)], processedThroughSample: end)
                try require(collector.retainedPCMFrames <= MeetingStreamingOwnerVoiceSamples.maximumAdaptivePCMFrames, "V2 acoustic lookback is fixed")
                try require(collector.retainedVoiceFrames <= MeetingStreamingOwnerVoiceSamples.maximumAdaptiveVoiceFrames, "V2 per-slot evidence and pending quality blocks are bounded")
            }
            collector.collect(activity: activity, processedThroughSample: frames, final: true)
            let live = collector.takeExcerpts()
            let retained = try await MeetingSpeakerVoiceSamples.collectFirstAndLatest(epoch: epoch, source: source, segments: activity)
            try require(live.map(\.clips) == retained.map(\.clips), "Live and retained V2 select byte-identical bounded evidence")
            if frames < 101_120 { try require(live.isEmpty, "Fewer than six usable seconds cannot establish owner identity") }
            else {
                try require(live.count == 1 && live[0].clips.count == 2, "Six usable seconds provide two disjoint excerpts")
                try require(live[0].clips.allSatisfy { (48_000...80_000).contains($0.count) }, "V2 adapts clip length from3s through5s")
            }
            try require(source.requests.allSatisfy { $0.count <= 16_000 }, "Retained verification reads only bounded buffers")
        }
        let changed = OwnerReplayFixture(frames: 320_000, changesAt: 160_000)
        var reuse = MeetingStreamingOwnerVoiceSamples(epoch: epoch, useAdaptiveOwnerEvidence: true)
        for start in stride(from: 0, to: 320_000, by: 16_000) {
            reuse.append(changed.signal(start..<(start + 16_000)), sourceStartSample: start)
            reuse.collect(activity: [.init(slotIndex: 0, start: 0, end: Double(start + 16_000) / 16_000)], processedThroughSample: start + 16_000)
        }
        reuse.collect(activity: [.init(slotIndex: 0, start: 0, end: 20)], processedThroughSample: 320_000, final: true)
        let reuseClips = reuse.takeExcerpts()[0].clips
        try require(reuseClips[0].allSatisfy { $0 > 0 } && reuseClips[1].allSatisfy { $0 < 0 },
                    "Later voice evidence replaces the old second clip, exposing slot reuse to the identity verifier")

        let qualitySource = OwnerReplayFixture(frames: 30 * 16_000,
            clipped: [0..<6 * 16_000, 24 * 16_000..<30 * 16_000])
        var quality = MeetingStreamingOwnerVoiceSamples(epoch: epoch, useAdaptiveOwnerEvidence: true)
        for start in stride(from: 0, to: 30 * 16_000, by: 16_000) {
            quality.append(qualitySource.signal(start..<(start + 16_000)), sourceStartSample: start)
            quality.collect(activity: [.init(slotIndex: 0, start: 0, end: Double(start + 16_000) / 16_000)], processedThroughSample: start + 16_000)
        }
        quality.collect(activity: [.init(slotIndex: 0, start: 0, end: 30)], processedThroughSample: 480_000, final: true)
        let usable = quality.takeExcerpts()
        let restoredQuality = try await MeetingSpeakerVoiceSamples.collectFirstAndLatest(epoch: epoch, source: qualitySource,
            segments: [.init(slotIndex: 0, start: 0, end: 30)])
        try require(usable.count == 1 && usable[0].clips.flatMap { $0 }.allSatisfy { abs($0) < 0.99 },
                    "Clipped early/trailing native voice cannot poison usable first/latest evidence")
        try require(usable.map(\.clips) == restoredQuality.map(\.clips), "Retained V2 applies the same signal quality recovery")

        var overlap = MeetingStreamingOwnerVoiceSamples(epoch: epoch, useAdaptiveOwnerEvidence: true)
        for start in stride(from: 0, to: 12 * 16_000, by: 16_000) {
            var audio = changed.signal(start..<(start + 16_000))
            for index in audio.indices where (3 * 16_000..<5 * 16_000).contains(start + index) { audio[index] = 0.9 }
            overlap.append(audio, sourceStartSample: start)
            let through = Double(start + 16_000) / 16_000
            var intervals = [MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0, end: through)]
            if through > 3 { intervals.append(.init(slotIndex: 1, start: 3, end: min(5, through))) }
            overlap.collect(activity: intervals, processedThroughSample: start + 16_000)
        }
        overlap.collect(activity: [.init(slotIndex: 0, start: 0, end: 12), .init(slotIndex: 1, start: 3, end: 5)],
            processedThroughSample: 192_000, final: true)
        let overlapSamples = overlap.takeExcerpts()
        try require(overlapSamples.count == 1 && overlapSamples[0].clips.flatMap { $0 }.allSatisfy { abs($0) < 0.5 },
                    "V2 excludes simultaneous voices and padded overlap edges before query admission")

        // Actual native interval admission with a second voice only190ms old at the
        // fast128 boundary. It is absent from the first snapshot, then backdates its start.
        let boundarySource = OwnerReplayFixture(frames: 192_000, overlaps: [160_800..<169_600])
        var native = MeetingFast32SpeakerIntervals(speakerCount: 8)
        func probabilities(_ frames: Range<Int>) -> [Float] {
            frames.flatMap { frame in (0..<8).map { slot -> Float in
                slot == 0 || (slot == 1 && (1_005..<1_060).contains(frame)) ? 0.9 : 0.1
            } }
        }
        var boundary = MeetingStreamingOwnerVoiceSamples(epoch: epoch, useAdaptiveOwnerEvidence: true)
        boundary.append(boundarySource.signal(0..<163_840), sourceStartSample: 0)
        try native.append(probabilities: probabilities(0..<1_024), frameCount: 1_024)
        let early = native.snapshot(duration: 10.24)
        try require(early.count == 1, "The actual native builder withholds the secondary voice until200ms")
        boundary.collect(activity: early, processedThroughSample: 163_840)
        boundary.append(boundarySource.signal(163_840..<192_000), sourceStartSample: 163_840)
        try native.append(probabilities: probabilities(1_024..<1_200), frameCount: 176)
        let finishedActivity = native.finish(duration: 12)
        boundary.collect(activity: finishedActivity, processedThroughSample: 192_000, final: true)
        let boundaryLive = boundary.takeExcerpts()
        let boundaryRetained = try await MeetingSpeakerVoiceSamples.collectFirstAndLatest(epoch: epoch,
            source: boundarySource, segments: finishedActivity)
        try require(boundaryLive.count == 1 && boundaryLive.map(\.clips) == boundaryRetained.map(\.clips),
                    "Late native admission cannot contaminate or change final live versus retained evidence")
        try require(boundaryLive[0].clips.flatMap { $0 }.allSatisfy { abs($0) < 0.5 },
                    "A secondary voice crossing the scoring boundary is excluded with its padded edges")

        // A no-text policy can acknowledge the complete acoustic cursor. The actual
        // adapter must retain owner-required activity even without transcript preroll.
        let admissionSession = MeetingPreparedStreamingRuntime(runtime: .init(), asr: SyntheticASR(Recorder()),
            diarizer: NativeBoundaryOwnerDiarizer(), trackID: epoch.trackID, attemptID: UUID(),
            configuration: .init(), speakerNameFormat: "Speaker %lld", collectOwnerEvidence: true,
            useAdaptiveOwnerEvidence: true, onProgress: { _ in })
        _ = try await admissionSession.recognize(window: .fixture(samples: boundarySource.signal(0..<176_000), final: true),
            offset: 0, preview: nil)
        try await admissionSession.discardActivity(beforeSample: 163_840)
        _ = try await admissionSession.recognize(window: .fixture(samples: boundarySource.signal(176_000..<192_000), final: true),
            offset: 11, preview: nil)
        _ = try await admissionSession.finishStreaming()
        let admissionLive = try admissionSession.ownerEvidence()?.samples ?? []
        try require(admissionLive.map(\.clips) == boundaryRetained.map(\.clips),
                    "Discard through the processed cursor cannot evict provisional owner activity or shift turn edges")
        await admissionSession.cleanup()

        for after in [0, 7] {
            let failedSource = OwnerReplayFixture(frames: 192_000, failAfterReads: after)
            let result = try await MeetingSpeakerVoiceSamples.collectFirstAndLatest(epoch: epoch, source: failedSource,
                segments: [.init(slotIndex: 0, start: 0, end: 12)])
            try require(result.isEmpty, "An optional owner reread failure discards all identity evidence without failing the transcript")
        }
        do {
            _ = try await MeetingSpeakerVoiceSamples.collectFirstAndLatest(epoch: epoch,
                source: OwnerReplayFixture(frames: 192_000, cancelRead: true),
                segments: [.init(slotIndex: 0, start: 0, end: 12)])
            throw FixtureFailure.invalid
        } catch is CancellationError {}

        var allSlots = MeetingStreamingOwnerVoiceSamples(epoch: epoch, useAdaptiveOwnerEvidence: true)
        let rows = (0..<8).map { MeetingNemotronSpeakerSegment(slotIndex: $0, start: Double($0 * 12), end: Double(($0 + 1) * 12)) }
        var maximumStored = 0
        for start in stride(from: 0, to: 96 * 16_000, by: 16_000) {
            allSlots.append(changed.signal(start..<(start + 16_000)), sourceStartSample: start)
            let through = Double(start + 16_000) / 16_000
            allSlots.collect(activity: rows.compactMap { row in
                let end = min(row.end, through)
                return end > row.start ? .init(slotIndex: row.slotIndex, start: row.start, end: end) : nil
            }, processedThroughSample: start + 16_000)
            maximumStored = max(maximumStored, allSlots.retainedVoiceFrames + allSlots.retainedPCMFrames)
        }
        let beforeSilence = allSlots.excerpts.map(\.clips)
        for second in 96..<(96 + 3_600) {
            let start = second * 16_000
            allSlots.append([Float](repeating: 0, count: 16_000), sourceStartSample: start)
            allSlots.collect(activity: [], processedThroughSample: start + 16_000)
            maximumStored = max(maximumStored, allSlots.retainedVoiceFrames + allSlots.retainedPCMFrames)
        }
        try require(allSlots.excerpts.map(\.clips) == beforeSilence && beforeSilence.count == 8,
                    "An hour of silence preserves all eight voices without replacing usable evidence")
        try require(maximumStored <= 1_600_000, "V2 retains at most6.4MB of sample elements across all eight slots")
        _ = allSlots.takeExcerpts()

        let lag = LaggedOwnerDiarizer()
        let session = MeetingPreparedStreamingRuntime(runtime: .init(), asr: SyntheticASR(Recorder()), diarizer: lag,
            trackID: epoch.trackID, attemptID: UUID(), configuration: .init(), speakerNameFormat: "Speaker %lld",
            collectOwnerEvidence: true, useAdaptiveOwnerEvidence: true, onProgress: { _ in })
        let source = OwnerReplayFixture(frames: 40 * 16_000, ranges: [12 * 16_000..<19 * 16_000])
        _ = try await session.recognize(window: .fixture(samples: source.signal(0..<320_000), final: true), offset: 0, preview: nil)
        _ = try await session.recognize(window: .fixture(samples: source.signal(320_000..<640_000), final: true), offset: 20, preview: nil)
        _ = try await session.finishStreaming()
        let live = try session.ownerEvidence()?.samples ?? []
        let retained = try await MeetingSpeakerVoiceSamples.collectFirstAndLatest(epoch: epoch, source: source,
            segments: [.init(slotIndex: 0, start: 12, end: 19)])
        try require(live.count == 1 && live.map(\.clips) == retained.map(\.clips),
                    "Twenty-second coalescing plus10.24s scoring lag cannot lose a later seven-second voice before silence")
        await session.cleanup()
        print("PASS V2 balanced first/latest evidence, retained/live parity, quality recovery, reuse and real acoustic lag")
    }

    private nonisolated static func ownerScopeRetiresModelsBeforeEncoder() async throws {
        for (failEncoder, legacyAnonymous, ownerV1) in [(false, false, false), (true, false, false), (false, true, false), (false, false, true)] {
            let scope = StreamingScopeFixture(failEncoder: failEncoder)
            var configuration = MeetingFinalProcessingConfiguration()
            if legacyAnonymous { configuration.diarizationFingerprint = "synthetic-legacy-anonymous" }
            if ownerV1 { configuration.diarizationFingerprint = "synthetic-owner-v1" }
            let frozenConfiguration = configuration
            let runtime = MeetingParakeetNemotronRuntime(scope: scope)
            let controller = MeetingStreamingPCMController.deferred { body in
                try await runtime.withPreparedStreamingPCM(trackID: UUID(), attemptID: UUID(), configuration: frozenConfiguration,
                    onProgress: { value in
                        if !value.batch.speakers.isEmpty {
                            try require(value.batch.segments.isEmpty, "Owner publication must never replace protected words")
                            try require(value.batch.speakers.allSatisfy(\.isLocalUser), "Only verified owner identities are promoted")
                            scope.event("identity-published")
                        }
                    }, body: body)
            }
            let audio = (0..<128_000).map { 0.1 * sin(Float($0) * 0.031) }
            _ = try await controller.recognize(window: .fixture(samples: audio, final: true), offset: 0)
            let finished = try await controller.finishStreaming()
            try require(finished.isFinal, "An unavailable optional encoder cannot fail completed anonymous speech")
            let events = scope.snapshot
            try require(events.prefix(4) == ["asr-scope-open", "speaker-scope-open", "speaker-scope-closed", "asr-scope-closed"],
                        "Both native inference scopes must retire before owner encoding")
            if legacyAnonymous {
                try require(events.count == 4, "A frozen anonymous recipe cannot run a new owner stage even when a profile exists")
            } else {
                try require(events.dropFirst(4).first == "voice-encode", "The voice encoder runs only after both model scopes close")
            }
            try require(events.contains("identity-published") == (!failEncoder && !legacyAnonymous),
                        "An unavailable encoder or legacy recipe preserves anonymous speech without claiming owner identity")
            if !legacyAnonymous {
                let expected = ownerV1 ? 48_000 : 61_440
                try require(scope.encodedClipFrames == [[expected, expected]],
                            "Exact ownerV1 keeps two3s clips while V2 uses balanced first/latest evidence")
            }
        }
        print("PASS actual production streaming scope releases both model owners before optional encoder and identity publication")
    }

    private static func optionalOwnerPreflightAndCancellation() async throws {
        let store = MeetingDiarizationModelStore.witness
        store.requests = []
        try await PichiMeetingProviderFactory.prepareSpeakerResources(for: .init())
        try require(store.requests == [[.speakerSeparation]],
                    "Missing optional owner resources cannot block an installed streaming speaker model")
        var offline = MeetingFinalProcessingConfiguration()
        offline.effectiveSpeakerProcessingMode = .afterRecording
        do { try await PichiMeetingProviderFactory.prepareSpeakerResources(for: offline); throw FixtureFailure.invalid }
        catch StreamingScopeFailure.encoder {}
        try require(store.requests.last == [.speakerSeparation, .voiceMatching],
                    "Existing offline resource preparation stays strict")

        let scope = StreamingScopeFixture(blockEncoder: true)
        let runtime = MeetingParakeetNemotronRuntime(scope: scope)
        let controller = MeetingStreamingPCMController.deferred { body in
            try await runtime.withPreparedStreamingPCM(trackID: UUID(), attemptID: UUID(), configuration: .init(),
                onProgress: { value in
                    if value.batch.speakers.contains(where: \.isLocalUser) { scope.event("unexpected-owner") }
                }, body: body)
        }
        let audio = (0..<128_000).map { 0.1 * sin(Float($0) * 0.031) }
        _ = try await controller.recognize(window: .fixture(samples: audio, final: true), offset: 0)
        let finish = Task { try await controller.finishStreaming() }
        for _ in 0..<10_000 {
            if scope.snapshot.contains("voice-encode") { break }
            await Task.yield()
        }
        try require(scope.snapshot.contains("voice-encode"), "The synthetic owner encoder must start")
        let joined = Task { await controller.cancelAndWait(); scope.event("cancel-joined") }
        for _ in 0..<20 { await Task.yield() }
        try require(!scope.snapshot.contains("cancel-joined"), "Cancellation must wait for noncooperative native encoding")
        scope.releaseEncoder()
        await joined.value
        do { _ = try await finish.value; throw FixtureFailure.invalid } catch is CancellationError {}
        try require(!scope.snapshot.contains("unexpected-owner"), "Cancelled evidence cannot publish a local-user identity")
        print("PASS optional streaming owner preflight and cancellation joins native encoding without false identity")
    }

    private nonisolated static func ownerEvidenceBoundsAndQuality() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        func voice(_ count: Int, offset: Int = 0) -> [Float] {
            (0..<count).map { 0.1 * sin(Float($0 + offset) * 0.031) }
        }
        var short = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
        short.append(voice(5 * 16_000), sourceStartSample: 0)
        short.collect(activity: [.init(slotIndex: 0, start: 0, end: 5)], processedThroughSample: 80_000)
        try require(short.excerpts.isEmpty, "Short evidence cannot force owner identification")

        var complete = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
        complete.append(voice(8 * 16_000), sourceStartSample: 0)
        complete.collect(activity: [.init(slotIndex: 0, start: 0, end: 8)], processedThroughSample: 128_000)
        try require(complete.excerpts.count == 1 && complete.excerpts[0].clips.map(\.count) == [48_000, 48_000],
                    "Two independent three-second clips suffice for an existing global slot")
        try require(complete.excerpts[0].token.analysisEpochID == epoch, "Evidence retains the continuous epoch")
        let preserved = complete.excerpts[0].clips
        for ordinal in 0..<180 {
            let start = (8 + ordinal * 20) * 16_000
            complete.append([Float](repeating: 0, count: 320_000), sourceStartSample: start)
            complete.collect(activity: [], processedThroughSample: start + 320_000)
            try require(complete.retainedPCMFrames <= MeetingStreamingOwnerVoiceSamples.maximumPCMFrames,
                        "An hour of silence must not grow retained PCM")
            try require(complete.retainedVoiceFrames <= MeetingStreamingOwnerVoiceSamples.maximumVoiceFrames,
                        "Voice excerpt storage is bounded independently of meeting duration")
        }
        try require(complete.excerpts[0].clips == preserved, "Long silence does not overwrite accepted clean evidence")

        var overlap = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
        var audio = voice(12 * 16_000)
        for index in (3 * 16_000)..<(5 * 16_000) { audio[index] = 0.9 }
        overlap.append(audio, sourceStartSample: 0)
        overlap.collect(activity: [.init(slotIndex: 0, start: 0, end: 12),
            .init(slotIndex: 1, start: 3, end: 5)], processedThroughSample: audio.count)
        try require(overlap.excerpts.count == 1 && overlap.excerpts[0].token.label == "slot-0",
                    "Only enough single-speaker evidence can establish a candidate")
        try require(overlap.excerpts[0].clips.flatMap { $0 }.allSatisfy { abs($0) < 0.5 },
                    "Overlapping samples and their padded edges never enter owner clips")

        for bad in [Float.zero, 1, Float.nan] {
            var silent = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
            silent.append([Float](repeating: bad, count: 160_000), sourceStartSample: 0)
            silent.collect(activity: [.init(slotIndex: 0, start: 0, end: 10)], processedThroughSample: 160_000)
            try require(silent.excerpts.isEmpty, "Silence, clipped DC and invalid PCM cannot confirm the owner")
        }
        var incremental = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
        let equivalent = voice(8 * 16_000)
        for start in stride(from: 0, to: equivalent.count, by: 1_600) {
            incremental.append(Array(equivalent[start..<(start + 1_600)]), sourceStartSample: start)
            incremental.collect(activity: [.init(slotIndex: 0, start: 0, end: Double(start + 1_600) / 16_000)],
                processedThroughSample: start + 1_600)
        }
        try require(incremental.excerpts.first?.clips == preserved,
                    "The same stable voice yields identical evidence with 100ms or bulk acoustic callbacks")
        var dense = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
        dense.append(voice(160_000), sourceStartSample: 0)
        let overlapRows = (0..<8_192).map { index -> MeetingNemotronSpeakerSegment in
            .init(slotIndex: index % 8, start: Double(index / 8) / 128, end: min(10, Double(index / 8) / 128 + 2))
        }
        dense.collect(activity: overlapRows, processedThroughSample: 160_000)
        try require(dense.excerpts.isEmpty, "Dense simultaneous voices cannot manufacture clean owner clips")
        var delayed = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
        delayed.append(voice(160_000), sourceStartSample: 0)
        delayed.collect(activity: [], processedThroughSample: 0)
        try require(delayed.excerpts.isEmpty, "Unscored audio is never treated as clean owner evidence")
        delayed.collect(activity: [.init(slotIndex: 0, start: 0, end: 10)], processedThroughSample: 160_000)
        try require(delayed.excerpts.count == 1, "A later scored watermark admits retained evidence")
        delayed.append([0.1], sourceStartSample: 180_000)
        try require(delayed.excerpts.isEmpty && delayed.retainedPCMFrames == 0,
                    "A discontinuity discards optional identity evidence rather than relabeling voices")
        print("PASS bounded streaming owner clips, short speech, long silence, overlap, quality and delayed scoring")
    }

}
