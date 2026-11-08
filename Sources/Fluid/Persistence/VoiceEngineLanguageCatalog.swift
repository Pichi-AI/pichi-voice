import Foundation
#if canImport(Speech)
import Speech
#endif

struct VoiceEngineLanguage: Identifiable, Equatable {
    let id: String
    let displayName: String
    let aliases: [String]
    let isPopular: Bool

    var popularDisplayName: String {
        self.id == "zh" ? "Mandarin" : self.displayName
    }

    /// Only the visible language name is localized; engine/API IDs remain unchanged.
    func localizedDisplayName(locale: Locale) -> String {
        locale.localizedString(forIdentifier: self.id)?.capitalized(with: locale)
            ?? PichiLocalization.text(self.displayName, locale: locale)
    }
}

struct VoiceEngineLanguageRoute: Identifiable, Equatable {
    enum LanguageBinding: Equatable {
        case automatic
        case appleSpeech(localeIdentifier: String)
        case cohere(SettingsStore.CohereLanguage)
        case nemotron(SettingsStore.NemotronLanguage)
        case whisper(languageCode: String)

        var id: String {
            switch self {
            case .automatic:
                return "auto"
            case let .appleSpeech(localeIdentifier):
                return "apple-\(localeIdentifier)"
            case let .cohere(language):
                return "cohere-\(language.rawValue)"
            case let .nemotron(language):
                return "nemotron-\(language.rawValue)"
            case let .whisper(languageCode):
                return "whisper-\(languageCode)"
            }
        }
    }

    let language: VoiceEngineLanguage
    let model: SettingsStore.SpeechModel
    let binding: LanguageBinding

    var id: String {
        "\(self.language.id)-\(self.model.rawValue)-\(self.binding.id)"
    }

    var badgeText: String? {
        switch self.model {
        case .parakeetTDT, .parakeetTDTv2, .fluidParakeetMini, .fluidParakeetPico, .fluidParakeetPro:
            return AppBrand.text("Optimized for FluidVoice")
        default:
            return nil
        }
    }
}

