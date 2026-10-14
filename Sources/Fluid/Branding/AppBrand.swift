import Foundation

/// Visual profiles cannot alter the installation, credentials, update trust, or telemetry.
nonisolated struct BrandProfile: Codable, Equatable, Sendable {
    let appName: String
    let meetingName: String
    let assistantName: String
    let tagline: String
    let accentLight: String
    let accentDark: String
    let website: String
    let support: String

    // Neutral fail-closed copy is only used when a distribution resource is missing or corrupt.
    // Product-specific defaults live in brand-package.json, including Pichi's initial profile.
    static let neutral = BrandProfile(
        appName: "Voice", meetingName: "Meet", assistantName: "AI",
        tagline: "Your voice. Your ideas. Your Mac.",
        accentLight: "#555555", accentDark: "#AAAAAA",
        website: "https://example.invalid", support: "https://example.invalid"
    )

    static func decode(_ data: Data) throws -> BrandProfile {
        guard data.count <= 32_768 else { throw ValidationError.invalid("Profile is larger than 32 KB.") }
        let profile = try JSONDecoder().decode(Self.self, from: data)
        try profile.validate()
        return profile
    }

    func validate() throws {
        for (label, value) in [("App name", self.appName), ("Meeting name", self.meetingName), ("AI name", self.assistantName), ("Tagline", self.tagline)] {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.count <= 120, value.rangeOfCharacter(from: .controlCharacters) == nil
            else { throw ValidationError.invalid(PichiLocalization.format("%@ must contain 1 to 120 printable characters.", PichiLocalization.text(label))) }
        }
        for color in [self.accentLight, self.accentDark] {
            try Self.validateColor(color)
        }
        for value in [self.website, self.support] {
            try Self.validateHTTPS(value)
        }
    }

    static func validateColor(_ value: String) throws {
        guard value.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil else {
            throw ValidationError.invalid("Accent colors must use #RRGGBB.")
        }
    }

    static func validateHTTPS(_ value: String) throws {
        guard value.count <= 2_048, let url = URL(string: value), url.scheme == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil,
              value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ValidationError.invalid("Website and support links must be HTTPS URLs without credentials.")
        }
    }

    enum ValidationError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
}

/// Keep upstream types and filenames intact while exposing downstream identity in one place.
nonisolated enum AppBrand {
    static let appearanceChanged = Notification.Name("PichiBrandAppearanceChanged")
    static let profileDefaultsKey = "PichiBrandProfile"
    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "local.voice.unbundled" }
    static var releaseBundleIdentifier: String { self.releaseBundleIdentifier(from: self.bundleIdentifier) }
    static func releaseBundleIdentifier(from identifier: String) -> String {
        identifier.hasSuffix(".debug") ? String(identifier.dropLast(".debug".count)) : identifier
    }
    static var storageNamespace: String { self.bundleIdentifier }
    static func logsDirectory(in libraryDirectory: URL, storageNamespace: String) -> URL {
        // The namespace is trusted bundle identity, never an imported appearance name.
        libraryDirectory.appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(storageNamespace, isDirectory: true)
    }
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(self.storageNamespace, isDirectory: true)
    }
    static var modelsDirectory: URL { self.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true) }
    static var cachesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent(self.storageNamespace, isDirectory: true)
    }
    static var keychainService: String { self.bundleIdentifier + ".provider-api-keys" }
    static let keychainAccount = "providerApiKeys"

    static let packagedPackage: BrandPackage = {
        guard let url = Bundle.main.url(forResource: "brand-package", withExtension: "json"),
              let data = try? Data(contentsOf: url), let package = try? BrandPackage.decode(data)
        else { return BrandPackage(profile: .neutral) }
        return package
    }()

    static var package: BrandPackage { BrandPackageStore.shared.current() }
    static var packagedProfile: BrandProfile { self.packagedPackage.profile }
    static var profile: BrandProfile { self.package.profile }
    static var appName: String { self.profile.appName }
    static var meetingName: String { self.profile.meetingName }
    static var assistantName: String { self.profile.assistantName }
    static var filenamePrefix: String { self.filenamePrefix(for: self.appName) }
    static func filenamePrefix(for name: String) -> String {
        let unsafe = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/:\\"))
        let value = name.components(separatedBy: unsafe).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var bounded = ""
        for character in value {
            let next = String(character)
            guard bounded.utf8.count + next.utf8.count <= 120 else { break }
            bounded += next
        }
        return bounded.isEmpty || bounded == "." || bounded == ".." ? "Voice" : bounded
    }
    static var tagline: String {
        // Imported copy is user data, even when it matches a String Catalog key.
        !BrandPackageStore.shared.hasOverride && self.distribution.localizePackagedTagline
            ? PichiLocalization.text(self.profile.tagline) : self.profile.tagline
    }
    static var supportURL: URL { URL(string: self.profile.support)! }
    static var websiteURL: URL { URL(string: self.profile.website)! }
    static let distribution = BrandDistribution.load(bundle: .main)
    // Update checks use trusted bundle configuration, never an imported visual package.
    static var repositoryOwner: String { self.distribution.repositoryOwner }
    static var repositoryName: String { self.distribution.repositoryName }
    static var repositoryURL: URL { URL(string: self.package.links?.repository ?? self.profile.website)! }
    static let updatesEnabled = AppBrand.distribution.updatesAllowedForCurrentSignature
    static var feedbackEndpoint: URL? { self.distribution.feedbackEndpoint.flatMap(URL.init(string:)) }

    static func text(_ source: String) -> String {
        let profile = self.profile
        return self.text(source, profile: profile, language: PichiLocalization.language)
    }

    static func text(_ source: String, profile: BrandProfile, language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        self.substitutingProductNames(in: PichiLocalization.text(source, language: language, bundle: bundle), profile: profile)
    }

    /// Localize a trusted template before inserting brand data. Only inserted names are escaped;
    /// format arguments remain verbatim data and never pass through brand substitution.
    static func format(_ source: String, _ arguments: CVarArg...) -> String {
        self.format(source, profile: self.profile, language: PichiLocalization.language, arguments: arguments)
    }

    static func format(_ source: String, profile: BrandProfile, language: PichiInterfaceLanguage, bundle: Bundle = .main, arguments: [CVarArg]) -> String {
        let localized = PichiLocalization.text(source, language: language, bundle: bundle)
        let template = self.substitutingProductNames(in: localized, profile: profile, escapingFormatSpecifiers: true)
        return String(format: template, locale: language.locale, arguments: arguments)
    }

    static func substitutingProductNames(in source: String, profile: BrandProfile, escapingFormatSpecifiers: Bool = false) -> String {
        let names = [
            "fluidvoice": profile.appName, "fluid voice": profile.appName,
            "fluidmeet": profile.meetingName, "fluid meet": profile.meetingName,
            "fluid intelligence": profile.assistantName,
        ]
        // Replace original matches only, so a custom brand name is never processed twice.
        let expression = try! NSRegularExpression(
            pattern: names.keys.sorted().map(NSRegularExpression.escapedPattern).joined(separator: "|"),
            options: [.caseInsensitive]
        )
        var result = source
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let originalRange = Range(match.range, in: source), let resultRange = Range(match.range, in: result) else { continue }
            let original = String(source[originalRange])
            guard let replacement = names[original.lowercased()] else { continue }
            let displayedName = original == original.uppercased() ? replacement.uppercased() : replacement
            result.replaceSubrange(resultRange, with: escapingFormatSpecifiers
                ? displayedName.replacingOccurrences(of: "%", with: "%%") : displayedName)
        }
        return result
    }
}
