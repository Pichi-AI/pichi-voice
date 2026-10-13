import XCTest
@testable import PichiVoiceMobile

final class MeetingLiveCaptionPresentationTests: XCTestCase {
    private func row(_ text: String, speaker: MeetingLiveSpeaker = .you, id: UUID = UUID(),
                     partial: Bool = false, label: Bool = false) -> MeetingLiveBubbleComposer.Row {
        .init(id: id, speaker: speaker, text: text, isPartial: partial, showsLabel: label)
    }

    func testWordTimingRowsFlowWithoutChangingCanonicalMembers() {
        let rows = [row("Здравствуйте", label: true), row(","), row("давайте"), row("обсудим"), row("инструкцию.")]
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text(), "Здравствуйте, давайте обсудим инструкцию.")
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows, "Presentation must retain every original row and its ID")
        XCTAssertEqual(paragraphs[0].id, rows[0].id)
        XCTAssertTrue(paragraphs[0].showsLabel)
    }

    func testSourceChangeAndExplicitBreakRemainVisible() {
        let rows = [row("Первая строка\nВторая строка", label: true), row("Продолжение"),
                    row("English response", speaker: .them, label: true), row("follows", speaker: .them)]
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertEqual(paragraphs.map { $0.text() }, ["Первая строка\nВторая строка", "Продолжение", "English response follows"])
        XCTAssertEqual(paragraphs.map(\.speaker), [.you, .you, .them])
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows)
    }

    func testPartialGrowthCorrectionAndSolidificationKeepParagraphIdentity() {
        let committed = row("Начало", label: true)
        let partialID = UUID()
        let short = [committed, row("жду", id: partialID, partial: true)]
        let correction = [committed, row("иду", id: partialID, partial: true)]
        let long = [committed, row(String(repeating: "слово ", count: 150), id: partialID, partial: true)]
        let finalized = [committed, row(long[1].text, id: partialID)]
        XCTAssertNotEqual(short, correction, "Equal-length hypotheses must still invalidate content observers")
        for rows in [short, correction, long, finalized] {
            let paragraph = MeetingLiveCaptionParagraphs.compose(rows)
            XCTAssertEqual(paragraph.count, 1)
            XCTAssertEqual(paragraph[0].id, committed.id)
            XCTAssertEqual(paragraph[0].rows[1].id, partialID)
        }
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(short)[0].text(includingPartials: false), "Начало")
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(correction)[0].text(), "Начало иду")
    }

    func testLongWordStreamHasBoundedParagraphsWithoutDroppingWords() {
        let rows = (0..<600).map { row("слово\($0)", label: $0 == 0) }
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertGreaterThan(paragraphs.count, 5)
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows)
        XCTAssertTrue(paragraphs.allSatisfy { $0.text().count <= 530 })
        XCTAssertEqual(Set(paragraphs.map(\.id)).count, paragraphs.count)
        XCTAssertTrue(MeetingLiveCaptionParagraphs.compose([]).isEmpty)
    }

    func testChronologicalReorderingRetainsCanonicalMembersAndSourceBoundaries() {
        let first = row("Начало", label: true)
        let remote = row("Response", speaker: .them, label: true)
        let turnID = UUID()
        let partial = row("продолжение", id: turnID, partial: true, label: true)
        let liveRows = [first, remote, partial]
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(liveRows).flatMap(\.rows), liveRows)
        let finalRows = [first, row("продолжение", id: turnID), remote]
        let paragraphs = MeetingLiveCaptionParagraphs.compose(finalRows)
        XCTAssertEqual(paragraphs.map { $0.text() }, ["Начало продолжение", "Response"])
        XCTAssertEqual(paragraphs.flatMap(\.rows), finalRows)
        XCTAssertEqual(paragraphs[0].rows[1].id, turnID,
                       "Chronological reflow can regroup a turn but must retain its canonical identity")
    }

    func testSensitivePlaceholdersAndExistingWhitespaceAreNotRewritten() {
        let rows = [row("Позвоните "), row("[PERSON]"), row(" по адресу [ADDRESS]."), row("\n"), row("[PHONE]")]
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(rows).map { $0.text() }.joined(separator: "\n"),
                       "Позвоните [PERSON] по адресу [ADDRESS].\n\n[PHONE]")
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(rows).flatMap(\.rows), rows)
    }

    func testGrowthIsLayoutChangeRatherThanScrollIntent() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let before = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 600, contentOffset: 300)
        let grown = Geometry(contentBottom: 900, viewportHeight: 300, contentHeight: 1200, contentOffset: 300)
        XCTAssertEqual(before.isPinnedToBottom, true)
        XCTAssertEqual(grown.isPinnedToBottom, false, "Proximity changes, but the follow preference must not")
        XCTAssertTrue(grown.layoutChanged(from: before))
        XCTAssertFalse(grown.offsetChanged(from: before))
        XCTAssertTrue(grown.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true))
        let bottomBeforeShrink = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 900, contentOffset: 600)
        let shrink = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 600, contentOffset: 300)
        XCTAssertTrue(shrink.fallbackFollowPreference(after: bottomBeforeShrink,
            currentlyFollowing: true, upwardDrag: false), "iOS 17 layout shrink must not look like an upward drag")
        let userScrolled = Geometry(contentBottom: 450, viewportHeight: 300, contentHeight: 600, contentOffset: 150)
        XCTAssertFalse(userScrolled.layoutChanged(from: before))
        XCTAssertTrue(userScrolled.offsetChanged(from: before))
        XCTAssertEqual(userScrolled.isPinnedToBottom, false)
        XCTAssertFalse(userScrolled.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true))
        let reflow = Geometry(contentBottom: 850, viewportHeight: 300, contentHeight: 1200, contentOffset: 350)
        XCTAssertTrue(reflow.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true),
                      "A reflow that also adjusts the offset must retain the follow preference")
    }

    func testUpwardDragPausesOnlyScrollableTextAndLatestMotionKeepsFollowing() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let short = Geometry(contentBottom: 100, viewportHeight: 300, contentHeight: 100, contentOffset: 0)
        let bounce = Geometry(contentBottom: 120, viewportHeight: 300, contentHeight: 100, contentOffset: -20)
        XCTAssertTrue(bounce.followPreference(after: short, currentlyFollowing: true, userIsScrolling: true, upwardDrag: true))
        let bottom = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 900, contentOffset: 600)
        let up = Geometry(contentBottom: 320, viewportHeight: 300, contentHeight: 900, contentOffset: 580)
        XCTAssertFalse(up.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: true, upwardDrag: true))
        let growingWhileUp = Geometry(contentBottom: 360, viewportHeight: 300, contentHeight: 940, contentOffset: 580)
        XCTAssertFalse(growingWhileUp.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: true),
                       "New captions must not override simultaneous reading of older text")
        XCTAssertFalse(growingWhileUp.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: true, upwardDrag: true))
        XCTAssertFalse(growingWhileUp.fallbackFollowPreference(after: bottom,
            currentlyFollowing: true, upwardDrag: true), "iOS 17 must respect an upward drag during content growth")
        XCTAssertTrue(growingWhileUp.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: false),
                      "Layout growth without a user gesture must keep following")
        let momentumUp = Geometry(contentBottom: 330, viewportHeight: 300, contentHeight: 900, contentOffset: 570)
        XCTAssertFalse(momentumUp.followPreference(after: up, currentlyFollowing: false, userIsScrolling: true),
                       "A small deliberate upward drag must remain paused during deceleration")
        let older = Geometry(contentBottom: 700, viewportHeight: 300, contentHeight: 900, contentOffset: 200)
        let movingDown = Geometry(contentBottom: 600, viewportHeight: 300, contentHeight: 900, contentOffset: 300)
        XCTAssertTrue(movingDown.followPreference(after: older, currentlyFollowing: true, userIsScrolling: true),
                      "An explicit latest action must remain active during its animation")
        XCTAssertFalse(movingDown.followPreference(after: older, currentlyFollowing: false, userIsScrolling: true),
                       "A reader moving down through older text has not reached the bottom yet")
        XCTAssertTrue(bottom.followPreference(after: movingDown, currentlyFollowing: false, userIsScrolling: true))
    }
}
