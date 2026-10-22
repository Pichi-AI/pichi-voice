import XCTest
import UIKit
import CoreText

final class MobileNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        if name.contains("testFragmentParticipantCorrectionScopesUndoAndReopen")
            || name.contains("testManualYouDesignationSwitchClearUndoAndReopen")
            || name.contains("testTranscriptScrollKeepsNavigationControlsReadable") {
            #if !targetEnvironment(simulator)
            throw XCTSkip("Participant correction fixtures are simulator-only")
            #endif
        }
        if name.contains("testSavedTranscriptCaptionContractInBothAppearances") {
            #if !targetEnvironment(simulator)
            throw XCTSkip("This staged-session UI contract is simulator-only; physical saved-session review is separately guarded")
            #else
            guard ProcessInfo.processInfo.environment["PICHI_PRIVATE_SAVED_SESSION_ID"] != nil else {
                throw XCTSkip("Stage an authorized local saved-session fixture and provide its ID")
            }
            #endif
        }
        let productionDownload = name.contains("testPhysicalProductionDownloadSpeechActivity")
        let productionSmoke = name.contains("testPhysicalProductionMeetingAndProtectedExport") || productionDownload
        if productionSmoke {
            #if targetEnvironment(simulator)
            throw XCTSkip("Production smoke requires an explicitly authorized physical device")
            #else
            guard ProcessInfo.processInfo.environment["PICHI_PHYSICAL_PRODUCTION_SMOKE"] == "1" else {
                throw XCTSkip("Set PICHI_PHYSICAL_PRODUCTION_SMOKE=1 to create one real meeting")
            }
            if productionDownload,
               ProcessInfo.processInfo.environment["PICHI_PHYSICAL_PRODUCTION_DOWNLOAD_SPEECH_ACTIVITY"] != "1" {
                throw XCTSkip("Set PICHI_PHYSICAL_PRODUCTION_DOWNLOAD_SPEECH_ACTIVITY=1 to use the production Download action")
            }
            #endif
        }
        continueAfterFailure = false
        if !productionDownload { XCUIDevice.shared.orientation = .portrait }
        app = XCUIApplication()
        if !productionDownload { app.launchArguments += ["-PichiInterfaceLanguage", "en"] }
        if productionSmoke {
            // Attach without restarting a running AUT, including an unowned recording.
            // The body checks idle state before it can claim a new recording.
            switch app.state {
            case .notRunning:
                guard !productionDownload else {
                    throw NSError(domain: "ProductionUISmoke", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Download smoke only attaches to an already running ordinary Release AUT"])
                }
                app.launch()
            case .runningForeground, .runningBackground, .runningBackgroundSuspended: app.activate()
            case .unknown:
                throw NSError(domain: "ProductionUISmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot safely determine the existing AUT state"])
            @unknown default:
                throw NSError(domain: "ProductionUISmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot safely attach to the existing AUT state"])
            }
        } else { app.launch() }
        if !productionDownload { waitForOrientation(portrait: true) }
    }

    /// The parent preserves storage and independently verifies downloaded artifact hashes.
    /// This attaches to the existing ordinary Release AUT and changes no preferences.
    @MainActor
    func testPhysicalProductionDownloadSpeechActivity() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Production download smoke requires an explicitly authorized physical device")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_PRODUCTION_SMOKE"] == "1",
              environment["PICHI_PHYSICAL_PRODUCTION_DOWNLOAD_SPEECH_ACTIVITY"] == "1" else {
            throw XCTSkip("Production download requires both physical smoke and speech activity download opt-ins")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "ProductionUISmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func requireNoActiveAttempt() throws {
            try require(app.state == .runningForeground && app.alerts.count == 0
                        && !app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.preparing"].firstMatch.exists,
                        "Download smoke refuses existing recording, preparation, processing or alerts")
        }
        func requireMeetingAtRest() throws {
            try requireNoActiveAttempt()
            let start = app.buttons["meeting.start"]
            try require((start.exists && start.isEnabled) || app.buttons["transcript.more"].exists,
                        "Meetings must show idle recording controls or an existing completed transcript")
            let recoveryHeading = app.staticTexts.matching(NSPredicate(format: "label IN %@", [
                "Meeting transcription was interrupted", "Расшифровка встречи прервана",
                "Meeting transcription failed", "Не удалось расшифровать встречу"
            ])).firstMatch
            try require(!recoveryHeading.exists, "Download smoke refuses interrupted or failed meetings even without retryable audio")
            try require(!app.buttons["meeting.retry"].exists && !app.buttons["meeting.restartProcessing"].exists,
                        "Download smoke refuses a meeting awaiting recovery")
        }
        do {
            capture("speech-download-01-attached")
            try require(!revision.isEmpty && revision != "working-tree",
                        "A concrete frozen Release AUT revision is required")
            try requireNoActiveAttempt()
            // Ordinary navigation reveals the current session before Settings is touched.
            openNavigation("meetings", title: app.tabBars.buttons["Встречи"].exists ? "Встречи" : "Meetings")
            try requireMeetingAtRest()
            openNavigation("settings", title: app.tabBars.buttons["Настройки"].exists ? "Настройки" : "Settings")
            try requireNoActiveAttempt()
            let recording = app.buttons["settings.recording"]
            try require(recording.waitForExistence(timeout: 5) && recording.isEnabled && recording.isHittable,
                        "Existing Recording settings navigation must be available")
            recording.tap()
            capture("speech-download-02-recording-settings")
            try require(app.descendants(matching: .any)["settings.recording.detail"].firstMatch
                .waitForExistence(timeout: 5), "Recording settings must open normally")
            let download = app.buttons["recording.downloadSpeechActivity"]
            let heading = app.staticTexts.matching(NSPredicate(
                format: "label ==[c] %@ OR label ==[c] %@", "Speech detection", "Определение речи")).firstMatch
            let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            for step in 0..<8 where !download.isHittable || !heading.isHittable {
                try requireNoActiveAttempt()
                try require(scroll.exists && scroll.isHittable, "Recording settings must expose a native scroll container")
                if download.isHittable { scroll.swipeDown() } else { scroll.swipeUp() }
                capture("speech-download-03-reveal-\(step)")
            }
            try requireNoActiveAttempt()
            try require(heading.isHittable && download.isHittable && download.isEnabled,
                        "The speech detection section and its enabled production Download must be visible")
            download.tap()
            capture("speech-download-04-production-download-tapped")
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            var ready = false
            while ProcessInfo.processInfo.systemUptime < deadline {
                try requireNoActiveAttempt()
                // Ready labels elsewhere (speaker resources or owner voice) cannot satisfy this check.
                let sectionTop = heading.frame.maxY
                let sectionBottom = download.frame.minY
                ready = heading.isHittable && download.isHittable && download.isEnabled
                    && sectionBottom > sectionTop
                    && app.staticTexts.matching(NSPredicate(format: "label IN %@", ["Ready", "Готово"]))
                        .allElementsBoundByIndex.contains { label in
                            let bounds = label.frame
                            return !bounds.isEmpty && bounds.minY >= sectionTop && bounds.maxY <= sectionBottom
                                && bounds.maxX > download.frame.minX && bounds.minX < download.frame.maxX
                        }
                if ready { break }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            capture("speech-download-05-download-result")
            try require(ready, "Speech detection must show its own Ready label and enabled Download within 120 seconds")
            openNavigation("meetings", title: app.tabBars.buttons["Встречи"].exists ? "Встречи" : "Meetings")
            try requireMeetingAtRest()
            capture("speech-download-06-returned-to-existing-meeting")
        } catch {
            capture("speech-download-failure-current-state")
            throw error
        }
        #endif
    }

    /// The parent owns approved external speech playback and before/after storage inspection.
    /// This selector creates one real meeting using the ordinary AUT's existing settings.
    @MainActor
    func testPhysicalProductionMeetingAndProtectedExport() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Production smoke requires an explicitly authorized physical device")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_PRODUCTION_SMOKE"] == "1" else {
            throw XCTSkip("Set PICHI_PHYSICAL_PRODUCTION_SMOKE=1 to create one real meeting")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        guard !revision.isEmpty, revision != "working-tree" else {
            throw NSError(domain: "ProductionUISmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "A concrete frozen Release AUT revision is required"])
        }
        let backgroundSmoke = environment["PICHI_PHYSICAL_PRODUCTION_BACKGROUND_SMOKE"] == "1"
        let longSmoke = environment["PICHI_PHYSICAL_PRODUCTION_LONG_SMOKE"] == "1"
        let presentationFile = environment["PICHI_PHYSICAL_PRODUCTION_PRESENTATION_FILE"]
        let saveExportName = environment["PICHI_PHYSICAL_PRODUCTION_SAVE_EXPORT_NAME"]
        if let saveExportName {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard saveExportName.count <= 128, saveExportName.hasSuffix(".json"),
                  saveExportName.count > 5, !saveExportName.hasPrefix("."),
                  saveExportName.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  environment["PICHI_PRESENTATION_FIXTURE_LOCATION"]?.isEmpty == false,
                  environment["PICHI_PRESENTATION_FIXTURE_FOLDER"] == "Codex-Pichi-Demo-20261018" else {
                throw NSError(domain: "ProductionUISmoke", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Native export needs a unique JSON basename and the explicit owned Files location/folder"])
            }
        }
        guard presentationFile == nil || (!backgroundSmoke && presentationFile?.isEmpty == false) else {
            throw NSError(domain: "ProductionUISmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "A presentation is a foreground test and needs a staged synthetic PDF filename"])
        }
        guard let observationSeconds = Int(environment["PICHI_PHYSICAL_PRODUCTION_SMOKE_SECONDS"] ?? "45"),
              ([45, 180].contains(observationSeconds) || (longSmoke && observationSeconds == 3600)),
              !backgroundSmoke || observationSeconds == 180 else {
            throw NSError(domain: "ProductionUISmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Smoke duration must be 45 or 180 seconds, or 3600 with explicit long opt-in; background requires 180"])
        }
        let began = ProcessInfo.processInfo.systemUptime
        var events: [[String: Any]] = []
        var recordingUIHealthChecks: [[String: Any]] = []
        var passedRecordingUIHealthChecks = 0
        let recordingUIHealthCheckIntervalSeconds = PhysicalProductionObservationSchedule(
            startedAt: began, observationSeconds: observationSeconds, longSmoke: longSmoke).uiHealthCheckIntervalSeconds
        var backgroundObservedSeconds: TimeInterval = 0
        var ownsRecording = false
        var outcome = "failed"
        func mark(_ event: String) {
            let uptime = ProcessInfo.processInfo.systemUptime
            events.append(["event": event, "uptimeSeconds": uptime, "elapsedSeconds": uptime - began,
                           "wallClockUnixSeconds": Date().timeIntervalSince1970])
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "ProductionUISmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func recordingVisible() -> Bool {
            app.state == .runningForeground
                && app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                && app.buttons["meeting.stop"].exists && app.buttons["meeting.stop"].isEnabled
                && app.descendants(matching: .any)["meeting.timer"].firstMatch.exists
                && app.alerts.count == 0 && !app.buttons["meeting.retry"].exists
        }
        func completed() -> Bool {
            app.state == .runningForeground && app.buttons["transcript.more"].exists
                && !app.buttons["meeting.stop"].exists
                && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
        }
        let terminalTitle = environment["PICHI_PHYSICAL_PRODUCTION_OWNED_TERMINAL_TITLE"]
        let terminalState = environment["PICHI_PHYSICAL_PRODUCTION_OWNED_TERMINAL_STATE"]
        let completedTitle = environment["PICHI_PHYSICAL_PRODUCTION_OWNED_COMPLETED_TITLE"]
        if terminalTitle != nil || terminalState != nil {
            try require(terminalTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        && (terminalTitle?.count ?? 0) <= 1024
                        && ["completed", "interrupted", "failed"].contains(terminalState ?? "")
                        && completedTitle == nil,
                        "Owned terminal admission requires a nonempty exact title and explicit terminal state; do not combine legacy admission")
        }
        let priorOwnedTitle = terminalTitle ?? completedTitle
        let priorOwnedState = terminalState ?? (completedTitle == nil ? nil : "completed")
        func noActiveAttemptVisible() -> Bool {
            app.state == .runningForeground
                && !app.buttons["meeting.stop"].exists
                && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
        }
        func priorOwnedTerminalVisible() -> Bool {
            guard let priorOwnedTitle, !priorOwnedTitle.isEmpty, noActiveAttemptVisible(),
                  app.staticTexts.matching(NSPredicate(format: "label == %@", priorOwnedTitle)).firstMatch.exists else {
                return false
            }
            let interrupted = app.staticTexts.matching(NSPredicate(format: "label IN %@",
                ["Meeting transcription was interrupted", "Расшифровка встречи прервана"])).firstMatch.exists
            let failed = app.staticTexts.matching(NSPredicate(format: "label IN %@",
                ["Meeting transcription failed", "Не удалось расшифровать встречу"])).firstMatch.exists
            switch priorOwnedState {
            case "completed":
                return completed() && !interrupted && !failed && !app.buttons["meeting.retry"].exists
                    && !app.buttons["meeting.restartProcessing"].exists
            case "interrupted": return interrupted && !failed
            case "failed": return failed && !interrupted
            default: return false
            }
        }
        func waitForCompletion(timeout: TimeInterval) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while ProcessInfo.processInfo.systemUptime < deadline {
                try require(app.state == .runningForeground,
                            "Completion inspection requires the still-running foreground AUT")
                if completed() { return }
                try require(app.alerts.count == 0 && !app.buttons["meeting.retry"].exists,
                            "The owned meeting must complete without an error or recovery prompt")
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            try require(false, "Stop did not expose a completed transcript within the deadline")
        }
        // XCTest action failures can bypass Swift catch. Always register owned
        // cleanup before Start, and retain its evidence even when the body aborts.
        addTeardownBlock { @MainActor in
            if ownsRecording {
                let cleanup = Task { @MainActor in
                    self.continueAfterFailure = true
                    self.capture("production-failure-owned-state")
                    let stopDeadline = ProcessInfo.processInfo.systemUptime + 15
                    var foregroundReady = false
                    while ProcessInfo.processInfo.systemUptime < stopDeadline {
                        // State inspection never activates or launches the AUT. Do not
                        // query controls while it is backgrounded, suspended or dead.
                        switch self.app.state {
                        case .notRunning, .unknown:
                            mark("cleanup_requires_parent_inspection")
                            print("[PRODUCTION_UI_SMOKE] cleanup_requires_parent_inspection")
                            return
                        case .runningBackground, .runningBackgroundSuspended:
                            try? await Task.sleep(nanoseconds: 250_000_000)
                            continue
                        case .runningForeground: foregroundReady = true
                        @unknown default:
                            mark("cleanup_requires_parent_inspection")
                            print("[PRODUCTION_UI_SMOKE] cleanup_requires_parent_inspection")
                            return
                        }
                        if completed() { break }
                        if presentationFile != nil && !self.app.buttons["meeting.stop"].isHittable {
                            // This selector owns the PDF/picker it opened. Close only
                            // that presentation before using normal owned Stop.
                            let closePresentation = self.app.buttons.matching(NSPredicate(
                                format: "identifier == %@ OR label IN %@", "meeting.presentation.close",
                                ["Cancel", "Отмена", "Отменить"])).firstMatch
                            if closePresentation.exists && closePresentation.isHittable {
                                closePresentation.tap()
                                self.capture("production-failure-owned-presentation-dismissed")
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                continue
                            }
                        }
                        let stop = self.app.buttons["meeting.stop"]
                        if stop.exists, stop.isEnabled, stop.isHittable {
                            mark("cleanup_stop_tap_requested")
                            stop.tap()
                            mark("cleanup_stop_tap_returned")
                            self.capture("production-failure-owned-stop")
                            break
                        }
                        if self.app.alerts.count > 0 || self.app.buttons["meeting.retry"].exists { break }
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                    guard foregroundReady, self.app.state == .runningForeground else {
                        mark("cleanup_requires_parent_inspection")
                        print("[PRODUCTION_UI_SMOKE] cleanup_requires_parent_inspection")
                        return
                    }
                    do {
                        try await waitForCompletion(timeout: 90)
                        mark("cleanup_completed_transcript_visible")
                    } catch {
                        mark("cleanup_requires_parent_inspection")
                        print("[PRODUCTION_UI_SMOKE] cleanup_requires_parent_inspection")
                    }
                    self.capture("production-failure-owned-terminal")
                }
                await cleanup.value
            }
            let report: [String: Any] = [
                "test": "testPhysicalProductionMeetingAndProtectedExport", "revision": revision,
                "outcome": outcome, "events": events, "plannedRecordingObservationSeconds": observationSeconds,
                "backgroundSmoke": backgroundSmoke, "backgroundObservedSeconds": backgroundObservedSeconds,
                "longSmoke": longSmoke, "presentationFile": presentationFile ?? "",
                "recordingUIHealthCheckIntervalSeconds": recordingUIHealthCheckIntervalSeconds,
                "recordingUIHealthCheckCount": recordingUIHealthChecks.count,
                "passedRecordingUIHealthCheckCount": passedRecordingUIHealthChecks,
                "recordingUIHealthChecks": recordingUIHealthChecks,
                "recordingUIObservationScope": "Application state and accessibility health use the nominal recorded cadence, not continuously between checks. Actual start/completion timestamps and durations are attached. The parent independently captures native USB frames at 1 Hz and verifies coverage separately; this selector does not replace that capture.",
                "nativeExportFilename": saveExportName ?? "",
                "backgroundObservationScope": "Sum of intervals between consecutive runningBackground samples; app state alone does not prove audio capture, text or speaker progress",
                "speechPlaybackOwner": "parent_external_player",
                "measurementScope": "XCTest action returns and accessibility observations, including synchronization and polling; not touch latency or recognition accuracy"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "production-ui-smoke-timing-\(revision).json"
                attachment.lifetime = .keepAlways
                self.add(attachment)
            }
        }
        mark("test_body_entered")
        do {
            try require(app.state == .runningForeground, "The ordinary signed Release AUT must be foreground")
            // The parent freshly backs up and verifies the exact owned session ID,
            // title and terminal state before supplying these test-only flags. No
            // unknown or active session, retry/restart action or storage deletion
            // is admitted. Failed/interrupted New Meeting normally resolves owned
            // recovery metadata and schedules retention; the parent must preflight
            // sweep effects on all sessions as well as compare preserved data after.
            if app.alerts.count > 0 {
                try require(terminalTitle != nil && priorOwnedTerminalVisible() && app.alerts.count == 1,
                            "Only an explicitly verified owned terminal meeting may dismiss its standard error alert")
                let alert = app.alerts.firstMatch
                let ok = alert.buttons.matching(NSPredicate(format: "label IN %@", ["OK", "ОК"])).firstMatch
                try require(["Error", "Ошибка"].contains(alert.label) && alert.buttons.count == 1
                            && alert.textFields.count == 0 && alert.secureTextFields.count == 0
                            && ok.exists && ok.isEnabled && ok.isHittable,
                            "Only the ordinary single-OK error alert may be dismissed; no other prompt is accepted")
                ok.tap()
                try require(alert.waitForNonExistence(timeout: 5) && priorOwnedTerminalVisible(),
                            "Error dismissal must preserve the same owned terminal meeting")
                mark("prior_owned_terminal_standard_error_dismissed")
                capture("production-01-prior-owned-terminal-error-dismissed")
            }
            openNavigation("meetings", title: "Meetings")
            capture("production-01-existing-idle")
            try require(noActiveAttemptVisible(),
                        "An existing recording or processing attempt is not owned by this selector")
            let start = app.buttons["meeting.start"]
            if !start.exists, priorOwnedTitle != nil {
                try require(priorOwnedTerminalVisible() && app.alerts.count == 0,
                            "Only the parent's verified prior owned terminal meeting may be left through New Meeting")
                let newMeeting = app.buttons["meeting.new"]
                try require(newMeeting.exists && newMeeting.isEnabled && newMeeting.isHittable,
                            "The owned terminal meeting must expose normal New Meeting")
                newMeeting.tap()
                mark(priorOwnedState == "completed"
                    ? "prior_owned_completed_meeting_left_without_storage_edit"
                    : "prior_owned_terminal_meeting_left_through_normal_new_meeting")
                capture("production-01-prior-owned-terminal-left")
            }
            try require(start.waitForExistence(timeout: 15) && start.isEnabled && start.isHittable
                        && app.alerts.count == 0,
                        "The meeting must be idle; only the explicitly verified prior owned terminal meeting may be left")
            let startDeadline = ProcessInfo.processInfo.systemUptime + 15
            mark("start_tap_requested")
            // Ownership starts immediately before the only Start tap so a failed
            // accessibility response still leaves cleanup responsible for this attempt.
            ownsRecording = true
            start.tap()
            mark("start_tap_returned")
            print("[PRODUCTION_UI_SMOKE] start_tap_returned")
            capture("production-02-start-tap-returned")
            while !recordingVisible() && ProcessInfo.processInfo.systemUptime < startDeadline {
                try require(app.alerts.count == 0 && !app.buttons["meeting.retry"].exists,
                            "The real Start action must not require a prompt or enter recovery")
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            if !recordingVisible() {
                let hierarchy = XCTAttachment(string: app.debugDescription)
                hierarchy.name = "production-start-accessibility-\(revision)"
                hierarchy.lifetime = .keepAlways
                add(hierarchy)
            }
            try require(recordingVisible() && ProcessInfo.processInfo.systemUptime <= startDeadline,
                        "Start must expose real recording controls within 15 seconds of the XCTest tap request")
            mark("recording_visible")
            print("[PRODUCTION_UI_SMOKE] recording_visible")
            capture("production-03-recording-visible")
            var presentationDone: XCUIElement?
            if let presentationFile {
                let done = try openSyntheticPresentation(filename: presentationFile)
                presentationDone = done
                mark("presentation_visible")
                print("[PRODUCTION_UI_SMOKE] presentation_visible")
                capture("production-presentation-preview")
            }
            mark("recording_observation_began")
            let observationStartedAt = ProcessInfo.processInfo.systemUptime
            var observationSchedule = PhysicalProductionObservationSchedule(
                startedAt: observationStartedAt, observationSeconds: observationSeconds, longSmoke: longSmoke)
            try require(observationSchedule.uiHealthCheckIntervalSeconds == recordingUIHealthCheckIntervalSeconds,
                        "Recording observation must use the reported fixed UI health cadence")
            let speechDeadline = observationSchedule.deadline
            var previousState: XCUIApplication.State?
            var previousObservation: TimeInterval?
            while ProcessInfo.processInfo.systemUptime < speechDeadline {
                try Task.checkCancellation()
                // Sleeping remains cancellation-responsive without asking XCTest to
                // snapshot the growing accessibility tree on every one-second wake.
                let healthCheckStartedAt = ProcessInfo.processInfo.systemUptime
                guard observationSchedule.beginUIHealthCheck(at: healthCheckStartedAt) else {
                    try await Task.sleep(nanoseconds: observationSchedule.sleepNanoseconds(
                        at: ProcessInfo.processInfo.systemUptime))
                    continue
                }
                let state = app.state
                let observedAt = ProcessInfo.processInfo.systemUptime
                recordingUIHealthChecks.append([
                    "startedUptimeSeconds": healthCheckStartedAt, "uptimeSeconds": observedAt,
                    "elapsedObservationSeconds": healthCheckStartedAt - observationStartedAt,
                    "appState": state.rawValue
                ])
                if state != previousState { mark("observation_app_state_\(state.rawValue)") }
                if state == .runningBackground, previousState == .runningBackground, let previousObservation {
                    backgroundObservedSeconds += observedAt - previousObservation
                }
                switch state {
                case .runningForeground:
                    if let presentationDone {
                        try require(presentationDone.exists,
                                    "The in-app PDF must remain presented; recording continuity is checked in the saved session")
                    } else {
                        try require(recordingVisible(), "The owned foreground recording must remain visibly active")
                    }
                case .runningBackground:
                    try require(backgroundSmoke, "Background observation requires its explicit opt-in flag")
                    // The parent owns Safari switching and separately reads the saved
                    // protected checkpoint. Never query a background AUT's controls.
                case .runningBackgroundSuspended, .notRunning, .unknown:
                    try require(false, "The owned AUT became suspended, stopped or unknown during recording")
                @unknown default:
                    try require(false, "The owned AUT entered an unsupported recording state")
                }
                let healthCheckFinishedAt = ProcessInfo.processInfo.systemUptime
                recordingUIHealthChecks[recordingUIHealthChecks.count - 1]["completedUptimeSeconds"] = healthCheckFinishedAt
                recordingUIHealthChecks[recordingUIHealthChecks.count - 1]["queryDurationSeconds"] =
                    healthCheckFinishedAt - healthCheckStartedAt
                passedRecordingUIHealthChecks += 1
                previousState = state
                previousObservation = observedAt
                try await Task.sleep(nanoseconds: observationSchedule.sleepAfterUIHealthCheckNanoseconds(
                    at: ProcessInfo.processInfo.systemUptime))
            }
            mark("recording_observation_ended")
            if let presentationDone {
                try require(presentationDone.isHittable, "The PDF must expose native Done before returning to Stop")
                presentationDone.tap()
                mark("presentation_dismissed")
                capture("production-presentation-dismissed")
                try require(presentationDone.waitForNonExistence(timeout: 10),
                            "Native PDF dismissal must finish before accessing recording controls")
                try require(app.buttons["meeting.stop"].waitForExistence(timeout: 10),
                            "Dismissing the PDF must return to the same owned recording")
            }
            capture("production-04-before-stop")
            try require(recordingVisible(), "The parent must return the still-recording AUT to foreground before Stop")
            try require(!backgroundSmoke || backgroundObservedSeconds > 0,
                        "Background smoke must observe runningBackground before returning to the recording UI")
            mark("returned_foreground_recording_visible")
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 90
            mark("stop_tap_requested")
            app.buttons["meeting.stop"].tap()
            mark("stop_tap_returned")
            capture("production-05-stop-tap-returned")
            try await waitForCompletion(timeout: max(0, stopDeadline - ProcessInfo.processInfo.systemUptime))
            try require(ProcessInfo.processInfo.systemUptime <= stopDeadline,
                        "Stop must expose a completed transcript within 90 seconds of the XCTest tap request")
            ownsRecording = false
            mark("completed_transcript_visible")
            capture("production-06-completed-transcript")
            let paragraphs = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
            let transcript = app.scrollViews["meeting.transcript"]
            for step in 0..<4 where !paragraphs.firstMatch.exists {
                try require(transcript.exists, "The completed transcript must expose its native scroll view")
                transcript.swipeUp()
                capture("production-07-reveal-paragraph-\(step)")
            }
            try require(paragraphs.firstMatch.waitForExistence(timeout: 10),
                        "The saved real meeting must contain actual readable transcript paragraphs")
            mark("transcript_paragraph_observed")
            capture("production-08-saved-paragraph")
            let more = app.buttons["transcript.more"]
            for step in 0..<4 where !more.isHittable {
                transcript.swipeDown()
                capture("production-09-return-to-actions-\(step)")
            }
            try require(more.isHittable && more.isEnabled, "The completed transcript actions must be available")
            more.tap()
            capture("production-10-export-menu")
            let export = app.buttons["transcript.exportProtected"]
            try require(export.waitForExistence(timeout: 5) && export.isEnabled && export.isHittable,
                        "The saved real meeting must enable protected transcript export")
            mark("protected_export_tap_requested")
            export.tap()
            let activityList = app.otherElements["ActivityListView"]
            try require(activityList.waitForExistence(timeout: 15),
                        "Protected export must reload the saved session and present the native activity UI")
            mark("native_activity_visible")
            capture("production-11-native-protected-export")
            if let saveExportName {
                mark("native_files_save_requested")
                try saveProtectedExportToOwnedFiles(filename: saveExportName)
                try require(activityList.waitForNonExistence(timeout: 15) && more.isHittable,
                            "Native Files Save must return to the same completed transcript")
                mark("native_files_saved")
                print("[PRODUCTION_UI_SMOKE] native_files_saved")
                capture("production-11-native-files-saved")
                // Preserve the existing share cancellation check after real Save.
                more.tap()
                try require(export.waitForExistence(timeout: 5) && export.isHittable,
                            "The completed meeting must remain exportable after native Files Save")
                export.tap()
                try require(activityList.waitForExistence(timeout: 15),
                            "Native sharing must reopen after saving the protected export")
                mark("native_activity_reopened_after_save")
                capture("production-11-native-export-reopened")
            }
            let identifiedClose = app.buttons["header.closeButton"]
            let close = identifiedClose.exists ? identifiedClose : app.buttons.matching(
                NSPredicate(format: "label IN %@", ["Close", "Закрыть", "Cancel", "Отмена"])).firstMatch
            try require(close.waitForExistence(timeout: 5) && close.isHittable,
                        "The native share sheet must expose its Cancel/Close action")
            close.tap()
            try require(activityList.waitForNonExistence(timeout: 10) && more.isHittable,
                        "Cancelling protected export must return to the same completed transcript")
            mark("native_activity_cancelled")
            capture("production-12-export-cancelled")
            outcome = "completed"
            print("[PRODUCTION_UI_SMOKE] complete")
        } catch {
            capture("production-failure-current-state")
            throw error
        }
        #endif
    }

    func testPDFPresentationOpensAndReturnsToReadyInBothLanguages() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The parent stages a synthetic PDF in an isolated simulator Files provider")
        #else
        let filename = ProcessInfo.processInfo.environment["PICHI_PRESENTATION_FIXTURE_NAME"] ?? "SyntheticDemoPresentation.pdf"
        for (language, appearance) in [("en", "light"), ("ru", "dark")] {
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            openNavigation("meetings", title: language == "ru" ? "Встречи" : "Meetings")
            // This isolated simulator can restore an earlier synthetic recovery
            // fixture. Use normal New Meeting without deleting its stored audio.
            if !app.buttons["meeting.start"].exists {
                XCTAssertFalse(app.buttons["meeting.stop"].exists)
                XCTAssertFalse(app.descendants(matching: .any)["meeting.processing"].firstMatch.exists)
                let newMeeting = app.buttons["meeting.new"]
                XCTAssertTrue(newMeeting.waitForExistence(timeout: 10) && newMeeting.isHittable)
                newMeeting.tap()
                capture("presentation-\(language)-new-ready")
            }
            XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 15))
            capture("presentation-\(language)-ready")
            let done = try openSyntheticPresentation(filename: filename)
            capture("presentation-\(language)-native-pdf")
            done.tap()
            XCTAssertTrue(done.waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["meeting.start"].isHittable)
            XCTAssertFalse(app.buttons["meeting.stop"].exists)
            capture("presentation-\(language)-dismissed-ready")
            // A released document can be chosen again without a stale modal or lease.
            let reopenedDone = try openSyntheticPresentation(filename: filename)
            capture("presentation-\(language)-reopened-pdf")
            reopenedDone.tap()
            XCTAssertTrue(reopenedDone.waitForNonExistence(timeout: 10))
            XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 10))
            capture("presentation-\(language)-reopened-dismissed")
        }
        app.terminate()
        #endif
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

    func testFastManualReturnToCaptionBottomRestoresFollowing() throws {
        app.terminate()
        app.launchEnvironment["PICHI_UI_CAPTION_REVIEW"] = "1"
        app.launch()
        defer { app.terminate() }
        let viewport = app.tables["meeting.liveTranscript.viewport"]
        let latest = app.buttons["meeting.liveTranscript.latest"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        XCTAssertFalse(latest.waitForExistence(timeout: 1))
        capture("caption-01-initial-following")
        viewport.swipeDown(velocity: .fast)
        XCTAssertTrue(latest.waitForExistence(timeout: 3))
        capture("caption-02-reading-older-text")
        for _ in 0..<12 where latest.exists {
            viewport.swipeUp(velocity: .fast)
        }
        XCTAssertTrue(latest.waitForNonExistence(timeout: 3), "A fast finger crossing the bottom must resume following without tapping the button")
        capture("caption-03-manual-bottom-resumed")
        XCTAssertFalse(latest.waitForExistence(timeout: 2), "New captions must keep following after the rebound settles")
        capture("caption-04-new-text-still-followed")
    }

    func testOwnerVoiceSettingsUseNativeRecordingStructureInBothLanguages() throws {
        for (language, settingsTitle, appearance) in [("en", "Settings", "light"), ("ru", "Настройки", "dark")] {
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            waitForOrientation(portrait: true)
            openNavigation("settings", title: settingsTitle)
            let recording = app.buttons["settings.recording"]
            XCTAssertTrue(recording.waitForExistence(timeout: 5))
            recording.tap()
            let start = app.buttons["ownerVoice.start"]
            let scroll = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.scrollViews.firstMatch
            for step in 0..<8 where !start.isHittable {
                scroll.swipeUp()
                capture("owner-\(language)-reveal-\(step)")
            }
            XCTAssertTrue(start.isHittable)
            XCTAssertGreaterThanOrEqual(start.frame.height, 44)
            XCTAssertEqual(start.label, language == "ru" ? "Настроить мой голос" : "Set up my voice")
            XCTAssertTrue(app.staticTexts["ownerVoice.readingPrompt"].exists)
            XCTAssertFalse(app.buttons["ownerVoice.save"].exists, "Save appears only after a valid sample is checked")
            capture("owner-\(language)-\(appearance)-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            for step in 0..<5 where !start.isHittable {
                scroll.swipeUp()
                capture("owner-\(language)-landscape-reveal-\(step)")
            }
            XCTAssertTrue(start.isHittable)
            capture("owner-\(language)-\(appearance)-landscape")
            openNavigation("meetings", title: language == "ru" ? "Встречи" : "Meetings")
            XCTAssertTrue(app.buttons["meeting.start"].waitForExistence(timeout: 5))
            capture("owner-\(language)-left-settings")
        }
    }

    func testStreamingSpeakerSettingsInBothLanguagesAndThemes() throws {
        for (language, settingsTitle, appearance) in [
            ("en", "Settings", "light"), ("ru", "Настройки", "dark")
        ] {
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                "-SelectedSpeechModel", "gigaam-v3-eou", "-MobileSetupVersion", "1"]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            waitForOrientation(portrait: true)
            capture("streaming-settings-\(language)-ready")
            openNavigation("settings", title: settingsTitle)
            app.buttons["settings.recording"].tap()
            let status = app.descendants(matching: .any)["recording.requiredResources"].firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 10))
            for identifier in ["recording.diarization", "recording.streamingDiarization"] {
                XCTAssertFalse(app.switches[identifier].exists, "Speaker identification is automatic")
            }
            for identifier in ["recording.downloadSpeakerModel", "recording.downloadSpeechActivity"] {
                XCTAssertFalse(app.buttons[identifier].exists, "Required resources use automatic preparation")
            }
            capture("streaming-settings-\(language)-\(appearance)-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            XCTAssertTrue(status.exists)
            capture("streaming-settings-\(language)-\(appearance)-landscape")
        }
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
        XCTAssertTrue(app.staticTexts["GigaAM v3"].exists)
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
            try revealParagraphAboveNavigation(body, step: "word-timing-\(appearance)-landscape-reading")
            XCTAssertTrue(body.exists)
            capture("word-timing-\(appearance)-landscape-paragraph")
        }
    }

    private func revealParagraphAboveNavigation(_ paragraph: XCUIElement, step: String,
                                               container: XCUIElement? = nil) throws {
        let scroll = app.scrollViews.matching(identifier: "meeting.transcript").firstMatch
        XCTAssertTrue(scroll.exists)
        for attempt in 0..<8 {
            let window = app.windows.firstMatch.frame
            let viewport = scroll.frame.intersection(window)
            let top = max(viewport.minY, app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : viewport.minY)
            let bottom = min(viewport.maxY, app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : viewport.maxY)
            // A phone in landscape may virtualize the paragraph below its header. Scroll
            // it into the accessibility tree before asking for an off-screen element's frame.
            // A stable container may already exist while its expected body label differs.
            if !paragraph.exists {
                if let container, container.exists, container.frame.maxY > top, container.frame.minY < bottom,
                   !paragraph.waitForExistence(timeout: 2) {
                    recordSavedParagraphAccessibility(step: step, container: container)
                    XCTFail("The saved paragraph container is visible, but its expected text prefix is absent")
                    return
                }
                if paragraph.exists { continue }
                let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                from.press(forDuration: 0.05, thenDragTo: to)
                capture("\(step)-reveal-\(attempt)")
                continue
            }
            if paragraph.isHittable && paragraph.frame.minY >= top && paragraph.frame.maxY <= bottom { return }
            let upwards = paragraph.frame.maxY > bottom
            let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.65 : 0.35))
            let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.35 : 0.65))
            from.press(forDuration: 0.05, thenDragTo: to)
            capture("\(step)-scroll-\(attempt)")
        }
        recordSavedParagraphAccessibility(step: step, container: container)
        XCTFail("The full paragraph must be readable above the navigation controls")
    }

    private func savedParagraphIdentifiers(expectedCount: Int) throws -> [String]? {
        guard let encoded = ProcessInfo.processInfo.environment["PICHI_PRIVATE_SAVED_EXPECTED_PARAGRAPH_IDS"] else { return nil }
        let ids = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String],
                               "Expected paragraph IDs must be a JSON string array")
        let matched = try XCTUnwrap(ids.count == expectedCount ? ids : nil,
                                   "Each expected saved paragraph must have its matching stable ID")
        return try matched.map { try XCTUnwrap(UUID(uuidString: $0), "Expected paragraph IDs must be UUIDs").uuidString }
    }

    private func normalizedParagraphText(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func recordSavedParagraphAccessibility(step: String, container: XCUIElement?, expected: String? = nil) {
        let elements = container.map { $0.descendants(matching: .staticText).allElementsBoundByIndex }
            ?? app.staticTexts.allElementsBoundByIndex
        let labels = elements.map { "\($0.identifier): \($0.label)" }.joined(separator: "\n")
        let details = "expected: \(expected ?? "not supplied")\ncontainer: \(container?.identifier ?? "global fallback")\n\(labels)"
        let attachment = XCTAttachment(string: details)
        attachment.name = "\(step)-actual-paragraph-accessibility"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Prefixes only locate the body within its stable paragraph container. Passing still
    /// requires the complete label, preserving every non-whitespace character and word.
    private func assertSavedParagraphs(_ expected: [String], identifiers: [String]?, step: String) throws {
        let checked = try XCTUnwrap(expected.count >= 3 ? Array(expected.prefix(3)) : nil,
                                   "The saved-session review checks three complete original paragraphs")
        for (index, text) in checked.enumerated() {
            let container = identifiers.map {
                app.descendants(matching: .any).matching(identifier: "transcript.paragraph.\($0[index])").firstMatch
            }
            let texts = container.map { $0.descendants(matching: .staticText) } ?? app.staticTexts
            let prefix = String(text.prefix(16))
            let body = texts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
            if index == 0 {
                if let container { _ = container.waitForExistence(timeout: 15) }
                else { _ = body.waitForExistence(timeout: 15) }
            }
            try revealParagraphAboveNavigation(body, step: "\(step)-\(index)", container: container)
            if !body.exists || normalizedParagraphText(body.label) != normalizedParagraphText(text) {
                recordSavedParagraphAccessibility(step: "\(step)-\(index)", container: container, expected: text)
                capture("\(step)-\(index)-text-mismatch")
            }
            XCTAssertTrue(body.exists, "The expected body must exist inside the original saved paragraph")
            XCTAssertEqual(normalizedParagraphText(body.label), normalizedParagraphText(text),
                           "The complete saved paragraph must match the protected replay; a matching prefix is insufficient")
            capture("\(step)-\(index)-visible")
        }
    }


    func testGeneralizedSpeakerAttributionLabelsInBothLanguagesAndThemes() throws {
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9016"
        for (language, appearance, historyTitle, mainLabel, participantLabel) in [
            ("en", "light", "History", "Анна", "Борис"),
            ("ru", "dark", "История", "Анна", "Борис")
        ] {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            waitForOrientation(portrait: true)
            capture("attribution-\(language)-ready")
            openNavigation("history", title: historyTitle)
            capture("attribution-\(language)-history")
            let meeting = app.buttons["history.session.\(fixtureID)"]
            guard meeting.waitForExistence(timeout: 5) else {
                throw XCTSkip("Stage the synthetic GeneralizedAttributionMeeting.json in the simulator meeting store")
            }
            meeting.tap()
            XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
            capture("attribution-\(language)-opened")
            let label = app.staticTexts[mainLabel].firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5), "The continuing participant uses its plain name")
            let mixedText = app.staticTexts["Обсудим план встречи. Да, уточню. Продолжим обсуждение."].firstMatch
            XCTAssertTrue(mixedText.waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["Да, уточню."].exists, "The short interruption must not remain a separate paragraph")
            XCTAssertFalse(app.staticTexts["Several speakers"].exists)
            XCTAssertFalse(app.staticTexts["Несколько говорящих"].exists)
            try revealParagraphAboveNavigation(mixedText, step: "attribution-\(language)-portrait")
            capture("attribution-\(language)-portrait-foreground")
            let inferred = app.staticTexts[participantLabel].firstMatch
            XCTAssertTrue(inferred.exists, "A selected participant uses its plain name while retaining inference metadata")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            try revealParagraphAboveNavigation(mixedText, step: "attribution-\(language)-landscape")
            XCTAssertTrue(label.exists && mixedText.exists)
            capture("attribution-\(language)-landscape-foreground")
        }
    }

    func testProtectedTranscriptExportOpensNativeShareSheetInBothLanguages() throws {
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9016"
        for (language, appearance, historyTitle) in [("en", "light", "History"), ("ru", "dark", "История")] {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            waitForOrientation(portrait: true)
            capture("protected-export-\(language)-ready")
            openNavigation("history", title: historyTitle)
            capture("protected-export-\(language)-history")
            let meeting = app.buttons["history.session.\(fixtureID)"]
            XCTAssertTrue(meeting.waitForExistence(timeout: 5), "Stage the approved protected synthetic fixture")
            meeting.tap()
            let more = app.buttons["transcript.more"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            capture("protected-export-\(language)-transcript")
            more.tap()
            let export = app.buttons["transcript.exportProtected"]
            XCTAssertTrue(export.waitForExistence(timeout: 5))
            XCTAssertTrue(export.isEnabled)
            capture("protected-export-\(language)-menu")
            export.tap()
            let activityList = app.otherElements["ActivityListView"]
            let presented = activityList.waitForExistence(timeout: 10)
            capture("protected-export-\(language)-native-share")
            let description = XCTAttachment(string: app.debugDescription)
            description.name = "protected-export-\(language)-native-share-accessibility"
            description.lifetime = .keepAlways
            add(description)
            XCTAssertTrue(presented || app.buttons["Save to Files"].exists || app.buttons["Сохранить в Файлы"].exists,
                          "The protected JSON must reach the native share sheet")
            XCTAssertTrue(app.otherElements["LP.CaptionBar.TopCaption"].label.contains("Синтетическая проверка атрибуции"),
                          "The exported filename must preserve the original Cyrillic meeting title")
            let closeShare = app.buttons["header.closeButton"]
            XCTAssertTrue(closeShare.waitForExistence(timeout: 5))
            closeShare.tap()
            XCTAssertTrue(more.waitForExistence(timeout: 5), "Cancel must return to the original transcript")
            capture("protected-export-\(language)-cancelled")
            more.tap()
            XCTAssertTrue(export.waitForExistence(timeout: 5))
            export.tap()
            XCTAssertTrue(activityList.waitForExistence(timeout: 10), "A cancelled share must be immediately reusable")
            if language == "en" {
                let saveFiles = app.cells.matching(NSPredicate(format: "label == %@", "Save to Files")).firstMatch
                XCTAssertTrue(saveFiles.waitForExistence(timeout: 5))
                saveFiles.tap()
                capture("protected-export-files-picker")
                let pickerDescription = XCTAttachment(string: app.debugDescription)
                pickerDescription.name = "protected-export-files-picker-accessibility"
                pickerDescription.lifetime = .keepAlways
                add(pickerDescription)
                let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "Отмена", "Отменить"])).firstMatch
                XCTAssertTrue(app.buttons["DOCPicker.actionButton"].waitForExistence(timeout: 10),
                              "The system file destination picker must open")
                // Compact Files presents the current folder first; its Cancel
                // action is on the enclosing locations page, unlike iPad.
                if !cancel.exists {
                    let locations = app.buttons["BackButton"]
                    XCTAssertTrue(locations.waitForExistence(timeout: 5))
                    locations.tap()
                    capture("protected-export-files-locations")
                }
                XCTAssertTrue(cancel.waitForExistence(timeout: 10), "The system file destination picker must open")
                cancel.tap()
                capture("protected-export-files-picker-cancelled")
                if activityList.exists { closeShare.tap() }
                XCTAssertTrue(more.waitForExistence(timeout: 5))
                more.tap()
                XCTAssertTrue(export.waitForExistence(timeout: 5))
                export.tap()
                XCTAssertTrue(activityList.waitForExistence(timeout: 10))
                saveFiles.tap()
                let save = app.buttons["DOCPicker.actionButton"]
                XCTAssertTrue(save.waitForExistence(timeout: 10))
                let filename = app.textFields["DOCPicker.filenameTextField"]
                XCTAssertTrue(filename.waitForExistence(timeout: 5))
                let suffix = "-" + UUID().uuidString.prefix(8)
                filename.tap()
                filename.typeText(String(suffix))
                XCTAssertTrue((filename.value as? String)?.contains(suffix) == true,
                              "Each synthetic export uses a fresh destination, never an existing user file")
                XCTAssertTrue(save.isEnabled)
                capture("protected-export-files-save-ready")
                save.tap()
                XCTAssertTrue(activityList.waitForNonExistence(timeout: 10), "Saving must dismiss native sharing")
                XCTAssertTrue(more.isHittable, "A completed share must return control to the transcript")
                capture("protected-export-files-saved")
            }
        }
        app.terminate()
    }

    func testLegacyOrphanWordReadsInsideOneParticipantParagraphInBothLanguagesAndThemes() throws {
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9021"
        let firstID = "00000000-0000-0000-0000-202610170001"
        func assertIncomingTurns(step: String) throws {
            // Independent assigned replies are turn boundaries. Only unresolved
            // neighboring words follow their incoming speaker in the current policy.
            for (suffix, text, speaker) in [
                ("004", "Нет, это ответ.", "Борис"),
                ("006", "Короткая вставка", "Анна"),
                ("008", "и продолжение.", "Борис")
            ] {
                let row = app.descendants(matching: .any)[
                    "transcript.paragraph.00000000-0000-0000-0000-202610170\(suffix)"
                ].firstMatch
                XCTAssertTrue(row.waitForExistence(timeout: 5))
                let body = row.staticTexts[text].firstMatch
                XCTAssertTrue(body.waitForExistence(timeout: 5))
                try revealParagraphAboveNavigation(body, step: "\(step)-\(suffix)", container: row)
                XCTAssertTrue(row.staticTexts[speaker].exists,
                              "Each complete paragraph must retain its own participant caption")
            }
            XCTAssertFalse(app.staticTexts["Нет, это ответ. Короткая вставка и продолжение."].exists,
                           "A genuine short reply must not be swallowed by another participant")
        }
        for (language, appearance, historyTitle, participantLabel, cancelTitle) in [
            ("en", "light", "History", "Анна", "Cancel"),
            ("ru", "dark", "История", "Анна", "Отмена")
        ] {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            waitForOrientation(portrait: true)
            capture("legacy-attribution-\(language)-ready")
            openNavigation("history", title: historyTitle)
            capture("legacy-attribution-\(language)-history")
            let meeting = app.buttons["history.session.\(fixtureID)"]
            guard meeting.waitForExistence(timeout: 5) else {
                throw XCTSkip("Stage the synthetic LegacyAttributionMeeting.json in the simulator meeting store")
            }
            meeting.tap()
            XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
            capture("legacy-attribution-\(language)-opened")
            let label = app.staticTexts[participantLabel].firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5))
            let paragraph = app.staticTexts["Обсудим и продолжим."].firstMatch
            XCTAssertTrue(paragraph.waitForExistence(timeout: 5))
            try revealParagraphAboveNavigation(paragraph, step: "legacy-attribution-\(language)-portrait")
            XCTAssertFalse(app.staticTexts[language == "ru" ? "Неизвестный участник" : "Unknown speaker"].exists)
            capture("legacy-attribution-\(language)-portrait-merged")
            app.buttons["transcript.edit.\(firstID)"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["transcript.edit.fragments"].firstMatch.waitForExistence(timeout: 5))
            for fragment in 1...3 {
                XCTAssertTrue(app.descendants(matching: .any)["transcript.edit.fragment.00000000-0000-0000-0000-20261017000\(fragment)"].firstMatch.exists,
                              "Reading grouping must preserve every independently correctable original member")
            }
            capture("legacy-attribution-\(language)-original-members")
            app.buttons[cancelTitle].firstMatch.tap()
            capture("legacy-attribution-\(language)-editor-cancelled")
            try assertIncomingTurns(step: "legacy-attribution-\(language)-incoming-portrait")
            XCTAssertFalse(app.staticTexts[language == "ru" ? "Неизвестный участник" : "Unknown speaker"].exists)
            XCTAssertFalse(app.staticTexts["Несколько говорящих"].exists)
            XCTAssertFalse(app.staticTexts["Several speakers"].exists)
            capture("legacy-attribution-\(language)-incoming-prefix")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            // Landscape can virtualize the whole paragraph below the meeting header.
            try revealParagraphAboveNavigation(paragraph, step: "legacy-attribution-\(language)-landscape")
            XCTAssertTrue(label.exists && paragraph.exists)
            capture("legacy-attribution-\(language)-landscape-merged")
            try assertIncomingTurns(step: "legacy-attribution-\(language)-incoming-landscape")
            capture("legacy-attribution-\(language)-landscape-incoming-prefix")
        }
    }

    func testExplicitSpeakerAliasPersistsWithTranscriptPrivacyEnabled() throws {
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9024"
        let speakerID = "00000000-0000-0000-0000-000000000065"
        for (language, appearance, historyTitle, saveTitle) in [
            ("en", "light", "History", "Save"),
            ("ru", "dark", "История", "Сохранить")
        ] {
            func openFixture() throws {
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                                       "-MeetingPIIRedactionEnabled", "YES"]
                app.launch()
                capture("explicit-alias-\(language)-ready")
                openNavigation("history", title: historyTitle)
                capture("explicit-alias-\(language)-history")
                let meeting = app.buttons["history.session.\(fixtureID)"]
                guard meeting.waitForExistence(timeout: 5) else {
                    throw XCTSkip("Stage the synthetic ExplicitSpeakerAliasMeeting.json in the isolated test store")
                }
                meeting.tap()
                XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
                capture("explicit-alias-\(language)-opened")
            }
            func rename(_ previous: String, to name: String) {
                let participant = app.buttons["transcript.speaker.\(speakerID)"]
                XCTAssertTrue(participant.waitForExistence(timeout: 5))
                participant.tap()
                capture("explicit-alias-\(language)-editor")
                let field = app.textViews["transcript.edit.text"]
                XCTAssertTrue(field.waitForExistence(timeout: 5))
                XCTAssertEqual(field.value as? String, previous)
                field.tap()
                field.press(forDuration: 1.1)
                capture("explicit-alias-\(language)-selection-menu")
                let selectAll = app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@",
                    ["Select All", "Выбрать все", "Выбрать всё"])).firstMatch
                // UIKit can put Select All on a later menu page on a narrow
                // phone, independently of the app's interface language.
                for page in 1...3 {
                    if selectAll.waitForExistence(timeout: 0.5) { break }
                    let nextPage = app.buttons.matching(NSPredicate(format: "label IN %@",
                        ["Next page", "Следующая страница"])).firstMatch
                    guard nextPage.waitForExistence(timeout: 1) else { break }
                    nextPage.tap()
                    capture("explicit-alias-\(language)-selection-page-\(page)")
                }
                XCTAssertTrue(selectAll.waitForExistence(timeout: 3))
                selectAll.tap()
                field.typeText(name)
                capture("explicit-alias-\(language)-entered")
                app.buttons[saveTitle].firstMatch.tap()
                let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", name), object: participant)
                XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 5), .completed)
                XCTAssertTrue(app.staticTexts["[ИМЯ] оставил [ТЕЛЕФОН]."].exists,
                              "A metadata correction must preserve the protected transcript")
                capture("explicit-alias-\(language)-saved")
            }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            try openFixture()
            rename("Анна", to: "Иван Петров")
            app.terminate()
            try openFixture()
            XCTAssertEqual(app.buttons["transcript.speaker.\(speakerID)"].label, "Иван Петров")
            capture("explicit-alias-\(language)-persisted")
            rename("Иван Петров", to: "Анна")
        }
    }

    /// Covers a saved meeting where the automatic owner designation was lost entirely.
    func testManualYouDesignationSwitchClearUndoAndReopen() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Participant correction fixtures are simulator-only")
        #else
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9026"
        let firstID = "00000000-0000-0000-0000-000000000065"
        let secondID = "00000000-0000-0000-0000-000000000066"
        for (language, appearance, history, ownerName) in [
            ("en", "light", "History", "You"),
            ("ru", "dark", "История", "Вы")
        ] {
            func openFixture() throws {
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
                app.launch()
                capture("manual-you-\(language)-ready")
                openNavigation("history", title: history)
                capture("manual-you-\(language)-history")
                let meeting = app.buttons["history.session.\(fixtureID)"]
                guard meeting.waitForExistence(timeout: 5) else {
                    throw XCTSkip("Stage ManualOwnerDesignationMeeting.json in the isolated simulator store")
                }
                meeting.tap()
                XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
                assertParticipantHeadersHaveCompactLabels()
                capture("manual-you-\(language)-opened")
            }
            func assertOnlyOwner(_ id: String?, step: String) {
                if let id {
                    let participant = app.buttons["transcript.speaker.\(id)"]
                    let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", ownerName), object: participant)
                    XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed,
                                   "The chosen participant must receive the owner label after the correction commits")
                }
                let owners = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                    "transcript.speaker.", ownerName))
                let count = id == nil ? 0 : 1
                let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == %d", count), object: owners)
                XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                               "A meeting must have exactly the manually chosen owner, or none after clearing")
                capture("manual-you-\(language)-\(step)")
            }
            func selectRole(_ id: String, removing: Bool = false, step: String) throws {
                let menu = app.buttons["transcript.participant.actions.\(id)"]
                try revealParagraphAboveNavigation(menu, step: "manual-you-\(language)-\(step)-reveal")
                XCTAssertTrue(menu.isEnabled)
                menu.tap()
                capture("manual-you-\(language)-\(step)-menu")
                let action = app.buttons["transcript.participant.\(removing ? "removeYou" : "markYou").\(id)"]
                XCTAssertTrue(action.waitForExistence(timeout: 5) && action.isEnabled)
                action.tap()
                capture("manual-you-\(language)-\(step)-committed")
            }
            func undo(step: String) throws {
                let more = app.buttons["transcript.more"]
                try revealParagraphAboveNavigation(more, step: "manual-you-\(language)-\(step)-reveal")
                more.tap()
                capture("manual-you-\(language)-\(step)-menu")
                let action = app.buttons["transcript.undo"]
                XCTAssertTrue(action.waitForExistence(timeout: 5) && action.isEnabled)
                action.tap()
                capture("manual-you-\(language)-\(step)-committed")
            }

            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            try openFixture()
            assertOnlyOwner(nil, step: "initial-owner-missing")
            try selectRole(secondID, step: "mark-second")
            assertOnlyOwner(secondID, step: "second-is-you")
            app.terminate()
            try openFixture()
            assertOnlyOwner(secondID, step: "second-is-you-reopened")
            try selectRole(firstID, step: "switch-to-first")
            assertOnlyOwner(firstID, step: "first-is-only-you")
            try selectRole(firstID, removing: true, step: "clear-first")
            assertOnlyOwner(nil, step: "designation-cleared")
            try undo(step: "undo-clear")
            assertOnlyOwner(firstID, step: "first-restored")
            try selectRole(secondID, step: "switch-second-for-undo")
            assertOnlyOwner(secondID, step: "second-is-only-you")
            try undo(step: "undo-switch")
            assertOnlyOwner(firstID, step: "first-restored-after-switch")
            try selectRole(firstID, removing: true, step: "restore-ownerless-fixture")
            assertOnlyOwner(nil, step: "fixture-ownerless")
            app.terminate()
            try openFixture()
            assertOnlyOwner(nil, step: "cleared-designation-reopened")
        }
        #endif
    }

    /// Previously saved uncertainty metadata keeps plain captions after reopening.
    func testLegacyParticipantCaptionsStayPlainAfterReopen() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Legacy participant fixtures are simulator-only")
        #else
        let fixtureID = "8EEC0000-2026-4000-8000-000000000021"
        for (language, appearance, history) in [
            ("en", "light", "History"),
            ("ru", "dark", "История")
        ] {
            for iteration in 0..<2 {
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
                app.launch()
                openNavigation("history", title: history)
                let meeting = app.buttons["history.session.\(fixtureID)"]
                XCTAssertTrue(meeting.waitForExistence(timeout: 5), "Stage the synthetic legacy participant fixture")
                meeting.tap()
                XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
                let firstCaption = app.staticTexts["Участник 2"].firstMatch
                XCTAssertTrue(firstCaption.waitForExistence(timeout: 5), "Saved uncertainty metadata keeps a plain participant caption")
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "(provisional)", "(предварительно)")).firstMatch.exists)
                capture("provisional-\(language)-reopen-\(iteration)")
                let last = app.descendants(matching: .any)["transcript.paragraph.8EEC0000-2026-4000-8000-000000000005"].firstMatch
                try revealParagraphAboveNavigation(last, step: "provisional-\(language)-tail-\(iteration)")
                let finalCaption = app.staticTexts["Участник 3"].firstMatch
                XCTAssertTrue(finalCaption.waitForExistence(timeout: 5) && finalCaption.isHittable,
                    "The virtualized saved participant keeps its fully visible plain caption after scrolling")
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format:
                    "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "(provisional)", "(предварительно)")).firstMatch.exists)
                capture("provisional-\(language)-tail-visible-\(iteration)")
                app.terminate()
            }
        }
        #endif
    }

    /// Uses an isolated synthetic saved meeting. It never starts capture or a model.
    func testFragmentParticipantCorrectionScopesUndoAndReopen() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Participant correction fixtures are simulator-only")
        #else
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9025"
        let ownerID = "00000000-0000-0000-0000-000000000065"
        let otherID = "00000000-0000-0000-0000-000000000066"
        let unusedID = "00000000-0000-0000-0000-000000000067"
        let firstID = "00000000-0000-0000-0000-202610210101"
        let memberID = "00000000-0000-0000-0000-202610210102"
        let secondID = "00000000-0000-0000-0000-202610210104"
        let lastID = "00000000-0000-0000-0000-202610210105"
        for (language, appearance, history, ownerName, otherName) in [
            ("en", "light", "History", "You", "Participant 1"),
            ("ru", "dark", "История", "Вы", "Participant 1")
        ] {
            func openFixture() throws {
                app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
                app.launch()
                capture("participant-correction-\(language)-ready")
                openNavigation("history", title: history)
                capture("participant-correction-\(language)-history")
                let meeting = app.buttons["history.session.\(fixtureID)"]
                guard meeting.waitForExistence(timeout: 5) else {
                    throw XCTSkip("Stage ParticipantCorrectionMeeting.json in the isolated simulator store")
                }
                meeting.tap()
                XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 5))
                assertParticipantHeadersHaveCompactLabels()
                capture("participant-correction-\(language)-opened")
            }
            func row(_ id: String) -> XCUIElement {
                app.descendants(matching: .any)["transcript.paragraph.\(id)"].firstMatch
            }
            func assertSpeaker(_ id: String, _ name: String, step: String) throws {
                let paragraph = row(id)
                try revealParagraphAboveNavigation(paragraph, step: "participant-correction-\(language)-\(step)")
                XCTAssertTrue(paragraph.staticTexts[name].firstMatch.waitForExistence(timeout: 5),
                              "Only the selected fragment's participant caption may change")
            }
            func openAssignment(_ id: String, step: String) throws {
                try revealParagraphAboveNavigation(row(id), step: "participant-correction-\(language)-\(step)")
                let control = app.buttons["transcript.reassign.\(id)"]
                XCTAssertTrue(control.waitForExistence(timeout: 5) && control.isEnabled)
                control.tap()
                capture("participant-correction-\(language)-\(step)-scope")
            }
            func assign(_ target: String, step: String) {
                let control = app.buttons["transcript.reassign.target.\(target)"]
                XCTAssertTrue(control.waitForExistence(timeout: 5))
                control.tap()
                capture("participant-correction-\(language)-\(step)-saved")
            }
            func undo(step: String) throws {
                try revealParagraphAboveNavigation(app.buttons["transcript.more"], step: "participant-correction-\(language)-\(step)-reveal-menu")
                app.buttons["transcript.more"].tap()
                capture("participant-correction-\(language)-\(step)-menu")
                let control = app.buttons["transcript.undo"]
                XCTAssertTrue(control.waitForExistence(timeout: 5) && control.isEnabled)
                control.tap()
                capture("participant-correction-\(language)-\(step)-restored")
            }

            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            try openFixture()
            XCTAssertTrue(app.buttons["transcript.speaker.\(ownerID)"].exists,
                          "The automatic owner remains available for global naming")
            try assertSpeaker(firstID, ownerName, step: "initial-owner")
            try openAssignment(firstID, step: "whole-owner-to-other")
            let whole = app.buttons["transcript.reassign.whole"]
            XCTAssertTrue(whole.waitForExistence(timeout: 5))
            whole.tap()
            capture("participant-correction-\(language)-whole-targets")
            XCTAssertTrue(app.buttons["transcript.reassign.target.\(unusedID)"].exists,
                          "An active participant with no current fragments must still be a correction target")
            assign(otherID, step: "whole-owner-to-other")
            try assertSpeaker(firstID, otherName, step: "whole-corrected")
            XCTAssertTrue(row(firstID).staticTexts["Обсудим первую фразу. Вторая реплика."].exists,
                          "Every corrected member stays together; the neighboring turn already assigned to this participant can join it")
            try assertSpeaker(lastID, ownerName, step: "other-owner-turn-unchanged")
            // Undo is one operation for the entire displayed fragment, not one per word.
            try revealParagraphAboveNavigation(row(firstID), step: "participant-correction-\(language)-reveal-undo")
            try undo(step: "whole-undo")
            try assertSpeaker(firstID, ownerName, step: "whole-undo-owner")
            XCTAssertTrue(row(firstID).staticTexts["Обсудим первую фразу."].exists)

            try openAssignment(firstID, step: "member-owner-to-other")
            let member = app.descendants(matching: .any)["transcript.reassign.fragment.\(memberID)"].firstMatch
            XCTAssertTrue(member.waitForExistence(timeout: 5))
            member.tap()
            capture("participant-correction-\(language)-member-targets")
            assign(otherID, step: "member-owner-to-other")
            try assertSpeaker(memberID, otherName, step: "member-corrected")
            try assertSpeaker(firstID, ownerName, step: "member-neighbor-unchanged")
            try undo(step: "member-undo")
            try assertSpeaker(firstID, ownerName, step: "member-undo-owner")
            XCTAssertTrue(row(firstID).staticTexts["Обсудим первую фразу."].exists)

            try openAssignment(secondID, step: "other-to-owner")
            assign(ownerID, step: "other-to-owner")
            try assertSpeaker(firstID, ownerName, step: "other-now-owner")
            let allOwnerText = "Обсудим первую фразу. Вторая реплика. Последняя реплика."
            XCTAssertTrue(row(firstID).staticTexts[allOwnerText].exists,
                          "The changed turn joins its owner's neighboring text without losing words")
            app.terminate()
            try openFixture()
            try assertSpeaker(firstID, ownerName, step: "owner-correction-reopened")
            XCTAssertTrue(row(firstID).staticTexts[allOwnerText].exists,
                          "The corrected owner and all unchanged text must survive reopening")
            // Restore the synthetic fixture through the same user-facing operation.
            try openAssignment(firstID, step: "restore-other")
            let restoreMember = app.descendants(matching: .any)["transcript.reassign.fragment.\(secondID)"].firstMatch
            XCTAssertTrue(restoreMember.waitForExistence(timeout: 5))
            restoreMember.tap()
            capture("participant-correction-\(language)-restore-member-targets")
            assign(otherID, step: "restore-other")
            try assertSpeaker(secondID, otherName, step: "fixture-restored")
            try assertSpeaker(firstID, ownerName, step: "first-scope-restored")
            try assertSpeaker(lastID, ownerName, step: "last-scope-restored")
        }
        #endif
    }

    /// Native captures cover both the initial header and its scroll-under transition.
    /// The parent reviews the navigation surface as well as these hit-test assertions.
    func testTranscriptScrollKeepsNavigationControlsReadable() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic saved-meeting navigation review is simulator-only")
        #else
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9025"
        let lastID = "00000000-0000-0000-0000-202610210105"
        for (language, appearance, history) in [("en", "light", "History"), ("ru", "dark", "История")] {
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            capture("navigation-surface-\(language)-ready")
            openNavigation("history", title: history)
            let meeting = app.buttons["history.session.\(fixtureID)"]
            XCTAssertTrue(meeting.waitForExistence(timeout: 10))
            meeting.tap()
            let scroll = app.scrollViews["meeting.transcript"]
            XCTAssertTrue(scroll.waitForExistence(timeout: 10))
            assertParticipantHeadersHaveCompactLabels()
            capture("navigation-surface-\(language)-header")
            let paragraph = app.descendants(matching: .any)["transcript.paragraph.\(lastID)"].firstMatch
            try revealParagraphAboveNavigation(paragraph, step: "navigation-surface-\(language)-last")
            let back = app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.exists && back.isHittable)
            capture("navigation-surface-\(language)-scrolled")
            scroll.swipeDown()
            XCTAssertTrue(back.isHittable)
            capture("navigation-surface-\(language)-returned")
        }
        #endif
    }

    func testSavedTranscriptCaptionContractInBothAppearances() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Simulator-only saved transcript contract")
        #else
        let environment = ProcessInfo.processInfo.environment
        let sessionID = try XCTUnwrap(environment["PICHI_PRIVATE_SAVED_SESSION_ID"])
        let encoded = try XCTUnwrap(environment["PICHI_PRIVATE_SAVED_EXPECTED_PARAGRAPHS"])
        let expected = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as! [String]
        XCTAssertFalse(expected.isEmpty)
        let identifiers = try savedParagraphIdentifiers(expectedCount: expected.count)
        for (language, appearance, history) in [("en", "light", "History"), ("ru", "dark", "История")] {
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            capture("saved-reading-\(language)-ready")
            openNavigation("history", title: history)
            let meeting = app.buttons["history.session.\(sessionID)"]
            XCTAssertTrue(meeting.waitForExistence(timeout: 15))
            meeting.tap()
            XCTAssertTrue(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 15))
            try assertSavedParagraphs(expected, identifiers: identifiers, step: "saved-reading-\(language)")
            XCTAssertFalse(app.staticTexts["Unknown speaker"].exists)
            XCTAssertFalse(app.staticTexts["Неизвестный участник"].exists)
            XCTAssertFalse(app.staticTexts["Microphone"].exists)
            XCTAssertFalse(app.staticTexts["Микрофон"].exists)
            capture("saved-reading-\(language)-no-unsupported-header")
        }
        #endif
    }

    func testPrivateSavedIncomingParagraphsOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("A separately authorized physical-device saved-session review")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let sessionID = environment["PICHI_PRIVATE_SAVED_SESSION_ID"],
              let encoded = environment["PICHI_PRIVATE_SAVED_EXPECTED_PARAGRAPHS"],
              let data = encoded.data(using: .utf8),
              let expected = try JSONSerialization.jsonObject(with: data) as? [String], !expected.isEmpty else {
            throw XCTSkip("Provide an authorized session ID and expected paragraphs for read-only device review")
        }
        let identifiers = try savedParagraphIdentifiers(expectedCount: expected.count)
        app.terminate()
        app.launchArguments = ["-PichiInterfaceLanguage", "ru"]
        app.launch()
        capture("private-saved-ready")
        // A scheduled iPadOS update can cover the application with a passcode sheet.
        // Dismiss only its reminder action; never interact with credentials or update settings.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for title in ["Напомнить позже", "Remind Me Later"] {
            let reminder = springboard.buttons[title].firstMatch
            if reminder.exists {
                reminder.tap()
                capture("private-saved-update-reminder-dismissed")
                app.activate()
                capture("private-saved-active")
                break
            }
        }
        openNavigation("history", title: "История")
        capture("private-saved-history")
        let meeting = app.buttons["history.session.\(sessionID)"]
        XCTAssertTrue(meeting.waitForExistence(timeout: 10))
        meeting.tap()
        capture("private-saved-transcript")
        let scroll = app.scrollViews.matching(identifier: "meeting.transcript").firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        try assertSavedParagraphs(expected, identifiers: identifiers, step: "private-saved")
        #endif
    }

    func testRetainedProcessingRecoveryActionsInBothLanguagesAndThemes() throws {
        let fixtureID = "2C920909-152B-4050-9ACB-454E82411015"
        for (language, appearance, historyTitle, restartTitle) in [
            ("en", "light", "History", "Start processing again"),
            ("ru", "dark", "История", "Начать обработку заново")
        ] {
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance]
            app.launch()
            waitForOrientation(portrait: true)
            openNavigation("history", title: historyTitle)
            let meeting = app.buttons["history.session.\(fixtureID)"]
            guard meeting.waitForExistence(timeout: 5) else {
                throw XCTSkip("Stage the synthetic RetainedRecoveryMeeting.json and silent audio in the simulator store")
            }
            meeting.tap()
            capture("retained-recovery-\(language)-opened")
            let retry = app.buttons["meeting.retry"]
            let restart = app.buttons["meeting.restartProcessing"]
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            XCTAssertTrue(restart.waitForExistence(timeout: 5))
            XCTAssertEqual(restart.label, restartTitle)
            XCTAssertTrue(retry.isHittable && restart.isHittable,
                          "Continue and restart must both be reachable without covering each other")
            XCTAssertTrue(retry.frame.intersection(restart.frame).isEmpty)
            capture("retained-recovery-\(language)-portrait-actions")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            XCTAssertTrue(retry.isHittable && restart.isHittable)
            capture("retained-recovery-\(language)-landscape-actions")
        }
    }

    func testMeetingLocationTitlesInBothLanguagesAndThemes() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic address presentation is verified only in owned simulators")
        #else
        let fixtureID = "A02B2152-C9AF-4E50-88A5-BE1B97120210"
        for (language, appearance, historyTitle, expected) in [
            ("en", "light", "History", "1 Example Street, Example City"),
            ("ru", "dark", "История", "ул. Примерная, 1, Примерск"),
            ("en", "dark", "History", "1 Example Street, Example City"),
            ("ru", "light", "История", "ул. Примерная, 1, Примерск")
        ] {
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                "-MobileSetupVersion", "1"]
            app.launch()
            capture("location-\(language)-\(appearance)-launched")
            openNavigation("history", title: historyTitle)
            let meeting = app.buttons["history.session.\(fixtureID)"]
            XCTAssertTrue(meeting.waitForExistence(timeout: 10), "Stage LocationMeeting.json in the owned simulator")
            XCTAssertTrue(meeting.label.contains(expected), meeting.label)
            capture("location-\(language)-\(appearance)-history")
            meeting.tap()
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", expected))
                .firstMatch.waitForExistence(timeout: 5))
            capture("location-\(language)-\(appearance)-detail")
        }
        #endif
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

    /// The parent stages this approved synthetic file through native Files storage.
    /// No app data directory exposure, production launch flag or recording reset is used.
    private func openSyntheticPresentation(filename: String) throws -> XCUIElement {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "PresentationUISmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        try require(!filename.isEmpty && !filename.contains("/") && filename.hasSuffix(".pdf"),
                    "An exact staged synthetic PDF filename is required")
        let presentation = app.buttons["meeting.presentation"]
        try require(presentation.waitForExistence(timeout: 5) && presentation.isHittable,
                    "The meeting toolbar must expose PDF Presentation")
        presentation.tap()
        capture("presentation-files-picker")
        let stem = (filename as NSString).deletingPathExtension
        let file = app.staticTexts.matching(NSPredicate(format: "label IN %@", [filename, stem])).firstMatch
        if !file.waitForExistence(timeout: 5) {
            let environment = ProcessInfo.processInfo.environment
            let locationNames = environment["PICHI_PRESENTATION_FIXTURE_LOCATION"].map { [$0] }
                ?? ["On My iPad", "On My iPhone", "На iPad", "На iPhone"]
            let location = app.cells.matching(NSPredicate(format: "label IN %@", locationNames)).firstMatch
            // Files can start in Recents or a compact folder. Choose the known
            // parent location; injected files are not automatically in Recents.
            for step in 0..<3 where !location.isHittable {
                let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Обзор"])).firstMatch
                let back = app.buttons["BackButton"]
                if browse.exists && browse.isHittable { browse.tap() }
                else if back.exists && back.isHittable { back.tap() }
                else { break }
                capture("presentation-files-location-\(step)")
            }
            if location.exists && location.isHittable {
                location.tap()
                capture("presentation-files-known-location")
                if let folderName = environment["PICHI_PRESENTATION_FIXTURE_FOLDER"] {
                    let folder = app.staticTexts[folderName].firstMatch
                    try require(folder.waitForExistence(timeout: 15) && folder.isHittable,
                                "The owned synthetic PDF folder must exist in the selected Files location")
                    folder.tap()
                    capture("presentation-files-owned-folder")
                }
            }
        }
        if !file.waitForExistence(timeout: 5) {
            let search = app.searchFields.firstMatch
            if !search.exists {
                let searchButton = app.buttons.matching(NSPredicate(format: "label IN %@", ["Search", "Поиск"])).firstMatch
                if searchButton.exists && searchButton.isHittable { searchButton.tap() }
            }
            try require(search.waitForExistence(timeout: 5) && search.isHittable,
                        "Stage the approved synthetic PDF in native Files before this test")
            search.tap()
            search.typeText(stem + "\n")
        }
        try require(file.waitForExistence(timeout: 15) && file.isHittable,
                    "The exact staged synthetic PDF must be selectable in Files")
        let fileCell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", stem)).firstMatch
        try require(fileCell.exists && fileCell.isEnabled && fileCell.isHittable,
                    "The approved PDF must be an enabled Files item")
        // In icon mode the filename has its own text interaction. Select the
        // observed item's thumbnail rather than its editable filename label.
        fileCell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        capture("presentation-file-selected")
        let done = app.buttons["meeting.presentation.close"]
        try require(done.waitForExistence(timeout: 15) && app.state == .runningForeground,
                    "Native PDF viewer must show the PDF inside the foreground AUT")
        capture("presentation-native-preview")
        return done
    }

    /// Saves only through the native activity UI into an explicitly staged test folder.
    /// The parent reads back the exact file and validates its actual protected payload.
    private func saveProtectedExportToOwnedFiles(filename: String) throws {
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "ProductionUISmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        let environment = ProcessInfo.processInfo.environment
        let locationName = try XCTUnwrap(environment["PICHI_PRESENTATION_FIXTURE_LOCATION"])
        let folderName = try XCTUnwrap(environment["PICHI_PRESENTATION_FIXTURE_FOLDER"])
        let saveFiles = app.cells.matching(NSPredicate(format: "label IN %@",
            ["Save to Files", "Сохранить в Файлы", "Сохранить в «Файлы»"])).firstMatch
        try require(saveFiles.waitForExistence(timeout: 10) && saveFiles.isHittable,
                    "The native activity list must offer Save to Files")
        saveFiles.tap()
        capture("production-files-picker")
        let description = XCTAttachment(string: app.debugDescription)
        description.name = "production-files-picker-accessibility"
        description.lifetime = .keepAlways
        add(description)
        do {
            let save = app.buttons["DOCPicker.actionButton"]
            try require(save.waitForExistence(timeout: 10), "The native save destination picker must open")
            let location = app.cells.matching(NSPredicate(format: "label == %@", locationName)).firstMatch
            for step in 0..<5 where !location.isHittable {
                let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Обзор"])).firstMatch
                let back = app.buttons["BackButton"]
                if browse.exists && browse.isHittable { browse.tap() }
                else if back.exists && back.isHittable { back.tap() }
                else { break }
                capture("production-files-location-\(step)")
            }
            try require(location.waitForExistence(timeout: 5) && location.isHittable,
                        "Only the explicit staged Files location may receive this export")
            location.tap()
            capture("production-files-known-location")
            let folderCell = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", folderName)).firstMatch
            let folderText = app.staticTexts[folderName].firstMatch
            try require(folderCell.waitForExistence(timeout: 10) || folderText.exists,
                        "The owned export folder must already exist; no new folders are created")
            if folderCell.exists && folderCell.isHittable { folderCell.tap() }
            else {
                try require(folderText.isHittable, "The owned folder must be selectable")
                folderText.tap()
            }
            capture("production-files-owned-folder")
            let ownedFolderTitle = app.navigationBars[folderName]
            try require(ownedFolderTitle.waitForExistence(timeout: 5),
                        "The native picker must confirm the exact owned destination folder")
            let stem = (filename as NSString).deletingPathExtension
            let existing = app.cells.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@",
                filename, stem + ",")).firstMatch
            try require(!existing.exists && !app.staticTexts[filename].exists && !app.staticTexts[stem].exists,
                        "The unique export destination must not already exist; overwrite is forbidden")
            let nameField = app.textFields["DOCPicker.filenameTextField"]
            try require(nameField.waitForExistence(timeout: 5) && nameField.isHittable,
                        "The native save picker must expose its filename field")
            let previous = try XCTUnwrap(nameField.value as? String)
            try require(previous.count <= 256, "The initial native filename must be bounded")
            nameField.tap()
            // Files commonly hides the existing extension in the editable field.
            // Keep its current convention to avoid creating a doubled .json suffix.
            let enteredName = previous.hasSuffix(".json") ? filename : stem
            nameField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + enteredName)
            try require(nameField.value as? String == enteredName,
                        "The exact unique export filename must be present before Save")
            try require(save.isEnabled && save.isHittable, "The native Save action must be enabled")
            capture("production-files-save-ready")
            save.tap()
            try require(save.waitForNonExistence(timeout: 15) && app.alerts.count == 0,
                        "Native Files Save must dismiss without replacement, conflict resolution or any confirmation")
        } catch {
            capture("production-files-save-unavailable")
            // Return the native destination picker through Cancel only. Never
            // accept a replacement prompt or recover by copying private app data.
            let cancel = app.buttons.matching(NSPredicate(format: "label IN %@",
                ["Cancel", "Отмена", "Отменить"])).firstMatch
            for step in 0..<5 where !cancel.isHittable {
                let back = app.buttons["BackButton"]
                guard back.exists && back.isHittable else { break }
                back.tap()
                capture("production-files-cancel-location-\(step)")
            }
            if cancel.exists && cancel.isHittable {
                cancel.tap()
                capture("production-files-picker-cancelled-after-failure")
            }
            throw error
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

    private func assertParticipantHeadersHaveCompactLabels(file: StaticString = #filePath, line: UInt = #line) {
        let names = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker."))
        XCTAssertGreaterThan(names.count, 0, file: file, line: line)
        for name in names.allElementsBoundByIndex {
            let speakerID = String(name.identifier.dropFirst("transcript.speaker.".count))
            let actions = app.buttons["transcript.participant.actions.\(speakerID)"]
            XCTAssertTrue(actions.exists, file: file, line: line)
            XCTAssertLessThanOrEqual(name.frame.height, actions.frame.height + 1,
                "Participant names must remain readable compact labels rather than tall, narrow word fragments",
                file: file, line: line)
        }
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
        reviewNativeScreenshotIfRequested(step, namePrefix: "navigation", revision: revision)
    }
}
