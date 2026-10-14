import Foundation
#if !PICHI_WHISPER_DIAGNOSTICS_STANDALONE
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
        print("PASS: 7 synthetic Whisper diagnostic scenarios using production values")
    }
}
#else
@MainActor
final class WhisperDiagnosticsTests: XCTestCase {
    func testSilenceAndPhysicalDuration() throws { try WhisperDiagnosticCases.silenceAndPhysicalDuration() }
    func testSineAndDCOffset() throws { try WhisperDiagnosticCases.sineAndDCOffset() }
    func testClippingAndQuietSampleFractions() throws { try WhisperDiagnosticCases.clippingAndQuietSampleFractions() }
    func testInvalidPCMIsRejected() throws { try WhisperDiagnosticCases.invalidPCMIsRejected() }
    func testTokenProbabilitiesExcludeUnavailableOrInvalidValues() throws { try WhisperDiagnosticCases.tokenProbabilitiesExcludeUnavailableOrInvalidValues() }
    func testLanguageFieldsCannotLogArbitraryPayloads() throws { try WhisperDiagnosticCases.languageFieldsCannotLogArbitraryPayloads() }
    func testUnknownTimingsRemainUnknown() throws { try WhisperDiagnosticCases.unknownTimingsRemainUnknown() }

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
}
#endif
