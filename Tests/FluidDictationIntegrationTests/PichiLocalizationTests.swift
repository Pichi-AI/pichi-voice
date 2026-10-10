@testable import FluidVoice_Debug
import Foundation
import XCTest

final class PichiLocalizationTests: XCTestCase {
    func testMissingAndUnknownPreferencesDefaultToRussianIndependentlyOfSpeechLanguage() throws {
        let suite = "PichiLocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["en"], forKey: "AppleLanguages")
        defaults.set("de", forKey: "WhisperLanguage")
        XCTAssertEqual(PichiInterfaceLanguage.stored(in: defaults), .russian)
        defaults.set("unsupported", forKey: PichiInterfaceLanguage.defaultsKey)
        XCTAssertEqual(PichiInterfaceLanguage.stored(in: defaults), .russian)
    }

    func testChoicePersistsWithoutChangingSpeechOrSummaryPreferences() throws {
        let suite = "PichiLocalizationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("ru", forKey: "WhisperLanguage")
        defaults.set("ru", forKey: "MeetingSummaryLanguage")
        PichiInterfaceLanguage.english.persist(in: defaults)
        XCTAssertEqual(PichiInterfaceLanguage.stored(in: defaults), .english)
        XCTAssertEqual(defaults.string(forKey: "WhisperLanguage"), "ru")
        XCTAssertEqual(defaults.string(forKey: "MeetingSummaryLanguage"), "ru")
        PichiInterfaceLanguage.russian.persist(in: defaults)
        XCTAssertEqual(PichiInterfaceLanguage.stored(in: defaults), .russian)
    }

    func testExplicitRussianLookupAndEnglishFallbackLeaveUnknownUserDataAlone() throws {
        try self.withLocalizedBundle { bundle in
            XCTAssertEqual(PichiLocalization.text("Settings", language: .russian, bundle: bundle), "Настройки")
            XCTAssertEqual(PichiLocalization.text("Settings", language: .english, bundle: bundle), "Settings")
            let privateTranscript = "settings [not a UI key] https://example.invalid/model-id"
            XCTAssertEqual(PichiLocalization.text(privateTranscript, language: .russian, bundle: bundle), privateTranscript)
        }
    }

    func testAdditionalCatalogLanguagesAndRegionalFallbackNeedNoSourceCases() throws {
        try self.withLocalizedBundle { bundle in
            let french = try XCTUnwrap(PichiInterfaceLanguage(rawValue: "fr"))
            let regionalFrench = try XCTUnwrap(PichiInterfaceLanguage(rawValue: "fr-CA"))
            XCTAssertTrue(PichiInterfaceLanguage.availableLanguages(in: bundle).contains(french))
            XCTAssertFalse(PichiInterfaceLanguage.availableLanguages(in: bundle).contains { $0.rawValue == "base" })
            XCTAssertEqual(PichiLocalization.text("Settings", language: regionalFrench, bundle: bundle), "Paramètres")
            let suite = "PichiLocalizationTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            regionalFrench.persist(in: defaults)
            XCTAssertEqual(PichiInterfaceLanguage.stored(in: defaults, bundle: bundle), french)
            PichiInterfaceLanguage(rawValue: "de")!.persist(in: defaults)
            XCTAssertEqual(PichiInterfaceLanguage.stored(in: defaults, bundle: bundle), .russian)
        }
    }

    func testLocalizationHappensBeforeBrandSubstitutionAndNeverTranslatesCustomNames() throws {
        try self.withLocalizedBundle { bundle in
            let profile = BrandProfile(
                appName: "Settings", meetingName: "FluidVoice", assistantName: "My AI",
                tagline: "Settings", accentLight: "#123456", accentDark: "#654321",
                website: "https://example.invalid", support: "https://example.invalid/support"
            )
            XCTAssertEqual(AppBrand.text("Welcome to FluidVoice", profile: profile, language: .russian, bundle: bundle), "Добро пожаловать в Settings")
            XCTAssertEqual(AppBrand.substitutingProductNames(in: "FluidMeet / FluidVoice", profile: profile), "FluidVoice / Settings")
            XCTAssertEqual(AppBrand.substitutingProductNames(in: "FLUIDVOICE / Fluid Voice / FLUID INTELLIGENCE", profile: profile), "SETTINGS / Settings / MY AI")
        }
    }

    func testFormattedKeysPreserveArgumentsAndLiteralPercent() throws {
        try self.withLocalizedBundle { bundle in
            XCTAssertEqual(
                PichiLocalization.format("Progress: %lld%% for %@", language: .russian, bundle: bundle, arguments: [42, "GigaAM"]),
                "Готово: 42% для GigaAM"
            )
            XCTAssertEqual(
                PichiLocalization.format("Progress: %lld%% for %@", language: .english, bundle: bundle, arguments: [42, "GigaAM"]),
                "Progress: 42% for GigaAM"
            )
        }
    }

