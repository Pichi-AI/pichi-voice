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

    private enum CodingKeys: String, CodingKey { case provenance, turns, sensitiveAliases, textAnchors }
    init(provenance: String, turns: [Turn], sensitiveAliases: [[String]], textAnchors: [String]) {
        self.provenance = provenance; self.turns = turns
        self.sensitiveAliases = sensitiveAliases; self.textAnchors = textAnchors
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(provenance: try values.decode(String.self, forKey: .provenance),
                  turns: try values.decode([Turn].self, forKey: .turns),
                  sensitiveAliases: try values.decodeIfPresent([[String]].self, forKey: .sensitiveAliases) ?? [],
                  textAnchors: try values.decodeIfPresent([String].self, forKey: .textAnchors) ?? [])
    }
    var containsOverlap: Bool {
        var end = 0.0
        for turn in turns.sorted(by: { $0.start < $1.start }) {
            if turn.start < end { return true }
            end = max(end, turn.end)
        }
        return false
    }
    func validate(duration: Double, privateEvaluation: Bool = false) throws {
        guard ["synthetic", "human-reviewed", "weak-fathom"].contains(provenance),
              duration.isFinite, duration > 0,
              turns.count >= (privateEvaluation ? 1 : 2), turns.count <= 512,
              Set(turns.map(\.speaker)).count >= (privateEvaluation ? 1 : 2),
              Set(turns.map(\.speaker)).count <= (privateEvaluation ? 8 : 6),
              textAnchors.count >= (privateEvaluation ? 0 : 2), textAnchors.count <= 32,
              textAnchors.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 128 }),
              (privateEvaluation || !sensitiveAliases.isEmpty), sensitiveAliases.count <= 64,
              sensitiveAliases.allSatisfy({ !$0.isEmpty && $0.count <= 16 && $0.allSatisfy {
                  !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf16.count <= 256
              } }) else { throw NSError(domain: "InvalidCombinedMeetingReference", code: 1) }
        var previousEnd = 0.0
        for turn in turns {
            guard turn.start.isFinite, turn.end.isFinite, turn.start >= 0,
                  (privateEvaluation || turn.start >= previousEnd),
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

/// Private controls are separate from the legacy simulator visual-review gate.
private nonisolated struct CombinedEvaluationOptions {
    let privateEvaluation: Bool
    let repetitions: Int
    let longEvaluation: Bool
    var maximumDurationSeconds: Double { longEvaluation ? 3_900 : 600 }
    var maximumAudioBytes: Int { (longEvaluation ? 128 : 64) * 1_048_576 }
    var maximumProtectedEvidenceBytes: Int { (longEvaluation ? 64 : 16) * 1_048_576 }
    var sampleIntervalSeconds: Double { longEvaluation ? 1 : 0.25 }
    var maximumSamples: Int { longEvaluation ? 12_000 : 10_000 }

    func validatePCM(frameCount: Int64, fileBytes: Int) throws {
        guard frameCount >= 160_000, frameCount <= Int64(maximumDurationSeconds * 16_000),
              fileBytes >= 0, fileBytes <= maximumAudioBytes else {
            throw NSError(domain: "CombinedMeetingPCMFormatOrDuration", code: 1)
        }
    }
    init(environment: [String: String]) throws {
        privateEvaluation = environment["PICHI_COMBINED_MEETING_PRIVATE_EVALUATION"] == "1"
        guard let count = Int(environment["PICHI_COMBINED_MEETING_REPETITIONS"] ?? "1"),
              (1...3).contains(count), privateEvaluation || count == 1 else {
            throw NSError(domain: "CombinedMeetingEvaluationOptions", code: 1)
        }
        repetitions = count
        longEvaluation = environment["PICHI_COMBINED_MEETING_LONG_EVALUATION"] == "1"
        guard !longEvaluation || (privateEvaluation && count == 1) else {
            throw NSError(domain: "CombinedMeetingEvaluationOptions", code: 2)
        }
    }
}

/// Reads the process counter off MainActor. The caller owns and joins its sampling Task.
private nonisolated final class CombinedResourceSamples: @unchecked Sendable {
    struct Sample: Sendable {
        let phase: String
        let elapsed: Double
        let bytes: UInt64
        let thermalState: Int
        var json: [String: Any] {
            ["phase": phase, "elapsedSeconds": elapsed, "footprintBytes": bytes, "thermalState": thermalState]
        }
    }
    struct Snapshot: Sendable {
        let samples: [Sample]
        let missing: Int
        let omitted: Int
        let maximumGap: Double
        let missedIntervals: Int
        let maximumThermalState: Int
    }
    private let lock = NSLock()
    private let limit: Int
    let intervalSeconds: Double
    private var phase = "preparation"
    private var rows: [Sample] = []
    private var missing = 0
    private var omitted = 0
    private var previousElapsed: Double?
    private var maximumGap = 0.0
    private var missedIntervals = 0
    private var maximumThermalState = 0
    init(limit: Int = 10_000, intervalSeconds: Double = 0.25) throws {
        guard (1...12_000).contains(limit), intervalSeconds.isFinite,
              (0.05...60).contains(intervalSeconds) else {
            throw NSError(domain: "CombinedMeetingResourceSamplingOptions", code: 1)
        }
        self.limit = limit
        self.intervalSeconds = intervalSeconds
    }
    func setPhase(_ value: String) { lock.withLock { phase = value } }
    func capture(since started: Double) {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let bytes = Self.footprintBytes()
        record(elapsed: elapsed, bytes: bytes, thermalState: ProcessInfo.processInfo.thermalState.rawValue)
    }
    func record(elapsed: Double, bytes: UInt64?, thermalState: Int) {
        lock.withLock {
            if let previousElapsed {
                let gap = max(0, elapsed - previousElapsed)
                maximumGap = max(maximumGap, gap)
                missedIntervals += max(0, Int(min(Double(Int.max / 2), (gap / intervalSeconds).rounded(.down))) - 1)
            }
            previousElapsed = elapsed
            maximumThermalState = max(maximumThermalState, thermalState)
            guard let bytes else { missing += 1; return }
            guard rows.count < limit else { omitted += 1; return }
            rows.append(.init(phase: phase, elapsed: elapsed, bytes: bytes, thermalState: thermalState))
        }
    }
    func snapshot() -> Snapshot {
        lock.withLock { .init(samples: rows, missing: missing, omitted: omitted, maximumGap: maximumGap,
                             missedIntervals: missedIntervals, maximumThermalState: maximumThermalState) }
    }
    static func footprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// Flushes a fixed metadata schema directly to XCTest stdout, including while
/// post-stop inference occupies MainActor. No transcript or voice identity enters it.
private nonisolated final class CombinedLongProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let started: Double
    private var phase = "preparation"
    private var deliveredFrames = 0
    private var protectedUtterances = 0
    private var protectedPartials = 0
    private var protectedFinalSegments = 0
    private var lastEmission: Double?
    init(started: Double) { self.started = started }
    func update(phase: String, deliveredFrames: Int, protectedUtterances: Int,
                protectedPartials: Int, protectedFinalSegments: Int = 0) {
        lock.withLock {
            self.phase = phase
            self.deliveredFrames = deliveredFrames
            self.protectedUtterances = protectedUtterances
            self.protectedPartials = protectedPartials
            self.protectedFinalSegments = protectedFinalSegments
        }
    }
    func emit(force: Bool = false) {
        lock.withLock {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            guard force || lastEmission.map({ elapsed - $0 >= 60 }) ?? true else { return }
            lastEmission = elapsed
            let row: [String: Any] = ["event": "combinedMeetingLongProgress", "schema": 1,
                "phase": phase, "elapsedSeconds": elapsed, "deliveredFrames": deliveredFrames,
                "protectedUtteranceCount": protectedUtterances, "protectedPartialCount": protectedPartials,
                "protectedFinalSegmentCount": protectedFinalSegments,
                "footprintBytes": CombinedResourceSamples.footprintBytes() as Any? ?? NSNull(),
                "thermalState": ProcessInfo.processInfo.thermalState.rawValue]
            if var bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) {
                bytes.append(0x0A)
                // FileHandle writes do not depend on the C stdio buffering policy.
                try? FileHandle.standardOutput.write(contentsOf: bytes)
            }
        }
    }
}

