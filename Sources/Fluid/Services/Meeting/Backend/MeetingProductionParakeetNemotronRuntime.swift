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
// - Optional local WeSpeaker encoding in its own phase, using bounded voice excerpts.
// - Strict PCM runs one ASR phase first, then observes provisional speech before the
//   separate Nemotron/voice phases. File-backed orchestration retains its original order.
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
        let began = MeetingPCMRuntimeDiagnostics.begin(.diarize)
        defer { MeetingPCMRuntimeDiagnostics.completed(.diarize, since: began, samples: samples.count) }
        let timeline = try self.diarizer.processComplete(
            samples,
            sourceSampleRate: nil,
            keepingEnrolledSpeakers: false,
            finalizeOnCompletion: true
        )
        try Task.checkCancellation()
        let physicalDuration = Double(samples.count) / 16_000
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
    private let pcmIdentityState = MeetingPCMIdentityState()
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
        voiceModelDirectory: URL? = nil
    ) {
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
            if self.usesDefaultVoiceModelDirectory { try MeetingSpeakerVoiceModelArtifacts.validateRootContainment() }
            try MeetingSpeakerVoiceModelArtifacts.validate(at: self.voiceModelDirectory)
            let locator = self.modelLocator
            _ = try await self.compiledNemotron.compiledModel(for: located) { try locator.recheck($0) }
            // Open the actual CPU prediction plan before microphone admission. Keeping the
            // same compiled derivative makes subsequent model loads warm, without retaining
            // weights across ASR/voice phases or spending the PCM backlog on a cold CoreML load.
            _ = try await self.withNemotronDiarization(artifact: located) { _ in MeetingNemotronPhaseResult() }
        } else { artifact = nil }
        try Task.checkCancellation()
        try self.pcmIdentityState.pin(attemptID: attemptID, configuration: configuration.identityFingerprint, artifact: artifact)
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
    /// hypothesis and the same physical PCM pass to the existing speaker phases.
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
                let phase = try await self.withPreparedASR(attemptID: attemptID, configuration: configuration) { session in
                    var samples: [Float] = []
                    var output: MeetingParakeetEpochOutput?
                    var sealed = false
                    while var update = try await window.next() {
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
                        if samples.isEmpty { samples = update.samples }
                        else { samples.append(contentsOf: update.samples) }
                        update.samples = []
                        if hasNewPCM {
                            let recognized = try await session.transcribeWithTimings(samples)
                            let observed = MeetingParakeetEpochOutput(epochID: epoch, text: recognized.result.text,
                                words: recognized.words, sampleRate: 16_000, sampleCount: samples.count, spanSamples: [])
                            // An empty observation can be silence or a provider's rejected
                            // hypothesis. Neither invalidates speech already accepted for
                            // a shorter prefix. Keep its original coverage and timings.
                            let hasSpeech = !observed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            if hasSpeech || output == nil || output?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                                output = observed
                            }
                            if let preview, hasSpeech || output?.sampleCount == observed.sampleCount {
                                try await preview(self.pcmSpeechObservation(output: observed, epoch: epoch,
                                    offset: offset, duration: Double(samples.count) / 16_000, attemptID: attemptID))
                            }
                            DebugLogger.shared.info("progressive_speech offset=\(offset) frames=\(samples.count) sealed=\(update.isFinal)", source: "MeetingPCMRuntime")
                        }
                        if update.isFinal { sealed = true; break }
                    }
                    guard sealed, let output, output.sampleCount > 0, output.sampleCount <= samples.count else {
                        throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                    }
                    let physicalSampleCount = samples.count
                    // Native inference has joined. Transfer only the same array's covered
                    // prefix to attribution; the scalar records the consumed physical tail.
                    samples.removeSubrange(output.sampleCount..<samples.count)
                    return MeetingParakeetPhaseResult(outputs: [output], boundedPCMSamples: samples,
                        boundedPCMSourceSampleCount: physicalSampleCount)
                }
                try Task.checkCancellation()
                guard phase.outputs.count == 1, let output = phase.outputs.first,
                      output.sampleCount == phase.boundedPCMSamples.count else {
                    throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                }
                // withPreparedASR has joined and released its weights before attribution.
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
                return batch
            }
        }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func pcmSpeechObservation(output: MeetingParakeetEpochOutput, epoch: MeetingAnalysisEpochID,
                                      offset: TimeInterval, duration: TimeInterval,
                                      attemptID: UUID) throws -> MeetingPCMTranscriptBatch {
        let units = MeetingParakeetNemotronBackend.pcmUnits(result: ASRTranscriptionResult(text: output.text),
            words: output.words, epoch: epoch, duration: duration, activity: [], identityTokens: [])
        var observation = try MeetingTranscriptAssembler(speakerNameFormat: self.pcmSpeakerNameFormat)
            .assemblePCMWindow(attemptID: attemptID, epoch: epoch, offset: offset, duration: duration,
                units: units, identityLinks: [], priorSpeakers: [])
        observation.isComplete = false
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
                                                              words: output.words, sampleRate: 16_000,
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
        // pcmUnits produces no units exactly when the provider text is empty.
        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // No current text units can acquire a speaker. Leave attempt-local identity
            // evidence untouched and avoid loading attribution models for empty speech.
            DebugLogger.shared.info("speaker_attribution_empty offset=\(offset) frames=\(samples.count)", source: "MeetingPCMRuntime")
            return MeetingPCMTranscriptBatch(segments: [])
        }
        var activity: [MeetingBackendSpeakerActivity] = []
        var currentProfiles: [MeetingSpeakerVoiceProfile] = []
        var voiceExcerptCount = 0
        var voiceEncodingFailed = false
        if configuration.speakerLabelsEnabled {
            guard !PichiMeetingProviderFactory.isTranscriptOnlyDiarizationFingerprint(configuration.diarizationFingerprint) else {
                throw MeetingNemotronModelReadinessError.modelNotInstalled(path: MeetingNemotronModelLocator.defaultPackageURL().path)
            }
            guard let artifact = try self.pcmIdentityState.pinnedArtifact(attemptID: attemptID, configuration: configuration.identityFingerprint) else {
                throw MeetingModelResidencyError.staleGrant
            }
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
            voiceExcerptCount = phase.voiceSamples.count
            // Voice identity is optional evidence. Offline missing embeddings preserve the
            // transcript and explicit uncertainty, rather than merging slots by index.
            do { currentProfiles = try await self.speakerVoiceProfiles(samples: phase.voiceSamples) }
            catch {
                try Task.checkCancellation()
                currentProfiles = []
                voiceEncodingFailed = true
            }
        }
        try Task.checkCancellation()
        let admission = MeetingSpeakerVoiceMatcher.pcmAdmission(
            priorProfiles: priorProfiles, currentProfiles: currentProfiles, epoch: epoch
        )
        let units = MeetingParakeetNemotronBackend.pcmUnits(result: ASRTranscriptionResult(text: output.text),
                                                           words: output.words, epoch: epoch, duration: duration,
                                                           activity: activity, identityTokens: admission.identityTokens)
        let batch = try MeetingTranscriptAssembler(speakerNameFormat: self.pcmSpeakerNameFormat).assemblePCMWindow(attemptID: attemptID, epoch: epoch,
                                                                      offset: offset, duration: duration, units: units,
                                                                      identityLinks: admission.links, priorSpeakers: priorSpeakers)
        try Task.checkCancellation()
        if configuration.speakerLabelsEnabled {
            let assigned = batch.segments.filter { $0.attributionState == .assigned }.count
            let ambiguous = batch.segments.filter { $0.attributionState == .overlappingSpeakers }.count
            let activityCount = activity.count
            let excerptCount = voiceExcerptCount
            let encodingFailed = voiceEncodingFailed
            let admissionDiagnostics = admission.diagnosticFields
            let unassigned = batch.segments.count - assigned - ambiguous
            DebugLogger.shared.logLazy(source: "MeetingPCMRuntime") {
                "[meeting/pcm] phase=speaker.admission activitySegments=\(activityCount) cleanVoiceExcerpts=\(excerptCount)"
                    + " voiceEncodingFailed=\(encodingFailed) \(admissionDiagnostics)"
                    + " assignedUnits=\(assigned) ambiguousUnits=\(ambiguous) unassignedUnits=\(unassigned)"
            }
        }
        self.pcmIdentityState.commit(profiles: admission.retainedProfiles, speakers: batch.speakers)
        return batch
    }

    /// Runs in its own phase, so the additional encoder never overlaps ASR or Nemotron residency.
    /// Only short, admitted single-speaker excerpts reach this local model; no audio is uploaded.
    func speakerVoiceProfiles(samples: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        let began = MeetingPCMRuntimeDiagnostics.begin(.voice)
        defer { MeetingPCMRuntimeDiagnostics.completed(.voice, since: began, samples: samples.count) }
        #if arch(arm64)
        guard !samples.isEmpty else { return [] }
        try Task.checkCancellation()
        #if os(iOS)
        let computeUnits: MLComputeUnits = .cpuOnly
        #else
        let computeUnits: MLComputeUnits = .cpuAndNeuralEngine
        #endif
        if self.usesDefaultVoiceModelDirectory { try MeetingSpeakerVoiceModelArtifacts.validateRootContainment() }
        try MeetingSpeakerVoiceModelArtifacts.validate(at: self.voiceModelDirectory)
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        let model = try MLModel(contentsOf: self.voiceModelDirectory, configuration: configuration)
        try Task.checkCancellation()
        guard let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue,
              (1...4096).contains(maskFrames) else {
            throw MeetingModelResidencyError.unsupportedProvider
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
        let locator = self.modelLocator
        let compiledURL = try await self.compiledNemotron.compiledModel(for: artifact) { try locator.recheck($0) }
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
        let asrService = await self.asrServiceProvider()
        let began = MeetingPCMRuntimeDiagnostics.begin(.asrPrepare)
        return try await asrService.withPreparedMeetingASR(
            attemptID: attemptID,
            configuration: configuration
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
/// error payloads, paths, speaker metadata or audio samples.
private nonisolated enum MeetingPCMRuntimeDiagnostics {
    nonisolated enum Phase: String, Sendable {
        case compile = "nemotron.compile"
        case load = "nemotron.load"
        case diarize = "nemotron.diarize"
        case voice = "voice.encode"
        case asrPrepare = "asr.prepare"
        case asrInfer = "asr.infer"
    }
    nonisolated struct Started: Sendable {
        let wall: ContinuousClock.Instant
        let cpu: DiagnosticProcessCPUTime?
    }
    static func begin(_ phase: Phase) -> Started {
        let started = Started(wall: .now, cpu: DiagnosticProcessCPUTime.capture())
        let cpuTotal = started.cpu?.totalMilliseconds.map(String.init) ?? "unavailable"
        let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        DebugLogger.shared.logLazy(source: "MeetingPCMRuntime") {
            "[meeting/pcm] phase=\(phase.rawValue) event=begin uptimeMs=\(uptime) processCpuTotalMs=\(cpuTotal) cpuScope=process"
        }
        return started
    }
    static func completed(_ phase: Phase, since began: Started, samples: Int = 0, sourceBytes: Int64 = 0) {
        let nowCPU = DiagnosticProcessCPUTime.capture()
        let elapsed = began.wall.duration(to: .now).components
        let milliseconds = elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
        let cpu = began.cpu.flatMap { nowCPU?.milliseconds(since: $0) }.map(String.init) ?? "unavailable"
        let cpuTotal = nowCPU?.totalMilliseconds.map(String.init) ?? "unavailable"
        let uptime = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        let count = max(0, min(320_000, samples))
        let bytes = max(0, min(1_000_000_000, sourceBytes))
        DebugLogger.shared.logLazy(source: "MeetingPCMRuntime") {
            "[meeting/pcm] phase=\(phase.rawValue) elapsedMs=\(milliseconds) count=\(count) sourceBytes=\(bytes) event=end uptimeMs=\(uptime) processCpuMs=\(cpu) processCpuTotalMs=\(cpuTotal) cpuScope=process"
        }
    }
}