    func testSemanticKeysRetainEnglishFallbackAndSeparateTranslationContexts() throws {
        try self.withLocalizedBundle { bundle in
            XCTAssertEqual(PichiLocalization.text("action.edit", language: .russian, bundle: bundle, defaultValue: "Edit"), "Изменить")
            XCTAssertEqual(PichiLocalization.text("Edit", language: .russian, bundle: bundle), "Редактирование")
            XCTAssertEqual(PichiLocalization.text("action.edit", language: .english, bundle: bundle, defaultValue: "Edit"), "Edit")
            let french = try XCTUnwrap(PichiInterfaceLanguage(rawValue: "fr"))
            XCTAssertEqual(PichiLocalization.text("action.edit", language: french, bundle: bundle, defaultValue: "Edit"), "Edit")
            XCTAssertEqual(PichiLocalization.text("future.context", language: .russian, bundle: bundle, defaultValue: "Future copy"), "Future copy")
        }
    }

    func testDirectionComesFromAppleLanguageMetadataForAnyCatalogLanguage() throws {
        for identifier in ["en", "ru", "fr-CA", "ja", "zh-Hant"] {
            XCTAssertFalse(try XCTUnwrap(PichiInterfaceLanguage(rawValue: identifier)).usesRightToLeftLayout)
        }
        for identifier in ["ar", "ar-SA", "he", "fa-IR", "ur"] {
            XCTAssertTrue(try XCTUnwrap(PichiInterfaceLanguage(rawValue: identifier)).usesRightToLeftLayout)
        }
        XCTAssertEqual(PichiInterfaceLanguage.russian.displayName, "Русский")
        XCTAssertEqual(PichiInterfaceLanguage.english.displayName, "English")
    }

    func testCompiledAppleCatalogChoosesRussianAndEnglishPluralForms() {
        let russian = [0: "0 слов", 1: "1 слово", 2: "2 слова", 5: "5 слов", 11: "11 слов",
                       21: "21 слово", 22: "22 слова", 25: "25 слов", 101: "101 слово", 111: "111 слов"]
        for (count, expected) in russian {
            XCTAssertEqual(PichiLocalization.format("%lld words", language: .russian, bundle: .main, arguments: [count]), expected)
        }
        XCTAssertEqual(PichiLocalization.format("%lld words", language: .english, bundle: .main, arguments: [1]), "1 word")
        XCTAssertEqual(PichiLocalization.format("%lld words", language: .english, bundle: .main, arguments: [2]), "2 words")
        XCTAssertEqual(PichiLocalization.format("%lld entries", language: .russian, bundle: .main, arguments: [22]), "22 записи")
        XCTAssertEqual(PichiLocalization.format("%lld percent", language: .russian, bundle: .main, arguments: [21]), "21 процент")
    }

    func testCompiledSettingsCopyLocalizesDescriptionsAndSelectedOptionsWithoutChangingStoredIDs() {
        let activationLabels: [HotkeyActivationMode: String] = [
            .toggle: "Переключение", .hold: "Удержание", .automatic: "Автоматически (оба режима)",
        ]
        XCTAssertEqual(HotkeyActivationMode.allCases.map(\.rawValue), ["toggle", "hold", "automatic"])
        for mode in HotkeyActivationMode.allCases {
            XCTAssertEqual(PichiLocalization.text(mode.displayName, language: .russian, bundle: .main), activationLabels[mode])
            XCTAssertNotEqual(PichiLocalization.text(mode.description, language: .russian, bundle: .main), mode.description)
            XCTAssertEqual(PichiLocalization.text(mode.displayName, language: .english, bundle: .main), mode.displayName)
        }

        XCTAssertEqual(SettingsStore.TextInsertionMode.allCases.map(\.rawValue), ["reliablePaste", "standard"])
        XCTAssertEqual(PichiLocalization.text(SettingsStore.TextInsertionMode.reliablePaste.displayName, language: .russian, bundle: .main), "Через буфер обмена (рекомендуется)")
        XCTAssertEqual(PichiLocalization.text(SettingsStore.TextInsertionMode.standard.displayName, language: .russian, bundle: .main), "Прямая вставка")
        for mode in SettingsStore.TextInsertionMode.allCases {
            XCTAssertNotEqual(PichiLocalization.text(mode.description, language: .russian, bundle: .main), mode.description)
            XCTAssertEqual(PichiLocalization.text(mode.description, language: .english, bundle: .main), mode.description)
        }
        XCTAssertEqual(SettingsStore.AutomaticDictionarySuggestionFrequency.allCases.map(\.rawValue), [1, 2, 3])
        XCTAssertEqual(SettingsStore.AutomaticDictionarySuggestionFrequency.allCases.map {
            PichiLocalization.text($0.displayName, language: .russian, bundle: .main)
        }, ["1 исправления", "2 исправлений", "3 исправлений"])

        let descriptions = [
            "Automatically copy transcribed text to clipboard as a backup.",
            "Save transcriptions for stats tracking. Disable for privacy.",
            "Store actual microphone audio locally with dictation history. Disabled by default.",
            "Skip Saturday and Sunday when calculating usage streaks. Perfect for weekday-only users.",
            "Avoid transcription when a recording up to four seconds contains only clear silence. Disabled by default to preserve quiet speech.",
            "Say a phrase at the end of dictation to send with your chosen Enter command.",
            "Share anonymous daily feature, insertion performance, onboarding, and model metrics. Never includes transcription text or prompts.",
            "Telemetry is disabled in this distribution.",
        ]
        for description in descriptions {
            XCTAssertNotEqual(PichiLocalization.text(description, language: .russian, bundle: .main), description)
            XCTAssertEqual(PichiLocalization.text(description, language: .english, bundle: .main), description)
        }
        let privacyCopy = PichiLocalization.text("For privacy questions, contact our support team.", language: .russian, bundle: .main)
        XCTAssertEqual(privacyCopy, "По вопросам конфиденциальности обратитесь в службу поддержки.")
        XCTAssertNotNil(privacyCopy.range(of: PichiLocalization.text("support team", language: .russian, bundle: .main)))
    }

