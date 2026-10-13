import Foundation
import Security
import LocalAuthentication

enum KeychainServiceError: Error, LocalizedError {
    case invalidData
    case unavailable
    case readbackMismatch
    case unhandled(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Failed to convert key data."
        case .unavailable:
            return PichiLocalization.text("Provider credentials are unavailable. Open API key settings to retry.")
        case .readbackMismatch:
            return PichiLocalization.text("Saved API keys could not be verified in Keychain.")
        case let .unhandled(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "\(message) (OSStatus: \(status))"
            }
            return "Unhandled Keychain error (OSStatus: \(status))"
        }
    }
}

/// Lightweight helper for storing provider API keys in the system Keychain.
/// Keys are stored as generic passwords scoped to the FluidVoice service.
final class KeychainService: @unchecked Sendable {
    static let shared = KeychainService()

    private struct TestingBackend {
        let load: () throws -> [String: String]
        let save: ([String: String]) throws -> Void
        let legacyLoad: () throws -> [String: String]
        let legacyRemove: ([String]) throws -> Void
        let access: (Bool) -> Void
    }

    enum Readiness: Equatable {
        case pending
        case loaded
        case unavailable
    }

    private enum KeyCache {
        case unloaded
        case loaded([String: String])
    }

    private let service = AppBrand.keychainService
    private let account = AppBrand.keychainAccount
    private let cacheLock = NSLock()
    private let ioLock = NSRecursiveLock()
    private var keyCache = KeyCache.unloaded
    private var readinessState = Readiness.pending
    private var backgroundLoadPending = false
    private var pendingUserActions = 0
    // All admitted Security operations are owned by this serial worker. Cache
    // reads take only cacheLock, even while Security is waiting for the OS.
    private let worker = DispatchQueue(label: "provider-credential-storage", qos: .utility)
    private let testingBackend: TestingBackend?

    private init() {
        // The ASR baseline host must never touch credentials; any transitive
        // `SettingsStore.shared` initialization reaches this stored-property singleton.
        #if PICHI_CREDENTIAL_TEST_BACKEND_ONLY
        fatalError("Credential regression must use an injected backend")
        #endif
        #if FLUID_ASR_BASELINE
        fatalError("KeychainService is unavailable in the ASR baseline host")
        #endif
        self.testingBackend = nil
    }

    init(
        testingLoad: @escaping () throws -> [String: String],
        testingSave: @escaping ([String: String]) throws -> Void,
        testingLegacyLoad: @escaping () throws -> [String: String] = { [:] },
        testingLegacyRemove: @escaping ([String]) throws -> Void = { _ in },
        testingAccess: @escaping (Bool) -> Void = { _ in }
    ) {
        self.testingBackend = TestingBackend(
            load: testingLoad, save: testingSave, legacyLoad: testingLegacyLoad,
            legacyRemove: testingLegacyRemove, access: testingAccess
        )
    }

    // MARK: - Public API

    var readiness: Readiness {
        self.cacheLock.withLock { self.readinessState }
    }

    /// A missing snapshot is unknown, never an authoritative empty aggregate.
    var cachedKeys: [String: String]? {
        guard case let .loaded(keys) = self.cachedState() else { return nil }
        return keys
    }

    /// One atomic snapshot for inference admission. Refresh failures may retain
    /// cached display values, but must not present them as loaded credentials.
    var loadedKeys: [String: String]? {
        self.cacheLock.withLock {
            guard self.readinessState == .loaded, case let .loaded(keys) = self.keyCache else { return nil }
            return keys
        }
    }

    /// Coalesces startup/activation refreshes without creating waiting threads.
    /// The immutable additions are collected after SettingsStore initialization.
    @discardableResult
    func loadInBackground(
        migrating additions: [String: String] = [:],
        completion: @escaping @Sendable (Result<[String: String], Error>) -> Void
    ) -> Bool {
        let admitted = self.cacheLock.withLock {
            guard !self.backgroundLoadPending else { return false }
            self.backgroundLoadPending = true
            self.readinessState = .pending
            return true
        }
        guard admitted else { return false }
        self.worker.async {
            let result = Result { try self.loadAndMigrate(additions, interactive: false) }
            self.cacheLock.withLock {
                self.backgroundLoadPending = false
                self.readinessState = self.pendingUserActions > 0 ? .pending
                    : ((try? result.get()) == nil ? .unavailable : .loaded)
            }
            completion(result)
        }
        return true
    }

    /// Only an explicit credential action permits normal OS authentication.
    func loadForUserAction(migrating additions: [String: String] = [:]) async throws -> [String: String] {
        try await self.onWorker { try self.loadAndMigrate(additions, interactive: true) }
    }

