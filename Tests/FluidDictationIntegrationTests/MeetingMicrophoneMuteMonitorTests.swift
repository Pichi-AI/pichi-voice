import Foundation
import XCTest
import PichiCallObservation
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
        XCTAssertEqual(state.historicalReleaseUntilAt, 140, "The first following unmute ends the private release gap")
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
            XCTAssertEqual(state.historicalReleaseUntilAt, 135, "The 135..137 epoch is newer than the historical scope")
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
        XCTAssertEqual(state.historicalReleaseUntilAt, 140)
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

    func testHistoricalReleaseKeepsFirstResumeWhenHUDAndRenderedUnmuteShareEpoch() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.keyDown(at: 110)
        XCTAssertTrue(state.observeTemporaryHUD(true, at: 115))
        XCTAssertFalse(state.observe(.muted, at: 119))
        XCTAssertFalse(state.observe(.unmuted, at: 125))
        XCTAssertTrue(state.observe(.muted, at: 130))
        XCTAssertTrue(state.observe(.unmuted, at: 135))
        XCTAssertFalse(state.keyUp(processedAt: 170, releasedAt: 120))
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertEqual(state.historicalReleaseUnmuteAt, 135)
        XCTAssertEqual(state.historicalReleaseUntilAt, 125)
    }

    func testRetiredHistoryIncludesTheFirstResumeBoundary() {
        var state = MeetingMuteTransitionState()
        XCTAssertTrue(state.observe(.muted, at: 100))
        state.keyDown(at: 105)
        XCTAssertFalse(state.observe(.muted, at: 110))
        XCTAssertTrue(state.observe(.unmuted, at: 115))
        for index in UInt64(0)..<64 {
            XCTAssertTrue(state.observe(.muted, at: 120 + index * 10))
            XCTAssertTrue(state.observe(.unmuted, at: 125 + index * 10))
        }
        XCTAssertFalse(state.keyUp(processedAt: 800, releasedAt: 112))
        XCTAssertEqual(state.state, .unmuted)
        XCTAssertNil(state.historicalReleaseUntilAt)
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

private actor CallObservationBarrier {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func park() async {
        self.entered = true
        let waiters = self.entryWaiters; self.entryWaiters.removeAll()
        waiters.forEach { $0.resume() }
        if !self.released { await withCheckedContinuation { self.releaseWaiters.append($0) } }
    }
    func waitUntilEntered() async {
        if !self.entered { await withCheckedContinuation { self.entryWaiters.append($0) } }
    }
    func release() {
        self.released = true
        let waiters = self.releaseWaiters; self.releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private final nonisolated class CallObservationTestMicrophone: MeetingMicrophoneObservationPolling, @unchecked Sendable {
    private let lock = NSLock()
    private var counts = (starts: 0, polls: 0, keys: 0, stops: 0)
    private var managed = false
    let handler: MeetingMicrophoneMuteMonitor.Handler
    let stopBarrier: CallObservationBarrier?
    init(handler: @escaping MeetingMicrophoneMuteMonitor.Handler, stopBarrier: CallObservationBarrier? = nil) {
        self.handler = handler; self.stopBarrier = stopBarrier
    }
    func start(externallyDriven: Bool) { self.lock.withLock { self.counts.starts += 1; self.managed = externallyDriven } }
    func requestPoll() { self.lock.withLock { self.counts.polls += 1 } }
    func handleSharedPTT(_ event: MeetingMutePTTListener.Event) { self.lock.withLock { self.counts.keys += 1 } }
    func stop() async {
        self.lock.withLock { self.counts.stops += 1 }
        await self.stopBarrier?.park()
    }
    func emit(_ state: MeetingMicrophoneMuteState) {
        self.handler(.init(state: state, observedAtHostTime: 100, generation: 1))
    }
    var snapshot: (Int, Int, Int, Int, Bool) {
        self.lock.withLock { (self.counts.starts, self.counts.polls, self.counts.keys, self.counts.stops, self.managed) }
    }
}

private final nonisolated class CallObservationTestKeys: MeetingCallKeyListening, @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0, stops = 0
    var canListen = true
    var handler: (@Sendable (MeetingMutePTTListener.Event) -> Void)?
    func start() -> Bool { self.lock.withLock { self.starts += 1; return self.canListen } }
    func stop() { self.lock.withLock { self.stops += 1 } }
    var snapshot: (Int, Int) { self.lock.withLock { (self.starts, self.stops) } }
}

private final nonisolated class CallObservationTestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var microphones: [CallObservationTestMicrophone] = []
    private var states: [MeetingMicrophoneMuteState] = []
    var stopBarrier: CallObservationBarrier?
    func make(_ handler: @escaping MeetingMicrophoneMuteMonitor.Handler) -> CallObservationTestMicrophone {
        let mic = CallObservationTestMicrophone(handler: handler, stopBarrier: self.stopBarrier)
        self.lock.withLock { self.microphones.append(mic) }; return mic
    }
    func observe(_ observation: MeetingMicrophoneMuteObservation) { self.lock.withLock { self.states.append(observation.state) } }
    var drivers: [CallObservationTestMicrophone] { self.lock.withLock { self.microphones } }
    var delivered: [MeetingMicrophoneMuteState] { self.lock.withLock { self.states } }
}

@MainActor
private final class CallObservationTestDetection: MeetingCallDetectionDriving {
    var starts = 0, stops = 0, polls = 0
    var pollBarrier: CallObservationBarrier?
    func startManagedObservation() { self.starts += 1 }
    func stopManagedObservation() { self.stops += 1 }
    func pollManagedObservation() async { self.polls += 1; await self.pollBarrier?.park() }
}

@MainActor
final class MeetingCallObservationServiceTests: XCTestCase {
    private func service(store: CallObservationTestStore, keys: CallObservationTestKeys) -> MeetingCallObservationService {
        MeetingCallObservationService(automaticScheduling: false,
            microphoneFactory: { _, handler in store.make(handler) },
            keyListenerFactory: { handler in keys.handler = handler; return keys })
    }

    func testSharedScheduleAndSinglePassiveKeyListenerAcrossObservers() async throws {
        let store = CallObservationTestStore(), keys = CallObservationTestKeys()
        let service = self.service(store: store, keys: keys)
        let detection = CallObservationTestDetection()
        XCTAssertNil(service.pollingIntervalNanoseconds)
        service.attachDetection(detection); service.attachDetection(detection)
        XCTAssertEqual(detection.starts, 1)
        XCTAssertEqual(service.pollingIntervalNanoseconds, 2_000_000_000)
        let first = service.makeMicrophoneObservation(application: nil, handler: store.observe)
        let second = service.makeMicrophoneObservation(application: nil, handler: store.observe)
        try first.start(); try first.start(); try second.start()
        XCTAssertEqual(service.activeMicrophoneObservationCount, 2)
        XCTAssertEqual(service.pollingIntervalNanoseconds, 250_000_000)
        XCTAssertEqual(keys.snapshot.0, 1)
        XCTAssertTrue(store.drivers.allSatisfy { $0.snapshot.0 == 1 && $0.snapshot.4 })
        service.pollOnce(at: 10)
        keys.handler?(.disabled)
        XCTAssertTrue(store.drivers.allSatisfy { $0.snapshot.1 == 1 && $0.snapshot.2 == 1 })
        await first.stop(); await first.stop()
        XCTAssertEqual(keys.snapshot.1, 0)
        keys.handler?(.disabled)
        XCTAssertEqual(store.drivers[0].snapshot.2, 1)
        XCTAssertEqual(store.drivers[1].snapshot.2, 2)
        await second.stop()
        XCTAssertEqual(keys.snapshot.1, 1)
        XCTAssertEqual(service.pollingIntervalNanoseconds, 2_000_000_000)
        service.detachDetection(detection)
        XCTAssertNil(service.pollingIntervalNanoseconds)
        XCTAssertEqual(detection.stops, 1)
        await service.shutdown()
    }

    func testRetiredObservationCannotPublishAfterStopAndCannotRestart() async throws {
        let store = CallObservationTestStore(), keys = CallObservationTestKeys()
        keys.canListen = false
        let service = self.service(store: store, keys: keys)
        let token = service.makeMicrophoneObservation(application: nil, handler: store.observe)
        try token.start()
        let microphone = try XCTUnwrap(store.drivers.first)
        microphone.emit(.muted)
        await token.stop()
        microphone.emit(.unmuted)
        try token.start()
        XCTAssertEqual(store.delivered, [.muted])
        XCTAssertEqual(store.drivers.count, 1)
        XCTAssertEqual(microphone.snapshot.3, 1)
        XCTAssertEqual(keys.snapshot.1, 1)
        await service.shutdown()
    }

    func testConcurrentStopJoinsSameNativeRetirementAndFencesDeliveryFirst() async throws {
        let store = CallObservationTestStore(), keys = CallObservationTestKeys()
        let barrier = CallObservationBarrier(); store.stopBarrier = barrier
        let service = self.service(store: store, keys: keys)
        let token = service.makeMicrophoneObservation(application: nil, handler: store.observe)
        try token.start()
        let microphone = try XCTUnwrap(store.drivers.first)
        let first = Task { await token.stop() }
        await barrier.waitUntilEntered()
        let second = Task { await token.stop() }
        microphone.emit(.unmuted)
        XCTAssertTrue(store.delivered.isEmpty)
        XCTAssertEqual(service.activeMicrophoneObservationCount, 0)
        await barrier.release()
        await first.value; await second.value
        XCTAssertEqual(microphone.snapshot.3, 1)
        await service.shutdown()
    }

    func testDetachedSlowDetectorCannotCreateOverlappingNativePolls() async {
        let store = CallObservationTestStore(), keys = CallObservationTestKeys()
        let service = self.service(store: store, keys: keys)
        let first = CallObservationTestDetection(), second = CallObservationTestDetection()
        let barrier = CallObservationBarrier(); first.pollBarrier = barrier
        service.attachDetection(first); service.pollOnce(at: 0)
        await barrier.waitUntilEntered()
        service.detachDetection(first); service.attachDetection(second)
        service.pollOnce(at: 100)
        XCTAssertEqual(first.polls, 1)
        XCTAssertEqual(second.polls, 0)
        await barrier.release()
        await service.shutdown()
        XCTAssertEqual(first.stops, 1)
        XCTAssertEqual(second.stops, 1)
        XCTAssertFalse(service.hasDetectionDriver)
    }

    func testObserverLimitRejectsBeforeAllocatingAnotherNativeDriver() async throws {
        let store = CallObservationTestStore(), keys = CallObservationTestKeys()
        let service = self.service(store: store, keys: keys)
        var tokens: [MeetingCallMicrophoneObservation] = []
        for _ in 0..<8 {
            let token = service.makeMicrophoneObservation(application: nil, handler: store.observe)
            try token.start(); tokens.append(token)
        }
        let excess = service.makeMicrophoneObservation(application: nil, handler: store.observe)
        XCTAssertThrowsError(try excess.start())
        XCTAssertEqual(store.drivers.count, 8)
        await service.shutdown()
        XCTAssertTrue(store.drivers.allSatisfy { $0.snapshot.3 == 1 })
        XCTAssertEqual(keys.snapshot.0, 1)
        XCTAssertEqual(keys.snapshot.1, 1)
        for token in tokens { await token.stop() }
    }
}

final class MeetingCommunicationModuleIntegrationTests: XCTestCase {
    func testRegisteredProfilesValidateAndResearchEntriesCannotObserve() throws {
        let snapshot = MeetingCommunicationModuleHost.snapshot
        XCTAssertEqual(snapshot.registrations.count, 12)
        XCTAssertEqual(Set(snapshot.registry.modules.map { $0.descriptor.id }).count, 12)
        for module in snapshot.registry.modules { XCTAssertNoThrow(try module.descriptor.validate()) }
        XCTAssertTrue(snapshot.registry.modules.filter { $0.descriptor.validation == .researchOnly }
            .allSatisfy { $0.descriptor.nativeBundleIdentifiers.isEmpty && $0.descriptor.browserBundleIdentifiers.isEmpty })
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "com.tinyspeck.slackmacgap"), .nativeTier1)
        XCTAssertEqual(MeetingAppRegistry.tier(forBundleIdentifier: "ru.keepcoder.Telegram"), .nativeTier1)
        XCTAssertNil(MeetingAppRegistry.tier(forBundleIdentifier: "unknown.call.application"))
    }

    func testRussianWebModuleUsesKnownDocumentAndCallControls() throws {
        let registry = MeetingCommunicationModuleHost.snapshot.registry
        func evidence(_ labels: [String], host: String = "telemost.yandex.ru") -> CommunicationModuleEvidence? {
            registry.resolve(snapshot: .init(bundleIdentifier: "com.google.Chrome", processID: 42, windowID: 9,
                documentURL: "https://" + host + "/j/synthetic-call", controls: labels.map { .init(role: "AXButton", labels: [$0]) }))
        }
        XCTAssertEqual(evidence(["Выйти из встречи", "Включить микрофон"])?.microphoneState, .muted)
        XCTAssertEqual(evidence(["Выйти из встречи", "Отключить микрофон"])?.microphoneState, .unmuted)
        XCTAssertEqual(evidence(["Отключить микрофон"])?.callState, .indeterminate)
        XCTAssertNil(evidence(["Выйти из встречи", "Отключить микрофон"], host: "telemost.yandex.ru.evil.test"))
        XCTAssertEqual(evidence(["Выйти из встречи", "Включить микрофон участника"])?.microphoneState, .indeterminate)
    }

    func testPTTModifiersArePerModuleAndIgnoreCapsLock() {
        let space = CommunicationPushToTalkChord()
        let optionSpace = CommunicationPushToTalkChord(modifiers: [.option])
        XCTAssertNotNil(MeetingPTTChordMatcher.chord(in: [space], keyCode: 49, flags: 0))
        XCTAssertNil(MeetingPTTChordMatcher.chord(in: [space], keyCode: 49, flags: CGEventFlags.maskCommand.rawValue))
        XCTAssertNil(MeetingPTTChordMatcher.chord(in: [optionSpace], keyCode: 49, flags: 0))
        XCTAssertNotNil(MeetingPTTChordMatcher.chord(in: [optionSpace], keyCode: 49, flags: CGEventFlags.maskAlternate.union(.maskAlphaShift).rawValue))
        XCTAssertNil(MeetingPTTChordMatcher.chord(in: [optionSpace], keyCode: 50, flags: CGEventFlags.maskAlternate.rawValue))
    }

    func testLostPTTControlRetiresOnlyATemporaryGrant() {
        var permanent = MeetingMuteTransitionState()
        XCTAssertFalse(permanent.observe(.unmuted, at: 100))
        XCTAssertFalse(permanent.retireTemporaryGrant(at: 200))
        XCTAssertEqual(permanent.state, .unmuted)
        var temporary = MeetingMuteTransitionState()
        XCTAssertTrue(temporary.observe(.muted, at: 100))
        temporary.keyDown(at: 110)
        XCTAssertTrue(temporary.observe(.unmuted, at: 120))
        XCTAssertTrue(temporary.retireTemporaryGrant(at: 130))
        XCTAssertEqual(temporary.state, .muted)
        XCTAssertFalse(temporary.observe(.unmuted, at: 125))
        XCTAssertFalse(temporary.observe(.muted, at: 140))
        XCTAssertTrue(temporary.observe(.unmuted, at: 150))
    }

    func testDocumentIdentityDropsSecretsButPreservesSelectedRoomAndOrigin() {
        XCTAssertEqual(MeetingCommunicationAXProbe.documentIdentity("https://telemost.yandex.ru/j/room?token=private#fragment"), "https://telemost.yandex.ru/j/room")
        XCTAssertNotEqual(MeetingCommunicationAXProbe.documentIdentity("https://telemost.yandex.ru/j/room"), MeetingCommunicationAXProbe.documentIdentity("https://telemost.yandex.ru/j/another"))
        XCTAssertNil(MeetingCommunicationAXProbe.documentIdentity("https://user:password@telemost.yandex.ru/j/room"))
    }
}

