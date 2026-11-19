@testable import FluidVoice_Debug
import AppKit
import SwiftUI
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

    func testUnmatchedReleaseOpensHistoryFromTheNativeSheet() async throws {
        var selected: SidebarItem?
        let content = ReleaseHighlightsContent.current(version: "9.0.0")
        let view = ReleaseHighlightsView(canExplore: true, content: content) { selected = $0?.sidebarItem }
        let host = NSHostingView(rootView: view.appTheme(.light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        func historyButton(in elements: [Any]) -> (any NSAccessibilityProtocol)? {
            for case let element as any NSAccessibilityProtocol in elements {
                if element.accessibilityIdentifier() == "releaseHighlights.history" { return element }
                if let button = historyButton(in: element.accessibilityChildren() ?? []) { return button }
            }
            return nil
        }

        let button = try XCTUnwrap(historyButton(in: host.accessibilityChildren() ?? []))
        XCTAssertTrue(button.accessibilityPerformPress())
        await Task.yield()
        XCTAssertEqual(selected, .changelog)
    }

    func testCurrentReleaseHighlightsHaveCompleteRussianCopy() {
        var keys = ["View release history"]
        for version in ["0.2.3", "0.3.0"] {
            let content = ReleaseHighlightsContent.current(version: version)
            XCTAssertEqual(content.release, version)
            keys += [content.title, content.subtitle]
            keys += content.features.flatMap { [$0.eyebrow, $0.title, $0.detail, $0.action] }
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
