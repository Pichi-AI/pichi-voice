import XCTest

/// Run only on a fresh, task-owned simulator. This checks the real root, navigation,
/// preference store and Keychain without starting a microphone or model operation.
final class MobileKioskUITests: XCTestCase {
    private var app: XCUIApplication!
    private let password = "482915"
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

    func testVoiceWelcomeAndRestrictedSettingsRespectPasswordGateAcrossEntriesAndRelaunch() throws {
        guard ProcessInfo.processInfo.environment["PICHI_KIOSK_UI_EXISTING_VOICE"] != "1",
              ProcessInfo.processInfo.environment["PICHI_KIOSK_UI_WARM_REOPEN"] != "1" else {
            throw XCTSkip("The missing-voice flow requires a task-owned container without a profile")
        }
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
        tap(app.buttons["settings.kiosk"], step: "06-open-administrator-settings")
        XCTAssertTrue(element("kiosk.settings").waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["kiosk.confirmation"].exists,
                      "A fresh simulator must have no previous administrator credential")

        enter("123", into: "kiosk.password", step: "07-short-password")
        enter("123", into: "kiosk.confirmation", step: "08-short-confirmation")
        tap(app.buttons["kiosk.enable"], step: "09-short-password-rejected")
        XCTAssertTrue(element("kiosk.passwordError").waitForExistence(timeout: 5))
        XCTAssertEqual(element("kiosk.passwordError").label,
                       language == "ru" ? "Используйте пароль длиной от 6 до 128 символов." : "Use a password with 6 to 128 characters.")
        XCTAssertFalse(element("kiosk.voiceWelcome").exists)

        replace("123", with: password, in: "kiosk.password", step: "10-valid-password")
        replace("123", with: "759421", in: "kiosk.confirmation", step: "11-mismatched-confirmation")
        tap(app.buttons["kiosk.enable"], step: "12-mismatch-rejected")
        XCTAssertTrue(element("kiosk.passwordError").waitForExistence(timeout: 5))
        XCTAssertEqual(element("kiosk.passwordError").label,
                       language == "ru" ? "Пароли не совпадают." : "The passwords do not match.")
        XCTAssertFalse(element("kiosk.voiceWelcome").exists)

        replace("759421", with: password, in: "kiosk.confirmation", step: "13-matching-confirmation")
        tap(app.buttons["kiosk.enable"], step: "14-first-entry-voice-question", waitFor: "kiosk.voiceWelcome")
        assertVoiceWelcome()

        // This never presses ownerVoice.start, grants microphone access or saves a profile.
        tap(app.buttons["kiosk.voiceWelcome.setup"], step: "15-welcome-opens-own-voice",
            waitFor: "kiosk.limitedSettings")
        assertLimitedSettings()
        closeLimitedSettings(step: "16-return-to-recording")
        assertRecordingIsolated()

        openAdministrator(stepPrefix: "17")
        tap(app.buttons["kiosk.unlockCancel"], step: "18-admin-cancelled", waitFor: "kiosk.limitedSettings")
        assertLimitedSettings()
        closeLimitedSettings(step: "19-recording-after-admin-cancel")
        assertRecordingIsolated()

        openAdministrator(stepPrefix: "20")
        enter("759421", into: "kiosk.unlockPassword", step: "21-wrong-admin-password")
        tap(app.buttons["kiosk.unlockConfirm"], step: "22-wrong-password-rejected")
        XCTAssertTrue(element("kiosk.passwordError").waitForExistence(timeout: 5))
        XCTAssertTrue(element("kiosk.unlock").exists)
        assertAdministrativeDestinationsAbsent()
        tap(app.buttons["kiosk.unlockCancel"], step: "23-wrong-password-cancelled", waitFor: "kiosk.limitedSettings")
        closeLimitedSettings(step: "24-recording-after-wrong-password")
        assertRecordingIsolated()

        relaunchIntoRecording(step: "25-relaunch-does-not-repeat-voice-question")
        openLimitedSettings(step: "26-own-voice-remains-available-after-relaunch")
        assertLimitedSettings()
        unlock(stepPrefix: "27")

        openSettings()
        tap(app.buttons["settings.privacy"], step: "28-privacy-after-unlock")
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, configuredAudio,
                       "Voice invitation, restricted settings, relaunch and exit must preserve the administrator's audio choice")
        capture("29-audio-choice-preserved")

