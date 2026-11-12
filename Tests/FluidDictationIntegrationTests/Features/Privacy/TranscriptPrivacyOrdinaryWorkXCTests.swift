@testable import FluidVoice_Debug
import Foundation
import XCTest

/// On iPhone every privacy model operation holds a residency token. A failed one must return it,
/// otherwise the model manager treats the resource as busy until the app restarts.
final class TranscriptPrivacyOrdinaryWorkXCTests: XCTestCase {
    private struct SyntheticFailure: Error {}

    private actor EndedTokens {
        private(set) var values: [UUID] = []
        func add(_ token: UUID) { self.values.append(token) }
    }

    func testFailedPreparationReturnsTheTokenItTook() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("privacy-ordinary-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let token = UUID(), ended = EndedTokens()
        let store = PichiTranscriptPrivacyModelStore(directory: directory) { _, _, _ in throw SyntheticFailure() }
        let service = PichiTranscriptPrivacyService(modelStore: store, beginOrdinaryWork: { token },
                                                    endOrdinaryWork: { await ended.add($0) })
        do {
            try await service.prepare()
            XCTFail("Preparation without a model should fail")
        } catch {}
        let values = await ended.values
        XCTAssertEqual(values, [token])
    }
}
