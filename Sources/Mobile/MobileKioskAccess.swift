import Combine
import CommonCrypto
import Foundation
import LocalAuthentication
import Security

/// The kiosk credential is separate from provider API keys and from imported appearance.
/// One protected item commits the password verifier, access mode and retry budget together.
nonisolated protocol MobileKioskCredentialStoring: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

private nonisolated struct MobileKioskKeychainStore: MobileKioskCredentialStoring {
    private var query: [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "invalid-installation") + ".local-kiosk",
         kSecAttrAccount as String: "administrator",
         kSecUseAuthenticationContext as String: context]
    }

    func read() throws -> Data? {
        guard Bundle.main.bundleIdentifier != nil else { throw MobileKioskAccess.AccessError.unavailable }
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw MobileKioskAccess.AccessError.unavailable
        }
        return data
    }

    func write(_ data: Data) throws {
        guard Bundle.main.bundleIdentifier != nil else { throw MobileKioskAccess.AccessError.unavailable }
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw MobileKioskAccess.AccessError.unavailable
            }
        } else if status != errSecSuccess {
            throw MobileKioskAccess.AccessError.unavailable
        }
        guard try read() == data else { throw MobileKioskAccess.AccessError.unavailable }
    }
}

@MainActor
final class MobileKioskAccess: ObservableObject {
    static let shared = MobileKioskAccess()

    nonisolated enum AccessError: Error, LocalizedError, Equatable {
        case invalidPassword, confirmationMismatch, incorrectPassword, temporarilyLocked, unavailable, busy

        var errorDescription: String? {
            switch self {
            case .invalidPassword: PichiLocalization.text("Use a password with 6 to 128 characters.")
            case .confirmationMismatch: PichiLocalization.text("The passwords do not match.")
            case .incorrectPassword: PichiLocalization.text("The administrator password is incorrect.")
            case .temporarilyLocked: PichiLocalization.text("Too many attempts. Wait one minute before trying again.")
            case .unavailable: PichiLocalization.text("Kiosk security is unavailable. Access remains locked. Try again after unlocking the device.")
            case .busy: PichiLocalization.text("A password check is already in progress.")
            }
        }
    }

