import XCTest
import Combine
import SwiftUI
import UIKit
@testable import PichiVoiceMobile

final class MeetingLiveCaptionPresentationTests: XCTestCase {
    func testBufferedCaptionCoverageDoesNotInventTimingForGrowingIdenticalWords() {
        let coarse = PichiMeetingCaptionRecognition(text: "Same words", endOfUtteranceProbability: nil)
        for count in [48_000, 96_000, 192_000] {
            XCTAssertNil(coarse.nativeCoverage(sampleCount: count, sampleRate: 16_000),
                         "A longer buffer with identical words cannot retire more captured audio")
        }
        let native = PichiMeetingCaptionRecognition(text: "Same words", endOfUtteranceProbability: nil,
            segmentTimings: [.init(text: "Same words", start: 0.2, end: 1.1)])
        for count in [48_000, 96_000, 192_000] {
            XCTAssertEqual(native.nativeCoverage(sampleCount: count, sampleRate: 16_000), 0.2..<1.1,
                           "Only actual native speech intervals survive a growing window")
        }
        let partialMetadata = PichiMeetingCaptionRecognition(text: "Same words", endOfUtteranceProbability: nil,
            segmentTimings: [.init(text: "Same", start: 0.2, end: 1.1)])
        XCTAssertNil(partialMetadata.nativeCoverage(sampleCount: 48_000, sampleRate: 16_000))
        let words = PichiMeetingCaptionRecognition(text: "Same words", endOfUtteranceProbability: nil,
            words: [.init(text: "Same", start: 0.2, end: 0.6), .init(text: "words", start: 0.7, end: 1.1)])
        XCTAssertEqual(words.nativeCoverage(sampleCount: 48_000, sampleRate: 16_000), 0.2..<1.1)
    }

    func testRepeatedHypothesesAdmitWholeWordsWithoutFreezingAnOpenToken() {
        XCTAssertEqual(MeetingSpeechHypothesisStability.stableUTF16Count(previous: "кот", current: "которая пишет"), 0)
        XCTAssertEqual(MeetingSpeechHypothesisStability.stableUTF16Count(previous: "слово которого", current: "слово которое меняется"), "слово ".utf16.count)
        XCTAssertEqual(MeetingSpeechHypothesisStability.stableUTF16Count(previous: "Иван", current: "и вам завтра"), 0)
        XCTAssertEqual(MeetingSpeechHypothesisStability.stableUTF16Count(previous: "Ёжик 👩🏽‍⚕️ говорит", current: "Ёжик 👩🏽‍⚕️ говорит дальше"), "Ёжик 👩🏽‍⚕️ ".utf16.count)
        XCTAssertEqual(MeetingSpeechHypothesisStability.stableUTF16Count(previous: "Готово.", current: "Готово."), "Готово.".utf16.count)
        let id = UUID()
        var snapshot = MeetingLiveTranscriptSnapshot.empty.settingPartial(.init(id: id, text: "кот", start: 0), for: .you)
        XCTAssertNil(snapshot.partials[.you]?.stableUTF16Count)
        snapshot = snapshot.settingPartial(.init(id: id, text: "которая пишет", start: 0), for: .you)
        XCTAssertEqual(snapshot.partials[.you]?.stableUTF16Count, 0)
        snapshot = snapshot.settingPartial(.init(id: id, text: "которая пишет слова", start: 0), for: .you)
        XCTAssertEqual(snapshot.partials[.you]?.stableUTF16Count, "которая ".utf16.count)
        snapshot = snapshot.settingPartial(.init(id: UUID(), text: "которая пишет слова", start: 3), for: .you)
        XCTAssertNil(snapshot.partials[.you]?.stableUTF16Count, "A new turn has no repeated hypothesis yet")
    }

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

