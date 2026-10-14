import Foundation
import CryptoKit
import TranscribeCpp
#if os(iOS)
import Darwin
#endif

/// Aggregate diagnostics only. No PCM is retained; thresholds describe sample
/// amplitude, not voice activity or a decision to discard quiet speech.
nonisolated struct WhisperSignalDiagnostics: Sendable, Equatable {
    static let sampleRate = 16_000
    static let quietAmplitude: Double = 0.001 // -60 dBFS per sample, not a VAD threshold.
    let sampleCount: Int
    let rms: Double
    let peak: Double
    let dc: Double
    let clippingFraction: Double
    let quietFraction: Double

    var durationMilliseconds: Double { Double(sampleCount) * 1_000 / Double(Self.sampleRate) }

    /// Also performs the provider's finite-input validation in the same pass.
    static func measure(_ samples: [Float]) -> Self? {
        guard !samples.isEmpty else { return nil }
        var squares: Double = 0
        var sum: Double = 0
        var peak: Double = 0
        var clipped = 0
        var quiet = 0
        for sample in samples {
            guard sample.isFinite else { return nil }
            let value = Double(sample)
            let amplitude = abs(value)
            squares += value * value
            sum += value
            peak = max(peak, amplitude)
            if amplitude >= 1 { clipped += 1 }
            if amplitude <= Self.quietAmplitude { quiet += 1 }
        }
        let count = Double(samples.count)
        return .init(sampleCount: samples.count, rms: sqrt(squares / count), peak: peak,
                     dc: sum / count, clippingFraction: Double(clipped) / count,
                     quietFraction: Double(quiet) / count)
    }
}

/// The library calls token.p a family-specific confidence hint. This summary
/// does not replace the app's confidence contract or imply calibrated accuracy.
nonisolated struct WhisperProbabilityDiagnostics: Sendable, Equatable {
    let validCount: Int
    let invalidCount: Int
    let mean: Double?

    static func measure<S: Sequence>(_ probabilities: S) -> Self where S.Element == Float {
        var count = 0
        var invalid = 0
        var sum: Double = 0
        for probability in probabilities {
            guard probability.isFinite, probability >= 0, probability <= 1 else {
                invalid += 1
                continue
            }
            count += 1
            sum += Double(probability)
        }
        return .init(validCount: count, invalidCount: invalid, mean: count == 0 ? nil : sum / Double(count))
    }

    /// Only registered language codes enter support logs, never arbitrary strings
    /// passed through the library's language fields.
    static func languageField(_ value: String?, supportedCodes: Set<String>, absent: String) -> String {
        guard let value else { return absent }
        return supportedCodes.contains(value) ? value : "unsupported"
    }

    /// Native timing zero means unmeasured. Invalid values must not look like a
    /// fast measured stage or enter logs as NaN/Inf.
    static func timingField(_ milliseconds: Float) -> String {
        guard milliseconds.isFinite, milliseconds > 0 else { return "unmeasured" }
        return String(format: "%.3f", milliseconds)
    }
}

/// TranscriptionProvider implementation using transcribe.cpp for Whisper GGUF models.
final class WhisperProvider: TranscriptionProvider {
    let name = "Whisper (Universal)"

    var isAvailable: Bool {
        guard case .success = Self.backendInitialization else { return false }
        return Transcribe.backendAvailable(Self.platformBackend)
    }

    private static let backendInitialization: Result<Void, Error> = Result {
        try Transcribe.initBackends()
    }

    private let stateLock = NSLock()
    private var model: Model?
    private var session: Session?
    private var ready = false
    private var loadedModelName: String?

    private let overriddenModelDirectory: URL?
    private let urlSession: URLSession
    private let languageCodeOverride: String?
    private let useAutomaticLanguageDetection: Bool
    private let expectedArtifactFingerprint: String?

    let modelOverride: SettingsStore.SpeechModel?

    init(
        modelDirectory: URL? = nil,
        urlSession: URLSession = .shared,
        modelOverride: SettingsStore.SpeechModel? = nil,
        languageCodeOverride: String? = nil,
        useAutomaticLanguageDetection: Bool = false,
        expectedArtifactFingerprint: String? = nil
    ) {
        self.overriddenModelDirectory = modelDirectory
        self.urlSession = urlSession
        self.modelOverride = modelOverride
        self.languageCodeOverride = languageCodeOverride
        self.useAutomaticLanguageDetection = useAutomaticLanguageDetection
        self.expectedArtifactFingerprint = expectedArtifactFingerprint
    }

