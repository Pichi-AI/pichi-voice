import Foundation
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class LocalAPISettingsToggleTests: XCTestCase {
    func testFreshInstallDefaultsToFalse() {
        self.withRestoredLocalAPISetting {
            UserDefaults.standard.removeObject(forKey: SettingsStore.Keys.localAPIEnabled)
            XCTAssertFalse(SettingsStore.shared.localAPIEnabled)
            XCTAssertNil(UserDefaults.standard.object(forKey: SettingsStore.Keys.localAPIEnabled))
        }
    }

    func testTogglePersistsRawBooleanAcrossInstances() throws {
        let suite = "LocalAPISettingsToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.localAPIEnabled = true
        XCTAssertTrue(store.localAPIEnabled)
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.Keys.localAPIEnabled))

        XCTAssertTrue(SettingsStore(defaults: defaults).localAPIEnabled)

        store.localAPIEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults).localAPIEnabled)
    }

    private func withRestoredLocalAPISetting(_ body: () -> Void) {
        _ = SettingsStore.shared
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: SettingsStore.Keys.localAPIEnabled)
        defer {
            if let original {
                defaults.set(original, forKey: SettingsStore.Keys.localAPIEnabled)
            } else {
                defaults.removeObject(forKey: SettingsStore.Keys.localAPIEnabled)
            }
        }
        body()
    }
}
