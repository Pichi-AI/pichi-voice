import Foundation
import CryptoKit

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the local composite backend.
// Parakeet TDT v2/v3 produce word-timed ASR; Nemotron-3 produces per-epoch speaker activity. The
// backend owns orchestration — per-epoch materialization, unit construction, slot assignment and
// exactly-tiling coverage receipts — while the host-injected runtime owns the two model
// capabilities. It never touches the filesystem outside the frozen request's session directory,
// never equates speaker slots across tracks or epochs, and never invents timing: clamping happens
// only at physical epoch bounds. Text without word timings retains validated native segment
// intervals as utterances, or one epoch-covering fallback, rather than fabricated words.

@MainActor
final class MeetingParakeetNemotronBackend: MeetingTranscriptionBackend {
    nonisolated static let descriptor = MeetingBackendDescriptor(
        id: .parakeetNemotron,
        version: "5",
        execution: .local,
        supportedLanguageCodes: VoiceEngineLanguageCatalog.parakeetV3LanguageIDs,
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        supportedFinalPrecisions: [.word, .utterance],
        resultContract: .canonicalEvidence,
        knownLimits: [
            "Nemotron-3 has 8 speaker slots per analysis epoch; a ninth voice is not reliably announced or separated.",
            "Speaker slots are epoch-scoped; conservative local voice matching can reconnect identities across epochs of the same track.",
            "Parakeet TDT v2 handles English; v3 handles the supported European languages.",
            "When ASR returns text without usable word timings, validated native segment intervals are retained as utterances; otherwise one epoch-covering utterance is emitted.",
            "Local Nemotron model must be installed before planning. Voice matching downloads its local embedding model on first use.",
        ],
        analysisSampleRate: 16_000,
        diarizationDependencies: [.speakerSeparation, .voiceMatching],
        supportedInputs: [.recordedChunks, .boundedMicrophonePCM]
    )

    let descriptor: MeetingBackendDescriptor
    var echoVerdictProvider: (any MeetingUnitEchoVerdictProviding)? { MeetingTextOverlapEchoVerdictProvider() }

    private let runtimeFactory: MeetingParakeetNemotronRuntimeFactory
    private let modelLocator: any MeetingNemotronModelLocating
    private let materializer: any MeetingEpochAudioMaterializing
    private let diarizationPolicy: MeetingBackendDiarizationPolicy
    private var plannedArtifact: (attemptID: UUID, artifact: MeetingNemotronModelArtifact?)?

