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
        openNavigation("settings", title: "Settings")
        XCTAssertTrue(app.otherElements["settings.root"].exists || app.buttons["settings.privacy"].exists)
        app.buttons["settings.privacy"].tap()
        XCTAssertTrue(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["privacy.saveAudio"].value as? String, "1")
        XCTAssertEqual(app.switches["privacy.pii"].value as? String, "0")
        capture("03-privacy-defaults")
        try tapNativeSwitch("privacy.saveAudio")
        capture("04-privacy-after-tap")
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: app.switches["privacy.saveAudio"])
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed)
        capture("04-privacy-audio-off")
        try tapNativeSwitch("privacy.saveAudio")
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
