import Foundation

extension MeetingProcessingPipeline {
    /// The existing PCM transport owns capture backpressure. One scoped controller keeps
    /// prepared inference on a single worker; the transcript owner receives protected words
    /// and speaker-only revisions. A streaming attempt never archives or replays its audio.
    func makeStreamingMemoryConsumer(
        attempt: MeetingMemoryProcessingAttempt, track: MeetingAudioTrack,
        service: any MeetingASRServicing,
        observeSpeech: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
    ) async throws -> any MeetingMemoryAudioConsuming {
        let configuration = attempt.request.configuration
        let attemptID = attempt.request.attemptID
        let runtime = attempt.runtime
        let checkpoint = attempt.checkpoint
        let preview = attempt.preview
        let publishPreview: @Sendable (MeetingStreamingTranscriptState.Emission) async throws -> Void = { emission in
            guard emission.hasPreviewChanges, let preview else { return }
            // A canonical checkpoint publishes history and its remaining preview atomically.
            // Replacing that display earlier would hide words during persistence awaits.
            guard emission.safeBatch.segments.isEmpty, emission.safeBatch.speakerRevisions.isEmpty else { return }
            try Task.checkCancellation()
            try await preview(emission.safeBatch.livePreview)
        }
        let state = try MeetingStreamingTranscriptState(attemptID: attemptID, track: track,
            configuration: configuration, privacyContext: attempt.privacyContext,
            priorSpeakers: attempt.request.session.speakers)
        let publish: @Sendable (MeetingStreamingTranscriptState.Emission, String) async throws -> Void = { emission, phase in
            try Task.checkCancellation()
            let batch = emission.safeBatch
            if !batch.segments.isEmpty || !batch.speakerRevisions.isEmpty || emission.hasSpeakerIdentityChanges
                || batch.protectedSourceThroughSample != nil {
                try await checkpoint(batch)
            }
            try await publishPreview(emission)
            Self.logStreamingEmission(emission, attemptID: attemptID, phase: phase)
        }
        let sessionID = attempt.request.session.id
        let backendID = attempt.descriptor.id.rawValue
        let idleResourceIdentity = MeetingBackendIdlePreparedResource.identity(
            backendID: attempt.descriptor.id, configuration: configuration)
        let controller = MeetingStreamingPCMController.deferred { body in
            try await DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                let started = ProcessInfo.processInfo.systemUptime
                DebugLogger.shared.info("prepare_started session=\(sessionID) backend=\(backendID) model=\(configuration.asrModel) captureAdmitted=true", source: "MeetingMemoryAudio")
                defer {
                    let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
                    DebugLogger.shared.info("streaming_scope_finished elapsedMs=\(elapsed)", source: "MeetingMemoryAudio")
                }
                try await attempt.preparePrivacy()
                try await service.withMeetingModelResidency(attemptID: attemptID, idleResourceIdentity: idleResourceIdentity,
                    acceptsCompletedCancellation: { _ in false }) { prepared in
                    try await runtime.preparePCMResources(attemptID: attemptID, configuration: configuration)
                    if let prepared {
                        do {
                            guard let bound = try await prepared.resource() as? MeetingBackendIdlePreparedResource,
                                  bound.backendID == attempt.descriptor.id, bound.configuration == configuration else {
                                throw MeetingModelResidencyError.staleGrant
                            }
                            try await runtime.adoptIdleResources(bound.resource, configuration: configuration)
                        } catch {
                            await prepared.cleanup()
                            try Task.checkCancellation()
                            // Optional readiness never changes the actual recording contract.
                            // The normal pinned runtime still owns the cold preparation path.
                            DebugLogger.shared.info("idle_preparation=fallback captureAdmitted=true", source: "MeetingMemoryAudio")
                        }
                    }
                    try await runtime.withPreparedStreamingPCM(trackID: track.id, attemptID: attemptID,
                        configuration: configuration, onProgress: { observation in
                            let emission = try await state.observe(observation)
                            try await publish(emission, "progress")
                        }, body: { session in
                            DebugLogger.shared.info("prepare_ready elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) captureAdmitted=true", source: "MeetingMemoryAudio")
                            try await body(session)
                        })
                }
            }
        }
        do {
            try Task.checkCancellation()
            let consumer = try Self.makeProgressiveMemoryAudioConsumer(
                chunkSeconds: 20, maximumPendingSeconds: 60,
                initialPreviewSeconds: 3, previewIntervalSeconds: 10,
                confidentlyNonSpeech: attempt.confidentlyNonSpeech,
                recognize: { window, offset in
                    let observation = try await controller.recognize(window: window, offset: offset,
                        preview: observeSpeech)
                    let emission = try await state.observe(observation)
                    try await publishPreview(emission)
                    Self.logStreamingEmission(emission, attemptID: attemptID, phase: "window")
                    return emission.safeBatch
                }, checkpoint: { batch in
                    try await checkpoint(batch)
                    // Progress callbacks run on the controller worker and cannot recursively
                    // submit commands. Eviction is acknowledged only after publication joins.
                    if await state.metadataDiagnostics?.isFinal != true {
                        try await controller.discardActivity(beforeSample: await state.retainActivityFromSample)
                    }
                }, didProcessWindow: { feedback in
                    // The timing owner excludes only waits for future PCM. This receipt joins
                    // canonical privacy above and the full checkpoint/projection before the
                    // next optional preview decision on the prepared worker.
                    try await controller.recordWindowProcessing(feedback)
                }, finalize: {
                    if controller.cancelIfUnstarted() {
                        await state.cancel()
                        return nil
                    }
                    let final = try await controller.finishStreaming()
                    let emission = try await state.finish(final)
                    try await publishPreview(emission)
                    Self.logStreamingEmission(emission, attemptID: attemptID, phase: "finish")
                    return emission.safeBatch
                }, diagnostic: { message in
                    DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                        DebugLogger.shared.info(message, source: "MeetingMemoryAudio")
                    }
                }, failure: { _ in
                    // The transport rejects subsequent input and preserves completed text.
                    // It has no hidden full-audio replay fallback in streaming mode.
                    DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                        DebugLogger.shared.info("attemptID=\(attemptID) mode=streaming input_rejected replay=false",
                            source: "MeetingStreamingPCM")
                    }
                })
            attempt.streamingController = controller
            attempt.streamingTranscript = state
            attempt.consumer = consumer
            return consumer
        } catch {
            await controller.cancelAndWait()
            await state.cancel()
            throw error
        }
    }

    private nonisolated static func logStreamingEmission(
        _ emission: MeetingStreamingTranscriptState.Emission, attemptID: UUID, phase: String
    ) {
        let value = emission.diagnostics
        let known = emission.safeBatch.segments.filter { $0.speakerID != nil }.count
        let uptimeMS = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        let stageTiming = " privacyMs=\(value.privacyMilliseconds) attributionMs=\(value.attributionMilliseconds)"
        DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
            DebugLogger.shared.info(
                "attemptID=\(attemptID) uptimeMs=\(uptimeMS) phase=\(phase) mode=streaming replay=false acceptedThroughSample=\(value.acceptedThroughSample) processedThroughSample=\(value.diarizationProcessedThroughSample) asrStableThroughSample=\(value.asrStableThroughSample) committedThroughSample=\(value.committedThroughSample) privacySafeThroughSample=\(value.privacySafeThroughSample) retainActivityFromSample=\(emission.retainActivityFromSample) pendingWords=\(value.pendingProtectedWords) retainedWords=\(value.retainedAttributionWords) insertedWords=\(value.insertedWords) revisedWords=\(value.revisedWords) knownCount=\(known)"
                + stageTiming, source: "MeetingStreamingPCM")
        }
    }
}
