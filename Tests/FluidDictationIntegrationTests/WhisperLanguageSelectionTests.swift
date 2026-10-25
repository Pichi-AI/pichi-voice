@testable import FluidVoice_Debug
import XCTest
import Foundation

final class WhisperLanguageSelectionTests: XCTestCase {
    @MainActor
    func testFreshPackagedOnboardingDefaultIsRussianAndPrimaryGridRemainsBounded() {
        let packaged = AppBrand.packagedPackage.style?.defaultOnboardingLanguageID
        XCTAssertEqual(packaged, "ru")
        let all = VoiceEngineLanguageCatalog.whisperLanguages
        let popular = VoiceEngineLanguageCatalog.primaryLanguages(in: all, configuredLanguageID: nil, packagedLanguageID: packaged)
        XCTAssertEqual(popular.first?.id, "ru")
        XCTAssertLessThanOrEqual(popular.count, 11)
        XCTAssertEqual(Set(popular.map(\.id)).count, popular.count)
        XCTAssertTrue(all.contains { $0.id == "zh" }, "Overflow languages remain available in the full catalog")
        XCTAssertFalse(popular.contains { $0.id == "zh" }, "Promoting the default retains the original four-row capacity")
        XCTAssertEqual(VoiceEngineLanguageCatalog.defaultOnboardingLanguage(availableModels: [.gigaam])?.id, "ru")
        XCTAssertNil(VoiceEngineLanguageCatalog.defaultOnboardingLanguage(availableModels: []))
        let available = VoiceEngineLanguageCatalog.allLanguages(availableModels: [.gigaam, .whisperSmall])
        let primary = VoiceEngineLanguageCatalog.popularLanguages(availableModels: [.gigaam, .whisperSmall])
        XCTAssertEqual(Set(available.filter(\.isPopular).map(\.id)), Set(primary.map(\.id)))
        XCTAssertTrue(available.contains { $0.id == "zh" })
    }

    @MainActor
    func testUnavailableConfiguredLanguageFallsBackToPackagedAvailableChoice() {
        let russian = VoiceEngineLanguage(id: "ru", displayName: "Russian", aliases: [], isPopular: true)
        let english = VoiceEngineLanguage(id: "en", displayName: "English", aliases: [], isPopular: true)
        let french = VoiceEngineLanguage(id: "fr", displayName: "French", aliases: [], isPopular: true)
        XCTAssertEqual(VoiceEngineLanguageCatalog.resolveDefaultLanguage(in: [english, russian], configuredLanguageID: "zz", packagedLanguageID: "ru")?.id, "ru")
        XCTAssertEqual(VoiceEngineLanguageCatalog.resolveDefaultLanguage(in: [english, french], configuredLanguageID: "fr-CA", packagedLanguageID: "ru")?.id, "fr")
        XCTAssertEqual(VoiceEngineLanguageCatalog.resolveDefaultLanguage(in: [english], configuredLanguageID: "ru", packagedLanguageID: "ru")?.id, "en")
        XCTAssertNil(VoiceEngineLanguageCatalog.resolveDefaultLanguage(in: [], configuredLanguageID: "ru", packagedLanguageID: "ru"))
    }

    @MainActor
    func testFreshSpeechDefaultUsesPackagedRouteAndAvailableEngineCapabilities() {
        XCTAssertEqual(SettingsStore.SpeechModel.defaultModel, .gigaam)
        XCTAssertEqual(VoiceEngineLanguageCatalog.packagedDefaultSpeechModel(
            availableModels: [.gigaam, .whisperSmall, .parakeetTDTv2], packagedLanguageID: "ru"), .gigaam)
        XCTAssertEqual(VoiceEngineLanguageCatalog.packagedDefaultSpeechModel(
            availableModels: [.gigaam, .whisperSmall, .parakeetTDTv2], packagedLanguageID: "en"), .parakeetTDTv2)
        XCTAssertEqual(VoiceEngineLanguageCatalog.packagedDefaultSpeechModel(
            availableModels: [.whisperSmall], packagedLanguageID: "ru"), .whisperSmall)
        XCTAssertNil(VoiceEngineLanguageCatalog.packagedDefaultSpeechModel(availableModels: [], packagedLanguageID: "ru"))
    }

