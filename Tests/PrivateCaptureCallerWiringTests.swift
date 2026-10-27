import Foundation

extension MeetingSessionStoreCheckpointTests {
    @MainActor static func checkPrivateCaptureCallerWiring(check: (Bool, String) -> Void) async {
        let first = ContentCaptureCallerHarness()
        let output = ContentCaptureCallerHarness.PrivateDictationCaptureOutput(results: [false, true])
        first.privateCaptureOutput = output
        first.privateCaptureStopID = output.id
        first.profiles.captureStopHandlerID = output.id
        first.asr.isRunningOrStarting = true
        await first.stopAndProcessTranscription()
        check(first.processCalls == 1 && first.asr.stops == 1 && output.finishes == 1,
            "The actual Content Stop caller joins ASR and attempts local durability once")
        check(first.privateCaptureOutput === output && first.privateCaptureStopID == output.id
            && first.profiles.captureStopHandlerID == output.id && first.profiles.cleared.isEmpty,
            "A false persistence result retains the exact Content output and Stop ownership")
        check(first.processingDictationLifecycleID == nil && output.hasPendingPersistenceRetry,
            "Failed durability releases processing admission while retaining its original persistence retry")
        await first.stopAndProcessTranscription()
        check(first.processCalls == 1 && first.asr.stops == 1 && output.finishes == 2,
            "The next actual Content Stop retries the retained output without entering ASR or processing again")
        check(first.privateCaptureOutput == nil && first.privateCaptureStopID == nil
            && first.profiles.captureStopHandlerID == nil && first.profiles.cleared == [output.id],
            "Successful retry alone releases the exact retained output and Stop callback")

        let reopened = ContentCaptureCallerHarness()
        let retainedID = UUID()
        reopened.profiles.captureStopHandlerID = retainedID
        await reopened.stopAndProcessTranscription()
        check(reopened.profiles.requested == [retainedID] && reopened.profiles.captureStopHandlerID == retainedID
            && reopened.processCalls == 0 && reopened.asr.stops == 0,
            "A recreated Content caller forwards the exact retained Stop ID without consuming another capture's ASR result")

        let refused = ContentCaptureCallerHarness()
        let stillRecording = ContentCaptureCallerHarness.PrivateDictationCaptureOutput(results: [true])
        refused.privateCaptureOutput = stillRecording
        refused.privateCaptureStopID = stillRecording.id
        refused.profiles.captureStopHandlerID = stillRecording.id
        refused.asr.isRunningOrStarting = true
        refused.refuseProcessing = true
        await refused.stopAndProcessTranscription()
        check(refused.processCalls == 1 && refused.asr.stops == 0 && stillRecording.finishes == 0
            && refused.privateCaptureOutput === stillRecording
            && refused.profiles.captureStopHandlerID == stillRecording.id,
            "A refused processing attempt preserves the original running capture and its unconsumed output admission")

        let canceled = ContentCaptureCallerHarness()
        let canceledOutput = ContentCaptureCallerHarness.PrivateDictationCaptureOutput(results: [false, true])
        canceled.privateCaptureOutput = canceledOutput
        canceled.privateCaptureStopID = canceledOutput.id
        canceled.profiles.captureStopHandlerID = canceledOutput.id
        await canceled.finishCancelledCaptureOutput(canceledOutput, id: canceledOutput.id)
        check(canceled.privateCaptureOutput === canceledOutput && canceled.privateCaptureStopID == canceledOutput.id
            && canceled.profiles.captureStopHandlerID == canceledOutput.id,
            "The actual canceled-start cleanup retains the original output when persistence fails")
        await canceled.finishCancelledCaptureOutput(canceledOutput, id: canceledOutput.id)
        check(canceled.privateCaptureOutput == nil && canceled.privateCaptureStopID == nil
            && canceled.profiles.cleared == [canceledOutput.id],
            "Canceled-start cleanup retries and releases only after original output durability succeeds")

        let guarded = ContentCaptureCallerHarness()
        guarded.processingDictationLifecycleID = guarded.overlayLifecycleID
        guarded.profiles.captureStopHandlerID = UUID()
        await guarded.stopAndProcessTranscription()
        check(guarded.profiles.requested.isEmpty && guarded.processCalls == 0,
            "An in-flight Content output lifecycle rejects a second Stop callback before forwarding or consuming output")
    }
}

// The runner inserts the complete production Stop and canceled-output cleanup methods.
// Only their hardware, output durability and presentation dependencies are inert substitutes.
@MainActor final class ContentCaptureCallerHarness {
    enum DictationOutputRoute { case normal, historyOnly }
    final class PrivateDictationCaptureOutput {
        let id = UUID()
        private var results: [Bool]
        var hasPendingPersistenceRetry = false
        private(set) var finishes = 0
        init(results: [Bool]) { self.results = results }
        func finish() async -> Bool {
            finishes += 1
            let result = results.removeFirst()
            hasPendingPersistenceRetry = !result
            return result
        }
    }
    final class CaptureRegistry {
        var captureStopHandlerID: UUID?
        var requested: [UUID] = []
        var cleared: [UUID] = []
        func requestCaptureStop(id: UUID) async {
            guard captureStopHandlerID == id else { return }
            requested.append(id)
        }
        func clearCaptureStopHandler(id: UUID) {
            guard captureStopHandlerID == id else { return }
            cleared.append(id)
            captureStopHandlerID = nil
        }
    }
    final class ASR {
        var isRunningOrStarting = false
        var stops = 0
        func stop() { stops += 1; isRunningOrStarting = false }
    }
    struct OverlayCloseTrace {
        init(_ label: String) {}
        mutating func finish() {}
    }
    enum DebugLogger { @TaskLocal static var pipelineID: String? }
    final class NotchContentState {
        static let shared = NotchContentState()
        var stopSnapshotLabel: String?
    }
    let profiles = CaptureRegistry()
    let asr = ASR()
    var privateCaptureOutput: PrivateDictationCaptureOutput?
    var privateCaptureStopID: UUID?
    var processingDictationLifecycleID: UInt64?
    var overlayLifecycleID: UInt64 = 1
    var processCalls = 0
    var refuseProcessing = false
    func processStoppedTranscription(route: DictationOutputRoute, pipelineID: String,
        toggleStopRequestedAt: TimeInterval?, privateOutput: PrivateDictationCaptureOutput?) async {
        processCalls += 1
        if !refuseProcessing { asr.stop() }
    }
}
