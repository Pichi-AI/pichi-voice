import Foundation

typealias LegacyAccountConfiguration = BrandDistribution.LegacyAccountConfiguration

/// One destination contract for the existing durable publication stores. OIDC encoding
/// remains the original flat object so existing consent and outbox files keep their scope.
nonisolated enum AccountPublicationConfiguration: Codable, Equatable, Sendable {
    case oidc(AccountConfiguration)
    case legacy(LegacyAccountConfiguration)
    private enum CodingKeys: String, CodingKey { case legacySession }
    init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        if let legacy = try keyed.decodeIfPresent(LegacyAccountConfiguration.self, forKey: .legacySession) {
            self = .legacy(legacy)
        } else { self = .oidc(try AccountConfiguration(from: decoder)) }
    }
    func encode(to encoder: any Encoder) throws {
        switch self {
        case .oidc(let value): try value.encode(to: encoder)
        case .legacy(let value):
            var keyed = encoder.container(keyedBy: CodingKeys.self)
            try keyed.encode(value, forKey: .legacySession)
        }
    }
    var apiBaseURL: URL { switch self { case .oidc(let c): c.apiBaseURL; case .legacy(let c): c.apiBaseURL } }
    var bundleIdentifier: String { switch self { case .oidc(let c): c.bundleIdentifier; case .legacy(let c): c.bundleIdentifier } }
    var scopeIdentifier: String {
        switch self {
        case .oidc(let c): [c.bundleIdentifier, c.issuer.absoluteString, c.clientID, c.apiAudience, c.apiBaseURL.absoluteString].joined(separator: "|")
        case .legacy(let c): [c.bundleIdentifier, "legacy-session", c.apiBaseURL.absoluteString].joined(separator: "|")
        }
    }
    func validate() throws { switch self { case .oidc(let c): try c.validate(); case .legacy(let c): try c.validate() } }
    func matches(_ identity: AccountIdentity) -> Bool {
        switch self {
        case .oidc(let c): !identity.isLegacySession && identity.issuer == c.issuer.absoluteString
        case .legacy(let c): identity.legacyOrigin == c.apiBaseURL.absoluteString && identity.issuer.isEmpty && identity.subject.isEmpty
        }
    }
}
