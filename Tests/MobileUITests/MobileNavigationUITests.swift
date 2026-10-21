import XCTest
import UIKit
import CoreText

final class MobileNavigationUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments += ["-PichiInterfaceLanguage", "en"]
        app.launch()
        waitForOrientation(portrait: true)
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
        let viewport = app.scrollViews["meeting.liveTranscript.viewport"]
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
        for (language, settingsTitle, appearance, title) in [
            ("en", "Settings", "light", "Identify speakers during recording"),
            ("ru", "Настройки", "dark", "Определять говорящих во время записи")
        ] {
            app.terminate()
            app.launchArguments = ["-PichiInterfaceLanguage", language, "-ThemePreference", appearance,
                "-SelectedSpeechModel", "gigaam-v3-eou", "-MeetingSpeakerLabelsEnabled", "YES",
                "-MeetingSpeakerProcessingMode", "afterRecording"]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            waitForOrientation(portrait: true)
            capture("streaming-settings-\(language)-ready")
            openNavigation("settings", title: settingsTitle)
            app.buttons["settings.recording"].tap()
            let toggle = app.switches["recording.streamingDiarization"]
            XCTAssertTrue(toggle.waitForExistence(timeout: 5))
            XCTAssertEqual(toggle.value as? String, "0")
            XCTAssertTrue(toggle.label.contains(title))
            capture("streaming-settings-\(language)-\(appearance)-portrait")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            XCTAssertTrue(toggle.exists)
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

    private func revealParagraphAboveNavigation(_ paragraph: XCUIElement, step: String) throws {
        let scroll = app.scrollViews.matching(identifier: "meeting.transcript").firstMatch
        XCTAssertTrue(scroll.exists)
        for attempt in 0..<6 {
            // A phone in landscape may virtualize the paragraph below its header. Scroll
            // it into the accessibility tree before asking for an off-screen element's frame.
            if !paragraph.exists {
                let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                from.press(forDuration: 0.05, thenDragTo: to)
                capture("\(step)-reveal-\(attempt)")
                continue
            }
            let top = app.navigationBars.firstMatch.exists ? app.navigationBars.firstMatch.frame.maxY : app.windows.firstMatch.frame.minY
            let bottom = app.tabBars.firstMatch.exists ? app.tabBars.firstMatch.frame.minY : app.windows.firstMatch.frame.maxY
            if paragraph.isHittable && paragraph.frame.minY >= top && paragraph.frame.maxY <= bottom { return }
            let upwards = paragraph.frame.maxY > bottom
            let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.65 : 0.35))
            let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upwards ? 0.35 : 0.65))
            from.press(forDuration: 0.05, thenDragTo: to)
            capture("\(step)-scroll-\(attempt)")
        }
        XCTFail("The full paragraph must be readable above the navigation controls")
    }


    func testGeneralizedSpeakerAttributionLabelsInBothLanguagesAndThemes() throws {
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9016"
        for (language, appearance, historyTitle, interruptionLabel, participantLabel) in [
            ("en", "light", "History", "Борис (interrupting; background: Анна)", "Борис"),
            ("ru", "dark", "История", "Борис (перебивает; фон: Анна)", "Борис")
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
            let label = app.staticTexts[interruptionLabel].firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5), "The foreground label must retain the background speaker")
            let mixedText = app.staticTexts["Да, уточню."].firstMatch
            XCTAssertTrue(mixedText.waitForExistence(timeout: 5))
            try revealParagraphAboveNavigation(mixedText, step: "attribution-\(language)-portrait")
            capture("attribution-\(language)-portrait-foreground")
            let inferred = app.staticTexts[participantLabel].firstMatch
            XCTAssertTrue(inferred.exists, "A selected participant uses its plain name while retaining inference metadata")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            XCTAssertTrue(label.exists && mixedText.exists)
            try revealParagraphAboveNavigation(mixedText, step: "attribution-\(language)-landscape")
            capture("attribution-\(language)-landscape-foreground")
        }
    }

    func testLegacyOrphanWordReadsInsideOneParticipantParagraphInBothLanguagesAndThemes() throws {
        let fixtureID = "1AD3258B-41DC-426A-A9CA-0FB6531A9021"
        let firstID = "00000000-0000-0000-0000-202610170001"
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
            let incomingParagraph = app.staticTexts["Нет, это ответ."].firstMatch
            XCTAssertTrue(incomingParagraph.waitForExistence(timeout: 5))
            try revealParagraphAboveNavigation(incomingParagraph, step: "legacy-attribution-\(language)-incoming-portrait")
            XCTAssertTrue(app.staticTexts["Борис"].firstMatch.exists)
            XCTAssertFalse(app.staticTexts[language == "ru" ? "Неизвестный участник" : "Unknown speaker"].exists)
            capture("legacy-attribution-\(language)-incoming-prefix")
            XCUIDevice.shared.orientation = .landscapeLeft
            waitForOrientation(portrait: false)
            // Landscape can virtualize the whole paragraph below the meeting header.
            try revealParagraphAboveNavigation(paragraph, step: "legacy-attribution-\(language)-landscape")
            XCTAssertTrue(label.exists && paragraph.exists)
            capture("legacy-attribution-\(language)-landscape-merged")
            try revealParagraphAboveNavigation(incomingParagraph, step: "legacy-attribution-\(language)-incoming-landscape")
            capture("legacy-attribution-\(language)-landscape-incoming-prefix")
        }
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
        for (index, text) in expected.enumerated() {
            let paragraph = app.staticTexts[text].firstMatch
            for attempt in 0..<40 {
                if paragraph.exists && paragraph.isHittable { break }
                let from = scroll.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.8))
                let to = scroll.coordinate(withNormalizedOffset: .init(dx: 0.5, dy: 0.25))
                from.press(forDuration: 0.05, thenDragTo: to)
                capture("private-saved-\(index)-scroll-\(attempt)")
            }
            XCTAssertTrue(paragraph.exists && paragraph.isHittable,
                          "The actual saved unknown prefix must be inside its incoming participant's paragraph")
            capture("private-saved-\(index)-merged")
        }
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

    private func waitForOrientation(portrait: Bool) {
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let frame = self.app.windows.firstMatch.frame
            guard frame.width > 0, frame.height > 0 else { return false }
            return (portrait ? frame.height > frame.width : frame.width > frame.height)
                && (self.app.buttons["meeting.start"].exists ? self.app.buttons["meeting.start"].isHittable : true)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
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
    }
}
