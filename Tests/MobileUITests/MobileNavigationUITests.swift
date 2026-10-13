import XCTest

final class MobileNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["-PichiInterfaceLanguage", "en"]
        app.launch()
    }

    func testMVPSettingsAndOrientation() throws {
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        capture("01-ready-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        capture("02-ready-landscape")
        openNavigation("settings", title: "Settings")
        XCTAssertTrue(app.otherElements["settings.root"].exists || app.buttons["settings.privacy"].exists)
        app.buttons["settings.privacy"].tap()
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, "1")
        XCTAssertEqual(app.switches["privacy.pii"].value as? String, "0")
        capture("03-privacy-defaults")
        app.switches["privacy.saveAudio"].tap()
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, "0")
        capture("04-privacy-audio-off")
        app.switches["privacy.saveAudio"].tap()
        XCUIDevice.shared.orientation = .portrait
        capture("05-privacy-portrait")
    }

    func testHistoryIsSeparateFromCurrentMeeting() throws {
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        openNavigation("history", title: "History")
        XCTAssertTrue(app.otherElements["history.list"].exists || app.tables.firstMatch.exists || app.collectionViews.firstMatch.exists)
        XCTAssertFalse(app.buttons["meeting.start"].exists)
        capture("01-history")
        openNavigation("meetings", title: "Meetings")
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        capture("02-current-meeting")
    }

    private func openNavigation(_ identifier: String, title: String) {
        let sidebar = app.buttons["navigation.\(identifier)"]
        if sidebar.exists { sidebar.tap() } else { app.tabBars.buttons[title].tap() }
    }

    private func capture(_ step: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        attachment.name = "\(name)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
