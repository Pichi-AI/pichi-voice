import XCTest

/// Stage only synthetic NavigationMeeting.json copies in a fresh owned simulator.
/// The ordinary root, swipe recognizer, coordinator and persistent store all run.
final class MobileRecordingDeletionUITests: XCTestCase {
    func testShortSwipeButtonFullSwipeAndColdPersistence() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recording deletion fixtures require a task-owned simulator")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_RECORDING_DELETION_FIXTURE_STAGED"] == "1" else {
            throw XCTSkip("Stage four synthetic F0000000-0000-4000-8000-000000000001...004 records and NavigationMeeting.json")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
        let survivor = "history.session.DDD86147-F0B9-4B13-88B5-099B1E0D8BA5"
        for (index, language, appearance) in [(0, "ru", "dark"), (1, "en", "light")] {
            app.launchArguments = ["-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1",
                "-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            let buttonID = String(format: "F0000000-0000-4000-8000-%012d", index * 2 + 1)
            let fullID = String(format: "F0000000-0000-4000-8000-%012d", index * 2 + 2)
            let row = app.buttons["history.session.\(buttonID)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["meeting.start"].isEnabled)
            let before = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).count
            let cell = app.cells.containing(.button, identifier: "history.session.\(buttonID)").firstMatch
            XCTAssertTrue(cell.exists)
            capture("\(language)-\(appearance)-00-before-swipe")
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                .press(forDuration: 0, thenDragTo: cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
            let delete = app.buttons["history.delete.\(buttonID)"]
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "Short swipe reveals Delete")
            XCTAssertEqual(delete.label, language == "ru" ? "Удалить" : "Delete")
            XCTAssertTrue(row.exists, "Revealing the action must not delete")
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).count, before)
            capture("\(language)-\(appearance)-01-delete-revealed")
            delete.tap()
            XCTAssertTrue(row.waitForNonExistence(timeout: 10), "The red button deletes immediately")
            XCTAssertEqual(app.sheets.count, 0, "Swipe deletion must not require confirmation")
            XCTAssertEqual(app.alerts.count, 0)
            let fullRow = app.buttons["history.session.\(fullID)"]
            XCTAssertTrue(fullRow.exists)
            let fullCell = app.cells.containing(.button, identifier: "history.session.\(fullID)").firstMatch
            fullCell.swipeLeft(velocity: .slow)
            XCTAssertTrue(fullRow.waitForNonExistence(timeout: 10), "Full swipe commits deletion")
            XCTAssertTrue(app.buttons[survivor].exists, "Other recordings remain")
            XCTAssertEqual(app.sheets.count, 0)
            XCTAssertEqual(app.alerts.count, 0)
            capture("\(language)-\(appearance)-02-deleted")
            app.terminate()
            app.launch()
            XCTAssertTrue(app.buttons[survivor].waitForExistence(timeout: 15))
            XCTAssertFalse(app.buttons["history.session.\(buttonID)"].exists)
            XCTAssertFalse(app.buttons["history.session.\(fullID)"].exists)
            capture("\(language)-\(appearance)-03-reopened")
            app.terminate()
        }
        #endif
    }

    private func capture(_ step: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "recording-swipe-\(step)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
