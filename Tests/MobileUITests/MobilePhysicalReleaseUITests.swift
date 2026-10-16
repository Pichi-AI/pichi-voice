import XCTest
import UIKit
@preconcurrency import AVFoundation

/// Opt-in tests of the installed, ordinary app through its public UI. The runner owns
/// only public synthetic playback; it does not import the app or inject capture/services.
final class MobilePhysicalReleaseUITests: XCTestCase {
    @MainActor
    func testPhysicalOwnerVoiceSampleCanBeCheckedAndDiscardedWithoutSaving() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized physical-device audio lease")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_OWNER_VOICE_UI"] == "1",
              environment["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1" else {
            throw XCTSkip("Enable physical owner voice checking and audible playback explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        try require(!revision.isEmpty && revision != "working-tree", "A concrete AUT revision is required")
        let runnerID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(runnerID.hasSuffix(".xctrunner"), "Playback must be owned by the UI test runner")
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        try require(backgroundModes.contains("audio"), "The frozen signed UI runner must declare background audio")
        let assets = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: false)
        let fixture = assets.appendingPathComponent("PhysicalReleaseUI/audio/owner-enrollment.wav")
        try require(FileManager.default.fileExists(atPath: fixture.path), "Stage the approved synthetic owner voice WAV in the runner")
        let player = try AVAudioPlayer(contentsOf: fixture)
        try require(player.duration.isFinite && player.duration >= 15, "Owner checking requires a valid single-voice speech fixture")
        player.numberOfLoops = -1
        player.volume = 0.8
        try require(player.prepareToPlay(), "The runner must prepare actual synthetic speech playback")

        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice.mobile")
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.activate()
        try openNavigation(app, "meetings", titles: ["Meetings", "Встречи"], revision: revision)
        try require(!app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "An existing meeting or transcription is not owned by this test")
        try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        try tap(app.buttons["settings.recording"], "Open the ordinary recording settings")
        let start = app.buttons["ownerVoice.start"]
        try reveal(start, in: app, revision: revision)
        let status = app.descendants(matching: .any)["ownerVoice.status"].firstMatch
        try require(status.waitForExistence(timeout: 5), "The existing owner profile status must be visible")
        // Allow the Settings transaction's asynchronous metadata refresh to settle.
        // A human profile is never deleted, replaced, or used as a synthetic test draft.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        if app.buttons["ownerVoice.delete"].exists
            || ["Your voice is saved", "Ваш голос сохранён"].contains(status.label) {
            throw XCTSkip("A pre-existing owner profile is preserved; this test requires an unset profile")
        }
        try require(["Your voice is not set up", "Ваш голос ещё не настроен"].contains(status.label),
                    "The app must confirm that no owner profile is configured")
        try require(!app.buttons["ownerVoice.save"].exists && !app.buttons["ownerVoice.cancel"].exists,
                    "An existing enrollment transaction is not owned by this test")
        try require(app.alerts.count == 0 && !app.staticTexts["ownerVoice.error"].exists,
                    "Permissions and owner profile readiness must be resolved before the audio lease")
        capture("owner-01-profile-unset", revision: revision)

        let audioSession = AVAudioSession.sharedInstance()
        try require(audioSession.outputVolume > 0.05, "Device output must be audible before playback")
        let originalCategory = audioSession.category
        let originalMode = audioSession.mode
        let originalOptions = audioSession.categoryOptions
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        var ownsEnrollment = false
        defer {
            player.stop()
            if ownsPlaybackSession { try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) }
            if changedPlaybackCategory {
                try? audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            }
        }
        do {
            let runner = XCUIApplication(bundleIdentifier: runnerID)
            runner.activate()
            try require(runner.state == .runningForeground, "The runner must initiate foreground playback")
            try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
            changedPlaybackCategory = true
            try audioSession.setActive(true)
            ownsPlaybackSession = true
            try require(player.play(), "The runner must start synthetic owner speech")
            app.activate()
            try tap(start, "Start the ordinary owner voice microphone capture")
            ownsEnrollment = true
            let stop = app.buttons["ownerVoice.stop"]
            try require(stop.waitForExistence(timeout: 30), "Owner voice setup must start actual microphone capture")
            capture("owner-02-microphone-recording", revision: revision)
            let began = ProcessInfo.processInfo.systemUptime
            for second in 1...18 {
                let remaining = began + Double(second) - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                try require(player.isPlaying, "Synthetic owner speech playback must continue during capture")
                if !stop.exists { break } // The production capture may reach its bounded duration itself.
            }
            if stop.exists { try tap(stop, "Finish the bounded owner voice sample") }
            try require(stop.waitForNonExistence(timeout: 10), "Microphone capture must join before checking the sample")
            player.stop()
            capture("owner-03-sample-checking", revision: revision)
            let save = app.buttons["ownerVoice.save"]
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while !save.exists && ProcessInfo.processInfo.systemUptime < deadline {
                try require(!app.staticTexts["ownerVoice.error"].exists, "The actual single-voice microphone sample must pass checking")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            try reveal(save, in: app, revision: revision)
            try require(save.exists && save.isEnabled, "A checked draft must expose the explicit Save action")
            try require(!app.buttons["ownerVoice.delete"].exists, "Checking alone must not persist a voice profile")
            capture("owner-04-checked-draft-unsaved", revision: revision)
            try tap(app.buttons["ownerVoice.cancel"], "Discard the synthetic draft without saving it")
            try require(save.waitForNonExistence(timeout: 5), "Discard must remove the ready draft")
            ownsEnrollment = false
            try require(!app.buttons["ownerVoice.delete"].exists, "Discard must leave no persistent owner profile")
            try require(["Your voice is not set up", "Ваш голос ещё не настроен"].contains(status.label),
                        "The owner profile must remain unset after discarding the draft")
            capture("owner-05-draft-discarded", revision: revision)
            try openNavigation(app, "history", titles: ["History", "История"], revision: revision)
            try openNavigation(app, "meetings", titles: ["Meetings", "Встречи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists, "Owner checking must release capture without starting a meeting")
            try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
            try tap(app.buttons["settings.recording"], "Reopen recording settings after capture cleanup")
            try reveal(start, in: app, revision: revision)
            try require(start.isEnabled && !app.buttons["ownerVoice.delete"].exists && !save.exists,
                        "Navigation must remain responsive and the discarded draft must not return")
            capture("owner-06-clean-settings-reopened", revision: revision)
        } catch {
            player.stop()
            if ownsEnrollment {
                let cleanup = Task { @MainActor in
                    app.activate()
                    let cancel = app.buttons["ownerVoice.cancel"]
                    if cancel.exists && cancel.isEnabled { cancel.tap() }
                    let deadline = ProcessInfo.processInfo.systemUptime + 120
                    while app.buttons["ownerVoice.cancel"].exists && ProcessInfo.processInfo.systemUptime < deadline {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                    }
                    self.capture("owner-failure-draft-cleanup", revision: revision)
                    if app.buttons["ownerVoice.cancel"].exists {
                        print("[PHYSICAL_OWNER_UI] cleanup_requires_parent_inspection revision=\(revision)")
                    }
                }
                await cleanup.value
            }
            throw error
        }
        #endif
    }

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
            try require(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph.")).count > 0,
                        "The completed transcript must contain readable paragraphs backed by real segments")
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

    /// Human-observed smoke flow. Every checkpoint pauses before the next UI action
    /// until the parent has inspected the native screenshot and supplied its ACK.
    @MainActor
    func testReleaseVisibleOneMinuteRecordingWithParentCheckpoints() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized, visually observed physical-device audio lease")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_VISIBLE_UI"] == "1",
              environment["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1" else {
            throw XCTSkip("Enable visible physical recording and audible playback explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        try require(!revision.isEmpty && revision != "working-tree", "A concrete frozen AUT revision is required")
        let runnerID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(runnerID.hasSuffix(".xctrunner"), "Only the UI runner may own synthetic playback")
        let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        try require(backgroundModes.contains("audio"), "The frozen, validly signed runner must declare background audio")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let fixture = support.appendingPathComponent("PhysicalReleaseUI/audio/ru.wav")
        try require(FileManager.default.fileExists(atPath: fixture.path), "Stage the approved synthetic Russian WAV in the runner")
        let player = try AVAudioPlayer(contentsOf: fixture)
        try require(player.duration.isFinite && player.duration >= 1, "The speech fixture must be valid")
        player.numberOfLoops = -1
        player.volume = 0.8
        try require(player.prepareToPlay(), "The runner must prepare synthetic playback")
        let checkpoints = support.appendingPathComponent("VisibleRecordingUI", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        print("[VISIBLE_UI_RUN] directory=\(checkpoints.path) revision=\(revision) test=testReleaseVisibleOneMinuteRecordingWithParentCheckpoints")

        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice.mobile")
        app.launchArguments = []
        app.launchEnvironment = [:]
        let audioSession = AVAudioSession.sharedInstance()
        let originalCategory = audioSession.category
        let originalMode = audioSession.mode
        let originalOptions = audioSession.categoryOptions
        var ownsRecording = false
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        defer {
            player.stop()
            if ownsPlaybackSession { try? audioSession.setActive(false, options: .notifyOthersOnDeactivation) }
            if changedPlaybackCategory {
                try? audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            }
        }
        do {
            app.activate()
            try await visibleCheckpoint("00-foreground", app: app, revision: revision, directory: checkpoints)
            try require(app.state == .runningForeground, "The ordinary Release AUT must be foreground")
            try openNavigation(app, "meetings", titles: ["Meetings", "Встречи"], revision: revision)
            try await visibleCheckpoint("01-meetings-idle", app: app, revision: revision, directory: checkpoints)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "An existing recording or processing attempt is not owned by this test")
            if !app.buttons["meeting.start"].exists {
                try tap(app.buttons["meeting.new"], "Create a fresh meeting view without deleting history")
                try await visibleCheckpoint("02-new-meeting", app: app, revision: revision, directory: checkpoints)
            }
            try require(app.buttons["meeting.start"].waitForExistence(timeout: 15)
                        && app.buttons["meeting.start"].isEnabled && app.buttons["meeting.start"].isHittable,
                        "The real Start action must be ready")
            try require(app.alerts.count == 0, "Resolve permission or readiness prompts through normal UI before testing")
            try require(audioSession.outputVolume > 0.05, "The device speaker must already be audible")
            try await visibleCheckpoint("03-ready", app: app, revision: revision, directory: checkpoints)

            try tap(app.buttons["meeting.start"], "Tap the actual Release Start action before any speech playback")
            ownsRecording = true
            try await waitForVisibleRecording(in: app, timeout: 90)
            let beforeSpeechTimer = try visibleTimerSeconds(in: app)
            try await visibleCheckpoint("04-recording-before-speech", app: app, revision: revision, directory: checkpoints)
            try verifyVisibleRecording(in: app)
            try require(!player.isPlaying, "No speech may play before visually acknowledged recording")

            let runner = XCUIApplication(bundleIdentifier: runnerID)
            runner.activate()
            try await visibleCheckpoint("05-playback-runner-foreground", app: runner, revision: revision, directory: checkpoints)
            try require(runner.state == .runningForeground, "Initiate playback while its owning runner is foreground")
            try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
            changedPlaybackCategory = true
            try audioSession.setActive(true)
            ownsPlaybackSession = true
            try require(player.play(), "The runner must start real synthetic speech playback")
            app.activate()
            try verifyVisibleRecording(in: app)
            try require(try visibleTimerSeconds(in: app) >= beforeSpeechTimer, "The same recording timer must survive the foreground change")
            try await visibleCheckpoint("06-recording-with-speech", app: app, revision: revision, directory: checkpoints)
            let speechStartTimer = try visibleTimerSeconds(in: app)
            try await observeVisibleRecording(in: app, player: player, seconds: 30)
            let thirtySecondTimer = try visibleTimerSeconds(in: app)
            try require(thirtySecondTimer >= speechStartTimer + 25, "The visible timer must advance during the first speech interval")
            try await visibleCheckpoint("07-recording-30-seconds", app: app, revision: revision, directory: checkpoints)
            try await observeVisibleRecording(in: app, player: player, seconds: 30)
            let sixtySecondTimer = try visibleTimerSeconds(in: app)
            try require(sixtySecondTimer >= thirtySecondTimer + 25, "The visible timer must keep advancing during the second speech interval")
            try await visibleCheckpoint("08-recording-60-seconds", app: app, revision: revision, directory: checkpoints)
            print("[VISIBLE_UI_RECORDING] timerBeforeSpeech=\(beforeSpeechTimer) timerAtSpeech=\(speechStartTimer) timerAt30=\(thirtySecondTimer) timerAt60=\(sixtySecondTimer) liveCharacters=\(liveTextCharacterCount(in: app))")

            player.stop()
            try require(!player.isPlaying, "Stop the owned speech player before stopping capture")
            try tap(app.buttons["meeting.stop"], "Tap the actual Stop and Transcribe action")
            // A very short session may complete before the processing snapshot. Retain
            // the observed state rather than requiring a transient spinner to linger.
            try await waitForVisibleProcessingOrCompletion(in: app, timeout: 30)
            try await visibleCheckpoint("09-processing", app: app, revision: revision, directory: checkpoints)
            try await waitForCompletedTranscript(in: app, timeout: 300)
            ownsRecording = false
            try require(!app.buttons["meeting.stop"].exists, "Joined completion must remove the recording controls")
            let paragraphs = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
            try require(paragraphs.count > 0, "Completion must expose actual readable transcript paragraphs")
            let speakers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker."))
            if speakers.count > 0 {
                try require(speakers.allElementsBoundByIndex.allSatisfy { !$0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                            "Every exposed speaker must have a readable label")
            }
            print("[VISIBLE_UI_COMPLETED] paragraphs=\(paragraphs.count) speakers=\(speakers.count) revision=\(revision)")
            try await visibleCheckpoint("10-completed", app: app, revision: revision, directory: checkpoints)
        } catch {
            player.stop()
            // Ownership begins only after this test taps Start. Never stop an
            // unrelated meeting found in the initial foreground or idle checkpoint.
            if ownsRecording {
                let cleanup = Task { @MainActor in
                    app.activate()
                    try? self.saveVisibleCheckpoint("failure-owned-recording-foreground", app: app,
                                                    revision: revision, directory: checkpoints)
                    let stop = app.buttons["meeting.stop"]
                    if stop.waitForExistence(timeout: 30), stop.isEnabled {
                        stop.tap()
                        try? self.saveVisibleCheckpoint("failure-owned-recording-stop", app: app,
                                                        revision: revision, directory: checkpoints)
                        do { try await self.waitForCompletedTranscript(in: app, timeout: 300) }
                        catch { print("[VISIBLE_UI_CLEANUP] joined_completion_requires_parent_inspection") }
                    } else if !app.buttons["transcript.more"].exists {
                        print("[VISIBLE_UI_CLEANUP] stop_unavailable_requires_parent_inspection")
                    }
                    try? self.saveVisibleCheckpoint("failure-owned-recording-cleanup", app: app,
                                                    revision: revision, directory: checkpoints)
                }
                await cleanup.value
            } else {
                try? saveVisibleCheckpoint("failure-current-state", app: app, revision: revision, directory: checkpoints)
            }
            throw error
        }
        #endif
    }

    @MainActor private func saveVisibleCheckpoint(_ step: String, app: XCUIApplication,
                                                  revision: String, directory: URL) throws {
        let screenshot = XCUIScreen.main.screenshot()
        try screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(step).png"), options: .atomic)
        let details = "test=\(name)\nstep=\(step)\nrevision=\(revision)\nuptime=\(ProcessInfo.processInfo.systemUptime)\nappState=\(app.state.rawValue)\n\n\(app.debugDescription)\n"
        try details.write(to: directory.appendingPathComponent("\(step).txt"), atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "\(name)-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor private func visibleCheckpoint(_ step: String, app: XCUIApplication,
                                              revision: String, directory: URL) async throws {
        try saveVisibleCheckpoint(step, app: app, revision: revision, directory: directory)
        print("[VISIBLE_UI_CHECKPOINT] step=\(step) directory=\(directory.path) revision=\(revision)")
        let acknowledgement = directory.appendingPathComponent("\(step).ack")
        let deadline = ProcessInfo.processInfo.systemUptime + 120
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: acknowledgement.path) {
                print("[VISIBLE_UI_ACK] step=\(step)")
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("Parent did not acknowledge native checkpoint \(step) within 120 seconds")
    }

    @MainActor private func verifyVisibleRecording(in app: XCUIApplication) throws {
        try require(app.state == .runningForeground, "The recording AUT must remain visibly foreground")
        try require(app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                    && app.buttons["meeting.stop"].exists && app.buttons["meeting.stop"].isEnabled
                    && app.descendants(matching: .any)["meeting.timer"].firstMatch.exists,
                    "Actual recording UI must expose its recording container, enabled Stop action and timer")
        try require(app.alerts.count == 0 && !app.buttons["meeting.retry"].exists,
                    "The actual recording must not show an error or permission alert")
    }

    @MainActor private func visibleTimerSeconds(in app: XCUIApplication) throws -> Int {
        let timer = app.descendants(matching: .any)["meeting.timer"].firstMatch
        try require(timer.exists, "The actual recording timer must exist")
        let components = timer.label.split(separator: ":").map { Int($0) }
        try require((2...3).contains(components.count) && components.allSatisfy { $0 != nil && $0! >= 0 },
                    "The visible recording timer must use a readable timestamp")
        return components.reduce(0) { $0 * 60 + $1! }
    }

    @MainActor private func waitForVisibleRecording(in app: XCUIApplication, timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if app.buttons["meeting.stop"].exists && app.buttons["meeting.stop"].isEnabled {
                try verifyVisibleRecording(in: app)
                return
            }
            if app.alerts.count > 0 || app.buttons["meeting.retry"].exists {
                throw verificationFailure("The real Start action exposed an alert or failed attempt")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("The real Start action did not reach active recording")
    }

    @MainActor private func observeVisibleRecording(in app: XCUIApplication, player: AVAudioPlayer,
                                                   seconds: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try verifyVisibleRecording(in: app)
            try require(player.isPlaying, "Owned synthetic playback must remain active during recording")
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        try verifyVisibleRecording(in: app)
    }

    @MainActor private func waitForVisibleProcessingOrCompletion(in app: XCUIApplication,
                                                                timeout: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
                || (app.buttons["transcript.more"].exists && !app.buttons["meeting.stop"].exists) { return }
            if app.alerts.count > 0 || app.buttons["meeting.retry"].exists {
                throw verificationFailure("The actual Stop action failed instead of processing")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("Stop did not enter processing or joined completion")
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
