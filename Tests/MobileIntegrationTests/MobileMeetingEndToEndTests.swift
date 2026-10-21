@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import Darwin
import UIKit
import SwiftUI
@testable import PichiVoiceMobile
import XCTest

/// Opt-in real rendering load for the isolated native inference probe. The ordinary host
/// otherwise displays its unrelated shared services, which cannot validate live layout cost.
@MainActor
private final class CombinedVisibleMeetingUI {
    private let window: UIWindow
    private weak var previous: UIWindow?

    init(services: AppServices) throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            throw NSError(domain: "VisibleMeetingProbeRequiresForegroundScene", code: 1)
        }
        self.previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.rootViewController = UIHostingController(rootView: AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
            MobileMeetingRoot(coordinator: services.meetingSessionCoordinator, asr: services.asr,
                store: services.meetingStore, privacy: services.transcriptPrivacy,
                required: services.requiredResources, privacyActivation: services.privacyActivation,
                microphones: { .init(identities: [], defaultCoreAudioUID: nil) })
        })
        self.window = window
        window.makeKeyAndVisible()
    }

    func close() {
        let restore = self.window.isKeyWindow && self.window.windowScene?.activationState == .foregroundActive
        self.window.isHidden = true
        self.window.rootViewController = nil
        if restore { self.previous?.makeKeyAndVisible() }
    }
}

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
    private nonisolated let wrapped: any TranscriptTextRedacting
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var observations: [Observation] = []
    private var retainedUTF16 = 0
    private var omittedObservations = 0
    private(set) var backgroundSuccessfulCalls = 0
    private(set) var backgroundRedactedCalls = 0

    init(wrapping wrapped: any TranscriptTextRedacting) { self.wrapped = wrapped }
    nonisolated var checkpointIdentity: String? { wrapped.checkpointIdentity }
    nonisolated var supportsSpeechBoundaryAdmission: Bool { wrapped.supportsSpeechBoundaryAdmission }
    @MainActor func prepareForMeeting() async throws { try await wrapped.prepareForMeeting() }

    @MainActor func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await redact(text, speechBoundary: false)
    }
    @MainActor func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await redact(text, speechBoundary: true)
    }
    @MainActor private func redact(_ text: String, speechBoundary: Bool) async throws -> TranscriptTextRedaction {
        let result: TranscriptTextRedaction
        if speechBoundary { result = try await wrapped.redactSpeechBoundaryWithSpans(text) }
        else { result = try await wrapped.redactWithSpans(text) }
        if UIApplication.shared.applicationState == .background {
            backgroundSuccessfulCalls += 1
            if !result.spans.isEmpty { backgroundRedactedCalls += 1 }
        }
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

private actor CombinedPrivacyPreparationSpy: TranscriptTextRedacting {
    nonisolated let checkpointIdentity: String? = "synthetic-preparation-spy-v1"
    private(set) var preparations = 0
    func prepareForMeeting() async throws { preparations += 1 }
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
    nonisolated let wrapped: any TranscriptTextRedacting
    let aliases: [[String]]
    private(set) var observed: Set<Int> = []
    private(set) var fullyMasked: Set<Int> = []
    private(set) var unmaskedPublishableObservations = 0
    init(wrapping wrapped: any TranscriptTextRedacting, aliases: [[String]]) {
        self.wrapped = wrapped; self.aliases = aliases
    }
    nonisolated var checkpointIdentity: String? { wrapped.checkpointIdentity }
    nonisolated var supportsSpeechBoundaryAdmission: Bool { wrapped.supportsSpeechBoundaryAdmission }
    @MainActor func prepareForMeeting() async throws { try await wrapped.prepareForMeeting() }
    @MainActor func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await redact(text, speechBoundary: false)
    }
    @MainActor func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await redact(text, speechBoundary: true)
    }
    @MainActor private func redact(_ text: String, speechBoundary: Bool) async throws -> TranscriptTextRedaction {
        let began = MeetingPCMRuntimeDiagnostics.beginDetailed(.privacyRedact)
        var succeeded = false
        defer { MeetingPCMRuntimeDiagnostics.completedDetailed(.privacyRedact, since: began,
            samples: text.utf16.count, succeeded: succeeded) }
        let result: TranscriptTextRedaction
        if speechBoundary { result = try await wrapped.redactSpeechBoundaryWithSpans(text) }
        else { result = try await wrapped.redactWithSpans(text) }
        succeeded = true
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
    private var retainedWriter: MeetingAudioChunkWriter?
    private var liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    private var active: (MeetingSessionID, MeetingAudioTrack)?
    func setFactory(_ factory: IOSMeetingCaptureEngine.MemoryConsumerFactory?) { self.factory = factory }
    func preflightPermissions() async throws { }
    func start(session: MeetingSession, configuration: MeetingCaptureConfiguration, sessionDirectory: URL,
               eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
               liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
        guard active == nil, let factory,
              configuration.audioStorageMode == .memoryOnly
                || configuration.effectiveSpeakerProcessingMode == .streaming else {
            throw MeetingCaptureError.captureStartFailed("Synthetic input requires strict or streaming PCM")
        }
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic microphone", format: .init(codec: "lpcm-f32", sampleRate: 16_000,
            channelCount: 1, bitRate: nil), timebase: session.timebase, health: .waiting, chunks: [])
        if configuration.audioStorageMode != .memoryOnly {
            retainedWriter = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory,
                chunkDuration: configuration.chunkDuration, eventHandler: eventHandler)
        }
        do { consumer = try await factory(session, configuration, track, eventHandler) }
        catch {
            _ = await retainedWriter?.stop()
            retainedWriter = nil
            throw error
        }
        active = (session.id, track)
        self.liveAudioHandler = liveAudioHandler
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
            // Match production capture's live tee: VAD and pending-wave projection
            // must observe the same source clock as the strict PCM consumer.
            if let retainedWriter, !retainedWriter.enqueue(buffer) { throw MeetingMemoryAudioError.overload }
            guard consumer.enqueue(buffer) else { throw MeetingMemoryAudioError.overload }
            self.liveAudioHandler?(.microphone, buffer)
        }
    }
    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        guard let (id, original) = active, id == sessionID else { throw MeetingCaptureError.wrongActiveSession }
        defer { active = nil; consumer = nil; retainedWriter = nil; liveAudioHandler = nil }
        var track = if let retainedWriter { await retainedWriter.stop() } else { original }
        try await consumer?.finish()
        track.health.status = .stopped
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

    func attributionAgreementUnavailableReason(referenceContainsOverlap: Bool) -> String? {
        if longEvaluation { return "longEvaluationRequiresOfflineWordScoring" }
        if referenceContainsOverlap { return "overlappingReferenceRequiresOfflineWordScoring" }
        return nil
    }

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

/// The source length is explicit so one private asset slot can hold separately reviewed
/// short, paused, and hour-long recordings without trimming or repeating their audio.
private nonisolated struct StreamingEvaluationOptions {
    let expectedSourceFrames: Int64
    let expectedOwnerCount: Int?
    var requiresPreStopOutput: Bool { expectedSourceFrames >= 30 * 16_000 }
    func requiresRecognizedSpeech(referenceProvenance: String) -> Bool {
        // Preserve the established voiced longer-fixture checks even when its
        // speaker reference is weak; a new short fixture must attest reviewed voice.
        expectedSourceFrames >= 30 * 16_000
            || (expectedSourceFrames >= 5 * 16_000 && ["synthetic", "human-reviewed"].contains(referenceProvenance))
    }
    init(environment: [String: String], combined: CombinedEvaluationOptions) throws {
        guard combined.privateEvaluation, combined.repetitions == 1,
              environment["PICHI_MEETING_DETAILED_PROFILE"] == "1",
              let frames = Int64(environment["PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES"] ?? "2880000"),
              frames >= 1, frames <= Int64(combined.maximumDurationSeconds * 16_000) else {
            throw NSError(domain: "StreamingMeetingEvaluationOptions", code: 1)
        }
        expectedSourceFrames = frames
        switch environment["PICHI_MEETING_STREAMING_EXPECTED_OWNER_COUNT"] {
        case nil: expectedOwnerCount = nil
        case "0": expectedOwnerCount = 0
        case "1": expectedOwnerCount = 1
        default: throw NSError(domain: "StreamingMeetingEvaluationOptions", code: 2)
        }
    }
    func validatePCM(frameCount: Int64, fileBytes: Int, combined: CombinedEvaluationOptions) throws {
        guard frameCount == expectedSourceFrames, fileBytes >= 0, fileBytes <= combined.maximumAudioBytes else {
            throw NSError(domain: "StreamingMeetingUnexpectedSourcePCM", code: 1)
        }
    }
}

/// Scalar-only executor diagnostics. Queue entry is timestamped inside MainActor;
/// utility resumption and sampler cadence are separate measurements, never FPS.
private nonisolated final class CombinedMainActorSamples: @unchecked Sendable {
    enum Phase: String, CaseIterable, Sendable {
        case preparation, modelPreparation, configurationPreparation, configurationReady
        case captureAdmission, capture, postStop, completedPrivacyReady, completedValidation, historyReload, diagnosticExport, privacyRelease
        case aliasMaintenance, aliasSave, aliasRestore, betweenAttemptsRelease, retainedRecovery, cleanup, other
    }
    private struct Sample {
        let phase: Phase
        let crossedPhase: Bool
        let entry: Double
        let marker: Double
        let resume: Double
        let roundTrip: Double
        let submissionInterval: Double?
        let completionInterval: Double?
        let utilityWakeGap: Double?
    }
    private let lock = NSLock()
    private let limit: Int
    private var phase = Phase.preparation
    private var samples: [Sample] = []
    private var omitted = 0
    private var invalid = 0

    init(limit: Int = 12_000) {
        precondition((0...12_000).contains(limit))
        self.limit = limit
    }
    func setPhase(_ value: String) { lock.withLock { phase = Phase(rawValue: value) ?? .other } }
    func currentPhase() -> Phase { lock.withLock { phase } }

    /// Absolute uptime values are consumed here and never retained or serialized.
    func record(phase submittedPhase: Phase, entryPhase: Phase, queued: Double, entered: Double, departed: Double, resumed: Double,
                previousQueued: Double?, previousResumed: Double?) {
        lock.withLock {
            guard queued.isFinite, entered.isFinite, departed.isFinite, resumed.isFinite,
                  queued >= 0, entered >= queued, departed >= entered, resumed >= departed,
                  previousQueued.map({ $0.isFinite && $0 >= 0 && $0 <= queued }) ?? true,
                  previousResumed.map({ $0.isFinite && $0 >= 0 && $0 <= queued }) ?? true else {
                invalid += 1; return
            }
            guard samples.count < limit else { omitted += 1; return }
            samples.append(.init(phase: submittedPhase, crossedPhase: submittedPhase != entryPhase,
                entry: entered - queued, marker: departed - entered, resume: resumed - departed, roundTrip: resumed - queued,
                submissionInterval: previousQueued.map { queued - $0 },
                completionInterval: previousResumed.map { resumed - $0 },
                utilityWakeGap: previousResumed.map { queued - $0 }))
        }
    }

    func json(interval: Double) -> [String: Any] {
        lock.withLock {
            func metric(_ values: [Double]) -> [String: Any] {
                let sorted = values.sorted()
                func percentile(_ p: Double) -> Double {
                    sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
                }
                return ["samples": sorted.count, "p50Seconds": percentile(0.5), "p95Seconds": percentile(0.95),
                        "p99Seconds": percentile(0.99), "maximumSeconds": sorted.last ?? 0]
            }
            func metrics(_ values: [Sample]) -> [String: Any] {
                ["samples": values.count, "phaseChangesWhileQueued": values.filter(\.crossedPhase).count,
                 "mainActorQueueEntry": metric(values.map(\.entry)),
                 "mainActorMarkerExecution": metric(values.map(\.marker)),
                 "utilityContinuationResume": metric(values.map(\.resume)),
                 "roundTrip": metric(values.map(\.roundTrip)),
                 "utilitySubmissionInterval": metric(values.compactMap(\.submissionInterval)),
                 "utilityCompletionInterval": metric(values.compactMap(\.completionInterval)),
                 "utilityWakeGap": metric(values.compactMap(\.utilityWakeGap))]
            }
            let roundTrip = metric(samples.map(\.roundTrip))
            var result = metrics(samples)
            result["schema"] = 2
            result["omittedSamples"] = omitted
            result["invalidSamples"] = invalid
            result["capacity"] = limit
            result["requestedIntervalSeconds"] = interval
            result["phases"] = Dictionary(uniqueKeysWithValues: Phase.allCases.compactMap { phase in
                let rows = samples.filter { $0.phase == phase }
                return rows.isEmpty ? nil : (phase.rawValue, metrics(rows))
            })
            // Preserve old readers without rebranding their confounded round trip as
            // executor queue delay. New reports must use mainActorQueueEntry above.
            result["p50WaitSeconds"] = roundTrip["p50Seconds"]
            result["p95WaitSeconds"] = roundTrip["p95Seconds"]
            result["p99WaitSeconds"] = roundTrip["p99Seconds"]
            result["maximumWaitSeconds"] = roundTrip["maximumSeconds"]
            result["maximumObservedIntervalSeconds"] = samples.compactMap(\.completionInterval).max() ?? 0
            result["legacyWaitFieldsScope"] = "Queued until utility continuation resumes; round trip, not MainActor queue delay."
            result["phaseScope"] = "Attributed to submission phase; phaseChangesWhileQueued counts transitions before MainActor entry."
            result["preparationPhaseScope"] = "modelPreparation is the test's explicit asr.downloadModel, before the product defaultConfiguration call measured as configurationPreparation."
            result["clockScope"] = "Queue entry: utility submission to first timestamp inside MainActor. Marker execution: that entry to last in-actor timestamp. Utility resume: marker departure to utility continuation. Cadence and wake gaps describe this utility sampler only."
            result["coverageScope"] = "A delayed utility task cannot probe MainActor before it submits. Utility wake gaps expose those unsampled periods; small entry latency does not establish responsiveness during a gap."
            result["scope"] = "Sampled utility-to-MainActor queue entry, utility continuation resumption and utility sampling gaps. Does not measure touch latency, rendered frames or FPS."
            return result
        }
    }
}

/// Reads the process counter off MainActor. The caller owns and joins its sampling Task.
nonisolated final class CombinedResourceSamples: @unchecked Sendable {
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

/// Explicit private XCTest diagnostics survive a lost XCTest attachment connection.
/// A terminal diagnostic is never a substitute for the external XCTest result. This
/// owner writes only existing post-privacy evidence, outside the sampled window.
private nonisolated struct CombinedDurableEvidencePin: Encodable {
    let runID: String
    let testedRevision: String
    let audioSHA256: String
    let expectedSourceFrames: Int64

    init?(environment: [String: String], streaming: Bool, options: CombinedEvaluationOptions,
          actualRevision: String, audioSHA256: String, sourceFrames: Int64) throws {
        guard environment["PICHI_MEETING_DURABLE_EVIDENCE"] == "1" else { return nil }
        func hex(_ value: String, count: Int) -> Bool {
            value.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard streaming, options.privateEvaluation, options.repetitions == 1,
              environment["PICHI_MEETING_DETAILED_PROFILE"] == "1",
              let rawID = environment["PICHI_MEETING_DURABLE_RUN_ID"],
              let id = UUID(uuidString: rawID), id.uuidString.lowercased() == rawID,
              let revision = environment["PICHI_COMBINED_MEETING_TESTED_REVISION"],
              hex(revision, count: 40), revision == actualRevision,
              let digest = environment["PICHI_MEETING_DURABLE_AUDIO_SHA256"],
              hex(digest, count: 64), digest == audioSHA256,
              let expected = environment["PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES"].flatMap(Int64.init),
              expected > 0, expected == sourceFrames else {
            throw NSError(domain: "CombinedMeetingDurableEvidencePin", code: 1)
        }
        runID = rawID; testedRevision = revision; self.audioSHA256 = digest; expectedSourceFrames = expected
    }
}

private nonisolated final class CombinedDurableEvaluationEvidence {
    static let directoryName = "PrivateMeetingEvaluationTests"
    private let directory: URL
    private let pin: CombinedDurableEvidencePin
    private let maximumEvidenceBytes: Int
    private let files = FileManager.default

    init(pin: CombinedDurableEvidencePin, cachesDirectory: URL, maximumEvidenceBytes: Int) throws {
        self.pin = pin
        self.maximumEvidenceBytes = maximumEvidenceBytes
        let caches = cachesDirectory.standardizedFileURL
        // The caller obtains the fixed sandbox Caches location, never an environment
        // path. Refuse a replaced Library/Caches boundary, while allowing the OS's
        // own /var alias outside the application container.
        try Self.requireDirectory(caches.deletingLastPathComponent())
        try Self.requireDirectory(caches)
        let parent = caches.appendingPathComponent(Self.directoryName, isDirectory: true)
        if !files.fileExists(atPath: parent.path) {
            try files.createDirectory(at: parent, withIntermediateDirectories: false)
        }
        try Self.requireDirectory(parent)
        directory = parent.appendingPathComponent(pin.runID, isDirectory: true)
        // A fresh run owns a new directory. Never replace another attempt's evidence.
        guard !files.fileExists(atPath: directory.path) else {
            throw NSError(domain: "CombinedMeetingDurableEvidenceExists", code: 1)
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
        try Self.requireDirectory(directory)
        try write(try JSONEncoder().encode(pin), name: "manifest.json", limit: 4_096)
        try terminal(state: "running", assertionFailures: nil, evidenceDigests: [:])
    }

    private static func requireDirectory(_ url: URL) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw NSError(domain: "CombinedMeetingDurableEvidenceDirectory", code: 1)
        }
    }

    private func write(_ data: Data, name: String, limit: Int) throws {
        guard data.count <= limit else { throw NSError(domain: "CombinedMeetingDurableEvidenceSize", code: 1) }
        try Self.requireDirectory(directory)
        let target = directory.appendingPathComponent(name)
        if files.fileExists(atPath: target.path) {
            guard try files.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeRegular else {
                throw NSError(domain: "CombinedMeetingDurableEvidenceFile", code: 1)
            }
        }
        try data.write(to: target, options: .atomic)
    }

    private func terminal(state: String, assertionFailures: Int?, evidenceDigests: [String: String], phase: String? = nil) throws {
        var values: [String: Any] = [
            "schema": 1, "pin": try JSONSerialization.jsonObject(with: JSONEncoder().encode(pin)),
            "state": state, "recordedXCTestFailureCount": assertionFailures as Any? ?? NSNull(),
            "xctestAcceptance": "externalXCTestPassRequired", "evidenceSHA256": evidenceDigests,
            "scope": "Private test diagnostics only. Completion here cannot establish XCTest PASS, quality acceptance, or absence of later test failures. No audio, profiles, embeddings, original text, or arbitrary error descriptions are written."
        ]
        if let phase { values["failurePhase"] = phase }
        try write(try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]), name: "terminal.json", limit: 8_192)
    }

    func finish(metadata: Data, protectedEvaluation: Data, assertionFailures: Int?) throws {
        try write(metadata, name: "metadata.json", limit: maximumEvidenceBytes)
        try write(protectedEvaluation, name: "protected-evaluation.json", limit: maximumEvidenceBytes)
        let hashes = ["metadata.json": metadata, "protected-evaluation.json": protectedEvaluation].mapValues {
            SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
        }
        try terminal(state: "completedDiagnostic", assertionFailures: assertionFailures, evidenceDigests: hashes)
    }

    func fail(cancelled: Bool, phase: String, assertionFailures: Int?, metadata: Data) throws {
        let allowed = ["preparation", "configurationReady", "capture", "postStop", "completedPrivacyReady",
                       "betweenAttemptsRelease", "retainedRecovery", "cleanup"]
        try write(metadata, name: "failure-metadata.json", limit: maximumEvidenceBytes)
        let hash = SHA256.hash(data: metadata).map { String(format: "%02x", $0) }.joined()
        try terminal(state: cancelled ? "cancelledDiagnostic" : "failedDiagnostic", assertionFailures: assertionFailures,
                     evidenceDigests: ["failure-metadata.json": hash], phase: allowed.contains(phase) ? phase : "other")
    }
}

