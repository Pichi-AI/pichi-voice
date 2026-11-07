import Foundation

nonisolated enum ModelPreparationPhase: Sendable, Equatable {
    case preparingDownload
    case downloading
    case optimizing
    case loading
}

nonisolated struct ModelPreparationProgress: Sendable, Equatable {
    let phase: ModelPreparationPhase
    let fractionCompleted: Double?

    init(phase: ModelPreparationPhase, fractionCompleted: Double? = nil) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted.map { max(0.0, min(1.0, $0)) }
    }

    static let preparingDownload = ModelPreparationProgress(phase: .preparingDownload)
    static let optimizing = ModelPreparationProgress(phase: .optimizing)
    static let loading = ModelPreparationProgress(phase: .loading)

    static func downloading(_ fractionCompleted: Double) -> ModelPreparationProgress {
        ModelPreparationProgress(phase: .downloading, fractionCompleted: fractionCompleted)
    }
}

/// Bridges provider callbacks into dependencies whose progress handlers are `@Sendable`.
/// The callback is immutable; callers remain responsible for hopping to their UI actor.
final nonisolated class ModelPreparationProgressRelay: @unchecked Sendable {
    private static let minimumDeliveryInterval: TimeInterval = 0.1

    private let handler: ((ModelPreparationProgress) -> Void)?
    private let lock = NSLock()
    private var lastPhase: ModelPreparationPhase?
    private var lastDeliveredPercentage: Int?
    private var lastDeliveryTime: TimeInterval = 0
    private var pendingProgress: ModelPreparationProgress?
    private var deliveryScheduled = false

    init(_ handler: ((ModelPreparationProgress) -> Void)?) {
        self.handler = handler
    }

    func report(_ progress: ModelPreparationProgress) {
        let now = ProcessInfo.processInfo.systemUptime
        let delivery = self.lock.withLock { () -> (immediate: Bool, delay: TimeInterval?) in
            if progress.phase != self.lastPhase {
                self.lastPhase = progress.phase
                self.pendingProgress = nil
                self.lastDeliveredPercentage = nil
                self.lastDeliveryTime = now
                return (true, nil)
            }

            guard progress.phase == .downloading else { return (false, nil) }

            let percentage = Int((progress.fractionCompleted ?? 0) * 100)
            guard percentage != self.lastDeliveredPercentage else { return (false, nil) }

            let elapsed = now - self.lastDeliveryTime
            if elapsed >= Self.minimumDeliveryInterval {
                self.pendingProgress = nil
                self.lastDeliveredPercentage = percentage
                self.lastDeliveryTime = now
                return (true, nil)
            }

            self.pendingProgress = progress
            guard !self.deliveryScheduled else { return (false, nil) }
            self.deliveryScheduled = true
            return (false, Self.minimumDeliveryInterval - elapsed)
        }

        if delivery.immediate {
            self.handler?(progress)
        } else if let delay = delivery.delay {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.flushPendingProgress()
            }
        }
    }

    private func flushPendingProgress() {
        let progress = self.lock.withLock { () -> ModelPreparationProgress? in
            self.deliveryScheduled = false
            guard let progress = self.pendingProgress,
                  progress.phase == self.lastPhase
            else {
                self.pendingProgress = nil
                return nil
            }

            self.pendingProgress = nil
            self.lastDeliveredPercentage = Int((progress.fractionCompleted ?? 0) * 100)
            self.lastDeliveryTime = ProcessInfo.processInfo.systemUptime
            return progress
        }
        if let progress {
            self.handler?(progress)
        }
    }
}

// MARK: - Transcription Result

/// Unified result type for ASR transcription across all providers
/// Named ASRTranscriptionResult to avoid conflict with MeetingTranscriptionService.TranscriptionResult
nonisolated struct ASRTranscriptionResult: Sendable {
    let text: String
    let confidence: Float
    /// Optional calibrated endpoint evidence from providers that actually expose an EOU head.
    let endOfUtteranceProbability: Float?
    /// FluidAudio's own Parakeet processing time. This excludes FluidVoice
    /// executor queueing, provider setup, and post-transcription work.
    let parakeetProcessingDurationMilliseconds: Int?
    let pronunciationEnrollment: PronunciationEnrollmentCapture?
    let dictionaryLearningAlignment: DictionaryLearningAlignment?
    /// Native utterance intervals, when a provider cannot supply word alignment.
    /// These retain coarser timing precision and must never be presented as word times.
    let segmentTimings: [ASRSegmentTiming]

    init(
        text: String,
        confidence: Float = 1.0,
        endOfUtteranceProbability: Float? = nil,
        parakeetProcessingDurationMilliseconds: Int? = nil,
        pronunciationEnrollment: PronunciationEnrollmentCapture? = nil,
        dictionaryLearningAlignment: DictionaryLearningAlignment? = nil,
        segmentTimings: [ASRSegmentTiming] = []
    ) {
        self.text = text
        self.confidence = confidence
        self.endOfUtteranceProbability = endOfUtteranceProbability
        self.parakeetProcessingDurationMilliseconds = parakeetProcessingDurationMilliseconds
        self.pronunciationEnrollment = pronunciationEnrollment
        self.dictionaryLearningAlignment = dictionaryLearningAlignment
        self.segmentTimings = segmentTimings
    }
}

