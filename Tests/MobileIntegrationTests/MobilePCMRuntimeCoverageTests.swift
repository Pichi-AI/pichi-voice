@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@testable import PichiVoiceMobile
import XCTest

/// Model-mocked native runtime coverage. The prepared provider and strict PCM
/// transport are real; no model downloads, app activation or microphone are used.
@MainActor
final class MobilePCMRuntimeCoverageTests: XCTestCase {
    @MainActor private final class NativeScopeProvider: TranscriptionProvider {
        let name = "Generic native scope fixture"
        let isAvailable = true
        let supportsWordTimings = true
        var isReady = false
        var prepareCalls = 0
        var timedSampleCounts: [Int] = []
        var growingPrefixFixture = false
        var timedResponses: [Int: (text: String, words: [ASRWordTiming])] = [:]
        var timedErrors: [Int: CocoaError] = [:]
        var segmentResponses: [Int: [ASRSegmentTiming]] = [:]
        var releaseCalls = 0
        func releaseResidency() async { releaseCalls += 1; isReady = false }
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
            self.prepareCalls += 1
            self.isReady = true
        }
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            XCTFail("The native meeting session must preserve the provider's timing capability")
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
            self.timedSampleCounts.append(samples.count)
            if let error = timedErrors[samples.count] { throw error }
            if let response = timedResponses[samples.count] {
                return (ASRTranscriptionResult(text: response.text, confidence: response.text.isEmpty ? 0 : 1,
                    segmentTimings: segmentResponses[samples.count] ?? []), response.words)
            }
            var words: [ASRWordTiming] = [.init(text: "Scoped", start: 0.1, end: 0.4), .init(text: "provider", start: 0.4, end: 0.8)]
            if growingPrefixFixture && samples.count >= 96_000 {
                words.append(.init(text: "grows", start: 0.8, end: 1.1))
            }
            return (ASRTranscriptionResult(text: words.map(\.text).joined(separator: " "), confidence: 1), words)
        }
    }

    @MainActor private final class PCMPreviewObservation {
        var batch: MeetingPCMTranscriptBatch?
        var batches: [MeetingPCMTranscriptBatch] = []
        var checkpoints: [MeetingPCMTranscriptBatch] = []
        var safePreviews: [MeetingLivePartial?] = []
        var operation: Task<MeetingPCMTranscriptBatch, Error>?
    }

    private struct BenignPrivacyFixture: TranscriptTextRedacting {
        func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
            .init(text: text, spans: [], provisionalSafeUTF16: text.utf16.count)
        }
    }

    private func progressiveSample(frames: Int, start: Int64) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(pcm.floatChannelData?[0])
        for index in 0..<frames { data[index] = 0.1 }
        return try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm,
            presentationTime: CMTime(value: start, timescale: 16_000))
    }

    func testNativeSegmentOnlyResultSurvivesBothPreparedRuntimePaths() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let first = ASRSegmentTiming(text: "Первая фраза.", start: 0.2, end: 2.5)
        let second = ASRSegmentTiming(text: "Second phrase.", start: 3.1, end: 5.8)
        fixture.provider.timedResponses = [48_000: (first.text, []), 96_000: (first.text + " " + second.text, [])]
        fixture.provider.segmentResponses = [48_000: [first], 96_000: [first, second]]
        let attempt = UUID(), track = UUID()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let direct = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0.1, count: 96_000),
            offset: 10, trackID: track, attemptID: attempt, configuration: fixture.configuration)
        XCTAssertEqual(direct.segments.map(\.text), [first.text, second.text])
        XCTAssertEqual(direct.segments.map { $0.start.seconds }, [10.2, 13.1])
        XCTAssertEqual(direct.segments.map { $0.end.seconds }, [12.5, 15.8])
        let observed = PCMPreviewObservation()
        let firstObserved = expectation(description: "Native segment preview")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, _ in
                try await fixture.runtime.recognizePCM(window: window, offset: 20, trackID: track,
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        await MainActor.run {
                            observed.batches.append(batch)
                            if observed.batches.count == 1 { firstObserved.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("Segment-only results must use the same prepared native scope") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [firstObserved], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        try await consumer.finish()
        let final = try XCTUnwrap(observed.checkpoints.first)
        XCTAssertEqual(final.segments.map(\.text), [first.text, second.text])
        XCTAssertEqual(final.segments.map { $0.start.seconds }, [20.2, 23.1])
        XCTAssertEqual(final.segments.map { $0.end.seconds }, [22.5, 25.8])
        XCTAssertEqual(final.segments.first?.id, observed.batches.first?.segments.first?.id)
        XCTAssertTrue(final.isComplete)
        XCTAssertEqual(fixture.provider.timedSampleCounts, [96_000, 48_000, 96_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 2)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testRuntimeEmptyFirstThenSpeechPassesTypedPrivacyWithoutInventingATrack() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let text = "Сегодня обсуждаем подробную инструкцию и проверяем запись разговора."
        fixture.provider.timedResponses = [48_000: ("", []), 96_000: (text, []),
            144_000: (text + " Потом сохраним результат.", [])]
        let attempt = UUID(), track = UUID(), observed = PCMPreviewObservation()
        let privacy = MeetingTranscriptPrivacyContext(redactor: BenignPrivacyFixture())
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let first = expectation(description: "Empty native observation crossed privacy")
        let second = expectation(description: "First text remains unconfirmed")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: track,
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        let safe = try await privacy.previewSpeech(batch)
                        await MainActor.run {
                            observed.batches.append(batch); observed.safePreviews.append(safe)
                            if observed.batches.count == 1 { first.fulfill() }
                            if observed.batches.count == 2 { second.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("A genuine empty native observation cannot interrupt capture") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        await fulfillment(of: [second], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 96_000)))
        try await consumer.finish()
        XCTAssertTrue(observed.batches.first?.segments.isEmpty == true)
        XCTAssertTrue(observed.batches.allSatisfy { $0.sourceTrack == nil })
        XCTAssertTrue(observed.batches.allSatisfy { $0.speechObservationIdentity?.epochID.trackID == track })
        XCTAssertGreaterThanOrEqual(observed.safePreviews.count, 3)
        guard observed.safePreviews.count >= 3 else { return }
        XCTAssertNil(observed.safePreviews[0]); XCTAssertNil(observed.safePreviews[1])
        let finalPreview = try XCTUnwrap(observed.safePreviews.last.flatMap { $0 })
        XCTAssertTrue(finalPreview.text.contains("Сегодня обсуждаем"))
        XCTAssertEqual(observed.checkpoints.count, 1)
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testRuntimeEmptySealedWindowDoesNotInheritPendingPrivacyPreview() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        fixture.provider.timedResponses = [48_000: ("", []), 96_000: ("", [])]
        let attempt = UUID(), track = UUID(), observed = PCMPreviewObservation()
        let privacy = MeetingTranscriptPrivacyContext(redactor: BenignPrivacyFixture())
        let prior = MeetingTranscriptSegment(id: UUID(), start: .init(value: 0, timescale: 1),
            end: .init(value: 3, timescale: 1), sourceTrackID: track, speakerID: nil,
            text: "Earlier approved speech remains in the bounded context.", revision: 0,
            status: .final, overlap: .none, completeness: .complete)
        let held = try await privacy.redact(.init(segments: [prior]))
        XCTAssertNotNil(held.livePreview); XCTAssertTrue(held.segments.isEmpty)
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let first = expectation(description: "Empty next window")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, _ in
                try await fixture.runtime.recognizePCM(window: window, offset: 6, trackID: track,
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        let safe = try await privacy.previewSpeech(batch)
                        await MainActor.run {
                            observed.batches.append(batch); observed.safePreviews.append(safe)
                            if observed.batches.count == 1 { first.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("An empty sealed next window must safely drain") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        try await consumer.finish()
        XCTAssertTrue(observed.batches.allSatisfy { $0.segments.isEmpty && $0.sourceTrack == nil })
        XCTAssertTrue(observed.batches.last?.speechObservationIsFinal == true)
        XCTAssertTrue(observed.safePreviews.allSatisfy { $0 == nil })
        let tail = try await privacy.finish()
        XCTAssertEqual(tail?.segments.map(\.id), [prior.id])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testProgressiveNativeEmptySealPreservesAcceptedPrefixWithIncompleteCoverage() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        fixture.provider.timedResponses = [48_000: ("Accepted prefix", [
            .init(text: "Accepted", start: 0.2, end: 1), .init(text: "prefix", start: 1.1, end: 2.9)
        ]), 96_000: ("", [])]
        let attempt = UUID(); let track = UUID(); let observed = PCMPreviewObservation()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let first = expectation(description: "Accepted prefix observed")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, _ in
                try await fixture.runtime.recognizePCM(window: window, offset: 8, trackID: track,
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        await MainActor.run {
                            observed.batches.append(batch)
                            if observed.batches.count == 1 { first.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("Empty provider hypothesis is not a capture failure") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        try await consumer.finish()
        let final = try XCTUnwrap(observed.checkpoints.first)
        XCTAssertEqual(observed.checkpoints.count, 1)
        XCTAssertTrue(observed.batches.allSatisfy { $0.segments.map(\.text) == ["Accepted", "prefix"] },
                      "An empty longer observation cannot erase the accepted preview")
        XCTAssertEqual(observed.batches.last?.speechObservationIsFinal, true)
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000, 96_000])
        XCTAssertEqual(final.segments.map(\.text), ["Accepted", "prefix"])
        XCTAssertEqual(final.segments.map(\.id), observed.batches.first?.segments.map(\.id))
        XCTAssertEqual(final.segments.map { $0.start.seconds }, [8.2, 9.1])
        XCTAssertEqual(final.segments.map { $0.end.seconds }, [9, 10.9], "Original word timing cannot be extended to the physical end at 14 seconds")
        XCTAssertFalse(final.isComplete)
        XCTAssertTrue(final.segments.allSatisfy { $0.completeness == .incompleteTrack && $0.status == .final })
        XCTAssertEqual(fixture.provider.prepareCalls, 1)
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testProgressiveNativeEmptyIntermediateKeepsPrefixUntilAcceptedFinalWins() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        fixture.provider.timedResponses = [48_000: ("First prefix", []), 96_000: ("", []), 144_000: ("Final accepted speech", [])]
        let attempt = UUID(); let observed = PCMPreviewObservation()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let first = expectation(description: "First nonempty observation")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: UUID(),
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        await MainActor.run {
                            observed.batches.append(batch)
                            if observed.batches.count == 1 { first.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("An empty intermediate observation cannot fail the window") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        for _ in 0..<100 where fixture.provider.timedSampleCounts.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000, 96_000])
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 96_000)))
        try await consumer.finish()
        let final = try XCTUnwrap(observed.checkpoints.first)
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000, 96_000, 144_000])
        XCTAssertEqual(observed.batches.first?.segments.map(\.text), ["First prefix"])
        XCTAssertEqual(observed.batches.last?.segments.map(\.text), ["Final accepted speech"])
        XCTAssertTrue(observed.batches.allSatisfy { !$0.segments.isEmpty })
        XCTAssertEqual(observed.batches.last?.speechObservationIsFinal, true)
        XCTAssertEqual(final.segments.map(\.text), ["Final accepted speech"])
        XCTAssertEqual(final.segments.first?.end.seconds, 9)
        XCTAssertTrue(final.isComplete)
        XCTAssertTrue(final.segments.allSatisfy { $0.completeness == .complete })
        XCTAssertEqual(fixture.provider.prepareCalls, 1)
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
    }

    func testProgressiveNativeAllEmptySpeechDrainsScopeAndAdmitsNextWindow() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        fixture.provider.timedResponses = [48_000: (" \n", []), 96_000: ("", [])]
        let attempt = UUID(); let track = UUID(); let observed = PCMPreviewObservation()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let first = expectation(description: "Empty observation")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: track,
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        await MainActor.run {
                            observed.batches.append(batch)
                            if observed.batches.count == 1 { first.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("Empty speech must preserve the provider's empty result semantics") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        try await consumer.finish()
        let final = try XCTUnwrap(observed.checkpoints.first)
        XCTAssertTrue(final.segments.isEmpty)
        XCTAssertTrue(final.speakers.isEmpty)
        XCTAssertTrue(final.isComplete, "No accepted speech establishes a missing speech tail")
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000, 96_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
        let next = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0.1, count: 16_000),
            offset: 6, trackID: track, attemptID: attempt, configuration: fixture.configuration)
        XCTAssertEqual(next.segments.map(\.text), ["Scoped", "provider"])
        XCTAssertEqual(fixture.provider.prepareCalls, 2)
        XCTAssertEqual(fixture.provider.releaseCalls, 2)
    }

    func testEmptyAttributionSkipsSpeakerModelsWithoutPublishingPriorEvidence() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        defer { fixture.service.releaseExclusiveActivity(fixture.lease) }
        let track = UUID(); let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "synthetic-prior")
        let profile = MeetingSpeakerVoiceProfile(token: token, embeddings: [[1, 0], [1, 0]])
        let speaker = MeetingSessionSpeaker(id: UUID(), displayName: "Synthetic participant",
            diarizationClusterID: "synthetic-prior", trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        let output = MeetingParakeetEpochOutput(epochID: epoch, text: " \n", words: [],
            sampleRate: 16_000, sampleCount: 16_000, spanSamples: [])
        let configuration = MeetingFinalProcessingConfiguration(asrModel: fixture.configuration.asrModel,
            languageCode: fixture.configuration.languageCode, speakerLabelsEnabled: true)
        // With no prepared attribution artifact, entering the speaker stage would
        // throw staleGrant. Empty text must return before opening NN or voice.
        let result = try await fixture.runtime.attributePCMSpeech(samples: [Float](repeating: 0, count: 16_000),
            output: output, epoch: epoch, offset: 0, attemptID: UUID(), configuration: configuration,
            priorProfiles: [profile], priorSpeakers: [speaker])
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertTrue(result.speakers.isEmpty, "An empty window cannot create or rewrite speakers")
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(fixture.provider.prepareCalls, 0)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testProgressiveProviderFailureCannotBeHiddenByAcceptedPrefix() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let failure = CocoaError(.coderReadCorrupt)
        fixture.provider.timedResponses = [48_000: ("Accepted prefix", [])]
        fixture.provider.timedErrors = [96_000: failure]
        let attempt = UUID(); let first = expectation(description: "Accepted prefix before failure")
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: UUID(),
                    attemptID: attempt, configuration: fixture.configuration, preview: { _ in first.fulfill() })
            }, checkpoint: { _ in XCTFail("A provider exception cannot become a partial successful checkpoint") }, failure: { _ in })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        do { try await consumer.finish(); XCTFail("An ASR failure cannot be replaced with the old prefix") }
        catch { XCTAssertEqual(error as? CocoaError, failure) }
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000, 96_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
    }

    func testProgressiveCancellationJoinsObserverBeforeReleasingOwnedPrefix() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let attempt = UUID(); let track = UUID(); let latch = PCMObserverLatch(); let observed = PCMPreviewObservation()
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let entered = expectation(description: "Cancellation-deaf observer entered")
        let published = expectation(description: "Cancellation operation published")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, offset in
                let operation = Task {
                    try await fixture.runtime.recognizePCM(window: window, offset: offset, trackID: track,
                        attemptID: attempt, configuration: fixture.configuration,
                        preview: { _ in entered.fulfill(); await latch.wait() })
                }
                await MainActor.run { observed.operation = operation; published.fulfill() }
                return try await operation.value
            }, checkpoint: { _ in XCTFail("Cancelled prefix cannot publish a checkpoint") }, failure: { _ in })
        addTeardownBlock {
            await latch.open()
            await MainActor.run { observed.operation?.cancel() }
            try? await consumer.finish()
        }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [entered, published], timeout: 3)
        try XCTUnwrap(observed.operation).cancel()
        XCTAssertTrue(fixture.owner.isClaimed)
        XCTAssertEqual(fixture.provider.releaseCalls, 0, "Cancellation cannot release weights while a callback still owns the prefix")
        do {
            _ = try await fixture.runtime.recognizePCM(samples: [0.1], offset: 1, trackID: track,
                attemptID: attempt, configuration: fixture.configuration)
            XCTFail("The cancelled callback must retain the runtime until it joins")
        } catch { XCTAssertEqual(error as? MeetingParakeetNemotronRuntimeError, .concurrentPCMWindow) }
        await latch.open()
        do { try await consumer.finish(); XCTFail("Joined cancellation cannot publish") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.provider.timedSampleCounts, [48_000])
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
        XCTAssertFalse(fixture.owner.isClaimed)
        _ = try await fixture.runtime.recognizePCM(samples: [Float](repeating: 0.1, count: 16_000), offset: 1,
            trackID: track, attemptID: attempt, configuration: fixture.configuration)
        XCTAssertEqual(fixture.provider.prepareCalls, 2)
    }

    private func makeNativePCMPreviewFixture() throws -> (service: ASRService, lease: ASRActivityLease,
        provider: NativeScopeProvider, owner: MeetingASRPreparationOwner,
        runtime: MeetingParakeetNemotronRuntime, configuration: MeetingFinalProcessingConfiguration) {
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        let provider = NativeScopeProvider()
        let owner = MeetingASRPreparationOwner(isActiveLease: { $0 == lease }, isUserDownloadInProgress: { false },
            retireDictationResources: { _ in }, makeProvider: { _ in provider },
            prepareProvider: { prepared, _, progress in try await prepared.prepare(progressHandler: progress) },
            drainExecutor: { _ in })
        service.meetingASRPreparationOwnerForTesting = owner
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou",
            asrArtifactFingerprint: "synthetic-preview-artifact", languageCode: "ru", speakerLabelsEnabled: false)
        return (service, lease, provider, owner,
            MeetingParakeetNemotronRuntime(asrServiceProvider: { service }, modelLocator: EmptySpeechModelLocator()), configuration)
    }

}

private nonisolated struct EmptySpeechModelLocator: MeetingNemotronModelLocating {
    func locate() throws -> MeetingNemotronModelArtifact {
        throw MeetingNemotronModelReadinessError.modelNotInstalled(path: "synthetic-empty-speech")
    }
    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact {
        throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "synthetic-empty-speech")
    }
}

private actor PCMObserverLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}
