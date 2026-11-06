import XCTest
import UIKit

/// Native navigation and durable settings over an owned, empty simulator container.
/// The existing review admission prevents unrelated model/account bootstrap work.
final class MobileCISmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("CI smoke requires its owned simulator")
        #else
        continueAfterFailure = false
        app = XCUIApplication()
        #endif
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    private func launch(language: String = "en", appearance: String = "light") {
        app.launchArguments = ["-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1",
            "-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
        app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 20))
    }

    private func navigate(_ section: String, title: String) {
        let sidebar = app.buttons["navigation.\(section)"]
        if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        else {
            let tab = app.tabBars.buttons[title]
            XCTAssertTrue(tab.waitForExistence(timeout: 5) && tab.isHittable)
            tab.tap()
        }
    }

    private func capture(_ state: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "ci-\(state)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testNavigationAndNestedSettingsReturnToRecordings() {
        launch()
        navigate("settings", title: "Settings")
        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["settings.privacy"].tap()
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        capture("privacy-en-light")
        navigate("meetings", title: "Recordings")
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        capture("recordings-en-light")
    }

    func testRussianDarkNativeSettings() {
        launch(language: "ru", appearance: "dark")
        navigate("settings", title: "Настройки")
        XCTAssertTrue(app.buttons["settings.privacy"].waitForExistence(timeout: 5))
        app.buttons["settings.privacy"].tap()
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        capture("privacy-ru-dark")
    }

    func testSaveAudioChoicePersistsAcrossOrdinaryRelaunch() throws {
        launch()
        navigate("settings", title: "Settings")
        app.buttons["settings.privacy"].tap()
        let setting = app.switches["privacy.saveAudio"]
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(setting.value as? String)
        XCTAssertTrue(["0", "1"].contains(original))
        // The trailing coordinate is the native UISwitch in the identified row.
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let expected = original == "0" ? "1" : "0"
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: setting)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        app.terminate()
        launch()
        navigate("settings", title: "Settings")
        app.buttons["settings.privacy"].tap()
        XCTAssertTrue(setting.waitForExistence(timeout: 5))
        XCTAssertEqual(setting.value as? String, expected)
        capture("privacy-persisted")
        setting.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", original), object: setting)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    }

    func testFixtureAdmissionDoesNotSkipOrdinaryNavigation() {
        XCTAssertTrue(MobileNavigationUITests.needsStagedFixture("testMeetingLocationTitlesInBothLanguagesAndThemes", environment: [:]))
        XCTAssertFalse(MobileNavigationUITests.needsStagedFixture("testMeetingLocationTitlesInBothLanguagesAndThemes", environment: ["PICHI_MOBILE_STAGED_UI_FIXTURES": "1"]))
        XCTAssertTrue(MobileNavigationUITests.needsStagedFixture("testMeetingLocationTitlesInBothLanguagesAndThemes", environment: ["PICHI_MOBILE_STAGED_UI_FIXTURES": "false"]))
        XCTAssertFalse(MobileNavigationUITests.needsStagedFixture("testMVPSettingsAndOrientation", environment: [:]))
    }
}