/// Token emission envelopes locate decoder output, not measured spoken-word boundaries.
/// A recognition owner adds source context before filtering or rebasing the native word list.
/// Missing metadata retains the older provider contract without guessing its timing basis.
nonisolated struct ASRWordTimingProvenance: Codable, Equatable, Sendable {
    enum Basis: String, Codable, Sendable { case tokenEmission }

    let basis: Basis
    let sourceWindowID: String?
    let sourceWordIndex: Int?

    init(basis: Basis, sourceWindowID: String? = nil, sourceWordIndex: Int? = nil) {
        self.basis = basis
        self.sourceWindowID = sourceWindowID
        self.sourceWordIndex = sourceWordIndex
    }

    var hasValidSourceContext: Bool {
        guard let sourceWindowID, let sourceWordIndex,
              Self.validWindowID(sourceWindowID),
              (0..<8_192).contains(sourceWordIndex) else { return false }
        return true
    }

    var isValid: Bool {
        (self.sourceWindowID == nil && self.sourceWordIndex == nil) || self.hasValidSourceContext
    }

    private static func validWindowID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Namespace the provider's original inference context, never enumerate its filtered output.
    /// Basis-only metadata stays unscoped; missing native positions cannot be reconstructed here.
    func scoped(to namespace: String) -> Self? {
        guard self.isValid, Self.validWindowID(namespace) else { return nil }
        guard let sourceWindowID, let sourceWordIndex else { return self }
        let scoped = Self(basis: self.basis, sourceWindowID: "\(namespace)/\(sourceWindowID)",
                          sourceWordIndex: sourceWordIndex)
        return scoped.hasValidSourceContext ? scoped : nil
    }
}

nonisolated struct ASRWordTiming: Codable, Sendable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let timingProvenance: ASRWordTimingProvenance?

    init(text: String, start: TimeInterval, end: TimeInterval,
         timingProvenance: ASRWordTimingProvenance? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.timingProvenance = timingProvenance
    }
}

/// A provider's actual segment boundary, in seconds from its input PCM start.
/// Unlike word alignment, one interval may contain multiple words or a sentence.
nonisolated struct ASRSegmentTiming: Codable, Sendable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    /// Partial or malformed timing metadata must not silently discard wording or
    /// invent a speaker boundary. Admit only an ordered, physically valid complete
    /// segmentation whose rendered text still equals the provider's whole result.
    static func validated(_ segments: [Self], text: String, duration: TimeInterval) -> [Self] {
        guard duration.isFinite, duration > 0, !segments.isEmpty, segments.count <= 8_192 else { return [] }
        var previousEnd: TimeInterval = 0
        for segment in segments {
            guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  segment.start.isFinite, segment.end.isFinite, segment.start >= previousEnd,
                  segment.end > segment.start, segment.end <= duration + 1e-6 else { return [] }
            previousEnd = segment.end
        }
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard normalized(segments.map(\.text).joined(separator: " ")) == normalized(text) else { return [] }
        return segments
    }
}

/// The prepared execution policy reported by a provider. This is configuration,
/// not a measurement of GPU or Neural Engine utilization.
nonisolated struct TranscriptionExecutionStatus: Sendable, Equatable {
    enum Backend: String, Sendable {
        case cpu
        case gpu
        case neuralEngine

        var label: String {
            switch self {
            case .cpu: return "CPU"
            case .gpu: return "GPU"
            case .neuralEngine: return "Neural Engine"
            }
        }
    }

    let backend: Backend
    /// A bounded localization key supplied by the adapter, never a raw inference error.
    let fallbackReason: String?

    init(backend: Backend, fallbackReason: String? = nil) {
        self.backend = backend
        self.fallbackReason = fallbackReason
    }
}

// MARK: - Transcription Provider Protocol

/// Protocol that abstracts speech-to-text transcription.
/// Implementations can use different backends (FluidAudio, transcribe.cpp, etc.)
protocol TranscriptionProvider {
    /// Display name of the provider
    var name: String { get }

    /// Whether this provider is available on the current system
    var isAvailable: Bool { get }

    /// Whether models are downloaded and ready
    var isReady: Bool { get }

    /// Non-nil only for a prepared, on-device pronunciation encoder.
    /// History learning must not send retained recordings to an unsupported service.
    var pronunciationProfileModelKey: String? { get }

    /// Current prepared execution policy, or nil when the provider does not report it.
    var executionStatus: TranscriptionExecutionStatus? { get }

    /// Download/prepare models for transcription.
    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws

    /// Freeze provider-owned transcription options before the admitted operation first suspends.
    /// The caller retains this same provider until all streaming/final work has joined.
    /// Admission is atomic: on failure the provider releases any partially acquired options.
    @MainActor func beginAdmittedTranscription(leaseID: UUID) throws

