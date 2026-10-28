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
            openMeetings(title: language == "ru" ? "Встречи" : "Meetings")
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

    /// Navigation rows only. In-place controls such as pickers and actions stay on the root.
    private func destinationIdentifiers() -> [String] {
        let inPlace: Set<String> = ["settings.replaySetup", "settings.interfaceLanguage", "settings.appearance"]
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
    }
}
