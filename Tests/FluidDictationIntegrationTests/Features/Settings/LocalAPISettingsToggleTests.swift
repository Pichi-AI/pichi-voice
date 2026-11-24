import Foundation
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class LocalAPISettingsToggleTests: XCTestCase {
    func testFreshProfileDefaultsToFalseWithoutPersistingConsent() throws {
        let suite = "LocalAPISettingsToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults, initializeDesktop: false)
        XCTAssertFalse(store.localAPIEnabled)
        XCTAssertNil(defaults.object(forKey: SettingsStore.Keys.localAPIEnabled))
        XCTAssertFalse(PrivateProfileDefaults.sharedDeviceKeys.contains(SettingsStore.Keys.localAPIEnabled))
    }

    func testTogglePersistsRawBooleanAcrossInstances() throws {
        let suite = "LocalAPISettingsToggleTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults, initializeDesktop: false)
        store.localAPIEnabled = true
        XCTAssertTrue(store.localAPIEnabled)
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.Keys.localAPIEnabled))

        XCTAssertTrue(SettingsStore(defaults: defaults, initializeDesktop: false).localAPIEnabled)

        store.localAPIEnabled = false
        XCTAssertFalse(SettingsStore(defaults: defaults, initializeDesktop: false).localAPIEnabled)
    }

    func testConsentDoesNotLeakToAnotherSettingsDomain() throws {
        let firstSuite = "LocalAPISettingsToggleTests-\(UUID().uuidString)"
        let secondSuite = "LocalAPISettingsToggleTests-\(UUID().uuidString)"
        let first = try XCTUnwrap(UserDefaults(suiteName: firstSuite))
        let second = try XCTUnwrap(UserDefaults(suiteName: secondSuite))
        defer {
            first.removePersistentDomain(forName: firstSuite)
            second.removePersistentDomain(forName: secondSuite)
        }

        let firstStore = SettingsStore(defaults: first, initializeDesktop: false)
        let secondStore = SettingsStore(defaults: second, initializeDesktop: false)
        firstStore.localAPIEnabled = true
        XCTAssertFalse(secondStore.localAPIEnabled)
        secondStore.localAPIEnabled = true
        firstStore.localAPIEnabled = false
        XCTAssertTrue(secondStore.localAPIEnabled)
    }
}
