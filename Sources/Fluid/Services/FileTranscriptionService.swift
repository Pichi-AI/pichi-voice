import AVFoundation
import Combine
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// One speaker-attributed portion of a file transcription.
nonisolated struct SpeakerTranscriptSegment: Identifiable, Sendable, Codable, Equatable {
    let speaker: String
    let startSeconds: Double
    let endSeconds: Double
    let text: String

    var id: String {
        "\(self.speaker)-\(self.startSeconds)"
    }

    var timestampText: String {
        let total = Int(self.startSeconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var plainText: String {
        "[\(self.timestampText)] \(self.speaker): \(self.text)"
    }

    enum CodingKeys: String, CodingKey {
        case speaker, startSeconds, endSeconds, text
    }
}

/// An audio interval for which speaker-attributed ASR produced no usable text.
nonisolated struct SpeakerTranscriptGap: Sendable, Codable, Equatable {
    let startSeconds: Double
    let endSeconds: Double

    var durationSeconds: Double {
        max(0, self.endSeconds - self.startSeconds)
    }

    var timestampRangeText: String {
        "\(Self.timestamp(self.startSeconds))-\(Self.timestamp(self.endSeconds))"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let safeSeconds = max(0, seconds)
        let wholeMinutes = Int(safeSeconds) / 60
        let remainingSeconds = safeSeconds - Double(wholeMinutes * 60)
        return String(format: "%d:%04.1f", wholeMinutes, remainingSeconds)
    }
}

nonisolated struct SpeakerChunkTranscription: Sendable, Equatable {
    let text: String
    let confidence: Float
}

nonisolated struct SpeakerTurnTranscription: Sendable, Equatable {
    let text: String
    let confidence: Float
    let gaps: [SpeakerTranscriptGap]
}

nonisolated struct SpeakerRecognizedTurn: Sendable, Equatable {
    let speaker: String
    let startSeconds: Double
    let endSeconds: Double
    let transcription: SpeakerTurnTranscription
}

nonisolated struct SpeakerLabeledTranscript: Sendable, Equatable {
    let segments: [SpeakerTranscriptSegment]
    let confidence: Float
    let gaps: [SpeakerTranscriptGap]
    let notice: String?
}

nonisolated struct SpeakerLabelingCoverage: Sendable, Equatable {
    let gapCount: Int
    let skippedDurationSeconds: Double
    let maxGapDurationSeconds: Double
    let diarizedDurationSeconds: Double

    var skippedRatio: Double {
        guard self.diarizedDurationSeconds.isFinite, self.diarizedDurationSeconds > 0 else {
            return self.skippedDurationSeconds > 0 ? .infinity : 0
        }
        return self.skippedDurationSeconds / self.diarizedDurationSeconds
    }
}

nonisolated enum SpeakerLabeledTranscriptionPolicy {
    static func transcribeChunks(
        _ ranges: [SpeakerTranscriptGap],
        operation: (SpeakerTranscriptGap) async throws -> SpeakerChunkTranscription?
    ) async rethrows -> SpeakerTurnTranscription {
        var pieces: [String] = []
        var confidenceSum: Float = 0
        var gaps: [SpeakerTranscriptGap] = []

        for range in ranges {
            let result = try await operation(range)
            let text = result?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, let result else {
                gaps.append(range)
                continue
            }

            pieces.append(text)
            confidenceSum += result.confidence
        }

        let confidence = pieces.isEmpty ? 0 : confidenceSum / Float(pieces.count)
        return SpeakerTurnTranscription(
            text: pieces.joined(separator: " "),
            confidence: confidence,
            gaps: gaps
        )
    }

    static func shouldKeepSpeakerLabels(
        hasRecognizedText: Bool,
        gaps: [SpeakerTranscriptGap],
        diarizedDurationSeconds: Double
    ) -> Bool {
        guard hasRecognizedText else { return false }
        guard !gaps.isEmpty else { return true }
        guard diarizedDurationSeconds.isFinite, diarizedDurationSeconds > 0 else { return false }

        let coverage = self.coverage(
            gaps: gaps,
            diarizedDurationSeconds: diarizedDurationSeconds
        )
        guard coverage.maxGapDurationSeconds <= 5 else { return false }

        let allowedSkippedDuration = min(30, diarizedDurationSeconds * 0.01)
        return coverage.skippedDurationSeconds <= allowedSkippedDuration
    }

    static func coverage(
        gaps: [SpeakerTranscriptGap],
        diarizedDurationSeconds: Double
    ) -> SpeakerLabelingCoverage {
        let durations = gaps.map(\.durationSeconds)
        return SpeakerLabelingCoverage(
            gapCount: gaps.count,
            skippedDurationSeconds: durations.reduce(0, +),
            maxGapDurationSeconds: durations.max() ?? 0,
            diarizedDurationSeconds: diarizedDurationSeconds
        )
    }

    static func fallbackDiagnostic(
        hasRecognizedText: Bool,
        gaps: [SpeakerTranscriptGap],
        diarizedDurationSeconds: Double
    ) -> String {
        guard hasRecognizedText else {
            return "Speaker labeling produced no recognized text"
        }
        guard diarizedDurationSeconds.isFinite, diarizedDurationSeconds > 0 else {
            return "Speaker labeling produced an invalid diarized duration"
        }

        let coverage = self.coverage(
            gaps: gaps,
            diarizedDurationSeconds: diarizedDurationSeconds
        )
        return String(
            format: "Speaker labeling omitted too much audio (gaps=%d, skipped=%.3fs, maxGap=%.3fs, diarized=%.3fs, ratio=%.4f)",
            coverage.gapCount,
            coverage.skippedDurationSeconds,
            coverage.maxGapDurationSeconds,
            coverage.diarizedDurationSeconds,
            coverage.skippedRatio
        )
    }

    static func limitationNotice(for gaps: [SpeakerTranscriptGap]) -> String? {
        guard !gaps.isEmpty else { return nil }
        let noun = gaps.count == 1 ? "section" : "sections"
        let duration = gaps.reduce(0) { $0 + $1.durationSeconds }
        return "Speaker labels were kept, but \(gaps.count) short audio \(noun) totaling \(String(format: "%.1f", duration)) seconds produced no text."
    }

    static func assembleTurns(_ turns: [SpeakerRecognizedTurn]) -> SpeakerLabeledTranscript? {
        let gaps = turns.flatMap(\.transcription.gaps)
        let recognizedTurns = turns.filter {
            !$0.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let diarizedDuration = turns.reduce(0) {
            $0 + max(0, $1.endSeconds - $1.startSeconds)
        }
        guard self.shouldKeepSpeakerLabels(
            hasRecognizedText: !recognizedTurns.isEmpty,
            gaps: gaps,
            diarizedDurationSeconds: diarizedDuration
        ) else {
            return nil
        }

        let segments = recognizedTurns.map { turn in
            SpeakerTranscriptSegment(
                speaker: turn.speaker,
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                text: turn.transcription.text
            )
        }
        let confidence = recognizedTurns.reduce(0) {
            $0 + $1.transcription.confidence
        } / Float(recognizedTurns.count)
        return SpeakerLabeledTranscript(
            segments: segments,
            confidence: confidence,
            gaps: gaps,
            notice: self.limitationNotice(for: gaps)
        )
    }
}

/// Result of a transcription operation
nonisolated struct TranscriptionResult: Identifiable, Sendable, Codable {
    let id: UUID
    let text: String
    let confidence: Float
    let duration: TimeInterval
    let processingTime: TimeInterval
    let fileName: String
    let timestamp: Date
    /// Speaker-attributed segments when diarization was enabled; empty otherwise.
    let speakerSegments: [SpeakerTranscriptSegment]
    /// Persisted explanation when speaker labeling was partial or unavailable.
    let speakerLabelingNotice: String?
    /// Exact intervals omitted from an otherwise accepted speaker-attributed transcript.
    let speakerLabelingGaps: [SpeakerTranscriptGap]

    init(
        id: UUID = UUID(),
        text: String,
        confidence: Float,
        duration: TimeInterval,
        processingTime: TimeInterval,
        fileName: String,
        timestamp: Date = Date(),
        speakerSegments: [SpeakerTranscriptSegment] = [],
        speakerLabelingNotice: String? = nil,
        speakerLabelingGaps: [SpeakerTranscriptGap] = []
    ) {
        self.id = id
        self.text = text
        self.confidence = confidence
        self.duration = duration
        self.processingTime = processingTime
        self.fileName = fileName
        self.timestamp = timestamp
        self.speakerSegments = speakerSegments
        self.speakerLabelingNotice = speakerLabelingNotice
        self.speakerLabelingGaps = speakerLabelingGaps
    }

    enum CodingKeys: String, CodingKey {
        case text, confidence, duration, processingTime, fileName, timestamp, speakerSegments
        case speakerLabelingNotice, speakerLabelingGaps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.text = try c.decode(String.self, forKey: .text)
        self.confidence = try c.decode(Float.self, forKey: .confidence)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.processingTime = try c.decode(TimeInterval.self, forKey: .processingTime)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.speakerSegments = try c.decodeIfPresent([SpeakerTranscriptSegment].self, forKey: .speakerSegments) ?? []
        self.speakerLabelingNotice = try c.decodeIfPresent(String.self, forKey: .speakerLabelingNotice)
        self.speakerLabelingGaps = try c.decodeIfPresent([SpeakerTranscriptGap].self, forKey: .speakerLabelingGaps) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.text, forKey: .text)
        try c.encode(self.confidence, forKey: .confidence)
        try c.encode(self.duration, forKey: .duration)
        try c.encode(self.processingTime, forKey: .processingTime)
        try c.encode(self.fileName, forKey: .fileName)
        try c.encode(self.timestamp, forKey: .timestamp)
        if !self.speakerSegments.isEmpty {
            try c.encode(self.speakerSegments, forKey: .speakerSegments)
        }
        try c.encodeIfPresent(self.speakerLabelingNotice, forKey: .speakerLabelingNotice)
        if !self.speakerLabelingGaps.isEmpty {
            try c.encode(self.speakerLabelingGaps, forKey: .speakerLabelingGaps)
        }
    }

    var textExport: String {
        var metadata = [
            "Transcription: \(self.fileName)",
            "Date: \(self.timestamp.formatted())",
            "Duration: \(String(format: "%.1f", self.duration))s",
            "Processing Time: \(String(format: "%.1f", self.processingTime))s",
            "Confidence: \(String(format: "%.1f%%", self.confidence * 100))",
        ]
        if let speakerLabelingNotice {
            metadata.append("Speaker labeling: \(speakerLabelingNotice)")
        }
        if !self.speakerLabelingGaps.isEmpty {
            metadata.append("Unlabeled audio ranges: \(self.speakerLabelingGaps.map(\.timestampRangeText).joined(separator: ", "))")
        }
        return metadata.joined(separator: "\n") + "\n\n---\n\n" + self.text
    }

    /// Shared bytes for direct service exports and immutable FileDocument snapshots.
    var textExportData: Data {
        Data(self.textExport.utf8)
    }

    func jsonExportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Stable UI state survives interface-language changes while transcription continues.
/// Only these known catalog keys are localized; file names and transcript content remain data.
nonisolated enum FileTranscriptionStatus: Equatable, Sendable {
    case idle, preparingModels, modelsReady, analyzingAudio, identifyingSpeakers, complete
    case transcribingAudio(durationSeconds: Int?)
    case transcribing(percent: Int)
    case transcribingSpeakerSegments(index: Int, total: Int)

    func text(language: PichiInterfaceLanguage = PichiLocalization.language, bundle: Bundle = .main) -> String {
        switch self {
        case .idle: return ""
        case .preparingModels: return PichiLocalization.text("Preparing ASR models...", language: language, bundle: bundle)
        case .modelsReady: return PichiLocalization.text("Models ready", language: language, bundle: bundle)
        case .analyzingAudio: return PichiLocalization.text("Analyzing audio file...", language: language, bundle: bundle)
        case .identifyingSpeakers: return PichiLocalization.text("Identifying speakers...", language: language, bundle: bundle)
        case .complete: return PichiLocalization.text("Complete!", language: language, bundle: bundle)
        case let .transcribingAudio(durationSeconds):
            if let durationSeconds {
                return PichiLocalization.format("Transcribing audio (%llds)...", language: language, bundle: bundle, arguments: [durationSeconds])
            }
            return PichiLocalization.text("Transcribing audio...", language: language, bundle: bundle)
        case let .transcribing(percent):
            return PichiLocalization.format("Transcribing... %lld%%", language: language, bundle: bundle, arguments: [percent])
        case let .transcribingSpeakerSegments(index, total):
            return PichiLocalization.format("Transcribing speaker segments (%lld/%lld)...", language: language, bundle: bundle, arguments: [index, total])
        }
    }
}

/// Service for transcribing complete audio/video files with optional speaker diarization
/// NOTE: This service shares the ASR models with ASRService to avoid duplicate memory usage
@MainActor
final class FileTranscriptionService: ObservableObject, PrivateProfileTransitionParticipant {
    private let privateOperations = PrivateProfileOperationOwner()
    private nonisolated final class CallerCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var canceled = false
        var isCanceled: Bool { self.lock.withLock { self.canceled } }
        func cancel() { self.lock.withLock { self.canceled = true } }
    }
    private struct Presentation {
        var currentFileURL: URL?
        var isTranscribing = false
        var progress = 0.0
        var status: FileTranscriptionStatus = .idle
        var error: String?
        var result: TranscriptionResult?
        var fallbackNotice: String?
    }
    @Published private var presentation = Presentation()
    private(set) var currentFileURL: URL? {
        get { self.privateOperations.isCurrent ? self.presentation.currentFileURL : nil }
        set { if self.privateOperations.isCurrent { self.presentation.currentFileURL = newValue } }
    }
    var isTranscribing: Bool {
        get { self.privateOperations.isCurrent && self.presentation.isTranscribing }
        set { if self.privateOperations.isCurrent { self.presentation.isTranscribing = newValue } }
    }
    var progress: Double {
        get { self.privateOperations.isCurrent ? self.presentation.progress : 0 }
        set { if self.privateOperations.isCurrent { self.presentation.progress = newValue } }
    }
    private(set) var status: FileTranscriptionStatus {
        get { self.privateOperations.isCurrent ? self.presentation.status : .idle }
        set { if self.privateOperations.isCurrent { self.presentation.status = newValue } }
    }
    var currentStatus: String { self.status.text() }
    var error: String? {
        get { self.privateOperations.isCurrent ? self.presentation.error : nil }
        set { if self.privateOperations.isCurrent { self.presentation.error = newValue } }
    }
    var result: TranscriptionResult? {
        get { self.privateOperations.isCurrent ? self.presentation.result : nil }
        set { if self.privateOperations.isCurrent { self.presentation.result = newValue } }
    }
    var fallbackNotice: String? {
        get { self.privateOperations.isCurrent ? self.presentation.fallbackNotice : nil }
        set { if self.privateOperations.isCurrent { self.presentation.fallbackNotice = newValue } }
    }

    // MARK: - Supported Formats

    /// File extensions the OS can actually decode, queried dynamically from AVFoundation.
    /// Filtered to audio/video types only — excludes subtitles, playlists, etc.
    /// Uses every extension tag of each type, not just the preferred one: `.opus`/`.oga`
    /// (e.g. WhatsApp voice notes) map to the same UTType as `.ogg` and decode natively.
    static let supportedFileExtensions: Set<String> = {
        let avTypes = AVURLAsset.audiovisualTypes()
        let extensions = avTypes.flatMap { fileType -> [String] in
            guard let utType = UTType(fileType.rawValue) else { return [] }
            guard utType.conforms(to: .audio) || utType.conforms(to: .movie) else { return [] }
            return utType.tags[.filenameExtension] ?? []
        }
        return Set(extensions.map { $0.lowercased() })
    }()

    /// Content types accepted by the file picker — broad categories so the OS filters naturally.
    static let allowedContentTypes: [UTType] = [.audio, .movie]

    /// User-facing description of supported formats (curated for readability).
    static let supportedFormatsDescription = "Supported: WAV, MP3, M4A, OGG, OPUS, MP4, MOV, and more"

    /// Error copy shown when a dropped file is not accepted.
    static let dropErrorCopy = "Accepted file types: WAV, MP3, M4A, OGG, OPUS, MP4, MOV, and more."

    /// Share the ASR service instance to avoid loading models twice
    private let asrService: ASRService
    private let historyStore: FileTranscriptionHistoryStore

    init(asrService: ASRService, historyStore: FileTranscriptionHistoryStore? = nil) {
        self.asrService = asrService
        self.historyStore = historyStore ?? FileTranscriptionHistoryStore.shared
        PrivateProfileService.shared.register(self)
    }

    func prepareForPrivateProfileTransition() async throws {
        self.presentation = Presentation()
        self.historyStore.concealPrivateProjections()
        await privateOperations.retireAndJoin()
        self.presentation = Presentation()
    }

    enum TranscriptionError: LocalizedError {
        case activityInProgress(String)
        case modelLoadFailed(String)
        case audioConversionFailed(String)
        case transcriptionFailed(String)
        case fileNotSupported(String)

        var errorDescription: String? {
            switch self {
            case let .activityInProgress(msg):
                return msg
            case let .modelLoadFailed(msg):
                return PichiLocalization.format("Failed to load ASR models: %@", msg)
            case let .audioConversionFailed(msg):
                return PichiLocalization.format("Failed to convert audio: %@", msg)
            case let .transcriptionFailed(msg):
                return PichiLocalization.format("Transcription failed: %@", msg)
            case let .fileNotSupported(msg):
                return PichiLocalization.format("File format not supported: %@", msg)
            }
        }
    }

    /// Initialize the ASR models (reuses models from ASRService - no duplicate download!)
    func initializeModels() async throws {
        do { try await self.privateOperations.perform { try await self.initializeModelsBound() } }
        catch {
            guard self.privateOperations.isCurrent, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }

    private func initializeModelsBound() async throws {
        try self.requireCurrentOperation()
        guard !self.asrService.isAsrReady else { return }

        self.status = .preparingModels
        self.progress = 0.1

        do {
            try await self.asrService.ensureAsrReady()

            self.status = .modelsReady
            self.progress = 0.0
        } catch {
            throw TranscriptionError.modelLoadFailed(error.localizedDescription)
        }
    }

    /// Transcribe an audio or video file
    /// - Parameters:
    ///   - fileURL: URL to the audio/video file
    func transcribeFile(_ fileURL: URL) async throws -> TranscriptionResult {
        let callerCancellation = CallerCancellation()
        do {
            return try await withTaskCancellationHandler {
                try await self.privateOperations.perform {
                    try await self.transcribeFileBound(fileURL, callerCancellation: callerCancellation)
                }
            } onCancel: { callerCancellation.cancel() }
        }
        catch {
            guard self.privateOperations.isCurrent, !Task.isCancelled else { throw CancellationError() }
            throw error
        }
    }

    private func requireCurrentOperation() throws {
        guard self.privateOperations.isCurrent, !Task.isCancelled else { throw CancellationError() }
    }

    private func complete(_ result: TranscriptionResult, profile: PrivateProfileSnapshot,
                          admission: FileTranscriptionHistoryWriteAdmission,
                          callerCancellation: CallerCancellation) throws -> TranscriptionResult {
        // Explicit visible cancellation discards output. A provider already completing after
        // logout may commit only through its original hidden-profile write capability.
        if callerCancellation.isCanceled || (Task.isCancelled && PrivateProfileStorage.isReadable(profile)) { throw CancellationError() }
        try self.historyStore.addEntry(result, admission: admission)
        if self.privateOperations.isCurrent, !Task.isCancelled {
            self.status = .complete; self.progress = 1
            self.result = result
        }
        return result
    }

    private func transcribeFileBound(_ fileURL: URL, callerCancellation: CallerCancellation) async throws -> TranscriptionResult {
        try self.requireCurrentOperation()
        guard !self.isTranscribing else {
            throw TranscriptionError.activityInProgress(PichiLocalization.text("This file is already being transcribed."))
        }

        let activityLease: ASRActivityLease
        do {
            activityLease = try self.asrService.acquireExclusiveActivity(.fileTranscription)
        } catch {
            let wrappedError = TranscriptionError.activityInProgress(error.localizedDescription)
            self.error = wrappedError.localizedDescription
            throw wrappedError
        }

        defer { self.asrService.releaseExclusiveActivity(activityLease) }
        let profile = PrivateProfileStorage.current
        let output = try self.historyStore.admitWrite()
        defer { output.finish() }
        let provider = try self.asrService.beginAdmittedTranscription(lease: activityLease)
        let operation = { [self] () async throws -> TranscriptionResult in
            let settings = SettingsStore.shared
            let speakerLabelsEnabled = settings.fileTranscriptionSpeakerLabelsEnabled
            let expectedSpeakers = settings.fileTranscriptionExpectedSpeakerCount
            let analyticsModel = settings.selectedSpeechModel.analyticsDescriptor
            let analytics = AnalyticsService.shared
            var labelingNotice: String?

            self.currentFileURL = fileURL
            self.isTranscribing = true
            error = nil
            self.fallbackNotice = nil
            self.progress = 0.0
            let startTime = Date()

            defer {
                self.isTranscribing = false
                self.progress = 0.0
            }

            do {
                // Initialize models if not already done (reuses ASRService models)
                if !self.asrService.isAsrReady {
                    try await self.initializeModelsBound()
                }

                // Get the current transcription provider (works for both Parakeet and Whisper)
                try self.requireCurrentOperation()
                guard provider.isReady else {
                    throw TranscriptionError.modelLoadFailed(PichiLocalization.text("Transcription provider not ready"))
                }

                // Check file extension
                let fileExtension = fileURL.pathExtension.lowercased()

                guard Self.supportedFileExtensions.contains(fileExtension) else {
                    throw TranscriptionError
                        .fileNotSupported(PichiLocalization.format("Format .%@ not supported. %@", fileExtension,
                                                                   PichiLocalization.text(Self.supportedFormatsDescription)))
                }

                analytics.recordUsage(mode: .meeting, transcriptionModel: analyticsModel)

                // Get audio duration for progress display
                self.status = .analyzingAudio
                self.progress = 0.2

                let asset = AVAsset(url: fileURL)
                let duration: Double
                do {
                    let cmDuration = try await asset.load(.duration)
                    duration = CMTimeGetSeconds(cmDuration)
                } catch {
                    try self.requireCurrentOperation()
                    // Fall back to 0 if we can't determine duration
                    duration = 0
                    DebugLogger.shared.warning("Could not determine audio duration: \(error.localizedDescription)", source: "FileTranscriptionService")
                }

                try self.requireCurrentOperation()
                let isVideoContainer = UTType(filenameExtension: fileExtension)
                    .map { $0.conforms(to: .movie) } ?? false

                // Speaker-labeled path: diarize first, then transcribe each speaker turn.
                // Any diarization failure falls back to the standard paths below.
                if speakerLabelsEnabled,
                   SpeakerDiarizationService.isSupported,
                   !isVideoContainer
                {
                    if let labeledResult = try await self.transcribeFileWithSpeakerLabels(
                        fileURL,
                        provider: provider,
                        duration: duration,
                        startTime: startTime,
                        expectedSpeakers: expectedSpeakers,
                        entryID: output.entryID
                    ) {
                        return try self.complete(labeledResult, profile: profile, admission: output, callerCancellation: callerCancellation)
                    }
                    try self.requireCurrentOperation()
                    DebugLogger.shared.warning(
                        "Speaker labeling unavailable for this file; falling back to standard transcription",
                        source: "FileTranscriptionService"
                    )
                    labelingNotice = "Speaker labeling was unavailable for this file. The transcript was completed without speaker labels."
                    self.fallbackNotice = labelingNotice
                    self.progress = 0.3
                } else if speakerLabelsEnabled, isVideoContainer {
                    DebugLogger.shared.info(
                        "Speaker labeling skipped for video container; using standard transcription",
                        source: "FileTranscriptionService"
                    )
                }

                if provider.prefersNativeFileTranscription && !isVideoContainer {
                    self.status = .transcribingAudio(durationSeconds: duration > 0 ? Int(duration) : nil)
                    self.progress = 0.3

                    DebugLogger.shared.info(
                        "FileTranscriptionService: using native file transcription path for provider=\(provider.name)",
                        source: "FileTranscriptionService"
                    )

                    try self.requireCurrentOperation()
                    let nativeResult = try await provider.transcribeFile(at: fileURL)
                    let processingTime = Date().timeIntervalSince(startTime)
                    let result = TranscriptionResult(
                        id: output.entryID,
                        text: nativeResult.text,
                        confidence: nativeResult.confidence,
                        duration: duration,
                        processingTime: processingTime,
                        fileName: fileURL.lastPathComponent,
                        speakerLabelingNotice: labelingNotice
                    )
                    return try self.complete(result, profile: profile, admission: output, callerCancellation: callerCancellation)
                }

                if provider.prefersNativeFileTranscription && isVideoContainer {
                    DebugLogger.shared.info(
                        "FileTranscriptionService: using buffered transcription path for video container [provider=\(provider.name), extension=\(fileExtension)]",
                        source: "FileTranscriptionService"
                    )
                }

                // Transcribe using chunked processing for long files
                // This reads audio in ~20 minute segments to avoid memory overflow on 3+ hour files
                let chunkDurationSeconds: Double = 20 * 60 // 20 minutes per chunk (well under 24min model limit)
                let sampleRate: Double = 16_000 // Target sample rate for ASR
                let samplesPerChunk = Int(chunkDurationSeconds * sampleRate)

                var allTranscriptions: [String] = []
                var totalConfidence: Float = 0
                var chunkCount = 0

                // Open audio file for reading
                let audioFile: AVAudioFile
                do {
                    audioFile = try AVAudioFile(forReading: fileURL)
                } catch {
                    throw TranscriptionError.audioConversionFailed(PichiLocalization.format("Could not open audio file: %@", error.localizedDescription))
                }

                let fileFormat = audioFile.processingFormat
                let totalFrames = AVAudioFrameCount(audioFile.length)
                let fileSampleRate = fileFormat.sampleRate
                guard fileSampleRate > 0 else {
                    throw TranscriptionError.audioConversionFailed(PichiLocalization.text("Invalid audio file: sample rate is 0"))
                }
                let resampleRatio = sampleRate / fileSampleRate

                // Calculate chunk size in source file frames
                let sourceFramesPerChunk = AVAudioFrameCount(Double(samplesPerChunk) / resampleRatio)
                var currentFrame: AVAudioFramePosition = 0

                self.status = .transcribingAudio(durationSeconds: duration > 0 ? Int(duration) : nil)

                while currentFrame < audioFile.length {
                    try self.requireCurrentOperation()
                    let remainingFrames = AVAudioFrameCount(audioFile.length - currentFrame)
                    let framesToRead = min(sourceFramesPerChunk, remainingFrames)

                    // Read chunk from file
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                        throw TranscriptionError.audioConversionFailed(PichiLocalization.text("Could not create audio buffer"))
                    }

                    audioFile.framePosition = currentFrame
                    do {
                        try audioFile.read(into: buffer, frameCount: framesToRead)
                    } catch {
                        throw TranscriptionError.audioConversionFailed(PichiLocalization.format("Could not read audio chunk: %@", error.localizedDescription))
                    }

                    // Convert buffer to 16kHz mono Float32 samples
                    var samples: [Float]
                    do {
                        samples = try AudioBufferConverter.monoSamples(
                            from: buffer,
                            targetSampleRate: sampleRate
                        )
                    } catch {
                        throw TranscriptionError.audioConversionFailed(PichiLocalization.format("Could not resample audio: %@", error.localizedDescription))
                    }

                    // Keep short files and final tails. The existing ASR minimum is met with
                    // trailing silence, without dropping source audio or changing its duration.
                    guard !samples.isEmpty else {
                        currentFrame += AVAudioFramePosition(framesToRead)
                        continue
                    }
                    if samples.count < Int(sampleRate) {
                        samples.append(contentsOf: repeatElement(Float(0), count: Int(sampleRate) - samples.count))
                    }

                    // Transcribe this chunk using the provider (works for both Parakeet and Whisper)
                    let chunkResult = try await provider.transcribe(samples)

                    if !chunkResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        allTranscriptions.append(chunkResult.text)
                        totalConfidence += chunkResult.confidence
                        chunkCount += 1
                    }

                    currentFrame += AVAudioFramePosition(framesToRead)

                    // Update progress
                    let progressPercent = Double(currentFrame) / Double(audioFile.length)
                    self.progress = 0.3 + (progressPercent * 0.6) // Progress from 30% to 90%
                    self.status = .transcribing(percent: Int(progressPercent * 100))
                }

                if allTranscriptions.isEmpty, self.privateOperations.isCurrent {
                    DebugLogger.shared.warning(
                        "No audio chunks produced recognized text",
                        source: "FileTranscriptionService"
                    )
                }

                // Combine all chunk transcriptions
                let finalText = allTranscriptions.joined(separator: " ")
                let avgConfidence = chunkCount > 0 ? totalConfidence / Float(chunkCount) : 0

                let transcriptionResult = (text: finalText, confidence: avgConfidence)

                self.status = .complete
                self.progress = 1.0

                let processingTime = Date().timeIntervalSince(startTime)

                let result = TranscriptionResult(
                    id: output.entryID,
                    text: transcriptionResult.text,
                    confidence: transcriptionResult.confidence,
                    duration: duration,
                    processingTime: processingTime,
                    fileName: fileURL.lastPathComponent,
                    speakerLabelingNotice: labelingNotice
                )
                return try self.complete(result, profile: profile, admission: output, callerCancellation: callerCancellation)

            } catch is CancellationError {
                throw CancellationError()
            } catch let error as TranscriptionError {
                self.error = error.localizedDescription
                throw error
            } catch {
                let wrappedError = TranscriptionError.transcriptionFailed(error.localizedDescription)
                self.error = wrappedError.localizedDescription
                throw wrappedError
            }
        }
        do {
            let result = try await operation()
            await self.asrService.endAdmittedTranscription(lease: activityLease)
            return result
        } catch {
            await self.asrService.endAdmittedTranscription(lease: activityLease)
            throw error
        }
    }

    /// Export transcription result to text file
    nonisolated func exportToText(_ result: TranscriptionResult, to destinationURL: URL) throws {
        try result.textExportData.write(to: destinationURL, options: .atomic)
    }

    /// Export transcription result to JSON
    nonisolated func exportToJSON(_ result: TranscriptionResult, to destinationURL: URL) throws {
        try result.jsonExportData().write(to: destinationURL, options: .atomic)
    }

    /// Reset the service state
    func reset() {
        guard !self.isTranscribing else { return }
        self.result = nil
        self.error = nil
        self.fallbackNotice = nil
        self.currentFileURL = nil
        self.status = .idle
        self.progress = 0.0
    }

    // MARK: - Speaker-Labeled Transcription

    /// Diarize-first pipeline: identify speaker turns, then transcribe the audio slice for
    /// each turn with the active provider. Tiny empty ASR intervals can be retained as explicit
    /// gaps. Material omissions or genuine errors return nil so the caller can run the standard
    /// full-file transcription path instead.
    private func transcribeFileWithSpeakerLabels(
        _ fileURL: URL,
        provider: TranscriptionProvider,
        duration: Double,
        startTime: Date,
        expectedSpeakers: Int,
        entryID: UUID
    ) async throws -> TranscriptionResult? {
        try self.requireCurrentOperation()
        self.status = .identifyingSpeakers
        self.progress = 0.25

        let diarizer = SpeakerDiarizationService(
            expectedSpeakers: expectedSpeakers > 0 ? expectedSpeakers : nil
        )

        let turns: [SpeakerDiarizationService.SpeakerTurn]
        do {
            turns = try await diarizer.diarize(fileURL: fileURL)
            try self.requireCurrentOperation()
        } catch {
            if error is CancellationError || !self.privateOperations.isCurrent || Task.isCancelled { throw CancellationError() }
            DebugLogger.shared.warning(
                "Diarization failed: \(error.localizedDescription)",
                source: "FileTranscriptionService"
            )
            return nil
        }

        guard !turns.isEmpty else {
            DebugLogger.shared.info(
                "Diarization found no speaker turns",
                source: "FileTranscriptionService"
            )
            return nil
        }

        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: fileURL)
        } catch {
            DebugLogger.shared.warning(
                "Could not open audio for speaker slicing: \(error.localizedDescription)",
                source: "FileTranscriptionService"
            )
            return nil
        }

        var recognizedTurns: [SpeakerRecognizedTurn] = []

        for (index, turn) in turns.enumerated() {
            try self.requireCurrentOperation()
            self.status = .transcribingSpeakerSegments(index: index + 1, total: turns.count)
            self.progress = 0.3 + (Double(index) / Double(turns.count)) * 0.65

            let transcribed: SpeakerTurnTranscription
            do {
                transcribed = try await self.transcribeSpeakerTurn(turn, from: audioFile, provider: provider)
            } catch {
                if error is CancellationError || !self.privateOperations.isCurrent || Task.isCancelled { throw CancellationError() }
                // A genuine audio-read or ASR failure can omit an unknown amount of speech.
                // Use the standard full-file path rather than accepting uncertain labels.
                DebugLogger.shared.warning(
                    "Speaker labeling aborted at segment \(index + 1)/\(turns.count) (\(String(format: "%.1f", turn.startSeconds))s): \(error.localizedDescription); falling back to standard transcription",
                    source: "FileTranscriptionService"
                )
                return nil
            }

            recognizedTurns.append(SpeakerRecognizedTurn(
                speaker: turn.speakerLabel,
                startSeconds: turn.startSeconds,
                endSeconds: turn.endSeconds,
                transcription: transcribed
            ))
        }

        guard let labeledTranscript = SpeakerLabeledTranscriptionPolicy.assembleTurns(recognizedTurns) else {
            try self.requireCurrentOperation()
            let gaps = recognizedTurns.flatMap(\.transcription.gaps)
            let diarizedDuration = recognizedTurns.reduce(0) {
                $0 + max(0, $1.endSeconds - $1.startSeconds)
            }
            let hasRecognizedText = recognizedTurns.contains {
                !$0.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            let diagnostic = SpeakerLabeledTranscriptionPolicy.fallbackDiagnostic(
                hasRecognizedText: hasRecognizedText,
                gaps: gaps,
                diarizedDurationSeconds: diarizedDuration
            )
            DebugLogger.shared.warning(
                "\(diagnostic); falling back to standard transcription",
                source: "FileTranscriptionService"
            )
            return nil
        }

        let labeledText = labeledTranscript.segments
            .map(\.plainText)
            .joined(separator: "\n\n")
        let processingTime = Date().timeIntervalSince(startTime)

        let result = TranscriptionResult(
            id: entryID,
            text: labeledText,
            confidence: labeledTranscript.confidence,
            duration: duration,
            processingTime: processingTime,
            fileName: fileURL.lastPathComponent,
            speakerSegments: labeledTranscript.segments,
            speakerLabelingNotice: labeledTranscript.notice,
            speakerLabelingGaps: labeledTranscript.gaps
        )

        return result
    }

    /// Transcribe a single speaker turn, splitting overlong turns into bounded chunks.
    /// Returns the concatenated text, mean confidence, and explicit empty ASR intervals.
    /// Throws on a genuine audio-read or ASR failure so the caller can use full-file transcription.
    private func transcribeSpeakerTurn(
        _ turn: SpeakerDiarizationService.SpeakerTurn,
        from audioFile: AVAudioFile,
        provider: TranscriptionProvider
    ) async throws -> SpeakerTurnTranscription {
        // Bound memory for unusually long single-speaker stretches. Providers remain free to
        // apply their own model-specific, energy-aware chunking within each request.
        let maxChunkSeconds: Double = 20 * 60

        var ranges: [SpeakerTranscriptGap] = []
        if turn.endSeconds - turn.startSeconds > maxChunkSeconds {
            var chunkStart = turn.startSeconds
            while chunkStart < turn.endSeconds {
                let chunkEnd = min(chunkStart + maxChunkSeconds, turn.endSeconds)
                ranges.append(SpeakerTranscriptGap(startSeconds: chunkStart, endSeconds: chunkEnd))
                chunkStart = chunkEnd
            }
        } else {
            ranges.append(SpeakerTranscriptGap(startSeconds: turn.startSeconds, endSeconds: turn.endSeconds))
        }

        return try await SpeakerLabeledTranscriptionPolicy.transcribeChunks(ranges) { range in
            try self.requireCurrentOperation()
            let samples = try self.readSamples(
                from: audioFile,
                startSeconds: range.startSeconds,
                endSeconds: range.endSeconds,
                minimumDurationSeconds: 1.1
            )
            guard samples.count >= 16_000 else { return nil }

            let chunkResult = try await provider.transcribe(samples)
            return SpeakerChunkTranscription(
                text: chunkResult.text,
                confidence: chunkResult.confidence
            )
        }
    }

    /// Read a time range from an audio file as 16kHz mono Float32 samples.
    /// Ranges shorter than `minimumDurationSeconds` are padded with trailing silence
    /// (never widened into neighboring audio) so very brief speaker turns meet the ASR
    /// input minimum without absorbing an adjacent speaker's words.
    private nonisolated func readSamples(
        from audioFile: AVAudioFile,
        startSeconds: Double,
        endSeconds: Double,
        minimumDurationSeconds: Double
    ) throws -> [Float] {
        let sourceSampleRate = audioFile.processingFormat.sampleRate
        guard sourceSampleRate > 0 else {
            throw TranscriptionError.audioConversionFailed(PichiLocalization.text("Invalid audio file: sample rate is 0"))
        }
        let fileDurationSeconds = Double(audioFile.length) / sourceSampleRate

        let start = max(0, startSeconds)
        let end = min(endSeconds, fileDurationSeconds)
        guard end > start else { return [] }

        let startFrame = AVAudioFramePosition((start * sourceSampleRate).rounded(.down))
        let frameCount = AVAudioFrameCount(((end - start) * sourceSampleRate).rounded(.up))
        guard frameCount > 0 else { return [] }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: audioFile.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw TranscriptionError.audioConversionFailed(PichiLocalization.text("Could not create audio buffer"))
        }

        audioFile.framePosition = startFrame
        try audioFile.read(into: buffer, frameCount: frameCount)
        var samples = try self.resampleBuffer(buffer)

        // Pad short turns with trailing silence (at the 16kHz ASR rate) rather than widening
        // the window into adjacent turns — absorbing a neighbor's audio would attribute their
        // words to this speaker. Trailing silence keeps the segment single-speaker.
        let minimumSamples = Int((minimumDurationSeconds * 16_000).rounded(.up))
        if samples.count < minimumSamples {
            samples.append(contentsOf: repeatElement(Float(0), count: minimumSamples - samples.count))
        }
        return samples
    }

    // MARK: - Audio Resampling Helpers

    /// Resample an audio buffer to 16 kHz mono Float32 samples using the shared downmixer.
    private nonisolated func resampleBuffer(
        _ buffer: AVAudioPCMBuffer,
        targetSampleRate: Double = 16_000
    ) throws -> [Float] {
        try AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: targetSampleRate)
    }
}
