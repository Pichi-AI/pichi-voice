import Foundation

/// The concrete inference adapter keeps both prepared sessions inside their existing model
/// scopes. One controller worker invokes it serially; no complete recording or unprotected
/// transcript history is retained. Canonical privacy admission remains the pipeline's owner.
final nonisolated class MeetingPreparedStreamingRuntime: MeetingPreparedStreamingPCMProcessing, @unchecked Sendable {
    private let runtime: MeetingParakeetNemotronRuntime
    private let asr: any MeetingParakeetASRSession
    private let diarizer: any MeetingIncrementalNemotronDiarizerSession
    private let trackID: MeetingAudioTrackID
    private let attemptID: UUID
    private let configuration: MeetingFinalProcessingConfiguration
    private let speakerNameFormat: String
    private let onProgress: @Sendable (MeetingStreamingPCMObservation) async throws -> Void
    private let lock = NSLock()
    private var busy = false
    private var closed = false
    private var finished = false
    private var pacing = MeetingPCMPreviewPacing()
    private var update = MeetingIncrementalDiarizationUpdate(activity: [], acceptedThroughSample: 0,
        processedThroughSample: 0, retainedFromSample: 0, isFinal: false)
    private var speakers: [MeetingSessionSpeaker] = []

    init(runtime: MeetingParakeetNemotronRuntime, asr: any MeetingParakeetASRSession,
         diarizer: any MeetingIncrementalNemotronDiarizerSession, trackID: MeetingAudioTrackID,
         attemptID: UUID, configuration: MeetingFinalProcessingConfiguration, speakerNameFormat: String,
         onProgress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void) {
        self.runtime = runtime
        self.asr = asr
        self.diarizer = diarizer
        self.trackID = trackID
        self.attemptID = attemptID
        self.configuration = configuration
        self.speakerNameFormat = speakerNameFormat
        self.onProgress = onProgress
    }

    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                   preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingStreamingPCMObservation {
        try self.begin()
        defer { self.end() }
        guard offset.isFinite, offset >= 0, offset <= 31_536_000,
              abs(offset * 16_000 - (offset * 16_000).rounded()) < 0.001,
              Int((offset * 16_000).rounded()) == self.update.acceptedThroughSample else {
            throw MeetingIncrementalDiarizationError.nonContiguousInput
        }
        let epoch = MeetingAnalysisEpochID(trackID: self.trackID, ordinal: self.update.acceptedThroughSample)
        let timing = MeetingPCMWindowComputeTiming()
        let phase = try await self.runtime.recognizeProgressivePCMPhase(session: self.asr, window: window,
            offset: offset, epoch: epoch, attemptID: self.attemptID, timing: timing,
            permitsIntermediateObservations: self.pacing.permitsIntermediateObservations, preview: preview,
            consumePCM: { samples, start in
                try Task.checkCancellation()
                let next = try await self.diarizer.appendStreaming(samples, sourceStartSample: start)
                try Task.checkCancellation()
                try self.accept(next, expectedAccepted: start + samples.count, final: false)
                let publication = timing.beginExclusion()
                do {
                    try await self.onProgress(self.observation())
                    timing.endExclusion(since: publication)
                } catch {
                    timing.endExclusion(since: publication)
                    throw error
                }
                try Task.checkCancellation()
            })
        try Task.checkCancellation()
        guard phase.outputs.count == 1, let output = phase.outputs.first,
              output.sampleCount == phase.boundedPCMSamples.count else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        let physicalCount = phase.boundedPCMSourceSampleCount ?? phase.boundedPCMSamples.count
        guard physicalCount >= output.sampleCount, physicalCount <= 320_000,
              epoch.ordinal + physicalCount == self.update.acceptedThroughSample else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        // Keep ASR-native word identities based on the physical window. Speaker identity uses
        // the one global epoch below; changing the ASR epoch would duplicate word IDs.
        var raw = try await self.runtime.attributePCMSpeech(samples: phase.boundedPCMSamples, output: output,
            epoch: epoch, offset: offset, attemptID: self.attemptID, configuration: self.configuration,
            priorProfiles: [], priorSpeakers: self.speakers)
        if output.sampleCount < physicalCount {
            raw.isComplete = false
            for index in raw.segments.indices { raw.segments[index].completeness = .incompleteTrack }
        }
        let attributed = try MeetingPCMRecordingAttribution.assemble(transcript: raw,
            activity: self.activity(), epoch: self.globalEpoch, attemptID: self.attemptID,
            duration: Double(self.update.acceptedThroughSample) / 16_000,
            speakerNameFormat: self.speakerNameFormat,
            speakerAttributionPolicy: self.configuration.speakerAttributionPolicy)
        self.speakers = attributed.mergingSpeakers(into: self.speakers)
        self.pacing.record(computeSeconds: timing.computeSeconds, audioSeconds: Double(physicalCount) / 16_000)
        try Task.checkCancellation()
        return self.observation(batch: attributed, asrStableThroughSample: self.update.acceptedThroughSample)
    }

    func finishStreaming() async throws -> MeetingStreamingPCMObservation {
        try self.begin()
        defer { self.end() }
        let next = try await self.diarizer.finishStreaming(totalSamples: self.update.acceptedThroughSample)
        try Task.checkCancellation()
        try self.accept(next, expectedAccepted: self.update.acceptedThroughSample, final: true)
        self.lock.withLock { self.finished = true }
        return self.observation(asrStableThroughSample: self.update.acceptedThroughSample)
    }

    func discardActivity(beforeSample: Int) async throws {
        try self.begin()
        defer { self.end() }
        guard beforeSample >= self.update.retainedFromSample, beforeSample <= self.update.processedThroughSample else {
            throw MeetingIncrementalDiarizationError.invalidWatermark
        }
        try await self.diarizer.discardActivity(beforeSample: beforeSample)
        try Task.checkCancellation()
        let floor = Double(beforeSample) / 16_000
        self.update = .init(activity: self.update.activity.compactMap {
            let start = max(floor, $0.start)
            return $0.end > start ? .init(slotIndex: $0.slotIndex, start: start, end: $0.end) : nil
        }, acceptedThroughSample: self.update.acceptedThroughSample,
            processedThroughSample: self.update.processedThroughSample, retainedFromSample: beforeSample, isFinal: false)
    }

    func requireFinished() throws {
        try self.lock.withLock {
            guard self.finished, !self.busy, !self.closed else { throw MeetingStreamingPCMControllerError.invalidScope }
        }
    }

    /// Called only after the resource body's command has joined. The native session's own
    /// joined cleanup is still awaited before its factory and the prepared ASR can be released.
    func cleanup() async {
        self.lock.withLock { self.closed = true }
        await self.diarizer.cleanupStreaming()
        self.speakers.removeAll()
        self.update = .init(activity: [], acceptedThroughSample: 0, processedThroughSample: 0,
                            retainedFromSample: 0, isFinal: false)
    }

    private var globalEpoch: MeetingAnalysisEpochID { .init(trackID: self.trackID, ordinal: 0) }

    private func activity() -> [MeetingBackendSpeakerActivity] {
        self.update.activity.map {
            .init(token: .init(analysisEpochID: self.globalEpoch, label: "slot-\($0.slotIndex)"), start: $0.start, end: $0.end)
        }
    }

    private func observation(batch: MeetingPCMTranscriptBatch = .init(segments: []),
                             asrStableThroughSample: Int? = nil) -> MeetingStreamingPCMObservation {
        .init(batch: batch, activity: self.activity(), acceptedThroughSample: self.update.acceptedThroughSample,
            processedThroughSample: self.update.processedThroughSample, retainedFromSample: self.update.retainedFromSample,
            isFinal: self.update.isFinal, asrStableThroughSample: asrStableThroughSample)
    }

    private func accept(_ next: MeetingIncrementalDiarizationUpdate, expectedAccepted: Int, final: Bool) throws {
        guard next.acceptedThroughSample == expectedAccepted,
              next.acceptedThroughSample >= self.update.acceptedThroughSample,
              next.processedThroughSample >= self.update.processedThroughSample,
              next.processedThroughSample <= next.acceptedThroughSample,
              next.retainedFromSample == self.update.retainedFromSample,
              next.retainedFromSample <= next.processedThroughSample,
              next.isFinal == final, !final || next.processedThroughSample == next.acceptedThroughSample,
              next.activity.count <= 16_384,
              next.activity.allSatisfy({ (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
                  && $0.start >= Double(next.retainedFromSample) / 16_000 && $0.end > $0.start
                  && $0.end <= Double(next.processedThroughSample) / 16_000 + 0.000_001 }) else {
            throw MeetingIncrementalDiarizationError.invalidWatermark
        }
        self.update = next
    }

    private func begin() throws {
        try Task.checkCancellation()
        try self.lock.withLock {
            guard !self.closed else { throw MeetingIncrementalDiarizationError.closed }
            guard !self.finished else { throw MeetingIncrementalDiarizationError.alreadyFinished }
            guard !self.busy else { throw MeetingIncrementalDiarizationError.concurrentOperation }
            self.busy = true
        }
    }
    private func end() { self.lock.withLock { self.busy = false } }
}