    /// Meeting policy is immutable, including automatic detection. An automatic meeting
    /// never follows the dictation language preference after the attempt has started.
    convenience init(meetingConfiguration configuration: MeetingFinalProcessingConfiguration) throws {
        let options = try MeetingProviderOptions.resolve(configuration)
        guard options.model.isWhisperModel else {
            throw MeetingProviderOptionsError.unsupportedASRModel(configuration.asrModel)
        }
        self.init(
            modelDirectory: configuration.asrArtifactDirectory,
            modelOverride: options.model,
            languageCodeOverride: configuration.languageCode,
            useAutomaticLanguageDetection: configuration.languageCode == "auto",
            expectedArtifactFingerprint: configuration.asrArtifactFingerprint
        )
    }

    deinit {
        self.unloadModel()
    }

    var isReady: Bool {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.ready
    }

    var supportsWordTimings: Bool {
        self.stateLock.withLock {
            guard let maximum = self.model?.capabilities.maxTimestampKind else { return false }
            return maximum == .word || maximum == .token
        }
    }

    private var selectedModel: SettingsStore.SpeechModel {
        self.modelOverride ?? SettingsStore.shared.selectedSpeechModel
    }

    private var modelName: String {
        self.selectedModel.whisperModelFile ?? "whisper-base-Q8_0.gguf"
    }

    private var legacyModelName: String? {
        self.selectedModel.legacyWhisperModelFile
    }

    private var modelURL: URL {
        self.modelDirectory.appendingPathComponent(self.modelName)
    }

    private var legacyModelURL: URL? {
        self.legacyModelName.map { self.modelDirectory.appendingPathComponent($0) }
    }

    private var modelDirectory: URL {
        if let overriddenModelDirectory {
            return overriddenModelDirectory
        }
        return AppBrand.cachesDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
    }

    private var modelDownloadURL: URL? {
        let modelName = self.modelName
        let suffix = "-Q8_0.gguf"
        guard modelName.hasSuffix(suffix) else { return nil }
        let repoName = String(modelName.dropLast(suffix.count))
        return URL(string: "https://huggingface.co/handy-computer/\(repoName)-gguf/resolve/main/\(modelName)")
    }

    static var platformBackend: Backend {
        #if os(iOS)
        // The same resident model remains usable when recording continues in the background.
        // An audio background mode does not authorize Metal command-buffer execution.
        .cpu
        #else
        CPUArchitecture.isAppleSilicon ? .metal : .cpu
        #endif
    }

    private var backend: Backend { Self.platformBackend }

    private func unloadModel() {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.session = nil
        self.model = nil
        self.ready = false
        self.loadedModelName = nil
    }

