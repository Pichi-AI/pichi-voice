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
}
