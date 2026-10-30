import XCTest

/// The parent stages one synthetic default-named long session in an owned simulator.
/// This exercises the ordinary store migration, list and detail without speech models.
final class MobileUniversalTitleUITests: XCTestCase {
    @MainActor
    func testGeneratedTitleSurvivesRelaunchLanguageAndAppearance() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic title migration uses owned simulators only")
        #else
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let identifier = try XCTUnwrap(environment["PICHI_TITLE_FIXTURE_ID"])
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        XCTAssertFalse(revision.isEmpty)
        let app = XCUIApplication()
        defer { app.terminate() }
        for (language, expected) in [("ru", "Обсуждение вопросов"), ("en", "Discussion of questions")] {
            for appearance in ["light", "dark"] {
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                    "-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1",
                    "-MeetingPIIRedactionEnabled", "NO", "-MeetingPIIRedactionRequested", "NO",
                    "-MeetingSpeakerProcessingMode", "afterRecording"]
                app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
                app.launch()
                let row = app.buttons["history.session.\(identifier)"]
                XCTAssertTrue(row.waitForExistence(timeout: 20), "Cold history must load the staged session")
                XCTAssertTrue(row.label.contains(expected), row.label)
                capture(app, "title-list-\(language)-\(appearance)-\(revision.prefix(8))")
                row.tap()
                XCTAssertTrue(app.buttons["transcript.more"].waitForExistence(timeout: 10))
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", expected))
                    .firstMatch.waitForExistence(timeout: 5))
                capture(app, "title-detail-\(language)-\(appearance)-\(revision.prefix(8))")
                app.terminate()
            }
        }
        #endif
    }

    @MainActor
    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
