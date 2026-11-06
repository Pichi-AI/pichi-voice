import Foundation

/// Effective recording state after conference transitions and local intent. Online capture
/// starts enabled; missing conference UI preserves the last automatic state.
nonisolated enum MeetingMicrophoneMuteState: String, Equatable, Sendable {
    case notApplicable
    case unmuted
    case muted
    /// Local recording intent, independent of the conference's remembered state.
    case manuallyMuted

    var admitsMicrophone: Bool { self == .notApplicable || self == .unmuted }
}

#if os(macOS)
/// One attempt's control plane for the existing admission gate. Serializes local intent and
/// observer callbacks before publishing effective state. It owns no PCM or observation loop.
final nonisolated class MeetingMicrophoneRecordingControl: @unchecked Sendable {
    private let lock = NSLock()
    private let gate: MeetingMicrophonePrivacyGate
    private let hostTime: @Sendable () -> UInt64
    private let publish: @Sendable (MeetingMicrophoneMuteState) -> Void
    private var meetingState = MeetingMicrophoneMuteState.unmuted
    private var manuallyMuted = false
    private var stopped = false

    init(gate: MeetingMicrophonePrivacyGate,
         hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
         publish: @escaping @Sendable (MeetingMicrophoneMuteState) -> Void) {
        self.gate = gate
        self.hostTime = hostTime
        self.publish = publish
        gate.setAdmitted(true, observedAtHostTime: hostTime())
        publish(.unmuted)
    }

    func observe(_ observation: MeetingMicrophoneMuteObservation) {
        self.lock.withLock {
            guard !self.stopped, observation.state == .muted || observation.state == .unmuted else { return }
            self.meetingState = observation.state
            if observation.state == .unmuted, let release = observation.unsafeStartHostTime,
               let resumed = observation.refinementUntilHostTime {
                // This operation only subtracts approvals. Local mute has already closed its
                // epoch, so historical refinement cannot recreate a locally denied interval.
                self.gate.refineHistoricalRelease(unsafeStartHostTime: release, resumedAtHostTime: resumed)
            }
            self.apply(at: observation.observedAtHostTime, unsafeStart: observation.unsafeStartHostTime)
        }
    }

    func setManuallyMuted(_ muted: Bool) {
        self.lock.withLock {
            guard !self.stopped, self.manuallyMuted != muted else { return }
            self.manuallyMuted = muted
            self.apply(at: self.hostTime())
        }
    }

    /// Freeze commands before joining monitor and PCM delivery during stop/cancellation.
    func finish() { self.lock.withLock { self.stopped = true } }

    private func apply(at time: UInt64, unsafeStart: UInt64? = nil) {
        let state: MeetingMicrophoneMuteState = self.manuallyMuted ? .manuallyMuted : self.meetingState
        self.gate.setAdmitted(state.admitsMicrophone, observedAtHostTime: time,
            unsafeStartHostTime: state.admitsMicrophone ? nil : unsafeStart ?? time)
        self.publish(state)
    }
}
#endif