/// The streaming test reads only whitelisted numeric diagnostics for this exact attempt.
/// It never attaches support logs, paths, source wording, identities or model inputs.
private nonisolated enum CombinedStreamingDiagnostics {
    struct Row: Equatable, Sendable {
        let attemptID: UUID
        let phase: String
        let uptimeMS: Int64
        let accepted: Int
        let processed: Int
        let asrStable: Int
        let committed: Int
        let pendingWords: Int
        let knownCount: Int
        let isStreamingFinish: Bool
        var json: [String: Any] {
            ["phase": phase, "uptimeMs": uptimeMS, "acceptedThroughSample": accepted,
             "processedThroughSample": processed, "asrStableThroughSample": asrStable,
             "committedThroughSample": committed, "pendingWords": pendingWords,
             "knownCount": knownCount, "streamingFinishWithoutReplay": isStreamingFinish]
        }
    }

    static func fields(_ line: String) -> [String: String] {
        Dictionary(line.split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
        }, uniquingKeysWith: { first, _ in first })
    }

    static func row(_ line: String, attempts: Set<UUID>) -> Row? {
        guard line.contains("[MeetingStreamingPCM]") else { return nil }
        let values = fields(line)
        guard let rawID = values["attemptID"], let id = UUID(uuidString: rawID), attempts.contains(id),
              let phase = values["phase"], ["progress", "window", "finish"].contains(phase),
              let uptime = values["uptimeMs"].flatMap(Int64.init), uptime >= 0,
              let accepted = values["acceptedThroughSample"].flatMap(Int.init),
              let processed = values["processedThroughSample"].flatMap(Int.init),
              let asrStable = values["asrStableThroughSample"].flatMap(Int.init),
              let committed = values["committedThroughSample"].flatMap(Int.init),
              let pending = values["pendingWords"].flatMap(Int.init),
              let known = values["knownCount"].flatMap(Int.init),
              accepted >= 0, processed >= 0, asrStable >= 0, committed >= 0, pending >= 0, known >= 0,
              processed <= accepted, asrStable <= accepted,
              committed <= min(asrStable, processed) else { return nil }
        return .init(attemptID: id, phase: phase, uptimeMS: uptime, accepted: accepted,
            processed: processed, asrStable: asrStable, committed: committed,
            pendingWords: pending, knownCount: known,
            isStreamingFinish: phase == "finish" && values["mode"] == "streaming" && values["replay"] == "false")
    }

    /// Both bounded logger files cover a rotation. Reading never changes logger ownership.
    static func lines() throws -> [String] {
        let current = FileLogger.shared.currentLogFileURL()
        let previous = current.appendingPathExtension("1")
        return try [previous, current].flatMap { url -> [String] in
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard bytes <= 1_100_000 else { throw NSError(domain: "StreamingMeetingDiagnosticLogSize", code: 1) }
            return try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines)
        }
    }

    static func phaseTotals(_ lines: [String], from startMS: Int64, through endMS: Int64) -> [String: Any] {
        var elapsed: [String: Int64] = [:]
        var counts: [String: Int] = [:]
        for line in lines where line.contains("[MeetingPCMRuntime]") {
            let values = fields(line)
            guard values["event"] == "end", let phase = values["phase"],
                  let timestamp = values["uptimeMs"].flatMap(Int64.init), (startMS...endMS).contains(timestamp),
                  let milliseconds = values["elapsedMs"].flatMap(Int64.init), milliseconds >= 0 else { continue }
            elapsed[phase, default: 0] += milliseconds
            counts[phase, default: 0] += 1
        }
        return ["elapsedMillisecondsByPhase": elapsed, "completedSpansByPhase": counts,
                "scope": "Whole-process diagnostic spans ending in this test interval; nested spans overlap"]
    }

    static func completedPhaseCount(_ phase: String, in lines: [String], from startMS: Int64, through endMS: Int64) -> Int {
        lines.filter { line in
            guard line.contains("[MeetingPCMRuntime]") else { return false }
            let values = fields(line)
            return values["event"] == "end" && values["phase"] == phase
                && values["uptimeMs"].flatMap(Int64.init).map { (startMS...endMS).contains($0) } == true
        }.count
    }

    struct TransportRow: Sendable {
        let offsetSeconds: Double
        let frames: Int
        let pending: Int
        let peakPending: Int
        let budget: Int
        let windowMS: Int
        let checkpointMS: Int
        var json: [String: Any] {
            ["offsetSeconds": offsetSeconds, "frames": frames, "pendingFrames": pending,
             "peakPendingFrames": peakPending, "budgetFrames": budget,
             "windowWallMilliseconds": windowMS, "checkpointMilliseconds": checkpointMS]
        }
    }

    static func transportRow(_ line: String, attempts: Set<UUID>) -> TransportRow? {
        guard line.contains("[MeetingMemoryAudio]") else { return nil }
        let values = fields(line)
        guard let rawID = values["pipelineID"], let id = UUID(uuidString: rawID), attempts.contains(id),
              let offset = values["offset"].flatMap(Double.init), offset.isFinite, offset >= 0,
              let frames = values["frames"].flatMap(Int.init), frames > 0,
              let pending = values["pendingFrames"].flatMap(Int.init), pending >= 0,
              let peak = values["peakPendingFrames"].flatMap(Int.init), peak >= pending,
              let budget = values["budgetFrames"].flatMap(Int.init), budget > 0, peak <= budget,
              let windowMS = values["windowMs"].flatMap(Int.init), windowMS >= 0,
              let checkpointMS = values["checkpointMs"].flatMap(Int.init), checkpointMS >= 0 else { return nil }
        return .init(offsetSeconds: offset, frames: frames, pending: pending,
                     peakPending: peak, budget: budget, windowMS: windowMS, checkpointMS: checkpointMS)
    }

    static func percentile95(_ values: [Int]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return Double(sorted[max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)]) / 16_000
    }
}

/// Opt-in test evidence survives ordinary support-log rotation. Retain only a fixed
/// scalar schema, never arbitrary log text. The joined sampler owns no inference resources.
private nonisolated final class CombinedStreamingEvidenceCollector: @unchecked Sendable {
    static let intervalSeconds: Double = 60
    static let maximumRows = 30_000
    static let maximumBytes = 8 * 1_048_576
    private let lock = NSLock()
    private let startedMS: Int64
    private let rowLimit: Int
    private let byteLimit: Int
    private var retained: [String] = []
    private var seen: Set<String> = []
    private var retainedBytes = 0
    private var omittedRows = 0
    private var readFailures = 0
    init(startedMS: Int64, maximumRows: Int = 30_000, maximumBytes: Int = 8 * 1_048_576) {
        self.startedMS = startedMS
        self.rowLimit = max(0, min(Self.maximumRows, maximumRows))
        self.byteLimit = max(0, min(Self.maximumBytes, maximumBytes))
    }
    func capture() {
        do { ingest(try CombinedStreamingDiagnostics.lines()) }
        catch { lock.withLock { readFailures += 1 } }
    }
    func ingest(_ lines: [String]) {
        lock.withLock {
            for line in lines {
                guard let scalar = Self.scalarLine(line, from: startedMS) else { continue }
                let key = SHA256.hash(data: Data(scalar.utf8)).map { String(format: "%02x", $0) }.joined()
                guard !seen.contains(key) else { continue }
                // Include the deduplication key in the bounded UTF-8 payload budget.
                let size = scalar.utf8.count + key.utf8.count
                guard retained.count < rowLimit, size <= byteLimit - retainedBytes else {
                    omittedRows += 1
                    continue
                }
                retainedBytes += size
                seen.insert(key)
                retained.append(scalar)
            }
        }
    }
    func snapshot() -> (lines: [String], omitted: Int, failures: Int, metadata: [String: Any]) {
        lock.withLock {
            (retained, omittedRows, readFailures,
             ["scope": "Test-local scalar cursor and transport rows plus whole-process runtime end spans in this uptime interval; final validation selects exact completed attempt IDs. Logger snapshot order is preserved across deduplicated polls. No raw log attachment, transcript, audio, embeddings or owner identity.",
              "pollIntervalSeconds": Self.intervalSeconds, "rowCapacity": rowLimit,
              "utf8PayloadAndDedupKeyByteCapacity": byteLimit, "retainedRows": retained.count,
              "retainedUTF8PayloadAndDedupKeyBytes": retainedBytes, "omittedRows": omittedRows,
              "logReadFailures": readFailures,
              "limitations": "Polling cannot recover lines rotated out between reads; Swift container overhead is outside the payload byte count. Completeness and zero omission are asserted separately."])
        }
    }
    private static func scalarLine(_ line: String, from startedMS: Int64) -> String? {
        guard line.utf8.count <= 8_192 else { return nil }
        let values = CombinedStreamingDiagnostics.fields(line)
        let source: String
        var output: [String: String] = [:]
        if line.contains("[MeetingStreamingPCM]") {
            guard let id = values["attemptID"].flatMap(UUID.init(uuidString:)) else { return nil }
            source = "MeetingStreamingPCM"
            output["attemptID"] = id.uuidString
            output["phase"] = ["progress", "window", "finish"].contains(values["phase"] ?? "") ? values["phase"] : "invalid"
            for key in ["uptimeMs", "acceptedThroughSample", "processedThroughSample", "asrStableThroughSample",
                        "committedThroughSample", "pendingWords", "knownCount"] {
                output[key] = values[key].flatMap(Int64.init).map(String.init) ?? "invalid"
            }
            output["mode"] = values["mode"] == "streaming" ? "streaming" : "invalid"
            output["replay"] = values["replay"] == "false" ? "false" : "invalid"
        } else if line.contains("[MeetingMemoryAudio]"), values["frames"] != nil {
            guard let id = values["pipelineID"].flatMap(UUID.init(uuidString:)) else { return nil }
            source = "MeetingMemoryAudio"
            output["pipelineID"] = id.uuidString
            let offset = values["offset"].flatMap(Double.init)
            output["offset"] = offset.flatMap { $0.isFinite ? String($0) : nil } ?? "invalid"
            for key in ["frames", "pendingFrames", "peakPendingFrames", "budgetFrames", "windowMs", "checkpointMs"] {
                output[key] = values[key].flatMap(Int64.init).map(String.init) ?? "invalid"
            }
        } else if line.contains("[MeetingPCMRuntime]"), values["event"] == "end" {
            guard let phase = values["phase"].flatMap(MeetingPCMRuntimeDiagnostics.Phase.init(rawValue:)),
                  let span = values["spanID"].flatMap(UUID.init(uuidString:)),
                  let elapsed = values["elapsedMs"].flatMap(Int64.init), elapsed >= 0,
                  let uptime = values["uptimeMs"].flatMap(Int64.init), uptime >= startedMS else { return nil }
            source = "MeetingPCMRuntime"
            output = ["phase": phase.rawValue, "spanID": span.uuidString, "elapsedMs": String(elapsed),
                      "uptimeMs": String(uptime), "event": "end"]
        } else { return nil }
        if let uptime = output["uptimeMs"].flatMap(Int64.init), uptime < startedMS { return nil }
        // Keep a validated clock prefix so distinct transport windows remain distinct
        // even when every numeric value except the log clock happens to match.
        let clock = line.range(of: #"^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\]"#, options: .regularExpression)
            .map { String(line[$0]) + " " } ?? ""
        return clock + "[\(source)] " + output.keys.sorted().map { "\($0)=\(output[$0]!)" }.joined(separator: " ")
    }
}

/// Detects persistent audio/media creation in the app container, including its temporary
/// directory. Files deleted between observations remain an explicit limitation.
private nonisolated enum CombinedStreamingAudioInventory {
    static func onlyAllowed(_ paths: Set<String>, retainedRoot: URL?) -> Bool {
        guard let retainedRoot else { return paths.isEmpty }
        let prefix = retainedRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return paths.allSatisfy {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(prefix)
        }
    }

    static func paths(in root: URL) throws -> Set<String> {
        let extensions: Set<String> = ["wav", "aif", "aiff", "caf", "m4a", "aac", "mp3", "flac", "ogg", "opus", "mp4", "mov"]
        guard let iterator = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else {
            throw NSError(domain: "StreamingMeetingAudioInventory", code: 1)
        }
        var entries = 0
        var paths: Set<String> = []
        for case let url as URL in iterator {
            entries += 1
            guard entries <= 100_000 else { throw NSError(domain: "StreamingMeetingAudioInventory", code: 2) }
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if properties.isSymbolicLink == true { iterator.skipDescendants(); continue }
            if properties.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) {
                paths.insert(url.standardizedFileURL.path)
            }
        }
        return paths
    }
}

private struct SyntheticSpeechBoundaryRedactor: TranscriptTextRedacting {
    nonisolated var checkpointIdentity: String? { "synthetic-boundary-v1" }
    nonisolated var supportsSpeechBoundaryAdmission: Bool { true }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: text, spans: [])
    }
    func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: "[ИМЯ]", spans: [.init(range: NSRange(location: 0, length: text.utf16.count), replacement: "[ИМЯ]")],
              provisionalSafeUTF16: text.utf16.count)
    }
}

@MainActor
final class MobileMeetingEndToEndTests: XCTestCase {
    func testObservationWrapperPreservesSpeechBoundaryCapabilityAndMaskAccounting() async throws {
        let observation = CombinedPrivacyObservations(wrapping: SyntheticSpeechBoundaryRedactor(), aliases: [["Иван Тестов"]])
        XCTAssertTrue(observation.supportsSpeechBoundaryAdmission)
        XCTAssertEqual(observation.checkpointIdentity, "synthetic-boundary-v1")
        let result = try await observation.redactSpeechBoundaryWithSpans("Иван Тестов")
        XCTAssertEqual(result.text, "[ИМЯ]")
        XCTAssertEqual(observation.observed, [0])
        XCTAssertEqual(observation.fullyMasked, [0])
        XCTAssertEqual(observation.unmaskedPublishableObservations, 0)
        let replay = SyntheticPrivacyReplayDiagnostics(wrapping: SyntheticSpeechBoundaryRedactor())
        XCTAssertTrue(replay.supportsSpeechBoundaryAdmission)
        let replayResult = try await replay.redactSpeechBoundaryWithSpans("Иван Тестов")
        XCTAssertEqual(replayResult.text, "[ИМЯ]")
        let evidence = try XCTUnwrap(JSONSerialization.jsonObject(with: replay.attachmentData()) as? [String: Any])
        XCTAssertEqual((evidence["observations"] as? [[String: Any]])?.count, 1)
    }

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

