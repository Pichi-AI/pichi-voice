@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// The only owner that couples speaker-route microphone samples to AEC provenance changes.
/// Its small lock never protects PCM work; it only closes/reopens transcript admission around
/// asynchronous writer transactions.
final nonisolated class MeetingAECOutputCommitter: @unchecked Sendable {
    private final class SampleBox: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer

        init(_ sampleBuffer: CMSampleBuffer) { self.sampleBuffer = sampleBuffer }
    }

    private enum State: Equatable {
        case unprotected
        case promotionPending(UInt64, MeetingMicrophoneEchoProtection)
        case admitted(MeetingMicrophoneEchoProtection)
    }

    private let lock = NSLock()
    private let writer: MeetingAudioChunkWriter
    private let producerEpoch: UInt64
    private let expectedGateEpoch: UInt64?
    private let transcriptGate: MeetingMicrophoneTranscriptGate
    private let liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    private let terminalFailure: @Sendable (MeetingAECFailure) -> Void
    private let protectionChanged: @Sendable (MeetingMicrophoneEchoProtection) -> Void
    private let pending = DispatchGroup()
    private var state: State = .unprotected
    private var generation: UInt64 = 0
    /// Gate epoch captured when a promotion begins; the open succeeds only if nothing closed meanwhile.
    private var promotionGateEpoch: UInt64 = 0
    private var terminalFailureReported = false
    private var pendingCommitCount = 0
    private var retired = false

    var hasPendingCommits: Bool {
        self.lock.withLock { self.pendingCommitCount > 0 }
    }

    init(
        writer: MeetingAudioChunkWriter,
        producerEpoch: UInt64 = 0,
        expectedGateEpoch: UInt64? = nil,
        transcriptGate: MeetingMicrophoneTranscriptGate,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?,
        protectionChanged: @escaping @Sendable (MeetingMicrophoneEchoProtection) -> Void = { _ in },
        terminalFailure: @escaping @Sendable (MeetingAECFailure) -> Void
    ) {
        self.writer = writer
        self.producerEpoch = producerEpoch
        self.expectedGateEpoch = expectedGateEpoch
        self.transcriptGate = transcriptGate
        self.liveAudioHandler = liveAudioHandler
        self.terminalFailure = terminalFailure
        self.protectionChanged = protectionChanged
    }

    /// Only an existing filtered promotion can continue without a new attestation. Raw speech
    /// admitted during warm-up must not accidentally count as a successful AEC promotion.
    func commitProcessed(_ sampleBuffer: CMSampleBuffer, mayPromote: Bool, originalCapture: CMSampleBuffer? = nil) {
        guard self.ownsAdmission else {
            if self.lock.withLock({ !self.retired }) { self.retainPendingCapture(originalCapture ?? sampleBuffer) }
            return
        }
        let hasPromotion = self.lock.withLock { () -> Bool in
            switch self.state {
            case .admitted(.softwareEchoCancelled), .promotionPending(_, .softwareEchoCancelled): return true
            default: return false
            }
        }
        guard mayPromote || hasPromotion else {
            guard self.enqueueOrFail(sampleBuffer, startSeconds: Self.seconds(of: sampleBuffer)) else { return }
            _ = self.transcriptGate.observeAndAdmit(sampleBuffer)
            return
        }
        self.commitAdmitted(sampleBuffer, protection: .softwareEchoCancelled)
    }

    /// A filtering failure changes processing provenance, not whether captured speech exists.
    /// Persist the honest fallback state before offering any of its audio to live transcription.
    func commitUnfiltered(_ sampleBuffer: CMSampleBuffer) {
        self.commitAdmitted(sampleBuffer, protection: .unfiltered)
    }

    func commitCaptured(_ sampleBuffer: CMSampleBuffer, protection: MeetingMicrophoneEchoProtection) {
        precondition(protection == .unfiltered || protection == .acousticallyClosed)
        self.commitAdmitted(sampleBuffer, protection: protection)
    }

    /// Retiring local ownership never changes the shared gate or a successor's durable era.
    func retire() {
        self.lock.withLock {
            self.retired = true
            self.generation &+= 1
            self.state = .unprotected
        }
    }

    /// Route/rebuild flushes retain already accepted capture PCM exactly once. Obsolete owners
    /// may retain these bytes but cannot relabel them, reopen admission, or offer stale live data.
    func retainPendingCapture(_ sampleBuffer: CMSampleBuffer, unfiltered: Bool = false) {
        guard unfiltered else {
            _ = self.enqueueOrFail(sampleBuffer, startSeconds: Self.seconds(of: sampleBuffer))
            return
        }
        let start = Self.seconds(of: sampleBuffer)
        self.beginPendingCommit()
        self.writer.enqueue(sampleBuffer, producerEpoch: self.producerEpoch, afterPersistingMetadata: { track in
            Self.applyEra(to: &track, protection: .unfiltered, provenance: nil, startSeconds: start)
        }, failClosed: true) { result in
            defer { self.endPendingCommit() }
            if case let .failure(error) = result { self.reportTerminalFailure(Self.terminalFailure(for: error)) }
        }
    }

    private var ownsAdmission: Bool {
        self.lock.withLock {
            !self.retired && (self.expectedGateEpoch == nil || self.expectedGateEpoch == self.transcriptGate.invalidationEpoch)
        }
    }

    /// Metadata-only route choices share the frame committer's immutable authority. Losing that
    /// authority makes completion inert; the successor owns the next conservative/valid era.
    func resumeProtection(
        _ protection: MeetingMicrophoneEchoProtection,
        mayResume: @escaping @Sendable () -> Bool
    ) async throws -> Bool {
        precondition(protection == .unfiltered || protection == .acousticallyClosed)
        guard self.ownsAdmission, mayResume() else { return false }
        let epoch = self.expectedGateEpoch ?? self.transcriptGate.invalidationEpoch
        let start = self.transcriptGate.latestObservedSeconds()
        self.beginPendingCommit()
        return try await withCheckedThrowingContinuation { continuation in
            self.writer.enqueueMetadata(failClosed: true, mutate: { track in
                let permitted = mayResume()
                self.lock.withLock {
                    guard permitted, !self.retired, self.transcriptGate.invalidationEpoch == epoch else { return }
                    Self.applyEra(to: &track, protection: protection, provenance: nil, startSeconds: start)
                }
            }) { result in
                defer { self.endPendingCommit() }
                switch result {
                case .success:
                    let permitted = mayResume()
                    let opened = self.lock.withLock {
                        !self.retired && permitted && self.transcriptGate.updateIfNotInvalidated(protection, since: epoch)
                    }
                    continuation.resume(returning: opened)
                case let .failure(error): continuation.resume(throwing: error)
                }
            }
        }
    }

    private func commitAdmitted(_ sampleBuffer: CMSampleBuffer, protection: MeetingMicrophoneEchoProtection) {
        guard self.ownsAdmission else {
            if self.lock.withLock({ !self.retired }) { self.retainPendingCapture(sampleBuffer) }
            return
        }
        let sampleBox = SampleBox(sampleBuffer)
        let startSeconds = Self.seconds(of: sampleBuffer)
        let action = self.lock.withLock { () -> (token: UInt64?, gateEpoch: UInt64) in
            switch self.state {
            case let .admitted(current) where current == protection:
                return (nil, self.promotionGateEpoch)
            case let .promotionPending(_, current) where current == protection:
                return (nil, self.promotionGateEpoch)
            default:
                self.generation &+= 1
                let token = self.generation
                self.promotionGateEpoch = self.expectedGateEpoch ?? self.transcriptGate.invalidationEpoch
                self.state = .promotionPending(token, protection)
                return (token, self.promotionGateEpoch)
            }
        }

        guard let token = action.token else {
            // The existing bounded writer queue orders live offers after the era commit and all
            // earlier samples, including a rapid filtered-to-unfiltered transition.
            _ = self.enqueueOrFail(sampleBox.sampleBuffer, startSeconds: startSeconds) { [self] in
                self.offerLive(sampleBox, gateEpoch: action.gateEpoch)
            }
            return
        }
        self.beginPendingCommit()
        self.writer.enqueue(
            sampleBox.sampleBuffer,
            producerEpoch: self.producerEpoch,
            afterPersistingMetadata: { track in
                self.lock.withLock {
                    guard !self.retired,
                          self.expectedGateEpoch == nil || self.expectedGateEpoch == self.transcriptGate.invalidationEpoch
                    else { return }
                    Self.applyEra(
                        to: &track,
                        protection: protection,
                        provenance: protection == .softwareEchoCancelled ? MeetingAECConstants.provenance : nil,
                        startSeconds: startSeconds
                    )
                }
            },
            // Promotion failure must preserve the older conservative in-memory track.
            failClosed: false
        ) { [self] result in
            defer { self.endPendingCommit() }
            switch result {
            case .success:
                guard self.ownsAdmission else { return }
                // A route/lifecycle close racing this completion holds the gate closed; land a
                // compensating conservative write after the optimistic era just persisted.
                let opened = self.lock.withLock {
                    !self.retired && self.transcriptGate.updateIfNotInvalidated(protection, since: action.gateEpoch)
                }
                guard opened else {
                    let needsSafetyEra = self.lock.withLock { () -> Bool in
                        guard !self.retired, self.generation == token else { return false }
                        self.generation &+= 1
                        self.state = .unprotected
                        return true
                    }
                    if needsSafetyEra { self.persistSafetyEra(startSeconds: startSeconds) }
                    return
                }
                self.offerLive(sampleBox, gateEpoch: action.gateEpoch)
                if self.ownsAdmission, self.transcriptGate.invalidationEpoch == action.gateEpoch {
                    self.protectionChanged(protection)
                }
                self.lock.withLock {
                    if self.generation == token { self.state = .admitted(protection) }
                }
            case let .failure(error):
                guard self.ownsAdmission else { return }
                self.lock.withLock {
                    if self.generation == token { self.state = .unprotected }
                }
                _ = self.transcriptGate.invalidate()
                self.reportTerminalFailure(Self.terminalFailure(for: error))
            }
        }
    }

    private func offerLive(_ sample: SampleBox, gateEpoch: UInt64) {
        let admitted = self.lock.withLock {
            !self.retired && self.transcriptGate.observeAndAdmit(sample.sampleBuffer, since: gateEpoch)
        }
        if admitted {
            self.liveAudioHandler?(.microphone, sample.sampleBuffer)
        }
    }

    /// Records a raw/bypass sample. If the prior state could have been protected, its demotion and
    /// this sample are one writer command, so raw bytes cannot land beneath optimistic metadata.
    func commitRaw(_ sampleBuffer: CMSampleBuffer, failure: MeetingAECFailure) {
        guard self.lock.withLock({ !self.retired }) else { return }
        let sampleBox = SampleBox(sampleBuffer)
        let startSeconds = Self.seconds(of: sampleBuffer)
        _ = self.transcriptGate.observeAndAdmit(sampleBox.sampleBuffer)
        let mustPersistDemotion = self.lock.withLock { () -> Bool in
            let needed = self.state != .unprotected
            self.generation &+= 1
            self.state = .unprotected
            return needed
        }
        _ = self.transcriptGate.invalidate()
        guard mustPersistDemotion else {
            _ = self.enqueueOrFail(sampleBox.sampleBuffer, startSeconds: startSeconds)
            return
        }

        self.beginPendingCommit()
        self.writer.enqueue(
            sampleBox.sampleBuffer,
            producerEpoch: self.producerEpoch,
            afterPersistingMetadata: { track in
                Self.applyEra(
                    to: &track,
                    protection: .unprotected,
                    provenance: nil,
                    startSeconds: startSeconds
                )
            },
            failClosed: true
        ) { [self] result in
            defer { self.endPendingCommit() }
            if case let .failure(error) = result {
                self.reportTerminalFailure(Self.terminalFailure(for: error))
            }
        }
        _ = failure
    }

    /// Called on the shared SCK queue after the gate was synchronously closed at route/rebuild
    /// observation. It queues the conservative era before any later raw callback can reach writer.
    func invalidateForExternalBoundary(
        _ boundary: MeetingMicrophoneTranscriptGate.InvalidationBoundary?
    ) {
        self.lock.withLock {
            self.generation &+= 1
            self.state = .unprotected
        }
        _ = self.transcriptGate.invalidate()
        self.persistSafetyEra(startSeconds: boundary?.unsafeStartSeconds, force: true)
    }

    /// Enqueues the fail-closed `unprotected` era as a bounded writer-queue command and reports a
    /// terminal failure if even that command cannot persist.
    private func persistSafetyEra(startSeconds: Double?, force: Bool = false) {
        self.beginPendingCommit()
        self.writer.enqueueMetadata(
            failClosed: true,
            mutate: { track in
                self.lock.withLock {
                    guard force || !self.retired else { return }
                    Self.applyEra(
                        to: &track, protection: .unprotected, provenance: nil, startSeconds: startSeconds
                    )
                }
            }
        ) { [self] result in
            defer { self.endPendingCommit() }
            if case let .failure(error) = result {
                self.reportTerminalFailure(Self.terminalFailure(for: error))
            }
        }
    }

    func waitForPendingCommits() async {
        await withCheckedContinuation { continuation in
            self.pending.notify(queue: .global(qos: .userInitiated)) {
                continuation.resume()
            }
        }
        // Live offers share the bounded PCM queue, so also drain samples behind the era commit.
        _ = await self.writer.snapshot()
    }

    /// Close live delivery without relabelling successfully filtered audio at Stop.
    func finish() {
        self.lock.withLock {
            self.generation &+= 1
            self.state = .unprotected
            self.retired = true
        }
        _ = self.transcriptGate.invalidate()
    }

    func failTerminal(_ failure: MeetingAECFailure) {
        _ = self.transcriptGate.invalidate()
        self.lock.withLock {
            self.generation &+= 1
            self.state = .unprotected
        }
        self.reportTerminalFailure(failure)
    }

    private func beginPendingCommit() {
        self.lock.withLock {
            self.pendingCommitCount += 1
            self.pending.enter()
        }
    }

    private func endPendingCommit() {
        self.lock.withLock {
            self.pendingCommitCount -= 1
            self.pending.leave()
        }
    }

    private func reportTerminalFailure(_ failure: MeetingAECFailure) {
        let shouldReport = self.lock.withLock { () -> Bool in
            guard !self.terminalFailureReported else { return false }
            self.terminalFailureReported = true
            return true
        }
        if shouldReport { self.terminalFailure(failure) }
    }

    /// The plain enqueue carries no era command, so an overflow must still leave the in-memory
    /// and persisted track unprotected before the terminal stop completes.
    private func enqueueOrFail(
        _ sampleBuffer: CMSampleBuffer,
        startSeconds: Double?,
        onConsumed: (@Sendable () -> Void)? = nil
    ) -> Bool {
        self.beginPendingCommit()
        guard self.writer.enqueue(sampleBuffer, producerEpoch: self.producerEpoch, onConsumed: {
            defer { self.endPendingCommit() }
            onConsumed?()
        }) else {
            self.endPendingCommit()
            self.lock.withLock {
                self.generation &+= 1
                self.state = .unprotected
            }
            _ = self.transcriptGate.invalidate()
            self.persistSafetyEra(startSeconds: startSeconds)
            self.reportTerminalFailure(.writerQueueFull)
            return false
        }
        return true
    }

    private static func terminalFailure(for error: Error) -> MeetingAECFailure {
        switch error as? MeetingAudioChunkWriter.SequencedCommandError {
        case .queueFull: return .writerQueueFull
        case .writerNotAccepting: return .stopped
        case nil: return .metadataPersistence
        }
    }

    private static func seconds(of sampleBuffer: CMSampleBuffer) -> Double? {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.isNumeric else { return nil }
        let seconds = CMTimeGetSeconds(time)
        return seconds.isFinite ? seconds : nil
    }

    static func applyEra(
        to track: inout MeetingAudioTrack,
        protection: MeetingMicrophoneEchoProtection,
        provenance: MeetingAECProvenance?,
        startSeconds: Double?
    ) {
        guard var eras = track.captureEras, !eras.isEmpty else { return }
        let lastIndex = eras.index(before: eras.endIndex)
        if let startSeconds,
           startSeconds.isFinite,
           startSeconds > eras[lastIndex].startSeconds
        {
            var era = eras[lastIndex]
            era.startSeconds = startSeconds
            era.echoProtection = protection
            era.aecProvenance = provenance
            era.settledConfig = nil
            era.clockDrift = nil
            eras.append(era)
        } else {
            eras[lastIndex].echoProtection = protection
            eras[lastIndex].aecProvenance = provenance
        }
        track.captureEras = eras
    }
}
