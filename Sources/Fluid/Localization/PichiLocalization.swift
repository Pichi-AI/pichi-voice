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
    // Native names remain recognisable from any interface language.
    var displayName: String {
        if self == .russian { return "Русский" }
        if self == .english { return "English" }
        return self.locale.localizedString(forIdentifier: self.rawValue) ?? self.rawValue
    }

    static var allCases: [Self] { self.availableLanguages(in: .main) }

    static func availableLanguages(in bundle: Bundle) -> [Self] {
        let languages = Set(bundle.localizations.filter { $0 != "Base" }.compactMap(Self.init(rawValue:)))
            .union([Self.russian, .english])
        let additional = languages.filter { $0 != .russian && $0 != .english }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return [.russian, .english] + additional
    }

    static func stored(in defaults: UserDefaults, bundle: Bundle = .main) -> Self {
        guard let raw = defaults.string(forKey: self.defaultsKey),
              let language = Self(rawValue: raw) else { return .russian }
        let available = self.availableLanguages(in: bundle)
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

    static func text(_ source: String, locale: Locale) -> String {
        self.text(source, language: PichiInterfaceLanguage(rawValue: locale.identifier) ?? .russian, bundle: .main)
    }

    static func text(_ source: String, language: PichiInterfaceLanguage, bundle: Bundle) -> String {
        let available = bundle.localizations.filter { $0 != "Base" }
        guard let identifier = Bundle.preferredLocalizations(from: available, forPreferences: [language.rawValue, "en"]).first,
              let resolved = PichiInterfaceLanguage(rawValue: identifier),
              resolved.languageCode == language.languageCode || resolved == .english,
              let path = bundle.path(forResource: identifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else { return source }
        return localizedBundle.localizedString(forKey: source, value: source, table: "Localizable")
    }

    static func format(_ source: String, _ arguments: CVarArg...) -> String {
        self.format(source, language: self.language, bundle: .main, arguments: arguments)
    }

    static func format(_ source: String, language: PichiInterfaceLanguage, bundle: Bundle, arguments: [CVarArg]) -> String {
        String(format: self.text(source, language: language, bundle: bundle), locale: language.locale, arguments: arguments)
    }

    static func configureApplicationLanguage() {
        // Scope Apple's standard AppKit menu localization to this app's own defaults domain.
        // Updating native system menus takes effect on the next app launch.
        let primary = self.language.rawValue
        UserDefaults.standard.set(primary == "en" ? ["en"] : [primary, "en"], forKey: "AppleLanguages")
    }
}
