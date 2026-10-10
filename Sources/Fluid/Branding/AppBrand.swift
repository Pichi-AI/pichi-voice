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

    static let pichi = BrandProfile(
        appName: "Pichi Voice", meetingName: "Pichi Meet", assistantName: "Pichi AI",
        tagline: "Your voice. Your ideas. Your Mac.",
        accentLight: "#6749C1", accentDark: "#A78FFF",
        website: "https://pichi.ai", support: "https://github.com/Pichi-AI/pichi-voice/issues"
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
            else { throw ValidationError.invalid("\(label) must contain 1 to 120 printable characters.") }
        }
        for color in [self.accentLight, self.accentDark] {
            guard color.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil
            else { throw ValidationError.invalid("Accent colors must use #RRGGBB.") }
        }
        for value in [self.website, self.support] {
            guard value.count <= 2_048, let url = URL(string: value), url.scheme == "https",
                  url.host?.isEmpty == false, url.user == nil, url.password == nil
            else { throw ValidationError.invalid("Website and support links must be HTTPS URLs without credentials.") }
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
    static var bundleIdentifier: String { Bundle.main.bundleIdentifier ?? "ai.pichi.voice" }
    static var releaseBundleIdentifier: String { self.releaseBundleIdentifier(from: self.bundleIdentifier) }
    static func releaseBundleIdentifier(from identifier: String) -> String {
        identifier.hasSuffix(".debug") ? String(identifier.dropLast(".debug".count)) : identifier
    }
    static var storageNamespace: String { self.bundleIdentifier }
    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(self.storageNamespace, isDirectory: true)
    }
    static var modelsDirectory: URL { self.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true) }
    static var cachesDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return base.appendingPathComponent(self.storageNamespace, isDirectory: true)
    }
    static var keychainService: String { self.bundleIdentifier + ".provider-api-keys" }
    static let keychainAccount = "providerApiKeys"

    static let packagedProfile: BrandProfile = {
        guard let url = Bundle.main.url(forResource: "pichi-brand", withExtension: "json"),
              let data = try? Data(contentsOf: url), let profile = try? BrandProfile.decode(data)
        else { return .pichi }
        return profile
    }()

    static var profile: BrandProfile {
        guard let data = UserDefaults.standard.data(forKey: self.profileDefaultsKey),
              let profile = try? BrandProfile.decode(data)
        else { return self.packagedProfile }
        return profile
    }

    static var appName: String { self.profile.appName }
    static var meetingName: String { self.profile.meetingName }
    static var assistantName: String { self.profile.assistantName }
    static var tagline: String {
        // Imported white-label copy is user content, even when it matches a UI key.
        UserDefaults.standard.data(forKey: self.profileDefaultsKey) == nil && self.packagedProfile == .pichi
            ? PichiLocalization.text(self.packagedProfile.tagline) : self.profile.tagline
    }
    static var supportURL: URL { URL(string: self.profile.support)! }
    static var websiteURL: URL { URL(string: self.profile.website)! }
    static let repositoryOwner = "Pichi-AI"
    static let repositoryName = "pichi-voice"
    static let repositoryURL = URL(string: "https://github.com/Pichi-AI/pichi-voice")!
    // Pichi has no signed distribution feed yet. Runtime branding cannot enable updates.
    static let updatesEnabled = false
    static let feedbackEndpoint: URL? = nil

    static func text(_ source: String) -> String {
        let profile = self.profile
        return self.text(source, profile: profile, language: PichiLocalization.language)
    }

    static func text(_ source: String, profile: BrandProfile, language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        self.substitutingProductNames(in: PichiLocalization.text(source, language: language, bundle: bundle), profile: profile)
    }

    static func substitutingProductNames(in source: String, profile: BrandProfile) -> String {
        let names = [
            "FluidVoice": profile.appName, "Fluid Voice": profile.appName,
            "FLUIDVOICE": profile.appName.uppercased(), "FLUID VOICE": profile.appName.uppercased(),
            "FluidMeet": profile.meetingName, "Fluid Meet": profile.meetingName,
            "FLUIDMEET": profile.meetingName.uppercased(), "FLUID MEET": profile.meetingName.uppercased(),
            "Fluid Intelligence": profile.assistantName, "FLUID INTELLIGENCE": profile.assistantName.uppercased(),
        ]
        // Replace original matches only, so a custom brand name is never processed twice.
        let expression = try! NSRegularExpression(pattern: names.keys.sorted().map(NSRegularExpression.escapedPattern).joined(separator: "|"))
        var result = source
        for match in expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let originalRange = Range(match.range, in: source),
                  let resultRange = Range(match.range, in: result),
                  let replacement = names[String(source[originalRange])] else { continue }
            result.replaceSubrange(resultRange, with: replacement)
        }
        return result
    }
}
