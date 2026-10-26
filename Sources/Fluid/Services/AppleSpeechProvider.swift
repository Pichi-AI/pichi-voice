import AVFoundation
import Foundation
import Speech

// MARK: - Apple Speech Provider

/// A TranscriptionProvider that uses Apple's native SFSpeechRecognizer.
/// This uses Apple's system speech path and lets macOS choose local or online recognition.
final class AppleSpeechProvider: TranscriptionProvider {
    var name: String { "Apple Speech (Legacy)" }

    /// Always available on macOS 10.15+ (Catalina and later)
    var isAvailable: Bool {
        SFSpeechRecognizer.authorizationStatus() != .restricted
    }

    /// Apple Speech is "always ready" (no downloads needed),
    /// but we track if we've checked permissions.
    private(set) var isReady: Bool = false

    /// The recognizer instance. We intentionally re-create it if the locale changes,
    /// using the language selected in Voice Engine/onboarding.
    private var recognizer: SFSpeechRecognizer?
    private var recognizerLocaleIdentifier: String?

    // MARK: - Dictation capture configuration

    private struct DictationCaptureConfiguration {
        let leaseID: UUID
        let locale: Locale
    }

    private let dictationCaptureLock = NSRecursiveLock()
    private var dictationCaptureConfiguration: DictationCaptureConfiguration?
    private var recognitionOperations: [UUID: AppleSpeechRecognitionOperation] = [:]
    private var isEndingAdmission = false

    func beginAdmittedTranscription(leaseID: UUID) throws {
        try self.dictationCaptureLock.withLock {
            guard !self.isEndingAdmission else { throw CancellationError() }
            if let capture = self.dictationCaptureConfiguration {
                guard capture.leaseID == leaseID else {
                    throw CancellationError()
                }
                return
            }
            self.dictationCaptureConfiguration = DictationCaptureConfiguration(
                leaseID: leaseID, locale: self.selectedSpeechLocale
            )
        }
    }

    func endAdmittedTranscription(leaseID: UUID) async {
        let operations = self.dictationCaptureLock.withLock { () -> [AppleSpeechRecognitionOperation]? in
            guard self.dictationCaptureConfiguration?.leaseID == leaseID else { return nil }
            self.isEndingAdmission = true
            return Array(self.recognitionOperations.values)
        }
        guard let operations else { return }
        for operation in operations { operation.cancel() }
        for operation in operations { await operation.waitUntilFinished() }
        self.dictationCaptureLock.withLock {
            guard self.dictationCaptureConfiguration?.leaseID == leaseID else { return }
            self.dictationCaptureConfiguration = nil
            self.isEndingAdmission = false
        }
    }

    private var selectedSpeechLocale: Locale {
        self.dictationCaptureLock.withLock {
            self.dictationCaptureConfiguration?.locale ?? SettingsStore.shared.selectedAppleSpeechLocale
        }
    }

    // MARK: - Provider initialization

    init() {
        _ = self.updateRecognizerIfNeeded()
    }

    // MARK: - Lifecycle

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        // 1. Request Authorization
        let status = await self.requestAuthorization()

