import XCTest
import UIKit
@preconcurrency import AVFoundation

/// Opt-in tests of the installed app through its public UI. Audible fixtures belong
/// to the runner; silent input uses only the app's explicit DEBUG capture adapter.
final class MobilePhysicalReleaseUITests: XCTestCase {
    /// Opt-in regression against an already installed ordinary app. The parent
    /// preserves its data, owns the phone/audio lease and selects destination artifacts.
    @MainActor
    func testPhysicalGigaAMRecordingSurvivesSystemTransitions() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the explicitly owned physical iPhone and microphone")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_GIGAAM_BACKGROUND_UI"] == "1" else {
            throw XCTSkip("Physical background recording requires explicit opt-in")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let priorModel = try XCTUnwrap(environment["PICHI_PHYSICAL_PRIOR_MODEL"])
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
        let fixture = support.appendingPathComponent("BackgroundRecordingUI/speech.wav")
        var ownedPlayer: AVAudioPlayer?
        let audio = AVAudioSession.sharedInstance()
        let category = audio.category, mode = audio.mode, options = audio.categoryOptions
        defer {
            ownedPlayer?.stop()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            try? audio.setCategory(category, mode: mode, options: options)
        }
        let app = XCUIApplication(bundleIdentifier: "ai.pichi.voice")
        var ownsRecording = false
        func selectModel(_ model: String) throws {
            try self.openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
            try self.tap(app.buttons["settings.models"], "Open model settings")
            let selected = app.descendants(matching: .any)["model.selected.\(model)"].firstMatch
            if !selected.exists {
                let activate = app.buttons["model.activate.\(model)"]
                try self.reveal(activate, in: app, revision: revision)
                try self.tap(activate, "Activate the already installed model")
            }
            try self.require(selected.waitForExistence(timeout: 45), "The requested installed model must become selected")
        }
        do {
            app.activate()
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists
                && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                "Preserve every existing recording and processing attempt")
            try selectModel("gigaam-v3-eou")
            capture("background-01-gigaam", revision: revision)
            let runner = XCUIApplication(bundleIdentifier: try XCTUnwrap(Bundle.main.bundleIdentifier))
            runner.activate()
            try require(runner.state == .runningForeground, "The runner must prepare playback in foreground")
            try audio.setCategory(.playback, mode: .default, options: .mixWithOthers)
            try audio.setActive(true)
            // prepareToPlay can activate the session; it follows foreground admission
            // and the explicit playback configuration, just like play itself.
            let player = try AVAudioPlayer(contentsOf: fixture)
            ownedPlayer = player
            player.numberOfLoops = -1
            player.volume = 0.15
            try require(player.prepareToPlay(), "Prepare approved synthetic speech in the phone runner")
            try require(player.play(), "Start the owned phone speaker fixture")
            app.activate()
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try reveal(app.buttons["meeting.start"], in: app, revision: revision)
            try tap(app.buttons["meeting.start"], "Start normal microphone recording")
            ownsRecording = true
            try await waitForVisibleRecording(in: app, timeout: 90)
            try await observeVisibleRecording(in: app, player: player, seconds: 6)
            capture("background-02-recording", revision: revision)
            var timer = try visibleTimerSeconds(in: app)

            // Pull down Notification Center from the top edge, then dismiss it.
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.01))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
            try await Task.sleep(nanoseconds: 6_000_000_000)
            capture("background-03-notification-center", revision: revision)
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)))
            app.activate()
            try verifyVisibleRecording(in: app)
            try require(visibleTimerSeconds(in: app) > timer, "Recording must survive Notification Center")
            capture("background-04-after-notifications", revision: revision)
            timer = try visibleTimerSeconds(in: app)

            XCUIDevice.shared.press(.home)
            try require(app.state == .runningBackground, "The actual app must enter background on Home")
            try await Task.sleep(nanoseconds: 8_000_000_000)
            try require(app.state == .runningBackground && player.isPlaying, "Microphone app and fixture must remain alive on Home")
            capture("background-05-home", revision: revision)
            app.activate()
            try verifyVisibleRecording(in: app)
            try require(visibleTimerSeconds(in: app) > timer, "Recording must survive Home")
            timer = try visibleTimerSeconds(in: app)

            let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
            settings.activate()
            try require(settings.state == .runningForeground && app.state == .runningBackground,
                "Settings must really replace the recording UI")
            try await Task.sleep(nanoseconds: 8_000_000_000)
            capture("background-06-other-app", revision: revision)
            app.activate()
            try verifyVisibleRecording(in: app)
            try require(visibleTimerSeconds(in: app) > timer, "Recording must survive another app")
            try require(liveTextCharacterCount(in: app) > 0, "Physical synthetic speech must produce visible captions")
            capture("background-07-returned", revision: revision)
            player.stop()
            try tap(app.buttons["meeting.stop"], "Stop only this test's recording")
            try await waitForCompletedTranscript(in: app, timeout: 180)
            ownsRecording = false
            capture("background-08-completed", revision: revision)
            try selectModel(priorModel)
        } catch {
            ownedPlayer?.stop()
            app.activate()
            if ownsRecording, app.buttons["meeting.stop"].exists {
                app.buttons["meeting.stop"].tap()
                try? await waitForCompletedTranscript(in: app, timeout: 120)
            }
            capture("background-failure", revision: revision)
            if !app.buttons["meeting.stop"].exists { try? selectModel(priorModel) }
            throw error
        }
        #endif
    }

    /// Observes an already running frozen Release after the parent preserves its data.
    /// The parent owns normal launch, reboot, unlock and continuous native capture.
    @MainActor
    func testPhysicalReadOnlyMeetingHistoryAfterColdStart() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Saved physical history observation requires the explicitly selected device")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_HISTORY_READ_ONLY"] == "1" else {
            throw XCTSkip("Explicitly enable read-only observation of existing physical History")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let phase = try XCTUnwrap(environment["PICHI_PHYSICAL_HISTORY_PHASE"])
        let sourceIDs = try XCTUnwrap(environment["PICHI_PHYSICAL_HISTORY_EXPECTED_IDS"])
        try require(["before-reboot", "after-reboot"].contains(phase) && sourceIDs.count <= 1024,
                    "Supply a known reboot phase and one through ten existing visible session UUIDs")
        let values = sourceIDs.split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        let parsed = values.compactMap { UUID(uuidString: $0)?.uuidString }
        let expectedIDs = Set(parsed)
        try require((1...10).contains(values.count) && parsed.count == values.count
                    && expectedIDs.count == values.count,
                    "Expected History IDs must be distinct valid UUIDs from the preserved device data")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        var historyNavigationCompleted = false
        var loadedWithoutRefresh = false
        defer {
            let observedIDs = historyIDs(in: app).sorted()
            let report: [String: Any] = [
                "phase": phase, "revision": revision,
                "expectedSessionIDs": expectedIDs.sorted(),
                "observedSessionIDs": observedIDs, "observedRowCount": observedIDs.count,
                "expectedRowsLoadedWithoutRefresh": loadedWithoutRefresh,
                "historyNavigationCompleted": historyNavigationCompleted, "manualRefreshActions": 0,
                "scope": "Attach-only observation of existing saved History; no app launch, transcript opening, scrolling, search, settings or recording actions"
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "physical-history-\(phase)-\(revision).json"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            let accessibility = XCTAttachment(string: app.debugDescription)
            accessibility.name = "physical-history-\(phase)-\(revision)-accessibility"
            accessibility.lifetime = .keepAlways
            add(accessibility)
            capture("history-\(phase)-final", revision: revision)
        }
        capture("history-\(phase)-initial", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        historyNavigationCompleted = true
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        for id in expectedIDs.sorted() {
            let remaining = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            let rows = app.buttons.matching(identifier: "history.session.\(id)")
            try require(rows.firstMatch.waitForExistence(timeout: remaining) && rows.count == 1,
                        "Existing saved History must load its expected unique rows without manual refresh")
        }
        try require(app.state == .runningForeground && app.alerts.count == 0
                    && !app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "History observation must remain idle without starting or interrupting an attempt")
        loadedWithoutRefresh = true
        #endif
    }

    /// Opt in with PICHI_PHYSICAL_PROTECTED_EXPORT_ICLOUD_ROOT=1, the existing
    /// PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT=1 / SESSION_ID / SESSION_TITLE /
    /// SESSION_STATE=completed contract, plus
    /// PICHI_PHYSICAL_PROTECTED_EXPORT_DESTINATION="iCloud Drive". Supply
    /// PICHI_PHYSICAL_PROTECTED_EXPORT_FILENAME=pichi-protected-<slug>-<32 lowercase hex>.json.
    /// The parent owns fresh preservation, continuous frames and exact Mac readback.
    @MainActor
    func testPhysicalOwnedCompletedProtectedExportToICloudDriveRoot() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized completed physical-device meeting")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_PROTECTED_EXPORT_ICLOUD_ROOT"] == "1" else {
            throw XCTSkip("Enable protected export of one explicitly verified owned completed meeting")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let sessionID = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_ID"])
        let title = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_TITLE"])
        let filename = try XCTUnwrap(environment["PICHI_PHYSICAL_PROTECTED_EXPORT_FILENAME"])
        let root = "iCloud Drive"
        try require(UUID(uuidString: sessionID) != nil && !title.isEmpty && title.count <= 1024
                    && environment["PICHI_PHYSICAL_READ_ONLY_SESSION_STATE"] == "completed"
                    && environment["PICHI_PHYSICAL_PROTECTED_EXPORT_DESTINATION"] == root,
                    "Supply the exact owned completed session and explicitly authorize iCloud Drive root")
        try require(filename.range(of: "\\Apichi-protected-[a-z0-9][a-z0-9-]{0,47}-[0-9a-f]{32}\\.json\\z",
                                   options: .regularExpression) != nil,
                    "Use a bounded ASCII JSON basename with a fresh random 32-hex suffix; no paths or overwrite")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        let starts = app.buttons.matching(identifier: "meeting.start")
        let ready = app.descendants(matching: .any)["history.list"].firstMatch.exists
            && starts.count == 1 && starts.firstMatch.isHittable && starts.firstMatch.isEnabled
        try require(!app.otherElements["ActivityListView"].exists
                    && !app.otherElements["Browse View (Picker)"].exists
                    && (ready || completedReadOnlyTranscriptVisible(in: app, title: title)),
                    "Begin ready or on the exact owned completed transcript, without pre-existing native export UI")
        captureProtectedExportStep("root-export-01-idle-entry", app: app, revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        captureProtectedExportStep("root-export-02-owned-history-list", app: app, revision: revision)
        let rows = app.buttons.matching(identifier: "history.session.\(sessionID)")
        try require(rows.firstMatch.waitForExistence(timeout: 10) && rows.count == 1
                    && rows.firstMatch.staticTexts.matching(NSPredicate(format: "label == %@", title)).count == 1,
                    "Only the unique exact owned history ID with its expected title may be opened")
        try tap(rows.firstMatch, "Open only the exact owned completed history session")
        captureProtectedExportStep("root-export-03-owned-history-transcript", app: app, revision: revision)
        try require(completedReadOnlyTranscriptVisible(in: app, title: title),
                    "The selected owned record must remain completed and exportable")
        try require(app.buttons.matching(identifier: "transcript.more").count == 1,
                    "The owned transcript must expose one actions control")
        try tap(app.buttons["transcript.more"], "Open the owned transcript's ordinary actions")
        captureProtectedExportStep("root-export-04-protected-actions", app: app, revision: revision)
        try require(app.buttons.matching(identifier: "transcript.exportProtected").count == 1,
                    "Only the unique protected transcript export may be selected")
        try tap(app.buttons["transcript.exportProtected"], "Open only protected transcript export")
        let activities = app.otherElements.matching(identifier: "ActivityListView")
        let activity = activities.firstMatch
        let identifiedSaves = app.buttons.matching(identifier: "DOCPicker.actionButton")
        let identifiedNames = app.textFields.matching(identifier: "DOCPicker.filenameTextField")
        let nativePickers = app.otherElements.matching(identifier: "Browse View (Picker)")
        // iPadOS 17 omits both DOCPicker control identifiers. Admit only its
        // observed owned picker, one browsing root, one native navbar Save and
        // one filename TextField in that picker. Never mix partial schemas.
        let browsingRoots = nativePickers.otherElements.matching(NSPredicate(format:
            "identifier BEGINSWITH %@", "DOC.browsingRoot Source: "))
        let nativeBars = browsingRoots.navigationBars.matching(identifier: "FullDocumentManagerViewControllerNavigationBar")
        let nativeSaves = nativeBars.buttons.matching(NSPredicate(format: "label IN %@", ["Save", "Сохранить"]))
        let nativeNames = nativePickers.textFields
        var usesControlIdentifiers: Bool { identifiedSaves.count > 0 || identifiedNames.count > 0 }
        var saves: XCUIElementQuery { usesControlIdentifiers ? identifiedSaves : nativeSaves }
        var names: XCUIElementQuery { usesControlIdentifiers ? identifiedNames : nativeNames }
        func saveControlsAreUnique() -> Bool {
            if usesControlIdentifiers { return identifiedSaves.count == 1 && identifiedNames.count == 1 }
            return nativePickers.count == 1 && browsingRoots.count == 1 && nativeBars.count == 1
                && nativeSaves.count == 1 && nativeNames.count == 1
        }
        var ownsActivity = true
        var ownsPicker = false
        defer {
            // Cancel only native UI opened here. Unknown alerts are never accepted.
            if ownsActivity || ownsPicker {
                captureProtectedExportStep("root-export-failure-observed", app: app, revision: revision)
            }
            if app.state == .runningForeground && app.alerts.count == 0 {
                if ownsPicker && (saves.count == 1 || names.count == 1
                    || app.otherElements["Browse View (Picker)"].exists) {
                    let cancel = app.buttons.matching(NSPredicate(format: "label IN %@",
                        ["Cancel", "Отмена", "Отменить"]))
                    if cancel.count == 1 && cancel.firstMatch.isHittable {
                        cancel.firstMatch.tap()
                        captureProtectedExportStep("root-export-cleanup-picker-cancel", app: app, revision: revision)
                    }
                }
                // iPadOS 17 exposes a label-only Close inside this owned native
                // activity navbar. Never close an unrelated or pre-existing UI.
                let identifiedClose = activities.buttons.matching(identifier: "header.closeButton")
                let contentBars = activities.navigationBars.matching(identifier: "UIActivityContentView")
                let nativeClose = contentBars.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Закрыть"]))
                let close = identifiedClose.count > 0 ? identifiedClose : nativeClose
                let uniqueClose = identifiedClose.count > 0 ? identifiedClose.count == 1
                    : contentBars.count == 1 && nativeClose.count == 1
                if ownsActivity && activities.count == 1 && app.alerts.count == 0 && uniqueClose
                    && close.firstMatch.isEnabled && close.firstMatch.isHittable {
                    close.firstMatch.tap()
                    captureProtectedExportStep("root-export-cleanup-activity-close", app: app, revision: revision)
                }
            }
        }
        try require(activity.waitForExistence(timeout: 15) && activities.count == 1 && app.alerts.count == 0,
                    "Protected export must present the native activity UI without alerts")
        captureProtectedExportStep("root-export-05-native-activity", app: app, revision: revision)
        let saveFiles = app.cells.matching(NSPredicate(format: "label IN %@",
            ["Save to Files", "Сохранить в Файлы", "Сохранить в «Файлы»"]))
        try require(saveFiles.firstMatch.waitForExistence(timeout: 10) && saveFiles.count == 1,
                    "The owned native activity list must offer one unambiguous Save to Files")
        try tap(saveFiles.firstMatch, "Open the native Save to Files destination picker")
        ownsPicker = true
        let pickerAppeared = identifiedSaves.firstMatch.waitForExistence(timeout: 1)
            || nativePickers.firstMatch.waitForExistence(timeout: 10)
        try require(pickerAppeared && saveControlsAreUnique() && app.alerts.count == 0,
                    "The owned native save picker must expose one complete unambiguous native control schema")
        captureProtectedExportStep("root-export-06-native-picker", app: app, revision: revision)

        let rootBars = app.navigationBars.matching(identifier: root)
        // This provider identity and its separate title are observed native AX,
        // not a similarly named folder found by global text matching.
        let cloudRoots = app.otherElements.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND identifier ENDSWITH %@",
            "DOC.browsingRoot Source: com.apple.CloudDocs.iCloudDriveFileProvider/", ", Title: iCloud Drive"))
        func rootIsVerified() -> Bool {
            rootBars.count <= 1 && cloudRoots.count <= 1 && (rootBars.count == 1 || (cloudRoots.count == 1
                && cloudRoots.firstMatch.navigationBars.matching(identifier: "FullDocumentManagerViewControllerNavigationBar")
                    .staticTexts.matching(NSPredicate(format: "label == %@", root)).count == 1))
        }
        let locations = app.cells.matching(NSPredicate(format: "identifier == %@ AND label == %@",
            "DOC.sidebar.item.iCloud Drive", root))
        var explicitlySelectedRoot = false
        for step in 0..<5 {
            try require(app.alerts.count == 0 && saveControlsAreUnique(),
                        "Remain inside the owned native save picker without accepting alerts")
            if locations.count == 1 && locations.firstMatch.isHittable {
                try tap(locations.firstMatch, "Choose only the explicit iCloud Drive provider root")
                captureProtectedExportStep("root-export-07-explicit-cloud-root", app: app, revision: revision)
                explicitlySelectedRoot = true
                break
            }
            let browse = app.buttons.matching(NSPredicate(format: "label IN %@", ["Browse", "Обзор"]))
            let back = app.buttons.matching(identifier: "BackButton")
            if browse.count == 1 && browse.firstMatch.isHittable {
                try tap(browse.firstMatch, "Reveal native Files locations through Browse")
            } else if back.count == 1 && back.firstMatch.isHittable {
                try tap(back.firstMatch, "Return through the owned native picker's exact Back control")
            } else {
                throw verificationFailure("Cannot verify the explicit iCloud Drive root; no Recents, search or guessed destination is used")
            }
            captureProtectedExportStep("root-export-08-location-navigation-\(step)", app: app, revision: revision)
        }
        let rootAppeared = cloudRoots.firstMatch.waitForExistence(timeout: 5)
            || rootBars.firstMatch.waitForExistence(timeout: 1)
        try require(explicitlySelectedRoot && rootAppeared && rootIsVerified()
                    && saveControlsAreUnique() && app.alerts.count == 0,
                    "After explicit provider selection, native navigation must confirm iCloud Drive root")
        captureProtectedExportStep("root-export-09-root-confirmed", app: app, revision: revision)
        let stem = (filename as NSString).deletingPathExtension
        let existing = app.cells.matching(NSPredicate(format:
            "label == %@ OR label == %@ OR label BEGINSWITH %@ OR label BEGINSWITH %@",
            filename, stem, filename + ",", stem + ","))
        try require(existing.count == 0 && !app.staticTexts[filename].exists && !app.staticTexts[stem].exists,
                    "The fresh unique export basename must not already exist; overwrite is forbidden")
        let name = names.firstMatch
        let previous = try XCTUnwrap(name.value as? String)
        try require(!previous.isEmpty && previous.count <= 256,
                    "The native filename field must contain a bounded editable filename")
        try tap(name, "Edit only the owned export filename")
        captureProtectedExportStep("root-export-10-filename-editing", app: app, revision: revision)
        // Retain Files' observed extension convention to avoid a doubled suffix.
        let enteredName = previous.lowercased().hasSuffix(".json") ? filename : stem
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count) + enteredName)
        captureProtectedExportStep("root-export-11-unique-name-entered", app: app, revision: revision)
        try require(name.value as? String == enteredName && rootIsVerified() && app.alerts.count == 0
                    && saveControlsAreUnique() && saves.firstMatch.isEnabled && saves.firstMatch.isHittable
                    && existing.count == 0 && !app.staticTexts[filename].exists && !app.staticTexts[stem].exists,
                    "Save requires the exact unique filename in verified iCloud Drive root with no conflict")
        captureProtectedExportStep("root-export-12-save-ready", app: app, revision: revision)
        try tap(saves.firstMatch, "Save the protected JSON only to the explicitly verified iCloud Drive root")
        captureProtectedExportStep("root-export-13-save-requested", app: app, revision: revision)
        try require(saves.firstMatch.waitForNonExistence(timeout: 15) && !names.firstMatch.exists
                    && activity.waitForNonExistence(timeout: 10) && app.alerts.count == 0
                    && completedReadOnlyTranscriptVisible(in: app, title: title),
                    "Native Save must dismiss to the same owned completed transcript without any replacement or confirmation")
        ownsPicker = false
        ownsActivity = false
        captureProtectedExportStep("root-export-14-native-save-dismissed", app: app, revision: revision)
        print("[PHYSICAL_PROTECTED_EXPORT_ICLOUD_ROOT] filename=\(filename) native_save_dismissed=true readback_required=true")
        #endif
    }

    @MainActor private func captureProtectedExportStep(_ step: String, app: XCUIApplication, revision: String) {
        capture(step, revision: revision)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "\(name)-\(step)-accessibility-\(revision)"
        accessibility.lifetime = .keepAlways
        add(accessibility)
    }

    /// Observation only: the parent verifies the saved session and idle process,
    /// preserves current data and owns continuous native frame capture. This test
    /// never starts, stops, relaunches, retries, edits or deletes a meeting.
    @MainActor
    func testPhysicalOwnedCompletedProtectedShareObservation() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized completed physical-device meeting")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_PROTECTED_SHARE_OBSERVATION"] == "1" else {
            throw XCTSkip("Enable observation of an explicitly verified owned completed meeting")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        let sessionID = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_ID"])
        let title = try XCTUnwrap(environment["PICHI_PHYSICAL_READ_ONLY_SESSION_TITLE"])
        try require(UUID(uuidString: sessionID) != nil && !title.isEmpty && title.count <= 1024
                    && environment["PICHI_PHYSICAL_READ_ONLY_SESSION_STATE"] == "completed",
                    "The parent must supply an exact owned session ID, title and completed state")
        let app = try attachReadOnlyPhysicalApp(revision: revision)
        try require(completedReadOnlyTranscriptVisible(in: app, title: title),
                    "Begin on the exact parent-verified completed transcript, with no active attempt")
        capture("share-observation-01-owned-completed-current", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        let row = app.buttons["history.session.\(sessionID)"]
        try require(row.waitForExistence(timeout: 10) && row.isEnabled && row.isHittable,
                    "Only the exact owned history session may be selected; no search or other row is opened")
        try require(row.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists,
                    "The exact owned history ID must also expose its expected title")
        try tap(row, "Open only the exact owned completed history session")
        capture("share-observation-02-owned-history-transcript", revision: revision)
        try require(completedReadOnlyTranscriptVisible(in: app, title: title),
                    "The selected owned history record must remain completed and exportable")
        let more = app.buttons["transcript.more"]
        try tap(more, "Open the completed transcript's ordinary actions")
        capture("share-observation-03-protected-export-menu", revision: revision)
        try tap(app.buttons["transcript.exportProtected"], "Open only protected transcript export")
        let activityList = app.otherElements["ActivityListView"]
        let close = app.buttons["header.closeButton"]
        var ownsShare = true
        defer {
            // Only dismiss the exact native activity UI opened by this selector.
            // Never accept an alert, pick a destination or tap a suggested contact.
            if ownsShare && app.state == .runningForeground && activityList.exists
                && app.alerts.count == 0 && close.exists && close.isHittable {
                close.tap()
                capture("share-observation-cleanup-native-close", revision: revision)
            }
        }
        try require(activityList.waitForExistence(timeout: 15) && app.alerts.count == 0,
                    "The ordinary protected export must present the observed native activity UI")
        capture("share-observation-04-native-activity", revision: revision)
        let accessibility = XCTAttachment(string: app.debugDescription)
        accessibility.name = "protected-share-observation-accessibility-\(revision)"
        accessibility.lifetime = .keepAlways
        add(accessibility)
        try tap(close, "Close only the observed native activity header")
        try require(activityList.waitForNonExistence(timeout: 10)
                    && completedReadOnlyTranscriptVisible(in: app, title: title),
                    "Cancelling observation must return to the same owned completed transcript")
        ownsShare = false
        capture("share-observation-05-cancelled-no-delivery", revision: revision)
        print("[PHYSICAL_PROTECTED_SHARE_OBSERVATION] native_ui_observed_and_cancelled delivery_attempted=false")
        #endif
    }

    @MainActor private func attachReadOnlyPhysicalApp(revision: String) throws -> XCUIApplication {
        continueAfterFailure = false
        try require(revision.count == 40 && revision.allSatisfy { "0123456789abcdef".contains($0) }
                    && ProcessInfo.processInfo.environment["PICHI_PHYSICAL_READ_ONLY_IDLE_PREFLIGHT"] == "1",
                    "The parent must freshly preserve all current data and verify an idle frozen Release process")
        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        switch app.state {
        case .runningForeground: break
        case .runningBackground: app.activate()
        case .notRunning, .runningBackgroundSuspended, .unknown:
            throw verificationFailure("Read-only observation never launches, relaunches or resumes an unknown/suspended AUT")
        @unknown default:
            throw verificationFailure("The existing AUT state is unsupported for read-only observation")
        }
        try require(app.state == .runningForeground && app.alerts.count == 0
                    && !app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "Read-only observation requires the parent's idle process, never an active attempt")
        return app
    }

    @MainActor private func completedReadOnlyTranscriptVisible(in app: XCUIApplication, title: String) -> Bool {
        app.state == .runningForeground && app.alerts.count == 0
            && app.staticTexts.matching(NSPredicate(format: "label == %@", title)).firstMatch.exists
            && app.buttons["transcript.more"].exists && app.buttons["transcript.more"].isHittable
            && !app.buttons["meeting.stop"].exists && !app.buttons["meeting.retry"].exists
            && !app.buttons["meeting.restartProcessing"].exists
            && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
            && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists
            && !app.staticTexts.matching(NSPredicate(format: "label IN %@",
                ["Transcription was interrupted", "Расшифровка записи прервана",
                 "Transcription failed", "Не удалось расшифровать запись"])).firstMatch.exists
    }

    @MainActor
    func testPhysicalOwnerVoiceSampleIsSavedWhenCheckedAndCanBeDeleted() async throws {
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
        var ownedPlayer: AVAudioPlayer?

        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.activate()
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        try require(!app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "An existing meeting or transcription is not owned by this test")
        try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
        try tap(app.buttons["settings.participants"], "Open the ordinary participant settings")
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
        var savedSyntheticProfile = false
        defer {
            ownedPlayer?.stop()
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
            let player = try AVAudioPlayer(contentsOf: fixture)
            ownedPlayer = player
            try require(player.duration.isFinite && player.duration >= 15, "Owner checking requires a valid single-voice speech fixture")
            player.numberOfLoops = -1
            player.volume = 0.8
            try require(player.prepareToPlay(), "The runner must prepare actual synthetic speech playback")
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
            // A checked sample is saved without a separate step; the synthetic profile is then removed.
            let delete = app.buttons["ownerVoice.delete"]
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while !delete.exists && ProcessInfo.processInfo.systemUptime < deadline {
                try require(!app.staticTexts["ownerVoice.error"].exists, "The actual single-voice microphone sample must pass checking")
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            savedSyntheticProfile = delete.exists
            try require(delete.exists && ["Your voice is saved", "Ваш голос сохранён"].contains(status.label),
                        "A checked sample must be saved without a separate Save action")
            try require(!app.buttons["ownerVoice.save"].exists, "Saving needs no separate action")
            capture("owner-04-checked-sample-saved", revision: revision)
            try reveal(delete, in: app, revision: revision)
            try tap(delete, "Remove the synthetic owner profile")
            let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Удалить"])).firstMatch
            try require(confirm.waitForExistence(timeout: 5), "Deleting the voice profile asks first")
            try tap(confirm, "Confirm removing the synthetic owner profile")
            try require(delete.waitForNonExistence(timeout: 15), "Delete must remove the saved profile")
            savedSyntheticProfile = false
            ownsEnrollment = false
            try require(["Your voice is not set up", "Ваш голос ещё не настроен"].contains(status.label),
                        "The owner profile must be unset after deleting the synthetic profile")
            capture("owner-05-profile-deleted", revision: revision)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists, "Owner checking must release capture without starting a meeting")
            try openNavigation(app, "settings", titles: ["Settings", "Настройки"], revision: revision)
            try tap(app.buttons["settings.participants"], "Reopen participant settings after capture cleanup")
            try reveal(start, in: app, revision: revision)
            try require(start.isEnabled && !app.buttons["ownerVoice.delete"].exists,
                        "Navigation must remain responsive and the deleted profile must not return")
            capture("owner-06-clean-settings-reopened", revision: revision)
        } catch {
            ownedPlayer?.stop()
            // The precondition proved no human profile existed, so a saved one is the synthetic sample.
            if savedSyntheticProfile || (app.buttons["ownerVoice.delete"].exists && ownsEnrollment) {
                app.activate()
                let delete = app.buttons["ownerVoice.delete"]
                if delete.exists && delete.isHittable { delete.tap() }
                let confirm = app.buttons.matching(NSPredicate(format: "label IN %@", ["Delete", "Удалить"])).firstMatch
                if confirm.waitForExistence(timeout: 5) { confirm.tap() }
                if !delete.waitForNonExistence(timeout: 15) {
                    print("[PHYSICAL_OWNER_UI] synthetic_profile_cleanup_requires_parent_inspection revision=\(revision)")
                }
                self.capture("owner-failure-synthetic-profile-cleanup", revision: revision)
                ownsEnrollment = false
            }
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
        var ownedPlayer: AVAudioPlayer?

        let app = XCUIApplication()
        // Preserve the user's actual language, theme, model and privacy choices.
        app.launchArguments = []
        app.launchEnvironment = [:]
        app.activate()
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        try require(!app.buttons["meeting.stop"].exists
                    && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                    "The app must be idle; an existing recording is not owned by this test")
        capture("01-installed-app", revision: revision)
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
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
        try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
        if !app.buttons["meeting.start"].exists {
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
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
            ownedPlayer?.stop()
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
            let player = try AVAudioPlayer(contentsOf: fixture)
            ownedPlayer = player
            try require(player.duration.isFinite && player.duration >= 1, "The staged speech fixture must be valid")
            player.numberOfLoops = -1
            player.volume = 0.8
            try require(player.prepareToPlay(), "The runner must prepare real fixture playback")
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
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            let newIDs = historyIDs(in: app).subtracting(previousSessionIDs)
            try require(newIDs.count == 1, "History must show exactly one new meeting from this attempt")
            let sessionID = try XCTUnwrap(newIDs.first)
            print("[PHYSICAL_RELEASE_UI] completed sessionID=\(sessionID) finalCharacters=\(finalTextCount)")
            capture("19-completed-history-row", revision: revision)
            app.terminate()
            app.launch()
            capture("20-normal-relaunch", revision: revision)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try tap(app.buttons["history.session.\(sessionID)"], "Reopen the persisted meeting after normal relaunch")
            try require(app.descendants(matching: .any)["meeting.transcript"].firstMatch.waitForExistence(timeout: 10),
                        "The persisted transcript must reopen")
            try require(!app.buttons["meeting.stop"].exists, "Relaunch must not restore active capture")
            capture("21-persisted-transcript-reopened", revision: revision)
        } catch {
            ownedPlayer?.stop()
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

    /// Human-observed smoke flow, extended to three minutes for external playback.
    /// Every checkpoint pauses until the parent inspects the native screenshot and ACKs.
    @MainActor
    func testReleaseVisibleOneMinuteRecordingWithParentCheckpoints() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized, visually observed physical-device audio lease")
        #else
        let environment = ProcessInfo.processInfo.environment
        let externalAudio = environment["PICHI_PHYSICAL_EXTERNAL_AUDIO"] == "1"
        guard environment["PICHI_PHYSICAL_VISIBLE_UI"] == "1",
              externalAudio || environment["PICHI_PHYSICAL_RELEASE_UI_AUDIO"] == "1" else {
            throw XCTSkip("Enable visible physical recording and audible playback explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        try require(!revision.isEmpty && revision != "working-tree", "A concrete frozen AUT revision is required")
        let expectedExternalLiveText = environment["PICHI_PHYSICAL_EXPECTED_LIVE_TEXT"]
            .map(normalizedVisibleSpeech).flatMap { $0.isEmpty ? nil : $0 }
        let runnerID = try XCTUnwrap(Bundle.main.bundleIdentifier)
        try require(runnerID.hasSuffix(".xctrunner"), "Only the UI runner may own synthetic playback")
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let player: AVAudioPlayer?
        if externalAudio {
            player = nil
        } else {
            let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
            try require(backgroundModes.contains("audio"), "The frozen, validly signed runner must declare background audio")
            let fixture = support.appendingPathComponent("PhysicalReleaseUI/audio/ru.wav")
            try require(FileManager.default.fileExists(atPath: fixture.path), "Stage the approved synthetic Russian WAV in the runner")
            let ownedPlayer = try AVAudioPlayer(contentsOf: fixture)
            try require(ownedPlayer.duration.isFinite && ownedPlayer.duration >= 1, "The speech fixture must be valid")
            ownedPlayer.numberOfLoops = -1
            ownedPlayer.volume = 0.8
            player = ownedPlayer
        }
        let audioSource = externalAudio ? "external_parent_acoustic" : "runner_speaker"
        let checkpoints = support.appendingPathComponent("VisibleRecordingUI", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        print("[VISIBLE_UI_RUN] directory=\(checkpoints.path) revision=\(revision) test=testReleaseVisibleOneMinuteRecordingWithParentCheckpoints source=\(audioSource)")

        let app = XCUIApplication()
        app.launchArguments = []
        app.launchEnvironment = [:]
        // External playback is owned and observed by the parent on another device.
        // Do not create an audio session or switch foreground apps on that route.
        let audioSession = externalAudio ? nil : AVAudioSession.sharedInstance()
        let originalCategory = audioSession?.category
        let originalMode = audioSession?.mode
        let originalOptions = audioSession?.categoryOptions
        var ownsRecording = false
        var changedPlaybackCategory = false
        var ownsPlaybackSession = false
        defer {
            player?.stop()
            if ownsPlaybackSession { try? audioSession?.setActive(false, options: .notifyOthersOnDeactivation) }
            if changedPlaybackCategory, let audioSession, let originalCategory, let originalMode, let originalOptions {
                try? audioSession.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            }
        }
        do {
            app.activate()
            try await visibleCheckpoint("00-foreground", app: app, revision: revision, directory: checkpoints)
            try require(app.state == .runningForeground, "The ordinary Release AUT must be foreground")
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try await visibleCheckpoint("01-meetings-idle", app: app, revision: revision, directory: checkpoints)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "An existing recording or processing attempt is not owned by this test")
            if !app.buttons["meeting.start"].exists {
                try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
                try await visibleCheckpoint("02-new-meeting", app: app, revision: revision, directory: checkpoints)
            }
            try require(app.buttons["meeting.start"].waitForExistence(timeout: 15)
                        && app.buttons["meeting.start"].isEnabled && app.buttons["meeting.start"].isHittable,
                        "The real Start action must be ready")
            try require(app.alerts.count == 0, "Resolve permission or readiness prompts through normal UI before testing")
            if let audioSession {
                try require(audioSession.outputVolume > 0.05, "The device speaker must already be audible")
            }
            try await visibleCheckpoint("03-ready", app: app, revision: revision, directory: checkpoints)

            try tap(app.buttons["meeting.start"], "Tap the actual Release Start action before any speech playback")
            ownsRecording = true
            try await waitForVisibleRecording(in: app, timeout: 90)
            let beforeSpeechTimer = try visibleTimerSeconds(in: app)
            try await visibleCheckpoint("04-recording-before-speech", app: app, revision: revision, directory: checkpoints)
            try verifyVisibleRecording(in: app)
            try require(player?.isPlaying != true, "No owned speech may play before visually acknowledged recording")

            if externalAudio {
                print("[VISIBLE_UI_EXTERNAL_AUDIO] action=start_approved_synthetic_playback_before_ack checkpoint=05-external-playback-ready")
                try await visibleCheckpoint("05-external-playback-ready", app: app, revision: revision, directory: checkpoints)
                try verifyVisibleRecording(in: app)
                try require(try visibleTimerSeconds(in: app) >= beforeSpeechTimer, "The same recording must continue while external playback starts")
                try await visibleCheckpoint("06-recording-with-speech", app: app, revision: revision, directory: checkpoints)
                var intervalStartTimer = try visibleTimerSeconds(in: app)
                for interval in 1...3 {
                    try await observeVisibleRecording(in: app, player: nil, seconds: 60)
                    let intervalEndTimer = try visibleTimerSeconds(in: app)
                    try require(intervalEndTimer >= intervalStartTimer + 55, "The visible recording timer must advance through each external speech interval")
                    let liveCharacters = liveTextCharacterCount(in: app)
                    try require(liveCharacters > 0, "External audible input must produce actual visible live text during every interval")
                    try verifyLatestCaptionVisible(in: app)
                    print("[VISIBLE_UI_RECORDING] source=\(audioSource) playbackEvidence=parent_checkpoint_ack interval=\(interval) observedSeconds=60 timerStart=\(intervalStartTimer) timerEnd=\(intervalEndTimer) liveCharacters=\(liveCharacters)")
                    try await visibleCheckpoint("07-recording-\(interval * 60)-seconds", app: app, revision: revision, directory: checkpoints)
                    intervalStartTimer = try visibleTimerSeconds(in: app)
                }
                if let expectedExternalLiveText {
                    let visibleSpeech = normalizedVisibleSpeech(liveParagraphs(in: app).map(\.label).joined(separator: " "))
                    try require(visibleSpeech.contains(expectedExternalLiveText),
                                "Visible live captions must contain the explicitly expected external fixture phrase before Stop")
                    print("[VISIBLE_UI_EXTERNAL_AUDIO] expectedLivePhraseMatched=true source=\(audioSource)")
                }
                // The ACK attests that the parent stopped its external player after
                // inspecting this still-active recording. The runner owns no player.
                print("[VISIBLE_UI_EXTERNAL_AUDIO] action=stop_external_playback_before_ack checkpoint=08-ready-to-stop")
                try await visibleCheckpoint("08-ready-to-stop", app: app, revision: revision, directory: checkpoints)
                try verifyVisibleRecording(in: app)
            } else {
                let player = try XCTUnwrap(player)
                let audioSession = try XCTUnwrap(audioSession)
                let runner = XCUIApplication(bundleIdentifier: runnerID)
                runner.activate()
                try await visibleCheckpoint("05-playback-runner-foreground", app: runner, revision: revision, directory: checkpoints)
                try require(runner.state == .runningForeground, "Initiate playback while its owning runner is foreground")
                try audioSession.setCategory(.playback, mode: .default, options: .mixWithOthers)
                changedPlaybackCategory = true
                try audioSession.setActive(true)
                ownsPlaybackSession = true
                try require(player.prepareToPlay(), "The foreground runner must prepare synthetic playback")
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
                print("[VISIBLE_UI_RECORDING] source=\(audioSource) timerBeforeSpeech=\(beforeSpeechTimer) timerAtSpeech=\(speechStartTimer) timerAt30=\(thirtySecondTimer) timerAt60=\(sixtySecondTimer) liveCharacters=\(liveTextCharacterCount(in: app))")
                try require(liveTextCharacterCount(in: app) > 0, "Audible input must produce actual visible live text before Stop")

                player.stop()
                try require(!player.isPlaying, "Stop the owned speech player before stopping capture")
            }
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
            print("[VISIBLE_UI_COMPLETED] paragraphs=\(paragraphs.count) speakers=\(speakers.count) revision=\(revision) source=\(audioSource)")
            try await visibleCheckpoint("10-completed", app: app, revision: revision, directory: checkpoints)
        } catch {
            player?.stop()
            // Ownership begins only after this test taps Start. Never stop an
            // unrelated meeting found in the initial foreground or idle checkpoint.
            if ownsRecording {
                let cleanup = Task { @MainActor in
                    app.activate()
                    try? self.saveVisibleCheckpoint("failure-owned-recording-foreground", app: app,
                                                    revision: revision, directory: checkpoints)
                    // Older iPadOS can propagate the container identifier to an inset
                    // button. Use that observed identifier only to clean up OUR failed
                    // attempt; the success path still requires the correct Stop identity.
                    let identifiedStop = app.buttons["meeting.stop"]
                    let stop = identifiedStop.exists ? identifiedStop : app.buttons["meeting.recording"]
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

    /// Runs the real recording UI while the DEBUG app feeds a staged file into capture.
    /// The parent observes USB diagnostics and explicitly requests Stop after EOF.
    @MainActor
    func testDebugSilentLongRecordingWithParentStopSignal() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly authorized, visibly observed physical iPad")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_PHYSICAL_SILENT_LONG_UI"] == "1" else {
            throw XCTSkip("Enable the silent physical long-recording test explicitly")
        }
        let revision = try XCTUnwrap(environment["PICHI_TEST_REVISION"])
        try require(!revision.isEmpty && revision != "working-tree", "A concrete frozen DEBUG AUT revision is required")
        let inputFile = try XCTUnwrap(environment["PICHI_DEBUG_AUDIO_FILE"])
        let speedText = environment["PICHI_DEBUG_AUDIO_SPEED"] ?? "1"
        let speed = try XCTUnwrap(Double(speedText))
        try require(!inputFile.isEmpty && speed.isFinite && (0.1...32).contains(speed),
                    "An explicit staged input file and supported feed speed are required")
        executionTimeAllowance = 2 * 60 * 60
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let checkpoints = support.appendingPathComponent("VisibleRecordingUI", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        print("[VISIBLE_UI_RUN] directory=\(checkpoints.path) revision=\(revision) test=testDebugSilentLongRecordingWithParentStopSignal source=debug_file_input speed=\(speed)")

        let app = XCUIApplication()
        var ownsRecording = false
        do {
            // Activation preserves an existing process. Never relaunch an unrelated
            // recording merely to install the DEBUG input environment.
            app.activate()
            try saveVisibleCheckpoint("00-existing-foreground", app: app, revision: revision, directory: checkpoints)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "An existing recording or processing attempt is not owned by this test")
            try await visibleCheckpoint("01-meetings-idle", app: app, revision: revision, directory: checkpoints)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.recording"].firstMatch.exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "The app must still be idle after parent inspection before relaunch")
            app.launchArguments = []
            app.launchEnvironment = ["PICHI_DEBUG_AUDIO_INPUT": "1", "PICHI_DEBUG_AUDIO_FILE": inputFile,
                                     "PICHI_DEBUG_AUDIO_SPEED": speedText, "PICHI_TEST_REVISION": revision]
            app.launch()
            try saveVisibleCheckpoint("02-silent-aut-launched", app: app, revision: revision, directory: checkpoints)
            try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
            try require(!app.buttons["meeting.stop"].exists
                        && !app.descendants(matching: .any)["meeting.processing"].firstMatch.exists,
                        "The relaunched DEBUG AUT must remain idle before this test starts recording")
            if !app.buttons["meeting.start"].exists {
                try openNavigation(app, "meetings", titles: ["Recordings", "Записи"], revision: revision)
                try saveVisibleCheckpoint("02-new-meeting", app: app, revision: revision, directory: checkpoints)
            }
            try require(app.alerts.count == 0, "Resolve ordinary readiness prompts before silent capture")
            try await visibleCheckpoint("03-ready", app: app, revision: revision, directory: checkpoints)
            try tap(app.buttons["meeting.start"], "Start the actual app recording with silent DEBUG file input")
            ownsRecording = true
            try await waitForVisibleRecording(in: app, timeout: 90)
            try await visibleCheckpoint("04-recording", app: app, revision: revision, directory: checkpoints)

            let stopSignal = checkpoints.appendingPathComponent("silent-stop.ack")
            let began = ProcessInfo.processInfo.systemUptime
            let deadline = began + 2 * 60 * 60
            var previousTimer = try visibleTimerSeconds(in: app)
            var tick = 0
            while !FileManager.default.fileExists(atPath: stopSignal.path) {
                try require(ProcessInfo.processInfo.systemUptime < deadline, "Parent must signal Stop within two hours")
                let nextTick = min(ProcessInfo.processInfo.systemUptime + 30, deadline)
                while ProcessInfo.processInfo.systemUptime < nextTick
                    && !FileManager.default.fileExists(atPath: stopSignal.path) {
                    try Task.checkCancellation()
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
                try verifyVisibleRecording(in: app)
                if FileManager.default.fileExists(atPath: stopSignal.path) { break }
                let timer = try visibleTimerSeconds(in: app)
                try require(timer > previousTimer, "The real recording timer must advance between silent input observations")
                let liveCharacters = liveTextCharacterCount(in: app)
                if ProcessInfo.processInfo.systemUptime - began >= 120 {
                    try require(liveCharacters > 0, "Silent input must expose live captions within the first two observed minutes")
                }
                previousTimer = timer
                tick += 1
                let step = String(format: "05-recording-tick-%04d", tick)
                try saveVisibleCheckpoint(step, app: app, revision: revision, directory: checkpoints)
                print("[SILENT_LONG_UI_TICK] step=\(step) wallSeconds=\(Int(ProcessInfo.processInfo.systemUptime - began)) timerSeconds=\(timer) liveCharacters=\(liveCharacters)")
            }
            try verifyVisibleRecording(in: app)
            try require(liveTextCharacterCount(in: app) > 0, "Direct file input must produce actual visible live text before Stop")
            try saveVisibleCheckpoint("06-parent-stop-signal", app: app, revision: revision, directory: checkpoints)
            try tap(app.buttons["meeting.stop"], "Stop the real recording after the parent observes input EOF")
            try await waitForVisibleProcessingOrCompletion(in: app, timeout: 30)
            try saveVisibleCheckpoint("09-processing", app: app, revision: revision, directory: checkpoints)
            print("[VISIBLE_UI_CHECKPOINT] step=09-processing directory=\(checkpoints.path) revision=\(revision)")
            try await waitForCompletedTranscript(in: app, timeout: 60 * 60)
            ownsRecording = false
            let paragraphs = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.paragraph."))
            try require(paragraphs.count > 0, "Joined completion must expose actual transcript paragraphs")
            let speakers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "transcript.speaker."))
            print("[SILENT_LONG_UI_COMPLETED] paragraphs=\(paragraphs.count) speakers=\(speakers.count) revision=\(revision)")
            try await visibleCheckpoint("10-completed", app: app, revision: revision, directory: checkpoints)
        } catch {
            if ownsRecording {
                let cleanup = Task { @MainActor in
                    app.activate()
                    let identifiedStop = app.buttons["meeting.stop"]
                    let stop = identifiedStop.exists ? identifiedStop : app.buttons["meeting.recording"]
                    if stop.waitForExistence(timeout: 30), stop.isEnabled { stop.tap() }
                    do { try await self.waitForCompletedTranscript(in: app, timeout: 60 * 60) }
                    catch { print("[SILENT_LONG_UI_CLEANUP] joined_completion_requires_parent_inspection") }
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
            if app.buttons["meeting.recording"].exists {
                throw verificationFailure("The recording container identifier replaced the Stop button identifier")
            }
            if app.alerts.count > 0 || app.buttons["meeting.retry"].exists {
                throw verificationFailure("The real Start action exposed an alert or failed attempt")
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw verificationFailure("The real Start action did not reach active recording")
    }

    @MainActor private func observeVisibleRecording(in app: XCUIApplication, player: AVAudioPlayer?,
                                                   seconds: TimeInterval) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            try verifyVisibleRecording(in: app)
            if let player {
                try require(player.isPlaying, "Owned synthetic playback must remain active during recording")
            }
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

    private func normalizedVisibleSpeech(_ value: String) -> String {
        value.lowercased().components(separatedBy: .alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
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
