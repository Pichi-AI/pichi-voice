import Foundation

/// Portable host seam. Existing desktop and mobile compositions share the preparation,
/// inference executor and residency owners; the pipeline does not own platform capture.
@MainActor
protocol MeetingASRServicing: ASRActivityLeasing {
    var isRunning: Bool { get }
    var fileTranscriptionProvider: any TranscriptionProvider { get }
    func ensureAsrReady() async throws
    func meetingResidencyParticipant() -> MeetingModelParticipant
    func withMeetingModelResidency<T>(
        attemptID: UUID,
        acceptsCompletedCancellation: (T) -> Bool,
        work: () async throws -> T
    ) async throws -> T
    func withPreparedMeetingASR<T>(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: @escaping (any TranscriptionProvider) async throws -> T
    ) async throws -> T
    func transcribeMeetingSamples(_ samples: [Float], provider: any TranscriptionProvider, languageCode: String) async throws -> ASRTranscriptionResult
    func transcribeMeetingSamplesWithTimings(_ samples: [Float], provider: any TranscriptionProvider) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming])
    func transcribeMeetingFile(at fileURL: URL, provider: any TranscriptionProvider) async throws -> ASRTranscriptionResult
}

extension ASRService: MeetingASRServicing {}