    private func currentLoadedModelName() -> String? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.loadedModelName
    }

    private func installModel(_ model: Model, session: Session, modelName: String) {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        self.model = model
        self.session = session
        self.loadedModelName = modelName
        self.ready = true
    }

    private func activeSession() -> Session? {
        self.stateLock.lock()
        defer { self.stateLock.unlock() }
        return self.session
    }

    private func removeLegacyModelIfNeeded() {
        for legacyFile in SettingsStore.SpeechModel.legacyWhisperModelFiles {
            let url = self.modelDirectory.appendingPathComponent(legacyFile)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
                DebugLogger.shared.info("WhisperProvider: Removed legacy Whisper cache \(legacyFile)", source: "WhisperProvider")
            } catch {
                DebugLogger.shared.warning(
                    "WhisperProvider: Failed to remove legacy Whisper cache \(legacyFile): \(error.localizedDescription)",
                    source: "WhisperProvider"
                )
            }
        }
    }

    private func isModelFileValid(at url: URL, for targetModel: SettingsStore.SpeechModel) -> Bool {
        guard let expectedModelFile = targetModel.whisperModelFile,
              url.lastPathComponent == expectedModelFile
        else {
            return false
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return false
        }
        return size.int64Value == targetModel.expectedDownloadBytes
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()

        let targetModel = self.selectedModel
        let currentModelName = targetModel.whisperModelFile ?? "whisper-base-Q8_0.gguf"

        let loadedModelName = self.currentLoadedModelName()
        if self.isReady, loadedModelName != currentModelName {
            DebugLogger.shared.info(
                "WhisperProvider: Model changed from \(loadedModelName ?? "nil") to \(currentModelName), forcing reload",
                source: "WhisperProvider"
            )
            self.unloadModel()
        }

        guard !self.isReady else { return }

        try Self.backendInitialization.get()
        try self.validateBackendAvailability(for: targetModel)

        try FileManager.default.createDirectory(at: self.modelDirectory, withIntermediateDirectories: true)

        if FileManager.default.fileExists(atPath: self.modelURL.path),
           !self.isModelFileValid(at: self.modelURL, for: targetModel)
        {
            DebugLogger.shared.warning(
                "WhisperProvider: Found invalid model file at \(self.modelURL.path); removing to force re-download",
                source: "WhisperProvider"
            )
            try? FileManager.default.removeItem(at: self.modelURL)
        }

        if !FileManager.default.fileExists(atPath: self.modelURL.path) {
            DebugLogger.shared.info("WhisperProvider: Downloading Whisper GGUF model...", source: "WhisperProvider")
            progressHandler?(.preparingDownload)
            try await self.downloadModel { progress in
                progressHandler?(.downloading(progress))
            }
        }

        guard self.isModelFileValid(at: self.modelURL, for: targetModel) else {
            try? FileManager.default.removeItem(at: self.modelURL)
            throw NSError(
                domain: "WhisperProvider",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model file is missing or corrupted. Please re-download the model."]
            )
        }
        if let expected = self.expectedArtifactFingerprint,
           try Self.installedArtifactFingerprint(for: targetModel, directory: self.modelDirectory) != expected {
            throw NSError(domain: "WhisperProvider", code: -8, userInfo: [
                NSLocalizedDescriptionKey: "The installed Whisper artifact changed after this meeting was scheduled. Start a new processing run.",
            ])
        }
        self.removeLegacyModelIfNeeded()

        let requiredMemoryGB = targetModel.requiredMemoryGB
        let availableMemoryGB = Self.availableMemoryGB()
        DebugLogger.shared.info(
            "WhisperProvider: Memory check - Required: \(String(format: "%.1f", requiredMemoryGB))GB, Available: \(String(format: "%.1f", availableMemoryGB))GB",
            source: "WhisperProvider"
        )

        if availableMemoryGB < requiredMemoryGB {
            let errorMessage = """
            Insufficient memory for \(targetModel.displayName).
            Required: \(String(format: "%.1f", requiredMemoryGB)) GB
            Available: \(String(format: "%.1f", availableMemoryGB)) GB

            Please try a smaller model or close other applications to free up memory.
            """
            DebugLogger.shared.error("WhisperProvider: \(errorMessage)", source: "WhisperProvider")
            throw NSError(
                domain: "WhisperProvider",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: errorMessage]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Loading \(currentModelName) with \(self.backend)", source: "WhisperProvider")
        progressHandler?(.loading)

        let loadedModel = try Model(
            path: self.modelURL.path,
            options: ModelOptions(backend: self.backend)
        )
        let runtimeBackend = loadedModel.backend.lowercased()
        if self.backend == .metal,
           !runtimeBackend.contains("metal"),
           !runtimeBackend.contains("mtl")
        {
            throw NSError(
                domain: "WhisperProvider",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "\(targetModel.displayName) loaded on \(loadedModel.backend), but Metal is required on Apple Silicon."]
            )
        }
        let sessionOptions = SessionOptions()
        let loadedSession = try loadedModel.session(sessionOptions)
        DebugLogger.shared.info(
            "whisper_session requested_threads=\(sessionOptions.nThreads) requested_context=\(sessionOptions.nCtx) threads_policy=library_default",
            source: "WhisperProvider"
        )

        if self.useAutomaticLanguageDetection,
           (!loadedModel.capabilities.supportsLanguageDetect
                || !Set(loadedModel.capabilities.languages).isSuperset(of: ["ru", "en"])) {
            throw NSError(domain: "WhisperProvider", code: -9, userInfo: [
                NSLocalizedDescriptionKey: "This Whisper artifact does not support automatic Russian and English recognition.",
            ])
        }

        try Task.checkCancellation()
        self.installModel(loadedModel, session: loadedSession, modelName: currentModelName)
        DebugLogger.shared.info(
            "WhisperProvider: Model ready (\(currentModelName), backend=\(loadedModel.backend), arch=\(loadedModel.arch))",
            source: "WhisperProvider"
        )
    }

    private func validateBackendAvailability(for model: SettingsStore.SpeechModel) throws {
        if self.backend == .metal, !Transcribe.backendAvailable(.metal) {
            throw NSError(
                domain: "WhisperProvider",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "\(model.displayName) requires the Metal Whisper backend on Apple Silicon."]
            )
        }

        if self.backend == .cpu, !Transcribe.backendAvailable(.cpu) {
            throw NSError(
                domain: "WhisperProvider",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Whisper CPU backend is unavailable on this device."]
            )
        }
    }

    private static func availableMemoryGB() -> Double {
        #if os(iOS)
        // This admission is the existing model's minimum recommended device RAM, not a
        // prediction of free allocation space. iOS owns per-process memory limits, so a
        // desktop count of free/inactive VM pages is not a useful mobile measurement.
        return Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        #else
        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &vmStats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPointer in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPointer, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            DebugLogger.shared.warning("WhisperProvider: Failed to get memory stats, assuming sufficient memory", source: "WhisperProvider")
            return 16.0
        }

        let freePages = UInt64(vmStats.free_count)
        let inactivePages = UInt64(vmStats.inactive_count)
        let purgablePages = UInt64(vmStats.purgeable_count)
        let availableBytes = (freePages + inactivePages + purgablePages) * UInt64(pageSize)
        return Double(availableBytes) / (1024 * 1024 * 1024)
        #endif
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples, languageCode: nil)
    }

    func transcribe(_ samples: [Float], languageCode: String?) async throws -> ASRTranscriptionResult {
        let transcript = try await self.run(samples, languageCode: languageCode, timestamps: .segment)
        let fullText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ASRTranscriptionResult(text: fullText, confidence: 1.0)
    }

    private func run(_ samples: [Float], languageCode: String?, timestamps: TimestampKind) async throws -> Transcript {
        try Task.checkCancellation()
        let minSamples = 1
        guard samples.count >= minSamples else {
            throw NSError(
                domain: "WhisperProvider",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Audio too short for Whisper transcription"]
            )
        }

        guard let session = self.activeSession() else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Whisper model not loaded"]
            )
        }

        guard let signal = WhisperSignalDiagnostics.measure(samples) else {
            throw NSError(domain: "WhisperProvider", code: -10, userInfo: [NSLocalizedDescriptionKey: "The audio contains invalid PCM samples."])
        }

        let resolvedLanguageCode = self.resolvedLanguageCode(explicit: languageCode)
        // A capture stop may leave less than one second of speech. Pad inside the
        // inference adapter so the sink keeps the original physical clock and PCM
        // bound; no temporary WAV or fabricated final duration is needed.
        let inferenceSamples = samples.count < 16_000
            ? samples + [Float](repeating: 0, count: 16_000 - samples.count)
            : samples
        let options = Self.runOptions(languageCode: resolvedLanguageCode, timestamps: timestamps)
        let supportedCodes = VoiceEngineLanguageCatalog.whisperSupportedLanguageCodes
        let requestedLanguage = WhisperProbabilityDiagnostics.languageField(options.language, supportedCodes: supportedCodes, absent: "auto")
        let targetLanguage = WhisperProbabilityDiagnostics.languageField(options.targetLanguage, supportedCodes: supportedCodes, absent: "none")
        let autodetect = options.language == nil
        let requestedTask = options.task == .transcribe ? "transcribe" : "translate"
        let requestedTimestamps = Self.timestampLabel(options.timestamps)
        let inferenceSampleCount = inferenceSamples.count
        DebugLogger.shared.logLazy(source: "WhisperProvider") {
            "whisper_input samples=\(signal.sampleCount) sample_rate=\(WhisperSignalDiagnostics.sampleRate) " +
                "audio_ms=\(String(format: "%.3f", signal.durationMilliseconds)) inference_samples=\(inferenceSampleCount) " +
                "rms=\(String(format: "%.6f", signal.rms)) peak=\(String(format: "%.6f", signal.peak)) " +
                "dc=\(String(format: "%.6f", signal.dc)) clipping_fraction=\(String(format: "%.6f", signal.clippingFraction)) " +
                "quiet_fraction=\(String(format: "%.6f", signal.quietFraction)) quiet_amplitude=\(WhisperSignalDiagnostics.quietAmplitude) " +
                "language=\(requestedLanguage) autodetect=\(autodetect) task=\(requestedTask) " +
                "target_language=\(targetLanguage) timestamps=\(requestedTimestamps)"
        }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let transcript = try await session.run(inferenceSamples, options: options)
            let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let probabilities = WhisperProbabilityDiagnostics.measure(transcript.tokens.lazy.map(\.p))
            let language = WhisperProbabilityDiagnostics.languageField(transcript.language, supportedCodes: supportedCodes, absent: "unavailable")
            let returnedTimestamps = Self.timestampLabel(transcript.timestampKind)
            let segmentCount = transcript.segments.count
            let wordCount = transcript.words.count
            let tokenCount = transcript.tokens.count
            let timings = transcript.timings
            // Capture only aggregates, so the asynchronous logger never retains the
            // transcript, its tokens/text, or the input sample array.
            DebugLogger.shared.logLazy(source: "WhisperProvider") {
                "whisper_output wall_ms=\(String(format: "%.3f", wallMilliseconds)) language=\(language) " +
                    "timestamps=\(returnedTimestamps) segments=\(segmentCount) words=\(wordCount) tokens=\(tokenCount) " +
                    "token_p_valid=\(probabilities.validCount) token_p_invalid=\(probabilities.invalidCount) " +
                    "token_p_mean=\(probabilities.mean.map { String(format: "%.6f", $0) } ?? "unavailable") " +
                    "mel_ms=\(WhisperProbabilityDiagnostics.timingField(timings.melMs)) " +
                    "encode_ms=\(WhisperProbabilityDiagnostics.timingField(timings.encodeMs)) " +
                    "decode_ms=\(WhisperProbabilityDiagnostics.timingField(timings.decodeMs))"
            }
            return transcript
        } catch {
            let wallMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000
            let cancelled = Task.isCancelled
            DebugLogger.shared.logLazy(level: .warning, source: "WhisperProvider") {
                "whisper_failure wall_ms=\(String(format: "%.3f", wallMilliseconds)) cancelled=\(cancelled)"
            }
            throw error
        }
    }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        guard self.supportsWordTimings else { return try (await self.transcribe(samples), []) }
        let transcript = try await self.run(samples, languageCode: nil, timestamps: .word)
        let duration = Double(samples.count) / 16_000
        let words = transcript.words.compactMap { word -> ASRWordTiming? in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let start = Double(word.t0Ms) / 1000
            let end = Double(word.t1Ms) / 1000
            guard !text.isEmpty, start >= 0, end > start, end <= duration + 1e-6 else { return nil }
            return ASRWordTiming(text: text, start: start, end: end)
        }
        // Partial timing evidence must not lose wording from an unaligned tail.
        return (ASRTranscriptionResult(text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)),
                words.count == transcript.words.count ? words : [])
    }

    static func runOptions(languageCode: String?, timestamps: TimestampKind = .segment) -> RunOptions {
        RunOptions(timestamps: timestamps, language: languageCode == "auto" ? nil : languageCode)
    }

    private static func timestampLabel(_ kind: TimestampKind) -> String {
        switch kind {
        case .none: "none"
        case .auto: "auto"
        case .segment: "segment"
        case .word: "word"
        case .token: "token"
        }
    }

    func resolvedLanguageCode(explicit: String? = nil) -> String? {
        if let explicit { return explicit == "auto" ? nil : explicit }
        if self.useAutomaticLanguageDetection { return nil }
        let selected = self.languageCodeOverride ?? SettingsStore.shared.selectedWhisperLanguageCode
        return selected == "auto" ? nil : selected
    }

    func releaseResidency() async { self.unloadModel() }
    var shouldClearCacheAfterCancellation: Bool { self.overriddenModelDirectory == nil && self.expectedArtifactFingerprint == nil }

    /// The loader consumes GGUF, not legacy whisper.cpp GGML `.bin` exports. Inspect the
    /// installed selected artifact once at attempt snapshot/preparation, never on UI render.
    static func installedArtifactFingerprint(for model: SettingsStore.SpeechModel, directory: URL? = nil) throws -> String? {
        guard let file = model.whisperModelFile else { return nil }
        let root = directory ?? AppBrand.cachesDirectory.appendingPathComponent("WhisperModels", isDirectory: true)
        let url = root.appendingPathComponent(file)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.int64Value == model.expectedDownloadBytes,
              attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var digest = SHA256()
        while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
            try Task.checkCancellation()
            digest.update(data: bytes)
        }
        return "sha256:" + digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func modelsExistOnDisk() -> Bool {
        return self.isModelFileValid(at: self.modelURL, for: self.selectedModel)
    }

    func clearCache() async throws {
        self.unloadModel()
        let files = [self.modelURL, self.legacyModelURL].compactMap { $0 }
        let directory = self.modelDirectory
        try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            for file in files where manager.fileExists(atPath: file.path) {
                try manager.removeItem(at: file)
            }
            if manager.fileExists(atPath: directory.path),
               try manager.contentsOfDirectory(atPath: directory.path).isEmpty
            {
                try manager.removeItem(at: directory)
            }
        }.value
    }

    private func downloadModel(progressHandler: ((Double) -> Void)?) async throws {
        guard let url = self.modelDownloadURL else {
            throw NSError(
                domain: "WhisperProvider",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Whisper model URL"]
            )
        }

        DebugLogger.shared.info("WhisperProvider: Downloading from \(url.absoluteString)", source: "WhisperProvider")

        let maxAttempts = 3
        for attempt in 1...maxAttempts {
            do {
                if attempt == 1 {
                    progressHandler?(0.0)
                }
                try await self.downloadFile(from: url, to: self.modelURL, progressHandler: progressHandler)
                DebugLogger.shared.info("WhisperProvider: Model downloaded successfully", source: "WhisperProvider")
                return
            } catch let error as NSError {
                if Task.isCancelled
                    || (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
                {
                    throw CancellationError()
                }

                let isLastAttempt = attempt == maxAttempts
                if error.domain == NSURLErrorDomain {
                    let message: String
                    switch error.code {
                    case NSURLErrorNotConnectedToInternet:
                        message = "No internet connection. Please connect to the internet to download the Whisper model."
                    case NSURLErrorTimedOut:
                        message = "Download timed out. Please check your internet connection and try again."
                    case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
                        message = "Cannot reach download server. Please check your internet connection."
                    default:
                        message = "Network error: \(error.localizedDescription)"
                    }

                    if isLastAttempt {
                        throw NSError(
                            domain: "WhisperProvider",
                            code: error.code,
                            userInfo: [NSLocalizedDescriptionKey: message]
                        )
                    }
                    DebugLogger.shared.warning(
                        "WhisperProvider: Download attempt \(attempt)/\(maxAttempts) failed (\(message)). Retrying...",
                        source: "WhisperProvider"
                    )
                } else {
                    if isLastAttempt { throw error }
                    DebugLogger.shared.warning(
                        "WhisperProvider: Download attempt \(attempt)/\(maxAttempts) failed (\(error.localizedDescription)). Retrying...",
                        source: "WhisperProvider"
                    )
                }

                let delayNanos = UInt64(1_000_000_000) << UInt64(attempt - 1)
                try await Task.sleep(nanoseconds: delayNanos)
            }
        }
    }

    private func downloadFile(from url: URL, to destination: URL, progressHandler: ((Double) -> Void)?) async throws {
        var temporaryURL: URL?
        do {
            let (downloadedURL, response) = try await ProgressiveFileDownloader.download(
                from: url,
                configuration: self.urlSession.configuration
            ) { totalBytesWritten, totalBytesExpectedToWrite in
                guard totalBytesExpectedToWrite > 0 else { return }
                let pct = min(0.999, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
                progressHandler?(pct)
            }
            temporaryURL = downloadedURL
            try Task.checkCancellation()

            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid server response"]
                )
            }
            guard httpResponse.statusCode == 200 else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to download model (HTTP \(httpResponse.statusCode))"]
                )
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: downloadedURL.path)
            let actualBytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard actualBytes > 0 else {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model is empty. Please try again."]
                )
            }
            if httpResponse.expectedContentLength > 0,
               actualBytes != httpResponse.expectedContentLength
            {
                throw NSError(
                    domain: "WhisperProvider",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Downloaded model size mismatch. Please try again."]
                )
            }

            try Task.checkCancellation()
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: downloadedURL, to: destination)
            temporaryURL = nil
            try Task.checkCancellation()
        } catch {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
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
        progressHandler?(1.0)
    }
}