private final nonisolated class ModuleObserverTestProbe: MeetingCommunicationObservationReading, @unchecked Sendable {
    private let lock = NSLock()
    private var microphone: CommunicationMicrophoneState? = .muted
    private var callState: CommunicationCallState = .inCall
    private var windowID: UInt32 = 77
    private var requestedBounds: [UInt32?] = []
    private var focused = true
    private var requestHandler: (@Sendable () -> Void)?
    private var focusDocuments: [String?] = []
    func configure(microphone: CommunicationMicrophoneState?, focused: Bool = true,
                   callState: CommunicationCallState = .inCall, windowID: UInt32 = 77,
                   onRequest: (@Sendable () -> Void)? = nil) {
        self.lock.withLock {
            self.microphone = microphone; self.focused = focused; self.callState = callState
            self.windowID = windowID; self.requestHandler = onRequest
        }
    }
    func request(application: MeetingApplicationIdentity, boundWindowID: UInt32?, boundDocument: String?,
                 modules: MeetingCommunicationModuleSnapshot,
                 completion: @escaping @Sendable ([MeetingCommunicationObservation]) -> Void) {
        let (mic, phase, window, handler) = self.lock.withLock {
            self.requestedBounds.append(boundWindowID)
            return (self.microphone, self.callState, self.windowID, self.requestHandler)
        }
        if let mic, boundWindowID == nil || boundWindowID == window {
            let snapshot = CommunicationObservationSnapshot(bundleIdentifier: application.bundleIdentifier,
                processID: application.processID ?? 42, windowID: window, documentURL: "https://call.example.com/room",
                controls: [.init(role: "AXButton", labels: [phase == .prejoin ? "Join now" : "Leave call"]),
                    .init(role: "AXButton", labels: [mic == .muted ? "Turn on microphone" : "Turn off microphone"])])
            completion([.init(snapshot: snapshot, evidence: modules.registry.resolve(snapshot: snapshot)!, acquiredAtHostTime: mach_absolute_time())])
        } else { completion([]) }
        handler?()
    }
    func ownsFocus(application: MeetingApplicationIdentity, windowID: UInt32, boundDocument: String?) -> Bool {
        self.lock.withLock { self.focusDocuments.append(boundDocument); return self.focused }
    }
    var documents: [String?] { self.lock.withLock { self.focusDocuments } }
    var bounds: [UInt32?] { self.lock.withLock { self.requestedBounds } }
}

