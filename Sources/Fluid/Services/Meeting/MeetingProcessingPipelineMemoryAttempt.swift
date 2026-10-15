import Foundation

@MainActor
final class MeetingMemoryProcessingAttempt {
    let request: MeetingBackendRequest
    let descriptor: MeetingBackendDescriptor
    let runtime: any MeetingParakeetNemotronRunning
    let redactor: (any TranscriptTextRedacting)?
    let privacyContext: MeetingTranscriptPrivacyContext?
    let checkpoint: @MainActor (MeetingPCMTranscriptBatch) async throws -> Void
    let preview: (@MainActor @Sendable (MeetingLivePartial?) async throws -> Void)?
    let speechPreviewID = UUID()
    var consumer: (any MeetingMemoryAudioConsuming)?
    init(request: MeetingBackendRequest, descriptor: MeetingBackendDescriptor, runtime: any MeetingParakeetNemotronRunning,
         redactor: (any TranscriptTextRedacting)?,
         checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void,
         preview: (@MainActor @Sendable (MeetingLivePartial?) async throws -> Void)?) {
        self.request = request; self.descriptor = descriptor; self.runtime = runtime; self.redactor = redactor; self.checkpoint = checkpoint
        self.privacyContext = redactor.map { MeetingTranscriptPrivacyContext(redactor: $0) }
        self.preview = preview
    }
}

extension MeetingProcessingPipeline {
    /// Pure capability admission can run before download owners, permission prompts and the
    /// audio lease. The actual session request is frozen and bound separately at preparation.
    func validateMemoryAudioInput(configuration: MeetingCaptureConfiguration, backendID: MeetingBackendID) throws -> MeetingBackendDescriptor {
        guard configuration.audioStorageMode == .memoryOnly else { throw MeetingMemoryAudioError.invalidBudget }
        let processingConfiguration = PichiMeetingProviderFactory.validationConfiguration(backendID: backendID,
            languageCode: configuration.languageCode, diarizationEnabled: configuration.speakerLabelsEnabled ?? true)
        let admissionContext = self.pcmAdmissionContextProvider(configuration.piiRedactionEnabled == true)
        return try self.resolveMemoryInputBackend(backendID: backendID, configuration: processingConfiguration,
            mode: configuration.mode, admissionContext: admissionContext).descriptor
    }

