import Foundation
import XCTest
@testable import PichiVoiceMobile

/// The recording Live Activity follows only the coordinator's capture states. ActivityKit itself is
/// not exercised here; these are the decisions the owner applies to it.
final class MobileRecordingActivityPlanTests: XCTestCase {
    private func session(startedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic meeting",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture"))
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        return MeetingSession(configuration: configuration, startedAt: startedAt, timebase: timebase)
    }

    func testRecordingStartsOnceAndIgnoresRepeatsAndDegradedCapture() throws {
        let session = session()
        var plan = MobileRecordingActivityPlan()
        let recording = try XCTUnwrap(MobileRecordingActivityPlan.recording(state: .recording(session.id), session: session))
        XCTAssertEqual(recording, .init(sessionID: session.id, startedAt: session.startedAt, mode: .inRoom))

        XCTAssertEqual(plan.update(recording), [.start(recording)])
        XCTAssertEqual(plan.update(recording), [])
        // A degraded recording is still capturing and keeps the same activity.
        let degraded = MobileRecordingActivityPlan.recording(state: .recordingDegraded(session.id), session: session)
        XCTAssertEqual(degraded, recording)
        XCTAssertEqual(plan.update(degraded), [])
        XCTAssertEqual(plan.sessionID, session.id)
    }

    func testPreparationAndMismatchedSessionsDoNotStart() {
        let session = session()
        XCTAssertNil(MobileRecordingActivityPlan.recording(state: .preparing(session.id), session: session))
        XCTAssertNil(MobileRecordingActivityPlan.recording(state: .recording(session.id), session: nil))
        XCTAssertNil(MobileRecordingActivityPlan.recording(state: .recording(UUID()), session: session))
        var plan = MobileRecordingActivityPlan()
        XCTAssertEqual(plan.update(nil), [])
        XCTAssertNil(plan.sessionID)
    }

    func testStopFailureInterruptionAndDiscardEndTheActivity() {
        let session = session()
        let failure = MeetingSessionFailure(id: UUID(), occurredAt: Date(), domain: .capture,
            code: "synthetic", message: "Synthetic failure", recoverable: false)
        let exits: [MeetingCoordinatorState] = [
            .stopping(session.id), .processing(session.id, .transcribing), .completed(session.id),
            .interrupted(session.id), .failed(session.id, failure), .failed(nil, failure), .idle,
        ]
        for state in exits {
            var plan = MobileRecordingActivityPlan()
            let recording = MobileRecordingActivityPlan.recording(state: .recording(session.id), session: session)
            XCTAssertEqual(plan.update(recording).count, 1)
            let desired = MobileRecordingActivityPlan.recording(state: state, session: session)
            XCTAssertNil(desired, "\(state)")
            XCTAssertEqual(plan.update(desired), [.end(session.id)], "\(state)")
            XCTAssertEqual(plan.update(desired), [], "\(state)")
            XCTAssertNil(plan.sessionID)
        }
    }

    func testRefusedRequestIsNotRetriedAndStillEndsItsSession() throws {
        let session = session()
        var plan = MobileRecordingActivityPlan()
        let recording = try XCTUnwrap(MobileRecordingActivityPlan.recording(state: .recording(session.id), session: session))
        // The system may refuse the start, for example on iPad. Later state changes do not retry.
        XCTAssertEqual(plan.update(recording), [.start(recording)])
        XCTAssertEqual(plan.update(recording), [])
        XCTAssertEqual(plan.update(nil), [.end(session.id)])
    }

    func testNewSessionEndsThePreviousActivityFirst() throws {
        let first = session(), second = session(startedAt: Date(timeIntervalSince1970: 1_800_000_600))
        var plan = MobileRecordingActivityPlan()
        let firstRecording = try XCTUnwrap(MobileRecordingActivityPlan.recording(state: .recording(first.id), session: first))
        let secondRecording = try XCTUnwrap(MobileRecordingActivityPlan.recording(state: .recording(second.id), session: second))
        XCTAssertEqual(plan.update(firstRecording), [.start(firstRecording)])
        XCTAssertEqual(plan.update(secondRecording), [.end(first.id), .start(secondRecording)])
        XCTAssertEqual(plan.sessionID, second.id)
    }

    func testActivitiesFromAnEarlierProcessAreStale() {
        XCTAssertEqual(MobileRecordingActivityPlan.staleActivityIDs(existing: ["earlier", "older"], owned: nil), ["earlier", "older"])
        XCTAssertEqual(MobileRecordingActivityPlan.staleActivityIDs(existing: ["earlier", "current"], owned: "current"), ["earlier"])
        XCTAssertEqual(MobileRecordingActivityPlan.staleActivityIDs(existing: [], owned: "current"), [])
    }
}
