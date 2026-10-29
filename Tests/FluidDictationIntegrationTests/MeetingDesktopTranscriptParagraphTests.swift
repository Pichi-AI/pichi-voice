import Foundation
@testable import FluidVoice_Debug
import XCTest

final class MeetingDesktopTranscriptParagraphTests: XCTestCase {
    private func session() -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic reading fixture",
            languageCode: "ru", microphone: .init(captureDeviceID: "fixture", displayName: "Fixture"))
        var session = MeetingSession(configuration: configuration, startedAt: Date(timeIntervalSince1970: 0),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                            firstPresentationTime: nil))
        session.state = .completed
        session.endedAt = Date(timeIntervalSince1970: 60)
        session.speakers = (0..<2).map { _ in
            .init(id: UUID(), displayName: "Same name", diarizationClusterID: nil,
                  trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        }
        let track = UUID()
        session.transcriptSegments = ["Привет", ",", "обсудим", "план.", "Да.", "Продолжим."].enumerated().map { index, text in
            .init(id: UUID(), start: .init(value: Int64(index * 500), timescale: 1000),
                  end: .init(value: Int64(index * 500 + 400), timescale: 1000), sourceTrackID: track,
                  speakerID: session.speakers[index == 4 ? 1 : 0].id, text: text, revision: 0,
                  status: .final, overlap: .none, completeness: .complete, attributionState: .assigned,
                  nativePrecision: .word, nativeUnitID: "synthetic-word-\(index)",
                  nativeTiming: .init(start: Double(index) / 2, end: Double(index) / 2 + 0.4))
        }
        return session
    }

    private func projection(_ session: MeetingSession) async throws -> MeetingResultTranscriptProjection {
        let paragraphs = try await MeetingTranscriptExporter.readingParagraphs(for: session)
        return MeetingResultTranscriptProjection(session: session, paragraphs: paragraphs)
    }

    func testDesktopRowsGroupWordsAndKeepGenuineOneWordReply() async throws {
        let source = self.session()
        let projection = try await self.projection(source)
        let rows = projection.rows(matching: .init(source), includeEchoes: false)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map { $0.paragraph.text }, ["Привет, обсудим план.", "Да.", "Продолжим."])
        XCTAssertEqual(rows.map(\.memberIDs), [Array(source.transcriptSegments.prefix(4).map(\.id)),
            [source.transcriptSegments[4].id], [source.transcriptSegments[5].id]])
        XCTAssertEqual(rows.flatMap { $0.paragraph.segments }, source.transcriptSegments)
        XCTAssertEqual(rows[0].presentation.participantID, source.speakers[0].id)
        XCTAssertEqual(rows[1].presentation.participantID, source.speakers[1].id,
                       "Equal display names cannot collapse different participants")
        let interval = try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows[0].memberIDs)
        XCTAssertEqual(interval.start, source.transcriptSegments[0].start)
        XCTAssertEqual(interval.end, source.transcriptSegments[3].end)
    }

    func testRetiredSessionOrEditedSourceCannotRenderCachedRows() async throws {
        let source = self.session(), projection = try await self.projection(source)
        var changed = source
        changed.id = UUID()
        XCTAssertTrue(projection.rows(matching: .init(changed), includeEchoes: false).isEmpty)
        changed = source
        changed.transcriptSegments[0].revision += 1
        changed.transcriptSegments[0].text = "Changed"
        XCTAssertTrue(projection.rows(matching: .init(changed), includeEchoes: true).isEmpty)
        changed = source
        changed.title = "Title changes do not change transcript membership"
        XCTAssertEqual(projection.rows(matching: .init(changed), includeEchoes: false).count, 3)
    }

    func testEchoEvidenceViewKeepsOriginalOrderAndSingleMemberPlayback() async throws {
        var source = self.session()
        var echo = source.transcriptSegments[0]
        echo.id = UUID(); echo.text = "Echo"; echo.isLikelyEcho = true
        echo.start = .init(value: 450, timescale: 1000)
        echo.end = .init(value: 490, timescale: 1000)
        source.transcriptSegments.insert(echo, at: 1)
        let projection = try await self.projection(source)
        let reading = projection.rows(matching: .init(source), includeEchoes: false)
        XCTAssertEqual(reading.count, 3)
        XCTAssertFalse(reading.flatMap(\.memberIDs).contains(echo.id))
        let evidence = projection.rows(matching: .init(source), includeEchoes: true)
        XCTAssertEqual(evidence.map(\.id), source.transcriptSegments.map(\.id))
        for row in evidence {
            XCTAssertEqual(row.memberIDs, [row.id])
            XCTAssertEqual(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: row.memberIDs),
                           row.paragraph.firstSegment)
        }
        XCTAssertEqual(projection.rows(matching: .init(source), includeEchoes: false), reading)
    }

    func testMemberSearchKeepsCapturedRevisionAndDoesNotMutateParagraph() async throws {
        let source = self.session(), projection = try await self.projection(source)
        let paragraph = try XCTUnwrap(projection.rows(matching: .init(source), includeEchoes: false).first?.paragraph)
        let selection = MeetingTranscriptMemberSelection(paragraph: paragraph, purpose: .editText)
        XCTAssertEqual(selection.members(matching: "ОБСУДИМ"), [source.transcriptSegments[2]])
        XCTAssertEqual(selection.members(matching: "   "), paragraph.segments)
        XCTAssertEqual(selection.member(id: source.transcriptSegments[2].id)?.revision,
                       source.transcriptSegments[2].revision)
        XCTAssertNil(selection.member(id: source.transcriptSegments[5].id),
                     "Another paragraph's member cannot enter this edit draft")
        XCTAssertEqual(selection.paragraph.segments, Array(source.transcriptSegments.prefix(4)))
        XCTAssertEqual(paragraph.segments, Array(source.transcriptSegments.prefix(4)),
                       "Searching or abandoning a selection is presentation-only")
    }
}