    private func resolveMemoryInputBackend(backendID: MeetingBackendID, configuration: MeetingFinalProcessingConfiguration,
                                          mode: MeetingCaptureMode,
                                          admissionContext: MeetingPCMAdmissionContext) throws -> any MeetingTranscriptionBackend {
        let backend = try self.backendRegistry.makeBackend(id: backendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingBackendError.unsupportedInput(backend: backendID, input: .boundedMicrophonePCM)
            }))
        try backend.descriptor.validatePCMInput(configuration: configuration, mode: mode, admissionContext: admissionContext)
        try backend.validatePCMInput(configuration: configuration, mode: mode, admissionContext: admissionContext)
        return backend
    }

    func prepareMemoryAudio(session: MeetingSession, sessionDirectory: URL,
                            checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) async throws {
        try await prepareMemoryAudioAttempt(session: session, sessionDirectory: sessionDirectory, checkpoint: checkpoint, preview: nil)
    }

    func prepareMemoryAudio(session: MeetingSession, sessionDirectory: URL,
                            checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void,
                            preview: @escaping @MainActor @Sendable (MeetingLivePartial?) async throws -> Void) async throws {
        try await prepareMemoryAudioAttempt(session: session, sessionDirectory: sessionDirectory, checkpoint: checkpoint, preview: preview)
    }

    private func prepareMemoryAudioAttempt(session: MeetingSession, sessionDirectory: URL,
                            checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void,
                            preview: (@MainActor @Sendable (MeetingLivePartial?) async throws -> Void)?) async throws {
        guard session.audioStorageMode == .memoryOnly, self.memoryAttempts[session.id] == nil else { throw MeetingMemoryAudioError.invalidBudget }
        let backendID = session.recordingBackendID.map(MeetingBackendID.init(rawValue:)) ?? .productionDefault
        let attemptID = UUID()
        let admissionContext = self.pcmAdmissionContextProvider(session.piiRedactionEnabled == true)
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
                languageCode: session.languageCode, diarizationEnabled: session.speakerLabelsEnabled ?? true,
                artifactFingerprintOverride: session.recordingASRArtifactFingerprint))
        let preflightBackend = try self.resolveMemoryInputBackend(backendID: backendID,
            configuration: preflightRequest.configuration, mode: session.mode, admissionContext: admissionContext)
        let descriptor = preflightBackend.descriptor
        try descriptor.validatePCMInput(preflightRequest, admissionContext: admissionContext)
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
        try descriptor.validatePCMInput(request, admissionContext: admissionContext)
        try backend.validatePCMInput(configuration: request.configuration, mode: session.mode, admissionContext: admissionContext)
        let redactor = session.piiRedactionEnabled == true ? try self.privacyRedactorProvider() : nil
        if session.piiRedactionEnabled == true, redactor == nil { throw MeetingPrivacyPublicationError.redactorUnavailable }
        let runtime = try backend.makePCMRuntime(request)
        let configuration = request.configuration
        // Validate/prepare the pinned provider before microphone admission. All ownership is
        // returned before capture, then each bounded window takes the same shared resource gate.
        let service = self.asrServiceProvider()
        try await DebugLogger.$pipelineID.withValue(request.attemptID.uuidString) {
            let started = ProcessInfo.processInfo.systemUptime
            var prepared = false
            DebugLogger.shared.info("prepare_started session=\(session.id) backend=\(backendID.rawValue) model=\(configuration.asrModel)", source: "MeetingMemoryAudio")
            defer {
                let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                DebugLogger.shared.info("prepare_finished success=\(prepared) elapsedMs=\(elapsed)", source: "MeetingMemoryAudio")
            }
            try await service.withMeetingModelResidency(attemptID: request.attemptID, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.preparePCMResources(attemptID: request.attemptID, configuration: configuration)
                _ = try await runtime.withPreparedASR(attemptID: request.attemptID, configuration: configuration) { _ in MeetingParakeetPhaseResult() }
            }
            prepared = true
        }
        try Task.checkCancellation()
        self.memoryAttempts[session.id] = MeetingMemoryProcessingAttempt(request: request, descriptor: descriptor, runtime: runtime, redactor: redactor, checkpoint: checkpoint, preview: preview)
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
        let publishPreview = attempt.preview
        let speechPreviewID = attempt.speechPreviewID
        let observeSpeech: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
        if let publishPreview {
            observeSpeech = { speech in
                var speech = speech
                speech.sourceTrack = track
                let partial: MeetingLivePartial?
                let admission: String
                if let privacyContext {
                    partial = try await privacyContext.previewSpeech(speech)
                    admission = await privacyContext.speechAdmissionDiagnosticFields
                } else {
                    admission = "privacy=false"
                    partial = speech.speechPreview(id: speechPreviewID)
                }
                try Task.checkCancellation()
                try await publishPreview(partial)
                DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                    let nativeTiming = speech.speechObservationHasNativeTiming.map { String($0) } ?? "legacy"
                    let coverageEnd = partial?.end.map { String($0) } ?? "none"
                    DebugLogger.shared.info("speech_preview visible=\(partial != nil) sourceSegments=\(speech.segments.count) nativeTiming=\(nativeTiming) sealed=\(speech.speechObservationIsFinal) coverageEnd=\(coverageEnd) \(admission)", source: "MeetingMemoryAudio")
                }
            }
        } else { observeSpeech = nil }
        DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
            DebugLogger.shared.info("strict_capture session=\(sessionID) track=\(trackID) backend=\(attempt.descriptor.id.rawValue) model=\(configuration.asrModel) speakers=\(configuration.speakerLabelsEnabled) privacy=\(privacyContext != nil)", source: "MeetingMemoryAudio")
        }
        let protect: @Sendable (MeetingPCMTranscriptBatch, TimeInterval, Double, Bool) async throws -> MeetingPCMTranscriptBatch = { input, offset, elapsed, progressive in
            var batch = input
            batch.sourceTrack = track
            let recognized = ProcessInfo.processInfo.systemUptime
            if let privacyContext { batch = try await privacyContext.redact(batch) }
            let privacyElapsed = Int((ProcessInfo.processInfo.systemUptime - recognized) * 1000)
            DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                DebugLogger.shared.info("stage=window offset=\(offset) elapsedMs=\(Int(elapsed * 1000)) progressive=\(progressive) privacyMs=\(privacyElapsed) publishedSegments=\(batch.segments.count)", source: "MeetingMemoryAudio")
            }
            return batch
        }
        let finalize: @Sendable () async throws -> MeetingPCMTranscriptBatch? = { try await privacyContext?.finish() }
        let diagnostic: @Sendable (String) -> Void = { message in
            DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                DebugLogger.shared.info(message, source: "MeetingMemoryAudio")
            }
        }
        let failure: @Sendable (Error) -> Void = { error in
            // Neither provider errors nor transcript content cross into durable diagnostics.
            eventHandler(.interrupted(kind: .captureStoppedUnexpectedly, trackID: trackID,
                                       detail: (error as? MeetingMemoryAudioError)?.localizedDescription
                                           ?? PichiLocalization.text("In-memory transcription stopped. Completed text was preserved.")))
        }
        let consumer: any MeetingMemoryAudioConsuming
        if let policy = attempt.descriptor.pcmObservationPolicy, runtime.supportsProgressivePCMInput {
            consumer = try Self.makeProgressiveMemoryAudioConsumer(
                initialPreviewSeconds: policy.initialSeconds, previewIntervalSeconds: policy.intervalSeconds,
                recognize: { window, offset in
                    try await service.withMeetingModelResidency(attemptID: attemptID, acceptsCompletedCancellation: { _ in false }) {
                        let started = ProcessInfo.processInfo.systemUptime
                        let batch = try await DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                            try await runtime.recognizePCM(window: window, offset: offset, trackID: trackID,
                                attemptID: attemptID, configuration: configuration, preview: observeSpeech)
                        }
                        return try await protect(batch, offset, ProcessInfo.processInfo.systemUptime - started, true)
                    }
                }, checkpoint: { try await checkpoint($0) }, finalize: finalize,
                diagnostic: diagnostic, failure: failure)
        } else {
            // Existing injected runtimes retain their sealed input contract. A scheduling
            // preference does not falsely grant an unimplemented runtime capability.
            consumer = try Self.makeMemoryAudioConsumer(initialChunkSeconds: 3,
                recognize: { samples, offset in
                    try await service.withMeetingModelResidency(attemptID: attemptID, acceptsCompletedCancellation: { _ in false }) {
                        let started = ProcessInfo.processInfo.systemUptime
                        let batch = try await DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                            try await runtime.recognizePCM(samples: samples, offset: offset, trackID: trackID,
                                attemptID: attemptID, configuration: configuration, preview: observeSpeech)
                        }
                        return try await protect(batch, offset, ProcessInfo.processInfo.systemUptime - started, false)
                    }
                }, checkpoint: { try await checkpoint($0) }, finalize: finalize,
                diagnostic: diagnostic, failure: failure)
        }
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