private final nonisolated class ModuleObserverTestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [MeetingMicrophoneMuteState] = []
    private let arrivals: [XCTestExpectation]
    init(_ arrivals: [XCTestExpectation]) { self.arrivals = arrivals }
    func append(_ observation: MeetingMicrophoneMuteObservation) {
        let index = self.lock.withLock { self.values.append(observation.state); return self.values.count - 1 }
        if index < self.arrivals.count { self.arrivals[index].fulfill() }
    }
    var states: [MeetingMicrophoneMuteState] { self.lock.withLock { self.values } }
}

final class MeetingModuleMicrophoneObserverTests: XCTestCase {
    func testPrejoinDoesNotInventMuteOrPinTheWrongWindowAfterJoin() async throws {
        let module = try SemanticCommunicationModule(descriptor: .init(id: "test.prejoin", displayName: "Prejoin boundary",
            browserBundleIdentifiers: ["com.google.Chrome"], urlRules: [.init(host: "call.example.com")],
            callRules: .init(connected: [.init(labels: ["Leave call"])], prejoin: [.init(labels: ["Join now"])]),
            microphoneRules: .init(muted: [.init(labels: ["Turn on microphone"])], unmuted: [.init(labels: ["Turn off microphone"])])))
        let snapshot = MeetingCommunicationModuleSnapshot(registry: try .init(modules: [module]), registrations: [.init(module: module)])
        let arrivals = (0..<3).map { self.expectation(description: "prejoin admission \($0)") }
        let capture = ModuleObserverTestCapture(arrivals), probe = ModuleObserverTestProbe()
        let observer = MeetingModuleMicrophoneObserver(application: .init(bundleIdentifier: "com.google.Chrome", processID: 42, displayName: "Synthetic browser"),
            snapshot: snapshot, probe: probe) { capture.append($0) }
        observer.start(externallyDriven: true)
        await self.fulfillment(of: [arrivals[0]], timeout: 2)
        let preview = self.expectation(description: "preview inspected")
        probe.configure(microphone: .unmuted, callState: .prejoin, windowID: 77, onRequest: { preview.fulfill() })
        observer.requestPoll()
        await self.fulfillment(of: [preview], timeout: 2)
        probe.configure(microphone: .muted, windowID: 88)
        observer.requestPoll()
        await self.fulfillment(of: [arrivals[1]], timeout: 2)
        probe.configure(microphone: .unmuted, windowID: 88)
        observer.requestPoll()
        await self.fulfillment(of: [arrivals[2]], timeout: 2)
        let pinned = self.expectation(description: "connected window pinned")
        probe.configure(microphone: nil, windowID: 88, onRequest: { pinned.fulfill() })
        observer.requestPoll()
        await self.fulfillment(of: [pinned], timeout: 2)
        await observer.stop()
        XCTAssertEqual(probe.bounds, [nil, nil, 88, 88])
        XCTAssertEqual(capture.states, [.unmuted, .muted, .unmuted])
    }
    func testSameWindowDocumentLossRetiresTemporaryGrantButPreservesPermanentUnmute() async throws {
        let module = try SemanticCommunicationModule(descriptor: .init(id: "test.owned-call", displayName: "Synthetic call",
            browserBundleIdentifiers: ["com.google.Chrome"], urlRules: [.init(host: "call.example.com")],
            callRules: .init(connected: [.init(labels: ["Leave call"])]),
            microphoneRules: .init(muted: [.init(labels: ["Turn on microphone"])], unmuted: [.init(labels: ["Turn off microphone"])]),
            pushToTalkChords: [.init()]))
        let snapshot = MeetingCommunicationModuleSnapshot(registry: try .init(modules: [module]), registrations: [.init(module: module)])
        let arrivals = (0..<5).map { self.expectation(description: "microphone transition \($0)") }
        let capture = ModuleObserverTestCapture(arrivals)
        let probe = ModuleObserverTestProbe()
        let observer = MeetingModuleMicrophoneObserver(application: .init(bundleIdentifier: "com.google.Chrome", processID: 42, displayName: "Synthetic browser"),
            snapshot: snapshot, probe: probe) { capture.append($0) }
        observer.start(externallyDriven: true)
        await self.fulfillment(of: [arrivals[0]], timeout: 2)
        observer.requestPoll()
        await self.fulfillment(of: [arrivals[1]], timeout: 2)
        observer.handleSharedPTT(.key(held: true, timestampNanoseconds: nil))
        probe.configure(microphone: .unmuted)
        observer.requestPoll()
        await self.fulfillment(of: [arrivals[2]], timeout: 2)
        probe.configure(microphone: nil, focused: false)
        observer.requestPoll()
        await self.fulfillment(of: [arrivals[3]], timeout: 2)
        XCTAssertFalse(probe.documents.isEmpty)
        XCTAssertEqual(probe.documents.compactMap { $0 }, Array(repeating: "https://call.example.com/room", count: probe.documents.count))

        // A fresh rendered mute rearms the release fence; the next explicit unmute is permanent.
        let rearmed = self.expectation(description: "fresh muted frame")
        probe.configure(microphone: .muted, onRequest: { rearmed.fulfill() })
        observer.requestPoll()
        await self.fulfillment(of: [rearmed], timeout: 2)
        probe.configure(microphone: .unmuted)
        observer.requestPoll()
        await self.fulfillment(of: [arrivals[4]], timeout: 2)
        observer.handleSharedPTT(.disabled)
        let missing = self.expectation(description: "missing document after permanent unmute")
        probe.configure(microphone: nil, focused: false, onRequest: { missing.fulfill() })
        observer.requestPoll()
        await self.fulfillment(of: [missing], timeout: 2)
        await observer.stop()
        XCTAssertEqual(capture.states, [.unmuted, .muted, .unmuted, .muted, .unmuted])
    }
}

