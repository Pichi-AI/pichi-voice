import Foundation

// Compile the actual controller and progressive-window implementation with this minimal
// context. These tests own no native model, microphone, file store or personal transcript.
typealias MeetingAudioTrackID = UUID
typealias MeetingBackendSpeakerToken = String

nonisolated struct MeetingPCMTranscriptBatch: Sendable { let text: String }
nonisolated struct MeetingBackendSpeakerActivity: Sendable {}
nonisolated enum PichiLocalization { static func text(_ key: String) -> String { key } }
private enum ExpectedFailure: Error { case prepare, recognize, cleanup }

private actor Signal {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(released: Bool = false) { self.released = released }
    func wait() async {
        if self.released { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
    func release() {
        self.released = true
        let waiters = self.waiters
        self.waiters = []
        for waiter in waiters { waiter.resume() }
    }
}

private actor Evidence {
    private(set) var events: [String] = []
    func record(_ event: String) { self.events.append(event) }
    func contains(_ event: String) -> Bool { self.events.contains(event) }
}

private nonisolated struct Prepared: MeetingPreparedStreamingPCMProcessing {
    let evidence: Evidence
    var entered: Signal? = nil
    var inferenceGate: Signal? = nil
    var failRecognition = false
    var finishEntered: Signal? = nil
    var feedbackEntered: Signal? = nil
    var feedbackGate: Signal? = nil

    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                   preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingStreamingPCMObservation {
        await self.evidence.record("recognize")
        await self.entered?.release()
        await self.inferenceGate?.wait()
        if self.failRecognition { throw ExpectedFailure.recognize }
        var count = 0
        while let update = try await window.next() {
            count += update.samples.count
            if let preview { try await preview(.init(text: "safe-preview")) }
        }
        return .init(batch: .init(text: "safe-\(count)"), activity: [], acceptedThroughSample: count,
                     processedThroughSample: count, retainedFromSample: 0, isFinal: false)
    }
    func finishStreaming() async throws -> MeetingStreamingPCMObservation {
        await self.evidence.record("finish")
        await self.finishEntered?.release()
        return .init(batch: .init(text: "safe-final"), activity: [], acceptedThroughSample: 3,
                     processedThroughSample: 3, retainedFromSample: 0, isFinal: true)
    }
    func discardActivity(beforeSample: Int) async throws { await self.evidence.record("ack-\(beforeSample)") }
    func recordWindowProcessing(_ feedback: MeetingPCMWindowProcessingFeedback) async throws {
        await self.evidence.record("feedback")
        await self.feedbackEntered?.release()
        await self.feedbackGate?.wait()
    }
}

@main
nonisolated struct MeetingStreamingPCMControllerTests {
    static func require(_ value: Bool, _ detail: String) throws {
        guard value else { throw NSError(domain: "StreamingPCMController", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
    }

    private static func scoped(_ prepared: Prepared, cleanupGate: Signal = Signal(released: true), failCleanup: Bool = false) -> MeetingStreamingPCMController.ScopeOperation {
        { body in
            await prepared.evidence.record("prepared-both")
            do { try await body(prepared) }
            catch {
                await cleanupGate.wait()
                await prepared.evidence.record("cleaned")
                throw error
            }
            await cleanupGate.wait()
            await prepared.evidence.record("cleaned")
            if failCleanup { throw ExpectedFailure.cleanup }
        }
    }

    static func main() async throws {
        try await self.testSharedTracksFinishAndCancel()
        try await self.testSuccessAndFinishJoin()
        try await self.testPreparationFailure()
        try await self.testPreparationCancellationJoin()
        try await self.testRecognitionFailureJoin()
        try await self.testCancellationWhileWaitingForPCM()
        try await self.testConcurrentCommandClosesAndJoins()
        try await self.testLatePreviewAndCallbackReentry()
        try await self.testCleanupFailureDoesNotPublishFinal()
        try await self.testDetachedScopePreservesReentry()
        try await self.testDeferredPreparationAndEarlyStop()
        try await self.testDeferredFailureAndCancellation()
        try await self.testFeedbackCancellationJoin()
        print("PASS streaming controller preparation, single-command admission, actual PCM wait cancellation, guarded previews and joined resource teardown")
    }

    static func testSharedTracksFinishAndCancel() async throws {
        let firstID = UUID(), secondID = UUID(), evidence = Evidence()
        let firstFinished = Signal()
        let firstPrepared = Prepared(evidence: evidence, finishEntered: firstFinished), secondPrepared = Prepared(evidence: evidence)
        let controllers = try MeetingStreamingPCMController.deferredTracks(trackIDs: [firstID, secondID]) { body in
            await evidence.record("one-scope-open")
            do { try await body([firstID: firstPrepared, secondID: secondPrepared]) }
            catch { await evidence.record("one-scope-cleaned"); throw error }
            await evidence.record("one-scope-cleaned")
        }
        let first = controllers[firstID]!, second = controllers[secondID]!
        async let firstResult = first.recognize(window: .controllerTestWindow(samples: [0.1], sealed: true), offset: 0)
        async let secondResult = second.recognize(window: .controllerTestWindow(samples: [0.2, 0.3], sealed: true), offset: 0)
        let results = try await (firstResult, secondResult)
        try require(results.0.batch.text == "safe-1" && results.1.batch.text == "safe-2", "Physical source windows stay independent")
        let firstStop = Task { _ = try await first.finishStreaming(); await evidence.record("first-stop-returned") }
        await firstFinished.wait()
        try require(await !evidence.contains("first-stop-returned"), "First source cannot release the shared native scope")
        _ = try await second.finishStreaming()
        try await firstStop.value
        let events = await evidence.events
        try require(events.filter { $0 == "one-scope-open" }.count == 1 && events.filter { $0 == "one-scope-cleaned" }.count == 1,
                    "Both sources own exactly one preparation and joined cleanup")
        try require(events.firstIndex(of: "one-scope-cleaned")! < events.firstIndex(of: "first-stop-returned")!, "Stop returns only after shared cleanup")

        let cancelledEvidence = Evidence(), cancelledEntered = Signal()
        let cancelled = try MeetingStreamingPCMController.deferredTracks(trackIDs: [firstID, secondID]) { body in
            do { try await body([firstID: Prepared(evidence: cancelledEvidence, entered: cancelledEntered), secondID: Prepared(evidence: cancelledEvidence)]) }
            catch { await cancelledEvidence.record("cancel-cleaned"); throw error }
        }
        let waiting = Task { try await cancelled[firstID]!.recognize(window: .controllerTestWindow(samples: [], sealed: false), offset: 0) }
        await cancelledEntered.wait()
        waiting.cancel()
        do { _ = try await waiting.value; throw ExpectedFailure.recognize }
        catch is CancellationError {}
        try require(await cancelledEvidence.contains("cancel-cleaned"), "Cancelling one source joins the idle sibling and whole native scope")
        await cancelled[secondID]!.cancelAndWait()
    }

    static func testFeedbackCancellationJoin() async throws {
        let evidence = Evidence(), entered = Signal(), feedback = Signal(), cleanup = Signal()
        let controller = try await MeetingStreamingPCMController.prepare(using: self.scoped(
            .init(evidence: evidence, feedbackEntered: entered, feedbackGate: feedback), cleanupGate: cleanup))
        let operation = Task {
            do {
                try await controller.recordWindowProcessing(.init(sourceStartSample: 0, sourceFrameCount: 1,
                    chargedPendingFrames: 0, maximumPendingFrames: 960_000))
                throw NSError(domain: "ExpectedFeedbackCancellation", code: 1)
            } catch is CancellationError { await evidence.record("feedback-returned") }
        }
        await entered.wait()
        operation.cancel()
        try require(await !evidence.contains("feedback-returned"), "Cancellation joins the active feedback command")
        await feedback.release()
        for _ in 0..<20 { await Task.yield() }
        try require(await !evidence.contains("feedback-returned"), "Feedback cancellation still owns native scope cleanup")
        await cleanup.release()
        try await operation.value
        try require(await evidence.events.suffix(2) == ["cleaned", "feedback-returned"],
                    "Cancellation cannot abandon feedback or release the prepared scope early")
    }

    static func testDeferredPreparationAndEarlyStop() async throws {
        let evidence = Evidence(), entered = Signal(), preparation = Signal()
        let scope = self.scoped(Prepared(evidence: evidence))
        let controller = MeetingStreamingPCMController.deferred { body in
            await entered.release()
            await preparation.wait()
            try await scope(body)
        }
        try require(await evidence.events.isEmpty, "Admitting capture does not open either native model")
        let first = Task {
            try await controller.recognize(window: .controllerTestWindow(samples: [0, 0.1, -0.1], sealed: true), offset: 0)
        }
        await entered.wait()
        try require(await evidence.events.isEmpty, "The first captured PCM remains owned while models prepare")
        await preparation.release()
        let result = try await first.value
        try require(result.batch.text == "safe-3", "All initially captured samples reach the sole prepared worker")
        _ = try await controller.finishStreaming()
        try require(await evidence.events == ["prepared-both", "recognize", "finish", "cleaned"],
                    "Deferred capture uses one resource scope and joins finalization")

        let shortEvidence = Evidence()
        let short = MeetingStreamingPCMController.deferred(using: self.scoped(.init(evidence: shortEvidence)))
        _ = try await short.finishStreaming()
        try require(await shortEvidence.events == ["prepared-both", "finish", "cleaned"],
                    "Stop before the first PCM window has one joined final command")
    }

    static func testDeferredFailureAndCancellation() async throws {
        let failureEvidence = Evidence()
        let failed = MeetingStreamingPCMController.deferred { _ in
            await failureEvidence.record("cleaned")
            throw ExpectedFailure.prepare
        }
        do {
            _ = try await failed.recognize(window: .controllerTestWindow(samples: [0], sealed: true), offset: 0)
            throw NSError(domain: "ExpectedDeferredFailure", code: 1)
        } catch ExpectedFailure.prepare { }
        try require(await failureEvidence.events == ["cleaned"], "Deferred failure never publishes a false ready result")

        let untouchedEvidence = Evidence()
        let untouched = MeetingStreamingPCMController.deferred(using: self.scoped(.init(evidence: untouchedEvidence)))
        await untouched.cancelAndWait()
        try require(await untouchedEvidence.events.isEmpty, "Cancellation before first use opens no resources")

        let emptyEvidence = Evidence()
        let empty = MeetingStreamingPCMController.deferred(using: self.scoped(.init(evidence: emptyEvidence)))
        try require(empty.cancelIfUnstarted(), "Empty capture closes without opening native engines")
        await empty.cancelAndWait()
        try require(await emptyEvidence.events.isEmpty, "Failed microphone admission has no model cleanup to create")

        let evidence = Evidence(), entered = Signal(), preparation = Signal(), cleanup = Signal()
        let scope = self.scoped(.init(evidence: evidence), cleanupGate: cleanup)
        let controller = MeetingStreamingPCMController.deferred { body in
            await entered.release()
            await preparation.wait() // Deliberately non-cooperative native preparation.
            try await scope(body)
        }
        let task = Task {
            do {
                _ = try await controller.recognize(window: .controllerTestWindow(samples: [0], sealed: true), offset: 0)
                throw NSError(domain: "ExpectedDeferredCancellation", code: 1)
            } catch is CancellationError { await evidence.record("returned") }
        }
        await entered.wait()
        task.cancel()
        await preparation.release()
        try require(await !evidence.contains("returned"), "Cancelling startup waits for native preparation and cleanup")
        await cleanup.release()
        try await task.value
        try require(await evidence.events.suffix(2) == ["cleaned", "returned"], "No task escapes a cancelled deferred scope")
    }

    static func testSuccessAndFinishJoin() async throws {
        let evidence = Evidence(), cleanup = Signal()
        let controller = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence), cleanupGate: cleanup))
        try require(await evidence.contains("prepared-both"), "Readiness follows both prepared resources")
        let window = MeetingPCMProgressiveWindow.controllerTestWindow(samples: [0, 0.1, -0.1], sealed: true)
        let recognized = try await controller.recognize(window: window, offset: 0) { _ in await evidence.record("preview") }
        try require(recognized.batch.text == "safe-3" && recognized.acceptedThroughSample == 3, "The sole worker consumes actual window deltas")
        try await controller.discardActivity(beforeSample: 2)
        let final = Task {
            let result = try await controller.finishStreaming()
            await evidence.record("finish-returned")
            return result
        }
        while await !evidence.contains("finish") { await Task.yield() }
        try require(await !evidence.contains("finish-returned"), "Finish cannot return while the outer resource cleanup is suspended")
        await cleanup.release()
        let result = try await final.value
        let events = await evidence.events
        try require(result.isFinal && events.firstIndex(of: "cleaned")! < events.firstIndex(of: "finish-returned")!,
                    "Final observation follows complete resource release")
        do { _ = try await controller.finishStreaming(); throw NSError(domain: "ExpectedClosed", code: 1) }
        catch MeetingStreamingPCMControllerError.closed { }
        try require(await evidence.events.filter { $0 == "finish" }.count == 1, "Finish executes exactly once")
        await controller.cancelAndWait()
    }

    static func testPreparationFailure() async throws {
        let evidence = Evidence()
        do {
            _ = try await MeetingStreamingPCMController.prepare { _ in
                await evidence.record("cleaned")
                throw ExpectedFailure.prepare
            }
            throw NSError(domain: "ExpectedPrepareFailure", code: 1)
        } catch ExpectedFailure.prepare { }
        try require(await evidence.contains("cleaned"), "Preparation failure returns only after its scope unwinds")
        do { _ = try await MeetingStreamingPCMController.prepare { _ in }; throw NSError(domain: "ExpectedScopeFailure", code: 1) }
        catch MeetingStreamingPCMControllerError.invalidScope { }
    }

    static func testPreparationCancellationJoin() async throws {
        let evidence = Evidence(), started = Signal(), preparation = Signal(), cleanup = Signal()
        let preparing = Task {
            do {
                _ = try await MeetingStreamingPCMController.prepare { body in
                    await started.release()
                    await preparation.wait() // Deliberately non-cooperative preparation.
                    do { try await body(Prepared(evidence: evidence)) }
                    catch { await cleanup.wait(); await evidence.record("cleaned"); throw error }
                }
                throw NSError(domain: "ExpectedCancelledPrepare", code: 1)
            } catch is CancellationError { await evidence.record("prepare-returned") }
        }
        await started.wait()
        preparing.cancel()
        await preparation.release()
        try require(await !evidence.contains("prepare-returned"), "Cancelled readiness joins preparation and cleanup")
        await cleanup.release()
        try await preparing.value
        try require(await evidence.events == ["cleaned", "prepare-returned"], "No session escapes a cancelled readiness wait")
    }

    static func testRecognitionFailureJoin() async throws {
        let evidence = Evidence(), entered = Signal(), cleanup = Signal()
        let controller = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence, entered: entered, failRecognition: true), cleanupGate: cleanup))
        let task = Task {
            do { _ = try await controller.recognize(window: .controllerTestWindow(samples: [], sealed: false), offset: 0); throw NSError(domain: "ExpectedRecognitionFailure", code: 1) }
            catch ExpectedFailure.recognize { await evidence.record("recognize-returned") }
        }
        await entered.wait()
        try require(await !evidence.contains("recognize-returned"), "Recognition errors wait for resource release")
        await cleanup.release()
        try await task.value
        try require(await evidence.events.suffix(2) == ["cleaned", "recognize-returned"], "Failure resolves after the outer scope joins")
    }

    static func testCancellationWhileWaitingForPCM() async throws {
        let evidence = Evidence(), entered = Signal()
        let controller = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence, entered: entered)))
        let window = MeetingPCMProgressiveWindow.controllerTestWindow(samples: [], sealed: false)
        let task = Task { try await controller.recognize(window: window, offset: 0) }
        await entered.wait()
        task.cancel()
        do { _ = try await task.value; throw NSError(domain: "ExpectedPCMWaitCancellation", code: 1) }
        catch is CancellationError { }
        try require(await evidence.contains("cleaned"), "Cancellation wakes actual window.next and joins resource retirement")
        await controller.cancelAndWait()
    }

    static func testConcurrentCommandClosesAndJoins() async throws {
        let evidence = Evidence(), entered = Signal()
        let controller = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence, entered: entered)))
        let first = Task { try await controller.recognize(window: .controllerTestWindow(samples: [], sealed: false), offset: 0) }
        await entered.wait()
        do { try await controller.discardActivity(beforeSample: 0); throw NSError(domain: "ExpectedConcurrentCommandRejection", code: 1) }
        catch MeetingStreamingPCMControllerError.concurrentOperation { }
        do { _ = try await first.value; throw NSError(domain: "ExpectedFirstCallCancellation", code: 1) }
        catch is CancellationError { }
        try require(await evidence.contains("cleaned"), "Concurrent admission fails closed and joins the admitted owner")
    }

    static func testLatePreviewAndCallbackReentry() async throws {
        let evidence = Evidence(), entered = Signal(), inference = Signal()
        let controller = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence, entered: entered, inferenceGate: inference)))
        let task = Task {
            try await controller.recognize(window: .controllerTestWindow(samples: [0], sealed: true), offset: 0) { _ in await evidence.record("late-preview") }
        }
        await entered.wait()
        task.cancel()
        await inference.release()
        do { _ = try await task.value; throw NSError(domain: "ExpectedInferenceCancellation", code: 1) }
        catch is CancellationError { }
        let events = await evidence.events
        try require(!events.contains("late-preview") && events.contains("cleaned"), "Cancelled native work cannot publish a later preview")

        let second = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence)))
        _ = try await second.recognize(window: .controllerTestWindow(samples: [0], sealed: true), offset: 0) { _ in
            do { try await second.discardActivity(beforeSample: 0); throw NSError(domain: "ExpectedReentryRejection", code: 1) }
            catch MeetingStreamingPCMControllerError.reentrantOperation { await evidence.record("reentry-rejected") }
        }
        _ = try await second.finishStreaming()
        try require(await evidence.contains("reentry-rejected"), "Recursive command rejects without joining its own worker")

        let third = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence)))
        do {
            _ = try await third.recognize(window: .controllerTestWindow(samples: [0], sealed: true), offset: 0) { _ in
                await third.cancelAndWait()
                await evidence.record("callback-cancel-requested")
            }
            throw NSError(domain: "ExpectedCallbackCancellation", code: 1)
        } catch is CancellationError { }
        let cancellationEvents = await evidence.events
        try require(cancellationEvents.suffix(2) == ["callback-cancel-requested", "cleaned"],
                    "Recursive cancellation unwinds its callback and outer public call joins cleanup without self-deadlock")
    }

    static func testDetachedScopePreservesReentry() async throws {
        let evidence = Evidence()
        let scope = self.scoped(.init(evidence: evidence))
        let controller = try await MeetingStreamingPCMController.prepare { body in
            // Production withPreparedASR moves the resource body off MainActor this way.
            let work = Task.detached { try await scope(body) }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        _ = try await controller.recognize(window: .controllerTestWindow(samples: [0], sealed: true), offset: 0) { _ in
            do { try await controller.discardActivity(beforeSample: 0); throw NSError(domain: "ExpectedDetachedReentryRejection", code: 1) }
            catch MeetingStreamingPCMControllerError.reentrantOperation { await evidence.record("detached-reentry-rejected") }
        }
        _ = try await controller.finishStreaming()
        try require(await evidence.contains("detached-reentry-rejected"), "Executor bridges must preserve command callback reentry guards")

        let cancellation = try await MeetingStreamingPCMController.prepare { body in
            let work = Task.detached { try await scope(body) }
            try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        }
        do {
            _ = try await cancellation.recognize(window: .controllerTestWindow(samples: [0], sealed: true), offset: 0) { _ in
                await cancellation.cancelAndWait()
                await evidence.record("detached-callback-cancelled")
            }
            throw NSError(domain: "ExpectedDetachedCallbackCancellation", code: 1)
        } catch is CancellationError { }
        try require(await evidence.events.suffix(2) == ["detached-callback-cancelled", "cleaned"],
                    "Callback cancellation after an executor bridge unwinds before the outer join")
    }

    static func testCleanupFailureDoesNotPublishFinal() async throws {
        let evidence = Evidence()
        let controller = try await MeetingStreamingPCMController.prepare(using: self.scoped(.init(evidence: evidence), failCleanup: true))
        do { _ = try await controller.finishStreaming(); throw NSError(domain: "ExpectedCleanupFailure", code: 1) }
        catch ExpectedFailure.cleanup { }
        try require(await evidence.events == ["prepared-both", "finish", "cleaned"], "Cleanup failure prevents successful final observation")
    }
}
