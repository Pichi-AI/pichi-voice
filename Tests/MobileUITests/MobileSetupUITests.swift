import Foundation
import XCTest

/// Opt-in native acceptance on an explicitly owned simulator. No microphone or
/// physical device is accessed. Setup uses the production services and installed artifacts.
final class MobileSetupUITests: XCTestCase {
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Setup acceptance requires the task-owned simulator")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_SETUP_UI_ACCEPTANCE"] == "1" else {
            throw XCTSkip("Opt in on a fresh task-owned simulator with staged public artifacts")
        }
        #endif
        continueAfterFailure = false
        // A previous test can leave the device rotated; Settings rows below the fold are not rendered.
        XCUIDevice.shared.orientation = .portrait
    }

    /// Pinned-page presentation with the account expectation taken from the frozen
    /// distribution. No sign-in, ASR preparation, voice enrollment or capture occurs.
    func testDistributionSetupPagesKeepAccountOptional() throws {
        let accountExpectation = try XCTUnwrap(
            ProcessInfo.processInfo.environment["PICHI_SETUP_EXPECT_ACCOUNT_CONFIGURATION"],
            "Derive the account expectation from the frozen app's packaged distribution")
        XCTAssertTrue(["configured", "unconfigured"].contains(accountExpectation))
        let app = XCUIApplication()
        defer { app.terminate() }
        for (language, appearance) in [("en", "light"), ("ru", "dark")] {
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                                   "-MobileSetupVersion", "0", "-MobileSetupStep", "0"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.0"].firstMatch.waitForExistence(timeout: 15))
            XCTAssertEqual(app.alerts.count, 0)
            capture("guest-\(language)-welcome")
            let next = app.buttons["onboarding.next"]
            XCTAssertTrue(next.isHittable && next.isEnabled)
            // Pinned argument-domain steps are presentation fixtures, not writable
            // navigation state. The ordinary first-run test below verifies Next.
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                                   "-MobileSetupVersion", "0", "-MobileSetupStep", "1"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.1"].firstMatch.waitForExistence(timeout: 10))
            capture("guest-\(language)-voice-choice")
            app.terminate()

            // Inspect the final setup page without downloading or accepting
            // any models. This is a page review, not a completed setup test.
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                                   "-MobileSetupVersion", "0", "-MobileSetupStep", "6"]
            app.launch()
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.6"].firstMatch.waitForExistence(timeout: 15))
            if accountExpectation == "configured" {
                XCTAssertTrue(app.buttons["account.signIn"].exists,
                              "A configured distribution offers optional sign-in")
                let guest = app.buttons["account.continueAsGuest"]
                XCTAssertTrue(guest.exists && guest.isEnabled,
                              "A configured account must not prevent continuing as a guest")
            } else {
                XCTAssertFalse(app.buttons["account.signIn"].exists,
                               "The guest distribution must not offer an unconfigured or local SSO server")
                XCTAssertFalse(app.buttons["account.continueAsGuest"].exists)
            }
            XCTAssertEqual(app.alerts.count, 0)
            capture("guest-\(language)-ready-page")
            app.terminate()
        }
    }

    func testFirstRunPreparesActualResourcesSkipsMicrophoneAndEntersApp() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light"]
        if ProcessInfo.processInfo.environment["PICHI_SETUP_ATTACH_EXISTING"] == "1" {
            XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground,
                          "Attach only to the normal application launched on the owned simulator")
            app.activate()
        } else { app.launch() }
        if ProcessInfo.processInfo.environment["PICHI_SETUP_RESUME_AT_PRIVACY"] == "1" {
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.3"].firstMatch.waitForExistence(timeout: 15))
        } else {
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.0"].firstMatch.waitForExistence(timeout: 15),
                          "This test requires a fresh application container")
            capture("flow-00-welcome")
            app.buttons["onboarding.next"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.1"].firstMatch.waitForExistence(timeout: 10))
            capture("flow-01-model-choice")
            XCTAssertTrue(app.buttons["onboarding.model.gigaam-v3-eou"].exists)
            app.buttons["onboarding.next"].tap()
            capture("flow-02-model-preparation")
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.2"].firstMatch.waitForExistence(timeout: 180))
            capture("flow-03-participants")
            app.buttons["onboarding.next"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.3"].firstMatch.waitForExistence(timeout: 180))
        }
        capture("flow-04-privacy-default")
        XCTAssertEqual(app.switches["privacy.pii"].value as? String, "0")
        if ProcessInfo.processInfo.environment["PICHI_SETUP_PREPARE_PRIVACY_E2E"] == "1" {
            try tapNativeSwitch("privacy.pii", in: app)
            capture("flow-04a-privacy-enabling")
            XCTAssertTrue(app.descendants(matching: .any)["privacy.pii.active"].firstMatch.waitForExistence(timeout: 180))
            capture("flow-04b-privacy-ready")
            try tapNativeSwitch("privacy.pii", in: app)
            XCTAssertFalse(app.descendants(matching: .any)["privacy.pii.active"].firstMatch.exists)
            capture("flow-04c-privacy-off")
        }
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.4"].firstMatch.waitForExistence(timeout: 10))
        capture("flow-05-voice-offer")
        XCTAssertTrue(app.buttons["ownerVoice.start"].exists)
        XCTAssertEqual(app.alerts.count, 0, "Showing enrollment must not request microphone permission")
        app.buttons["onboarding.skip"].tap()
        capture("flow-06-skipped-voice")
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.5"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["meetingLocation.enabled"].value as? String, "0")
        XCTAssertEqual(app.alerts.count, 0, "Showing the optional location page must not request permission")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        capture("flow-07-location-offer")
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.6"].firstMatch.waitForExistence(timeout: 10))
        capture("flow-08-skipped-location")
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Сделайте первую запись"].firstMatch.waitForExistence(timeout: 10),
                      "A completed first setup opens the empty Meetings list with its first-meeting hint")
        capture("flow-09-normal-app")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["onboarding.next"].exists)
        capture("flow-10-restart")
        try assertFirstMeetingHintLayoutInBothLanguagesAndAppearances(app)
    }

    /// The empty Meetings list is the first meeting's hint after a real setup and every relaunch.
    /// Start and the next recording's settings stay above the tab bar in both orientations.
    private func assertFirstMeetingHintLayoutInBothLanguagesAndAppearances(_ app: XCUIApplication) throws {
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        for language in ["en", "ru"] {
            for appearance in ["light", "dark"] {
                app.terminate()
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
                app.launch()
                let title = language == "ru" ? "Сделайте первую запись" : "Make your first recording"
                XCTAssertTrue(app.staticTexts[title].firstMatch.waitForExistence(timeout: 10))
                for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
                    XCUIDevice.shared.orientation = orientation
                    let predicate = NSPredicate { _, _ in
                        let frame = app.windows.firstMatch.frame
                        return orientation == .portrait ? frame.height > frame.width : frame.width > frame.height
                    }
                    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10), .completed)
                    XCTAssertTrue(app.buttons["meeting.start"].isHittable, "Start must remain reachable above the tab bar")
                    let settings = app.buttons["meeting.settings"]
                    XCTAssertTrue(settings.waitForExistence(timeout: 5))
                    XCTAssertTrue(settings.isHittable)
                    XCTAssertTrue(app.windows.firstMatch.frame.contains(settings.frame), "The whole line must remain visible")
                    if app.tabBars.firstMatch.exists {
                        XCTAssertTrue(settings.frame.intersection(app.tabBars.firstMatch.frame).isEmpty,
                                      "The floating tab bar must not cover the next recording's settings")
                    }
                    capture("first-hint-\(language)-\(appearance)-\(name)")
                }
            }
        }
    }

    /// Argument-domain page selection is only a native layout review. It does not
    /// claim that static pages prove downloads, model accuracy or enrollment acceptance.
    func testRussianNativeSetupPagesInBothAppearances() {
        let app = XCUIApplication()
        let steps = ProcessInfo.processInfo.environment["PICHI_SETUP_MODEL_CHOICE_ONLY"] == "1" ? [1] : Array(0...6)
        for appearance in ["light", "dark"] {
            for step in steps {
                app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", appearance,
                                       "-MobileSetupVersion", "0", "-MobileSetupStep", String(step)]
                app.launch()
                XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.\(step)"].firstMatch.waitForExistence(timeout: 15))
                capture("native-ru-\(appearance)-step\(step)")
                XCTAssertEqual(app.alerts.count, 0)
                if step == 4 { XCTAssertFalse(app.buttons["ownerVoice.stop"].exists) }
                app.terminate()
            }
        }
    }

    /// Parent stages MobileSetupStep=5 in the owned simulator's persistent domain.
    /// Launch arguments must not override the step being changed by real Next/Skip.
    func testLocationSetupCanAdvanceWithoutPermission() {
        let app = XCUIApplication()
        let language = ProcessInfo.processInfo.environment["PICHI_LOCATION_TEST_LANGUAGE"] ?? "ru"
        app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", "light", "-MobileSetupVersion", "0"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.5"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.switches["meetingLocation.enabled"].exists)
        XCTAssertEqual(app.switches["meetingLocation.enabled"].value as? String, "0")
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        capture("location-\(language)-optional-offer")
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.6"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.alerts.count, 0, "Location authorization is optional for completing setup")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        capture("location-\(language)-advanced-without-permission")
        app.terminate()
    }

    /// Parent stages a completed setup (MobileSetupVersion=1) in the owned simulator's persistent domain.
    /// A launch argument would pin completion, so replay must change the stored value.
    func testReplayOnboardingReturnsToWelcome() {
        let app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light"]
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let sidebar = app.buttons["navigation.settings"]
        // Far from the label and icon: the whole sidebar row must respond.
        if sidebar.waitForExistence(timeout: 5) { sidebar.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
        else { app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Настройки", "Settings"])).firstMatch.tap() }
        let replay = app.buttons["settings.replaySetup"]
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].firstMatch.waitForExistence(timeout: 10))
        // Replay is the last row of the Settings root, below the fold on a phone.
        reveal("settings.replaySetup", in: app)
        XCTAssertTrue(replay.isEnabled, "Replay is available while no meeting is active")
        capture("replay-00-settings")
        replay.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.0"].firstMatch.waitForExistence(timeout: 10))
        capture("replay-01-welcome")
        // A quick second tap must not act on the page that is still arriving.
        app.buttons["onboarding.next"].doubleTap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.1"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.step.2"].firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["onboarding.cancel"].exists, "The second tap must not start model preparation")
        XCTAssertFalse(app.descendants(matching: .any)["onboarding.error"].exists)
        capture("replay-02-one-page-per-double-tap")
        app.terminate()
    }

    /// Only the hero scales to a phone; the highlights below or beside it keep their reading size.
    func testWelcomeHighlightsKeepReadingSizeOnPhone() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Phone layout") }
        let app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light",
                               "-MobileSetupVersion", "0", "-MobileSetupStep", "0"]
        app.launch()
        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.0"].firstMatch.waitForExistence(timeout: 15))
            let highlight = app.staticTexts["Текст во время записи"]
            XCTAssertTrue(highlight.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(highlight.frame.height, 18, "The highlights must not shrink with the hero")
            XCTAssertTrue(app.buttons["onboarding.next"].isHittable)
            capture("welcome-phone-\(name)")
        }
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testLocationPreferencePersistsInSettingsAfterPermissionDenial() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light", "-MobileSetupVersion", "1"]
        app.launch()
        openRecording(in: app)
        let location = app.switches["meetingLocation.enabled"]
        revealLocationSwitch(in: app)
        XCTAssertEqual(location.value as? String, "0", "Run on a fresh task-owned application container")
        capture("location-settings-00-disabled")
        try tapNativeSwitch("meetingLocation.enabled", in: app)
        dismissLocationPermissionIfPresented()
        XCTAssertEqual(location.value as? String, "1")
        XCTAssertTrue(app.buttons["meetingLocation.openSettings"].exists)
        capture("location-settings-01-enabled-denied")
        app.terminate()
        app.launch()
        openRecording(in: app)
        revealLocationSwitch(in: app)
        XCTAssertEqual(location.value as? String, "1")
        XCTAssertEqual(app.alerts.count, 0, "Restarting must not request location authorization")
        XCTAssertEqual(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count, 0)
        capture("location-settings-02-restart-enabled")
        app.terminate()
    }

    func testLocationSetupSkipDisablesPreference() {
        let app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "dark", "-MobileSetupVersion", "0"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.5"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.switches["meetingLocation.enabled"].value as? String, "1")
        capture("location-setup-03-enabled")
        app.buttons["onboarding.skip"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.6"].firstMatch.waitForExistence(timeout: 10))
        capture("location-setup-04-skipped")
        app.terminate()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "dark", "-MobileSetupVersion", "1"]
        app.launch()
        openRecording(in: app)
        revealLocationSwitch(in: app)
        XCTAssertEqual(app.switches["meetingLocation.enabled"].value as? String, "0")
        XCTAssertFalse(app.buttons["onboarding.next"].exists, "Completed installations stay completed")
        capture("location-settings-05-restart-disabled")
        app.terminate()
    }

    func testLocationPageInBothLanguagesAndThemes() {
        let app = XCUIApplication()
        for language in ["ru", "en"] {
            for appearance in ["light", "dark"] {
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                                       "-MobileSetupVersion", "0", "-MobileSetupStep", "5"]
                app.launch()
                XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.5"].firstMatch.waitForExistence(timeout: 15))
                XCTAssertTrue(app.switches["meetingLocation.enabled"].exists)
                XCTAssertEqual(app.alerts.count, 0)
                capture("location-page-\(language)-\(appearance)")
                app.terminate()
            }
        }
    }

    func testNativeSensitiveDictionaryCRUDAndDarkAppearance() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Inline dictionary acceptance requires an owned simulator")
        #else
        let app = XCUIApplication()
        for (language, appearance) in [("ru", "dark"), ("en", "light")] {
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                "-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1",
                "-MeetingPIIRedactionEnabled", "NO", "-MeetingPIIRedactionRequested", "NO"]
            app.launch()
            openPrivacy(in: app)
            reveal("privacy.dictionary.add", in: app)
            let add = app.buttons["privacy.dictionary.add"]
            capture("dictionary-\(language)-\(appearance)-00-settings")
            add.tap()
            // A fresh simulator can present the OS keyboard's one-time typing tip.
            // This is fixture setup, independent of the app's automatic field focus.
            for host in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
                let tip = host.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "Speed up your typing")).firstMatch
                if tip.waitForExistence(timeout: 1) {
                    capture("dictionary-\(language)-\(appearance)-keyboard-welcome")
                    host.buttons["Continue"].tap()
                }
            }
            let input = app.textFields["privacy.dictionary.phrase"]
            XCTAssertTrue(input.waitForExistence(timeout: 5))
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Keyboard must appear without tapping the input")
            XCTAssertFalse(add.exists, "Input must replace the Add row")
            XCTAssertFalse(app.pickers["privacy.dictionary.matchMode"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["settings.privacy.detail"].firstMatch.exists,
                          "Editing stays in the privacy page")
            XCTAssertTrue(input.isHittable)
            XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1,
                                     "Keyboard must not cover the input")
            XCTAssertFalse(app.buttons["privacy.dictionary.save"].isEnabled)
            capture("dictionary-\(language)-\(appearance)-01-inline-keyboard")
            if language == "ru" {
                input.typeText("Ёжик Тестовый\n")
                let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                    "privacy.dictionary.entry.", "Ёжик Тестовый")).firstMatch
                XCTAssertTrue(entry.waitForExistence(timeout: 5))
                XCTAssertFalse(input.exists)
                capture("dictionary-ru-dark-02-return-saved")
                add.tap()
                XCTAssertTrue(input.waitForExistence(timeout: 5))
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                input.typeText("Ёжик Тестовый")
                app.buttons["privacy.dictionary.save"].tap()
                let validation = app.staticTexts["privacy.dictionary.error"]
                XCTAssertTrue(validation.waitForExistence(timeout: 5))
                XCTAssertTrue(validation.isHittable)
                XCTAssertLessThanOrEqual(validation.frame.maxY, app.keyboards.firstMatch.frame.minY + 1,
                                         "Validation must remain readable above the keyboard")
                XCTAssertLessThanOrEqual(input.frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
                XCTAssertLessThanOrEqual(app.buttons["privacy.dictionary.cancel"].frame.maxY, app.keyboards.firstMatch.frame.minY + 1)
                XCTAssertTrue(input.exists && app.keyboards.firstMatch.exists, "Failed save preserves the focused draft")
                XCTAssertEqual(input.value as? String, "Ёжик Тестовый")
                capture("dictionary-ru-dark-03-duplicate")
                app.buttons["privacy.dictionary.cancel"].tap()
                XCTAssertFalse(input.exists)
                entry.tap()
                XCTAssertTrue(input.waitForExistence(timeout: 5))
                XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
                input.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
                input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Ёжик Тестовый".count))
                input.typeText("Ёжик Проверочный")
                XCTAssertEqual(input.value as? String, "Ёжик Проверочный")
                app.buttons["privacy.dictionary.save"].tap()
                let changed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                    "privacy.dictionary.entry.", "Ёжик Проверочный")).firstMatch
                XCTAssertTrue(changed.waitForExistence(timeout: 5))
                capture("dictionary-ru-dark-04-edited")
                changed.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
                    .press(forDuration: 0.05, thenDragTo: changed.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
                let delete = app.buttons["privacy.dictionary.delete"]
                XCTAssertTrue(delete.waitForExistence(timeout: 5))
                delete.tap()
                XCTAssertFalse(changed.exists)
                add.tap()
                XCTAssertTrue(input.waitForExistence(timeout: 5))
                input.typeText("Несохранённый черновик")
                app.buttons["privacy.dictionary.cancel"].tap()
                XCTAssertFalse(input.exists)
                XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "privacy.dictionary.entry.")).firstMatch.exists)
                capture("dictionary-ru-dark-05-deleted-cancelled")
            } else {
                app.buttons["privacy.dictionary.cancel"].tap()
                XCTAssertFalse(input.exists)
            }
            reveal("privacy.groups.illicit-remuneration", in: app)
            app.buttons["privacy.groups.illicit-remuneration"].tap()
            XCTAssertTrue(app.switches["privacy.groups.illicit-remuneration.enabled"].waitForExistence(timeout: 5))
            capture("dictionary-\(language)-\(appearance)-group-cleanup-copy")
            app.terminate()
        }
        #endif
    }

    private func openPrivacy(in app: XCUIApplication) {
        let sidebar = app.buttons["navigation.settings"]
        if sidebar.waitForExistence(timeout: 2) { sidebar.tap() }
        else {
            let settings = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Настройки", "Settings"])).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].firstMatch.waitForExistence(timeout: 10))
        reveal("settings.privacy", in: app)
        app.buttons["settings.privacy"].tap()
    }

    private func openRecording(in app: XCUIApplication) {
        let sidebar = app.buttons["navigation.settings"]
        if sidebar.waitForExistence(timeout: 2) { sidebar.tap() }
        else { app.tabBars.buttons["Настройки"].tap() }
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].firstMatch.waitForExistence(timeout: 10))
        reveal("settings.recording", in: app)
        capture("location-settings-open-root")
        app.buttons["settings.recording"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.recording.detail"].firstMatch.waitForExistence(timeout: 10))
        capture("location-settings-open-recording")
    }

    private func revealLocationSwitch(in app: XCUIApplication) {
        let location = app.switches["meetingLocation.enabled"]
        for step in 0..<6 where !location.isHittable {
            app.swipeUp()
            capture("location-settings-scroll-\(step)")
        }
        XCTAssertTrue(location.isHittable)
    }

    private func dismissLocationPermissionIfPresented() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        let appeared = alert.waitForExistence(timeout: 15)
        if ProcessInfo.processInfo.environment["PICHI_LOCATION_EXPECT_PERMISSION_PROMPT"] == "1" {
            XCTAssertTrue(appeared, "Fresh owned simulator must show the actual location permission prompt")
        }
        if appeared {
            capture("location-settings-system-permission")
            let deny = alert.buttons.matching(NSPredicate(format: "label IN %@",
                ["Don’t Allow", "Don't Allow", "Don’t allow", "Don't allow", "Не разрешать", "Запретить"])).firstMatch
            XCTAssertTrue(deny.exists, "Only deny location in the task-owned simulator")
            deny.tap()
            capture("location-settings-permission-denied")
        }
    }

    private func reveal(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        for step in 0..<6 where !button.isHittable {
            app.swipeUp()
            capture("reveal-\(identifier)-\(step)")
        }
        XCTAssertTrue(button.isHittable)
    }

    private func tapNativeSwitch(_ identifier: String, in app: XCUIApplication) throws {
        let row = app.switches[identifier]
        let bounds = row.frame
        let previousValue = row.value as? String
        print("Native setup switch \(identifier): bounds=\(bounds), children=\(app.switches.allElementsBoundByIndex.map { $0.frame })")
        if let control = app.switches.allElementsBoundByIndex.first(where: {
            bounds.contains($0.frame) && $0.frame.width > 0 && $0.frame.width < bounds.width / 2
        }) {
            XCTAssertTrue(control.isHittable)
            control.tap()
        } else {
            // A standalone Toggle can expose the native switch itself as the identified
            // element. Its trailing control is visible in the gated native screenshot.
            XCTAssertTrue(row.isHittable)
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        }
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (row.value as? String) != previousValue
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
    }

    private func capture(_ step: String) {
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "unverified-revision"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "setup-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        reviewNativeScreenshotIfRequested(step, namePrefix: "setup", revision: revision)
    }
}

