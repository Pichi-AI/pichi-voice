import Darwin
import Foundation
import XCTest

/// Opt-in for the authorized QA account. One-shot host FIFO keeps credentials out
/// of argv, test environment, regular files and committed fixtures.
final class MobileLegacyQALoginUITests: XCTestCase {
    func testExistingQALoginRestoresAndRetiresLocally() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Requires an owned simulator")
        #else
        guard let path = ProcessInfo.processInfo.environment["PICHI_QA_LOGIN_PIPE"] else { throw XCTSkip("Private one-shot input required") }
        continueAfterFailure = false
        var credential = try QALoginCredential(oneShotPipe: path)
        defer { credential.password = "" }
        let app = XCUIApplication()
        app.launchArguments = ["-PichiInterfaceLanguage", "en", "-ThemePreference", "light", "-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1"]
        app.launch(); defer { app.terminate() }
        openAccount(app)
        XCTAssertEqual(app.staticTexts["account.legacy.destination"].label, "ai-call-studio.qa.aspirity.com")
        let email = app.textFields["account.legacy.email"], password = app.secureTextFields["account.legacy.password"]
        XCTAssertTrue(email.waitForExistence(timeout: 10) && password.exists)
        email.tap(); email.typeText(credential.email)
        password.tap(); password.typeText(credential.password + "\n"); credential.password = ""
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        capture("secure-entry")
        app.buttons["account.signIn"].tap()
        let transitioned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["meeting.start"].isHittable || app.descendants(matching: .any)["account.displayName"].firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [transitioned], timeout: 45), .completed)
        openAccount(app)
        XCTAssertTrue(app.descendants(matching: .any)["account.displayName"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["account.signIn"].exists)
        let workspace = app.buttons["account.workspace.selector"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 10), "Fresh sign-in selects a verified workspace without another tap")
        let selectedWorkspace = workspace.value as? String
        XCTAssertNotNil(selectedWorkspace)
        XCTAssertFalse(selectedWorkspace?.isEmpty ?? true)
        XCTAssertNotEqual(selectedWorkspace, "Choose a workspace")
        let automatic = app.switches["cloud.sync.toggle"]
        XCTAssertTrue(automatic.waitForExistence(timeout: 10))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == YES"), object: automatic)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertEqual(automatic.value as? String, "0", "Workspace selection never grants upload consent")
        capture("fresh-account-automatic-workspace")
        app.terminate(); app.launch(); openAccount(app)
        XCTAssertTrue(app.descendants(matching: .any)["account.displayName"].firstMatch.waitForExistence(timeout: 45))
        XCTAssertFalse(app.buttons["account.signIn"].exists)
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        XCTAssertEqual(workspace.value as? String, selectedWorkspace, "Restoration preserves the committed workspace")
        XCTAssertEqual(automatic.value as? String, "0")
        capture("restored")
        let actions = app.buttons["account.actions"]
        XCTAssertTrue(actions.waitForExistence(timeout: 5) && actions.isHittable)
        actions.tap()
        // Native UIMenu exposes the localized action title, not its SwiftUI identifier.
        let change = app.buttons["Switch account"]
        for _ in 0..<6 where !change.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(change.isHittable); change.tap()
        let retired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.buttons["meeting.start"].isHittable || app.textFields["account.legacy.email"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [retired], timeout: 20), .completed)
        openAccount(app)
        XCTAssertTrue(app.textFields["account.legacy.email"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.descendants(matching: .any)["account.displayName"].firstMatch.exists); capture("local-retirement")
        #endif
    }
    private func openAccount(_ app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        if settings.waitForExistence(timeout: 15) && settings.isHittable { settings.tap() }
        else {
            let sidebar = app.buttons["navigation.settings"]
            XCTAssertTrue(sidebar.isHittable); sidebar.tap()
        }
        let account = app.buttons["settings.account"]
        if account.waitForExistence(timeout: 5) && account.isHittable { account.tap() }
    }
    private func capture(_ step: String) {
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "qa-login-" + step + "-" + revision; attachment.lifetime = .keepAlways; add(attachment)
        reviewNativeScreenshotIfRequested(step, namePrefix: "qa-login", revision: revision)
    }
}

/// Reads the authorized QA account once from a private host FIFO owned by this user.
struct QALoginCredential: Decodable {
    let email: String
    var password: String

    init(oneShotPipe path: String) throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFIFO,
              metadata.st_uid == geteuid(), metadata.st_mode & 0o077 == 0 else { throw NSError(domain: "QALogin", code: 1) }
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw NSError(domain: "QALogin", code: 2) }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var bytes = try input.read(upToCount: 4097) ?? Data(); try input.close()
        guard !bytes.isEmpty, bytes.count <= 4096 else { throw NSError(domain: "QALogin", code: 3) }
        defer { bytes.resetBytes(in: 0..<bytes.count); bytes.removeAll() }
        self = try JSONDecoder().decode(Self.self, from: bytes)
    }
}
