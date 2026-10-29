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
            XCTAssertTrue(app.buttons["account.workspace.selector"].waitForExistence(timeout: 5))
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

    /// The default account screen exposes its selected scope and consent without
    /// a wall of implementation details; those details remain reachable on demand.
    func testCompactAccountShowsSelectedWorkspaceAndExpandableDetails() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        for (language, appearance) in [("en", "light"), ("en", "dark"), ("ru", "light"), ("ru", "dark")] {
            app.launchEnvironment["PICHI_UI_AUTOMATIC_SETTINGS_REVIEW"] = "1"
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            let prefix = "compact-\(language)-\(appearance)"
            XCTAssertTrue(app.descendants(matching: .any)["automatic.review.ready"].firstMatch.waitForExistence(timeout: 15))
            let workspace = app.buttons["account.workspace.selector"]
            XCTAssertTrue(workspace.waitForExistence(timeout: 5))
            XCTAssertEqual(workspace.value as? String, "Synthetic workspace Ёё")
            let automatic = app.switches["cloud.sync.toggle"]
            XCTAssertTrue(automatic.isHittable && automatic.isEnabled)
            XCTAssertEqual(automatic.value as? String, "0")
            XCTAssertTrue(app.staticTexts["cloud.sync.summary"].exists)
            let destination = app.descendants(matching: .any)["cloud.automatic.destination"].firstMatch
            XCTAssertFalse(destination.exists, "The technical server row is collapsed by default")
            XCTAssertFalse(app.buttons["account.switchPerson"].exists)
            XCTAssertFalse(app.buttons["account.signOut"].exists)
            capture(prefix + "-default")

            XCTAssertTrue(workspace.isHittable)
            workspace.tap()
            capture(prefix + "-workspace-opened")
            // Native UIMenu actions expose their visible title rather than
            // forwarding the SwiftUI Button's accessibility identifier.
            XCTAssertTrue(app.buttons["Synthetic workspace Ёё"].waitForExistence(timeout: 5))
            dismissMenu(app)
            XCTAssertTrue(workspace.isHittable)

            let details = app.descendants(matching: .any)["cloud.sync.details.toggle"].firstMatch
            expose(details, in: app, step: prefix + "-details-visible")
            details.tap()
            capture(prefix + "-details-open")
            XCTAssertTrue(destination.waitForExistence(timeout: 5))
            details.tap()
            XCTAssertFalse(destination.exists)
            XCTAssertEqual(automatic.value as? String, "0", "Reading details must not enable sending")

            let actions = app.buttons["account.actions"]
            expose(actions, in: app, step: prefix + "-actions-visible")
            actions.tap()
            capture(prefix + "-actions")
            let switchTitle = language == "ru" ? "Сменить аккаунт" : "Switch account"
            let signOutTitle = language == "ru" ? "Выйти" : "Sign out"
            XCTAssertTrue(app.buttons[switchTitle].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons[signOutTitle].exists)
            dismissMenu(app)
            let close = app.buttons["automatic.review.close"]
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(app.descendants(matching: .any)["automatic.review.closed"].firstMatch.waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    private func dismissMenu(_ app: XCUIApplication) {
        // The navigation title is outside both compact native menus and does not
        // change settings, account ownership or publication consent.
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func expose(_ element: XCUIElement, in app: XCUIApplication, step: String) {
        for index in 0..<7 where !element.isHittable {
            // A SwiftUI Form container can report non-hittable while its visible
            // rows are tappable. Gesture in the observed active form's content,
            // above the floating tabs, instead of using its center hit test.
            let identified = [app.collectionViews["settings.privacy.detail"],
                app.collectionViews["automatic.review.privacy"]]
            let candidates = identified + app.collectionViews.allElementsBoundByIndex
                + app.scrollViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
            guard let scroll = candidates.first(where: { $0.exists && $0.frame.width > 0 && $0.frame.height > 0 }) else {
                XCTFail("The visible settings form must provide a native scroll container")
                return
            }
            let down = element.exists && element.frame.midY < app.windows.firstMatch.frame.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: down ? 0.3 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: down ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
            capture(step + "-scroll-\(index)")
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    private func tap(_ row: XCUIElement, app: XCUIApplication, step: String) {
        expose(row, in: app, step: step)
        XCTAssertTrue(row.isHittable && row.isEnabled)
        let bounds = row.frame
        // Reuse the existing navigation acceptance approach: identified SwiftUI
        // rows expose a narrower native backing UISwitch inside their bounds.
        let controls = app.switches.allElementsBoundByIndex.filter {
            let frame = $0.frame
            return frame.width > 0 && frame.width < bounds.width / 2
                && bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
        XCTAssertLessThanOrEqual(controls.count, 1)
        if let control = controls.first {
            XCTAssertTrue(control.isHittable)
            control.tap()
        } else {
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        }
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
