import Foundation

/// Pichi-specific model selection stays outside the upstream provider implementation.
@MainActor
enum PichiMeetingProviderFactory {
    nonisolated static let gigaamModelID = "gigaam-v3-eou"
    nonisolated static let transcriptOnlyDiarizationFingerprint = "unavailable:gigaam-transcript-only-v1"

    static func make(_ configuration: MeetingFinalProcessingConfiguration) throws -> any TranscriptionProvider {
        _ = try MeetingProviderOptions.resolve(configuration)
        if configuration.asrModel == self.gigaamModelID {
            let store = configuration.asrArtifactDirectory.map { PichiGigaAMModelStore(directory: $0) } ?? .shared
            return PichiGigaAMProvider(modelStore: store, expectedModelFingerprint: configuration.asrArtifactFingerprint)
        }
        return try FluidAudioProvider(meetingConfiguration: configuration)
    }

    static func selectedBackendID(languageCode: String) -> MeetingBackendID {
        if SettingsStore.shared.selectedSpeechModel.rawValue == self.gigaamModelID { return .gigaam }
        let saved = SettingsStore.shared.meetingTranscriptionBackendID
        return saved == .legacyCompatibility && languageCode != "en" ? .productionDefault : saved
    }

    /// The returned value is frozen once per attempt and used by planning, ASR and metadata.
    static func configuration(
        backendID: MeetingBackendID,
        languageCode: String,
        artifactFingerprintOverride: String? = nil
    ) -> MeetingFinalProcessingConfiguration {
        guard backendID == .gigaam else {
            return MeetingFinalProcessingConfiguration(languageCode: languageCode)
        }
        let installed = try? PichiGigaAMModelStore.shared.installedModel()
        let artifactFingerprint = installed.flatMap {
            try? PichiGigaAMModelStore(directory: $0.directory).installedModelFingerprint()
        }
        let diarizationFingerprint: String
        #if arch(arm64)
        diarizationFingerprint = (try? MeetingNemotronModelLocator().locate()) == nil
            ? self.transcriptOnlyDiarizationFingerprint
            : MeetingProcessingCheckpoint.currentDiarizationFingerprint
        #else
        diarizationFingerprint = self.transcriptOnlyDiarizationFingerprint
        #endif
        return MeetingFinalProcessingConfiguration(
            asrModel: self.gigaamModelID,
            asrArtifactFingerprint: artifactFingerprintOverride ?? artifactFingerprint,
            asrArtifactDirectory: installed?.directory,
            languageCode: languageCode,
            diarizationFingerprint: diarizationFingerprint
        )
    }
}
