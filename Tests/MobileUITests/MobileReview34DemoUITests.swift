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
        try await recordingDemo(coreVideo: false)
    }

    @MainActor
    func testPhysicalOwnedCoreFlowVideo() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical phone/pad video and explicit audio window required")
        #else
        try await recordingDemo(coreVideo: true)
        #endif
    }

    @MainActor private func recordingDemo(coreVideo: Bool) async throws {
        let env = ProcessInfo.processInfo.environment
        guard coreVideo ? (env["PICHI_CORE_FLOW_VIDEO"] == "owned-core-flow" && env["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1")
            : env["PICHI_REVIEW34_DEMO"] == "fresh-empty-guest-recording" else {
            throw XCTSkip("Explicit owned recording/video audio window required")
        }
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
        func expectedExistingHistory(_ ids: [String]) -> Bool {
            coreVideo ? Review34DemoAdmission.knownVisibleHistory(baselineIDs: baselineIDs, visibleIDs: ids)
                : Set(ids) == Set(baselineIDs)
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        if coreVideo {
            let proof = try Data(contentsOf: support.appendingPathComponent("CoreFlowVideo/backup-proof.json"))
            let idiom = UIDevice.current.userInterfaceIdiom == .phone ? "phone" : UIDevice.current.userInterfaceIdiom == .pad ? "pad" : "unsupported"
            guard Review34DemoAdmission.coreVideoProof(proof, expectedSHA: env["PICHI_CORE_FLOW_PROOF_SHA"],
                revision: env["PICHI_TEST_REVISION"], deviceID: env["PICHI_CORE_FLOW_DEVICE_ID"],
                idiom: idiom, osVersion: UIDevice.current.systemVersion, baselineIDs: baselineIDs, expectedBackupSHA: backupHash) else { throw Unverified() }
            let admitted = try JSONDecoder().decode(Review34DemoAdmission.CoreVideoProof.self, from: proof)
            let latestStatus = admitted.latestOSVerified ? "verified" : "not_verified"
            print("[PICHI_CORE_FLOW_PURPOSE] purpose=\(admitted.purpose.rawValue) os=\(UIDevice.current.systemVersion) latestStatus=\(latestStatus)")
        }

        let closeLabels = ["Close audio player", "Закрыть аудиоплеер"]
        let transportLabels = ["Pause audio chunk", "Приостановить воспроизведение фрагмента",
                               "Play audio chunk", "Воспроизвести аудиофрагмент"]
        guard expectedExistingHistory(currentIDs),
              app.state == .runningForeground, app.alerts.count == 0, app.sheets.count == 0,
              !app.buttons["meeting.stop"].exists, !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
              (coreVideo || Self.recordingAdmission(revision: env["PICHI_TEST_REVISION"], optIn: env["PICHI_REVIEW34_DEMO"],
                isPad: UIDevice.current.userInterfaceIdiom == .pad,
                idle: app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
                    && !app.buttons["meeting.stop"].exists && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                historyCount: currentIDs.count, expectedHistoryCount: baselineIDs.count)),
              app.buttons["meeting.start"].isEnabled && app.buttons["meeting.start"].isHittable,
              app.sliders.count == 0,
              app.buttons.matching(NSPredicate(format: "label IN %@", closeLabels)).count == 0 else { throw Unverified() }
        let fixture = support.appendingPathComponent("BackgroundRecordingUI/speech.wav")
        let bytes = try Data(contentsOf: fixture)
        guard bytes.count == 424586,
              SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == "81998993976a2804d414b261d3af679d49a1b1e08d952bace5ffc31291a392c8" else { throw Unverified() }
        let audio = AVAudioSession.sharedInstance()
        let category = audio.category, mode = audio.mode, options = audio.categoryOptions
        var ownedPlayer: AVAudioPlayer?
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        var ownsRecording = false
        var observedOwnedRecording = false
        var openedSessionID: String?
        var openedTitle: String?
        var playbackOwner: Review34DemoAdmission.PlaybackOwner?
        var observedOwnedPlayback = false
        var ownsShare = false
        let stop = app.buttons["meeting.stop"]
        let transcript = app.scrollViews.matching(identifier: "meeting.transcript")
        defer { ownedPlayer?.stop() }
        func foregroundIdle() -> Bool {
            app.state == .runningForeground && app.alerts.count == 0 && app.sheets.count == 0
                && XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.count == 0
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
            try openTopLevel("meetings", labels: ["Recordings", "Записи"])
            try await PhysicalUITransitionWait.until(timeout: 15, condition: {
                foregroundIdle() && app.descendants(matching: .any)["history.list"].firstMatch.exists && transcript.count == 0
            })
        }
        func openTopLevel(_ name: String, labels: [String]) throws {
            guard foregroundIdle(), !stop.exists else { throw Unverified() }
            let sidebar = app.buttons["navigation." + name]
            if sidebar.exists && sidebar.isHittable { sidebar.tap() }
            else {
                let tabs = app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", labels))
                guard tabs.count == 1, tabs.firstMatch.isEnabled, tabs.firstMatch.isHittable else { throw Unverified() }
                tabs.firstMatch.tap()
            }
        }
        func revealPolicyControl(_ element: XCUIElement, container: XCUIElement) throws {
            try PhysicalControlReveal.run(startingUpward: true, ready: {
                foregroundIdle() && element.exists && element.isEnabled && element.isHittable
            }, scroll: { upward, _ in
                guard foregroundIdle(), container.exists, container.isHittable else { throw Unverified() }
                if upward { container.swipeUp() } else { container.swipeDown() }
            })
        }
        func verifyRecordingPolicies() async throws {
            try openTopLevel("settings", labels: ["Settings", "Настройки"])
            let root = app.descendants(matching: .any)["settings.root"].firstMatch
            if !root.waitForExistence(timeout: 2) || !root.isHittable {
                try openTopLevel("settings", labels: ["Settings", "Настройки"])
            }
            guard root.waitForExistence(timeout: 5), root.isHittable else { throw Unverified() }
            let privacy = app.buttons["settings.privacy"]
            try revealPolicyControl(privacy, container: root)
            guard privacy.exists, privacy.isEnabled, privacy.isHittable else { throw Unverified() }
            privacy.tap()
            let save = app.switches["privacy.saveAudio"]
            guard save.waitForExistence(timeout: 5), !coreVideo || save.value as? String == "1" else { throw Unverified() }
            let saveValue = save.value as? String
            try openTopLevel("settings", labels: ["Settings", "Настройки"])
            let account = app.buttons["settings.account"]
            if !root.exists || !root.isHittable { try openTopLevel("settings", labels: ["Settings", "Настройки"]) }
            try revealPolicyControl(account, container: root)
            guard account.waitForExistence(timeout: 5), account.isEnabled, account.isHittable else { throw Unverified() }
            account.tap()
            let delivery = app.switches["cloud.sync.toggle"]
            _ = delivery.waitForExistence(timeout: 5)
            let emails = app.textFields.matching(identifier: "account.legacy.email")
            let passwords = app.secureTextFields.matching(identifier: "account.legacy.password")
            let signIn = app.buttons.matching(identifier: "account.signIn")
            let destination = app.staticTexts.matching(identifier: "account.legacy.destination")
            let transient = ["account.signingIn", "account.updating", "account.protectedDataUnavailable", "account.profile.hidden"]
                .contains { app.descendants(matching: .any)[$0].firstMatch.exists }
            let conflicts = transient || app.buttons["account.signOut"].exists || app.buttons["app.account.signOut"].exists
                || app.descendants(matching: .any)["account.displayName"].firstMatch.exists
                || app.descendants(matching: .any)["app.account.displayName"].firstMatch.exists
            let guest = Review34DemoAdmission.GuestEvidence(emailCount: emails.count, secureFieldCount: passwords.count,
                signInCount: signIn.count, destination: destination.count == 1 ? destination.element.label : nil,
                fieldsEnabled: emails.count == 1 && passwords.count == 1 && emails.element.isEnabled && passwords.element.isEnabled,
                signInVisible: signIn.count == 1 && !signIn.element.frame.isEmpty && app.frame.intersects(signIn.element.frame),
                conflictingAccountState: conflicts, foregroundWithoutPrompts: foregroundIdle()).verifiedSignedOut
            guard !transient, Review34DemoAdmission.recordingPoliciesReady(idle: foregroundIdle() && !stop.exists,
                saveAudio: saveValue, automaticDelivery: delivery.exists ? delivery.value as? String : nil,
                noExistingPlayer: app.sliders.count == 0 && app.buttons.matching(NSPredicate(format: "label IN %@", closeLabels)).count == 0,
                requireRetainedAudio: coreVideo, automaticDeliveryPresent: delivery.exists,
                verifiedSignedOut: guest, cancelled: Task.isCancelled)
            else { throw Unverified() }
            try await openHistory()
            guard expectedExistingHistory(historyIDs()) else { throw Unverified() }
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
            try await verifyRecordingPolicies()
            // Cancellation boundary follows the last eligibility read, never cleanup Stop/Close.
            try Task.checkCancellation()
            app.terminate()
            guard let runnerID = Bundle.main.bundleIdentifier, runnerID.hasSuffix(".xctrunner"),
                  (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("audio") == true else { throw Unverified() }
            try Task.checkCancellation()
            XCUIApplication(bundleIdentifier: runnerID).activate()
            try Task.checkCancellation()
            try audio.setCategory(.playback, mode: .default, options: .mixWithOthers)
            changedPlaybackCategory = true
            try Task.checkCancellation()
            try audio.setActive(true)
            ownsPlaybackSession = true
            try Task.checkCancellation()
            let player = try AVAudioPlayer(contentsOf: fixture); ownedPlayer = player
            player.numberOfLoops = -1; player.volume = 0.2
            try Task.checkCancellation()
            guard player.prepareToPlay() else { throw Unverified() }
            try Task.checkCancellation()
            guard player.play() else { throw Unverified() }
            app.launchArguments = []; app.launchEnvironment = [:]
            try Task.checkCancellation()
            app.launch()
            // Re-read actual OFF in both legacy and phone/pad core paths after cold launch.
            try await verifyRecordingPolicies()
            let start = app.buttons["meeting.start"]
            guard start.waitForExistence(timeout: 20), start.isEnabled, start.isHittable,
                  expectedExistingHistory(historyIDs()), app.sliders.count == 0,
                  app.buttons.matching(NSPredicate(format: "label IN %@", closeLabels)).count == 0 else { throw Unverified() }
            try Task.checkCancellation()
            ownsRecording = true; start.tap()
            let deadline = ProcessInfo.processInfo.systemUptime + 40
            var granted = false
            while !stop.exists || !stop.isEnabled {
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
            try await Task.sleep(nanoseconds: coreVideo ? 20_000_000_000 : 18_000_000_000)
            player.stop()
            try await finishOwnedRecording()
            XCTAssertTrue(app.staticTexts["transcript.metadata.duration"].exists)
            let paragraphs = transcript.firstMatch.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
            XCTAssertGreaterThan(paragraphs.count, 0, "The actual microphone fixture must produce committed text")
            guard paragraphs.count > 0 else { throw Unverified() }
            print("[PICHI_REVIEW34_DEMO] saved_transcript_visible=true")
            // Resolve the single new UUID, then reopen exactly that row before binding controls.
            try await openHistory()
            let visibleIDs = historyIDs()
            let ownedID = coreVideo
                ? Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: baselineIDs, visibleIDs: visibleIDs)
                : Review34DemoAdmission.newOwnedSessionID(baselineIDs: baselineIDs, historyIDs: visibleIDs)
            guard let id = ownedID else { throw Unverified() }
            print("[PICHI_REVIEW34_DEMO] owned_session_id=\(id)")
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
            } else if coreVideo { throw Unverified() }
            let more = app.buttons["transcript.more"]
            guard completedTranscript(), more.isEnabled, more.isHittable else { throw Unverified() }
            more.tap()
            let json = app.buttons.matching(NSPredicate(format: "label IN %@", ["Export as JSON", "Экспортировать как JSON"]))
            guard json.count == 1, json.element.isHittable else { throw Unverified() }
            ownsShare = true; json.element.tap()
            XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(timeout: 15), "The actual generated JSON must enter the native share sheet")
            guard app.otherElements["ActivityListView"].exists else { throw Unverified() }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "review34-owned-json-share"; screenshot.lifetime = .keepAlways; add(screenshot)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Закрыть"]))
            if close.count == 1, close.element.isHittable { close.element.tap() }
            if coreVideo {
                guard app.otherElements["ActivityListView"].waitForNonExistence(timeout: 10), completedTranscript() else { throw Unverified() }
            }
            ownsShare = app.otherElements["ActivityListView"].exists
            print("[PICHI_REVIEW34_DEMO] json_share_presented=true external_delivery=false")
        }, cleanup: {
            ownedPlayer?.stop()
            var cleanupFailure: Error?
            do {
                try await finishOwnedRecording()
                try await closeOwnedPlayback()
                if ownsShare && app.otherElements["ActivityListView"].exists {
                    guard openedSessionID != nil, openedTitle != nil else { throw Unverified() }
                    let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Закрыть", "Cancel", "Отмена"]))
                    guard close.count == 1, close.element.isHittable else { throw Unverified() }
                    close.element.tap()
                    guard app.otherElements["ActivityListView"].waitForNonExistence(timeout: 10) else { throw Unverified() }
                    ownsShare = false
                }
            } catch { cleanupFailure = error }
            do {
                if ownsPlaybackSession {
                    try audio.setActive(false, options: .notifyOthersOnDeactivation)
                    ownsPlaybackSession = false
                }
                if changedPlaybackCategory {
                    try audio.setCategory(category, mode: mode, options: options)
                    guard audio.category == category, audio.mode == mode, audio.categoryOptions == options else { throw Unverified() }
                    changedPlaybackCategory = false
                }
            } catch { if cleanupFailure == nil { cleanupFailure = error } }
            if let cleanupFailure {
                let failure = cleanupFailure as NSError
                print("[PICHI_REVIEW34_DEMO] owned_cleanup_requires_parent_inspection=true domain=\(failure.domain) code=\(failure.code)")
                throw cleanupFailure
            }
            print("[PICHI_REVIEW34_DEMO] owned_recording_playback_cleanup_joined=true")
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
