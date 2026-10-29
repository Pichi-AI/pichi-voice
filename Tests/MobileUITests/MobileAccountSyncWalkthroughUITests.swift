import XCTest
import UIKit

/// Opt-in walk through sign-in and cloud sync for the authorized QA account, in the order a new
/// user meets them: Account, sign-in, workspace, sync, Privacy, then one meeting and its status.
/// Credentials come from a one-shot host FIFO of its own. Sending is opt-in (each upload uses one
/// session of the account's balance). It never uses Sign out, which ends every session of the
/// account, and never switches the server's active organization; it retires this device at the end.
final class MobileAccountSyncWalkthroughUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The account walkthrough runs in an owned simulator")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_QA_ACCOUNT_WALKTHROUGH_PIPE"] != nil else {
            throw XCTSkip("Private one-shot QA input required")
        }
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru", "-ThemePreference", "light"]
        app.launchEnvironment["PICHI_DEBUG_AUDIO_INPUT"] = "1"
        app.launchEnvironment["PICHI_DEBUG_AUDIO_FILE"] = "meeting.wav"
        #endif
    }

    override func tearDown() {
        app?.terminate()
        super.tearDown()
    }

    func testAccountAndSyncWalkthrough() throws {
        var credential = try QALoginCredential(
            oneShotPipe: try XCTUnwrap(ProcessInfo.processInfo.environment["PICHI_QA_ACCOUNT_WALKTHROUGH_PIPE"]))
        defer { credential.password = "" }
        app.launch()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 30))
        open("settings"); settle(); capture("01-settings")
        app.buttons["settings.account"].tap(); settle()
        captureScrolling("02-account-signed-out")

        let email = app.textFields["account.legacy.email"], password = app.secureTextFields["account.legacy.password"]
        XCTAssertTrue(email.waitForExistence(timeout: 10) && password.exists, "A signed-out QA build offers email and password")
        email.tap(); email.typeText(credential.email)
        password.tap(); password.typeText(credential.password + "\n"); credential.password = ""
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        capture("03-filled")
        app.buttons["account.signIn"].tap()
        pause(1); capture("04-signing-in")
        // Signing in switches to the account's private profile and rebuilds the interface;
        // Account stays open and shows the result.
        let name = app.descendants(matching: .any)["account.displayName"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 60), "Account shows the signed-in QA account")
        settle(); captureScrolling("05-signed-in")

        // A workspace is chosen inside the server's active organization only. Without one,
        // nothing is sent and no session of the account's balance is used.
        let sync = app.switches["cloud.sync.toggle"]
        let sends = ProcessInfo.processInfo.environment["PICHI_ACCOUNT_SEND"] == "1"
        if sends, !(sync.exists && sync.isEnabled) {
            // Sign-in selects a verified workspace when it can; otherwise the workspace menu offers them.
            let selector = app.buttons["account.workspace.selector"]
            let workspace = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                "account.workspace.", "account.workspace.selector")).firstMatch
            if selector.exists { reveal(selector); selector.tap() }
            if workspace.waitForExistence(timeout: 5) {
                workspace.tap()
                XCTAssertTrue(name.waitForExistence(timeout: 30), "Choosing a workspace keeps Account open")
                pause(2); captureScrolling("06-workspace-chosen")
            }
        }
        reveal(sync); settle(); capture("07-sync-before")
        if sends, sync.exists, sync.isEnabled, sync.value as? String == "0" {
            tapSwitch(sync); pause(3); captureScrolling("08-sync-enabled")
        }

        backToSettings()
        app.buttons["settings.privacy"].tap(); settle()
        captureScrolling("09-privacy-signed-in")
        // Automatic sending withholds meetings recorded without data cleanup.
        let cleanup = app.switches["privacy.pii"]
        reveal(cleanup)
        if cleanup.exists, cleanup.value as? String == "0" {
            tapSwitch(cleanup); pause(2); capture("09b-cleanup-enabling")
            _ = app.descendants(matching: .any)["privacy.pii.active"].firstMatch.waitForExistence(timeout: 300)
            settle(); captureScrolling("09c-privacy-cleanup-on")
        }
        backToSettings()

        // One short meeting, then its status in the meeting page and the list.
        open("meetings"); settle(); capture("10-meetings")
        app.buttons["meeting.start"].tap()
        XCTAssertTrue(app.buttons["meeting.stop"].waitForExistence(timeout: 90), "Recording must start")
        pause(25); capture("11-recording")
        app.buttons["meeting.stop"].tap()
        // A sent meeting is encrypted on this device, so its page shows the protected state instead of text.
        let page = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@",
            ["meeting.transcript", "meeting.profile.hidden", "meeting.localContent.concealed"])).firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 300) || app.staticTexts.matching(NSPredicate(format: "label IN %@",
            ["Зашифрованная запись", "Encrypted recording"])).firstMatch.exists, "The stopped meeting opens its page")
        settle(); capture("12-transcript-status")
        for step in 0..<6 { pause(10); capture("13-status-after-\((step + 1) * 10)s") }
        open("meetings"); open("meetings"); settle(); capture("14-list-status")

        // With on-device encryption, a new meeting stays in the list as a locked row that opens its
        // protected page. Only without sending: nothing here is uploaded.
        if !sends {
            open("settings"); app.buttons["settings.privacy"].tap(); settle()
            let encrypt = app.switches["privacy.encryptLocalRecordings"]
            reveal(encrypt)
            let enabledHere = encrypt.exists && encrypt.value as? String == "0"
            if enabledHere { tapSwitch(encrypt); pause(1); captureScrolling("16-encryption-on") }
            backToSettings()
            open("meetings"); settle()
            app.buttons["meeting.start"].tap()
            XCTAssertTrue(app.buttons["meeting.stop"].waitForExistence(timeout: 90), "The encrypted recording must start")
            pause(8)
            app.buttons["meeting.stop"].tap()
            let protected = app.descendants(matching: .any)["meeting.localContent.concealed"].firstMatch
            XCTAssertTrue(protected.waitForExistence(timeout: 300), "An encrypted meeting opens its protected page")
            settle(); capture("17-encrypted-page")
            open("meetings"); open("meetings"); settle(); capture("18-encrypted-row")
            let locked = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@)",
                "history.session.", "Зашифрованная запись", "Encrypted recording")).firstMatch
            XCTAssertTrue(locked.waitForExistence(timeout: 5), "The encrypted meeting stays listed without its content")
            locked.tap()
            XCTAssertTrue(protected.waitForExistence(timeout: 5), "The locked row opens the protected page")
            capture("19-encrypted-row-opened")
            if enabledHere {
                open("settings"); app.buttons["settings.privacy"].tap(); settle()
                reveal(encrypt)
                if encrypt.exists, encrypt.value as? String == "1" { tapSwitch(encrypt) }
                backToSettings()
            }
        }

        // Switch account, in the account actions menu, retires only this device's legacy session.
        open("settings")
        let account = app.buttons["settings.account"]
        if account.waitForExistence(timeout: 10) { account.tap() }
        let actions = app.buttons["account.actions"]
        reveal(actions)
        if actions.exists && actions.isHittable { actions.tap() }
        let retire = app.buttons["account.switchPerson"]
        if retire.waitForExistence(timeout: 5) { retire.tap() }
        XCTAssertTrue(app.textFields["account.legacy.email"].waitForExistence(timeout: 30)
                      || app.buttons["meeting.start"].waitForExistence(timeout: 5), "This device is signed out locally")
        settle(); capture("15-signed-out-locally")
    }

    private func open(_ section: String) {
        let sidebar = app.buttons["navigation.\(section)"]
        if sidebar.exists && sidebar.isHittable { sidebar.tap(); return }
        let titles = ["meetings": ["Встречи", "Meetings"], "settings": ["Настройки", "Settings"]][section] ?? []
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", titles)).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "\(section) must be reachable")
        tab.tap()
    }

    private func backToSettings() {
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["Настройки", "Settings"])).firstMatch
        if back.waitForExistence(timeout: 5) { back.tap() }
    }

    private func reveal(_ element: XCUIElement) {
        let scroll = app.collectionViews.firstMatch
        for _ in 0..<6 where !(element.exists && element.isHittable) { scroll.swipeUp() }
    }

    /// A Form toggle can expose the whole row; its switch is at the trailing edge.
    private func tapSwitch(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }

    /// Captures the visible page, then each further screen until the visible text stops changing.
    private func captureScrolling(_ step: String) {
        capture(step + "-a")
        let scroll = app.collectionViews.firstMatch
        guard scroll.exists else { return }
        var previous = visibleText(), swipes = 0
        for page in 1..<6 {
            scroll.swipeUp(velocity: .slow); swipes += 1; settle()
            let current = visibleText()
            if current == previous { break }
            previous = current
            capture(step + "-" + String(UnicodeScalar(UInt8(97 + page))))
        }
        for _ in 0...swipes { scroll.swipeDown(velocity: .fast) }
    }

    private func visibleText() -> [String] {
        let frame = app.windows.firstMatch.frame
        return app.staticTexts.allElementsBoundByIndex.filter { $0.exists && frame.intersects($0.frame) }.map(\.label)
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
        attachment.name = "account-\(device)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
