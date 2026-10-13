@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingAgentLocalizationTests: XCTestCase {
    func testEachSkillStateUsesTheCompiledCatalogAndKeepsItsSemanticPresentation() {
        let states: [(FluidServeSkillInstaller.Status?, String, String)] = [
            (nil, "Checking…", "Проверка…"),
            (.agentNotFound, "Not on this Mac", "Нет на этом Mac"),
            (.notInstalled, "Not added", "Навык не добавлен"),
            (.installed, "Skill added", "Навык добавлен"),
            (.needsUpdate, "Needs update", "Нужно обновить"),
            (.foreign, "Another fluidmeet skill is already there", "Здесь уже есть другой навык fluidmeet"),
        ]
        for (status, englishTitle, russianTitle) in states {
            let english = MeetingAgentIntegrations.state(for: status, language: .english)
            let russian = MeetingAgentIntegrations.state(for: status, language: .russian)
            XCTAssertEqual(english.title, englishTitle)
            XCTAssertEqual(russian.title, russianTitle)
            XCTAssertEqual(english.symbol, russian.symbol)
            XCTAssertEqual(english.tone, russian.tone)
        }
        let russianTitles = states.map { MeetingAgentIntegrations.state(for: $0.0, language: .russian).title }
        XCTAssertEqual(Set(russianTitles).count, states.count)
        XCTAssertTrue(russianTitles.last?.contains("fluidmeet") == true, "The skill identifier remains data")
    }

    func testBrowserMeetingLabelsTranslateOnlyTheSurroundingCopy() {
        let service = "Meeting"
        let browser = "Settings"
        XCTAssertEqual(PichiLocalization.format("%@ · in %@", language: .english, bundle: .main,
                                                arguments: [service, browser]), "Meeting · in Settings")
        XCTAssertEqual(PichiLocalization.format("%@ · in %@", language: .russian, bundle: .main,
                                                arguments: [service, browser]), "Meeting · в Settings")
        XCTAssertEqual(service, "Meeting")
        XCTAssertEqual(browser, "Settings")
    }

    func testBuildFailureCopySubstitutesTheBrandAfterLocalizationWithoutTranslatingItsName() {
        let profile = BrandProfile(
            appName: "Settings", meetingName: "Meeting", assistantName: "Assistant",
            tagline: "Fixture", accentLight: "#123456", accentDark: "#654321",
            website: "https://example.invalid", support: "https://example.invalid/support"
        )
        let message = AppBrand.text("This build of FluidVoice cannot share meetings with coding agents.",
                                    profile: profile, language: .russian)
        XCTAssertEqual(message, "В этой сборке Settings нельзя предоставить агентам для программирования доступ к встречам.")
        XCTAssertFalse(message.contains("FluidVoice"))
        XCTAssertFalse(message.contains("Настройки"))
    }

    func testCurrentReleaseHighlightsHaveCompleteRussianCopy() {
        let content = ReleaseHighlightsContent.current(hasPrivateAI: false)
        let keys = [content.title, content.subtitle] + content.features.flatMap {
            [$0.eyebrow, $0.title, $0.detail, $0.action]
        }
        for key in keys {
            let english = PichiLocalization.text(key, language: .english, bundle: .main)
            let russian = PichiLocalization.text(key, language: .russian, bundle: .main)
            XCTAssertEqual(english, key)
            XCTAssertNotEqual(russian, english, "Missing Russian release copy: \(key)")
            XCTAssertFalse(russian.isEmpty)
        }
    }
}
