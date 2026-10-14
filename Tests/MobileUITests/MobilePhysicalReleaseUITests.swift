import XCTest
import UIKit
@preconcurrency import AVFoundation

/// Opt-in tests of the installed, ordinary app through its public UI. The runner owns
/// only public synthetic playback; it does not import the app or inject capture/services.
final class MobilePhysicalReleaseUITests: XCTestCase {
    @MainActor
    func testReleaseTinyFiveMinuteBackgroundRecordingAndJSONShare() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized physical-device audio lease")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_RELEASE_UI_SOAK"] == "1",
              environment["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1" else {
            throw XCTSkip("Enable physical Release UI recording and audible playback explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"],
                                    "The frozen AUT source revision must be recorded")
        try require(!revision.isEmpty && revision != "working-tree", "A concrete AUT revision is required")
        let runnerID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(runnerID.hasSuffix(".xctrunner"), "Playback must be owned by the UI test runner")
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        try require(backgroundModes.contains("audio"),
                    "The copied UI runner must declare audio before valid signing and freezing")
        let assets = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: false)
        let fixture = assets.appendingPathComponent("PhysicalReleaseUI/audio/ru.wav")
        try require(FileManager.default.fileExists(atPath: fixture.path), "Stage the approved public Russian WAV in the runner")
        let player = try AVAudioPlayer(contentsOf: fixture)
        try require(player.duration.isFinite && player.duration >= 1, "The staged speech fixture must be valid")
        player.numberOfLoops = -1
        player.volume = 0.8
        try require(player.prepareToPlay(), "The runner must prepare real fixture playback")

        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice.mobile")
        // Preserve the user's actual language, theme, model and privacy choices.
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.activate()
        try openNavigation(app, "meetings", titles: ["Meetings", "Встречи"], revision: revision)
        try require(!app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "The app must be idle; an existing recording is not owned by this test")
        capture("01-installed-app", revision: revision)
        try openNavigation(app, "history", titles: ["History", "История"], revision: revision)
        let previousSessionIDs = historyIDs(in: app)
        try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        if !app.buttons["settings.models"].exists {
            try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        }
        try tap(app.buttons["settings.models"], "Open the installed model settings")
        capture("02-models-opened", revision: revision)
        let selectedTiny = app.descendants(matching: .any)["model.selected.whisper-tiny"].firstMatch
        try reveal(selectedTiny, in: app, revision: revision)
        try require(selectedTiny.exists, "Whisper Tiny must already be selected; the test never changes the model")
        capture("03-tiny-selected", revision: revision)
        try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        try tap(app.buttons["settings.privacy"], "Open privacy")
        try require(app.switches["privacy.saveAudio"].waitForExistence(timeout: 5), "Audio privacy must be visible")
        try require(app.switches["privacy.saveAudio"].value as? String == "0", "Save audio must already be OFF")
        try require(app.switches["privacy.pii"].value as? String == "1", "PII must already be ON")
        capture("04-strict-privacy", revision: revision)
        try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        try tap(app.buttons["settings.recording"], "Open recording settings")
        let speakers = app.switches["recording.diarization"]
        try reveal(speakers, in: app, revision: revision)
        try require(speakers.value as? String == "1", "Speaker labels must already be ON")
        capture("05-speaker-settings", revision: revision)
        try openNavigation(app, "meetings", titles: ["Meetings", "Встречи"], revision: revision)
        if !app.buttons["meeting.start"].exists {
            try tap(app.buttons["meeting.new"], "Reset the completed current view without deleting history")
            capture("06-new-meeting", revision: revision)
        }
        try require(app.buttons["meeting.start"].waitForExistence(timeout: 15), "The real Start action must be ready")
        try require(app.alerts.count == 0, "Permissions and model readiness must be resolved before the audio lease")
        capture("07-ready", revision: revision)

        let audioSession = AVAudioSession.sharedInstance()
        try require(audioSession.outputVolume > 0.05, "Device output must be audible before playback")
        let originalCategory = audioSession.category
        let originalMode = audioSession.mode
        let originalOptions = audioSession.categoryOptions
        var ownsRecording = false
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        defer {
            player.stop()
            if ownsPlaybackSession {
                try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            }
            if changedPlaybackCategory {
                try? audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            }
        }
        do {
            // Initiate actual audio while the runner itself is foreground, then return to
            // the AUT. This uses the public audio background mode, not background assertions.
            let runner = XCUIApplication(bundleIdentifier: runnerID)
            runner.activate()
            try require(runner.state == .runningForeground, "The runner must own foreground playback initiation")
            try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
            changedPlaybackCategory = true
            try audioSession.setActive(true)
            ownsPlaybackSession = true
            try require(player.play(), "The runner must start synthetic speech")
            app.activate()
            try tap(app.buttons["meeting.start"], "Start through the ordinary Release UI")
            // Once the Start action has been admitted, failure cleanup owns this attempt,
            // even if preparation has not yet exposed an enabled Stop button.
            ownsRecording = true
            try require(app.buttons["meeting.stop"].waitForExistence(timeout: 30), "The Release app must start recording")
            try require(app.buttons["meeting.stop"].isEnabled, "Capture must reach the recording state")
            capture("08-recording-started", revision: revision)
            let start = ProcessInfo.processInfo.systemUptime
            var earlyTextCount = 0
            let preferences = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            for second in 1...300 {
                let remaining = start + Double(second) - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                try require(player.isPlaying, "Synthetic playback stopped before second \(second)")
                if second == 10 {
                    earlyTextCount = liveTextCharacterCount(in: app)
                    capture("09-live-at-ten-seconds", revision: revision)
                    preferences.activate()
                    try require(preferences.state == .runningForeground, "Settings must be the actual foreground app")
                    try require(app.state == .runningBackground, "The AUT must enter actual background recording")
                    capture("10-actual-background", revision: revision)
                    print("[PHYSICAL_RELEASE_UI] background_started revision=\(revision) earlyCharacters=\(earlyTextCount)")
                } else if second > 10 {
                    try require(app.state == .runningBackground, "The recording app left background or terminated at second \(second)")
                }
                if second.isMultiple(of: 30) {
                    print("[PHYSICAL_RELEASE_UI] elapsed=\(second) playback=true appBackground=\(app.state == .runningBackground)")
                }
            }
            player.stop()
            try require(!player.isPlaying, "The owned player must stop before completion")
            app.activate()
            try require(app.buttons["meeting.stop"].waitForExistence(timeout: 5) && app.buttons["meeting.stop"].isEnabled,
                        "Capture must still be active after five minutes")
            let finalTextCount = liveTextCharacterCount(in: app)
            try require(finalTextCount > max(earlyTextCount, 20), "Protected committed text must advance during background capture")
            try verifyLatestCaptionVisible(in: app)
            capture("11-five-minutes-following-latest", revision: revision)

            let viewport = app.descendants(matching: .any)["meeting.liveTranscript"].firstMatch
            viewport.swipeDown()
            let latest = app.buttons["meeting.liveTranscript.latest"]
            try require(latest.waitForExistence(timeout: 5), "Reading older captions must pause automatic following")
            capture("12-reading-older-captions", revision: revision)
            try tap(latest, "Return to the latest protected text")
            try verifyLatestCaptionVisible(in: app)
            capture("13-returned-to-latest", revision: revision)

            try tap(app.buttons["meeting.stop"], "Stop and transcribe through the Release UI")
            capture("14-stop-requested", revision: revision)
            try await waitForCompletedTranscript(in: app, timeout: 120)
            ownsRecording = false
            try require(!app.buttons["meeting.stop"].exists, "The recording controls must disappear after joined completion")
            try require(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.segment.")).count > 0,
                        "The completed transcript must contain real segments")
            capture("15-completed-transcript", revision: revision)
            try tap(app.buttons["transcript.more"], "Open completed transcript actions")
            capture("16-transcript-actions", revision: revision)
            try require(firstButton(in: app, labels: ["Export Audio", "Экспорт аудио"]) == nil,
                        "Strict memory-only recording must not offer audio export")
            let jsonExport = try XCTUnwrap(firstButton(in: app, labels: ["Export as JSON", "Экспортировать как JSON"]),
                                          "The actual JSON export action must be present")
            try tap(jsonExport, "Export the protected JSON transcript")
            let saveToFiles = try await waitForButton(in: app,
                labels: ["Save to Files", "Сохранить в Файлы"], timeout: 15)
            try require(saveToFiles.exists, "The actual native share sheet must offer Save to Files")
            capture("17-native-json-share", revision: revision)
            // The parent can copy the AUT's owned temporary share directory here. This
            // verifies generated JSON, not delivery to a guessed/cloud Files destination.
            print("[PHYSICAL_RELEASE_UI] export_presented kind=json inspectionSeconds=15")
            try await Task.sleep(nanoseconds: 15_000_000_000)
            app.swipeDown()
            if !app.buttons["transcript.more"].isHittable {
                try tap(try XCTUnwrap(firstButton(in: app, labels: ["Close", "Закрыть", "Cancel", "Отмена"])),
                        "Dismiss the share sheet without sending to another application")
            }
            try require(app.buttons["transcript.more"].isHittable, "The share sheet must close safely")
            capture("18-share-dismissed", revision: revision)
            try openNavigation(app, "history", titles: ["History", "История"], revision: revision)
            let newIDs = historyIDs(in: app).subtracting(previousSessionIDs)
            try require(newIDs.count == 1, "History must show exactly one new meeting from this attempt")
            let sessionID = try XCTUnwrap(newIDs.first)
            print("[PHYSICAL_RELEASE_UI] completed sessionID=\(sessionID) finalCharacters=\(finalTextCount)")
            capture("19-completed-history-row", revision: revision)
            app.terminate()
            app.launch()
            capture("20-normal-relaunch", revision: revision)
            try openNavigation(app, "history", titles: ["History", "История"], revision: revision)
            try tap(app.buttons["history.session.\(sessionID)"], "Reopen the persisted meeting after normal relaunch")
            try require(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 10),
                        "The persisted transcript must reopen")
            try require(!app.buttons["meeting.stop"].exists, "Relaunch must not restore active capture")
            capture("21-persisted-transcript-reopened", revision: revision)
        } catch {
            player.stop()
            if ownsRecording {
                // Request the same normal stop/join path as the user. Never stop someone
                // else's pre-existing recording or delete checkpoints after a failure.
                // An unstructured cleanup task does not inherit the test task's
                // cancellation. Join it before returning the original failure.
                let cleanup = Task { @MainActor in
                    app.activate()
                    let stop = app.buttons["meeting.stop"]
                    if stop.waitForExistence(timeout: 30), stop.isEnabled {
                        stop.tap()
                        do { try await self.waitForCompletedTranscript(in: app, timeout: 120) }
                        catch { print("[PHYSICAL_RELEASE_UI] cleanup_stop_requires_parent_inspection") }
                    } else {
                        print("[PHYSICAL_RELEASE_UI] cleanup_stop_unavailable_requires_parent_inspection")
                    }
                    self.capture("failure-owned-recording-cleanup", revision: revision)
                }
                await cleanup.value
            }
            throw error
        }
        #endif
    }

    @MainActor private func openNavigation(_ app: XCUIApplication, _ identifier: String, titles: [String], revision: String) throws {
        let sidebar = app.buttons["navigation.\(identifier)"]
        if sidebar.exists { try tap(sidebar, "Open \(identifier)") }
        else {
            let tab = try XCTUnwrap(titles.map { app.tabBars.buttons[$0] }.first { $0.exists })
            try tap(tab, "Open \(identifier)")
        }
        capture("navigation-\(identifier)", revision: revision)
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, revision: String) throws {
        for step in 0..<5 where !element.exists || !element.isHittable {
            let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
            try require(scroll.exists, "Settings must expose its native scrollable form")
            scroll.swipeUp()
            capture("settings-scroll-\(step)", revision: revision)
        }
        try require(element.exists, "The required existing setting must be present")
    }

    @MainActor private func historyIDs(in app: XCUIApplication) -> Set<String> {
        Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "history.session.")).allElementsBoundByIndex
            .map { String($0.identifier.dropFirst("history.session.".count)) })
    }

    @MainActor private func liveTextCharacterCount(in app: XCUIApplication) -> Int {
        liveParagraphs(in: app).reduce(0) { $0 + $1.label.count }
    }

    @MainActor private func liveParagraphs(in app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "meeting.liveParagraph.")).allElementsBoundByIndex
    }

    @MainActor private func verifyLatestCaptionVisible(in app: XCUIApplication) throws {
        let latest = try XCTUnwrap(liveParagraphs(in: app).last, "At least one committed protected paragraph is required")
        let viewport = app.descendants(matching: .any)["meeting.liveTranscript"].firstMatch
        try require(viewport.frame.height > 0 && !latest.frame.intersection(viewport.frame).isEmpty && latest.isHittable,
                    "The latest committed paragraph must actually be visible in the native viewport")
    }

    @MainActor private func firstButton(in app: XCUIApplication, labels: [String]) -> XCUIElement? {
        labels.map { app.buttons[$0].firstMatch }.first { $0.exists }
    }

    @MainActor private func waitForButton(in app: XCUIApplication, labels: [String], timeout: TimeInterval) async throws -> XCUIElement {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let button = firstButton(in: app, labels: labels) { return button }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("The expected native share action did not appear")
    }

    @MainActor private func waitForCompletedTranscript(in app: XCUIApplication, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if app.buttons["transcript.more"].exists && !app.buttons["meeting.stop"].exists { return }
            if app.buttons["meeting.retry"].exists || app.alerts.count > 0 {
                throw verificationFailure("The actual recording failed or was interrupted instead of completing")
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        throw verificationFailure("Completion did not join and expose the transcript within the deadline")
    }

    @MainActor private func tap(_ element: XCUIElement, _ message: String) throws {
        try require(element.waitForExistence(timeout: 5) && element.isHittable && element.isEnabled, message)
        element.tap()
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw verificationFailure(message) }
    }

    private func verificationFailure(_ message: String) -> NSError {
        NSError(domain: "PhysicalReleaseUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func capture(_ step: String, revision: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
