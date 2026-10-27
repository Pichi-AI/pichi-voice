import XCTest
import UIKit

/// The actual native settings with disposable synthetic account/store inputs.
/// No server login, recording, deletion of user data or release readiness is implied.
final class MobileAutomaticSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Automatic settings visual review requires an owned simulator")
        #else
        continueAfterFailure = false
        #endif
    }

    func testAutomaticDeliverySettingsInBothLanguagesAndThemes() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        for (language, appearance) in [("en", "light"), ("en", "dark"), ("ru", "light"), ("ru", "dark")] {
            app.launchEnvironment["PICHI_UI_AUTOMATIC_SETTINGS_REVIEW"] = "1"
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            let prefix = "automatic-\(language)-\(appearance)"
            XCTAssertTrue(app.descendants(matching: .any)["automatic.review.ready"].firstMatch.waitForExistence(timeout: 15))
            XCTAssertFalse(app.descendants(matching: .any)["automatic.review.failed"].firstMatch.exists)
            XCTAssertTrue(app.buttons["account.workspace.17.9"].waitForExistence(timeout: 5))
            capture(prefix + "-account")
            let automatic = app.switches["cloud.sync.toggle"]
            let deletion = app.switches["cloud.automatic.deleteLocal"]
            expose(automatic, in: app, step: prefix + "-automatic")
            expose(deletion, in: app, step: prefix + "-retention")
            XCTAssertEqual(automatic.value as? String, "0")
            XCTAssertEqual(deletion.value as? String, "0")
            XCTAssertFalse(deletion.isEnabled)
            capture(prefix + "-off")
            tap(automatic)
            waitForValue(automatic, "1")
            XCTAssertTrue(deletion.isEnabled)
            capture(prefix + "-automatic-on")
            tap(deletion)
            waitForValue(deletion, "1")
            XCTAssertFalse(app.descendants(matching: .any)["cloud.sync.error"].firstMatch.exists)
            capture(prefix + "-retention-on")
            tap(automatic)
            waitForValue(automatic, "0")
            XCTAssertEqual(deletion.value as? String, "1", "OFF pauses delivery without silently changing the future retention preference")
            XCTAssertFalse(deletion.isEnabled)
            capture(prefix + "-paused")
            let close = app.buttons["automatic.review.close"]
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(app.descendants(matching: .any)["automatic.review.closed"].firstMatch.waitForExistence(timeout: 10),
                "Fixture must join owned work and remove its temporary root before app termination")
            capture(prefix + "-closed")
            app.terminate()
        }
    }

    private func expose(_ element: XCUIElement, in app: XCUIApplication, step: String) {
        let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        for index in 0..<7 where !element.isHittable {
            XCTAssertTrue(scroll.exists && scroll.isHittable)
            scroll.swipeUp()
            capture(step + "-scroll-\(index)")
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func tap(_ row: XCUIElement) {
        XCTAssertTrue(row.isHittable && row.isEnabled)
        // An identified SwiftUI Toggle exposes a full-width native row. The switch
        // occupies its trailing control, while a center tap can land on the caption.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    }
    private func waitForValue(_ element: XCUIElement, _ value: String) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }
    private func capture(_ step: String) {
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "automatic-settings-\(step)-\(revision)"; attachment.lifetime = .keepAlways; add(attachment)
        reviewNativeScreenshotIfRequested(step, namePrefix: "automatic-settings", revision: revision)
    }
}