struct AppleSpeechLocaleOption: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum VoiceEngineLanguageCatalog {
    static func appleSpeechLocaleOptions(
        identifiers: [String],
        displayLocale: Locale = .current
    ) -> [AppleSpeechLocaleOption] {
        let uniqueIdentifiers = Set(identifiers.map { Self.normalizedLocaleIdentifier($0) })
        return uniqueIdentifiers
            .map { AppleSpeechLocaleOption(id: $0, displayName: displayLocale.localizedString(forIdentifier: $0) ?? $0) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    static func allLanguages(
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguage] {
        self.allLanguages(supportedLanguageCodes: Set(self.availableDefinitions(availableModels: availableModels).map(\.id)))
    }

    /// Capability callers share catalog names, ordering and presentation without selecting an
    /// onboarding route. Preferred onboarding engines can differ from other compiled consumers.
    static func allLanguages(supportedLanguageCodes: Set<String>) -> [VoiceEngineLanguage] {
        let languages = self.languageDefinitions.filter { supportedLanguageCodes.contains($0.id) }
        let primaryIDs = Set(self.primaryDefinitions(from: languages).map(\.id))
        return languages.map { language in
            VoiceEngineLanguage(id: language.id, displayName: language.displayName, aliases: language.aliases,
                                isPopular: primaryIDs.contains(language.id))
        }
    }

    static func popularLanguages(
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguage] {
        self.primaryDefinitions(from: self.availableDefinitions(availableModels: availableModels)).map { language in
            VoiceEngineLanguage(id: language.id, displayName: language.displayName, aliases: language.aliases, isPopular: true)
        }
    }

    static var defaultOnboardingLanguageID: String { self.defaultOnboardingLanguage()?.id ?? "en" }

    static func defaultOnboardingLanguage(
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> VoiceEngineLanguage? {
        guard let language = self.resolvedDefaultLanguage(in: self.availableDefinitions(availableModels: availableModels)) else { return nil }
        return VoiceEngineLanguage(id: language.id, displayName: language.displayName, aliases: language.aliases, isPopular: true)
    }

    /// Fresh speech selection follows the shipped language and its existing route order.
    /// Imported appearance packages do not change the distribution's engine default.
    static func packagedDefaultSpeechModel(
        availableModels: [SettingsStore.SpeechModel], packagedLanguageID: String?
    ) -> SettingsStore.SpeechModel? {
        let languages = self.availableDefinitions(availableModels: availableModels)
        guard let language = self.resolveDefaultLanguage(in: languages, configuredLanguageID: nil,
                                                        packagedLanguageID: packagedLanguageID) else { return nil }
        return self.routes(for: language, availableModels: availableModels).first?.model
    }

    private static func availableDefinitions(availableModels: [SettingsStore.SpeechModel]) -> [VoiceEngineLanguage] {
        self.languageDefinitions.filter { !Self.routes(for: $0, availableModels: availableModels).isEmpty }
    }

    // The existing onboarding grid has eleven language cards plus Other in four rows.
    // Promote any configured available default while retaining that bounded layout.
    private static let primaryLanguageCapacity = 11

    private static func primaryDefinitions(from languages: [VoiceEngineLanguage]) -> [VoiceEngineLanguage] {
        self.primaryLanguages(in: languages,
                              configuredLanguageID: AppBrand.package.style?.defaultOnboardingLanguageID,
                              packagedLanguageID: AppBrand.packagedPackage.style?.defaultOnboardingLanguageID)
    }

    /// Pure catalog presentation policy; production supplies active/package configuration explicitly.
    static func primaryLanguages(in languages: [VoiceEngineLanguage], configuredLanguageID: String?,
                                 packagedLanguageID: String?) -> [VoiceEngineLanguage] {
        let candidates = languages.filter(\.isPopular)
        guard let primary = self.resolveDefaultLanguage(in: languages, configuredLanguageID: configuredLanguageID,
                                                       packagedLanguageID: packagedLanguageID) else {
            return Array(candidates.prefix(self.primaryLanguageCapacity))
        }
        return Array(([primary] + candidates.filter { $0.id != primary.id }).prefix(self.primaryLanguageCapacity))
    }

    private static func resolvedDefaultLanguage(in languages: [VoiceEngineLanguage]) -> VoiceEngineLanguage? {
        self.resolveDefaultLanguage(in: languages,
                                    configuredLanguageID: AppBrand.package.style?.defaultOnboardingLanguageID,
                                    packagedLanguageID: AppBrand.packagedPackage.style?.defaultOnboardingLanguageID)
    }

    /// A configured locale may be unknown to this speech catalog or unavailable on this platform.
    /// Use the packaged available choice, then the existing catalog's neutral fallback/order.
    static func resolveDefaultLanguage(in languages: [VoiceEngineLanguage], configuredLanguageID: String?,
                                       packagedLanguageID: String?) -> VoiceEngineLanguage? {
        for candidate in [configuredLanguageID, packagedLanguageID].compactMap({ $0 }) {
            guard let identifier = PichiInterfaceLanguage(rawValue: candidate)?.languageCode else { continue }
            if let language = languages.first(where: { $0.id == identifier }) { return language }
        }
        return languages.first(where: { $0.id == "en" }) ?? languages.first
    }

    static func searchableLanguages(
        query: String,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels,
        locale: Locale = PichiLocalization.locale
    ) -> [VoiceEngineLanguage] {
        let languages = Self.allLanguages(availableModels: availableModels)
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedQuery.isEmpty else { return languages }

        return languages.filter { language in
            language.localizedDisplayName(locale: locale).lowercased().contains(normalizedQuery) ||
                language.displayName.lowercased().contains(normalizedQuery) ||
                language.id.lowercased().contains(normalizedQuery) ||
                language.aliases.contains { $0.lowercased().contains(normalizedQuery) }
        }
    }

    static func language(
        id: String,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> VoiceEngineLanguage? {
        self.allLanguages(availableModels: availableModels).first { $0.id == id }
    }

    static var whisperLanguages: [VoiceEngineLanguage] {
        self.languageDefinitions.filter { self.whisperLanguageCode(for: $0.id) != nil }
    }

    static func whisperLanguage(forCode languageCode: String) -> VoiceEngineLanguage? {
        self.whisperLanguages.first { self.whisperLanguageCode(for: $0.id) == languageCode }
    }

    static func routes(
        for language: VoiceEngineLanguage,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguageRoute] {
        self.routeCandidates(for: language).filter { route in
            availableModels.contains(route.model)
        }
    }

    static func routes(
        forLanguageID languageID: String,
        availableModels: [SettingsStore.SpeechModel] = SettingsStore.SpeechModel.availableModels
    ) -> [VoiceEngineLanguageRoute] {
        guard let language = Self.language(id: languageID, availableModels: availableModels) else {
            return []
        }
        return Self.routes(for: language, availableModels: availableModels)
    }

    /// Describe the active engine, not an earlier onboarding choice. A multilingual
    /// automatic route has no forced language, whereas a single-language engine does.
    static func currentLanguage(settings: SettingsStore = .shared) -> VoiceEngineLanguage? {
        var bindings: [VoiceEngineLanguageRoute.LanguageBinding] = [
            .appleSpeech(localeIdentifier: settings.selectedAppleSpeechLocaleIdentifier),
            .cohere(settings.selectedCohereLanguage),
            .nemotron(settings.selectedNemotronLanguage),
        ]
        if let languageCode = settings.selectedWhisperLanguageCode {
            bindings.append(.whisper(languageCode: languageCode))
        }
        return self.currentLanguage(for: settings.selectedSpeechModel, matchingBindings: bindings)
    }

    static func currentLanguage(for model: SettingsStore.SpeechModel,
                                matchingBindings: [VoiceEngineLanguageRoute.LanguageBinding]) -> VoiceEngineLanguage? {
        // The onboarding shortlist intentionally omits some installed Whisper sizes.
        // Their actual language preference still uses the complete existing catalog.
        if model.isWhisperModel {
            for binding in matchingBindings {
                if case let .whisper(languageCode) = binding {
                    return self.whisperLanguage(forCode: languageCode)
                }
            }
            return nil
        }
        let routes = self.allLanguages(availableModels: [model]).flatMap {
            self.routes(for: $0, availableModels: [model])
        }
        // Native Speech supports locales outside the onboarding shortlist. An explicit
        // locale still identifies a language; it must not be shown as auto-detection.
        if model.provider == .apple {
            for binding in matchingBindings {
                if case let .appleSpeech(localeIdentifier) = binding {
                    if let route = routes.first(where: { $0.binding == binding }) { return route.language }
                    guard let identifier = PichiInterfaceLanguage(rawValue: localeIdentifier)?.languageCode else { return nil }
                    return self.languageDefinitions.first(where: { $0.id == identifier })
                        ?? VoiceEngineLanguage(id: identifier,
                            displayName: Locale(identifier: "en").localizedString(forIdentifier: identifier) ?? identifier,
                            aliases: [], isPopular: false)
                }
            }
            return nil
        }
        let selected = routes.filter { matchingBindings.contains($0.binding) }
        if selected.count == 1 { return selected.first?.language }
        let automatic = routes.filter { $0.binding == .automatic }
        return automatic.count == 1 ? automatic.first?.language : nil
    }

    static func apply(_ route: VoiceEngineLanguageRoute, to settings: SettingsStore = .shared) {
        settings.onboardingSelectedLanguageID = route.language.id
        settings.selectedSpeechModel = route.model

        switch route.binding {
        case .automatic:
            break
        case let .whisper(languageCode):
            settings.selectedWhisperLanguageCode = languageCode
        case let .appleSpeech(localeIdentifier):
            settings.selectedAppleSpeechLocaleIdentifier = localeIdentifier
        case let .cohere(language):
            settings.selectedCohereLanguage = language
        case let .nemotron(language):
            settings.selectedNemotronLanguage = language
        }
    }

    private static func routeCandidates(for language: VoiceEngineLanguage) -> [VoiceEngineLanguageRoute] {
        var routes: [VoiceEngineLanguageRoute] = []

        if language.id == "ru" {
            routes.append(Self.route(language, .gigaam, .automatic))
        }

        if language.id == "en" {
            routes.append(Self.route(language, .parakeetTDTv2, .automatic))
            routes.append(Self.route(language, .parakeetRealtime, .automatic))
        }

        if Self.parakeetV3LanguageIDs.contains(language.id) {
            routes.append(Self.route(language, .parakeetTDT, .automatic))
            routes.append(Self.route(language, .fluidParakeetMini, .automatic))
            routes.append(Self.route(language, .fluidParakeetPico, .automatic))
            routes.append(Self.route(language, .fluidParakeetPro, .automatic))
        }

        if let cohereLanguage = Self.cohereLanguage(for: language.id) {
            routes.append(Self.route(language, .cohereTranscribeSixBit, .cohere(cohereLanguage)))
        }

        if let nemotronLanguage = Self.nemotronLanguage(for: language.id) {
            routes.append(Self.route(language, .nemotronStreaming, .nemotron(nemotronLanguage)))
            routes.append(Self.route(language, .nemotronOffline, .nemotron(nemotronLanguage)))
        }

        if TranscribeSpeechModelCatalog.qwenLanguageCodes.contains(language.id) {
            routes.append(Self.route(language, .qwen3Asr06BQ4, .automatic))
        }

        if let whisperLanguageCode = Self.whisperLanguageCode(for: language.id) {
            for model in Self.whisperModelOrder {
                routes.append(Self.route(language, model, .whisper(languageCode: whisperLanguageCode)))
            }
        }

        if let appleSpeechAnalyzerLocale = Self.appleSpeechAnalyzerLocaleIdentifier(for: language.id) {
            routes.append(Self.route(language, .appleSpeechAnalyzer, .appleSpeech(localeIdentifier: appleSpeechAnalyzerLocale)))
        }

        if let appleSpeechLegacyLocale = Self.appleSpeechLegacyLocaleIdentifier(for: language.id) {
            routes.append(Self.route(language, .appleSpeech, .appleSpeech(localeIdentifier: appleSpeechLegacyLocale)))
        }

        return routes
    }

    private static func route(
        _ language: VoiceEngineLanguage,
        _ model: SettingsStore.SpeechModel,
        _ binding: VoiceEngineLanguageRoute.LanguageBinding
    ) -> VoiceEngineLanguageRoute {
        VoiceEngineLanguageRoute(language: language, model: model, binding: binding)
    }

    private static func cohereLanguage(for languageID: String) -> SettingsStore.CohereLanguage? {
        self.cohereLanguageMap[languageID]
    }

    private static func nemotronLanguage(for languageID: String) -> SettingsStore.NemotronLanguage? {
        self.nemotronLanguageMap[languageID]
    }

    static func whisperLanguageCode(for languageID: String) -> String? {
        self.whisperLanguageCodeMap[languageID]
    }

    private static func appleSpeechAnalyzerLocaleIdentifier(for languageID: String) -> String? {
        self.appleSpeechAnalyzerLocaleMap[languageID]
    }

    private static func appleSpeechLegacyLocaleIdentifier(for languageID: String) -> String? {
        guard let preferredLocales = self.appleSpeechLegacyLocalePreferences[languageID] else {
            return nil
        }

        let supportedLocales = self.legacyAppleLocaleIDs
        return preferredLocales.first { supportedLocales.contains($0) }
    }

    private static let popularLanguageIDs: Set<String> = [
        "ru",
        "en",
        "es",
        "fr",
        "de",
        "pt",
        "it",
        "ja",
        "ko",
        "zh",
        "hi",
        "ar",
    ]

    nonisolated static let parakeetV3LanguageIDs = Set(ParakeetSpeechModelCatalog.v3.supportedLanguageCodes)

    private static let cohereLanguageMap: [String: SettingsStore.CohereLanguage] = [
        "ar": .arabic,
        "de": .german,
        "el": .greek,
        "en": .english,
        "es": .spanish,
        "fr": .french,
        "it": .italian,
        "ja": .japanese,
        "ko": .korean,
        "nl": .dutch,
        "pl": .polish,
        "pt": .portuguese,
        "vi": .vietnamese,
        "zh": .mandarinChinese,
    ]

    private static let nemotronLanguageMap: [String: SettingsStore.NemotronLanguage] = {
        let supportedLanguageIDs = Set(Self.languageDefinitions.map(\.id))
        var languageMap: [String: SettingsStore.NemotronLanguage] = [:]

        for nemotronLanguage in SettingsStore.NemotronLanguage.allCases where nemotronLanguage.rawValue != SettingsStore.NemotronLanguage.auto.rawValue {
            let languageID = Self.languageID(forNemotronLanguage: nemotronLanguage)
            guard supportedLanguageIDs.contains(languageID) else { continue }
            languageMap[languageID] = nemotronLanguage
        }

        return languageMap
    }()

    private static func languageID(forNemotronLanguage language: SettingsStore.NemotronLanguage) -> String {
        switch language.rawValue {
        case "nb-NO":
            return "no"
        default:
            return language.rawValue
                .split(separator: "-", maxSplits: 1)
                .first
                .map(String.init) ?? language.rawValue
        }
    }

    private static let whisperModelOrder: [SettingsStore.SpeechModel] = [
        .whisperSmall,
        .whisperLargeTurbo,
    ]

    private static let appleSpeechAnalyzerLocaleMap: [String: String] = [
        "de": "de-DE",
        "en": "en-US",
        "es": "es-US",
        "fr": "fr-FR",
        "it": "it-IT",
        "ja": "ja-JP",
        "ko": "ko-KR",
        "pt": "pt-BR",
        "zh": "zh-CN",
    ]

    private static let appleSpeechLegacyLocalePreferences: [String: [String]] = [
        "ar": ["ar-SA"],
        "ca": ["ca-ES"],
        "cs": ["cs-CZ"],
        "da": ["da-DK"],
        "de": ["de-DE", "de-AT", "de-CH"],
        "el": ["el-GR"],
        "en": ["en-US", "en-GB", "en-CA", "en-AU", "en-IN"],
        "es": ["es-US", "es-ES", "es-MX", "es-419"],
        "fi": ["fi-FI"],
        "fr": ["fr-FR", "fr-CA", "fr-BE", "fr-CH"],
        "he": ["he-IL"],
        "hi": ["hi-IN"],
        "hr": ["hr-HR"],
        "hu": ["hu-HU"],
        "id": ["id-ID"],
        "it": ["it-IT", "it-CH"],
        "ja": ["ja-JP"],
        "ko": ["ko-KR"],
        "ms": ["ms-MY"],
        "nl": ["nl-NL", "nl-BE"],
        "no": ["nb-NO"],
        "pl": ["pl-PL"],
        "pt": ["pt-BR", "pt-PT"],
        "ro": ["ro-RO"],
        "ru": ["ru-RU"],
        "sk": ["sk-SK"],
        "sv": ["sv-SE"],
        "th": ["th-TH"],
        "tr": ["tr-TR"],
        "uk": ["uk-UA"],
        "vi": ["vi-VN"],
        "zh": ["zh-CN", "zh-TW", "zh-HK"],
    ]

    private static let legacyAppleLocaleIDs: Set<String> = {
        #if canImport(Speech)
        if #available(macOS 10.15, *) {
            return Set(SFSpeechRecognizer.supportedLocales().map { Self.normalizedLocaleIdentifier($0.identifier) })
        }
        #endif
        return []
    }()

    private static func normalizedLocaleIdentifier(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-")
    }

    private static let whisperLanguageCodeMap: [String: String] = {
        var languageMap: [String: String] = [:]
        for language in Self.languageDefinitions {
            let whisperCode = language.id
            guard Self.whisperSupportedLanguageCodes.contains(whisperCode) else { continue }
            languageMap[language.id] = whisperCode
        }
        return languageMap
    }()

    nonisolated static let whisperSupportedLanguageCodes: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo",
        "br", "bs", "ca", "cs", "cy", "da", "de", "el", "en", "es",
        "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw",
        "he", "hi", "hr", "ht", "hu", "hy", "id", "is", "it", "ja",
        "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo",
        "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
        "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt",
        "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq",
        "sr", "su", "sv", "sw", "ta", "te", "tg", "th", "tk", "tl",
        "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh",
    ]

    private static let languageDefinitions: [VoiceEngineLanguage] = [
        Self.language("af", "Afrikaans"),
        Self.language("am", "Amharic"),
        Self.language("ar", "Arabic", aliases: ["Arab"]),
        Self.language("as", "Assamese"),
        Self.language("az", "Azerbaijani"),
        Self.language("ba", "Bashkir"),
        Self.language("be", "Belarusian"),
        Self.language("bg", "Bulgarian"),
        Self.language("bn", "Bengali", aliases: ["Bangla"]),
        Self.language("bo", "Tibetan"),
        Self.language("br", "Breton"),
        Self.language("bs", "Bosnian"),
        Self.language("ca", "Catalan"),
        Self.language("cs", "Czech"),
        Self.language("cy", "Welsh"),
        Self.language("da", "Danish"),
        Self.language("de", "German", aliases: ["Deutsch"]),
        Self.language("el", "Greek"),
        Self.language("en", "English"),
        Self.language("es", "Spanish", aliases: ["Castilian"]),
        Self.language("et", "Estonian"),
        Self.language("eu", "Basque"),
        Self.language("fa", "Persian", aliases: ["Farsi"]),
        Self.language("fi", "Finnish"),
        Self.language("fo", "Faroese"),
        Self.language("fr", "French"),
        Self.language("gl", "Galician"),
        Self.language("gu", "Gujarati"),
        Self.language("ha", "Hausa"),
        Self.language("haw", "Hawaiian"),
        Self.language("he", "Hebrew"),
        Self.language("hi", "Hindi"),
        Self.language("hr", "Croatian"),
        Self.language("ht", "Haitian Creole"),
        Self.language("hu", "Hungarian"),
        Self.language("hy", "Armenian"),
        Self.language("id", "Indonesian"),
        Self.language("is", "Icelandic"),
        Self.language("it", "Italian"),
        Self.language("ja", "Japanese"),
        Self.language("jw", "Javanese"),
        Self.language("ka", "Georgian"),
        Self.language("kk", "Kazakh"),
        Self.language("km", "Khmer"),
        Self.language("kn", "Kannada"),
        Self.language("ko", "Korean"),
        Self.language("la", "Latin"),
        Self.language("lb", "Luxembourgish"),
        Self.language("ln", "Lingala"),
        Self.language("lo", "Lao"),
        Self.language("lt", "Lithuanian"),
        Self.language("lv", "Latvian"),
        Self.language("mg", "Malagasy"),
        Self.language("mi", "Maori"),
        Self.language("mk", "Macedonian"),
        Self.language("ml", "Malayalam"),
        Self.language("mn", "Mongolian"),
        Self.language("mr", "Marathi"),
        Self.language("ms", "Malay"),
        Self.language("mt", "Maltese"),
        Self.language("my", "Myanmar", aliases: ["Burmese"]),
        Self.language("ne", "Nepali"),
        Self.language("nl", "Dutch"),
        Self.language("nn", "Norwegian Nynorsk"),
        Self.language("no", "Norwegian", aliases: ["Norwegian Bokmal"]),
        Self.language("oc", "Occitan"),
        Self.language("pa", "Punjabi"),
        Self.language("pl", "Polish"),
        Self.language("ps", "Pashto"),
        Self.language("pt", "Portuguese"),
        Self.language("ro", "Romanian", aliases: ["Moldavian", "Moldovan"]),
        Self.language("ru", "Russian"),
        Self.language("sa", "Sanskrit"),
        Self.language("sd", "Sindhi"),
        Self.language("si", "Sinhala", aliases: ["Sinhalese"]),
        Self.language("sk", "Slovak"),
        Self.language("sl", "Slovenian"),
        Self.language("sn", "Shona"),
        Self.language("so", "Somali"),
        Self.language("sq", "Albanian"),
        Self.language("sr", "Serbian"),
        Self.language("su", "Sundanese"),
        Self.language("sv", "Swedish"),
        Self.language("sw", "Swahili"),
        Self.language("ta", "Tamil"),
        Self.language("te", "Telugu"),
        Self.language("tg", "Tajik"),
        Self.language("th", "Thai"),
        Self.language("tk", "Turkmen"),
        Self.language("tl", "Tagalog", aliases: ["Filipino"]),
        Self.language("tr", "Turkish"),
        Self.language("tt", "Tatar"),
        Self.language("uk", "Ukrainian"),
        Self.language("ur", "Urdu"),
        Self.language("uz", "Uzbek"),
        Self.language("vi", "Vietnamese"),
        Self.language("yi", "Yiddish"),
        Self.language("yo", "Yoruba"),
        Self.language("zh", "Mandarin Chinese", aliases: ["Chinese", "Mandarin"]),
    ]

    private static func language(
        _ id: String,
        _ displayName: String,
        aliases: [String] = []
    ) -> VoiceEngineLanguage {
        VoiceEngineLanguage(
            id: id,
            displayName: displayName,
            aliases: aliases,
            isPopular: self.popularLanguageIDs.contains(id)
        )
    }
}
