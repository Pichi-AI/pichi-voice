import Foundation
#if !PICHI_WHISPER_DIAGNOSTICS_STANDALONE
import AVFoundation
import TranscribeCpp
import XCTest
@testable import PichiVoiceMobile
#endif

/// The same synthetic scenarios run against the production value declarations
/// in a portable harness and against the real hosted iOS module. No models,
/// capture, playback, application settings, or user logs are used.
private enum WhisperDiagnosticCases {
    struct Mismatch: Error { let description: String }

    static func require(_ predicate: @autoclosure () -> Bool, _ message: String) throws {
        guard predicate() else { throw Mismatch(description: message) }
    }

    static func approximate(_ actual: Double, _ expected: Double, _ tolerance: Double = 1e-6) throws {
        try require(actual.isFinite && abs(actual - expected) <= tolerance, "Unexpected aggregate \(actual), expected \(expected)")
    }

    static func silenceAndPhysicalDuration() throws {
        guard let silence = WhisperSignalDiagnostics.measure([Float](repeating: 0, count: 16_000)) else {
            throw Mismatch(description: "Valid silence rejected")
        }
        try require(silence.sampleCount == 16_000, "Incorrect actual sample count")
        try approximate(silence.durationMilliseconds, 1_000)
        try approximate(silence.rms, 0)
        try approximate(silence.peak, 0)
        try approximate(silence.dc, 0)
        try approximate(silence.clippingFraction, 0)
        try approximate(silence.quietFraction, 1)
        guard let tail = WhisperSignalDiagnostics.measure([0.25]) else { throw Mismatch(description: "Valid tail rejected") }
        try approximate(tail.durationMilliseconds, 0.0625)
        try require(tail.sampleCount == 1, "Diagnostics must not report inference padding as captured audio")
    }

