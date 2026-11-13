import AppKit
import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
import XCTest

final class MeetingProviderOptionsTests: XCTestCase {
    func testMeetingDictionaryRewritingStaysOutsideASR() throws {
        let options = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(
            customDictionaryRewritingEnabled: true,
            customDictionaryEntries: [.init(triggers: ["space fest"], replacement: "Spacefast")]
        ))
        XCTAssertFalse(options.customDictionaryRewritingEnabled, "final-turn rewriting must not alter ASR word timings")
        XCTAssertFalse(options.vocabularyBoostingEnabled)
        XCTAssertFalse(options.pronunciationMatchingEnabled)
    }

    @MainActor
    func testEveryOfferedMeetingModelUsesTheSharedLiveContractWithoutSubstitution() throws {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        for model in PichiMeetingProviderFactory.retranscriptionModels {
            let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: model.rawValue), model.rawValue)
            let language = try XCTUnwrap(PichiMeetingProviderFactory.defaultLanguageCode(for: model.rawValue))
            XCTAssertEqual(registry.descriptor(for: descriptor.id), descriptor)
            XCTAssertTrue(descriptor.supportedInputs.isSuperset(of: [.boundedMicrophonePCM, .boundedMultiTrackPCM]))
            XCTAssertTrue(descriptor.supportedSpeakerProcessingModes.contains(.streaming))
            XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: language,
                selectedModelID: model.rawValue, savedBackendID: .legacyCompatibility), descriptor.id)
            let configuration = PichiMeetingProviderFactory.configuration(asrModel: model.rawValue,
                languageCode: language, artifactFingerprintOverride: "synthetic-pinned-export", speakerProcessingMode: .streaming)
            XCTAssertEqual(configuration.asrModel, model.rawValue)
            XCTAssertEqual(configuration.asrArtifactFingerprint, "synthetic-pinned-export")
            XCTAssertEqual(try MeetingProviderOptions.resolve(configuration).model, model)
            XCTAssertEqual(try PichiMeetingProviderFactory.modelLocator(for: configuration).profile, .experimentalFast128FP16CPU)
            for mode in MeetingCaptureMode.allCases {
                XCTAssertNoThrow(try descriptor.validatePCMInput(configuration: configuration, mode: mode))
                XCTAssertNoThrow(try PichiMeetingProviderFactory.validateRecordingConfiguration(configuration,
                    isAppleSilicon: true, captureMode: mode))
            }
        }
        let incompatible = PichiMeetingProviderFactory.validationConfiguration(backendID: .parakeetV2,
            languageCode: "ru", preferredASRModel: .parakeetTDTv2, diarizationEnabled: true,
            speakerProcessingMode: .streaming)
        XCTAssertEqual(incompatible.asrModel, SettingsStore.SpeechModel.parakeetTDTv2.rawValue)
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(incompatible)) {
            XCTAssertEqual($0 as? MeetingProviderOptionsError, .unsupportedLanguageCode("ru"))
        }
    }

    func testDefaultMeetingConfigurationResolvesToPinnedProEnglishPolicy() throws {
        let options = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration())
        XCTAssertEqual(options.model, .fluidParakeetPro)
        XCTAssertFalse(options.vocabularyBoostingEnabled)
        XCTAssertFalse(options.pronunciationMatchingEnabled)
        XCTAssertFalse(options.customDictionaryRewritingEnabled)
        XCTAssertFalse(options.experimentalUnifiedFinalEnabled)
    }

    func testRetranscriptionLanguagePreservesNormalizedIdentifiersIndependentlyOfModelSupport() {
        XCTAssertEqual(MeetingRetranscriptionLanguage.canonicalCode(" de "), "de")
        XCTAssertEqual(MeetingRetranscriptionLanguage.canonicalCode("en"), "en")
        XCTAssertEqual(MeetingRetranscriptionLanguage.canonicalCode("ru"), "ru")
        XCTAssertEqual(MeetingRetranscriptionLanguage.canonicalCode("zh"), "zh")
        XCTAssertEqual(MeetingRetranscriptionLanguage.canonicalCode(" DE "), "de")
        XCTAssertEqual(MeetingRetranscriptionLanguage.canonicalCode("auto"), "auto")
        XCTAssertEqual(MeetingRetranscriptionLanguage.canonicalCode("pt-BR"), "pt-br")
        XCTAssertNil(MeetingRetranscriptionLanguage.canonicalCode("en_US"))
        XCTAssertNil(MeetingRetranscriptionLanguage.canonicalCode("invalid language"))
        XCTAssertNil(MeetingRetranscriptionLanguage.canonicalCode(" "))
        XCTAssertEqual(MeetingRetranscriptionLanguage.displayName(for: "de"), "German")
        XCTAssertFalse(MeetingRetranscriptionLanguage.canRetranscribe(selection: "en", currentLanguageCode: "en"))
        XCTAssertTrue(MeetingRetranscriptionLanguage.canRetranscribe(selection: "en", currentLanguageCode: "en", allowsSameLanguage: true))
        XCTAssertFalse(MeetingRetranscriptionLanguage.canRetranscribe(selection: "invalid", currentLanguageCode: "en", allowsSameLanguage: true))
        XCTAssertTrue(MeetingRetranscriptionLanguage.canRetranscribe(selection: "nl", currentLanguageCode: "en"))
        XCTAssertEqual(
            MeetingFinalProcessingConfiguration(languageCode: "de").asrModel,
            "fluid-parakeet-pro"
        )
    }

    func testRetranscriptionChoicesKeepRegisteredProviderCapabilityAdmission() throws {
        let choices = MeetingRetranscriptionLanguage.choices
        XCTAssertTrue(choices.contains { $0.id == "zh" })
        XCTAssertFalse(choices.contains { $0.id == "zz" })
        XCTAssertTrue(PichiMeetingProviderFactory.registeredLanguageCodes(for: "whisper-tiny")?.contains("zh") == true)
        XCTAssertFalse(PichiMeetingProviderFactory.registeredLanguageCodes(for: "gigaam-v3-eou")?.contains("zh") == true)
        XCTAssertEqual(try MeetingProviderOptions.resolve(
            MeetingFinalProcessingConfiguration(asrModel: "whisper-tiny", languageCode: "zh")).model, .whisperTiny)
        let availableModels = Set(SettingsStore.SpeechModel.availableModels)
        let meetingModels = PichiMeetingProviderFactory.retranscriptionModels.filter { availableModels.contains($0) }
        for choice in choices {
            XCTAssertTrue(meetingModels.contains { model in
                (try? MeetingProviderOptions.resolve(
                    MeetingFinalProcessingConfiguration(asrModel: model.rawValue, languageCode: choice.id))) != nil
            }, "Every offered language requires an available meeting provider: \(choice.id)")
        }
        for model in ["gigaam-v3-eou", "parakeet-tdt-v2", "parakeet-tdt", "fluid-parakeet-pro"] {
            XCTAssertThrowsError(try MeetingProviderOptions.resolve(
                MeetingFinalProcessingConfiguration(asrModel: model, languageCode: "zh"))) { error in
                XCTAssertEqual(error as? MeetingProviderOptionsError, .unsupportedLanguageCode("zh"))
            }
        }
    }

    func testExplicitLanguageCapabilitiesPreserveCatalogPresentationWithoutExpandingOnboardingRoutes() throws {
        let choices = VoiceEngineLanguageCatalog.allLanguages(supportedLanguageCodes: ["zh", "ru", "zz", "auto"])
        XCTAssertEqual(choices.map(\.id), ["ru", "zh"])
        XCTAssertTrue(VoiceEngineLanguageCatalog.allLanguages(supportedLanguageCodes: []).isEmpty)
        for choice in choices {
            let catalogLanguage = try XCTUnwrap(VoiceEngineLanguageCatalog.whisperLanguage(forCode: choice.id))
            XCTAssertEqual(choice.displayName, catalogLanguage.displayName)
            XCTAssertEqual(choice.aliases, catalogLanguage.aliases)
            XCTAssertEqual(choice.localizedDisplayName(locale: Locale(identifier: "ru")),
                           catalogLanguage.localizedDisplayName(locale: Locale(identifier: "ru")))
        }
        XCTAssertTrue(VoiceEngineLanguageCatalog.allLanguages(availableModels: [.whisperTiny]).isEmpty,
                      "Meeting capabilities do not add Tiny to preferred onboarding routes")
        XCTAssertEqual(VoiceEngineLanguageCatalog.routes(forLanguageID: "zh", availableModels: [.whisperSmall, .whisperLargeTurbo]).map(\.model),
                       [.whisperSmall, .whisperLargeTurbo])
    }

    func testP1DefaultASRModelMatchesSpeechModelRawValue() {
        XCTAssertEqual(
            MeetingFinalProcessingConfiguration.defaultASRModel,
            SettingsStore.SpeechModel.fluidParakeetPro.rawValue
        )
    }

    func testPreferredMeetingModelRespectsLanguageAndSupportedModels() throws {
        let cases: [(SettingsStore.SpeechModel, String, SettingsStore.SpeechModel)] = [
            (.fluidParakeetPro, "en", .fluidParakeetPro),
            (.fluidParakeetPro, "de", .fluidParakeetPro),
            (.parakeetTDT, "en", .parakeetTDT),
            (.parakeetTDT, "nl", .parakeetTDT),
            (.parakeetTDTv2, "en", .parakeetTDTv2),
            (.parakeetTDTv2, "fr", .fluidParakeetPro),
            (.whisperTiny, "en", .fluidParakeetPro),
            (.whisperTiny, "de", .fluidParakeetPro),
            (.fluidParakeetMini, "en", .fluidParakeetPro),
        ]
        for (selected, language, expected) in cases {
            let configuration = MeetingFinalProcessingConfiguration(preferredASRModel: selected, languageCode: language)
            XCTAssertEqual(try MeetingProviderOptions.resolve(configuration).model, expected)
            XCTAssertEqual(configuration.languageCode, language)
        }
    }

    func testMeetingDefaultPrefersProThenInstalledV3() {
        let pro = SettingsStore.SpeechModel.fluidParakeetPro.rawValue
        let v3 = SettingsStore.SpeechModel.parakeetTDT.rawValue
        XCTAssertEqual(MeetingProviderOptions.defaultModel(installedModelIDs: [pro, v3]), .fluidParakeetPro)
        XCTAssertEqual(MeetingProviderOptions.defaultModel(installedModelIDs: [pro]), .fluidParakeetPro)
        XCTAssertEqual(MeetingProviderOptions.defaultModel(installedModelIDs: [v3]), .parakeetTDT)
        XCTAssertEqual(MeetingProviderOptions.defaultModel(installedModelIDs: []), .fluidParakeetPro)
        XCTAssertEqual(MeetingProviderOptions.defaultModel(installedModelIDs: ["parakeet-tdt-v2", "whisper-tiny"]), .fluidParakeetPro)
    }

    func testExplicitMeetingModelRemainsPinnedOverPreference() throws {
        let configuration = MeetingFinalProcessingConfiguration(
            asrModel: "parakeet-tdt",
            preferredASRModel: .fluidParakeetPro
        )
        XCTAssertEqual(try MeetingProviderOptions.resolve(configuration).model, .parakeetTDT)
    }

    func testProCanBeExplicitlyUsedForEveryV3MeetingLanguage() throws {
        for language in VoiceEngineLanguageCatalog.parakeetV3LanguageIDs {
            let configuration = MeetingFinalProcessingConfiguration(asrModel: "fluid-parakeet-pro", languageCode: language)
            XCTAssertEqual(try MeetingProviderOptions.resolve(configuration).model, .fluidParakeetPro)
        }
    }

    @MainActor
    func testProMeetingProviderPinsChoiceWithoutChangingDictationOrEnhancements() throws {
        let selected = SettingsStore.shared.selectedSpeechModel
        let configuration = MeetingFinalProcessingConfiguration(preferredASRModel: .fluidParakeetPro)
        let provider = try FluidAudioProvider(meetingConfiguration: configuration)
        #if arch(arm64)
        XCTAssertEqual(provider.modelOverride, .fluidParakeetPro)
        #endif
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
        XCTAssertFalse(provider.isWordBoostingActive)
        XCTAssertEqual(provider.boostedVocabularyTermsCount, 0)
        XCTAssertFalse(try MeetingProviderOptions.resolve(configuration).pronunciationMatchingEnabled)
        XCTAssertFalse(try MeetingProviderOptions.resolve(configuration).customDictionaryRewritingEnabled)
        XCTAssertNotEqual(configuration.identityFingerprint, MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt").identityFingerprint)
    }

    func testResolveRejectsUnsupportedModelsWithoutRelabeling() {
        let unsupportedModels = [
            "parakeet-tdt-v3",
            "parakeet-tdt-v99",
            "whisper-base",
            "fluid-parakeet-mini",
            "fluid-parakeet-pico",
            "cohere-transcribe-6bit",
            "",
        ]
        for asrModel in unsupportedModels {
            let configuration = MeetingFinalProcessingConfiguration(asrModel: asrModel)
            XCTAssertThrowsError(try MeetingProviderOptions.resolve(configuration)) { error in
                XCTAssertEqual(
                    error as? MeetingProviderOptionsError,
                    .unsupportedASRModel(asrModel)
                )
            }
        }
    }

    @MainActor
    func testExternalCoreMLModelCannotBypassRegisteredMeetingFactory() {
        let model = SettingsStore.SpeechModel.cohereTranscribeSixBit
        XCTAssertTrue(model.requiresIOS18)
        for registered in [SettingsStore.SpeechModel.gigaam, .whisperTiny, .parakeetTDT] {
            XCTAssertFalse(registered.requiresIOS18)
            XCTAssertNotNil(PichiMeetingProviderFactory.registeredBackendDescriptor(for: registered.rawValue))
        }
        XCTAssertNil(PichiMeetingProviderFactory.registeredBackendDescriptor(for: model.rawValue))
        XCTAssertThrowsError(try PichiMeetingProviderFactory.make(MeetingFinalProcessingConfiguration(asrModel: model.rawValue))) { error in
            XCTAssertEqual(error as? MeetingProviderOptionsError, .unsupportedASRModel(model.rawValue))
        }
    }

    func testResolveRejectsNonEnglishLanguageCodeForV2() {
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v2", languageCode: "de")
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(configuration)) { error in
            XCTAssertEqual(
                error as? MeetingProviderOptionsError,
                .unsupportedLanguageCode("de")
            )
        }
    }

    func testSupportedLanguagesResolveToPinnedModelsWithoutEnhancements() throws {
        for language in VoiceEngineLanguageCatalog.parakeetV3LanguageIDs {
            let configuration = MeetingFinalProcessingConfiguration(languageCode: language)
            let options = try MeetingProviderOptions.resolve(configuration)
            XCTAssertEqual(options.model, .fluidParakeetPro)
            XCTAssertFalse(options.vocabularyBoostingEnabled)
            XCTAssertFalse(options.pronunciationMatchingEnabled)
            XCTAssertFalse(options.customDictionaryRewritingEnabled)
            XCTAssertFalse(options.experimentalUnifiedFinalEnabled)
            let capture = MeetingCaptureConfiguration(
                mode: .inRoom,
                title: "Multilingual meeting",
                languageCode: language,
                microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")
            )
            try capture.validate()
            let session = MeetingSession(configuration: capture, timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
            try session.validateForPersistence()
            let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
            XCTAssertEqual(restored.languageCode, language)
        }
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(languageCode: "zh")))
    }

    func testV3PinsProviderAndChangesResumeFingerprint() throws {
        let configuration = MeetingFinalProcessingConfiguration(preferredASRModel: .parakeetTDT, languageCode: "de")
        let provider = try FluidAudioProvider(meetingConfiguration: configuration)
        #if arch(arm64)
        XCTAssertEqual(provider.modelOverride, .parakeetTDT)
        #endif
        XCTAssertNotEqual(configuration.identityFingerprint, MeetingFinalProcessingConfiguration().identityFingerprint)
    }

    @MainActor
    func testMultilingualRegisteredMeetingProvidersPinAutomaticLanguageAndDiarizationPolicy() throws {
        for model: SettingsStore.SpeechModel in [.whisperTiny, .parakeetTDT] {
            let configuration = PichiMeetingProviderFactory.configuration(asrModel: model.rawValue, languageCode: "auto",
                                                                         diarizationEnabled: false)
            XCTAssertEqual(try MeetingProviderOptions.resolve(configuration).model, model)
            XCTAssertEqual(PichiMeetingProviderFactory.defaultLanguageCode(for: model.rawValue), "auto")
            XCTAssertTrue(PichiMeetingProviderFactory.isTranscriptOnlyDiarizationFingerprint(configuration.diarizationFingerprint))
            let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: model.rawValue))
            XCTAssertTrue(descriptor.supportedLanguageCodes.isSuperset(of: ["ru", "en", "auto"]))
            XCTAssertNotEqual(descriptor.id, .legacyCompatibility)
            XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: "auto", selectedModelID: model.rawValue,
                savedBackendID: .productionDefault), descriptor.id)
            let provider = try PichiMeetingProviderFactory.make(configuration)
            if model.isWhisperModel {
                let whisper = try XCTUnwrap(provider as? WhisperProvider)
                XCTAssertEqual(whisper.modelOverride, .whisperTiny)
                XCTAssertNil(whisper.resolvedLanguageCode())
            } else {
                XCTAssertTrue(provider is FluidAudioProvider)
            }
        }
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(
            MeetingFinalProcessingConfiguration(asrModel: SettingsStore.SpeechModel.gigaam.rawValue, languageCode: "auto")
        ))
    }

    @MainActor
    func testOwnedModelSelectionAndSavedFallbackDoNotUseSharedSettings() {
        let shared = SettingsStore.shared
        let keys = ["SelectedSpeechModel", "MeetingTranscriptionBackendID"]
        let originals = keys.map { shared.defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, originals) {
                if let value { shared.defaults.set(value, forKey: key) }
                else { shared.defaults.removeObject(forKey: key) }
            }
        }
        shared.selectedSpeechModel = .whisperTiny
        shared.meetingTranscriptionBackendID = .whisperTiny
        let unknown = MeetingBackendID(rawValue: "synthetic-unknown-owner")
        let ownedModelID = PichiMeetingProviderFactory.gigaamModelID
        // The owner's registered speech choice is authoritative. Ambient saved values
        // are fallback preferences, not the explicit per-request capture override.
        for saved in [MeetingBackendID.productionDefault, .gigaam, .whisperTiny, .legacyCompatibility, unknown] {
            for language in ["en", "ru"] {
                XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: language,
                    selectedModelID: ownedModelID, savedBackendID: saved), .gigaam)
            }
        }
        // An unregistered model still consumes only the supplied owner's saved fallback.
        let unregisteredModelID = SettingsStore.SpeechModel.whisperSmall.rawValue
        XCTAssertNil(PichiMeetingProviderFactory.registeredBackendDescriptor(for: unregisteredModelID))
        for (saved, english, nonEnglish) in [
            (MeetingBackendID.productionDefault, MeetingBackendID.productionDefault, MeetingBackendID.productionDefault),
            (.whisperTiny, .whisperTiny, .whisperTiny),
            (.legacyCompatibility, .legacyCompatibility, .productionDefault),
            (unknown, unknown, unknown),
        ] {
            for (language, expected) in [("en", english), ("fr", nonEnglish), ("ru", nonEnglish)] {
                XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: language,
                    selectedModelID: unregisteredModelID, savedBackendID: saved), expected)
            }
        }
        XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: "ru", selectedModelID: ownedModelID), .gigaam)
        XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: "ru"), .whisperTiny)
        XCTAssertEqual(shared.selectedSpeechModel, .whisperTiny)
        XCTAssertEqual(shared.meetingTranscriptionBackendID, .whisperTiny)
    }

    @MainActor
    func testLiveModelBindsRegisteredConfigurationAndPreservesUnboundRollbackChoice() {
        let override = PichiMeetingProviderFactory.configuration(backendID: .whisperTiny, languageCode: "ru",
            artifactFingerprintOverride: "synthetic-whisper", diarizationEnabled: false)
        XCTAssertEqual(PichiMeetingProviderFactory.liveModelID(backendID: .whisperTiny, configuration: override,
            selectedModelID: PichiMeetingProviderFactory.gigaamModelID), PichiMeetingProviderFactory.whisperTinyModelID)
        XCTAssertEqual(override.asrArtifactFingerprint, "synthetic-whisper")
        let legacy = PichiMeetingProviderFactory.configuration(backendID: .legacyCompatibility,
            languageCode: "en", diarizationEnabled: false)
        XCTAssertEqual(PichiMeetingProviderFactory.liveModelID(backendID: .legacyCompatibility, configuration: legacy,
            selectedModelID: PichiMeetingProviderFactory.whisperTinyModelID), PichiMeetingProviderFactory.whisperTinyModelID)
        XCTAssertNil(legacy.asrArtifactFingerprint)
        XCTAssertEqual(PichiMeetingProviderFactory.liveModelID(backendID: .init(rawValue: "synthetic-unknown"),
            configuration: override, selectedModelID: PichiMeetingProviderFactory.gigaamModelID), PichiMeetingProviderFactory.gigaamModelID)
    }

    /// Attempt owners freeze through the detached variant. It must bind exactly the snapshot the
    /// synchronous builder produces on this machine, with and without a frozen session identity.
    @MainActor
    func testFrozenConfigurationMatchesSynchronousSnapshotForEveryRegistration() async throws {
        for backendID in [MeetingBackendID.gigaam, .whisperTiny, .parakeetV3, .legacyCompatibility] {
            for override in [nil, "sha256:synthetic-frozen-session"] as [String?] {
                for diarizationEnabled in [false, true] {
                    let frozen = try await PichiMeetingProviderFactory.frozenConfiguration(backendID: backendID, languageCode: "ru",
                        artifactFingerprintOverride: override, diarizationEnabled: diarizationEnabled)
                    let synchronous = PichiMeetingProviderFactory.configuration(backendID: backendID, languageCode: "ru",
                        artifactFingerprintOverride: override, diarizationEnabled: diarizationEnabled)
                    XCTAssertEqual(frozen, synchronous, "\(backendID.rawValue) override=\(override ?? "nil")")
                    if let override, backendID != .legacyCompatibility { XCTAssertEqual(frozen.asrArtifactFingerprint, override) }
                }
            }
        }
        for model: SettingsStore.SpeechModel in [.gigaam, .whisperTiny, .parakeetTDT] {
            let frozen = try await PichiMeetingProviderFactory.frozenConfiguration(asrModel: model.rawValue, languageCode: "auto")
            XCTAssertEqual(frozen, PichiMeetingProviderFactory.configuration(asrModel: model.rawValue, languageCode: "auto"))
        }
    }

    /// The path is resolved on the caller's actor; the digest itself can run detached.
    @MainActor
    func testWhisperFingerprintOperationMatchesInstalledIdentityOffTheMainActor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperFingerprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = SettingsStore.SpeechModel.whisperTiny
        let file = root.appendingPathComponent(try XCTUnwrap(model.whisperModelFile))
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("synthetic".utf8)))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(model.expectedDownloadBytes))
        try handle.close()

        let expected = try XCTUnwrap(try WhisperProvider.installedArtifactFingerprint(for: model, directory: root))
        let operation = WhisperProvider.installedArtifactFingerprintOperation(for: model, directory: root)
        let detached = try await Task.detached(priority: .userInitiated) { try operation() }.value
        XCTAssertEqual(detached, expected)
        try FileHandle(forWritingTo: file).truncate(atOffset: UInt64(model.expectedDownloadBytes - 1))
        XCTAssertNil(try operation(), "A partial artifact has no identity")
    }

    @MainActor
    func testGigaAMMeetingPolicyPinsRussianAndRejectsOtherLanguages() throws {
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", languageCode: "ru")
        let options = try MeetingProviderOptions.resolve(configuration)
        XCTAssertEqual(options.model.rawValue, "gigaam-v3-eou")
        XCTAssertTrue(try PichiMeetingProviderFactory.make(configuration) is PichiGigaAMProvider)
        XCTAssertThrowsError(try FluidAudioProvider(meetingConfiguration: configuration)) { error in
            XCTAssertEqual(error as? MeetingProviderOptionsError, .unsupportedASRModel("gigaam-v3-eou"))
        }
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(
            MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", languageCode: "en")
        )) { error in
            XCTAssertEqual(error as? MeetingProviderOptionsError, .unsupportedLanguageCode("en"))
        }
        XCTAssertNotEqual(configuration.identityFingerprint, MeetingFinalProcessingConfiguration(languageCode: "ru").identityFingerprint)
    }

    func testRecordingBackendPinIsBackwardCompatibleAndPersisted() throws {
        var session = MeetingSession(configuration: MeetingCaptureConfiguration(
            mode: .inRoom, title: "Russian meeting", languageCode: "ru",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")
        ), timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.recordingBackendID = MeetingBackendID.gigaam.rawValue
        let encoder = JSONEncoder()
        let restored = try JSONDecoder().decode(MeetingSession.self, from: encoder.encode(session))
        XCTAssertEqual(restored.recordingBackendID, MeetingBackendID.gigaam.rawValue)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
        object.removeValue(forKey: "recordingBackendID")
        let legacy = try JSONDecoder().decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.recordingBackendID)
    }

    func testLegacyDefaultsDecodeWithoutLanguageAndNewDefaultsPersistIt() throws {
        let encoder = JSONEncoder()
        let original = MeetingRecordingDefaults.unconfigured
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(original)) as? [String: Any])
        json.removeValue(forKey: "languageCode")
        let legacy = try JSONDecoder().decode(MeetingRecordingDefaults.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.languageCode)
        XCTAssertEqual(legacy.mode, original.mode)
        var configured = original
        configured.languageCode = "de"
        XCTAssertEqual(try JSONDecoder().decode(MeetingRecordingDefaults.self, from: encoder.encode(configured)).languageCode, "de")
    }

    func testResolveRejectsEveryEnhancementFlag() {
        let cases: [(MeetingFinalProcessingConfiguration, String)] = [
            (MeetingFinalProcessingConfiguration(vocabularyBoostingEnabled: true), "vocabularyBoosting"),
            (MeetingFinalProcessingConfiguration(pronunciationMatchingEnabled: true), "pronunciationMatching"),
            (MeetingFinalProcessingConfiguration(experimentalUnifiedFinalEnabled: true), "experimentalUnifiedFinal"),
        ]
        for (configuration, feature) in cases {
            XCTAssertThrowsError(try MeetingProviderOptions.resolve(configuration)) { error in
                XCTAssertEqual(
                    error as? MeetingProviderOptionsError,
                    .unsupportedFeature(feature)
                )
            }
        }
    }

    func testMeetingConstructorPinsModelOverrideImmutably() throws {
        let provider = try FluidAudioProvider(meetingConfiguration: MeetingFinalProcessingConfiguration())
        // The Intel stub stores no modelOverride; the pinning assertion is arm64-only.
        #if arch(arm64)
        XCTAssertEqual(provider.modelOverride, .fluidParakeetPro)
        #endif
        XCTAssertFalse(provider.isWordBoostingActive)
        XCTAssertEqual(provider.boostedVocabularyTermsCount, 0)
    }

    func testMeetingConstructorRejectsUnsupportedConfiguration() {
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v3")
        XCTAssertThrowsError(try FluidAudioProvider(meetingConfiguration: configuration)) { error in
            XCTAssertEqual(
                error as? MeetingProviderOptionsError,
                .unsupportedASRModel("parakeet-tdt-v3")
            )
        }
    }

    @MainActor
    func testOptInMeetingLanguageSettingsSnapshot() throws {
        guard let directory = ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_SETTINGS_SNAPSHOT"] else {
            throw XCTSkip("Set FLUIDVOICE_MEETING_SETTINGS_SNAPSHOT for a settings visual check")
        }
        var draft = MeetingTranscriptionSetupDraft()
        draft.languageCode = "de"
        let view = MeetingRecordingSettingsSheet(
            draft: .constant(draft),
            retentionPolicy: .constant(SettingsStore.shared.meetingAudioRetentionPolicy),
            applications: [],
            microphones: [],
            readiness: .checking,
            isFirstSetup: false,
            onRefreshSources: {},
            onOpenMicrophoneSettings: {},
            onOpenScreenRecordingSettings: {},
            onOpenVoiceEngine: {},
            onCancel: {},
            onSave: {}
        )
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let host = NSHostingView(rootView: view.appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme)).environment(\.colorScheme, scheme))
            host.frame = NSRect(x: 0, y: 0, width: 820, height: 720)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("meeting-language-\(name).png"))
        }
    }

    #if arch(arm64)
    @MainActor
    func testOptInGermanV3AudioProducesOriginalLanguageAndWordTimings() async throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_GERMAN_FIXTURE"] else {
            throw XCTSkip("Set FLUIDVOICE_MEETING_GERMAN_FIXTURE to a 16 kHz mono German WAV for model verification")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        let selected = SettingsStore.shared.selectedSpeechModel
        let provider = try FluidAudioProvider(meetingConfiguration: .init(preferredASRModel: .parakeetTDT, languageCode: "de"))
        try await provider.prepare(progressHandler: nil)
        let output = try await provider.transcribeWithWordTimings(samples)
        print("Meeting v3 German smoke: \(output.result.text); words=\(output.words.count)")
        XCTAssertTrue(output.result.text.lowercased().contains("morgen"))
        XCTAssertTrue(output.result.text.lowercased().contains("freitag"))
        XCTAssertFalse(output.words.isEmpty)
        XCTAssertTrue(output.words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= Double(samples.count) / 16_000 + 0.1 })
        XCTAssertEqual(SettingsStore.shared.selectedSpeechModel, selected)
    }
    #endif

    #if arch(arm64)
    func testLegacyConstructorsKeepDynamicModelResolution() {
        XCTAssertNil(FluidAudioProvider().modelOverride)
        XCTAssertNil(FluidAudioProvider(configureWordBoosting: false).modelOverride)
        XCTAssertEqual(
            FluidAudioProvider(modelOverride: .parakeetTDT, configureWordBoosting: false).modelOverride,
            .parakeetTDT
        )
    }
    #endif
}
