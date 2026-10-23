#if os(macOS)
import Foundation

/// Owns only the capture lifetime for record buttons without ContentView's output pipeline.
/// The existing ASR service and admitted history writer still perform capture and persistence.
@MainActor final class PrivateDirectDictationCapture {
    let output: PrivateDictationCaptureOutput
    private let asr: ASRService
    private let forDictionaryTraining: Bool
    private let requiresPronunciation: Bool
    private let captureDictionaryPronunciation: Bool?
    private var startTask: Task<AudioCaptureStartOutcome, Never>?
    private var stopTask: Task<String, Never>?
    private var completionTask: Task<Bool, Never>?
    private var preservedConcealedResult = false
    private var stoppedText = ""
    private var stoppedAudio: DictationAudioSnapshot?
    private var acceptedVisibleResult = false
    private(set) var isFinished = false

    init(asr: ASRService, savesHistory: Bool, savesAudio: Bool, transcriptionModel: String,
         forDictionaryTraining: Bool = false, requiresPronunciation: Bool = true,
         captureDictionaryPronunciation: Bool? = nil, history: TranscriptionHistoryStore? = nil) throws {
        guard PrivateProfileStorage.acceptsNewWork, !asr.isRunningOrStarting,
              !PrivateProfileService.shared.hasRetainedCaptureStopHandler else {
            throw CancellationError()
        }
        self.asr = asr
        self.forDictionaryTraining = forDictionaryTraining
        self.requiresPronunciation = requiresPronunciation
        self.captureDictionaryPronunciation = captureDictionaryPronunciation
        self.output = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: savesHistory,
            savesAudio: savesAudio, transcriptionModel: transcriptionModel, history: history)
        guard PrivateProfileService.shared.installCaptureStopHandler(id: output.id, stop: {
            _ = await self.stop()
            await self.complete()
        }) else {
            let unusedOutput = output
            let cleanupID = UUID()
            let cleanup = Task { @MainActor in
                await unusedOutput.finish()
                PrivateProfileService.shared.finishPrivateWrite(id: cleanupID)
            }
            PrivateProfileService.shared.retainPrivateWrite(cleanup, id: cleanupID)
            throw CancellationError()
        }
    }

    var isVisible: Bool { output.isVisible }

    func start(onCaptureStarted: (@MainActor () -> Void)? = nil) async -> AudioCaptureStartOutcome {
        if let startTask { return await startTask.value }
        guard !isFinished, output.isVisible else {
            await finish()
            return .failed
        }
        let task = Task { @MainActor in
            await asr.start(forDictionaryTraining: forDictionaryTraining,
                requiresPronunciation: requiresPronunciation, onCaptureStarted: onCaptureStarted)
        }
        startTask = task
        let outcome = await task.value
        if outcome != .started { await finish() }
        return outcome
    }

    /// Concurrent root Stop and view Stop requests join the same finalization and local write.
    func stop() async -> String {
        if let stopTask { return await stopTask.value }
        guard !isFinished else { return "" }
        let task = Task { @MainActor in
            if let startTask, await startTask.value != .started {
                await finish()
                return ""
            }
            let text = await asr.stop(forDictionaryTraining: forDictionaryTraining,
                captureDictionaryPronunciation: captureDictionaryPronunciation)
            stoppedText = text
            stoppedAudio = asr.consumeLastCompletedAudioSnapshot()
            return text
        }
        stopTask = task
        return await task.value
    }

    /// Call synchronously after the caller has accepted or deliberately dismissed a visible result.
    /// Until this handoff, root Stop retains the original local output even if ASR has returned.
    @discardableResult func acknowledgeVisibleResult() -> Bool {
        guard output.isVisible else { return false }
        acceptedVisibleResult = true
        return true
    }

    @discardableResult func complete() async -> Bool {
        if let completionTask { return await completionTask.value }
        let task = Task { @MainActor in
            if !acceptedVisibleResult, !output.isVisible, !preservedConcealedResult {
                preservedConcealedResult = true
                output.preserveLocalResult(text: stoppedText, audio: stoppedAudio)
            }
            guard await finish() else { return false }
            stoppedText = ""; stoppedAudio = nil
            return true
        }
        completionTask = task
        let completed = await task.value
        if !completed { completionTask = nil }
        return completed
    }

    @discardableResult private func finish() async -> Bool {
        guard await output.finish() else { return false }
        isFinished = true
        PrivateProfileService.shared.clearCaptureStopHandler(id: output.id)
        return true
    }
}
#endif