        switch status {
        case .authorized:
            self.isReady = true
            DebugLogger.shared.info("AppleSpeechProvider authorized and ready", source: "AppleSpeechProvider")
        case .denied:
            throw NSError(domain: "AppleSpeechProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Speech recognition permission denied"])
        case .restricted:
            throw NSError(domain: "AppleSpeechProvider", code: 2, userInfo: [NSLocalizedDescriptionKey: "Speech recognition is restricted on this device"])
        case .notDetermined:
            // Should not happen after requestAuthorization returns, but handled for safety
            self.isReady = false
        @unknown default:
            self.isReady = false
        }
    }

    func clearCache() async throws {
        // No cache to clear for system speech
    }

    func modelsExistOnDisk() -> Bool {
        return true // System models are always "on disk"
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isAvailable else {
            throw NSError(domain: "AppleSpeechProvider", code: 3, userInfo: [NSLocalizedDescriptionKey: "Speech recognition unavailable"])
        }

        // 1. Convert [Float] samples to AVAudioPCMBuffer
        guard let buffer = self.createPCMBuffer(from: samples) else {
            throw NSError(domain: "AppleSpeechProvider", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"])
        }

        // 2. Ensure recognizer exists for the selected speech language
        guard let recognizer = self.updateRecognizerIfNeeded() else {
            throw NSError(domain: "AppleSpeechProvider", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to initialize SFSpeechRecognizer"])
        }

        if !recognizer.isAvailable {
            throw NSError(domain: "AppleSpeechProvider", code: 6, userInfo: [NSLocalizedDescriptionKey: "SFSpeechRecognizer is currently unavailable"])
        }

        // 3. Create Request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false // We want the final result for this chunk
        request.requiresOnDeviceRecognition = false // Allow macOS to use the best available Apple speech path.
        request.append(buffer)
        request.endAudio() // Signal that this buffer is the complete utterance for this request

        // The delegate owns both the request and task until Apple's terminal callback.
        // Cancellation may arrive before recognitionTask has returned its handle.
        let operation = AppleSpeechRecognitionOperation(request: request)
        let operationID = UUID()
        try self.dictationCaptureLock.withLock {
            guard !self.isEndingAdmission else { throw CancellationError() }
            self.recognitionOperations[operationID] = operation
        }
        defer {
            self.dictationCaptureLock.withLock { self.recognitionOperations[operationID] = nil }
            operation.finishJoining()
        }
        return try await withTaskCancellationHandler {
            if Task.isCancelled { operation.cancel() }
            let result = await operation.recognize(using: recognizer)
            try Task.checkCancellation()
            try operation.checkCancellation()
            return try result.get()
        } onCancel: {
            operation.cancel()
        }
    }

    // MARK: - Helpers

    private func updateRecognizerIfNeeded() -> SFSpeechRecognizer? {
        let locale = self.selectedSpeechLocale
        let localeIdentifier = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if self.recognizer == nil || self.recognizerLocaleIdentifier != localeIdentifier {
            self.recognizer = SFSpeechRecognizer(locale: locale)
            self.recognizerLocaleIdentifier = localeIdentifier
        }
        return self.recognizer
    }

    /// Converts raw [Float] samples (16kHz mono) to AVAudioPCMBuffer
    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        // Define format: 16kHz, Mono, Float32 (standard for ML/ASR)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        // Efficient copy
        guard let channelData = buffer.floatChannelData else { return nil }

        // Use withUnsafeBufferPointer for safe memory access
        samples.withUnsafeBufferPointer { samplePtr in
            guard let baseAddress = samplePtr.baseAddress else { return }
            // Copy memory from array to AVAudioPCMBuffer
            // channelData[0] is UnsafeMutablePointer<Float>
            channelData[0].update(from: baseAddress, count: samples.count)
        }

        return buffer
    }

    /// Structured concurrency wrapper for authorization
    private func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

// MARK: - Legacy recognition ownership

/// The system does not retain a recognition delegate. Keep it, the input request and
/// the task alive until a finish or cancellation callback, including startup races.
final nonisolated class AppleSpeechRecognitionOperation: NSObject, SFSpeechRecognitionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var cancelled = false
    private var terminal = false
    private var handleInstalled = false
    private var joined = false
    private var text = ""
    private var continuation: CheckedContinuation<Result<ASRTranscriptionResult, Error>, Never>?
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []

    init(request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }

    func recognize(using recognizer: SFSpeechRecognizer) async -> Result<ASRTranscriptionResult, Error> {
        await withCheckedContinuation { continuation in
            self.lock.withLock { self.continuation = continuation }
            // Always install the handle, even if cancellation raced the synchronous SDK call.
            let request = self.lock.withLock { self.request! }
            let task = recognizer.recognitionTask(with: request, delegate: self)
            let cancelled = self.lock.withLock {
                self.task = task
                self.handleInstalled = true
                return self.cancelled
            }
            if cancelled { task.cancel() }
            self.deliverTerminalIfReady()
        }
    }

    func checkCancellation() throws {
        if self.lock.withLock({ self.cancelled }) { throw CancellationError() }
    }

    func cancel() {
        let resources = self.lock.withLock { () -> (SFSpeechAudioBufferRecognitionRequest?, SFSpeechRecognitionTask?) in
            self.cancelled = true
            return (self.request, self.task)
        }
        resources.0?.endAudio()
        resources.1?.cancel()
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishRecognition result: SFSpeechRecognitionResult) {
        self.lock.withLock {
            guard !self.cancelled, !self.terminal else { return }
            self.text = result.bestTranscription.formattedString
        }
    }

    func speechRecognitionTask(_ task: SFSpeechRecognitionTask, didFinishSuccessfully successfully: Bool) {
        self.lock.withLock { self.terminal = true }
        self.deliverTerminalIfReady()
    }

    func speechRecognitionTaskWasCancelled(_ task: SFSpeechRecognitionTask) {
        self.lock.withLock {
            self.cancelled = true
            self.terminal = true
        }
        self.deliverTerminalIfReady()
    }

    private func deliverTerminalIfReady() {
        let delivery = self.lock.withLock { () -> (CheckedContinuation<Result<ASRTranscriptionResult, Error>, Never>, Result<ASRTranscriptionResult, Error>)? in
            guard self.terminal, self.handleInstalled, let continuation = self.continuation else { return nil }
            self.continuation = nil
            let result: Result<ASRTranscriptionResult, Error> = self.cancelled
                ? .failure(CancellationError())
                : .success(ASRTranscriptionResult(text: self.text, confidence: self.text.isEmpty ? 0 : 1))
            self.request = nil
            self.task = nil
            return (continuation, result)
        }
        if let delivery { delivery.0.resume(returning: delivery.1) }
    }

    /// Separate terminal system completion from return of the provider's Swift work.
    func finishJoining() {
        let waiters = self.lock.withLock {
            self.joined = true
            let waiters = self.joinWaiters
            self.joinWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilFinished() async {
        await withCheckedContinuation { continuation in
            let ready = self.lock.withLock {
                guard !self.joined else { return true }
                self.joinWaiters.append(continuation)
                return false
            }
            if ready { continuation.resume() }
        }
    }
}
