import Foundation
#if os(iOS)
import UIKit
#endif
#if canImport(Darwin)
import Darwin
#endif

#if arch(arm64)
import CoreML
import FluidAudio
#endif

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the production runtime behind
// `MeetingParakeetNemotronRunning`. It owns the model capabilities for one attempt:
//
// - Nemotron diarization: one shared weight load per attempt, one *fresh* `SortformerDiarizer`
//   state per track (`initialize(models:)` re-creates streaming state), released before the ASR
//   phase begins — the loaded-set sequence is none -> Nemotron -> drained -> Parakeet -> drained.
// - Prepared-provider ASR: one `ASRService.withPreparedMeetingASR` scope per attempt, with the heavy body
//   bounced off the main actor so materialization and inference never block the UI.
// - Optional local WeSpeaker encoding in its own phase, using bounded voice excerpts.
// - The default strict PCM route runs ASR during capture and one global Nemotron pass
//   after Stop, followed by optional owner encoding in its own phase.
// - The explicit streaming capability holds one prepared ASR and one incremental Nemotron
//   state under the same outer attempt grant. Their native calls remain serial, and Stop
//   flushes only the unscored tail. Optional owner encoding follows after both scopes retire.
//
// Parakeet does ASR only; Nemotron does diarization only. Neither capability sees anything beyond
// the request the host froze.

nonisolated enum MeetingParakeetNemotronRuntimeError: LocalizedError, Equatable {
    case unsupportedArchitecture
    case invalidPCMWindow
    case concurrentPCMWindow

    var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            return "The local Parakeet + Nemotron meeting backend requires Apple Silicon."
        case .invalidPCMWindow:
            return "The meeting PCM window is outside the bounded inference contract."
        case .concurrentPCMWindow:
            return "Another PCM window still owns the meeting inference runtime."
        }
    }
}

/// Buffered providers decode each growing prefix again. Keep optional observations only
/// while the measured whole window leaves headroom for the next captured audio window.
/// Scalar scheduling state contains no audio/text and resets with the frozen attempt identity.
nonisolated struct MeetingPCMPreviewPacing: Sendable {
    private(set) var permitsIntermediateObservations = true

    static func shouldInfer(hasNewPCM: Bool, isFinal: Bool, permitsIntermediateObservations: Bool) -> Bool {
        (hasNewPCM && permitsIntermediateObservations) || (isFinal && !permitsIntermediateObservations)
    }

    mutating func record(computeSeconds: TimeInterval, audioSeconds: TimeInterval,
                         chargedPendingFrames: Int = 0, maximumPendingFrames: Int? = nil) {
        guard computeSeconds.isFinite, computeSeconds >= 0,
              audioSeconds.isFinite, audioSeconds > 0, chargedPendingFrames >= 0,
              maximumPendingFrames.map({ $0 > 0 && chargedPendingFrames <= $0 }) ?? (chargedPendingFrames == 0) else { return }
        // Match the compute hysteresis: shed repeated prefixes before the admission ceiling,
        // and restore them only after both processing and the charged queue have headroom.
        let pressure = maximumPendingFrames.map { Double(chargedPendingFrames) / Double($0) } ?? 0
        if self.permitsIntermediateObservations, computeSeconds * 5 >= audioSeconds * 3 || pressure >= 0.6 {
            self.permitsIntermediateObservations = false
        } else if !self.permitsIntermediateObservations, computeSeconds * 5 < audioSeconds * 2, pressure < 0.4 {
            self.permitsIntermediateObservations = true
        }
    }
}

/// Measures owned window work across executor hops. Waiting for future PCM is excluded;
/// awaited protected publication remains charged because it delays the next live window.
final nonisolated class MeetingPCMWindowComputeTiming: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> TimeInterval
    private let started: TimeInterval
    private var excluded: TimeInterval = 0

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.started = now()
    }

    func beginExclusion() -> TimeInterval { self.now() }

    func endExclusion(since start: TimeInterval) {
        let interval = max(0, self.now() - start)
        self.lock.withLock { self.excluded += interval }
    }

    var computeSeconds: TimeInterval {
        self.lock.withLock { max(0, self.now() - self.started - self.excluded) }
    }
}

/// Holds the existing native loading scope open without running inference in its idle task.
/// A later consumer borrows the ready factory once in its own TaskLocal context. Cleanup
/// cancels and joins that consumer before releasing and joining the parked loading scope.
final nonisolated class MeetingRetainedDiarizationScope: Sendable {
    private actor State {
        private var factory: (any MeetingNemotronDiarizerFactory)?
        private var readyWaiters: [CheckedContinuation<Void, Error>] = []
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var borrowWaiters: [CheckedContinuation<Void, Never>] = []
        private var borrowID: UUID?
        private var cancelBorrow: (@Sendable () -> Void)?
        private var claimed = false
        private var closed = false
        private var finished = false
        private var failure: (any Error)?

        func publish(_ factory: any MeetingNemotronDiarizerFactory) throws {
            guard !self.closed, !self.finished, self.factory == nil else { throw CancellationError() }
            self.factory = factory
            let waiters = self.readyWaiters
            self.readyWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func ready() async throws {
            guard !self.closed else { throw CancellationError() }
            if self.factory != nil { return }
            if self.finished { throw self.failure ?? CancellationError() }
            try await withCheckedThrowingContinuation { self.readyWaiters.append($0) }
        }

        func waitForRelease() async {
            guard !self.closed else { return }
            await withCheckedContinuation { self.releaseWaiter = $0 }
        }

        func claim() throws -> (UUID, any MeetingNemotronDiarizerFactory) {
            guard !self.closed, !self.finished, !self.claimed, let factory = self.factory else {
                throw CancellationError()
            }
            self.claimed = true
            let id = UUID()
            self.borrowID = id
            return (id, factory)
        }

        func registerBorrow(id: UUID, cancel: @escaping @Sendable () -> Void) {
            guard self.borrowID == id else { cancel(); return }
            self.cancelBorrow = cancel
            if self.closed { cancel() }
        }

        func finishBorrow(id: UUID) {
            guard self.borrowID == id else { return }
            self.borrowID = nil
            self.cancelBorrow = nil
            let waiters = self.borrowWaiters
            self.borrowWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        func close() async {
            self.closed = true
            self.cancelBorrow?()
            let waiters = self.readyWaiters
            self.readyWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: CancellationError()) }
            if self.borrowID != nil {
                await withCheckedContinuation { self.borrowWaiters.append($0) }
            }
            self.releaseWaiter?.resume()
            self.releaseWaiter = nil
        }

        func finish(_ failure: (any Error)?) {
            self.finished = true
            self.failure = failure
            self.factory = nil
            let waiters = self.readyWaiters
            self.readyWaiters.removeAll()
            for waiter in waiters { waiter.resume(throwing: failure ?? CancellationError()) }
        }
    }

    private let state: State
    private let work: Task<Void, Error>

    init(open: @escaping @Sendable (
        @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> Void
    ) async throws -> Void) {
        let state = State()
        self.state = state
        self.work = Task.detached(priority: .utility) {
            do {
                try await open { factory in
                    try await state.publish(factory)
                    await state.waitForRelease()
                }
                await state.finish(nil)
            } catch {
                await state.finish(error)
                throw error
            }
        }
    }

    func waitUntilReady() async throws {
        do {
            try await withTaskCancellationHandler {
                try await self.state.ready()
                try Task.checkCancellation()
            } onCancel: {
                self.work.cancel()
                Task { await self.state.close() }
            }
        } catch {
            await self.cleanup()
            throw error
        }
    }

    func withFactory<Result: Sendable>(
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> Result
    ) async throws -> Result {
        let (id, factory) = try await self.state.claim()
        // This task inherits the actual meeting caller's context, never the parked idle
        // scope's grant or pipeline correlation. Native work remains serial in the body.
        let consumer = Task { try await body(factory) }
        await self.state.registerBorrow(id: id, cancel: { consumer.cancel() })
        do {
            let result = try await withTaskCancellationHandler {
                try await consumer.value
            } onCancel: { consumer.cancel() }
            try Task.checkCancellation()
            await self.state.finishBorrow(id: id)
            await self.cleanup()
            return result
        } catch {
            await self.state.finishBorrow(id: id)
            await self.cleanup()
            throw error
        }
    }

    func cleanup() async {
        self.work.cancel()
        await self.state.close()
        _ = await self.work.result
    }
}