    @MainActor
    func testFreshSpeechDefaultDoesNotReplaceLegacySelections() {
        for isAppleSilicon in [true, false] {
            let legacyAutomatic: SettingsStore.SpeechModel = isAppleSilicon ? .parakeetTDT : .whisperBase
            XCTAssertEqual(SettingsStore.migratedSpeechModel(legacyProvider: nil, legacyWhisperSize: nil,
                isAppleSilicon: isAppleSilicon, freshDefault: .gigaam), .gigaam)
            for provider in ["auto", "fluidAudio"] {
                XCTAssertEqual(SettingsStore.migratedSpeechModel(legacyProvider: provider, legacyWhisperSize: nil,
                    isAppleSilicon: isAppleSilicon, freshDefault: .gigaam), legacyAutomatic)
            }
            XCTAssertEqual(SettingsStore.migratedSpeechModel(legacyProvider: "whisper", legacyWhisperSize: "ggml-small.bin",
                isAppleSilicon: isAppleSilicon, freshDefault: .gigaam), .whisperSmall)
            XCTAssertEqual(SettingsStore.migratedSpeechModel(legacyProvider: "whisper", legacyWhisperSize: "ggml-large-v3.bin",
                isAppleSilicon: isAppleSilicon, freshDefault: .gigaam), isAppleSilicon ? .whisperLarge : .whisperBase)
            XCTAssertEqual(SettingsStore.migratedSpeechModel(legacyProvider: nil, legacyWhisperSize: "ggml-base.bin",
                isAppleSilicon: isAppleSilicon, freshDefault: .gigaam), legacyAutomatic)
        }
    }

    @MainActor
    func testOnboardingBootstrapReplayAndCompletionPreserveExplicitLanguageChoice() throws {
        let suite = "OnboardingLanguagePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SettingsStore.onboardingLanguagePreference(in: defaults, defaultLanguageID: "ru"), "ru")
        SettingsStore.bootstrapOnboardingState(in: defaults, isTrueFirstOpen: true, hasLegacyUsageSignals: false, defaultLanguageID: "ru")
        XCTAssertEqual(SettingsStore.onboardingLanguagePreference(in: defaults, defaultLanguageID: "en"), "ru")
        defaults.set("de", forKey: "OnboardingSelectedLanguageID")
        SettingsStore.resetOnboardingProgress(in: defaults)
        XCTAssertEqual(SettingsStore.onboardingLanguagePreference(in: defaults, defaultLanguageID: "ru"), "de")
        defaults.removeObject(forKey: "OnboardingCompleted")
        SettingsStore.bootstrapOnboardingState(in: defaults, isTrueFirstOpen: false, hasLegacyUsageSignals: true, defaultLanguageID: "ru")
        XCTAssertEqual(SettingsStore.onboardingLanguagePreference(in: defaults, defaultLanguageID: "ru"), "de")
        defaults.set(true, forKey: "OnboardingCompleted")
        XCTAssertEqual(SettingsStore.onboardingLanguagePreference(in: defaults, defaultLanguageID: "ru"), "de")
    }

    @MainActor
    func testLanguageNamesAndSearchUseSelectedLocaleWithoutTranslatingIDs() throws {
        let locale = Locale(identifier: "ru")
        let russian = try XCTUnwrap(VoiceEngineLanguageCatalog.language(id: "ru", availableModels: [.gigaam, .parakeetTDT]))
        let german = try XCTUnwrap(VoiceEngineLanguageCatalog.language(id: "de", availableModels: [.parakeetTDT]))
        XCTAssertEqual(russian.localizedDisplayName(locale: locale), "Русский")
        XCTAssertEqual(german.localizedDisplayName(locale: locale), "Немецкий")
        XCTAssertEqual(german.id, "de")
        XCTAssertEqual(german.displayName, "German")
        XCTAssertTrue(VoiceEngineLanguageCatalog.searchableLanguages(query: "немец", availableModels: [.parakeetTDT], locale: locale).contains { $0.id == "de" })
        XCTAssertTrue(VoiceEngineLanguageCatalog.searchableLanguages(query: "German", availableModels: [.parakeetTDT], locale: locale).contains { $0.id == "de" })
    }

