import XCTest
import UIKit

/// Opt-in native walk through every Settings destination for visual review. It opens pages,
/// scrolls and captures screenshots only: no preference, model, account or recording changes.
final class MobileSettingsReviewUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Settings visual review runs in an owned simulator")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_SETTINGS_VISUAL_REVIEW"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_PICHI_SETTINGS_VISUAL_REVIEW=1 to capture every settings page")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        #endif
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    /// Mobile CPU policy is visible before preparation, without claiming a live session.
    func testMobileCPUPreferenceOnModelPageInRussianLightAndDark() throws {
        for appearance in ["light", "dark"] {
            app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
            app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", appearance,
                                   "-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1"]
            app.launch()
            XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
            capture("cpu-preference-ru-\(appearance)-home")
            openSettings(title: "Настройки")
            capture("cpu-preference-ru-\(appearance)-settings")
            let models = app.buttons["settings.models"]
            reveal(models)
            XCTAssertTrue(models.isHittable)
            models.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.models.detail"].firstMatch.waitForExistence(timeout: 10))
            let preference = app.staticTexts["model.computePreference.gigaam-v3-eou"]
            reveal(preference)
            XCTAssertTrue(preference.exists && preference.isHittable)
            XCTAssertEqual(preference.label, "CPU для записи в фоне")
            XCTAssertFalse(app.descendants(matching: .any)["model.executionStatus.gigaam-v3-eou"].firstMatch.exists,
                           "An unprepared provider must not claim active execution")
            settle()
            capture("cpu-preference-ru-\(appearance)-models")
            app.terminate()
        }
    }

    /// Offline legal resources are reachable from the guest Settings stack in every app appearance.
    func testLicensesInBothLanguagesAndThemes() throws {
        for (language, appearance) in [("ru", "light"), ("ru", "dark"), ("en", "light"), ("en", "dark")] {
            let settingsTitle = language == "ru" ? "Настройки" : "Settings"
            let licensesTitle = language == "ru" ? "Лицензии" : "Licenses"
            let prefix = "licenses-\(language)-\(appearance)"
            app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                                   "-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1"]
            app.launch()
            openSettings(title: settingsTitle)
            let licenses = app.buttons["settings.licenses"]
            reveal(licenses)
            XCTAssertTrue(licenses.exists && licenses.isHittable)
            licenses.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.licenses.detail"].firstMatch.waitForExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars[licensesTitle].exists)
            capture(prefix + "-list")
            let component = app.buttons["licenses.component.fluidvoice"]
            XCTAssertTrue(component.exists && component.isHittable)
            component.tap()
            XCTAssertTrue(app.descendants(matching: .any)["licenses.component.detail"].firstMatch.waitForExistence(timeout: 5))
            let license = app.staticTexts["licenses.document.FluidVoice-LICENSE.txt"]
            XCTAssertTrue(license.exists)
            XCTAssertTrue(license.label.contains("GNU GENERAL PUBLIC LICENSE"))
            XCTAssertTrue(license.label.contains("How to Apply These Terms to Your New Programs"), "The full bundled text must load")
            capture(prefix + "-detail")
            app.navigationBars.buttons[licensesTitle].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.licenses.detail"].firstMatch.waitForExistence(timeout: 5))
            app.navigationBars.buttons[settingsTitle].firstMatch.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.root"].firstMatch.waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testEverySettingsPageInBothLanguagesAndThemes() throws {
        for (language, appearance) in [("ru", "light"), ("ru", "dark"), ("en", "light")] {
            let settingsTitle = language == "ru" ? "Настройки" : "Settings"
            let prefix = "\(language)-\(appearance)"
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                                   "-MobileSetupVersion", "1"]
            app.launch()
            openSettings(title: settingsTitle)
            XCTAssertTrue(app.descendants(matching: .any)["settings.root"].firstMatch.waitForExistence(timeout: 10))
            settle()
            captureScrolling("\(prefix)-00-root")
            for (index, identifier) in destinationIdentifiers().enumerated() {
                let row = app.buttons[identifier]
                reveal(row)
                XCTAssertTrue(row.isHittable, "\(identifier) must be reachable")
                row.tap()
                settle()
                let page = identifier.replacingOccurrences(of: ".", with: "-")
                captureScrolling("\(prefix)-\(String(format: "%02d", index + 1))-\(page)")
                let back = app.navigationBars.buttons[settingsTitle].firstMatch
                XCTAssertTrue(back.waitForExistence(timeout: 5), "\(identifier) must return to Settings")
                back.tap()
                XCTAssertTrue(app.descendants(matching: .any)["settings.root"].firstMatch.waitForExistence(timeout: 5))
            }
            // The Recording sheet on the start screen is the second entry to the same page.
            openMeetings(title: language == "ru" ? "Записи" : "Recordings")
            let quickSettings = app.buttons["meeting.settings"]
            XCTAssertTrue(quickSettings.waitForExistence(timeout: 10))
            quickSettings.tap()
            settle()
            // A downward swipe at the top would dismiss the sheet, so it stays where it ends.
            captureScrolling("\(prefix)-90-recording-sheet", returnToTop: false)
            let done = app.buttons["settings.recording.done"]
            XCTAssertTrue(done.waitForExistence(timeout: 5))
            done.tap()
        }
    }

    /// The settings column in both orientations: a wide iPad detail keeps a readable width.
    func testSettingsColumnInBothOrientations() throws {
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light", "-MobileSetupVersion", "1"]
        app.launch()
        openSettings(title: "Настройки")
        let root = app.descendants(matching: .any)["settings.root"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 10))
        for (name, orientation) in [("portrait", UIDeviceOrientation.portrait), ("landscape", .landscapeLeft)] {
            XCUIDevice.shared.orientation = orientation
            settle()
            capture("ru-light-\(name)-root")
            let recording = app.buttons["settings.recording"]
            reveal(recording)
            recording.tap()
            XCTAssertTrue(app.descendants(matching: .any)["settings.recording.detail"].firstMatch.waitForExistence(timeout: 5))
            settle()
            capture("ru-light-\(name)-recording")
            app.navigationBars.buttons["Настройки"].firstMatch.tap()
            XCTAssertTrue(root.waitForExistence(timeout: 5))
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Opt-in: downloads the small Whisper Tiny model to exercise installed-model rows, the full-row
    /// action target and the Delete confirmation, then deletes it again. The selected model is unchanged.
    func testModelRowsDownloadAndConfirmDeletion() throws {
        guard ProcessInfo.processInfo.environment["PICHI_SETTINGS_MODEL_ACTIONS"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_PICHI_SETTINGS_MODEL_ACTIONS=1 to download and delete Whisper Tiny")
        }
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light", "-MobileSetupVersion", "1"]
        app.launch()
        openSettings(title: "Настройки")
        let models = app.buttons["settings.models"]
        reveal(models)
        models.tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.models.detail"].firstMatch.waitForExistence(timeout: 5))
        let download = app.buttons["model.download.whisper-tiny"]
        let delete = app.buttons["model.delete.whisper-tiny"]
        // The model's rows can be below the fold on a phone; find its section before deciding.
        reveal(app.buttons["model.details.whisper-tiny"])
        for _ in 0..<3 where !delete.exists && !download.exists { app.collectionViews.firstMatch.swipeUp() }
        if !delete.exists {
            reveal(download)
            // An action is the whole native row, not only its text line.
            XCTAssertGreaterThanOrEqual(download.frame.height + 0.001, 44)
            download.tap()
            XCTAssertTrue(delete.waitForExistence(timeout: 240), "Whisper Tiny must finish downloading")
        }
        reveal(delete)
        XCTAssertGreaterThanOrEqual(delete.frame.height + 0.001, 44)
        settle()
        capture("ru-light-model-installed")
        delete.tap()
        // iOS exposes a dialog action as a button nested in a button with the same identifier.
        let confirm = app.buttons["model.delete.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "Deleting a model asks first")
        capture("ru-light-model-delete-confirmation")
        confirm.tap()
        XCTAssertTrue(download.waitForExistence(timeout: 30))
        settle()
        capture("ru-light-model-deleted")
    }

    /// Navigation rows only. In-place controls such as pickers and actions stay on the root.
    private func destinationIdentifiers() -> [String] {
        let inPlace: Set<String> = ["settings.replaySetup", "settings.interfaceLanguage", "settings.appearance", "settings.privacyPolicy"]
        let rows = app.collectionViews.firstMatch.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "settings."))
        var identifiers: [String] = []
        for _ in 0..<3 {
            for row in rows.allElementsBoundByIndex where !inPlace.contains(row.identifier) && !identifiers.contains(row.identifier) {
                identifiers.append(row.identifier)
            }
            app.collectionViews.firstMatch.swipeUp()
        }
        for _ in 0..<3 { app.collectionViews.firstMatch.swipeDown() }
        XCTAssertFalse(identifiers.isEmpty, "Settings must list its destinations")
        return identifiers
    }

    private func openSettings(title: String) { openSection("settings", title: title) }
    private func openMeetings(title: String) { openSection("meetings", title: title) }

    private func openSection(_ identifier: String, title: String) {
        let sidebar = app.buttons["navigation.\(identifier)"]
        if sidebar.waitForExistence(timeout: 5) && sidebar.isHittable { sidebar.tap() }
        else {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 5) && tab.isHittable, "\(title) must be reachable")
            tab.tap()
        }
    }

    private func reveal(_ element: XCUIElement) {
        let scroll = app.collectionViews.firstMatch
        for _ in 0..<4 where !(element.exists && element.isHittable) { scroll.swipeUp() }
        for _ in 0..<4 where !(element.exists && element.isHittable) { scroll.swipeDown() }
    }

    /// Captures the visible page, then each further screen until the visible text stops changing.
    private func captureScrolling(_ step: String, returnToTop: Bool = true) {
        capture(step + "-a")
        let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
        guard scroll.exists else { return }
        var previous = visibleText()
        var swipes = 0
        for page in 1..<8 {
            scroll.swipeUp(velocity: .slow)
            swipes += 1
            settle()
            let current = visibleText()
            if current == previous { break }
            previous = current
            capture(step + "-" + String(UnicodeScalar(UInt8(97 + page))))
        }
        if returnToTop { for _ in 0...swipes { scroll.swipeDown(velocity: .fast) } }
    }

    private func visibleText() -> [String] {
        let frame = app.windows.firstMatch.frame
        return app.staticTexts.allElementsBoundByIndex.filter { $0.exists && frame.intersects($0.frame) }.map(\.label)
    }

    private func settle() {
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(value: false), object: nil)], timeout: 0.8)
    }

    private func capture(_ step: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        attachment.name = "settings-\(device)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        reviewNativeScreenshotIfRequested(step, namePrefix: "settings-\(device)", revision: revision)
    }
}
