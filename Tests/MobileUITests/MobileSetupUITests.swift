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
        app.launch()
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
        capture("flow-04-privacy-default")
        XCTAssertEqual(app.switches["privacy.pii"].value as? String, "0")
        if ProcessInfo.processInfo.environment["PICHI_SETUP_PREPARE_PRIVACY_E2E"] == "1" {
            app.switches["privacy.pii"].tap()
            capture("flow-04a-privacy-enabling")
            XCTAssertTrue(app.descendants(matching: .any)["privacy.pii.active"].firstMatch.waitForExistence(timeout: 180))
            capture("flow-04b-privacy-ready")
            app.switches["privacy.pii"].tap()
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
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        capture("flow-07-normal-app")
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["onboarding.next"].exists)
        capture("flow-08-restart")
    }

    /// Argument-domain page selection is only a native layout review. It does not
    /// claim that static pages prove downloads, model accuracy or enrollment acceptance.
    func testRussianNativeSetupPagesInBothAppearances() {
        let app = XCUIApplication()
        for appearance in ["light", "dark"] {
            for step in 0...5 {
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

    private func capture(_ step: String) {
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "unverified-revision"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "setup-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Simulator-only review gates let each real UI step be inspected before the
        // next action. This changes no production flow and never opens a microphone.
        if let directory = ProcessInfo.processInfo.environment["PICHI_SETUP_STEP_REVIEW_DIRECTORY"] {
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let name = "setup-\(step)-\(revision)"
            let frame = root.appendingPathComponent(name + ".png")
            let acknowledgement = root.appendingPathComponent(name + ".continue")
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try XCUIScreen.main.screenshot().pngRepresentation.write(to: frame, options: .atomic)
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
    }
}
