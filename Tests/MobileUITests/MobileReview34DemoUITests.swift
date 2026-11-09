import Foundation
import UIKit
import XCTest
import AVFoundation
import CryptoKit

/// Opt-in native review scenarios on the unchanged installed ordinary build34.
/// Recording uses a hash-checked synthetic fixture and preserves the pinned baseline.
/// No credential input, sign-in, deletion or external delivery is performed.
final class MobileReview34DemoUITests: XCTestCase {
    func testPhysicalRecordingAdmissionRejectsOccupiedHistoryOrUnexpectedPrompt() {
        XCTAssertTrue(Self.recordingAdmission(revision: Self.revision, optIn: "fresh-empty-guest-recording", isPad: true, idle: true, historyCount: 0))
        XCTAssertTrue(Self.recordingAdmission(revision: Self.revision, optIn: "fresh-empty-guest-recording", isPad: true, idle: true, historyCount: 1, expectedHistoryCount: 1))
        XCTAssertFalse(Self.recordingAdmission(revision: Self.revision, optIn: "fresh-empty-guest-recording", isPad: true, idle: true, historyCount: 2, expectedHistoryCount: 1))
        XCTAssertFalse(Self.recordingAdmission(revision: Self.revision, optIn: "fresh-empty-guest-recording", isPad: true, idle: true, historyCount: 0, expectedHistoryCount: -1))
        XCTAssertFalse(Self.recordingAdmission(revision: "older", optIn: "fresh-empty-guest-recording", isPad: true, idle: true, historyCount: 0))
        XCTAssertFalse(Self.recordingAdmission(revision: Self.revision, optIn: nil, isPad: true, idle: true, historyCount: 0))
        XCTAssertFalse(Self.recordingAdmission(revision: Self.revision, optIn: "fresh-empty-guest-recording", isPad: false, idle: true, historyCount: 0))
        XCTAssertFalse(Self.recordingAdmission(revision: Self.revision, optIn: "fresh-empty-guest-recording", isPad: true, idle: false, historyCount: 0))
        XCTAssertFalse(Self.recordingAdmission(revision: Self.revision, optIn: "fresh-empty-guest-recording", isPad: true, idle: true, historyCount: 1))
        XCTAssertTrue(Self.microphonePrompt(["“Pichi Voice” Would Like to Access the Microphone", "Record audio and transcribe speech on this device."]))
        XCTAssertFalse(Self.microphonePrompt(["Enter iPad Passcode for XCTest", "Enable UI Automation"]))
        XCTAssertFalse(Self.microphonePrompt(["Another App Would Like to Access the Microphone", "Record audio and transcribe speech on this device."]))
    }

