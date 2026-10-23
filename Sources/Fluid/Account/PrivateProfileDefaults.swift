import Foundation

/// A stable injection point for existing SettingsStore and AppStorage consumers.
/// Account reads use the explicit persistent domain, because UserDefaults suites
/// otherwise search the application domain and expose legacy guest preferences.
nonisolated final class PrivateProfileDefaults: UserDefaults, @unchecked Sendable {
    static let shared = PrivateProfileDefaults()
    static let sharedDeviceKeys: Set<String> = [
        // Installation wizard gates survive sign-in, including an explicit replay.
        // Model, provider, privacy and speech-language choices remain private.
        "OnboardingCompleted", "OnboardingCurrentStep", "ManualOnboardingResetRequested",
        "ManualOnboardingResetRequestedAt", "MobileSetupVersion",
        "PichiInterfaceLanguage", "AppleLanguages", "ThemePreference", "AccentColorOption",
        "ShowInDock", "IntendedDockVisibility", "ShowMainWindowAtLoginLaunch", "LaunchAtStartup",
        "LaunchAtStartupCompatibilityFallback", "AutoUpdateCheckEnabled", "ShowUpdatePopups",
        "UpdatePopupPreferenceRevision", "BetaReleasesEnabled", "UpdateChannelPreferenceRevision",
        "LastUpdateCheckDate", "UpdatePromptSnoozedUntil", "SnoozedUpdateVersion",
        "PreferredInputDeviceUID", "PreferredOutputDeviceUID", "MicrophonePriority",
        "SuppressedMicrophoneUIDs", "MicrophoneSelectionMode", "AppOnlyMicrophoneSelectionMigrationVersion"
    ]

    private let fixedProfile: PrivateProfileSnapshot?
    private let guestDefaults: UserDefaults
    private let lock = NSRecursiveLock()
    private var registered: [String: Any] = [:]

    init(profile: PrivateProfileSnapshot? = nil, guestDefaults: UserDefaults = .standard) {
        self.fixedProfile = profile
        self.guestDefaults = guestDefaults
        // The facade's own domain is never a source of persisted preferences.
        super.init(suiteName: nil)!
    }

    static func bound(to profile: PrivateProfileSnapshot) -> UserDefaults {
        let bound = PrivateProfileDefaults(profile: profile)
        bound.registered = shared.lock.withLock { shared.registered }
        return bound
    }

    var selectedProfile: PrivateProfileSnapshot { self.profile }

    private var profile: PrivateProfileSnapshot { self.fixedProfile ?? PrivateProfileStorage.current }
    private func readable(_ profile: PrivateProfileSnapshot) -> Bool {
        let selected = PrivateProfileStorage.current
        return profile.isReadable && selected.isReadable && selected.id == profile.id && selected.generation == profile.generation
    }
    private func domain(_ profile: PrivateProfileSnapshot) -> String {
        AppBrand.storageNamespace + ".private-profile." + profile.id
    }
    private func suite(_ profile: PrivateProfileSnapshot) -> UserDefaults {
        UserDefaults(suiteName: self.domain(profile))!
    }

    override func object(forKey key: String) -> Any? {
        if Self.sharedDeviceKeys.contains(key) { return self.guestDefaults.object(forKey: key) }
        let profile = self.profile
        guard self.readable(profile) else { return nil }
        if profile.isGuest { return self.guestDefaults.object(forKey: key) }
        // Do not call suite.object(forKey:), which searches the guest app domain.
        let value = self.suite(profile).persistentDomain(forName: self.domain(profile))?[key]
            ?? self.lock.withLock { self.registered[key] }
        return self.readable(profile) ? value : nil
    }
    override func set(_ value: Any?, forKey key: String) {
        if Self.sharedDeviceKeys.contains(key) { self.guestDefaults.set(value, forKey: key); return }
        let profile = self.profile
        guard self.readable(profile) else { return }
        let destination = profile.isGuest ? self.guestDefaults : self.suite(profile)
        destination.set(value, forKey: key)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: self)
    }
    override func removeObject(forKey key: String) { self.set(nil, forKey: key) }
    override func register(defaults registrationDictionary: [String: Any]) {
        self.lock.withLock { self.registered.merge(registrationDictionary) { _, new in new } }
        // Guest behavior retains the existing application registration semantics.
        self.guestDefaults.register(defaults: registrationDictionary)
    }
    override func string(forKey key: String) -> String? {
        if let value = self.object(forKey: key) as? String { return value }
        return (self.object(forKey: key) as? NSNumber)?.stringValue
    }
    override func array(forKey key: String) -> [Any]? { self.object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { self.object(forKey: key) as? [String: Any] }
    override func data(forKey key: String) -> Data? { self.object(forKey: key) as? Data }
    override func stringArray(forKey key: String) -> [String]? { self.object(forKey: key) as? [String] }
    override func bool(forKey key: String) -> Bool { (self.object(forKey: key) as? NSNumber)?.boolValue ?? (self.object(forKey: key) as? NSString)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (self.object(forKey: key) as? NSNumber)?.intValue ?? (self.object(forKey: key) as? NSString)?.integerValue ?? 0 }
    override func float(forKey key: String) -> Float { (self.object(forKey: key) as? NSNumber)?.floatValue ?? (self.object(forKey: key) as? NSString)?.floatValue ?? 0 }
    override func double(forKey key: String) -> Double { (self.object(forKey: key) as? NSNumber)?.doubleValue ?? (self.object(forKey: key) as? NSString)?.doubleValue ?? 0 }
    override func url(forKey key: String) -> URL? {
        if let value = self.object(forKey: key) as? URL { return value }
        if let path = self.string(forKey: key) { return URL(fileURLWithPath: path) }
        return nil
    }
    override func set(_ value: Bool, forKey key: String) { self.set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Int, forKey key: String) { self.set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Float, forKey key: String) { self.set(NSNumber(value: value), forKey: key) }
    override func set(_ value: Double, forKey key: String) { self.set(NSNumber(value: value), forKey: key) }
    override func set(_ url: URL?, forKey key: String) { self.set(url?.path, forKey: key) }
    override func dictionaryRepresentation() -> [String: Any] {
        let profile = self.profile
        var values = self.guestDefaults.dictionaryRepresentation().filter { Self.sharedDeviceKeys.contains($0.key) }
        guard self.readable(profile) else { return values }
        let privateValues = profile.isGuest ? self.guestDefaults.dictionaryRepresentation()
            : self.lock.withLock { self.registered }.merging(self.suite(profile).persistentDomain(forName: self.domain(profile)) ?? [:]) { _, saved in saved }
        values.merge(privateValues.filter { !Self.sharedDeviceKeys.contains($0.key) }) { _, new in new }
        return values
    }
    override func synchronize() -> Bool {
        let profile = self.profile
        guard self.readable(profile) else { return false }
        return (profile.isGuest ? self.guestDefaults : self.suite(profile)).synchronize()
    }
}
