import Foundation
@testable import PichiGigaAM
import XCTest

final class GigaAMWindowReuseTests: XCTestCase {
    private final class FirstCall: @unchecked Sendable {
        private let lock = NSLock()
        private var first = true
        func take() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            let value = self.first
            self.first = false
            return value
        }
    }
    private static func pcm(_ seconds: Int) -> [Float] {
        (0..<(seconds * 16_000)).map { Float($0 / 16_000) / 100 }
    }

    private static func infer(_ samples: [Float], features: Bool) throws -> GigaAMTranscript {
        let duration = Double(samples.count) / 16_000
        let words = stride(from: 0.08, to: duration, by: 0.5).map { start in
            GigaAMWordTiming(text: "да", start: start, end: min(duration, start + 0.08), confidence: 0.75)
        }
        var windows: [GigaAMEncoderWindow] = []
        if features {
            for start in stride(from: 0, to: duration, by: 10) {
                let end = min(duration, start + 10)
                let frames = Int(ceil((end - start) / 0.04))
                var values = [Float](repeating: 0, count: frames * GigaAMEncoderFeatures.dimension)
                for frame in 0..<frames { values[frame * GigaAMEncoderFeatures.dimension] = 1 }
                windows.append(try .init(offset: start, ownership: start..<end,
                    features: .init(values: values)))
            }
        }
        return .init(text: words.map(\.text).joined(separator: " "), confidence: 0.75,
            words: words, endOfUtteranceProbability: 0.8, processingDuration: 0, encoderWindows: windows)
    }

    private func runtime() throws -> GigaAMRuntime {
        try GigaAMRuntime(windowInferenceForTesting: { samples, features in
            try Self.infer(samples, features: features)
        })
    }

    private func assertEquivalent(_ a: GigaAMTranscript, _ b: GigaAMTranscript,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.text, b.text, file: file, line: line)
        XCTAssertEqual(a.words, b.words, file: file, line: line)
        XCTAssertEqual(a.confidence, b.confidence, file: file, line: line)
        XCTAssertEqual(a.endOfUtteranceProbability, b.endOfUtteranceProbability, file: file, line: line)
        XCTAssertEqual(a.encoderWindows.map(\.offset), b.encoderWindows.map(\.offset), file: file, line: line)
        XCTAssertEqual(a.encoderWindows.map(\.ownership), b.encoderWindows.map(\.ownership), file: file, line: line)
        XCTAssertEqual(a.encoderWindows.map(\.features), b.encoderWindows.map(\.features), file: file, line: line)
    }

    func testExactPreviewFinalRunsNoInferenceAndKeepsAllWordAndFeatureEvidence() async throws {
        let runtime = try self.runtime(), baselineRuntime = try self.runtime()
        let pcm = Self.pcm(65), session = GigaAMWindowReuseSession()
        _ = try await runtime.transcribe(pcm, captureEncoderFeatures: true, reusingWindowsFor: session)
        let final = try await runtime.transcribe(pcm, captureEncoderFeatures: true, reusingWindowsFor: session)
        let work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 0)
        XCTAssertEqual(work.reusedWindows, 4)
        let baseline = try await baselineRuntime.transcribe(pcm, captureEncoderFeatures: true)
        self.assertEquivalent(final, baseline)
        XCTAssertFalse(final.encoderWindows.isEmpty)
        XCTAssertTrue(final.words.allSatisfy { $0.sourceContext?.isValid == true })
    }

    func testGrowingTailRecomputesOnlyItsChangedWindowsIncludingOverlap() async throws {
        let runtime = try self.runtime(), baselineRuntime = try self.runtime(), session = GigaAMWindowReuseSession()
        _ = try await runtime.transcribe(Self.pcm(59), reusingWindowsFor: session)
        let final = try await runtime.transcribe(Self.pcm(62), reusingWindowsFor: session)
        let work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 2)
        XCTAssertEqual(work.reusedWindows, 2)
        XCTAssertEqual(work.inferredSamples, (22 + 3) * 16_000)
        let baseline = try await baselineRuntime.transcribe(Self.pcm(62))
        self.assertEquivalent(final, baseline)
        XCTAssertTrue(final.words.contains { $0.start > 61 })
    }

    func testShortDictationAndExactTwentySecondBoundaryKeepTheLastWord() async throws {
        for seconds in [1, 20, 21, 40, 41] {
            let runtime = try self.runtime(), baselineRuntime = try self.runtime(), session = GigaAMWindowReuseSession()
            let pcm = Self.pcm(seconds)
            _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
            let final = try await runtime.transcribe(pcm, reusingWindowsFor: session)
            let baseline = try await baselineRuntime.transcribe(pcm)
            self.assertEquivalent(final, baseline)
            let work = await runtime.lastTranscriptionWork
            XCTAssertEqual(work.inferredWindows, 0)
            XCTAssertLessThanOrEqual(try XCTUnwrap(final.words.last).end, Double(seconds))
        }
    }

    func testSameLengthMutationAndRetractionCannotReturnStaleWindows() async throws {
        let runtime = try self.runtime(), baselineRuntime = try self.runtime(), session = GigaAMWindowReuseSession()
        var pcm = Self.pcm(65)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        pcm[20 * 16_000] = -0.5
        let changed = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        let changedWork = await runtime.lastTranscriptionWork
        XCTAssertEqual(changedWork.inferredWindows, 2, "Both sides of the changed overlap must be invalidated")
        self.assertEquivalent(changed, try await baselineRuntime.transcribe(pcm))
        let retracted = Array(pcm.prefix(19 * 16_000))
        let shorter = try await runtime.transcribe(retracted, reusingWindowsFor: session)
        self.assertEquivalent(shorter, try await baselineRuntime.transcribe(retracted))
        let shorterWork = await runtime.lastTranscriptionWork
        XCTAssertEqual(shorterWork.inferredWindows, 1)
    }

    func testNewAdmissionNoSessionBeginAttemptAndMatchingDiscardInvalidateReuse() async throws {
        let runtime = try self.runtime(), first = GigaAMWindowReuseSession(), second = GigaAMWindowReuseSession(), pcm = Self.pcm(21)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: first)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: second)
        var work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 2)
        await runtime.discardWindowReuse(for: first.id)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: second)
        work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 0)
        try await runtime.beginAttempt()
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: second)
        work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 2)
        await runtime.discardWindowReuse(for: second.id)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: second)
        work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 2)
        _ = try await runtime.transcribe(pcm)
        _ = try await runtime.transcribe(pcm)
        work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 2)
    }

    func testFeatureUpgradeRecomputesAndDowngradeReusesWithoutPublishingFeatures() async throws {
        let runtime = try self.runtime(), session = GigaAMWindowReuseSession(), pcm = Self.pcm(21)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        let upgraded = try await runtime.transcribe(pcm, captureEncoderFeatures: true, reusingWindowsFor: session)
        var work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 2)
        XCTAssertFalse(upgraded.encoderWindows.isEmpty)
        let downgraded = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 0)
        XCTAssertTrue(downgraded.encoderWindows.isEmpty)
        XCTAssertEqual(downgraded.words, upgraded.words)
    }

    func testFailureAndCancellationClearPreviouslyRetainedWindows() async throws {
        let runtime = try self.runtime(), session = GigaAMWindowReuseSession(), pcm = Self.pcm(41)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        var invalid = pcm
        invalid[0] = .nan
        do {
            _ = try await runtime.transcribe(invalid, reusingWindowsFor: session)
            XCTFail("Invalid audio must fail")
        } catch {}
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        var work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 3)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.transcribe(pcm, reusingWindowsFor: session)
        }
        do { _ = try await task.value; XCTFail("Cancelled inference must not publish cached text") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 3)
    }

    func testCacheBudgetNeverDiscardsOutputAndRetainsNoPCM() throws {
        var cache = GigaAMWindowReuse(maximumBytes: 100, maximumWindows: 1)
        let session = GigaAMWindowReuseSession(), pcm = Self.pcm(1), digest = GigaAMWindowReuse.digest(pcm)
        cache.prepare(session: session, sampleCount: pcm.count)
        let output = try Self.infer(pcm, features: true)
        cache.store(output, coreStart: 0, sampleRange: 0..<pcm.count, digest: digest, capturedFeatures: true)
        XCTAssertTrue(cache.entries.isEmpty)
        XCTAssertEqual(cache.retainedBytes, 0)
        XCTAssertFalse(output.words.isEmpty, "Declining a cache entry must not alter the transcript being returned")
        cache.prepare(session: GigaAMWindowReuseSession(), sampleCount: pcm.count)
        XCTAssertNotEqual(cache.sessionID, session.id)
    }

    func testClosedSessionCannotBeRecreatedByLateInference() async throws {
        let runtime = try self.runtime(), session = GigaAMWindowReuseSession(), pcm = Self.pcm(41)
        _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
        session.invalidate()
        await runtime.discardWindowReuse(for: session.id)
        for _ in 0..<2 {
            _ = try await runtime.transcribe(pcm, reusingWindowsFor: session)
            let work = await runtime.lastTranscriptionWork
            XCTAssertEqual(work.inferredWindows, 3, "Late work must not retain another cache under a closed handle")
            XCTAssertEqual(work.reusedWindows, 0)
        }
    }

    func testMissingFeatureEvidenceIsRetriedInsteadOfCachedAsComplete() async throws {
        let first = FirstCall()
        let runtime = try GigaAMRuntime(windowInferenceForTesting: { samples, features in
            try Self.infer(samples, features: features && !first.take())
        })
        let session = GigaAMWindowReuseSession(), pcm = Self.pcm(1)
        let missing = try await runtime.transcribe(pcm, captureEncoderFeatures: true, reusingWindowsFor: session)
        XCTAssertTrue(missing.encoderWindows.isEmpty)
        let recovered = try await runtime.transcribe(pcm, captureEncoderFeatures: true, reusingWindowsFor: session)
        let work = await runtime.lastTranscriptionWork
        XCTAssertEqual(work.inferredWindows, 1)
        XCTAssertFalse(recovered.encoderWindows.isEmpty)
        XCTAssertEqual(recovered.words, missing.words)
        _ = try await runtime.transcribe(pcm, captureEncoderFeatures: true, reusingWindowsFor: session)
        let reusedWork = await runtime.lastTranscriptionWork
        XCTAssertEqual(reusedWork.inferredWindows, 0)
    }
}
