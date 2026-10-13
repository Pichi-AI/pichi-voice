import Foundation
import ScreenCaptureKit

/// A stopped producer can be replaced only after an explicit transient error. Audio silence and
/// missing callbacks alone are not evidence that a ScreenCaptureKit stream has stopped.
nonisolated enum MeetingScreenCaptureRecoveryPolicy {
    static func isPermissionFailure(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == SCStreamErrorDomain && error.code == SCStreamError.Code.userDeclined.rawValue
    }

    static func shouldRetry(_ error: Error) -> Bool {
        if let error = error as? MeetingCaptureError {
            switch error {
            case .applicationUnavailable, .noCaptureDisplay, .microphoneUnavailable: return true
            default: return false
            }
        }
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain, let code = SCStreamError.Code(rawValue: error.code) else { return false }
        switch code {
        case .failedToStart, .failedApplicationConnectionInvalid, .failedApplicationConnectionInterrupted,
             .failedNoMatchingApplicationContext, .internalError, .noWindowList, .noDisplayList,
             .noCaptureSource, .failedToStartAudioCapture, .failedToStartMicrophoneCapture, .systemStoppedStream:
            return true
        default:
            // Includes userStopped, userDeclined, entitlement/configuration failures and unknown
            // future errors. Do not fight explicit cancellation or retry broken ownership.
            return false
        }
    }

    /// Called only for a published producer, on the callback queue before its first PCM command.
    /// Failed/rejected candidates cannot replace the identity of the last recorded capture era.
    static func applyRecoveredMicrophoneEra(
        to track: inout MeetingAudioTrack,
        microphone: MeetingMicrophoneIdentity,
        startSeconds: Double?
    ) {
        var eras = track.captureEras ?? []
        let start = startSeconds ?? eras.last?.startSeconds ?? 0
        let replacement = MeetingCaptureEra(
            method: .screenCaptureKit,
            deviceUID: microphone.coreAudioUID,
            deviceName: microphone.displayName,
            roleAtElection: .unknown,
            echoProtection: .unprotected,
            startSeconds: start
        )
        if let last = eras.last, start > last.startSeconds {
            eras.append(replacement)
        } else if eras.isEmpty {
            eras = [replacement]
        } else {
            eras[eras.count - 1] = replacement
        }
        track.captureEras = eras
        track.captureMethod = .screenCaptureKit
    }

    static func mayReplaceRetiredCandidate(stopSucceeded: Bool, didStopReceived: Bool) -> Bool {
        stopSucceeded || didStopReceived
    }

    static func mayAdmitSample(
        stopping: Bool,
        rebuilding: Bool,
        producerStopped: Bool,
        ownsCurrentProducer: Bool
    ) -> Bool {
        !stopping && !rebuilding && !producerStopped && ownsCurrentProducer
    }
}

/// Bounded state and delay, with no attempt limit. The task that owns producer replacement also
/// owns this backoff; cancellation wakes its sleep and stop joins that same task's completion.
nonisolated struct MeetingCaptureRecoveryBackoff {
    private var delay: UInt64 = 250_000_000

    mutating func nextDelayNanoseconds() -> UInt64 {
        self.delay = min(self.delay * 2, 5_000_000_000)
        return self.delay
    }

    mutating func waitForRetry() async throws {
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: self.nextDelayNanoseconds())
        try Task.checkCancellation()
    }
}
