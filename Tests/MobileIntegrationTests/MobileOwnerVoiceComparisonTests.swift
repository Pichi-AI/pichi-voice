@preconcurrency import AVFoundation
import CryptoKit
import Foundation
import XCTest
@testable import PichiVoiceMobile

/// Explicitly enabled diagnosis only. No recording, enrollment, profile replacement, ASR,
/// diarization model, transcript export or model installation belongs to this test.
private nonisolated struct OwnerVoiceComparisonOptions: Sendable {
    enum Failure: Error { case invalidOptions, invalidInput, unavailableProfile, invalidQuery, invalidReport }
    let audioSHA256: String
    let sourceFrames: Int

    init(environment: [String: String]) throws {
        guard environment["PICHI_OWNER_VOICE_PRIVATE_DIAGNOSTIC"] == "1",
              environment["PICHI_COMBINED_MEETING_PRIVATE_EVALUATION"] == "1",
              environment["PICHI_COMBINED_MEETING_E2E"] == "1",
              environment["PICHI_MEETING_DETAILED_PROFILE"] == "1",
              let digest = environment["PICHI_OWNER_VOICE_DIAGNOSTIC_AUDIO_SHA256"],
              digest.count == 64, digest.allSatisfy({ "0123456789abcdef".contains($0) }),
              let frames = Int(environment["PICHI_OWNER_VOICE_DIAGNOSTIC_SOURCE_FRAMES"] ?? "320000"),
              (102_400...320_000).contains(frames) else { throw Failure.invalidOptions }
        self.audioSHA256 = digest
        self.sourceFrames = frames
    }

    func read(root: URL) throws -> [Float] {
        let file = root.appendingPathComponent("audio/combined-ru.wav")
        let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              let size = properties.fileSize, (44...2_000_000).contains(size) else { throw Failure.invalidInput }
        let data = try Data(contentsOf: file)
        guard data.count == size, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == self.audioSHA256 else {
            throw Failure.invalidInput
        }
        let source = try AVAudioFile(forReading: file)
        guard source.processingFormat.sampleRate == 16_000, source.processingFormat.channelCount == 1,
              source.length == self.sourceFrames,
              let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(self.sourceFrames)) else {
            throw Failure.invalidInput
        }
        try source.read(into: buffer)
        guard Int(buffer.frameLength) == self.sourceFrames, let samples = buffer.floatChannelData?[0] else { throw Failure.invalidInput }
        let result = Array(UnsafeBufferPointer(start: samples, count: self.sourceFrames))
        guard result.allSatisfy(\.isFinite) else { throw Failure.invalidInput }
        return result
    }
}

/// The report schema permits numbers and booleans only. Raw PCM and embeddings stay inside
/// the joined inference worker and can never be encoded through this value type.
private nonisolated struct OwnerVoiceComparisonScalars: Encodable, Sendable {
    struct Quality: Encodable, Sendable {
        let sampleCount: Int
        let finiteCount: Int
        let mean: Double
        let rms: Double
        let centeredRMS: Double
        let minimum: Float
        let maximum: Float
        let clippedFraction: Double
        init(_ audio: [Float]) {
            sampleCount = audio.count
            finiteCount = audio.filter(\.isFinite).count
            mean = audio.reduce(0) { $0 + Double($1) } / Double(max(1, audio.count))
            rms = sqrt(audio.reduce(0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.count)))
            let average = mean
            centeredRMS = sqrt(audio.reduce(0) { $0 + pow(Double($1) - average, 2) } / Double(max(1, audio.count)))
            minimum = audio.min() ?? 0
            maximum = audio.max() ?? 0
            clippedFraction = Double(audio.filter { abs($0) >= 0.99 }.count) / Double(max(1, audio.count))
        }
    }
    struct Variant: Encodable, Sendable {
        let variantID: Int
        let inputQuality: [Quality]
        let querySelfDistance: Float?
        let querySelfMatrix: [[Float?]]
        let crossOwnerMatrix: [[Float?]]
        let crossOwnerWorstDistance: Float?
        let queryPassesSelfConsistency: Bool
        let queryPassesOwnerDistance: Bool
        let verifiedOwnerCount: Int
        let sameSourceEarlyReferenceConfirmedCount: Int
        let duplicateEncodingDistance: Float?
    }
    let schemaVersion: Int
    let sourceQuality: Quality
    let ownerReferenceSelfDistance: Float?
    let ownerReferenceSelfMatrix: [[Float?]]
    let ownerReferenceValid: Bool
    let ownerOriginalPCMAvailable: Bool
    let maximumDistance: Float
    let requiredAmbiguityMargin: Float
    let independentCandidatesPerComparison: Int
    let observedAmbiguityMarginAvailable: Bool
    let inferenceSeconds: Double
    var ownerProfileUnchanged: Bool
    let variants: [Variant]

    static func matrix(_ lhs: [[Float]], _ rhs: [[Float]]) -> [[Float?]] {
        lhs.map { a in rhs.map { b in MeetingSpeakerEmbeddingIndex.cosineDistance(a, b) } }
    }
}

