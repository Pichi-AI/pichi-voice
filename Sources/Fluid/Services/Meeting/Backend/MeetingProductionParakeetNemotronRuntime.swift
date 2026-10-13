import Foundation

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
// - Optional local WeSpeaker encoding between those phases, using bounded voice excerpts.
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

/// Small attempt-local identity evidence, protected separately from model residency.
/// No PCM or audio files are retained here. The existing matcher receives a bounded
/// complete-link reference set; uncertain/new voices beyond that limit stay unassigned.
private final nonisolated class MeetingPCMIdentityState: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptID: UUID?
    private var busy = false
    private var profiles: [MeetingSpeakerVoiceProfile] = []
    private var speakers: [MeetingSessionSpeaker] = []

    func begin(attemptID: UUID) throws -> (profiles: [MeetingSpeakerVoiceProfile], speakers: [MeetingSessionSpeaker]) {
        try self.lock.withLock {
            guard !self.busy else { throw MeetingParakeetNemotronRuntimeError.concurrentPCMWindow }
            if self.attemptID != attemptID {
                self.attemptID = attemptID
                self.profiles.removeAll()
                self.speakers.removeAll()
            }
            self.busy = true
            return (self.profiles, self.speakers)
        }
    }

    func commit(profiles: [MeetingSpeakerVoiceProfile], speakers: [MeetingSessionSpeaker]) {
        self.lock.withLock {
            self.profiles = Array(profiles.prefix(MeetingSpeakerVoiceSamples.maximumProfiles))
            for speaker in speakers where !self.speakers.contains(where: { $0.id == speaker.id }) {
                guard self.speakers.count < MeetingSpeakerVoiceSamples.maximumProfiles else { break }
                self.speakers.append(speaker)
            }
        }
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
        let diarizer = SortformerDiarizer(config: self.config)
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

    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] {
        try Task.checkCancellation()
        let timeline = try self.diarizer.processComplete(
            samples,
            sourceSampleRate: nil,
            keepingEnrolledSpeakers: false,
            finalizeOnCompletion: true
        )
        try Task.checkCancellation()
        return timeline.speakers
            .sorted { $0.key < $1.key }
            .flatMap { index, speaker in
                speaker.finalizedSegments.compactMap { segment in
                    guard segment.isFinalized, segment.endTime > segment.startTime else { return nil }
                    return MeetingNemotronSpeakerSegment(
                        slotIndex: index,
                        start: TimeInterval(segment.startTime),
                        end: TimeInterval(segment.endTime)
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

    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        try await self.asrService.transcribeMeetingSamplesWithTimings(samples, provider: self.provider)
    }
}

final nonisolated class MeetingParakeetNemotronRuntime: MeetingParakeetNemotronRunning {
    private let asrServiceProvider: @MainActor () -> any MeetingASRServicing
    private let modelLocator: any MeetingNemotronModelLocating
    private let pcmIdentityState = MeetingPCMIdentityState()
    private let pcmSpeakerNameFormat = PichiLocalization.text("Speaker %lld")

    init(
        asrServiceProvider: @escaping @MainActor () -> any MeetingASRServicing,
        modelLocator: any MeetingNemotronModelLocating
    ) {
        self.asrServiceProvider = asrServiceProvider
        self.modelLocator = modelLocator
    }

    /// The strict privacy capture sink supplies bounded mono16k PCM directly. Each
    /// window uses the original residency scope, diarizer, prepared ASR and assembler;
    /// it never invokes a file materializer or writes an intermediate audio file.
    func recognizePCM(
        samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration
    ) async throws -> MeetingPCMTranscriptBatch {
        guard !samples.isEmpty, samples.count <= 320_000, samples.allSatisfy(\.isFinite),
              offset.isFinite, offset >= 0, offset <= 31_536_000 else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        _ = try MeetingProviderOptions.resolve(configuration)
        let prior = try self.pcmIdentityState.begin(attemptID: attemptID)
        defer { self.pcmIdentityState.end() }
        // The pipeline owns the outer withMeetingModelResidency scope, just as it
        // does for file-backed epochs. Nested resource claims are not permitted.
        let work = Task.detached(priority: .userInitiated) {
            try await self.recognizePCMPhases(samples: samples, offset: offset, trackID: trackID,
                                             attemptID: attemptID, configuration: configuration,
                                             priorProfiles: prior.profiles, priorSpeakers: prior.speakers)
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func recognizePCMPhases(
        samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        priorProfiles: [MeetingSpeakerVoiceProfile], priorSpeakers: [MeetingSessionSpeaker]
    ) async throws -> MeetingPCMTranscriptBatch {
        try Task.checkCancellation()
        let duration = Double(samples.count) / 16_000
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: Int((offset * 16_000).rounded()))
        var activity: [MeetingBackendSpeakerActivity] = []
        var currentProfiles: [MeetingSpeakerVoiceProfile] = []
        if configuration.speakerLabelsEnabled {
            guard !PichiMeetingProviderFactory.isTranscriptOnlyDiarizationFingerprint(configuration.diarizationFingerprint) else {
                throw MeetingNemotronModelReadinessError.modelNotInstalled(path: MeetingNemotronModelLocator.defaultPackageURL().path)
            }
            let artifact = try self.modelLocator.locate()
            let phase = try await self.withNemotronDiarization(artifact: artifact) { factory in
                let diarizer = try await factory.makeDiarizer(epoch: epoch)
                let segments = try await diarizer.diarize(samples: samples)
                guard segments.count <= 4_096, segments.allSatisfy({
                    (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
                        && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 1e-6
                }) else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
                return MeetingNemotronPhaseResult(
                    activity: segments.map { .init(token: .init(analysisEpochID: epoch, label: "slot-\($0.slotIndex)"),
                                                  start: $0.start, end: $0.end) },
                    voiceSamples: MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: samples, segments: segments)
                )
            }
            activity = phase.activity
            // Voice identity is optional evidence. Offline missing embeddings preserve the
            // transcript and explicit uncertainty, rather than merging slots by index.
            do { currentProfiles = try await self.speakerVoiceProfiles(samples: phase.voiceSamples) }
            catch {
                try Task.checkCancellation()
                currentProfiles = []
            }
        }
        try Task.checkCancellation()
        let phase = try await self.withPreparedASR(attemptID: attemptID, configuration: configuration) { session in
            let output = try await session.transcribeWithTimings(samples)
            return MeetingParakeetPhaseResult(outputs: [.init(epochID: epoch, text: output.result.text,
                                                              words: output.words, sampleRate: 16_000,
                                                              sampleCount: samples.count, spanSamples: [])])
        }
        try Task.checkCancellation()
        guard phase.outputs.count == 1, let output = phase.outputs.first else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        let allProfiles = priorProfiles + currentProfiles
        let allowedTokens = Set(allProfiles.map(\.token))
        let links = MeetingSpeakerVoiceMatcher.links(profiles: allProfiles, allowedTokens: allowedTokens)
            .filter { $0.token.analysisEpochID == epoch }
        let retained = Array(allProfiles.prefix(MeetingSpeakerVoiceSamples.maximumProfiles))
        let identityTokens = Set(retained.filter { $0.token.analysisEpochID == epoch }.map(\.token))
            .union(links.map(\.token))
        let units = MeetingParakeetNemotronBackend.pcmUnits(result: ASRTranscriptionResult(text: output.text),
                                                           words: output.words, epoch: epoch, duration: duration,
                                                           activity: activity, identityTokens: identityTokens)
        let batch = try MeetingTranscriptAssembler(speakerNameFormat: self.pcmSpeakerNameFormat).assemblePCMWindow(attemptID: attemptID, epoch: epoch,
                                                                      offset: offset, duration: duration, units: units,
                                                                      identityLinks: links, priorSpeakers: priorSpeakers)
        try Task.checkCancellation()
        self.pcmIdentityState.commit(profiles: retained, speakers: batch.speakers)
        return batch
    }

    /// Runs between Nemotron and ASR, so the additional encoder never overlaps their residency.
    /// Only short, admitted single-speaker excerpts reach this local model; no audio is uploaded.
    func speakerVoiceProfiles(samples: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        #if arch(arm64)
        guard !samples.isEmpty else { return [] }
        try Task.checkCancellation()
        #if os(iOS)
        let computeUnits: MLComputeUnits = .cpuOnly
        #else
        let computeUnits: MLComputeUnits = .cpuAndNeuralEngine
        #endif
        let models = try await DownloadUtils.loadModels(
            .diarizer,
            modelNames: [ModelNames.Diarizer.embeddingFile],
            directory: AppBrand.modelsDirectory,
            computeUnits: computeUnits
        )
        try Task.checkCancellation()
        guard let model = models[ModelNames.Diarizer.embeddingFile],
              let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?
              .multiArrayConstraint?.shape.last?.intValue,
              (1...4096).contains(maskFrames)
        else {
            throw NSError(domain: "MeetingSpeakerVoice", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The speaker voice model has an unsupported input format.",
            ])
        }
        let extractor = EmbeddingExtractor(embeddingModel: model)
        let mask = [Float](repeating: 1, count: maskFrames)
        var profiles: [MeetingSpeakerVoiceProfile] = []
        for sample in samples.prefix(MeetingSpeakerVoiceSamples.maximumProfiles) {
            try Task.checkCancellation()
            guard sample.clips.count == 2 else { continue }
            var embeddings: [[Float]] = []
            for clip in sample.clips {
                try Task.checkCancellation()
                guard (48_000...160_000).contains(clip.count) else { continue }
                let output = try extractor.getEmbeddings(audio: clip, masks: [mask])
                if let embedding = output.first, embedding.count == 256, embedding.allSatisfy(\.isFinite) {
                    embeddings.append(embedding)
                }
            }
            if embeddings.count == 2 {
                profiles.append(.init(token: sample.token, embeddings: embeddings))
            }
        }
        return profiles
        #else
        return []
        #endif
    }

    func withNemotronDiarization(
        artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        #if arch(arm64)
        // Recheck at open time: the artifact located at plan/readiness time is validated again
        // before CoreML touches it (plan §5).
        let artifact = try self.modelLocator.recheck(artifact)
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
        let models = try await SortformerModels.load(
            config: config,
            mainModelPath: artifact.packageURL,
            configuration: mlConfiguration
        )
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
        let asrService = await self.asrServiceProvider()
        return try await asrService.withPreparedMeetingASR(
            attemptID: attemptID,
            configuration: configuration
        ) { provider in
            let session = PreparedParakeetASRSession(asrService: asrService, provider: provider)
            // ASRService runs this scope body on the main actor; the attempt's epoch loop
            // (materialization + model calls) must not live there. Cancellation of the scope
            // cancels this bridging await, which cancels the detached body.
            let work = Task.detached(priority: .userInitiated) { try await body(session) }
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }
}
