import Foundation

// Hardware-free substitutes only for ASR and the root Stop callback registry.
// The capture holder, profile boundary, history writer and audio persistence are production sources.
enum AudioCaptureStartOutcome: Equatable { case started, alreadyActive, failed }

@MainActor final class ASRService {
    var isRunningOrStarting = false
    var isStarting = false
    var isRunning: Bool { isRunningOrStarting && !isStarting }
    var isDictionaryTrainingCaptureActive = false
    func cancelPendingAudioCaptureStart(reason: String) async { isRunningOrStarting = false; isStarting = false }
    var starts = 0
    var stops = 0
    var trainingStarts: [Bool] = []
    var trainingStops: [Bool] = []
    var startGate: DirectCaptureSignal?
    var stopGate: DirectCaptureSignal?
    var outcome: AudioCaptureStartOutcome = .started
    var text = "synthetic original input"
    var audio: DictationAudioSnapshot?
    func start(forDictionaryTraining: Bool = false, requiresPronunciation: Bool = true,
               onCaptureStarted: (@MainActor () -> Void)? = nil) async -> AudioCaptureStartOutcome {
        starts += 1; trainingStarts.append(forDictionaryTraining)
        isRunningOrStarting = true
        if let startGate { await startGate.wait() }
        if outcome != .started { isRunningOrStarting = false }
        else { onCaptureStarted?() }
        return outcome
    }
    func stop(forDictionaryTraining: Bool = false, captureDictionaryPronunciation: Bool? = nil) async -> String {
        stops += 1; trainingStops.append(forDictionaryTraining)
        if let stopGate { await stopGate.wait() }
        isRunningOrStarting = false
        return text
    }
    func consumeLastCompletedAudioSnapshot() -> DictationAudioSnapshot? {
        defer { audio = nil }; return audio
    }
}

@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    private var callback: (UUID, @MainActor () async -> Void)?
    private var writes: [UUID: Task<Void, Never>] = [:]
    var hasRetainedCaptureStopHandler: Bool { callback != nil }
    @discardableResult func installCaptureStopHandler(id: UUID, stop: @escaping @MainActor () async -> Void) -> Bool {
        guard callback == nil || callback?.0 == id else { return false }
        callback = (id, stop); return true
    }
    func clearCaptureStopHandler(id: UUID) { if callback?.0 == id { callback = nil } }
    func requestCaptureStop() async { await callback?.1() }
    func retainPrivateWrite(_ task: Task<Void, Never>, id: UUID) { writes[id] = task }
    func finishPrivateWrite(id: UUID) { writes.removeValue(forKey: id) }
}

nonisolated final class DirectCaptureSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.withLock {
            signaled = true
            let current = waiters; waiters = []
            for waiter in current { waiter.resume() }
        }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { if signaled { continuation.resume() } else { waiters.append(continuation) } }
        }
    }
}
