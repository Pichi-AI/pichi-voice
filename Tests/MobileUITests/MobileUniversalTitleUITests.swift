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
        guard let identifier = environment["PICHI_TITLE_FIXTURE_ID"], !identifier.isEmpty else {
            throw XCTSkip("Stage an owned synthetic long recording and provide PICHI_TITLE_FIXTURE_ID")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let englishIdentifier = try XCTUnwrap(environment["PICHI_TITLE_ENGLISH_FIXTURE_ID"])
        XCTAssertFalse(revision.isEmpty)
        let app = XCUIApplication()
        defer { app.terminate() }
        for language in ["ru", "en"] {
            for appearance in ["light", "dark"] {
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                    "-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1",
                    "-MeetingPIIRedactionEnabled", "NO", "-MeetingPIIRedactionRequested", "NO",
                    "-MeetingSpeakerProcessingMode", "afterRecording"]
                app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
                app.launch()
                let row = app.buttons["history.session.\(identifier)"]
                XCTAssertTrue(row.waitForExistence(timeout: 20), "Cold history must load the staged session")
                let expected = "Обсуждение вопросов"
                let title = app.staticTexts["history.title.\(identifier)"]
                XCTAssertTrue(title.waitForExistence(timeout: 5))
                XCTAssertEqual(title.label, expected, "A Russian recording keeps a bare Russian title in either interface")
                let englishTitle = app.staticTexts["history.title.\(englishIdentifier)"]
                XCTAssertTrue(englishTitle.waitForExistence(timeout: 5))
                XCTAssertEqual(englishTitle.label, "Discussion of questions", "The second recording follows its English speech")
                let start = Date(timeIntervalSince1970: 1_700_000_000).formatted(
                    Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: language)))
                let metadata = app.staticTexts["history.metadata.\(identifier)"]
                XCTAssertTrue(metadata.exists)
                XCTAssertTrue(metadata.label.contains(start), "The visible metadata must include start date and clock time")
                let expectedPlace = language == "ru" ? "ул. Примерная, 1, Примерск" : "1 Example Street, Example City"
                let place = app.descendants(matching: .any).matching(identifier: "history.location.\(identifier)").firstMatch
                XCTAssertTrue(place.exists, "The saved place stays visible alongside its semantic title")
                XCTAssertEqual(place.label, expectedPlace)
                XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "history.location.\(englishIdentifier)").firstMatch.exists,
                               "A recording without geolocation must not inherit another recording's place")
                capture(app, "title-list-\(language)-\(appearance)-\(revision.prefix(8))")
                row.tap()
                XCTAssertTrue(app.buttons["transcript.more"].waitForExistence(timeout: 10))
                let detailTitle = app.staticTexts["transcript.title"]
                XCTAssertTrue(detailTitle.waitForExistence(timeout: 5))
                XCTAssertEqual(detailTitle.label, expected, "No date or time is appended to the recording name")
                XCTAssertEqual(app.staticTexts["transcript.metadata.start"].label, start)
                XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "transcript.location").firstMatch.label, expectedPlace)
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
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "unverified-revision"
        reviewNativeScreenshotIfRequested(name, namePrefix: "universal-title", revision: revision)
    }
}
