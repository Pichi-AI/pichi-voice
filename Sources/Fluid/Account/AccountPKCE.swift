import CryptoKit
import Foundation
import Security

nonisolated struct AccountAuthorizationAttempt: Sendable {
    let verifier: String
    let state: String
    let nonce: String
    let redirectURI: URL
    var challenge: String { Data(SHA256.hash(data: Data(verifier.utf8))).accountBase64URL }

    init(redirectURI: URL) throws {
        func random() throws -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw AccountError.invalidState
            }
            return Data(bytes).accountBase64URL
        }
        self.verifier = try random(); self.state = try random(); self.nonce = try random()
        self.redirectURI = redirectURI
    }

    func code(from callback: URL) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == redirectURI.scheme, parts.host == redirectURI.host,
              parts.path == redirectURI.path, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.fragment == nil else { throw AccountError.invalidCallback }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else { throw AccountError.invalidState }
        if items.contains(where: { $0.name == "error" }) { throw AccountError.cancelled }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 8192,
              code.rangeOfCharacter(from: .controlCharacters) == nil else { throw AccountError.invalidCallback }
        return code
    }
}

extension Data {
    nonisolated var accountBase64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    nonisolated init?(accountBase64URL value: String) {
        guard !value.isEmpty, value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
    }
}
