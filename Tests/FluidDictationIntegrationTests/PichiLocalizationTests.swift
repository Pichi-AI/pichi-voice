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

    private func withLocalizedBundle(_ body: (Bundle) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PichiLocalization-\(UUID().uuidString).bundle")
        defer { try? FileManager.default.removeItem(at: directory) }
        let translations = directory.appendingPathComponent("ru.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: translations, withIntermediateDirectories: true)
        let french = directory.appendingPathComponent("fr.lproj", isDirectory: true)
        try FileManager.default.createDirectory(at: french, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Base.lproj"), withIntermediateDirectories: true)
        let frenchStrings = try PropertyListSerialization.data(fromPropertyList: ["Settings": "Paramètres"], format: .xml, options: 0)
        try frenchStrings.write(to: french.appendingPathComponent("Localizable.strings"))
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
