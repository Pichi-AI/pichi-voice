@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Darwin
import UIKit
@testable import PichiVoiceMobile
import XCTest

/// Explicitly enabled synthetic replay evidence belongs only to a private XCTest
/// attachment. Support logs, the app store and export paths never receive it.
private actor SyntheticPrivacyReplayDiagnostics: TranscriptTextRedacting {
    private struct Observation: Encodable {
        let elapsedSeconds: TimeInterval
        let input: String
        let output: String
        let inputUTF16: Int
        let provisionalSafeUTF16: Int?
        let spans: [Span]
    }
    private struct Span: Encodable {
        let start: Int
        let length: Int
        let replacement: String
    }
    private let wrapped: any TranscriptTextRedacting
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var observations: [Observation] = []
    private var retainedUTF16 = 0
    private var omittedObservations = 0

    init(wrapping wrapped: any TranscriptTextRedacting) { self.wrapped = wrapped }

    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let result = try await wrapped.redactWithSpans(text)
        let size = text.utf16.count + result.text.utf16.count
        if observations.count < 128, size <= 32_768, retainedUTF16 + size <= 131_072 {
            retainedUTF16 += size
            observations.append(.init(elapsedSeconds: ProcessInfo.processInfo.systemUptime - startedAt,
                input: text, output: result.text, inputUTF16: text.utf16.count,
                provisionalSafeUTF16: result.provisionalSafeUTF16,
                spans: result.spans.map { .init(start: $0.range.location, length: $0.range.length, replacement: $0.replacement) }))
        } else { omittedObservations += 1 }
        return result
    }

    func attachmentData() throws -> Data {
        struct Evidence: Encodable {
            let observations: [Observation]
            let omittedObservations: Int
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Evidence(observations: observations, omittedObservations: omittedObservations))
    }
}

private struct SyntheticDiagnosticEchoRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: text, spans: [], provisionalSafeUTF16: text.utf16.count)
    }
}

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
    func testPrivateSyntheticPrivacyDiagnosticsAreBoundedAndTransparent() async throws {
        let diagnostics = SyntheticPrivacyReplayDiagnostics(wrapping: SyntheticDiagnosticEchoRedactor())
        for _ in 0..<130 {
            let result = try await diagnostics.redactWithSpans("Synthetic fixture")
            XCTAssertEqual(result.text, "Synthetic fixture")
            XCTAssertEqual(result.provisionalSafeUTF16, 17)
        }
        let data = try await diagnostics.attachmentData()
        let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual((evidence["observations"] as? [[String: Any]])?.count, 128)
        XCTAssertEqual(evidence["omittedObservations"] as? Int, 2)
    }

    func testPhysicalStrictGigaAMWithSpeakersAndPrivacyKeepsUp() async throws {
        try await verifyPhysicalStrictMeeting(model: .gigaam)
    }

    func testPhysicalStrictWhisperTinyWithSpeakersAndPrivacyKeepsUp() async throws {
        try await verifyPhysicalStrictMeeting(model: .whisperTiny)
    }

    func testPhysicalStrictParakeetWithSpeakersAndPrivacyKeepsUp() async throws {
        try await verifyPhysicalStrictMeeting(model: .parakeetTDT)
    }

    /// The exact user configuration that serial, unpaced ASR fixtures did not cover.
    /// Speech comes from the device speaker through the real selected microphone.
    private func verifyPhysicalStrictMeeting(model: SettingsStore.SpeechModel) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires explicitly enabled physical strict meeting recording")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STRICT_MEETING_E2E"] == "1" else {
            throw XCTSkip("Enable physical strict ASR, diarization and PII replay explicitly")
        }
        guard let duration = Int(ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STRICT_MEETING_SECONDS"] ?? "60"),
              (60...300).contains(duration) else {
            throw NSError(domain: "PhysicalStrictMeetingDuration", code: 1)
        }
        guard AVAudioSession.sharedInstance().outputVolume > 0.05 else {
            throw XCTSkip("Physical speech replay requires audible device output")
        }
        let assets = try MobileInferenceTestAssets.resolve()
        let name = "PhysicalStrictMeeting.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = model
        settings.meetingSaveAudio = false
        settings.meetingSpeakerLabelsEnabled = true
        settings.meetingPIIRedactionEnabled = true
        let store = MeetingSessionStore(rootDirectory: root)
        let privacy = PichiTranscriptPrivacyService(modelStore: .init(directory: assets.appendingPathComponent("models/privacy")))
        let diagnostics = ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STRICT_PRIVACY_DIAGNOSTICS"] == "1"
            ? SyntheticPrivacyReplayDiagnostics(wrapping: privacy) : nil
        let services = AppServices(store: store, settings: settings, privacy: privacy, privacyRedactor: diagnostics)
        let coordinator = services.meetingSessionCoordinator
        let twoVoiceFixture = ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STRICT_TWO_VOICES"] == "1"
        let fixture = twoVoiceFixture ? "audio/mixed-two-voices.wav" : "audio/ru.wav"
        let player = try AVAudioPlayer(contentsOf: assets.appendingPathComponent(fixture))
        player.numberOfLoops = -1
        var firstTextSecond: Int?
        var firstPendingSecond: Int?
        var largestPendingCount = 0
        var updates = 0
        var protectedUpdateSeconds: [Double] = []
        var lastUpdateSecond = 0
        var lastBackgroundUpdateSecond = 0
        var previousIDs: Set<UUID> = []
        var previousPartial: MeetingLivePartial?
        let requiresBackground = ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STRICT_MEETING_BACKGROUND"] == "1"
        var backgroundSeconds: TimeInterval = 0
        var backgroundUpdates = 0
        var wasBackground = false
        do {
            let configuration: MeetingCaptureConfiguration
            do {
                configuration = try await coordinator.defaultConfiguration(mode: .inRoom, title: "Synthetic strict speech")
            } catch let error as MeetingBackendError {
                // The positive hardware probe cannot exercise a combination that the
                // registered backend deliberately rejects before capture. Keep that
                // refusal covered by MobilePCMAdmissionTests instead of bypassing it.
                guard case .unsupportedPCMConfiguration = error else { throw error }
                throw XCTSkip("Registered strict PCM admission rejects this exact deployment: \(error.localizedDescription)")
            }
            let recording = try await coordinator.startRecording(configuration: configuration)
            XCTAssertEqual(recording.audioStorageMode, .memoryOnly)
            XCTAssertEqual(recording.speakerLabelsEnabled, true)
            XCTAssertEqual(recording.piiRedactionEnabled, true)
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            XCTAssertTrue(player.play())
            let captureStart = ProcessInfo.processInfo.systemUptime
            var previousResourceTime = captureStart
            var previousCPU = DiagnosticProcessCPUTime.capture()
            var previousObservationTime = captureStart
            print("[PHYSICAL_STRICT_E2E] speech_started model=\(model.rawValue) duration=\(duration)")
            while ProcessInfo.processInfo.systemUptime - captureStart < Double(duration) {
                // Do not backfill observations after a delayed MainActor resume.
                let remaining = max(0, Double(duration) - (ProcessInfo.processInfo.systemUptime - captureStart))
                try await Task.sleep(nanoseconds: UInt64(min(1, remaining) * 1_000_000_000))
                let now = ProcessInfo.processInfo.systemUptime
                let elapsed = now - captureStart
                let second = Int(elapsed.rounded(.down))
                guard coordinator.isRecording else {
                    XCTFail("Strict \(model.rawValue) stopped at second \(second), before completing paced input")
                    throw MeetingMemoryAudioError.overload
                }
                let snapshot = coordinator.liveTranscript
                let pending = coordinator.pendingSpeech
                largestPendingCount = max(largestPendingCount, pending.tokens.count)
                if !pending.tokens.isEmpty { firstPendingSecond = firstPendingSecond ?? second }
                XCTAssertLessThanOrEqual(pending.tokens.count, 64)
                let isBackground = UIApplication.shared.applicationState == .background
                let observationInterval = now - previousObservationTime
                let adjacentBackgroundObservation = isBackground && wasBackground && observationInterval <= 2
                // Only credit adjacent background observations at the expected cadence.
                // A long scheduling gap provides no evidence about the intervening state.
                if adjacentBackgroundObservation {
                    backgroundSeconds += min(observationInterval, 1.25)
                }
                let ids = Set(snapshot.utterances.filter { !$0.text.isEmpty }.map(\.id))
                if !ids.isEmpty || snapshot.partials.values.contains(where: { !$0.text.isEmpty }) {
                    firstTextSecond = firstTextSecond ?? Int(elapsed.rounded(.up))
                }
                let partial = snapshot.partials[.you]
                if !ids.subtracting(previousIDs).isEmpty || (partial != nil && partial != previousPartial) {
                    updates += 1
                    protectedUpdateSeconds.append(elapsed)
                    lastUpdateSecond = second
                    if adjacentBackgroundObservation {
                        backgroundUpdates += 1
                        lastBackgroundUpdateSecond = second
                    }
                }
                previousIDs = ids
                previousPartial = partial
                wasBackground = isBackground
                previousObservationTime = now
                print("[PHYSICAL_STRICT_E2E] second=\(second) model=\(model.rawValue) utterances=\(ids.count) updates=\(updates) pendingAudio=\(pending.tokens.count) background=\(isBackground)")
                if now - previousResourceTime >= 15 {
                    let cpu = DiagnosticProcessCPUTime.capture()
                    let cpuMS = previousCPU.flatMap { earlier in cpu?.milliseconds(since: earlier) } ?? -1
                    let wallMS = Int64((now - previousResourceTime) * 1_000)
                    print("[PHYSICAL_STRICT_RESOURCE] second=\(second) cpuMS=\(cpuMS) wallMS=\(wallMS) footprintBytes=\(physicalFootprintBytes() ?? 0)")
                    previousCPU = cpu
                    previousResourceTime = now
                }
            }
            let capturedSeconds = ProcessInfo.processInfo.systemUptime - captureStart
            player.stop()
            XCTAssertGreaterThanOrEqual(capturedSeconds, Double(duration))
            XCTAssertNotNil(firstPendingSecond, "Real accepted microphone audio must show capture progress before recognition completes")
            XCTAssertNotNil(firstTextSecond, "Filtered live speech must be visible before stopping")
            XCTAssertLessThanOrEqual(firstTextSecond ?? 61, 12, "Speech must appear before slower attribution completes")
            XCTAssertGreaterThanOrEqual(updates, 3, "Repeated capture must keep advancing after the original 35-second failure")
            XCTAssertGreaterThanOrEqual(lastUpdateSecond, duration - 15,
                                        "Protected text must keep advancing near the end, not only during the first window")
            if requiresBackground {
                XCTAssertGreaterThanOrEqual(backgroundSeconds, duration == 300 ? 280.0 : 20.0,
                                            "The host must actually leave the foreground during paced recording")
                XCTAssertGreaterThan(backgroundUpdates, 0, "Safe text must advance between actual background observations")
            }
            if duration == 300 {
                XCTAssertGreaterThanOrEqual(lastUpdateSecond, 280, "Protected text must still advance near the end of the five-minute capture")
                if requiresBackground { XCTAssertGreaterThanOrEqual(lastBackgroundUpdateSecond, 280) }
            }
            let completed = try await coordinator.stopAndTranscribe()
            XCTAssertTrue(coordinator.pendingSpeech.tokens.isEmpty, "Terminal teardown clears visual audio estimates")
            XCTAssertEqual(completed.state, .completed)
            XCTAssertFalse(completed.transcriptSegments.isEmpty)
            if twoVoiceFixture {
                XCTAssertGreaterThanOrEqual(completed.speakers.count, 2, "Two-voice stress input must actually exercise speaker identification")
            }
            XCTAssertFalse(completed.hasFinalizedAudio)
            XCTAssertTrue(completed.transcriptSegments.allSatisfy { $0.originalText == nil })
            let saved = try await store.load(id: completed.id)
            XCTAssertEqual(saved?.transcriptSegments, completed.transcriptSegments)
            // Opt-in replay evidence is retained privately in XCTest, never in
            // routine support logs. The export contains protected text only.
            let transcriptAttachment = XCTAttachment(data: try MeetingTranscriptExporter.json(for: completed),
                                                       uniformTypeIdentifier: "public.json")
            transcriptAttachment.name = "Physical-strict-protected-transcript-\(model.rawValue)"
            transcriptAttachment.lifetime = .keepAlways
            add(transcriptAttachment)
            let timingData = try JSONSerialization.data(withJSONObject: [
                "model": model.rawValue, "durationSeconds": capturedSeconds,
                "firstTextSecond": firstTextSecond ?? -1,
                "firstPendingSecond": firstPendingSecond ?? -1, "largestPendingCount": largestPendingCount,
                "protectedUpdateSeconds": protectedUpdateSeconds,
                "backgroundSeconds": backgroundSeconds
            ], options: [.prettyPrinted, .sortedKeys])
            let timingAttachment = XCTAttachment(data: timingData, uniformTypeIdentifier: "public.json")
            timingAttachment.name = "Physical-strict-protected-update-timing-\(model.rawValue)"
            timingAttachment.lifetime = .keepAlways
            add(timingAttachment)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                XCTAssertEqual(file.pathExtension, "json", "Strict capture must not create any audio file")
            }
            let payload = try MeetingSharePayload.transcript(data: MeetingTranscriptExporter.json(for: completed), title: completed.title, fileExtension: "json")
            XCTAssertFalse(payload.includesAudio)
            payload.cleanup()
            print("[PHYSICAL_STRICT_E2E] complete model=\(model.rawValue) duration=\(duration) capturedSeconds=\(capturedSeconds) firstTextSecond=\(firstTextSecond ?? -1) updates=\(updates) backgroundSeconds=\(backgroundSeconds) backgroundUpdates=\(backgroundUpdates) lastUpdateSecond=\(lastUpdateSecond) lastBackgroundUpdateSecond=\(lastBackgroundUpdateSecond)")
            // This is one service composition, not application termination. Stopping the
            // coordinator already joins capture/model work; terminating the shared model
            // residency here would invalidate later tests in this same hosted process.
            XCTAssertNil(services.asr.activeExclusiveActivity)
            XCTAssertFalse(services.asr.hasActiveModelPreparation)
            await coordinator.shutdownForTermination()
            try await privacy.unload()
            try await addPrivatePrivacyDiagnostics(diagnostics, model: model)
        } catch {
            player.stop()
            await coordinator.shutdownForTermination()
            try? await privacy.unload()
            try await addPrivatePrivacyDiagnostics(diagnostics, model: model)
            throw error
        }
        #endif
    }

    private func addPrivatePrivacyDiagnostics(_ diagnostics: SyntheticPrivacyReplayDiagnostics?,
                                             model: SettingsStore.SpeechModel) async throws {
        guard let diagnostics else { return }
        let attachment = XCTAttachment(data: try await diagnostics.attachmentData(), uniformTypeIdentifier: "public.json")
        attachment.name = "Private-synthetic-privacy-observations-\(model.rawValue)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }

    func testPhysicalMicrophoneThroughLiveGigaAMPrivacyAndExport() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an explicitly enabled physical microphone and speaker test")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_PHYSICAL_MEETING_E2E"] == "1" else {
            throw XCTSkip("Explicitly enable physical meeting recording with public synthetic speech playback")
        }
        guard AVAudioSession.sharedInstance().outputVolume > 0.05 else {
            throw XCTSkip("Physical speech replay requires audible iPad output volume")
        }
        let assets = try MobileInferenceTestAssets.resolve()
        let name = "PhysicalMeetingE2E.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .gigaam
        settings.meetingSaveAudio = true
        settings.meetingSpeakerLabelsEnabled = false
        settings.meetingPIIRedactionEnabled = true
        let store = MeetingSessionStore(rootDirectory: root)
        let privacy = PichiTranscriptPrivacyService(modelStore: .init(directory: assets.appendingPathComponent("models/privacy")))
        let services = AppServices(store: store, settings: settings, privacy: privacy)
        let player = try AVAudioPlayer(contentsOf: assets.appendingPathComponent("audio/ru.wav"))
        player.numberOfLoops = 1
        var backgroundObserved = false
        var backgroundTextUpdates = 0
        do {
            let configuration = try await services.meetingSessionCoordinator.defaultConfiguration(mode: .inRoom, title: "Physical synthetic speech")
            let recording = try await services.meetingSessionCoordinator.startRecording(configuration: configuration)
            XCTAssertEqual(recording.audioStorageMode, .retainedFiles)
            let readyDeadline = ProcessInfo.processInfo.systemUptime + 20
            while services.meetingSessionCoordinator.liveTranscript.availability != .available,
                  ProcessInfo.processInfo.systemUptime < readyDeadline {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertEqual(services.meetingSessionCoordinator.liveTranscript.availability, .available)
            // Test-only audible fixture replay. The real selected microphone receives it;
            // there is no injected PCM or microphone implementation in this composition.
            try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
            XCTAssertTrue(player.play())
            print("[PHYSICAL_MEETING_E2E] synthetic_speech_started")
            var previousSnapshot = services.meetingSessionCoordinator.liveTranscript
            var previousBackground = false
            for _ in 0..<25 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                let isBackground = UIApplication.shared.applicationState == .background
                let snapshot = services.meetingSessionCoordinator.liveTranscript
                let previousIDs = Set(previousSnapshot.utterances.map(\.id))
                let newSpeech = snapshot.utterances.contains { !previousIDs.contains($0.id) && !$0.text.isEmpty }
                if isBackground, previousBackground, snapshot.revision > previousSnapshot.revision, newSpeech {
                    backgroundTextUpdates += 1
                }
                previousSnapshot = snapshot
                previousBackground = isBackground
                backgroundObserved = backgroundObserved || isBackground
            }
            player.stop()
            let live = services.meetingSessionCoordinator.liveTranscript
            XCTAssertFalse(live.utterances.isEmpty && live.partials.values.allSatisfy { $0.text.isEmpty }, "Actual microphone speech must appear before recording stops")
            if ProcessInfo.processInfo.environment["PICHI_PHYSICAL_MEETING_BACKGROUND"] == "1" {
                XCTAssertTrue(backgroundObserved, "The host app must actually enter the background during speech recognition")
                XCTAssertGreaterThan(backgroundTextUpdates, 0, "A new nonempty filtered utterance must be committed between actual background observations")
            }
            let completed = try await services.meetingSessionCoordinator.stopAndTranscribe()
            XCTAssertEqual(completed.state, .completed)
            XCTAssertFalse(completed.transcriptSegments.isEmpty)
            XCTAssertTrue(completed.hasFinalizedAudio)
            XCTAssertTrue(completed.transcriptSegments.allSatisfy { $0.originalText == nil })
            let saved = try await store.load(id: completed.id)
            XCTAssertEqual(saved?.transcriptSegments, completed.transcriptSegments)
            let payload = try MeetingSharePayload.transcript(data: MeetingTranscriptExporter.json(for: completed), title: completed.title, fileExtension: "json")
            payload.cleanup()
            // Disposing one test composition must not terminate the process-shared
            // model residency used by subsequent physical meeting probes.
            XCTAssertNil(services.asr.activeExclusiveActivity)
            XCTAssertFalse(services.asr.hasActiveModelPreparation)
            await services.meetingSessionCoordinator.shutdownForTermination()
            try await privacy.unload()
        } catch {
            player.stop()
            await services.meetingSessionCoordinator.shutdownForTermination()
            try? await privacy.unload()
            throw error
        }
        #endif
    }

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
            XCTAssertNil(services.asr.activeExclusiveActivity)
            XCTAssertFalse(services.asr.hasActiveModelPreparation)
            await services.meetingSessionCoordinator.shutdownForTermination()
            try await services.transcriptPrivacy.unload()
        } catch {
            await services.meetingSessionCoordinator.shutdownForTermination()
            try? await services.transcriptPrivacy.unload()
            throw error
        }
    }
}