/// Adapter-owned prepared weights only. No audio lease, attempt, track, diarizer state or
/// transcript exists until the normal meeting controller consumes this exact pair.
private final nonisolated class MeetingIdleParakeetNemotronResources: MeetingIdlePreparedResource, @unchecked Sendable {
    let configuration: MeetingFinalProcessingConfiguration
    let artifact: MeetingNemotronModelArtifact
    let asr: MeetingASRPreparedProvider
    let speakerScope: MeetingRetainedDiarizationScope
    var configurationIdentity: String { self.configuration.identityFingerprint }
    private let lock = NSLock()
    private var adopted = false
    private var claimed = false
    private var closed = false

    init(configuration: MeetingFinalProcessingConfiguration, artifact: MeetingNemotronModelArtifact,
         asr: MeetingASRPreparedProvider, speakerScope: MeetingRetainedDiarizationScope) {
        self.configuration = configuration
        self.artifact = artifact
        self.asr = asr
        self.speakerScope = speakerScope
    }

    func adopt(configuration: MeetingFinalProcessingConfiguration, artifact: MeetingNemotronModelArtifact) throws {
        try self.lock.withLock {
            guard !self.closed, !self.adopted, !self.claimed,
                  self.configuration == configuration, self.artifact == artifact else {
                throw MeetingModelResidencyError.staleGrant
            }
            self.adopted = true
        }
    }

    func claim(configuration: MeetingFinalProcessingConfiguration, artifact: MeetingNemotronModelArtifact) throws {
        try self.lock.withLock {
            guard !self.closed, self.adopted, !self.claimed,
                  self.configuration == configuration, self.artifact == artifact else {
                throw MeetingModelResidencyError.staleGrant
            }
            self.claimed = true
        }
    }

    func cleanup() async {
        self.lock.withLock { self.closed = true }
        await self.speakerScope.cleanup()
        await self.asr.cleanup()
    }
}

private final nonisolated class MeetingIdleNativeResourceSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var resource: MeetingIdleParakeetNemotronResources?

    func adopt(_ resource: MeetingIdleParakeetNemotronResources, configuration: MeetingFinalProcessingConfiguration,
               artifact: MeetingNemotronModelArtifact) throws {
        try self.lock.withLock {
            guard self.resource == nil else { throw MeetingModelResidencyError.busy }
            try resource.adopt(configuration: configuration, artifact: artifact)
            self.resource = resource
        }
    }

    func take() -> MeetingIdleParakeetNemotronResources? {
        self.lock.withLock {
            let resource = self.resource
            self.resource = nil
            return resource
        }
    }
}

/// Small attempt-local identity evidence, protected separately from model residency.
/// No PCM or audio files are retained here. The existing matcher receives a bounded
/// complete-link reference set; uncertain/new voices beyond that limit stay unassigned.
final nonisolated class MeetingPCMIdentityState: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptID: UUID?
    private var busy = false
    private var profiles: [MeetingSpeakerVoiceProfile] = []
    private var speakers: [MeetingSessionSpeaker] = []
    private var previewPacing = MeetingPCMPreviewPacing()
    private var resourcePin: (attemptID: UUID, configuration: String, artifact: MeetingNemotronModelArtifact?)?

    func pin(attemptID: UUID, configuration: String, artifact: MeetingNemotronModelArtifact?) throws {
        try self.lock.withLock {
            guard !self.busy else { throw MeetingParakeetNemotronRuntimeError.concurrentPCMWindow }
            if let pin = self.resourcePin, pin.attemptID == attemptID {
                guard pin.configuration == configuration else { throw MeetingModelResidencyError.staleGrant }
                guard pin.artifact == artifact else {
                    throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact?.packageURL.path ?? "")
                }
                return
            }
            self.resourcePin = (attemptID, configuration, artifact)
        }
    }

    func pinnedArtifact(attemptID: UUID, configuration: String) throws -> MeetingNemotronModelArtifact? {
        try self.lock.withLock {
            guard let pin = self.resourcePin, pin.attemptID == attemptID,
                  pin.configuration == configuration else { throw MeetingModelResidencyError.staleGrant }
            return pin.artifact
        }
    }

    func begin(attemptID: UUID) throws -> (profiles: [MeetingSpeakerVoiceProfile], speakers: [MeetingSessionSpeaker], permitsIntermediateObservations: Bool) {
        try self.lock.withLock {
            guard !self.busy else { throw MeetingParakeetNemotronRuntimeError.concurrentPCMWindow }
            if self.attemptID != attemptID {
                self.attemptID = attemptID
                self.profiles.removeAll()
                self.speakers.removeAll()
                self.previewPacing = MeetingPCMPreviewPacing()
            }
            self.busy = true
            return (self.profiles, self.speakers, self.previewPacing.permitsIntermediateObservations)
        }
    }

    func commit(profiles: [MeetingSpeakerVoiceProfile], batch: MeetingPCMTranscriptBatch) {
        self.lock.withLock {
            self.profiles = Array(profiles.prefix(MeetingSpeakerVoiceSamples.maximumProfiles))
            self.speakers = batch.mergingSpeakers(into: self.speakers)
        }
    }

    func recordCompute(computeSeconds: TimeInterval, audioSeconds: TimeInterval) {
        self.lock.withLock { self.previewPacing.record(computeSeconds: computeSeconds, audioSeconds: audioSeconds) }
    }

    func end() { self.lock.withLock { self.busy = false } }
}

#if arch(arm64)

/// Shared-weight Nemotron factory: one `SortformerModels` load, fresh streaming state for each
/// diarizer it makes. The backend makes one per track, so slots never merge across tracks.
private final nonisolated class NemotronDiarizerFactory: MeetingNemotronDiarizerFactory, @unchecked Sendable {
    let config: SortformerConfig
    let models: SortformerModels
    private let lock = NSLock()
    private var created: [SortformerDiarizer] = []

    init(config: SortformerConfig, models: SortformerModels) {
        self.config = config
        self.models = models
    }

    func makeDiarizer(epoch _: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
        try Task.checkCancellation()
        // Retain only enough raw probabilities for post-processing context. Final speaker
        // intervals remain available for whole-recording assignment; model cache stays fixed.
        var timelineConfig = DiarizerTimelineConfig.sortformerDefault
        timelineConfig.maxStoredFrames = 4_096
        let diarizer = SortformerDiarizer(config: self.config, timelineConfig: timelineConfig)
        diarizer.initialize(models: self.models)
        self.lock.withLock { self.created.append(diarizer) }
        return NemotronDiarizerSession(diarizer: diarizer)
    }

    func cleanup() {
        let diarizers = self.lock.withLock {
            let pending = self.created
            self.created.removeAll()
            return pending
        }
        for diarizer in diarizers {
            diarizer.cleanup()
        }
    }
}

private nonisolated struct NemotronDiarizerSession: MeetingNemotronDiarizerSession, @unchecked Sendable {
    // The diarizer is used strictly serially: one epoch, one caller, one call.
    let diarizer: SortformerDiarizer

    func diarize(source: any MeetingPCMReplaySource) async throws -> [MeetingNemotronSpeakerSegment] {
        try Task.checkCancellation()
        let began = MeetingPCMRuntimeDiagnostics.begin(.diarize)
        defer { MeetingPCMRuntimeDiagnostics.completed(.diarize, since: began, samples: source.totalSampleCount) }
        // This is a stopped recording replay, never a live diarization path. Feed bounded
        // decoded slices to the SAME model state, drain every available result, then finalize
        // exactly once. No processComplete call can reset speaker slots between slices.
        try await source.replay { samples in
            try autoreleasepool {
                _ = try self.diarizer.process(samples: samples, sourceSampleRate: nil)
                while try self.diarizer.process() != nil { try Task.checkCancellation() }
            }
        }
        try autoreleasepool { _ = try self.diarizer.finalizeSession() }
        try Task.checkCancellation()
        return self.segments(from: self.diarizer.timeline, duration: Double(source.totalSampleCount) / 16_000)
    }

    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] {
        try Task.checkCancellation()
        let began = MeetingPCMRuntimeDiagnostics.begin(.diarize)
        defer { MeetingPCMRuntimeDiagnostics.completed(.diarize, since: began, samples: samples.count) }
        // The native prediction loop is synchronous. Drain its Objective-C tensors
        // before this phase releases weights and another model becomes resident.
        let timeline = try autoreleasepool {
            try self.diarizer.processComplete(
                samples,
                sourceSampleRate: nil,
                keepingEnrolledSpeakers: false,
                finalizeOnCompletion: true
            )
        }
        try Task.checkCancellation()
        return self.segments(from: timeline, duration: Double(samples.count) / 16_000)
    }

    private func segments(from timeline: DiarizerTimeline, duration physicalDuration: TimeInterval) -> [MeetingNemotronSpeakerSegment] {
        return timeline.speakers
            .sorted { $0.key < $1.key }
            .flatMap { index, speaker in
                speaker.finalizedSegments.compactMap { segment in
                    // FluidAudio's finalize() promotes tentative segments into this
                    // finalized list but leaves their old isFinalized flag untouched.
                    // processComplete finalized the timeline; trust its finalized list.
                    let start = max(0, min(physicalDuration, TimeInterval(segment.startTime)))
                    let end = max(0, min(physicalDuration, TimeInterval(segment.endTime)))
                    guard start.isFinite, end.isFinite, end > start else { return nil }
                    return MeetingNemotronSpeakerSegment(
                        slotIndex: index,
                        start: start,
                        end: end
                    )
                }
            }
    }
}

#endif

