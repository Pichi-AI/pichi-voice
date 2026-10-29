import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Recording keys have a separate trusted namespace from login grants and provider keys.
/// Actor isolation keeps Security I/O off MainActor. No key file or synchronizing item exists.
actor MeetingRecordingKeychainStore {
    nonisolated static var defaultNamespace: String {
        (Bundle.main.bundleIdentifier ?? AppBrand.keychainService) + ".recording-encryption.v1"
    }
    private let namespace: String

    init(namespace: String) { self.namespace = namespace }

    func load(profileID: String) throws -> MeetingRecordingCipher? {
        var request = try query(profileID: profileID)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if let unavailable = ProtectedDataAccessError.keychainFailure(status) { throw unavailable }
        guard status == errSecSuccess, let data = result as? Data, data.count == 32 else {
            throw MeetingRecordingCipher.Failure.unavailableKey
        }
        return try MeetingRecordingCipher(profileID: profileID, key: data)
    }

    /// Composition may create only during explicit secure-mode preflight. Missing keys for
    /// existing ciphertext must be treated as unavailable, never as permission to overwrite it.
    func loadOrCreate(profileID: String) throws -> MeetingRecordingCipher {
        if let existing = try load(profileID: profileID) { return existing }
        let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var insert = try query(profileID: profileID)
        insert[kSecValueData as String] = secret
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(insert as CFDictionary, nil)
        if let unavailable = ProtectedDataAccessError.keychainFailure(status) { throw unavailable }
        guard status == errSecSuccess || status == errSecDuplicateItem,
              let verified = try load(profileID: profileID) else { throw MeetingRecordingCipher.Failure.unavailableKey }
        if status == errSecSuccess {
            let expected = try MeetingRecordingCipher(profileID: profileID, key: secret)
            guard verified.hasSameKey(as: expected) else { throw MeetingRecordingCipher.Failure.unavailableKey }
        }
        return verified
    }

    private func query(profileID: String) throws -> [String: Any] {
        guard !namespace.isEmpty, namespace.utf8.count <= 512,
              namespace.rangeOfCharacter(from: .controlCharacters) == nil,
              !profileID.isEmpty, profileID.utf8.count <= 512,
              profileID.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw MeetingRecordingCipher.Failure.invalidConfiguration
        }
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: namespace,
            kSecAttrAccount as String: "recording-key-v1:" + profileID,
            kSecAttrSynchronizable as String: false,
            kSecUseAuthenticationContext as String: authentication]
    }
}
