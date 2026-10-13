import Foundation

/// Compiled downstream registrations. Adding a provider changes this composition boundary and
/// its inference adapter, without adding model fields to the meeting pipeline or host context.
@MainActor
enum PichiMeetingProviderFactory {
    nonisolated static let gigaamModelID = "gigaam-v3-eou"
    nonisolated static let whisperTinyModelID = "whisper-tiny"
    nonisolated static let parakeetV3ModelID = "parakeet-tdt"
    // Retain the persisted identifier from the first downstream implementation.
    nonisolated static let transcriptOnlyDiarizationFingerprint = "unavailable:gigaam-transcript-only-v1"

    /// Resource reach is part of a registered inference capability, not a model switch
    /// in capture or the coordinator. These conservative admission values still require
    /// sustained inference/thermal measurements on each supported physical device.
    nonisolated struct LiveAdmission: Sendable, Equatable {
        let minimumPhysicalMemoryBytes: UInt64
        let maximumTrackCount: Int
    }

    private nonisolated struct Registration: Sendable {
        let descriptor: MeetingBackendDescriptor
        let defaultLanguageCode: String
        let providerFactory: @MainActor (MeetingFinalProcessingConfiguration) throws -> any TranscriptionProvider
        let configurationSnapshot: @MainActor (String, String?, Bool) -> MeetingFinalProcessingConfiguration
        let modelsExistOnDisk: @Sendable () -> Bool
        let liveAdmission: LiveAdmission
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
            configurationSnapshot: { languageCode, artifactFingerprintOverride, diarizationEnabled in
                PichiMeetingProviderFactory.gigaamConfiguration(languageCode: languageCode, artifactFingerprintOverride: artifactFingerprintOverride,
                                                               diarizationEnabled: diarizationEnabled)
            },
            modelsExistOnDisk: { PichiGigaAMModelStore.shared.modelsExistOnDisk() },
            liveAdmission: LiveAdmission(minimumPhysicalMemoryBytes: 4 * 1_073_741_824, maximumTrackCount: 2)
        ),
        PichiMeetingProviderFactory.whisperTinyModelID: Registration(
            descriptor: MeetingBackendDescriptor(
                id: .whisperTiny,
                version: "1",
                execution: .local,
                supportedLanguageCodes: Set(VoiceEngineLanguageCatalog.whisperLanguages.map(\.id)).union(["auto"]),
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.utterance],
                resultContract: .canonicalEvidence,
                knownLimits: [
                    "Whisper Tiny multilingual uses the registered GGUF artifact, not an English-only or legacy GGML checkpoint.",
                    "Automatic language detection occurs per bounded recognition window; mixed-language accuracy requires device testing.",
                    "This adapter emits utterance text without invented word timings.",
                    "Automatic speaker separation is independent of Whisper and requires an installed Nemotron model.",
                ],
                analysisSampleRate: 16_000
            ),
            defaultLanguageCode: "auto",
            providerFactory: { try WhisperProvider(meetingConfiguration: $0) },
            configurationSnapshot: { languageCode, fingerprint, diarizationEnabled in
                let model = SettingsStore.SpeechModel.whisperTiny
                let directory = AppBrand.cachesDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
                return MeetingFinalProcessingConfiguration(
                    asrModel: model.rawValue,
                    asrArtifactFingerprint: fingerprint ?? (try? WhisperProvider.installedArtifactFingerprint(for: model, directory: directory)),
                    asrArtifactDirectory: directory,
                    languageCode: languageCode,
                    diarizationFingerprint: PichiMeetingProviderFactory.availableDiarizationFingerprint(enabled: diarizationEnabled),
                    speakerLabelsEnabled: diarizationEnabled
                )
            },
            modelsExistOnDisk: { SettingsStore.SpeechModel.whisperTiny.isInstalled },
            liveAdmission: LiveAdmission(minimumPhysicalMemoryBytes: 2 * 1_073_741_824, maximumTrackCount: 2)
        ),
        PichiMeetingProviderFactory.parakeetV3ModelID: Registration(
            descriptor: MeetingBackendDescriptor(
                id: .parakeetV3,
                version: "1",
                execution: .local,
                supportedLanguageCodes: VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.union(["auto"]),
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.word, .utterance],
                resultContract: .canonicalEvidence,
                knownLimits: [
                    "Parakeet TDT 0.6B v3 detects its 25 supported languages automatically, including Russian and English.",
                    "This is buffered recognition, not the English-only Parakeet realtime engine.",
                    "Automatic speaker separation requires an installed Nemotron model.",
                    "CPU-only mobile runtime throughput and mixed-language quality require sustained device measurements.",
                ],
                analysisSampleRate: 16_000
            ),
            defaultLanguageCode: "auto",
            providerFactory: { try FluidAudioProvider(meetingConfiguration: $0) },
            configurationSnapshot: { languageCode, fingerprint, diarizationEnabled in
                let descriptor = ParakeetSpeechModelCatalog.v3
                let directory = descriptor.cacheDirectory(in: AppBrand.modelsDirectory)
                let installed = descriptor.artifactsAreComplete(at: directory)
                return MeetingFinalProcessingConfiguration(
                    asrModel: PichiMeetingProviderFactory.parakeetV3ModelID,
                    asrArtifactFingerprint: fingerprint ?? (installed ? (try? descriptor.installedArtifactFingerprint(at: directory)) : nil),
                    asrArtifactDirectory: installed ? directory : nil,
                    languageCode: languageCode,
                    diarizationFingerprint: PichiMeetingProviderFactory.availableDiarizationFingerprint(enabled: diarizationEnabled),
                    speakerLabelsEnabled: diarizationEnabled
                )
            },
            modelsExistOnDisk: { SettingsStore.SpeechModel.parakeetTDT.isInstalled },
            liveAdmission: LiveAdmission(minimumPhysicalMemoryBytes: 4 * 1_073_741_824, maximumTrackCount: 2)
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

    nonisolated static func registeredLiveAdmission(for modelID: String) -> LiveAdmission? {
        self.registrations[modelID]?.liveAdmission
    }

    nonisolated static func isTranscriptOnlyDiarizationFingerprint(_ value: String?) -> Bool {
        value?.hasPrefix("unavailable:") == true
    }

    static func validateRecordingConfiguration(
        _ configuration: MeetingFinalProcessingConfiguration,
        isAppleSilicon: Bool
    ) throws {
        let options = try MeetingProviderOptions.resolve(configuration)
        guard isAppleSilicon || !options.model.requiresAppleSilicon else {
            throw MeetingProviderOptionsError.unsupportedArchitecture
        }
    }

    static func registerBackends(in registry: MeetingTranscriptionBackendRegistry) {
        for (modelID, registration) in self.registrations {
            registry.register(registration.descriptor.id, descriptor: registration.descriptor) { context in
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

    static func selectedBackendID(languageCode: String, selectedModelID: String? = nil) -> MeetingBackendID {
        let modelID = selectedModelID ?? SettingsStore.shared.selectedSpeechModel.rawValue
        if let registration = self.registrations[modelID] {
            return registration.descriptor.id
        }
        let saved = SettingsStore.shared.meetingTranscriptionBackendID
        return saved == .legacyCompatibility && languageCode != "en" ? .productionDefault : saved
    }

    /// The returned value is frozen once per attempt and used by planning, ASR and metadata.
    static func configuration(
        backendID: MeetingBackendID,
        languageCode: String,
        artifactFingerprintOverride: String? = nil,
        diarizationEnabled: Bool = true
    ) -> MeetingFinalProcessingConfiguration {
        if let registration = self.registrations.values.first(where: { $0.descriptor.id == backendID }) {
            return registration.configurationSnapshot(languageCode, artifactFingerprintOverride, diarizationEnabled)
        }
        return MeetingFinalProcessingConfiguration(languageCode: languageCode,
                                                  diarizationFingerprint: PichiMeetingProviderFactory.availableDiarizationFingerprint(enabled: diarizationEnabled),
                    speakerLabelsEnabled: diarizationEnabled)
    }

    static func configuration(
        asrModel: String,
        languageCode: String,
        artifactFingerprintOverride: String? = nil,
        diarizationEnabled: Bool = true
    ) -> MeetingFinalProcessingConfiguration {
        if let registration = self.registrations[asrModel] {
            return registration.configurationSnapshot(languageCode, artifactFingerprintOverride, diarizationEnabled)
        }
        return MeetingFinalProcessingConfiguration(asrModel: asrModel, languageCode: languageCode,
                                                  diarizationFingerprint: PichiMeetingProviderFactory.availableDiarizationFingerprint(enabled: diarizationEnabled),
                    speakerLabelsEnabled: diarizationEnabled)
    }

    private static func gigaamConfiguration(
        languageCode: String,
        artifactFingerprintOverride: String?,
        diarizationEnabled: Bool
    ) -> MeetingFinalProcessingConfiguration {
        let installed = try? PichiGigaAMModelStore.shared.installedModel()
        let artifactFingerprint = installed.flatMap {
            try? PichiGigaAMModelStore(directory: $0.directory).installedModelFingerprint()
        }
        let diarizationFingerprint = PichiMeetingProviderFactory.availableDiarizationFingerprint(enabled: diarizationEnabled)
        return MeetingFinalProcessingConfiguration(
            asrModel: self.gigaamModelID,
            asrArtifactFingerprint: artifactFingerprintOverride ?? artifactFingerprint,
            asrArtifactDirectory: installed?.directory,
            languageCode: languageCode,
            diarizationFingerprint: diarizationFingerprint,
            speakerLabelsEnabled: diarizationEnabled
        )
    }

    private static func availableDiarizationFingerprint(enabled: Bool) -> String {
        guard enabled else { return self.transcriptOnlyDiarizationFingerprint }
        #if arch(arm64)
        return (try? MeetingNemotronModelLocator().locate()) == nil
            ? self.transcriptOnlyDiarizationFingerprint
            : MeetingProcessingCheckpoint.currentDiarizationFingerprint
        #else
        return self.transcriptOnlyDiarizationFingerprint
        #endif
    }
}

// Existing downstream source references retain their stable identity; registration owns the ID.
extension MeetingBackendID {
    nonisolated static let gigaam = MeetingBackendID(rawValue: "local-gigaam-v3-eou-v1")
    nonisolated static let whisperTiny = MeetingBackendID(rawValue: "local-whisper-tiny-multilingual-v1")
    nonisolated static let parakeetV3 = MeetingBackendID(rawValue: "local-parakeet-tdt-v3-v1")
}
