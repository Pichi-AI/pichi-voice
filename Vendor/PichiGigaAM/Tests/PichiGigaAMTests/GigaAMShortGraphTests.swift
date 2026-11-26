import Foundation
import XCTest
@testable import PichiGigaAM

final class GigaAMShortGraphTests: XCTestCase {
    func testReconstructsSpecAndPositionalRanges() throws {
        let recipe = Data([0, 1, 2, 1, 1, 20, 2, 0x80, 1, 2])
        let result = try GigaAMShortGraph.reconstruct(recipe: recipe, original: Data([0, 3, 8]), expectedSize: 5) { offset, count in
            XCTAssertEqual(offset, 128)
            XCTAssertEqual(count, 2)
            return Data([6, 9])
        }
        XCTAssertEqual(result, Data([3, 8, 20, 6, 9]))
    }

    func testRejectsMalformedOrIncompleteRecipe() {
        for bytes: [UInt8] in [[0, 9, 1], [1, 2, 1], [2, 0, 1], [1, 0x80], [9, 0, 1], [0, 0, 2], []] {
            XCTAssertThrowsError(try GigaAMShortGraph.reconstruct(recipe: Data(bytes), original: Data([0]), expectedSize: 1) { _, _ in Data() })
        }
    }
}
