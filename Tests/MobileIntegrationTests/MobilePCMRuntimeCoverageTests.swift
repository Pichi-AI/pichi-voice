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
        var unfilteredPreviews: [MeetingLivePartial?] = []
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

    func testProgressivePreviewCoverageDistinguishesNativeTimingFromCoarseWindows() async throws {
        for timing in ["coarse", "words", "segments", "invalid-segments"] {
            let fixture = try self.makeNativePCMPreviewFixture()
            addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
            let text = "Сегодня обсуждаем подробную инструкцию и проверяем запись разговора."
            let words: [ASRWordTiming] = timing == "words"
                ? [.init(text: text, start: 0.2, end: 1.7)] : []
            fixture.provider.timedResponses = [48_000: (text, words), 96_000: (text, words), 144_000: (text, words)]
            if timing == "segments" || timing == "invalid-segments" {
                let end = timing == "segments" ? 2.7 : 30
                for count in [48_000, 96_000, 144_000] {
                    fixture.provider.segmentResponses[count] = [.init(text: text, start: 0.3, end: end)]
                }
            }
            let attempt = UUID(), track = UUID(), observed = PCMPreviewObservation()
            let privacy = MeetingTranscriptPrivacyContext(redactor: BenignPrivacyFixture())
            try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
            let first = expectation(description: "First \(timing) observation")
            let second = expectation(description: "Repeated \(timing) observation")
            let previewID = UUID()
            let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
                recognize: { window, _ in
                    try await fixture.runtime.recognizePCM(window: window, offset: 10, trackID: track,
                        attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                            let direct = batch.speechPreview(id: previewID)
                            let safe = try await privacy.previewSpeech(batch)
                            await MainActor.run {
                                observed.batches.append(batch)
                                observed.unfilteredPreviews.append(direct)
                                observed.safePreviews.append(safe)
                                if observed.batches.count == 1 { first.fulfill() }
                                if observed.batches.count == 2 { second.fulfill() }
                            }
                        })
                }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
                failure: { _ in XCTFail("Coverage metadata must not interrupt capture") })
            addTeardownBlock { try? await consumer.finish() }
            XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
            await fulfillment(of: [first], timeout: 3)
            XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
            await fulfillment(of: [second], timeout: 3)
            XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 96_000)))
            try await consumer.finish()
            XCTAssertGreaterThanOrEqual(observed.batches.count, 3)
            guard observed.batches.count >= 3 else { continue }
            let native = timing == "words" || timing == "segments"
            XCTAssertTrue(observed.batches.allSatisfy { $0.speechObservationHasNativeTiming == native })
            let firstDirect = try XCTUnwrap(observed.unfilteredPreviews[0])
            let secondDirect = try XCTUnwrap(observed.unfilteredPreviews[1])
            XCTAssertEqual(firstDirect.text, text)
            XCTAssertEqual(secondDirect.text, text, "Repeating the same words cannot imply new word coverage")
            XCTAssertNil(observed.safePreviews[0], "The first unconfirmed hypothesis must still wait for agreement")
            let secondSafe = try XCTUnwrap(observed.safePreviews[1])
            if native {
                let nativeEnd = timing == "words" ? 11.7 : 12.7
                XCTAssertEqual(firstDirect.end ?? -1, nativeEnd, accuracy: 0.001)
                XCTAssertEqual(secondDirect.end ?? -1, nativeEnd, accuracy: 0.001)
                XCTAssertEqual(secondSafe.end ?? -1, nativeEnd, accuracy: 0.001)
            } else {
                XCTAssertNil(firstDirect.end)
                XCTAssertNil(secondDirect.end)
                XCTAssertNil(secondSafe.end, "Whole sampled windows cannot retire waves during an unchanged hypothesis")
                XCTAssertEqual(observed.unfilteredPreviews.last.flatMap { $0 }?.end, 19)
                XCTAssertEqual(observed.safePreviews.last.flatMap { $0 }?.end, 19)
            }
            XCTAssertTrue(observed.batches.last?.speechObservationIsFinal == true)
            XCTAssertEqual(fixture.provider.releaseCalls, 1)
            XCTAssertFalse(fixture.owner.isClaimed)
        }
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

    func testSealedCoarsePreviewCoversAcceptedPrefixWithoutRejectedPhysicalTail() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        addTeardownBlock { await MainActor.run { fixture.service.releaseExclusiveActivity(fixture.lease) } }
        let text = "Сегодня обсуждаем подробную инструкцию и проверяем запись разговора."
        fixture.provider.timedResponses = [48_000: (text, []), 96_000: ("", [])]
        let attempt = UUID(), track = UUID(), previewID = UUID(), observed = PCMPreviewObservation()
        let privacy = MeetingTranscriptPrivacyContext(redactor: BenignPrivacyFixture())
        try await fixture.runtime.preparePCMResources(attemptID: attempt, configuration: fixture.configuration)
        let first = expectation(description: "Coarse prefix accepted before a rejected tail")
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, _ in
                try await fixture.runtime.recognizePCM(window: window, offset: 10, trackID: track,
                    attemptID: attempt, configuration: fixture.configuration, preview: { batch in
                        let direct = batch.speechPreview(id: previewID)
                        let safe = try await privacy.previewSpeech(batch)
                        await MainActor.run {
                            observed.batches.append(batch)
                            observed.unfilteredPreviews.append(direct)
                            observed.safePreviews.append(safe)
                            if observed.batches.count == 1 { first.fulfill() }
                        }
                    })
            }, checkpoint: { batch in await MainActor.run { observed.checkpoints.append(batch) } },
            failure: { _ in XCTFail("A rejected longer observation cannot erase accepted prefix coverage") })
        addTeardownBlock { try? await consumer.finish() }
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 0)))
        await fulfillment(of: [first], timeout: 3)
        XCTAssertTrue(consumer.enqueue(try self.progressiveSample(frames: 48_000, start: 48_000)))
        try await consumer.finish()
        XCTAssertNil(observed.unfilteredPreviews.first.flatMap { $0 }?.end)
        XCTAssertEqual(observed.unfilteredPreviews.last.flatMap { $0 }?.end, 13)
        XCTAssertEqual(observed.safePreviews.last.flatMap { $0 }?.end, 13)
        XCTAssertTrue(observed.batches.last?.speechObservationIsFinal == true)
        XCTAssertTrue(observed.batches.allSatisfy { $0.speechObservationHasNativeTiming == false })
        let final = try XCTUnwrap(observed.checkpoints.first)
        XCTAssertEqual(final.segments.first?.end.seconds, 13)
        XCTAssertFalse(final.isComplete, "The rejected physical tail at 16 seconds cannot become accepted text coverage")
        XCTAssertEqual(fixture.provider.releaseCalls, 1)
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

    func testLiveSpeakerEnabledSpeechNeverOpensDiarizerOrVoiceEncoder() async throws {
        let fixture = try self.makeNativePCMPreviewFixture()
        defer { fixture.service.releaseExclusiveActivity(fixture.lease) }
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let output = MeetingParakeetEpochOutput(epochID: epoch, text: "Защищённый <PERSON> текст.",
            words: [.init(text: "Защищённый", start: 0.1, end: 0.4),
                    .init(text: "<PERSON>", start: 0.4, end: 0.7),
                    .init(text: "текст.", start: 0.7, end: 0.9)],
            sampleRate: 16_000, sampleCount: 16_000, spanSamples: [])
        let configuration = MeetingFinalProcessingConfiguration(asrModel: fixture.configuration.asrModel,
            languageCode: "ru", speakerLabelsEnabled: true)
        // No speaker artifact is pinned and no weights exist in this fixture. The former
        // live speaker phase threw staleGrant here; every live result must now be text only.
        let result = try await fixture.runtime.attributePCMSpeech(samples: [Float](repeating: 0.1, count: 16_000),
            output: output, epoch: epoch, offset: 0, attemptID: UUID(), configuration: configuration,
            priorProfiles: [], priorSpeakers: [])
        XCTAssertEqual(result.segments.map(\.text), ["Защищённый", "<PERSON>", "текст."])
        XCTAssertTrue(result.speakers.isEmpty)
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerID == nil && $0.attributionState == .unassigned })
        XCTAssertEqual(fixture.provider.prepareCalls, 0)
    }

    func testPostStopGlobalAttributionPreservesProtectedTextIDsAndOriginalProvenance() throws {
        let track = UUID(), attempt = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let first = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-3")
        let second = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        var original: [MeetingTranscriptSegment] = []
        for (index, start) in [0.0, 10.0, 28_780.0, 28_790.0].enumerated() {
            original.append(.init(id: UUID(), start: .init(value: Int64(start * 1_000), timescale: 1_000),
                end: .init(value: Int64((start + 6) * 1_000), timescale: 1_000), sourceTrackID: track,
                speakerID: nil, text: "Фраза \(index) <PERSON>", originalText: "Protected synthetic original",
                revision: 2, status: .final, overlap: .none, completeness: .incompleteTrack,
                isLikelyEcho: false, attributionState: .unassigned))
        }
        let input = MeetingPCMTranscriptBatch(segments: original, isComplete: false)
        let activity: [MeetingBackendSpeakerActivity] = [
            .init(token: first, start: 0, end: 6), .init(token: second, start: 10, end: 16),
            .init(token: first, start: 28_780, end: 28_786), .init(token: second, start: 28_790, end: 28_796)]
        let output = try MeetingPCMRecordingAttribution.assemble(transcript: input, activity: activity,
            epoch: epoch, attemptID: attempt, duration: 28_800, speakerNameFormat: "Speaker %lld")
        XCTAssertFalse(output.isComplete)
        XCTAssertEqual(output.speakers.count, 2)
        XCTAssertEqual(output.segments[0].speakerID, output.segments[2].speakerID)
        XCTAssertEqual(output.segments[1].speakerID, output.segments[3].speakerID)
        XCTAssertNotEqual(output.segments[0].speakerID, output.segments[1].speakerID)
        for (before, after) in zip(original, output.segments) {
            var expected = before
            expected.speakerID = after.speakerID
            expected.attributionState = .assigned
            expected.nativePrecision = .utterance
            expected.nativeUnitID = "post-stop:\(before.id)"
            expected.nativeSpeakerAssignment = .assigned(before.start.seconds == 0 || before.start.seconds == 28_780 ? first : second)
            expected.nativeTiming = .init(start: before.start.seconds, end: before.end.seconds)
            XCTAssertEqual(expected, after, "Only speaker attribution may change after privacy publication")
        }
        let overlapped = try MeetingPCMRecordingAttribution.assemble(transcript: input,
            activity: activity + [.init(token: second, start: 0, end: 6)], epoch: epoch,
            attemptID: attempt, duration: 28_800, speakerNameFormat: "Speaker %lld")
        XCTAssertNil(overlapped.segments[0].speakerID)
        XCTAssertEqual(overlapped.segments[0].attributionState, .overlappingSpeakers)
        XCTAssertEqual(overlapped.segments[0].text, original[0].text)
    }

    func testPostStopContinuityUsesIncomingSpeakerAndRetainsOriginalAnchorIDs() throws {
        let track = UUID(), attempt = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let a = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let b = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-1")
        let ranges: [(Double, Double)] = [(0, 6), (6, 6.3), (6.3, 12), (12, 12.3), (12.3, 18.3)]
        let original = ranges.enumerated().map { index, range in
            MeetingTranscriptSegment(id: UUID(),
                start: .init(value: Int64((range.0 * 1_000).rounded()), timescale: 1_000),
                end: .init(value: Int64((range.1 * 1_000).rounded()), timescale: 1_000),
                sourceTrackID: track, speakerID: nil, text: "protected-\(index)", originalText: "Synthetic <PERSON>",
                revision: 2, status: .final, overlap: .none, completeness: .complete, attributionState: .unassigned,
                nativePrecision: .word, nativeUnitID: "native-\(index)")
        }
        let result = try MeetingPCMRecordingAttribution.assemble(transcript: .init(segments: original),
            activity: [.init(token: a, start: 0, end: 6), .init(token: a, start: 6.3, end: 12),
                       .init(token: b, start: 12.3, end: 18.3)],
            epoch: epoch, attemptID: attempt, duration: 18.3, speakerNameFormat: "Speaker %lld")
        XCTAssertEqual(result.segments.map(\.id), original.map(\.id))
        XCTAssertEqual(result.segments.map(\.text), original.map(\.text))
        XCTAssertEqual(result.segments.map(\.originalText), original.map(\.originalText))
        XCTAssertEqual(result.segments.map(\.revision), original.map(\.revision))
        XCTAssertEqual(result.segments[1].speakerID, result.segments[0].speakerID)
        XCTAssertEqual(result.segments[3].speakerID, result.segments[4].speakerID)
        XCTAssertNotEqual(result.segments[3].speakerID, result.segments[2].speakerID)
        XCTAssertEqual(result.segments[1].speakerAttribution?.rule, .neighborAgreement)
        XCTAssertEqual(result.segments[3].speakerAttribution?.rule, .incomingSpeaker)
        XCTAssertEqual(result.segments[1].nativeUnitID, "native-1")
        XCTAssertEqual(result.segments[3].nativeSpeakerAssignment, .unassigned)
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerAttributionInference == nil })
        XCTAssertEqual(result.segments.map(\.nativePrecision), Array(repeating: .word, count: original.count))
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic continuity export",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1))
        session.transcriptSegments = result.segments
        session.speakers = result.speakers
        let data = try MeetingTranscriptExporter.json(for: session)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exported = try XCTUnwrap(document["segments"] as? [[String: Any]])
        let inference = try XCTUnwrap(exported[3]["speakerAttribution"] as? [String: Any])
        XCTAssertEqual(inference["rule"] as? String, "incomingSpeaker")
        XCTAssertEqual(inference["unitID"] as? String, "native-3")
        XCTAssertNil(exported[3]["speakerAttributionInference"])
    }

    func testPostStopUnsafePublicationCannotProvideContextOrReceiveGuesses() throws {
        let track = UUID(), epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0), attempt = UUID()
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let ranges: [(Double, Double)] = [(0, 6), (6, 6.2), (6.2, 12.2),
                                         (20, 26), (26, 26.2), (26.2, 32.2)]
        let activity: [MeetingBackendSpeakerActivity] = [
            .init(token: token, start: 0, end: 6), .init(token: token, start: 6.2, end: 12.2),
            .init(token: token, start: 20, end: 26), .init(token: token, start: 26.2, end: 32.2)]
        let base = ranges.enumerated().map { index, range in
            MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64((range.0 * 1_000).rounded()), timescale: 1_000),
                end: .init(value: Int64((range.1 * 1_000).rounded()), timescale: 1_000), sourceTrackID: track,
                speakerID: nil, text: "protected-\(index)", revision: 2, status: .final,
                overlap: .none, completeness: .complete, attributionState: .unassigned,
                nativePrecision: .word, nativeUnitID: "native-\(index)")
        }
        for unsafeIndex in [0, 1, 2] {
            for kind in 0..<4 {
                var original = base
                switch kind {
                case 0: original[unsafeIndex].completeness = .incompleteTrack
                case 1: original[unsafeIndex].isLikelyEcho = true
                case 2: original[unsafeIndex].status = .provisional
                default: original[unsafeIndex].attributionState = .timingUncertain
                }
                let output = try MeetingPCMRecordingAttribution.assemble(transcript: .init(segments: original),
                    activity: activity, epoch: epoch, attemptID: attempt, duration: 33, speakerNameFormat: "Speaker %lld")
                XCTAssertNil(output.segments[1].speakerID, "Unsafe targets and either unsafe anchor block the contextual chain")
                XCTAssertNotNil(output.segments[0].speakerID, "Actual safe acoustic support remains available")
                XCTAssertNotNil(output.segments[2].speakerID)
                XCTAssertEqual(output.segments[4].speakerID, output.segments[3].speakerID)
                XCTAssertEqual(output.segments[4].speakerAttribution?.rule, .neighborAgreement,
                               "An unrelated safe bout in the same epoch still resolves")
                XCTAssertEqual(output.segments[unsafeIndex].status, original[unsafeIndex].status)
                XCTAssertEqual(output.segments[unsafeIndex].completeness, original[unsafeIndex].completeness)
                XCTAssertEqual(output.segments[unsafeIndex].isEcho, original[unsafeIndex].isEcho)
                if kind == 3 { XCTAssertEqual(output.segments[unsafeIndex].attributionState, .timingUncertain) }
                XCTAssertEqual(output.segments.map(\.id), original.map(\.id))
                XCTAssertEqual(output.segments.map(\.text), original.map(\.text))
            }
        }
    }

    func testStoppedRecordingReplayUsesExactBoundedRangesAndRejectsCorruptAudio() async throws {
        let source = ReplayFixture(totalSampleCount: 32_137)
        var counts: [Int] = []
        try await source.replay { counts.append($0.count) }
        XCTAssertEqual(counts, [16_000, 16_000, 137])
        let ranges = await source.ranges
        XCTAssertEqual(ranges, [0..<16_000, 16_000..<32_000, 32_000..<32_137])
        let corrupt = ReplayFixture(totalSampleCount: 16_000, corrupt: true)
        do {
            try await corrupt.replay { _ in XCTFail("Corrupt decoded PCM must not reach native inference") }
            XCTFail("A short decoder read must fail explicitly")
        } catch { XCTAssertEqual(error as? MeetingParakeetNemotronRuntimeError, .invalidPCMWindow) }
    }

    func testStoppedRecordingReplayChecksCancellationBeforeConsumingDecodedAudio() async throws {
        let source = ReplayFixture(totalSampleCount: 48_000)
        let task = Task {
            try await source.replay { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("Cancellation must escape the joined replay") }
        catch { XCTAssertTrue(error is CancellationError) }
        let ranges = await source.ranges
        XCTAssertEqual(ranges, [0..<16_000], "Cancellation cannot decode the remainder or finalize a partial recording")
    }

    private actor ReplayFixture: MeetingPCMReplaySource {
        nonisolated let totalSampleCount: Int
        let corrupt: Bool
        var ranges: [Range<Int>] = []
        init(totalSampleCount: Int, corrupt: Bool = false) {
            self.totalSampleCount = totalSampleCount; self.corrupt = corrupt
        }
        func readSamples(in range: Range<Int>) async throws -> [Float] {
            ranges.append(range)
            return [Float](repeating: 0.1, count: max(0, range.count - (corrupt ? 1 : 0)))
        }
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