    func testActualParticipantsOnOneMicrophoneFormDistinctReadableTurns() {
        let first = MeetingSpeakerPresentation(identity: "participant-a", label: .identified(.init(displayName: "Same alias", isLocalUser: false)))
        let second = MeetingSpeakerPresentation(identity: "participant-b", label: .identified(.init(displayName: "Same alias", isLocalUser: false)))
        let words = ["Начало", "[PERSON]", "и", "ответ", "второго"]
        let utterances = words.enumerated().map { index, text in
            MeetingLiveUtterance(id: UUID(), speaker: .you, text: text,
                start: Double(index) * 0.2, end: Double(index) * 0.2 + 0.1,
                participant: index < 3 ? first : second)
        }
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot.utterances = utterances
        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertEqual(rows.map(\.showsLabel), [true, false, false, true, false])
        XCTAssertEqual(paragraphs.map { $0.text() }, ["Начало [PERSON] и", "ответ второго"])
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows)
        XCTAssertEqual(rows.map(\.id), utterances.map(\.id))
        XCTAssertEqual(snapshot.utterances, utterances, "Presentation preserves protected text, source and native times")
        XCTAssertTrue(rows.allSatisfy { $0.speaker == .you }, "Source routing is independent of actual participant identity")
    }

    func testEstimatedWordPromotesWholeParticipantTurnWithoutOrphanHeaders() {
        let name = MeetingSpeakerPresentation.Name(displayName: "Ёлкин", isLocalUser: false)
        let direct = MeetingSpeakerPresentation(identity: "one-turn", label: .identified(name))
        let estimated = MeetingSpeakerPresentation(identity: "one-turn", label: .estimated(name))
        let rows = [
            MeetingLiveBubbleComposer.Row(id: UUID(), speaker: .you, text: "Текст", isPartial: false, showsLabel: true, participant: direct),
            .init(id: UUID(), speaker: .you, text: "и", isPartial: false, showsLabel: false, participant: estimated),
            .init(id: UUID(), speaker: .you, text: "продолжение", isPartial: false, showsLabel: false, participant: direct),
        ]
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].participant, estimated)
        XCTAssertEqual(paragraphs[0].text(), "Текст и продолжение")
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows)
    }

    func testSelectedParticipantLabelsStayPlainInEnglishAndRussian() {
        for alias in ["Participant 1", "Participant 2", "Участник 1", "Участник 2", "Ёлкин"] {
            let direct = MeetingSpeakerPresentation(identity: UUID().uuidString,
                label: .identified(.init(displayName: alias, isLocalUser: false)))
            let estimated = direct.markingEstimated()
            for language in [PichiInterfaceLanguage.english, .russian] {
                XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: direct, language: language), alias)
                XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: estimated, language: language), alias)
            }
            XCTAssertTrue(estimated.isEstimated, "Plain labels retain internal heuristic evidence")
            XCTAssertFalse(direct.isEstimated)
            XCTAssertEqual(direct.identity, estimated.identity)
        }
    }

    func testUncertainOverlapAndInterruptingRolesStayDistinctFromKnownTurn() {
        let name = MeetingSpeakerPresentation.Name(displayName: "Участник", isLocalUser: false)
        let roles: [MeetingSpeakerPresentation] = [
            .init(identity: "assigned", label: .identified(name)),
            .init(identity: "unknown", label: .unknown),
            .init(identity: "simultaneous", label: .candidates([name, nil], relation: .simultaneous)),
            .init(identity: "interruption", label: .interrupting(name, background: [nil])),
            .init(identity: "assigned", label: .identified(name)),
        ]
        let rows = roles.map { MeetingLiveBubbleComposer.Row(id: UUID(), speaker: .you, text: "слово",
            isPartial: false, showsLabel: true, participant: $0) }
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertEqual(paragraphs.count, roles.count)
        XCTAssertEqual(paragraphs.compactMap(\.participant), roles)
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows)
    }

    func testActualParticipantDoesNotClaimIdentityOfSourceOnlyPartial() {
        let id = UUID()
        let participant = MeetingSpeakerPresentation(identity: "person", label: .identified(.init(displayName: "Участник", isLocalUser: false)))
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot.utterances = [.init(id: id, speaker: .you, text: "[PERSON]", start: 0, end: 1, participant: participant)]
        // A stale provisional callback can still be present in an incoming value. Never render
        // it twice when the same turn becomes a protected, attributed result.
        snapshot.partials[.you] = .init(id: id, text: "STALE_PARTIAL", start: 0)
        XCTAssertEqual(MeetingLiveBubbleComposer.rows(for: snapshot).map(\.text), ["[PERSON]"])
        snapshot.partials[.you] = .init(id: UUID(), text: "следующий", start: 2)
        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.showsLabel), [true, true])
        XCTAssertNil(rows[1].participant)
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(rows).count, 2)
    }

    func testParticipantRefinementDoesNotPretendThatNewWordsArrived() {
        let id = UUID()
        var original = MeetingLiveTranscriptSnapshot.empty
        original.utterances = [.init(id: id, speaker: .you, text: "[PERSON] говорит", start: 0, end: 1)]
        var attributed = original
        attributed.utterances[0].participant = .init(identity: "participant", label: .identified(.init(displayName: "Участник", isLocalUser: false)))
        XCTAssertFalse(attributed.hasNewWords(since: original))
        attributed.utterances[0].text += " дальше"
        XCTAssertTrue(attributed.hasNewWords(since: original))
        XCTAssertFalse(MeetingLiveTranscriptSnapshot.empty.hasNewWords(since: original))
    }

    func testLateEstimateQualifiesHeaderBeforeLongTurnLayoutBreak() {
        let name = MeetingSpeakerPresentation.Name(displayName: "Участник", isLocalUser: false)
        let direct = MeetingSpeakerPresentation(identity: "one-long-turn", label: .identified(name))
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot.utterances = (0..<200).map { index in
            .init(id: UUID(), speaker: .you, text: "слово", start: Double(index), end: Double(index) + 0.5,
                  participant: index == 199 ? direct.markingEstimated() : direct)
        }
        let original = snapshot
        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertGreaterThan(paragraphs.count, 1)
        XCTAssertEqual(rows.filter(\.showsLabel).count, 1)
        XCTAssertEqual(paragraphs[0].participant?.isEstimated, true,
                       "A later estimate cannot hide below a layout-only paragraph break")
        XCTAssertEqual(snapshot, original, "Aggregated reading headers never change original word evidence")
        XCTAssertEqual(rows.map(\.id), snapshot.utterances.map(\.id))
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
        var heightPublishedBeforeClamp = shrink
        heightPublishedBeforeClamp.contentOffset = bottomBeforeShrink.contentOffset
        XCTAssertTrue(shrink.fallbackFollowPreference(after: heightPublishedBeforeClamp,
            currentlyFollowing: true, upwardDrag: false), "A later offset-only clamp belongs to the previous layout change")
        let userScrolled = Geometry(contentBottom: 450, viewportHeight: 300, contentHeight: 600, contentOffset: 150)
        XCTAssertFalse(userScrolled.layoutChanged(from: before))
        XCTAssertTrue(userScrolled.offsetChanged(from: before))
        XCTAssertEqual(userScrolled.isPinnedToBottom, false)
        XCTAssertFalse(userScrolled.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true))
        let reflow = Geometry(contentBottom: 850, viewportHeight: 300, contentHeight: 1200, contentOffset: 350)
        XCTAssertTrue(reflow.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true),
                      "A reflow that also adjusts the offset must retain the follow preference")
    }

    func testIOS17OffsetOnlyLayoutCorrectionCannotPauseWithoutAnActualDrag() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let bottom = Geometry(contentBottom: 600, viewportHeight: 600, contentHeight: 2000, contentOffset: 1400)
        let correction = Geometry(contentBottom: 700, viewportHeight: 600, contentHeight: 2000, contentOffset: 1300)
        XCTAssertFalse(correction.layoutChanged(from: bottom))
        XCTAssertTrue(correction.offsetChanged(from: bottom))
        XCTAssertTrue(correction.fallbackFollowPreference(after: bottom,
            currentlyFollowing: true, upwardDrag: false),
            "UIKit offset compensation without a finger must retain follow intent")
        XCTAssertFalse(correction.fallbackFollowPreference(after: bottom,
            currentlyFollowing: true, upwardDrag: true), "An actual upward drag still pauses")

        let momentum = Geometry(contentBottom: 800, viewportHeight: 600, contentHeight: 2000, contentOffset: 1200)
        XCTAssertFalse(momentum.fallbackFollowPreference(after: correction,
            currentlyFollowing: false, upwardDrag: false), "Finger release must not undo reading mode")
        let growth = Geometry(contentBottom: 1000, viewportHeight: 600, contentHeight: 2200, contentOffset: 1200)
        XCTAssertFalse(growth.fallbackFollowPreference(after: momentum,
            currentlyFollowing: false, upwardDrag: false), "New captions must respect the reader")
        let returned = Geometry(contentBottom: 600, viewportHeight: 600, contentHeight: 2200, contentOffset: 1600)
        XCTAssertTrue(returned.fallbackFollowPreference(after: growth,
            currentlyFollowing: false, upwardDrag: false), "Returning to the actual bottom resumes following")
    }

    func testIOS17VoiceOverRetainsPriorOffsetIntentWithoutReplacingNativeScroll() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let bottom = Geometry(contentBottom: 600, viewportHeight: 600, contentHeight: 2000, contentOffset: 1400)
        let earlier = Geometry(contentBottom: 700, viewportHeight: 600, contentHeight: 2000, contentOffset: 1300)
        XCTAssertFalse(earlier.fallbackFollowPreference(after: bottom,
            currentlyFollowing: true, upwardDrag: false, accessibilityOffsetIntent: true))
        XCTAssertTrue(earlier.fallbackFollowPreference(after: bottom,
            currentlyFollowing: true, upwardDrag: false, accessibilityOffsetIntent: false))
        let growth = Geometry(contentBottom: 900, viewportHeight: 600, contentHeight: 2200, contentOffset: 1300)
        XCTAssertFalse(growth.fallbackFollowPreference(after: earlier,
            currentlyFollowing: false, upwardDrag: false, accessibilityOffsetIntent: true))
        XCTAssertTrue(growth.fallbackFollowPreference(after: earlier,
            currentlyFollowing: true, upwardDrag: false, accessibilityOffsetIntent: true))
        let returned = Geometry(contentBottom: 600, viewportHeight: 600, contentHeight: 2200, contentOffset: 1600)
        XCTAssertTrue(returned.fallbackFollowPreference(after: growth,
            currentlyFollowing: false, upwardDrag: false, accessibilityOffsetIntent: true))
        let beforeClamp = Geometry(contentBottom: 600, viewportHeight: 600, contentHeight: 1800, contentOffset: 1600)
        let clamped = Geometry(contentBottom: 600, viewportHeight: 600, contentHeight: 1800, contentOffset: 1200)
        XCTAssertTrue(clamped.fallbackFollowPreference(after: beforeClamp,
            currentlyFollowing: true, upwardDrag: false, accessibilityOffsetIntent: true))
    }

    func testFastBottomCrossingLatchesFollowThroughRubberBandRecoil() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let older = Geometry(contentBottom: 450, viewportHeight: 300, contentHeight: 900, contentOffset: 450)
        let overshoot = Geometry(contentBottom: 276, viewportHeight: 300, contentHeight: 900, contentOffset: 624)
        let rebound = Geometry(contentBottom: 292, viewportHeight: 300, contentHeight: 900, contentOffset: 608)
        let bottom = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 900, contentOffset: 600)
        var following = overshoot.followPreference(after: older, currentlyFollowing: false, userIsScrolling: true)
        XCTAssertTrue(following, "A fast gesture can cross the bottom without stopping on its exact offset")
        following = rebound.followPreference(after: overshoot, currentlyFollowing: following, userIsScrolling: true)
        XCTAssertTrue(following, "Bottom recoil must not be interpreted as scrolling up to read older text")
        following = bottom.followPreference(after: rebound, currentlyFollowing: following, userIsScrolling: true)
        XCTAssertTrue(following)
        let grown = Geometry(contentBottom: 350, viewportHeight: 300, contentHeight: 950, contentOffset: 600)
        XCTAssertTrue(grown.followPreference(after: bottom, currentlyFollowing: following, userIsScrolling: true),
                      "New content after reaching the bottom retains follow intent")
        let upward = Geometry(contentBottom: 322, viewportHeight: 300, contentHeight: 900, contentOffset: 578)
        XCTAssertFalse(upward.followPreference(after: bottom, currentlyFollowing: following,
                                              userIsScrolling: true, upwardDrag: true),
                       "A subsequent genuine upward drag still pauses following")
        var fallbackFollowing = overshoot.fallbackFollowPreference(after: older, currentlyFollowing: false, upwardDrag: false)
        fallbackFollowing = rebound.fallbackFollowPreference(after: overshoot, currentlyFollowing: fallbackFollowing, upwardDrag: false)
        XCTAssertTrue(bottom.fallbackFollowPreference(after: rebound, currentlyFollowing: fallbackFollowing, upwardDrag: false),
                      "The iOS 17 geometry adapter must retain the same bottom-crossing latch")
    }

    func testFinalBottomGeometryCanArriveAfterScrollPhaseBecameIdle() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let almost = Geometry(contentBottom: 322, viewportHeight: 300, contentHeight: 900, contentOffset: 578)
        let bottom = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 900, contentOffset: 600)
        XCTAssertTrue(bottom.followPreference(after: almost, currentlyFollowing: false, userIsScrolling: false),
                      "The final geometry callback must resume even when the phase callback has already delivered idle")
        let near = Geometry(contentBottom: 320, viewportHeight: 300, contentHeight: 900, contentOffset: 580)
        XCTAssertFalse(near.followPreference(after: almost, currentlyFollowing: false, userIsScrolling: false),
                       "Moving toward the end without reaching it must not resume following")
        XCTAssertFalse(bottom.followPreference(after: bottom, currentlyFollowing: false, userIsScrolling: false),
                       "An unchanged position carries no new user intent")
        let beforeShrink = Geometry(contentBottom: 450, viewportHeight: 300, contentHeight: 1050, contentOffset: 600)
        XCTAssertFalse(bottom.followPreference(after: beforeShrink, currentlyFollowing: false, userIsScrolling: true),
                       "Content shrink alone must not opt an older-text reader back into following")
        let duringGrowth = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 1050, contentOffset: 750)
        XCTAssertFalse(duringGrowth.followPreference(after: bottom, currentlyFollowing: false, userIsScrolling: true),
                       "Layout compensation alone must not opt the reader back into following")
    }

    func testBottomCrossingCoalescedWithNewCaptionsStillResumes() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let older = Geometry(contentBottom: 450, viewportHeight: 300, contentHeight: 900, contentOffset: 450)
        let crossed = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 950, contentOffset: 650)
        XCTAssertTrue(crossed.followPreference(after: older, currentlyFollowing: false, userIsScrolling: true))
        XCTAssertTrue(crossed.followPreference(after: older, currentlyFollowing: false, userIsScrolling: false),
                      "The same genuine travel can arrive after the kinetic phase ends")
        let overshoot = Geometry(contentBottom: 280, viewportHeight: 300, contentHeight: 950, contentOffset: 670)
        XCTAssertTrue(crossed.followPreference(after: overshoot, currentlyFollowing: true, userIsScrolling: true))
        let compensated = Geometry(contentBottom: 450, viewportHeight: 300, contentHeight: 950, contentOffset: 500)
        XCTAssertFalse(compensated.followPreference(after: older, currentlyFollowing: false, userIsScrolling: true),
                       "Height compensation is not genuine finger travel toward the bottom")
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
        XCTAssertFalse(up.followPreference(after: movingDown, currentlyFollowing: false, userIsScrolling: true),
                       "Twenty points above the bottom must not resume following")
        XCTAssertFalse(up.fallbackFollowPreference(after: movingDown, currentlyFollowing: false, upwardDrag: false))
        XCTAssertTrue(bottom.followPreference(after: movingDown, currentlyFollowing: false, userIsScrolling: true))
    }
}

