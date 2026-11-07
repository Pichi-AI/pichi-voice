import Foundation
import Security

/// Trusted installation policy loaded from the signed bundle. A visual import never writes this file.
nonisolated struct BrandDistribution: Codable, Equatable, Sendable {
    let formatVersion: Int
    var repository: String?
    var appIconAsset: String?
    var markAsset: String?
    var menuBarAsset: String?
    var localizePackagedTagline: Bool = false
    var updatesEnabled: Bool = false
    var expectedSigningTeam: String?
    var feedbackEndpoint: String?
    var privacyPolicyURL: String?
    var account: AccountConfiguration?
    var legacyAccount: LegacyAccountConfiguration?

    static let unconfigured = BrandDistribution(formatVersion: 1)

    static func load(bundle: Bundle) -> Self {
        guard let url = bundle.url(forResource: "brand-distribution", withExtension: "json"),
              let data = try? Data(contentsOf: url), data.count <= 32_768,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              (try? value.validate()) != nil else { return .unconfigured }
        return value
    }

    func validate() throws {
        guard self.formatVersion == 1 else { throw BrandProfile.ValidationError.invalid("Unsupported distribution version.") }
        if let repository {
            try BrandProfile.validateHTTPS(repository)
            guard let url = URL(string: repository), url.host == "github.com", url.pathComponents.count == 3,
                  url.query == nil, url.fragment == nil,
                  url.pathComponents.dropFirst().allSatisfy({ $0.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil }) else {
                throw BrandProfile.ValidationError.invalid("The updater repository must identify one GitHub repository.")
            }
        }
        for name in [self.appIconAsset, self.markAsset, self.menuBarAsset].compactMap({ $0 }) {
            guard name.range(of: "^[A-Za-z0-9_-]{1,120}$", options: .regularExpression) != nil else {
                throw BrandProfile.ValidationError.invalid("Distribution asset names are invalid.")
            }
        }
        guard account == nil || legacyAccount == nil else {
            throw BrandProfile.ValidationError.invalid("Select one account authentication mode.")
        }
        try self.account?.validate()
        try self.legacyAccount?.validate()
        if let feedbackEndpoint { try BrandProfile.validateHTTPS(feedbackEndpoint) }
        if let privacyPolicyURL { try BrandProfile.validateHTTPS(privacyPolicyURL) }
        if let expectedSigningTeam {
            guard expectedSigningTeam.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else {
                throw BrandProfile.ValidationError.invalid("Signing team must contain 10 uppercase letters or digits.")
            }
        }
        guard !self.updatesEnabled || (self.repository != nil && self.expectedSigningTeam != nil) else {
            throw BrandProfile.ValidationError.invalid("App updates need a repository and expected signing team.")
        }
    }

    var repositoryOwner: String { self.repository.flatMap(URL.init(string:))?.pathComponents.dropFirst().first ?? "" }
    var repositoryName: String { self.repository.flatMap(URL.init(string:))?.lastPathComponent ?? "" }

    var updatesAllowedForCurrentSignature: Bool {
        #if os(macOS)
        guard self.updatesEnabled, let expectedSigningTeam = self.expectedSigningTeam else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return team == expectedSigningTeam
        #else
        // Mobile updates belong to the signed App Store distribution.
        return false
        #endif
    }
}

// Account trust is part of the signed distribution, never the portable appearance package.
extension BrandDistribution {
    nonisolated struct AccountConfiguration: Codable, Equatable, Sendable {
        let issuer: URL
        let apiBaseURL: URL
        let clientID: String
        let apiAudience: String
        let bundleIdentifier: String

        var redirectURI: URL { URL(string: bundleIdentifier + ":/oauth/callback")! }

        func validate() throws {
            for url in [issuer, apiBaseURL] {
                try BrandProfile.validateHTTPS(url.absoluteString)
                guard url.query == nil, url.fragment == nil, !url.path.contains(".."),
                      !url.absoluteString.hasSuffix("/") else {
                    throw BrandProfile.ValidationError.invalid("Invalid account endpoint.")
                }
            }
            guard bundleIdentifier.range(of: "^[a-z][a-z0-9-]*(?:\\.[a-z][a-z0-9-]*){2,}$", options: .regularExpression) != nil,
                  bundleIdentifier.count <= 200,
                  [clientID, apiAudience].allSatisfy({ !$0.isEmpty && $0.count <= 200 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
                throw BrandProfile.ValidationError.invalid("Invalid account client configuration.")
            }
        }
    }
}

// Existing cookie sessions are deliberately configured separately from OIDC trust.
extension BrandDistribution {
    nonisolated struct LegacyAccountConfiguration: Codable, Equatable, Sendable {
        let apiBaseURL: URL
        let bundleIdentifier: String

        func validate() throws {
            try BrandProfile.validateHTTPS(apiBaseURL.absoluteString)
            guard let host = apiBaseURL.host, !host.isEmpty,
                  apiBaseURL.user == nil, apiBaseURL.password == nil,
                  apiBaseURL.path.isEmpty, apiBaseURL.query == nil, apiBaseURL.fragment == nil,
                  !apiBaseURL.absoluteString.hasSuffix("/"),
                  bundleIdentifier.range(of: "^[a-z][a-z0-9-]*(?:\\.[a-z][a-z0-9-]*){2,}$", options: .regularExpression) != nil,
                  bundleIdentifier.count <= 200 else {
                throw BrandProfile.ValidationError.invalid("Invalid legacy session origin.")
            }
        }
    }
}