private final nonisolated class RecordedCallStatus: MeetingRenderedAudioStatusObserving {
    let snapshot: MeetingRenderedAudioStatusSnapshot
    init(_ snapshot: MeetingRenderedAudioStatusSnapshot) { self.snapshot = snapshot }
    func sample(processID: Int32, boundWindowID: UInt32?) -> MeetingRenderedAudioStatusSnapshot { self.snapshot }
    func ownsFocusedWindow(processID: Int32) -> Bool { false }
    func invalidate() {}
}

/// Sanitized control subsets observed with CUA on 2026-11-06, not fabricated platform labels.
/// Dynamic room IDs, process/window IDs, participant names and messages are excluded.
final class MeetingRecordedCommunicationSurfaceTests: XCTestCase {
    private func evidence(bundle: String = "com.google.Chrome", url: String?, controls: [CommunicationControlSnapshot]) -> CommunicationModuleEvidence? {
        MeetingCommunicationModuleHost.snapshot.registry.resolve(snapshot: .init(bundleIdentifier: bundle,
            processID: 42, windowID: 77, documentURL: url,
            windowIdentifier: bundle == "us.zoom.xos" ? "zm.meeting.window.main" : nil, controls: controls))
    }

    func testObservedMeetMuteAndUnmuteControlsMatchProductionProfile() {
        let leave = CommunicationControlSnapshot(role: "AXButton", labels: ["Leave call"])
        for (label, expected) in [("Turn on microphone", CommunicationMicrophoneState.muted), ("Turn off microphone", .unmuted)] {
            let value = self.evidence(url: "https://meet.google.com/meet/abc-defg-hij", controls: [leave, .init(role: "AXButton", labels: [label])])
            XCTAssertEqual(value?.callState, .inCall)
            XCTAssertEqual(value?.microphoneState, expected)
        }
    }

