import Foundation

/// Guest-only adapter for older in-memory UserDefaults doubles. This deliberately
/// does not model account isolation. Dedicated profile suites compile the real defaults facade.
nonisolated enum PrivateProfileDefaults {
    static var shared: UserDefaults { .standard }
    static func bound(to profile: PrivateProfileSnapshot) -> UserDefaults { .standard }
}
