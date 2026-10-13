@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@testable import PichiVoiceMobile
import XCTest

/// A synthetic microphone implements the existing capture contract. Everything after
/// PCM delivery is the actual mobile composition, ASR, coordinator, pipeline and store.
private actor SyntheticMeetingMicrophone: MeetingCaptureControlling {
    private var factory: IOSMeetingCaptureEngine.MemoryConsumerFactory?
    private var consumer: (any MeetingMemoryAudioConsuming)?
    private var active: (MeetingSessionID, MeetingAudioTrack)?
    func setFactory(_ factory: IOSMeetingCaptureEngine.MemoryConsumerFactory?) { self.factory = factory }
    func preflightPermissions() async throws { }
    func start(session: MeetingSession, configuration: MeetingCaptureConfiguration, sessionDirectory: URL,
               eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
               liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
        guard active == nil, let factory, configuration.audioStorageMode == .memoryOnly else {
            throw MeetingCaptureError.captureStartFailed("Synthetic input requires strict PCM")
        }
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic microphone", format: .init(codec: "lpcm-f32", sampleRate: 16_000,
            channelCount: 1, bitRate: nil), timebase: session.timebase, health: .waiting, chunks: [])
        consumer = try await factory(session, configuration, track, eventHandler)
        active = (session.id, track)
        return .init(tracks: [track], firstPresentationTime: nil)
    }
    func deliver(_ samples: [Float]) throws {
        guard let consumer else { throw MeetingCaptureError.noActiveCapture }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        for start in stride(from: 0, to: samples.count, by: 1600) {
            let end = min(samples.count, start + 1600)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start)))
            pcm.frameLength = AVAudioFrameCount(end - start)
            let target = try XCTUnwrap(pcm.floatChannelData?[0])
            for frame in start..<end { target[frame - start] = samples[frame] }
            let buffer = try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm,
                presentationTime: CMTime(value: Int64(start), timescale: 16_000))
            guard consumer.enqueue(buffer) else { throw MeetingMemoryAudioError.overload }
        }
    }
    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        guard let (id, original) = active, id == sessionID else { throw MeetingCaptureError.wrongActiveSession }
        try await consumer?.finish()
        var track = original; track.health.status = .stopped
        active = nil; consumer = nil
        return .init(tracks: [track], stoppedAt: Date())
    }
    func shutdownForTermination() async {
        if let (id, _) = active { _ = try? await stop(sessionID: id) }
        factory = nil
    }
}

@MainActor
final class MobileMeetingEndToEndTests: XCTestCase {
    func testStrictMeetingThroughActualMobileCompositionPersistsAndExports() async throws {
        let assets = try MobileInferenceTestAssets.resolve()
        let input = try AVAudioFile(forReading: assets.appendingPathComponent("audio/ru.wav"))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)))
        try input.read(into: pcm)
        let samples = Array(UnsafeBufferPointer(start: try XCTUnwrap(pcm.floatChannelData?[0]), count: Int(pcm.frameLength)))
        let name = "MobileMeetingE2E.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        settings.meetingSaveAudio = false; settings.meetingSpeakerLabelsEnabled = false
        let store = MeetingSessionStore(rootDirectory: root)
        let microphone = SyntheticMeetingMicrophone()
        let services = AppServices(store: store, capture: microphone, settings: settings,
            microphoneResolver: { _ in .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone") })
        await microphone.setFactory { session, _, track, events in
            try await services.meetingProcessingPipeline.memoryConsumer(for: session.id, track: track, eventHandler: events)
        }
        do {
            // Uses the same installation operation as Settings, with verified public artifacts.
            try await services.asr.downloadModel(.whisperTiny)
            let configuration = try await services.meetingSessionCoordinator.defaultConfiguration(mode: .inRoom, title: "Synthetic meeting")
            let recording = try await services.meetingSessionCoordinator.startRecording(configuration: configuration)
            XCTAssertEqual(recording.audioStorageMode, .memoryOnly)
            try await microphone.deliver(samples)
            let completed = try await services.meetingSessionCoordinator.stopAndTranscribe()
            XCTAssertEqual(completed.state, .completed)
            XCTAssertFalse(completed.transcriptSegments.isEmpty)
            XCTAssertFalse(completed.hasFinalizedAudio)
            XCTAssertEqual(completed.transcriptTimeDomain, .meetingRelative)
            let saved = try await store.load(id: completed.id)
            XCTAssertEqual(saved?.transcriptSegments, completed.transcriptSegments)
            let text = MeetingTranscriptExporter.text(for: completed)
            XCTAssertFalse(text.isEmpty)
            let payload = try MeetingSharePayload.transcript(data: try MeetingTranscriptExporter.json(for: completed),
                title: completed.title, fileExtension: "json")
            defer { payload.cleanup() }
            XCTAssertFalse(payload.includesAudio)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in files {
                if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    XCTAssertEqual(file.pathExtension, "json", file.lastPathComponent)
                }
            }
            await microphone.shutdownForTermination()
            await services.asr.shutdownForTermination()
        } catch {
            await microphone.shutdownForTermination()
            await services.asr.shutdownForTermination()
            throw error
        }
    }
}
