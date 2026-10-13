import Foundation
@testable import FluidVoice_Debug
import XCTest

private struct SyntheticPersonRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let input = text as NSString
        let range = input.range(of: "Анна Тестова")
        guard range.location != NSNotFound else { return TranscriptTextRedaction(text: text, spans: []) }
        return TranscriptTextRedaction(text: input.replacingCharacters(in: range, with: "[PERSON]"),
                                       spans: [.init(range: range, replacement: "[PERSON]")])
    }
}

private struct SyntheticFailingRedactor: TranscriptTextRedacting {
    struct Failure: Error {}
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction { throw Failure() }
}

final class MeetingPrivacyPublicationTests: XCTestCase {
    func testUtteranceKeepsUnrelatedTextAndTimingAfterPIIRedaction() async throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let input = MeetingFinalTextUnit(id: "utterance", trackID: epoch.trackID, analysisEpochID: epoch,
                                        precision: .utterance, text: "Врач Анна Тестова просит копию.",
                                        analysisStart: 0, analysisEnd: 3, speaker: .unassigned, analysisSpanIDs: ["span"])
        let original = MeetingFinalTranscriptEvidence(backendID: .gigaam, attemptID: UUID(), units: [input])
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedEvidence(original, using: SyntheticPersonRedactor())
        XCTAssertEqual(safe.units[0].text, "Врач [PERSON] просит копию.")
        XCTAssertEqual(safe.units[0].id, input.id)
        XCTAssertEqual(safe.units[0].analysisStart, input.analysisStart)
        XCTAssertEqual(safe.units[0].analysisEnd, input.analysisEnd)
        XCTAssertEqual(safe.units[0].precision, .utterance)
        XCTAssertEqual(original.units[0].text, input.text)
    }

    func testNameSpanningWordUnitsCannotEscapeIntoCanonicalSidecarLexemes() async throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let words = ["Здравствуйте", "Анна", "Тестова", "hello"]
        let units = words.enumerated().map { index, text in
            MeetingFinalTextUnit(id: "word-\(index)", trackID: epoch.trackID, analysisEpochID: epoch,
                                 precision: .word, text: text, analysisStart: Double(index), analysisEnd: Double(index + 1),
                                 speaker: .unassigned, analysisSpanIDs: ["span"])
        }
        let original = MeetingFinalTranscriptEvidence(backendID: .gigaam, attemptID: UUID(), units: units)
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedEvidence(original, using: SyntheticPersonRedactor())
        XCTAssertEqual(safe.units.map(\.text), ["Здравствуйте", "[PERSON]", "[PERSON]", "hello"])
        XCTAssertEqual(safe.units.map(\.id), original.units.map(\.id))
        XCTAssertEqual(safe.units.map(\.analysisSpanIDs), original.units.map(\.analysisSpanIDs))
    }

    func testPrivacyFailureCannotReturnAnUnfilteredPublication() async throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let unit = MeetingFinalTextUnit(id: "utterance", trackID: epoch.trackID, analysisEpochID: epoch,
                                       precision: .utterance, text: "Анна Тестова", analysisStart: 0, analysisEnd: 1,
                                       speaker: .unassigned, analysisSpanIDs: ["span"])
        let evidence = MeetingFinalTranscriptEvidence(backendID: .gigaam, attemptID: UUID(), units: [unit])
        do {
            _ = try await MeetingTranscriptPrivacyPolicy.redactedEvidence(evidence, using: SyntheticFailingRedactor())
            XCTFail("A failed privacy model must prevent publication")
        } catch is SyntheticFailingRedactor.Failure { }
    }
}