    init(
        runtimeFactory: @escaping MeetingParakeetNemotronRuntimeFactory,
        modelLocator: any MeetingNemotronModelLocating = MeetingNemotronModelLocator(),
        materializer: any MeetingEpochAudioMaterializing = MeetingEpochAudioMaterializer(),
        descriptor: MeetingBackendDescriptor = MeetingParakeetNemotronBackend.descriptor,
        diarizationPolicy: MeetingBackendDiarizationPolicy = .required
    ) {
        self.runtimeFactory = runtimeFactory
        self.modelLocator = modelLocator
        self.materializer = materializer
        self.descriptor = descriptor
        self.diarizationPolicy = diarizationPolicy
    }

    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode) throws {
        try self.descriptor.validatePCMInput(configuration: configuration, mode: mode)
        _ = try MeetingProviderOptions.resolve(configuration)
    }

    func makePCMRuntime(_ request: MeetingBackendRequest) throws -> any MeetingParakeetNemotronRunning {
        try self.descriptor.validatePCMInput(request)
        try self.validatePCMInput(configuration: request.configuration, mode: request.session.mode)
        return try self.runtimeFactory(request)
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard self.descriptor.supportedLanguageCodes.contains(request.session.languageCode) else {
            throw MeetingBackendError.unsupportedLanguage(
                backend: self.descriptor.id,
                languageCode: request.session.languageCode
            )
        }
        guard request.configuration.languageCode == request.session.languageCode else {
            throw MeetingProviderOptionsError.unsupportedLanguageCode(request.configuration.languageCode)
        }
        // The pinned meeting provider policy rejects unsupported requested options explicitly
        // (plan §5): no coercion of another model or feature into this backend.
        _ = try MeetingProviderOptions.resolve(request.configuration)
        // Model readiness is a precondition of planning; execute performs no downloads.
        let artifact: MeetingNemotronModelArtifact?
        switch self.diarizationPolicy {
        case .required:
            artifact = try self.modelLocator.locate()
        case .ifInstalled:
            do {
                artifact = try self.modelLocator.locate()
            } catch MeetingNemotronModelReadinessError.modelNotInstalled {
                artifact = nil
            }
        case .disabled:
            artifact = nil
        }
        let plan = MeetingBackendPlan(request: request, descriptor: self.descriptor)
        guard !plan.trackKindsByID.isEmpty else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: self.descriptor.id)
        }
        self.plannedArtifact = (request.attemptID, artifact)
        return plan
    }

    func execute(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest?,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingBackendOutcome {
        guard let manifest else {
            throw MeetingBackendError.outcomeContractMismatch(
                backend: self.descriptor.id,
                declared: .canonicalEvidence
            )
        }
        let validatedManifest = try manifest.validated(against: plan)
        guard let plannedArtifact = self.plannedArtifact,
              plannedArtifact.attemptID == plan.attemptID
        else {
            throw MeetingBackendError.planDisagreesWithRequest(
                backend: self.descriptor.id,
                defect: .attemptIdentity
            )
        }
        let artifact = try plannedArtifact.artifact.map { try self.modelLocator.recheck($0) }
        self.plannedArtifact = nil
        // The host hands out the runtime only for the exact frozen request.
        let runtime = try self.runtimeFactory(plan.request)
        let materializer = self.materializer
        let request = plan.request
        let backendID = self.descriptor.id
        let backendVersion = self.descriptor.version
        let work = Task.detached(priority: .userInitiated) {
            try await Self.runAttempt(
                request: request,
                manifest: validatedManifest,
                runtime: runtime,
                artifact: artifact,
                backendID: backendID,
                backendVersion: backendVersion,
                materializer: materializer,
                progress: progress
            )
        }
        let bundle = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        return .canonicalEvidence(bundle)
    }

    // MARK: - Orchestration (background context)

    /// One epoch's work item: its manifest spans in analysis order.
    /// Silence placed between a track's epochs when they are diarized as one stream.
    private nonisolated static let epochJoinSilenceSeconds = 0.5

    private nonisolated struct EpochWork: Sendable {
        let track: MeetingAnalysisTrackManifest
        let epoch: MeetingAnalysisEpochRecord
        let spans: [MeetingAnalysisSpan]
    }

    /// Completed 20-second ASR cores and diarizer-owned opaque streaming state. No PCM or
    /// owner-voice embeddings are serialized. Raw working text is encrypted by the retained
    /// store and must still pass the normal privacy publication gate after restoration.
    private nonisolated struct ASRProgress: Codable, Sendable {
        var nextSample = 0
        var text: [String] = []
        var words: [ASRWordTiming] = []
        var untimedChunks: [MeetingUntimedASRChunk] = []
    }
    private nonisolated struct ResumeState: Codable, Sendable {
        var completedTracks: Set<UUID> = []
        var trackSegments: [UUID: [MeetingNemotronSpeakerSegment]] = [:]
        var streamingStates: [UUID: Data] = [:]
        var asr: [MeetingAnalysisEpochID: ASRProgress] = [:]
        var confirmedOwnerTokens: Set<MeetingBackendSpeakerToken>?
    }
    private actor ResumeOwner {
        private let store: MeetingRetainedProcessingCheckpoint
        private let session: MeetingSession
        private let pin: MeetingRetainedProcessingCheckpoint.Pin
        private let inputFingerprint: String
        private let ownerVoiceIdentity: String?
        private let runtimeFingerprint: String?
        private var state: ResumeState

        init(request: MeetingBackendRequest, manifest: MeetingAnalysisManifest,
             backendID: MeetingBackendID, backendVersion: String, ownerVoiceIdentity: String?, runtimeFingerprint: String?) throws {
            self.store = .init(sessionDirectory: request.sessionDirectory)
            self.session = request.session
            self.pin = .init(schema: 1, sessionID: request.session.id, backendID: backendID,
                backendVersion: backendVersion, configuration: request.configuration,
                piiRedactionEnabled: request.session.piiRedactionEnabled == true,
                privacyFingerprint: request.privacyFingerprint)
            // A retry has a fresh attempt UUID, but every source byte/hash, timing mapping,
            // epoch separator and backend version must still describe the same physical input.
            let neutralAttempt = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
            let stableTracks = try manifest.tracks.map { track in
                let spans = track.spans.map { span in
                    MeetingAnalysisSpan(id: MeetingAnalysisSpan.stableID(attemptID: neutralAttempt, chunk: span.chunk, pieceIndex: span.pieceIndex),
                        chunk: span.chunk, pieceIndex: span.pieceIndex, trackKind: span.trackKind, analysisEpochID: span.analysisEpochID,
                        recordedInterval: span.recordedInterval, sourceLocalInterval: span.sourceLocalInterval,
                        analysisInterval: span.analysisInterval, presentationInterval: span.presentationInterval,
                        presentationMapping: span.presentationMapping, captureEra: span.captureEra, admission: span.admission,
                        observed: span.observed, discontinuity: span.discontinuity, timing: span.timing)
                }
                let ids = Dictionary(uniqueKeysWithValues: zip(track.spans.map(\.id), spans.map(\.id)))
                let gaps = track.gaps.map { gap in
                    MeetingAnalysisGap(id: MeetingAnalysisGap.stableID(attemptID: neutralAttempt, chunk: gap.chunk, pieceIndex: gap.pieceIndex),
                        chunk: gap.chunk, pieceIndex: gap.pieceIndex, reason: gap.reason, recordedInterval: gap.recordedInterval,
                        captureEra: gap.captureEra, admission: gap.admission, detail: gap.detail)
                }
                let epochs = try track.epochs.map { epoch in
                    MeetingAnalysisEpochRecord(id: epoch.id, resetReason: epoch.resetReason,
                        spanIDs: try epoch.spanIDs.map { id in
                            guard let stableID = ids[id] else { throw MeetingRetainedProcessingCheckpoint.Failure.invalid }
                            return stableID
                        }, analysisInterval: epoch.analysisInterval)
                }
                return MeetingAnalysisTrackManifest(id: track.id, kind: track.kind, spans: spans, gaps: gaps, epochs: epochs)
            }
            let stable = MeetingAnalysisManifest(backendID: manifest.backendID, backendVersion: manifest.backendVersion,
                attemptID: neutralAttempt, sessionID: manifest.sessionID,
                captureMode: manifest.captureMode, presentationOriginSeconds: manifest.presentationOriginSeconds,
                analysisSampleRate: manifest.analysisSampleRate, residualBoundSeconds: manifest.residualBoundSeconds,
                tracks: stableTracks)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            self.inputFingerprint = SHA256.hash(data: try encoder.encode(stable)).map { String(format: "%02x", $0) }.joined()
            self.ownerVoiceIdentity = ownerVoiceIdentity
            self.runtimeFingerprint = runtimeFingerprint
            if let saved = try self.store.read(session: request.session) {
                guard saved.pin == self.pin, saved.ownerVoiceIdentity == ownerVoiceIdentity,
                      saved.runtimeFingerprint == runtimeFingerprint else {
                    throw MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration
                }
                guard saved.inputFingerprint == self.inputFingerprint else {
                    throw MeetingRetainedProcessingCheckpoint.Failure.changedInput
                }
                do { self.state = try PropertyListDecoder().decode(ResumeState.self, from: saved.payload) }
                catch { throw MeetingRetainedProcessingCheckpoint.Failure.invalid }
                let trackIDs = Set(manifest.tracks.map(\.id))
                let epochIDs = Set(manifest.tracks.flatMap(\.epochs).map(\.id))
                guard self.state.completedTracks.isSubset(of: trackIDs),
                      Set(self.state.trackSegments.keys) == self.state.completedTracks,
                      Set(self.state.streamingStates.keys).isSubset(of: trackIDs),
                      self.state.completedTracks.isDisjoint(with: self.state.streamingStates.keys),
                      Set(self.state.asr.keys).isSubset(of: epochIDs) else {
                    throw MeetingRetainedProcessingCheckpoint.Failure.invalid
                }
            } else { self.state = ResumeState() }
        }
        func snapshot() -> ResumeState { self.state }
        func saveStreaming(_ data: Data, trackID: UUID) throws {
            self.state.streamingStates[trackID] = data; try self.persist()
        }
        func completeTrack(_ segments: [MeetingNemotronSpeakerSegment], trackID: UUID) throws {
            self.state.completedTracks.insert(trackID); self.state.trackSegments[trackID] = segments
            self.state.streamingStates.removeValue(forKey: trackID); try self.persist()
        }
        func saveASR(_ progress: ASRProgress, epochID: MeetingAnalysisEpochID) throws {
            self.state.asr[epochID] = progress; try self.persist()
        }
        func saveOwnerTokens(_ tokens: Set<MeetingBackendSpeakerToken>) throws {
            self.state.confirmedOwnerTokens = tokens; try self.persist()
        }
        private func persist() throws {
            try Task.checkCancellation()
            let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
            do {
                try self.store.write(.init(pin: self.pin, inputFingerprint: self.inputFingerprint,
                    ownerVoiceIdentity: self.ownerVoiceIdentity, runtimeFingerprint: self.runtimeFingerprint,
                    payload: try encoder.encode(self.state)), session: self.session)
            } catch let error as CancellationError { throw error }
            catch let error as MeetingRetainedProcessingCheckpoint.Failure { throw error }
            catch { throw MeetingRetainedProcessingCheckpoint.Failure.unavailable }
        }
    }

    /// The cache owns only replay handles and small span mappings. A retained recording's
    /// decoded PCM lives in an attempt-owned derivative and is deleted when this scope drains.
    private final nonisolated class MaterializationCache: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MeetingAnalysisEpochID: MeetingEpochAudioReplay] = [:]

        func value(for epochID: MeetingAnalysisEpochID) -> MeetingEpochAudioReplay? {
            self.lock.withLock { self.values[epochID] }
        }

        func insert(_ value: MeetingEpochAudioReplay, epochID: MeetingAnalysisEpochID) {
            self.lock.withLock { self.values[epochID] = value }
        }
    }

    private nonisolated struct TrackReplay: MeetingPCMReplaySource {
        let pieces: [(source: any MeetingPCMReplaySource, offset: Int)]
        let totalSampleCount: Int

        func readSamples(in range: Range<Int>) async throws -> [Float] {
            guard range.lowerBound >= 0, range.upperBound <= self.totalSampleCount,
                  range.count <= 30 * 16_000 else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
            var output = [Float](repeating: 0, count: range.count)
            for piece in self.pieces {
                try Task.checkCancellation()
                let lower = max(range.lowerBound, piece.offset)
                let upper = min(range.upperBound, piece.offset + piece.source.totalSampleCount)
                guard upper > lower else { continue }
                let samples = try await piece.source.readSamples(in: (lower - piece.offset)..<(upper - piece.offset))
                guard samples.count == upper - lower else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
                output.replaceSubrange((lower - range.lowerBound)..<(upper - range.lowerBound), with: samples)
            }
            return output
        }
    }

    private nonisolated static func runAttempt(
        request: MeetingBackendRequest,
        manifest: MeetingAnalysisManifest,
        runtime: any MeetingParakeetNemotronRunning,
        artifact: MeetingNemotronModelArtifact?,
        backendID: MeetingBackendID,
        backendVersion: String,
        materializer: any MeetingEpochAudioMaterializing,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingCanonicalResultBundle {
        let epochWork: [EpochWork] = manifest.tracks.flatMap { track in
            let spansByID = Dictionary(
                track.spans.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            return track.epochs.map { epoch in
                EpochWork(
                    track: track,
                    epoch: epoch,
                    spans: epoch.spanIDs.compactMap { spansByID[$0] }
                )
            }
        }

        let pcmMaterializations = MaterializationCache()
        let ownerProfile = runtime.ownerVoiceProfileSnapshot
        let ownerIdentity = ownerProfile.map { "\($0.metadata.generation.uuidString):\($0.encoderFingerprint)" }
        let runtimeFingerprint = artifact.map { "\($0.implementationFingerprint);manifest=\($0.manifestSHA256)" }
        let resume = request.session.audioStorageMode == .retainedFiles
            && (request.session.piiRedactionEnabled != true || request.privacyFingerprint != nil)
            ? try ResumeOwner(request: request, manifest: manifest, backendID: backendID,
                              backendVersion: backendVersion, ownerVoiceIdentity: ownerIdentity,
                              runtimeFingerprint: runtimeFingerprint) : nil
        let restored = await resume?.snapshot() ?? ResumeState()

        // Phase A: Nemotron diarization, one continuous state per track, then drained. A track's
        // epochs are diarized in order as one stream, so a voice keeps its slot across a reset;
        // each epoch still maps its own segments back through its own spans.
        if artifact != nil { await progress(.identifyingSpeakers) }
        var phaseA = try await Self.withOptionalDiarization(runtime: runtime, artifact: artifact) { factory in
            var result = MeetingNemotronPhaseResult()
            for track in manifest.tracks {
                var pieces: [(work: EpochWork, materialized: MeetingEpochAudioReplay, offset: Int)] = []
                var trackSampleCount = 0
                for work in epochWork where work.track.id == track.id {
                    try Task.checkCancellation()
                    let materialized: MeetingEpochAudioReplay
                    do {
                        materialized = try await Self.materialize(
                            work: work,
                            manifest: manifest,
                            request: request,
                            materializer: materializer,
                            cache: pcmMaterializations
                        )
                    } catch let error as CancellationError {
                        throw error
                    } catch let error as MeetingEpochMaterializationError where error.isSampleLimitExceeded {
                        throw error
                    } catch {
                        result.failures[work.epoch.id] = "epochMaterializationFailed"
                        continue
                    }
                    let separatorSamples = pieces.isEmpty ? 0 : Int(Self.epochJoinSilenceSeconds * materialized.sampleRate)
                    guard materialized.source.totalSampleCount > 0,
                          trackSampleCount <= Int.max - separatorSamples - materialized.source.totalSampleCount else {
                        throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                    }
                    trackSampleCount += separatorSamples
                    pieces.append((work, materialized, trackSampleCount))
                    trackSampleCount += materialized.source.totalSampleCount
                }
                guard let first = pieces.first else { continue }
                // A transient failed materialization shortens the concatenated source and
                // shifts every later piece. Such a partial run cannot restore or replace a
                // checkpoint for the complete physical track, even with the same manifest.
                let completeTrackInput = pieces.count == epochWork.filter { $0.track.id == track.id }.count
                try Task.checkCancellation()
                do {
                    let source = TrackReplay(pieces: pieces.map { ($0.materialized.source, $0.offset) },
                                             totalSampleCount: trackSampleCount)
                    let segments: [MeetingNemotronSpeakerSegment]
                    if completeTrackInput, restored.completedTracks.contains(track.id), let saved = restored.trackSegments[track.id] {
                        guard saved.allSatisfy({ segment in
                            (0..<8).contains(segment.slotIndex) && segment.start.isFinite && segment.end.isFinite
                                && segment.start >= 0 && segment.end > segment.start
                                && segment.end <= Double(trackSampleCount) / 16_000 + 1e-6
                        }) else { throw MeetingRetainedProcessingCheckpoint.Failure.invalid }
                        segments = saved
                    } else {
                        let diarizer = try await factory.makeDiarizer(epoch: first.work.epoch.id)
                        if completeTrackInput, let resumable = diarizer as? any MeetingResumableNemotronDiarizerSession, let resume {
                            segments = try await resumable.diarize(source: source, restoring: restored.streamingStates[track.id]) { data in
                                try await resume.saveStreaming(data, trackID: track.id)
                            }
                        } else { segments = try await diarizer.diarize(source: source) }
                        if completeTrackInput { try await resume?.completeTrack(segments, trackID: track.id) }
                    }
                    if ownerProfile != nil, restored.confirmedOwnerTokens == nil {
                        result.voiceSamples.append(contentsOf: try await MeetingSpeakerVoiceSamples.collect(
                            epoch: first.work.epoch.id, source: source, segments: segments
                        ).prefix(max(0, MeetingSpeakerVoiceSamples.maximumProfiles - result.voiceSamples.count)))
                    }
                    for piece in pieces {
                        let pieceStart = Double(piece.offset) / piece.materialized.sampleRate
                        let pieceEnd = pieceStart + Double(piece.materialized.source.totalSampleCount) / piece.materialized.sampleRate
                        for segment in segments {
                            let localStart = max(segment.start, pieceStart) - pieceStart
                            let localEnd = min(segment.end, pieceEnd) - pieceStart
                            guard localEnd > localStart,
                                  let start = Self.analysisTime(
                                      forMaterializedSeconds: localStart,
                                      boundary: .start,
                                      sampleRate: piece.materialized.sampleRate,
                                      sampleCount: piece.materialized.source.totalSampleCount,
                                      spanSamples: piece.materialized.spanSamples,
                                      spans: piece.work.spans
                                  ), let end = Self.analysisTime(
                                      forMaterializedSeconds: localEnd,
                                      boundary: .end,
                                      sampleRate: piece.materialized.sampleRate,
                                      sampleCount: piece.materialized.source.totalSampleCount,
                                      spanSamples: piece.materialized.spanSamples,
                                      spans: piece.work.spans
                                  )
                            else { continue }
                            guard end > start else { continue }
                            result.activity.append(MeetingBackendSpeakerActivity(
                                token: MeetingBackendSpeakerToken(
                                    analysisEpochID: piece.work.epoch.id,
                                    label: "slot-\(segment.slotIndex)"
                                ),
                                start: start,
                                end: end
                            ))
                        }
                    }
                } catch let error as CancellationError {
                    throw error
                } catch let error as MeetingRetainedProcessingCheckpoint.Failure {
                    throw error
                } catch is MeetingDiarizerCheckpointError {
                    throw MeetingRetainedProcessingCheckpoint.Failure.invalid
                } catch {
                    for piece in pieces {
                        result.failures[piece.work.epoch.id] = "diarizationFailed"
                    }
                    continue
                }
            }
            return result
        }
        try Task.checkCancellation()
        // Explicit owner identity is optional. The same bounded encoder runs after diarizer
        // weights drain and before ASR loads. Only confirmed token IDs leave this phase.
        var ownerTokens = restored.confirmedOwnerTokens ?? Set<MeetingBackendSpeakerToken>()
        if restored.confirmedOwnerTokens == nil, ownerProfile != nil, !phaseA.voiceSamples.isEmpty {
            do {
                let profiles = try await runtime.speakerVoiceProfiles(samples: phaseA.voiceSamples)
                let confirmed = MeetingOwnerVoiceVerifier.confirmedTokens(owner: ownerProfile, profiles: profiles)
                let matchedSlots = Set(confirmed.map { "\($0.analysisEpochID.trackID.uuidString):\($0.label)" })
                ownerTokens = Set(phaseA.activity.map(\.token).filter {
                    matchedSlots.contains("\($0.analysisEpochID.trackID.uuidString):\($0.label)")
                })
            } catch { try Task.checkCancellation() }
        }
        if phaseA.failures.isEmpty { try await resume?.saveOwnerTokens(ownerTokens) }
        phaseA.voiceSamples.removeAll()

        // Phase B: Parakeet ASR inside the attempt's single prepared-meeting scope. Epochs that
        // failed phase A are excluded from ASR as well: an epoch is one unit of work.
        await progress(.transcribing)
        let phaseB = try await runtime.withPreparedASR(
            attemptID: request.attemptID,
            configuration: request.configuration
        ) { asr in
            var result = MeetingParakeetPhaseResult()
            for work in epochWork where phaseA.failures[work.epoch.id] == nil {
                try Task.checkCancellation()
                let materialized: MeetingEpochAudioReplay
                do {
                    materialized = try await Self.materialize(
                        work: work,
                        manifest: manifest,
                        request: request,
                        materializer: materializer,
                        cache: pcmMaterializations
                    )
                } catch let error as CancellationError {
                    throw error
                } catch let error as MeetingEpochMaterializationError where error.isSampleLimitExceeded {
                    throw error
                } catch {
                    result.failures[work.epoch.id] = "epochMaterializationFailed"
                    continue
                }
                try Task.checkCancellation()
                do {
                    result.outputs.append(try await Self.transcribeReplay(materialized, epochID: work.epoch.id,
                        asr: asr, restoring: restored.asr[work.epoch.id], resume: resume))
                } catch let error as CancellationError {
                    throw error
                } catch let error as MeetingRetainedProcessingCheckpoint.Failure {
                    throw error
                } catch {
                    result.failures[work.epoch.id] = "asrFailed"
                    continue
                }
            }
            return result
        }
        try Task.checkCancellation()

        return try self.assembleBundle(
            request: request,
            manifest: manifest,
            epochWork: epochWork,
            phaseA: phaseA,
            phaseB: phaseB,
            backendID: backendID,
            confirmedLocalUserTokens: ownerTokens
        )
    }

    private nonisolated static func withOptionalDiarization(
        runtime: any MeetingParakeetNemotronRunning,
        artifact: MeetingNemotronModelArtifact?,
        body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        // Transcript-only processing retains track/timing evidence without claiming speaker IDs.
        guard let artifact else { return MeetingNemotronPhaseResult() }
        return try await runtime.withNemotronDiarization(artifact: artifact, body)
    }

    private nonisolated static func materialize(
        work: EpochWork, manifest: MeetingAnalysisManifest, request: MeetingBackendRequest,
        materializer: any MeetingEpochAudioMaterializing, cache: MaterializationCache
    ) async throws -> MeetingEpochAudioReplay {
        if let cached = cache.value(for: work.epoch.id) { return cached }
        let value = try await materializer.makeReplay(epoch: work.epoch, track: work.track,
            manifest: manifest, sessionDirectory: request.sessionDirectory)
        try Task.checkCancellation()
        cache.insert(value, epochID: work.epoch.id)
        return value
    }

    /// Timed providers receive overlapping context. A word belongs to the core containing its
    /// midpoint, retaining a boundary word once with its original provider times. Providers
    /// without word timing use contiguous cores; no textual/word alignment is manufactured.
    private nonisolated static func transcribeReplay(_ audio: MeetingEpochAudioReplay,
        epochID: MeetingAnalysisEpochID, asr: any MeetingParakeetASRSession,
        restoring: ASRProgress?, resume: ResumeOwner?) async throws -> MeetingParakeetEpochOutput {
        let count = audio.source.totalSampleCount
        let coreSamples = Int(20 * audio.sampleRate)
        let contextSamples = Int(2 * audio.sampleRate)
        let saved = restoring ?? ASRProgress()
        guard count > 0, audio.sampleRate.isFinite, audio.sampleRate > 0,
              saved.nextSample >= 0, saved.nextSample <= count,
              saved.nextSample == count || saved.nextSample % coreSamples == 0,
              saved.words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                  && $0.end > $0.start && $0.end <= Double(count) / audio.sampleRate + 1e-6 }),
              saved.untimedChunks.allSatisfy({ $0.sampleRange.lowerBound >= 0
                  && $0.sampleRange.upperBound <= saved.nextSample && !$0.sampleRange.isEmpty
                  && $0.segmentTimings.allSatisfy({ $0.start.isFinite && $0.end.isFinite
                      && $0.start >= 0 && $0.end > $0.start && $0.end <= Double(count) / audio.sampleRate + 1e-6 }) }) else {
            throw MeetingRetainedProcessingCheckpoint.Failure.invalid
        }
        var start = saved.nextSample
        var text = saved.text
        var words = saved.words
        var untimedChunks = saved.untimedChunks
        while start < count {
            try Task.checkCancellation()
            let end = min(count, start + coreSamples)
            var lower = max(0, start - contextSamples)
            var upper = min(count, end + contextSamples)
            var output = try await asr.transcribeWithTimings(try await audio.source.readSamples(in: lower..<upper))
            func validWords() -> [ASRWordTiming] {
                output.words.filter { word in
                    !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && word.start.isFinite && word.end.isFinite && word.start >= 0
                        && word.end > word.start && word.end <= Double(upper - lower) / audio.sampleRate + 1e-6
                }
            }
            var physicalWords = validWords()
            if physicalWords.isEmpty, !output.result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               lower != start || upper != end {
                // Word timing can be unavailable or malformed for one core. Its actual text
                // survives a bounded core-only retry; this says nothing about later cores.
                lower = start; upper = end
                output = try await asr.transcribeWithTimings(try await audio.source.readSamples(in: lower..<upper))
                physicalWords = validWords()
            }
            let offset = Double(lower) / audio.sampleRate
            if !physicalWords.isEmpty {
                let kept = physicalWords.filter { word in
                    let midpoint = (word.start + word.end) * audio.sampleRate / 2 + Double(lower)
                    return midpoint >= Double(start) && (midpoint < Double(end) || end == count)
                }
                words.append(contentsOf: kept.map { .init(text: $0.text, start: $0.start + offset, end: $0.end + offset) })
                text.append(kept.map(\.text).joined(separator: " "))
            } else {
                let value = output.result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    text.append(value)
                    let native = ASRSegmentTiming.validated(output.result.segmentTimings, text: value,
                        duration: Double(upper - lower) / audio.sampleRate)
                    untimedChunks.append(.init(sampleRange: lower..<upper, text: value,
                        segmentTimings: native.map { .init(text: $0.text, start: $0.start + offset, end: $0.end + offset) }))
                }
            }
            start = end
            try await resume?.saveASR(.init(nextSample: start, text: text, words: words,
                                            untimedChunks: untimedChunks), epochID: epochID)
        }
        return MeetingParakeetEpochOutput(epochID: epochID, text: text.filter { !$0.isEmpty }.joined(separator: " "),
            words: words, sampleRate: audio.sampleRate, sampleCount: count, spanSamples: audio.spanSamples,
            untimedChunks: untimedChunks)
    }

    // MARK: - Units, assignment and receipts

    /// Pure assembly of the final bundle: units from provider word timings clamped only at
    /// physical epoch bounds, slot assignment from overlapping epoch activity, and exactly one
    /// tiling receipt per admissible span. Failed epochs emit no units and mark every span failed;
    /// other epochs continue (plan §4).
    private nonisolated static func assembleBundle(
        request: MeetingBackendRequest,
        manifest: MeetingAnalysisManifest,
        epochWork: [EpochWork],
        phaseA: MeetingNemotronPhaseResult,
        phaseB: MeetingParakeetPhaseResult,
        backendID: MeetingBackendID,
        confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken> = []
    ) throws -> MeetingCanonicalResultBundle {
        let outputsByEpoch = Dictionary(
            phaseB.outputs.map { ($0.epochID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let activityByEpoch = Dictionary(grouping: phaseA.activity, by: { $0.token.analysisEpochID })
        var failures = phaseA.failures
        failures.merge(phaseB.failures) { first, _ in first }

        var units: [MeetingFinalTextUnit] = []
        var receipts: [MeetingSpanCoverageReceipt] = []

        for work in epochWork {
            try Task.checkCancellation()
            if let reason = failures[work.epoch.id] {
                for span in work.spans {
                    receipts.append(Self.receipt(for: span, status: .failed, reasonCode: reason))
                }
                continue
            }
            for span in work.spans {
                receipts.append(Self.receipt(for: span, status: .processed))
            }
            guard let output = outputsByEpoch[work.epoch.id] else { continue }
            let epochActivity = activityByEpoch[work.epoch.id] ?? []
            units.append(contentsOf: Self.units(
                for: output,
                work: work,
                activity: epochActivity,
                attemptID: request.attemptID
            ))
        }

        return MeetingCanonicalResultBundle(
            evidence: MeetingFinalTranscriptEvidence(
                backendID: backendID,
                attemptID: request.attemptID,
                units: units,
                speakerActivity: phaseA.activity.filter { failures[$0.token.analysisEpochID] == nil },
                speakerSlotsContinueAcrossEpochs: true
            ),
            coverageReceipts: receipts,
            confirmedLocalUserTokens: confirmedLocalUserTokens
        )
    }

    private nonisolated static func receipt(
        for span: MeetingAnalysisSpan,
        status: MeetingSpanCoverageStatus,
        reasonCode: String? = nil
    ) -> MeetingSpanCoverageReceipt {
        MeetingSpanCoverageReceipt(
            id: "receipt:\(span.id)",
            spanID: span.id,
            analysisStart: span.analysisInterval.start,
            analysisEnd: span.analysisInterval.end,
            status: status,
            reasonCode: reasonCode
        )
    }

    /// A PCM window has no removed gaps or file spans. Keep the original speaker
    /// coverage and handoff decisions while admitting only physically valid word times.
    nonisolated static func pcmUnits(
        result: ASRTranscriptionResult,
        words: [ASRWordTiming],
        epoch: MeetingAnalysisEpochID,
        duration: TimeInterval,
        activity: [MeetingBackendSpeakerActivity],
        identityTokens: Set<MeetingBackendSpeakerToken>
    ) -> [MeetingFinalTextUnit] {
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let usable = words.count <= 8_192 && !words.isEmpty && words.allSatisfy {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                && $0.end > $0.start && $0.end <= duration + 1e-6
        }
        func admitted(_ assignment: MeetingBackendSpeakerAssignment) -> MeetingBackendSpeakerAssignment {
            if case let .assigned(token) = assignment, !identityTokens.contains(token) { return .unassigned }
            return assignment
        }
        guard usable else {
            let segments = ASRSegmentTiming.validated(result.segmentTimings, text: text, duration: duration)
            if !segments.isEmpty {
                return segments.enumerated().map { index, segment in
                    MeetingFinalTextUnit(id: "pcm:\(epoch):segment:\(index)", trackID: epoch.trackID,
                        analysisEpochID: epoch, precision: .utterance,
                        text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                        analysisStart: segment.start, analysisEnd: segment.end,
                        speaker: admitted(Self.assignment(start: segment.start, end: segment.end,
                            activity: activity, allowDominance: false)),
                        analysisSpanIDs: [], confidence: nil)
                }
            }
            return [MeetingFinalTextUnit(
                id: "pcm:\(epoch):utterance", trackID: epoch.trackID, analysisEpochID: epoch,
                precision: .utterance, text: text, analysisStart: 0, analysisEnd: duration,
                speaker: admitted(Self.assignment(start: 0, end: duration, activity: activity, allowDominance: false)),
                analysisSpanIDs: [], confidence: nil
            )]
        }
        var previous: (token: MeetingBackendSpeakerToken, end: TimeInterval)?
        return words.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map { index, word in
            let coverage = Self.assignment(start: word.start, end: word.end, activity: activity, allowDominance: true)
            let assignment = admitted(Self.handoffAssignment(coverage, start: word.start, end: word.end,
                                                            activity: activity, previousAssignedWord: previous))
            if case let .assigned(token) = assignment { previous = (token, word.end) } else { previous = nil }
            return MeetingFinalTextUnit(
                id: "pcm:\(epoch):\(index)", trackID: epoch.trackID, analysisEpochID: epoch,
                precision: .word, text: word.text.trimmingCharacters(in: .whitespacesAndNewlines),
                analysisStart: word.start, analysisEnd: word.end, speaker: assignment,
                analysisSpanIDs: [], confidence: nil
            )
        }
    }

    /// Timed units for one successful epoch. Provider times are seconds into the epoch's
    /// materialized buffer and map through its verified physical span ranges. Words with
    /// unusable timings are dropped, never repaired. Without words, valid complete native
    /// segments retain utterance precision; otherwise the complete text covers the epoch.
    private nonisolated static func units(
        for output: MeetingParakeetEpochOutput,
        work: EpochWork,
        activity: [MeetingBackendSpeakerActivity],
        attemptID: UUID,
        fallbackRange: Range<Int>? = nil,
        idSuffix: String = ""
    ) -> [MeetingFinalTextUnit] {
        let epochStart = fallbackRange.flatMap {
            Self.analysisTime(forMaterializedSeconds: Double($0.lowerBound) / output.sampleRate, boundary: .start,
                sampleRate: output.sampleRate, sampleCount: output.sampleCount, spanSamples: output.spanSamples, spans: work.spans)
        } ?? work.epoch.analysisInterval.start
        let physicalEnd = Self.analysisTime(
            forMaterializedSeconds: Double(fallbackRange?.upperBound ?? output.sampleCount) / output.sampleRate,
            boundary: .end,
            sampleRate: output.sampleRate,
            sampleCount: output.sampleCount,
            spanSamples: output.spanSamples,
            spans: work.spans
        ) ?? epochStart
        guard physicalEnd > epochStart else { return [] }

        var wordUnits: [MeetingFinalTextUnit] = []
        let untimedAnalysisIntervals = output.untimedChunks.compactMap { chunk -> MeetingAnalysisInterval? in
            guard let start = Self.analysisTime(forMaterializedSeconds: Double(chunk.sampleRange.lowerBound) / output.sampleRate,
                boundary: .start, sampleRate: output.sampleRate, sampleCount: output.sampleCount,
                spanSamples: output.spanSamples, spans: work.spans),
                  let end = Self.analysisTime(forMaterializedSeconds: Double(chunk.sampleRange.upperBound) / output.sampleRate,
                boundary: .end, sampleRate: output.sampleRate, sampleCount: output.sampleCount,
                spanSamples: output.spanSamples, spans: work.spans) else { return nil }
            return MeetingAnalysisInterval(start: start, end: end)
        }
        var previousAssignedWord: (token: MeetingBackendSpeakerToken, end: TimeInterval)?
        let sortedWords = output.words.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        for (index, word) in sortedWords {
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty,
                  word.start.isFinite, word.end.isFinite, word.end > word.start
            else { continue }
            guard let start = Self.analysisTime(
                forMaterializedSeconds: word.start,
                boundary: .start,
                sampleRate: output.sampleRate,
                sampleCount: output.sampleCount,
                spanSamples: output.spanSamples,
                spans: work.spans
            ), let end = Self.analysisTime(
                forMaterializedSeconds: word.end,
                boundary: .end,
                sampleRate: output.sampleRate,
                sampleCount: output.sampleCount,
                spanSamples: output.spanSamples,
                spans: work.spans
            ) else { continue }
            guard end > start else { continue }
            guard let spanIDs = Self.intersectingSpanIDs(start: start, end: end, spans: work.spans)
            else { continue }
            if let previous = previousAssignedWord, untimedAnalysisIntervals.contains(where: {
                $0.start < start && $0.end > previous.end
            }) { previousAssignedWord = nil }
            let coverageAssignment = Self.assignment(
                start: start,
                end: end,
                activity: activity,
                allowDominance: true
            )
            let speaker = Self.handoffAssignment(
                coverageAssignment,
                start: start,
                end: end,
                activity: activity,
                previousAssignedWord: previousAssignedWord
            )
            wordUnits.append(MeetingFinalTextUnit(
                id: "unit:\(attemptID.uuidString):\(work.epoch.id)\(idSuffix):\(index)",
                trackID: work.track.id,
                analysisEpochID: work.epoch.id,
                precision: .word,
                text: text,
                analysisStart: start,
                analysisEnd: end,
                speaker: speaker,
                analysisSpanIDs: spanIDs,
                confidence: nil
            ))
            if case let .assigned(token) = speaker {
                previousAssignedWord = (token, end)
            } else {
                // An uncertain word is a hard context break; never chain a later guess through it.
                previousAssignedWord = nil
            }
        }
        for (index, chunk) in output.untimedChunks.enumerated() {
            let bounded = MeetingParakeetEpochOutput(epochID: output.epochID, text: chunk.text, words: [],
                segmentTimings: chunk.segmentTimings, sampleRate: output.sampleRate,
                sampleCount: output.sampleCount, spanSamples: output.spanSamples)
            wordUnits.append(contentsOf: Self.units(for: bounded, work: work, activity: activity,
                attemptID: attemptID, fallbackRange: chunk.sampleRange, idSuffix: ":chunk-\(index)"))
        }
        if !wordUnits.isEmpty {
            return wordUnits.sorted { ($0.analysisStart, $0.analysisEnd, $0.id) < ($1.analysisStart, $1.analysisEnd, $1.id) }
        }

        let text = output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let nativeSegments = ASRSegmentTiming.validated(output.segmentTimings, text: text,
            duration: Double(output.sampleCount) / output.sampleRate)
        if !nativeSegments.isEmpty {
            var segmentUnits: [MeetingFinalTextUnit] = []
            for (index, segment) in nativeSegments.enumerated() {
                guard let start = Self.analysisTime(forMaterializedSeconds: segment.start, boundary: .start,
                    sampleRate: output.sampleRate, sampleCount: output.sampleCount,
                    spanSamples: output.spanSamples, spans: work.spans),
                    let end = Self.analysisTime(forMaterializedSeconds: segment.end, boundary: .end,
                    sampleRate: output.sampleRate, sampleCount: output.sampleCount,
                    spanSamples: output.spanSamples, spans: work.spans), end > start,
                    let ids = Self.intersectingSpanIDs(start: start, end: end, spans: work.spans)
                else { segmentUnits = []; break }
                segmentUnits.append(MeetingFinalTextUnit(
                    id: "unit:\(attemptID.uuidString):\(work.epoch.id)\(idSuffix):segment:\(index)", trackID: work.track.id,
                    analysisEpochID: work.epoch.id, precision: .utterance,
                    text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    analysisStart: start, analysisEnd: end,
                    speaker: Self.assignment(start: start, end: end, activity: activity, allowDominance: false),
                    analysisSpanIDs: ids, confidence: nil))
            }
            if !segmentUnits.isEmpty { return segmentUnits }
        }
        let spanIDs = Self.intersectingSpanIDs(start: epochStart, end: physicalEnd, spans: work.spans) ?? []
        guard !spanIDs.isEmpty else { return [] }
        return [MeetingFinalTextUnit(
            id: "unit:\(attemptID.uuidString):\(work.epoch.id)\(idSuffix):utterance",
            trackID: work.track.id,
            analysisEpochID: work.epoch.id,
            precision: .utterance,
            text: text,
            analysisStart: epochStart,
            analysisEnd: physicalEnd,
            speaker: Self.assignment(start: epochStart, end: physicalEnd, activity: activity, allowDominance: false),
            analysisSpanIDs: spanIDs,
            confidence: nil
        )]
    }

    /// The contiguous run of the epoch's spans intersecting the unit's analysis interval.
    /// Contiguity is structural: the epoch's spans tile its analysis interval with no holes.
    private nonisolated static func intersectingSpanIDs(
        start: TimeInterval,
        end: TimeInterval,
        spans: [MeetingAnalysisSpan]
        // nil means unavailable; an empty result means available with no values.
        // swiftlint:disable:next discouraged_optional_collection
    ) -> [String]? {
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        let ids = spans.filter {
            min($0.analysisInterval.end, end) - max($0.analysisInterval.start, start) > tolerance
        }.map(\.id)
        return ids.isEmpty ? nil : ids
    }

    private nonisolated enum MaterializedBoundary {
        case start
        case end
    }

    private nonisolated static func analysisTime(
        forMaterializedSeconds seconds: TimeInterval,
        boundary: MaterializedBoundary,
        materialized: MeetingMaterializedEpoch,
        spans: [MeetingAnalysisSpan]
    ) -> TimeInterval? {
        self.analysisTime(
            forMaterializedSeconds: seconds,
            boundary: boundary,
            sampleRate: materialized.sampleRate,
            sampleCount: materialized.samples.count,
            spanSamples: materialized.spanSamples,
            spans: spans
        )
    }

    /// Maps model/provider time through the actual resampled per-span sample ranges. This avoids
    /// accumulating a frame-rounding error at every source-file boundary and then pretending the
    /// concatenated buffer is an exact one-to-one copy of manifest analysis seconds.
    private nonisolated static func analysisTime(
        forMaterializedSeconds seconds: TimeInterval,
        boundary: MaterializedBoundary,
        sampleRate: Double,
        sampleCount: Int,
        spanSamples: [MeetingMaterializedSpanSamples],
        spans: [MeetingAnalysisSpan]
    ) -> TimeInterval? {
        guard seconds.isFinite, sampleRate.isFinite, sampleRate > 0, sampleCount > 0 else { return nil }
        let position = min(max(seconds * sampleRate, 0), Double(sampleCount))
        let probe: Double
        switch boundary {
        case .start:
            probe = min(position, Double(sampleCount).nextDown)
        case .end:
            probe = max(0, position == 0 ? 0 : position.nextDown)
        }
        let mappingsByID = Dictionary(
            spanSamples.map { ($0.spanID, $0.sampleRange) },
            uniquingKeysWith: { first, _ in first }
        )
        let spansByID = Dictionary(spans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard let mapping = spanSamples.first(where: {
            Double($0.sampleRange.lowerBound) <= probe && probe < Double($0.sampleRange.upperBound)
        }), let range = mappingsByID[mapping.spanID], let span = spansByID[mapping.spanID], !range.isEmpty
        else { return nil }
        let fraction = min(max(
            (position - Double(range.lowerBound)) / Double(range.count),
            0
        ), 1)
        return span.analysisInterval.start + fraction * span.analysisInterval.duration
    }

    /// Nemotron emits diarization decisions on this cadence (plan §4); a boundary sliver shorter
    /// than one output hop is model noise, not evidence of a second speaker.
    private nonisolated static let nemotronCadenceMaximumFloorSeconds: TimeInterval = 0.08
    private nonisolated static let handoffMaximumWordDurationSeconds: TimeInterval = 0.8
    private nonisolated static let handoffMaximumPreviousWordGapSeconds: TimeInterval = 0.8

    /// Conservative initial product policy for multi-candidate words, isolated here so the ratios
    /// are named and covered at exact boundaries instead of living as unexplained literals.
    private nonisolated enum SpeakerDominancePolicy {
        static let minimumLeaderCoverageFraction: Double = 0.5
        static let maximumRunnerUpCoverageFraction: Double = 0.2
        static let minimumLeaderToRunnerUpRatio: Double = 2.0
    }

    /// The cadence floor scaled down for short words, so an 80ms boundary hop can never be
    /// discarded outright from a 150ms word: never more than 20% of the unit's own duration.
    private nonisolated static func boundaryNoiseThresholdSeconds(duration: TimeInterval) -> TimeInterval {
        min(self.nemotronCadenceMaximumFloorSeconds, 0.2 * duration)
    }

    /// Clips each activity interval to the unit and unions same-token intervals before measuring
    /// coverage, so duplicate or fragmented diarizer segments for one slot never double-count.
    private nonisolated static func coverageSeconds(
        start: TimeInterval,
        end: TimeInterval,
        activity: [MeetingBackendSpeakerActivity]
    ) -> [MeetingBackendSpeakerToken: TimeInterval] {
        var intervalsByToken: [MeetingBackendSpeakerToken: [(start: TimeInterval, end: TimeInterval)]] = [:]
        for entry in activity {
            let clippedStart = max(entry.start, start)
            let clippedEnd = min(entry.end, end)
            guard clippedEnd > clippedStart else { continue }
            intervalsByToken[entry.token, default: []].append((clippedStart, clippedEnd))
        }
        var coverage: [MeetingBackendSpeakerToken: TimeInterval] = [:]
        for (token, intervals) in intervalsByToken {
            coverage[token] = Self.unionDurationSeconds(intervals)
        }
        return coverage
    }

    private nonisolated static func unionDurationSeconds(
        _ intervals: [(start: TimeInterval, end: TimeInterval)]
    ) -> TimeInterval {
        let sorted = intervals.sorted { $0.start < $1.start }
        guard var runStart = sorted.first?.start else { return 0 }
        var runEnd = sorted[0].end
        var total: TimeInterval = 0
        for interval in sorted.dropFirst() {
            if interval.start > runEnd {
                total += runEnd - runStart
                runStart = interval.start
                runEnd = interval.end
            } else {
                runEnd = max(runEnd, interval.end)
            }
        }
        total += runEnd - runStart
        return total
    }

    /// Coverage-based slot attribution (plan §4 "Backend-specific overlap dominance"): a candidate
    /// must clear the scaled cadence-noise floor to count at all; a sole surviving candidate
    /// assigns; multiple candidates assign only under a conservative dominance margin, and remain
    /// ambiguous otherwise. `allowDominance` is `false` for the whole-epoch utterance fallback,
    /// which has no word-level precision to justify picking a winner among real candidates.
    nonisolated static func assignment(
        start: TimeInterval,
        end: TimeInterval,
        activity: [MeetingBackendSpeakerActivity],
        allowDominance: Bool
    ) -> MeetingBackendSpeakerAssignment {
        let duration = end - start
        let threshold = Self.boundaryNoiseThresholdSeconds(duration: duration)
        let coverage = Self.coverageSeconds(start: start, end: end, activity: activity)
        let aboveThreshold = coverage.filter { $0.value > threshold }
        let ranked = aboveThreshold.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key.label < rhs.key.label
        }

        switch ranked.count {
        case 0:
            return .unassigned
        case 1:
            return .assigned(ranked[0].key)
        default:
            let leader = ranked[0]
            let runnerUp = ranked[1]
            let leaderFraction = duration > 0 ? leader.value / duration : 0
            let runnerUpFraction = duration > 0 ? runnerUp.value / duration : 0
            let decision: MeetingBackendSpeakerAssignment
            if allowDominance,
               leaderFraction >= SpeakerDominancePolicy.minimumLeaderCoverageFraction,
               runnerUpFraction <= SpeakerDominancePolicy.maximumRunnerUpCoverageFraction,
               leader.value >= runnerUp.value * SpeakerDominancePolicy.minimumLeaderToRunnerUpRatio
            {
                decision = .assigned(leader.key)
            } else {
                decision = .ambiguous(ranked.map(\.key).sorted { $0.label < $1.label })
            }
            #if DEBUG
            Self.logMultiCandidateDecision(
                duration: duration,
                candidateCoverageSeconds: ranked.map(\.value),
                decision: decision
            )
            #endif
            return decision
        }
    }

    /// Deliberately simple second pass for short turn-boundary words. The user chose the more
    /// readable handoff behavior despite its known risk for genuine interruption/backchannel
    /// speech. Coverage remains the first-pass authority; this only resolves an otherwise
    /// ambiguous two-slot result with immediate assigned-word context.
    nonisolated static func handoffAssignment(
        _ coverageAssignment: MeetingBackendSpeakerAssignment,
        start: TimeInterval,
        end: TimeInterval,
        activity: [MeetingBackendSpeakerActivity],
        previousAssignedWord: (token: MeetingBackendSpeakerToken, end: TimeInterval)?
    ) -> MeetingBackendSpeakerAssignment {
        guard case let .ambiguous(candidates) = coverageAssignment,
              candidates.count == 2,
              let previousAssignedWord,
              candidates.contains(previousAssignedWord.token)
        else { return coverageAssignment }

        let duration = end - start
        let gap = start - previousAssignedWord.end
        guard duration.isFinite,
              duration > 0,
              duration <= Self.handoffMaximumWordDurationSeconds,
              gap.isFinite,
              gap >= -Self.nemotronCadenceMaximumFloorSeconds,
              gap <= Self.handoffMaximumPreviousWordGapSeconds
        else { return coverageAssignment }

        guard let other = candidates.first(where: { $0 != previousAssignedWord.token }) else {
            return coverageAssignment
        }
        let otherOnsets = activity.compactMap { entry -> TimeInterval? in
            guard entry.token == other,
                  min(entry.end, end) - max(entry.start, start)
                  > MeetingAnalysisManifestSchema.mappingToleranceSeconds
            else { return nil }
            return entry.start
        }
        guard let otherOnset = otherOnsets.min() else { return coverageAssignment }
        let onsetDelta = otherOnset - start
        let resolved: MeetingBackendSpeakerAssignment = abs(onsetDelta)
            <= Self.nemotronCadenceMaximumFloorSeconds
            ? .assigned(other)
            : .assigned(previousAssignedWord.token)

        #if DEBUG
        Self.logHandoffDecision(
            duration: duration,
            previousWordGap: gap,
            otherOnsetDelta: onsetDelta,
            assignedEntrant: abs(onsetDelta) <= Self.nemotronCadenceMaximumFloorSeconds
        )
        #endif
        return resolved
    }

    #if DEBUG
    /// Structured, DEBUG-only measurement of a multi-candidate word decision. Deliberately carries
    /// only durations, coverage seconds and the resulting decision kind — never transcript text,
    /// unit/word identity, file paths, or participant identity.
    private nonisolated static func logMultiCandidateDecision(
        duration: TimeInterval,
        candidateCoverageSeconds: [TimeInterval],
        decision: MeetingBackendSpeakerAssignment
    ) {
        let decisionLabel: String
        switch decision {
        case .assigned: decisionLabel = "dominant"
        case .ambiguous: decisionLabel = "ambiguous"
        case .unassigned: decisionLabel = "unassigned"
        }
        let overlaps = candidateCoverageSeconds
            .map { String(format: "%.3f", $0) }
            .joined(separator: ",")
        DebugLogger.shared.info(
            String(
                format: "[speakerCoverage] duration=%.3fs candidates=%d overlaps=[%@] decision=%@",
                duration,
                candidateCoverageSeconds.count,
                overlaps,
                decisionLabel
            ),
            source: "MeetingParakeetNemotronBackend"
        )
    }

    private nonisolated static func logHandoffDecision(
        duration: TimeInterval,
        previousWordGap: TimeInterval,
        otherOnsetDelta: TimeInterval,
        assignedEntrant: Bool
    ) {
        DebugLogger.shared.info(
            String(
                format: "[speakerHandoff] duration=%.3fs previousGap=%.3fs otherOnsetDelta=%.3fs decision=%@",
                duration,
                previousWordGap,
                otherOnsetDelta,
                assignedEntrant ? "entrant" : "incumbent"
            ),
            source: "MeetingParakeetNemotronBackend"
        )
    }
    #endif
}