/// Hosted native rendering tests. Input rows are synthetic; the caption view, SwiftUI
/// layout and backing UIScrollView are real. This fixture never composes audio services.
@MainActor
final class MeetingLiveCaptionNativeScrollTests: XCTestCase {
    func testStreamingParticipantsRenderAsSeparateNativeTurns() async throws {
        let first = MeetingSpeakerPresentation.Name(displayName: "Анна", isLocalUser: false)
        let second = MeetingSpeakerPresentation.Name(displayName: "Борис", isLocalUser: false)
        let participants: [MeetingSpeakerPresentation] = [
            .init(identity: "first", label: .identified(first)),
            .init(identity: "second", label: .interrupting(second, background: [first])),
            .init(identity: "unknown", label: .unknown)
        ]
        let texts = ["Обсудим план встречи.", "Да, уточню один вопрос.", "Короткий неуверенный фрагмент."]
        let rows = zip(participants, texts).map { participant, text in
            MeetingLiveBubbleComposer.Row(id: UUID(), speaker: .you, text: text,
                isPartial: false, showsLabel: true, participant: participant)
        }
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(rows).count, 3)
        for scheme in [ColorScheme.light, .dark] {
            let host = try CaptionNativeHost(rows: rows, scheme: scheme)
            defer { host.close() }
            try await settle(host, "Streaming participant paragraphs have native layout") {
                self.scrollViews(in: host.controller.view).contains { $0.bounds.height > 0 }
            }
            capture(host, step: "streaming-participants", scheme: scheme)
        }
    }

    func testShortInlineBubbleKeepsItsIntrinsicWidth() async throws {
        let host = try CaptionNativeHost(rows: [row("Привет.")], scheme: .light, documentStyle: false)
        defer { host.close() }
        try await settle(host, "A short active bubble keeps its word-sized width") {
            self.descendants(in: host.controller.view).compactMap { $0 as? UITextView }.contains {
                $0.accessibilityIdentifier == "meeting.inlineCaption.text"
                    && $0.bounds.width > 20 && $0.bounds.width < host.model.width / 2
            }
        }
        capture(host, step: "bubble-01-intrinsic-width", scheme: .light)
        host.model.pending = pending(count: 2)
        try await settle(host, "Inline pending words expand the bubble only as needed") {
            self.descendants(in: host.controller.view).contains {
                $0.accessibilityIdentifier == "meeting.inlineWave.2" && $0.bounds.width > 0
            }
        }
        capture(host, step: "bubble-02-inline-words", scheme: .light)
    }

    func testPendingWordsStartAfterTheLastWordAndWrapNatively() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let text = "Ёжик идёт."
            let host = try CaptionNativeHost(rows: [row(text, label: true)], scheme: scheme)
            defer { host.close() }
            host.model.pending = pending(count: 12)
            try await settle(host, "Inline waveform views are laid out by the native text view") {
                self.descendants(in: host.controller.view).contains {
                    $0.accessibilityIdentifier == "meeting.inlineWave.1" && $0.bounds.width > 0
                }
            }
            let native = try XCTUnwrap(descendants(in: host.controller.view).compactMap { $0 as? UITextView }
                .first { $0.accessibilityIdentifier == "meeting.inlineCaption.text" })
            XCTAssertNotNil(native.textLayoutManager, "Inline view providers must stay on TextKit 2")
            XCTAssertFalse(native.isScrollEnabled, "Only the enclosing live-caption viewport scrolls")
            func wave(_ id: Int) throws -> UIView {
                try XCTUnwrap(self.descendants(in: host.controller.view).first {
                    $0.accessibilityIdentifier == "meeting.inlineWave.\(id)"
                })
            }
            let first = try wave(1)
            let end = try XCTUnwrap(native.position(from: native.beginningOfDocument, offset: text.utf16.count))
            let caret = native.caretRect(for: end)
            let firstRect = first.convert(first.bounds, to: native)
            XCTAssertGreaterThan(firstRect.minX, caret.minX, "A word space separates the text and waveform")
            XCTAssertLessThan(firstRect.minX - caret.minX, 16)
            XCTAssertLessThan(abs(firstRect.midY - caret.midY), caret.height / 2)
            capture(host, step: "inline-01-same-last-line", scheme: scheme)
            let wideWidth = host.model.width
            host.model.width = ceil(caret.minX + firstRect.width / 2)
            try await settle(host, "A waveform that cannot fit must wrap as a whole word") {
                let rect = first.convert(first.bounds, to: native)
                return rect.minX < 3 && rect.minY > caret.minY + caret.height / 2
            }
            capture(host, step: "inline-02-word-wrap", scheme: scheme)
            host.model.width = wideWidth
            host.model.rows[0].text = "Русский и English 👩🏽‍⚕️\n"
            try await settle(host, "Explicit newline starts the next waveform at the next line") {
                guard let current = self.descendants(in: host.controller.view).first(where: {
                    $0.accessibilityIdentifier == "meeting.inlineWave.1" && $0.window === host.window
                }) else { return false }
                return current.convert(current.bounds, to: native).minX < 3
            }
            capture(host, step: "inline-03-explicit-newline", scheme: scheme)
            XCTAssertFalse(host.model.rows.contains { $0.text.contains("\u{FFFC}") },
                           "Native attachment characters never enter the transcript")
            host.model.pending = .empty
            try await settle(host, "Recognized text replaces native attachments") {
                !native.attributedText.string.contains("\u{FFFC}")
            }
            capture(host, step: "inline-04-replaced", scheme: scheme)
        }
    }

    private func descendants(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    func testNativeSpeechQuietAndTextPreview() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let host = try CaptionNativeHost(rows: [
                row("Сегодня обсудим инструкцию к препарату и условия хранения.", label: true),
                row("Let's also look at the English version of the document."),
                row("После встречи я пришлю актуальные материалы.")
            ], scheme: scheme)
            defer { host.close() }
            try await settle(host, "Short review document is rendered") {
                self.scrollViews(in: host.controller.view).contains { $0.bounds.height > 0 }
            }
            let diagnosticID = UUID()
            var projection = MeetingPendingSpeechProjection(diagnostics: { event in
                DebugLogger.shared.logLazy(level: .debug, source: "MeetingPendingSpeech") {
                    "fixture=delayed-caption captureID=\(diagnosticID.uuidString) \(event.logFields)"
                }
            })
            func feed(_ first: Int, _ last: Int, speech: Bool) async throws {
                for frame in first..<last {
                    let time = Double(frame) * 0.02
                    let rms: Float = speech ? 0.018 + 0.011 * Float(sin(time * 2 * .pi * 3)) : 0.001
                    projection.observe(source: .you, start: time, end: time + 0.02,
                        rms: rms, peak: rms * 3, zeroCrossingRate: 0.12)
                    if host.model.pending != projection.snapshot { host.model.pending = projection.snapshot }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }
            try await feed(0, 100, speech: true)
            host.model.pending = projection.snapshot
            XCTAssertFalse(host.model.pending.tokens.isEmpty)
            try await settle(host, "Speech waveforms are rendered") { true }
            if let viewport = scrollViews(in: host.controller.view).first {
                let rect = viewport.convert(viewport.bounds, to: host.window)
                print("[NATIVE_REVIEW_VIEWPORT] x=\(rect.minX) y=\(rect.minY) width=\(rect.width) height=\(rect.height) scale=\(host.window.screen.scale)")
            }
            capture(host, step: "review-01-audio-pending", scheme: scheme)
            let waitingIDs = host.model.pending.tokens.map(\.id)
            try await feed(100, 700, speech: false)
            host.model.pending = projection.snapshot
            XCTAssertEqual(host.model.pending.tokens.map(\.id), waitingIDs,
                           "A long pause cannot remove speech while the recognizer is still working")
            try await settle(host, "Waiting speech remains visible during quiet") { true }
            capture(host, step: "review-02-quiet-still-waiting", scheme: scheme)
            try await feed(700, 800, speech: true)
            host.model.pending = projection.snapshot
            XCTAssertFalse(host.model.pending.tokens.isEmpty)
            let approved = "Документы доступны в разделе с материалами встречи."
            projection.reconcile(visible: .init(revision: 1,
                utterances: [.init(id: UUID(), speaker: .you, text: approved, start: 0, end: 16)]))
            host.model.rows.append(row(approved))
            host.model.pending = projection.snapshot
            XCTAssertTrue(host.model.pending.tokens.isEmpty)
            try await settle(host, "Approved text replaces its waveforms") { true }
            capture(host, step: "review-03-text-replacement", scheme: scheme)
        }
    }

    func testNativeScrollingRemainsResponsiveWhileNativeWorkIsBlocked() async throws {
        let host = try CaptionNativeHost(rows: wordRows(count: 360), scheme: .light)
        defer { host.close() }
        let scroll = try await captionScroll(in: host)
        try await settle(host, "Initial native document follows the bottom") { self.nearBottom(scroll) }
        let probe = BlockingNativeProbe()
        let executor = TranscriptionExecutor()
        let work = Task { try await executor.runBlocking { probe.run() } }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !probe.hasEntered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(probe.hasEntered)
            XCTAssertFalse(probe.hasFinished)
            XCTAssertFalse(probe.ranOnMainThread)
            let olderOffset = max(0, bottomOffset(scroll) - 250)
            scroll.setContentOffset(CGPoint(x: 0, y: olderOffset), animated: false)
            try await settle(host, "Native viewport can scroll while synchronous work is still running") {
                abs(scroll.contentOffset.y - olderOffset) < 3 && !probe.hasFinished
            }
            capture(host, step: "01-scrolled-during-native-work", scheme: .light)
            probe.release()
            let released = try await work.value
            XCTAssertTrue(released)
        } catch {
            probe.release()
            _ = await work.result
            throw error
        }
    }

    func testPendingWaveformsGrowAndBecomeRealTextInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let originalRows = wordRows(count: 260)
            let host = try CaptionNativeHost(rows: originalRows, scheme: scheme)
            defer { host.close() }
            let scroll = try await captionScroll(in: host)
            try await settle(host, "Initial transcript follows the bottom") { self.nearBottom(scroll) }
            let originalHeight = scroll.contentSize.height
            host.model.pending = pending(count: 12)
            try await settle(host, "Pending audio appears after the real text") {
                scroll.contentSize.height > originalHeight + 15 && self.nearBottom(scroll)
            }
            capture(host, step: "01-pending-waveforms", scheme: scheme)
            let shortHeight = scroll.contentSize.height
            host.model.pending = pending(count: 40)
            try await settle(host, "New pending words wrap and remain visible") {
                scroll.contentSize.height > shortHeight + 20 && self.nearBottom(scroll)
            }
            capture(host, step: "02-pending-growth", scheme: scheme)
            XCTAssertEqual(host.model.rows, originalRows, "Visual placeholders must not enter transcript rows")

            host.model.rows += [row("Распознанный текст. The real words replace pending audio.")]
            host.model.pending = .empty
            try await settle(host, "Approved text replaces the waveforms without losing following") { self.nearBottom(scroll) }
            capture(host, step: "03-recognized-text", scheme: scheme)
            XCTAssertEqual(host.model.rows.dropLast(), originalRows[...])
            let beforeMoreAudio = scroll.contentSize.height
            host.model.pending = pending(count: 32)
            try await settle(host, "Following survives pending-to-text replacement") {
                scroll.contentSize.height > beforeMoreAudio + 20 && self.nearBottom(scroll)
            }
            host.model.width *= 0.65
            try await settle(host, "Pending audio follows after viewport reflow") {
                abs(scroll.bounds.width - host.model.width) < 2 && self.nearBottom(scroll)
            }
            capture(host, step: "04-narrow-waveforms", scheme: scheme)
            let beforeNextReplacement = scroll.contentSize.height
            host.model.rows.append(row("Следующая фраза распознана. The next words replace captured audio."))
            host.model.pending = .empty
            try await settle(host, "The next recognized words replace waveforms and retain following") {
                scroll.contentSize.height < beforeNextReplacement - 20 && self.nearBottom(scroll)
            }
            capture(host, step: "05-next-text-replacement", scheme: scheme)
        }
    }

    private func pending(count: Int) -> MeetingPendingSpeechSnapshot {
        .init(tokens: (0..<count).map { index in
            .init(id: UInt64(index + 1), source: .you, start: Double(index) * 0.4,
                  end: Double(index + 1) * 0.4, widthHint: 0.55 + Double(index % 7) * 0.09, level: 0.65)
        }, isCapturing: true, revision: UInt64(count))
    }

    func testNativeWordRowsPartialCorrectionsAndReflowFollowLatestInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let partialID = UUID()
            let initialPartial = row(String(repeating: "i", count: 120), id: partialID, partial: true)
            let initialRows = wordRows(count: 260) + [initialPartial]
            let host = try CaptionNativeHost(rows: initialRows, scheme: scheme)
            defer { host.close() }
            let scroll = try await captionScroll(in: host)
            try await settle(host, "Initial long document must follow the bottom") { self.nearBottom(scroll) }
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 200)
            capture(host, step: "01-word-rows-bottom", scheme: scheme)

            let beforeAppend = scroll.contentSize.height
            host.model.rows = Array(initialRows.dropLast()) + wordRows(count: 80) + [initialPartial]
            try await settle(host, "New committed word rows must stay visible") {
                scroll.contentSize.height > beforeAppend + 20 && self.nearBottom(scroll)
            }
            let beforeCorrectionImage = capture(host, step: "02-committed-words-appended", scheme: scheme)

            let beforeCorrection = scroll.contentSize.height
            let previousPartial = try XCTUnwrap(host.model.rows.last)
            var corrected = previousPartial
            corrected.text = String(repeating: "Ш", count: previousPartial.text.count)
            XCTAssertEqual(corrected.text.count, previousPartial.text.count)
            XCTAssertEqual(corrected.id, partialID)
            host.model.rows[host.model.rows.count - 1] = corrected
            try await settle(host, "An equal-length same-ID correction must retain the latest position") {
                scroll.contentSize.height >= beforeCorrection - 2 && self.nearBottom(scroll)
            }
            let correctedImage = capture(host, step: "03-equal-length-partial-correction", scheme: scheme)
            // Proportional fonts also reflow here. A supported monospaced brand can retain
            // identical geometry, so inspect actual native pixels rather than assuming glyph widths.
            let beforeBitmap = try XCTUnwrap(beforeCorrectionImage.cgImage)
            let correctedBitmap = try XCTUnwrap(correctedImage.cgImage)
            XCTAssertEqual(beforeBitmap.width, correctedBitmap.width)
            XCTAssertEqual(beforeBitmap.height, correctedBitmap.height)
            XCTAssertEqual(beforeBitmap.bitsPerPixel, correctedBitmap.bitsPerPixel)
            XCTAssertEqual(beforeBitmap.bytesPerRow, correctedBitmap.bytesPerRow)
            let beforePixels = try XCTUnwrap(beforeBitmap.dataProvider?.data) as Data
            let correctedPixels = try XCTUnwrap(correctedBitmap.dataProvider?.data) as Data
            XCTAssertNotEqual(beforePixels, correctedPixels, "Equal-length partial correction must change the rendered text")

            let beforeGrowth = scroll.contentSize.height
            host.model.rows[host.model.rows.count - 1].text += String(repeating: " продолжение", count: 55)
            try await settle(host, "A growing partial with unchanged row count and ID must follow") {
                scroll.contentSize.height > beforeGrowth + 80 && self.nearBottom(scroll)
            }
            capture(host, step: "04-same-id-partial-growth", scheme: scheme)

            let beforeNarrowing = scroll.contentSize.height
            let originalWidth = host.model.width
            host.model.width = originalWidth * 0.65
            try await settle(host, "Width reflow must retain the latest position") {
                abs(scroll.bounds.width - host.model.width) < 2
                    && scroll.contentSize.height > beforeNarrowing + 20 && self.nearBottom(scroll)
            }
            capture(host, step: "05-narrower-viewport-following", scheme: scheme)

            let beforeShrink = scroll.contentSize.height
            host.model.rows = wordRows(count: 100) + [row("Встреча продолжается. English version remains visible.", partial: true)]
            try await settle(host, "Content shrink must retain the latest position") {
                scroll.contentSize.height < beforeShrink - 100 && self.nearBottom(scroll)
            }
            capture(host, step: "06-content-shrink-following", scheme: scheme)
            let shrunkHeight = scroll.contentSize.height
            host.model.rows = Array(host.model.rows.dropLast()) + wordRows(count: 100)
                + [row("Новый текст после изменения размера.", partial: true)]
            try await settle(host, "Following must remain active after the previous content shrink") {
                scroll.contentSize.height > shrunkHeight + 100 && self.nearBottom(scroll)
            }
            capture(host, step: "07-append-after-shrink", scheme: scheme)
        }
    }

    func testFullMeetingHistoryCanReachItsBeginningAfterMultipleParticipantTurns() async throws {
        let voices = ["Анна", "Борис", "Виктор"]
        let rows = (0..<1_200).map { index in
            let owner = voices[(index / 200) % voices.count]
            return MeetingLiveBubbleComposer.Row(id: UUID(), speaker: .you,
                text: index == 0 ? "Самое начало всей встречи." : "Слово \(index)",
                isPartial: false, showsLabel: index % 200 == 0,
                participant: .init(identity: owner, label: .identified(.init(displayName: owner, isLocalUser: false))))
        }
        let host = try CaptionNativeHost(rows: rows, scheme: .light)
        defer { host.close() }
        let scroll = try await captionScroll(in: host)
        try await settle(host, "Full history starts following the latest participant") { self.nearBottom(scroll) }
        capture(host, step: "full-history-01-tail", scheme: .light)
        let beginning = -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: 0, y: beginning), animated: false)
        try await settle(host, "The first participant's words remain reachable beyond the last 100 words") {
            abs(scroll.contentOffset.y - beginning) < 3 && !self.nearBottom(scroll)
        }
        capture(host, step: "full-history-02-beginning", scheme: .light)
        // A programmatic offset proves the full history is reachable, not that a
        // person dragged. Real manual reading/return is covered by UI gestures.
        XCTAssertEqual(host.model.rows.first?.id, rows.first?.id)
    }

    func testIOS17ProgrammaticOffsetCorrectionKeepsFollowingWhenNewRowsArrive() async throws {
        guard #unavailable(iOS 18) else {
            throw XCTSkip("This exercises the iOS 17 geometry fallback; programmatic movement is not a user gesture.")
        }
        for scheme in [ColorScheme.light, .dark] {
            let host = try CaptionNativeHost(rows: wordRows(count: 360), scheme: scheme)
            defer { host.close() }
            let scroll = try await captionScroll(in: host)
            try await settle(host, "Initial captions must be bottom-pinned") { self.nearBottom(scroll) }
            capture(host, step: "01-before-layout-offset-correction", scheme: scheme)

            let olderOffset = max(-scroll.adjustedContentInset.top, self.bottomOffset(scroll) - 250)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: olderOffset), animated: false)
            try await settle(host, "UIKit can adjust the offset without a finger gesture") {
                abs(scroll.contentOffset.y - olderOffset) < 3 && !self.nearBottom(scroll)
            }
            capture(host, step: "02-programmatic-offset-correction", scheme: scheme)

            let oldContentHeight = scroll.contentSize.height
            host.model.rows += wordRows(count: 120)
            try await settle(host, "New captions must remain visible after a non-user offset correction") {
                scroll.contentSize.height > oldContentHeight + 40
                    && self.nearBottom(scroll)
            }
            capture(host, step: "03-append-preserves-following", scheme: scheme)
            let heightBeforePending = scroll.contentSize.height
            host.model.pending = pending(count: 40)
            try await settle(host, "Pending waveforms must also retain automatic following") {
                scroll.contentSize.height > heightBeforePending + 20
                    && self.nearBottom(scroll)
            }
            capture(host, step: "04-pending-preserves-following", scheme: scheme)
            let heightBeforeStop = scroll.contentSize.height
            host.model.pending = .empty
            try await settle(host, "Terminal pending cleanup must preserve following") {
                scroll.contentSize.height < heightBeforeStop - 20
                    && self.nearBottom(scroll)
            }
            capture(host, step: "05-capture-stop-preserves-following", scheme: scheme)
            host.model.pending = pending(count: 64)
            try await settle(host, "Later pending audio must still follow") { self.nearBottom(scroll) }
            capture(host, step: "06-later-pending-follows", scheme: scheme)
        }
    }

    private func row(_ text: String, id: UUID = UUID(), partial: Bool = false,
                     label: Bool = false) -> MeetingLiveBubbleComposer.Row {
        .init(id: id, speaker: .you, text: text, isPartial: partial, showsLabel: label)
    }

    private func wordRows(count: Int) -> [MeetingLiveBubbleComposer.Row] {
        let words = ["Сегодня", "мы", "обсудим", "инструкцию.", "Please", "review", "the", "English", "version.",
                     "Препарат", "и", "дозировка", "указаны", "в", "документе."]
        return (0..<count).map { row(words[$0 % words.count], label: $0 == 0) }
    }

    private func captionScroll(in host: CaptionNativeHost) async throws -> UIScrollView {
        try await settle(host, "The real caption UIScrollView must be attached and scrollable") {
            self.scrollViews(in: host.controller.view).contains {
                $0.window === host.window && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 200
            }
        }
        let candidates = scrollViews(in: host.controller.view).filter {
            $0.window === host.window && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 200
        }
        XCTAssertEqual(candidates.count, 1, "The fixture must inspect the component's only scroll view")
        let scroll = try XCTUnwrap(candidates.first)
        // Fixture-only chrome control: a fading OS indicator must not masquerade as an
        // equal-length text correction in the native-pixel assertion. No app preference changes.
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        return scroll
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func bottomOffset(_ scroll: UIScrollView) -> CGFloat {
        max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    }

    private func nearBottom(_ scroll: UIScrollView) -> Bool {
        abs(bottomOffset(scroll) - scroll.contentOffset.y) < 4
    }

    private func settle(_ host: CaptionNativeHost, _ reason: String,
                        predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var previous: [NativeScrollGeometry]?
        var stableSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.window.layoutIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            let geometry = scrollViews(in: host.controller.view).map {
                NativeScrollGeometry(identity: ObjectIdentifier($0), window: $0.window.map { ObjectIdentifier($0) },
                    bounds: $0.bounds, contentSize: $0.contentSize, contentOffset: $0.contentOffset,
                    inset: $0.adjustedContentInset)
            }
            if predicate(), geometry == previous {
                if let stableSince, now - stableSince >= 0.3 { return }
                if stableSince == nil { stableSince = now }
            } else { stableSince = nil }
            previous = geometry
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print("[NATIVE_CAPTION] timeout=\(reason) geometry=\(String(describing: previous))")
        for native in descendants(in: host.controller.view).compactMap({ $0 as? UITextView }) {
            var kinds: [String] = []
            native.attributedText.enumerateAttribute(.attachment, in: NSRange(location: 0, length: native.attributedText.length)) { value, _, _ in
                if let attachment = value as? NSTextAttachment {
                    kinds.append("\(type(of: attachment)) views=\(attachment.usesTextAttachmentView) type=\(attachment.fileType ?? "nil") bytes=\(attachment.contents?.count ?? -1)")
                }
            }
            print("[INLINE_NATIVE] textKit2=\(native.textLayoutManager != nil) attachments=\(kinds)")
            if let manager = native.textLayoutManager {
                manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
                    print("[INLINE_FRAGMENT] state=\(fragment.state.rawValue) views=\(fragment.textAttachmentViewProviders.count)")
                    return true
                }
            }
        }
        capture(host, step: "timeout", scheme: host.controller.overrideUserInterfaceStyle == .dark ? .dark : .light)
        XCTFail(reason)
        throw CaptionNativeHost.LayoutTimeout()
    }

    private struct NativeScrollGeometry: Equatable {
        let identity: ObjectIdentifier
        let window: ObjectIdentifier?
        let bounds: CGRect
        let contentSize: CGSize
        let contentOffset: CGPoint
        let inset: UIEdgeInsets
    }

    @discardableResult
    private func capture(_ host: CaptionNativeHost, step: String, scheme: ColorScheme) -> UIImage {
        host.window.layoutIfNeeded()
        let caption = scrollViews(in: host.controller.view).first
        let captureBounds = caption.map { $0.convert($0.bounds, to: host.window) } ?? host.window.bounds
        var drewHierarchy = false
        // Crop only the owned caption viewport, preserving native scale and pixels. This
        // bounds evidence memory on older iPads and never draws another window or user data.
        let image = UIGraphicsImageRenderer(size: captureBounds.size).image { context in
            context.cgContext.translateBy(x: -captureBounds.minX, y: -captureBounds.minY)
            drewHierarchy = host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "Capture only the test-owned native window after its layout settled")
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        let appearance = scheme == .dark ? "dark" : "light"
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-\(step)-\(appearance)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}

