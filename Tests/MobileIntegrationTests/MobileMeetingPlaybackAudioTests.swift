@preconcurrency import AVFoundation
import Combine
import CoreMedia
@testable import PichiVoiceMobile
import XCTest

@MainActor
final class MobileMeetingPlaybackAudioTests: XCTestCase {
    func testPlaybackReplacesSilentSensitiveAndRecordingCategoriesBeforeActivation() throws {
        for category: AVAudioSession.Category in [.soloAmbient, .ambient, .record, .playAndRecord] {
            let system = PlaybackSystemSession()
            system.category = category
            system.mode = .voiceChat
            system.categoryOptions = [.defaultToSpeaker]
            let owner = MeetingPlaybackAudioSession(session: system)
            try owner.activate()
            XCTAssertEqual(system.events, ["category", "activate"])
            XCTAssertEqual(system.category, .playback)
            XCTAssertEqual(system.mode, .default)
            XCTAssertEqual(system.categoryOptions, [.mixWithOthers])
            owner.deactivate()
            XCTAssertEqual(system.activeOptions, [.notifyOthersOnDeactivation])
        }
    }

    func testUnusedAndRepeatedReleaseDoNotDeactivateAnotherOwner() throws {
        let system = PlaybackSystemSession()
        let owner = MeetingPlaybackAudioSession(session: system)
        owner.deactivate()
        XCTAssertTrue(system.events.isEmpty)
        try owner.activate()
        owner.deactivate()
        owner.deactivate()
        XCTAssertEqual(system.events, ["category", "activate", "deactivate"])
    }

    func testCaptureTakingOverCannotBeDeactivatedByPlaybackCleanup() throws {
        let system = PlaybackSystemSession()
        let owner = MeetingPlaybackAudioSession(session: system)
        try owner.activate()
        system.category = .playAndRecord
        system.categoryOptions = [.defaultToSpeaker, .allowBluetoothA2DP]
        owner.deactivate()
        XCTAssertEqual(system.events, ["category", "activate"])
    }

    func testCategoryFailureNeverActivatesOrReleasesAnUnownedSession() {
        let system = PlaybackSystemSession()
        system.failCategory = true
        let owner = MeetingPlaybackAudioSession(session: system)
        XCTAssertThrowsError(try owner.activate())
        owner.deactivate()
        XCTAssertEqual(system.events, ["category"])
    }

    func testActivationFailureReleasesPartialActivationAndAllowsRetry() throws {
        let system = PlaybackSystemSession()
        system.failActivation = true
        let owner = MeetingPlaybackAudioSession(session: system)
        XCTAssertThrowsError(try owner.activate())
        XCTAssertEqual(system.events, ["category", "activate", "deactivate"])
        system.failActivation = false
        try owner.activate()
        owner.deactivate()
        XCTAssertEqual(system.events.suffix(3), ["category", "activate", "deactivate"])
    }

    func testTranscriptActionActivatesPlaybackAndReactivatesAfterPause() async throws {
        let (store, session) = try await fixture()
        let audio = PlaybackAudioOwner()
        let playback = MeetingSegmentPlayback(store: store, audioSession: audio)
        defer { playback.stop() }
        try await load(playback, session: session)
        XCTAssertTrue(playback.progress.isPlaying)
        XCTAssertEqual(audio.activations, 1)
        XCTAssertEqual(playback.progress.duration, 0.5, accuracy: 0.01)
        playback.togglePause()
        XCTAssertFalse(playback.progress.isPlaying)
        XCTAssertFalse(audio.isActive)
        playback.togglePause()
        XCTAssertTrue(playback.progress.isPlaying)
        XCTAssertEqual(audio.activations, 2)
        playback.stop()
        XCTAssertFalse(audio.isActive)
        XCTAssertNil(playback.activeSegmentID)
    }

    func testActivationErrorIsVisibleAndNeverClaimsToPlay() async throws {
        let (store, session) = try await fixture()
        let audio = PlaybackAudioOwner()
        audio.failActivation = true
        let playback = MeetingSegmentPlayback(store: store, audioSession: audio)
        defer { playback.stop() }
        try await load(playback, session: session)
        XCTAssertEqual(playback.errorMessage, "This audio chunk could not be played.")
        XCTAssertFalse(playback.progress.isPlaying)
        XCTAssertNil(playback.activeSegmentID)
        XCTAssertFalse(audio.isActive)
    }