    private nonisolated struct Credential: Codable, Sendable {
        var version = 1
        var salt: Data
        var verifier: Data
        var iterations: UInt32 = 600_000
        var enabled: Bool
        // Missing in older credentials. Only an explicit new entry may offer setup.
        var voiceWelcomePending: Bool?
        var failedAttempts = 0
        var retryAfter: Date?

        func validate() throws {
            guard version == 1, salt.count == 32, verifier.count == 32, iterations == 600_000,
                  (0...5).contains(failedAttempts),
                  (failedAttempts == 5) == (retryAfter != nil),
                  retryAfter.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
                throw AccessError.unavailable
            }
        }
    }

    @Published private(set) var isEnabled = true
    @Published private(set) var hasPassword = true
    @Published private(set) var isAvailable = false
    @Published private(set) var isBusy = false
    private let storage: any MobileKioskCredentialStoring
    private let now: () -> Date

    init(storage: (any MobileKioskCredentialStoring)? = nil, now: @escaping () -> Date = Date.init) {
        self.storage = storage ?? MobileKioskKeychainStore()
        self.now = now
        do { publish(try load()) }
        catch { lockForUnavailableStorage() }
    }

    /// The first enable establishes the password. Later enables require that same password.
    /// Password checks run off the main actor; the operation guard prevents interleaved writes.
    func enable(password: String, confirmation: String? = nil) async throws {
        guard !isBusy else { throw AccessError.busy }
        isBusy = true
        defer { isBusy = false }
        let credential: Credential
        if let stored = try loadOrLock() {
            var enabled = try await authenticate(password: password, credential: stored)
            if !stored.enabled { enabled.voiceWelcomePending = true }
            enabled.enabled = true
            credential = enabled
        } else {
            guard (6...128).contains(password.count), password.utf8.count <= 512 else {
                throw AccessError.invalidPassword
            }
            guard confirmation == password else { throw AccessError.confirmationMismatch }
            var salt = Data(count: 32)
            let status = salt.withUnsafeMutableBytes { bytes in
                SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
            }
            guard status == errSecSuccess else { throw AccessError.unavailable }
            let verifier = try await Self.derive(password: password, salt: salt)
            credential = Credential(salt: salt, verifier: verifier, enabled: true, voiceWelcomePending: true)
        }
        try persistOrLock(credential)
    }

    /// A verified exit disables kiosk mode durably. Relaunching cannot reset a failed attempt.
    func unlock(password: String) async throws {
        guard !isBusy else { throw AccessError.busy }
        isBusy = true
        defer { isBusy = false }
        guard let stored = try loadOrLock() else { throw AccessError.unavailable }
        var credential = try await authenticate(password: password, credential: stored)
        credential.enabled = false
        credential.voiceWelcomePending = false
        try persistOrLock(credential)
    }

    /// Claims this entry's one opportunity before the caller checks whether a voice exists.
    /// Consuming the protected marker first prevents an app relaunch from reopening setup.
    /// The synchronous main-actor transaction is shared by all application scenes.
    func claimVoiceWelcome() throws -> Bool {
        guard !isBusy else { throw AccessError.busy }
        guard var credential = try loadOrLock(), credential.enabled,
              credential.voiceWelcomePending == true else { return false }
        credential.voiceWelcomePending = false
        try persistOrLock(credential)
        return true
    }

    private func authenticate(password: String, credential stored: Credential) async throws -> Credential {
        var credential = stored
        if let retryAfter = credential.retryAfter {
            guard now() >= retryAfter else { throw AccessError.temporarilyLocked }
            credential.failedAttempts = 0
            credential.retryAfter = nil
        }
        // Reject oversized entries before allocating work for PBKDF2, but still charge an attempt.
        let candidate = password.count <= 128 && password.utf8.count <= 512
            ? try await Self.derive(password: password, salt: credential.salt) : Data()
        guard Self.equal(candidate, credential.verifier) else {
            credential.failedAttempts += 1
            if credential.failedAttempts == 5 { credential.retryAfter = now().addingTimeInterval(60) }
            try persistOrLock(credential)
            throw credential.retryAfter == nil ? AccessError.incorrectPassword : AccessError.temporarilyLocked
        }
        credential.failedAttempts = 0
        credential.retryAfter = nil
        return credential
    }

    private func load() throws -> Credential? {
        guard let data = try storage.read() else { return nil }
        guard data.count <= 16_384 else { throw AccessError.unavailable }
        let credential = try JSONDecoder().decode(Credential.self, from: data)
        try credential.validate()
        return credential
    }

    private func loadOrLock() throws -> Credential? {
        do {
            let credential = try load()
            publish(credential)
            return credential
        } catch {
            lockForUnavailableStorage()
            throw AccessError.unavailable
        }
    }

    private func persistOrLock(_ credential: Credential) throws {
        do {
            try credential.validate()
            try storage.write(JSONEncoder().encode(credential))
            publish(credential)
        } catch {
            lockForUnavailableStorage()
            throw AccessError.unavailable
        }
    }

    private func publish(_ credential: Credential?) {
        isEnabled = credential?.enabled ?? false
        hasPassword = credential != nil
        isAvailable = true
    }

    private func lockForUnavailableStorage() {
        isEnabled = true
        hasPassword = true
        isAvailable = false
    }

    private nonisolated static func equal(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }

    private nonisolated static func derive(password: String, salt: Data) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let passwordBytes = Array(password.utf8)
            var output = [UInt8](repeating: 0, count: 32)
            let status = output.withUnsafeMutableBufferPointer { result in
                passwordBytes.withUnsafeBytes { password in
                    salt.withUnsafeBytes { salt in
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                            password.baseAddress?.assumingMemoryBound(to: Int8.self), password.count,
                            salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 600_000, result.baseAddress, result.count)
                    }
                }
            }
            guard status == kCCSuccess else { throw AccessError.unavailable }
            return Data(output)
        }.value
    }
}
