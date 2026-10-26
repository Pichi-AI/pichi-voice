import AVFoundation
import Combine
import Foundation

#if canImport(Speech)
import Speech
#endif

// MARK: - Apple Speech Analyzer Provider (macOS 26+)

/// A TranscriptionProvider that uses Apple's new SpeechAnalyzer API (macOS 26+).
/// This provides advanced speech-to-text with streaming capabilities.
@available(macOS 26.0, *)
final class AppleSpeechAnalyzerProvider: TranscriptionProvider {
    var name: String { "Apple Speech (macOS 26+)" }

    var isAvailable: Bool {
        // SpeechAnalyzer is always available on macOS 26+
        true
    }

    private(set) var isReady: Bool = false
    var shouldClearCacheAfterCancellation: Bool { false }

    /// Buffer converter for audio format conversion
    private var converter: BufferConverter?

    /// The required audio format for the analyzer
    private var analyzerFormat: AVAudioFormat?
    private var preparedLocale: Locale?
    private let captureLock = NSRecursiveLock()
    private var dictationCaptureLocale: (leaseID: UUID, locale: Locale)?
    private var analysisOperations: [UUID: AppleSpeechAnalyzerOperation] = [:]
    private var isEndingAdmission = false

    func beginAdmittedTranscription(leaseID: UUID) throws {
        try self.captureLock.withLock {
            guard !self.isEndingAdmission else { throw CancellationError() }
            if let capture = self.dictationCaptureLocale {
                guard capture.leaseID == leaseID else { throw CancellationError() }
                return
            }
            self.dictationCaptureLocale = (leaseID, self.preparedLocale ?? self.selectedSpeechLocale())
        }
    }

    func endAdmittedTranscription(leaseID: UUID) async {
        let operations = self.captureLock.withLock { () -> [AppleSpeechAnalyzerOperation]? in
            guard self.dictationCaptureLocale?.leaseID == leaseID else { return nil }
            self.isEndingAdmission = true
            return Array(self.analysisOperations.values)
        }
        guard let operations else { return }
        for operation in operations { operation.cancel() }
        for operation in operations { await operation.waitUntilFinished() }
        self.captureLock.withLock {
            guard self.dictationCaptureLocale?.leaseID == leaseID else { return }
            self.dictationCaptureLocale = nil
            self.isEndingAdmission = false
        }
    }

    /// Thread-safe cache for model installation status.
    /// Protected by `_cacheQueue` for thread-safe access from both sync and async contexts.
    private var _modelsInstalledCache: Bool = false
    private let _cacheQueue = DispatchQueue(label: "com.fluidvoice.speechanalyzer.cache")

    init() {}

    // MARK: - Lifecycle

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        try Task.checkCancellation()
        let locale = self.selectedSpeechLocale()
        let localeID = self.normalizedIdentifier(for: locale)

        // 1. Create a transcriber to check locale support and download if needed
        let transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // 2. Check if locale is supported
        let supportedLocales = await SpeechTranscriber.supportedLocales
        try Task.checkCancellation()
        let isSupported = supportedLocales.map { self.normalizedIdentifier(for: $0) }.contains(localeID)

        guard isSupported else {
            throw NSError(
                domain: "AppleSpeechAnalyzerProvider",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Current locale is not supported by SpeechAnalyzer"]
            )
        }

        // 3. Check if model is installed, download if needed
        let installedLocales = await SpeechTranscriber.installedLocales
        try Task.checkCancellation()
        let isInstalled = installedLocales.map { self.normalizedIdentifier(for: $0) }.contains(localeID)

        if !isInstalled {
            DebugLogger.shared.info("Downloading speech model for locale: \(localeID)", source: "AppleSpeechAnalyzerProvider")
            if let downloader = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                progressHandler?(.preparingDownload)
                // Report progress periodically during download
                let progress = downloader.progress
                let progressTask = Task {
                    while !Task.isCancelled, !progress.isFinished, !progress.isCancelled {
                        progressHandler?(.downloading(progress.fractionCompleted))
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
                defer { progressTask.cancel() }

                do {
                    try await withTaskCancellationHandler {
                        try await downloader.downloadAndInstall()
                    } onCancel: {
                        progress.cancel()
                    }
                } catch {
                    let nsError = error as NSError
                    if Task.isCancelled
                        || error is CancellationError
                        || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
                    {
                        throw CancellationError()
                    }
                    throw error
                }
                try Task.checkCancellation()
                progressHandler?(.optimizing)
            }
        }

        // 4. Get the best available audio format for conversion
        progressHandler?(.loading)
        self.analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try Task.checkCancellation()
        self.converter = BufferConverter()
        self.preparedLocale = locale

        try Task.checkCancellation()
        self.isReady = true

        // Update cache to reflect that model is now installed (thread-safe)
        self._cacheQueue.sync { self._modelsInstalledCache = true }

        DebugLogger.shared.info("AppleSpeechAnalyzerProvider ready", source: "AppleSpeechAnalyzerProvider")
    }

