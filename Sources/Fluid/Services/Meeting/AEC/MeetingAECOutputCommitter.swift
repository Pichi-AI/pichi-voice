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
    private var reportedProtection: MeetingMicrophoneEchoProtection?
    private var generation: UInt64 = 0
    /// Gate epoch captured when a promotion begins; the open succeeds only if nothing closed meanwhile.
    private var promotionGateEpoch: UInt64 = 0
    private var terminalFailureReported = false
    private var pendingCommitCount = 0
    private var retired = false
    private struct PendingLive {
        let id: UUID
        let sample: SampleBox
        let token: UInt64
        let epoch: UInt64
        let protection: MeetingMicrophoneEchoProtection
        let reportsProtection: Bool
        let bytes: Int
        var consumed = false
    }
    private var pendingLive: [PendingLive] = []
    private var pendingLiveBytes = 0
    private var readyLiveTokens = Set<UInt64>()
    private var liveDeferred = false
    private var ownedPCMFrames: UInt64 = 0
    private var offeredLiveFrames: UInt64 = 0
    /// Includes raw retained tails and offers revoked after dequeue, not only queued offers.
    /// Durability is the writer's authority; these counters prevent false transcript completeness.
    var hasDeferredLiveAudio: Bool { self.lock.withLock { self.liveDeferred || self.ownedPCMFrames != self.offeredLiveFrames } }

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
        self.clearPendingLive()
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
        self.observeOwnedPCM(sampleBuffer)
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

    /// Keep opening speech while the filter learns, without claiming verified cancellation or
    /// reporting normal warm-up as a filtering failure. Provenance still commits before live ASR.
    func commitWarmup(_ sampleBuffer: CMSampleBuffer) {
        self.commitAdmitted(sampleBuffer, protection: .unfiltered, reportsProtectionChange: false)
    }

    private func commitAdmitted(
        _ sampleBuffer: CMSampleBuffer,
        protection: MeetingMicrophoneEchoProtection,
        reportsProtectionChange: Bool = true
    ) {
        guard !self.lock.withLock({ self.retired }) else { return }
        if self.lock.withLock({ self.liveDeferred }) {
            self.observeOwnedPCM(sampleBuffer)
            _ = self.writer.enqueue(sampleBuffer, producerEpoch: self.producerEpoch)
            return
        }
        guard self.ownsAdmission else {
            if self.lock.withLock({ !self.retired }) { self.retainPendingCapture(sampleBuffer) }
            return
        }
        let sampleBox = SampleBox(sampleBuffer)
        let startSeconds = Self.seconds(of: sampleBuffer)
        let action = self.lock.withLock { () -> (token: UInt64, epoch: UInt64, promotion: Bool) in
            switch self.state {
            case let .admitted(current) where current == protection:
                return (self.generation, self.promotionGateEpoch, false)
            case let .promotionPending(token, current) where current == protection:
                return (token, self.promotionGateEpoch, false)
            default:
                self.generation &+= 1
                self.promotionGateEpoch = self.expectedGateEpoch ?? self.transcriptGate.invalidationEpoch
                self.state = .promotionPending(self.generation, protection)
                return (self.generation, self.promotionGateEpoch, true)
            }
        }
        let id = UUID()
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        let channels = CMSampleBufferGetFormatDescription(sampleBuffer)
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        guard (1...65_536).contains(frames), (1...8).contains(channels) else {
            _ = self.writer.enqueue(sampleBuffer, producerEpoch: self.producerEpoch)
            self.reportTerminalFailure(.invalidSampleBuffer)
            return
        }
        let bytes = frames * Int(channels) * MemoryLayout<Float>.stride
        let retained = self.lock.withLock { () -> Bool in
            guard self.pendingLive.count < 512, bytes >= 0, bytes <= 2 * 1024 * 1024 - self.pendingLiveBytes else { return false }
            self.pendingLive.append(.init(id: id, sample: sampleBox, token: action.token, epoch: action.epoch,
                protection: protection, reportsProtection: reportsProtectionChange, bytes: bytes))
            self.pendingLiveBytes += bytes
            return true
        }
        if !retained { self.reportTerminalFailure(.writerQueueFull) }
        guard action.promotion else {
            _ = self.enqueueOrFail(sampleBuffer, startSeconds: startSeconds) { self.consumeLive(id) }
            return
        }
        self.beginPendingCommit()
        self.observeOwnedPCM(sampleBuffer)
        self.writer.enqueue(sampleBuffer, producerEpoch: self.producerEpoch, afterPersistingMetadata: { track in
            self.lock.withLock {
                guard !self.retired,
                      self.expectedGateEpoch == nil || self.expectedGateEpoch == self.transcriptGate.invalidationEpoch else { return }
                Self.applyEra(to: &track, protection: protection,
                    provenance: protection == .softwareEchoCancelled ? MeetingAECConstants.provenance : nil,
                    startSeconds: startSeconds)
            }
        }, failClosed: false) { result in
            defer { self.endPendingCommit() }
            switch result {
            case .success:
                guard self.ownsAdmission, self.transcriptGate.invalidationEpoch == action.epoch else {
                    self.clearPendingLive()
                    self.persistSafetyEra(startSeconds: startSeconds)
                    return
                }
                self.lock.withLock {
                    self.readyLiveTokens.insert(action.token)
                    if self.generation == action.token { self.state = .admitted(protection) }
                }
                self.consumeLive(id)
            case let .failure(error):
                if self.ownsAdmission { _ = self.transcriptGate.invalidate() }
                self.reportTerminalFailure(Self.terminalFailure(for: error))
            }
        }
    }

    private func consumeLive(_ id: UUID) {
        self.lock.withLock {
            if let index = self.pendingLive.firstIndex(where: { $0.id == id }) { self.pendingLive[index].consumed = true }
        }
        while let value = self.lock.withLock({ () -> PendingLive? in
            guard !self.liveDeferred, !self.retired, let first = self.pendingLive.first,
                  first.consumed, self.readyLiveTokens.contains(first.token) else { return nil }
            self.pendingLive.removeFirst()
            self.pendingLiveBytes -= first.bytes
            let retained = Set(self.pendingLive.map(\.token)).union([self.generation])
            self.readyLiveTokens.formIntersection(retained)
            return first
        }) {
            guard self.transcriptGate.updateIfNotInvalidated(value.protection, since: value.epoch) else { continue }
            self.offerLive(value.sample, gateEpoch: value.epoch)
            if value.reportsProtection { self.reportProtection(value.protection, gateEpoch: value.epoch) }
        }
    }

    private func clearPendingLive() {
        self.lock.withLock {
            self.pendingLive.removeAll(); self.pendingLiveBytes = 0; self.readyLiveTokens.removeAll()
        }
    }

    private func observeOwnedPCM(_ sample: CMSampleBuffer) {
        self.lock.withLock { self.ownedPCMFrames &+= UInt64(max(0, CMSampleBufferGetNumSamples(sample))) }
    }

    private func reportProtection(_ protection: MeetingMicrophoneEchoProtection, gateEpoch: UInt64) {
        guard self.ownsAdmission, self.transcriptGate.invalidationEpoch == gateEpoch else { return }
        let changed = self.lock.withLock {
            guard self.reportedProtection != protection else { return false }
            self.reportedProtection = protection
            return true
        }
        if changed { self.protectionChanged(protection) }
    }

    private func offerLive(_ sample: SampleBox, gateEpoch: UInt64) {
        let admitted = self.lock.withLock {
            !self.retired && self.transcriptGate.observeAndAdmit(sample.sampleBuffer, since: gateEpoch)
        }
        if admitted, let handler = self.liveAudioHandler {
            self.lock.withLock { self.offeredLiveFrames &+= UInt64(max(0, CMSampleBufferGetNumSamples(sample.sampleBuffer))) }
            handler(.microphone, sample.sampleBuffer)
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
        self.observeOwnedPCM(sampleBox.sampleBuffer)
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
        self.clearPendingLive()
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
            self.liveDeferred = true
            self.pendingLive.removeAll(); self.pendingLiveBytes = 0; self.readyLiveTokens.removeAll()
            return true
        }
        if shouldReport {
            self.persistSafetyEra(startSeconds: self.transcriptGate.latestObservedSeconds())
            self.terminalFailure(failure)
        }
    }

    /// The plain enqueue carries no era command, so an overflow must still leave the in-memory
    /// and persisted track unprotected before the terminal stop completes.
    private func enqueueOrFail(
        _ sampleBuffer: CMSampleBuffer,
        startSeconds: Double?,
        onConsumed: (@Sendable () -> Void)? = nil
    ) -> Bool {
        self.beginPendingCommit()
        self.observeOwnedPCM(sampleBuffer)
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
