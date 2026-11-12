import Foundation
import XCTest

final class PhysicalOwnedCleanupTests: XCTestCase {
    private enum Failure: Error, Equatable { case operation, stop, join }

    @MainActor
    func testOwnedMutationVerifiesBeforeDispatchingExactlyOneEvent() throws {
        var calls: [String] = []
        try PhysicalOwnedMutation.run(verify: { calls.append("verify") }, mutate: { calls.append("event") })
        XCTAssertEqual(calls, ["verify", "event"])
    }

    @MainActor
    func testOwnedMutationRejectsFailedOwnershipWithoutDispatch() {
        var events = 0
        XCTAssertThrowsError(try PhysicalOwnedMutation.run(verify: { throw Failure.operation }, mutate: { events += 1 })) {
            XCTAssertEqual($0 as? Failure, .operation)
        }
        XCTAssertEqual(events, 0)
    }

    @MainActor
    func testOwnedMutationCancelledBeforeVerificationDoesNotQueryOrDispatch() async throws {
        var queries = 0, events = 0
        let task = Task { @MainActor in
            try PhysicalOwnedMutation.run(verify: { queries += 1 }, mutate: { events += 1 })
        }
        task.cancel()
        do { try await task.value; XCTFail("Cancelled mutation must be denied") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(events, 0)
    }

    @MainActor
    func testOwnedMutationCancelledDuringLastEligibilityQueryDoesNotDispatch() async throws {
        var queries = 0, events = 0
        let task = Task { @MainActor in
            try PhysicalOwnedMutation.run(verify: {
                queries += 1
                // Model cancellation delivered while the final native query returns true.
                withUnsafeCurrentTask { $0?.cancel() }
            }, mutate: { events += 1 })
        }
        do { try await task.value; XCTFail("Late cancellation must prevent the native event") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(events, 0)
    }

    @MainActor
    func testDeniedOwnedMutationStillRunsIndependentJoinedCleanup() async throws {
        var events = 0, cleaned = false
        let task = Task { @MainActor in
            try await PhysicalOwnedRecordingCleanup.withJoinedCleanup(operation: {
                try PhysicalOwnedMutation.run(verify: { withUnsafeCurrentTask { $0?.cancel() } },
                                              mutate: { events += 1 })
            }, cleanup: {
                XCTAssertFalse(Task.isCancelled)
                cleaned = true
            })
        }
        do { try await task.value; XCTFail("Cancellation must propagate after cleanup") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(events, 0)
        XCTAssertTrue(cleaned)
    }

    @MainActor
    func testSharedRevealSupportsBothFrozenAndLegacyDirections() throws {
        for (upward, target) in [(true, 3), (false, -3), (true, -3), (false, 3)] {
            var position = 0
            try PhysicalControlReveal.run(startingUpward: upward, ready: { position == target },
                scroll: { up, _ in position += up ? 1 : -1 })
            XCTAssertEqual(position, target)
        }
        try PhysicalControlReveal.run(ready: { true }, scroll: { _, _ in XCTFail("Ready controls must not scroll") })
    }

    @MainActor
    func testSharedRevealPreservesReadinessFailureWithoutGestures() {
        XCTAssertThrowsError(try PhysicalControlReveal.run(ready: { throw Failure.operation },
            scroll: { _, _ in XCTFail("Failed ownership/cancellation must not cause a gesture") })) {
            XCTAssertEqual($0 as? Failure, .operation)
        }
    }

    @MainActor
    func testUnavailableRecordingAndPlaybackControlsWaitForReadinessThenJoin() async throws {
        for resource in ["recording", "inline-player"] {
            var time: TimeInterval = 0
            var calls: [String] = []
            try await PhysicalOwnedRecordingCleanup.run(observe: {
                PhysicalUITransitionWait.ownedRecordingAction(stopReady: time >= 2, processing: false, completed: false)
            }, stop: { calls.append("\(resource)-stop") }, join: { calls.append("\(resource)-join") },
               now: { time }, pause: { time += 1 })
            XCTAssertEqual(time, 2)
            XCTAssertEqual(calls, ["\(resource)-stop", "\(resource)-join"])
        }
    }

    @MainActor
    func testAlreadyCompletedOwnerJoinsWithoutAnotherStop() async throws {
        var stopped = false
        var joined = false
        try await PhysicalOwnedRecordingCleanup.run(observe: { .join },
            stop: { stopped = true }, join: { joined = true })
        XCTAssertFalse(stopped)
        XCTAssertTrue(joined)
    }

    @MainActor
    func testStopFailureStillJoinsAndKeepsOriginalFailure() async throws {
        var joined = false
        do {
            try await PhysicalOwnedRecordingCleanup.run(observe: { .requestStop },
                stop: { throw Failure.stop }, join: { joined = true })
            XCTFail("Stop failure must not become cleanup success")
        } catch { XCTAssertEqual(error as? Failure, .stop) }
        XCTAssertTrue(joined)
    }

    @MainActor
    func testJoinFailureRemainsAnUnresolvedCleanup() async throws {
        do {
            try await PhysicalOwnedRecordingCleanup.run(observe: { .join },
                stop: { XCTFail("An admitted completion needs no second Stop") }, join: { throw Failure.join })
            XCTFail("Join failure must propagate")
        } catch { XCTAssertEqual(error as? Failure, .join) }
    }

    @MainActor
    func testStopAndJoinFailuresAreBothRetained() async throws {
        do {
            try await PhysicalOwnedRecordingCleanup.run(observe: { .requestStop },
                stop: { throw Failure.stop }, join: { throw Failure.join })
            XCTFail("Two failures must not become success")
        } catch {
            let failure = try XCTUnwrap(error as? PhysicalOwnedRecordingCleanup.StopAndJoinFailure)
            XCTAssertEqual(failure.stopError as? Failure, .stop)
            XCTAssertEqual(failure.joinError as? Failure, .join)
        }
    }

    @MainActor
    func testMissingOwnedControlTimesOutWithoutTouchingAnotherResource() async throws {
        var time: TimeInterval = 0
        var acted = false
        do {
            try await PhysicalOwnedRecordingCleanup.run(observe: { nil },
                stop: { acted = true }, join: { acted = true }, now: { time }, pause: { time += 1 })
            XCTFail("Unavailable ownership must fail closed")
        } catch { XCTAssertTrue(error is PhysicalUITransitionWait.TimedOut) }
        XCTAssertEqual(time, 30)
        XCTAssertFalse(acted)
    }

    @MainActor
    func testOperationFailureRunsMandatoryCleanupAndIsNotErased() async throws {
        var cleaned = false
        do {
            try await PhysicalOwnedRecordingCleanup.withJoinedCleanup(operation: { throw Failure.operation },
                cleanup: { cleaned = true })
            XCTFail("The original operation failure must propagate")
        } catch { XCTAssertEqual(error as? Failure, .operation) }
        XCTAssertTrue(cleaned)
    }

    @MainActor
    func testCleanupFailureAfterSuccessfulOperationIsNotSuccess() async throws {
        do {
            try await PhysicalOwnedRecordingCleanup.withJoinedCleanup(operation: {}, cleanup: { throw Failure.join })
            XCTFail("Unresolved mandatory cleanup must propagate")
        } catch { XCTAssertEqual(error as? Failure, .join) }
    }

    @MainActor
    func testOperationAndCleanupFailuresRemainDistinct() async throws {
        do {
            try await PhysicalOwnedRecordingCleanup.withJoinedCleanup(operation: { throw Failure.operation },
                cleanup: { throw Failure.join })
            XCTFail("Both failures must be retained")
        } catch {
            let failure = try XCTUnwrap(error as? PhysicalOwnedRecordingCleanup.OperationAndCleanupFailure)
            XCTAssertEqual(failure.operationError as? Failure, .operation)
            XCTAssertEqual(failure.cleanupError as? Failure, .join)
        }
    }

    @MainActor
    func testCancelledOperationGetsIndependentJoinedCleanup() async throws {
        var cleaned = false
        let task = Task { @MainActor in
            try await PhysicalOwnedRecordingCleanup.withJoinedCleanup(operation: {
                withUnsafeCurrentTask { $0?.cancel() }
                try Task.checkCancellation()
            }, cleanup: {
                XCTAssertFalse(Task.isCancelled)
                cleaned = true
            })
        }
        do { try await task.value; XCTFail("Cancellation must propagate after cleanup") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(cleaned)
    }

    @MainActor
    func testOperationDoesNotReturnBeforeCleanupJoinFinishes() async throws {
        let entered = expectation(description: "Mandatory cleanup has entered its join")
        var release: CheckedContinuation<Void, Never>?
        var released = false
        var returned = false
        let task = Task { @MainActor in
            try await PhysicalOwnedRecordingCleanup.withJoinedCleanup(operation: {}, cleanup: {
                await withCheckedContinuation { continuation in
                    if released { continuation.resume() }
                    else { release = continuation }
                    entered.fulfill()
                }
            })
            returned = true
        }
        let result = await XCTWaiter.fulfillment(of: [entered], timeout: 2)
        XCTAssertEqual(result, .completed)
        XCTAssertFalse(returned)
        released = true
        release?.resume(); release = nil
        if result != .completed { task.cancel() }
        try await task.value
        XCTAssertTrue(returned)
    }

    private let oldID = "00000000-0000-4000-8000-000000000001"
    private let newID = "00000000-0000-4000-8000-000000000002"
    private let otherID = "00000000-0000-4000-8000-000000000003"

    func testOnlyOneFreshSessionWithTheFullBaselineCanBeOwned() {
        XCTAssertEqual(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [oldID], historyIDs: [newID, oldID]), newID)
        XCTAssertEqual(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [], historyIDs: [newID]), newID)
        XCTAssertNil(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [oldID], historyIDs: [oldID]))
        XCTAssertNil(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [oldID], historyIDs: [newID]))
        XCTAssertNil(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [oldID], historyIDs: [oldID, newID, otherID]))
    }

    func testMalformedAndDuplicateSessionSetsAreNotAdopted() {
        for (baseline, current) in [([oldID, oldID], [oldID, newID]),
                                     ([oldID], [oldID, newID, newID]),
                                     (["invalid"], [oldID, newID]), ([oldID], [oldID, "invalid"])] {
            XCTAssertNil(Review34DemoAdmission.newOwnedSessionID(baselineIDs: baseline, historyIDs: current))
        }
    }

    func testOldOrMalformedPlaybackOwnerCannotBeCreated() {
        XCTAssertNil(Review34DemoAdmission.PlaybackOwner(sessionID: oldID, baselineIDs: [oldID],
            paragraphID: "transcript.paragraph.synthetic", audioID: "transcript.audio.synthetic"))
        XCTAssertNil(Review34DemoAdmission.PlaybackOwner(sessionID: "invalid", baselineIDs: [],
            paragraphID: "transcript.paragraph.synthetic", audioID: "transcript.audio.synthetic"))
        XCTAssertNil(Review34DemoAdmission.PlaybackOwner(sessionID: newID, baselineIDs: [oldID],
            paragraphID: "another.paragraph", audioID: "transcript.audio.synthetic"))
        XCTAssertNil(Review34DemoAdmission.PlaybackOwner(sessionID: newID, baselineIDs: [oldID],
            paragraphID: "transcript.paragraph.synthetic", audioID: "other.audio"))
    }

    func testPlaybackScopeRejectsChangedSessionControlOrAmbiguity() throws {
        let owner = try XCTUnwrap(Review34DemoAdmission.PlaybackOwner(sessionID: newID, baselineIDs: [oldID],
            paragraphID: "transcript.paragraph.synthetic", audioID: "transcript.audio.synthetic"))
        func matches(_ session: String?, _ paragraph: String = "transcript.paragraph.synthetic",
                     _ audio: String = "transcript.audio.synthetic", _ paragraphs: Int = 1, _ controls: Int = 1) -> Bool {
            owner.matches(openedSessionID: session, paragraphID: paragraph, audioID: audio,
                paragraphCount: paragraphs, audioCount: controls)
        }
        XCTAssertTrue(matches(newID))
        XCTAssertFalse(matches(oldID)); XCTAssertFalse(matches(nil))
        XCTAssertFalse(matches(newID, "transcript.paragraph.other"))
        XCTAssertFalse(matches(newID, "transcript.paragraph.synthetic", "transcript.audio.other"))
        XCTAssertFalse(matches(newID, "transcript.paragraph.synthetic", "transcript.audio.synthetic", 0))
        XCTAssertFalse(matches(newID, "transcript.paragraph.synthetic", "transcript.audio.synthetic", 2))
        XCTAssertFalse(matches(newID, "transcript.paragraph.synthetic", "transcript.audio.synthetic", 1, 0))
        XCTAssertFalse(matches(newID, "transcript.paragraph.synthetic", "transcript.audio.synthetic", 1, 2))
    }
}