@MainActor
private final class CaptionNativeRows: ObservableObject {
    @Published var rows: [MeetingLiveBubbleComposer.Row]
    @Published var pending: MeetingPendingSpeechSnapshot = .empty
    @Published var width: CGFloat
    let height: CGFloat

    init(rows: [MeetingLiveBubbleComposer.Row], width: CGFloat, height: CGFloat) {
        self.rows = rows; self.width = width; self.height = height
    }
}

private struct CaptionNativeDocument: View {
    @ObservedObject var model: CaptionNativeRows
    let scheme: ColorScheme
    let documentStyle: Bool

    var body: some View {
        let theme = AppTheme.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme)
        ZStack {
            theme.palette.windowBackground
            MeetingLiveBubbleScrollList(rows: model.rows, pending: model.pending, documentStyle: documentStyle)
                .frame(width: model.width, height: model.height)
                .background(theme.palette.contentBackground)
        }
        .appTheme(theme)
        .environment(\.colorScheme, scheme)
        .environment(\.locale, Locale(identifier: "ru"))
    }
}

@MainActor
private final class CaptionNativeHost {
    struct LayoutTimeout: Error {}
    let model: CaptionNativeRows
    let window: UIWindow
    let controller: UIHostingController<CaptionNativeDocument>
    private weak var previousKeyWindow: UIWindow?

