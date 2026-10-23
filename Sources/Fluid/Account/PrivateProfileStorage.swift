import CryptoKit
import Foundation

/// Local storage identity is derived from N1's verified identity, never email or display names.
/// A workspace is part of the storage scope; changing it cannot expose another workspace's data.
nonisolated struct PrivateProfileSnapshot: Equatable, Sendable {
    let id: String
    let context: AccountContext?
    let generation: UUID
    let rootDirectory: URL
    let legacyRootDirectory: URL
    let isReadable: Bool

    var isGuest: Bool { id == "guest" }
    func directory(_ component: String) -> URL {
        rootDirectory.appendingPathComponent(component, isDirectory: true)
    }
    var credentialService: String {
        isGuest ? AppBrand.keychainService : AppBrand.keychainService + ".profile." + id
    }
}

/// The selected filesystem/preferences scope only. N1 owns authentication and account selection.
/// No credentials, consent, queue or network state belongs here.
nonisolated enum PrivateProfileStorage {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var value: PrivateProfileSnapshot
        var acceptsNewWork = true
        var resets: [@Sendable () -> Void] = []
        init() {
            let root = AppBrand.applicationSupportDirectory
            value = .init(id: "guest", context: nil, generation: UUID(), rootDirectory: root,
                legacyRootDirectory: root, isReadable: true)
        }
    }
    private static let state = State()

    static var current: PrivateProfileSnapshot {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.value
    }

    static var acceptsNewWork: Bool {
        state.lock.lock(); defer { state.lock.unlock() }
        return state.acceptsNewWork && state.value.isReadable
    }

    static func closeAdmission() {
        state.lock.lock(); state.acceptsNewWork = false; state.lock.unlock()
    }

    static func isReadable(_ profileID: String) -> Bool {
        let current = self.current
        return current.isReadable && current.id == profileID
    }

    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool {
        let current = self.current
        return current.isReadable && current.id == profile.id && current.generation == profile.generation
    }

    static func proposed(context: AccountContext?, generation: UUID,
                         legacyRootDirectory: URL? = nil) throws -> PrivateProfileSnapshot {
        let legacy = legacyRootDirectory ?? current.legacyRootDirectory
        guard let context else {
            return .init(id: "guest", context: nil, generation: generation,
                rootDirectory: legacy, legacyRootDirectory: legacy, isReadable: true)
        }
        let parts = [AppBrand.storageNamespace, context.identity.issuer, context.identity.subject,
            context.identity.internalUserID, context.organizationID ?? "", context.workspaceID ?? ""]
        guard parts.prefix(4).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }),
              (context.organizationID == nil) == (context.workspaceID == nil),
              context.organizationID?.isEmpty != true, context.workspaceID?.isEmpty != true
        else { throw AccountError.invalidAccount }
        let bytes = try JSONEncoder().encode(parts)
        let key = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return .init(id: key, context: context, generation: generation,
            rootDirectory: legacy.appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(key, isDirectory: true),
            legacyRootDirectory: legacy, isReadable: true)
    }

    /// Composition-owned lifecycle calls this only after joined transition preparation.
    static func select(_ snapshot: PrivateProfileSnapshot) {
        state.lock.lock(); state.value = snapshot; state.acceptsNewWork = snapshot.isReadable; state.lock.unlock()
    }

    /// Reject new private reads immediately while an old recording keeps its admitted writer.
    static func conceal(generation: UUID) {
        state.lock.lock()
        let old = state.value
        state.acceptsNewWork = false
        // Keep the source generation until selection commits, so cleanup retry reaches the
        // exact old cached stores instead of manufacturing fresh instances over unsaved data.
        state.value = .init(id: old.id, context: old.context, generation: old.generation,
            rootDirectory: old.rootDirectory, legacyRootDirectory: old.legacyRootDirectory, isReadable: false)
        state.lock.unlock()
    }

    static func registerCacheReset(_ reset: @escaping @Sendable () -> Void) {
        state.lock.lock(); state.resets.append(reset); state.lock.unlock()
    }

    static func clearStoreCaches() {
        state.lock.lock(); let resets = state.resets; state.lock.unlock()
        for reset in resets { reset() }
    }

    /// Records the helper-visible access boundary without moving or deleting legacy guest data.
    /// The helper must fail closed for account profiles until it supports the same authorization.
    static func persistAccessMarker(_ snapshot: PrivateProfileSnapshot) throws {
        let manager = FileManager.default
        let root = snapshot.legacyRootDirectory.appendingPathComponent("Profiles", isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        let attributes = try manager.attributesOfItem(atPath: root.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AccountError.isolationRequired }
        let data = try JSONEncoder().encode(AccessMarker(schemaVersion: 1, profileID: snapshot.id,
            generation: snapshot.generation, isReadable: snapshot.isReadable))
        let url = root.appendingPathComponent("active-profile-v1.json")
        try data.write(to: url, options: .atomic)
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }

    private struct AccessMarker: Codable {
        let schemaVersion: Int
        let profileID: String
        let generation: UUID
        let isReadable: Bool
    }
}

/// Existing actor stores need one cached instance per immutable root, rather than a mutable root
/// on one actor. Clear these caches only after the lifecycle joins their admitted operations.
nonisolated final class PrivateProfileStoreCache<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Value] = [:]
    init() { PrivateProfileStorage.registerCacheReset { [weak self] in self?.removeAll() } }
    func value(for profile: PrivateProfileSnapshot = PrivateProfileStorage.current,
               create: (PrivateProfileSnapshot) -> Value) -> Value {
        lock.lock(); defer { lock.unlock() }
        let key = profile.id + ":" + profile.generation.uuidString
        if let value = values[key] { return value }
        let value = create(profile); values[key] = value; return value
    }
    func removeAll() { lock.lock(); values.removeAll(); lock.unlock() }
}

/// Main-actor stores retain their existing ObservableObject contract and use the same scope key.
@MainActor enum PrivateProfileObjectCache {
    private static var values: [String: Any] = [:]
    static func value<Value>(key: String, create: () -> Value) -> Value {
        let profile = PrivateProfileStorage.current
        let scopedKey = profile.id + ":" + profile.generation.uuidString + ":" + key
        if let value = values[scopedKey] as? Value { return value }
        let value = create(); values[scopedKey] = value; return value
    }
    static func removeAll() { values.removeAll() }
}
