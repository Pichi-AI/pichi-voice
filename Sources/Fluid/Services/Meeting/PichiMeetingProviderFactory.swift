import Foundation

/// Compiled downstream registrations. Adding a provider changes this composition boundary and
/// its inference adapter, without adding model fields to the meeting pipeline or host context.
@MainActor
enum PichiMeetingProviderFactory {
    nonisolated static let gigaamModelID = "gigaam-v3-eou"
    // Retain the persisted identifier from the first downstream implementation.
    nonisolated static let transcriptOnlyDiarizationFingerprint = "unavailable:gigaam-transcript-only-v1"

    private nonisolated struct Registration: Sendable {
        let descriptor: MeetingBackendDescriptor
        let defaultLanguageCode: String
        let providerFactory: @MainActor (MeetingFinalProcessingConfiguration) throws -> any TranscriptionProvider
        let configurationSnapshot: @MainActor (String, String?) -> MeetingFinalProcessingConfiguration
        let modelsExistOnDisk: @Sendable () -> Bool
    }

    private nonisolated static let registrations: [String: Registration] = [
        PichiMeetingProviderFactory.gigaamModelID: Registration(
            descriptor: MeetingBackendDescriptor(
                id: .gigaam,
                version: "1",
                execution: .local,
                supportedLanguageCodes: ["ru"],
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.word, .utterance],
                resultContract: .canonicalEvidence,
                knownLimits: [
                    "GigaAM is a Russian recognition model; other languages require another selected model.",
                    "Word times come from CTC token frames. Text without usable word timings remains an utterance.",
                    "Automatic speaker separation requires an installed Nemotron model and Apple Silicon.",
                    "Without diarization, speaker identities remain unknown; microphone/application source tracks remain distinct.",
                ],
                analysisSampleRate: 16_000
            ),
            defaultLanguageCode: "ru",
            providerFactory: { configuration in
                let store = configuration.asrArtifactDirectory.map { PichiGigaAMModelStore(directory: $0) } ?? .shared
                return PichiGigaAMProvider(modelStore: store, expectedModelFingerprint: configuration.asrArtifactFingerprint)
            },
            configurationSnapshot: { languageCode, artifactFingerprintOverride in
                PichiMeetingProviderFactory.gigaamConfiguration(languageCode: languageCode, artifactFingerprintOverride: artifactFingerprintOverride)
            },
            modelsExistOnDisk: { PichiGigaAMModelStore.shared.modelsExistOnDisk() }
        ),
    ]

    nonisolated static func registeredLanguageCodes(for modelID: String) -> Set<String>? {
        self.registrations[modelID]?.descriptor.supportedLanguageCodes
    }

    nonisolated static func registeredBackendDescriptor(for modelID: String) -> MeetingBackendDescriptor? {
        self.registrations[modelID]?.descriptor
    }

    nonisolated static func defaultLanguageCode(for modelID: String) -> String? {
        self.registrations[modelID]?.defaultLanguageCode
    }

    nonisolated static func registeredModelsExistOnDisk(for modelID: String) -> Bool? {
        self.registrations[modelID]?.modelsExistOnDisk()
    }

    nonisolated static func isTranscriptOnlyDiarizationFingerprint(_ value: String?) -> Bool {
        value?.hasPrefix("unavailable:") == true
    }

    static func registerBackends(in registry: MeetingTranscriptionBackendRegistry) {
        for (modelID, registration) in self.registrations {
            registry.register(registration.descriptor.id) { context in
                MeetingProviderBackedBackend(
                    descriptor: registration.descriptor,
                    providerModelID: modelID,
                    runtimeFactory: context.parakeetNemotronRuntimeFactory
                )
            }
        }
    }

    static func make(_ configuration: MeetingFinalProcessingConfiguration) throws -> any TranscriptionProvider {
        _ = try MeetingProviderOptions.resolve(configuration)
        if let registration = self.registrations[configuration.asrModel] {
            return try registration.providerFactory(configuration)
        }
        return try FluidAudioProvider(meetingConfiguration: configuration)
    }

    static func selectedBackendID(languageCode: String) -> MeetingBackendID {
        if let registration = self.registrations[SettingsStore.shared.selectedSpeechModel.rawValue] {
            return registration.descriptor.id
        }
        let saved = SettingsStore.shared.meetingTranscriptionBackendID
        return saved == .legacyCompatibility && languageCode != "en" ? .productionDefault : saved
    }

    /// The returned value is frozen once per attempt and used by planning, ASR and metadata.
    static func configuration(
        backendID: MeetingBackendID,
        languageCode: String,
        artifactFingerprintOverride: String? = nil
    ) -> MeetingFinalProcessingConfiguration {
        if let registration = self.registrations.values.first(where: { $0.descriptor.id == backendID }) {
            return registration.configurationSnapshot(languageCode, artifactFingerprintOverride)
        }
        return MeetingFinalProcessingConfiguration(languageCode: languageCode)
    }

    static func configuration(
        asrModel: String,
        languageCode: String,
        artifactFingerprintOverride: String? = nil
    ) -> MeetingFinalProcessingConfiguration {
        if let registration = self.registrations[asrModel] {
            return registration.configurationSnapshot(languageCode, artifactFingerprintOverride)
        }
        return MeetingFinalProcessingConfiguration(asrModel: asrModel, languageCode: languageCode)
    }

    private static func gigaamConfiguration(
        languageCode: String,
        artifactFingerprintOverride: String?
    ) -> MeetingFinalProcessingConfiguration {
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

// Existing downstream source references retain their stable identity; registration owns the ID.
extension MeetingBackendID {
    nonisolated static let gigaam = MeetingBackendID(rawValue: "local-gigaam-v3-eou-v1")
}
