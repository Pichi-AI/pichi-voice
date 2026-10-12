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
        if let feedbackEndpoint { try BrandProfile.validateHTTPS(feedbackEndpoint) }
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
        guard self.updatesEnabled, let expectedSigningTeam = self.expectedSigningTeam else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code, SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return team == expectedSigningTeam
    }
}