/// Shared by opt-in simulator acceptance cases so each real UI action is reviewed
/// against its native frame before the next action. No production behavior changes.
func reviewNativeScreenshotIfRequested(_ step: String, namePrefix: String, revision: String) {
    #if targetEnvironment(simulator)
        if let directory = ProcessInfo.processInfo.environment["PICHI_SETUP_STEP_REVIEW_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let name = "\(namePrefix)-\(step)-\(revision)-\(UUID().uuidString.prefix(8))"
            let frame = root.appendingPathComponent(name + ".png")
            let acknowledgement = root.appendingPathComponent(name + ".continue")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: frame, options: .atomic)
                try XCUIApplication().debugDescription.write(to: root.appendingPathComponent(name + ".accessibility.txt"), atomically: true, encoding: .utf8)
                let marker = ["step": step, "revision": revision, "screenshot": frame.path,
                              "acknowledgement": acknowledgement.path]
                try JSONEncoder().encode(marker).write(to: root.appendingPathComponent("current-step.json"), options: .atomic)
                let deadline = Date().addingTimeInterval(300)
                while !FileManager.default.fileExists(atPath: acknowledgement.path), Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: acknowledgement.path),
                              "The exact native frame must be reviewed before the next step")
            } catch { XCTFail("Native review evidence could not be saved") }
        }
    #endif
}
