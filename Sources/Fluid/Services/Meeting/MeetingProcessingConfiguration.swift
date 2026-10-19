import Foundation

/// Immutable value snapshot of meeting post-processing ASR configuration. The pipeline builds it
/// once per attempt and the meeting preparation owner constructs a fixed provider from it, so an
/// active run never follows later dictation-setting changes.
nonisolated struct MeetingFinalProcessingConfiguration: Codable, Equatable, Sendable {
    static let defaultASRModel = "parakeet-tdt-v2"
    static let defaultLanguageCode = "en"
    /// Mirrors `MeetingProcessingPipeline.pipelineVersion`; that class is `@MainActor`, so a
    /// MainActor test guards this literal against drift instead of referencing it here.
    static let defaultPipelineVersion = 16

    let asrModel: String
    let asrArtifactFingerprint: String?
    let asrArtifactDirectory: URL?
    let languageCode: String
    let vocabularyBoostingEnabled: Bool
    let pronunciationMatchingEnabled: Bool
    let customDictionaryRewritingEnabled: Bool
    let experimentalUnifiedFinalEnabled: Bool
    let diarizationFingerprint: String
    let pipelineVersion: Int
    let speakerLabelsEnabled: Bool
    /// Nil preserves older encoded snapshots and their exact identity framing.
    let speakerProcessingMode: MeetingSpeakerProcessingMode?
    /// Nil identifies an older configuration and retains its legacy presentation policy.
    let speakerAttributionPolicy: MeetingSpeakerAttributionPolicy?

    init(
        asrModel: String? = nil,
        asrArtifactFingerprint: String? = nil,
        asrArtifactDirectory: URL? = nil,
        languageCode: String = Self.defaultLanguageCode,
        vocabularyBoostingEnabled: Bool = false,
        pronunciationMatchingEnabled: Bool = false,
        customDictionaryRewritingEnabled: Bool = false,
        experimentalUnifiedFinalEnabled: Bool = false,
        diarizationFingerprint: String = MeetingProcessingCheckpoint.currentDiarizationFingerprint,
        pipelineVersion: Int = Self.defaultPipelineVersion,
        speakerLabelsEnabled: Bool = true,
        speakerProcessingMode: MeetingSpeakerProcessingMode = .afterRecording,
        speakerAttributionPolicy: MeetingSpeakerAttributionPolicy? = .standard
    ) {
        self.asrModel = asrModel ?? (languageCode == Self.defaultLanguageCode ? Self.defaultASRModel : "parakeet-tdt")
        self.asrArtifactFingerprint = asrArtifactFingerprint
        self.asrArtifactDirectory = asrArtifactDirectory
        self.languageCode = languageCode
        self.vocabularyBoostingEnabled = vocabularyBoostingEnabled
        self.pronunciationMatchingEnabled = pronunciationMatchingEnabled
        self.customDictionaryRewritingEnabled = customDictionaryRewritingEnabled
        self.experimentalUnifiedFinalEnabled = experimentalUnifiedFinalEnabled
        self.diarizationFingerprint = diarizationFingerprint
        self.pipelineVersion = pipelineVersion
        self.speakerLabelsEnabled = speakerLabelsEnabled
        self.speakerProcessingMode = speakerLabelsEnabled && speakerProcessingMode == .streaming ? .streaming : nil
        self.speakerAttributionPolicy = speakerAttributionPolicy
    }

    var effectiveSpeakerProcessingMode: MeetingSpeakerProcessingMode {
        self.speakerLabelsEnabled ? self.speakerProcessingMode ?? .afterRecording : .afterRecording
    }

    /// Identity of this inert configuration snapshot only. It does not by itself prove the runtime
    /// enforced these options; resumability may rely on it only once processing fully applies them.
    var identityFingerprint: String {
        var pairs: [(key: String, value: String)] = [
            ("asr", self.asrModel),
            ("lang", self.languageCode),
            ("vocabBoost", String(self.vocabularyBoostingEnabled)),
            ("pronunciationMatch", String(self.pronunciationMatchingEnabled)),
            ("dictionaryRewrite", String(self.customDictionaryRewritingEnabled)),
            ("unifiedFinal", String(self.experimentalUnifiedFinalEnabled)),
            ("diarizer", self.diarizationFingerprint),
            ("pipeline", String(self.pipelineVersion)),
            ("speakerLabels", String(self.speakerLabelsEnabled)),
            ("speakerAttribution", self.speakerAttributionPolicy?.fingerprint ?? "legacy-raw"),
        ]
        if let asrArtifactFingerprint { pairs.append(("asrArtifact", asrArtifactFingerprint)) }
        if self.effectiveSpeakerProcessingMode == .streaming { pairs.append(("speakerProcessing", "streaming")) }
        return MeetingConfigFingerprintEncoding.encode(pairs)
    }
}

/// Inert value snapshot of live-caption ASR configuration. Live captions do no diarization.
nonisolated struct MeetingLiveCaptionsConfiguration: Equatable, Sendable {
    static let defaultModelRepositoryID = "FluidInference/parakeet-realtime-eou-120m-coreml"
    static let defaultModelVariant = "160ms"
    /// Branch selected by the current loader; source pins no resolved HF commit, so this is the
    /// loader default, not a revision pin.
    static let defaultModelRevision = "main"
    static let defaultChunkSizeMilliseconds = 160
    static let defaultLanguageCode = "en"

    let modelRepositoryID: String
    let modelVariant: String
    let modelRevision: String
    let chunkSizeMilliseconds: Int
    let languageCode: String

    init(
        modelRepositoryID: String = Self.defaultModelRepositoryID,
        modelVariant: String = Self.defaultModelVariant,
        modelRevision: String = Self.defaultModelRevision,
        chunkSizeMilliseconds: Int = Self.defaultChunkSizeMilliseconds,
        languageCode: String = Self.defaultLanguageCode
    ) {
        self.modelRepositoryID = modelRepositoryID
        self.modelVariant = modelVariant
        self.modelRevision = modelRevision
        self.chunkSizeMilliseconds = chunkSizeMilliseconds
        self.languageCode = languageCode
    }

    var identityFingerprint: String {
        MeetingConfigFingerprintEncoding.encode([
            ("modelRepo", self.modelRepositoryID),
            ("modelVariant", self.modelVariant),
            ("revision", self.modelRevision),
            ("revisionState", "unresolved"),
            ("chunkMs", String(self.chunkSizeMilliseconds)),
            ("lang", self.languageCode),
            ("diarizer", "none"),
        ])
    }
}
