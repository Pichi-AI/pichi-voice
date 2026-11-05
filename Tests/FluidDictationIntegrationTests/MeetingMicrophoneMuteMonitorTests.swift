import Foundation
import XCTest
@testable import FluidVoice_Debug

final class MeetingMicrophoneMuteMonitorTests: XCTestCase {
    func testOverlappingSourceWindowsRequireUniqueExactTitle() {
        let frame = CGRect(x: 0, y: 25, width: 1_400, height: 900)
        let home = MeetingMuteControlLocator.WindowDescriptor(windowID: 10, processID: 42,
            bundleIdentifier: "us.zoom.xos", frame: frame, title: "Zoom Workplace")
        let call = MeetingMuteControlLocator.WindowDescriptor(windowID: 11, processID: 42,
            bundleIdentifier: "us.zoom.xos", frame: frame, title: "Zoom Meeting")
        XCTAssertEqual(MeetingMuteControlLocator.matchingWindow(processID: 42, frame: frame,
            title: "Zoom Meeting", windows: [home, call])?.windowID, 11)
        XCTAssertNil(MeetingMuteControlLocator.matchingWindow(processID: 42, frame: frame,
            title: nil, windows: [home, call]))
        XCTAssertNil(MeetingMuteControlLocator.matchingWindow(processID: 42, frame: frame,
            title: "zoom meeting", windows: [home, call]))
        let duplicate = MeetingMuteControlLocator.WindowDescriptor(windowID: 12, processID: 42,
            bundleIdentifier: "us.zoom.xos", frame: frame, title: "Zoom Meeting")
        XCTAssertNil(MeetingMuteControlLocator.matchingWindow(processID: 42, frame: frame,
            title: "Zoom Meeting", windows: [home, call, duplicate]))
    }

    func testUniqueGeometryDoesNotRequireTitleButUsesCurrentFrameAndProcess() {
        let oldFrame = CGRect(x: 0, y: 25, width: 1_400, height: 900)
        let movedFrame = CGRect(x: 130, y: 80, width: 800, height: 600)
        let stale = MeetingMuteControlLocator.WindowDescriptor(windowID: 11, processID: 42,
            bundleIdentifier: "us.zoom.xos", frame: oldFrame)
        let current = MeetingMuteControlLocator.WindowDescriptor(windowID: 11, processID: 42,
            bundleIdentifier: "us.zoom.xos", frame: movedFrame)
        XCTAssertNil(MeetingMuteControlLocator.matchingWindow(processID: 42, frame: movedFrame,
            title: "Zoom Meeting", windows: [stale]))
        XCTAssertEqual(MeetingMuteControlLocator.matchingWindow(processID: 42, frame: movedFrame,
            title: nil, windows: [current])?.windowID, 11)
        XCTAssertNil(MeetingMuteControlLocator.matchingWindow(processID: 43, frame: movedFrame,
            title: nil, windows: [current]))
    }

    func testDelayedReleaseUsesEventBoundaryAndInvalidTimesRevokeAll() {
        let delayed = MeetingMuteTransitionState.releaseBoundary(eventTime: 100, processedAt: 200)
        XCTAssertEqual(delayed.fence, 100)
        XCTAssertEqual(delayed.unsafeStart, 100)
        for missingOrInvalid in [nil, UInt64(0), UInt64(201)] {
            let boundary = MeetingMuteTransitionState.releaseBoundary(eventTime: missingOrInvalid, processedAt: 200)
            XCTAssertEqual(boundary.fence, 200)
            XCTAssertEqual(boundary.unsafeStart, 0)
        }
    }

    func testZoomActionAndHelpMustAgree() {
        XCTAssertEqual(MeetingMuteUISemantics.zoom(title: nil, description: "Mute my audio", help: "Noise removal is on. Mute my audio (shortcut)"), .unmuted)
        XCTAssertEqual(MeetingMuteUISemantics.zoom(title: nil, description: "Unmute my audio", help: "Press a shortcut to unmute or hold Space to temporarily unmute."), .muted)
        XCTAssertEqual(MeetingMuteUISemantics.zoom(title: nil, description: "Unmute my audio", help: "Noise removal is on. Mute my audio (shortcut)"), .unknown)
        XCTAssertEqual(MeetingMuteUISemantics.zoom(title: "Mute my audio", description: "Unmute my audio", help: nil), .unknown)
        XCTAssertEqual(MeetingMuteUISemantics.zoom(title: "Audio", description: nil, help: nil), .unknown)
    }

