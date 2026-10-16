@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Darwin
import UIKit
@testable import PichiVoiceMobile
import XCTest

/// Explicitly enabled synthetic replay evidence belongs only to a private XCTest
/// attachment. Support logs, the app store and export paths never receive it.
@MainActor
private final class SyntheticPrivacyReplayDiagnostics: TranscriptTextRedacting {
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

/// The manifest stays in the opt-in asset directory. Human-reviewed reference turns
/// and aliases are never copied to a routine log or the application's persistent store.
private struct CombinedMeetingReference: Decodable {
    struct Turn: Decodable {
        let start: Double
        let end: Double
        let speaker: Int
    }
    let provenance: String // synthetic, human-reviewed, or explicitly weak Fathom metadata
    let turns: [Turn]     // non-overlapping speech intervals, fixture-relative seconds
    let sensitiveAliases: [[String]] // each row describes one entity's ASR spellings
    let textAnchors: [String] // reviewed non-sensitive words that privacy must preserve

    func validate(duration: Double) throws {
        guard ["synthetic", "human-reviewed", "weak-fathom"].contains(provenance),
              turns.count >= 2, turns.count <= 512,
              Set(turns.map(\.speaker)).count >= 2, Set(turns.map(\.speaker)).count <= 6,
              textAnchors.count >= 2, textAnchors.count <= 32,
              textAnchors.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 128 }),
              !sensitiveAliases.isEmpty, sensitiveAliases.count <= 64,
              sensitiveAliases.allSatisfy({ !$0.isEmpty && $0.count <= 16 && $0.allSatisfy {
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 256
              } }) else { throw NSError(domain: "InvalidCombinedMeetingReference", code: 1) }
        var previousEnd = 0.0
        for turn in turns {
            guard turn.start.isFinite, turn.end.isFinite, turn.start >= previousEnd,
                  turn.end > turn.start, turn.end <= duration else {
                throw NSError(domain: "InvalidCombinedMeetingReference", code: 2)
            }
            previousEnd = turn.end
        }
    }

    /// Segment-time agreement after a global one-to-one label permutation. Missing,
    /// unknown, and duplicate-overlap predictions count against reference duration.
    /// This is transcript attribution agreement, not acoustic DER or word accuracy.
    func agreement(segments: [MeetingTranscriptSegment]) -> Double {
        let speakers = Array(Set(turns.map(\.speaker))).sorted()
        let predicted = Array(Set(segments.compactMap(\.speakerID)))
        guard predicted.count <= 8 else { return 0 }
        let total = turns.reduce(0) { $0 + $1.end - $1.start }
        var weights = Array(repeating: Array(repeating: 0.0, count: predicted.count), count: speakers.count)
        // A small fixed grid prevents duplicate segments from earning double credit.
        for turn in turns {
            var time = turn.start
            while time < turn.end {
                let width = min(0.1, turn.end - time)
                let midpoint = time + width / 2
                let candidates = segments.filter { !$0.text.isEmpty && $0.start.seconds <= midpoint && $0.end.seconds > midpoint }
                if candidates.count == 1, let speaker = candidates[0].speakerID,
                   let row = speakers.firstIndex(of: turn.speaker), let column = predicted.firstIndex(of: speaker) {
                    weights[row][column] += width
                }
                time += width
            }
        }
        func best(_ row: Int, _ used: Set<Int>) -> Double {
            guard row < weights.count else { return 0 }
            var result = best(row + 1, used) // reference speaker may have no prediction
            for column in predicted.indices where !used.contains(column) {
                result = max(result, weights[row][column] + best(row + 1, used.union([column])))
            }
            return result
        }
        return total > 0 ? best(0, []) / total : 0
    }
}