    func clearCache() async throws {
        // Release reserved locales
        let reserved = await AssetInventory.reservedLocales
        for locale in reserved {
            await AssetInventory.release(reservedLocale: locale)
        }

        // Reset cache to reflect models are no longer installed (thread-safe)
        self._cacheQueue.sync { self._modelsInstalledCache = false }

        self.isReady = false
        self.preparedLocale = nil
    }

    /// Returns the cached result of whether models are installed (thread-safe).
    ///
    /// **Important**: This method returns a cached value that defaults to `false`.
    /// For an accurate result, call `refreshModelsExistOnDiskAsync()` first.
    ///
    /// The synchronous nature of this protocol method makes it impossible to
    /// perform the actual async `SpeechTranscriber.installedLocales` check inline.
    /// Callers should use `refreshModelsExistOnDiskAsync()` during initialization
    /// to populate the cache before relying on this value.
    func modelsExistOnDisk() -> Bool {
        return self._cacheQueue.sync { self._modelsInstalledCache }
    }

    /// Performs an async check to determine if speech models are installed for the current locale.
    /// Updates the internal cache so that subsequent `modelsExistOnDisk()` calls return accurate results.
    /// Thread-safe: uses dispatch queue to update cache.
    ///
    /// - Returns: `true` if the current locale's speech model is installed on disk, `false` otherwise.
    func refreshModelsExistOnDiskAsync() async -> Bool {
        let installedLocales = await SpeechTranscriber.installedLocales
        let localeID = self.normalizedIdentifier(for: self.selectedSpeechLocale())
        let isInstalled = installedLocales.map { self.normalizedIdentifier(for: $0) }.contains(localeID)

        self._cacheQueue.sync { self._modelsInstalledCache = isInstalled }

        DebugLogger.shared.debug(
            "AppleSpeechAnalyzer: Model installed check - locale: \(localeID), installed: \(isInstalled)",
            source: "AppleSpeechAnalyzerProvider"
        )

        return isInstalled
    }

    // MARK: - Transcription

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isReady, let analyzerFormat = self.analyzerFormat else {
            throw NSError(
                domain: "AppleSpeechAnalyzerProvider",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Speech Analyzer not ready"]
            )
        }

        DebugLogger.shared.debug("AppleSpeechAnalyzer: Starting transcription with \(samples.count) samples", source: "AppleSpeechAnalyzerProvider")
        let transcriptionLocale = self.captureLock.withLock {
            self.dictationCaptureLocale?.locale ?? self.preparedLocale ?? self.selectedSpeechLocale()
        }

        // 1. Create a FRESH transcriber for this transcription
        let freshTranscriber = SpeechTranscriber(
            locale: transcriptionLocale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: []
        )

        // 4. Convert samples to AVAudioPCMBuffer
        guard let buffer = createPCMBuffer(from: samples) else {
            throw NSError(
                domain: "AppleSpeechAnalyzerProvider",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio buffer"]
            )
        }