    static func sineAndDCOffset() throws {
        let sine = (0..<16_000).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 16_000)) }
        guard let signal = WhisperSignalDiagnostics.measure(sine),
              let constant = WhisperSignalDiagnostics.measure([Float](repeating: 0.25, count: 320)) else {
            throw Mismatch(description: "Valid synthetic signal rejected")
        }
        try approximate(signal.rms, 0.5 / sqrt(2))
        try approximate(signal.peak, 0.5)
        try approximate(signal.dc, 0)
        try approximate(signal.clippingFraction, 0)
        try approximate(signal.quietFraction, 0.125)
        try approximate(constant.rms, 0.25)
        try approximate(constant.dc, 0.25)
        try approximate(constant.quietFraction, 0)
    }

    static func clippingAndQuietSampleFractions() throws {
        guard let signal = WhisperSignalDiagnostics.measure([0, 1, -1, 0.0005, -0.0005, 2, -2]) else {
            throw Mismatch(description: "Finite out-of-range amplitudes must be measured truthfully")
        }
        try approximate(signal.peak, 2)
        try approximate(signal.dc, 0)
        try approximate(signal.rms, sqrt(10.0000005 / 7))
        try approximate(signal.clippingFraction, 4.0 / 7)
        try approximate(signal.quietFraction, 3.0 / 7)
    }

    static func invalidPCMIsRejected() throws {
        try require(WhisperSignalDiagnostics.measure([]) == nil, "Empty input has no measurable level")
        for invalid in [Float.nan, .infinity, -.infinity] {
            try require(WhisperSignalDiagnostics.measure([0, invalid, 0]) == nil, "Non-finite PCM must fail validation")
        }
        guard let huge = WhisperSignalDiagnostics.measure([.greatestFiniteMagnitude]) else {
            throw Mismatch(description: "Finite PCM wrongly rejected")
        }
        try require(huge.rms.isFinite && huge.peak.isFinite, "Double accumulator must not overflow for finite Float amplitudes")
    }

    static func tokenProbabilitiesExcludeUnavailableOrInvalidValues() throws {
        let mixed = WhisperProbabilityDiagnostics.measure([Float(0), 0.25, 0.75, 1, .nan, .infinity, -.infinity, -0.1, 1.1])
        try require(mixed.validCount == 4 && mixed.invalidCount == 5, "Only finite [0,1] probabilities may enter the mean")
        guard let mean = mixed.mean else { throw Mismatch(description: "Valid probabilities lost") }
        try approximate(mean, 0.5)
        let empty = WhisperProbabilityDiagnostics.measure([Float]())
        try require(empty.validCount == 0 && empty.invalidCount == 0 && empty.mean == nil, "No tokens must not imply perfect confidence")
        let absent = WhisperProbabilityDiagnostics.measure([Float.nan, -1])
        try require(absent.validCount == 0 && absent.invalidCount == 2 && absent.mean == nil, "Unavailable confidence must remain unavailable")
    }

    static func languageFieldsCannotLogArbitraryPayloads() throws {
        let codes: Set<String> = ["ru", "en"]
        try require(WhisperProbabilityDiagnostics.languageField("ru", supportedCodes: codes, absent: "auto") == "ru", "Registered language lost")
        try require(WhisperProbabilityDiagnostics.languageField(nil, supportedCodes: codes, absent: "auto") == "auto", "Automatic language lost")
        for payload in ["", "synthetic private transcript", "ru\nforged log", "person@example.invalid", "RU"] {
            try require(WhisperProbabilityDiagnostics.languageField(payload, supportedCodes: codes, absent: "none") == "unsupported", "Arbitrary library payload must not enter logs")
        }
    }

    static func unknownTimingsRemainUnknown() throws {
        for timing in [Float(0), -1, .nan, .infinity, -.infinity] {
            try require(WhisperProbabilityDiagnostics.timingField(timing) == "unmeasured", "Unknown stage must not look measured")
        }
        try require(WhisperProbabilityDiagnostics.timingField(1.25) == "1.250", "Measured library timing lost")
    }

    static func tinyPolicyRequiresLoadedArtifactAndBoundedPhysicalInput() throws {
        let tiny = "whisper-tiny-Q8_0.gguf"
        for count in [1, 16_000, 320_000] {
            try require(WhisperShortInputPolicy.applies(modelFile: tiny, sampleCount: count), "Supported short Tiny input lost")
        }
        for count in [-1, 0, 320_001, Int.max] {
            try require(!WhisperShortInputPolicy.applies(modelFile: tiny, sampleCount: count), "Long/invalid input must retain the original recipe")
        }
        for artifact in [nil, "whisper-base-Q8_0.gguf", "whisper-tiny.en-Q8_0.gguf", "selected-whisper-tiny", "whisper-small-Q8_0.gguf"] {
            try require(!WhisperShortInputPolicy.applies(modelFile: artifact, sampleCount: 16_000), "Policy must follow the actual loaded artifact")
        }
    }

    static func nativeQualityKeepsClearAndQuietSpeechWithoutTokens() throws {
        // Approved synthetic benchmark traces, including quiet RU at 1% gain.
        // These are encoder-quality scalars, independent of absent token.p data.
        for chunk in [
            quality(avgLogprob: -0.18514045, compressionRatio: 0.8135593, noSpeechProbability: 0.002179833),
            quality(avgLogprob: -0.17152354, compressionRatio: 0.74418604, noSpeechProbability: 0.0036504273),
            quality(avgLogprob: -0.29947317, compressionRatio: 0.82539684, noSpeechProbability: 0.009763503),
        ] {
            try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [chunk]) == .accepted, "Valid speech quality must remain accepted")
        }
        let boundary = quality(avgLogprob: -1, compressionRatio: 2.4, noSpeechProbability: 0.899)
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [boundary]) == .accepted, "Inclusive quality boundaries must remain accepted")
        try require(WhisperShortInputPolicy.evaluate(hasText: false, chunks: []) == .empty, "An empty successful decode is not a capture failure")
    }

    static func uncertainSpeechIsPreservedWhileSilenceAndRepetitionAreRejected() throws {
        // Scalar traces from the reported 1.0 (24) failure, not private PCM or text.
        for chunk in [quality(avgLogprob: -1.013960, noSpeechProbability: 0.101760),
                      quality(avgLogprob: -1.223409, noSpeechProbability: 0.096204),
                      quality(avgLogprob: -2.653449, noSpeechProbability: 0.147411)] {
            let decision = WhisperShortInputPolicy.evaluate(hasText: true, chunks: [chunk])
            try require(decision == .lowLogprob && decision.preservesText,
                        "Uncertain native wording must not become a successful empty speech result")
        }
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [quality(compressionRatio: 2.401)]) == .compression, "Repetitive final decoder tier must be suppressed")
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [quality(noSpeechProbability: 0.9)]) == .noSpeech, "Strong no-speech evidence must suppress Tiny hallucination")
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [quality(noSpeechProbability: 0.01, noSpeechTriggered: true)]) == .noSpeech, "Native no-speech decision must be honored")
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [quality(), quality(avgLogprob: -1.01, fallbacks: 5)]) == .lowLogprob, "Low likelihood remains an explicit diagnostic decision")
        for rejected in [quality(compressionRatio: 2.401), quality(noSpeechProbability: 0.95),
                         quality(avgLogprob: .nan)] {
            let decision = WhisperShortInputPolicy.evaluate(hasText: true, chunks: [quality(avgLogprob: -1.2), rejected])
            try require(!decision.preservesText, "Uncertain early wording cannot hide a later unsafe or malformed chunk")
        }
        for decision: WhisperShortInputPolicy.Decision in [.empty, .missingQuality, .invalidQuality, .noSpeech, .compression] {
            try require(!decision.preservesText, "Rejected native evidence cannot be published")
        }
        try require(WhisperShortInputPolicy.Decision.accepted.preservesText, "Clear native speech remains accepted")
        // Successful fallback is not intrinsically bad quality. It is the
        // native final-tier measurements that determine acceptance.
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [quality(temperature: 0.2, fallbacks: 1)]) == .accepted, "Do not invent a confidence penalty from the fallback count")
    }

    static func missingOrMalformedNativeQualityCannotBecomePerfectConfidence() throws {
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: []) == .missingQuality, "Nonempty result without quality cannot imply success")
        for value in [Float.nan, .infinity, -.infinity] {
            for chunk in [quality(temperature: value), quality(avgLogprob: value), quality(compressionRatio: value), quality(noSpeechProbability: value)] {
                try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [chunk]) == .invalidQuality, "Non-finite quality must be rejected")
            }
        }
        for chunk in [quality(temperature: -1), quality(avgLogprob: 0.1), quality(compressionRatio: -1), quality(noSpeechProbability: -0.1), quality(noSpeechProbability: 1.1), quality(fallbacks: -1)] {
            try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [chunk]) == .invalidQuality, "Out-of-domain quality must be rejected")
        }
    }

    static func partialQualityGateDoesNotPretendToBeSemanticOrVoiceActivityDetection() throws {
        // This approved noise control still passes the native thresholds. Keep
        // the limitation explicit instead of tightening a quiet-speech RMS gate.
        let noise = quality(avgLogprob: -0.9629, noSpeechProbability: 0.7977)
        try require(WhisperShortInputPolicy.evaluate(hasText: true, chunks: [noise]) == .accepted, "Native quality criteria do not prove semantic correctness")
    }

    private static func quality(temperature: Float = 0, avgLogprob: Float = -0.5,
                                compressionRatio: Float = 1.2, noSpeechProbability: Float = 0.1,
                                fallbacks: Int32 = 0, noSpeechTriggered: Bool = false) -> WhisperShortInputPolicy.Chunk {
        .init(temperature: temperature, avgLogprob: avgLogprob, compressionRatio: compressionRatio,
              noSpeechProbability: noSpeechProbability, fallbacks: fallbacks, noSpeechTriggered: noSpeechTriggered)
    }
}

