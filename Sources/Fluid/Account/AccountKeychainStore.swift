import CryptoKit
import Foundation
import Security
import LocalAuthentication

/// One atomic active-account envelope per distribution/issuer/client/API. No cloud synchronization,
/// shared access group, provider-key migration or email linking. I/O never runs on MainActor.
actor AccountKeychainStore: AccountCredentialStoring {
    private nonisolated struct Envelope: Codable {
        let version: Int
        let scope: String
        let accountScope: String
        let grant: AccountGrant
    }
    nonisolated static func scope(configuration: AccountConfiguration) -> String {
        let fields = [configuration.bundleIdentifier, configuration.issuer.absoluteString, configuration.clientID,
                      configuration.apiAudience, configuration.apiBaseURL.absoluteString]
        return Data(SHA256.hash(data: try! JSONEncoder().encode(fields))).map { String(format: "%02x", $0) }.joined()
    }
    private let namespace: String
    private let scope: String
    init(configuration: AccountConfiguration) {
        scope = Self.scope(configuration: configuration)
        namespace = configuration.bundleIdentifier + ".account-grants." + scope
    }
    private func query() -> [String: Any] {
        let authentication = LAContext(); authentication.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: namespace,
         kSecAttrAccount as String: "active-device-account-v1", kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: authentication]
    }
    func load() throws -> AccountGrant? {
        var request = query(); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, data.count <= 131072,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1,
              envelope.scope == scope, envelope.accountScope == accountScope(envelope.grant.identity) else { throw AccountError.credentialsUnavailable }
        return envelope.grant
    }
    func save(_ grant: AccountGrant) throws {
        let envelope = Envelope(version: 1, scope: scope, accountScope: accountScope(grant.identity), grant: grant)
        let data = try JSONEncoder().encode(envelope)
        guard data.count <= 131072 else { throw AccountError.credentialsUnavailable }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query(); attributes.forEach { insert[$0.key] = $0.value }
            guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw AccountError.credentialsUnavailable }
        } else if status != errSecSuccess { throw AccountError.credentialsUnavailable }
        // Verify the exact serialized envelope without deleting the previous item first.
        var request = query(); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var readback: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &readback) == errSecSuccess, readback as? Data == data else {
            throw AccountError.credentialsUnavailable
        }
    }
    func clear() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.credentialsUnavailable }
        guard try load() == nil else { throw AccountError.credentialsUnavailable }
    }
    private func accountScope(_ identity: AccountIdentity) -> String {
        Data(SHA256.hash(data: try! JSONEncoder().encode(identity.storageComponents)))
            .map { String(format: "%02x", $0) }.joined()
    }
}