        // 5. Convert to analyzer format if needed
        let convertedBuffer: AVAudioPCMBuffer
        if let converter = self.converter {
            do {
                convertedBuffer = try converter.convertBuffer(buffer, to: analyzerFormat)
            } catch {
                DebugLogger.shared.warning("Buffer conversion failed: \(error)", source: "AppleSpeechAnalyzerProvider")
                convertedBuffer = buffer
            }
        } else {
            convertedBuffer = buffer
        }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [freshTranscriber])
        // Return the collected text from its task rather than sharing mutable text
        // between the collector and the provider operation.
        let resultsTask = Task { () throws -> String in
            var finalText = ""
            for try await result in freshTranscriber.results {
                try Task.checkCancellation()
                if result.isFinal {
                    let text = String(result.text.characters)
                    if !finalText.isEmpty && !text.isEmpty { finalText += " " }
                    finalText += text
                }
            }
            try Task.checkCancellation()
            return finalText
        }
        let operation = AppleSpeechAnalyzerOperation(
            resultsTask: resultsTask,
            finishInput: { inputContinuation.finish() },
            cancelAnalyzer: { await analyzer.cancelAndFinishNow() }
        )
        let operationID = UUID()
        let admitted = self.captureLock.withLock {
            guard !self.isEndingAdmission else { return false }
            self.analysisOperations[operationID] = operation
            return true
        }
        guard admitted else {
            await operation.cancelAndJoinWorkers()
            throw CancellationError()
        }
        defer {
            self.captureLock.withLock { self.analysisOperations[operationID] = nil }
            operation.finishJoining()
        }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try operation.checkCancellation()
                try await analyzer.start(inputSequence: inputStream)
                try Task.checkCancellation()
                try operation.checkCancellation()
                inputContinuation.yield(AnalyzerInput(buffer: convertedBuffer))
                inputContinuation.finish()
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let finalText = try await resultsTask.value
                await operation.joinWorkers()
                try Task.checkCancellation()
                try operation.checkCancellation()
                return ASRTranscriptionResult(text: finalText, confidence: 1.0)
            } catch {
                // start and finalize may both throw after the collector has started.
                // No path releases the provider before the input, analyzer and collector join.
                await operation.cancelAndJoinWorkers()
                throw error
            }
        } onCancel: {
            operation.cancel()
        }
    }

    // MARK: - Helpers

    private func selectedSpeechLocale() -> Locale {
        self.captureLock.withLock {
            self.dictationCaptureLocale?.locale ?? SettingsStore.shared.selectedAppleSpeechLocale
        }
    }

    private func normalizedIdentifier(for locale: Locale) -> String {
        locale.identifier(.bcp47).replacingOccurrences(of: "_", with: "-")
    }

    /// Converts raw [Float] samples (16kHz mono) to AVAudioPCMBuffer
    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            return nil
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        guard let channelData = buffer.floatChannelData else { return nil }

        samples.withUnsafeBufferPointer { samplePtr in
            guard let baseAddress = samplePtr.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }

        return buffer
    }
}

// MARK: - Analyzer worker ownership

/// Retains the asynchronous SDK cancellation and collector until both have joined.
/// Its callbacks contain only this analyzer's input and actor, never live settings.
final nonisolated class AppleSpeechAnalyzerOperation: @unchecked Sendable {
    private let lock = NSLock()
    private let resultsTask: Task<String, Error>
    private let finishInput: @Sendable () -> Void
    private let cancelAnalyzer: @Sendable () async -> Void
    private var cancellationTask: Task<Void, Never>?
    private var workersFinished = false
    private var joined = false
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        resultsTask: Task<String, Error>,
        finishInput: @escaping @Sendable () -> Void,
        cancelAnalyzer: @escaping @Sendable () async -> Void
    ) {
        self.resultsTask = resultsTask
        self.finishInput = finishInput
        self.cancelAnalyzer = cancelAnalyzer
    }

    func checkCancellation() throws {
        if self.lock.withLock({ self.cancellationTask != nil }) { throw CancellationError() }
    }

    func cancel() {
        let requested = self.lock.withLock {
            guard !self.workersFinished, self.cancellationTask == nil else { return false }
            self.cancellationTask = Task { await self.cancelAnalyzer() }
            return true
        }
        if requested {
            self.finishInput()
            self.resultsTask.cancel()
        }
    }

    func cancelAndJoinWorkers() async {
        self.cancel()
        await self.joinWorkers()
    }

    func joinWorkers() async {
        let cancellationTask = self.lock.withLock {
            self.workersFinished = true
            return self.cancellationTask
        }
        await cancellationTask?.value
        _ = await self.resultsTask.result
    }

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

// MARK: - Buffer Converter (from Apple's sample)

@available(macOS 26.0, *)
private class BufferConverter {
    enum Error: Swift.Error {
        case failedToCreateConverter
        case failedToCreateConversionBuffer
        case conversionFailed(NSError?)
    }

    private var converter: AVAudioConverter?

    func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let inputFormat = buffer.format
        guard inputFormat != format else {
            return buffer
        }

        if converter == nil || converter?.outputFormat != format {
            converter = AVAudioConverter(from: inputFormat, to: format)
            converter?.primeMethod = .none
        }

        guard let converter else {
            throw Error.failedToCreateConverter
        }

        let sampleRateRatio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let scaledInputFrameLength = Double(buffer.frameLength) * sampleRateRatio
        let frameCapacity = AVAudioFrameCount(scaledInputFrameLength.rounded(.up))

        guard let conversionBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: frameCapacity
        ) else {
            throw Error.failedToCreateConversionBuffer
        }

        var nsError: NSError?
        var bufferProcessed = false

        let status = converter.convert(to: conversionBuffer, error: &nsError) { _, inputStatusPointer in
            defer { bufferProcessed = true }
            inputStatusPointer.pointee = bufferProcessed ? .noDataNow : .haveData
            return bufferProcessed ? nil : buffer
        }

        guard status != .error else {
            throw Error.conversionFailed(nsError)
        }

        return conversionBuffer
    }
}