#if PICHI_WHISPER_DIAGNOSTICS_STANDALONE
@main
private struct WhisperDiagnosticsStandalone {
    static func main() throws {
        try WhisperDiagnosticCases.silenceAndPhysicalDuration()
        try WhisperDiagnosticCases.sineAndDCOffset()
        try WhisperDiagnosticCases.clippingAndQuietSampleFractions()
        try WhisperDiagnosticCases.invalidPCMIsRejected()
        try WhisperDiagnosticCases.tokenProbabilitiesExcludeUnavailableOrInvalidValues()
        try WhisperDiagnosticCases.languageFieldsCannotLogArbitraryPayloads()
        try WhisperDiagnosticCases.unknownTimingsRemainUnknown()
        try WhisperDiagnosticCases.tinyPolicyRequiresLoadedArtifactAndBoundedPhysicalInput()
        try WhisperDiagnosticCases.nativeQualityKeepsClearAndQuietSpeechWithoutTokens()
        try WhisperDiagnosticCases.uncertainSpeechIsPreservedWhileSilenceAndRepetitionAreRejected()
        try WhisperDiagnosticCases.missingOrMalformedNativeQualityCannotBecomePerfectConfidence()
        try WhisperDiagnosticCases.partialQualityGateDoesNotPretendToBeSemanticOrVoiceActivityDetection()
        print("PASS: 12 synthetic Whisper diagnostic/quality scenarios using production values")
    }
}
#else
@MainActor
final class WhisperDiagnosticsTests: XCTestCase {
    func testRealTinyProviderPreservesAnUncertainNativeSpeechResult() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["PICHI_WHISPER_MODEL_DIR"],
              let fixture = environment["PICHI_WHISPER_UNCERTAIN_FIXTURE"] else {
            throw XCTSkip("Enable a verified local Tiny model and synthetic noisy speech fixture explicitly")
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: fixture))
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        XCTAssertTrue((16_000...320_000).contains(Int(file.length)))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        // Verify the fixture's native premise before exercising the actual provider.
        // This does not infer wording accuracy from a scalar or publish private audio.
        let native = try await self.uncertainNativeSnapshot(samples, directory: directory)
        XCTAssertFalse(native.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(native.isUncertain, "The fixture must cover the reported low-likelihood branch")
        let provider = WhisperProvider(modelDirectory: URL(fileURLWithPath: directory),
            modelOverride: .whisperTiny, useAutomaticLanguageDetection: true)
        addTeardownBlock { @MainActor in await provider.releaseResidency() }
        try await provider.prepare()
        let recognized = try await provider.transcribe(samples)
        XCTAssertEqual(recognized.text, native.text.trimmingCharacters(in: .whitespacesAndNewlines),
                       "The adapter must preserve uncertain native wording instead of returning silence")
        XCTAssertFalse(recognized.text.isEmpty)
        // Uncertain native speech can lack usable alignment. The existing timing
        // validator may omit it; surviving intervals must still fit physical PCM.
        XCTAssertTrue(recognized.segmentTimings.allSatisfy { $0.end <= Double(samples.count) / 16_000 })
    }

    private func uncertainNativeSnapshot(_ samples: [Float], directory: String) async throws -> (text: String, isUncertain: Bool) {
        try Transcribe.initBackends()
        let model = try Model(path: URL(fileURLWithPath: directory)
            .appendingPathComponent("whisper-tiny-Q8_0.gguf").path, options: .init(backend: .cpu))
        let session = try model.session()
        let snapshot = try await session.runWhisper(samples, options: WhisperProvider.runOptions(
            languageCode: "auto", model: .whisperTiny,
            loadedModelName: "whisper-tiny-Q8_0.gguf", sampleCount: samples.count))
        let chunks = snapshot.chunks.map {
            WhisperShortInputPolicy.Chunk(temperature: $0.temperature, avgLogprob: $0.avgLogprob,
                compressionRatio: $0.compressionRatio, noSpeechProbability: $0.noSpeechProbability,
                fallbacks: $0.fallbacks, noSpeechTriggered: $0.noSpeechTriggered)
        }
        return (snapshot.transcript.text,
            WhisperShortInputPolicy.evaluate(hasText: !snapshot.transcript.text.isEmpty, chunks: chunks) == .lowLogprob)
    }

    func testSilenceAndPhysicalDuration() throws { try WhisperDiagnosticCases.silenceAndPhysicalDuration() }
    func testSineAndDCOffset() throws { try WhisperDiagnosticCases.sineAndDCOffset() }
    func testClippingAndQuietSampleFractions() throws { try WhisperDiagnosticCases.clippingAndQuietSampleFractions() }
    func testInvalidPCMIsRejected() throws { try WhisperDiagnosticCases.invalidPCMIsRejected() }
    func testTokenProbabilitiesExcludeUnavailableOrInvalidValues() throws { try WhisperDiagnosticCases.tokenProbabilitiesExcludeUnavailableOrInvalidValues() }
    func testLanguageFieldsCannotLogArbitraryPayloads() throws { try WhisperDiagnosticCases.languageFieldsCannotLogArbitraryPayloads() }
    func testUnknownTimingsRemainUnknown() throws { try WhisperDiagnosticCases.unknownTimingsRemainUnknown() }
    func testTinyPolicyRequiresLoadedArtifactAndBoundedPhysicalInput() throws { try WhisperDiagnosticCases.tinyPolicyRequiresLoadedArtifactAndBoundedPhysicalInput() }
    func testNativeQualityKeepsClearAndQuietSpeechWithoutTokens() throws { try WhisperDiagnosticCases.nativeQualityKeepsClearAndQuietSpeechWithoutTokens() }
    func testUncertainSpeechIsPreservedWhileSilenceAndRepetitionAreRejected() throws {
        try WhisperDiagnosticCases.uncertainSpeechIsPreservedWhileSilenceAndRepetitionAreRejected()
    }
    func testMissingOrMalformedNativeQualityCannotBecomePerfectConfidence() throws { try WhisperDiagnosticCases.missingOrMalformedNativeQualityCannotBecomePerfectConfidence() }
    func testPartialQualityGateDoesNotPretendToBeSemanticOrVoiceActivityDetection() throws { try WhisperDiagnosticCases.partialQualityGateDoesNotPretendToBeSemanticOrVoiceActivityDetection() }

    func testSegmentOnlyNativeResultRetainsCoarseIntervalsWithoutWordClaims() {
        let segments = [ASRSegmentTiming(text: " Здравствуйте, давайте обсудим документ.", start: 0.2, end: 3.1),
                        ASRSegmentTiming(text: " Хорошо, посмотрим результаты.", start: 3.3, end: 6.5)]
        let result = WhisperProvider.transcriptionResult(
            text: " Здравствуйте, давайте обсудим документ. Хорошо, посмотрим результаты. ",
            segmentTimings: segments, sampleCount: 8 * 16_000)
        XCTAssertEqual(result.segmentTimings, segments)
        XCTAssertEqual(result.text, "Здравствуйте, давайте обсудим документ. Хорошо, посмотрим результаты.")
        XCTAssertNil(result.dictionaryLearningAlignment, "Native segments cannot claim word alignment")
        let options = WhisperProvider.runOptions(languageCode: "auto", timestamps: .segment,
            loadedModelName: "whisper-tiny-Q8_0.gguf", sampleCount: 8 * 16_000)
        XCTAssertTrue(options.timestamps == .segment, "Retaining metadata must not force costly word alignment")
    }

    func testNativeTerminalTimestampTickIsClippedOnlyToTheActualPCMEnd() {
        // Exact public RU fixture trace: 76777 frames, native final tick 4800ms.
        // Normal and attenuated speech return respectively one and two segments.
        let count = 76_777
        let duration = Double(count) / 16_000
        for segments: [ASRSegmentTiming] in [
            [.init(text: "First phrase. Second phrase.", start: 0, end: 4.8)],
            [.init(text: "First phrase.", start: 0, end: 2.76), .init(text: "Second phrase.", start: 2.76, end: 4.8)]
        ] {
            let text = segments.map(\.text).joined(separator: " ")
            let result = WhisperProvider.transcriptionResult(text: text, segmentTimings: segments, sampleCount: count)
            XCTAssertEqual(result.segmentTimings.count, segments.count)
            XCTAssertEqual(result.segmentTimings.last?.end, duration)
            XCTAssertEqual(result.segmentTimings.map(\.start), segments.map(\.start))
            XCTAssertEqual(result.segmentTimings.map(\.text), segments.map(\.text))
            XCTAssertTrue(result.segmentTimings.allSatisfy { $0.end <= duration })
            XCTAssertEqual(ASRSegmentTiming.validated(result.segmentTimings, text: text, duration: duration), result.segmentTimings)
        }
        let aligned = ASRSegmentTiming(text: "Aligned phrase.", start: 0, end: 4.8)
        XCTAssertEqual(WhisperProvider.transcriptionResult(text: aligned.text,
            segmentTimings: [aligned], sampleCount: 76_800).segmentTimings, [aligned])
        for invalid in [ASRSegmentTiming(text: "Invalid phrase.", start: 0, end: 4.82),
                        .init(text: "Invalid phrase.", start: 0, end: 4.799),
                        .init(text: "Invalid phrase.", start: 4.8, end: 4.8)] {
            let result = WhisperProvider.transcriptionResult(text: invalid.text,
                segmentTimings: [invalid], sampleCount: count)
            XCTAssertEqual(result.text, invalid.text)
            XCTAssertTrue(result.segmentTimings.isEmpty,
                "Arbitrary overrun, extra native ticks and nonphysical starts still use the complete untimed fallback")
        }
    }

    func testMalformedOrPartialNativeSegmentationRetainsFullWordingWithoutInventedTimes() {
        let text = "Keep the complete phrase."
        let invalid: [[ASRSegmentTiming]] = [
            [], [.init(text: "Keep", start: 0, end: 1)],
            [.init(text: text, start: -0.1, end: 2)],
            [.init(text: text, start: 0, end: .nan)],
            [.init(text: text, start: 0, end: 2.1)],
            [.init(text: text, start: 1, end: 1)],
            [.init(text: "Keep the", start: 0, end: 1.5), .init(text: "complete phrase.", start: 1, end: 2)],
            [.init(text: "Keep the", start: 1, end: 2), .init(text: "complete phrase.", start: 0, end: 1)],
        ]
        for segments in invalid {
            let result = WhisperProvider.transcriptionResult(text: text, segmentTimings: segments, sampleCount: 32_000)
            XCTAssertEqual(result.text, text)
            XCTAssertTrue(result.segmentTimings.isEmpty)
        }
        let brokenWord = [ASRSegmentTiming(text: "Ко", start: 0, end: 1), .init(text: "торый", start: 1, end: 2)]
        XCTAssertTrue(WhisperProvider.transcriptionResult(text: "Который", segmentTimings: brokenWord,
            sampleCount: 32_000).segmentTimings.isEmpty, "Segment metadata must not insert a space inside a word")
        let padded = WhisperProvider.transcriptionResult(text: text,
            segmentTimings: [.init(text: text, start: 0, end: 0.8)], sampleCount: 8_000)
        XCTAssertEqual(padded.text, text)
        XCTAssertTrue(padded.segmentTimings.isEmpty, "Padded inference does not extend physical audio bounds")
        XCTAssertTrue(ASRSegmentTiming.validated([.init(text: text, start: 0, end: 1)],
            text: text, duration: .infinity).isEmpty)
        XCTAssertTrue(ASRSegmentTiming.validated(Array(repeating: .init(text: text, start: 0, end: 1), count: 8_193),
            text: text, duration: 10_000).isEmpty)
    }

    func testProductionRunOptionsKeepRecognitionAndAutomaticLanguageSemantics() {
        for language in [nil, "auto", "ru", "en"] as [String?] {
            let options = WhisperProvider.runOptions(languageCode: language)
            XCTAssertTrue(options.task == .transcribe)
            XCTAssertNil(options.targetLanguage)
            XCTAssertEqual(options.language, language == "auto" ? nil : language)
            XCTAssertTrue(options.timestamps == .segment)
            XCTAssertNil(options.family)
        }
        let words = WhisperProvider.runOptions(languageCode: "auto", timestamps: .word)
        XCTAssertTrue(words.timestamps == .word)
        XCTAssertTrue(words.task == .transcribe)
        XCTAssertNil(words.targetLanguage)
    }

    func testTinyBoundedRunOptionsKeepLanguageAndTimestampContract() {
        for language in [nil, "auto", "ru", "en"] as [String?] {
            let options = WhisperProvider.runOptions(languageCode: language, timestamps: .word,
                                                     loadedModelName: "whisper-tiny-Q8_0.gguf", sampleCount: 32_000)
            XCTAssertTrue(options.task == .transcribe)
            XCTAssertNil(options.targetLanguage)
            XCTAssertEqual(options.language, language == "auto" ? nil : language)
            XCTAssertTrue(options.timestamps == .word)
            guard case .whisper(let family) = options.family else { return XCTFail("Bounded Tiny options missing") }
            XCTAssertEqual(family.temperature, 0)
            XCTAssertEqual(family.temperatureInc, 0)
            XCTAssertEqual(family.seed, 1)
            XCTAssertNil(family.initialPrompt)
            XCTAssertNil(family.logprobThold)
            XCTAssertNil(family.noSpeechThold)
        }
        for pair in [("whisper-tiny-Q8_0.gguf", 320_001), ("whisper-base-Q8_0.gguf", 32_000)] {
            XCTAssertNil(WhisperProvider.runOptions(languageCode: "auto", loadedModelName: pair.0, sampleCount: pair.1).family)
        }
    }
}
#endif