    func testObservedTeamsConsumerRequiresTheSelfToolbarAndButtonIdentity() {
        let leave = CommunicationControlSnapshot(role: "AXButton", identifier: "hangup-button", labels: ["Leave"])
        for (label, expected) in [("Unmute mic", CommunicationMicrophoneState.muted), ("Mute mic", .unmuted)] {
            let selfMic = CommunicationControlSnapshot(role: "AXButton", identifier: "microphone-button", labels: [label], ancestorIdentifiers: ["horizontalMiddleEnd"])
            let value = self.evidence(url: "https://teams.live.com/v2/", controls: [leave, selfMic])
            XCTAssertEqual(value?.callState, .inCall)
            XCTAssertEqual(value?.microphoneState, expected)
            let unrelated = CommunicationControlSnapshot(role: "AXButton", identifier: "microphone-button", labels: [label], ancestorIdentifiers: ["participant-menu"])
            XCTAssertEqual(self.evidence(url: "https://teams.live.com/v2/", controls: [leave, unrelated])?.microphoneState, .indeterminate)
        }
    }

    func testObservedPrejoinControlsDoNotBecomeConnectedCalls() {
        let zoom = self.evidence(bundle: "us.zoom.xos", url: nil,
            controls: [.init(role: "AXButton", labels: ["Start"]), .init(role: "AXButton", identifier: "Audio", labels: ["Audio, turn on, currently muted", "Unmute"])])
        XCTAssertEqual(zoom?.callState, .prejoin)
        XCTAssertEqual(zoom?.microphoneState, .indeterminate)
        let teams = self.evidence(url: "https://teams.live.com/v2/", controls: [
            .init(role: "AXButton", identifier: "prejoin-join-button", labels: ["Join now"]),
            .init(role: "AXSwitch", labels: ["Unmute mic (⇧ ⌘ M)"], value: "0")])
        XCTAssertEqual(teams?.callState, .prejoin)
    }

