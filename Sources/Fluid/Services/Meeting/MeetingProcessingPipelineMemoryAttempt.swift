import Foundation

@MainActor
final class MeetingMemoryProcessingAttempt {
    let request: MeetingBackendRequest
    let runtime: any MeetingParakeetNemotronRunning
    let redactor: (any TranscriptTextRedacting)?
    let privacyContext: MeetingTranscriptPrivacyContext?
    let checkpoint: @MainActor (MeetingPCMTranscriptBatch) async throws -> Void
    var consumer: (any MeetingMemoryAudioConsuming)?
    init(request: MeetingBackendRequest, runtime: any MeetingParakeetNemotronRunning,
         redactor: (any TranscriptTextRedacting)?,
         checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) {
        self.request = request; self.runtime = runtime; self.redactor = redactor; self.checkpoint = checkpoint
        self.privacyContext = redactor.map { MeetingTranscriptPrivacyContext(redactor: $0) }
    }
}

extension MeetingProcessingPipeline {
    func prepareMemoryAudio(session: MeetingSession, sessionDirectory: URL,
                            checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) async throws {
        guard session.audioStorageMode == .memoryOnly, self.memoryAttempts[session.id] == nil else { throw MeetingMemoryAudioError.invalidBudget }
        let backendID = session.recordingBackendID.map(MeetingBackendID.init(rawValue:)) ?? .productionDefault
        guard let descriptor = self.backendRegistry.descriptor(for: backendID) else { throw MeetingBackendError.unknownBackend(backendID) }
        if session.speakerLabelsEnabled != false {
            try await self.prepareSpeakerDependencies(for: descriptor, session: session)
        }
        let configuration = PichiMeetingProviderFactory.configuration(
            backendID: backendID, languageCode: session.languageCode,
            artifactFingerprintOverride: session.recordingASRArtifactFingerprint,
            diarizationEnabled: session.speakerLabelsEnabled ?? true
        )
        let redactor = session.piiRedactionEnabled == true ? try self.privacyRedactorProvider() : nil
        if session.piiRedactionEnabled == true, redactor == nil { throw MeetingPrivacyPublicationError.redactorUnavailable }
        let request = MeetingBackendRequest(attemptID: UUID(), session: session, sessionDirectory: sessionDirectory, configuration: configuration)
        let runtime = try self.meetingRuntimeFactory(request)
        // Validate/prepare the pinned provider before microphone admission. All ownership is
        // returned before capture, then each bounded window takes the same shared resource gate.
        let service = self.asrServiceProvider()
        try await service.withMeetingModelResidency(attemptID: request.attemptID, acceptsCompletedCancellation: { _ in false }) {
            try await runtime.preparePCMResources(attemptID: request.attemptID, configuration: configuration)
            _ = try await runtime.withPreparedASR(attemptID: request.attemptID, configuration: configuration) { _ in MeetingParakeetPhaseResult() }
        }
        try Task.checkCancellation()
        self.memoryAttempts[session.id] = MeetingMemoryProcessingAttempt(request: request, runtime: runtime, redactor: redactor, checkpoint: checkpoint)
    }

    func memoryConsumer(for sessionID: UUID, track: MeetingAudioTrack,
                        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void) async throws -> any MeetingMemoryAudioConsuming {
        guard let attempt = self.memoryAttempts[sessionID], attempt.consumer == nil else { throw MeetingMemoryAudioError.invalidBudget }
        let service = self.asrServiceProvider()
        let runtime = attempt.runtime
        let configuration = attempt.request.configuration
        let attemptID = attempt.request.attemptID
        let trackID = track.id
        let privacyContext = attempt.privacyContext
        let checkpoint = attempt.checkpoint
        let consumer = try Self.makeMemoryAudioConsumer(
            recognize: { samples, offset in
                try await service.withMeetingModelResidency(attemptID: attemptID, acceptsCompletedCancellation: { _ in false }) {
                    var batch = try await runtime.recognizePCM(samples: samples, offset: offset, trackID: trackID, attemptID: attemptID, configuration: configuration)
                    batch.sourceTrack = track
                    if let privacyContext { return try await privacyContext.redact(batch) }
                    return batch
                }
            },
            checkpoint: { batch in try await checkpoint(batch) },
            finalize: { try await privacyContext?.finish() },
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
        record.backendID = session.recordingBackendID
        progress(.completed)
        return MeetingProcessingResult(speakers: session.speakers, segments: session.transcriptSegments,
                                       attempt: record, isComplete: session.transcriptIsComplete ?? true)
    }
}