/// Records counts only. Absence from actual ASR is an unobserved case, never a
/// successful removal. Inference and every returned span still come from production.
@MainActor
private final class CombinedPrivacyObservations: TranscriptTextRedacting {
    let wrapped: any TranscriptTextRedacting
    let aliases: [[String]]
    private(set) var observed: Set<Int> = []
    private(set) var fullyMasked: Set<Int> = []
    private(set) var unmaskedPublishableObservations = 0
    init(wrapping wrapped: any TranscriptTextRedacting, aliases: [[String]]) {
        self.wrapped = wrapped; self.aliases = aliases
    }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let result = try await wrapped.redactWithSpans(text)
        let source = text as NSString
        for (index, alternatives) in aliases.enumerated() {
            for alias in alternatives {
                var search = NSRange(location: 0, length: source.length)
                while search.length > 0 {
                    let range = source.range(of: alias, options: [.caseInsensitive], range: search)
                    guard range.location != NSNotFound else { break }
                    observed.insert(index)
                    var cursor = 0
                    var sensitive: [NSRange] = []
                    for character in text {
                        let length = String(character).utf16.count
                        let charRange = NSRange(location: cursor, length: length)
                        if NSIntersectionRange(charRange, range).length > 0,
                           character.isLetter || character.isNumber { sensitive.append(charRange) }
                        cursor += length
                    }
                    let fullyCovered = !sensitive.isEmpty && sensitive.allSatisfy({ character in
                        result.spans.contains { NSIntersectionRange($0.range, character).length == character.length }
                    })
                    if fullyCovered { fullyMasked.insert(index) }
                    if !fullyCovered && NSMaxRange(range) <= (result.provisionalSafeUTF16 ?? source.length) {
                        unmaskedPublishableObservations += 1
                    }
                    let end = NSMaxRange(range)
                    search = NSRange(location: end, length: source.length - end)
                }
            }
        }
        return result
    }
    func remainingCases(in text: String) -> Int {
        aliases.filter { alternatives in alternatives.contains { text.range(of: $0, options: [.caseInsensitive]) != nil } }.count
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
    func deliver(_ samples: [Float], startingAt sampleOffset: Int = 0) throws {
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
                presentationTime: CMTime(value: Int64(sampleOffset + start), timescale: 16_000))
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
    /// No audio, preparation, or model downloads occur without this separate gate.
    /// PCM injection measures the actual shared inference composition. It does not
    /// claim microphone, background execution, power, or acoustic capture validation.
    func testCombinedRussianMeetingPrivacySpeakersAndFootprint() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_COMBINED_MEETING_E2E"] == "1" else {
            throw XCTSkip("Explicitly enable combined Russian fixture inference")
        }
        let assets = try MobileInferenceTestAssets.resolve()
        let referenceURL = assets.appendingPathComponent("audio/combined-ru-reference.json")
        guard (try referenceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 131_072 else {
            throw NSError(domain: "CombinedMeetingReferenceSize", code: 1)
        }
        let referenceData = try Data(contentsOf: referenceURL)
        let reference = try JSONDecoder().decode(CombinedMeetingReference.self, from: referenceData)
        let audioURL = assets.appendingPathComponent("audio/combined-ru.wav")
        guard (try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1_048_576 else {
            throw NSError(domain: "CombinedMeetingAudioSize", code: 1)
        }
        let audioFile = try FileHandle(forReadingFrom: audioURL)
        defer { try? audioFile.close() }
        var audioHasher = SHA256()
        while let chunk = try audioFile.read(upToCount: 65_536), !chunk.isEmpty { audioHasher.update(data: chunk) }
        let audioDigest = audioHasher.finalize().map { String(format: "%02x", $0) }.joined()
        let referenceDigest = SHA256.hash(data: referenceData).map { String(format: "%02x", $0) }.joined()
        let input = try AVAudioFile(forReading: audioURL)
        guard input.processingFormat.sampleRate == 16_000, input.processingFormat.channelCount == 1,
              input.length >= 160_000, input.length <= 9_600_000 else {
            throw NSError(domain: "CombinedMeetingPCMFormatOrDuration", code: 1)
        }
        let duration = Double(input.length) / 16_000
        try reference.validate(duration: duration)
        let baseline = try XCTUnwrap(physicalFootprintBytes())
        let name = "CombinedMeetingProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny // preserve the deployed iPad engine
        settings.meetingRecordingDefaults.languageCode = "ru"
        settings.meetingSaveAudio = false
        settings.meetingSpeakerLabelsEnabled = true
        settings.meetingPIIRedactionEnabled = true
        let store = MeetingSessionStore(rootDirectory: root)
        let privacy = PichiTranscriptPrivacyService(modelStore: .init(directory: assets.appendingPathComponent("models/privacy")))
        let observations = CombinedPrivacyObservations(wrapping: privacy, aliases: reference.sensitiveAliases)
        let microphone = SyntheticMeetingMicrophone()
        let services = AppServices(store: store, capture: microphone, settings: settings,
            privacy: privacy, privacyRedactor: observations,
            microphoneResolver: { _ in .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone") })
        await microphone.setFactory { session, _, track, events in
            try await services.meetingProcessingPipeline.memoryConsumer(for: session.id, track: track, eventHandler: events)
        }
        let coordinator = services.meetingSessionCoordinator
        var phase = "preparation"
        let started = ProcessInfo.processInfo.systemUptime
        var samples: [[String: Any]] = []
        var missingFootprintSamples = 0
        var omittedFootprintSamples = 0
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let bytes = self.physicalFootprintBytes() {
                    if samples.count < 10_000 {
                        samples.append(["phase": phase, "elapsedSeconds": ProcessInfo.processInfo.systemUptime - started,
                                        "footprintBytes": bytes])
                    } else { omittedFootprintSamples += 1 }
                } else { missingFootprintSamples += 1 }
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
            }
        }
        defer { sampler.cancel() }
        do {
            // The same service operation used by Settings, with pinned artifacts.
            try await services.asr.downloadModel(.whisperTiny)
            let configuration = try await coordinator.defaultConfiguration(mode: .inRoom, title: "Combined Russian probe")
            let privacyReady = await privacy.isReady
            XCTAssertTrue(privacyReady)
            XCTAssertEqual(PichiTranscriptPrivacyModelStore.descriptor.id, "ru-pii-ner-a1-int8", "Combined evidence requires the A1 descriptor verified and loaded by privacy.prepare")
            phase = "privacyReady"
            try await Task.sleep(nanoseconds: 300_000_000)
            let recording = try await coordinator.startRecording(configuration: configuration)
            XCTAssertEqual(recording.audioStorageMode, .memoryOnly)
            XCTAssertEqual(recording.piiRedactionEnabled, true)
            phase = "capture"
            let captureStart = ProcessInfo.processInfo.systemUptime
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1_600))
            var offset = 0
            // Bounded file reads and real-time delivery preserve backpressure. No
            // whole-meeting PCM array or unbounded synthetic enqueue burst is used.
            while offset < Int(input.length) {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(1_600, Int(input.length) - offset)))
                guard buffer.frameLength > 0 else { throw NSError(domain: "CombinedMeetingPrematureEOF", code: 1) }
                let pcm = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
                try await microphone.deliver(pcm, startingAt: offset)
                offset += pcm.count
                XCTAssertTrue(coordinator.isRecording, "Capture must remain active for the complete fixture")
                let remaining = captureStart + Double(offset) / 16_000 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            phase = "postStop"
            let stopStart = ProcessInfo.processInfo.systemUptime
            let completed = try await coordinator.stopAndTranscribe()
            let stopSeconds = ProcessInfo.processInfo.systemUptime - stopStart
            phase = "completedPrivacyReady"
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(completed.state, .completed)
            let diarizationModels = completed.processingAttempts.compactMap(\.diarizationModel)
            let expectedDiarization = "Nemotron3-fast32-split-w8a8@82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8;model=25a90f97f254428d4b30374b76af9c74fdee8327;weight=99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed;config=32-4-40-264"
            XCTAssertFalse(diarizationModels.isEmpty, "The completed attempt must record its actual frozen diarizer lineage")
            XCTAssertTrue(diarizationModels.allSatisfy { $0.hasPrefix(expectedDiarization) }, "Combined evidence requires fast32 W8A8, including its pinned runtime and weight identity")
            XCTAssertTrue(completed.processingAttempts.contains { $0.asrModel == SettingsStore.SpeechModel.whisperTiny.rawValue })
            XCTAssertFalse(completed.transcriptSegments.isEmpty, "Actual ASR must produce final protected text")
            XCTAssertTrue(completed.transcriptSegments.contains { $0.text.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil },
                          "Actual ASR must produce Russian text")
            XCTAssertFalse(completed.hasFinalizedAudio)
            XCTAssertTrue(completed.transcriptSegments.allSatisfy { $0.originalText == nil })
            let protectedText = completed.transcriptSegments.map(\.text).joined(separator: " ")
            let matchedAnchors = reference.textAnchors.filter { protectedText.range(of: $0, options: [.caseInsensitive]) != nil }.count
            let agreement = reference.agreement(segments: completed.transcriptSegments)
            let assertsReferenceQuality = reference.provenance != "weak-fathom"
            if assertsReferenceQuality {
                XCTAssertEqual(matchedAnchors, reference.textAnchors.count, "Reviewed Russian ASR anchors must survive recognition and privacy")
                XCTAssertGreaterThanOrEqual(agreement, 0.8, "Reference speaker-time assignment must agree after global label permutation; speaker count alone is insufficient")
                XCTAssertEqual(observations.observed.count, reference.sensitiveAliases.count,
                               "Unrecognized source PII is unscored, not successfully redacted; provide approved ASR aliases or review fixture recognition")
                XCTAssertEqual(observations.fullyMasked.count, reference.sensitiveAliases.count,
                               "Every expected source entity needs actual fully covering privacy spans")
            } else {
                XCTAssertGreaterThan(matchedAnchors, 0, "Weak diagnostics still require recognized source anchors; unmatched anchors remain reported")
            }
            XCTAssertEqual(observations.unmaskedPublishableObservations, 0, "Recognized expected PII must never pass the privacy publication boundary unmasked")
            XCTAssertEqual(observations.remainingCases(in: protectedText), 0, "Protected output must contain none of the expected source aliases")
            let saved = try await store.load(id: completed.id)
            XCTAssertTrue(saved?.transcriptSegments == completed.transcriptSegments, "Reloaded protected segments must match without logging their contents")
            let export = try MeetingTranscriptExporter.json(for: completed)
            XCTAssertEqual(observations.remainingCases(in: String(decoding: export, as: UTF8.self)), 0)
            let payload = try MeetingSharePayload.transcript(data: export, title: completed.title, fileExtension: "json")
            defer { payload.cleanup() }
            XCTAssertFalse(payload.includesAudio)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                XCTAssertEqual(file.pathExtension, "json", "Strict storage may persist protected JSON only")
            }
            XCTAssertTrue(coordinator.pendingSpeech.tokens.isEmpty)
            XCTAssertNil(services.asr.activeExclusiveActivity)
            XCTAssertFalse(services.asr.hasActiveModelPreparation)
            XCTAssertFalse(services.asr.hasActiveModelDownload)
            await coordinator.shutdownForTermination()
            try await privacy.unload()
            let privacyStillReady = await privacy.isReady
            XCTAssertFalse(privacyStillReady)
            phase = "cleanup"
            try await Task.sleep(nanoseconds: 500_000_000)
            sampler.cancel()
            await sampler.value
            let peak = samples.compactMap { $0["footprintBytes"] as? UInt64 }.max() ?? baseline
            if let limit = environment["PICHI_COMBINED_MEETING_MAX_FOOTPRINT_MIB"] {
                let maximum = try XCTUnwrap(UInt64(limit))
                XCTAssertLessThanOrEqual(Double(peak) / 1_048_576, Double(maximum), "Whole-process sampled peak exceeds the explicitly configured budget")
            }
            XCTAssertEqual(missingFootprintSamples, 0)
            XCTAssertEqual(omittedFootprintSamples, 0, "A bounded diagnostic buffer must cover the entire completed attempt")
            let report: [String: Any] = [
                "schema": 1, "physicalDevice": !Self.isSimulator, "referenceProvenance": reference.provenance,
                "strongReferenceQualityAssertionsApplied": assertsReferenceQuality,
                "audioSHA256": audioDigest, "referenceSHA256": referenceDigest,
                "testedRevision": environment["PICHI_COMBINED_MEETING_TESTED_REVISION"] ?? "unrecorded",
                "asr": SettingsStore.SpeechModel.whisperTiny.rawValue,
                "privacyModel": PichiTranscriptPrivacyModelStore.descriptor.id,
                "diarizationModels": diarizationModels,
                "audioSeconds": duration, "postStopSeconds": stopSeconds,
                "baselineFootprintBytes": baseline, "peakFootprintBytes": peak,
                "cleanupFootprintDeltaBytes": Int64(physicalFootprintBytes() ?? baseline) - Int64(baseline),
                "sampleIntervalSeconds": 0.25, "footprintSamples": samples, "omittedFootprintSamples": omittedFootprintSamples,
                "attributionAgreement": agreement, "referenceTurns": reference.turns.count,
                "expectedSensitiveCases": reference.sensitiveAliases.count,
                "observedSensitiveCases": observations.observed.count,
                "fullyMaskedSensitiveCases": observations.fullyMasked.count,
                "unmaskedPublishableObservations": observations.unmaskedPublishableObservations,
                "matchedTextAnchors": matchedAnchors, "expectedTextAnchors": reference.textAnchors.count,
                "unscoredSensitiveCases": reference.sensitiveAliases.count - observations.observed.count,
                "limitations": "Sampled process footprint, not system-wide peak. Transcript attribution agreement is not DER. PCM injection excludes microphone, background and power validation. Idle ASR caches may remain resident."
            ]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Combined-Russian-meeting-metadata-only"
            attachment.lifetime = .keepAlways
            add(attachment)
        } catch {
            await coordinator.shutdownForTermination()
            try? await privacy.unload()
            sampler.cancel()
            await sampler.value
            let failed = try JSONSerialization.data(withJSONObject: ["phase": phase, "footprintSamples": samples], options: [.sortedKeys])
            let attachment = XCTAttachment(data: failed, uniformTypeIdentifier: "public.json")
            attachment.name = "Combined-Russian-meeting-failure-resource-samples"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    func testCombinedSpeakerAgreementRequiresCorrectAssignments() throws {
        let reference = CombinedMeetingReference(provenance: "synthetic", turns: [
            .init(start: 0, end: 1, speaker: 0), .init(start: 1, end: 2, speaker: 1)
        ], sensitiveAliases: [["Synthetic123!"]], textAnchors: ["слово", "пример"])
        try reference.validate(duration: 2)
        let first = UUID(), second = UUID(), track = UUID()
        func segment(_ start: Int64, _ end: Int64, _ speaker: UUID?) -> MeetingTranscriptSegment {
            .init(id: UUID(), start: .init(value: start, timescale: 1), end: .init(value: end, timescale: 1),
                  sourceTrackID: track, speakerID: speaker, text: "Synthetic", revision: 1,
                  status: .final, overlap: .none, completeness: .complete)
        }
        let correct = [segment(0, 1, second), segment(1, 2, first)]
        XCTAssertEqual(reference.agreement(segments: correct), 1, accuracy: 0.00001)
        XCTAssertEqual(reference.agreement(segments: []), 0)
        XCTAssertEqual(reference.agreement(segments: [segment(0, 1, first), segment(1, 2, first)]), 0.5, accuracy: 0.00001)
        XCTAssertEqual(reference.agreement(segments: correct + [correct[0]]), 0.5, accuracy: 0.00001)
        XCTAssertEqual(reference.agreement(segments: [segment(0, 2, nil)]), 0)
    }

    func testCombinedPrivacyEvidenceNeverCreditsMissingASR() async throws {
        let observations = CombinedPrivacyObservations(wrapping: SyntheticDiagnosticEchoRedactor(), aliases: [["Секрет123!"]])
        _ = try await observations.redactWithSpans("Обычные русские слова")
        XCTAssertEqual(observations.observed.count, 0)
        XCTAssertEqual(observations.fullyMasked.count, 0)
        _ = try await observations.redactWithSpans("Пароль Секрет123!")
        XCTAssertEqual(observations.observed.count, 1)
        XCTAssertEqual(observations.fullyMasked.count, 0, "Source absence from output alone must not establish a privacy span")
    }

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
