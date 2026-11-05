@testable import FluidVoice_Debug
import CryptoKit
import Foundation
import XCTest

/// With topic protection on, an unfinished sentence stays out of durable storage until the classifier has seen all of it.
final class TranscriptPublicationLimitXCTests: XCTestCase {
    private let text = "Первое предложение. Второе без точки"

    /// The smallest valid artifact. It has no weights, because this limit depends only on sentence boundaries.
    private func classifier() throws -> SensitiveTopicClassifierSnapshot {
        let topic = try XCTUnwrap(SensitiveTopicClassifierSnapshot.supportedTopicIDs.sorted().first)
        let artifact = SensitiveTopicClassifierSnapshot.Artifact(
            formatVersion: 1, featureIdentity: SensitiveTopicClassifierSnapshot.featureIdentity, dimensions: 1_024,
            trainingDigest: String(repeating: "0", count: 64),
            topics: [.init(id: topic, bias: 0, threshold: 0.5, weights: [:])])
        let data = try JSONEncoder().encode(artifact)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return try SensitiveTopicClassifierSnapshot(data: data, expectedSHA256: digest, selectedTopicIDs: [topic])
    }

    func testTopicProtectionHoldsBackTheUnfinishedSentence() throws {
        let dictionary = try TranscriptSensitiveDictionarySnapshot(entries: [], topicClassifier: self.classifier())
        let limit = try XCTUnwrap(dictionary.durablePublicationLimit(in: self.text))
        XCTAssertEqual(limit, try SensitiveTopicClassifierSnapshot.completedPrefixUTF16(in: self.text))
        XCTAssertLessThan(limit, self.text.utf16.count)
        XCTAssertGreaterThanOrEqual(limit, "Первое предложение.".utf16.count)
    }

    func testWithoutTopicProtectionNothingIsHeldBack() throws {
        let dictionary = try TranscriptSensitiveDictionarySnapshot(entries: [])
        XCTAssertNil(try dictionary.durablePublicationLimit(in: self.text))
    }
}
