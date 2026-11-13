@testable import FluidVoice_Debug
import Foundation
import XCTest

final class MeetingTranscriptNormalizerTests: XCTestCase {
    func testFinalPhraseFormattingRetainsNativeWordRowsAndTiming() async throws {
        let session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic quantities",
            microphone: .init(captureDeviceID: "synthetic-mic", displayName: "Fixture"), audioStorageMode: .memoryOnly),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        let track = UUID(), speaker = UUID()
        let input = ["twenty", "dollars"].enumerated().map { offset, text in
            var segment = MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64(offset), timescale: 1),
                end: .init(value: Int64(offset + 1), timescale: 1), sourceTrackID: track, speakerID: speaker,
                text: text, revision: 1, status: .final, overlap: .none, completeness: .complete)
            segment.nativePrecision = .word
            return segment
        }
        let result = try await MeetingProcessingPipeline.normalizedPublicationSegments(input, speakers: [],
            session: session, coverageGaps: [], configuration: .init(), redactor: nil, privacyIdentity: nil)
        XCTAssertEqual(result.map(\.id), input.map(\.id))
        XCTAssertEqual(result.map(\.start), input.map(\.start))
        XCTAssertEqual(result.map(\.end), input.map(\.end))
        XCTAssertEqual(result.map(\.speakerID), input.map(\.speakerID))
        XCTAssertEqual(result.map(\.nativePrecision), input.map(\.nativePrecision))
        XCTAssertEqual(result.map(\.text).joined().trimmingCharacters(in: .whitespaces), "$20")
    }

    private func segment(_ text: String) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: UUID(),
            start: .init(value: 1000, timescale: 1000),
            end: .init(value: 3000, timescale: 1000),
            sourceTrackID: UUID(),
            speakerID: UUID(),
            text: text,
            originalText: "original evidence",
            revision: 3,
            status: .final,
            overlap: .overlapsOtherTrack,
            completeness: .incompleteTrack,
            isLikelyEcho: false,
            attributionState: .timingUncertain
        )
    }

    func testSavedReplacementsPreserveMetadataAndUseLiteralWholeWordRules() async throws {
        let rules: [SettingsStore.CustomDictionaryEntry] = [
            .init(triggers: ["space fest", "spacefast"], replacement: "Spacefast"),
            .init(triggers: ["codec"], replacement: "Codex"),
            .init(triggers: ["fee"], replacement: "$30"),
            .init(triggers: ["claude"], replacement: "Claude Code"),
        ]
        let input = [self.segment("SPACE FEST codec codecs fee Claude Code, claude; twenty dollars")]
        let result = try await MeetingTranscriptNormalizer.normalize(input, languageCode: "en", dictionaryEntries: rules)
        var expected = input
        expected[0].text = "Spacefast Codex codecs $30 Claude Code, Claude Code; $20"
        XCTAssertEqual(result, expected, "only final display text may change")
        XCTAssertEqual(input[0].originalText, "original evidence")
    }

    func testDictionaryWorksInOtherLanguagesButDoesNotJoinSpeakersOrEditPartialCaptions() async throws {
        let rules: [SettingsStore.CustomDictionaryEntry] = [.init(triggers: ["space fest"], replacement: "Spacefast")]
        var provisional = self.segment("space fest")
        provisional.status = .provisional
        let input = [self.segment("space"), self.segment("fest"), self.segment("space fest"), provisional]
        var expected = input
        expected[2].text = "Spacefast"
        let result = try await MeetingTranscriptNormalizer.normalize(input, languageCode: "de", dictionaryEntries: rules)
        XCTAssertEqual(result, expected)
    }

    func testReplacementDeletionWhitespaceAndChainingMatchDictationRules() async throws {
        let rules: [SettingsStore.CustomDictionaryEntry] = [
            .init(triggers: ["first phrase"], replacement: "alias"),
            .init(triggers: ["alias"], replacement: "Name"),
            .init(triggers: ["remove"], replacement: ""),
            .init(triggers: ["linebreak"], replacement: "\n"),
        ]
        let result = try await MeetingTranscriptNormalizer.normalize([self.segment("first phrase remove linebreak next")], languageCode: "de", dictionaryEntries: rules)
        XCTAssertEqual(result[0].text, "Name \nnext")
    }

    func testFormatsQuantitiesAndPreservesEveryOtherSegmentField() async throws {
        let segments = [self.segment("twenty dollars, five billion parameters, one hundred tokens per second")]
        let result = try await MeetingTranscriptNormalizer.normalize(segments, languageCode: "en-US")
        var expected = segments
        expected[0].text = "$20, 5B parameters, 100 tokens per second"
        XCTAssertEqual(result, expected)
        XCTAssertEqual(segments[0].text, "twenty dollars, five billion parameters, one hundred tokens per second")
        let repeated = try await MeetingTranscriptNormalizer.normalize(result, languageCode: "en")
        XCTAssertEqual(repeated, result)
    }

    func testPreservesProseEmojiCommandsCodeLinksAndAmbiguousNumbers() async throws {
        let segments = [self.segment("fire emoji, literal fire emoji, twenty people, five pounds, `twenty dollars`, https://example.com/twenty-dollars")]
        let result = try await MeetingTranscriptNormalizer.normalize(segments, languageCode: "en")
        XCTAssertEqual(result, segments)
    }

    func testDoesNotCombineDifferentSpeakersOrFormatPartialCaptions() async throws {
        var partial = self.segment("twenty dollars")
        partial.status = .provisional
        let segments = [self.segment("twenty"), self.segment("dollars"), partial]
        let result = try await MeetingTranscriptNormalizer.normalize(segments, languageCode: "en")
        XCTAssertEqual(result, segments)
    }

    func testUsesEachRequestsLanguageWithoutCrossContamination() async throws {
        let segments = [self.segment("twenty dollars")]
        async let english = MeetingTranscriptNormalizer.normalize(segments, languageCode: "en")
        async let spanish = MeetingTranscriptNormalizer.normalize(segments, languageCode: "es")
        async let unknown = MeetingTranscriptNormalizer.normalize(segments, languageCode: "auto")
        let results = try await (english, spanish, unknown)
        XCTAssertEqual(results.0[0].text, "$20")
        XCTAssertEqual(results.1, segments)
        XCTAssertEqual(results.2, segments)
    }

    func testUnsafeAndOversizedTurnsPassThroughWithoutBlockingOtherTurns() async throws {
        let segments = [self.segment("twenty dollars\0"), self.segment(String(repeating: "a", count: 65_537)), self.segment("twenty dollars")]
        let result = try await MeetingTranscriptNormalizer.normalize(
            segments, languageCode: "en", dictionaryEntries: [.init(triggers: ["twenty"], replacement: "thirty")]
        )
        XCTAssertEqual(Array(result.prefix(2)), Array(segments.prefix(2)))
        XCTAssertEqual(result[2].text, "$30")
    }

    func testCancelledAttemptDoesNotPublishFormattedText() async {
        let segments = [self.segment("twenty dollars")]
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingTranscriptNormalizer.normalize(segments, languageCode: "en")
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled processing must not publish a transcript")
        } catch is CancellationError {
            // Expected: the caller retains its previous saved transcript.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
