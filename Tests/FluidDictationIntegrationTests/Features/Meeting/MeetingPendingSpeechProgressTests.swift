import Foundation
@testable import FluidVoice_Debug
import XCTest

final class MeetingPendingSpeechProgressTests: XCTestCase {
    private func speech(_ projection: inout MeetingPendingSpeechProjection, source: MeetingLiveSpeaker = .you,
                        start: Double, duration: Double) {
        for index in 0..<Int((duration / 0.02).rounded()) {
            let time = start + Double(index) * 0.02
            projection.observeSpeechActivity(source: source, start: time, end: time + 0.02, activity: .speech)
        }
    }

    private func admit(_ projection: inout MeetingPendingSpeechProjection, revision: UInt64 = 1) {
        var visible = MeetingLiveTranscriptSnapshot.empty
        visible.revision = revision
        projection.reconcile(visible: visible)
    }

    func testMeasuredCoverageAfterMultipleSwitchesIsSourceScoped() {
        var projection = MeetingPendingSpeechProjection()
        for source in [MeetingLiveSpeaker.you, .them] {
            speech(&projection, source: source, start: 0, duration: 2)
            speech(&projection, source: source, start: 4, duration: 2)
            speech(&projection, source: source, start: 10, duration: 2)
        }
        let application = projection.snapshot.tokens.filter { $0.source == .them }
        admit(&projection)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<2, 4..<6], transcriptRevision: 1)
        XCTAssertEqual(projection.snapshot.tokens.filter { $0.source == .them }, application)
        XCTAssertTrue(projection.snapshot.tokens.filter { $0.source == .you }.allSatisfy { $0.start >= 10 - 0.000_001 })
        projection.acknowledgeProtectedIntervals(source: .them, intervals: [0..<2, 4..<6], transcriptRevision: 1)
        XCTAssertFalse(projection.snapshot.tokens.isEmpty)
        XCTAssertTrue(projection.snapshot.tokens.allSatisfy { $0.start >= 10 - 0.000_001 }, "Later queued speech survives both acknowledgements")
    }

    func testCoalescedWaveRetiresItsMeasuredIslandsWithoutInventingGapCoverage() {
        var projection = MeetingPendingSpeechProjection()
        for index in 0..<90 { speech(&projection, start: Double(index), duration: 0.8) }
        XCTAssertEqual(projection.snapshot.tokens.count, MeetingPendingSpeechProjection.maximumTokens)
        let lastID = projection.snapshot.tokens.last!.id
        admit(&projection)
        projection.acknowledgeProtectedIntervals(source: .you,
            intervals: (0..<45).map { Double($0)..<(Double($0) + 0.8) }, transcriptRevision: 1)
        XCTAssertEqual(projection.snapshot.tokens.last?.id, lastID)
        projection.acknowledgeProtectedIntervals(source: .you,
            intervals: (45..<90).map { Double($0)..<(Double($0) + 0.8) }, transcriptRevision: 1)
        XCTAssertTrue(projection.snapshot.tokens.isEmpty, "A display envelope must not retain a fictitious wave for a missing PCM gap")
    }

    func testFragmentedAcknowledgementsStayBoundedAndCommitAtomically() {
        let overflow = expectation(description: "Fragmented coverage reports capacity")
        overflow.assertForOverFulfill = false
        var projection = MeetingPendingSpeechProjection(maximumIntervals: 4, diagnostics: { event in
            if event.kind == .capacityReached { overflow.fulfill() }
        })
        // Scalar-only observations fill 64 views; the final view coalesces later speech.
        speech(&projection, start: 0, duration: 30)
        XCTAssertEqual(projection.snapshot.tokens.count, MeetingPendingSpeechProjection.maximumTokens)
        let coalescedID = projection.snapshot.tokens.last!.id
        admit(&projection)
        for start in [26.0, 27.0, 28.0] {
            projection.acknowledgeProtectedIntervals(source: .you, intervals: [start..<(start + 0.1)], transcriptRevision: 1)
        }
        XCTAssertEqual(projection.retainedIntervalCounts.max(), 4)
        let bounded = projection.snapshot
        // The first interval could trim another token, but the second would exceed
        // the coalesced token's budget. Reject the whole ACK, including that trim.
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<0.2, 29..<29.1], transcriptRevision: 1)
        for index in 0..<20 {
            let start = 29.2 + Double(index) * 0.03
            projection.acknowledgeResolvedAudio(source: .you, start: start, end: start + 0.01)
        }
        XCTAssertEqual(projection.snapshot, bounded)
        XCTAssertEqual(projection.snapshot.tokens.last?.id, coalescedID)
        XCTAssertTrue(projection.retainedIntervalCounts.allSatisfy { $0 <= 4 })
        wait(for: [overflow], timeout: 0)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<30], transcriptRevision: 1)
        XCTAssertTrue(projection.snapshot.tokens.isEmpty, "A broader confirmed ACK can still retire all retained proof")
        XCTAssertTrue(projection.retainedIntervalCounts.allSatisfy { $0 == 0 })

        // Apply the same bound to cadence debt before its first visible token exists.
        var pending = MeetingPendingSpeechProjection(maximumIntervals: 3)
        admit(&pending)
        speech(&pending, start: 0, duration: 0.38)
        pending.acknowledgeProtectedIntervals(source: .you, intervals: [0.05..<0.06, 0.1..<0.11], transcriptRevision: 1)
        XCTAssertEqual(pending.retainedIntervalCounts.max(), 3)
        pending.acknowledgeResolvedAudio(source: .you, start: 0.15, end: 0.16)
        XCTAssertTrue(pending.retainedIntervalCounts.allSatisfy { $0 <= 3 })
        speech(&pending, start: 0.38, duration: 0.04)
        XCTAssertEqual(pending.snapshot.tokens.count, 1, "Overflow cannot consume unacknowledged cadence debt")
        pending.acknowledgeProtectedIntervals(source: .you, intervals: [0..<1], transcriptRevision: 1)
        XCTAssertTrue(pending.snapshot.tokens.isEmpty)
    }

    func testDelayedVADCannotRecreateProcessedAudioOrHideAnUnknownGap() {
        var projection = MeetingPendingSpeechProjection()
        admit(&projection)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<2, 4..<6], transcriptRevision: 1)
        speech(&projection, start: 0, duration: 6)
        XCTAssertFalse(projection.snapshot.tokens.isEmpty)
        XCTAssertTrue(projection.snapshot.tokens.allSatisfy { $0.start >= 2 - 0.000_001 && $0.end <= 4 + 0.000_001 },
                      "Only the unacknowledged gap can create new estimates")
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [2..<4], transcriptRevision: 1)
        XCTAssertTrue(projection.snapshot.tokens.isEmpty)
        speech(&projection, start: 6, duration: 0.2)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [6..<6.1], transcriptRevision: 1)
        speech(&projection, start: 6.2, duration: 0.2)
        XCTAssertTrue(projection.snapshot.tokens.isEmpty, "Processed cadence debt cannot mint another word-shaped estimate")
        speech(&projection, start: 6.4, duration: 0.1)
        XCTAssertEqual(projection.snapshot.tokens.count, 1)
        XCTAssertEqual(projection.snapshot.tokens[0].start, 6.1, accuracy: 0.000_001)
    }

    func testStaleInvalidAndStoppedCoverageCannotRetireSpeech() {
        var projection = MeetingPendingSpeechProjection()
        speech(&projection, start: 0, duration: 2)
        let original = projection.snapshot.tokens
        admit(&projection, revision: 2)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<2], transcriptRevision: 1)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<1, -1..<2], transcriptRevision: 2)
        projection.acknowledgeProtectedIntervals(source: .them, intervals: [0..<2], transcriptRevision: 2)
        XCTAssertEqual(projection.snapshot.tokens, original)
        projection.stop()
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<2], transcriptRevision: 2)
        speech(&projection, start: 3, duration: 2)
        XCTAssertTrue(projection.snapshot.tokens.isEmpty)
        XCTAssertFalse(projection.snapshot.isCapturing)
    }

    func testVisibleWordCoverageKeepsIdentityAndRetiresInternalSupport() {
        var projection = MeetingPendingSpeechProjection()
        speech(&projection, start: 0, duration: 1.2)
        let first = projection.snapshot.tokens.first!
        var visible = MeetingLiveTranscriptSnapshot.empty
        visible.revision = 1
        visible.partials[.you] = .init(id: UUID(), text: "approved", start: 0.1, end: 0.3)
        projection.reconcile(visible: visible)
        XCTAssertEqual(projection.snapshot.tokens.first?.id, first.id)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0..<0.1], transcriptRevision: 1)
        XCTAssertEqual(projection.snapshot.tokens.first!.start, 0.3, accuracy: 0.000_001)
        projection.acknowledgeProtectedIntervals(source: .you, intervals: [0.3..<0.4], transcriptRevision: 1)
        XCTAssertFalse(projection.snapshot.tokens.contains { $0.id == first.id }, "Covered middle audio cannot remain after both edges retire")
    }

    func testSourceTimelineMapsOnlyMeasuredAudioWithLeadingDelayAndRouteGaps() throws {
        let timeline = try MeetingPCMSourceTimeline(originSeconds: 100)
        try timeline.record(sourceStartSample: 0, frameCount: 16_000, presentationTime: 110)
        try timeline.record(sourceStartSample: 16_000, frameCount: 8_000, presentationTime: 113)
        try timeline.record(sourceStartSample: 24_000, frameCount: 16_000, presentationTime: 114)
        XCTAssertEqual(try timeline.measuredIntervals(fromSample: 8_000, throughSample: 32_000),
                       [10.5..<11, 13..<13.5, 14..<14.5])
        XCTAssertThrowsError(try timeline.measuredIntervals(fromSample: -1, throughSample: 40_000))
        XCTAssertThrowsError(try timeline.measuredIntervals(fromSample: 0, throughSample: 40_001))
        timeline.discard(beforeSample: 24_000)
        XCTAssertEqual(try timeline.measuredIntervals(fromSample: 24_000, throughSample: 40_000), [14..<15])
    }

    func testInRoomTimelineBindsOnlyTheFirstValidMeasuredPacket() throws {
        let timeline = try MeetingPCMSourceTimeline()
        XCTAssertThrowsError(try timeline.record(sourceStartSample: 0, frameCount: 16_000, presentationTime: .nan))
        try timeline.record(sourceStartSample: 0, frameCount: 16_000, presentationTime: 600)
        try timeline.record(sourceStartSample: 16_000, frameCount: 16_000, presentationTime: 603)
        XCTAssertEqual(try timeline.measuredIntervals(fromSample: 0, throughSample: 32_000), [0..<1, 3..<4])
        XCTAssertNil(timeline.mapInterval(start: 0.5, end: 1.5), "A negative VAD query must not bridge an unknown source gap")
    }
}
