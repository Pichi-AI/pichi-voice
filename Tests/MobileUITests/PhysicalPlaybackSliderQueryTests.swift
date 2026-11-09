import Foundation
import XCTest

final class PhysicalPlaybackSliderQueryTests: XCTestCase {
    func testExactEnglishAndRussianNativeLabelsAreRecognized() {
        for label in ["Audio chunk position", "Позиция в аудиофрагменте"] {
            XCTAssertTrue(PhysicalPlaybackSliderQuery.predicate.evaluate(with: ["label": label]))
            XCTAssertTrue(PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: 1, sliderCount: matches([label])))
        }
    }

    func testUnknownPartialAndChangedCaseLabelsAreNotAdopted() {
        for label in ["", "Audio", "audio chunk position", "Audio chunk position ",
                      "Audio chunk position elsewhere", "Позиция", "Позиция в аудиофрагменте "] {
            XCTAssertFalse(PhysicalPlaybackSliderQuery.predicate.evaluate(with: ["label": label]))
            XCTAssertFalse(PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: 1, sliderCount: matches([label])))
        }
        XCTAssertFalse(PhysicalPlaybackSliderQuery.predicate.evaluate(with: ["identifier": "Audio chunk position"]))
    }

    func testUnrelatedControlsDoNotHideTheSingleOwnedSlider() {
        let controls = ["Recording volume", "Позиция в аудиофрагменте", "Another setting"]
        XCTAssertEqual(matches(controls), 1)
        XCTAssertTrue(PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: 1, sliderCount: matches(controls)))
    }

    func testDuplicateOrMixedLocaleSlidersRemainAmbiguous() {
        for controls in [["Audio chunk position", "Audio chunk position"],
                         ["Позиция в аудиофрагменте", "Позиция в аудиофрагменте"],
                         ["Audio chunk position", "Позиция в аудиофрагменте"]] {
            XCTAssertEqual(matches(controls), 2)
            XCTAssertFalse(PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: 1, sliderCount: matches(controls)))
        }
    }

    func testMissingOrAmbiguousParagraphCannotAuthorizeAValidSlider() {
        for count in [-1, 0, 2, 3] {
            XCTAssertFalse(PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: count, sliderCount: 1))
        }
    }

    func testMissingOrInvalidSliderCountCannotBeAdopted() {
        for count in [-1, 0, 2, 3] {
            XCTAssertFalse(PhysicalPlaybackSliderQuery.isUniqueOwnedMatch(paragraphCount: 1, sliderCount: count))
        }
    }

    func testPreexistingPlayerGuardRecognizesEitherLocaleAndNeverTreatsDuplicatesAsAbsent() {
        XCTAssertEqual(matches(["Unrelated setting"]), 0)
        for controls in [["Audio chunk position"], ["Позиция в аудиофрагменте"],
                         ["Audio chunk position", "Позиция в аудиофрагменте"]] {
            XCTAssertGreaterThan(matches(controls), 0, "The no-existing-player admission must reject these controls")
        }
    }

    private func matches(_ labels: [String]) -> Int {
        let predicate = PhysicalPlaybackSliderQuery.predicate
        return labels.filter { predicate.evaluate(with: ["label": $0]) }.count
    }
}
