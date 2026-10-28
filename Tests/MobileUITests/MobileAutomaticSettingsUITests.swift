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

    /// Run before authenticated HTTP cases on a fresh task-owned simulator.
    func testGuestDataCleanupCanEncryptButCannotDeleteAfterSync() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light",
            "-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1"]
        app.launch()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        let settings = app.buttons["navigation.settings"]
        if settings.exists && settings.isHittable { settings.tap() }
        else {
            // The compact native TabView exposes the localized tab label rather
            // than the sidebar identifier. Use the same route as navigation tests.
            let tab = app.tabBars.buttons["Настройки"]
            XCTAssertTrue(tab.waitForExistence(timeout: 5) && tab.isHittable)
            tab.tap()
        }
        capture("guest-settings-opened")
        let privacy = app.buttons["settings.privacy"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        privacy.tap()
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        capture("guest-privacy-opened")
        let encryption = app.switches["privacy.encryptLocalRecordings"]
        expose(encryption, in: app, step: "guest-encryption-visible")
        XCTAssertTrue(encryption.isEnabled)
        XCTAssertEqual(encryption.value as? String, "0")
        tap(encryption, app: app, step: "guest-encryption-before-enable")
        waitForValue(encryption, "1")
        capture("guest-encryption-enabled")
        tap(encryption, app: app, step: "guest-encryption-before-restore")
        waitForValue(encryption, "0")
        let deletion = app.switches["cloud.automatic.deleteLocal"]
        expose(deletion, in: app, step: "guest-retention-visible")
        XCTAssertFalse(deletion.isEnabled)
        XCTAssertEqual(deletion.value as? String, "0")
        capture("guest-retention-disabled")
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
            expose(automatic, in: app, step: prefix + "-automatic")
            XCTAssertEqual(automatic.value as? String, "0")
            openPrivacy(app, step: prefix + "-privacy")
            let encryption = app.switches["privacy.encryptLocalRecordings"]
            let deletion = app.switches["cloud.automatic.deleteLocal"]
            expose(encryption, in: app, step: prefix + "-encryption")
            XCTAssertEqual(encryption.value as? String, "0")
            XCTAssertTrue(encryption.isEnabled)
            expose(deletion, in: app, step: prefix + "-retention")
            XCTAssertEqual(deletion.value as? String, "0")
            XCTAssertTrue(deletion.isEnabled, "A connected workspace can configure retention without enabling uploads")
            tap(encryption, app: app, step: prefix + "-local-encryption-visible")
            waitForValue(encryption, "1")
            tap(deletion, app: app, step: prefix + "-retention-visible")
            waitForValue(deletion, "1")
            capture(prefix + "-local-policies-on")
            closePrivacy(app)
            expose(automatic, in: app, step: prefix + "-automatic-still-off")
            XCTAssertEqual(automatic.value as? String, "0", "Privacy choices must not silently grant upload consent")
            tap(automatic, app: app, step: prefix + "-automatic-visible")
            waitForValue(automatic, "1")
            openPrivacy(app, step: prefix + "-protected-sync")
            expose(encryption, in: app, step: prefix + "-forced-encryption")
            waitForValue(encryption, "1", enabled: false)
            XCTAssertTrue(app.descendants(matching: .any)["privacy.encryption.requiredForSync"].firstMatch.exists)
            expose(deletion, in: app, step: prefix + "-synced-retention")
            XCTAssertEqual(deletion.value as? String, "1")
            XCTAssertTrue(deletion.isEnabled)
            capture(prefix + "-automatic-requires-encryption")
            closePrivacy(app)
            tap(automatic, app: app, step: prefix + "-automatic-pause-visible")
            waitForValue(automatic, "0")
            openPrivacy(app, step: prefix + "-independent-policies")
            expose(encryption, in: app, step: prefix + "-encryption-still-on")
            XCTAssertEqual(encryption.value as? String, "1")
            XCTAssertTrue(encryption.isEnabled)
            tap(encryption, app: app, step: prefix + "-encryption-off-visible")
            waitForValue(encryption, "0")
            expose(deletion, in: app, step: prefix + "-retention-still-on")
            XCTAssertEqual(deletion.value as? String, "1")
            XCTAssertTrue(deletion.isEnabled)
            tap(deletion, app: app, step: prefix + "-retention-off-visible")
            waitForValue(deletion, "0")
            XCTAssertFalse(app.descendants(matching: .any)["privacy.retention.error"].firstMatch.exists)
            capture(prefix + "-policies-restored-off")
            closePrivacy(app)
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
        for index in 0..<7 where !element.isHittable {
            // Navigation and sheets can retain a non-hittable list underneath the
            // current form. Scroll only the visible native container.
            let candidates = app.collectionViews.allElementsBoundByIndex
                + app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            guard let scroll = candidates.first(where: { $0.exists && $0.isHittable }) else {
                XCTFail("The visible settings form must provide a hittable scroll container")
                return
            }
            if element.exists && element.frame.midY < app.windows.firstMatch.frame.midY { scroll.swipeDown() }
            else { scroll.swipeUp() }
            capture(step + "-scroll-\(index)")
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func tap(_ row: XCUIElement, app: XCUIApplication, step: String) {
        expose(row, in: app, step: step)
        XCTAssertTrue(row.isHittable && row.isEnabled)
        // An identified SwiftUI Toggle exposes a full-width native row. The switch
        // occupies its trailing control, while a center tap can land on the caption.
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
    }
    private func openPrivacy(_ app: XCUIApplication, step: String) {
        let button = app.buttons["automatic.review.openPrivacy"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["automatic.review.privacy"].firstMatch.waitForExistence(timeout: 5))
        capture(step)
    }
    private func closePrivacy(_ app: XCUIApplication) {
        app.buttons["automatic.review.closePrivacy"].tap()
        XCTAssertTrue(app.buttons["automatic.review.openPrivacy"].waitForExistence(timeout: 5))
    }
    private func waitForValue(_ element: XCUIElement, _ value: String, enabled: Bool = true) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ AND enabled == %@", value, NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }
    private func capture(_ step: String) {
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "automatic-settings-\(step)-\(revision)"; attachment.lifetime = .keepAlways; add(attachment)
        reviewNativeScreenshotIfRequested(step, namePrefix: "automatic-settings", revision: revision)
    }
}
