import CryptoKit
import Foundation

/// Optional successful model checks, separate from legacy provider connection status.
/// Stores only hashes and timestamps, never API keys, URLs, or request contents.
@MainActor
final class ProviderModelVerificationStore {
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    static let defaultsKey = "ProviderModelVerificationsV1"
    static let maximumEntries = 256
    private let defaults: UserDefaults
    private var successes: [String: Double]
    private let profile: PrivateProfileSnapshot?
    private var profileIsCurrent: Bool {
        guard let profile else { return true }
        let current = PrivateProfileStorage.current
        return current.isReadable && current.id == profile.id && current.generation == profile.generation
    }

    init(defaults: UserDefaults = PrivateProfileDefaults.shared) {
        self.defaults = defaults
        self.profile = (defaults as? PrivateProfileDefaults)?.selectedProfile
        let stored = defaults.dictionary(forKey: Self.defaultsKey) as? [String: Double] ?? [:]
        self.successes = Dictionary(uniqueKeysWithValues: stored
            .filter { $0.key.count == 64 && $0.value.isFinite }
            .sorted { $0.value > $1.value }
            .prefix(Self.maximumEntries)
            .map { ($0.key, $0.value) })
    }

    static func identity(providerID: String, baseURL: String, apiKey: String, model: String, connectionOptions: [String: String] = [:]) -> String {
        var fields = [providerID, baseURL, apiKey, model].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !connectionOptions.isEmpty { fields += connectionOptions.keys.sorted().flatMap { [$0, connectionOptions[$0] ?? ""] } }
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func clearInMemory() { self.successes.removeAll() }

    func contains(_ identity: String) -> Bool { self.profileIsCurrent && self.successes[identity] != nil }

    func recordSuccess(_ identity: String, now: Date = Date()) {
        guard self.profileIsCurrent else { return }
        self.successes[identity] = now.timeIntervalSince1970
        while self.successes.count > Self.maximumEntries,
              let oldest = self.successes.min(by: { $0.value < $1.value })?.key
        {
            self.successes.removeValue(forKey: oldest)
        }
        self.defaults.set(self.successes, forKey: Self.defaultsKey)
    }

    func remove(_ identity: String) {
        guard self.profileIsCurrent else { return }
        guard self.successes.removeValue(forKey: identity) != nil else { return }
        self.defaults.set(self.successes, forKey: Self.defaultsKey)
    }
}
