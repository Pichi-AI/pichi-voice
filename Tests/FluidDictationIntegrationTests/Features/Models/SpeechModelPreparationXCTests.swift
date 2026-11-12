@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Cancelling a retry of a downloaded model must keep it, because getting it back costs gigabytes.
@MainActor
final class SpeechModelPreparationXCTests: XCTestCase {
    private struct SyntheticFailure: Error {}

    private final class Provider: TranscriptionProvider {
        let name = "Synthetic"
        let isAvailable = true
        let isReady = false
        var failure: any Error = CancellationError()
        var modelsOnDisk = false
        var clearsAfterCancellation = true
        private(set) var clearCalls = 0

        var shouldClearCacheAfterCancellation: Bool { self.clearsAfterCancellation }
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws { throw self.failure }
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult { .init(text: "", confidence: 0) }
        func modelsExistOnDisk() -> Bool { self.modelsOnDisk }
        func clearCache() async throws { self.clearCalls += 1 }
    }

    private func prepare(_ provider: Provider, updateWeights: Bool = false) async -> any Error {
        do {
            try await SpeechModelPreparationOperation.prepare(provider: provider, updateWeights: updateWeights) { _ in }
            XCTFail("Preparation should have failed")
            return SyntheticFailure()
        } catch {
            return error
        }
    }

    func testCancellingAFirstDownloadClearsItsPartialFiles() async {
        let provider = Provider()
        let error = await self.prepare(provider)
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(provider.clearCalls, 1)
    }

    func testCancellingARetryKeepsAModelAlreadyOnDisk() async {
        let provider = Provider()
        provider.modelsOnDisk = true
        _ = await self.prepare(provider)
        XCTAssertEqual(provider.clearCalls, 0)
    }

    func testProviderCanKeepItsCacheOnCancellation() async {
        let provider = Provider()
        provider.clearsAfterCancellation = false
        _ = await self.prepare(provider)
        XCTAssertEqual(provider.clearCalls, 0)
    }

    func testCancellingAWeightUpdateKeepsTheCache() async {
        let provider = Provider()
        _ = await self.prepare(provider, updateWeights: true)
        XCTAssertEqual(provider.clearCalls, 0)
    }

    func testAnOrdinaryFailureKeepsTheCacheAndItsError() async {
        let provider = Provider()
        provider.failure = SyntheticFailure()
        let error = await self.prepare(provider)
        XCTAssertTrue(error is SyntheticFailure)
        XCTAssertEqual(provider.clearCalls, 0)
    }

    func testACancelledDownloadRequestCountsAsCancellation() async {
        let provider = Provider()
        provider.failure = URLError(.cancelled)
        let error = await self.prepare(provider)
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(provider.clearCalls, 1)
    }
}
