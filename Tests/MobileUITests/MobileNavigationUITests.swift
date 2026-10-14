import XCTest
import UIKit
import CoreText

final class MobileNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments += ["-PichiInterfaceLanguage", "en"]
        app.launch()
        waitForOrientation(portrait: true)
    }

    func testMVPSettingsAndOrientation() throws {
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        XCTAssertGreaterThanOrEqual(app.buttons["meeting.start"].frame.height, 44)
        capture("01-ready-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(portrait: false)
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        capture("02-ready-landscape")
        if app.tabBars.firstMatch.exists {
            let tabBar = app.tabBars.firstMatch.frame
            XCTAssertTrue(app.buttons["meeting.start"].frame.intersection(tabBar).isEmpty,
                          "The floating tab bar must not cover the recording action")
            let storageCaption = app.descendants(matching: .any)["meeting.storageNote"].firstMatch
            XCTAssertTrue(storageCaption.waitForExistence(timeout: 5))
            XCTAssertGreaterThan(storageCaption.frame.height, 0)
            XCTAssertTrue(storageCaption.frame.intersection(tabBar).isEmpty,
                          "The floating tab bar must not cover the storage caption")
        }
        openNavigation("settings", title: "Settings")
        XCTAssertTrue(app.otherElements["settings.root"].exists || app.buttons["settings.privacy"].exists)
        app.buttons["settings.privacy"].tap()
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        // The app may already contain user-selected preferences. Fresh defaults belong to
        // isolated SettingsStore tests; UI navigation must preserve this installation's choice.
        let originalAudioChoice = try XCTUnwrap(app.switches["privacy.saveAudio"].value as? String)
        XCTAssertTrue(["0", "1"].contains(originalAudioChoice))
        XCTAssertTrue(["0", "1"].contains(app.switches["privacy.pii"].value as? String ?? ""))
        capture("03-privacy-settings")
        if originalAudioChoice == "1" { try tapNativeSwitch("privacy.saveAudio") }
        capture("04-privacy-after-tap")
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: app.switches["privacy.saveAudio"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        capture("04-privacy-audio-off")
        try tapNativeSwitch("privacy.saveAudio")
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: app.switches["privacy.saveAudio"])
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 3), .completed)
        if originalAudioChoice == "0" { try tapNativeSwitch("privacy.saveAudio") }
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(portrait: true)
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

    func testSectionNavigationSwitchesImmediatelyFromSettingsDetails() throws {
        let destinations = ["general", "recording", "models", "privacy"]
        for detail in destinations {
            openNavigation("settings", title: "Settings")
            XCTAssertTrue(app.buttons["settings.\(detail)"].waitForExistence(timeout: 5))
            app.buttons["settings.\(detail)"].tap()
            let visibleDetail = app.descendants(matching: .any)["settings.\(detail).detail"].firstMatch
            XCTAssertTrue(visibleDetail.waitForExistence(timeout: 5))
            capture("settings-\(detail)-opened")
            if detail == "recording" { XCTAssertFalse(app.buttons["settings.recording.done"].exists) }

            openNavigation("meetings", title: "Meetings")
            XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5), "A pushed \(detail) view must not cover Meetings")
            XCTAssertTrue(app.buttons["meeting.start"].isHittable)
            capture("settings-\(detail)-to-meetings")
            openNavigation("history", title: "History")
            XCTAssertFalse(app.buttons["meeting.start"].exists)
            XCTAssertTrue(app.descendants(matching: .any)["history.list"].firstMatch.waitForExistence(timeout: 5))
            capture("settings-\(detail)-to-history")

            openNavigation("settings", title: "Settings")
            XCTAssertTrue(visibleDetail.waitForExistence(timeout: 5), "Returning to Settings preserves its own detail")
            let back = app.navigationBars.buttons["Settings"].firstMatch
            XCTAssertTrue(back.waitForExistence(timeout: 5))
            back.tap()
            XCTAssertTrue(app.buttons["settings.\(detail)"].waitForExistence(timeout: 5))
            capture("settings-\(detail)-back-to-root")
        }
    }

    func testRotatingDeepSettingsAndClosingRecordingSheet() throws {
        openNavigation("settings", title: "Settings")
        app.buttons["settings.models"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["settings.models.detail"].firstMatch.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(portrait: false)
        XCTAssertTrue(app.descendants(matching: .any)["settings.models.detail"].firstMatch.waitForExistence(timeout: 5),
                      "Rotating the layout must preserve the selected settings detail")
        capture("models-landscape")
        openNavigation("meetings", title: "Meetings")
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        app.buttons["meeting.settings"].tap()
        let done = app.buttons["settings.recording.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        capture("recording-settings-sheet")
        done.tap()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["meeting.start"].isHittable)
        openNavigation("history", title: "History")
        capture("sheet-closed-history")
    }

    func testReselectingSettingsReturnsToRoot() throws {
        for detail in ["general", "recording", "models", "privacy"] {
            openNavigation("settings", title: "Settings")
            let row = app.buttons["settings.\(detail)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.tap()
            let visibleDetail = app.descendants(matching: .any)["settings.\(detail).detail"].firstMatch
            XCTAssertTrue(visibleDetail.waitForExistence(timeout: 5))
            capture("reselect-\(detail)-opened")
            openNavigation("settings", title: "Settings")
            XCTAssertTrue(row.waitForExistence(timeout: 5), "Reselecting Settings must return to its root")
            XCTAssertTrue(row.isHittable)
            XCTAssertFalse(visibleDetail.exists)
            capture("reselect-\(detail)-root")
        }
        openNavigation("meetings", title: "Meetings")
        openNavigation("meetings", title: "Meetings")
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        openNavigation("history", title: "History")
        openNavigation("history", title: "History")
        XCTAssertTrue(app.descendants(matching: .any)["history.list"].firstMatch.waitForExistence(timeout: 5))
    }

    func testReselectingHistoryClosesMeetingDetail() throws {
        openNavigation("history", title: "History")
        let meeting = app.buttons["history.session.DDD86147-F0B9-4B13-88B5-099B1E0D8BA5"]
        guard meeting.waitForExistence(timeout: 5) else {
            throw XCTSkip("Stage the synthetic NavigationMeeting.json in the simulator's meeting store before this test")
        }
        meeting.tap()
        capture("history-detail-after-row-tap")
        XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
        capture("history-detail-opened")
        openNavigation("meetings", title: "Meetings")
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
        openNavigation("history", title: "History")
        XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5),
                      "Switching sections preserves the history detail until History is reselected")
        openNavigation("history", title: "History")
        XCTAssertTrue(app.descendants(matching: .any)["history.list"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(meeting.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["meeting.transcript"].firstMatch.exists)
        capture("history-reselected-root")
    }

    func testRussianSettingsAndModelsInDarkAppearance() throws {
        app.terminate()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "dark"]
        app.launch()
        waitForOrientation(portrait: true)
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
        capture("01-russian-dark-ready")
        openNavigation("settings", title: "Настройки")
        app.buttons["settings.models"].tap()
        capture("02-russian-dark-models-top")
        XCTAssertTrue(app.staticTexts["Pichi GigaAM v3"].exists)
        for step in 0..<3 where !app.staticTexts["Whisper Tiny"].exists {
            app.collectionViews.firstMatch.swipeUp()
            capture("02-models-scroll-\(step)")
        }
        XCTAssertTrue(app.staticTexts["Whisper Tiny"].waitForExistence(timeout: 5))
        capture("02-russian-dark-models")
    }

    func testWordTimedHistoryFlowsAndParticipantsWrapInBothOrientationsAndThemes() throws {
        let fixtureID = "C2A6906B-356C-4D80-B963-E125DF244703"
        let sentence = "Здравствуйте, давайте обсудим инструкцию. После встречи я пришлю документ."
        for appearance in ["light", "dark"] {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", appearance]
            app.launch()
            waitForOrientation(portrait: true)
            openNavigation("history", title: "История")
            let meeting = app.buttons["history.session.\(fixtureID)"]
            guard meeting.waitForExistence(timeout: 5) else {
                throw XCTSkip("Stage the synthetic WordTimingMeeting.json in the simulator meeting store")
            }
            meeting.tap()
            XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
            let first = app.buttons["transcript.speaker.00000000-0000-0000-0000-000000000065"]
            let second = app.buttons["transcript.speaker.00000000-0000-0000-0000-000000000066"]
            XCTAssertTrue(first.waitForExistence(timeout: 5) && second.exists)
            XCTAssertEqual(first.frame.minY, second.frame.minY, accuracy: 2,
                           "Participants must occupy the available width instead of one full row each")
            capture("word-timing-\(appearance)-portrait-participants")
            let body = app.staticTexts[sentence].firstMatch
            XCTAssertTrue(body.waitForExistence(timeout: 5), "Canonical words must appear in one readable paragraph")
            XCTAssertFalse(app.staticTexts["обсудим"].exists, "Each word must not become a separate display row")
            try revealParagraphAboveNavigation(body, step: "word-timing-\(appearance)-portrait-reading")
            capture("word-timing-\(appearance)-portrait-paragraph")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            XCTAssertTrue(body.waitForExistence(timeout: 5))
            try revealParagraphAboveNavigation(body, step: "word-timing-\(appearance)-landscape-reading")
            capture("word-timing-\(appearance)-landscape-paragraph")
        }
    }

    private func revealParagraphAboveNavigation(_ paragraph: XCUIElement, step: String) throws {
        let scroll = app.scrollViews.matching(identifier: "meeting.transcript").firstMatch
        XCTAssertTrue(scroll.exists)
        for attempt in 0..<6 {
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : app.windows.firstMatch.frame.minY
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.windows.firstMatch.frame.maxY
            if paragraph.isHittable && paragraph.frame.minY >= top && paragraph.frame.maxY <= bottom { return }
            let upwards = paragraph.frame.maxY > bottom
            let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.65 : 0.35))
            let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.35 : 0.65))
            from.press(forDuration: 0.05, thenDragTo: to)
            capture("\(step)-scroll-\(attempt)")
        }
        XCTFail("The full paragraph must be readable above the navigation controls")
    }


    func testNativeRussianGlyphCoverage() throws {
        let letters = Array("АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя".utf16)
        let designs: [UIFontDescriptor.SystemDesign] = [.default, .serif, .rounded, .monospaced]
        let sizes: [CGFloat] = [12, 17, 22, 34]
        let weights: [UIFont.Weight] = [.regular, .medium, .semibold, .bold]
        for design in designs {
            for size in sizes {
                for weight in weights {
                    let native = UIFont.systemFont(ofSize: size, weight: weight)
                    let descriptor = try XCTUnwrap(native.fontDescriptor.withDesign(design))
                    let font = UIFont(descriptor: descriptor, size: size)
                    let coreText = CTFontCreateWithName(font.fontName as CFString, size, nil)
                    var glyphs = Array(repeating: CGGlyph(0), count: letters.count)
                    XCTAssertTrue(CTFontGetGlyphsForCharacters(coreText, letters, &glyphs, letters.count),
                        "Direct Russian glyphs missing in \(font.fontName), \(design), \(size), \(weight)")
                    XCTAssertFalse(glyphs.contains(0))
                }
            }
        }
    }

    private func waitForOrientation(portrait: Bool) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = self.app.windows.firstMatch.frame
            guard frame.width > 0, frame.height > 0 else { return false }
            return (portrait ? frame.height > frame.width : frame.width > frame.height)
                && (self.app.buttons["meeting.start"].exists ? self.app.buttons["meeting.start"].isHittable : true)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
    }

    private func openNavigation(_ identifier: String, title: String) {
        let sidebar = app.buttons["navigation.\(identifier)"]
        if sidebar.exists { sidebar.tap() } else { app.tabBars.buttons[title].tap() }
        capture("navigation-\(identifier)")
    }

    private func tapNativeSwitch(_ identifier: String) throws {
        let row = app.switches[identifier]
        // SwiftUI exposes an identified full-width row plus its native UISwitch.
        // A row-center tap lands on the label; operate the observed backing control.
        let bounds = row.frame
        let control = try XCTUnwrap(app.switches.allElementsBoundByIndex.first {
            bounds.contains($0.frame) && $0.frame.width > 0 && $0.frame.width < bounds.width / 2
        })
        XCTAssertTrue(control.isHittable)
        control.tap()
    }

    private func capture(_ step: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        attachment.name = "\(name)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
