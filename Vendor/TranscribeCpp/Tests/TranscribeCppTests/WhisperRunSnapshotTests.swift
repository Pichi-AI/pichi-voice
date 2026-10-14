import CTranscribe
import Foundation
import XCTest

@testable import TranscribeCpp

final class WhisperRunSnapshotTests: XCTestCase {
    private var options: RunOptions {
        RunOptions(task: .transcribe, timestamps: .segment,
                   family: .whisper(.init(temperature: 0, temperatureInc: 0, seed: 1)))
    }

    private func fixture() throws -> (Model, [Float]) {
        let (path, pcm) = try Fixtures.modelAndAudio()
        let model = try Model(path: path, options: .init(backend: .cpu))
        guard model.arch == "whisper" else { throw XCTSkip("snapshot requires Whisper fixture") }
        return (model, Array(pcm.prefix(3 * 16000)))
    }

    func testTraceCopiesAllNativeScalarsWithoutNormalizing() {
        var raw = transcribe_whisper_chunk_trace()
        transcribe_whisper_chunk_trace_init(&raw)
        XCTAssertGreaterThan(raw.struct_size, 0)
        raw.t0_ms = 123
        raw.t1_ms = 456
        raw.temperature_used = 0.4
        raw.avg_logprob = -1.7
        raw.compression_ratio = 2.8
        raw.no_speech_prob = 0.75
        raw.n_fallbacks = 2
        raw.no_speech_triggered = true
        let trace = WhisperChunkTrace(raw)
        raw.t0_ms = 999
        XCTAssertEqual(trace.t0Ms, 123)
        XCTAssertEqual(trace.t1Ms, 456)
        XCTAssertEqual(trace.temperature, 0.4)
        XCTAssertEqual(trace.avgLogprob, -1.7)
        XCTAssertEqual(trace.compressionRatio, 2.8)
        XCTAssertEqual(trace.noSpeechProbability, 0.75)
        XCTAssertEqual(trace.fallbacks, 2)
        XCTAssertTrue(trace.noSpeechTriggered)
    }

    func testTraceCountBoundsRejectMalformedCounts() throws {
        XCTAssertEqual(try validatedWhisperChunkCount(0), 0)
        XCTAssertEqual(try validatedWhisperChunkCount(4096), 4096)
        XCTAssertThrowsError(try validatedWhisperChunkCount(-1))
        XCTAssertThrowsError(try validatedWhisperChunkCount(4097))
        XCTAssertThrowsError(try validatedWhisperChunkCount(Int32.max))
    }

    func testSnapshotCopiesActualTraceAndSurvivesNextRun() throws {
        let (model, pcm) = try fixture()
        let session = try model.session(.init(nThreads: 4))
        let snapshot = try session.runWhisper(pcm, options: options)
        XCTAssertEqual(snapshot.chunks.count, Int(transcribe_get_whisper_chunk_count(session.ptr)))
        XCTAssertFalse(snapshot.chunks.isEmpty)
        var native = transcribe_whisper_chunk_trace()
        transcribe_whisper_chunk_trace_init(&native)
        XCTAssertEqual(transcribe_get_whisper_chunk_trace(session.ptr, 0, &native), TRANSCRIBE_OK)
        XCTAssertEqual(snapshot.chunks[0], WhisperChunkTrace(native))
        let expected = snapshot
        _ = try session.runWhisper(Array(pcm.prefix(16000)), options: options)
        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(snapshot.chunks[0], WhisperChunkTrace(native))
        XCTAssertNil(session.cancelToken)
    }

    func testFailedRunDoesNotReturnPriorSuccessfulQuality() throws {
        let (model, pcm) = try fixture()
        let session = try model.session(.init(nThreads: 4))
        _ = try session.runWhisper(pcm, options: options)
        XCTAssertThrowsError(try session.runWhisper([], options: options)) { error in
            guard case TranscribeError.invalidArgument = error else {
                return XCTFail("expected native invalid input, got \(error)")
            }
        }
    }

    func testOrdinaryRunAndBatchKeepTheirExistingResults() throws {
        let (model, pcm) = try fixture()
        let session = try model.session(.init(nThreads: 4))
        let ordinary = try session.run(pcm, options: options)
        let snapshot = try session.runWhisper(pcm, options: options)
        XCTAssertEqual(ordinary.text, snapshot.transcript.text)
        XCTAssertEqual(ordinary.segments, snapshot.transcript.segments)
        let batch = try session.runBatch([pcm, []], options: options)
        XCTAssertEqual(batch.count, 2)
        XCTAssertEqual(try batch[0].get().text, ordinary.text)
        guard case .failure(let error) = batch[1],
              case TranscribeError.invalidArgument = error else {
            return XCTFail("batch must preserve the invalid-input slot")
        }
    }

