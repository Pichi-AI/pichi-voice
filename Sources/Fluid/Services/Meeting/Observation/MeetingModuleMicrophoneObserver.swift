#if os(macOS)
import Foundation
import PichiCallObservation

/// Generic module driver. The common scheduler owns its lifetime and cadence. A session pins
/// one module, process, window and document; absent/ambiguous evidence never changes its latch.
final nonisolated class MeetingModuleMicrophoneObserver: MeetingMicrophoneObservationPolling, @unchecked Sendable {
    private let application: MeetingApplicationIdentity?
    private let modules: MeetingCommunicationModuleSnapshot
    private let probe: any MeetingCommunicationObservationReading
    private let handler: MeetingMicrophoneMuteMonitor.Handler
    private let queue = DispatchQueue(label: "meeting.communication.microphone", qos: .utility)
    private var running = false
    private var stopped = false
    private var generation: UInt64 = 0
    private var pending = false
    private var windowID: UInt32?
    private var document: String?
    private var moduleID: String?
    private var ownedChord: CommunicationPushToTalkChord?
    private var lastPublished: MeetingMicrophoneMuteState?
    private var transition = MeetingMuteTransitionState()
    private var rendered: (any MeetingMicrophoneObservationPolling)?

    init(application: MeetingApplicationIdentity?, snapshot: MeetingCommunicationModuleSnapshot,
         probe: any MeetingCommunicationObservationReading = MeetingCommunicationAXProbe.shared,
         handler: @escaping MeetingMicrophoneMuteMonitor.Handler) {
        self.application = application; self.modules = snapshot; self.probe = probe; self.handler = handler
    }

    func start(externallyDriven: Bool) {
        self.queue.async {
            guard !self.running, !self.stopped else { return }
            self.running = true; self.generation &+= 1
            self.publish(.unmuted, at: mach_absolute_time())
        }
    }

    func requestPoll() {
        self.queue.async {
            guard self.running else { return }
            if let rendered = self.rendered { rendered.requestPoll(); return }
            if self.transition.temporaryUnmute, let application = self.application, let window = self.windowID,
               !self.probe.ownsFocus(application: application, windowID: window, boundDocument: self.document) {
                self.ownedChord = nil
                let now = mach_absolute_time()
                if self.transition.retireTemporaryGrant(at: now) { self.publish(.muted, at: now, unsafeStart: now, refine: true) }
            }
            guard !self.pending, let application = self.application,
                  !self.modules.registry.candidates(bundleIdentifier: application.bundleIdentifier).isEmpty else { return }
            self.pending = true
            let generation = self.generation
            self.probe.request(application: application, boundWindowID: self.windowID,
                boundDocument: self.document, modules: self.modules) { [weak self] observations in
                self?.queue.async { [weak self] in
                    guard let self, self.running, self.generation == generation else { return }
                    self.pending = false
                    let allPositive = observations.filter { $0.evidence.callState != .indeterminate }
                    // Prejoin/ringing may live in a different window from the eventual call.
                    // Prefer one connected surface and pin ownership only after connection.
                    let connected = allPositive.filter { $0.evidence.callState == .inCall || $0.evidence.callState == .onHold }
                    let positive = self.windowID == nil && !connected.isEmpty ? connected : allPositive
                    guard positive.count == 1, let observation = positive.first,
                          self.moduleID == nil || self.moduleID == observation.evidence.moduleID,
                          MeetingMicrophoneMuteMonitor.elapsed(since: observation.acquiredAtHostTime, until: mach_absolute_time()) <= 0.65 else { return }
                    if self.moduleID == nil, observation.evidence.callState == .inCall || observation.evidence.callState == .onHold {
                        self.moduleID = observation.evidence.moduleID
                        self.windowID = observation.snapshot.windowID
                        self.document = observation.snapshot.documentURL
                        if let registration = self.modules.registration(id: observation.evidence.moduleID),
                           registration.renderedBundleIdentifiers.contains(application.bundleIdentifier),
                           let factory = registration.renderedFactory {
                            var boundApplication = application; boundApplication.windowID = self.windowID
                            let rendered = factory(boundApplication, self.handler)
                            self.rendered = rendered; rendered.start(externallyDriven: true); return
                        }
                    }
                    let state: MeetingMicrophoneMuteState?
                    switch observation.evidence.callState {
                    case .ringing, .onHold, .ended:
                        state = .muted // Explicit non-transmitting phase, never inferred from absence.
                    case .inCall:
                        switch observation.evidence.microphoneState {
                        case .muted: state = .muted
                        case .unmuted: state = .unmuted
                        case .indeterminate: state = nil
                        }
                    case .prejoin, .indeterminate: state = nil
                    }
                    if self.transition.observe(state, at: observation.acquiredAtHostTime) {
                        self.publish(self.transition.state, at: observation.acquiredAtHostTime)
                    }
                }
            }
        }
    }

    func handleSharedPTT(_ event: MeetingMutePTTListener.Event) {
        self.queue.async {
            guard self.running else { return }
            if let rendered = self.rendered { rendered.handleSharedPTT(event); return }
            let now = mach_absolute_time()
            switch event {
            case .disabled:
                self.ownedChord = nil
                if self.transition.retireTemporaryGrant(at: now) { self.publish(.muted, at: now, unsafeStart: now, refine: true) }
            case let .modifiersChanged(timestamp, flags):
                guard let owned = self.ownedChord, !MeetingPTTChordMatcher.modifiersMatch(owned, flags: flags) else { return }
                self.ownedChord = nil
                self.releasePTT(timestamp: timestamp, processedAt: now)
            case let .key(held, timestamp, code, flags):
                guard let moduleID = self.moduleID, let chords = self.modules.registration(id: moduleID)?.module.descriptor.pushToTalkChords else { return }
                if held {
                    guard let chord = MeetingPTTChordMatcher.chord(in: chords, keyCode: code, flags: flags) else { return }
                    guard let application = self.application, let window = self.windowID,
                          self.probe.ownsFocus(application: application, windowID: window, boundDocument: self.document) else { return }
                    self.ownedChord = chord
                    self.transition.keyDown(at: timestamp.map(MeetingMicrophoneMuteMonitor.hostTime(nanoseconds:)))
                } else {
                    guard self.ownedChord?.keyCode == code else { return }
                    self.ownedChord = nil
                    self.releasePTT(timestamp: timestamp, processedAt: now)
                }
            }
        }
    }

    private func releasePTT(timestamp: UInt64?, processedAt now: UInt64) {
        guard let observation = self.transition.releaseObservation(
            eventTime: timestamp.map(MeetingMicrophoneMuteMonitor.hostTime(nanoseconds:)),
            processedAt: now, generation: self.generation) else { return }
        self.publish(observation.state, at: observation.observedAtHostTime,
                     unsafeStart: observation.unsafeStartHostTime,
                     until: observation.refinementUntilHostTime, refine: true)
    }

    func stop() async {
        let rendered: (any MeetingMicrophoneObservationPolling)? = await withCheckedContinuation { continuation in
            self.queue.async {
                self.running = false; self.stopped = true; self.generation &+= 1
                let rendered = self.rendered; self.rendered = nil
                continuation.resume(returning: rendered)
            }
        }
        await rendered?.stop()
    }

    private func publish(_ state: MeetingMicrophoneMuteState, at observed: UInt64,
                         unsafeStart: UInt64? = nil, until: UInt64? = nil, refine: Bool = false) {
        guard self.running, state != self.lastPublished || refine else { return }
        self.lastPublished = state
        let now = mach_absolute_time()
        self.handler(.init(state: state, observedAtHostTime: state == .muted ? now : observed,
            generation: self.generation, unsafeStartHostTime: unsafeStart ?? (state == .muted ? observed : nil), refinementUntilHostTime: until))
        if state == .muted { self.transition.negativeWasProcessed(at: mach_absolute_time()) }
    }
}
#endif