    func testObservedTelemostConnectingToolbarIsNotEnoughToConfirmCall() {
        let value = self.evidence(url: "https://telemost.yandex.ru/j/anonymized-room", controls: [
            .init(role: "AXButton", labels: ["Выключить микрофон"]),
            .init(role: "AXButton", labels: ["Открыть экран звонка"]),
            .init(role: "AXButton", labels: ["Завершить звонок"])])
        XCTAssertEqual(value?.callState, .indeterminate)
        XCTAssertEqual(value?.microphoneState, .indeterminate)
    }

    func testRecordedNativeTeamsViewportPathCanReachControlsWithoutReadingListsOrEditors() {
        // CUA container roles mapped to their native AXGroup equivalent for this path replay.
        let path = ["AXWindow", "AXGroup", "AXGroup", "AXGroup", "AXScrollArea", "AXWebArea", "AXGroup"]
        XCTAssertTrue(path.enumerated().allSatisfy { MeetingCommunicationAXTraversal.descends(role: $0.element, depth: $0.offset) })
        for privateSubtree in ["AXTextArea", "AXTextField", "AXList", "AXTable", "AXOutline"] {
            XCTAssertFalse(MeetingCommunicationAXTraversal.descends(role: privateSubtree, depth: 6))
        }
        XCTAssertFalse(MeetingCommunicationAXTraversal.descends(role: "AXGroup", depth: 12))
    }

