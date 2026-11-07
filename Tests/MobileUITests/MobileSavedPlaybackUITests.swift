import XCTest

/// Ordinary saved transcript, store and AVPlayer. The parent stages only the
/// approved synthetic fixture in an owned simulator and retains storage evidence.
final class MobileSavedPlaybackUITests: XCTestCase {
    private let sessionID = "F0000000-0000-4000-8000-000000000121"
    private let segmentID = "F0000000-0000-4000-8000-000000001121"

    @MainActor
    func testSavedPlaybackPauseResumeEndReplayAndReopen() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic playback fixture is restricted to an owned simulator")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_SAVED_PLAYBACK_FIXTURE_STAGED"] == "1" else {
            throw XCTSkip("Stage SavedPlaybackMeeting.json and SavedPlaybackTone.wav as documented")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        for (language, appearance, recordings, play, pause, close, positionLabel) in [
            ("en", "light", "Recordings", "Play audio chunk", "Pause audio chunk", "Close audio player",
             "Audio chunk position"),
            ("ru", "dark", "Записи", "Воспроизвести аудиофрагмент",
             "Приостановить воспроизведение фрагмента", "Закрыть аудиоплеер", "Позиция в аудиофрагменте")
        ] {
            app.launchArguments = ["-MobileSetupVersion", "1", "-MobileMeetingBehaviorVersion", "1",
                "-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launchEnvironment["PICHI_UI_SAVED_MEETING_REVIEW"] = "1"
            app.launch()
            try openOwnedTranscript(app, recordings: recordings)
            let prefix = "saved-playback-\(language)-\(appearance)"
            capture("\(prefix)-01-transcript", app: app)
            try exercisePlayer(app, segmentID: segmentID, play: play, pause: pause, close: close,
                               positionLabel: positionLabel, prefix: prefix)
            app.terminate()
            app.launch()
            try openOwnedTranscript(app, recordings: recordings)
            XCTAssertTrue(app.buttons["transcript.audio.\(segmentID)"].isHittable)
            XCTAssertFalse(app.sliders[positionLabel].exists,
                           "A reopened saved transcript must not retain a running player")
            XCTAssertTrue(app.staticTexts["Synthetic playback acceptance clip."].exists)
            capture("\(prefix)-07-reopened", app: app)
            app.terminate()
        }
        #endif
    }

    @MainActor
    private func openOwnedTranscript(_ app: XCUIApplication, recordings: String) throws {
        let sidebar = app.buttons["navigation.meetings"]
        if sidebar.exists && sidebar.isHittable { sidebar.tap() }
        else {
            let tab = app.tabBars.buttons[recordings]
            XCTAssertTrue(tab.waitForExistence(timeout: 10) && tab.isHittable)
            tab.tap()
        }
        let row = app.buttons["history.session.\(sessionID)"]
        XCTAssertTrue(row.waitForExistence(timeout: 15) && row.isHittable,
                      "Only the staged synthetic session may be opened")
        row.tap()
        XCTAssertTrue(app.buttons["transcript.audio.\(segmentID)"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.alerts.count, 0)
        XCTAssertFalse(app.buttons["meeting.stop"].exists)
    }

    @MainActor
    private func exercisePlayer(_ app: XCUIApplication, segmentID: String, play: String,
                                pause: String, close: String, positionLabel: String, prefix: String) throws {
        let audio = app.buttons["transcript.audio.\(segmentID)"]
        let slider = app.sliders[positionLabel]
        audio.tap()
        defer {
            // Close only the player this test opened. Never stop a recording.
            if app.state == .runningForeground && app.alerts.count == 0
                && audio.exists && audio.label == close && audio.isHittable { audio.tap() }
        }
        let pauseButton = app.buttons[pause]
        let playButton = app.buttons[play]
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 10) && pauseButton.isEnabled)
        XCTAssertTrue(slider.exists && slider.isEnabled)
        try waitForPosition(slider, minimum: 1, timeout: 8)
        capture("\(prefix)-02-playing", app: app)
        pauseButton.tap()
        XCTAssertTrue(playButton.waitForExistence(timeout: 5) && playButton.isEnabled)
        let pausedPosition = try position(slider)
        let advanced = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            (try? position(slider)).map { $0 > pausedPosition + 1 } ?? false
        }, object: nil)
        // Allow one integer-second boundary from an already queued 0.2-second
        // progress callback. A player still running must cross two boundaries
        // during this interval and fail the observation.
        XCTAssertEqual(XCTWaiter.wait(for: [advanced], timeout: 3.5), .timedOut,
                       "Paused native playback must not continue advancing")
        XCTAssertTrue(playButton.exists)
        capture("\(prefix)-03-paused", app: app)
        playButton.tap()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 5))
        try waitForPosition(slider, minimum: pausedPosition + 1, timeout: 5)
        capture("\(prefix)-04-resumed", app: app)
        XCTAssertTrue(playButton.waitForExistence(timeout: 18), "The real clip must reach its end")
        XCTAssertEqual(try position(slider), 12, "The fixture has twelve seconds of playable PCM")
        capture("\(prefix)-05-ended", app: app)
        playButton.tap()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 5))
        let rewound = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            (try? position(slider)).map { $0 < 5 } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rewound], timeout: 5), .completed,
                       "Replay must start again near the beginning")
        try waitForPosition(slider, minimum: 1, timeout: 5)
        XCTAssertEqual(audio.label, close)
        audio.tap()
        XCTAssertTrue(slider.waitForNonExistence(timeout: 5))
        XCTAssertFalse(pauseButton.exists)
        capture("\(prefix)-06-closed", app: app)
    }

    @MainActor
    private func position(_ slider: XCUIElement) throws -> Int {
        let value = try XCTUnwrap(slider.value as? String)
        let parts = value.split(separator: ":").compactMap { Int($0) }
        XCTAssertEqual(parts.count, 2, "Native slider must expose its formatted playback position")
        guard parts.count == 2 else { throw NSError(domain: "SavedPlaybackUI", code: 1) }
        return parts[0] * 60 + parts[1]
    }

    @MainActor
    private func waitForPosition(_ slider: XCUIElement, minimum: Int, timeout: TimeInterval) throws {
        let reached = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            (try? position(slider)).map { $0 >= minimum } ?? false
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reached], timeout: timeout), .completed,
                       "Real native playback position must advance")
    }

    @MainActor
    private func capture(_ step: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = step; shot.lifetime = .keepAlways; add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(step)-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }
}