    init(rows: [MeetingLiveBubbleComposer.Row], scheme: ColorScheme, documentStyle: Bool = true) throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }) else { throw XCTSkip("Requires the hosted iOS test app's foreground UIWindowScene") }
        self.previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        self.window = UIWindow(windowScene: scene)
        self.window.frame = scene.coordinateSpace.bounds
        self.model = CaptionNativeRows(rows: rows, width: min(520, scene.coordinateSpace.bounds.width - 48),
                                       height: max(160, min(320, scene.coordinateSpace.bounds.height - 96)))
        self.controller = UIHostingController(rootView: CaptionNativeDocument(model: model, scheme: scheme,
            documentStyle: documentStyle))
        self.controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        self.window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        self.window.rootViewController = controller
        self.window.makeKeyAndVisible()
        self.window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        previousKeyWindow?.makeKey()
    }
}

final class MeetingSavedTranscriptPresentationTests: XCTestCase {
    func testMixedBoutReadsWithTheContinuingParticipantAndPreservesEveryOriginalWord() throws {
        let a = UUID(), b = UUID(), track = UUID()
        var source = session()
        source.state = .completed; source.endedAt = source.startedAt.addingTimeInterval(10)
        source.processingAttempts = [.init(id: UUID(), startedAt: source.startedAt, completedAt: source.endedAt,
                                          stage: .completed, pipelineVersion: 13)]
        source.speakers = [(a, "Участник 2"), (b, "Участник 1")].map {
            .init(id: $0.0, displayName: $0.1, diarizationClusterID: nil, trackKind: .microphone,
                  isLocalUser: false, identityCandidates: [])
        }
        var rows = [segment("Продолжаю", track: track, start: 0, speaker: a, attribution: .assigned),
                    segment("короткая", track: track, start: 0.6),
                    segment("вставка", track: track, start: 1.2, speaker: b, attribution: .assigned),
                    segment("и", track: track, start: 1.8),
                    segment("продолжение.", track: track, start: 2.4, speaker: a, attribution: .assigned)]
        for index in rows.indices { rows[index].revision = 0; rows[index].originalText = nil }
        for index in [1, 3] { rows[index].attributionState = .overlappingSpeakers; rows[index].overlap = .ambiguous }
        source.transcriptSegments = rows
        let original = try MeetingTranscriptExporter.json(for: source)
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: source)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        let paragraph = try XCTUnwrap(paragraphs.first)
        for language in [PichiInterfaceLanguage.english, .russian] {
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: source,
                speakerNames: [a: "Участник 2", b: "Участник 1"], language: language), "Участник 2")
        }
        let presentations = MeetingTranscriptExporter.speakerPresentations(in: source)
        XCTAssertTrue(rows.allSatisfy { presentations[$0.id]?.participantID == a })
        let liveRows = rows.map { MeetingLiveBubbleComposer.Row(id: $0.id, speaker: .you, text: $0.text,
            isPartial: false, showsLabel: true, participant: presentations[$0.id]) }
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(liveRows).count, 1)
        XCTAssertEqual(try MeetingTranscriptExporter.json(for: source), original)
    }

    @MainActor
    func testProtectedLiveHistoryRetainsEveryParticipantBeyondOneHundredWords() async throws {
        let voices = [UUID(), UUID(), UUID()]
        let track = UUID()
        var source = session()
        source.speakers = voices.enumerated().map { index, id in
            .init(id: id, displayName: "Участник \(index + 1)", diarizationClusterID: nil,
                  trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        }
        source.transcriptSegments = (0..<1_200).map { index in
            var word = segment(index == 0 ? "Самое начало встречи." : "Защищённое слово \(index)",
                track: track, start: Double(index) * 0.6,
                speaker: voices[(index / 200) % voices.count], attribution: .assigned)
            word.originalText = nil; word.revision = 0
            return word
        }
        // Active export duration advances with wall time; the persisted source codec must not.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let original = try encoder.encode(source)
        let preview = MeetingLivePartial(id: UUID(), text: "Только защищённый предпросмотр", start: 721)
        let result = try await MeetingSessionCoordinator.protectedLiveHistory(session: source, revision: 8, preview: preview)
        XCTAssertEqual(result.revision, 8)
        XCTAssertEqual(result.utterances.map(\.id), source.transcriptSegments.map(\.id))
        XCTAssertEqual(result.utterances.first?.text, "Самое начало встречи.")
        XCTAssertEqual(Set(result.utterances.compactMap { $0.participant?.participantID }), Set(voices))
        let rows = MeetingLiveBubbleComposer.rows(for: result)
        let paragraphs = try await MeetingLiveCaptionParagraphs.composeForDisplay(rows)
        XCTAssertEqual(paragraphs.flatMap(\.rows).map(\.id), rows.map(\.id))
        XCTAssertEqual(paragraphs.first?.id, source.transcriptSegments.first?.id)
        XCTAssertEqual(result.partials[.you]?.id, preview.id)
        XCTAssertEqual(try encoder.encode(source), original)

        let revised = try await MeetingSessionCoordinator.protectedLiveHistory(session: source, revision: 9, preview: nil)
        XCTAssertEqual(revised.utterances.map(\.id), result.utterances.map(\.id))
        XCTAssertTrue(revised.partials.isEmpty, "Finishing the preview cannot erase approved history")
        let cancelled = Task {
            try await MeetingSessionCoordinator.protectedLiveHistory(session: source, revision: 10, preview: nil)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("A cancelled projection published a new history") }
        catch is CancellationError { }
    }

    func testReadingCacheIgnoresMetersButInvalidatesAliasesWordsAndEvidence() {
        var source = session()
        source.speakers = [.init(id: UUID(), displayName: "Анна", diarizationClusterID: nil,
                                trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        source.transcriptSegments = [segment("Защищённый текст.", track: UUID(), start: 0,
                                            speaker: source.speakers[0].id, attribution: .assigned)]
        let original = MeetingTranscriptExporter.ReadingInput(source)
        var changed = source
        changed.title = "Другое название"; changed.updatedAt = source.updatedAt.addingTimeInterval(1)
        changed.events = [.init(id: UUID(), occurredAt: Date(), kind: .microphoneChanged,
                               trackID: nil, detail: "Synthetic capture health event")]
        XCTAssertEqual(MeetingTranscriptExporter.ReadingInput(changed), original)
        changed.speakers[0].displayName = "Борис"
        XCTAssertNotEqual(MeetingTranscriptExporter.ReadingInput(changed), original)
        changed = source; changed.transcriptSegments[0].text = "Исправленный текст."
        XCTAssertNotEqual(MeetingTranscriptExporter.ReadingInput(changed), original)
        changed = source; changed.transcriptSegments[0].attributionState = .timingUncertain
        XCTAssertNotEqual(MeetingTranscriptExporter.ReadingInput(changed), original)
        changed = source; changed.transcriptCoverageGaps = []
        XCTAssertNotEqual(MeetingTranscriptExporter.ReadingInput(changed), original)
    }

    func testNoMultipleVoiceLabelWhenThereIsNoSingleReadingOwner() {
        for (language, expected) in [(PichiInterfaceLanguage.english, "Unknown speaker"), (.russian, "Неизвестный участник")] {
            let value = MeetingSpeakerPresentation(identity: "historical-multiple", label: .candidates([], relation: .several))
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: value, language: language), expected)
        }
    }
    private func session() -> MeetingSession {
        MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic transcript",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil))
    }

    private func segment(_ text: String, track: UUID, start: Double, speaker: UUID? = nil,
                         attribution: MeetingTranscriptAttributionState = .unassigned) -> MeetingTranscriptSegment {
        .init(id: UUID(), start: .init(value: Int64(start * 1000), timescale: 1000),
              end: .init(value: Int64((start + 0.4) * 1000), timescale: 1000), sourceTrackID: track,
              speakerID: speaker, text: text, originalText: "Synthetic original", revision: 2,
              status: .final, overlap: .none, completeness: .complete, attributionState: attribution)
    }

    func testLegacyIncomingTurnKeepsItsShortUnknownPrefixAndPlainParticipantLabel() throws {
        let track = UUID(), outgoing = UUID(), incoming = UUID()
        var source = session()
        source.state = .completed; source.endedAt = source.startedAt.addingTimeInterval(700)
        source.processingAttempts = [.init(id: UUID(), startedAt: source.startedAt, completedAt: source.endedAt,
            stage: .completed, pipelineVersion: 13)]
        source.speakers = [(outgoing, "Анна"), (incoming, "Борис")].map {
            .init(id: $0.0, displayName: $0.1, diarizationClusterID: nil, trackKind: .microphone,
                  isLocalUser: false, identityCandidates: [])
        }
        var rows = [segment("Вопрос?", track: track, start: 608.4, speaker: outgoing, attribution: .assigned),
                    segment("Нет, это", track: track, start: 609.28),
                    segment("ответ.", track: track, start: 609.84, speaker: incoming, attribution: .assigned)]
        for index in rows.indices { rows[index].revision = 0; rows[index].originalText = nil }
        source.transcriptSegments = rows
        let before = try MeetingTranscriptExporter.json(for: source)
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: source)
        XCTAssertEqual(paragraphs.count, 2)
        let paragraph = try XCTUnwrap(paragraphs.last)
        XCTAssertEqual(paragraph.text, "Нет, это ответ.")
        XCTAssertEqual(paragraph.firstSegment.id, rows[1].id)
        XCTAssertNil(paragraph.firstSegment.speakerID)
        XCTAssertEqual(paragraph.projectedSpeakerID, incoming)
        XCTAssertEqual(paragraph.firstSegment.start, rows[1].start)
        for language in [PichiInterfaceLanguage.english, .russian] {
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: source,
                speakerNames: [outgoing: "Анна", incoming: "Борис"], language: language), "Борис")
        }
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        XCTAssertEqual(try MeetingTranscriptExporter.json(for: source), before)
    }

    func testLegacyOrphanWordsReadWithinTheirSameSpeakerTurnInBothLanguages() throws {
        let track = UUID(), speaker = UUID()
        var source = session()
        source.state = .completed; source.endedAt = source.startedAt.addingTimeInterval(3600)
        source.speakers = [.init(id: speaker, displayName: "Анна", diarizationClusterID: nil,
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        source.processingAttempts = [.init(id: UUID(), startedAt: source.startedAt, completedAt: source.endedAt,
            stage: .completed, pipelineVersion: 13)]
        func legacy(_ text: String, start: Double, end: Double, identified: Bool) -> MeetingTranscriptSegment {
            var row = segment(text, track: track, start: start, speaker: identified ? speaker : nil,
                              attribution: identified ? .assigned : .unassigned)
            row.end = .init(value: Int64((end * 1000).rounded()), timescale: 1000)
            row.originalText = nil; row.revision = 0
            return row
        }
        let cases = [(2.96, 3.28, 3.32, 3.44), (17.52, 17.64, 17.68, 17.84),
                     (69.32, 69.88, 69.92, 70.04), (97.80, 97.88, 97.92, 98.40),
                     (340.04, 341.04, 341.08, 341.28), (1577.32, 1580.0, 1580.48, 1580.84),
                     (2459.40, 2459.56, 2459.80, 2461.32)]
        for (before, start, end, after) in cases {
            let rows = [legacy("Начало", start: before - 0.1, end: before, identified: true),
                        legacy("и", start: start, end: end, identified: false),
                        legacy("продолжение.", start: after, end: after + 0.1, identified: true)]
            source.transcriptSegments = rows
            let original = source
            let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: source)
            XCTAssertEqual(paragraphs.count, 1)
            let paragraph = try XCTUnwrap(paragraphs.first)
            XCTAssertEqual(paragraph.text, "Начало и продолжение.")
            XCTAssertTrue(paragraph.containsLegacySpeakerBridge)
            XCTAssertEqual(paragraph.segments, rows)
            XCTAssertNil(paragraph.segments[1].speakerID)
            XCTAssertNil(paragraph.segments[1].nativePrecision)
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: source,
                speakerNames: [speaker: "Анна"], language: .english), "Анна")
            XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: source,
                speakerNames: [speaker: "Анна"], language: .russian), "Анна")
            XCTAssertEqual(source, original)
            XCTAssertEqual(try MeetingTranscriptExporter.json(for: source), try MeetingTranscriptExporter.json(for: original))
            var manual = rows; manual[1].revision += 1
            XCTAssertEqual(MeetingTranscriptExporter.displayParagraphs(for: manual, in: source).count, 3)
            var current = source; current.processingAttempts[0].pipelineVersion = 15
            XCTAssertEqual(MeetingTranscriptExporter.displayParagraphs(for: rows, in: current).count, 3)
            var enclosing = legacy("Enclosing envelope", start: before - 0.2, end: after + 1, identified: true)
            enclosing.isLikelyEcho = true
            var hiddenOverlap = source; hiddenOverlap.transcriptSegments.insert(enclosing, at: 0)
            let blocked = MeetingTranscriptExporter.displayParagraphs(for: rows, in: hiddenOverlap)
            XCTAssertEqual(blocked.count, 3)
            XCTAssertFalse(blocked.contains(where: \.containsLegacySpeakerBridge),
                "An earlier hidden envelope remains a temporal barrier after echo filtering")
        }
    }

    func testCurrentNeighborRuleDoesNotSplitTheSameForegroundTurn() throws {
        let track = UUID(), speaker = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "speaker")
        var source = session()
        source.speakers = [.init(id: speaker, displayName: "Анна", diarizationClusterID: nil,
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        var rows = [segment("Начало", track: track, start: 0, speaker: speaker, attribution: .assigned),
                    segment("и", track: track, start: 0.5, speaker: speaker, attribution: .assigned),
                    segment("конец.", track: track, start: 1, speaker: speaker, attribution: .assigned)]
        let decision = MeetingSpeakerAttributionDecision(unitID: "synthetic-word", rawAssignment: .unassigned,
            candidates: [], activeSupportSeconds: 0, simultaneousIntervals: [], relation: .none,
            selectedToken: token, rule: .neighborAgreement, cueUnitIDs: [], backgroundTokens: [],
            policyVersion: 2, policyFingerprint: MeetingSpeakerAttributionPolicy.standard.fingerprint)
        rows[1].speakerAttribution = .init(decision: decision, speakerIDs: [token: speaker])
        source.transcriptSegments = rows
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: source)
        XCTAssertEqual(paragraphs.count, 1)
        let paragraph = try XCTUnwrap(paragraphs.first)
        XCTAssertFalse(paragraph.containsLegacySpeakerBridge)
        XCTAssertEqual(paragraph.segments, rows)
        XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: source,
            speakerNames: [speaker: "Анна"], language: .english), "Анна")
        XCTAssertEqual(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: source,
            speakerNames: [speaker: "Анна"], language: .russian), "Анна")
        XCTAssertEqual(MeetingTranscriptExporter.displayRows(for: rows, in: source).map(\.showsLabel), [true, true, true],
            "The evidence/correction row projection still describes each changed attribution")
    }

    func testWordFragmentsReadAsParagraphWithoutRewritingEvidence() {
        let track = UUID()
        let words = ["Здравствуйте", ",", "давайте", "обсудим", "[PERSON]", ".", "English", "response", "."]
        let rows = words.enumerated().map { segment($0.element, track: track, start: Double($0.offset) / 2) }
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session())
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "Здравствуйте, давайте обсудим [PERSON]. English response.")
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        XCTAssertEqual(paragraphs[0].id, rows[0].id)
        XCTAssertEqual(paragraphs[0].firstSegment.start, rows[0].start)
    }

    func testUnknownAttributionStatesFlowWithoutInventingASpeaker() {
        let track = UUID()
        var rows = [segment("Слова", track: track, start: 0),
                    segment("при", track: track, start: 0.5, attribution: .overlappingSpeakers),
                    segment("неуверенном", track: track, start: 1, attribution: .timingUncertain),
                    segment("времени.", track: track, start: 1.5)]
        rows[1].overlap = .ambiguous
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session())
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "Слова при неуверенном времени.")
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        XCTAssertTrue(paragraphs[0].segments.allSatisfy { $0.speakerID == nil })
        XCTAssertEqual(paragraphs[0].segments.map(\.attributionState), rows.map(\.attributionState))
    }

    func testActualSpeakerIDsAndKnownToUnknownStateRemainBoundaries() {
        let track = UUID(), firstID = UUID(), secondID = UUID()
        var source = session()
        source.speakers = [firstID, secondID].map {
            .init(id: $0, displayName: "Same visible name", diarizationClusterID: nil, trackKind: .microphone,
                  isLocalUser: false, identityCandidates: [])
        }
        let rows = [segment("First", track: track, start: 0, speaker: firstID, attribution: .assigned),
                    segment("second", track: track, start: 0.5, speaker: secondID, attribution: .assigned),
                    segment("uncertain", track: track, start: 1, speaker: secondID, attribution: .timingUncertain),
                    segment("unknown", track: track, start: 1.5)]
        XCTAssertEqual(MeetingTranscriptExporter.displayParagraphs(for: rows, in: source).map(\.segments), rows.map { [$0] })
    }

    func testSourceStatusAndCompletenessBoundariesRemainExplicit() {
        let track = UUID()
        var rows = [segment("Source", track: track, start: 0), segment("change", track: UUID(), start: 0.5),
                    segment("status", track: track, start: 1), segment("completeness", track: track, start: 1.5),
                    segment("pause", track: track, start: 6)]
        rows[2].status = .provisional
        rows[3].completeness = .incompleteTrack
        XCTAssertEqual(MeetingTranscriptExporter.displayParagraphs(for: rows, in: session()).count, rows.count)
    }

    func testLongMonologueAndExplicitNewlinesRemainOneLosslessSpeakerTurn() {
        let track = UUID(), speaker = UUID()
        var rows = (0..<600).map {
            segment("слово\($0)", track: track, start: Double($0) * 2, speaker: speaker, attribution: .assigned)
        }
        rows[80].text += "\n"
        rows[300].text += "."
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session())
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        XCTAssertTrue(paragraphs[0].text.contains("слово80\nслово81"))
        XCTAssertTrue(paragraphs[0].text.contains("слово300. слово301"))
        XCTAssertEqual(paragraphs[0].id, rows[0].id)
        XCTAssertGreaterThan(paragraphs[0].text.count, 4_000)
        XCTAssertTrue(MeetingTranscriptExporter.displayParagraphs(for: [], in: session()).isEmpty)
    }

    func testReturningSpeakerStartsANewTurnAndUnknownWordsDoNotInheritIdentity() {
        let track = UUID(), firstID = UUID(), secondID = UUID()
        let rows = [segment("First speaker", track: track, start: 0, speaker: firstID, attribution: .assigned),
                    segment("still speaking", track: track, start: 20, speaker: firstID, attribution: .assigned),
                    segment("Second speaker", track: track, start: 21, speaker: secondID, attribution: .assigned),
                    segment("First speaker returns", track: track, start: 22, speaker: firstID, attribution: .assigned),
                    segment("to", track: track, start: 23),
                    segment("First speaker again", track: track, start: 24, speaker: firstID, attribution: .assigned)]
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session())
        XCTAssertEqual(paragraphs.map(\.segments), [Array(rows[0...1]), [rows[2]], [rows[3]], [rows[4]], [rows[5]]])
        XCTAssertNil(paragraphs[3].firstSegment.speakerID)
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
    }

    func testLongTurnPlaybackCoversEveryMemberAfterAPause() throws {
        let track = UUID(), speaker = UUID()
        let rows = (0..<300).map {
            segment("слово\($0)", track: track, start: Double($0) * 4, speaker: speaker, attribution: .assigned)
        }
        var source = session(); source.transcriptSegments = rows
        let paragraph = try XCTUnwrap(MeetingTranscriptExporter.displayParagraphs(for: rows, in: source).first)
        let interval = try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: paragraph.segments.map(\.id))
        XCTAssertEqual(interval.id, rows[0].id)
        XCTAssertEqual(interval.start, rows[0].start)
        XCTAssertEqual(interval.end, rows.last?.end)
        XCTAssertEqual(source.transcriptSegments, rows)
    }

    func testCorrectionReprojectsOnlyTheChangedMemberAndRetainsItsEvidence() {
        let track = UUID(), speaker = UUID()
        let rows = [segment("First", track: track, start: 0, speaker: speaker, attribution: .assigned),
                    segment("word.", track: track, start: 120, speaker: speaker, attribution: .assigned)]
        var corrected = rows
        corrected[1].text = "correction."
        corrected[1].revision += 1
        let paragraph = MeetingTranscriptExporter.displayParagraphs(for: corrected, in: session())[0]
        XCTAssertEqual(paragraph.text, "First correction.")
        XCTAssertEqual(paragraph.segments.map(\.id), rows.map(\.id))
        XCTAssertEqual(paragraph.segments.map(\.start), rows.map(\.start))
        XCTAssertEqual(paragraph.segments.map(\.end), rows.map(\.end))
        XCTAssertEqual(paragraph.segments.map(\.originalText), rows.map(\.originalText))
        XCTAssertEqual(paragraph.segments.map(\.revision), [rows[0].revision, rows[1].revision + 1])
        XCTAssertEqual(corrected[0], rows[0])
    }

    func testParagraphPlaybackStartsAtFirstWordAndCoversEveryMember() throws {
        let track = UUID()
        let rows = [segment("One", track: track, start: 4), segment("two", track: track, start: 4.5),
                    segment("three.", track: track, start: 5)]
        var source = session(); source.transcriptSegments = rows
        let range = try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows.map(\.id))
        XCTAssertEqual(range.id, rows[0].id)
        XCTAssertEqual(range.sourceTrackID, track)
        XCTAssertEqual(range.start, rows[0].start)
        XCTAssertEqual(range.end, rows.last?.end)
        XCTAssertEqual(source.transcriptSegments, rows)
        XCTAssertEqual(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: [rows[1].id]), rows[1])
    }

    func testParagraphPlaybackRefusesStaleOrCrossBoundaryMemberSelections() throws {
        let track = UUID()
        let rows = [segment("One", track: track, start: 0), segment("two", track: track, start: 0.5)]
        var source = session(); source.transcriptSegments = rows
        for ids in [[], [UUID()], [rows[0].id, rows[0].id], rows.map(\.id).reversed().map { $0 }, [rows[0].id, UUID()]] {
            XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: ids))
        }
        source.transcriptSegments[1].attributionState = .assigned
        source.transcriptSegments[1].speakerID = UUID()
        XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows.map(\.id)))
        source.transcriptSegments = rows
        source.transcriptSegments[1].sourceTrackID = UUID()
        XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows.map(\.id)))
    }
}