    /// Release only the matching operation's immutable private options after its work joins.
    @MainActor func endAdmittedTranscription(leaseID: UUID) async

    /// Transcribe audio samples
    /// - Parameter samples: 16kHz mono PCM float samples
    /// - Returns: Transcription result with text and confidence
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult

    /// Transcribe audio for live streaming updates.
    /// Providers can use faster/lighter paths than final transcription when needed.
    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult

    /// Transcribe audio for final output when recording stops.
    /// Providers can use higher-quality passes (e.g., vocabulary rescoring) here.
    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult

    /// Transcribe audio captured while training dictionary replacements.
    /// Providers can bypass final-output transforms that would distort the saved phrase.
    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult
    func transcribeDictionaryTraining(_ samples: [Float], capturePronunciation: Bool) async throws -> ASRTranscriptionResult

    /// Validate the provider's own acoustic representation before the shared wizard
    /// commits it. Counting recordings alone does not establish a usable template.
    func validateDictionaryPronunciations(_ captures: [PronunciationEnrollmentCapture]) async throws -> Bool

    /// Extract a pronunciation example from the immutable source occurrence, when compatible.
    /// Providers own feature-format and artifact validation; nil leaves legacy extraction available.
    func originalAudioEnrollment(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture?

    /// Meeting word alignment only; dictation never calls the method this gates.
    var supportsWordTimings: Bool { get }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming])

    /// Whether this provider prefers to handle long-form file transcription itself.
    /// This is useful when the backend already has model-native long-audio chunking/reassembly.
    var prefersNativeFileTranscription: Bool { get }

    /// Transcribe a complete audio/video file.
    /// Providers that do not implement this can rely on MeetingTranscriptionService fallback chunking.
    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult

    /// Check if models exist on disk (without loading them)
    func modelsExistOnDisk() -> Bool

    /// Release owned runtime allocations after pending work has drained, without deleting weights.
    /// The caller awaits this hook before discarding its provider references or loading a successor.
    func releaseResidency() async

    /// Install a supported local model folder. Implementations validate and atomically publish
    /// artifacts; cancellation must join any file operation before returning.
    func importModel(from directory: URL) async throws

    /// Restore the registered download source after an explicit local import, retaining weights.
    /// Callers use the same maintenance admission and joined cleanup as folder import.
    func restoreDefaultModelSource() async throws

    /// Clear cached models
    func clearCache() async throws

    /// Whether cancellation should discard an incomplete app-managed model cache.
    var shouldClearCacheAfterCancellation: Bool { get }
}

// Default implementation for optional methods
extension TranscriptionProvider {
    var pronunciationProfileModelKey: String? { nil }
    var executionStatus: TranscriptionExecutionStatus? { nil }
    @MainActor func beginAdmittedTranscription(leaseID: UUID) throws {}
    @MainActor func endAdmittedTranscription(leaseID: UUID) async {}
    func modelsExistOnDisk() -> Bool { return false }
    func clearCache() async throws {}
    /// Legacy providers with no pooled runtime retain their existing reference-owned teardown.
    func releaseResidency() async {}
    func importModel(from directory: URL) async throws {
        throw NSError(domain: "TranscriptionProvider", code: -2, userInfo: [
            NSLocalizedDescriptionKey: AppBrand.text("This speech model does not support importing a model folder."),
        ])
    }
    func restoreDefaultModelSource() async throws {
        throw NSError(domain: "TranscriptionProvider", code: -3, userInfo: [
            NSLocalizedDescriptionKey: AppBrand.text("This speech model does not support changing its model source."),
        ])
    }
    var shouldClearCacheAfterCancellation: Bool { true }
    var prefersNativeFileTranscription: Bool { false }
    var supportsWordTimings: Bool { false }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        try (await self.transcribe(samples), [])
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples)
    }

    func transcribeDictionaryTraining(_ samples: [Float], capturePronunciation: Bool) async throws -> ASRTranscriptionResult {
        try await self.transcribeDictionaryTraining(samples)
    }

    func validateDictionaryPronunciations(_ captures: [PronunciationEnrollmentCapture]) async throws -> Bool { true }

    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeFinal(samples)
    }

    func originalAudioEnrollment(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture? {
        nil
    }

    func transcribeFile(at fileURL: URL) async throws -> ASRTranscriptionResult {
        throw NSError(
            domain: "TranscriptionProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "\(self.name) does not implement native file transcription."]
        )
    }
}

// MARK: - Architecture Detection

/// Utility to detect the current CPU architecture
enum CPUArchitecture {
    case applesilicon
    case intel

    static var current: CPUArchitecture {
        #if arch(arm64)
        return .applesilicon
        #else
        return .intel
        #endif
    }

    static var isAppleSilicon: Bool {
        current == .applesilicon
    }

    static var isIntel: Bool {
        current == .intel
    }
}