    @MainActor
    func testCurrentLanguageReflectsEngineBindingsInsteadOfTheOnboardingPreference() {
        let unrelated: [VoiceEngineLanguageRoute.LanguageBinding] = [.whisper(languageCode: "de"), .cohere(.english)]
        XCTAssertEqual(VoiceEngineLanguageCatalog.currentLanguage(for: .gigaam, matchingBindings: unrelated)?.id, "ru")
        XCTAssertEqual(VoiceEngineLanguageCatalog.currentLanguage(for: .parakeetTDTv2, matchingBindings: unrelated)?.id, "en")
        XCTAssertNil(VoiceEngineLanguageCatalog.currentLanguage(for: .parakeetTDT, matchingBindings: unrelated))
        for model in SettingsStore.SpeechModel.allCases.filter(\.isWhisperModel) {
            XCTAssertNil(VoiceEngineLanguageCatalog.currentLanguage(for: model, matchingBindings: []))
            XCTAssertEqual(VoiceEngineLanguageCatalog.currentLanguage(for: model, matchingBindings: [.whisper(languageCode: "ru")])?.id, "ru")
            XCTAssertEqual(VoiceEngineLanguageCatalog.currentLanguage(for: model, matchingBindings: [.whisper(languageCode: "de")])?.id, "de")
        }
        for localeIdentifier in ["en-GB", "en-CA", "en_US"] {
            XCTAssertEqual(VoiceEngineLanguageCatalog.currentLanguage(for: .appleSpeech, matchingBindings: [.appleSpeech(localeIdentifier: localeIdentifier)])?.id, "en")
        }
        for localeIdentifier in ["nb-NO", "wuu-CN", "yue-CN"] {
            XCTAssertNotNil(VoiceEngineLanguageCatalog.currentLanguage(for: .appleSpeech, matchingBindings: [.appleSpeech(localeIdentifier: localeIdentifier)]))
        }
        XCTAssertEqual(VoiceEngineLanguageCatalog.currentLanguage(for: .cohereTranscribeSixBit, matchingBindings: unrelated)?.id, "en")
        XCTAssertNil(VoiceEngineLanguageCatalog.currentLanguage(for: .nemotronOffline, matchingBindings: [.nemotron(.auto)]))
        XCTAssertEqual(VoiceEngineLanguageCatalog.currentLanguage(for: .nemotronOffline, matchingBindings: [.nemotron(.init(rawValue: "ru"))])?.id, "ru")
    }

