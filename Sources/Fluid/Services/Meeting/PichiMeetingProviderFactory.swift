import Foundation
import PichiGigaAM

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
        let providerFactory: @MainActor @Sendable (MeetingFinalProcessingConfiguration) throws -> any TranscriptionProvider
        let configurationSnapshot: @MainActor @Sendable (String, String?, Bool, MeetingSpeakerProcessingMode) -> MeetingFinalProcessingConfiguration
        let speakerProcessingProfiles: [MeetingSpeakerProcessingMode: MeetingNemotronModelProfile]
        let modelsExistOnDisk: @MainActor @Sendable () -> Bool
        let liveAdmission: LiveAdmission
        /// Cheap catalog/file-presence metadata only, never model hashing or preparation.
        let admissionArtifactFingerprint: @MainActor @Sendable () -> String?
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
                    "GigaAM supports Russian. For English or mixed speech, select a multilingual model.",
                    "Speaker labels are automatic and can be uncertain in short or overlapping speech.",
                    "Download the speaker models in Recording settings before an offline meeting.",
                ],
                analysisSampleRate: 16_000,
                diarizationDependencies: [.speakerSeparation, .voiceMatching],
                allowsTranscriptOnlyOnUnsupportedHardware: true,
                supportedInputs: [.recordedChunks, .boundedMicrophonePCM],
                supportedSpeakerProcessingModes: [.afterRecording, .streaming]
            ),
            defaultLanguageCode: "ru",
            providerFactory: { configuration in
                let store = configuration.asrArtifactDirectory.map { PichiGigaAMModelStore(directory: $0) } ?? .shared
                return PichiGigaAMProvider(modelStore: store, expectedModelFingerprint: configuration.asrArtifactFingerprint)
            },
            configurationSnapshot: { languageCode, artifactFingerprintOverride, diarizationEnabled, processingMode in
                PichiMeetingProviderFactory.gigaamConfiguration(languageCode: languageCode, artifactFingerprintOverride: artifactFingerprintOverride,
                                                               diarizationEnabled: diarizationEnabled, speakerProcessingMode: processingMode)
            },
            speakerProcessingProfiles: [.afterRecording: .fast32SplitW8A8, .streaming: .experimentalFast128FP16CPU],
            modelsExistOnDisk: { PichiGigaAMModelStore.shared.modelsExistOnDisk() },
            // Sustained buffered captions passed on a nominal 4 GB iPad reporting
            // 4,166,696,960 physical bytes. Express this registration in decimal GB.
            liveAdmission: LiveAdmission(minimumPhysicalMemoryBytes: 4_000_000_000, maximumTrackCount: 2),
            admissionArtifactFingerprint: {
                // A fresh install prepares the public export. Complete imports retain priority.
                (try? PichiGigaAMModelStore.shared.installedModelFingerprint()) ?? GigaAMModelCatalog.downloadableModel.fingerprint
            }
        ),
        PichiMeetingProviderFactory.whisperTinyModelID: Registration(
            descriptor: MeetingBackendDescriptor(
                id: .whisperTiny,
                version: "2",
                execution: .local,
                supportedLanguageCodes: VoiceEngineLanguageCatalog.whisperSupportedLanguageCodes.union(["auto"]),
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.word, .utterance],
                resultContract: .canonicalEvidence,
                knownLimits: [
                    "Whisper Tiny is small and fast, with lower recognition accuracy.",
                    "Mixed Russian and English speech may contain errors or transliteration.",
                    "When different people speak in one transcript phrase, speaker labels may remain unknown.",
                    "Download the speaker models in Recording settings before an offline meeting.",
                ],
                analysisSampleRate: 16_000,
                diarizationDependencies: [.speakerSeparation, .voiceMatching],
                allowsTranscriptOnlyOnUnsupportedHardware: true,
                supportedInputs: [.recordedChunks, .boundedMicrophonePCM],
                pcmObservationPolicy: .init(initialSeconds: 3, intervalSeconds: 3)
            ),
            defaultLanguageCode: "auto",
            providerFactory: { try WhisperProvider(meetingConfiguration: $0) },
            configurationSnapshot: { languageCode, fingerprint, diarizationEnabled, processingMode in
                let model = SettingsStore.SpeechModel.whisperTiny
                let directory = AppBrand.cachesDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
                return MeetingFinalProcessingConfiguration(
                    asrModel: model.rawValue,
                    asrArtifactFingerprint: fingerprint ?? (try? WhisperProvider.installedArtifactFingerprint(for: model, directory: directory)),
                    asrArtifactDirectory: directory,
                    languageCode: languageCode,
                    diarizationFingerprint: PichiMeetingProviderFactory.availableDiarizationFingerprint(enabled: diarizationEnabled),
                    speakerLabelsEnabled: diarizationEnabled, speakerProcessingMode: processingMode
                )
            },
            speakerProcessingProfiles: [.afterRecording: .fast32SplitW8A8],
            modelsExistOnDisk: { SettingsStore.SpeechModel.whisperTiny.isInstalled },
            liveAdmission: LiveAdmission(minimumPhysicalMemoryBytes: 2 * 1_073_741_824, maximumTrackCount: 2),
            admissionArtifactFingerprint: { nil }
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
                    "Parakeet v3 supports 25 languages, including Russian and English.",
                    "Live text updates in fragments. Speaker labels can be uncertain in short or overlapping speech.",
                    "Download the speaker models in Recording settings before an offline meeting.",
                    "Battery use and recognition speed depend on the device. Test longer meetings on your iPad.",
                ],
                analysisSampleRate: 16_000,
                diarizationDependencies: [.speakerSeparation, .voiceMatching],
                allowsTranscriptOnlyOnUnsupportedHardware: true,
                supportedInputs: [.recordedChunks, .boundedMicrophonePCM]
            ),
            defaultLanguageCode: "auto",
            providerFactory: { try FluidAudioProvider(meetingConfiguration: $0) },
            configurationSnapshot: { languageCode, fingerprint, diarizationEnabled, processingMode in
                let descriptor = ParakeetSpeechModelCatalog.v3
                let directory = descriptor.cacheDirectory(in: AppBrand.modelsDirectory)
                let installed = descriptor.artifactsAreComplete(at: directory)
                return MeetingFinalProcessingConfiguration(
                    asrModel: PichiMeetingProviderFactory.parakeetV3ModelID,
                    asrArtifactFingerprint: fingerprint ?? (installed ? (try? descriptor.installedArtifactFingerprint(at: directory)) : nil),
                    asrArtifactDirectory: installed ? directory : nil,
                    languageCode: languageCode,
                    diarizationFingerprint: PichiMeetingProviderFactory.availableDiarizationFingerprint(enabled: diarizationEnabled),
                    speakerLabelsEnabled: diarizationEnabled, speakerProcessingMode: processingMode
                )
            },
            speakerProcessingProfiles: [.afterRecording: .fast32SplitW8A8],
            modelsExistOnDisk: { SettingsStore.SpeechModel.parakeetTDT.isInstalled },
            liveAdmission: LiveAdmission(minimumPhysicalMemoryBytes: 4 * 1_073_741_824, maximumTrackCount: 2),
            admissionArtifactFingerprint: { nil }
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

    static func registeredModelsExistOnDisk(for modelID: String) -> Bool? {
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
        isAppleSilicon: Bool,
        requiresInstalledArtifact: Bool = false,
        captureMode: MeetingCaptureMode = .inRoom
    ) throws {
        if let descriptor = self.registrations[configuration.asrModel]?.descriptor {
            try descriptor.validateSpeakerProcessingMode(configuration: configuration, mode: captureMode)
        } else if configuration.effectiveSpeakerProcessingMode == .streaming {
            throw MeetingBackendError.unsupportedSpeakerProcessingMode(backend: .productionDefault, mode: .streaming)
        }
        if configuration.effectiveSpeakerProcessingMode == .streaming { _ = try self.modelLocator(for: configuration) }
        let options = try MeetingProviderOptions.resolve(configuration)
        guard isAppleSilicon || !options.model.requiresAppleSilicon else {
            throw MeetingProviderOptionsError.unsupportedArchitecture
        }
        if requiresInstalledArtifact,
           configuration.asrArtifactFingerprint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            throw MeetingProcessingError.modelUnavailable
        }
    }

    /// Concrete model selection remains below the generic attempt and capture owners.
    /// Unknown streaming identities are refused instead of choosing the offline graph.
    static func modelLocator(for configuration: MeetingFinalProcessingConfiguration) throws -> MeetingNemotronModelLocator {
        let matched = MeetingNemotronModelProfile.matching(implementationFingerprint: configuration.diarizationFingerprint)
        if configuration.effectiveSpeakerProcessingMode == .streaming {
            guard let registration = self.registrations[configuration.asrModel],
                  let expected = registration.speakerProcessingProfiles[.streaming], matched == expected,
                  configuration.diarizationFingerprint == expected.streamingImplementationFingerprint else {
                throw MeetingBackendError.unsupportedSpeakerProcessingMode(
                    backend: self.registrations[configuration.asrModel]?.descriptor.id ?? .productionDefault, mode: .streaming)
            }
        }
        return MeetingNemotronModelLocator(profile: matched ?? .fast32SplitW8A8)
    }

    static func speakerModelStore(for modelID: String,
                                  speakerProcessingMode: MeetingSpeakerProcessingMode) -> MeetingDiarizationModelStore? {
        let profile = self.registrations[modelID]?.speakerProcessingProfiles[speakerProcessingMode]
            ?? (speakerProcessingMode == .afterRecording ? .fast32SplitW8A8 : nil)
        return profile.map { MeetingDiarizationModelStore.shared(for: $0) }
    }

    static func prepareSpeakerResources(for configuration: MeetingFinalProcessingConfiguration) async throws {
        guard configuration.speakerLabelsEnabled else { return }
        let locator = try self.modelLocator(for: configuration)
        // Streaming capture needs only the continuous speaker graph. Enrollment and the
        // explicit Settings download own optional voice-encoder installation; losing that
        // optional resource must not block capture or trigger a network wait before the mic.
        // The frozen runtime validates it locally and verifies the owner after model cleanup.
        let dependencies: Set<MeetingDiarizationDependency> = configuration.effectiveSpeakerProcessingMode == .streaming
            ? [.speakerSeparation] : (locator.supportsOwnerVoiceVerification
                ? [.speakerSeparation, .voiceMatching] : [.speakerSeparation])
        try await MeetingDiarizationModelStore.shared(for: locator.profile).prepare(dependencies: dependencies)
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

    static func selectedBackendID(languageCode: String, selectedModelID: String? = nil,
                                  savedBackendID: MeetingBackendID? = nil) -> MeetingBackendID {
        let modelID = selectedModelID ?? SettingsStore.shared.selectedSpeechModel.rawValue
        if let registration = self.registrations[modelID] { return registration.descriptor.id }
        let saved = savedBackendID ?? SettingsStore.shared.meetingTranscriptionBackendID
        return saved == .legacyCompatibility && languageCode != "en" ? .productionDefault : saved
    }

    /// A registered provider's frozen configuration binds ASR and artifact identity. The
    /// generic configuration of an unbound compatibility executor does not bind its ASR model.
    nonisolated static func liveModelID(backendID: MeetingBackendID, configuration: MeetingFinalProcessingConfiguration,
                                       selectedModelID: String) -> String {
        guard self.registrations[configuration.asrModel]?.descriptor.id == backendID else { return selectedModelID }
        return configuration.asrModel
    }

    /// Capability/option admission uses registered metadata only. Installed artifact identity
    /// belongs to the later frozen attempt snapshot. A restricted registration may supply cheap
    /// expected export metadata here; weight verification remains with provider preparation.
    static func validationConfiguration(backendID: MeetingBackendID, languageCode: String,
                                        diarizationEnabled: Bool,
                                        artifactFingerprintOverride: String? = nil,
                                        speakerProcessingMode: MeetingSpeakerProcessingMode = .afterRecording) -> MeetingFinalProcessingConfiguration {
        if let (modelID, registration) = self.registrations.first(where: { $0.value.descriptor.id == backendID }) {
            let diarizationFingerprint = diarizationEnabled && speakerProcessingMode == .streaming
                ? registration.speakerProcessingProfiles[.streaming]?.streamingImplementationFingerprint ?? "unavailable:unsupported-mode"
                : "unavailable:input-admission"
            return MeetingFinalProcessingConfiguration(asrModel: modelID,
                asrArtifactFingerprint: artifactFingerprintOverride ?? registration.admissionArtifactFingerprint(), languageCode: languageCode,
                diarizationFingerprint: diarizationFingerprint, speakerLabelsEnabled: diarizationEnabled,
                speakerProcessingMode: speakerProcessingMode)
        }
        return MeetingFinalProcessingConfiguration(languageCode: languageCode,
            diarizationFingerprint: "unavailable:input-admission", speakerLabelsEnabled: diarizationEnabled,
                speakerProcessingMode: speakerProcessingMode)
    }

    /// The returned value is frozen once per attempt and used by planning, ASR and metadata.
    static func configuration(
        backendID: MeetingBackendID,
        languageCode: String,
        artifactFingerprintOverride: String? = nil,
        diarizationEnabled: Bool = true,
        speakerProcessingMode: MeetingSpeakerProcessingMode = .afterRecording
    ) -> MeetingFinalProcessingConfiguration {
        if let registration = self.registrations.values.first(where: { $0.descriptor.id == backendID }) {
            return registration.configurationSnapshot(languageCode, artifactFingerprintOverride, diarizationEnabled, speakerProcessingMode)
        }
        return MeetingFinalProcessingConfiguration(languageCode: languageCode,
                                                  diarizationFingerprint: diarizationEnabled ? MeetingProcessingCheckpoint.currentDiarizationFingerprint : self.transcriptOnlyDiarizationFingerprint,
                                                  speakerLabelsEnabled: diarizationEnabled, speakerProcessingMode: speakerProcessingMode)
    }

    static func configuration(
        asrModel: String,
        languageCode: String,
        artifactFingerprintOverride: String? = nil,
        diarizationEnabled: Bool = true,
        speakerProcessingMode: MeetingSpeakerProcessingMode = .afterRecording
    ) -> MeetingFinalProcessingConfiguration {
        if let registration = self.registrations[asrModel] {
            return registration.configurationSnapshot(languageCode, artifactFingerprintOverride, diarizationEnabled, speakerProcessingMode)
        }
        return MeetingFinalProcessingConfiguration(asrModel: asrModel, languageCode: languageCode,
                                                  diarizationFingerprint: diarizationEnabled ? MeetingProcessingCheckpoint.currentDiarizationFingerprint : self.transcriptOnlyDiarizationFingerprint,
                                                  speakerLabelsEnabled: diarizationEnabled, speakerProcessingMode: speakerProcessingMode)
    }

    private static func gigaamConfiguration(
        languageCode: String,
        artifactFingerprintOverride: String?,
        diarizationEnabled: Bool,
        speakerProcessingMode: MeetingSpeakerProcessingMode
    ) -> MeetingFinalProcessingConfiguration {
        let installed = try? PichiGigaAMModelStore.shared.installedModel()
        let artifactFingerprint = installed.flatMap {
            try? PichiGigaAMModelStore(directory: $0.directory).installedModelFingerprint()
        }
        let profile = self.registrations[self.gigaamModelID]?.speakerProcessingProfiles[speakerProcessingMode]
        let diarizationFingerprint = PichiMeetingProviderFactory.availableDiarizationFingerprint(
            enabled: diarizationEnabled, profile: profile ?? .fast32SplitW8A8, speakerProcessingMode: speakerProcessingMode)
        return MeetingFinalProcessingConfiguration(
            asrModel: self.gigaamModelID,
            asrArtifactFingerprint: artifactFingerprintOverride ?? artifactFingerprint,
            asrArtifactDirectory: installed?.directory,
            languageCode: languageCode,
            diarizationFingerprint: diarizationFingerprint,
            speakerLabelsEnabled: diarizationEnabled, speakerProcessingMode: speakerProcessingMode
        )
    }

    private static func availableDiarizationFingerprint(
        enabled: Bool, profile: MeetingNemotronModelProfile = .fast32SplitW8A8,
        speakerProcessingMode: MeetingSpeakerProcessingMode = .afterRecording
    ) -> String {
        guard enabled else { return self.transcriptOnlyDiarizationFingerprint }
        // Streaming requires preparation of this exact profile before capture. A missing
        // candidate must not silently turn the requested processing mode into transcript-only.
        if speakerProcessingMode == .streaming { return profile.streamingImplementationFingerprint }
        #if arch(arm64)
        guard let artifact = try? MeetingNemotronModelLocator(profile: profile).locate(),
              (try? MeetingSpeakerVoiceModelArtifacts.validate()) != nil else { return self.transcriptOnlyDiarizationFingerprint }
        return artifact.implementationFingerprint + ";voice=wespeaker@" + MeetingSpeakerVoiceModelArtifacts.revision
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
