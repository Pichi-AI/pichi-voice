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

    @MainActor
    func testPhysicalFreshGuestRecordingStopPlaybackAndJSONShare() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PICHI_REVIEW34_DEMO"] == "fresh-empty-guest-recording" else { throw XCTSkip("Fresh empty guest recording opt-in required") }
        continueAfterFailure = true
        // Reserve bounded cleanup time in addition to the normal short demonstration.
        executionTimeAllowance = 300
        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        app.activate()
        guard let rawBaseline = env["PICHI_REVIEW34_BASELINE_IDS"],
              let backupHash = env["PICHI_REVIEW34_BASELINE_BACKUP_SHA"], backupHash.count == 64,
              backupHash.allSatisfy({ $0.isHexDigit }) else { throw Unverified() }
        let baselineIDs = rawBaseline.isEmpty ? [] : rawBaseline.split(separator: ",").map(String.init)
        guard baselineIDs.allSatisfy({ UUID(uuidString: $0) != nil }), Set(baselineIDs).count == baselineIDs.count else { throw Unverified() }
        func historyIDs() -> [String] {
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).allElementsBoundByIndex
                .map { String($0.identifier.dropFirst("history.session.".count)) }
        }
        let currentIDs = historyIDs()
        let closeLabels = ["Close audio player", "Закрыть аудиоплеер"]
        let transportLabels = ["Pause audio chunk", "Приостановить воспроизведение фрагмента",
                               "Play audio chunk", "Воспроизвести аудиофрагмент"]
        guard Set(currentIDs) == Set(baselineIDs),
              Self.recordingAdmission(revision: env["PICHI_TEST_REVISION"], optIn: env["PICHI_REVIEW34_DEMO"],
                isPad: UIDevice.current.userInterfaceIdiom == .pad,
                idle: app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
                    && !app.buttons["meeting.stop"].exists && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                historyCount: currentIDs.count, expectedHistoryCount: baselineIDs.count),
              app.buttons["meeting.start"].isEnabled && app.buttons["meeting.start"].isHittable,
              app.sliders.count == 0,
              app.buttons.matching(NSPredicate(format: "label IN %@", closeLabels)).count == 0 else { throw Unverified() }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let fixture = support.appendingPathComponent("BackgroundRecordingUI/speech.wav")
        let bytes = try Data(contentsOf: fixture)
        guard bytes.count == 424586,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == "81998993976a2804d414b261d3af679d49a1b1e08d952bace5ffc31291a392c8" else { throw Unverified() }
        let audio = AVAudioSession.sharedInstance()
        let category = audio.category, mode = audio.mode, options = audio.categoryOptions
        var ownedPlayer: AVAudioPlayer?
        var ownsRecording = false
        var observedOwnedRecording = false
        var openedSessionID: String?
        var openedTitle: String?
        var playbackOwner: Review34DemoAdmission.PlaybackOwner?
        var observedOwnedPlayback = false
        let stop = app.buttons["meeting.stop"]
        let transcript = app.scrollViews.matching(identifier: "meeting.transcript")
        defer {
            ownedPlayer?.stop()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(category, mode: mode, options: options)
        }
        func foregroundIdle() -> Bool {
            app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
        }
        func completedTranscript() -> Bool {
            foregroundIdle() && transcript.count == 1 && app.buttons["transcript.more"].exists
                && !stop.exists && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
                && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                && !app.buttons["meeting.retry"].exists && !app.buttons["meeting.restartProcessing"].exists
        }
        func finishOwnedRecording() async throws {
            guard ownsRecording else { return }
            app.activate()
            try await PhysicalOwnedRecordingCleanup.run(observe: {
                guard foregroundIdle() else { return nil }
                if stop.exists || app.descendants(matching: .any)["meeting.recording"].firstMatch.exists {
                    observedOwnedRecording = true
                }
                return PhysicalUITransitionWait.ownedRecordingAction(
                    stopReady: stop.exists && stop.isEnabled && stop.isHittable,
                    processing: observedOwnedRecording && app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    completed: observedOwnedRecording && completedTranscript())
            }, stop: {
                guard foregroundIdle(), stop.exists, stop.isEnabled, stop.isHittable else { throw Unverified() }
                stop.tap()
            }, join: {
                try await PhysicalUITransitionWait.until(timeout: 70, condition: {
                    observedOwnedRecording && completedTranscript()
                })
            })
            ownsRecording = false
        }
        func openHistory() async throws {
            guard foregroundIdle(), !stop.exists else { throw Unverified() }
            openedSessionID = nil; openedTitle = nil
            let sidebar = app.buttons["navigation.meetings"]
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
            else {
                let tabs = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["Recordings", "Записи"]))
                guard tabs.count == 1, tabs.firstMatch.isEnabled, tabs.firstMatch.isHittable else { throw Unverified() }
                tabs.firstMatch.tap()
            }
            try await PhysicalUITransitionWait.until(timeout: 15, condition: {
                foregroundIdle() && app.descendants(matching: .any)["history.list"].firstMatch.exists && transcript.count == 0
            })
        }
        func paragraph(_ owner: Review34DemoAdmission.PlaybackOwner) -> XCUIElementQuery {
            transcript.firstMatch.descendants(matching: .any).matching(identifier: owner.paragraphID)
        }
        func hasPlaybackScope(_ owner: Review34DemoAdmission.PlaybackOwner) -> Bool {
            guard completedTranscript(), app.staticTexts["transcript.title"].label == openedTitle else { return false }
            let matches = paragraph(owner)
            guard matches.count == 1 else { return false }
            let controls = matches.firstMatch.buttons.matching(identifier: owner.audioID)
            guard controls.count == 1 else { return false }
            return owner.matches(openedSessionID: openedSessionID, paragraphID: matches.firstMatch.identifier,
                audioID: controls.firstMatch.identifier, paragraphCount: matches.count, audioCount: controls.count)
        }
        func closeOwnedPlayback() async throws {
            guard let owner = playbackOwner else { return }
            let matches = paragraph(owner)
            let control = matches.firstMatch.buttons.matching(identifier: owner.audioID).firstMatch
            func joined() -> Bool {
                hasPlaybackScope(owner) && !closeLabels.contains(control.label)
                    && matches.firstMatch.sliders.count == 0
                    && matches.firstMatch.buttons.matching(NSPredicate(format: "label IN %@", transportLabels)).count == 0
            }
            try await PhysicalOwnedRecordingCleanup.run(observe: {
                guard hasPlaybackScope(owner) else { return nil }
                if closeLabels.contains(control.label) || matches.firstMatch.sliders.count > 0
                    || matches.firstMatch.buttons.matching(NSPredicate(format: "label IN %@", transportLabels)).count > 0 {
                    observedOwnedPlayback = true
                }
                return PhysicalUITransitionWait.ownedRecordingAction(
                    stopReady: control.isEnabled && closeLabels.contains(control.label), processing: false,
                    completed: observedOwnedPlayback && joined())
            }, stop: {
                try PhysicalControlReveal.run(startingUpward: false, ready: {
                    hasPlaybackScope(owner) && control.isEnabled && control.isHittable && closeLabels.contains(control.label)
                }, scroll: { upward, _ in
                    guard hasPlaybackScope(owner), transcript.firstMatch.isHittable else { throw Unverified() }
                    if upward { transcript.firstMatch.swipeUp() } else { transcript.firstMatch.swipeDown() }
                })
                guard hasPlaybackScope(owner), closeLabels.contains(control.label), control.isEnabled, control.isHittable else { throw Unverified() }
                control.tap()
            }, join: {
                try await PhysicalUITransitionWait.until(timeout: 10, condition: { observedOwnedPlayback && joined() })
            })
            playbackOwner = nil
        }
        try await PhysicalOwnedRecordingCleanup.withJoinedCleanup(operation: {
            try Task.checkCancellation()
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
            guard start.waitForExistence(timeout: 20), start.isEnabled, start.isHittable,
                  Set(historyIDs()) == Set(baselineIDs), app.sliders.count == 0,
                  app.buttons.matching(NSPredicate(format: "label IN %@", closeLabels)).count == 0 else { throw Unverified() }
            ownsRecording = true; start.tap()
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
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw Unverified() }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            observedOwnedRecording = true
            print("[PICHI_REVIEW34_DEMO] recording_ready=true")
            try await Task.sleep(nanoseconds: 18_000_000_000)
            player.stop()
            try await finishOwnedRecording()
            XCTAssertTrue(app.staticTexts["transcript.metadata.duration"].exists)
            let paragraphs = transcript.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
            XCTAssertGreaterThan(paragraphs.count, 0, "The actual microphone fixture must produce committed text")
            guard paragraphs.count > 0 else { throw Unverified() }
            print("[PICHI_REVIEW34_DEMO] saved_transcript_visible=true")
            // Resolve the single new UUID, then reopen exactly that row before binding controls.
            try await openHistory()
            guard let id = Review34DemoAdmission.newOwnedSessionID(baselineIDs: baselineIDs, historyIDs: historyIDs()) else { throw Unverified() }
            let rows = app.buttons.matching(identifier: "history.session.\(id)")
            let title = rows.firstMatch.staticTexts.matching(identifier: "history.title.\(id)")
            guard rows.count == 1, rows.firstMatch.isEnabled, rows.firstMatch.isHittable, title.count == 1 else { throw Unverified() }
            let expectedTitle = title.firstMatch.label
            rows.firstMatch.tap()
            try await PhysicalUITransitionWait.until(timeout: 15, condition: {
                completedTranscript() && app.staticTexts["transcript.title"].label == expectedTitle
            })
            openedSessionID = id; openedTitle = expectedTitle
            let audioButtons = transcript.firstMatch.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.audio."))
            if let control = audioButtons.allElementsBoundByIndex.first(where: { $0.isEnabled && $0.isHittable }) {
                let owners = transcript.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
                    .allElementsBoundByIndex.filter { $0.buttons.matching(identifier: control.identifier).count == 1 }
                guard owners.count == 1,
                      let owner = Review34DemoAdmission.PlaybackOwner(sessionID: id, baselineIDs: baselineIDs,
                        paragraphID: owners[0].identifier, audioID: control.identifier), hasPlaybackScope(owner),
                      !closeLabels.contains(control.label), owners[0].sliders.count == 0,
                      owners[0].buttons.matching(NSPredicate(format: "label IN %@", transportLabels)).count == 0 else { throw Unverified() }
                playbackOwner = owner
                control.tap()
                try await PhysicalUITransitionWait.until(timeout: 10, condition: {
                    guard hasPlaybackScope(owner), closeLabels.contains(control.label) else { return false }
                    observedOwnedPlayback = true
                    return true
                })
                try await Task.sleep(nanoseconds: 3_000_000_000)
                try await closeOwnedPlayback()
            }
            let more = app.buttons["transcript.more"]
            guard completedTranscript(), more.isEnabled, more.isHittable else { throw Unverified() }
            more.tap()
            let json = app.buttons.matching(NSPredicate(format: "label IN %@", ["Export as JSON", "Экспортировать как JSON"]))
            guard json.count == 1, json.element.isHittable else { throw Unverified() }
            json.element.tap()
            XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15), "The actual generated JSON must enter the native share sheet")
            guard app.otherElements["ActivityListView"].exists else { throw Unverified() }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "review34-owned-json-share"; screenshot.lifetime = .keepAlways; add(screenshot)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Закрыть"]))
            if close.count == 1, close.element.isHittable { close.element.tap() }
            print("[PICHI_REVIEW34_DEMO] json_share_presented=true external_delivery=false")
        }, cleanup: {
            ownedPlayer?.stop()
            do {
                try await finishOwnedRecording()
                try await closeOwnedPlayback()
                print("[PICHI_REVIEW34_DEMO] owned_recording_playback_cleanup_joined=true")
            } catch {
                let failure = error as NSError
                print("[PICHI_REVIEW34_DEMO] owned_cleanup_requires_parent_inspection=true domain=\(failure.domain) code=\(failure.code)")
                throw error
            }
        })
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