        returnToSettings()
        tap(app.buttons["settings.kiosk"], step: "30-existing-administrator-password")
        XCTAssertTrue(element("kiosk.settings").waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["kiosk.confirmation"].exists,
                       "Re-enabling must verify the existing administrator credential")
        enter(password, into: "kiosk.password", step: "31-existing-password-entered")
        tap(app.buttons["kiosk.enable"], step: "32-new-entry-asks-about-voice-again", waitFor: "kiosk.voiceWelcome")
        assertVoiceWelcome()
        tap(app.buttons["kiosk.voiceWelcome.skip"], step: "33-skip-voice-for-this-entry", waitFor: "kiosk.start")
        assertRecordingIsolated()
        relaunchIntoRecording(step: "34-relaunch-after-skip-does-not-repeat-question")
        openLimitedSettings(step: "35-own-voice-can-still-be-set-in-settings")
        assertLimitedSettings()
        unlock(stepPrefix: "36")

        openSettings()
        tap(app.buttons["settings.privacy"], step: "37-return-to-audio-settings")
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, configuredAudio)
        try toggleAudio(app.switches["privacy.saveAudio"])
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, originalAudio)
        capture("38-original-audio-choice-restored")
        returnToSettings()
        XCTAssertFalse(element("kiosk.root").exists)
        XCTAssertTrue(app.buttons["settings.kiosk"].exists)
    }

    /// The parent stages a valid invented profile in this fresh simulator's ordinary
    /// application container. Neither this test nor the app uses a testing injection.
    func testExistingVoiceProfileSkipsAutomaticWelcome() throws {
        guard ProcessInfo.processInfo.environment["PICHI_KIOSK_UI_EXISTING_VOICE"] == "1" else {
            throw XCTSkip("Opt in only after staging a valid synthetic voice profile on a fresh task-owned simulator")
        }
        openSettings()
        tap(app.buttons["settings.kiosk"], step: "existing-03-administrator-settings")
        XCTAssertTrue(app.secureTextFields["kiosk.confirmation"].waitForExistence(timeout: 5),
                      "Existing-profile acceptance still requires a fresh administrator credential")
        enter(password, into: "kiosk.password", step: "existing-04-password")
        enter(password, into: "kiosk.confirmation", step: "existing-05-confirmation")
        tap(app.buttons["kiosk.enable"], step: "existing-06-recording-without-voice-question", waitFor: "kiosk.start")
        assertRecordingIsolated()
        openLimitedSettings(step: "existing-07-saved-voice-in-restricted-settings", expectsProfile: true)
        closeLimitedSettings(step: "existing-08-return-to-recording")
        relaunchIntoRecording(step: "existing-09-relaunch-with-existing-profile")
        openLimitedSettings(step: "existing-10-voice-profile-remains-saved", expectsProfile: true)
        unlock(stepPrefix: "existing-11")
        XCTAssertFalse(element("kiosk.root").exists)
    }

    func testUnansweredVoiceWelcomeDoesNotReturnAfterWarmReopen() throws {
        guard ProcessInfo.processInfo.environment["PICHI_KIOSK_UI_WARM_REOPEN"] == "1" else {
            throw XCTSkip("Run on a task-owned container without an owner voice profile")
        }
        openSettings()
        tap(app.buttons["settings.kiosk"], step: "warm-03-administrator-settings")
        enter(password, into: "kiosk.password", step: "warm-04-password")
        if app.secureTextFields["kiosk.confirmation"].exists {
            enter(password, into: "kiosk.confirmation", step: "warm-05-confirmation")
        }
        tap(app.buttons["kiosk.enable"], step: "warm-06-first-entry-question", waitFor: "kiosk.voiceWelcome")
        assertVoiceWelcome()
        XCUIDevice.shared.press(.home)
        capture("warm-07-home-with-question-unanswered")
        app.activate()
        XCTAssertTrue(app.buttons["kiosk.start"].waitForExistence(timeout: 10))
        capture("warm-08-reopen-goes-to-recording")
        assertRecordingIsolated()
        openLimitedSettings(step: "warm-09-voice-only-in-settings")
        assertLimitedSettings()
        unlock(stepPrefix: "warm-10")
    }

    private func assertRecordingIsolated(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("kiosk.root").waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(app.buttons["kiosk.start"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["kiosk.settings.open"].exists, file: file, line: line)
        XCTAssertFalse(element("kiosk.voiceWelcome").exists, file: file, line: line)
        XCTAssertFalse(element("kiosk.limitedSettings").exists, file: file, line: line)
        XCTAssertFalse(app.buttons["kiosk.admin"].exists, file: file, line: line)
        assertAdministrativeDestinationsAbsent(file: file, line: line)
        assertNoModeTitle(file: file, line: line)
    }

    private func assertVoiceWelcome(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("kiosk.voiceWelcome").waitForExistence(timeout: 10), file: file, line: line)
        XCTAssertTrue(app.buttons["kiosk.voiceWelcome.setup"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["kiosk.voiceWelcome.skip"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["kiosk.start"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["kiosk.settings.open"].exists, file: file, line: line)
        for index in 0...6 {
            XCTAssertFalse(element("onboarding.step.\(index)").exists,
                           "The entry question must not expose the full setup flow", file: file, line: line)
        }
        assertAdministrativeDestinationsAbsent(file: file, line: line)
        assertNoModeTitle(file: file, line: line)
    }

    private func assertLimitedSettings(expectsProfile: Bool = false,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element("kiosk.limitedSettings").waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(element("settings.ownerVoice").exists, file: file, line: line)
        XCTAssertTrue(element("ownerVoice.status").exists, file: file, line: line)
        XCTAssertTrue(app.buttons["ownerVoice.start"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["ownerVoice.start"].isEnabled, file: file, line: line)
        if expectsProfile {
            XCTAssertTrue(app.buttons["ownerVoice.delete"].waitForExistence(timeout: 5),
                          "The staged profile must be read through the real voice service", file: file, line: line)
        } else {
            XCTAssertFalse(app.buttons["ownerVoice.delete"].exists,
                           "This task-owned container must have no voice profile", file: file, line: line)
        }
        let expectedStatus: String
        if expectsProfile { expectedStatus = language == "ru" ? "Ваш голос сохранён" : "Your voice is saved" }
        else { expectedStatus = language == "ru" ? "Ваш голос ещё не настроен" : "Your voice is not set up" }
        // Label propagates its identifier to both the SF Symbol and its text.
        let statusText = app.staticTexts["ownerVoice.status"].firstMatch
        XCTAssertTrue(statusText.waitForExistence(timeout: 5), file: file, line: line)
        XCTAssertTrue(statusText.label.contains(expectedStatus), file: file, line: line)
        XCTAssertTrue(app.buttons["kiosk.admin"].exists, file: file, line: line)
        assertAdministrativeDestinationsAbsent(file: file, line: line)
        assertNoModeTitle(file: file, line: line)
    }

    private func assertAdministrativeDestinationsAbsent(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.tabBars.count, 0, file: file, line: line)
        for identifier in ["navigation.settings", "navigation.history", "navigation.meetings",
                           "settings.root", "settings.kiosk", "settings.general", "settings.recording",
                           "settings.models", "settings.privacy", "settings.replaySetup", "privacy.saveAudio",
                           "meeting.start", "transcript.more", "meeting.presentation", "meeting.share"] {
            XCTAssertFalse(element(identifier).exists, "Restricted UI exposed \(identifier)", file: file, line: line)
        }
        XCTAssertEqual(app.alerts.count, 0,
                       "Viewing own-voice controls must not prompt for microphone access", file: file, line: line)
    }

    private func assertNoModeTitle(file: StaticString = #filePath, line: UInt = #line) {
        for title in ["Kiosk mode", "Режим киоска"] {
            XCTAssertFalse(app.navigationBars[title].exists, file: file, line: line)
            XCTAssertFalse(app.staticTexts[title].exists, file: file, line: line)
        }
    }

    private func openLimitedSettings(step: String, expectsProfile: Bool = false) {
        tap(app.buttons["kiosk.settings.open"], step: step, waitFor: "kiosk.limitedSettings")
        assertLimitedSettings(expectsProfile: expectsProfile)
    }

    private func closeLimitedSettings(step: String) {
        tap(app.buttons["kiosk.settings.done"], step: step, waitFor: "kiosk.start")
        assertRecordingIsolated()
    }

    private func openAdministrator(stepPrefix: String) {
        if !element("kiosk.limitedSettings").exists {
            openLimitedSettings(step: "\(stepPrefix)-a-open-restricted-settings")
        }
        tap(app.buttons["kiosk.admin"], step: "\(stepPrefix)-b-open-administrator", waitFor: "kiosk.unlock")
    }

    private func relaunchIntoRecording(step: String) {
        app.terminate()
        app.launch()
        assertRecordingIsolated()
        capture(step)
    }

    private func unlock(stepPrefix: String) {
        openAdministrator(stepPrefix: stepPrefix)
        enter(password, into: "kiosk.unlockPassword", step: "\(stepPrefix)-c-correct-password")
        tap(app.buttons["kiosk.unlockConfirm"], step: "\(stepPrefix)-d-admin-unlocked")
        let normal = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            !element("kiosk.root").exists && !element("kiosk.unlock").exists
                && (app.buttons["navigation.settings"].exists || app.tabBars.count > 0)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [normal], timeout: 10), .completed)
        capture("\(stepPrefix)-e-normal-interface-confirmed")
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
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5),
                      "The native keyboard must be ready before secure input")
        // A field entry is one interaction. Type immediately after focus rather than
        // suspending a transient secure-keyboard state for the visual review pause.
        typeNativeDigits(value)
        capture(step)
    }

    private func replace(_ previous: String, with value: String, in identifier: String, step: String) {
        let field = app.secureTextFields[identifier]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        for _ in previous { app.keyboards.keys["delete"].tap() }
        typeNativeDigits(value)
        capture(step)
    }

    /// Real native keys avoid ASCII typeText injection into a Russian keyboard.
    /// Submission and password-gate assertions verify the bindings, without
    /// assuming that a secure field exposes its value or length to accessibility.
    private func typeNativeDigits(_ value: String) {
        XCTAssertFalse(value.isEmpty)
        XCTAssertTrue(value.allSatisfy { $0.isASCII && $0.isNumber })
        guard let first = value.first else { return }
        if !app.keyboards.keys[String(first)].exists {
            app.keyboards.keys["more"].tap()
        }
        for digit in value {
            let key = app.keyboards.keys[String(digit)]
            XCTAssertTrue(key.waitForExistence(timeout: 3))
            key.tap()
        }
    }

    private func tap(_ target: XCUIElement, step: String, waitFor identifier: String? = nil) {
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        if ["kiosk.enable", "kiosk.unlockConfirm"].contains(target.identifier), app.keyboards.count > 0 {
            let done = app.buttons["kiosk.keyboardDone"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            XCTAssertTrue(done.isHittable)
            done.tap()
            capture("\(step)-keyboard-dismissed")
        }
        if target.identifier == "kiosk.admin", !target.isHittable {
            for attempt in 1...3 {
                element("kiosk.limitedSettings").swipeUp()
                capture("\(step)-scroll-\(attempt)")
                if target.isHittable { break }
            }
        }
        XCTAssertTrue(target.isEnabled)
        XCTAssertTrue(target.isHittable)
        target.tap()
        if let identifier { XCTAssertTrue(element(identifier).waitForExistence(timeout: 10)) }
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