@MainActor
final class MobileOwnerVoiceComparisonTests: XCTestCase {
    func testPrivateExistingOwnerVoiceScalarComparison() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_OWNER_VOICE_PRIVATE_DIAGNOSTIC"] != nil else {
            throw XCTSkip("Explicitly opt in to private scalar owner-voice comparison")
        }
        let options = try OwnerVoiceComparisonOptions(environment: environment)
        let root = try MobileInferenceTestAssets.resolve(environment: environment)
        let profileStore = MeetingOwnerVoiceProfileStore()
        guard let owner = try profileStore.load(), MeetingOwnerVoiceProfileStore.isValid(owner) else {
            throw OwnerVoiceComparisonOptions.Failure.unavailableProfile
        }
        let services = AppServices.shared
        let lease = try await services.meetingAudioActivityArbiter.acquireMeetingCapture()
        let scalarData: Data
        do {
            scalarData = try await services.asr.withMeetingModelResidency(attemptID: UUID()) {
                let executor = TranscriptionExecutor()
                return try await executor.runBlocking {
                    try Task.checkCancellation()
                    let samples = try options.read(root: root)
                    let result = try Self.compare(samples: samples, owner: owner)
                    try Task.checkCancellation()
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    return try encoder.encode(result)
                }
            }
            await services.meetingAudioActivityArbiter.release(lease)
        } catch {
            await services.meetingAudioActivityArbiter.release(lease)
            throw error
        }
        try Task.checkCancellation()
        // Compare in memory, never assert equality of biometric objects (XCTest would print
        // those objects on failure). No profile data, identity or source hash enters the report.
        let unchanged = try profileStore.load() == owner
        XCTAssertTrue(unchanged, "The diagnostic must preserve the existing owner reference")
        guard var report = try JSONSerialization.jsonObject(with: scalarData) as? [String: Any] else {
            throw OwnerVoiceComparisonOptions.Failure.invalidReport
        }
        report["ownerProfileUnchanged"] = unchanged
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "PrivateOwnerVoiceScalarComparison.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        // A refusal is diagnostic data, not a failed test or permission to relax thresholds.
        XCTAssertFalse((report["variants"] as? [Any] ?? []).isEmpty)
    }

    private nonisolated static func compare(samples: [Float], owner: MeetingOwnerVoiceProfileSnapshot) throws -> OwnerVoiceComparisonScalars {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let duration = Double(samples.count) / 16_000
        let interval = MeetingNemotronSpeakerSegment(slotIndex: 0, start: 0, end: duration)
        var streaming = MeetingStreamingOwnerVoiceSamples(epoch: epoch)
        // The input has been explicitly selected as one reviewed voice. This assumed whole
        // interval isolates encoder/channel effects from the production diarizer's decisions.
        var offset = 0
        for amount in [48_000, 160_000, 112_000] where offset < samples.count {
            let end = min(samples.count, offset + amount)
            streaming.append(Array(samples[offset..<end]), sourceStartSample: offset)
            streaming.collect(activity: [.init(slotIndex: 0, start: 0, end: Double(end) / 16_000)], processedThroughSample: end)
            offset = end
        }
        guard let short = streaming.excerpts.first else { throw OwnerVoiceComparisonOptions.Failure.invalidQuery }
        var requests: [MeetingSpeakerVoiceSamples] = []
        var IDs: [Int] = []
        func append(_ identifier: Int, _ clips: [[Float]]) {
            guard clips.count == 2, clips.allSatisfy({ (48_000...160_000).contains($0.count) }) else { return }
            IDs.append(identifier)
            requests.append(.init(token: .init(analysisEpochID: epoch, label: "diagnostic-\(identifier)"), clips: clips))
        }
        append(0, short.clips)
        if let enrollment = MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: samples, segments: [interval]).first {
            append(1, enrollment.clips)
        }
        if samples.count >= 306_560 {
            append(2, [Array(samples[192_000..<240_000]), Array(samples[256_000..<304_000])])
            append(3, [Array(samples[2_560..<146_560]), Array(samples[162_560..<306_560])])
        }
        let normalized = short.clips.map { clip -> [Float] in
            let quality = OwnerVoiceComparisonScalars.Quality(clip)
            let gain = Float(min(4, max(0.25, 0.08 / max(quality.rms, 0.000_001))))
            return clip.map { max(-0.98, min(0.98, $0 * gain)) }
        }
        append(4, normalized)
        append(5, short.clips.map { clip in
            let mean = Float(clip.reduce(0) { $0 + Double($1) } / Double(clip.count))
            return clip.map { $0 - mean }
        })
        append(6, short.clips) // Same-input repeatability control, never a new real identity.
        let began = ProcessInfo.processInfo.systemUptime
        let profiles = try MeetingSpeakerVoiceEncoder.encode(samples: requests)
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        guard profiles.count == requests.count, let first = profiles.first else { throw OwnerVoiceComparisonOptions.Failure.invalidQuery }
        let reference = MeetingSpeakerVoiceProfile(token: first.token, embeddings: owner.embeddings)
        let earlyReference = MeetingOwnerVoiceProfileSnapshot(metadata: .init(generation: UUID(), enrolledAt: Date()),
            encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint, embeddings: first.embeddings)
        var variants: [OwnerVoiceComparisonScalars.Variant] = []
        for index in profiles.indices {
            try Task.checkCancellation()
            let profile = profiles[index]
            let selfDistance = MeetingSpeakerVoiceMatcher.distance(profile, profile)
            let crossDistance = MeetingSpeakerVoiceMatcher.distance(profile, reference)
            let verified = MeetingOwnerVoiceVerifier.confirmedTokens(owner: owner, profiles: [profile]).count
            let sameSource = MeetingOwnerVoiceVerifier.confirmedTokens(owner: earlyReference, profiles: [profile]).count
            variants.append(.init(variantID: IDs[index], inputQuality: requests[index].clips.map(OwnerVoiceComparisonScalars.Quality.init),
                querySelfDistance: selfDistance, querySelfMatrix: OwnerVoiceComparisonScalars.matrix(profile.embeddings, profile.embeddings),
                crossOwnerMatrix: OwnerVoiceComparisonScalars.matrix(profile.embeddings, owner.embeddings), crossOwnerWorstDistance: crossDistance,
                queryPassesSelfConsistency: selfDistance.map { $0 <= MeetingSpeakerVoiceMatcher.maximumDistance } ?? false,
                queryPassesOwnerDistance: crossDistance.map { $0 <= MeetingSpeakerVoiceMatcher.maximumDistance } ?? false,
                verifiedOwnerCount: verified, sameSourceEarlyReferenceConfirmedCount: sameSource,
                duplicateEncodingDistance: IDs[index] == 6 ? MeetingSpeakerVoiceMatcher.distance(profile, first) : nil))
        }
        return .init(schemaVersion: 1, sourceQuality: .init(samples),
            ownerReferenceSelfDistance: MeetingSpeakerVoiceMatcher.distance(reference, reference),
            ownerReferenceSelfMatrix: OwnerVoiceComparisonScalars.matrix(owner.embeddings, owner.embeddings),
            ownerReferenceValid: MeetingOwnerVoiceProfileStore.isValid(owner), ownerOriginalPCMAvailable: false,
            maximumDistance: MeetingSpeakerVoiceMatcher.maximumDistance, requiredAmbiguityMargin: MeetingSpeakerVoiceMatcher.ambiguityMargin,
            independentCandidatesPerComparison: 1, observedAmbiguityMarginAvailable: false,
            inferenceSeconds: elapsed, ownerProfileUnchanged: false, variants: variants)
    }

    func testPrivateVoiceDiagnosticRequiresEveryOptInAndBoundedInput() throws {
        let enabled = ["PICHI_OWNER_VOICE_PRIVATE_DIAGNOSTIC": "1", "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1",
            "PICHI_COMBINED_MEETING_E2E": "1", "PICHI_MEETING_DETAILED_PROFILE": "1",
            "PICHI_OWNER_VOICE_DIAGNOSTIC_AUDIO_SHA256": String(repeating: "a", count: 64)]
        XCTAssertNoThrow(try OwnerVoiceComparisonOptions(environment: enabled))
        for key in enabled.keys {
            var missing = enabled; missing.removeValue(forKey: key)
            XCTAssertThrowsError(try OwnerVoiceComparisonOptions(environment: missing))
        }
        for frames in ["-1", "0", "102399", "320001", "999999999999999999999999", "nan"] {
            var invalid = enabled; invalid["PICHI_OWNER_VOICE_DIAGNOSTIC_SOURCE_FRAMES"] = frames
            XCTAssertThrowsError(try OwnerVoiceComparisonOptions(environment: invalid))
        }
    }

    func testPrivateVoiceDiagnosticQualityAndMatrixAreScalarOnly() throws {
        let quality = OwnerVoiceComparisonScalars.Quality([-1, -0.25, 0.25, 1])
        XCTAssertEqual(quality.sampleCount, 4)
        XCTAssertEqual(quality.finiteCount, 4)
        XCTAssertEqual(quality.mean, 0)
        XCTAssertEqual(quality.clippedFraction, 0.5)
        let data = try JSONEncoder().encode(quality)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["sampleCount", "finiteCount", "mean", "rms", "centeredRMS", "minimum", "maximum", "clippedFraction"])
        XCTAssertTrue(object.values.allSatisfy { $0 is NSNumber })
        let first: [Float] = [1, 0] + [Float](repeating: 0, count: 254)
        let other: [Float] = [0, 1] + [Float](repeating: 0, count: 254)
        let matrix = OwnerVoiceComparisonScalars.matrix([first, other], [first, other])
        XCTAssertEqual(matrix[0][0], 0)
        XCTAssertEqual(matrix[0][1], 1)
        XCTAssertEqual(matrix[1][0], 1)
        XCTAssertEqual(matrix[1][1], 0)
    }
}
