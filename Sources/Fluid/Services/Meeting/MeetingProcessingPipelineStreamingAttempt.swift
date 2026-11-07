import Foundation

extension MeetingProcessingPipeline {
    /// The existing PCM transport owns capture backpressure. One scoped controller keeps
    /// prepared inference on a single worker; the transcript owner receives protected words
    /// and speaker-only revisions. A streaming attempt never archives or replays its audio.
    func makeStreamingMemoryConsumer(
        attempt: MeetingMemoryProcessingAttempt, track: MeetingAudioTrack,
        service: any MeetingASRServicing
    ) async throws -> any MeetingMemoryAudioConsuming {
        let configuration = attempt.request.configuration
        let attemptID = attempt.request.attemptID
        let runtime = attempt.runtime
        let checkpoint: @Sendable (MeetingPCMTranscriptBatch) async throws -> Void = { try await attempt.publish($0) }
        let preview: (@MainActor @Sendable (MeetingLivePartial?) async throws -> Void)? = attempt.preview.map { publish in
            { partial in
                let projected = try attempt.projectedPreview(partial, trackID: track.id)
                try await publish(track.kind, projected)
            }
        }
        let publishPreview: @Sendable (MeetingStreamingTranscriptState.Emission) async throws -> Void = { emission in
            guard emission.hasPreviewChanges, let preview else { return }
            // A canonical checkpoint publishes history and its remaining preview atomically.
            // Replacing that display earlier would hide words during persistence awaits.
            guard emission.safeBatch.segments.isEmpty, emission.safeBatch.speakerRevisions.isEmpty else { return }
            try Task.checkCancellation()
            try await preview(emission.safeBatch.livePreview)
        }
        let nonSpeech: MeetingConfidentNonSpeechQuery?
        if let query = attempt.trackConfidentlyNonSpeech {
            nonSpeech = { start, end in await query(track.kind, start, end) }
        } else { nonSpeech = attempt.request.session.mode == .inRoom ? attempt.confidentlyNonSpeech : nil }
        let sourceTimeline: MeetingPCMSourceTimeline
        if attempt.request.session.mode == .onlineCall {
            let timebase = attempt.request.session.timebase
            let origin = Double(timebase.startedHostTime) * Double(timebase.machTimebaseNumerator)
                / Double(timebase.machTimebaseDenominator) / 1_000_000_000
            let timeline = try MeetingPCMSourceTimeline(originSeconds: origin,
                recordingTimePolicy: timebase.recordingTimePolicy)
            attempt.sourceTimelines[track.id] = timeline
            sourceTimeline = timeline
        } else {
            let timebase = attempt.request.session.timebase
            let origin = timebase.recordingTimePolicy == .hostMonotonicV1
                ? Double(timebase.startedHostTime) * Double(timebase.machTimebaseNumerator)
                    / Double(timebase.machTimebaseDenominator) / 1_000_000_000 : nil
            sourceTimeline = try MeetingPCMSourceTimeline(originSeconds: origin,
                recordingTimePolicy: timebase.recordingTimePolicy)
            attempt.sourceTimelines[track.id] = sourceTimeline
        }
        let state = try MeetingStreamingTranscriptState(attemptID: attemptID, track: track,
            configuration: configuration, privacyContext: attempt.request.session.mode == .onlineCall
                ? attempt.redactor.map { MeetingTranscriptPrivacyContext(redactor: $0) } : attempt.privacyContext,
            priorSpeakers: attempt.request.session.speakers)
        let retireSourceTimeline: @Sendable () async -> Void = {
            // Keep every privacy/attribution-held word and the preceding physical ASR
            // window. Echo caches already retain positioned intervals, not source maps.
            let protectedFloor = await state.retainActivityFromSample
            sourceTimeline.discard(beforeSample: max(0, protectedFloor - 20 * 16_000))
        }
        let publish: @Sendable (MeetingStreamingTranscriptState.Emission, String) async throws -> Void = { emission, phase in
            try Task.checkCancellation()
            let batch = emission.safeBatch
            if !batch.segments.isEmpty || !batch.speakerRevisions.isEmpty || emission.hasSpeakerIdentityChanges
                || batch.protectedSourceThroughSample != nil || !batch.protectedSourceIntervals.isEmpty {
                try await checkpoint(batch)
            }
            try await publishPreview(emission)
            Self.logStreamingEmission(emission, attemptID: attemptID, phase: phase)
        }
        let sessionID = attempt.request.session.id
        let backendID = attempt.descriptor.id.rawValue
        let idleResourceIdentity = MeetingBackendIdlePreparedResource.identity(
            backendID: attempt.descriptor.id, configuration: configuration)
        attempt.streamingTracks[track.id] = track
        attempt.streamingTranscripts[track.id] = state
        attempt.streamingProgress[track.id] = { observation in
            let admitted = try await attempt.observeEcho(observation, track: track)
            let emission = try await state.observe(admitted)
            try await publish(emission, "progress")
            await retireSourceTimeline()
        }
        let expectedTrackCount = attempt.request.session.mode == .onlineCall ? 2 : 1
        if attempt.streamingTracks.count == expectedTrackCount {
            let tracks = attempt.streamingTracks
            let progress = attempt.streamingProgress
            if expectedTrackCount > 1 {
                let timelines = attempt.sourceTimelines
                attempt.echoAdmission = try MeetingStreamingEchoAdmission(tracks: Array(tracks.values),
                    presentationInterval: { id, start, end in timelines[id]?.mapInterval(start: start, end: end) },
                    presentationThrough: { id, end in timelines[id]?.mapEndTime(end) })
            }
            let scope: MeetingStreamingPCMController.SharedScopeOperation = { body in
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
                        if tracks.count == 1, let only = tracks.values.first {
                            try await runtime.withPreparedStreamingPCM(trackID: only.id, attemptID: attemptID,
                                configuration: configuration, onProgress: { observation in
                                    try await progress[only.id]?(observation)
                                }, body: { session in
                                    try await body([only.id: session])
                                })
                        } else {
                            try await runtime.withPreparedStreamingPCMTracks(trackIDs: Array(tracks.keys), attemptID: attemptID,
                                configuration: configuration, onProgress: { trackID, observation in
                                    guard let publish = progress[trackID] else { throw MeetingStreamingPCMControllerError.invalidScope }
                                    try await publish(observation)
                                }, body: body)
                        }
                    }
                }
            }
            if expectedTrackCount == 1 {
                attempt.streamingControllers[track.id] = MeetingStreamingPCMController.deferred { body in
                    try await scope { sessions in
                        guard let session = sessions[track.id] else { throw MeetingStreamingPCMControllerError.invalidScope }
                        try await body(session)
                    }
                }
            } else {
                attempt.streamingControllers = try MeetingStreamingPCMController.deferredTracks(trackIDs: Array(tracks.keys), using: scope)
            }
        }
        let getController: @Sendable () async throws -> MeetingStreamingPCMController = {
            try await attempt.controller(for: track.id)
        }
        do {
            try Task.checkCancellation()
            let publishSpeech: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
            if let preview {
                publishSpeech = { speech in
                    let protected = try await state.observeSpeechPreview(speech)
                    try Task.checkCancellation()
                    try await preview(protected)
                }
            } else { publishSpeech = nil }
            let consumer = try Self.makeProgressiveMemoryAudioConsumer(
                chunkSeconds: 20, maximumPendingSeconds: 60,
                // Small PCM deliveries keep acoustic scoring and pause detection moving.
                // Repeated batch ASR has its own cadence in the existing runtime.
                initialPreviewSeconds: 0.5, previewIntervalSeconds: 0.5,
                // Only this source's complete measured quiet interval may suppress ASR.
                confidentlyNonSpeech: nonSpeech,
                pauseEndpointSilenceSeconds: 0.768,
                sourceTimeline: sourceTimeline,
                recognize: { window, offset in
                    let controller = try await getController()
                    let observation = try await controller.recognize(window: window, offset: offset,
                        preview: publishSpeech)
                    let admitted = try await attempt.observeEcho(observation, track: track)
                    let emission = try await state.observe(admitted)
                    try await publishPreview(emission)
                    Self.logStreamingEmission(emission, attemptID: attemptID, phase: "window")
                    return emission.safeBatch
                }, checkpoint: { batch in
                    try await checkpoint(batch)
                    // Progress callbacks run on the controller worker and cannot recursively
                    // submit commands. Eviction is acknowledged only after publication joins.
                    if await state.metadataDiagnostics?.isFinal != true {
                        let controller = try await getController()
                        try await controller.discardActivity(beforeSample: await state.retainActivityFromSample)
                    }
                    await retireSourceTimeline()
                }, didProcessWindow: { feedback in
                    // The timing owner excludes only waits for future PCM. This receipt joins
                    // canonical privacy above and the full checkpoint/projection before the
                    // next optional preview decision on the prepared worker.
                    let controller = try await getController()
                    try await controller.recordWindowProcessing(feedback)
                }, finalize: {
                    let controller = try await getController()
                    if expectedTrackCount == 1, controller.cancelIfUnstarted() {
                        await state.cancel()
                        return nil
                    }
                    try await attempt.sealEcho(trackID: track.id)
                    let final = try await controller.finishStreaming()
                    let admitted = try await attempt.observeEcho(final, track: track)
                    let emission = try await state.finish(admitted)
                    try await publishPreview(emission)
                    Self.logStreamingEmission(emission, attemptID: attemptID, phase: "finish")
                    return emission.safeBatch
                }, diagnostic: { message in
                    DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                        DebugLogger.shared.info(message, source: "MeetingMemoryAudio")
                    }
                }, failure: { _ in
                    Task { @MainActor in await attempt.cancelStreamingAfterFailure() }
                    // The transport rejects subsequent input and preserves completed text.
                    // It has no hidden full-audio replay fallback in streaming mode.
                    DebugLogger.$pipelineID.withValue(attemptID.uuidString) {
                        DebugLogger.shared.info("attemptID=\(attemptID) mode=streaming input_rejected replay=false",
                            source: "MeetingStreamingPCM")
                    }
                })
            attempt.streamingConsumers[track.id] = consumer
            if expectedTrackCount == 1 { attempt.consumer = consumer }
            return consumer
        } catch {
            if let controller = attempt.streamingControllers[track.id] { await controller.cancelAndWait() }
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
