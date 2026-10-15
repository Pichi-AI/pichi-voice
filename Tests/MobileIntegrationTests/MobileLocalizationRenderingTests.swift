import Foundation
import XCTest
@testable import PichiVoiceMobile

final class MobileLocalizationRenderingTests: XCTestCase {
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
