import Foundation

@MainActor
final class MeetingMemoryProcessingAttempt {
    let request: MeetingBackendRequest
    let descriptor: MeetingBackendDescriptor
    let runtime: any MeetingParakeetNemotronRunning
    let redactor: (any TranscriptTextRedacting)?
    let privacyContext: MeetingTranscriptPrivacyContext?
    let checkpoint: @MainActor (MeetingPCMTranscriptBatch) async throws -> Void
    var consumer: (any MeetingMemoryAudioConsuming)?
    init(request: MeetingBackendRequest, descriptor: MeetingBackendDescriptor, runtime: any MeetingParakeetNemotronRunning,
         redactor: (any TranscriptTextRedacting)?,
         checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) {
        self.request = request; self.descriptor = descriptor; self.runtime = runtime; self.redactor = redactor; self.checkpoint = checkpoint
        self.privacyContext = redactor.map { MeetingTranscriptPrivacyContext(redactor: $0) }
    }
}

extension MeetingProcessingPipeline {
    /// Pure capability admission can run before download owners, permission prompts and the
    /// audio lease. The actual session request is frozen and bound separately at preparation.
    func validateMemoryAudioInput(configuration: MeetingCaptureConfiguration, backendID: MeetingBackendID) throws -> MeetingBackendDescriptor {
        guard configuration.audioStorageMode == .memoryOnly else { throw MeetingMemoryAudioError.invalidBudget }
        let processingConfiguration = PichiMeetingProviderFactory.validationConfiguration(backendID: backendID,
            languageCode: configuration.languageCode, diarizationEnabled: configuration.speakerLabelsEnabled ?? true)
        return try self.resolveMemoryInputBackend(backendID: backendID, configuration: processingConfiguration, mode: configuration.mode).descriptor
    }

