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
        capture("flow-09-normal-app")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["onboarding.next"].exists)
        capture("flow-10-restart")
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
        let sidebar = app.buttons["navigation.settings"]
        if sidebar.waitForExistence(timeout: 10) { sidebar.tap() }
        else { app.tabBars.buttons["Настройки"].tap() }
        let replay = app.buttons["settings.replaySetup"]
        XCTAssertTrue(replay.waitForExistence(timeout: 10))
        XCTAssertTrue(replay.isEnabled, "Replay is available while no meeting is active")
        capture("replay-00-settings")
        replay.tap()
        XCTAssertTrue(app.descendants(matching: .any)["onboarding.step.0"].firstMatch.waitForExistence(timeout: 10))
        capture("replay-01-welcome")
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
        let app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light", "-MobileSetupVersion", "1"]
        app.launch()
        openPrivacy(in: app)
        reveal("privacy.dictionary.add", in: app)
        let previousFixture = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
            "privacy.dictionary.entry.", "Ёжик Тестовый")).firstMatch
        if ProcessInfo.processInfo.environment["PICHI_SETUP_REMOVE_INTERRUPTED_TEST_ENTRY"] == "1", previousFixture.exists {
            capture("dictionary-fixture-before-cleanup")
            previousFixture.tap()
            XCTAssertTrue(app.buttons["privacy.dictionary.delete"].waitForExistence(timeout: 5))
            app.buttons["privacy.dictionary.delete"].tap()
            capture("dictionary-fixture-cleaned")
        }
        capture("dictionary-00-settings")
        app.buttons["privacy.dictionary.add"].tap()
        let input = app.descendants(matching: .any)["privacy.dictionary.phrase"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        input.typeText("Ёжик Тестовый")
        capture("dictionary-01-add")
        app.buttons["privacy.dictionary.save"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "privacy.dictionary.entry.")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertTrue(entry.label.contains("Ёжик Тестовый"))
        capture("dictionary-02-saved")
        entry.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // First focus moves the sheet when the software keyboard appears. Tap the
        // settled text field's trailing area to place the caret after the short fixture.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "Ёжик Тестовый".count))
        XCTAssertFalse((input.value as? String ?? "").contains("Ёжик"))
        input.typeText("Ёжик Проверочный")
        XCTAssertEqual(input.value as? String, "Ёжик Проверочный")
        app.buttons["privacy.dictionary.save"].tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertEqual(entry.label, "Ёжик Проверочный")
        capture("dictionary-03-edited")
        entry.tap()
        app.buttons["privacy.dictionary.delete"].tap()
        XCTAssertFalse(entry.exists)
        capture("dictionary-04-deleted")
        app.terminate()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "dark", "-MobileSetupVersion", "1"]
        app.launch()
        openPrivacy(in: app)
        reveal("privacy.dictionary.add", in: app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "privacy.dictionary.entry.")).firstMatch.exists)
        capture("dictionary-05-dark-restart")
    }

    private func openPrivacy(in app: XCUIApplication) {
        let sidebar = app.buttons["navigation.settings"]
        if sidebar.waitForExistence(timeout: 2) { sidebar.tap() }
        else { app.tabBars.buttons["Настройки"].tap() }
        XCTAssertTrue(app.buttons["settings.privacy"].waitForExistence(timeout: 10))
        app.buttons["settings.privacy"].tap()
    }

    private func openRecording(in app: XCUIApplication) {
        let sidebar = app.buttons["navigation.settings"]
        if sidebar.waitForExistence(timeout: 2) { sidebar.tap() }
        else { app.tabBars.buttons["Настройки"].tap() }
        XCTAssertTrue(app.buttons["settings.recording"].waitForExistence(timeout: 10))
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
            capture("dictionary-scroll-\(identifier)-\(step)")
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
