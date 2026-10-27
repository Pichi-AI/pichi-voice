import XCTest

/// Run only on a fresh, task-owned simulator. This checks the real root, navigation,
/// preference store and Keychain without starting a microphone or model operation.
final class MobileKioskUITests: XCTestCase {
    private var app: XCUIApplication!
    private let password = "KioskTest42"
    private var language = "en"

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Kiosk acceptance requires a task-owned simulator")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_KIOSK_UI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt in on a fresh task-owned simulator")
        }
        continueAfterFailure = false
        language = environment["PICHI_KIOSK_UI_LANGUAGE"] ?? "en"
        XCTAssertTrue(["en", "ru"].contains(language))
        let theme = environment["PICHI_KIOSK_UI_THEME"] ?? "light"
        XCTAssertTrue(["light", "dark"].contains(theme))
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1",
            "-PichiInterfaceLanguage", language, "-ThemePreference", theme]
        app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
        app.launch()
        capture("01-normal-launch")
        #endif
    }

    func testPasswordGatePersistsAcrossRelaunchAndPreservesAdministratorSettings() throws {
        openSettings()
        tap(app.buttons["settings.privacy"], step: "03-open-privacy")
        let audio = app.switches["privacy.saveAudio"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        let originalAudio = try XCTUnwrap(audio.value as? String)
        XCTAssertTrue(["0", "1"].contains(originalAudio))
        try toggleAudio(audio)
        let configuredAudio = try XCTUnwrap(audio.value as? String)
        XCTAssertNotEqual(configuredAudio, originalAudio)
        capture("04-configured-audio-choice")

        returnToSettings()
        tap(app.buttons["settings.kiosk"], step: "06-open-kiosk-settings")
        XCTAssertTrue(element("kiosk.settings").waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["kiosk.confirmation"].exists,
                      "A fresh simulator must have no previous kiosk credential")

        enter("short", into: "kiosk.password", step: "07-short-password")
        enter("short", into: "kiosk.confirmation", step: "08-short-confirmation")
        tap(app.buttons["kiosk.enable"], step: "09-short-password-rejected")
        XCTAssertTrue(element("kiosk.passwordError").waitForExistence(timeout: 5))
        XCTAssertFalse(element("kiosk.root").exists)

        replace("short", with: password, in: "kiosk.password", step: "10-valid-password")
        replace("short", with: "Different42", in: "kiosk.confirmation", step: "11-mismatched-confirmation")
        tap(app.buttons["kiosk.enable"], step: "12-mismatch-rejected")
        XCTAssertTrue(element("kiosk.passwordError").waitForExistence(timeout: 5))
        XCTAssertFalse(element("kiosk.root").exists)

        replace("Different42", with: password, in: "kiosk.confirmation", step: "13-matching-confirmation")
        tap(app.buttons["kiosk.enable"], step: "14-kiosk-enabled")
        assertKioskIsolated(step: "14a-kiosk-confirmed")

        tap(app.buttons["kiosk.admin"], step: "15-admin-password-sheet")
        XCTAssertTrue(element("kiosk.unlock").waitForExistence(timeout: 5))
        tap(app.buttons["kiosk.unlockCancel"], step: "16-admin-cancelled")
        assertKioskIsolated(step: "16a-kiosk-after-cancel")

        tap(app.buttons["kiosk.admin"], step: "17-admin-sheet-reopened")
        enter("WrongTest42", into: "kiosk.unlockPassword", step: "18-wrong-admin-password")
        tap(app.buttons["kiosk.unlockConfirm"], step: "19-wrong-password-rejected")
        XCTAssertTrue(element("kiosk.passwordError").waitForExistence(timeout: 5))
        XCTAssertTrue(element("kiosk.unlock").exists)
        XCTAssertFalse(app.buttons["navigation.history"].exists)
        tap(app.buttons["kiosk.unlockCancel"], step: "20-wrong-password-cancelled")
        assertKioskIsolated(step: "20a-kiosk-after-wrong-password")

        app.terminate()
        app.launch()
        capture("21-relaunch-stays-locked")
        assertKioskIsolated(step: "21a-relaunch-confirmed")
        unlock(stepPrefix: "22")

        openSettings()
        tap(app.buttons["settings.privacy"], step: "24-privacy-after-unlock")
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, configuredAudio,
                       "Kiosk entry, relaunch and exit must preserve the administrator's audio choice")
        capture("25-audio-choice-preserved")

        returnToSettings()
        tap(app.buttons["settings.kiosk"], step: "27-existing-kiosk-password")
        XCTAssertTrue(element("kiosk.settings").waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["kiosk.confirmation"].exists,
                       "Re-enabling must verify the existing administrator credential")
        enter(password, into: "kiosk.password", step: "28-existing-password-entered")
        tap(app.buttons["kiosk.enable"], step: "29-kiosk-reenabled")
        assertKioskIsolated(step: "29a-kiosk-reenabled-confirmed")
        unlock(stepPrefix: "30")

        openSettings()
        tap(app.buttons["settings.privacy"], step: "32-return-to-audio-settings")
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, configuredAudio)
        try toggleAudio(app.switches["privacy.saveAudio"])
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, originalAudio)
        capture("33-original-audio-choice-restored")
        returnToSettings()
        XCTAssertFalse(element("kiosk.root").exists)
        XCTAssertTrue(app.buttons["settings.kiosk"].exists)
    }

    private func assertKioskIsolated(step: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("kiosk.root").waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(app.buttons["kiosk.start"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["kiosk.admin"].exists, file: file, line: line)
        XCTAssertEqual(app.tabBars.count, 0, file: file, line: line)
        for identifier in ["navigation.settings", "navigation.history", "navigation.meetings",
                           "settings.root", "settings.kiosk", "meeting.start", "transcript.more",
                           "meeting.presentation", "meeting.share"] {
            XCTAssertFalse(element(identifier).exists, "Kiosk exposed \(identifier)", file: file, line: line)
        }
        XCTAssertEqual(app.alerts.count, 0, file: file, line: line)
        capture(step)
    }

    private func unlock(stepPrefix: String) {
        tap(app.buttons["kiosk.admin"], step: "\(stepPrefix)-a-open-unlock")
        enter(password, into: "kiosk.unlockPassword", step: "\(stepPrefix)-b-correct-password")
        tap(app.buttons["kiosk.unlockConfirm"], step: "\(stepPrefix)-c-admin-unlocked")
        let normal = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            !element("kiosk.root").exists && !element("kiosk.unlock").exists
                && (app.buttons["navigation.settings"].exists || app.tabBars.count > 0)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [normal], timeout: 10), .completed)
        capture("\(stepPrefix)-d-normal-interface-confirmed")
    }

    private func openSettings() {
        let sidebar = app.buttons["navigation.settings"]
        if sidebar.waitForExistence(timeout: 2) {
            tap(sidebar, step: "02-settings-navigation")
        } else {
            tap(app.tabBars.buttons[language == "ru" ? "Настройки" : "Settings"], step: "02-settings-navigation")
        }
        XCTAssertTrue(app.buttons["settings.kiosk"].waitForExistence(timeout: 5))
    }

    private func returnToSettings() {
        let sidebar = app.buttons["navigation.settings"]
        if sidebar.exists {
            tap(sidebar, step: "05-settings-root")
        } else {
            tap(app.navigationBars.buttons[language == "ru" ? "Настройки" : "Settings"].firstMatch,
                step: "05-settings-root")
        }
        XCTAssertTrue(app.buttons["settings.kiosk"].waitForExistence(timeout: 5))
    }

    private func enter(_ value: String, into identifier: String, step: String) {
        let field = app.secureTextFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        capture("\(step)-focused")
        field.typeText(value)
        capture(step)
    }

    private func replace(_ previous: String, with value: String, in identifier: String, step: String) {
        let field = app.secureTextFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        capture("\(step)-focused")
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + value)
        capture(step)
    }

    private func tap(_ target: XCUIElement, step: String) {
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertTrue(target.isEnabled)
        XCTAssertTrue(target.isHittable)
        target.tap()
        capture(step)
    }

    private func toggleAudio(_ row: XCUIElement) throws {
        let previous = try XCTUnwrap(row.value as? String)
        let bounds = row.frame
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
            XCTAssertTrue(row.isHittable)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.exists && (row.value as? String) != previous
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func capture(_ step: String) {
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "unverified-revision"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "kiosk-access-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        reviewNativeScreenshotIfRequested(step, namePrefix: "kiosk-access", revision: revision)
    }
}
