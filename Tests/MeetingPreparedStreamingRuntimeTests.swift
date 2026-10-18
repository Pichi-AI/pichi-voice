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
nonisolated struct MeetingSpeakerVoiceSamples: Sendable { let token: MeetingBackendSpeakerToken; let clips: [[Float]] }
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {}
nonisolated struct MeetingOwnerVoiceProfileSnapshot: Sendable {}
nonisolated struct MeetingMaterializedSpanSamples: Sendable {}
nonisolated struct MeetingNemotronModelArtifact: Sendable {
    struct Profile: Sendable {
        enum Preference { case cpuOnly, devicePreferred }
        var streamingImplementationFingerprint = "synthetic-pinned-profile"
        func acceptsStreamingImplementationFingerprint(_ value: String) -> Bool {
            value == self.streamingImplementationFingerprint || value == "synthetic-legacy-anonymous"
        }
        func verifiesStreamingOwner(implementationFingerprint value: String) -> Bool {
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
    static func confirmedTokens(owner: MeetingOwnerVoiceProfileSnapshot?, profiles: [MeetingSpeakerVoiceProfile]) -> Set<MeetingBackendSpeakerToken> {
        profiles.isEmpty ? [] : [.init(analysisEpochID: .init(trackID: UUID(), ordinal: 0), label: "slot-0")]
    }
}
nonisolated enum StreamingScopeFailure: Error { case encoder }
nonisolated final class StreamingScopeFixture: @unchecked Sendable {
    let failEncoder: Bool
    let blockEncoder: Bool
    private var encoderReleased = false
    private var encoderWaiter: CheckedContinuation<Void, Never>?
    private let lock = NSLock()
    private var events: [String] = []
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
        try ownerEvidenceBoundsAndQuality()
        try await ownerScopeRetiresModelsBeforeEncoder()
        try await optionalOwnerPreflightAndCancellation()
        print("12 prepared streaming runtime contract groups passed")
    }
    private nonisolated static func ownerScopeRetiresModelsBeforeEncoder() async throws {
        for (failEncoder, legacyAnonymous) in [(false, false), (true, false), (false, true)] {
            let scope = StreamingScopeFixture(failEncoder: failEncoder)
            var configuration = MeetingFinalProcessingConfiguration()
            if legacyAnonymous { configuration.diarizationFingerprint = "synthetic-legacy-anonymous" }
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