    /// Apply edits to a fresh aggregate. An empty cold UI cache cannot replace
    /// credentials it has never observed; unrelated external edits are retained.
    func saveForUserAction(
        _ values: [String: String], replacing knownValues: [String: String],
        removing providerIDs: [String] = [], migrating additions: [String: String] = [:]
    ) async throws -> (keys: [String: String], migratedKeys: [String: String]) {
        try await self.onWorker {
            self.ioLock.lock()
            defer { self.ioLock.unlock() }
            let migrated = try self.loadAndMigrate(additions, interactive: true)
            var current = migrated
            for id in knownValues.keys where values[id] == nil { current.removeValue(forKey: id) }
            for (id, value) in values where knownValues[id] != value { current[id] = value }
            for id in providerIDs { current.removeValue(forKey: id) }
            try self.saveAndVerify(current, interactive: true)
            return (current, migrated)
        }
    }

    private func onWorker<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        self.cacheLock.withLock {
            self.pendingUserActions += 1
            self.readinessState = .pending
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.worker.async {
                let result = Result(catching: operation)
                self.cacheLock.withLock {
                    self.pendingUserActions -= 1
                    self.readinessState = self.backgroundLoadPending || self.pendingUserActions > 0 ? .pending
                        : ((try? result.get()) == nil ? .unavailable : .loaded)
                }
                continuation.resume(with: result)
            }
        }
    }

    private func loadAndMigrate(_ additions: [String: String], interactive: Bool) throws -> [String: String] {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        // A failed aggregate or legacy read aborts before any write or cleanup.
        var keys = try self.readStoredKeys(interactive: interactive)
        let legacy = try self.legacyProviderEntries(interactive: interactive)
        let normalizedLegacy = legacy.reduce(into: [String: String]()) { values, pair in
            let key = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty { values[pair.key] = key }
        }
        keys.merge(normalizedLegacy) { _, migrated in migrated }
        keys.merge(additions) { _, migrated in migrated }
        if !legacy.isEmpty || !additions.isEmpty {
            try self.saveAndVerify(keys, interactive: interactive)
            try self.removeLegacyEntries(providerIDs: Array(legacy.keys), interactive: interactive)
        } else {
            self.setCachedKeys(keys)
        }
        return keys
    }

    private func saveAndVerify(_ keys: [String: String], interactive: Bool) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        try self.saveStoredKeys(keys, interactive: interactive)
        guard try self.readStoredKeys(interactive: interactive) == keys else {
            throw KeychainServiceError.readbackMismatch
        }
        self.setCachedKeys(keys)
    }

    func storeKey(_ key: String, for providerID: String) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mutations are rare and must merge against the latest aggregate in
        // case another app instance or Keychain Access changed it.
        var keys = try self.loadStoredKeys(forceRefresh: true)
        keys[providerID] = trimmed
        try self.saveAndVerify(keys, interactive: true)
    }

    func fetchKey(for providerID: String) throws -> String? {
        let keys = try loadStoredKeys()
        return keys[providerID]
    }

    func deleteKey(for providerID: String) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        var keys = try self.loadStoredKeys(forceRefresh: true)
        guard keys.removeValue(forKey: providerID) != nil else { return }
        try self.saveAndVerify(keys, interactive: true)
    }

    func containsKey(for providerID: String) -> Bool {
        guard let keys = try? loadStoredKeys() else { return false }
        return keys[providerID] != nil
    }

    func allProviderIDs() throws -> [String] {
        return try self.loadStoredKeys().keys.sorted()
    }

    func fetchAllKeys() throws -> [String: String] {
        try self.loadStoredKeys()
    }

    /// Refreshes the process cache after the user returns to FluidVoice, so
    /// Keychain Access or another app instance cannot leave credentials stale.
    /// Callers should run this away from the main thread because Keychain I/O
    /// may wait for the login keychain to become available.
    func refreshCachedKeys() throws {
        _ = try self.loadStoredKeys(forceRefresh: true)
    }

    func storeAllKeys(_ values: [String: String]) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        // Never replace an aggregate whose authoritative read failed.
        _ = try self.loadStoredKeys(forceRefresh: true)
        try self.saveAndVerify(values, interactive: true)
    }

    func legacyProviderEntries(interactive: Bool = true) throws -> [String: String] {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        if let testingBackend { testingBackend.access(interactive); return try testingBackend.legacyLoad() }
        guard !Thread.isMainThread else { throw KeychainServiceError.unavailable }
        var result: [String: String] = [:]
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        self.applyAuthenticationPolicy(to: &query, interactive: interactive)
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)

        switch status {
        case errSecSuccess:
            guard let attributesArray = items as? [[String: Any]] else { throw KeychainServiceError.invalidData }
            for attributes in attributesArray {
                guard let providerID = attributes[kSecAttrAccount as String] as? String,
                      providerID != account
                else {
                    continue
                }

                var dataQuery = self.legacyQuery(for: providerID)
                dataQuery[kSecReturnData as String] = true
                dataQuery[kSecMatchLimit as String] = kSecMatchLimitOne

                self.applyAuthenticationPolicy(to: &dataQuery, interactive: interactive)
                var dataItem: CFTypeRef?
                let dataStatus = SecItemCopyMatching(dataQuery as CFDictionary, &dataItem)
                guard dataStatus == errSecSuccess else {
                    if dataStatus == errSecItemNotFound { continue }
                    throw KeychainServiceError.unhandled(dataStatus)
                }
                guard let data = dataItem as? Data,
                      let key = String(data: data, encoding: .utf8)
                else {
                    throw KeychainServiceError.invalidData
                }
                result[providerID] = key
            }
            return result
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    func removeLegacyEntries(providerIDs: [String] = [], interactive: Bool = true) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        // An explicit empty migration set must never enumerate/delete unrelated entries.
        guard !providerIDs.isEmpty else { return }
        if let testingBackend { testingBackend.access(interactive); try testingBackend.legacyRemove(providerIDs); return }
        guard !Thread.isMainThread else { throw KeychainServiceError.unavailable }
        let targets: [String]
        if !providerIDs.isEmpty {
            targets = providerIDs
        } else {
            targets = try Array((self.legacyProviderEntries()).keys)
        }

        for providerID in targets {
            var query = self.legacyQuery(for: providerID)
            self.applyAuthenticationPolicy(to: &query, interactive: interactive)
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainServiceError.unhandled(status)
            }
        }
    }

    // MARK: - Private helpers

    private func loadStoredKeys(forceRefresh: Bool = false) throws -> [String: String] {
        if !forceRefresh, case let .loaded(keys) = self.cachedState() { return keys }

        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        // A concurrent cold read may have populated the cache while this caller
        // waited for I/O ownership. Forced refreshes intentionally bypass it.
        if !forceRefresh, case let .loaded(keys) = self.cachedState() { return keys }

        let keys = try self.readStoredKeys()
        self.setCachedKeys(keys)
        return keys
    }

    private func readStoredKeys(interactive: Bool = true) throws -> [String: String] {
        if let testingBackend {
            testingBackend.access(interactive)
            return try testingBackend.load()
        }
        guard !Thread.isMainThread else { throw KeychainServiceError.unavailable }

        var query = self.aggregatedQuery()
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        self.applyAuthenticationPolicy(to: &query, interactive: interactive)
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw KeychainServiceError.invalidData
            }
            guard !data.isEmpty else { throw KeychainServiceError.invalidData }
            do {
                return try JSONDecoder().decode([String: String].self, from: data)
            } catch {
                throw KeychainServiceError.invalidData
            }
        case errSecItemNotFound:
            return [:]
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    private func saveStoredKeys(_ keys: [String: String], interactive: Bool) throws {
        self.ioLock.lock()
        defer { self.ioLock.unlock() }
        if let testingBackend {
            testingBackend.access(interactive)
            try testingBackend.save(keys)
            return
        }

        guard !Thread.isMainThread else { throw KeychainServiceError.unavailable }
        let data = try JSONEncoder().encode(keys)

        var attributes = self.aggregatedQuery()
        attributes[kSecValueData as String] = data

        self.applyAuthenticationPolicy(to: &attributes, interactive: interactive)
        let status = SecItemAdd(attributes as CFDictionary, nil)

        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data,
            ]
            var updateQuery = self.aggregatedQuery()
            self.applyAuthenticationPolicy(to: &updateQuery, interactive: interactive)
            let updateStatus = SecItemUpdate(
                updateQuery as CFDictionary,
                updateAttributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainServiceError.unhandled(updateStatus)
            }
        default:
            throw KeychainServiceError.unhandled(status)
        }
    }

    private func cachedState() -> KeyCache {
        self.cacheLock.lock()
        defer { self.cacheLock.unlock() }
        return self.keyCache
    }

    private func setCachedKeys(_ keys: [String: String]) {
        self.cacheLock.lock()
        self.keyCache = .loaded(keys)
        self.readinessState = self.backgroundLoadPending || self.pendingUserActions > 0 ? .pending : .loaded
        self.cacheLock.unlock()
    }

    private func applyAuthenticationPolicy(to query: inout [String: Any], interactive: Bool) {
        guard !interactive else { return }
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        // Keep the legacy login-keychain query scoped and fail closed. Skip would
        // hide protected items as absent, risking an empty-aggregate overwrite.
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
    }

    private func aggregatedQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
        ]
    }

    private func legacyQuery(for providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: providerID,
        ]
    }
}