/// Only post-privacy product values. No embeddings, contact identities, human names,
/// originalText or source audio are exported by this test helper.
private nonisolated enum CombinedProtectedEvaluation {
    static func values(segments: [MeetingTranscriptSegment], speakers: [MeetingSessionSpeaker]) throws -> [String: Any] {
        guard segments.count <= 100_000, speakers.count <= 512,
              segments.reduce(0, { $0 + $1.text.utf16.count }) <= 4_194_304 else {
            throw NSError(domain: "CombinedMeetingProtectedEvidenceSize", code: 1)
        }
        let encoder = JSONEncoder()
        let sanitized = segments.map { value in var copy = value; copy.originalText = nil; return copy }
        let rows: [[String: Any]] = speakers.enumerated().map { index, speaker in
            var row: [String: Any] = ["id": speaker.id.uuidString, "displayName": "Speaker \(index + 1)",
                                     "trackKind": speaker.trackKind.rawValue, "isLocalUser": speaker.isLocalUser]
            if let merged = speaker.mergedIntoSpeakerID { row["mergedIntoSpeakerID"] = merged.uuidString }
            return row
        }
        return ["segments": try JSONSerialization.jsonObject(with: encoder.encode(sanitized)), "speakers": rows]
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
        let options = try CombinedEvaluationOptions(environment: environment)
        // Same XCTest process, fresh service compositions. This does not prove warm residency.
        for repetition in 1...options.repetitions {
            try Task.checkCancellation()
            try await runCombinedRussianMeeting(environment: environment, options: options, repetition: repetition)
        }
    }

    private func runCombinedRussianMeeting(environment: [String: String], options: CombinedEvaluationOptions,
                                           repetition: Int) async throws {
        let asrModel = try XCTUnwrap(SettingsStore.SpeechModel(rawValue:
            environment["PICHI_COMBINED_MEETING_ASR"] ?? SettingsStore.SpeechModel.whisperTiny.rawValue),
            "An explicit ASR identifier must resolve without a model fallback")
        guard PichiMeetingProviderFactory.registeredBackendDescriptor(for: asrModel.rawValue) != nil else {
            throw NSError(domain: "CombinedMeetingUnsupportedASR", code: 1)
        }
        let assets = try MobileInferenceTestAssets.resolve()
        let referenceURL = assets.appendingPathComponent("audio/combined-ru-reference.json")
        guard (try referenceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 131_072 else {
            throw NSError(domain: "CombinedMeetingReferenceSize", code: 1)
        }
        let referenceData = try Data(contentsOf: referenceURL)
        let reference = try JSONDecoder().decode(CombinedMeetingReference.self, from: referenceData)
        let audioURL = assets.appendingPathComponent("audio/combined-ru.wav")
        let audioBytes = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard audioBytes <= options.maximumAudioBytes else {
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
              input.length >= 160_000 else {
            throw NSError(domain: "CombinedMeetingPCMFormatOrDuration", code: 1)
        }
        try options.validatePCM(frameCount: Int64(input.length), fileBytes: audioBytes)
        let duration = Double(input.length) / 16_000
        try reference.validate(duration: duration, privateEvaluation: options.privateEvaluation)
        let baseline = try XCTUnwrap(physicalFootprintBytes())
        let name = "CombinedMeetingProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = asrModel
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
        let processCPUStarted = DiagnosticProcessCPUTime.capture()
        let thermalStateStarted = ProcessInfo.processInfo.thermalState.rawValue
        let resourceSamples = try CombinedResourceSamples(limit: options.maximumSamples,
                                                         intervalSeconds: options.sampleIntervalSeconds)
        let progress = options.longEvaluation ? CombinedLongProgress(started: started) : nil
        progress?.emit(force: true)
        resourceSamples.capture(since: started)
        let sampler = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                resourceSamples.capture(since: started)
                progress?.emit()
                do { try await Task.sleep(nanoseconds: UInt64(resourceSamples.intervalSeconds * 1_000_000_000)) } catch { break }
            }
        }
        defer { sampler.cancel() }
        do {
            // The same service operation used by Settings, with pinned artifacts.
            try await services.asr.downloadModel(asrModel)
            let configuration = try await coordinator.defaultConfiguration(mode: .inRoom, title: "Combined Russian probe")
            let privacyReady = await privacy.isReady
            let preparationSeconds = ProcessInfo.processInfo.systemUptime - started
            XCTAssertTrue(privacyReady)
            XCTAssertEqual(PichiTranscriptPrivacyModelStore.descriptor.id, "ru-pii-ner-a1-int8", "Combined evidence requires the A1 descriptor verified and loaded by privacy.prepare")
            phase = "privacyReady"
            resourceSamples.setPhase(phase)
            try await Task.sleep(nanoseconds: 300_000_000)
            let recording = try await coordinator.startRecording(configuration: configuration)
            XCTAssertEqual(recording.audioStorageMode, .memoryOnly)
            XCTAssertEqual(recording.piiRedactionEnabled, true)
            phase = "capture"
            resourceSamples.setPhase(phase)
            let captureStart = ProcessInfo.processInfo.systemUptime
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1_600))
            var offset = 0
            var firstProtectedTextSeconds: Double?
            // Bounded file reads and real-time delivery preserve backpressure. No
            // whole-meeting PCM array or unbounded synthetic enqueue burst is used.
            while offset < Int(input.length) {
                try Task.checkCancellation()
                try input.read(into: buffer, frameCount: AVAudioFrameCount(min(1_600, Int(input.length) - offset)))
                guard buffer.frameLength > 0 else { throw NSError(domain: "CombinedMeetingPrematureEOF", code: 1) }
                let pcm = Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
                try await microphone.deliver(pcm, startingAt: offset)
                offset += pcm.count
                if firstProtectedTextSeconds == nil {
                    let live = coordinator.liveTranscript
                    if live.utterances.contains(where: { !$0.text.isEmpty }) || live.partials.values.contains(where: { !$0.text.isEmpty }) {
                        firstProtectedTextSeconds = ProcessInfo.processInfo.systemUptime - captureStart
                    }
                }
                if let progress {
                    let live = coordinator.liveTranscript
                    progress.update(phase: phase, deliveredFrames: offset,
                        protectedUtterances: live.utterances.count, protectedPartials: live.partials.count)
                }
                XCTAssertTrue(coordinator.isRecording, "Capture must remain active for the complete fixture")
                let remaining = captureStart + Double(offset) / 16_000 - ProcessInfo.processInfo.systemUptime
                if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
            }
            phase = "postStop"
            resourceSamples.setPhase(phase)
            progress?.update(phase: "postStopBegin", deliveredFrames: offset,
                protectedUtterances: coordinator.liveTranscript.utterances.count,
                protectedPartials: coordinator.liveTranscript.partials.count)
            progress?.emit(force: true)
            let stopStart = ProcessInfo.processInfo.systemUptime
            let completed = try await coordinator.stopAndTranscribe()
            let stopSeconds = ProcessInfo.processInfo.systemUptime - stopStart
            let completedWallSeconds = ProcessInfo.processInfo.systemUptime - started
            progress?.update(phase: "postStopEnd", deliveredFrames: offset,
                protectedUtterances: 0, protectedPartials: 0,
                protectedFinalSegments: completed.transcriptSegments.count)
            progress?.emit(force: true)
            phase = "completedPrivacyReady"
            resourceSamples.setPhase(phase)
            try await Task.sleep(nanoseconds: 300_000_000)
            XCTAssertEqual(completed.state, .completed)
            let diarizationModels = completed.processingAttempts.compactMap(\.diarizationModel)
            let expectedDiarization = "Nemotron3-fast32-split-w8a8@82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8;model=25a90f97f254428d4b30374b76af9c74fdee8327;weight=99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed;config=32-4-40-264"
            XCTAssertFalse(diarizationModels.isEmpty, "The completed attempt must record its actual frozen diarizer lineage")
            XCTAssertTrue(diarizationModels.allSatisfy { $0.hasPrefix(expectedDiarization) }, "Combined evidence requires fast32 W8A8, including its pinned runtime and weight identity")
            XCTAssertTrue(completed.processingAttempts.contains { $0.asrModel == asrModel.rawValue })
            XCTAssertTrue(completed.processingAttempts.allSatisfy { $0.asrModel == asrModel.rawValue },
                          "Every attempt must retain the selected ASR identity")
            XCTAssertFalse(completed.transcriptSegments.isEmpty, "Actual ASR must produce final protected text")
            XCTAssertTrue(completed.transcriptSegments.contains { $0.text.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil },
                          "Actual ASR must produce Russian text")
            XCTAssertFalse(completed.hasFinalizedAudio)
            XCTAssertTrue(completed.transcriptSegments.allSatisfy { $0.originalText == nil })
            let protectedText = completed.transcriptSegments.map(\.text).joined(separator: " ")
            let matchedAnchors = reference.textAnchors.filter { protectedText.range(of: $0, options: [.caseInsensitive]) != nil }.count
            let agreementAvailable = !reference.containsOverlap
            let agreement = agreementAvailable ? reference.agreement(segments: completed.transcriptSegments) : 0
            let assertsReferenceQuality = reference.provenance != "weak-fathom" && !options.privateEvaluation
            if assertsReferenceQuality {
                XCTAssertEqual(matchedAnchors, reference.textAnchors.count, "Reviewed Russian ASR anchors must survive recognition and privacy")
                XCTAssertGreaterThanOrEqual(agreement, 0.8, "Reference speaker-time assignment must agree after global label permutation; speaker count alone is insufficient")
                XCTAssertEqual(observations.observed.count, reference.sensitiveAliases.count,
                               "Unrecognized source PII is unscored, not successfully redacted; provide approved ASR aliases or review fixture recognition")
                XCTAssertEqual(observations.fullyMasked.count, reference.sensitiveAliases.count,
                               "Every expected source entity needs actual fully covering privacy spans")
            } else if !options.privateEvaluation {
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
            resourceSamples.setPhase(phase)
            try await Task.sleep(nanoseconds: 500_000_000)
            sampler.cancel()
            await sampler.value
            resourceSamples.capture(since: started)
            let resources = resourceSamples.snapshot()
            let peak = resources.samples.map(\.bytes).max() ?? baseline
            let totalWallSeconds = ProcessInfo.processInfo.systemUptime - started
            let cpuMilliseconds = processCPUStarted.flatMap { DiagnosticProcessCPUTime.capture()?.milliseconds(since: $0) }
            let policies = Array(Set(completed.transcriptSegments.compactMap { $0.speakerAttribution?.policyFingerprint })).sorted()
            let nativeWordCount = completed.transcriptSegments.filter { $0.nativePrecision == .word }.count
            let runIdentity: [String: Any] = [
                "runIndex": repetition, "repetitions": options.repetitions,
                "processID": ProcessInfo.processInfo.processIdentifier,
                "repeatCondition": repetition == 1 ? "firstRunFreshService" : "sameProcessFreshServiceRepeat",
                "modelResidencyVerified": false,
                "privateEvaluationEnabled": options.privateEvaluation,
                "longEvaluationEnabled": options.longEvaluation,
                "legacySimulatorReviewEnabled": Self.isSimulator && environment["PICHI_COMBINED_MEETING_EXPORT_PRIVATE_REVIEW"] == "1"
            ]
            if let limit = environment["PICHI_COMBINED_MEETING_MAX_FOOTPRINT_MIB"] {
                let maximum = try XCTUnwrap(UInt64(limit))
                XCTAssertLessThanOrEqual(Double(peak) / 1_048_576, Double(maximum), "Whole-process sampled peak exceeds the explicitly configured budget")
            }
            XCTAssertEqual(resources.missing, 0)
            XCTAssertEqual(resources.omitted, 0, "A bounded diagnostic buffer must cover the entire completed attempt")
            let report: [String: Any] = [
                "schema": 2, "physicalDevice": !Self.isSimulator, "referenceProvenance": reference.provenance,
                "strongReferenceQualityAssertionsApplied": assertsReferenceQuality,
                "audioSHA256": audioDigest, "referenceSHA256": referenceDigest,
                "testedRevision": environment["PICHI_COMBINED_MEETING_TESTED_REVISION"] ?? "unrecorded",
                "asr": asrModel.rawValue,
                "privacyModel": PichiTranscriptPrivacyModelStore.descriptor.id,
                "diarizationModels": diarizationModels,
                "audioSeconds": duration, "postStopSeconds": stopSeconds,
                "audioByteLimit": options.maximumAudioBytes,
                "protectedEvidenceByteLimit": options.maximumProtectedEvidenceBytes,
                "totalWallSeconds": totalWallSeconds, "completedWallSeconds": completedWallSeconds,
                "wallClockOrigin": "service composition ready, before model preparation; excludes fixture hashing",
                "totalWallIncludesDiagnosticHolds": true,
                "preparationSeconds": preparationSeconds, "captureWallSeconds": stopStart - captureStart,
                "postStopToAudioRatio": stopSeconds / duration,
                "processCPUMilliseconds": cpuMilliseconds as Any? ?? NSNull(),
                "firstProtectedTextSeconds": firstProtectedTextSeconds as Any? ?? NSNull(),
                "firstProtectedTextClock": "captureStart; polled after paced PCM blocks",
                "runIdentity": runIdentity,
                "asrArtifactFingerprints": completed.processingAttempts.compactMap(\.asrArtifactFingerprint),
                "pipelineVersions": Array(Set(completed.processingAttempts.map(\.pipelineVersion))).sorted(),
                "observedAttributionPolicyFingerprints": policies,
                "policyObservation": policies.isEmpty ? "no product decision fingerprint" : "protected product decisions",
                "nativeWordSegmentCount": nativeWordCount,
                "nativeTimingSegmentCount": completed.transcriptSegments.filter { $0.nativeTiming != nil }.count,
                "nativeSpeakerAssignmentSegmentCount": completed.transcriptSegments.filter { $0.nativeSpeakerAssignment != nil }.count,
                "presentationDecisionSegmentCount": completed.transcriptSegments.filter { $0.speakerAttribution != nil }.count,
                "deviceModel": UIDevice.current.model, "osVersion": UIDevice.current.systemVersion,
                "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
                "lowPowerModeEnabled": ProcessInfo.processInfo.isLowPowerModeEnabled,
                "batteryMonitoringEnabled": UIDevice.current.isBatteryMonitoringEnabled,
                "batteryLevel": UIDevice.current.batteryLevel, "batteryState": UIDevice.current.batteryState.rawValue,
                "thermalStateStart": thermalStateStarted, "thermalStateEnd": ProcessInfo.processInfo.thermalState.rawValue,
                "maximumSampledThermalState": resources.maximumThermalState,
                "baselineFootprintBytes": baseline, "peakFootprintBytes": peak,
                "cleanupFootprintDeltaBytes": Int64(physicalFootprintBytes() ?? baseline) - Int64(baseline),
                "sampleIntervalSeconds": resourceSamples.intervalSeconds,
                "sampleCapacity": options.maximumSamples, "footprintSamples": resources.samples.map(\.json),
                "omittedFootprintSamples": resources.omitted, "missingFootprintSamples": resources.missing,
                "maximumSampleGapSeconds": resources.maximumGap, "missedSampleIntervals": resources.missedIntervals,
                "attributionAgreement": agreementAvailable ? agreement as Any : NSNull(),
                "attributionAgreementAvailable": agreementAvailable,
                "attributionAgreementMetric": "Legacy single-speaker segment-time agreement after label permutation; not DER or word accuracy",
                "overlapReferenceMetric": reference.containsOverlap ? "unavailable; score native words offline" : "not present",
                "referenceSpeakerCount": Set(reference.turns.map(\.speaker)).count, "referenceTurns": reference.turns.count,
                "expectedSensitiveCases": reference.sensitiveAliases.count,
                "observedSensitiveCases": observations.observed.count,
                "fullyMaskedSensitiveCases": observations.fullyMasked.count,
                "unmaskedPublishableObservations": observations.unmaskedPublishableObservations,
                "matchedTextAnchors": matchedAnchors, "expectedTextAnchors": reference.textAnchors.count,
                "unscoredSensitiveCases": reference.sensitiveAliases.count - observations.observed.count,
                "limitations": "Sampled process footprint, not system-wide peak. Transcript attribution agreement is not DER. PCM injection excludes microphone, background and power validation. Idle ASR caches may remain resident."
            ]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "Combined-Russian-meeting-metadata-only" + (options.repetitions > 1 ? "-run-\(repetition)" : "")
            attachment.lifetime = .keepAlways
            add(attachment)
            // Physical private evaluation is separately gated. Legacy visual review
            // retains its simulator-only meaning; neither exports pre-privacy text.
            if options.privateEvaluation || (Self.isSimulator && environment["PICHI_COMBINED_MEETING_EXPORT_PRIVATE_REVIEW"] == "1") {
                var visualReview: [String: Any] = [
                    "schema": 2, "physicalDevice": !Self.isSimulator,
                    "purpose": options.privateEvaluation ? "Private protected evaluation from this actual run" : "Fresh simulator private visual review",
                    "runIdentity": runIdentity,
                    "observedAttributionPolicyFingerprints": policies,
                    "nativeWordSegmentCount": nativeWordCount,
                    "testedRevision": environment["PICHI_COMBINED_MEETING_TESTED_REVISION"] ?? "unrecorded",
                    "audioSHA256": audioDigest, "referenceSHA256": referenceDigest,
                    "asr": asrModel.rawValue, "privacyModel": PichiTranscriptPrivacyModelStore.descriptor.id,
                    "diarizationModels": diarizationModels, "audioSeconds": duration,
                    "attributionAgreement": agreementAvailable ? agreement as Any : NSNull(),
                    "attributionAgreementAvailable": agreementAvailable,
                    "referenceContainsOverlap": reference.containsOverlap,
                    "asrArtifactFingerprints": completed.processingAttempts.compactMap(\.asrArtifactFingerprint),
                    "limitations": "Post-privacy product values only; metadata may be absent or privacy-coarsened. No invented word timings, audio, embeddings, contact identities or source-separated overlap words. WER/CER and overlap scoring require offline reference."
                ]
                visualReview.merge(try CombinedProtectedEvaluation.values(segments: completed.transcriptSegments, speakers: completed.speakers)) { _, new in new }
                let reviewData = try JSONSerialization.data(withJSONObject: visualReview, options: [.prettyPrinted, .sortedKeys])
                guard reviewData.count <= options.maximumProtectedEvidenceBytes else {
                    throw NSError(domain: "CombinedMeetingProtectedEvidenceSize", code: 2)
                }
                let review = XCTAttachment(data: reviewData, uniformTypeIdentifier: "public.json")
                review.name = (options.privateEvaluation ? "Combined-Russian-meeting-private-protected-evaluation" : "Combined-Russian-meeting-private-visual-review")
                    + (options.repetitions > 1 ? "-run-\(repetition)" : "")
                review.lifetime = .keepAlways
                add(review)
            }
        } catch {
            progress?.emit(force: true)
            await coordinator.shutdownForTermination()
            try? await privacy.unload()
            sampler.cancel()
            await sampler.value
            let failed = try JSONSerialization.data(withJSONObject: ["phase": phase, "runIndex": repetition,
                "footprintSamples": resourceSamples.snapshot().samples.map(\.json)], options: [.sortedKeys])
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

    func testCombinedPrivateEvaluationOptionsAreBoundedAndSeparatelyGated() throws {
        let legacy = try CombinedEvaluationOptions(environment: [:])
        XCTAssertFalse(legacy.privateEvaluation)
        XCTAssertEqual(legacy.repetitions, 1)
        XCTAssertThrowsError(try CombinedEvaluationOptions(environment: ["PICHI_COMBINED_MEETING_REPETITIONS": "2"]))
        for raw in ["0", "4", "NaN", ""] {
            XCTAssertThrowsError(try CombinedEvaluationOptions(environment: [
                "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1", "PICHI_COMBINED_MEETING_REPETITIONS": raw]))
        }
        let repeated = try CombinedEvaluationOptions(environment: [
            "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1", "PICHI_COMBINED_MEETING_REPETITIONS": "3"])
        XCTAssertTrue(repeated.privateEvaluation)
        XCTAssertEqual(repeated.repetitions, 3)
        let visualOnly = try CombinedEvaluationOptions(environment: ["PICHI_COMBINED_MEETING_EXPORT_PRIVATE_REVIEW": "1"])
        XCTAssertFalse(visualOnly.privateEvaluation)
    }

    func testCombinedLongEvaluationRequiresPrivateSingleRunAndRetainsLegacyBounds() throws {
        let legacy = try CombinedEvaluationOptions(environment: [:])
        XCTAssertFalse(legacy.longEvaluation)
        XCTAssertEqual(legacy.maximumAudioBytes, 64 * 1_048_576)
        XCTAssertEqual(legacy.maximumDurationSeconds, 600)
        XCTAssertEqual(legacy.maximumProtectedEvidenceBytes, 16 * 1_048_576)
        XCTAssertEqual(legacy.sampleIntervalSeconds, 0.25)
        XCTAssertEqual(legacy.maximumSamples, 10_000)
        XCTAssertNoThrow(try legacy.validatePCM(frameCount: 9_600_000, fileBytes: 64 * 1_048_576))
        XCTAssertThrowsError(try legacy.validatePCM(frameCount: 9_600_001, fileBytes: 44))
        XCTAssertThrowsError(try legacy.validatePCM(frameCount: 160_000, fileBytes: 64 * 1_048_576 + 1))
        XCTAssertThrowsError(try legacy.validatePCM(frameCount: 159_999, fileBytes: 44))
        XCTAssertThrowsError(try CombinedEvaluationOptions(environment: ["PICHI_COMBINED_MEETING_LONG_EVALUATION": "1"]))
        XCTAssertThrowsError(try CombinedEvaluationOptions(environment: [
            "PICHI_COMBINED_MEETING_LONG_EVALUATION": "1",
            "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1", "PICHI_COMBINED_MEETING_REPETITIONS": "2"]))
        let long = try CombinedEvaluationOptions(environment: [
            "PICHI_COMBINED_MEETING_LONG_EVALUATION": "1", "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1"])
        XCTAssertTrue(long.longEvaluation)
        XCTAssertEqual(long.repetitions, 1)
        XCTAssertEqual(long.maximumProtectedEvidenceBytes, 64 * 1_048_576)
        XCTAssertNoThrow(try long.validatePCM(frameCount: 57_600_000, fileBytes: 115_200_044))
        XCTAssertNoThrow(try long.validatePCM(frameCount: 62_400_000, fileBytes: 128 * 1_048_576))
        XCTAssertThrowsError(try long.validatePCM(frameCount: 62_400_001, fileBytes: 44))
        XCTAssertThrowsError(try long.validatePCM(frameCount: 160_000, fileBytes: 128 * 1_048_576 + 1))
        XCTAssertThrowsError(try long.validatePCM(frameCount: 160_000, fileBytes: -1))
    }

    func testCombinedLongSamplerCoversThreeHoursAndUsesItsConfiguredPeriod() throws {
        let options = try CombinedEvaluationOptions(environment: [
            "PICHI_COMBINED_MEETING_LONG_EVALUATION": "1", "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1"])
        let sampler = try CombinedResourceSamples(limit: options.maximumSamples, intervalSeconds: options.sampleIntervalSeconds)
        for second in 0...10_800 { sampler.record(elapsed: Double(second), bytes: 10, thermalState: 0) }
        let result = sampler.snapshot()
        XCTAssertEqual(result.samples.count, 10_801)
        XCTAssertEqual(result.omitted, 0)
        XCTAssertEqual(result.missedIntervals, 0)
        let gapSampler = try CombinedResourceSamples(limit: 2, intervalSeconds: 1)
        gapSampler.record(elapsed: 0, bytes: 10, thermalState: 0)
        gapSampler.record(elapsed: 4, bytes: 10, thermalState: 0)
        XCTAssertEqual(gapSampler.snapshot().missedIntervals, 3)
        XCTAssertEqual(gapSampler.snapshot().maximumGap, 4)
        for period in [Double.nan, .infinity, -.infinity, -1, 0, 0.049, 60.001] {
            XCTAssertThrowsError(try CombinedResourceSamples(intervalSeconds: period))
        }
        for limit in [0, -1, 12_001] { XCTAssertThrowsError(try CombinedResourceSamples(limit: limit)) }
    }

    func testCombinedPrivateReferenceAllowsMissingPrivacyCasesWithoutWeakeningLegacy() throws {
        let data = Data(#"{"provenance":"human-reviewed","turns":[{"start":0,"end":2,"speaker":0},{"start":1,"end":3,"speaker":1}]}"#.utf8)
        let reference = try JSONDecoder().decode(CombinedMeetingReference.self, from: data)
        XCTAssertThrowsError(try reference.validate(duration: 3))
        XCTAssertNoThrow(try reference.validate(duration: 3, privateEvaluation: true))
        XCTAssertTrue(reference.containsOverlap)
        XCTAssertTrue(reference.sensitiveAliases.isEmpty)
        let adjacent = CombinedMeetingReference(provenance: "synthetic", turns: [
            .init(start: 0, end: 1, speaker: 0), .init(start: 1, end: 2, speaker: 1)
        ], sensitiveAliases: [["Synthetic123!"]], textAnchors: ["слово", "пример"])
        XCTAssertNoThrow(try adjacent.validate(duration: 2))
        XCTAssertFalse(adjacent.containsOverlap)
        XCTAssertThrowsError(try adjacent.validate(duration: .nan, privateEvaluation: true))
        let invalid = CombinedMeetingReference(provenance: "human-reviewed", turns: [
            .init(start: -1, end: 1, speaker: 0)
        ], sensitiveAliases: [], textAnchors: [])
        XCTAssertThrowsError(try invalid.validate(duration: 2, privateEvaluation: true))
    }

    func testCombinedProtectedEvaluationFiltersOriginalTextAndVoiceIdentityData() throws {
        let speakerID = UUID(), trackID = UUID()
        var segment = MeetingTranscriptSegment(id: UUID(), start: .init(value: 1, timescale: 10),
            end: .init(value: 3, timescale: 10), sourceTrackID: trackID, speakerID: speakerID,
            text: "[ИМЯ] работает", originalText: "Private pre-edit wording", revision: 1,
            status: .final, overlap: .none, completeness: .complete)
        segment.nativePrecision = .word
        segment.nativeTiming = .init(start: 0.1, end: 0.3)
        segment.nativeUnitID = "synthetic-word"
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0, generation: 0)
        let firstToken = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let secondToken = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-1")
        segment.nativeSpeakerAssignment = .assigned(firstToken)
        let decision = try XCTUnwrap(MeetingSpeakerAttribution.resolve(units: [
            .init(id: "synthetic-word", trackID: trackID, analysisEpochID: epoch, precision: .word,
                  text: "[ИМЯ] работает", analysisStart: 0.1, analysisEnd: 0.3,
                  speaker: .assigned(firstToken), analysisSpanIDs: ["synthetic-span"])
        ], activity: [.init(token: firstToken, start: 0.1, end: 0.3),
                      .init(token: secondToken, start: 0.15, end: 0.25)]).first)
        segment.speakerAttribution = .init(decision: decision, speakerIDs: [firstToken: speakerID])
        var speaker = MeetingSessionSpeaker(id: speakerID, displayName: "Private person name",
            diarizationClusterID: "synthetic-cluster", trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        speaker.diarizationEmbedding = [0.12345, 0.6789]
        let values = try CombinedProtectedEvaluation.values(segments: [segment], speakers: [speaker])
        let bytes = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
        let json = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(json.contains("originalText"))
        XCTAssertFalse(json.contains("Private pre-edit wording"))
        XCTAssertFalse(json.contains("Private person name"))
        XCTAssertFalse(json.contains("diarizationEmbedding"))
        XCTAssertFalse(json.contains("identityCandidates"))
        let rows = try XCTUnwrap(values["segments"] as? [[String: Any]])
        XCTAssertEqual(rows.first?["nativePrecision"] as? String, "word")
        XCTAssertNotNil(rows.first?["nativeTiming"])
        XCTAssertNotNil(rows.first?["nativeSpeakerAssignment"])
        let presentation = try XCTUnwrap(rows.first?["speakerAttribution"] as? [String: Any])
        XCTAssertEqual(presentation["policyFingerprint"] as? String, decision.policyFingerprint)
        XCTAssertEqual((presentation["candidates"] as? [[String: Any]])?.count, 2)
        XCTAssertEqual(rows.first?["text"] as? String, "[ИМЯ] работает")
        XCTAssertEqual(segment.originalText, "Private pre-edit wording", "Export must not mutate product values")
        let people = try XCTUnwrap(values["speakers"] as? [[String: Any]])
        XCTAssertEqual(people.first?["displayName"] as? String, "Speaker 1")
    }

    func testCombinedResourceSamplesBoundStorageAndExposeActualGaps() throws {
        let sampler = try CombinedResourceSamples(limit: 2)
        sampler.record(elapsed: 0, bytes: 10, thermalState: 0)
        sampler.setPhase("capture")
        sampler.record(elapsed: 0.25, bytes: 20, thermalState: 1)
        sampler.record(elapsed: 1.0, bytes: nil, thermalState: 2)
        sampler.record(elapsed: 1.25, bytes: 30, thermalState: 3)
        let result = sampler.snapshot()
        XCTAssertEqual(result.samples.count, 2)
        XCTAssertEqual(result.samples.last?.phase, "capture")
        XCTAssertEqual(result.missing, 1)
        XCTAssertEqual(result.omitted, 1)
        XCTAssertEqual(result.maximumGap, 0.75, accuracy: 0.000001)
        XCTAssertEqual(result.missedIntervals, 2)
        XCTAssertEqual(result.maximumThermalState, 3)
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

    private func physicalFootprintBytes() -> UInt64? { CombinedResourceSamples.footprintBytes() }

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
