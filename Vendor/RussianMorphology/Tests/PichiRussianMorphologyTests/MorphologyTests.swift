import XCTest
@testable import PichiRussianMorphology

final class MorphologyTests: XCTestCase {
    private let morphology = SensitiveDictionaryMorphologySnapshot()

    func testCompleteNounParadigms() throws {
        let expected = ["взятка", "взятки", "взятке", "взятку", "взяткой", "взяткою", "взяток", "взяткам", "взятками", "взятках"]
        let forms = try XCTUnwrap(morphology.forms(for: "взятка"))
        XCTAssertTrue(Set(expected).isSubset(of: forms), "missing: \(Set(expected).subtracting(forms))")
        let kickback = try XCTUnwrap(morphology.forms(for: "откат"))
        XCTAssertTrue(Set(["откат", "отката", "откату", "откатом", "откате", "откаты", "откатов", "откатам", "откатами", "откатах"]).isSubset(of: kickback))
    }

    func testInputMayAlreadyBeInflectedAndUppercase() throws {
        XCTAssertEqual(try morphology.forms(for: "ВЗЯТКАХ"), try morphology.forms(for: "взятка"))
        XCTAssertTrue(try XCTUnwrap(morphology.forms(for: "откате")).contains("откатов"))
    }

    func testIrregularNounsAndAdjectives() throws {
        XCTAssertTrue(try XCTUnwrap(morphology.forms(for: "ребёнок")).contains("детей"))
        XCTAssertTrue(try XCTUnwrap(morphology.forms(for: "человек")).contains("людьми"))
        XCTAssertTrue(try XCTUnwrap(morphology.forms(for: "коммерческий")).contains("коммерческого"))
        XCTAssertTrue(try XCTUnwrap(morphology.forms(for: "подкуп")).contains("подкупами"))
    }

    func testUnknownWordsDoNotInventForms() throws {
        XCTAssertNil(try morphology.forms(for: "квантобублозавр"))
        XCTAssertNil(try morphology.forms(for: "C0rp_42"))
        XCTAssertThrowsError(try morphology.forms(for: "два слова"))
        XCTAssertThrowsError(try morphology.forms(for: ""))
        XCTAssertThrowsError(try morphology.forms(for: "a\u{0}b"))
        XCTAssertThrowsError(try morphology.forms(for: String(repeating: "я", count: 65)))
    }

    func testCyrillicUnicodeAndNames() throws {
        let tree = try XCTUnwrap(morphology.forms(for: "ёлка"))
        XCTAssertTrue(tree.contains("ёлка"))
        XCTAssertEqual(try morphology.forms(for: "Е\u{308}ЛКА"), tree)
        XCTAssertTrue(try XCTUnwrap(morphology.forms(for: "Иван")).contains("иваном"))
        XCTAssertFalse(try XCTUnwrap(morphology.forms(for: "взятка")).contains("взяточничество"))
    }

    func testConcurrentCallsOwnTheirBuffers() async throws {
        try await withThrowingTaskGroup(of: Set<String>?.self) { group in
            for _ in 0..<24 { group.addTask { try SensitiveDictionaryMorphologySnapshot().forms(for: "взятка") } }
            for try await result in group { XCTAssertTrue(result?.contains("взяток") == true) }
        }
    }
}
