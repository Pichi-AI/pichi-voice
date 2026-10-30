import XCTest
import UIKit

/// Opt-in walk through the ordinary app after a completed first setup, in the order a new user
/// tries it: look around, start a meeting, stop it, find it again and open Settings. It captures
/// native screenshots for review and checks that a recording owns the whole window.
/// Speech comes from the DEBUG file input staged in the app's Application Support/DebugAudioInput.
final class MobileFirstRunWalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!
    private var language = "ru"

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The walkthrough runs in an owned simulator")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_FIRST_RUN_WALKTHROUGH"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_PICHI_FIRST_RUN_WALKTHROUGH=1 after a completed first setup")
        }
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        language = ProcessInfo.processInfo.environment["PICHI_WALKTHROUGH_LANGUAGE"] ?? "ru"
        let appearance = ProcessInfo.processInfo.environment["PICHI_WALKTHROUGH_THEME"] ?? "light"
        app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
        app.launchEnvironment["PICHI_DEBUG_AUDIO_INPUT"] = "1"
        app.launchEnvironment["PICHI_DEBUG_AUDIO_FILE"] = "meeting.wav"
        #endif
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testNewUserWalkthrough() throws {
        app.launch()
        let start = app.buttons["meeting.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        settle(); capture("01-first-screen")

        // A new user looks around before recording anything.
        open("settings"); settle(); capture("02-settings")
        let kiosk = app.buttons["settings.kiosk"]
        reveal(kiosk); kiosk.tap(); settle(); capture("03-restricted-mode")
        backToSettings()
        open("meetings")
        app.buttons["meeting.settings"].tap(); settle(); capture("04-recording-sheet")
        app.buttons["settings.recording.done"].tap()

        // The first meeting owns the whole window until it stops.
        start.tap(); capture("05-start-tapped")
        let stop = app.buttons["meeting.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 90), "Recording must start")
        settle(); capture("06-recording-started")
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Sections are hidden while recording")
        XCTAssertFalse(app.buttons["navigation.settings"].exists, "The sidebar is hidden while recording")
        XCTAssertTrue(app.descendants(matching: .any)["meeting.recordingStatus"].firstMatch.exists)
        pause(15); capture("07-recording-15s")
        pause(20); capture("08-recording-later")

        stop.tap()
        pause(1); capture("09-stopping")
        let transcript = app.descendants(matching: .any)["meeting.transcript"].firstMatch
        if !transcript.waitForExistence(timeout: 4) { capture("10-processing") }
        XCTAssertTrue(transcript.waitForExistence(timeout: 300), "The stopped meeting opens with its transcript")
        settle(); capture("11-transcript")

        // The meeting is in the list, with Start below it for the next one.
        open("meetings"); settle(); capture("12-meetings-one-meeting")
        XCTAssertTrue(start.waitForExistence(timeout: 5) && start.isHittable)
        let meeting = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).firstMatch
        XCTAssertTrue(meeting.exists)
        // The default name leaves the start to the row's second line and to the page.
        let name = language == "ru" ? "Запись" : "Recording"
        XCTAssertTrue(meeting.label.contains(name) && !meeting.label.contains("\(name) · "), meeting.label)
        meeting.tap(); settle(); capture("13-meeting-again")
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[name].exists, "The page title is the default name alone")
    }

    private func open(_ section: String) {
        let sidebar = app.buttons["navigation.\(section)"]
        if sidebar.exists && sidebar.isHittable { sidebar.tap(); return }
        let titles = ["meetings": ["Записи", "Recordings"], "settings": ["Настройки", "Settings"]][section] ?? []
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(section) must be reachable")
        tab.tap()
    }

    /// The iPad navigation bar also holds the sidebar toggle, so the first button is not Back.
    private func backToSettings() {
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Настройки", "Settings"])).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "A settings page must return to Settings")
        back.tap()
    }

    private func reveal(_ element: XCUIElement) {
        let scroll = app.collectionViews.firstMatch
        for _ in 0..<4 where !(element.exists && element.isHittable) { scroll.swipeUp() }
    }

    private func pause(_ seconds: TimeInterval) {
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(value: false), object: nil)],
                           timeout: seconds)
    }

    private func settle() { pause(0.8) }

    private func capture(_ step: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        attachment.name = "walkthrough-\(device)-\(language)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