    func testMeetingHealthWarningsUseCompiledCatalogWithoutChangingPersistedDiagnostics() throws {
        let warnings = [
            "No meeting audio is being captured while your microphone is active.": "Звук встречи не записывается, хотя микрофон активен.",
            "Capture delivered an invalid audio sample.": "Получен некорректный аудиосэмпл.",
            "Capture delivered audio without a valid presentation timestamp.": "Получено аудио без корректной временной метки.",
            "Capture delivered audio from a retired producer epoch.": "Получено аудио от уже заменённого источника захвата.",
            "Capture audio could not be normalized onto the meeting timeline.": "Не удалось синхронизировать аудио со шкалой времени встречи.",
            "Audio chunk timing was not monotonic.": "Временные метки аудиофрагмента нарушают порядок записи.",
        ]
        let french = try XCTUnwrap(PichiInterfaceLanguage(rawValue: "fr"))
        for (detail, translated) in warnings {
            var health = MeetingTrackHealth.waiting
            health.status = .degraded
            health.detail = detail
            let stored = try JSONEncoder().encode(health)
            XCTAssertEqual(health.localizedStatusText(language: .russian), translated)
            XCTAssertEqual(health.localizedStatusText(language: .english), detail)
            XCTAssertEqual(health.localizedStatusText(language: french), detail)
            XCTAssertEqual(try JSONDecoder().decode(MeetingTrackHealth.self, from: stored), health)
            XCTAssertEqual(health.detail, detail)
        }
    }

    func testMeetingHealthPresentationPreservesUnknownDeviceAndWriterDetailsVerbatim() {
        for detail in ["Settings", "Microphone Pichi %ld [ru] https://example.invalid/stream", "Audio writer queue dropped 7 samples while saturated."] {
            var health = MeetingTrackHealth.waiting
            health.status = .unavailable
            health.detail = detail
            XCTAssertEqual(health.localizedStatusText(language: .russian), detail)
            XCTAssertEqual(health.localizedStatusText(language: .english), detail)
        }
        var health = MeetingTrackHealth.waiting
        health.status = .degraded
        XCTAssertEqual(health.localizedStatusText(language: .russian), "Проблема с источником звука")
    }

    @MainActor
    func testPromptIconUsesSelectionIdentityInsteadOfTranslatedOrCustomLabel() {
        XCTAssertEqual(DictationPromptSelectorPresentation.iconName(for: .off, isAppOverrideActive: false), "bolt.fill")
        XCTAssertEqual(DictationPromptSelectorPresentation.iconName(for: .privateAI, isAppOverrideActive: false), "sparkles")
        XCTAssertNil(DictationPromptSelectorPresentation.iconName(for: .privateAI, isAppOverrideActive: true))
        XCTAssertNil(DictationPromptSelectorPresentation.iconName(for: .default, isAppOverrideActive: false))
        // A user's profile named Basic or its Russian translation is not the built-in off selection.
        XCTAssertNil(DictationPromptSelectorPresentation.iconName(for: .profile("Basic"), isAppOverrideActive: false))
        XCTAssertNil(DictationPromptSelectorPresentation.iconName(for: .profile("Базовый"), isAppOverrideActive: false))
    }

