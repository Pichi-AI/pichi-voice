import Foundation

/// Open BCP 47 identifiers: adding a String Catalog language adds a picker choice.
/// Interface preferences never change speech recognition or summary languages.
nonisolated struct PichiInterfaceLanguage: RawRepresentable, Hashable, CaseIterable, Identifiable, Sendable {
    let rawValue: String
    static let russian = Self(rawValue: "ru")!
    static let english = Self(rawValue: "en")!
    static let defaultsKey = "PichiInterfaceLanguage"

    init?(rawValue: String) {
        let normalized = rawValue.replacingOccurrences(of: "_", with: "-")
        guard normalized.count <= 64,
              normalized.range(of: "^[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil else { return nil }
        let components = normalized.split(separator: "-")
        self.rawValue = components.enumerated().map { index, component in
            index == 0 ? component.lowercased() : String(component)
        }.joined(separator: "-")
    }

    var id: String { self.rawValue }
    var locale: Locale { Locale(identifier: self.rawValue) }
    // Apple's language metadata supplies direction for every catalog language.
    var usesRightToLeftLayout: Bool { self.locale.language.characterDirection == .rightToLeft }
    // Native names remain recognisable from any interface language.
    var displayName: String {
        self.locale.localizedString(forIdentifier: self.rawValue)?.capitalized(with: self.locale) ?? self.rawValue
    }

    static var allCases: [Self] { self.availableLanguages(in: .main) }

    static func availableLanguages(in bundle: Bundle) -> [Self] {
        if bundle === Bundle.main { return self.mainLanguages }
        return self.discoverLanguages(in: bundle)
    }

    // Installed catalog metadata cannot change during the process. Keep this separate
    // from the selected preference, which must remain live when Settings changes.
    private static let mainLanguages = Self.discoverLanguages(in: .main)

    private static func discoverLanguages(in bundle: Bundle) -> [Self] {
        let languages = Set(bundle.localizations.filter { $0 != "Base" }.compactMap(Self.init(rawValue:)))
            .union([Self.russian, .english])
        let additional = languages.filter { $0 != .russian && $0 != .english }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return [.russian, .english] + additional
    }

    static func stored(in defaults: UserDefaults, bundle: Bundle = .main) -> Self {
        guard let raw = defaults.string(forKey: self.defaultsKey) else { return .russian }
        let available = self.availableLanguages(in: bundle)
        if let exact = available.first(where: { $0.rawValue == raw }) { return exact }
        guard let language = Self(rawValue: raw) else { return .russian }
        guard let preferred = Bundle.preferredLocalizations(from: available.map(\.rawValue), forPreferences: [language.rawValue]).first,
              let matched = available.first(where: { $0.rawValue == preferred }),
              matched.languageCode == language.languageCode else { return .russian }
        return matched
    }

    func persist(in defaults: UserDefaults) {
        defaults.set(self.rawValue, forKey: Self.defaultsKey)
    }

    var languageCode: String { self.rawValue.split(separator: "-").first.map(String.init) ?? self.rawValue }

}

/// Explicit UI-key lookup. Never pass transcripts, dictionary words, IDs, or URLs here.
nonisolated enum PichiLocalization {
    static let languageChanged = Notification.Name("PichiInterfaceLanguageChanged")

    static var language: PichiInterfaceLanguage {
        #if DEBUG
        // Existing upstream assertions can select English explicitly in their test host.
        // A production build always uses the persisted preference, defaulting to Russian.
        if NSClassFromString("XCTestCase") != nil,
           let raw = ProcessInfo.processInfo.environment["PICHI_INTERFACE_LANGUAGE"],
           let language = PichiInterfaceLanguage(rawValue: raw) {
            return language
        }
        #endif
        return .stored(in: .standard)
    }

    static var locale: Locale { self.language.locale }

    static func text(_ source: String) -> String {
        self.text(source, language: self.language, bundle: .main)
    }

    /// Semantic keys distinguish contexts while retaining English fallback copy.
    static func text(_ key: String, defaultValue: String) -> String {
        self.text(key, language: self.language, bundle: .main, defaultValue: defaultValue)
    }

    static func text(_ source: String, locale: Locale) -> String {
        self.text(source, language: PichiInterfaceLanguage(rawValue: locale.identifier) ?? .russian, bundle: .main)
    }

    static func text(_ source: String, language: PichiInterfaceLanguage, bundle: Bundle, defaultValue: String? = nil) -> String {
        self.resolvedText(source, language: language, bundle: bundle, defaultValue: defaultValue).value
    }

    private static let missingTranslation = UUID().uuidString

    private struct LocalizedResource: Sendable {
        let bundle: Bundle
        let locale: Locale
    }

    private static let mainSourceLanguage = PichiInterfaceLanguage(rawValue: Bundle.main.developmentLocalization ?? "en") ?? .english
    private static let mainResourceIdentifiers = Bundle.main.localizations.filter { $0 != "Base" }
    private static let mainResources: [String: LocalizedResource] = {
        var resources: [String: LocalizedResource] = [:]
        for identifier in Set(Self.mainResourceIdentifiers + [Self.mainSourceLanguage.rawValue]) {
            guard let language = PichiInterfaceLanguage(rawValue: identifier),
                  let path = Bundle.main.path(forResource: identifier, ofType: "lproj"),
                  let bundle = Bundle(path: path) else { continue }
            resources[identifier] = LocalizedResource(bundle: bundle, locale: language.locale)
        }
        return resources
    }()
    // One immutable lookup plan per installed language, never a cache of UI keys,
    // transcripts, custom bundles, preferences or imported brand names.
    private static let mainResourcePlans: [PichiInterfaceLanguage: [LocalizedResource]] = {
        Dictionary(uniqueKeysWithValues: PichiInterfaceLanguage.availableLanguages(in: .main).map { language in
            (language, Self.resourceIdentifiers(for: language, available: Self.mainResourceIdentifiers,
                sourceLanguage: Self.mainSourceLanguage).compactMap { Self.mainResources[$0] })
        })
    }()

    private static func resourceIdentifiers(for language: PichiInterfaceLanguage, available: [String],
                                            sourceLanguage: PichiInterfaceLanguage) -> [String] {
        var identifiers = Bundle.preferredLocalizations(from: available, forPreferences: [language.rawValue, sourceLanguage.rawValue])
        if !identifiers.contains(sourceLanguage.rawValue) { identifiers.append(sourceLanguage.rawValue) }
        return identifiers.filter { identifier in
            guard let resolved = PichiInterfaceLanguage(rawValue: identifier) else { return false }
            return resolved.languageCode == language.languageCode || resolved.languageCode == sourceLanguage.languageCode
        }
    }

    /// A partially translated installed language falls back per key through the source resource.
    /// Preserve its locale as well so fallback plural rules match the fallback language.
    private static func resolvedText(_ key: String, language: PichiInterfaceLanguage, bundle: Bundle,
                                     defaultValue: String? = nil) -> (value: String, locale: Locale) {
        if bundle === Bundle.main {
            let resources = self.mainResourcePlans[language] ?? self.resourceIdentifiers(for: language,
                available: self.mainResourceIdentifiers, sourceLanguage: self.mainSourceLanguage).compactMap { self.mainResources[$0] }
            for resource in resources {
                let value = resource.bundle.localizedString(forKey: key, value: self.missingTranslation, table: "Localizable")
                if value != self.missingTranslation { return (value, resource.locale) }
            }
            return (defaultValue ?? key, self.mainSourceLanguage.locale)
        }
        let sourceLanguage = PichiInterfaceLanguage(rawValue: bundle.developmentLocalization ?? "en") ?? .english
        let available = bundle.localizations.filter { $0 != "Base" }
        let identifiers = self.resourceIdentifiers(for: language, available: available, sourceLanguage: sourceLanguage)
        for identifier in identifiers {
            guard let resolved = PichiInterfaceLanguage(rawValue: identifier),
                  let path = bundle.path(forResource: identifier, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else { continue }
            let value = localizedBundle.localizedString(forKey: key, value: self.missingTranslation, table: "Localizable")
            if value != self.missingTranslation { return (value, resolved.locale) }
        }
        return (defaultValue ?? key, sourceLanguage.locale)
    }

    static func format(_ source: String, _ arguments: CVarArg...) -> String {
        self.format(source, language: self.language, bundle: .main, arguments: arguments)
    }

    static func format(_ source: String, locale: Locale, bundle: Bundle = .main, arguments: [CVarArg]) -> String {
        self.format(source, language: PichiInterfaceLanguage(rawValue: locale.identifier) ?? self.language,
                    bundle: bundle, arguments: arguments)
    }

    static func format(_ source: String, language: PichiInterfaceLanguage, bundle: Bundle, arguments: [CVarArg], defaultValue: String? = nil) -> String {
        let resource = self.resolvedText(source, language: language, bundle: bundle, defaultValue: defaultValue)
        return String(format: resource.value, locale: resource.locale, arguments: arguments)
    }

    /// Shared stats presentation. Keep the estimate numeric until rendering so
    /// compact share cards never have to interpret translated unit labels.
    static func formattedTimeSaved(minutes: Double, hoursOnly: Bool = false,
                                   language: PichiInterfaceLanguage = PichiLocalization.language,
                                   bundle: Bundle = .main) -> String {
        guard minutes >= 1 else { return self.text("< 1 min", language: language, bundle: bundle) }
        let wholeMinutes = Int(minutes)
        if wholeMinutes < 60 {
            return self.format("%lld min", language: language, bundle: bundle, arguments: [wholeMinutes])
        }
        let hours = wholeMinutes / 60
        let remainder = wholeMinutes % 60
        if hoursOnly || remainder == 0 {
            return self.format("%lldh", language: language, bundle: bundle, arguments: [hours])
        }
        return self.format("%lldh %lldm", language: language, bundle: bundle, arguments: [hours, remainder])
    }

    /// Stats renders its prominent number separately. The catalog's named
    /// quantity substitution selects grammar without repeating that number.
    static func formattedStreakUnit(days: Int, language: PichiInterfaceLanguage = PichiLocalization.language,
                                    bundle: Bundle = .main) -> String {
        self.format("stats.streak.unit", language: language, bundle: bundle, arguments: [days], defaultValue: "day streak")
    }

    static func configureApplicationLanguage() {
        // Scope Apple's standard AppKit menu localization to this app's own defaults domain.
        // Updating native system menus takes effect on the next app launch.
        let primary = self.language.rawValue
        UserDefaults.standard.set(primary == "en" ? ["en"] : [primary, "en"], forKey: "AppleLanguages")
    }
}
