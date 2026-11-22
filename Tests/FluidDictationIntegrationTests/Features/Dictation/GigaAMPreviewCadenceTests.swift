import XCTest
@testable import FluidVoice_Debug

@MainActor
final class GigaAMPreviewCadenceTests: XCTestCase {
    func testFixedCadenceSubtractsProcessingTimeAndSkipsOverruns() {
        let tick: UInt64 = 500_000_000
        let start: UInt64 = 1_000_000_000
        XCTAssertEqual(StreamingTaskLifecycle.nextPreviewDelay(interval: tick, origin: start, now: start + 40_000_000), 460_000_000)
        XCTAssertEqual(StreamingTaskLifecycle.nextPreviewDelay(interval: tick, origin: start, now: start + 1_200_000_000), 300_000_000)
        XCTAssertEqual(StreamingTaskLifecycle.nextPreviewDelay(interval: tick, origin: start, now: start + tick), tick)
    }

    func testCompletionRelativeProvidersRetainTheFullDelay() {
        XCTAssertEqual(StreamingTaskLifecycle.nextPreviewDelay(interval: 500, origin: nil, now: 600), 500)
    }
}
