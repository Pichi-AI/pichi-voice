import Foundation
@testable import FluidVoice_Debug
import XCTest

private actor SyntheticPersonRedactor: TranscriptTextRedacting {
    let approvesPreview: Bool
    private(set) var inputs: [String] = []
    init(approvesPreview: Bool = false) { self.approvesPreview = approvesPreview }

    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        self.inputs.append(text)
        let input = text as NSString
        let range = input.range(of: "Анна Тестова")
        guard range.location != NSNotFound else { return TranscriptTextRedaction(text: text, spans: []) }
        return TranscriptTextRedaction(text: input.replacingCharacters(in: range, with: "[PERSON]"),
                                       spans: [.init(range: range, replacement: "[PERSON]")],
                                       provisionalSafeUTF16: self.approvesPreview ? input.length : nil)
    }
}

private struct SyntheticFailingRedactor: TranscriptTextRedacting {
    struct Failure: Error {}
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction { throw Failure() }
}

final class MeetingPrivacyPublicationTests: XCTestCase {
    func testLivePartialUsesPriorPhraseContextWithoutChangingIdentityOrTiming() async throws {
        let utterance = MeetingLiveUtterance(id: UUID(), speaker: .you, text: "Анна", start: 0, end: 1)
        var partial = MeetingLivePartial(id: UUID(), text: "Тестова просит копию.", start: 1, end: 3)
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot.utterances = [utterance]
        snapshot.partials = [.you: partial]
        let approvedRedactor = SyntheticPersonRedactor(approvesPreview: true)
        let unstable = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(snapshot, using: approvedRedactor)
        XCTAssertTrue(unstable.utterances.isEmpty)
        XCTAssertTrue(unstable.partials.isEmpty)
        let unstableInputs = await approvedRedactor.inputs
        XCTAssertEqual(unstableInputs, ["Анна"], "An unstable partial cannot enter privacy inference")

        partial.stableUTF16Count = partial.text.utf16.count
        snapshot.partials[.you] = partial
        let unapproved = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(snapshot, using: SyntheticPersonRedactor())
        XCTAssertTrue(unapproved.utterances.isEmpty)
        XCTAssertTrue(unapproved.partials.isEmpty, "Stable recognition does not itself authorize publication")

        // Explicit adapter approval exercises projection only. The real detector's bounded
        // lexical admission and canonical finish are covered in MeetingPrivacyContextTests.
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(snapshot, using: approvedRedactor)
        XCTAssertEqual(safe.utterances.count, 1)
        let safeUtterance = try XCTUnwrap(safe.utterances.first)
        let safePartial = try XCTUnwrap(safe.partials[.you])
        XCTAssertEqual(safeUtterance.text, "[PERSON]")
        XCTAssertEqual(safePartial.text, "[PERSON] просит копию.")
        XCTAssertEqual(safeUtterance.id, utterance.id)
        XCTAssertEqual(safeUtterance.speaker, utterance.speaker)
        XCTAssertEqual(safeUtterance.start, utterance.start)
        XCTAssertEqual(safeUtterance.end, utterance.end)
        XCTAssertFalse(safeUtterance.hasIncompleteTextCoverage)
        XCTAssertEqual(safePartial.id, partial.id)
        XCTAssertEqual(safePartial.start, partial.start)
        XCTAssertEqual(safePartial.end, partial.end)
        XCTAssertNil(safePartial.stableUTF16Count, "Raw offsets do not describe redacted text")
        XCTAssertEqual(snapshot.utterances, [utterance])
        XCTAssertEqual(snapshot.partials[.you], partial)
    }

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

@MainActor
final class MeetingCaptureLanguageAdmissionTests: XCTestCase {
    func testValidWhisperLanguageOutsideParakeetCatalogueIsAdmittedBySharedDomain() throws {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "synthetic", displayName: "Synthetic microphone")
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic", languageCode: "ta", microphone: microphone)
        XCTAssertNoThrow(try configuration.validate())
        XCTAssertTrue(PichiMeetingProviderFactory.registeredLanguageCodes(for: "whisper-tiny")?.contains("ta") == true)
        XCTAssertNoThrow(try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(asrModel: "whisper-tiny", languageCode: "ta")))
        XCTAssertThrowsError(try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", languageCode: "ta")))
    }
    func testMalformedLanguageCannotReachProviderOrPersistence() throws {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "synthetic", displayName: "Synthetic microphone")
        for code in ["../ru", "en\n", "", String(repeating: "a", count: 36)] {
            XCTAssertThrowsError(try MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic", languageCode: code, microphone: microphone).validate())
        }
    }
    func testAllRegisteredMVPBackendsDeclareIndependentSpeakerResources() {
        for model in ["gigaam-v3-eou", "whisper-tiny", "parakeet-tdt"] {
            XCTAssertEqual(PichiMeetingProviderFactory.registeredBackendDescriptor(for: model)?.diarizationDependencies, [.speakerSeparation, .voiceMatching])
        }
    }
}

@MainActor
final class MeetingSpeakerHardwareAdmissionTests: XCTestCase {
    func testRetainedTranscriptOnlyFallbackSkipsUnsupportedSpeakerPreparationButStrictModeDoesNot() async throws {
        struct PreparationMarker: Error {}
        var preparations = 0
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { XCTFail("Pure capability admission cannot load ASR"); return ASRService() },
            managesModelResidency: false,
            prepareDiarizationDependencies: { _ in preparations += 1; throw PreparationMarker() },
            diarizationSupported: { false })
        let descriptor = MeetingBackendDescriptor(id: .init(rawValue: "synthetic-hardware-fallback"), version: "1", execution: .local,
            supportedLanguageCodes: ["en"], supportedTrackKinds: [.microphone], supportedFinalPrecisions: [.utterance],
            resultContract: .canonicalEvidence, knownLimits: [], diarizationDependencies: [.speakerSeparation, .voiceMatching],
            allowsTranscriptOnlyOnUnsupportedHardware: true)
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic", languageCode: "en",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"))
        var session = MeetingSession(configuration: configuration, timebase: .init(startedHostTime: 0,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        try await pipeline.prepareSpeakerDependencies(for: descriptor, session: session)
        XCTAssertEqual(preparations, 0)
        session.audioStorageMode = .memoryOnly
        do { try await pipeline.prepareSpeakerDependencies(for: descriptor, session: session); XCTFail("Requested strict speaker processing must not silently degrade") }
        catch is PreparationMarker { }
        XCTAssertEqual(preparations, 1)
        session.speakerLabelsEnabled = false
        try await pipeline.prepareSpeakerDependencies(for: descriptor, session: session)
        XCTAssertEqual(preparations, 1)
    }
}

final class MeetingTranscriptDisplayProjectionTests: XCTestCase {
    func testRepeatedSpeakerLabelsCollapseWithoutCollapsingAttributionStatesOrData() {
        let track = UUID()
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"))
        let session = MeetingSession(configuration: configuration, timebase: .init(startedHostTime: 0,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        let segments = ["Первое", "второе", "третье"].enumerated().map { index, text in
            MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64(index), timescale: 1),
                end: .init(value: Int64(index + 1), timescale: 1), sourceTrackID: track, speakerID: nil,
                text: text, revision: 0, status: .final, overlap: .none, completeness: .complete,
                attributionState: index == 2 ? .timingUncertain : .unassigned)
        }
        let rows = MeetingTranscriptExporter.displayRows(for: segments, in: session)
        XCTAssertEqual(rows.map(\.showsLabel), [true, false, true])
        XCTAssertEqual(rows.map(\.segment), segments)
    }
}
