import Foundation
@testable import FluidVoice_Debug
import XCTest

final class ChangelogNoteTests: XCTestCase {
    func testBilingualReleaseKeepsLinksNativeSectionsAndDuplicateBullets() throws {
        let body = """
        [English](#release-en) · [Русский](#release-ru)

        <a name="release-en"></a>

        ## English

        ### What's new

        - [Download](https://example.org/download)
        - Again
        - Again

        ---

        <a id='release-ru'></a>

        ## Русский

        ### Что нового

        - **Новое** и `<code>`
        """
        let blocks = ChangelogNote.make(from: body, releaseTitle: "Example", version: "1")
        XCTAssertEqual(blocks.map(\.kind), [
            .paragraph, .heading(level: 2), .heading(level: 3), .bullet, .bullet, .bullet,
            .divider, .heading(level: 2), .heading(level: 3), .bullet,
        ])
        XCTAssertEqual(blocks.map { String($0.text.characters) }, [
            "English · Русский", "English", "What's new", "Download", "Again", "Again",
            "", "Русский", "Что нового", "Новое и <code>",
        ])
        XCTAssertEqual(blocks[0].text.runs.compactMap(\.link).map(\.relativeString), ["#release-en", "#release-ru"])
        XCTAssertEqual(blocks[3].text.runs.compactMap(\.link).first?.absoluteString, "https://example.org/download")
        XCTAssertEqual(blocks.compactMap(\.anchor), ["release-en", "release-ru"])
        XCTAssertEqual(blocks[1].anchor, "release-en")
        XCTAssertEqual(blocks[7].anchor, "release-ru")
        XCTAssertTrue(blocks[9].text.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(blocks[9].text.runs.contains { $0.inlinePresentationIntent?.contains(.code) == true })
    }

    func testLegacyPlainNotesAndUpstreamBoilerplate() {
        let body = """
        # Example 1

        First paragraph.

        Second paragraph.

        ## Improvements

        * Corrected text

        [Report issues](https://github.com/altic-dev/FluidVoice/issues)

        ## Contributors

        Names
        """
        let blocks = ChangelogNote.make(from: body, releaseTitle: "Example 1", version: "1")
        XCTAssertEqual(blocks.map { String($0.text.characters) }, ["First paragraph.", "Second paragraph.", "Improvements", "Corrected text"])
    }

    func testDetailsRetainsContentWhileCodeExamplesRemainLiteral() {
        let body = """
        <details><summary>Changes</summary>

        A <em>small</em> fix.

        </details>

        ```
        <a name="sample"></a>
        ```
        """
        let blocks = ChangelogNote.make(from: body, releaseTitle: "Example", version: "1")
        XCTAssertEqual(blocks.map { String($0.text.characters).trimmingCharacters(in: .whitespacesAndNewlines) },
                       ["Changes", "A small fix.", "<a name=\"sample\"></a>"])
        XCTAssertTrue(blocks.compactMap(\.anchor).isEmpty)
    }
}
