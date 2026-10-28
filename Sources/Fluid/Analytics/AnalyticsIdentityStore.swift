import Foundation

/// Persists the anonymous analytics ID across app updates.
final nonisolated class AnalyticsIdentityStore: @unchecked Sendable {
    private static let profiles = PrivateProfileStoreCache<AnalyticsIdentityStore>()
    static var shared: AnalyticsIdentityStore { profiles.value { AnalyticsIdentityStore(profile: $0) } }

    private let identityLock = NSLock()
    private let profile: PrivateProfileSnapshot
    private let defaults: UserDefaults

    private enum Keys {
        static let anonymousInstallID = "AnalyticsAnonymousInstallID"
        static let firstOpenAt = "AnalyticsFirstOpenAt"
    }

    private init(profile: PrivateProfileSnapshot) {
        self.profile = profile
        self.defaults = PrivateProfileDefaults.bound(to: profile)
    }

    private var isReadable: Bool {
        let current = PrivateProfileStorage.current
        return current.isReadable && current.id == profile.id && current.generation == profile.generation
    }

    nonisolated var anonymousInstallID: String {
        self.identityLock.lock(); defer { self.identityLock.unlock() }
        guard self.isReadable else { return "" }
        if let existing = defaults.string(forKey: Keys.anonymousInstallID), !existing.isEmpty {
            return existing
        }
        let newID = UUID().uuidString
        self.defaults.set(newID, forKey: Keys.anonymousInstallID)
        return newID
    }

    /// Returns whether this is the first recorded launch.
    @discardableResult
    nonisolated func ensureFirstOpenRecorded() -> Bool {
        self.identityLock.lock(); defer { self.identityLock.unlock() }
        guard self.isReadable else { return false }
        if self.defaults.object(forKey: Keys.firstOpenAt) == nil {
            self.defaults.set(Date().timeIntervalSince1970, forKey: Keys.firstOpenAt)
            return true
        }
        return false
    }

    nonisolated var firstOpenAt: Date? {
        guard self.isReadable else { return nil }
        let timestamp = self.defaults.double(forKey: Keys.firstOpenAt)
        return timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
    }
}
