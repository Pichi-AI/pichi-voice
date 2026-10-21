import Foundation
import XCTest
@testable import PichiVoiceMobile

final class MobileLocalizationRenderingTests: XCTestCase {
    private func locationSession() -> MeetingSession {
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "In-room meeting",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone"),
            timestampDefaultTitle: true), startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1))
        session.location = .init(latitude: 37.3317, longitude: -122.0301, horizontalAccuracy: 12,
            capturedAt: session.startedAt, addresses: ["en": "1 Example Street, Example City",
                "ru": "ул. Примерная, 1, Примерск"])
        return session
    }

    @MainActor
    func testNativeMeetingLocationFromControlledSimulator() async throws {
        #if targetEnvironment(simulator)
        guard ProcessInfo.processInfo.environment["PICHI_LOCATION_SIMULATOR_TEST"] == "1" else {
            throw XCTSkip("Opt-in: uses the controlled simulator location and Apple's network geocoder")
        }
        let startedAt = Date()
        let result = await MeetingLocationService().locate(startedAt: startedAt, languages: [.russian, .english])
        let location = try XCTUnwrap(result)
        XCTAssertEqual(location.latitude, 37.3317, accuracy: 0.005)
        XCTAssertEqual(location.longitude, -122.0301, accuracy: 0.005)
        XCTAssertNotNil(location.address(for: .russian))
        XCTAssertNotNil(location.address(for: .english))
        XCTAssertGreaterThanOrEqual(location.capturedAt.timeIntervalSince(startedAt), -5)
        #else
        throw XCTSkip("Physical location requests require separate runtime review")
        #endif
    }

    func testSavedLocationFollowsInterfaceLanguageWithoutChangingTranscriptLanguage() throws {
        let session = locationSession()
        XCTAssertTrue(session.displayTitle(language: .russian).hasPrefix("ул. Примерная, 1, Примерск · "))
        XCTAssertTrue(session.displayTitle(language: .english).hasPrefix("1 Example Street, Example City · "))
        XCTAssertNotEqual(session.displayTitle(language: .english), session.displayTitle(language: .russian))
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(session))
        XCTAssertEqual(restored.location, session.location)
        XCTAssertEqual(restored.languageCode, session.languageCode)
        XCTAssertEqual(restored.title, session.title)
    }

    func testCustomAndLegacyTitlesDoNotBecomeAddresses() throws {
        var session = locationSession()
        session.defaultTitleBase = nil
        session.title = "Мой план Ёё / My plan"
        XCTAssertEqual(session.displayTitle(language: .russian), session.title)
        XCTAssertEqual(session.displayTitle(language: .english), session.title)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        object.removeValue(forKey: "location")
        object.removeValue(forKey: "defaultTitleBase")
        let restored = try JSONDecoder().decode(MeetingSession.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.location)
        XCTAssertEqual(restored.displayTitle(language: .english), session.title)
    }

    func testMissingAddressUsesLocalizedFallbackAndDateWithoutAnotherLanguage() {
        var session = locationSession()
        session.location?.addresses.removeValue(forKey: "ru")
        XCTAssertTrue(session.displayTitle(language: .russian).hasPrefix("Встреча в одной комнате · "))
        XCTAssertFalse(session.displayTitle(language: .russian).contains("Example Street"))
        session.location = nil
        XCTAssertTrue(session.displayTitle(language: .english).hasPrefix("In-room meeting · "))
    }

    func testWarmedCatalogKeepsPreferenceAndExplicitLocaleChangesLive() throws {
        let suite = "MobileLocalizationRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("auto", forKey: "WhisperLanguage")
        for _ in 0..<3 {
            for (language, expected) in [(PichiInterfaceLanguage.russian, "Настройки"), (.english, "Settings")] {
                language.persist(in: defaults)
                let current = PichiInterfaceLanguage.stored(in: defaults)
                XCTAssertEqual(current, language)
                XCTAssertEqual(PichiLocalization.text("Settings", language: current, bundle: .main), expected)
                XCTAssertEqual(PichiLocalization.text("Settings", locale: language.locale), expected)
                XCTAssertEqual(defaults.string(forKey: "WhisperLanguage"), "auto")
            }
        }
        defaults.set("unsupported", forKey: PichiInterfaceLanguage.defaultsKey)
        XCTAssertEqual(PichiInterfaceLanguage.stored(in: defaults), .russian)
        XCTAssertEqual(PichiLocalization.text("missing.semantic.key", language: .russian, bundle: .main,
            defaultValue: "Fallback copy"), "Fallback copy")
        let userText = "Settings [user transcript] Москва https://example.invalid"
        XCTAssertEqual(PichiLocalization.text(userText, language: .russian, bundle: .main), userText)
    }

    func testInstalledResourcePlansSupportConcurrentLanguages() async {
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for index in 0..<16 {
                group.addTask {
                    let language: PichiInterfaceLanguage = index.isMultiple(of: 2) ? .russian : .english
                    let expected = index.isMultiple(of: 2) ? "Настройки" : "Settings"
                    return PichiLocalization.text("Settings", language: language, bundle: .main) == expected
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 16)
        XCTAssertTrue(results.allSatisfy { $0 })
    }
}
