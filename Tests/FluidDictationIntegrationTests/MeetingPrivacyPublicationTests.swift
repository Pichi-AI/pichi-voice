import Foundation
@testable import FluidVoice_Debug
import XCTest

@MainActor
private final class SyntheticPersonRedactor: TranscriptTextRedacting {
    let approvesPreview: Bool
    private(set) var inputs: [String] = []
    init(approvesPreview: Bool = false) { self.approvesPreview = approvesPreview }

    @MainActor func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
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

@MainActor
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
        let unstableInputs = approvedRedactor.inputs
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

/// Ordinary retained-audio processing must prepare the exact frozen privacy capability even
/// after a cold launch. Synthetic canonical evidence exercises the real pipeline/publication.
@MainActor
final class MeetingPrivacyPreparationLifecycleTests: XCTestCase {
    private enum FixtureFailure: Error { case notPrepared, preparationFailed }
    private enum Behavior { case ready, failure, suspended, changedIdentity }
    private nonisolated final class Identity: @unchecked Sendable {
        private let lock = NSLock()
        private var value = "synthetic-privacy-v1"
        var current: String { self.lock.withLock { self.value } }
        func change() { self.lock.withLock { self.value = "synthetic-privacy-v2" } }
    }
    @MainActor private final class ColdRedactor: TranscriptTextRedacting {
        private nonisolated let identity = Identity()
        nonisolated var checkpointIdentity: String? { self.identity.current }
        var behavior: Behavior = .ready
        var started: AsyncStream<Void>.Continuation?
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var isReady = false
        private(set) var preparations = 0
        private(set) var inputs: [String] = []
        @MainActor func prepareForMeeting() async throws {
            self.preparations += 1
            switch self.behavior {
            case .failure: throw FixtureFailure.preparationFailed
            case .suspended:
                self.started?.yield(())
                // Deliberately non-cooperative so the pipeline's post-await cancellation
                // check, rather than an adapter-specific implementation, is exercised.
                await withCheckedContinuation { self.waiter = $0 }
            case .changedIdentity: self.identity.change()
            case .ready: break
            }
            self.isReady = true
        }
        func release() { self.waiter?.resume(); self.waiter = nil }
        @MainActor func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
            guard self.isReady else { throw FixtureFailure.notPrepared }
            self.inputs.append(text)
            let source = text as NSString
            let range = source.range(of: "Анна Тестова")
            if range.location == NSNotFound { return .init(text: text, spans: []) }
            return .init(text: source.replacingCharacters(in: range, with: "[PERSON]"),
                spans: [.init(range: range, replacement: "[PERSON]")])
        }
    }
    private struct Observer: MeetingChunkAudioObserving {
        func observe(chunk: MeetingAudioChunk, trackID: MeetingAudioTrackID) -> MeetingChunkObservationResult {
            .observed(.init(byteCount: chunk.byteCount, sha256: chunk.sha256,
                decoded: .init(sampleRate: 100, channelCount: 1, frameCount: 300,
                    durationSeconds: 3, codecPriming: .measuredFrames(0), processingFormatDescription: "synthetic")))
        }
    }
    private final class Backend: MeetingTranscriptionBackend {
        let descriptor = MeetingBackendDescriptor(id: .init(rawValue: "synthetic.privacy-preparation"),
            version: "1", execution: .local, supportedLanguageCodes: ["en"],
            supportedTrackKinds: [.microphone], supportedFinalPrecisions: [.utterance],
            resultContract: .canonicalEvidence, knownLimits: [])
        private(set) var executions = 0
        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            .init(request: request, descriptor: self.descriptor)
        }
        func execute(plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest?,
                     progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingBackendOutcome {
            self.executions += 1
            let manifest = try XCTUnwrap(manifest)
            let units = manifest.allSpans.enumerated().map { index, span in
                MeetingFinalTextUnit(id: "unit-\(index)", trackID: span.trackID, analysisEpochID: span.analysisEpochID,
                    precision: .utterance, text: "Анна Тестова", analysisStart: span.analysisInterval.start,
                    analysisEnd: span.analysisInterval.end, speaker: .unassigned, analysisSpanIDs: [span.id])
            }
            return .canonicalEvidence(.init(evidence: .init(backendID: plan.backendID,
                attemptID: plan.attemptID, units: units), coverageReceipts: manifest.allSpans.enumerated().map { index, span in
                    .init(id: "receipt-\(index)", spanID: span.id, analysisStart: span.analysisInterval.start,
                        analysisEnd: span.analysisInterval.end, status: .processed)
                }))
        }
    }
    private struct Fixture {
        var session: MeetingSession
        let directory: URL
        let pipeline: MeetingProcessingPipeline
        let backend: Backend
        let redactor: ColdRedactor
        let decoy: ColdRedactor
        let providerReads: () -> Int
    }
    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cold-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let chunk = MeetingAudioChunk(id: UUID(), sequence: 0, relativeFilePath: "tracks/microphone/synthetic.caf",
            presentationStart: .init(value: 0, timescale: 1), presentationEnd: .init(value: 3, timescale: 1),
            discontinuities: [], sha256: String(repeating: "a", count: 64), byteCount: 1_024, finalizationState: .finalized)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic retained retry",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"),
            audioStorageMode: .retainedFiles, speakerLabelsEnabled: false, piiRedactionEnabled: true), timebase: timebase)
        session.audioTracks = [.init(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [chunk])]
        let redactor = ColdRedactor()
        let decoy = ColdRedactor()
        let backend = Backend()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: backend.descriptor.id)
        registry.register(backend.descriptor.id) { _ in backend }
        var reads = 0
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: {
            XCTFail("Synthetic canonical evidence must not load an ASR model"); return ASRService()
        }, managesModelResidency: false, privacyRedactorProvider: {
            reads += 1
            return reads == 1 ? redactor : decoy
        }, serializationGate: MeetingProcessingSerializationGate(), backendRegistry: registry, chunkObserver: Observer())
        return .init(session: session, directory: directory, pipeline: pipeline, backend: backend,
            redactor: redactor, decoy: decoy, providerReads: { reads })
    }
    private func assertNoPublication(_ fixture: Fixture) throws {
        XCTAssertEqual(fixture.backend.executions, 0)
        XCTAssertTrue(fixture.redactor.inputs.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testColdRetainedAttemptPreparesExactPinnedRedactorBeforeSafeCanonicalPublication() async throws {
        let value = try self.fixture()
        XCTAssertFalse(value.redactor.isReady)
        let identity = value.redactor.checkpointIdentity
        let result = try await value.pipeline.process(session: value.session, sessionDirectory: value.directory, progress: { _ in })
        XCTAssertTrue(value.redactor.isReady)
        XCTAssertEqual(value.redactor.preparations, 1)
        XCTAssertEqual(value.providerReads(), 1, "The attempt must never refetch a different provider after preparation")
        XCTAssertEqual(value.decoy.preparations, 0)
        XCTAssertTrue(value.decoy.inputs.isEmpty)
        XCTAssertEqual(value.redactor.checkpointIdentity, identity)
        XCTAssertEqual(value.backend.executions, 1)
        XCTAssertEqual(result.segments.map(\.text), ["[PERSON]"])
        let reference = try XCTUnwrap(result.resultSidecarReference)
        let sidecar = try MeetingResultSidecarStore(sessionDirectory: value.directory).read(
            expectedAttemptID: result.attempt.id, expectedBackendID: value.backend.descriptor.id, reference: reference)
        XCTAssertEqual(sidecar.units.map(\.text), ["[PERSON]"])
    }

    func testPreparationFailureStopsBeforeExecutionAndPublication() async throws {
        let value = try self.fixture()
        value.redactor.behavior = .failure
        do {
            _ = try await value.pipeline.process(session: value.session, sessionDirectory: value.directory, progress: { _ in })
            XCTFail("A cold resource failure must not publish raw evidence")
        } catch FixtureFailure.preparationFailed {}
        XCTAssertEqual(value.redactor.preparations, 1)
        try self.assertNoPublication(value)
    }

    func testCancellationDuringNonCooperativePreparationStopsBeforePublicationAndReleasesLeaseForRetry() async throws {
        let value = try self.fixture()
        let (stream, started) = AsyncStream<Void>.makeStream()
        value.redactor.started = started
        value.redactor.behavior = .suspended
        let task = Task { try await value.pipeline.process(session: value.session, sessionDirectory: value.directory, progress: { _ in }) }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        value.redactor.release()
        do { _ = try await task.value; XCTFail("Cancelled preparation cannot run the backend") }
        catch is CancellationError {}
        try self.assertNoPublication(value)
        // A fresh retry must acquire the gate and prepare its own frozen cold provider.
        let result = try await value.pipeline.process(session: value.session, sessionDirectory: value.directory, progress: { _ in })
        XCTAssertEqual(value.decoy.preparations, 1)
        XCTAssertTrue(value.decoy.isReady)
        XCTAssertEqual(result.segments.map(\.text), ["[PERSON]"])
    }

    func testPreparationCannotChangeFrozenPrivacyIdentity() async throws {
        let value = try self.fixture()
        value.redactor.behavior = .changedIdentity
        do {
            _ = try await value.pipeline.process(session: value.session, sessionDirectory: value.directory, progress: { _ in })
            XCTFail("Prepared resource identity must match the frozen request")
        } catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration {}
        try self.assertNoPublication(value)
    }
}
