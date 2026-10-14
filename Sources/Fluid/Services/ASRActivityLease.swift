import Foundation

nonisolated enum ASRExclusiveActivity: String, Equatable, Sendable {
    case dictation
    case fileTranscription
    case localAPI
    case meeting
    case modelMaintenance
    case settingsRestore

    var displayName: String {
        switch self {
        case .dictation:
            return "dictation"
        case .fileTranscription:
            return "file transcription"
        case .localAPI:
            return "local API transcription"
        case .meeting:
            return "meeting transcription"
        case .modelMaintenance:
            return "voice model maintenance"
        case .settingsRestore:
            return "settings import"
        }
    }
}

nonisolated struct ASRActivityLease: Equatable, Sendable {
    let id: UUID
    let activity: ASRExclusiveActivity
}

nonisolated enum ASRActivityError: LocalizedError {
    case activityInProgress(ASRExclusiveActivity)
    case settingsRestoreUnavailable

    var errorDescription: String? {
        switch self {
        case let .activityInProgress(activity):
            return "Wait for the active \(activity.displayName) to finish."
        case .settingsRestoreUnavailable:
            return "Finish the current recording, transcription, microphone preview, or voice model operation, then import the backup again."
        }
    }
}
