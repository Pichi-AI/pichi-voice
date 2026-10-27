@preconcurrency import AVFoundation
import CoreMedia
import Foundation

nonisolated protocol MeetingCaptureControlling: Sendable {
    /// Any user-facing permission request must complete before the coordinator reserves
    /// the exclusive ASR meeting lease.
    func preflightPermissions() async throws

    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) async throws -> MeetingCaptureStartResult

    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult
    func shutdownForTermination() async
}


nonisolated enum MeetingCaptureError: LocalizedError {
    case captureAlreadyActive
    case noActiveCapture
    case wrongActiveSession
    case applicationNotSelected
    case applicationUnavailable(String)
    case noCaptureDisplay
    case microphoneUnavailable
    case microphonePermissionDenied
    case screenCapturePermissionDenied(String)
    case insufficientDiskSpace
    case captureStartFailed(String)
    case captureStopFailed(String, partialResult: MeetingCaptureStopResult)
    case unsupportedAudioFormat
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .captureAlreadyActive:
            return "Another meeting recording is already active."
        case .noActiveCapture:
            return "There is no active meeting recording."
        case .wrongActiveSession:
            return "A different meeting recording is active."
        case .applicationNotSelected:
            return PichiLocalization.text("Choose the application that contains the online meeting.")
        case let .applicationUnavailable(name):
            return PichiLocalization.format("%@ is no longer available to record.", name)
        case .noCaptureDisplay:
            return "No display is available for meeting-audio capture."
        case .microphoneUnavailable:
            return "The selected microphone is unavailable."
        case .microphonePermissionDenied:
            return "Microphone permission is required to record this meeting."
        case let .screenCapturePermissionDenied(detail):
            return "Screen & System Audio permission is required. \(detail)"
        case .insufficientDiskSpace:
            return "Not enough free space is available for PCM meeting capture. Free space for at least a one-hour recording and processing workspace, then try again."
        case let .captureStartFailed(detail):
            return "Meeting recording could not start. \(detail)"
        case let .captureStopFailed(detail, _):
            return "Meeting recording could not stop cleanly. \(detail)"
        case .unsupportedAudioFormat:
            return "The selected audio source uses an unsupported format."
        case let .writerFailed(detail):
            return "Meeting audio could not be saved. \(detail)"
        }
    }
}


nonisolated struct MeetingMicrophoneCatalogSnapshot: Sendable, Equatable {
    var identities: [MeetingMicrophoneIdentity]
    var defaultCoreAudioUID: String?
}


/// Incremental PCM ownership for the strict no-audio-file mode. The existing processing
/// pipeline constructs this consumer with a frozen model selection and durable text checkpoints.
/// Enqueue must be bounded; false is terminal rejection, never permission to use a file fallback.
nonisolated protocol MeetingMemoryAudioConsuming: Sendable {
    /// A safe localized reason, without provider error payloads or transcript content.
    var rejectionReason: String? { get }
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool
    func finish() async throws
}

extension MeetingMemoryAudioConsuming {
    var rejectionReason: String? { nil }
}

// Capture events are runtime contracts, independent of persisted meeting codecs.
nonisolated enum MeetingCaptureEvent: Sendable {
    /// Explicit local investigation only; never persisted as a session interruption.
    case audioComparisonProbeStarted(MeetingAudioComparisonProbe)
    case trackHealth(trackID: MeetingAudioTrackID, health: MeetingTrackHealth)
    /// Presentation-only status. The writer owns persisted capture eras; this cannot restart capture.
    case microphoneEchoProtectionChanged(MeetingMicrophoneEchoProtection)
    case chunkFinalized(trackID: MeetingAudioTrackID, chunk: MeetingAudioChunk, format: MeetingAudioFormat)
    case interrupted(kind: MeetingInterruptionKind, trackID: MeetingAudioTrackID?, detail: String?)
    /// `ack` is `nil` for downgrades — the mic is already dead, no race to gate on.
    case captureMethodChanged(trackID: MeetingAudioTrackID, method: MeetingAudioTrackCaptureMethod, ack: MeetingCaptureMethodChangeAck?)
}
