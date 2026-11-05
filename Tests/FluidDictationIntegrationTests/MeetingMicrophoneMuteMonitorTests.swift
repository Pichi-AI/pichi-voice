import Foundation
import XCTest
@testable import FluidVoice_Debug

final class MeetingMicrophoneMuteMonitorTests: XCTestCase {
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
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unknown, after: .unmuted, visual: .unmuted), .unknown)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unmuted, after: .muted, visual: .unmuted), .unknown)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .muted, after: .muted, visual: .unmuted), .unknown)
        XCTAssertEqual(MeetingMuteObservationPolicy.state(before: .unmuted, after: .unmuted, visual: .unknown), .unknown)
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

    func testDelayedKeyDownStillOwnsRelease() {
        var state = MeetingMutePTTState()
        state.keyDown(at: 90, persistentlyUnmuted: true, latestObservation: 100)
        XCTAssertTrue(state.possiblePTT)
        XCTAssertTrue(state.release(at: 150))
        XCTAssertFalse(state.permitsPositive(captureStarted: 160))
        state.confirmedMuted(captureStarted: 149)
        XCTAssertFalse(state.permitsPositive(captureStarted: 170))
        state.confirmedMuted(captureStarted: 151)
        XCTAssertTrue(state.permitsPositive(captureStarted: 170))
        XCTAssertFalse(state.permitsPositive(captureStarted: 140), "A late pre-release positive stays excluded after fresh mute clears the fence")
    }

    func testOrdinarySpaceInPersistentUnmuteDoesNotClose() {
        var state = MeetingMutePTTState()
        state.keyDown(at: 110, persistentlyUnmuted: true, latestObservation: 100)
        XCTAssertFalse(state.possiblePTT)
        XCTAssertFalse(state.release(at: 150))
        XCTAssertTrue(state.permitsPositive(captureStarted: 160))
    }

    func testShortPTTAndFocusLossRequireFreshMutedConfirmation() {
        var state = MeetingMutePTTState()
        state.keyDown(at: 110, persistentlyUnmuted: false, latestObservation: 100)
        state.keyDown(at: 120, persistentlyUnmuted: true, latestObservation: 115)
        XCTAssertTrue(state.possiblePTT, "Repeat delivery cannot reclassify a held PTT as persistent unmute")
        XCTAssertTrue(state.release(at: 150), "The focus-loss reset uses the same exclusion as key-up")
        XCTAssertFalse(state.release(at: 160))
        XCTAssertFalse(state.permitsPositive(captureStarted: 170))
        state.confirmedMuted(captureStarted: 170)
        XCTAssertTrue(state.permitsPositive(captureStarted: 180))
        var missingTime = MeetingMutePTTState()
        missingTime.keyDown(at: nil, persistentlyUnmuted: true, latestObservation: 100)
        XCTAssertTrue(missingTime.release(at: 150))
    }

    func testUnsupportedMonitorStopsWithoutOpeningNativeResources() {
        let capture = ObservationCapture()
        let monitor = MeetingMicrophoneMuteMonitor(application: .init(bundleIdentifier: "invalid.synthetic", processID: 1, displayName: "Synthetic")) {
            capture.append($0)
        }
        monitor.start()
        self.stop(monitor)
        XCTAssertEqual(capture.states, [.checking, .unknown, .unknown])
        monitor.start()
        self.stop(monitor)
        XCTAssertEqual(capture.states, [.checking, .unknown, .unknown], "Stop is terminal and idempotent for one attempt")
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
