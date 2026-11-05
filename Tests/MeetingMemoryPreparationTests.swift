import Foundation

// These inert resource types let the probe compile the complete production attempt owner.
// It runs no speech model, microphone, file store or personal transcript.
nonisolated struct MeetingBackendID: Sendable { let rawValue = "synthetic" }
nonisolated struct MeetingFinalProcessingConfiguration: Sendable {
    let identityFingerprint = "synthetic"
    var asrArtifactDirectory: URL? { nil }
}
nonisolated protocol MeetingIdlePreparedResource: Sendable {
    var configurationIdentity: String { get }
    func cleanup() async
}
nonisolated enum MeetingConfigFingerprintEncoding {
    static func encode(_ values: [(String, String)]) -> String { "synthetic" }
}
typealias MeetingTrackConfidentNonSpeechQuery = @Sendable (MeetingAudioTrackKind, TimeInterval, TimeInterval) async -> Bool
typealias MeetingAudioTrackID = UUID
nonisolated struct MeetingAudioTrack: Sendable { let id = UUID() }
nonisolated enum MeetingAudioTrackKind: Sendable { case microphone, applicationAudio }
nonisolated struct MeetingStreamingPCMObservation: Sendable {}
nonisolated enum MeetingStreamingPCMControllerError: Error { case invalidScope }
actor MeetingProcessingSerializationGate {
    func acquire() async throws {}
    func release() {}
}
nonisolated struct MeetingBackendRequest: Sendable {}
nonisolated struct MeetingBackendDescriptor: Sendable {}
nonisolated protocol MeetingParakeetNemotronRunning: Sendable {}
nonisolated struct MeetingProbeTime: Sendable {
    let value: Int64
    let timescale: Int32
    var seconds: Double { Double(value) / Double(timescale) }
}
nonisolated struct MeetingProbeSegment: Sendable {
    var start: MeetingProbeTime
    var end: MeetingProbeTime
}
nonisolated struct MeetingPCMTranscriptBatch: Sendable {
    var sourceTrack: MeetingAudioTrack?
    var segments: [MeetingProbeSegment] = []
    var speakers: [String] = []
    var speakerRevisions: [String] = []
    var echoRevisions: [String] = []
    var livePreview: MeetingLivePartial?
    var protectedSourceThroughSample: Int?
}
nonisolated struct MeetingLivePartial: Sendable { var start: Double; var end: Double? }
nonisolated struct MeetingProcessingResult: Sendable {}
nonisolated final class MeetingMemoryAudioArchive: Sendable {}
nonisolated protocol MeetingMemoryAudioConsuming: Sendable {}
nonisolated final class MeetingArchivedMemoryAudioConsumer: Sendable {}
nonisolated final class MeetingStreamingPCMController: Sendable { func cancelAndWait() async {} }
actor MeetingStreamingEchoAdmission {
    func observe(track: MeetingAudioTrack, observation: MeetingStreamingPCMObservation) -> MeetingStreamingPCMObservation { observation }
    func admitting(_ batch: MeetingPCMTranscriptBatch) -> MeetingPCMTranscriptBatch { batch }
    func pendingRevisionBatch() -> MeetingPCMTranscriptBatch? { nil }
    func markSealed(trackID: UUID) {}
    func cancel() {}
}
nonisolated final class MeetingStreamingTranscriptState: Sendable {}
nonisolated final class MeetingTranscriptPrivacyContext: Sendable {
    init(redactor: any TranscriptTextRedacting) {}
}
nonisolated enum MeetingRetainedProcessingCheckpoint {
    enum Failure: Error { case changedConfiguration }
}
private nonisolated struct Runtime: MeetingParakeetNemotronRunning {}
private enum ExpectedFailure: Error { case preparation, notReady }

private actor Latch {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if self.released { return }
        await withCheckedContinuation { self.continuation = $0 }
    }
    func release() { self.released = true; self.continuation?.resume(); self.continuation = nil }
}