    func testPartiallyTranslatedInstalledLanguageFallsBackThroughNativeEnglishPluralResources() throws {
        try self.withLocalizedBundle { bundle in
            let french = try XCTUnwrap(PichiInterfaceLanguage(rawValue: "fr"))
            XCTAssertTrue(PichiInterfaceLanguage.availableLanguages(in: bundle).contains(french))
            XCTAssertEqual(PichiLocalization.text("Settings", language: french, bundle: bundle), "Paramètres")
            for (count, expected) in [0: "0 words", 1: "1 word", 2: "2 words"] {
                XCTAssertEqual(PichiLocalization.format("%lld words", language: french, bundle: bundle, arguments: [count]), expected)
            }
        }
    }

    func testSummaryCopyUsesOutputCatalogLanguageWhilePreservingAllUserAndModelData() throws {
        try self.withLocalizedBundle { bundle in
            let french = try XCTUnwrap(PichiInterfaceLanguage(rawValue: "fr"))
            let evidence = PichiMeetingSummaryEvidence(segmentID: UUID(), quote: "Settings [Answered] Москва")
            let item = PichiMeetingSummaryItem(text: "User task Settings", evidence: [evidence], owner: "Recap",
                                              deadline: "к пятнице", superseded: true)
            let question = PichiMeetingSummaryItem(text: "User question Settings", evidence: [evidence], resolved: true)
            let document = PichiMeetingSummaryDocument(summary: [.init(text: "User recap Settings", evidence: [evidence])],
                                                       decisions: [], actions: [item], openQuestions: [question])
            let frenchText = document.copyText(language: french, bundle: bundle)
            XCTAssertTrue(frenchText.hasPrefix("Récapitulatif\n- User recap Settings\n  > Settings [Answered] Москва"))
            XCTAssertTrue(frenchText.contains("Actions\n- [Remplacé] User task Settings (Recap) [к пятнице]"))
            XCTAssertTrue(frenchText.contains("Questions et réponses\n- [Répondu] User question Settings"))
            XCTAssertTrue(frenchText.contains("Décisions\n"))
            XCTAssertTrue(frenchText.contains("Actions\n"))
            XCTAssertTrue(frenchText.contains("Questions et réponses\n"))
            let englishText = document.copyText(language: .english, bundle: bundle)
            XCTAssertTrue(englishText.hasPrefix("Recap\n- User recap Settings"))
            XCTAssertTrue(englishText.contains("Action items\n- [Superseded] User task Settings (Recap) [к пятнице]"))
            XCTAssertEqual(item.owner, "Recap")
            XCTAssertEqual(item.evidence[0].quote, "Settings [Answered] Москва")
        }
    }

    private func withLocalizedBundle(_ body: (Bundle) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PichiLocalization-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let translations = directory.appendingPathComponent("ru.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: translations, withIntermediateDirectories: true)
        let french = directory.appendingPathComponent("fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: french, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Base.lproj"), withIntermediateDirectories: true)
        let frenchStrings = try PropertyListSerialization.data(fromPropertyList: [
            "Settings": "Paramètres", "Recap": "Récapitulatif", "Decisions": "Décisions", "Action items": "Actions",
            "Questions and answers": "Questions et réponses", "[Superseded] ": "[Remplacé] ", "[Answered] ": "[Répondu] ",
        ], format: .xml, options: 0)
        try frenchStrings.write(to: french.appendingPathComponent("Localizable.strings"))
        let english = directory.appendingPathComponent("en.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: english, withIntermediateDirectories: true)
        let plural: [String: Any] = ["%lld words": [
            "NSStringLocalizedFormatKey": "%#@words@",
            "words": ["NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
                      "one": "%lld word", "other": "%lld words"],
        ]]
        let dictionary = try PropertyListSerialization.data(fromPropertyList: plural, format: .xml, options: 0)
        try dictionary.write(to: english.appendingPathComponent("Localizable.stringsdict"))
        let properties = ["CFBundleIdentifier": "ai.pichi.localization.fixture", "CFBundleDevelopmentRegion": "en"]
        let info = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
        try info.write(to: directory.appendingPathComponent("Info.plist"))
        let strings = [
            "Settings": "Настройки",
            "Edit": "Редактирование",
            "action.edit": "Изменить",
            "Welcome to FluidVoice": "Добро пожаловать в FluidVoice",
            "Progress: %lld%% for %@": "Готово: %lld%% для %@",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
        try data.write(to: translations.appendingPathComponent("Localizable.strings"))
        try body(XCTUnwrap(Bundle(path: directory.path)))
    }
}