    func testMeetSelectorsDoNotAcceptCameraOrAnotherParticipant() {
        XCTAssertEqual(MeetingMuteUISemantics.meet(title: "Turn on microphone", description: nil), .muted)
        XCTAssertEqual(MeetingMuteUISemantics.meet(title: nil, description: "Turn off microphone (shortcut)"), .unmuted)
        XCTAssertEqual(MeetingMuteUISemantics.meet(title: "Turn off microphone", description: "Turn on microphone"), .unknown)
        XCTAssertEqual(MeetingMuteUISemantics.meet(title: "Turn off camera", description: nil), .unknown)
        XCTAssertEqual(MeetingMuteUISemantics.meet(title: "Turn on microphone for another participant", description: nil), .unknown)
    }

    func testPositiveUnmuteRequiresBothSemanticsAndIcon() {
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unmuted, after: .unmuted, visual: .unmuted), .unmuted)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unknown, after: .unmuted, visual: .unmuted), nil)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unmuted, after: .muted, visual: .unmuted), nil)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .muted, after: .muted, visual: .unmuted), nil)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unmuted, after: .unmuted, visual: .unknown), nil)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unmuted, after: .unmuted, visual: .muted), .muted)
    }

    func testMeetDocumentIdentityIgnoresJoinParametersButNotAnotherRoom() {
        let first = MeetingMuteControlLocator.meetDocumentIdentity("https://meet.google.com/meet/abc-defg-hij?authuser=0#joined")
        XCTAssertEqual(first, MeetingMuteControlLocator.meetDocumentIdentity("https://meet.google.com/abc-defg-hij?authuser=1"))
        XCTAssertNotEqual(first, MeetingMuteControlLocator.meetDocumentIdentity("https://meet.google.com/abc-defg-hik"))
        XCTAssertNil(MeetingMuteControlLocator.meetDocumentIdentity("https://meet.google.com/home"))
        XCTAssertNil(MeetingMuteControlLocator.meetDocumentIdentity("https://meet.google.com.evil.example/abc-defg-hij"))
    }

    func testSyntheticMicrophoneShapesAreIndependentOfForegroundColor() {
        let shape = self.microphone()
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: self.rgb(shape, foreground: [250, 250, 250], background: [25, 25, 25])), .unmuted)
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: self.rgb(shape, foreground: [20, 20, 20], background: [240, 240, 240])), .unmuted)
        var levelFilledMicrophone = shape
        for x in 9...14 { levelFilledMicrophone.insert(18 * 24 + x) }
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: self.rgb(levelFilledMicrophone, foreground: [30, 210, 80], background: [25, 25, 25])), .unmuted)
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: self.rgb(self.microphone(slash: true), foreground: [70, 20, 20], background: [245, 220, 220])), .muted)
    }

    func testBlankAndUnrelatedGlyphsNeverProveUnmute() {
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: []), .unknown)
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: [UInt8](repeating: 0, count: MeetingMuteIconProof.componentCount)), .unknown)
        var camera = Set<Int>()
        for x in 4...17 { camera.insert(6 * 24 + x); camera.insert(16 * 24 + x) }
        for y in 6...16 { camera.insert(y * 24 + 4); camera.insert(y * 24 + 17) }
        for y in 9...13 { camera.insert(y * 24 + 20) }
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: self.rgb(camera)), .unknown)
        var slash = Set<Int>()
        for x in 4...18 { slash.insert((x + 1) * 24 + x); slash.insert((x + 2) * 24 + x) }
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: self.rgb(slash)), .unknown)
        let headOnly = Set(self.microphone().filter { $0 / 24 < 12 })
        XCTAssertEqual(MeetingMuteIconProof.classify(rgb: self.rgb(headOnly)), .unknown)
    }

    func testDefaultAndLastTransitionSurviveMissingEvidence() {
        var state = MeetingMuteTransitionState()
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertFalse(state.observe(nil, at: 100))
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertTrue(state.observe(.muted, at: 110))
        for time in UInt64(120)...160 { XCTAssertFalse(state.observe(nil, at: time)) }
        XCTAssertEqual(state.state, .muted, "A hidden toolbar, timeout or unreadable frame is not unmute")
        XCTAssertTrue(state.observe(.unmuted, at: 170))
        XCTAssertFalse(state.observe(nil, at: 1_000))
        XCTAssertEqual(state.state, .unmuted, "An enabled microphone does not need a permanent icon lease")
    }

    func testRepeatedAndOutOfOrderFramesDoNotPublishTransitions() {
        var state = MeetingMuteTransitionState()
        XCTAssertFalse(state.observe(.unmuted, at: 100))
        XCTAssertTrue(state.observe(.muted, at: 200))
        XCTAssertFalse(state.observe(.muted, at: 210))
        XCTAssertFalse(state.observe(.unmuted, at: 190))
        XCTAssertEqual(state.state, .muted)
        XCTAssertTrue(state.observe(.unmuted, at: 220))
        XCTAssertFalse(state.observe(.muted, at: 215))
        XCTAssertEqual(state.state, .unmuted)
    }

    func testSpaceKeyDownNeverOpensWithoutVisibleProof() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.keyDown(at: 110)
        XCTAssertEqual(state.state, .muted)
        XCTAssertFalse(state.observe(nil, at: 120))
        XCTAssertFalse(state.keyUp(processedAt: 130), "A rejected/unobserved PTT must not synthesize a grant")
        XCTAssertEqual(state.state, .muted)
        XCTAssertFalse(state.observe(.muted, at: 140), "A fresh rendered muted state rearms later transitions")
        XCTAssertTrue(state.observe(.unmuted, at: 150), "A later permanent visible unmute can open")
    }

    func testShortOwnedPTTReleaseRejectsFirstLingeringHUDAndUnmute() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.keyDown(at: 110)
        XCTAssertFalse(state.keyUp(processedAt: 120))
        XCTAssertEqual(state.state, .muted)
        XCTAssertFalse(state.observeTemporaryHUD(true, at: 130, corroboratedUnmute: true))
        XCTAssertFalse(state.observe(.unmuted, at: 130))
        XCTAssertFalse(state.observe(nil, at: 140))
        XCTAssertEqual(state.state, .muted)
        XCTAssertFalse(state.observe(.muted, at: 150))
        XCTAssertTrue(state.observe(.unmuted, at: 160))
    }

    func testVisibleTemporaryUnmuteReturnsToMutedOnRelease() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.keyDown(at: 110)
        XCTAssertTrue(state.observe(.unmuted, at: 120))
        XCTAssertTrue(state.temporaryUnmute)
        XCTAssertTrue(state.keyUp(processedAt: 150))
        XCTAssertEqual(state.state, .muted)
        XCTAssertFalse(state.observe(.unmuted, at: 140), "A queued pre-release frame is stale")
        XCTAssertFalse(state.observe(.unmuted, at: 160), "The same lingering pre-release icon is not a new transition")
        XCTAssertFalse(state.observe(nil, at: 170))
        XCTAssertFalse(state.observe(.muted, at: 180))
        XCTAssertTrue(state.observe(.unmuted, at: 190), "A fresh permanent transition can open after PTT")
    }

    func testOrdinarySpaceInPersistentUnmuteDoesNotClose() {
        var state = MeetingMuteTransitionState()
        XCTAssertFalse(state.observe(.unmuted, at: 100))
        state.keyDown(at: 110)
        XCTAssertFalse(state.possiblePTT)
        XCTAssertFalse(state.keyUp(processedAt: 150))
        XCTAssertEqual(state.state, .unmuted)
        state.keyDown(at: nil)
        XCTAssertFalse(state.keyUp(processedAt: 160))
        XCTAssertEqual(state.state, .unmuted, "A missing keyboard timestamp is not a conference mute transition")
    }

    func testDelayedKeyDownReclassifiesObservedUnmuteFromMuted() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        XCTAssertTrue(state.observe(.unmuted, at: 130))
        state.keyDown(at: 120)
        XCTAssertTrue(state.possiblePTT)
        XCTAssertTrue(state.temporaryUnmute)
        XCTAssertTrue(state.keyUp(processedAt: 150))
        XCTAssertEqual(state.state, .muted)
    }

    func testTemporaryHUDRequiresOwnedSpaceOrRenderedCorroboration() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.keyDown(at: 105)
        XCTAssertTrue(state.observeTemporaryHUD(true, at: 110))
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertTrue(state.temporaryUnmute)
        XCTAssertFalse(state.observe(nil, at: 120))
        XCTAssertFalse(state.observeTemporaryHUD(nil, at: 130))
        XCTAssertFalse(state.observeTemporaryHUD(false, at: 140), "HUD disappearance is not itself mute")
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertTrue(state.keyUp(processedAt: 150))
        XCTAssertEqual(state.state, .muted)
        XCTAssertFalse(state.observeTemporaryHUD(true, at: 160), "The lingering old HUD cannot reopen after release")
        XCTAssertFalse(state.observeTemporaryHUD(false, at: 170))
        state.keyDown(at: 175)
        XCTAssertTrue(state.observeTemporaryHUD(true, at: 180), "A new rendered HUD appearance can grant owned PTT")
    }

    func testOwnedHUDReclassifiesTemporaryModeFromAssumedOrPersistentUnmute() {
        for sawPersistentUnmute in [false, true] {
            var state = MeetingMuteTransitionState()
            if sawPersistentUnmute { XCTAssertFalse(state.observe(.unmuted, at: 100)) }
            state.keyDown(at: 110)
            XCTAssertEqual(state.state, .unmuted)
            XCTAssertFalse(state.observeTemporaryHUD(true, at: 120), "The output was already unmuted")
            XCTAssertTrue(state.temporaryUnmute, "The explicit owned HUD identifies the underlying muted base")
            XCTAssertTrue(state.keyUp(processedAt: 130))
            XCTAssertEqual(state.state, .muted)
        }
    }

    func testUnownedHUDCannotTurnCaptionTextIntoUnmute() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        XCTAssertFalse(state.observeTemporaryHUD(true, at: 110))
        XCTAssertEqual(state.state, .muted)
        XCTAssertFalse(state.observeTemporaryHUD(false, at: 120))
        XCTAssertTrue(state.observeTemporaryHUD(true, at: 130, corroboratedUnmute: true))
        XCTAssertEqual(state.state, .unmuted)
    }

    func testNegativeProcessingFenceMatchesAudioGate() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.negativeWasProcessed(at: 120)
        XCTAssertFalse(state.observe(.unmuted, at: 115))
        XCTAssertEqual(state.state, .muted)
        XCTAssertTrue(state.observe(.unmuted, at: 130))
    }

    func testListenerLossKeepsStateUntilExplicitMuteAndRefinesReleaseBoundary() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.keyDown(at: 110)
        XCTAssertTrue(state.observe(.unmuted, at: 120))
        state.keyListenerUnavailable()
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertFalse(state.observe(nil, at: 130))
        XCTAssertTrue(state.observe(.muted, at: 140))
        XCTAssertTrue(state.keyUp(processedAt: 150), "A delayed real release still narrows the PCM exclusion boundary")
        XCTAssertEqual(state.state, .muted)
    }

    func testDelayedKeyUpDoesNotOverrideNewerRenderedMuteUnmuteCycle() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 90))
        state.keyDown(at: 100)
        XCTAssertTrue(state.observe(.unmuted, at: 110))
        XCTAssertTrue(state.observe(.muted, at: 130))
        XCTAssertTrue(state.observe(.unmuted, at: 140))
        XCTAssertFalse(state.keyUp(processedAt: 170, releasedAt: 120))
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertFalse(state.temporaryUnmute)
        XCTAssertEqual(state.historicalReleaseUnmuteAt, 140, "The old PCM boundary refines history before this newer unmute")
        XCTAssertEqual(state.historicalReleaseUntilAt, 130, "Only the first muted period bounds the old temporary epoch")
        XCTAssertFalse(state.observe(.unmuted, at: 180))
        XCTAssertEqual(state.state, .unmuted)
    }

    func testHistoricalReleaseScopePreservesLaterLegitimateClosedEpochs() {
        for delayedHUDGrant in [false, true] {
            var state = MeetingMuteTransitionState()
            XCTAssertTrue(state.observe(.muted, at: 90))
            state.keyDown(at: 100)
            if delayedHUDGrant { XCTAssertTrue(state.observeTemporaryHUD(true, at: 125)) }
            else { XCTAssertTrue(state.observe(.unmuted, at: 110)) }
            XCTAssertEqual(state.observe(.muted, at: 130), !delayedHUDGrant)
            XCTAssertEqual(state.observe(.unmuted, at: 135), !delayedHUDGrant)
            XCTAssertTrue(state.observe(.muted, at: 137))
            XCTAssertTrue(state.observe(.unmuted, at: 140))
            XCTAssertFalse(state.keyUp(processedAt: 170, releasedAt: 120))
            XCTAssertEqual(state.state, .unmuted)
            XCTAssertEqual(state.historicalReleaseUnmuteAt, 140)
            XCTAssertEqual(state.historicalReleaseUntilAt, 130, "The 135..137 epoch is newer than the historical scope")
        }
    }

    func testHistoricalReleaseInsideAnObservedMutedPeriodUsesItsLastObservation() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 90))
        state.keyDown(at: 100)
        XCTAssertFalse(state.observe(.muted, at: 130))
        XCTAssertTrue(state.observe(.unmuted, at: 140))
        XCTAssertFalse(state.keyUp(processedAt: 170, releasedAt: 120))
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertEqual(state.historicalReleaseUntilAt, 130)
    }

    func testMutedHistoryIsBoundedAndDoesNotGuessAcrossRetiredPeriods() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 10))
        state.keyDown(at: 11)
        XCTAssertTrue(state.observe(.unmuted, at: 12))
        for index in UInt64(0)..<70 {
            XCTAssertTrue(state.observe(.muted, at: 20 + index * 2))
            XCTAssertTrue(state.observe(.unmuted, at: 21 + index * 2))
        }
        XCTAssertEqual(state.retainedMutedSegmentCount, 64)
        XCTAssertFalse(state.keyUp(processedAt: 200, releasedAt: 15))
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertNil(state.historicalReleaseUnmuteAt)
        XCTAssertNil(state.historicalReleaseUntilAt, "An evicted old boundary cannot truncate unrelated later epochs")
    }

    func testHUDDoesNotRewriteIndependentRenderedStateHistory() {
        for sawRenderedUnmute in [false, true] {
            var state = MeetingMuteTransitionState()
            XCTAssertTrue(state.observe(.muted, at: 100))
            state.keyDown(at: 110)
            XCTAssertTrue(state.observeTemporaryHUD(true, at: 120))
            if sawRenderedUnmute { XCTAssertFalse(state.observe(.unmuted, at: 125)) }
            XCTAssertEqual(state.observe(.muted, at: 130), sawRenderedUnmute,
                "Only an actual new rendered mute transition can cancel the temporary grant")
            XCTAssertFalse(state.observeTemporaryHUD(true, at: 130))
            XCTAssertEqual(state.state, sawRenderedUnmute ? .muted : .unmuted)
        }
    }

    func testZoomRenderedStatusRejectsDisplayNameTextAndAcceptsStatusOnlyMetadata() {
        XCTAssertNil(MeetingZoomMuteStatusObserver.selfTileState("Synthetic Peer, Computer audio muted"))
        XCTAssertNil(MeetingZoomMuteStatusObserver.selfTileState("Synthetic Peer, Computer audio unmuted"))
        XCTAssertEqual(MeetingZoomMuteStatusObserver.selfTileState("Computer audio muted"), .muted)
        XCTAssertEqual(MeetingZoomMuteStatusObserver.selfTileState("Computer audio unmuted"), .unmuted)
        XCTAssertNil(MeetingZoomMuteStatusObserver.selfTileState("Another participant, audio muted"))
        XCTAssertNil(MeetingZoomMuteStatusObserver.selfTileState("Computer camera muted"))
        XCTAssertNil(MeetingZoomMuteStatusObserver.selfTileState("Settings to mute computer audio"))
    }

    func testZoomTemporaryHUDRequiresExactRenderedStatus() {
        XCTAssertTrue(MeetingZoomMuteStatusObserver.isTemporaryHUDText("Temporarily unmuted"))
        XCTAssertTrue(MeetingZoomMuteStatusObserver.isTemporaryHUDText("Temporarily\nunmuted"))
        XCTAssertFalse(MeetingZoomMuteStatusObserver.isTemporaryHUDText("Hold Space to temporarily unmute"))
        XCTAssertFalse(MeetingZoomMuteStatusObserver.isTemporaryHUDText("Camera temporarily unmuted"))
        XCTAssertFalse(MeetingZoomMuteStatusObserver.isTemporaryHUDText(nil))
    }

    func testUnsupportedMonitorStopsWithoutOpeningNativeResources() {
        let capture = ObservationCapture()
        let monitor = MeetingMicrophoneMuteMonitor(application: .init(bundleIdentifier: "invalid.synthetic", processID: 1, displayName: "Synthetic")) {
            capture.append($0)
        }
        monitor.start()
        self.stop(monitor)
        XCTAssertEqual(capture.states, [.unmuted])
        monitor.start()
        self.stop(monitor)
        XCTAssertEqual(capture.states, [.unmuted], "Stop is terminal and idempotent for one attempt")
    }

    func testStoppingBeforeStartPreventsLaterCallbacks() {
        let capture = ObservationCapture()
        let monitor = MeetingMicrophoneMuteMonitor(application: nil) { capture.append($0) }
        self.stop(monitor)
        monitor.start()
        self.stop(monitor)
        XCTAssertTrue(capture.states.isEmpty)
    }

    private func stop(_ monitor: MeetingMicrophoneMuteMonitor) {
        let stopped = self.expectation(description: "joined monitor stop")
        Task { await monitor.stop(); stopped.fulfill() }
        self.wait(for: [stopped], timeout: 2)
    }

    /// Invented raster fixture, drawn independently from the production parametric templates.
    private func microphone(slash: Bool = false) -> Set<Int> {
        var pixels = Set<Int>()
        for y in 4...12 {
            for x in (y == 4 || y == 12 ? 11...12 : 10...13) { pixels.insert(y * 24 + x) }
        }
        for y in 11...13 { for x in [7, 8, 15, 16] { pixels.insert(y * 24 + x) } }
        for x in [8, 9, 10, 13, 14, 15] { pixels.insert(14 * 24 + x) }
        for x in 9...14 { pixels.insert(15 * 24 + x) }
        for x in 10...13 { pixels.insert(16 * 24 + x) }
        for y in 17...18 { for x in 11...12 { pixels.insert(y * 24 + x) } }
        if slash { for x in 4...18 { pixels.insert((x + 1) * 24 + x); pixels.insert((x + 2) * 24 + x) } }
        return pixels
    }

    private func rgb(_ pixels: Set<Int>, foreground: [UInt8] = [250, 250, 250], background: [UInt8] = [25, 25, 25]) -> [UInt8] {
        (0..<(24 * 24)).flatMap { pixels.contains($0) ? foreground : background }
    }

    private final class ObservationCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MeetingMicrophoneMuteObservation] = []
        func append(_ observation: MeetingMicrophoneMuteObservation) { self.lock.lock(); self.values.append(observation); self.lock.unlock() }
        var states: [MeetingMicrophoneMuteState] { self.lock.lock(); defer { self.lock.unlock() }; return self.values.map(\.state) }
    }
}