    func testRunWhisperRefusesAnExistingStreamLease() throws {
        let (model, pcm) = try fixture()
        let session = try model.session()
        // Whisper has no native stream in this artifact. Exercise the same
        // model-level lease that a supported Stream owns without native calls.
        model.runLock.lock()
        model.streamActive = true
        model.runLock.unlock()
        defer {
            model.runLock.lock()
            model.streamActive = false
            model.runLock.unlock()
        }
        XCTAssertThrowsError(try session.runWhisper(pcm, options: options)) { error in
            guard case TranscribeError.busy = error else {
                return XCTFail("expected busy compute lease, got \(error)")
            }
        }
    }

    func testAsyncMatchesSyncAndRestoresItsToken() async throws {
        let (model, pcm) = try fixture()
        let session = try model.session(.init(nThreads: 4))
        let synchronous = try { () throws -> WhisperRunSnapshot in
            try session.runWhisper(pcm, options: options)
        }()
        let asynchronous = try await session.runWhisper(pcm, options: options)
        XCTAssertEqual(synchronous.transcript.text, asynchronous.transcript.text)
        XCTAssertEqual(synchronous.chunks, asynchronous.chunks)
        XCTAssertNil(session.cancelToken)
    }

    func testAsyncPreservesCallerTokenAndItsPreCancelledError() async throws {
        let (model, pcm) = try fixture()
        let session = try model.session(.init(nThreads: 4))
        let token = CancellationToken()
        session.setCancellationToken(token)
        _ = try await session.runWhisper(pcm, options: options)
        XCTAssertTrue(session.cancelToken === token)
        token.cancel()
        do {
            _ = try await session.runWhisper(pcm, options: options)
            XCTFail("a pre-cancelled native run must not return a successful snapshot")
        } catch let error as TranscribeError {
            guard case .aborted(_, let partial) = error else {
                return XCTFail("expected aborted, got \(error)")
            }
            XCTAssertNotNil(partial)
        }
        XCTAssertTrue(session.cancelToken === token)
        XCTAssertTrue(session.wasAborted)
    }

    func testTaskCancellationJoinsNativeRunBeforeRestoringToken() async throws {
        let (model, pcm) = try fixture()
        let session = try model.session(.init(nThreads: 4))
        let task = Task { try await session.runWhisper(pcm, options: options) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled run must abort instead of returning quality")
        } catch let error as TranscribeError {
            guard case .aborted(_, let partial) = error else {
                return XCTFail("expected aborted, got \(error)")
            }
            XCTAssertNotNil(partial)
        }
        XCTAssertNil(session.cancelToken)
        XCTAssertTrue(session.wasAborted)
        // A new run on the same session proves the joined run released the
        // compute lock and removed only the bridge-owned cancellation token.
        _ = try await session.runWhisper(pcm, options: options)
    }

    func testConcurrentSessionsKeepTheirOwnAtomicSnapshots() async throws {
        let (model, pcm) = try fixture()
        let first = try model.session(.init(nThreads: 4))
        let second = try model.session(.init(nThreads: 4))
        let short = [Float](repeating: 0, count: 16000)
        let expectedLong = try { () throws -> WhisperRunSnapshot in
            try first.runWhisper(pcm, options: options)
        }()
        let expectedShort = try { () throws -> WhisperRunSnapshot in
            try second.runWhisper(short, options: options)
        }()
        XCTAssertNotEqual(expectedLong.chunks, expectedShort.chunks)
        async let a = first.runWhisper(pcm, options: options)
        async let b = second.runWhisper(short, options: options)
        let (longSnapshot, shortSnapshot) = try await (a, b)
        XCTAssertFalse(longSnapshot.chunks.isEmpty)
        XCTAssertFalse(shortSnapshot.chunks.isEmpty)
        // The native runtime reports padded 30-second encoder windows even for
        // shorter PCM. Compare against each session's real sequential result,
        // rather than inventing word times from input duration.
        XCTAssertEqual(longSnapshot.transcript.text, expectedLong.transcript.text)
        XCTAssertEqual(shortSnapshot.transcript.text, expectedShort.transcript.text)
        XCTAssertEqual(longSnapshot.chunks, expectedLong.chunks)
        XCTAssertEqual(shortSnapshot.chunks, expectedShort.chunks)
        XCTAssertNil(first.cancelToken)
        XCTAssertNil(second.cancelToken)
    }
}