    func testPhysicalFreshGuestRecordingStopPlaybackAndJSONShare() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PICHI_REVIEW34_DEMO"] == "fresh-empty-guest-recording" else { throw XCTSkip("Fresh empty guest recording opt-in required") }
        // Explicit Swift guards below keep owned cleanup on the failure path.
        continueAfterFailure = true
        executionTimeAllowance = 150
        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        app.activate()
        guard let rawBaseline = env["PICHI_REVIEW34_BASELINE_IDS"],
              let backupHash = env["PICHI_REVIEW34_BASELINE_BACKUP_SHA"], backupHash.count == 64,
              backupHash.allSatisfy({ $0.isHexDigit }) else { throw Unverified() }
        let baselineIDs = rawBaseline.isEmpty ? [] : rawBaseline.split(separator: ",").map(String.init)
        guard baselineIDs.allSatisfy({ UUID(uuidString: $0) != nil }), Set(baselineIDs).count == baselineIDs.count else { throw Unverified() }
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).allElementsBoundByIndex
        let currentIDs = Set(rows.map { String($0.identifier.dropFirst("history.session.".count)) })
        guard currentIDs == Set(baselineIDs) else { throw Unverified() }
        guard Self.recordingAdmission(revision: env["PICHI_TEST_REVISION"], optIn: env["PICHI_REVIEW34_DEMO"],
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            idle: app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
                && !app.buttons["meeting.stop"].exists && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
            historyCount: rows.count, expectedHistoryCount: baselineIDs.count),
              app.buttons["meeting.start"].isEnabled && app.buttons["meeting.start"].isHittable else { throw Unverified() }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let fixture = support.appendingPathComponent("BackgroundRecordingUI/speech.wav")
        let bytes = try Data(contentsOf: fixture)
        guard bytes.count == 424586,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == "81998993976a2804d414b261d3af679d49a1b1e08d952bace5ffc31291a392c8" else { throw Unverified() }
        let audio = AVAudioSession.sharedInstance()
        let category = audio.category, mode = audio.mode, options = audio.categoryOptions
        var ownedPlayer: AVAudioPlayer?
        var ownsRecording = false
        defer {
            ownedPlayer?.stop()
            if ownsRecording && app.buttons["meeting.stop"].exists && app.buttons["meeting.stop"].isHittable {
                app.buttons["meeting.stop"].tap()
                _ = app.buttons["meeting.stop"].waitForNonExistence(timeout: 30)
            }
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(category, mode: mode, options: options)
        }
        // Capture a normal cold launch without arguments or environment overrides.
        app.terminate()
        XCUIApplication(bundleIdentifier: "ai.pichi.voice.uitests.xctrunner").activate()
        try audio.setCategory(.playback, mode: .default, options: .mixWithOthers)
        try audio.setActive(true)
        let player = try AVAudioPlayer(contentsOf: fixture); ownedPlayer = player
        player.numberOfLoops = -1; player.volume = 0.2
        guard player.prepareToPlay(), player.play() else { throw Unverified() }
        app.launchArguments = []; app.launchEnvironment = [:]; app.launch()
        let start = app.buttons["meeting.start"]
        guard start.waitForExistence(timeout: 20), start.isEnabled, start.isHittable else { throw Unverified() }
        start.tap(); ownsRecording = true
        let stop = app.buttons["meeting.stop"]
        let deadline = ProcessInfo.processInfo.systemUptime + 40
        var granted = false
        while !stop.exists {
            let alerts = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
            if alerts.count > 0 {
                guard alerts.count == 1, !granted else { throw Unverified() }
                let alert = alerts.element
                guard Self.microphonePrompt(alert.staticTexts.allElementsBoundByIndex.map(\.label)) else { throw Unverified() }
                let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "ОК", "Allow", "Разрешить"]))
                guard allow.count == 1, allow.element.isEnabled, allow.element.isHittable else { throw Unverified() }
                allow.element.tap(); granted = true
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Unverified() }
            Thread.sleep(forTimeInterval: 0.25)
        }
        print("[PICHI_REVIEW34_DEMO] recording_ready=true")
        Thread.sleep(forTimeInterval: 18)
        guard stop.isEnabled, stop.isHittable else { throw Unverified() }
        player.stop(); stop.tap()
        let transcript = app.scrollViews["meeting.transcript"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 70), "Owned recording must finish into its saved transcript")
        guard transcript.exists, !stop.exists else { throw Unverified() }
        ownsRecording = false
        XCTAssertTrue(app.staticTexts["transcript.metadata.duration"].exists)
        let paragraphs = transcript.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
        XCTAssertGreaterThan(paragraphs.count, 0, "The actual microphone fixture must produce committed text")
        guard paragraphs.count > 0 else { throw Unverified() }
        print("[PICHI_REVIEW34_DEMO] saved_transcript_visible=true")
        let audioButtons = transcript.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.audio."))
        if audioButtons.count > 0, audioButtons.firstMatch.isEnabled, audioButtons.firstMatch.isHittable {
            let owned = audioButtons.firstMatch
            owned.tap(); Thread.sleep(forTimeInterval: 3)
            guard owned.exists, owned.isEnabled, owned.isHittable else { throw Unverified() }
            owned.tap(); Thread.sleep(forTimeInterval: 1)
        }
        let more = app.buttons["transcript.more"]
        guard more.isEnabled, more.isHittable else { throw Unverified() }
        more.tap()
        let json = app.buttons.matching(NSPredicate(format: "label IN %@", ["Export as JSON", "Экспортировать как JSON"]))
        guard json.count == 1, json.element.isHittable else { throw Unverified() }
        json.element.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15), "The actual generated JSON must enter the native share sheet")
        guard app.otherElements["ActivityListView"].exists else { throw Unverified() }
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "review34-owned-json-share"; screenshot.lifetime = .keepAlways; add(screenshot)
        Thread.sleep(forTimeInterval: 3)
        let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Закрыть"]))
        if close.count == 1, close.element.isHittable { close.element.tap() }
        print("[PICHI_REVIEW34_DEMO] json_share_presented=true external_delivery=false")
    }

    private static let revision = "1a245d0447b08e3fc681d439ea4ef3b392e034c2"
    private static func recordingAdmission(revision: String?, optIn: String?, isPad: Bool, idle: Bool, historyCount: Int, expectedHistoryCount: Int = 0) -> Bool {
        revision == Self.revision && optIn == "fresh-empty-guest-recording" && isPad && idle
            && expectedHistoryCount >= 0 && historyCount == expectedHistoryCount
    }
    private static func microphonePrompt(_ labels: [String]) -> Bool {
        let titles = ["“Pichi Voice” Would Like to Access the Microphone", "\"Pichi Voice\" Would Like to Access the Microphone",
                      "«Pichi Voice» запрашивает доступ к микрофону", "«Pichi Voice» запрашивает доступ к микрофону.", "Приложение «Pichi Voice» запрашивает доступ к микрофону."]
        let purposes = ["Record audio and transcribe speech on this device.", "Записывать звук и распознавать речь на этом устройстве."]
        return labels.contains(where: titles.contains) && labels.contains(where: purposes.contains)
    }
    func testFinishExactPreparedGuestSetupWithoutCredentials() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PICHI_REVIEW34_DEMO"] == "prepared-final-page-only" else { throw XCTSkip("Exact prepared-page opt-in required") }
        continueAfterFailure = false
        executionTimeAllowance = 90
        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        app.activate()
        let email = app.textFields.matching(identifier: "account.legacy.email")
        let password = app.secureTextFields.matching(identifier: "account.legacy.password")
        guard email.count == 1, password.count == 1 else { throw Unverified() }
        func empty(_ field: XCUIElement) -> Bool {
            Review34DemoAdmission.credentialsAreEmpty(value: field.value as? String, placeholder: field.placeholderValue)
        }
        let noAlerts = app.alerts.count == 0 && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0
        guard Review34DemoAdmission.admitted(revision: env["PICHI_TEST_REVISION"], optIn: env["PICHI_REVIEW34_DEMO"],
            isPad: UIDevice.current.userInterfaceIdiom == .pad,
            signedOut: !app.buttons["account.signOut"].exists && !app.buttons["account.signIn"].isEnabled,
            idle: app.state == .runningForeground && noAlerts && app.sheets.count == 0
                && !app.buttons["meeting.stop"].exists && !app.descendants(matching: .any)["account.signingIn"].firstMatch.exists,
            credentialsEmpty: empty(email.element) && empty(password.element)),
              app.staticTexts["account.legacy.destination"].label == "app.pichi.ai",
              app.descendants(matching: .any)["onboarding.step.6"].firstMatch.exists,
              app.buttons["onboarding.next"].isEnabled && app.buttons["onboarding.next"].isHittable else { throw Unverified() }
        app.buttons["onboarding.next"].tap()
        XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 60), "Prepared final page must open local recordings")
        XCTAssertFalse(app.buttons["meeting.stop"].exists, "Finishing setup must not start recording")
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "review34-prepared-guest-opened-recordings"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    private struct Unverified: Error {}
}