    /// Uses actual paced PCM and the registered streaming composition. This separate flag
    /// implies no approval to mutate normal preferences or existing meeting history.
    func testStreamingRussianMeetingPrivacySpeakersAndFootprint() async throws {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_MEETING_STREAMING_E2E"] == "1" else {
            throw XCTSkip("Explicitly enable actual streaming Russian fixture inference")
        }
        let options = try CombinedEvaluationOptions(environment: environment)
        guard options.privateEvaluation, options.repetitions == 1,
              environment["PICHI_MEETING_DETAILED_PROFILE"] == "1" else {
            throw NSError(domain: "StreamingMeetingRequiresPrivateSingleRunAndDetailedProfile", code: 1)
        }
        let revision = RuntimeBuildProvenance.sanitizedSourceRevision(environment["PICHI_COMBINED_MEETING_TESTED_REVISION"])
        guard revision != "unavailable",
              RuntimeBuildProvenance.sanitizedSourceRevision(Bundle.main.object(forInfoDictionaryKey: "AppSourceRevision")) == revision else {
            throw NSError(domain: "StreamingMeetingRequiresMatchingFrozenRevision", code: 1)
        }
        var pinned = environment
        pinned["PICHI_COMBINED_MEETING_ASR"] = SettingsStore.SpeechModel.gigaam.rawValue
        try await runCombinedRussianMeeting(environment: pinned, options: options, repetition: 1, streaming: true)
        #else
        throw XCTSkip("Streaming private evaluation requires a Debug test host")
        #endif
    }

    /// Same real pipeline for any registered streaming provider. The caller pins an
    /// explicit model and reviewed local fixture; no default-provider substitution occurs.
    func testRegisteredStreamingMeetingPrivacySpeakersAndFootprint() async throws {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_REGISTERED_STREAMING_E2E"] == "1" else {
            throw XCTSkip("Explicitly enable registered-provider streaming fixture inference")
        }
        let options = try CombinedEvaluationOptions(environment: environment)
        guard options.privateEvaluation, options.repetitions == 1,
              environment["PICHI_MEETING_DETAILED_PROFILE"] == "1",
              let model = environment["PICHI_COMBINED_MEETING_ASR"],
              PichiMeetingProviderFactory.registeredBackendDescriptor(for: model)?.supportedSpeakerProcessingModes.contains(.streaming) == true else {
            throw NSError(domain: "RegisteredStreamingRequiresExplicitSupportedModelAndFixture", code: 1)
        }
        let revision = RuntimeBuildProvenance.sanitizedSourceRevision(environment["PICHI_COMBINED_MEETING_TESTED_REVISION"])
        guard revision != "unavailable",
              RuntimeBuildProvenance.sanitizedSourceRevision(Bundle.main.object(forInfoDictionaryKey: "AppSourceRevision")) == revision else {
            throw NSError(domain: "StreamingMeetingRequiresMatchingFrozenRevision", code: 1)
        }
        try await runCombinedRussianMeeting(environment: environment, options: options, repetition: 1, streaming: true)
        #else
        throw XCTSkip("Registered streaming fixture evaluation requires a Debug test host")
        #endif
    }

    /// A retained recording still streams live. Recovery then uses a different coordinator
    /// and pipeline against those real test-owned files, with no in-memory attempt to adopt.
    func testRetainedStreamingRussianMeetingAndFreshPipelineRetry() async throws {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_MEETING_STREAMING_RETAINED_E2E"] == "1" else {
            throw XCTSkip("Explicitly enable retained streaming and fresh-pipeline recovery inference")
        }
        let options = try CombinedEvaluationOptions(environment: environment)
        guard options.privateEvaluation, !options.longEvaluation, options.repetitions == 1,
              environment["PICHI_MEETING_DETAILED_PROFILE"] == "1" else {
            throw NSError(domain: "RetainedStreamingMeetingRequiresPrivateSingleRunAndDetailedProfile", code: 1)
        }
        let revision = RuntimeBuildProvenance.sanitizedSourceRevision(environment["PICHI_COMBINED_MEETING_TESTED_REVISION"])
        guard revision != "unavailable",
              RuntimeBuildProvenance.sanitizedSourceRevision(Bundle.main.object(forInfoDictionaryKey: "AppSourceRevision")) == revision else {
            throw NSError(domain: "RetainedStreamingMeetingRequiresMatchingFrozenRevision", code: 1)
        }
        var pinned = environment
        pinned["PICHI_COMBINED_MEETING_ASR"] = SettingsStore.SpeechModel.gigaam.rawValue
        try await runCombinedRussianMeeting(environment: pinned, options: options, repetition: 1,
            streaming: true, saveAudio: true, recoverAfterStop: true)
        #else
        throw XCTSkip("Retained streaming private evaluation requires a Debug test host")
        #endif
    }

    private func runCombinedRussianMeeting(environment: [String: String], options: CombinedEvaluationOptions,
        repetition: Int, streaming: Bool = false, saveAudio: Bool = false,
        recoverAfterStop: Bool = false) async throws {
        guard !saveAudio || streaming, !recoverAfterStop || (streaming && saveAudio) else {
            throw NSError(domain: "CombinedMeetingInvalidRetainedTestOptions", code: 1)
        }
        let streamingOptions = streaming ? try StreamingEvaluationOptions(environment: environment, combined: options) : nil
        // Fresh retained recovery uses its existing bounded token comparison. Its
        // reviewed 180-second fixture remains separate from the primary streaming matrix.
        guard !recoverAfterStop || streamingOptions?.expectedSourceFrames == 2_880_000 else {
            throw NSError(domain: "RetainedStreamingMeetingRequiresComplete180SecondFixture", code: 1)
        }
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
        guard input.processingFormat.sampleRate == 16_000, input.processingFormat.channelCount == 1 else {
            throw NSError(domain: "CombinedMeetingPCMFormatOrDuration", code: 1)
        }
        if let streamingOptions {
            try streamingOptions.validatePCM(frameCount: Int64(input.length), fileBytes: audioBytes, combined: options)
        } else {
            try options.validatePCM(frameCount: Int64(input.length), fileBytes: audioBytes)
        }
        let duration = Double(input.length) / 16_000
        try reference.validate(duration: duration, privateEvaluation: options.privateEvaluation)
        let artifactValidationStarted = ProcessInfo.processInfo.systemUptime
        let streamingArtifact = streaming ? try MeetingNemotronModelLocator(profile: .experimentalFast128FP16CPU).locate() : nil
        let candidatePreflightValidationSeconds = streaming ? ProcessInfo.processInfo.systemUptime - artifactValidationStarted : 0
        if streaming {
            // Refuse a missing or wrong graph before any preparation can download a fallback.
            XCTAssertEqual(streamingArtifact?.profile, .experimentalFast128FP16CPU)
        }
        let ownerProfileGenerationAtStart = streaming ? try MeetingOwnerVoiceProfileStore().load()?.metadata.generation : nil
        if streamingOptions?.expectedOwnerCount != nil {
            XCTAssertNotNil(ownerProfileGenerationAtStart, "Both positive and negative owner comparisons require a real existing enrollment")
        }
        let baseline = try XCTUnwrap(physicalFootprintBytes())
        let durablePin = try CombinedDurableEvidencePin(environment: environment, streaming: streaming, options: options,
            actualRevision: RuntimeBuildProvenance.sanitizedSourceRevision(Bundle.main.object(forInfoDictionaryKey: "AppSourceRevision")),
            audioSHA256: audioDigest, sourceFrames: Int64(input.length))
        let durableEvidence: CombinedDurableEvaluationEvidence?
        if let durablePin {
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            durableEvidence = try CombinedDurableEvaluationEvidence(pin: durablePin, cachesDirectory: caches,
                maximumEvidenceBytes: options.maximumProtectedEvidenceBytes)
        } else { durableEvidence = nil }
        let name = "CombinedMeetingProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = asrModel
        settings.meetingRecordingDefaults.languageCode = environment["PICHI_COMBINED_MEETING_LANGUAGE"] ?? "ru"
        settings.meetingSaveAudio = saveAudio
        settings.meetingSpeakerLabelsEnabled = true
        settings.meetingSpeakerProcessingMode = streaming ? .streaming : .afterRecording
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
        let evidenceCollector = streaming ? CombinedStreamingEvidenceCollector(startedMS: Int64(started * 1_000)) : nil
        let processCPUStarted = DiagnosticProcessCPUTime.capture()
        let thermalStateStarted = ProcessInfo.processInfo.thermalState.rawValue
        let resourceSamples = try CombinedResourceSamples(limit: options.maximumSamples,
                                                         intervalSeconds: options.sampleIntervalSeconds)
        let detailedProfiling = MeetingPCMRuntimeDiagnostics.detailedProfilingEnabled
        let progress = (options.longEvaluation || detailedProfiling) ? CombinedLongProgress(started: started) : nil
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
        let mainActorSamples = CombinedMainActorSamples()
        let mainActorInterval = options.longEvaluation ? 0.5 : 0.1
        let mainActorSampler: Task<Void, Never>?
        if detailedProfiling {
            mainActorSampler = Task.detached(priority: .utility) {
                var previousQueued: Double?, previousResumed: Double?
                while !Task.isCancelled {
                    let submittedPhase = mainActorSamples.currentPhase()
                    let queued = ProcessInfo.processInfo.systemUptime
                    let arrival = await MainActor.run {
                        let entered = ProcessInfo.processInfo.systemUptime
                        let phase = mainActorSamples.currentPhase()
                        let isMainThread = Thread.isMainThread
                        let departed = ProcessInfo.processInfo.systemUptime
                        return (entered, departed, phase, isMainThread)
                    }
                    let resumed = ProcessInfo.processInfo.systemUptime
                    guard arrival.3, !Task.isCancelled else { return }
                    mainActorSamples.record(phase: submittedPhase, entryPhase: arrival.2,
                        queued: queued, entered: arrival.0, departed: arrival.1, resumed: resumed,
                        previousQueued: previousQueued, previousResumed: previousResumed)
                    previousQueued = queued; previousResumed = resumed
                    do { try await Task.sleep(nanoseconds: UInt64(mainActorInterval * 1_000_000_000)) }
                    catch { break }
                }
            }
        } else { mainActorSampler = nil }
        defer { mainActorSampler?.cancel() }
        let containerRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let existingAudioPaths: Set<String>
        do {
            existingAudioPaths = streaming ? try CombinedStreamingAudioInventory.paths(in: containerRoot) : []
        } catch {
            // This fallible inventory precedes the main test body. Even this early
            // failure must join both diagnostic owners before leaving the attempt.
            sampler.cancel(); mainActorSampler?.cancel()
            await sampler.value; await mainActorSampler?.value
            try? durableEvidence?.fail(cancelled: error is CancellationError, phase: "preparation",
                assertionFailures: testRun?.totalFailureCount, metadata: Data("{\"inventoryFailed\":true}".utf8))
            throw error
        }
        var observedNewAudioPaths: Set<String> = []
        var checkpointBeforeStop: [MeetingTranscriptSegment] = []
        var firstKnownSpeakerSeconds: Double?
        var firstOwnerProtectedWordSeconds: Double?
        var firstOwnerDeliveredFrames: Int?
        var maximumLiveOwnerSpeakerCount = 0
        var canonicalCheckpointsObserved = 0
        var maximumProtectedSegmentsBeforeStop = 0
        var streamingEvidence: [String: Any] = [:]
        let evidenceSampler: Task<Void, Never>? = evidenceCollector.map { collector in
            Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    collector.capture()
                    do { try await Task.sleep(nanoseconds: UInt64(CombinedStreamingEvidenceCollector.intervalSeconds * 1_000_000_000)) }
                    catch { break }
                }
            }
        }
        defer { evidenceSampler?.cancel() }
        do {
            // The same service operation used by Settings, with pinned artifacts.
            mainActorSamples.setPhase("modelPreparation")
            try await services.asr.downloadModel(asrModel)
            mainActorSamples.setPhase("configurationPreparation")
            let configuration = try await coordinator.defaultConfiguration(mode: .inRoom, title: "Combined Russian probe")
            if streaming {
                XCTAssertEqual(configuration.effectiveSpeakerProcessingMode, .streaming,
                               "The ordinary configuration service must preserve the explicit streaming preference")
                XCTAssertTrue(configuration.speakerLabelsEnabled == true)
                XCTAssertTrue(configuration.piiRedactionEnabled == true)
            }
            let privacyReady = await privacy.isReady
            let preparationSeconds = ProcessInfo.processInfo.systemUptime - started
            XCTAssertEqual(PichiTranscriptPrivacyModelStore.descriptor.id, "ru-pii-ner-a1-int8", "Combined evidence requires the pinned A1 descriptor; preparation can be deferred until PCM arrives")
            phase = "configurationReady"
            resourceSamples.setPhase(phase)
            mainActorSamples.setPhase(phase)
            try await Task.sleep(nanoseconds: 300_000_000)
            mainActorSamples.setPhase("captureAdmission")
            let startRequested = ProcessInfo.processInfo.systemUptime
            let recording = try await coordinator.startRecording(configuration: configuration)
            let startCommandSeconds = ProcessInfo.processInfo.systemUptime - startRequested
            let visibleUI: CombinedVisibleMeetingUI?
            if environment["PICHI_MEETING_RENDER_LIVE_E2E"] == "1" {
                guard streaming, detailedProfiling,
                      environment["PICHI_COMBINED_MEETING_PRIVATE_EVALUATION"] == "1" else {
                    throw NSError(domain: "VisibleMeetingProbeRequiresPrivateStreamingProfile", code: 1)
                }
                visibleUI = try CombinedVisibleMeetingUI(services: services)
            } else { visibleUI = nil }
            defer { visibleUI?.close() }
            XCTAssertEqual(recording.audioStorageMode, saveAudio ? .retainedFiles : .memoryOnly)
            XCTAssertEqual(recording.piiRedactionEnabled, true)
            if streaming { XCTAssertEqual(recording.effectiveSpeakerProcessingMode, .streaming) }
            phase = "capture"
            resourceSamples.setPhase(phase)
            mainActorSamples.setPhase(phase)
            let captureStart = ProcessInfo.processInfo.systemUptime
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 1_600))
            var offset = 0
            var firstProtectedTextSeconds: Double?
            var firstVisibleAnchorSeconds: [Int: Double] = [:]
            var nextAudioInventorySample = 15.0
            var previousProtectedIDs: Set<MeetingTranscriptSegmentID> = []
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
                if streaming, firstVisibleAnchorSeconds.count < reference.textAnchors.count {
                    let live = coordinator.liveTranscript
                    let visible = ((coordinator.activeSession?.transcriptSegments.map(\.text) ?? [])
                        + live.utterances.map(\.text) + live.partials.values.map(\.text)).joined(separator: " ")
                    for (index, anchor) in reference.textAnchors.enumerated()
                    where firstVisibleAnchorSeconds[index] == nil
                        && visible.range(of: anchor, options: [.caseInsensitive]) != nil {
                        firstVisibleAnchorSeconds[index] = ProcessInfo.processInfo.systemUptime - captureStart
                    }
                }
                if streaming, let current = coordinator.activeSession {
                    let protectedSegments = current.transcriptSegments
                    let currentIDs = Set(protectedSegments.map(\.id))
                    if currentIDs != previousProtectedIDs {
                        canonicalCheckpointsObserved += 1
                        previousProtectedIDs = currentIDs
                    }
                    maximumProtectedSegmentsBeforeStop = max(maximumProtectedSegmentsBeforeStop, protectedSegments.count)
                    XCTAssertEqual(currentIDs.count, protectedSegments.count, "Canonical checkpoints must never contain duplicate word identities")
                    XCTAssertTrue(protectedSegments.allSatisfy { $0.originalText == nil })
                    if firstKnownSpeakerSeconds == nil,
                       protectedSegments.contains(where: { segment in
                           segment.speakerID.map { id in current.speakers.contains { $0.id == id } } == true
                       }) {
                        firstKnownSpeakerSeconds = ProcessInfo.processInfo.systemUptime - captureStart
                    }
                    let ownerIDs = Set(current.speakers.filter(\.isLocalUser).map(\.id))
                    maximumLiveOwnerSpeakerCount = max(maximumLiveOwnerSpeakerCount, ownerIDs.count)
                    if firstOwnerProtectedWordSeconds == nil,
                       protectedSegments.contains(where: { $0.speakerID.map(ownerIDs.contains) == true }) {
                        firstOwnerProtectedWordSeconds = ProcessInfo.processInfo.systemUptime - captureStart
                        firstOwnerDeliveredFrames = offset
                    }
                    let sourceSeconds = Double(offset) / 16_000
                    if sourceSeconds >= nextAudioInventorySample {
                        observedNewAudioPaths.formUnion(try CombinedStreamingAudioInventory.paths(in: containerRoot).subtracting(existingAudioPaths))
                        nextAudioInventorySample += 15
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
            // A physical microphone almost never stops on an exact 10 ms boundary.
            // Keep the reviewed source intact, then exercise the same residual
            // sample count as the reported Stop failure with 5.5 ms of silence.
            let terminalSilenceSamples = streaming ? 88 : 0
            if terminalSilenceSamples > 0 {
                try await microphone.deliver([Float](repeating: 0, count: terminalSilenceSamples), startingAt: offset)
                offset += terminalSilenceSamples
            }
            if streaming {
                checkpointBeforeStop = coordinator.activeSession?.transcriptSegments ?? []
                let ownerMetrics: [String: Any] = ["event": "streamingOwnerBeforeStop",
                    "sourceFrames": offset,
                    "firstOwnerProtectedWordSeconds": firstOwnerProtectedWordSeconds as Any? ?? NSNull(),
                    "firstOwnerDeliveredFrames": firstOwnerDeliveredFrames as Any? ?? NSNull(),
                    "maximumLiveOwnerSpeakerCount": maximumLiveOwnerSpeakerCount,
                    "protectedCanonicalSegments": checkpointBeforeStop.count]
                print(String(decoding: try JSONSerialization.data(withJSONObject: ownerMetrics, options: [.sortedKeys]), as: UTF8.self))
                if streamingOptions?.requiresPreStopOutput == true,
                   streamingOptions?.requiresRecognizedSpeech(referenceProvenance: reference.provenance) == true {
                    XCTAssertGreaterThan(canonicalCheckpointsObserved, 0, "Streaming must publish canonical protected checkpoints before Stop")
                    XCTAssertFalse(checkpointBeforeStop.isEmpty, "Live partial text alone is not evidence of streaming canonical output")
                    XCTAssertNotNil(firstKnownSpeakerSeconds, "At least one actual voice must label protected canonical words before Stop")
                }
                observedNewAudioPaths.formUnion(try CombinedStreamingAudioInventory.paths(in: containerRoot).subtracting(existingAudioPaths))
                XCTAssertTrue(CombinedStreamingAudioInventory.onlyAllowed(observedNewAudioPaths, retainedRoot: saveAudio ? root : nil),
                              "Only explicitly retained audio in this isolated test root may be created")
            }
            phase = "postStop"
            resourceSamples.setPhase(phase)
            mainActorSamples.setPhase(phase)
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
            mainActorSamples.setPhase(phase)
            try await Task.sleep(nanoseconds: 300_000_000)
            mainActorSamples.setPhase("completedValidation")
            XCTAssertEqual(completed.state, .completed)
            let diarizationModels = completed.processingAttempts.compactMap(\.diarizationModel)
            let expectedProfile: MeetingNemotronModelProfile = streaming ? .experimentalFast128FP16CPU : .fast32SplitW8A8
            let expectedDiarization = streaming ? expectedProfile.streamingImplementationFingerprint
                : expectedProfile.implementationFingerprint
            XCTAssertFalse(diarizationModels.isEmpty, "The completed attempt must record its actual frozen diarizer lineage")
            if streaming {
                XCTAssertTrue(diarizationModels.allSatisfy { $0 == expectedDiarization },
                              "Streaming evidence requires the exact pinned graph and CPU compute policy without another model lineage")
            } else {
                XCTAssertTrue(diarizationModels.allSatisfy { $0.hasPrefix(expectedDiarization) },
                              "Combined evidence requires fast32 W8A8, including its pinned runtime and weight identity")
            }
            XCTAssertTrue(completed.processingAttempts.contains { $0.asrModel == asrModel.rawValue })
            XCTAssertTrue(completed.processingAttempts.allSatisfy { $0.asrModel == asrModel.rawValue },
                          "Every attempt must retain the selected ASR identity")
            let requiresRecognizedSpeech = streamingOptions?.requiresRecognizedSpeech(referenceProvenance: reference.provenance) ?? true
            if requiresRecognizedSpeech {
                XCTAssertFalse(completed.transcriptSegments.isEmpty, "Actual ASR must produce final protected text")
                XCTAssertTrue(completed.transcriptSegments.contains { $0.text.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil },
                              "Actual ASR must produce Russian text")
            }
            XCTAssertEqual(completed.hasFinalizedAudio, saveAudio)
            if saveAudio {
                XCTAssertTrue(completed.hasRetryableAudio)
                XCTAssertTrue(completed.audioTracks.flatMap(\.chunks).allSatisfy { $0.finalizationState == .finalized && $0.byteCount > 0 })
            }
            XCTAssertTrue(completed.transcriptSegments.allSatisfy { $0.originalText == nil })
            if streaming {
                evidenceSampler?.cancel()
                await evidenceSampler?.value
                streamingEvidence = try await streamingEvaluation(completed: completed,
                    checkpoint: checkpointBeforeStop, sourceFrames: offset, started: started,
                    captureStarted: captureStart, stopStarted: stopStart, completedAt: started + completedWallSeconds,
                    firstKnownSpeakerSeconds: firstKnownSpeakerSeconds,
                    canonicalCheckpointsObserved: canonicalCheckpointsObserved,
                    maximumProtectedSegmentsBeforeStop: maximumProtectedSegmentsBeforeStop, saveAudio: saveAudio,
                    requiresRecognizedSpeech: requiresRecognizedSpeech,
                    requiresPreStopOutput: streamingOptions?.requiresPreStopOutput == true && requiresRecognizedSpeech,
                    evidenceCollector: try XCTUnwrap(evidenceCollector))
                if let expectedOwnerCount = streamingOptions?.expectedOwnerCount {
                    let actualOwnerCount = completed.speakers.filter(\.isLocalUser).count
                    XCTAssertEqual(actualOwnerCount, expectedOwnerCount, "Compare the enrolled owner's actual production verification with the reviewed fixture expectation")
                    streamingEvidence["expectedOwnerCount"] = expectedOwnerCount
                    if expectedOwnerCount == 0 {
                        XCTAssertEqual(maximumLiveOwnerSpeakerCount, 0, "A reviewed negative voice cannot become the owner during capture")
                    } else if streamingOptions?.requiresPreStopOutput == true {
                        XCTAssertNotNil(firstOwnerProtectedWordSeconds, "A reviewed owner must label actual protected words before Stop")
                    }
                }
                let ownerProfileGenerationAfterStop = try MeetingOwnerVoiceProfileStore().load()?.metadata.generation
                XCTAssertEqual(ownerProfileGenerationAfterStop, ownerProfileGenerationAtStart,
                               "The real enrolled profile must remain unchanged during private streaming evaluation")
                streamingEvidence["ownerEnrollmentAvailableAtStart"] = ownerProfileGenerationAtStart != nil
                streamingEvidence["ownerEnrollmentUnchangedAfterStop"] = ownerProfileGenerationAfterStop == ownerProfileGenerationAtStart
                streamingEvidence["ownerVerificationExpectationApplied"] = streamingOptions?.expectedOwnerCount != nil
                streamingEvidence["verifiedOwnerSpeakerCount"] = completed.speakers.filter(\.isLocalUser).count
                streamingEvidence["firstOwnerProtectedWordSeconds"] = firstOwnerProtectedWordSeconds.map { $0 as Any } ?? NSNull()
                streamingEvidence["firstOwnerDeliveredFrames"] = firstOwnerDeliveredFrames.map { $0 as Any } ?? NSNull()
                streamingEvidence["maximumLiveOwnerSpeakerCount"] = maximumLiveOwnerSpeakerCount
                streamingEvidence["ownerVerificationScope"] = "Production enrolled profile, paced live protected words and completed session; no profile replacement or exported identity/embeddings. Identity accuracy requires independently reviewed voice labels."
                streamingEvidence["expectedSourceAudioFrames"] = streamingOptions?.expectedSourceFrames
                streamingEvidence["recognizedSpeechAssertionsApplied"] = requiresRecognizedSpeech
                streamingEvidence["preStopOutputAssertionsApplied"] = streamingOptions?.requiresPreStopOutput == true && requiresRecognizedSpeech
                streamingEvidence["firstVisibleTextAnchorSeconds"] = reference.textAnchors.indices.map { index in
                    ["referenceAnchorIndex": index,
                     "captureSeconds": firstVisibleAnchorSeconds[index].map { $0 as Any } ?? NSNull()] as [String: Any]
                }
                streamingEvidence["textAnchorClockScope"] = "First protected coordinator publication polled after paced PCM delivery, including canonical text and ephemeral previews; not a rendered-frame or microphone measurement."
                observedNewAudioPaths.formUnion(try CombinedStreamingAudioInventory.paths(in: containerRoot).subtracting(existingAudioPaths))
                XCTAssertTrue(CombinedStreamingAudioInventory.onlyAllowed(observedNewAudioPaths, retainedRoot: saveAudio ? root : nil))
                streamingEvidence["newPersistentAudioOrMediaPathsObserved"] = observedNewAudioPaths.count
                streamingEvidence["sourceAudioFrames"] = Int(input.length)
                streamingEvidence["terminalSilenceRegressionSamples"] = terminalSilenceSamples
                streamingEvidence["retainedTestRootAudioPermitted"] = saveAudio
                streamingEvidence["audioInventoryCadenceSeconds"] = 15
                streamingEvidence["audioInventoryScope"] = "App container including temporary directory; before preparation, paced input and completion; transient create/delete between observations not proven absent"
                let currentArtifact = try MeetingNemotronModelLocator(profile: expectedProfile).locate()
                XCTAssertEqual(currentArtifact.profile, expectedProfile)
                XCTAssertTrue(currentArtifact == streamingArtifact, "The installed pinned artifact must remain unchanged throughout the attempt")
            }
            let protectedText = completed.transcriptSegments.map(\.text).joined(separator: " ")
            let matchedAnchors = reference.textAnchors.filter { protectedText.range(of: $0, options: [.caseInsensitive]) != nil }.count
            let agreementUnavailableReason = options.attributionAgreementUnavailableReason(referenceContainsOverlap: reference.containsOverlap)
            let agreementAvailable = agreementUnavailableReason == nil
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
            mainActorSamples.setPhase("historyReload")
            let saved = try await store.load(id: completed.id)
            XCTAssertTrue(saved?.transcriptSegments == completed.transcriptSegments, "Reloaded protected segments must match without logging their contents")
            mainActorSamples.setPhase("diagnosticExport")
            let exportBegan = MeetingPCMRuntimeDiagnostics.beginDetailed(.diagnosticExport)
            let export = try MeetingTranscriptExporter.json(for: completed)
            MeetingPCMRuntimeDiagnostics.completedDetailed(.diagnosticExport, since: exportBegan,
                samples: completed.transcriptSegments.count)
            XCTAssertEqual(observations.remainingCases(in: String(decoding: export, as: UTF8.self)), 0)
            let payload = try MeetingSharePayload.transcript(data: export, title: completed.title, fileExtension: "json")
            defer { payload.cleanup() }
            XCTAssertFalse(payload.includesAudio)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let file as URL in files where try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                if !saveAudio { XCTAssertEqual(file.pathExtension, "json", "Strict storage may persist protected JSON only") }
            }
            XCTAssertTrue(coordinator.pendingSpeech.tokens.isEmpty)
            XCTAssertNil(services.asr.activeExclusiveActivity)
            XCTAssertFalse(services.asr.hasActiveModelPreparation)
            XCTAssertFalse(services.asr.hasActiveModelDownload)
            mainActorSamples.setPhase("privacyRelease")
            try await privacy.unload()
            let privacyStillReady = await privacy.isReady
            XCTAssertFalse(privacyStillReady)
            var explicitAliasSaveSeconds: Double?
            var explicitAliasMaintenanceWaitSeconds: Double?
            if detailedProfiling, let participant = completed.activeSpeakers.first {
                // A completed coordinator still owns normal history actions. Termination
                // deliberately closes that owner permanently, so benchmark before shutdown.
                // Exclude independent retention from this save-only measurement, and report
                // its wait separately rather than attributing background work to alias I/O.
                mainActorSamples.setPhase("aliasMaintenance")
                let maintenanceBegan = ProcessInfo.processInfo.systemUptime
                for _ in 0..<200 {
                    if coordinator.isQuiescent { break }
                    try await Task.sleep(nanoseconds: 25_000_000)
                }
                explicitAliasMaintenanceWaitSeconds = ProcessInfo.processInfo.systemUptime - maintenanceBegan
                XCTAssertTrue(coordinator.isQuiescent, "Background retention must release its mutation gate before the alias benchmark")
                mainActorSamples.setPhase("aliasSave")
                let beforeAlias = ProcessInfo.processInfo.systemUptime
                let renamed = try await coordinator.renameSpeaker(sessionID: completed.id,
                    speakerID: participant.id, to: "Explicit participant alias")
                explicitAliasSaveSeconds = ProcessInfo.processInfo.systemUptime - beforeAlias
                XCTAssertEqual(renamed.activeSpeakers.first(where: { $0.id == participant.id })?.displayName,
                               "Explicit participant alias")
                XCTAssertEqual(renamed.transcriptSegments, completed.transcriptSegments)
                mainActorSamples.setPhase("aliasRestore")
                let restored = try await coordinator.undoTranscriptCorrection(sessionID: completed.id)
                XCTAssertEqual(restored.activeSpeakers, completed.activeSpeakers)
                XCTAssertEqual(restored.transcriptSegments, completed.transcriptSegments)
                let privacyReadyAfterAlias = await privacy.isReady
                XCTAssertFalse(privacyReadyAfterAlias, "Renaming must not prepare the speech privacy model again")
            }
            mainActorSamples.setPhase("cleanup")
            await coordinator.shutdownForTermination()
            if recoverAfterStop {
                resourceSamples.capture(since: started)
                phase = "betweenAttemptsRelease"
                resourceSamples.setPhase(phase)
                mainActorSamples.setPhase(phase)
                let firstASRReadyBeforeRelease = services.asr.isAsrReady
                try await services.asr.meetingResidencyParticipant().suspend()
                let firstASRReadyAfterRelease = services.asr.isAsrReady
                XCTAssertFalse(firstASRReadyAfterRelease, "Release the first composition's cached ASR before constructing another")
                streamingEvidence["firstASRReadyBeforeRelease"] = firstASRReadyBeforeRelease
                streamingEvidence["firstASRReadyAfterRelease"] = firstASRReadyAfterRelease
                streamingEvidence["firstASRResidencyReleaseJoined"] = true
                try await privacy.unload()
                let previousPrivacyStillReady = await privacy.isReady
                XCTAssertFalse(previousPrivacyStillReady, "The first inference owner must unload before cold privacy recovery begins")
                phase = "retainedRecovery"
                resourceSamples.setPhase(phase)
                mainActorSamples.setPhase(phase)
                progress?.update(phase: phase, deliveredFrames: Int(input.length), protectedUtterances: 0,
                    protectedPartials: 0, protectedFinalSegments: completed.transcriptSegments.count)
                progress?.emit(force: true)
                streamingEvidence["retainedRecovery"] = try await retainedStreamingRecovery(completed: completed,
                    store: store, settings: settings, privacyModelDirectory: assets.appendingPathComponent("models/privacy"), reference: reference,
                    root: root, sourceFrames: offset, expectedDiarizationFingerprint: expectedDiarization)
                progress?.update(phase: "retainedRecoveryEnd", deliveredFrames: Int(input.length), protectedUtterances: 0,
                    protectedPartials: 0, protectedFinalSegments: completed.transcriptSegments.count)
                progress?.emit(force: true)
                observedNewAudioPaths.formUnion(try CombinedStreamingAudioInventory.paths(in: containerRoot).subtracting(existingAudioPaths))
                XCTAssertTrue(CombinedStreamingAudioInventory.onlyAllowed(observedNewAudioPaths, retainedRoot: root),
                              "Fresh retained retry must not write media outside this test-owned root")
                streamingEvidence["newPersistentAudioOrMediaPathsObserved"] = observedNewAudioPaths.count
                streamingEvidence["audioInventoryScope"] = "App container including temporary directory; before preparation, every15seconds during paced capture, and before/after joined Stop and retained retry; transient create/delete between observations not proven absent"
            }
            phase = "cleanup"
            resourceSamples.setPhase(phase)
            mainActorSamples.setPhase(phase)
            try await Task.sleep(nanoseconds: 500_000_000)
            evidenceSampler?.cancel()
            await evidenceSampler?.value
            sampler.cancel()
            await sampler.value
            mainActorSampler?.cancel()
            await mainActorSampler?.value
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
                "detailedProfilingEnabled": detailedProfiling,
                "streamingEvaluationEnabled": streaming,
                "saveAudioEnabled": saveAudio,
                "freshPipelineRetainedRecoveryEnabled": recoverAfterStop,
                "candidateArtifactValidatedBeforeMeasurement": streaming,
                "computeUnitsDiagnosticOverride": detailedProfiling && environment["PICHI_MEETING_PROFILE_COMPUTE_UNITS"] == "cpuOnly" ? "cpuOnly" : "automatic",
                "legacySimulatorReviewEnabled": Self.isSimulator && environment["PICHI_COMBINED_MEETING_EXPORT_PRIVATE_REVIEW"] == "1"
            ]
            if let limit = environment["PICHI_COMBINED_MEETING_MAX_FOOTPRINT_MIB"] {
                let maximum = try XCTUnwrap(UInt64(limit))
                XCTAssertLessThanOrEqual(Double(peak) / 1_048_576, Double(maximum), "Whole-process sampled peak exceeds the explicitly configured budget")
            }
            XCTAssertEqual(resources.missing, 0)
            XCTAssertEqual(resources.omitted, 0, "A bounded diagnostic buffer must cover the entire completed attempt")
            var report: [String: Any] = [
                "schema": 2, "physicalDevice": !Self.isSimulator, "referenceProvenance": reference.provenance,
                "strongReferenceQualityAssertionsApplied": assertsReferenceQuality,
                "audioSHA256": audioDigest, "referenceSHA256": referenceDigest,
                "testedRevision": environment["PICHI_COMBINED_MEETING_TESTED_REVISION"] ?? "unrecorded",
                "asr": asrModel.rawValue,
                "privacyModel": PichiTranscriptPrivacyModelStore.descriptor.id,
                "diarizationModels": diarizationModels,
                "expectedDiarizationFingerprint": expectedDiarization,
                "audioSeconds": duration, "postStopSeconds": stopSeconds,
                "inputFrameCount": input.length,
                "detailedProfilingEnabled": detailedProfiling,
                "computePlanDiagnosticIncludedAfterInference": MeetingCoreMLComputeDiagnostics.requested(environment: environment),
                "computePlanOverheadIncluded": MeetingCoreMLComputeDiagnostics.requested(environment: environment),
                "audioByteLimit": options.maximumAudioBytes,
                "protectedEvidenceByteLimit": options.maximumProtectedEvidenceBytes,
                "totalWallSeconds": totalWallSeconds, "completedWallSeconds": completedWallSeconds,
                "wallClockOrigin": "service composition ready, before model preparation; excludes fixture hashing and streaming candidate preflight artifact validation",
                "candidatePreflightArtifactValidationSecondsExcluded": candidatePreflightValidationSeconds,
                "totalWallIncludesDiagnosticHolds": true,
                "preparationSeconds": preparationSeconds, "captureWallSeconds": stopStart - captureStart,
                "preparationClock": "Service composition to configuration admission; native model preparation can continue during capture.",
                "privacyReadyAfterConfiguration": privacyReady,
                "startCommandSeconds": startCommandSeconds,
                "startCommandScope": "Coordinator admission to synthetic capture start return; not physical microphone activation or touch latency.",
                "liveProductionUIRendered": visibleUI != nil,
                "liveProductionUIScope": "When enabled, the production root renders this exact isolated coordinator in a test-owned foreground window. Native external one-second screenshots are indexed separately. No automated touch or scrolling latency is claimed.",
                "mainActorResponsiveness": mainActorSamples.json(interval: mainActorInterval),
                "explicitAliasSaveSeconds": explicitAliasSaveSeconds as Any? ?? NSNull(),
                "explicitAliasMaintenanceWaitSeconds": explicitAliasMaintenanceWaitSeconds as Any? ?? NSNull(),
                "explicitAliasSaveScope": "Coordinator load, metadata correction and durable save on the actual protected fixture output; excludes separately reported retention wait, touch and layout. Alias restored afterward.",
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
                "sampleScope": "Service composition ready through inference and cleanup; excludes subsequent protected JSON serialization and attachment allocation",
                "omittedFootprintSamples": resources.omitted, "missingFootprintSamples": resources.missing,
                "maximumSampleGapSeconds": resources.maximumGap, "missedSampleIntervals": resources.missedIntervals,
                "attributionAgreement": agreementAvailable ? agreement as Any : NSNull(),
                "attributionAgreementAvailable": agreementAvailable,
                "attributionAgreementUnavailableReason": agreementUnavailableReason as Any? ?? NSNull(),
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
            if recoverAfterStop {
                let firstPhases: Set<String> = ["preparation", "privacyReady", "capture", "postStop", "completedPrivacyReady"]
                let firstSamples = resources.samples.filter { firstPhases.contains($0.phase) }
                let retrySamples = resources.samples.filter { $0.phase == "retainedRecovery" }
                report["firstStreamingPeakFootprintBytes"] = firstSamples.map(\.bytes).max() as Any? ?? NSNull()
                report["firstStreamingFootprintSampleCount"] = firstSamples.count
                report["retainedRetryPeakFootprintBytes"] = retrySamples.map(\.bytes).max() as Any? ?? NSNull()
                report["retainedRetryFootprintSampleCount"] = retrySamples.count
                report["peakFootprintScope"] = "peakFootprintBytes covers both attempts and joined cleanup; firstStreamingPeakFootprintBytes excludes fresh retained retry; retainedRetryPeakFootprintBytes covers its own phase including source verification"
                report["sampleScope"] = "Two attempts and joined cleanup, with explicit phase tags; includes the private recovery attachment allocation; excludes the following combined report/attachment serialization"
                report["processCPUScope"] = "Whole process across first streaming attempt, inter-attempt release, fresh retained retry and cleanup"
            }
            if streaming { report["streaming"] = streamingEvidence }
            let metadataData = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            var protectedReviewData: Data?
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
                    "attributionAgreementUnavailableReason": agreementUnavailableReason as Any? ?? NSNull(),
                    "referenceContainsOverlap": reference.containsOverlap,
                    "asrArtifactFingerprints": completed.processingAttempts.compactMap(\.asrArtifactFingerprint),
                    "limitations": "Post-privacy product values only; metadata may be absent or privacy-coarsened. No invented word timings, audio, embeddings, contact identities or source-separated overlap words. WER/CER and overlap scoring require offline reference."
                ]
                visualReview.merge(try CombinedProtectedEvaluation.values(segments: completed.transcriptSegments, speakers: completed.speakers)) { _, new in new }
                if streaming { visualReview["streaming"] = streamingEvidence }
                let reviewData = try JSONSerialization.data(withJSONObject: visualReview, options: [.prettyPrinted, .sortedKeys])
                guard reviewData.count <= options.maximumProtectedEvidenceBytes else {
                    throw NSError(domain: "CombinedMeetingProtectedEvidenceSize", code: 2)
                }
                protectedReviewData = reviewData
            }
            if let durableEvidence {
                // Refuse persistence if any known privacy invariant failed. Anonymous
                // voice IDs and post-privacy native timings use the existing exporter.
                guard completed.state == .completed,
                      completed.transcriptSegments.allSatisfy({ $0.originalText == nil }),
                      observations.unmaskedPublishableObservations == 0,
                      observations.remainingCases(in: protectedText) == 0,
                      let protectedReviewData else {
                    throw NSError(domain: "CombinedMeetingDurableEvidencePrivacy", code: 1)
                }
                try durableEvidence.finish(metadata: metadataData, protectedEvaluation: protectedReviewData,
                    assertionFailures: testRun?.totalFailureCount)
            }
            let attachment = XCTAttachment(data: metadataData, uniformTypeIdentifier: "public.json")
            attachment.name = (recoverAfterStop ? "Retained-Streaming-Russian-meeting-metadata-only" : streaming ? "Streaming-Russian-meeting-metadata-only" : "Combined-Russian-meeting-metadata-only") + (options.repetitions > 1 ? "-run-\(repetition)" : "")
            attachment.lifetime = .keepAlways
            add(attachment)
            if let protectedReviewData {
                let review = XCTAttachment(data: protectedReviewData, uniformTypeIdentifier: "public.json")
                review.name = recoverAfterStop ? "Retained-Streaming-Russian-meeting-private-protected-evaluation" : streaming ? "Streaming-Russian-meeting-private-protected-evaluation" : (options.privateEvaluation ? "Combined-Russian-meeting-private-protected-evaluation" : "Combined-Russian-meeting-private-visual-review")
                    + (options.repetitions > 1 ? "-run-\(repetition)" : "")
                review.lifetime = .keepAlways
                add(review)
            }
        } catch {
            progress?.emit(force: true)
            await coordinator.shutdownForTermination()
            if recoverAfterStop { try? await services.asr.meetingResidencyParticipant().suspend() }
            try? await privacy.unload()
            evidenceSampler?.cancel()
            await evidenceSampler?.value
            sampler.cancel()
            await sampler.value
            mainActorSampler?.cancel()
            await mainActorSampler?.value
            let failed = try JSONSerialization.data(withJSONObject: ["phase": phase, "runIndex": repetition,
                "footprintSamples": resourceSamples.snapshot().samples.map(\.json)], options: [.sortedKeys])
            do {
                try durableEvidence?.fail(cancelled: error is CancellationError, phase: phase,
                    assertionFailures: testRun?.totalFailureCount, metadata: failed)
            } catch { XCTFail("Private durable failure diagnostics could not be written") }
            let attachment = XCTAttachment(data: failed, uniformTypeIdentifier: "public.json")
            attachment.name = "Combined-Russian-meeting-failure-resource-samples"
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }
    }

    private func retainedStreamingRecovery(completed: MeetingSession, store: MeetingSessionStore,
        settings: SettingsStore, privacyModelDirectory: URL, reference: CombinedMeetingReference,
        root: URL, sourceFrames: Int, expectedDiarizationFingerprint: String) async throws -> [String: Any] {
        let directory = try await store.sessionDirectory(for: completed.id)
        let sourceBefore = try retainedAudioProof(session: completed, directory: directory, root: root)
        XCTAssertEqual(sourceBefore.frames, sourceFrames, "The real retained writer must finalize every paced source frame")
        XCTAssertFalse(sourceBefore.digests.isEmpty)
        let completedAttemptIDs = Set(completed.processingAttempts.map(\.id))
        let originalAttempt = try XCTUnwrap(completed.processingAttempts.last(where: { $0.completedAt != nil }))
        XCTAssertEqual(originalAttempt.diarizationModel, expectedDiarizationFingerprint,
                       "The first attempt must pin the complete streaming recipe, including owner verification")
        let freshPrivacy = PichiTranscriptPrivacyService(modelStore: .init(directory: privacyModelDirectory))
        let privacyReadyBeforeRetry = await freshPrivacy.isReady
        XCTAssertFalse(privacyReadyBeforeRetry, "Fresh privacy runtime must start unprepared")
        // The previous redactor has unloaded. Live controller, queue, native speaker,
        // privacy runtime and coordinator references are new, in this same OS process.
        let savedCompleted = try await store.load(id: completed.id)
        var interrupted = try XCTUnwrap(savedCompleted)
        interrupted.state = .interrupted
        interrupted.recoveryResolvedAt = nil
        interrupted.updatedAt = Date()
        try await store.save(interrupted)
        let savedInterrupted = try await store.load(id: completed.id)
        let reloaded = try XCTUnwrap(savedInterrupted)
        XCTAssertEqual(reloaded.state, .interrupted)
        XCTAssertTrue(reloaded.hasRetryableAudio)
        XCTAssertEqual(reloaded.effectiveSpeakerProcessingMode, .streaming)
        // New-capture preferences are independent of this persisted recording's pin.
        settings.selectedSpeechModel = .whisperTiny
        settings.meetingTranscriptionBackendID = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(
            for: SettingsStore.SpeechModel.whisperTiny.rawValue)).id
        settings.meetingSpeakerProcessingMode = .afterRecording
        let observations = CombinedPrivacyObservations(wrapping: freshPrivacy, aliases: reference.sensitiveAliases)
        let recoveryCapture = SyntheticMeetingMicrophone()
        let fresh = AppServices(store: store, capture: recoveryCapture, settings: settings,
            privacy: freshPrivacy, privacyRedactor: observations,
            microphoneResolver: { _ in .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone") })
        XCTAssertTrue(fresh.meetingProcessingPipeline.memoryAttempts.isEmpty,
                      "A restored session must not depend on the previous live PCM attempt")
        let coordinator = fresh.meetingSessionCoordinator
        let began = ProcessInfo.processInfo.systemUptime
        let recoveryRunID = UUID().uuidString
        DebugLogger.shared.info("recoveryID=\(recoveryRunID) event=begin", source: "MeetingRetainedStreamingEvaluation")
        do {
            await coordinator.ensureRestored()
            let restoreSeconds = ProcessInfo.processInfo.systemUptime - began
            XCTAssertEqual(coordinator.activeSession?.id, completed.id)
            XCTAssertFalse(coordinator.isRecording)
            XCTAssertTrue(fresh.meetingProcessingPipeline.memoryAttempts.isEmpty)
            // Restoration records a pending recovery offer. Retry closes that
            // audit entry and creates one inference attempt, so measure from the
            // restored state rather than from the previous completed session.
            let restoredAttempts = try XCTUnwrap(coordinator.activeSession).processingAttempts
            let attemptsBeforeRetry = Set(restoredAttempts.map(\.id))
            XCTAssertTrue(completedAttemptIDs.isSubset(of: attemptsBeforeRetry))
            let recoveryOffers = restoredAttempts.filter { !completedAttemptIDs.contains($0.id) }
            XCTAssertEqual(recoveryOffers.count, 1)
            XCTAssertTrue(recoveryOffers.allSatisfy { $0.stage == .pending && $0.completedAt == nil })
            let retryBegan = ProcessInfo.processInfo.systemUptime
            // This is the existing History/Resume service operation. It plans its own
            // retained-file backend and prepares required resources through production code.
            let recovered = try await coordinator.retryProcessing(sessionID: completed.id)
            let privacyReadyAfterRetry = await freshPrivacy.isReady
            XCTAssertTrue(privacyReadyAfterRetry, "The existing retry operation must prepare its fresh privacy capability before publication")
            let finished = ProcessInfo.processInfo.systemUptime
            XCTAssertEqual(recovered.state, .completed)
            XCTAssertEqual(recovered.id, completed.id)
            XCTAssertEqual(recovered.audioStorageMode, .retainedFiles)
            XCTAssertEqual(recovered.effectiveSpeakerProcessingMode, .streaming)
            XCTAssertEqual(recovered.recordingBackendID, completed.recordingBackendID)
            XCTAssertEqual(recovered.recordingASRArtifactFingerprint, completed.recordingASRArtifactFingerprint)
            XCTAssertEqual(recovered.languageCode, completed.languageCode)
            XCTAssertEqual(recovered.piiRedactionEnabled, true)
            XCTAssertTrue(recovered.hasRetryableAudio)
            XCTAssertEqual(recovered.transcriptIsComplete, true, "A successful retry must cover its finalized retained source")
            let newAttempts = recovered.processingAttempts.filter { !attemptsBeforeRetry.contains($0.id) }
            XCTAssertEqual(newAttempts.count, 1, "Exactly one new attempt should replace interrupted processing")
            XCTAssertTrue(attemptsBeforeRetry.isSubset(of: Set(recovered.processingAttempts.map(\.id))))
            XCTAssertTrue(recoveryOffers.allSatisfy { offer in
                recovered.processingAttempts.contains { $0.id == offer.id && $0.completedAt != nil }
            }, "Retry must close the restored recovery offer and preserve its audit history")
            let attempt = try XCTUnwrap(newAttempts.last)
            XCTAssertEqual(attempt.stage, .completed)
            XCTAssertNotNil(attempt.completedAt)
            XCTAssertEqual(attempt.asrModel, SettingsStore.SpeechModel.gigaam.rawValue)
            XCTAssertEqual(attempt.asrArtifactFingerprint, originalAttempt.asrArtifactFingerprint,
                           "Recovery must retain the same actual ASR artifact")
            XCTAssertEqual(attempt.diarizationModel, expectedDiarizationFingerprint,
                           "Retained recovery must use the exact pinned streaming and owner-verification recipe")
            XCTAssertEqual(attempt.diarizationModel, originalAttempt.diarizationModel,
                           "Fresh recovery must preserve the first attempt's complete diarization identity")
            XCTAssertEqual(attempt.backendID, originalAttempt.backendID)
            XCTAssertTrue(fresh.meetingProcessingPipeline.memoryAttempts.isEmpty,
                          "Retained retry must not manufacture a replacement live capture attempt")
            let segments = recovered.transcriptSegments
            XCTAssertFalse(segments.isEmpty)
            XCTAssertTrue(segments.contains { $0.nativePrecision == .word })
            XCTAssertEqual(Set(segments.map(\.id)).count, segments.count)
            let nativeIDs = segments.compactMap(\.nativeUnitID)
            XCTAssertEqual(Set(nativeIDs).count, nativeIDs.count, "Fresh attempts may change IDs but may never duplicate their own units")
            XCTAssertTrue(segments.allSatisfy { $0.originalText == nil && $0.status == .final })
            XCTAssertTrue(segments.allSatisfy {
                guard let timing = $0.nativeTiming else { return true }
                return timing.start.isFinite && timing.end.isFinite && timing.start >= 0
                    && timing.end > timing.start && timing.end <= Double(sourceFrames) / 16_000 + 0.001
            })
            let known = segments.filter { segment in
                segment.speakerID.map { id in recovered.speakers.contains { $0.id == id } } == true
            }.count
            XCTAssertGreaterThan(known, 0, "Retained recovery must recover actual speaker-labelled words")
            let protectedText = segments.map(\.text).joined(separator: " ")
            XCTAssertEqual(observations.unmaskedPublishableObservations, 0)
            XCTAssertEqual(observations.remainingCases(in: protectedText), 0)
            let savedRecovery = try await store.load(id: recovered.id)
            let saved = try XCTUnwrap(savedRecovery)
            XCTAssertTrue(saved.transcriptSegments == segments)
            let sourceAfter = try retainedAudioProof(session: saved, directory: directory, root: root)
            XCTAssertTrue(sourceBefore.digests == sourceAfter.digests, "Retry must preserve every finalized source audio file byte for byte")
            XCTAssertEqual(sourceAfter.frames, sourceFrames)
            XCTAssertEqual(saved.audioTracks.flatMap(\.chunks), completed.audioTracks.flatMap(\.chunks))
            XCTAssertNil(fresh.asr.activeExclusiveActivity)
            XCTAssertFalse(fresh.asr.hasActiveModelPreparation)
            XCTAssertFalse(fresh.asr.hasActiveModelDownload)
            await coordinator.shutdownForTermination()
            try await fresh.asr.meetingResidencyParticipant().suspend()
            let recoveryASRReadyAfterRelease = fresh.asr.isAsrReady
            XCTAssertFalse(recoveryASRReadyAfterRelease)
            try await freshPrivacy.unload()
            let privacyReadyAfterCleanup = await freshPrivacy.isReady
            XCTAssertFalse(privacyReadyAfterCleanup)
            let sourceTokens = completed.transcriptSegments.flatMap { $0.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }
            let retryTokens = segments.flatMap { $0.text.lowercased().split(whereSeparator: \.isWhitespace).map(String.init) }
            guard sourceTokens.count <= 4_096, retryTokens.count <= 4_096 else {
                throw NSError(domain: "RetainedStreamingProtectedComparisonBudget", code: 1)
            }
            let differences = Self.protectedTokenEditDistance(sourceTokens, retryTokens)
            let barrierID = UUID().uuidString
            DebugLogger.shared.info("evaluationID=\(barrierID)", source: "MeetingStreamingEvaluation")
            var lines: [String] = []
            var sawBarrier = false
            for _ in 0..<20 {
                lines = try CombinedStreamingDiagnostics.lines()
                sawBarrier = lines.contains { $0.contains("[MeetingStreamingEvaluation]")
                    && CombinedStreamingDiagnostics.fields($0)["evaluationID"] == barrierID }
                if sawBarrier { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertTrue(sawBarrier)
            XCTAssertTrue(lines.contains { $0.contains("[MeetingRetainedStreamingEvaluation]")
                && CombinedStreamingDiagnostics.fields($0)["recoveryID"] == recoveryRunID
                && CombinedStreamingDiagnostics.fields($0)["event"] == "begin" },
                "The bounded diagnostic log must retain the beginning of this whole recovery attempt")
            var protectedValues = try CombinedProtectedEvaluation.values(segments: segments, speakers: recovered.speakers)
            protectedValues["schema"] = 2
            protectedValues["purpose"] = "Fresh retained-file retry in this test process, after live streaming finalized"
            protectedValues["asrArtifactFingerprints"] = recovered.processingAttempts.compactMap(\.asrArtifactFingerprint)
            protectedValues["diarizationModels"] = recovered.processingAttempts.compactMap(\.diarizationModel)
            protectedValues["audioSeconds"] = Double(sourceFrames) / 16_000
            protectedValues["referenceProvenance"] = reference.provenance
            protectedValues["limitations"] = "Protected canonical values only. Fresh attempt IDs and wording may differ; not source-separated speech or a new-process checkpoint continuation."
            let protectedEvidence = try JSONSerialization.data(withJSONObject: protectedValues, options: [.prettyPrinted, .sortedKeys])
            guard protectedEvidence.count <= 16 * 1_048_576 else {
                throw NSError(domain: "RetainedStreamingProtectedEvidenceBudget", code: 1)
            }
            let attachment = XCTAttachment(data: protectedEvidence, uniformTypeIdentifier: "public.json")
            attachment.name = "Retained-Streaming-fresh-pipeline-private-protected-evaluation"
            attachment.lifetime = .keepAlways
            add(attachment)
            return [
                "operation": "retryProcessing(sessionID:) against real retained chunks",
                "freshCoordinatorAndPipeline": true, "freshProcess": false,
                "freshPrivacyRuntimeInitiallyReady": privacyReadyBeforeRetry,
                "freshPrivacyRuntimePreparedByRetry": privacyReadyAfterRetry,
                "freshPrivacyRuntimeUnloadedAfterJoin": !privacyReadyAfterCleanup,
                "freshASRReadyAfterJoinedRelease": recoveryASRReadyAfterRelease,
                "noLiveMemoryAttemptBeforeOrAfter": fresh.meetingProcessingPipeline.memoryAttempts.isEmpty,
                "restorationSeconds": restoreSeconds, "retrySeconds": finished - retryBegan,
                "totalRecoverySeconds": finished - began, "sourceAudioFrameCount": sourceAfter.frames,
                "sourceAudioFileCount": sourceAfter.digests.count, "sourceAudioBytesPreserved": sourceBefore.digests == sourceAfter.digests,
                "asr": attempt.asrModel as Any? ?? NSNull(),
                "asrArtifactFingerprint": attempt.asrArtifactFingerprint as Any? ?? NSNull(),
                "diarizationModel": attempt.diarizationModel as Any? ?? NSNull(),
                "backendID": attempt.backendID as Any? ?? NSNull(),
                "originalCanonicalSegmentCount": completed.transcriptSegments.count,
                "recoveredCanonicalSegmentCount": segments.count,
                "recoveredNativeWordCount": segments.filter { $0.nativePrecision == .word }.count,
                "recoveredNativeTimingCount": segments.filter { $0.nativeTiming != nil }.count,
                "recoveredKnownSpeakerSegmentCount": known,
                "recoveredUnknownSpeakerSegmentCount": segments.filter { $0.speakerID == nil }.count,
                "recoveredOverlapSegmentCount": segments.filter { $0.overlap != .none }.count,
                "originalProtectedTokenCount": sourceTokens.count, "recoveredProtectedTokenCount": retryTokens.count,
                "protectedTokenEditDistance": differences,
                "protectedTokenDifferenceRate": sourceTokens.isEmpty ? NSNull() as Any : Double(differences) / Double(sourceTokens.count) as Any,
                "comparisonMetric": "Visible protected whitespace-token sequence difference between two real inference paths; not WER or speaker-identity accuracy",
                "phaseTimings": CombinedStreamingDiagnostics.phaseTotals(lines, from: Int64(began * 1_000), through: Int64(finished * 1_000)),
                "limitations": "New pipeline and initially unprepared A1 runtime in the same OS process; ASR and OS file caches may be warm. This tests durable retained-file retry without live memory state, not checkpoint continuation after process termination. Different fresh-attempt word IDs and model wording are allowed."
            ]
        } catch {
            await coordinator.shutdownForTermination()
            try? await fresh.asr.meetingResidencyParticipant().suspend()
            try? await freshPrivacy.unload()
            throw error
        }
    }

    private func retainedAudioProof(session: MeetingSession, directory: URL, root: URL) throws
        -> (digests: [String: String], frames: Int) {
        var digests: [String: String] = [:]
        var frames = 0
        for chunk in session.audioTracks.flatMap(\.chunks) {
            XCTAssertEqual(chunk.finalizationState, .finalized)
            let url = chunk.fileURL(relativeTo: directory)
            guard CombinedStreamingAudioInventory.onlyAllowed([url.path], retainedRoot: root) else {
                throw NSError(domain: "RetainedStreamingAudioEscapesTestRoot", code: 1)
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hasher = SHA256()
            while let data = try file.read(upToCount: 65_536), !data.isEmpty { hasher.update(data: data) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, chunk.sha256)
            XCTAssertEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init), chunk.byteCount)
            let audio = try AVAudioFile(forReading: url)
            XCTAssertEqual(audio.processingFormat.sampleRate, 16_000)
            XCTAssertEqual(audio.processingFormat.channelCount, 1)
            frames += Int(audio.length)
            guard digests[chunk.relativeFilePath] == nil else { throw NSError(domain: "RetainedStreamingDuplicateSourcePath", code: 1) }
            digests[chunk.relativeFilePath] = digest
        }
        return (digests, frames)
    }

    private static func protectedTokenEditDistance(_ first: [String], _ second: [String]) -> Int {
        var previous = Array(0...second.count)
        for (index, token) in first.enumerated() {
            var current = [index + 1]
            current.reserveCapacity(second.count + 1)
            for (otherIndex, other) in second.enumerated() {
                current.append(min(current[otherIndex] + 1, previous[otherIndex + 1] + 1,
                                   previous[otherIndex] + (token == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[second.count]
    }

    private func streamingEvaluation(completed: MeetingSession, checkpoint: [MeetingTranscriptSegment],
        sourceFrames: Int, started: Double, captureStarted: Double, stopStarted: Double, completedAt: Double,
        firstKnownSpeakerSeconds: Double?, canonicalCheckpointsObserved: Int,
        maximumProtectedSegmentsBeforeStop: Int, saveAudio: Bool = false,
        requiresRecognizedSpeech: Bool = true, requiresPreStopOutput: Bool = true,
        evidenceCollector: CombinedStreamingEvidenceCollector) async throws -> [String: Any] {
        let segments = completed.transcriptSegments
        let attempts = Set(completed.processingAttempts.map(\.id))
        XCTAssertEqual(completed.effectiveSpeakerProcessingMode, .streaming)
        XCTAssertEqual(Set(segments.map(\.id)).count, segments.count, "Final canonical word identities must be unique")
        let nativeIDs = segments.compactMap(\.nativeUnitID)
        XCTAssertEqual(Set(nativeIDs).count, nativeIDs.count, "Native ASR units must not be readmitted after streaming finish")
        let words = segments.filter { $0.nativePrecision == .word }
        if requiresRecognizedSpeech {
            let nativeUnits = segments.filter {
                ($0.nativePrecision == .word || $0.nativePrecision == .utterance)
                    && $0.nativeTiming != nil && $0.nativeUnitID != nil
            }
            XCTAssertFalse(nativeUnits.isEmpty, "Streaming attribution must retain actual native ASR boundaries")
            XCTAssertEqual(nativeUnits.count, segments.count,
                           "Every canonical segment must retain its actual interval, precision and native unit ID")
        }
        XCTAssertTrue(segments.allSatisfy { segment in
            guard let timing = segment.nativeTiming else { return true }
            return timing.start.isFinite && timing.end.isFinite && timing.start >= 0
                && timing.end > timing.start && timing.end <= Double(sourceFrames) / 16_000 + 0.001
        }, "Native envelopes must remain finite and inside the complete physical source interval")
        let byID = Dictionary(segments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertTrue(checkpoint.allSatisfy { earlier in
            guard let final = byID[earlier.id] else { return false }
            return earlier.text == final.text && earlier.nativeUnitID == final.nativeUnitID
                && earlier.nativeTiming == final.nativeTiming && earlier.start == final.start && earlier.end == final.end
                && earlier.nativePrecision == final.nativePrecision && earlier.status == final.status
                && earlier.completeness == final.completeness && final.originalText == nil
        }, "Speaker revisions must preserve previously protected canonical text, identities and native timing")
        let known = segments.filter { segment in
            segment.speakerID.map { id in completed.speakers.contains { $0.id == id } } == true
        }.count
        if requiresRecognizedSpeech { XCTAssertGreaterThan(known, 0) }
        if !saveAudio {
            XCTAssertTrue(completed.audioTracks.allSatisfy { $0.chunks.isEmpty }, "Strict streaming must not produce audio chunks")
        }

        var lines: [String] = []
        var rows: [CombinedStreamingDiagnostics.Row] = []
        let barrierID = UUID().uuidString
        DebugLogger.shared.info("evaluationID=\(barrierID)", source: "MeetingStreamingEvaluation")
        var sawLogBarrier = false
        // Both loggers enqueue serially. Seeing this test-only marker proves all earlier
        // joined inference rows reached disk without changing either queue owner.
        for _ in 0..<20 {
            lines = try CombinedStreamingDiagnostics.lines()
            sawLogBarrier = lines.contains { $0.contains("[MeetingStreamingEvaluation]")
                && CombinedStreamingDiagnostics.fields($0)["evaluationID"] == barrierID }
            if sawLogBarrier { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(sawLogBarrier, "The test must observe the asynchronous diagnostic write barrier before interpreting evidence")
        evidenceCollector.ingest(lines)
        let collected = evidenceCollector.snapshot()
        XCTAssertEqual(collected.omitted, 0, "The bounded collector must cover the entire diagnostic run")
        XCTAssertEqual(collected.failures, 0, "Every scheduled bounded-log read must succeed")
        lines = collected.lines
        rows = lines.compactMap { CombinedStreamingDiagnostics.row($0, attempts: attempts) }
        let selectedLines = lines.filter { line in
            guard line.contains("[MeetingStreamingPCM]"),
                  let rawID = CombinedStreamingDiagnostics.fields(line)["attemptID"],
                  let id = UUID(uuidString: rawID) else { return false }
            return attempts.contains(id)
        }
        XCTAssertFalse(rows.isEmpty, "Explicit streaming cursor diagnostics must cover the actual run")
        XCTAssertEqual(rows.count, selectedLines.count, "Malformed cursor rows from this exact attempt must fail rather than disappear from evidence")
        XCTAssertLessThanOrEqual(rows.first?.accepted ?? Int.max, 320_000,
                                 "Collected evidence must retain the beginning of streaming across support-log rotation")
        XCTAssertLessThanOrEqual(rows.count, 10_000, "Diagnostic evidence must remain bounded")
        let final = try XCTUnwrap(rows.last(where: \.isStreamingFinish), "Streaming finish must explicitly attest no recording replay")
        XCTAssertEqual(final.accepted, sourceFrames, "Every delivered source sample must enter the continuous diarizer exactly once")
        XCTAssertEqual(final.processed, sourceFrames, "EOF must score the complete physical prefix, clipping STFT padding")
        XCTAssertEqual(final.asrStable, sourceFrames, "EOF must finalize the source prefix including silence")
        XCTAssertEqual(final.committed, sourceFrames, "Privacy and speaker tail must be committed through the physical EOF")
        XCTAssertEqual(final.pendingWords, 0)
        for (earlier, later) in zip(rows, rows.dropFirst()) where earlier.attemptID == later.attemptID {
            XCTAssertLessThanOrEqual(earlier.accepted, later.accepted)
            XCTAssertLessThanOrEqual(earlier.processed, later.processed)
            XCTAssertLessThanOrEqual(earlier.asrStable, later.asrStable)
            XCTAssertLessThanOrEqual(earlier.committed, later.committed)
        }
        let startedMS = Int64(started * 1_000)
        let stopMS = Int64(stopStarted * 1_000)
        let completedMS = Int64(completedAt * 1_000)
        var replaySpanCount = 0
        for phase in ["recording.diarization", "recording.diarization_request", "audio.replay_read"] {
            let count = CombinedStreamingDiagnostics.completedPhaseCount(phase, in: lines,
                from: startedMS, through: completedMS)
            replaySpanCount += count
            XCTAssertEqual(count, 0, "Streaming must finish its continuous session without whole-recording replay")
        }
        for phase in requiresRecognizedSpeech ? ["asr.infer", "privacy.redact"] : [] {
            XCTAssertGreaterThan(CombinedStreamingDiagnostics.completedPhaseCount(phase, in: lines,
                from: startedMS, through: completedMS), 0, "Streaming evidence must include actual native ASR and privacy duration spans")
        }
        let transport = lines.compactMap { CombinedStreamingDiagnostics.transportRow($0, attempts: attempts) }
        XCTAssertFalse(transport.isEmpty, "The actual bounded transport must attest its queued and in-flight PCM budget")
        var transported = 0
        for window in transport {
            XCTAssertEqual(window.offsetSeconds * 16_000, Double(transported), accuracy: 1,
                           "Completed PCM windows must be contiguous and admitted exactly once")
            transported += window.frames
        }
        XCTAssertEqual(transported, sourceFrames, "Transport diagnostics must cover the complete physical source")
        let beforeStop = rows.filter { $0.uptimeMS < stopMS }
        if requiresPreStopOutput {
            XCTAssertFalse(beforeStop.isEmpty, "Diarization must execute while input is still paced, not begin after Stop")
            XCTAssertTrue(beforeStop.contains { $0.processed > 0 && $0.asrStable > 0 })
            // Published protected tail words are real canonical output even when a held
            // privacy phrase keeps the immutable prefix at zero. Never invent coverage
            // to make a short speech followed by silence satisfy a watermark assertion.
            XCTAssertGreaterThan(canonicalCheckpointsObserved, 0)
            XCTAssertFalse(checkpoint.isEmpty)
        }
        let afterStop = rows.filter { $0.uptimeMS >= stopMS }
        let throughStop = beforeStop.last
        let asrLag = rows.map { $0.accepted - $0.asrStable }
        let diarizationLag = rows.map { $0.accepted - $0.processed }
        let committedLag = rows.map { $0.accepted - $0.committed }
        return [
            "speakerProcessingMode": "streaming", "registeredProfile": MeetingNemotronModelProfile.experimentalFast128FP16CPU.rawValue,
            "sourceDelivery": "16 kHz mono PCM, 1600-frame blocks paced to monotonic real time",
            "sourceFrames": sourceFrames, "diagnosticCollector": collected.metadata,
            "canonicalCheckpointsObservedBeforeStop": canonicalCheckpointsObserved,
            "protectedCanonicalSegmentsBeforeStop": checkpoint.count,
            "maximumProtectedCanonicalSegmentsBeforeStop": maximumProtectedSegmentsBeforeStop,
            "firstKnownSpeakerSeconds": firstKnownSpeakerSeconds as Any? ?? NSNull(),
            "firstKnownSpeakerClock": "captureStart; canonical protected session state polled after paced blocks",
            "finalCanonicalSegmentCount": segments.count, "nativeWordCount": words.count,
            "uniqueNativeUnitCount": Set(nativeIDs).count, "knownSpeakerSegmentCount": known,
            "unknownSpeakerSegmentCount": segments.filter { $0.speakerID == nil }.count,
            "overlapSegmentCount": segments.filter { $0.overlap != .none }.count,
            "nativeTimingSegmentCount": segments.filter { $0.nativeTiming != nil }.count,
            "protectedCheckpointWordIdentityAndTimingPreserved": checkpoint.allSatisfy { byID[$0.id]?.nativeTiming == $0.nativeTiming && byID[$0.id]?.text == $0.text },
            "streamingRows": rows.map(\.json), "rowsBeforeStop": beforeStop.count, "rowsAfterStop": afterStop.count,
            "acceptedThroughSampleAtLastPreStopObservation": throughStop?.accepted as Any? ?? NSNull(),
            "processedThroughSampleAtLastPreStopObservation": throughStop?.processed as Any? ?? NSNull(),
            "asrStableThroughSampleAtLastPreStopObservation": throughStop?.asrStable as Any? ?? NSNull(),
            "committedThroughSampleAtLastPreStopObservation": throughStop?.committed as Any? ?? NSNull(),
            "maximumASRStableLagSeconds": Double(asrLag.max() ?? 0) / 16_000,
            "p95ASRStableLagSeconds": CombinedStreamingDiagnostics.percentile95(asrLag) as Any? ?? NSNull(),
            "maximumDiarizationLagSeconds": Double(diarizationLag.max() ?? 0) / 16_000,
            "p95DiarizationLagSeconds": CombinedStreamingDiagnostics.percentile95(diarizationLag) as Any? ?? NSNull(),
            "maximumCommittedLagSeconds": Double(committedLag.max() ?? 0) / 16_000,
            "p95CommittedLagSeconds": CombinedStreamingDiagnostics.percentile95(committedLag) as Any? ?? NSNull(),
            "cursorLagScope": "Accepted source prefix minus explicit ASR stability, scored diarization and protected commit cursors; event-weighted percentiles; excludes audio still queued before acceptance",
            "pendingWordPeak": rows.map(\.pendingWords).max() ?? 0,
            "transportWindows": transport.map(\.json),
            "transportedFrameCount": transported,
            "peakQueuedAndInFlightPCMSeconds": Double(transport.map(\.peakPending).max() ?? 0) / 16_000,
            "transportBudgetSeconds": Double(transport.map(\.budget).max() ?? 0) / 16_000,
            "transportTimingScope": "Growing window wall duration includes waiting for future capture and checkpoint publication; it is not ASR inference duration",
            "recordingReplayObserved": replaySpanCount > 0,
            "recordingReplaySpanCount": replaySpanCount,
            "phaseTimings": CombinedStreamingDiagnostics.phaseTotals(lines, from: startedMS, through: completedMS),
            "captureStartedUptimeMs": Int64(captureStarted * 1_000), "stopStartedUptimeMs": stopMS,
            "completedUptimeMs": completedMS,
            "limitations": "Anonymous session voice IDs are not verified real identities. Known-label coverage is not diarization accuracy. Reference WER and speaker quality require offline scoring. No isolated engine utilization or background execution claim."
        ]
    }

    private func durableEvidenceFixture() throws -> (environment: [String: String], options: CombinedEvaluationOptions,
        pin: CombinedDurableEvidencePin, caches: URL) {
        let environment = [
            "PICHI_MEETING_DURABLE_EVIDENCE": "1", "PICHI_MEETING_DURABLE_RUN_ID": UUID().uuidString.lowercased(),
            "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1", "PICHI_MEETING_DETAILED_PROFILE": "1",
            "PICHI_COMBINED_MEETING_TESTED_REVISION": String(repeating: "a", count: 40),
            "PICHI_MEETING_DURABLE_AUDIO_SHA256": String(repeating: "b", count: 64),
            "PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES": "320000"
        ]
        let options = try CombinedEvaluationOptions(environment: environment)
        let pin = try XCTUnwrap(CombinedDurableEvidencePin(environment: environment, streaming: true, options: options,
            actualRevision: String(repeating: "a", count: 40), audioSHA256: String(repeating: "b", count: 64), sourceFrames: 320_000))
        let caches = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("DurableMeetingEvidenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: false)
        return (environment, options, pin, caches)
    }

    func testDurableEvaluationEvidenceRequiresExplicitMatchingPins() throws {
        let fixture = try durableEvidenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.caches) }
        XCTAssertNil(try CombinedDurableEvidencePin(environment: [:], streaming: false,
            options: CombinedEvaluationOptions(environment: [:]), actualRevision: "", audioSHA256: "", sourceFrames: 0))
        let invalidValues = [
            "PICHI_MEETING_DURABLE_RUN_ID": "../foreign", "PICHI_COMBINED_MEETING_TESTED_REVISION": String(repeating: "c", count: 40),
            "PICHI_MEETING_DURABLE_AUDIO_SHA256": String(repeating: "c", count: 64),
            "PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES": "319999", "PICHI_MEETING_DETAILED_PROFILE": "0"
        ]
        for (key, value) in invalidValues {
            var environment = fixture.environment; environment[key] = value
            XCTAssertThrowsError(try CombinedDurableEvidencePin(environment: environment, streaming: true, options: fixture.options,
                actualRevision: fixture.pin.testedRevision, audioSHA256: fixture.pin.audioSHA256, sourceFrames: 320_000))
        }
        var missing = fixture.environment; missing.removeValue(forKey: "PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES")
        XCTAssertThrowsError(try CombinedDurableEvidencePin(environment: missing, streaming: true, options: fixture.options,
            actualRevision: fixture.pin.testedRevision, audioSHA256: fixture.pin.audioSHA256, sourceFrames: 320_000))
        XCTAssertThrowsError(try CombinedDurableEvidencePin(environment: fixture.environment, streaming: false, options: fixture.options,
            actualRevision: fixture.pin.testedRevision, audioSHA256: fixture.pin.audioSHA256, sourceFrames: 320_000))
        XCTAssertThrowsError(try CombinedDurableEvidencePin(environment: fixture.environment, streaming: true,
            options: CombinedEvaluationOptions(environment: [:]), actualRevision: fixture.pin.testedRevision,
            audioSHA256: fixture.pin.audioSHA256, sourceFrames: 320_000))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.caches.path), [])
    }

    func testDurableEvaluationEvidenceCommitsHashedDiagnosticsWithoutClaimingXCTestPass() throws {
        let fixture = try durableEvidenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.caches) }
        let writer = try CombinedDurableEvaluationEvidence(pin: fixture.pin, cachesDirectory: fixture.caches, maximumEvidenceBytes: 4_096)
        let directory = fixture.caches.appendingPathComponent(CombinedDurableEvaluationEvidence.directoryName)
            .appendingPathComponent(fixture.pin.runID)
        let metadata = Data("{\"peakFootprintBytes\":123}".utf8)
        let protected = Data("{\"segments\":[{\"text\":\"[ИМЯ] работает\"}],\"speakers\":[]}".utf8)
        try writer.finish(metadata: metadata, protectedEvaluation: protected, assertionFailures: 1)
        let terminal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("terminal.json"))) as? [String: Any])
        XCTAssertEqual(terminal["state"] as? String, "completedDiagnostic")
        XCTAssertEqual(terminal["recordedXCTestFailureCount"] as? Int, 1)
        XCTAssertEqual(terminal["xctestAcceptance"] as? String, "externalXCTestPassRequired")
        let digests = try XCTUnwrap(terminal["evidenceSHA256"] as? [String: String])
        for name in ["metadata.json", "protected-evaluation.json"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            XCTAssertEqual(digests[name], SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
            Set(["manifest.json", "metadata.json", "protected-evaluation.json", "terminal.json"]))
        XCTAssertThrowsError(try CombinedDurableEvaluationEvidence(pin: fixture.pin, cachesDirectory: fixture.caches, maximumEvidenceBytes: 4_096))
    }

    func testDurableEvaluationFailureAndCancellationContainOnlyBoundedDiagnostics() throws {
        let fixture = try durableEvidenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.caches) }
        let writer = try CombinedDurableEvaluationEvidence(pin: fixture.pin, cachesDirectory: fixture.caches, maximumEvidenceBytes: 4_096)
        let directory = fixture.caches.appendingPathComponent(CombinedDurableEvaluationEvidence.directoryName)
            .appendingPathComponent(fixture.pin.runID)
        try writer.fail(cancelled: true, phase: "Private arbitrary failure path", assertionFailures: nil,
            metadata: Data("{\"footprintSamples\":[]}".utf8))
        let data = try Data(contentsOf: directory.appendingPathComponent("terminal.json"))
        let terminal = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(terminal["state"] as? String, "cancelledDiagnostic")
        XCTAssertEqual(terminal["failurePhase"] as? String, "other")
        XCTAssertTrue(terminal["recordedXCTestFailureCount"] is NSNull)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private arbitrary"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("protected-evaluation.json").path))
    }

    func testDurableEvaluationEvidenceRejectsSymlinksAndOversizedOutput() throws {
        let fixture = try durableEvidenceFixture()
        defer { try? FileManager.default.removeItem(at: fixture.caches) }
        let parent = fixture.caches.appendingPathComponent(CombinedDurableEvaluationEvidence.directoryName)
        let foreign = fixture.caches.appendingPathComponent("foreign")
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: foreign)
        XCTAssertThrowsError(try CombinedDurableEvaluationEvidence(pin: fixture.pin, cachesDirectory: fixture.caches, maximumEvidenceBytes: 8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: foreign.path), [])
        try FileManager.default.removeItem(at: parent)
        let writer = try CombinedDurableEvaluationEvidence(pin: fixture.pin, cachesDirectory: fixture.caches, maximumEvidenceBytes: 8)
        XCTAssertThrowsError(try writer.finish(metadata: Data(repeating: 65, count: 9), protectedEvaluation: Data(), assertionFailures: 0))
        let directory = parent.appendingPathComponent(fixture.pin.runID)
        let terminal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("terminal.json"))) as? [String: Any])
        XCTAssertEqual(terminal["state"] as? String, "running")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("metadata.json").path))
    }

    func testStreamingDiagnosticCursorParserRejectsForeignAndImpossiblePrefixes() throws {
        let id = UUID(), other = UUID()
        let prefix = "[00:00:00.000] [INFO] [MeetingStreamingPCM] attemptID=\(id) phase=progress uptimeMs=100"
        let fields = "acceptedThroughSample=16000 processedThroughSample=12000 asrStableThroughSample=8000 committedThroughSample=4000 pendingWords=3 knownCount=1"
        let row = try XCTUnwrap(CombinedStreamingDiagnostics.row(prefix + " " + fields, attempts: [id]))
        XCTAssertEqual(row.accepted - row.asrStable, 8_000)
        XCTAssertFalse(row.isStreamingFinish)
        XCTAssertNil(CombinedStreamingDiagnostics.row(prefix + " " + fields, attempts: [other]))
        XCTAssertNil(CombinedStreamingDiagnostics.row((prefix + " " + fields).replacingOccurrences(of: "processedThroughSample=12000", with: "processedThroughSample=16001"), attempts: [id]))
        XCTAssertNil(CombinedStreamingDiagnostics.row((prefix + " " + fields).replacingOccurrences(of: "committedThroughSample=4000", with: "committedThroughSample=9000"), attempts: [id]))
        XCTAssertNil(CombinedStreamingDiagnostics.row((prefix + " " + fields).replacingOccurrences(of: "asrStableThroughSample=8000", with: "asrStableThroughSample=-1"), attempts: [id]))
        let finish = "[MeetingStreamingPCM] attemptID=\(id) phase=finish uptimeMs=101 acceptedThroughSample=16000 processedThroughSample=16000 asrStableThroughSample=16000 committedThroughSample=16000 pendingWords=0 knownCount=1 mode=streaming replay=false"
        XCTAssertTrue(try XCTUnwrap(CombinedStreamingDiagnostics.row(finish, attempts: [id])).isStreamingFinish)
        XCTAssertFalse(try XCTUnwrap(CombinedStreamingDiagnostics.row(finish.replacingOccurrences(of: "replay=false", with: "replay=true"), attempts: [id])).isStreamingFinish)
        XCTAssertEqual(CombinedStreamingDiagnostics.percentile95([16_000, 32_000, 48_000]), 3)
        XCTAssertNil(CombinedStreamingDiagnostics.percentile95([]))
        let transport = "[MeetingMemoryAudio] pipelineID=\(id) window offset=20.0 frames=320000 windowMs=20010 checkpointMs=4 pendingFrames=32000 peakPendingFrames=352000 budgetFrames=960000"
        XCTAssertEqual(try XCTUnwrap(CombinedStreamingDiagnostics.transportRow(transport, attempts: [id])).peakPending, 352_000)
        XCTAssertNil(CombinedStreamingDiagnostics.transportRow(transport, attempts: [other]))
        XCTAssertNil(CombinedStreamingDiagnostics.transportRow(transport.replacingOccurrences(of: "peakPendingFrames=352000", with: "peakPendingFrames=960001"), attempts: [id]))

        XCTAssertEqual(CombinedStreamingDiagnostics.completedPhaseCount("audio.replay_read", in: [
            "[MeetingPCMRuntime] phase=audio.replay_read event=end uptimeMs=102 elapsedMs=1",
            "[MeetingPCMRuntime] phase=audio.replay_read event=end uptimeMs=999 elapsedMs=1",
            "[MeetingPCMRuntime] phase=audio.replay_read event=begin uptimeMs=102"
        ], from: 100, through: 200), 1)
    }

    func testStreamingFixtureOptionsKeepDefaultAndValidateShortPausedAndHourSources() throws {
        var environment = ["PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1", "PICHI_MEETING_DETAILED_PROFILE": "1"]
        let combined = try CombinedEvaluationOptions(environment: environment)
        let standard = try StreamingEvaluationOptions(environment: environment, combined: combined)
        XCTAssertEqual(standard.expectedSourceFrames, 2_880_000)
        XCTAssertTrue(standard.requiresPreStopOutput)
        XCTAssertNil(standard.expectedOwnerCount)
        XCTAssertThrowsError(try StreamingEvaluationOptions(environment: [:], combined: combined))
        for frames: Int64 in [1, 88, 80_000, 192_000, 2_880_000] {
            environment["PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES"] = String(frames)
            let fixture = try StreamingEvaluationOptions(environment: environment, combined: combined)
            XCTAssertNoThrow(try fixture.validatePCM(frameCount: frames, fileBytes: 44, combined: combined))
            XCTAssertThrowsError(try fixture.validatePCM(frameCount: frames + 1, fileBytes: 44, combined: combined))
            XCTAssertEqual(fixture.requiresPreStopOutput, frames >= 480_000)
            XCTAssertEqual(fixture.requiresRecognizedSpeech(referenceProvenance: "human-reviewed"), frames >= 80_000)
            XCTAssertEqual(fixture.requiresRecognizedSpeech(referenceProvenance: "weak-fathom"), frames >= 480_000)
        }
        for raw in ["0", "-1", "9600001", "57600000", "NaN", "", "80000.0"] {
            environment["PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES"] = raw
            XCTAssertThrowsError(try StreamingEvaluationOptions(environment: environment, combined: combined))
        }
        environment["PICHI_COMBINED_MEETING_LONG_EVALUATION"] = "1"
        environment["PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES"] = "57600000"
        let long = try CombinedEvaluationOptions(environment: environment)
        let hour = try StreamingEvaluationOptions(environment: environment, combined: long)
        XCTAssertNoThrow(try hour.validatePCM(frameCount: 57_600_000, fileBytes: 115_200_044, combined: long))
        XCTAssertThrowsError(try hour.validatePCM(frameCount: 57_600_000, fileBytes: 128 * 1_048_576 + 1, combined: long))
        environment["PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES"] = "62400001"
        XCTAssertThrowsError(try StreamingEvaluationOptions(environment: environment, combined: long))
        environment["PICHI_MEETING_STREAMING_EXPECTED_SOURCE_FRAMES"] = "80000"
        for expected in ["0", "1"] {
            environment["PICHI_MEETING_STREAMING_EXPECTED_OWNER_COUNT"] = expected
            XCTAssertEqual(try StreamingEvaluationOptions(environment: environment, combined: long).expectedOwnerCount, Int(expected))
        }
        environment["PICHI_MEETING_STREAMING_EXPECTED_OWNER_COUNT"] = "yes"
        XCTAssertThrowsError(try StreamingEvaluationOptions(environment: environment, combined: long))
        // The separate legacy combined evaluator still refuses genuinely short audio.
        XCTAssertThrowsError(try combined.validatePCM(frameCount: 80_000, fileBytes: 44))
    }

    func testStreamingEvidenceCollectorSurvivesRotatedSnapshotsAndRetainsOnlyScalars() throws {
        let id = UUID(), span = UUID()
        let cursor = "[01:00:00.100] [INFO] [MeetingStreamingPCM] attemptID=\(id) phase=progress uptimeMs=100 acceptedThroughSample=16000 processedThroughSample=12000 asrStableThroughSample=8000 committedThroughSample=4000 pendingWords=3 knownCount=1 sourceText=private-word embedding=secret"
        let transport = "[01:00:00.101] [INFO] [MeetingMemoryAudio] pipelineID=\(id) window offset=0 frames=16000 windowMs=10 checkpointMs=1 pendingFrames=0 peakPendingFrames=16000 budgetFrames=960000 sourcePath=/private/audio.wav"
        let phase = "[MeetingPCMRuntime] phase=privacy.redact event=end spanID=\(span) uptimeMs=102 elapsedMs=5 privateInput=private-word"
        let finish = "[MeetingStreamingPCM] attemptID=\(id) phase=finish uptimeMs=200 acceptedThroughSample=16000 processedThroughSample=16000 asrStableThroughSample=16000 committedThroughSample=16000 pendingWords=0 knownCount=1 mode=streaming replay=false"
        let collector = CombinedStreamingEvidenceCollector(startedMS: 100)
        collector.ingest([cursor, transport, phase])
        // The next bounded logger snapshot has rotated away the first cursor.
        collector.ingest([transport, phase, finish])
        let result = collector.snapshot()
        XCTAssertEqual(result.lines.count, 4)
        XCTAssertEqual(result.omitted, 0)
        XCTAssertEqual(result.failures, 0)
        let rows = result.lines.compactMap { CombinedStreamingDiagnostics.row($0, attempts: [id]) }
        XCTAssertEqual(rows.map(\.uptimeMS), [100, 200])
        XCTAssertEqual(rows.first?.accepted, 16_000)
        XCTAssertTrue(rows.last?.isStreamingFinish == true)
        XCTAssertEqual(result.lines.compactMap { CombinedStreamingDiagnostics.transportRow($0, attempts: [id]) }.count, 1)
        XCTAssertEqual(CombinedStreamingDiagnostics.completedPhaseCount("privacy.redact", in: result.lines, from: 100, through: 200), 1)
        for forbidden in ["private-word", "secret", "sourceText", "embedding", "sourcePath", "/private/audio.wav"] {
            XCTAssertFalse(result.lines.joined().contains(forbidden))
        }
        collector.ingest([cursor.replacingOccurrences(of: "uptimeMs=100", with: "uptimeMs=99")])
        XCTAssertEqual(collector.snapshot().lines.count, 4)
        // Impossible prefixes remain visible to the validator, never silently turn valid.
        collector.ingest([finish.replacingOccurrences(of: "processedThroughSample=16000", with: "processedThroughSample=16001")])
        let invalid = collector.snapshot().lines.filter { $0.contains("[MeetingStreamingPCM]") }
        XCTAssertEqual(invalid.count, 3)
        XCTAssertEqual(invalid.compactMap { CombinedStreamingDiagnostics.row($0, attempts: [id]) }.count, 2)
    }

    func testStreamingEvidenceCollectorEnforcesRowAndByteCapacities() {
        let first = "[MeetingPCMRuntime] phase=asr.infer event=end spanID=\(UUID()) uptimeMs=100 elapsedMs=1"
        let second = "[MeetingPCMRuntime] phase=asr.infer event=end spanID=\(UUID()) uptimeMs=101 elapsedMs=1"
        let rows = CombinedStreamingEvidenceCollector(startedMS: 100, maximumRows: 1)
        rows.ingest([first, first, second])
        XCTAssertEqual(rows.snapshot().lines.count, 1)
        XCTAssertEqual(rows.snapshot().omitted, 1)
        let bytes = CombinedStreamingEvidenceCollector(startedMS: 100, maximumBytes: 1)
        bytes.ingest([first])
        XCTAssertTrue(bytes.snapshot().lines.isEmpty)
        XCTAssertEqual(bytes.snapshot().omitted, 1)
    }

    func testEvaluationPrivacyDecoratorsPreservePreparationAndCheckpointIdentity() async throws {
        let service = CombinedPrivacyPreparationSpy()
        let combined = CombinedPrivacyObservations(wrapping: service, aliases: [])
        let diagnostics = SyntheticPrivacyReplayDiagnostics(wrapping: service)
        XCTAssertEqual(combined.checkpointIdentity, service.checkpointIdentity)
        XCTAssertEqual(diagnostics.checkpointIdentity, service.checkpointIdentity)
        try await combined.prepareForMeeting()
        try await diagnostics.prepareForMeeting()
        let preparations = await service.preparations
        XCTAssertEqual(preparations, 2)
    }

    func testProtectedRetryTokenDifferenceHandlesEmptyInsertDeleteAndSubstitute() {
        XCTAssertEqual(Self.protectedTokenEditDistance([], []), 0)
        XCTAssertEqual(Self.protectedTokenEditDistance(["один"], []), 1)
        XCTAssertEqual(Self.protectedTokenEditDistance([], ["один"]), 1)
        XCTAssertEqual(Self.protectedTokenEditDistance(["один", "два"], ["один", "два"]), 0)
        XCTAssertEqual(Self.protectedTokenEditDistance(["один", "два"], ["один", "три"]), 1)
        XCTAssertEqual(Self.protectedTokenEditDistance(["один", "два"], ["один", "и", "два"]), 1)
    }

    func testStreamingAudioInventoryFindsNewNestedMediaWithoutReadingPayloads() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StreamingInventory.\(UUID())")
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("existing.wav"))
        let before = try CombinedStreamingAudioInventory.paths(in: root)
        XCTAssertEqual(before.count, 1)
        try Data().write(to: nested.appendingPathComponent("private.json"))
        try Data().write(to: nested.appendingPathComponent("accidental.CAF"))
        let added = try CombinedStreamingAudioInventory.paths(in: root).subtracting(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added.allSatisfy { $0.hasSuffix("accidental.CAF") })
        XCTAssertTrue(CombinedStreamingAudioInventory.onlyAllowed(added, retainedRoot: root))
        XCTAssertFalse(CombinedStreamingAudioInventory.onlyAllowed(added, retainedRoot: nil))
        XCTAssertFalse(CombinedStreamingAudioInventory.onlyAllowed([root.path + "-sibling/foreign.caf"], retainedRoot: root))
    }

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    #if arch(arm64)
    func testDetailedComputeOverrideRequiresTheExplicitProfilingGate() {
        XCTAssertEqual(MeetingFast32ComputePolicy.diagnosticUnits(preferred: .cpuAndGPU, environment: [:]), .cpuAndGPU)
        XCTAssertEqual(MeetingFast32ComputePolicy.diagnosticUnits(preferred: .cpuAndGPU,
            environment: ["PICHI_MEETING_PROFILE_COMPUTE_UNITS": "cpuOnly"]), .cpuAndGPU)
        XCTAssertEqual(MeetingFast32ComputePolicy.diagnosticUnits(preferred: .cpuAndGPU,
            environment: ["PICHI_MEETING_DETAILED_PROFILE": "1", "PICHI_MEETING_PROFILE_COMPUTE_UNITS": "cpuOnly"]), .cpuOnly)
        XCTAssertEqual(MeetingFast32ComputePolicy.diagnosticUnits(preferred: .cpuAndNeuralEngine,
            environment: ["PICHI_MEETING_DETAILED_PROFILE": "1", "PICHI_MEETING_PROFILE_COMPUTE_UNITS": "unexpected"]), .cpuAndNeuralEngine)
    }
    #endif

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

    func testCombinedLongAgreementUsesOfflineScoringWithoutChangingLegacyAvailability() throws {
        for environment: [String: String] in [[:], ["PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1"]] {
            let options = try CombinedEvaluationOptions(environment: environment)
            XCTAssertNil(options.attributionAgreementUnavailableReason(referenceContainsOverlap: false))
            XCTAssertEqual(options.attributionAgreementUnavailableReason(referenceContainsOverlap: true),
                           "overlappingReferenceRequiresOfflineWordScoring")
        }
        let long = try CombinedEvaluationOptions(environment: [
            "PICHI_COMBINED_MEETING_LONG_EVALUATION": "1", "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1"])
        for containsOverlap in [false, true] {
            XCTAssertEqual(long.attributionAgreementUnavailableReason(referenceContainsOverlap: containsOverlap),
                           "longEvaluationRequiresOfflineWordScoring")
        }
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

    func testMainActorSamplingSeparatesEntryFromDelayedUtilityContinuation() throws {
        let sampler = CombinedMainActorSamples()
        sampler.record(phase: .modelPreparation, entryPhase: .modelPreparation,
            queued: 10, entered: 10.001, departed: 10.0012, resumed: 12.0012,
            previousQueued: nil, previousResumed: nil)
        sampler.record(phase: .capture, entryPhase: .postStop,
            queued: 20, entered: 22, departed: 22.0002, resumed: 22.0012,
            previousQueued: 10, previousResumed: 12.0012)
        let json = sampler.json(interval: 0.1)
        let phases = try XCTUnwrap(json["phases"] as? [String: [String: Any]])
        let model = try XCTUnwrap(phases["modelPreparation"])
        let capture = try XCTUnwrap(phases["capture"])
        func maximum(_ row: [String: Any], _ key: String) throws -> Double {
            try XCTUnwrap((row[key] as? [String: Any])?["maximumSeconds"] as? Double)
        }
        XCTAssertEqual(try maximum(model, "mainActorQueueEntry"), 0.001, accuracy: 0.000_001)
        XCTAssertEqual(try maximum(model, "mainActorMarkerExecution"), 0.0002, accuracy: 0.000_001)
        XCTAssertEqual(try maximum(model, "utilityContinuationResume"), 2, accuracy: 0.000_001)
        XCTAssertEqual(try maximum(capture, "mainActorQueueEntry"), 2, accuracy: 0.000_001)
        XCTAssertEqual(try maximum(capture, "utilityContinuationResume"), 0.001, accuracy: 0.000_001)
        XCTAssertEqual(try maximum(capture, "utilitySubmissionInterval"), 10, accuracy: 0.000_001)
        XCTAssertEqual(try maximum(capture, "utilityWakeGap"), 7.9988, accuracy: 0.000_001)
        XCTAssertEqual(capture["phaseChangesWhileQueued"] as? Int, 1)
        XCTAssertEqual(try XCTUnwrap(json["maximumWaitSeconds"] as? Double), 2.0012, accuracy: 0.000_001)
    }

    func testMainActorSamplingIsBoundedPhaseScopedAndTimestampFree() throws {
        let sampler = CombinedMainActorSamples(limit: 2)
        sampler.setPhase("arbitrary private phase text")
        XCTAssertEqual(sampler.currentPhase(), .other)
        for start in [10.0, 20, 30] {
            sampler.record(phase: sampler.currentPhase(), entryPhase: .other,
                queued: start, entered: start + 0.01, departed: start + 0.02, resumed: start + 0.03,
                previousQueued: nil, previousResumed: nil)
        }
        let json = sampler.json(interval: 0.1)
        XCTAssertEqual(json["samples"] as? Int, 2)
        XCTAssertEqual(json["omittedSamples"] as? Int, 1)
        XCTAssertEqual(json["capacity"] as? Int, 2)
        let phases = try XCTUnwrap(json["phases"] as? [String: [String: Any]])
        XCTAssertEqual(Set(phases.keys), ["other"])
        XCTAssertEqual(phases["other"]?["samples"] as? Int, 2)
        let encoded = try JSONSerialization.data(withJSONObject: json)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("arbitrary private phase text"))
        for rawClockKey in ["queued", "entered", "departed", "resumed"] {
            XCTAssertFalse(text.contains("\"" + rawClockKey + "\":"))
        }
    }

    func testMainActorSamplingZeroDefaultsAndInvalidClockOrder() throws {
        let sampler = CombinedMainActorSamples()
        let empty = sampler.json(interval: 0.1)
        XCTAssertEqual(empty["samples"] as? Int, 0)
        XCTAssertEqual(empty["maximumWaitSeconds"] as? Double, 0)
        XCTAssertTrue((empty["phases"] as? [String: Any])?.isEmpty == true)
        for (queued, entered, departed, resumed) in [(Double.nan, 1.0, 1.0, 1.0), (2, 1, 2, 3), (1, 2, 1, 3), (1, 2, 3, 2)] {
            sampler.record(phase: .capture, entryPhase: .capture,
                queued: queued, entered: entered, departed: departed, resumed: resumed,
                previousQueued: nil, previousResumed: nil)
        }
        let rejected = sampler.json(interval: 0.1)
        XCTAssertEqual(rejected["samples"] as? Int, 0)
        XCTAssertEqual(rejected["invalidSamples"] as? Int, 4)
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

    /// External synthetic speech reaches the real microphone. No in-app player can
    /// keep this host alive or provide a second reason for audio background execution.
    func testPhysicalStreamingExternalSpeechContinuesInBackground() async throws {
        guard ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STREAMING_EXTERNAL_SPEECH"] == "1" else {
            throw XCTSkip("Explicitly enable the real-microphone external synthetic speech probe")
        }
        try await verifyPhysicalStrictMeeting(model: .gigaam, externalStreamingSpeech: true)
    }

    /// The exact user configuration that serial, unpaced ASR fixtures did not cover.
    /// Speech comes through the real selected microphone, from the device speaker
    /// or the explicitly selected external synthetic speech source.
    private func verifyPhysicalStrictMeeting(model: SettingsStore.SpeechModel,
                                             externalStreamingSpeech: Bool = false) async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires explicitly enabled physical strict meeting recording")
        #else
        guard ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STRICT_MEETING_E2E"] == "1" else {
            throw XCTSkip("Enable physical strict ASR, diarization and PII replay explicitly")
        }
        let environment = ProcessInfo.processInfo.environment
        guard let duration = Int(environment["PICHI_PHYSICAL_STRICT_MEETING_SECONDS"] ?? (externalStreamingSpeech ? "180" : "60")),
              (60...(externalStreamingSpeech ? 3_600 : 300)).contains(duration) else {
            throw NSError(domain: "PhysicalStrictMeetingDuration", code: 1)
        }
        #if DEBUG
        guard !IOSMeetingDebugFileInput.isRequested else {
            throw NSError(domain: "PhysicalStrictMeetingRequiresHardwareMicrophone", code: 1)
        }
        #endif
        guard externalStreamingSpeech || AVAudioSession.sharedInstance().outputVolume > 0.05 else {
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
        if externalStreamingSpeech {
            settings.meetingRecordingDefaults.languageCode = "ru"
            settings.meetingSpeakerProcessingMode = .streaming
        }
        let store = MeetingSessionStore(rootDirectory: root)
        let privacy = PichiTranscriptPrivacyService(modelStore: .init(directory: assets.appendingPathComponent("models/privacy")))
        let diagnostics = externalStreamingSpeech || environment["PICHI_PHYSICAL_STRICT_PRIVACY_DIAGNOSTICS"] == "1"
            ? SyntheticPrivacyReplayDiagnostics(wrapping: privacy) : nil
        let services = AppServices(store: store, settings: settings, privacy: privacy, privacyRedactor: diagnostics)
        let coordinator = services.meetingSessionCoordinator
        var visibleUI: CombinedVisibleMeetingUI?
        defer { visibleUI?.close() }
        let twoVoiceFixture = ProcessInfo.processInfo.environment["PICHI_PHYSICAL_STRICT_TWO_VOICES"] == "1"
        if externalStreamingSpeech {
            guard duration >= 180, twoVoiceFixture else {
                throw NSError(domain: "PhysicalStreamingBackgroundAcceptance", code: 1)
            }
        }
        let fixture = twoVoiceFixture ? "audio/mixed-two-voices.wav" : "audio/ru.wav"
        let player = externalStreamingSpeech ? nil : try AVAudioPlayer(contentsOf: assets.appendingPathComponent(fixture))
        player?.numberOfLoops = -1
        var firstTextSecond: Int?
        var firstPendingSecond: Int?
        var largestPendingCount = 0
        var updates = 0
        var protectedUpdateSeconds: [Double] = []
        var lastUpdateSecond = 0
        var lastBackgroundUpdateSecond = 0
        var previousIDs: Set<UUID> = []
        var previousSnapshot = coordinator.liveTranscript
        var firstMicrophoneHealthSecond: Int?
        var lastHealthyMicrophoneSecond = 0
        var microphonePTSAdvances = 0
        var previousMicrophonePTS: MeetingMediaTime?
        let requiresBackground = externalStreamingSpeech || environment["PICHI_PHYSICAL_STRICT_MEETING_BACKGROUND"] == "1"
        var backgroundSeconds: TimeInterval = 0
        var backgroundUpdates = 0
        var backgroundParticipantIDs: Set<SessionSpeakerID> = []
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
            let captureRequested = ProcessInfo.processInfo.systemUptime
            let recording = try await coordinator.startRecording(configuration: configuration)
            let captureAdmissionSeconds = ProcessInfo.processInfo.systemUptime - captureRequested
            XCTAssertEqual(recording.audioStorageMode, .memoryOnly)
            XCTAssertEqual(recording.speakerLabelsEnabled, true)
            XCTAssertEqual(recording.piiRedactionEnabled, true)
            if externalStreamingSpeech {
                XCTAssertEqual(recording.effectiveSpeakerProcessingMode, .streaming)
                // Match the existing combined probe: attach rendering after admission.
                // Presenting a new root first starts its asynchronous retention sweep,
                // racing this programmatic Start outside the UI's isQuiescent gate.
                visibleUI = try CombinedVisibleMeetingUI(services: services)
            } else {
                try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                XCTAssertTrue(player?.play() == true)
            }
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
                if let health = coordinator.trackHealth[.microphone], health.status == .healthy,
                   health.lastSampleAt != nil, let pts = health.lastPresentationTime {
                    firstMicrophoneHealthSecond = firstMicrophoneHealthSecond ?? second
                    lastHealthyMicrophoneSecond = second
                    if pts != previousMicrophonePTS { microphonePTSAdvances += 1 }
                    previousMicrophonePTS = pts
                }
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
                if snapshot.hasNewWords(since: previousSnapshot) {
                    updates += 1
                    protectedUpdateSeconds.append(elapsed)
                    lastUpdateSecond = second
                    if adjacentBackgroundObservation {
                        backgroundUpdates += 1
                        lastBackgroundUpdateSecond = second
                        let newParticipants = snapshot.utterances.filter { !previousIDs.contains($0.id) }
                            .compactMap { $0.participant?.participantID }
                        backgroundParticipantIDs.formUnion(newParticipants.prefix(max(0, 512 - backgroundParticipantIDs.count)))
                    }
                }
                previousIDs = ids
                previousSnapshot = snapshot
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
            player?.stop()
            XCTAssertGreaterThanOrEqual(capturedSeconds, Double(duration))
            if externalStreamingSpeech {
                // Pending tokens are an animation heuristic, not PCM acceptance. Health
                // PTS is published only after the real sink accepts microphone samples.
                XCTAssertNotNil(firstMicrophoneHealthSecond)
                XCTAssertGreaterThanOrEqual(microphonePTSAdvances, duration - 20)
                XCTAssertGreaterThanOrEqual(lastHealthyMicrophoneSecond, duration - 15)
            } else {
                XCTAssertNotNil(firstPendingSecond, "Real accepted microphone audio must show capture progress before recognition completes")
                XCTAssertLessThanOrEqual(firstTextSecond ?? 61, 12, "Speech must appear before slower attribution completes")
            }
            XCTAssertNotNil(firstTextSecond, "Filtered live speech must be visible before stopping")
            XCTAssertGreaterThanOrEqual(updates, 3, "Repeated capture must keep advancing after the original 35-second failure")
            XCTAssertGreaterThanOrEqual(lastUpdateSecond, duration - 15,
                                        "Protected text must keep advancing near the end, not only during the first window")
            if requiresBackground {
                let requiredBackgroundSeconds = externalStreamingSpeech ? Double(duration - 20) : duration == 300 ? 280.0 : 20.0
                XCTAssertGreaterThanOrEqual(backgroundSeconds, requiredBackgroundSeconds,
                                            "The host must actually leave the foreground during paced recording")
                XCTAssertGreaterThan(backgroundUpdates, 0, "Safe text must advance between actual background observations")
                if externalStreamingSpeech {
                    XCTAssertGreaterThanOrEqual(lastBackgroundUpdateSecond, duration - 15,
                                                "Streaming protected text must still advance in the background near the end")
                    XCTAssertGreaterThan(diagnostics?.backgroundSuccessfulCalls ?? 0, 0,
                                         "Production PII inference must complete while the app is in the background")
                    XCTAssertGreaterThan(diagnostics?.backgroundRedactedCalls ?? 0, 0,
                                         "External synthetic speech must exercise actual PII masking in the background")
                    XCTAssertGreaterThanOrEqual(backgroundParticipantIDs.count, twoVoiceFixture ? 2 : 1,
                                                "New protected background utterances must carry native participant attribution")
                }
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
            if externalStreamingSpeech {
                XCTAssertTrue(completed.transcriptSegments.contains { $0.speakerID != nil },
                              "The real streaming microphone path must publish speaker attribution")
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
                "captureAdmissionSeconds": captureAdmissionSeconds,
                "firstMicrophoneHealthSecond": firstMicrophoneHealthSecond ?? -1,
                "lastHealthyMicrophoneSecond": lastHealthyMicrophoneSecond,
                "microphonePTSAdvances": microphonePTSAdvances,
                "firstTextSecond": firstTextSecond ?? -1,
                "earlySafeTextUXTargetSeconds": 12,
                "earlySafeTextUXTargetMet": firstTextSecond.map { $0 <= 12 } ?? false,
                "acceptanceScope": externalStreamingSpeech
                    ? "Background transport and protected-text progress; first-safe-text latency is reported separately. This is not overall live-UX or speaker-accuracy acceptance."
                    : "Legacy strict capture and early-text checks",
                "firstPendingSecond": firstPendingSecond ?? -1, "largestPendingCount": largestPendingCount,
                "protectedUpdateSeconds": protectedUpdateSeconds,
                "backgroundSeconds": backgroundSeconds,
                "backgroundUpdates": backgroundUpdates,
                "backgroundParticipantCount": backgroundParticipantIDs.count,
                "lastBackgroundUpdateSecond": lastBackgroundUpdateSecond,
                "externalSpeechWithoutInAppPlayback": externalStreamingSpeech,
                "speakerProcessingMode": recording.effectiveSpeakerProcessingMode.rawValue,
                "backgroundPrivacySuccessfulCalls": diagnostics?.backgroundSuccessfulCalls ?? 0,
                "backgroundPrivacyRedactedCalls": diagnostics?.backgroundRedactedCalls ?? 0,
                "identifiedOwnerCount": completed.speakers.filter(\.isLocalUser).count,
                "ownerAccuracyEvaluated": false
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
            player?.stop()
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