    private func resolveMemoryInputBackend(backendID: MeetingBackendID, configuration: MeetingFinalProcessingConfiguration,
                                          mode: MeetingCaptureMode) throws -> any MeetingTranscriptionBackend {
        let backend = try self.backendRegistry.makeBackend(id: backendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingBackendError.unsupportedInput(backend: backendID, input: .boundedMicrophonePCM)
            }))
        try backend.descriptor.validatePCMInput(configuration: configuration, mode: mode)
        try backend.validatePCMInput(configuration: configuration, mode: mode)
        return backend
    }

    func prepareMemoryAudio(session: MeetingSession, sessionDirectory: URL,
                            checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) async throws {
        guard session.audioStorageMode == .memoryOnly, self.memoryAttempts[session.id] == nil else { throw MeetingMemoryAudioError.invalidBudget }
        let backendID = session.recordingBackendID.map(MeetingBackendID.init(rawValue:)) ?? .productionDefault
        let attemptID = UUID()
        func requestSnapshot() -> MeetingBackendRequest {
            MeetingBackendRequest(attemptID: attemptID, session: session, sessionDirectory: sessionDirectory,
                configuration: PichiMeetingProviderFactory.configuration(
                    backendID: backendID, languageCode: session.languageCode,
                    artifactFingerprintOverride: session.recordingASRArtifactFingerprint,
                    diarizationEnabled: session.speakerLabelsEnabled ?? true))
        }
        // Resolve the actual registered factory before preparing any weights. This metadata-only
        // context grants no executor/runtime. A declared descriptor alone cannot authorize PCM:
        // bare factories are inspected too, and the backend must implement strict-input admission.
        let preflightRequest = MeetingBackendRequest(attemptID: attemptID, session: session, sessionDirectory: sessionDirectory,
            configuration: PichiMeetingProviderFactory.validationConfiguration(backendID: backendID,
                languageCode: session.languageCode, diarizationEnabled: session.speakerLabelsEnabled ?? true))
        let preflightBackend = try self.resolveMemoryInputBackend(backendID: backendID,
            configuration: preflightRequest.configuration, mode: session.mode)
        let descriptor = preflightBackend.descriptor
        try descriptor.validatePCMInput(preflightRequest)
        try await self.prepareSpeakerDependencies(for: descriptor, session: session)
        try Task.checkCancellation()

        // Speaker resources can change the dependency fingerprint, so freeze the final request
        // after their preparation and resolve its executable factory with exact host binding.
        // The second resolution must retain the admitted factory capabilities, including for a
        // bare registration whose metadata is available only from its constructed backend.
        let request = requestSnapshot()
        let backend = try self.backendRegistry.makeBackend(id: backendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingBackendError.unsupportedInput(backend: backendID, input: .boundedMicrophonePCM)
            }, parakeetNemotronRuntimeFactory: { [self] callbackRequest in
                guard callbackRequest == request else {
                    throw MeetingBackendError.hostCapabilityRequestMismatch(backend: backendID)
                }
                return try self.meetingRuntimeFactory(callbackRequest)
            }))
        guard backend.descriptor == descriptor else {
            throw MeetingBackendError.backendDescriptorMismatch(backend: backendID)
        }
        try descriptor.validatePCMInput(request)
        try backend.validatePCMInput(configuration: request.configuration, mode: session.mode)
        let redactor = session.piiRedactionEnabled == true ? try self.privacyRedactorProvider() : nil
        if session.piiRedactionEnabled == true, redactor == nil { throw MeetingPrivacyPublicationError.redactorUnavailable }
        let runtime = try backend.makePCMRuntime(request)
        let configuration = request.configuration
        // Validate/prepare the pinned provider before microphone admission. All ownership is
        // returned before capture, then each bounded window takes the same shared resource gate.
        let service = self.asrServiceProvider()
        try await service.withMeetingModelResidency(attemptID: request.attemptID, acceptsCompletedCancellation: { _ in false }) {
            try await runtime.preparePCMResources(attemptID: request.attemptID, configuration: configuration)
            _ = try await runtime.withPreparedASR(attemptID: request.attemptID, configuration: configuration) { _ in MeetingParakeetPhaseResult() }
        }
        try Task.checkCancellation()
        self.memoryAttempts[session.id] = MeetingMemoryProcessingAttempt(request: request, descriptor: descriptor, runtime: runtime, redactor: redactor, checkpoint: checkpoint)
    }

    func memoryConsumer(for sessionID: UUID, track: MeetingAudioTrack,
                        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void) async throws -> any MeetingMemoryAudioConsuming {
        guard let attempt = self.memoryAttempts[sessionID], attempt.consumer == nil else { throw MeetingMemoryAudioError.invalidBudget }
        guard track.kind == .microphone, attempt.descriptor.supportedTrackKinds.contains(track.kind) else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: attempt.descriptor.id)
        }
        let service = self.asrServiceProvider()
        let runtime = attempt.runtime
        let configuration = attempt.request.configuration
        let attemptID = attempt.request.attemptID
        let trackID = track.id
        let privacyContext = attempt.privacyContext
        let checkpoint = attempt.checkpoint
        DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
            DebugLogger.shared.info("strict_capture session=\(sessionID) track=\(trackID) backend=\(attempt.descriptor.id.rawValue) model=\(configuration.asrModel) speakers=\(configuration.speakerLabelsEnabled) privacy=\(privacyContext != nil)", source: "MeetingMemoryAudio")
        }
        let consumer = try Self.makeMemoryAudioConsumer(
            recognize: { samples, offset in
                try await service.withMeetingModelResidency(attemptID: attemptID, acceptsCompletedCancellation: { _ in false }) {
                    let started = ProcessInfo.processInfo.systemUptime
                    var batch = try await DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                        try await runtime.recognizePCM(samples: samples, offset: offset, trackID: trackID, attemptID: attemptID, configuration: configuration)
                    }
                    batch.sourceTrack = track
                    let recognized = ProcessInfo.processInfo.systemUptime
                    if let privacyContext { batch = try await privacyContext.redact(batch) }
                    let elapsed = Int((recognized - started) * 1000)
                    let privacyElapsed = Int((ProcessInfo.processInfo.systemUptime - recognized) * 1000)
                    DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                        DebugLogger.shared.info("stage=window offset=\(offset) frames=\(samples.count) runtimeMs=\(elapsed) privacyMs=\(privacyElapsed) publishedSegments=\(batch.segments.count)", source: "MeetingMemoryAudio")
                    }
                    return batch
                }
            },
            checkpoint: { batch in try await checkpoint(batch) },
            finalize: { try await privacyContext?.finish() },
            diagnostic: { message in
                DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                    DebugLogger.shared.info(message, source: "MeetingMemoryAudio")
                }
            },
            failure: { _ in
                // Neither provider errors nor transcript content cross into durable diagnostics.
                eventHandler(.interrupted(kind: .captureStoppedUnexpectedly, trackID: trackID,
                                           detail: "In-memory transcription stopped. Completed text was preserved."))
            }
        )
        attempt.consumer = consumer
        return consumer
    }

    func cancelMemoryAudio(sessionID: MeetingSessionID) async {
        guard let attempt = self.memoryAttempts[sessionID] else { return }
        try? await attempt.consumer?.finish()
        if self.memoryAttempts[sessionID] === attempt { self.memoryAttempts.removeValue(forKey: sessionID) }
    }

    func finishMemoryAudio(session: MeetingSession, progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingProcessingResult {
        guard let attempt = self.memoryAttempts[session.id], let consumer = attempt.consumer else { throw MeetingProcessingError.noRecoverableAudio }
        defer { self.memoryAttempts.removeValue(forKey: session.id) }
        progress(.transcribing)
        try await consumer.finish()
        try Task.checkCancellation()
        progress(.finalizing)
        var record = session.processingAttempts.last(where: { $0.completedAt == nil }) ?? MeetingProcessingAttempt(
            id: attempt.request.attemptID, startedAt: session.startedAt, completedAt: nil, stage: .pending,
            pipelineVersion: attempt.request.configuration.pipelineVersion, asrProvider: session.recordingBackendID,
            asrModel: attempt.request.configuration.asrModel, languageCode: session.languageCode,
            diarizationModel: attempt.request.configuration.diarizationFingerprint, lastCompletedTrackID: nil, errorCode: nil
        )
        record.completedAt = Date(); record.stage = .completed
        record.asrModel = attempt.request.configuration.asrModel
        record.asrArtifactFingerprint = attempt.request.configuration.asrArtifactFingerprint
        record.asrProvider = attempt.descriptor.id.rawValue
        record.backendID = attempt.descriptor.id.rawValue
        record.backendVersion = attempt.descriptor.version
        progress(.completed)
        return MeetingProcessingResult(speakers: session.speakers, segments: session.transcriptSegments,
                                       attempt: record, isComplete: session.transcriptIsComplete ?? true)
    }
}