    func testHiddenToolbarNativeProofIsBoundToTheSameWindowAndCannotOverridePrejoin() throws {
        let module = try SemanticCommunicationModule(descriptor: .init(id: "observed.zoom", displayName: "Observed native surface",
            nativeBundleIdentifiers: ["us.zoom.xos"],
            callRules: .init(connected: [.init(labels: ["Leave"])], prejoin: [.init(labels: ["Start"])]),
            nativeWindowIdentifiers: ["zm.meeting.window.main"]))
        func host(window: UInt32) throws -> MeetingCommunicationModuleSnapshot {
            .init(registry: try .init(modules: [module]), registrations: [.init(module: module,
                nativeCallStatusFactory: { RecordedCallStatus(.init(callWindowID: window, state: .muted, temporaryHUDVisible: nil)) })])
        }
        let hidden = CommunicationObservationSnapshot(bundleIdentifier: "us.zoom.xos", processID: 42, windowID: 77,
            windowIdentifier: "zm.meeting.window.main", controls: [])
        XCTAssertEqual(try host(window: 77).resolve(hidden)?.callState, .inCall)
        XCTAssertEqual(try host(window: 77).resolve(hidden)?.microphoneState, .muted)
        XCTAssertEqual(try host(window: 88).resolve(hidden)?.callState, .indeterminate)
        let preview = CommunicationObservationSnapshot(bundleIdentifier: "us.zoom.xos", processID: 42, windowID: 77,
            windowIdentifier: "zm.meeting.window.main", controls: [.init(role: "AXButton", labels: ["Start"])])
        XCTAssertEqual(try host(window: 77).resolve(preview)?.callState, .prejoin)
        let conflict = CommunicationObservationSnapshot(bundleIdentifier: "us.zoom.xos", processID: 42, windowID: 77,
            windowIdentifier: "zm.meeting.window.main", controls: preview.controls + [.init(role: "AXButton", labels: ["Leave"])])
        XCTAssertEqual(try host(window: 77).resolve(conflict)?.callState, .indeterminate)
        let home = CommunicationObservationSnapshot(bundleIdentifier: "us.zoom.xos", processID: 42, windowID: 77,
            windowIdentifier: "home-window", controls: [])
        XCTAssertEqual(try host(window: 77).resolve(home)?.callState, .indeterminate)
        let impostor = CommunicationObservationSnapshot(bundleIdentifier: "another.app", processID: 42, windowID: 77, controls: [])
        XCTAssertNil(try host(window: 77).resolve(impostor))
    }
}
