import Foundation

/// Immutable value snapshot of meeting post-processing ASR configuration. The pipeline builds it
/// once per attempt and the meeting preparation owner constructs a fixed provider from it, so an
/// active run never follows later dictation-setting changes.
nonisolated struct MeetingFinalProcessingConfiguration: Codable, Equatable, Sendable {
    static let defaultASRModel = "parakeet-tdt-v2"
    static let defaultLanguageCode = "en"
    /// One shared immutable version keeps frozen requests and saved attempts consistent.
    static let defaultPipelineVersion = MeetingProcessingPipeline.pipelineVersion

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
    var recordingTimePolicy: MeetingRecordingTimePolicy? = nil
    let speakerLabelsEnabled: Bool
    /// Nil preserves older encoded snapshots and their exact identity framing.
    let speakerProcessingMode: MeetingSpeakerProcessingMode?
    /// Nil identifies an older configuration and retains its legacy presentation policy.
    let speakerAttributionPolicy: MeetingSpeakerAttributionPolicy?

    init(
        asrModel: String? = nil,
        asrArtifactFingerprint: String? = nil,
        asrArtifactDirectory: URL? = nil,
        preferredASRModel: SettingsStore.SpeechModel? = nil,
        languageCode: String = Self.defaultLanguageCode,
        vocabularyBoostingEnabled: Bool = false,
        pronunciationMatchingEnabled: Bool = false,
        customDictionaryRewritingEnabled: Bool = false,
        experimentalUnifiedFinalEnabled: Bool = false,
        diarizationFingerprint: String = MeetingProcessingCheckpoint.currentDiarizationFingerprint,
        pipelineVersion: Int = Self.defaultPipelineVersion,
        speakerLabelsEnabled: Bool = true,
        speakerProcessingMode: MeetingSpeakerProcessingMode = .afterRecording,
        speakerAttributionPolicy: MeetingSpeakerAttributionPolicy? = .standard,
        recordingTimePolicy: MeetingRecordingTimePolicy? = nil
    ) {
        self.asrArtifactFingerprint = asrArtifactFingerprint
        self.asrArtifactDirectory = asrArtifactDirectory
        self.asrModel = asrModel ?? MeetingProviderOptions.preferredModel(for: languageCode, selected: preferredASRModel).rawValue
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
        self.recordingTimePolicy = recordingTimePolicy
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
        if let recordingTimePolicy { pairs.append(("recordingTimePolicy", recordingTimePolicy.rawValue)) }
        if let asrArtifactFingerprint { pairs.append(("asrArtifact", asrArtifactFingerprint)) }
        if self.effectiveSpeakerProcessingMode == .streaming { pairs.append(("speakerProcessing", "streaming")) }
        return MeetingConfigFingerprintEncoding.encode(pairs)
    }
}

/// Retained attempts preserve language identifiers independently of the current model selection.
/// Backend admission validates support when a new processing attempt is planned.
enum MeetingRetranscriptionLanguage {
    nonisolated static func canonicalCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard code == "auto" || code.range(of: "^[A-Za-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else { return nil }
        return code
    }

    static var choices: [VoiceEngineLanguage] {
        let availableModels = Set(SettingsStore.SpeechModel.availableModels)
        let supportedLanguageCodes = PichiMeetingProviderFactory.retranscriptionModels
            .filter { availableModels.contains($0) }
            .reduce(into: Set<String>()) { codes, model in
                if let registered = PichiMeetingProviderFactory.registeredLanguageCodes(for: model.rawValue) {
                    codes.formUnion(registered)
                } else if MeetingProviderOptions.supportedModels.contains(model), let descriptor = model.parakeetDescriptor {
                    codes.formUnion(descriptor.supportedLanguageCodes)
                }
            }
        return VoiceEngineLanguageCatalog.allLanguages(supportedLanguageCodes: supportedLanguageCodes)
    }

    static func displayName(for languageCode: String) -> String {
        self.choices.first { $0.id == languageCode }?.displayName ?? languageCode
    }

    /// A same-language run replaces nothing and, if it fails, hides the transcript that is already there.
    nonisolated static func canRetranscribe(selection: String, currentLanguageCode: String) -> Bool {
        guard let code = canonicalCode(selection) else { return false }
        return code != currentLanguageCode
    }

    /// The language an empty meeting should try again. Use the latest attempt that recorded a
    /// language, pending or failed. A later recovery attempt with no language must not hide that
    /// request, and an older failure must not replace a newer one.
    nonisolated static func failedAttemptLanguage(for session: MeetingSession) -> String? {
        guard session.transcriptSegments.isEmpty,
              let language = session.processingAttempts.last(where: { $0.languageCode != nil })?.languageCode,
              canRetranscribe(selection: language, currentLanguageCode: session.languageCode)
        else { return nil }
        return Self.canonicalCode(language)
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