private nonisolated final class Redactor: TranscriptTextRedacting, @unchecked Sendable {
    private let lock = NSLock()
    private var identity = "pinned-resource"
    private var preparations = 0
    private var ready = false
    let gate = Latch()
    var failPreparation = false
    var checkpointIdentity: String? { self.lock.withLock { self.identity } }
    var count: Int { self.lock.withLock { self.preparations } }
    func mutateIdentity() { self.lock.withLock { self.identity = "changed-resource" } }
    func prepareForMeeting() async throws {
        self.lock.withLock { self.preparations += 1 }
        await self.gate.wait() // Deliberately non-cooperative native loading.
        if self.failPreparation { throw ExpectedFailure.preparation }
        self.lock.withLock { self.ready = true }
    }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        guard self.lock.withLock({ self.ready }) else { throw ExpectedFailure.notReady }
        return .init(text: "[NAME]", spans: [])
    }
}

@main
@MainActor
struct MeetingMemoryPreparationTests {
    static func require(_ value: Bool, _ detail: String) throws {
        if !value { throw NSError(domain: "MemoryPreparation", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
    }

    private static func owner(_ redactor: Redactor) -> MeetingMemoryProcessingAttempt {
        .init(request: .init(), descriptor: .init(), runtime: Runtime(), archive: .init(),
              redactor: redactor, checkpoint: { _ in }, preview: nil)
    }

    private static func awaitPreparation(_ redactor: Redactor) async throws {
        for _ in 0..<10_000 {
            if redactor.count > 0 { return }
            await Task.yield()
        }
        throw NSError(domain: "PreparationDidNotStart", code: 1)
    }

    static func main() async throws {
        let redactor = Redactor(), owner = self.owner(redactor)
        try require(redactor.count == 0, "Capture admission does not load NER")
        let first = Task { try await owner.preparePrivacy() }
        try await self.awaitPreparation(redactor)
        let second = Task { try await owner.preparePrivacy() }
        await Task.yield()
        try require(redactor.count == 1, "One attempt has only one preparation owner")
        await redactor.gate.release()
        try await first.value
        try await second.value
        try await owner.preparePrivacy()
        try require(redactor.count == 1, "Subsequent windows and replay reuse the same resource")

        let changedBefore = Redactor(), beforeOwner = self.owner(changedBefore)
        changedBefore.mutateIdentity()
        do { try await beforeOwner.preparePrivacy(); throw ExpectedFailure.notReady }
        catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration {}
        try require(changedBefore.count == 0, "A changed identity cannot load before first speech")

        let changedDuring = Redactor(), duringOwner = self.owner(changedDuring)
        let changed = Task { try await duringOwner.preparePrivacy() }
        try await self.awaitPreparation(changedDuring)
        changedDuring.mutateIdentity()
        await changedDuring.gate.release()
        do { try await changed.value; throw ExpectedFailure.notReady }
        catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration {}

        let cancelled = Redactor(), cancellationOwner = self.owner(cancelled)
        var returned = false
        let cancellation = Task {
            do { try await cancellationOwner.preparePrivacy(); throw ExpectedFailure.notReady }
            catch is CancellationError { returned = true }
        }
        try await self.awaitPreparation(cancelled)
        cancellation.cancel()
        for _ in 0..<20 { await Task.yield() }
        try require(!returned, "Cancellation cannot abandon non-cooperative resource loading")
        await cancelled.gate.release()
        try await cancellation.value
        try require(returned, "The cancelled caller returns only after preparation joins")

        let failed = Redactor(), failureOwner = self.owner(failed)
        failed.failPreparation = true
        await failed.gate.release()
        for _ in 0..<2 {
            do { try await failureOwner.preparePrivacy(); throw ExpectedFailure.notReady }
            catch ExpectedFailure.preparation {}
        }
        try require(failed.count == 1, "Failure is retained and cannot become raw-text publication")
        print("PASS deferred transcript privacy: one owned preparation, frozen identity, joined cancellation, failure closed")
    }
}