    @MainActor
    func testMeetingLanguagePresentationUsesInterfaceLocaleAndPreservesEngineMetadata() throws {
        let languages = VoiceEngineLanguageCatalog.allLanguages(availableModels: [.parakeetTDT])
        let metadata = languages.map { ($0.id, $0.displayName, $0.aliases) }
        let russian = Locale(identifier: "ru")
        let french = Locale(identifier: "fr")
        let russianLabels = Dictionary(uniqueKeysWithValues: languages.map { ($0.id, $0.localizedDisplayName(locale: russian)) })
        let frenchLabels = Dictionary(uniqueKeysWithValues: languages.map { ($0.id, $0.localizedDisplayName(locale: french)) })

        XCTAssertEqual(russianLabels["bg"], "Болгарский")
        XCTAssertEqual(russianLabels["ru"], "Русский")
        XCTAssertEqual(russianLabels["uk"], "Украинский")
        XCTAssertEqual(frenchLabels["ru"], "Russe")
        XCTAssertEqual(frenchLabels["uk"], "Ukrainien")
        XCTAssertEqual(Set(russianLabels.keys), Set(frenchLabels.keys))
        for (language, original) in zip(languages, metadata) {
            XCTAssertEqual(language.id, original.0)
            XCTAssertEqual(language.displayName, original.1)
            XCTAssertEqual(language.aliases, original.2)
        }

        let selected = try XCTUnwrap(languages.first { $0.id == "ru" })
        XCTAssertEqual(VoiceEngineLanguageCatalog.routes(for: selected, availableModels: [.gigaam]).first?.binding, .automatic)
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: selected.id), "ru")
    }

    func testHungarianLanguageCodeIsAvailable() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "hu"), "hu")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "hu")?.displayName, "Hungarian")
    }

    func testHebrewUsesWhisperLanguageCode() {
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguageCode(for: "he"), "he")
        XCTAssertEqual(VoiceEngineLanguageCatalog.whisperLanguage(forCode: "he")?.displayName, "Hebrew")
    }

    func testWhisperRunOptionsUseSelectedLanguage() {
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "hu").language, "hu")
    }

    func testWhisperRunOptionsAllowAutomaticDetection() {
        XCTAssertNil(WhisperProvider.runOptions(languageCode: nil).language)
        XCTAssertNil(WhisperProvider.runOptions(languageCode: "auto").language)
        XCTAssertTrue(WhisperProvider.runOptions(languageCode: "auto", timestamps: .word).timestamps == .word)
    }

    @MainActor
    func testPinnedAutomaticWhisperMeetingDoesNotReadDictationLanguage() throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedWhisperLanguageCode
        defer { settings.selectedWhisperLanguageCode = previous }
        settings.selectedWhisperLanguageCode = "de"
        let provider = try WhisperProvider(meetingConfiguration: MeetingFinalProcessingConfiguration(
            asrModel: SettingsStore.SpeechModel.whisperTiny.rawValue, languageCode: "auto"
        ))
        XCTAssertNil(provider.resolvedLanguageCode())
        settings.selectedWhisperLanguageCode = "ru"
        XCTAssertNil(provider.resolvedLanguageCode())
        XCTAssertEqual(provider.resolvedLanguageCode(explicit: "en"), "en")
        XCTAssertNil(provider.resolvedLanguageCode(explicit: "auto"))
        XCTAssertEqual(provider.modelOverride, .whisperTiny)
    }

    func testWhisperRunOptionsKeepLanguageFallbackAndTimestamps() {
        let options = WhisperProvider.runOptions(languageCode: nil, whisperLanguageCode: "hu")
        XCTAssertEqual(options.language, "hu")
        XCTAssertEqual(options.timestamps, .segment)
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "en", whisperLanguageCode: "hu").language, "en")
    }

    func testQwenDetectsLanguageWithoutInheritingWhisperSelection() {
        let options = WhisperProvider.runOptions(languageCode: nil, model: .qwen3Asr17B, whisperLanguageCode: "he")
        XCTAssertNil(options.language)
        XCTAssertEqual(options.timestamps, .none)
    }

    func testQwenHonorsExplicitLanguageWithoutRequestingTimestamps() {
        let options = WhisperProvider.runOptions(languageCode: "en", model: .qwen3Asr17B, whisperLanguageCode: "hu")
        XCTAssertEqual(options.language, "en")
        XCTAssertEqual(options.timestamps, .none)
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "auto", timestamps: .word,
            model: .qwen3Asr17B, whisperLanguageCode: "ru").timestamps, .none)
        XCTAssertNil(WhisperProvider.runOptions(languageCode: "auto", model: .qwen3Asr17B,
            whisperLanguageCode: "ru").language)
    }

    @MainActor
    func testQwenProviderLanguageResolutionDoesNotReadWhisperPreference() {
        let settings = SettingsStore.shared
        let previous = settings.selectedWhisperLanguageCode
        defer { settings.selectedWhisperLanguageCode = previous }
        settings.selectedWhisperLanguageCode = "ru"
        let provider = WhisperProvider(modelOverride: .qwen3Asr17B)
        XCTAssertNil(provider.resolvedLanguageCode())
        XCTAssertEqual(provider.resolvedLanguageCode(explicit: "en"), "en")
        XCTAssertNil(provider.resolvedLanguageCode(explicit: "auto"))
        // An active native call supplies its captured model, independently of UI selection.
        XCTAssertNil(provider.resolvedLanguageCode(model: .qwen3Asr17B))
        XCTAssertEqual(provider.resolvedLanguageCode(model: .whisperTiny), "ru")
    }

    func testQwenUsesItsOwnGGUFAndDoesNotExposeWhisperControls() {
        let model = SettingsStore.SpeechModel.qwen3Asr17B
        XCTAssertEqual(model.whisperModelFile, "Qwen3-ASR-1.7B-Q8_0.gguf")
        XCTAssertNil(model.legacyWhisperModelFile)
        XCTAssertEqual(model.provider, .qwen)
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertFalse(model.supportsStreaming)
        XCTAssertTrue(model.hasPerformanceRatings)
        XCTAssertEqual(SettingsStore.SpeechModel.availableModels.contains(model), CPUArchitecture.isAppleSilicon)
        XCTAssertFalse(SettingsStore.SpeechModel.availableModels.contains(.qwen3Asr))
    }

    func testQwenTranscribesFixtureFromExistingModelAndPreservesWhisperCache() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["FLUIDVOICE_QWEN_MODEL_PATH"] else {
            throw XCTSkip("Set FLUIDVOICE_QWEN_MODEL_PATH to an existing Qwen GGUF for the local inference check.")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelFile = try XCTUnwrap(SettingsStore.SpeechModel.qwen3Asr17B.whisperModelFile)
        try FileManager.default.linkItem(at: URL(fileURLWithPath: modelPath), to: directory.appendingPathComponent(modelFile))
        let legacyFile = directory.appendingPathComponent("ggml-tiny.bin")
        try Data("unrelated Whisper cache".utf8).write(to: legacyFile)
        let provider = WhisperProvider(modelDirectory: directory, modelOverride: .qwen3Asr17B)
        guard provider.modelsExistOnDisk() else {
            return XCTFail("This check must reuse the existing model without downloading.")
        }

        do {
            try await provider.prepare()
            let samples = try AudioFixtureLoader.load16kMonoFloatSamples(named: "dictation_fixture", ext: "wav")
            let result = try await provider.transcribe(samples)

            XCTAssertTrue(result.text.lowercased().contains("hello"), "Unexpected fixture transcription: \(result.text)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: modelPath))
            print("Qwen fixture transcription: \(result.text)")
        } catch {
            await provider.releaseResidency()
            throw error
        }
        await provider.releaseResidency()
    }

    func testStoredWhisperLanguageSelectionResolution() {
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: nil))
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: "auto"))
        XCTAssertEqual(SettingsStore.whisperLanguageCode(fromStoredValue: "hu"), "hu")
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromStoredValue: "unsupported"))
    }

    func testAutomaticWhisperLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.whisperLanguageBackupValue(for: nil)

        XCTAssertEqual(backupValue, "auto")
        XCTAssertNil(SettingsStore.whisperLanguageCode(fromBackupValue: backupValue))
    }

    func testForcedWhisperLanguageRoundTripsThroughBackupValue() {
        let backupValue = SettingsStore.whisperLanguageBackupValue(for: "hu")

        XCTAssertEqual(backupValue, "hu")
        XCTAssertEqual(SettingsStore.whisperLanguageCode(fromBackupValue: backupValue), "hu")
    }

    func testWhisperLanguageCodesAreUnique() {
        let languageCodes = VoiceEngineLanguageCatalog.whisperLanguages.compactMap {
            VoiceEngineLanguageCatalog.whisperLanguageCode(for: $0.id)
        }
        XCTAssertEqual(languageCodes.count, Set(languageCodes).count)
    }
}
