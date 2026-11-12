import Foundation

private enum PichiLocalization {
    static func text(_ key: String) -> String { key }
}

@MainActor private enum PrivateProfileStorage {
    struct Snapshot: Equatable { let generation: Int }
    static var current = Snapshot(generation: 0)
    static var acceptsNewWork = true
    static var readable = true
    static func isReadable(_ profile: Snapshot) -> Bool { readable && current == profile }
}

private actor RestoreGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        released = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor private final class RestorationASR {
    enum Source { case onboarding }
    var isAsrReady = false
    var calls = 0
    var gate: RestoreGate?
    var shouldFail = false
    var errorTitle = ""
    var errorMessage = ""
    var showError = false
    func ensureAsrReady(source: Source) async throws {
        calls += 1
        if let gate { await gate.wait() }
        try Task.checkCancellation()
        if shouldFail { throw NSError(domain: "SyntheticRestoreFailure", code: 1) }
        isAsrReady = true
    }
}

@MainActor private final class RestorationHost {
    enum Model { case selected, replacement }
    enum Step { case ownerVoice, other }
    final class Settings { var selectedSpeechModel = Model.selected }
    let settings = Settings()
    let asr = RestorationASR()
    var step = Step.ownerVoice
    var isOnboardingFlowVisible = true
    var ownerVoiceSpeechModelToRestore: Model? = .selected
    var ownerVoiceSpeechRestoreTask: Task<Void, Never>?
    var ownerVoiceStartTask: Task<Void, Never>?
    let ownerVoiceProfile = PrivateProfileStorage.current
    func restore() { restoreSpeechAfterOwnerVoiceIfNeeded() }
    func conceal() { cancelOwnerVoiceWorkForConceal() }
    // ACTUAL_OWNER_VOICE_RESTORATION
    // ACTUAL_OWNER_VOICE_CONCEALMENT
}

@main struct OnboardingOwnerVoiceRestorationTests {
    @MainActor static func main() async {
        let delayed = RestorationHost(), gate = RestoreGate()
        delayed.asr.gate = gate
        delayed.restore()
        let operation = delayed.ownerVoiceSpeechRestoreTask!
        await started(delayed)
        precondition(delayed.ownerVoiceSpeechRestoreTask != nil && !delayed.asr.isAsrReady,
                     "The footer remains busy until ordinary ASR restoration joins")
        delayed.restore()
        precondition(delayed.asr.calls == 1, "A repeated phase notification cannot start another preparation")
        await gate.release()
        await operation.value
        precondition(delayed.asr.isAsrReady && delayed.ownerVoiceSpeechRestoreTask == nil
                     && delayed.ownerVoiceSpeechModelToRestore == nil)
        delayed.restore()
        precondition(delayed.asr.calls == 1, "Save after restoration does not prepare the model again")

        let ready = RestorationHost()
        ready.asr.isAsrReady = true
        ready.restore()
        precondition(ready.asr.calls == 0 && ready.ownerVoiceSpeechRestoreTask == nil
                     && ready.ownerVoiceSpeechModelToRestore == nil)

        let replaced = RestorationHost()
        replaced.restore()
        let replacedOperation = replaced.ownerVoiceSpeechRestoreTask!
        replaced.settings.selectedSpeechModel = .replacement
        await replacedOperation.value
        precondition(replaced.asr.calls == 0 && replaced.ownerVoiceSpeechRestoreTask == nil,
                     "A queued restoration cannot prepare a different model")

        let cancelled = RestorationHost(), cancelGate = RestoreGate()
        cancelled.asr.gate = cancelGate
        cancelled.restore()
        let cancelOperation = cancelled.ownerVoiceSpeechRestoreTask!
        await started(cancelled)
        cancelOperation.cancel()
        await Task.yield()
        precondition(cancelled.ownerVoiceSpeechRestoreTask != nil,
                     "Cancel retains the owned task until the service returns")
        await cancelGate.release()
        await cancelOperation.value
        precondition(cancelled.ownerVoiceSpeechRestoreTask == nil && !cancelled.asr.showError
                     && cancelled.ownerVoiceSpeechModelToRestore != nil,
                     "Cancellation joins without publishing an error and keeps retry available")

        let failed = RestorationHost()
        failed.asr.shouldFail = true
        failed.restore()
        await failed.ownerVoiceSpeechRestoreTask!.value
        precondition(failed.asr.showError && failed.asr.errorTitle == "Voice Model Setup Failed"
                     && failed.ownerVoiceSpeechModelToRestore != nil)
        failed.asr.shouldFail = false
        failed.restore()
        await failed.ownerVoiceSpeechRestoreTask!.value
        precondition(failed.asr.isAsrReady && failed.ownerVoiceSpeechModelToRestore == nil,
                     "Failed preparation remains retryable without another voice recording")

        let concealed = RestorationHost(), concealGate = RestoreGate()
        concealed.asr.gate = concealGate
        concealed.asr.shouldFail = true
        concealed.restore()
        let concealOperation = concealed.ownerVoiceSpeechRestoreTask!
        await started(concealed)
        concealed.isOnboardingFlowVisible = false
        await concealGate.release()
        await concealOperation.value
        precondition(!concealed.asr.showError && concealed.ownerVoiceSpeechRestoreTask == nil,
                     "An outgoing onboarding cannot publish a late error")

        let retained = RestorationHost(), privateGate = RestoreGate()
        retained.asr.gate = privateGate
        retained.restore()
        let retainedOperation = retained.ownerVoiceSpeechRestoreTask!
        await started(retained)
        PrivateProfileStorage.acceptsNewWork = false
        PrivateProfileStorage.readable = false
        retained.conceal()
        precondition(retained.isOnboardingFlowVisible && retained.ownerVoiceSpeechRestoreTask != nil
                     && retained.ownerVoiceSpeechModelToRestore == nil,
                     "Concealment retains the mounted host but closes and cancels its owned work")
        await privateGate.release()
        await retainedOperation.value
        precondition(!retained.asr.showError && retained.ownerVoiceSpeechRestoreTask == nil)
        retained.ownerVoiceSpeechModelToRestore = .selected
        retained.restore()
        precondition(retained.asr.calls == 1 && retained.ownerVoiceSpeechModelToRestore == nil,
                     "A late idle notification after conceal cannot start a new model load")

        PrivateProfileStorage.acceptsNewWork = true
        PrivateProfileStorage.readable = true
        let switched = RestorationHost(), switchGate = RestoreGate()
        switched.asr.gate = switchGate
        switched.asr.shouldFail = true
        switched.restore()
        let switchedOperation = switched.ownerVoiceSpeechRestoreTask!
        await started(switched)
        PrivateProfileStorage.current = .init(generation: 1)
        await switchGate.release()
        await switchedOperation.value
        precondition(!switched.asr.showError && switched.ownerVoiceSpeechRestoreTask == nil,
                     "An earlier profile cannot publish into a readable replacement profile")
        let queued = RestorationHost()
        queued.restore()
        let queuedOperation = queued.ownerVoiceSpeechRestoreTask!
        PrivateProfileStorage.current = .init(generation: 2)
        await queuedOperation.value
        precondition(queued.asr.calls == 0 && queued.ownerVoiceSpeechRestoreTask == nil,
                     "A profile switch before queued work starts cannot load the old model")
        print("PASS: actual onboarding owner-voice restoration, single-flight readiness, selection pinning, joined cancellation, retry and concealed errors")
    }

    @MainActor private static func started(_ host: RestorationHost) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while host.asr.calls == 0 && ContinuousClock.now < deadline { await Task.yield() }
        precondition(host.asr.calls == 1)
    }
}
