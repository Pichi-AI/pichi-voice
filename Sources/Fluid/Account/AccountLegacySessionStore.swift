import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Secret material for one server-issued cookie, without inventing an offline TTL.
/// The server sets a seven-day Max-Age. A cookie without an explicit expiry is
/// usable only by its live transport and is never persisted for restart recovery.
nonisolated struct LegacyAccountCookie: Codable, Equatable, Sendable {
    let value: String
    let receivedAt: Date
    let expiresAt: Date

    func validate(now: Date = Date()) throws {
        guard !value.isEmpty, value.utf8.count <= 32_768,
              value.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil,
              !value.contains(";"), !value.contains(","),
              receivedAt.timeIntervalSince1970.isFinite, expiresAt.timeIntervalSince1970.isFinite,
              receivedAt <= now.addingTimeInterval(60), expiresAt > now,
              expiresAt > receivedAt, expiresAt.timeIntervalSince(receivedAt) <= 7 * 86_400 + 2 else {
            throw AccountError.reauthenticationRequired
        }
    }
}

/// Keychain-only restart envelope. Cached ACLs admit local profile access after an
/// offline restart; the publication operation always fetches fresh server evidence.
nonisolated struct LegacyAccountStoredSession: Codable, Equatable, Sendable {
    static let maximumBytes = 2_097_152
    let schemaVersion: Int
    let configuration: LegacyAccountConfiguration
    let cookie: LegacyAccountCookie
    let snapshot: AccountSnapshot
    let verifiedAt: Date
    let organizationID: String?
    let workspaceID: String?

    func validate(configuration expected: LegacyAccountConfiguration, now: Date = Date()) throws {
        try configuration.validate()
        guard schemaVersion == 1, configuration == expected,
              verifiedAt.timeIntervalSince1970.isFinite, verifiedAt <= now.addingTimeInterval(60),
              verifiedAt >= cookie.receivedAt.addingTimeInterval(-60),
              (organizationID == nil) == (workspaceID == nil) else { throw AccountError.invalidAccount }
        try cookie.validate(now: now)
        try snapshot.validateLegacy(origin: expected.apiBaseURL)
        if let organizationID, let workspaceID {
            guard snapshot.activeOrganizationID == organizationID,
                  snapshot.contains(organizationID: organizationID, workspaceID: workspaceID) else { throw AccountError.permissionDenied }
        }
    }

    static func decode(_ data: Data, configuration: LegacyAccountConfiguration, now: Date = Date()) throws -> Self {
        guard data.count <= maximumBytes, let value = try? JSONDecoder().decode(Self.self, from: data) else {
            throw AccountError.credentialsUnavailable
        }
        try value.validate(configuration: configuration, now: now)
        return value
    }
}

nonisolated protocol LegacyAccountSessionStoring: Sendable {
    func load() async throws -> LegacyAccountStoredSession?
    func save(_ session: LegacyAccountStoredSession) async throws
    func clear() async throws
}

/// This cookie is separate from OIDC grants and all recording-encryption keys.
/// Queries are device-only, nonsynchronizing and noninteractive, off MainActor.
actor LegacyAccountKeychainStore: LegacyAccountSessionStoring {
    private let configuration: LegacyAccountConfiguration
    private let namespace: String
    nonisolated static func scope(configuration: LegacyAccountConfiguration) -> String {
        let bytes = try! JSONEncoder().encode([configuration.bundleIdentifier, "legacy-session-v1", configuration.apiBaseURL.absoluteString])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    init(configuration: LegacyAccountConfiguration) {
        self.configuration = configuration
        namespace = configuration.bundleIdentifier + ".legacy-sessions." + Self.scope(configuration: configuration)
    }
    private func query() -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: namespace,
            kSecAttrAccount as String: "active-device-session-v1", kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: context]
    }
    private func storedBytes() throws -> Data? {
        var request = query(); request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if let unavailable = ProtectedDataAccessError.keychainFailure(status) { throw unavailable }
        guard status == errSecSuccess, let data = result as? Data, data.count <= LegacyAccountStoredSession.maximumBytes else {
            throw AccountError.credentialsUnavailable
        }
        return data
    }
    func load() throws -> LegacyAccountStoredSession? {
        guard let data = try storedBytes() else { return nil }
        return try LegacyAccountStoredSession.decode(data, configuration: configuration)
    }
    func save(_ session: LegacyAccountStoredSession) throws {
        try session.validate(configuration: configuration)
        let data = try JSONEncoder().encode(session)
        guard data.count <= LegacyAccountStoredSession.maximumBytes else { throw AccountError.credentialsUnavailable }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if let unavailable = ProtectedDataAccessError.keychainFailure(status) { throw unavailable }
        if status == errSecItemNotFound {
            var insert = query(); attributes.forEach { insert[$0.key] = $0.value }
            let inserted = SecItemAdd(insert as CFDictionary, nil)
            if let unavailable = ProtectedDataAccessError.keychainFailure(inserted) { throw unavailable }
            guard inserted == errSecSuccess else { throw AccountError.credentialsUnavailable }
        } else if status != errSecSuccess { throw AccountError.credentialsUnavailable }
        guard try storedBytes() == data else { throw AccountError.credentialsUnavailable }
    }
    func clear() throws {
        let status = SecItemDelete(query() as CFDictionary)
        if let unavailable = ProtectedDataAccessError.keychainFailure(status) { throw unavailable }
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.credentialsUnavailable }
        guard try storedBytes() == nil else { throw AccountError.credentialsUnavailable }
    }
}