    func testResumeActivationErrorClosesPlayerAndReleasesAudio() async throws {
        let (store, session) = try await fixture()
        let audio = PlaybackAudioOwner()
        let playback = MeetingSegmentPlayback(store: store, audioSession: audio)
        defer { playback.stop() }
        try await load(playback, session: session)
        playback.togglePause()
        audio.failActivation = true
        playback.togglePause()
        XCTAssertNotNil(playback.errorMessage)
        XCTAssertFalse(playback.progress.isPlaying)
        XCTAssertFalse(audio.isActive)
    }

    func testCompletionReleasesAudioAndReplayAcquiresItAgain() async throws {
        let (store, session) = try await fixture()
        let audio = PlaybackAudioOwner()
        let playback = MeetingSegmentPlayback(store: store, audioSession: audio)
        defer { playback.stop() }
        try await load(playback, session: session)
        let ended = expectation(description: "Native player finishes synthetic clip")
        let observation = playback.progress.$isPlaying.dropFirst().filter { !$0 }.prefix(1).sink { _ in ended.fulfill() }
        defer { observation.cancel() }
        await fulfillment(of: [ended], timeout: 10)
        XCTAssertFalse(audio.isActive)
        XCTAssertEqual(playback.progress.elapsed, playback.progress.duration)
        playback.togglePause()
        XCTAssertEqual(audio.activations, 2)
        XCTAssertTrue(audio.isActive)
    }

    func testProfileTransitionJoinsCancelledLoadWithoutActivatingAudio() async throws {
        let (store, session) = try await fixture()
        let audio = PlaybackAudioOwner()
        let playback = MeetingSegmentPlayback(store: store, audioSession: audio)
        playback.toggle(session: session, segmentIDs: session.transcriptSegments.map(\.id))
        try await playback.prepareForPrivateProfileTransition()
        XCTAssertEqual(audio.activations, 0)
        XCTAssertFalse(audio.isActive)
        XCTAssertNil(playback.activeSegmentID)
        XCTAssertNil(playback.errorMessage)
    }

    private func load(_ playback: MeetingSegmentPlayback, session: MeetingSession) async throws {
        let loaded = expectation(description: "Production transcript action resolves recorded audio")
        let observation = playback.$isLoading.dropFirst().filter { !$0 }.prefix(1).sink { _ in loaded.fulfill() }
        defer { observation.cancel() }
        playback.toggle(session: session, segmentIDs: session.transcriptSegments.map(\.id))
        await fulfillment(of: [loaded], timeout: 10)
    }

    private func fixture() async throws -> (MeetingSessionStore, MeetingSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic playback",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"), audioStorageMode: .retainedFiles)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: directory, eventHandler: { _ in })
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000))
        pcm.frameLength = 8_000
        let channel = try XCTUnwrap(pcm.floatChannelData?[0])
        for frame in 0..<8_000 { channel[frame] = 0.001 * sin(Float(frame) * 0.1) }
        XCTAssertTrue(writer.enqueue(try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm, presentationTime: .zero)))
        session.audioTracks = [await writer.stop()]
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(0.5)
        session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 16_000),
            end: .init(value: 8_000, timescale: 16_000), sourceTrackID: track.id, speakerID: nil,
            text: "Synthetic clip", revision: 0, status: .final, overlap: .none, completeness: .complete)]
        try await store.save(session)
        return (store, session)
    }
}

@MainActor
private final class PlaybackSystemSession: MeetingPlaybackSystemAudioSession {
    var category: AVAudioSession.Category = .soloAmbient
    var mode: AVAudioSession.Mode = .default
    var categoryOptions: AVAudioSession.CategoryOptions = []
    var activeOptions: AVAudioSession.SetActiveOptions = []
    var events: [String] = []
    var failCategory = false
    var failActivation = false
    func setCategory(_ category: AVAudioSession.Category, mode: AVAudioSession.Mode,
                     options: AVAudioSession.CategoryOptions) throws {
        events.append("category")
        if failCategory { throw CocoaError(.featureUnsupported) }
        self.category = category; self.mode = mode; categoryOptions = options
    }
    func setActive(_ active: Bool, options: AVAudioSession.SetActiveOptions) throws {
        events.append(active ? "activate" : "deactivate")
        activeOptions = options
        if active && failActivation { throw CocoaError(.featureUnsupported) }
    }
}

@MainActor
private final class PlaybackAudioOwner: MeetingPlaybackAudioSessionControlling {
    var activations = 0
    var isActive = false
    var failActivation = false
    func activate() throws {
        activations += 1
        if failActivation { throw CocoaError(.featureUnsupported) }
        isActive = true
    }
    func deactivate() { isActive = false }
}