/// The prepared provider session. The inherited interface name is retained; both references use ASRService's
/// own main-actor scope and meeting executor, never from the caller's context directly.
private nonisolated struct PreparedParakeetASRSession: MeetingParakeetASRSession, @unchecked Sendable {
    let asrService: any MeetingASRServicing
    let provider: any TranscriptionProvider

    func allowsIntermediatePCMObservations() async -> Bool {
        #if os(iOS)
        // Background audio capture still requires canonical recognition. Avoid decoding
        // speculative prefixes for an interface that cannot display their updates.
        await MainActor.run { UIApplication.shared.applicationState != .background }
        #else
        true
        #endif
    }

    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        let began = MeetingPCMRuntimeDiagnostics.begin(.asrInfer)
        defer { MeetingPCMRuntimeDiagnostics.completed(.asrInfer, since: began, samples: samples.count) }
        return try await self.asrService.transcribeMeetingSamplesWithTimings(samples, provider: self.provider)
    }
}

final nonisolated class MeetingParakeetNemotronRuntime: MeetingParakeetNemotronRunning {
    private let asrServiceProvider: @MainActor () -> any MeetingASRServicing
    private let modelLocator: any MeetingNemotronModelLocating
    private let voiceModelDirectory: URL
    private let usesDefaultVoiceModelDirectory: Bool
    private let ownerVoiceVerificationEnabled: Bool
    private let pcmIdentityState = MeetingPCMIdentityState()
    private let idleResources = MeetingIdleNativeResourceSlot()
    let ownerVoiceProfileSnapshot: MeetingOwnerVoiceProfileSnapshot?
    private let compiledNemotron = MeetingNemotronCompiledModelOwner { source, target in
        #if arch(arm64)
        let began = MeetingPCMRuntimeDiagnostics.begin(.compile)
        defer { MeetingPCMRuntimeDiagnostics.completed(.compile, since: began) }
        let temporary = try await MLModel.compileModel(at: source)
        // CoreML returns a newly compiled temporary directory. Adopt only this derivative,
        // never an installed source package or another model owner's cache.
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: target)
        #else
        throw MeetingParakeetNemotronRuntimeError.unsupportedArchitecture
        #endif
    }
    private let pcmSpeakerNameFormat = PichiLocalization.text("Speaker %lld")

    init(
        asrServiceProvider: @escaping @MainActor () -> any MeetingASRServicing,
        modelLocator: any MeetingNemotronModelLocating,
        voiceModelDirectory: URL? = nil,
        ownerVoiceProfileSnapshot: MeetingOwnerVoiceProfileSnapshot? = try? MeetingOwnerVoiceProfileStore().load()
    ) {
        let ownerVoiceVerificationEnabled = modelLocator.supportsOwnerVoiceVerification
        self.ownerVoiceVerificationEnabled = ownerVoiceVerificationEnabled
        self.ownerVoiceProfileSnapshot = ownerVoiceVerificationEnabled ? ownerVoiceProfileSnapshot : nil
        self.asrServiceProvider = asrServiceProvider
        self.modelLocator = modelLocator
        self.voiceModelDirectory = voiceModelDirectory ?? MeetingSpeakerVoiceModelArtifacts.packageURL()
        self.usesDefaultVoiceModelDirectory = voiceModelDirectory == nil
    }
    func preparePCMResources(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws {
        try Task.checkCancellation()
        _ = try MeetingProviderOptions.resolve(configuration)
        let artifact: MeetingNemotronModelArtifact?
        if configuration.speakerLabelsEnabled {
            guard !PichiMeetingProviderFactory.isTranscriptOnlyDiarizationFingerprint(configuration.diarizationFingerprint) else {
                throw MeetingNemotronModelReadinessError.modelNotInstalled(path: MeetingNemotronModelLocator.defaultPackageURL().path)
            }
            let located = try self.modelLocator.locate()
            artifact = located
            if configuration.effectiveSpeakerProcessingMode == .streaming {
                try Self.validateStreamingSelection(artifact: located, configuration: configuration)
            }
            if self.ownerVoiceVerificationEnabled,
               configuration.effectiveSpeakerProcessingMode != .streaming || self.ownerVoiceProfileSnapshot != nil {
                do {
                    if self.usesDefaultVoiceModelDirectory { try MeetingSpeakerVoiceModelArtifacts.validateRootContainment() }
                    try MeetingSpeakerVoiceModelArtifacts.validate(at: self.voiceModelDirectory)
                } catch {
                    if configuration.effectiveSpeakerProcessingMode != .streaming { throw error }
                    // Explicit owner identity is optional. A missing encoder cannot discard
                    // a valid anonymous streaming meeting; encode revalidates the pinned files.
                    DebugLogger.shared.info("mode=streaming owner_verification_resources=unavailable", source: "MeetingPCMRuntime")
                }
            }
            // Freeze validated selection only. Compile/open weights inside the owned model
            // scope: the offline speaker phase or the explicitly prepared streaming pair.
        } else { artifact = nil }
        try Task.checkCancellation()
        try self.pcmIdentityState.pin(attemptID: attemptID, configuration: configuration.identityFingerprint, artifact: artifact)
    }

    var supportsStreamingPCMProcessing: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }

    /// The registered installed-provider capability rejects unsupported or missing ASR
    /// selections before preparation. Existing native open scopes retain the actual weights.
    func prepareIdleResources(configuration: MeetingFinalProcessingConfiguration) async throws -> (any MeetingIdlePreparedResource)? {
        #if arch(arm64)
        try Task.checkCancellation()
        guard configuration.speakerLabelsEnabled, configuration.effectiveSpeakerProcessingMode == .streaming,
              await self.asrServiceProvider().supportsPreparedProviderAdoption else { return nil }
        DebugLogger.shared.info("idle_preparation=started resources=streaming", source: "MeetingPCMRuntime")
        _ = try MeetingProviderOptions.resolve(configuration)
        let artifact = try self.modelLocator.locate()
        try Self.validateStreamingSelection(artifact: artifact, configuration: configuration)
        guard let asr = try await Self.prepareIdleASR(configuration: configuration) else { return nil }
        let speakerScope = MeetingRetainedDiarizationScope { body in
            _ = try await self.withNemotronDiarization(artifact: artifact) { factory in
                try await body(factory)
                return MeetingNemotronPhaseResult()
            }
        }
        let resources = MeetingIdleParakeetNemotronResources(configuration: configuration, artifact: artifact,
            asr: asr, speakerScope: speakerScope)
        do {
            try await speakerScope.waitUntilReady()
            try Task.checkCancellation()
            if self.ownerVoiceProfileSnapshot != nil,
               artifact.profile.verifiesLiveStreamingOwner(implementationFingerprint: configuration.diarizationFingerprint) {
                let began = MeetingPCMRuntimeDiagnostics.begin(.voicePrepare)
                defer { MeetingPCMRuntimeDiagnostics.completed(.voicePrepare, since: began) }
                do {
                    let directory = self.voiceModelDirectory
                    let validateRoot = self.usesDefaultVoiceModelDirectory
                    // Idle preparation is requested by the UI owner. Use the existing
                    // joined blocking executor so native compilation cannot inherit it.
                    try await TranscriptionExecutor().runBlocking {
                        try MeetingSpeakerVoiceEncoder.prepare(directory: directory, validateDefaultRoot: validateRoot)
                    }
                } catch {
                    try Task.checkCancellation()
                    // Optional voice preparation never replaces a valid anonymous recording.
                    DebugLogger.shared.info("idle_preparation=owner_encoder_unavailable", source: "MeetingPCMRuntime")
                }
            }
            try Task.checkCancellation()
            guard try self.modelLocator.recheck(artifact) == artifact else {
                throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
            }
            DebugLogger.shared.info("idle_preparation=ready resources=streaming", source: "MeetingPCMRuntime")
            return resources
        } catch {
            await resources.cleanup()
            throw error
        }
        #else
        return nil
        #endif
    }

    @MainActor
    private static func prepareIdleASR(configuration: MeetingFinalProcessingConfiguration) async throws -> MeetingASRPreparedProvider? {
        let began = MeetingPCMRuntimeDiagnostics.begin(.asrPrepare)
        defer { MeetingPCMRuntimeDiagnostics.completed(.asrPrepare, since: began) }
        guard let provider = try PichiMeetingProviderFactory.makeInstalledProviderForIdle(configuration) else { return nil }
        let prepared = MeetingASRPreparedProvider(configuration: configuration, provider: provider)
        do {
            try await provider.prepare(progressHandler: nil)
            try Task.checkCancellation()
            guard provider.isReady else { throw MeetingModelResidencyError.unsupportedProvider }
            return prepared
        } catch {
            await prepared.cleanup()
            throw error
        }
    }

    func adoptIdleResources(_ resource: any MeetingIdlePreparedResource,
                            configuration: MeetingFinalProcessingConfiguration) async throws {
        try Task.checkCancellation()
        guard let resources = resource as? MeetingIdleParakeetNemotronResources else {
            throw MeetingModelResidencyError.unsupportedProvider
        }
        let artifact = try self.modelLocator.locate()
        try Self.validateStreamingSelection(artifact: artifact, configuration: configuration)
        guard try self.modelLocator.recheck(artifact) == artifact else {
            throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
        }
        try await resources.speakerScope.waitUntilReady()
        try Task.checkCancellation()
        try self.idleResources.adopt(resources, configuration: configuration, artifact: artifact)
        DebugLogger.shared.info("idle_preparation=adopted resources=streaming", source: "MeetingPCMRuntime")
    }

    private func takeIdleResources() -> MeetingIdleParakeetNemotronResources? {
        self.idleResources.take()
    }

    static func validateStreamingSelection(artifact: MeetingNemotronModelArtifact,
                                          configuration: MeetingFinalProcessingConfiguration) throws {
        guard configuration.speakerLabelsEnabled, configuration.effectiveSpeakerProcessingMode == .streaming,
              artifact.compiledModelURL != nil, artifact.profile.isExperimental,
              artifact.profile.computePreference == .cpuOnly,
              artifact.profile.acceptsStreamingImplementationFingerprint(configuration.diarizationFingerprint) else {
            throw MeetingModelResidencyError.staleGrant
        }
    }

    private final nonisolated class StreamingOwnerEvidenceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: MeetingPreparedStreamingRuntime.OwnerEvidence?
        func set(_ value: MeetingPreparedStreamingRuntime.OwnerEvidence?) { self.lock.withLock { self.value = value } }
        func take() -> MeetingPreparedStreamingRuntime.OwnerEvidence? {
            self.lock.withLock { let value = self.value; self.value = nil; return value }
        }
    }

    /// Retain one prepared ASR and one continuous speaker state on the controller's owned
    /// stack. The parent owns the outer residency grant. Both native engines run serially;
    /// returning from the body joins cleanup before either model scope can be released.
    func withPreparedStreamingPCM(
        trackID: MeetingAudioTrackID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        onProgress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void,
        body: @escaping @Sendable (any MeetingPreparedStreamingPCMProcessing) async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        _ = try MeetingProviderOptions.resolve(configuration)
        guard let artifact = try self.pcmIdentityState.pinnedArtifact(
            attemptID: attemptID, configuration: configuration.identityFingerprint) else {
            throw MeetingModelResidencyError.staleGrant
        }
        try Self.validateStreamingSelection(artifact: artifact, configuration: configuration)
        _ = try self.pcmIdentityState.begin(attemptID: attemptID)
        defer { self.pcmIdentityState.end() }
        let ownerEvidence = StreamingOwnerEvidenceBox()
        let adaptiveOwnerEvidence = artifact.profile.usesAdaptiveStreamingOwnerEvidence(
            implementationFingerprint: configuration.diarizationFingerprint)
        let ownerPolicy: MeetingOwnerVoiceVerifier.Policy = artifact.profile.requiresFullStreamingOwnerEvidence(
            implementationFingerprint: configuration.diarizationFingerprint) ? .streamingV4
            : adaptiveOwnerEvidence ? .streamingV2 : .legacy
        let collectOwnerEvidence = self.ownerVoiceProfileSnapshot != nil
            && artifact.profile.verifiesStreamingOwner(implementationFingerprint: configuration.diarizationFingerprint)
        let liveOwnerVerification = artifact.profile.verifiesLiveStreamingOwner(
            implementationFingerprint: configuration.diarizationFingerprint)
        let preserveOwnerCadenceAtEOF = artifact.profile.preservesStreamingOwnerCadenceAtEOF(
            implementationFingerprint: configuration.diarizationFingerprint)
        let idleResources = self.takeIdleResources()
        do {
            try idleResources?.claim(configuration: configuration, artifact: artifact)
            _ = try await self.withPreparedASR(attemptID: attemptID, configuration: configuration,
                preparedProvider: idleResources?.asr) { asr in
                let consume: @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult = { factory in
                    let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)
                    guard let diarizer = try await factory.makeDiarizer(epoch: epoch)
                        as? any MeetingIncrementalNemotronDiarizerSession else {
                        throw MeetingPCMInputError.unsupportedRuntime
                    }
                    let session = MeetingPreparedStreamingRuntime(runtime: self, asr: asr, diarizer: diarizer,
                        trackID: trackID, attemptID: attemptID, configuration: configuration,
                        speakerNameFormat: self.pcmSpeakerNameFormat, collectOwnerEvidence: collectOwnerEvidence,
                        useAdaptiveOwnerEvidence: adaptiveOwnerEvidence,
                        verifyOwnerDuringCapture: liveOwnerVerification,
                        ownerVerificationPolicy: ownerPolicy,
                        preserveOwnerCadenceAtEOF: preserveOwnerCadenceAtEOF, onProgress: onProgress)
                    do {
                        try await body(session)
                        try Task.checkCancellation()
                        try session.requireFinished()
                        if !liveOwnerVerification { ownerEvidence.set(try session.ownerEvidence()) }
                        await session.cleanup()
                    } catch {
                        await session.cleanup()
                        throw error
                    }
                    return MeetingNemotronPhaseResult()
                }
                if let idleResources {
                    _ = try await idleResources.speakerScope.withFactory(consume)
                } else {
                    _ = try await self.withNemotronDiarization(artifact: artifact, consume)
                }
                return MeetingParakeetPhaseResult()
            }
            await idleResources?.cleanup()
            if idleResources != nil { DebugLogger.shared.info("idle_preparation=retired beforeOwnerVoice=true", source: "MeetingPCMRuntime") }
        } catch {
            await idleResources?.cleanup()
            throw error
        }
        // Both inference scopes and their native cleanup have joined. The box retains only
        // bounded admitted clips, so the additional encoder never co-resides with either model.
        try Task.checkCancellation()
        if let evidence = ownerEvidence.take() {
            let profiles: [MeetingSpeakerVoiceProfile]
            do { profiles = try await self.speakerVoiceProfiles(samples: evidence.samples) }
            catch {
                try Task.checkCancellation()
                DebugLogger.shared.info("mode=streaming owner_verification=unavailable preservedAnonymousSpeech=true", source: "MeetingPCMRuntime")
                return
            }
            try Task.checkCancellation()
            let clipFrames = MeetingOwnerVoiceVerifier.clipFramesByToken(samples: evidence.samples, profiles: profiles)
            let confirmed = MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.ownerVoiceProfileSnapshot,
                profiles: profiles, policy: ownerPolicy, clipFramesByToken: clipFrames,
                diagnostics: MeetingPCMRuntimeDiagnostics.ownerVerificationObserver(samples: evidence.samples, profiles: profiles,
                    streaming: true, clipFramesByToken: clipFrames))
            DebugLogger.shared.info("mode=streaming owner_verification=completed profileCount=\(profiles.count) confirmedCount=\(confirmed.count)", source: "MeetingPCMRuntime")
            let identities = MeetingTranscriptAssembler.applyingLocalUserTokens(to: evidence.speakers,
                attemptID: attemptID, tokens: confirmed)
            let value = evidence.observation
            try await onProgress(.init(batch: .init(segments: [], speakers: identities), activity: value.activity,
                acceptedThroughSample: value.acceptedThroughSample, processedThroughSample: value.processedThroughSample,
                retainedFromSample: value.retainedFromSample, isFinal: false))
            try Task.checkCancellation()
        }
    }

    /// The strict privacy capture sink supplies bounded mono16k PCM directly. Each
    /// window uses the original residency scope, diarizer, prepared ASR and assembler;
    /// it never invokes a file materializer or writes an intermediate audio file.
    func recognizePCM(
        samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration
    ) async throws -> MeetingPCMTranscriptBatch {
        try await self.recognizePCM(samples: samples, offset: offset, trackID: trackID,
                                    attemptID: attemptID, configuration: configuration, preview: nil)
    }

    func recognizePCM(
        samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
    ) async throws -> MeetingPCMTranscriptBatch {
        guard !samples.isEmpty, samples.count <= 320_000, samples.allSatisfy(\.isFinite),
              offset.isFinite, offset >= 0, offset <= 31_536_000 else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        _ = try MeetingProviderOptions.resolve(configuration)
        _ = try self.pcmIdentityState.pinnedArtifact(attemptID: attemptID, configuration: configuration.identityFingerprint)
        let prior = try self.pcmIdentityState.begin(attemptID: attemptID)
        defer { self.pcmIdentityState.end() }
        // The pipeline owns the outer withMeetingModelResidency scope, just as it
        // does for file-backed epochs. Nested resource claims are not permitted.
        let pipelineID = DebugLogger.pipelineID
        let work = Task.detached(priority: .userInitiated) {
            try await DebugLogger.$pipelineID.withValue(pipelineID) {
                try await self.recognizePCMPhases(samples: samples, offset: offset, trackID: trackID,
                                                 attemptID: attemptID, configuration: configuration,
                                                 priorProfiles: prior.profiles, priorSpeakers: prior.speakers,
                                                 preview: preview)
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    var supportsProgressivePCMInput: Bool { true }

    /// One prepared provider consumes growing observations serially. Its final
    /// hypothesis is checkpointed without running speaker models during capture.
    func recognizePCM(
        window: MeetingPCMProgressiveWindow, offset: TimeInterval, trackID: UUID,
        attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
    ) async throws -> MeetingPCMTranscriptBatch {
        guard offset.isFinite, offset >= 0, offset <= 31_536_000 else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        _ = try MeetingProviderOptions.resolve(configuration)
        _ = try self.pcmIdentityState.pinnedArtifact(attemptID: attemptID, configuration: configuration.identityFingerprint)
        let prior = try self.pcmIdentityState.begin(attemptID: attemptID)
        defer { self.pcmIdentityState.end() }
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: Int((offset * 16_000).rounded()))
        let pipelineID = DebugLogger.pipelineID
        let work = Task.detached(priority: .userInitiated) {
            try await DebugLogger.$pipelineID.withValue(pipelineID) {
                let timing = MeetingPCMWindowComputeTiming()
                let phase = try await self.withPreparedASR(attemptID: attemptID, configuration: configuration) { session in
                    try await self.recognizeProgressivePCMPhase(session: session, window: window,
                        offset: offset, epoch: epoch, attemptID: attemptID, timing: timing,
                        permitsIntermediateObservations: prior.permitsIntermediateObservations, preview: preview)

                }
                try Task.checkCancellation()
                guard phase.outputs.count == 1, let output = phase.outputs.first,
                      output.sampleCount == phase.boundedPCMSamples.count else {
                    throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                }
                // withPreparedASR has joined and released its weights. Live canonical
                // checkpoints remain transcript-only; whole-recording speakers run after Stop.
                var batch = try await self.attributePCMSpeech(samples: phase.boundedPCMSamples, output: output,
                    epoch: epoch, offset: offset, attemptID: attemptID, configuration: configuration,
                    priorProfiles: prior.profiles, priorSpeakers: prior.speakers)
                let physicalSampleCount = phase.boundedPCMSourceSampleCount ?? phase.boundedPCMSamples.count
                guard physicalSampleCount >= output.sampleCount, physicalSampleCount <= 320_000 else {
                    throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                }
                if output.sampleCount < physicalSampleCount {
                    batch.isComplete = false
                    for index in batch.segments.indices { batch.segments[index].completeness = .incompleteTrack }
                }
                DebugLogger.shared.info("progressive_coverage offset=\(offset) coveredFrames=\(output.sampleCount) physicalFrames=\(physicalSampleCount) complete=\(batch.isComplete)", source: "MeetingPCMRuntime")
                let computeSeconds = timing.computeSeconds
                self.pcmIdentityState.recordCompute(computeSeconds: computeSeconds,
                    audioSeconds: Double(physicalSampleCount) / 16_000)
                let computeMS = Int64(min(86_400, computeSeconds) * 1_000)
                DebugLogger.shared.info("preview_headroom computeMS=\(computeMS) physicalFrames=\(physicalSampleCount) intermediate=\(prior.permitsIntermediateObservations)", source: "MeetingPCMRuntime")
                return batch
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Shared bounded ASR loop. A prepared streaming adapter can consume each exact PCM
    /// delta on the same owned worker before ASR, without owning a second whole window.
    func recognizeProgressivePCMPhase(
        session: any MeetingParakeetASRSession, window: MeetingPCMProgressiveWindow,
        offset: TimeInterval, epoch: MeetingAnalysisEpochID, attemptID: UUID,
        timing: MeetingPCMWindowComputeTiming, permitsIntermediateObservations: Bool,
        preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?,
        consumePCM: (@Sendable ([Float], Int) async throws -> Void)? = nil
    ) async throws -> MeetingParakeetPhaseResult {
        var samples: [Float] = []
        var output: MeetingParakeetEpochOutput?
        var inferredSampleCount = 0
        var sealed = false
        while true {
            let waitStarted = timing.beginExclusion()
            let next: MeetingPCMWindowUpdate?
            do {
                next = try await window.next()
                timing.endExclusion(since: waitStarted)
            } catch {
                timing.endExclusion(since: waitStarted)
                throw error
            }
            guard var update = next else { break }
            try Task.checkCancellation()
            guard update.totalFrames > 0, update.totalFrames <= 320_000,
                  update.totalFrames == samples.count + update.samples.count,
                  !update.samples.isEmpty || update.isFinal,
                  update.samples.allSatisfy(\.isFinite) else {
                throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
            }
            // The prior native inference has joined before this append.
            // Incoming deltas live in the consumer's charged queue meanwhile.
            let hasNewPCM = !update.samples.isEmpty
            if hasNewPCM, let consumePCM {
                try await consumePCM(update.samples, Int((offset * 16_000).rounded()) + samples.count)
                try Task.checkCancellation()
            }
            if samples.isEmpty { samples = update.samples }
            else { samples.append(contentsOf: update.samples) }
            update.samples = []
            // A pause closes exactly this delivered prefix. Capture may have advanced
            // while its VAD evidence arrived; the transport transfers that untouched
            // suffix to the next window, preserving the immutable inference input.
            if !update.isFinal,
               await window.sealAtSpeechBoundaryIfConfident(totalFrames: update.totalFrames, offset: offset) {
                try Task.checkCancellation()
                MeetingTimelineTrace.shared?.record("asr_pause_endpoint", fields: [
                    "attemptID": attemptID.uuidString, "windowOrdinal": String(epoch.ordinal),
                    "sourceEndSample": String(Int((offset * 16_000).rounded()) + samples.count)])
                // The following empty final marker runs final ASR once, even below
                // the optional preview cadence or when headroom suppresses previews.
                continue
            }
            let sessionAllowsObservations = await session.allowsIntermediatePCMObservations()
            try Task.checkCancellation()
            // Consume every delta regardless of optional observations. Lifecycle changes
            // cannot let an empty final marker reuse an older, shorter inferred prefix.
            // Subsecond PCM delivery serves VAD and the incremental diarizer. Buffered
            // providers re-decode a complete prefix, so do not repeat batch inference
            // on every such delivery. Final endpoints always bypass this cadence.
            let previewIsDue = !window.usesPauseEndpoint || samples.count - inferredSampleCount >= 48_000
            let shouldInfer = update.isFinal ? inferredSampleCount != samples.count
                : previewIsDue && MeetingPCMPreviewPacing.shouldInfer(hasNewPCM: hasNewPCM, isFinal: false,
                    permitsIntermediateObservations: permitsIntermediateObservations && sessionAllowsObservations)
            if shouldInfer {
                let inferenceStarted = ProcessInfo.processInfo.systemUptime
                let inferenceID = UUID().uuidString
                var skippedNonSpeech = false
                MeetingTimelineTrace.shared?.record("asr_request", fields: ["attemptID": attemptID.uuidString,
                    "windowOrdinal": String(epoch.ordinal), "inferenceID": inferenceID,
                    "sourceOffsetSample": String(Int((offset * 16_000).rounded())),
                    "sampleCount": String(samples.count), "sealed": String(update.isFinal)])
                let recognized: (result: ASRTranscriptionResult, words: [ASRWordTiming])
                let alreadyAcceptedSpeech = output?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                var confidentlyNonSpeech = false
                if !alreadyAcceptedSpeech {
                    confidentlyNonSpeech = await window.confidentlyNonSpeech(start: offset, end: offset + Double(samples.count) / 16_000)
                }
                try Task.checkCancellation()
                if confidentlyNonSpeech {
                    // The same capture-owned VAD scores this complete physical interval.
                    // Speaker input above remains contiguous, and an empty result advances
                    // ASR coverage without inventing words or discarding an accepted prefix.
                    skippedNonSpeech = true
                    recognized = (ASRTranscriptionResult(text: "", confidence: 0), [])
                    DebugLogger.shared.info("progressive_nonspeech_skip offset=\(offset) frames=\(samples.count) sealed=\(update.isFinal)", source: "MeetingPCMRuntime")
                } else {
                    recognized = try await session.transcribeWithTimings(samples)
                }
                try Task.checkCancellation()
                inferredSampleCount = samples.count
                let observed = MeetingParakeetEpochOutput(epochID: epoch, text: recognized.result.text,
                    words: recognized.words, segmentTimings: recognized.result.segmentTimings,
                    sampleRate: 16_000, sampleCount: samples.count, spanSamples: [])
                MeetingTimelineTrace.shared?.record("asr_hypothesis", fields: ["attemptID": attemptID.uuidString,
                    "windowOrdinal": String(epoch.ordinal), "inferenceID": inferenceID,
                    "sourceOffsetSample": String(Int((offset * 16_000).rounded())), "sampleCount": String(samples.count),
                    "sealed": String(update.isFinal), "skippedConfidentNonSpeech": String(skippedNonSpeech),
                    "wallMilliseconds": String((ProcessInfo.processInfo.systemUptime - inferenceStarted) * 1_000),
                    "confidence": String(recognized.result.confidence),
                    "acceptedByPrefixPolicy": String(!observed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || output == nil || output?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)],
                    text: observed.text, words: observed.words.map { .init(text: $0.text, start: $0.start, end: $0.end) })
                // An empty observation can be silence or a provider's rejected
                // hypothesis. Neither invalidates speech already accepted for
                // a shorter prefix. Keep its original coverage and timings.
                let hasSpeech = !observed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if hasSpeech || output == nil || output?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                    output = observed
                }
                if let preview, hasSpeech || output?.sampleCount == observed.sampleCount {
                    try await preview(self.pcmSpeechObservation(output: observed, epoch: epoch,
                        offset: offset, duration: Double(samples.count) / 16_000,
                        attemptID: attemptID, isFinal: update.isFinal))
                }
                DebugLogger.shared.info("progressive_speech offset=\(offset) frames=\(samples.count) sealed=\(update.isFinal)", source: "MeetingPCMRuntime")
            }
            if update.isFinal {
                // A final longer observation may reject its tail. Seal
                // the retained accepted prefix at its own sample count,
                // even when the final update brought additional PCM.
                if let output, let preview,
                   (!hasNewPCM && !shouldInfer) || output.sampleCount != samples.count {
                    try await preview(self.pcmSpeechObservation(output: output, epoch: epoch,
                        offset: offset, duration: Double(output.sampleCount) / 16_000,
                        attemptID: attemptID, isFinal: true))
                }
                sealed = true
                break
            }
        }
        guard sealed, let output, output.sampleCount > 0, output.sampleCount <= samples.count else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        let physicalSampleCount = samples.count
        // Native inference has joined. Transfer only the same array's covered
        // prefix to attribution; the scalar records the consumed physical tail.
        samples.removeSubrange(output.sampleCount..<samples.count)
        MeetingTimelineTrace.shared?.record("asr_window_finalized", fields: ["attemptID": attemptID.uuidString,
            "windowOrdinal": String(epoch.ordinal), "sourceOffsetSample": String(Int((offset * 16_000).rounded())),
            "physicalSampleCount": String(physicalSampleCount), "acceptedSampleCount": String(output.sampleCount)],
            text: output.text, words: output.words.map { .init(text: $0.text, start: $0.start, end: $0.end) })
        return MeetingParakeetPhaseResult(outputs: [output], boundedPCMSamples: samples,
            boundedPCMSourceSampleCount: physicalSampleCount)
    }

    func pcmSpeechObservation(output: MeetingParakeetEpochOutput, epoch: MeetingAnalysisEpochID,
                                      offset: TimeInterval, duration: TimeInterval,
                                      attemptID: UUID, isFinal: Bool = true) throws -> MeetingPCMTranscriptBatch {
        let units = try MeetingParakeetNemotronBackend.pcmUnits(
            result: ASRTranscriptionResult(text: output.text, segmentTimings: output.segmentTimings),
            words: output.words, epoch: epoch, duration: duration, activity: [], identityTokens: [])
        var observation = try MeetingTranscriptAssembler(speakerNameFormat: self.pcmSpeakerNameFormat)
            .assemblePCMWindow(attemptID: attemptID, epoch: epoch, offset: offset, duration: duration,
                units: units, identityLinks: [], priorSpeakers: [])
        observation.isComplete = false
        observation.speechObservationIsFinal = isFinal
        observation.speechObservationIdentity = .init(attemptID: attemptID, epochID: epoch)
        observation.speechObservationHasNativeTiming = !units.isEmpty && (
            units.allSatisfy { $0.precision == .word }
                || !ASRSegmentTiming.validated(output.segmentTimings, text: output.text, duration: duration).isEmpty)
        for index in observation.segments.indices { observation.segments[index].status = .provisional }
        return observation
    }

    private func recognizePCMPhases(
        samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        priorProfiles: [MeetingSpeakerVoiceProfile], priorSpeakers: [MeetingSessionSpeaker],
        preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
    ) async throws -> MeetingPCMTranscriptBatch {
        try Task.checkCancellation()
        let duration = Double(samples.count) / 16_000
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: Int((offset * 16_000).rounded()))
        // Strict capture needs speech before expensive attribution. The prepared ASR scope
        // has released its weights when it returns. Retain only this bounded text/timing output
        // and reuse it for the canonical assembly after the separate speaker phases.
        let phase = try await self.withPreparedASR(attemptID: attemptID, configuration: configuration) { session in
            let output = try await session.transcribeWithTimings(samples)
            return MeetingParakeetPhaseResult(outputs: [.init(epochID: epoch, text: output.result.text,
                                                              words: output.words, segmentTimings: output.result.segmentTimings,
                                                              sampleRate: 16_000,
                                                              sampleCount: samples.count, spanSamples: [])])
        }
        try Task.checkCancellation()
        guard phase.outputs.count == 1, let output = phase.outputs.first else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        if let preview {
            try Task.checkCancellation()
            try await preview(self.pcmSpeechObservation(output: output, epoch: epoch, offset: offset,
                duration: duration, attemptID: attemptID))
            try Task.checkCancellation()
        }
        return try await self.attributePCMSpeech(samples: samples, output: output, epoch: epoch,
            offset: offset, attemptID: attemptID, configuration: configuration,
            priorProfiles: priorProfiles, priorSpeakers: priorSpeakers)
    }

    func attributePCMSpeech(samples: [Float], output: MeetingParakeetEpochOutput,
                                   epoch: MeetingAnalysisEpochID, offset: TimeInterval, attemptID: UUID,
                                   configuration: MeetingFinalProcessingConfiguration,
                                   priorProfiles: [MeetingSpeakerVoiceProfile],
                                   priorSpeakers: [MeetingSessionSpeaker]) async throws -> MeetingPCMTranscriptBatch {
        try Task.checkCancellation()
        let duration = Double(samples.count) / 16_000
        // Assemble the ASR-native words before assigning speakers. The caller either keeps
        // this transcript-only checkpoint or adds the continuous streaming epoch's evidence.
        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return MeetingPCMTranscriptBatch(segments: [])
        }
        let units = try MeetingParakeetNemotronBackend.pcmUnits(
            result: ASRTranscriptionResult(text: output.text, segmentTimings: output.segmentTimings),
            words: output.words, epoch: epoch, duration: duration, activity: [], identityTokens: [],
            speakerAttributionPolicy: configuration.speakerAttributionPolicy ?? .standard)
        return try MeetingTranscriptAssembler(speakerNameFormat: self.pcmSpeakerNameFormat)
            .assemblePCMWindow(attemptID: attemptID, epoch: epoch, offset: offset,
                duration: duration, units: units, priorSpeakers: priorSpeakers,
                speakerAttributionPolicy: configuration.speakerAttributionPolicy)
    }

    func diarizePCMRecording(
        source: any MeetingPCMReplaySource, transcript: MeetingPCMTranscriptBatch,
        trackID: MeetingAudioTrackID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration
    ) async throws -> MeetingPCMTranscriptBatch {
        try Task.checkCancellation()
        guard configuration.speakerLabelsEnabled, !transcript.segments.isEmpty else { return transcript }
        guard source.totalSampleCount > 0 else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
        guard let artifact = try self.pcmIdentityState.pinnedArtifact(
            attemptID: attemptID, configuration: configuration.identityFingerprint) else {
            throw MeetingModelResidencyError.staleGrant
        }
        _ = try self.pcmIdentityState.begin(attemptID: attemptID)
        defer { self.pcmIdentityState.end() }
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)
        let pipelineID = DebugLogger.pipelineID
        let work = Task.detached(priority: .userInitiated) {
            try await DebugLogger.$pipelineID.withValue(pipelineID ?? attemptID.uuidString) {
                let recordingBegan = MeetingPCMRuntimeDiagnostics.begin(.recordingDiarize)
                var recordingSucceeded = false
                defer {
                    MeetingPCMRuntimeDiagnostics.completed(.recordingDiarize, since: recordingBegan,
                        samples: source.totalSampleCount, succeeded: recordingSucceeded)
                }
                let replaySource: any MeetingPCMReplaySource = MeetingPCMRuntimeDiagnostics.detailedProfilingEnabled
                    ? MeetingProfiledPCMReplaySource(wrapping: source) : source
                let phase = try await self.withNemotronDiarization(artifact: artifact) { factory in
                    let diarizer = try await factory.makeDiarizer(epoch: epoch)
                    let began = MeetingPCMRuntimeDiagnostics.begin(.diarize)
                    var succeeded = false
                    defer {
                        MeetingPCMRuntimeDiagnostics.completed(.diarize, since: began,
                            samples: source.totalSampleCount, succeeded: succeeded)
                    }
                    let segments = try await diarizer.diarize(source: replaySource)
                    let duration = Double(source.totalSampleCount) / 16_000
                    guard segments.allSatisfy({ (0..<8).contains($0.slotIndex)
                        && $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                        && $0.end > $0.start && $0.end <= duration + 1e-6 }) else {
                        throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                    }
                    succeeded = true
                    return MeetingNemotronPhaseResult(activity: segments.map {
                        .init(token: .init(analysisEpochID: epoch, label: "slot-\($0.slotIndex)"), start: $0.start, end: $0.end)
                    })
                }
                // Nemotron has joined and released its weights before the optional owner
                // encoder loads. Stable global slots already establish anonymous identities.
                try Task.checkCancellation()
                var confirmedOwner = Set<MeetingBackendSpeakerToken>()
                if self.ownerVoiceProfileSnapshot != nil {
                    let segments = phase.activity.compactMap { activity -> MeetingNemotronSpeakerSegment? in
                        guard let slot = Int(activity.token.label.dropFirst("slot-".count)) else { return nil }
                        return .init(slotIndex: slot, start: activity.start, end: activity.end)
                    }
                    // This entry point historically applies the legacy batch policy. Keep
                    // that behavior for saved recipes; a direct V4 streaming request must
                    // still carry the same full-clip eligibility as its live/retry route.
                    let fullOwnerEvidence = configuration.effectiveSpeakerProcessingMode == .streaming
                        && artifact.profile.requiresFullStreamingOwnerEvidence(
                            implementationFingerprint: configuration.diarizationFingerprint)
                    // Saved batch recipes retain their original read-failure behavior.
                    // Only V4 treats a strict optional identity reread failure as abstention.
                    let legacyExcerpts = fullOwnerEvidence ? []
                        : try await MeetingSpeakerVoiceSamples.collect(epoch: epoch, source: source, segments: segments)
                    do {
                        let excerpts = fullOwnerEvidence
                            ? try await MeetingSpeakerVoiceSamples.collectFirstAndLatest(epoch: epoch, source: source,
                                segments: segments, requireSuccessfulRead: true)
                            : legacyExcerpts
                        let profiles = try await self.speakerVoiceProfiles(samples: excerpts)
                        let clipFrames = MeetingOwnerVoiceVerifier.clipFramesByToken(samples: excerpts, profiles: profiles)
                        let complete = !fullOwnerEvidence || MeetingOwnerVoiceVerifier.hasCompleteEncoderResults(
                            samples: excerpts, profiles: profiles)
                        confirmedOwner = complete ? MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.ownerVoiceProfileSnapshot, profiles: profiles,
                            policy: fullOwnerEvidence ? .streamingV4 : .legacy, clipFramesByToken: clipFrames,
                            diagnostics: MeetingPCMRuntimeDiagnostics.ownerVerificationObserver(samples: excerpts, profiles: profiles,
                                streaming: false, clipFramesByToken: clipFrames)) : []
                    } catch { try Task.checkCancellation() }
                }
                try Task.checkCancellation()
                let attributionBegan = MeetingPCMRuntimeDiagnostics.beginDetailed(.wordAttribution)
                var attributionSucceeded = false
                defer {
                    MeetingPCMRuntimeDiagnostics.completedDetailed(.wordAttribution, since: attributionBegan,
                        samples: transcript.segments.count, succeeded: attributionSucceeded)
                }
                let batch = try MeetingPCMRecordingAttribution.assemble(transcript: transcript,
                    activity: phase.activity, epoch: epoch, attemptID: attemptID,
                    duration: Double(source.totalSampleCount) / 16_000,
                    speakerNameFormat: self.pcmSpeakerNameFormat, confirmedLocalUserTokens: confirmedOwner,
                    speakerAttributionPolicy: configuration.speakerAttributionPolicy)
                try Task.checkCancellation()
                attributionSucceeded = true
                recordingSucceeded = true
                return batch
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// Scoped local encoder. Streaming V3 invokes it serially inside the existing owned
    /// model grant; earlier recipes invoke it after ASR and Nemotron residency ends.
    /// Only short, admitted single-speaker excerpts reach this local model; no audio is uploaded.
    func speakerVoiceProfiles(samples: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        try Task.checkCancellation()
        // Retained retries use the same immutable profile as live capture. Anonymous profiles
        // neither advertise an owner snapshot nor load an encoder absent from their resource plan.
        guard self.ownerVoiceVerificationEnabled, !samples.isEmpty else { return [] }
        let began = MeetingPCMRuntimeDiagnostics.begin(.voice)
        defer { MeetingPCMRuntimeDiagnostics.completed(.voice, since: began, samples: samples.count) }
        return try MeetingSpeakerVoiceEncoder.encode(
            samples: samples, directory: self.voiceModelDirectory,
            validateDefaultRoot: self.usesDefaultVoiceModelDirectory
        )
    }

    func withNemotronDiarization(
        artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        #if arch(arm64)
        // Recheck at open time: the artifact located at plan/readiness time is validated again
        // before CoreML touches it (plan §5).
        let locator = self.modelLocator
        let compiledURL = try await self.compiledNemotron.compiledModel(for: artifact) { try locator.recheck($0) }
        if artifact.compiledModelURL != nil {
            // Keep the existing attempt/phase owner, ASR sequencing and per-track factory contract.
            // The validated artifact profile fixes its compute policy. The existing default
            // prefers ANE when available; explicitly selected evaluated FP16 profiles use CPU.
            // CoreML errors remain errors; this route never substitutes legacy weights.
            let configuration = MLModelConfiguration()
            configuration.computeUnits = artifact.profile.computePreference == .cpuOnly ? .cpuOnly
                : MeetingFast32ComputePolicy.diagnosticUnits(
                    preferred: MeetingFast32ComputePolicy.preferredUnits, environment: ProcessInfo.processInfo.environment)
            let computeName = configuration.computeUnits == .cpuOnly ? "cpuOnly"
                : configuration.computeUnits == .cpuAndNeuralEngine ? "cpuAndNeuralEngine" : "cpuAndGPU"
            DebugLogger.shared.log("[meeting/pcm] model=\(artifact.profile.rawValue) computeUnits=\(computeName)", source: "MeetingPCMRuntime")
            let loadBegan = MeetingPCMRuntimeDiagnostics.begin(.load)
            let model = try MLModel(contentsOf: compiledURL, configuration: configuration)
            try Task.checkCancellation()
            let silence = try MeetingModelInstaller.validatedSilenceEmbedding(
                at: MeetingModelInstaller.silenceEmbeddingURL(besides: artifact.packageURL))
            let projection: [Float]?
            if let fileName = artifact.profile.projectionFileName {
                let projectionData = try Data(contentsOf: artifact.packageURL.appendingPathComponent(fileName))
                guard projectionData.count == 1024 * 512 * MemoryLayout<Float>.size else { throw MeetingModelInstaller.InstallError.wrongPackage }
                projection = projectionData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            } else { projection = nil }
            guard let config = Nemotron3Config.preset(named: artifact.profile.presetName) else {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "runtimePresetMissing")
            }
            let models = try Nemotron3Models(config: config, model: model, silenceEmbedding: silence, preEncodeProjection: projection)
            MeetingPCMRuntimeDiagnostics.completed(.load, since: loadBegan, sourceBytes: artifact.totalByteCount)
            // Keep chunk JSON and outer phase rows on the same existing serial log
            // queue. AppLogger's separate stderr writer can split JSON inside XCTest.
            let factory = Fast32NemotronDiarizerFactory(config: config, models: models, profileLogSink: {
                DebugLogger.shared.log($0, source: "Nemotron3Diarizer")
            })
            defer { factory.cleanup() }
            try Task.checkCancellation()
            let result = try await body(factory)
            if MeetingCoreMLComputeDiagnostics.enabled {
                // Inspect after inference so plan specialization cannot warm the measured
                // model load or predictions. Its memory and wall time are diagnostic overhead.
                factory.cleanup()
                try Task.checkCancellation()
                let began = MeetingPCMRuntimeDiagnostics.begin(.computePlan)
                await MeetingCoreMLComputeDiagnostics.logPlan(for: compiledURL, configuration: configuration, role: .diarizer)
                MeetingPCMRuntimeDiagnostics.completed(.computePlan, since: began)
                try Task.checkCancellation()
            }
            return result
        }
        // The checkpoint's trained cache settings: one silence frame per speaker, filled with its
        // learned silence embedding. Anything else splits one voice across several slots.
        let config = try SortformerConfig.nemotron(
            spkcacheUpdatePeriod: 300,
            spkcacheSilFramesPerSpk: 1,
            predScoreThreshold: 0.25,
            learnedSilenceEmbedding: MeetingModelInstaller.validatedSilenceEmbedding(
                at: MeetingModelInstaller.silenceEmbeddingURL(besides: artifact.packageURL)
            )
        )
        let mlConfiguration = MLModelConfiguration()
        #if os(iOS)
        mlConfiguration.computeUnits = .cpuOnly
        #else
        mlConfiguration.computeUnits = .cpuAndGPU
        #endif
        let loadBegan = MeetingPCMRuntimeDiagnostics.begin(.load)
        let models = try await SortformerModels.load(
            config: config,
            mainModelPath: compiledURL,
            configuration: mlConfiguration
        )
        MeetingPCMRuntimeDiagnostics.completed(.load, since: loadBegan, sourceBytes: artifact.totalByteCount)
        let factory = NemotronDiarizerFactory(config: config, models: models)
        do {
            let result = try await body(factory)
            factory.cleanup()
            return result
        } catch {
            factory.cleanup()
            throw error
        }
        #else
        throw MeetingParakeetNemotronRuntimeError.unsupportedArchitecture
        #endif
    }

    func withPreparedASR(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult {
        try await self.withPreparedASR(attemptID: attemptID, configuration: configuration,
            preparedProvider: nil, body: body)
    }

    private func withPreparedASR(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        preparedProvider: MeetingASRPreparedProvider?,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult {
        let asrService = await self.asrServiceProvider()
        let began = MeetingPCMRuntimeDiagnostics.begin(.asrPrepare)
        return try await asrService.withPreparedMeetingASR(
            attemptID: attemptID,
            configuration: configuration,
            preparedProvider: preparedProvider
        ) { provider in
            MeetingPCMRuntimeDiagnostics.completed(.asrPrepare, since: began)
            let session = PreparedParakeetASRSession(asrService: asrService, provider: provider)
            // ASRService runs this scope body on the main actor; the attempt's epoch loop
            // (materialization + model calls) must not live there. Cancellation of the scope
            // cancels this bridging await, which cancels the detached body.
            let pipelineID = DebugLogger.pipelineID
            let work = Task.detached(priority: .userInitiated) {
                try await DebugLogger.$pipelineID.withValue(pipelineID) { try await body(session) }
            }
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }
}

/// Ordinary support logs use the existing rotated FileLogger in Release too. Begin/end lines
/// contain only phase names, elapsed/process CPU time and bounded counts, never text,
/// error payloads, paths, identity metadata or audio samples. Opt-in owner rows add only
/// bounded anonymous scalar matching evidence.
nonisolated enum MeetingPCMRuntimeDiagnostics {
    static let detailedProfilingEnabled = ProcessInfo.processInfo.environment["PICHI_MEETING_DETAILED_PROFILE"] == "1" || MeetingTimelineTrace.enabled
    /// Reuses the existing explicit local profiling opt-in in ordinary signed Release builds.
    /// Capture scalar lengths before enqueueing; neither this closure nor the log retains PCM.
    static func ownerVerificationObserver(
        samples: [MeetingSpeakerVoiceSamples], profiles: [MeetingSpeakerVoiceProfile], streaming: Bool,
        clipFramesByToken: [MeetingBackendSpeakerToken: [Int]]? = nil
    ) -> ((MeetingOwnerVoiceVerifier.Diagnostics) -> Void)? {
        guard self.detailedProfilingEnabled else { return nil }
        // The encoder may omit unusable inputs. Align lengths to admitted profile ordinals
        // internally; ambiguous duplicate inputs have unavailable lengths, never guessed ones.
        let inputs = Dictionary(grouping: samples.prefix(MeetingSpeakerVoiceSamples.maximumProfiles), by: \.token)
        let frames = profiles.prefix(MeetingSpeakerVoiceSamples.maximumProfiles).enumerated().map { ordinal, profile in
            if let clipFramesByToken {
                guard let frames = clipFramesByToken[profile.token] else { return "\(ordinal):unavailable" }
                return "\(ordinal):" + frames.prefix(2).map(String.init).joined(separator: "+")
            }
            guard let matches = inputs[profile.token], matches.count == 1, let sample = matches.first else { return "\(ordinal):unavailable" }
            return "\(ordinal):" + sample.clips.prefix(2).map { String($0.count) }.joined(separator: "+")
        }.joined(separator: ",")
        return { details in
            DebugLogger.shared.info("mode=\(streaming ? "streaming" : "recording") owner_verification_detail=completed "
                + details.diagnosticFields + " excerptFramesByProfile=[\(frames)]", source: "MeetingPCMRuntime")
        }
    }
    nonisolated enum Phase: String, Sendable {
        case compile = "nemotron.compile"
        case load = "nemotron.load"
        case diarize = "nemotron.diarize"
        case voice = "voice.encode"
        case voicePrepare = "voice.prepare"
        case asrPrepare = "asr.prepare"
        case asrInfer = "asr.infer"
        case recordingDiarize = "recording.diarization"
        case computePlan = "coreml.compute_plan"
        case replayRead = "audio.replay_read"
        case speechTail = "speech.tail"
        case wordAttribution = "transcript.attribution"
        case archiveRelease = "audio.release"
        case stopTotal = "stop.total"
        case stopInitialStore = "stop.initial_store"
        case captureStop = "stop.capture"
        case liveTeardown = "stop.live_teardown"
        case diarizationRequest = "recording.diarization_request"
        case resultPersist = "result.persist"
        case resultPublish = "result.publish"
        case privacyRedact = "privacy.redact"
        case diagnosticExport = "diagnostic.transcript_export"
    }
    nonisolated struct Started: Sendable {
        let id: UUID
        let wall: ContinuousClock.Instant
        let cpu: DiagnosticProcessCPUTime?
    }
    static func begin(_ phase: Phase) -> Started {
        let started = Started(id: UUID(), wall: .now, cpu: DiagnosticProcessCPUTime.capture())
        let cpuTotal = started.cpu?.totalMilliseconds.map(String.init) ?? "unavailable"
        let footprint = Self.physicalFootprintBytes().map(String.init) ?? "unavailable"
        let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        DebugLogger.shared.logLazy(source: "MeetingPCMRuntime") {
            "[meeting/pcm] phase=\(phase.rawValue) event=begin spanID=\(started.id) uptimeMs=\(uptime) processCpuTotalMs=\(cpuTotal) cpuScope=process physicalFootprintBytes=\(footprint) thermalState=\(thermal)"
        }
        MeetingTimelineTrace.shared?.record("phase_begin", fields: ["phase": phase.rawValue,
            "spanID": started.id.uuidString, "processCpuTotalMs": cpuTotal,
            "physicalFootprintBytes": footprint, "thermalState": String(thermal)])
        return started
    }
    static func completed(_ phase: Phase, since began: Started, samples: Int = 0, sourceBytes: Int64 = 0,
                          succeeded: Bool? = nil, sourceOffset: Int? = nil) {
        let nowCPU = DiagnosticProcessCPUTime.capture()
        let elapsed = began.wall.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        let cpu = began.cpu.flatMap { nowCPU?.milliseconds(since: $0) }.map(String.init) ?? "unavailable"
        let cpuTotal = nowCPU?.totalMilliseconds.map(String.init) ?? "unavailable"
        let footprint = Self.physicalFootprintBytes().map(String.init) ?? "unavailable"
        let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        let count = max(0, min(1_000_000_000, samples))
        let bytes = max(0, min(1_000_000_000, sourceBytes))
        let outcome = succeeded.map { $0 ? "completed" : Task.isCancelled ? "cancelled" : "failed" } ?? "finished"
        let offset = sourceOffset.map { String(max(0, min(1_000_000_000, $0))) } ?? "unavailable"
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        DebugLogger.shared.logLazy(source: "MeetingPCMRuntime") {
            "[meeting/pcm] phase=\(phase.rawValue) elapsedMs=\(milliseconds) count=\(count) sourceBytes=\(bytes) event=end spanID=\(began.id) outcome=\(outcome) sourceOffset=\(offset) uptimeMs=\(uptime) processCpuMs=\(cpu) processCpuTotalMs=\(cpuTotal) cpuScope=process physicalFootprintBytes=\(footprint) thermalState=\(thermal)"
        }
        MeetingTimelineTrace.shared?.record("phase_end", fields: ["phase": phase.rawValue,
            "spanID": began.id.uuidString, "elapsedMs": String(milliseconds), "sourceOffset": offset,
            "sampleCount": String(count), "outcome": outcome, "processCpuMs": cpu,
            "processCpuTotalMs": cpuTotal, "physicalFootprintBytes": footprint, "thermalState": String(thermal)])
    }

    static func beginDetailed(_ phase: Phase) -> Started? { detailedProfilingEnabled ? begin(phase) : nil }
    static func completedDetailed(_ phase: Phase, since began: Started?, samples: Int = 0, succeeded: Bool = true) {
        if let began { completed(phase, since: began, samples: samples, succeeded: succeeded) }
    }

    private static func physicalFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
        #else
        return nil
        #endif
    }
}

/// Metadata-only diagnostic adapter. The existing replay protocol still owns bounded reads,
/// validation and cancellation; the wrapped source retains all audio/cache ownership.
private nonisolated struct MeetingProfiledPCMReplaySource: MeetingPCMReplaySource {
    let wrapping: any MeetingPCMReplaySource
    var totalSampleCount: Int { wrapping.totalSampleCount }
    func readSamples(in range: Range<Int>) async throws -> [Float] {
        let began = MeetingPCMRuntimeDiagnostics.begin(.replayRead)
        var succeeded = false
        defer {
            MeetingPCMRuntimeDiagnostics.completed(.replayRead, since: began, samples: range.count,
                succeeded: succeeded, sourceOffset: range.lowerBound)
        }
        let samples = try await wrapping.readSamples(in: range)
        succeeded = true
        return samples
    }
}
