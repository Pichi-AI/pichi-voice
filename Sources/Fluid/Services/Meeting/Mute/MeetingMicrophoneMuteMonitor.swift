#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

nonisolated struct MeetingMicrophoneMuteObservation: Sendable {
    let state: MeetingMicrophoneMuteState
    /// Raw mach_absolute_time units. Positive freshness starts before AX and native capture.
    let observedAtHostTime: UInt64
    let generation: UInt64
}

/// Best-effort observation of the selected conference's actual microphone control. It never
/// opens an audio device, requests a permission, persists an image or grants an unknown state.
/// The capture owner must apply its bounded quarantine before every microphone PCM sink.
final nonisolated class MeetingMicrophoneMuteMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (MeetingMicrophoneMuteObservation) -> Void
    private static let nativeRequests = NativeRequestLease()
    private static let nativeTimeoutSeconds = 3.0
    private static let maximumPositiveAge = 0.65

    private let application: MeetingApplicationIdentity?
    private let handler: Handler
    private let queue = DispatchQueue(label: "meeting.microphone-mute.monitor", qos: .utility)
    private let locator = MeetingMuteControlLocator()
    private var timer: DispatchSourceTimer?
    private var generation: UInt64 = 0
    private var running = false
    private var started = false
    private var stopped = false
    private var pending: PendingRequest?
    private var content: SCShareableContent?
    private var lastMetadataAttempt = -Double.infinity
    private var boundWindowID: UInt32?
    private var boundDocumentURL: String?
    private var geometryRevision: UInt64?
    private var lastPositiveAt: UInt64?
    private var lastState = MeetingMicrophoneMuteState.checking
    private var lastObservationAt: UInt64 = 0
    private var ptt = MeetingMutePTTState()
    private var pttListener: MeetingMutePTTListener?
    private var activationObserver: NSObjectProtocol?

    private struct PendingRequest {
        let id: UUID
        let generation: UInt64
        let started: UInt64
        let metadata: Bool
        var timedOut = false
    }

    /// SCScreenshotManager and SCShareableContent expose no cancellation API. Keep at most one
    /// native request across monitor instances, including a retired generation awaiting reply.
    /// Stopping joins observation delivery, not an undocumented native cancellation operation.
    private final class NativeRequestLease: @unchecked Sendable {
        private let lock = NSLock()
        private var owner: UUID?
        func acquire() -> UUID? {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.owner == nil else { return nil }
            let id = UUID(); self.owner = id; return id
        }
        func release(_ id: UUID) {
            self.lock.lock(); defer { self.lock.unlock() }
            if self.owner == id { self.owner = nil }
        }
    }

    init(application: MeetingApplicationIdentity?, handler: @escaping Handler) {
        self.application = application
        self.handler = handler
    }

    deinit {
        self.timer?.cancel()
        self.pttListener?.stop()
        if let observer = self.activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func start() {
        self.queue.async { [weak self] in
            guard let self, !self.started, !self.stopped else { return }
            self.started = true
            self.running = true
            self.generation &+= 1
            self.publish(.checking, at: mach_absolute_time())
            guard self.platform != nil, self.application?.processID.map({ $0 > 0 }) == true else {
                self.publish(.unknown, at: mach_absolute_time())
                return
            }
            let listener = MeetingMutePTTListener { [weak self] event in
                self?.queue.async { [weak self] in self?.handlePTT(event) }
            }
            self.pttListener = listener
            _ = listener.start()
            self.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { [weak self] in self?.checkPTTFocus() }
            }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(250), leeway: .milliseconds(20))
            timer.setEventHandler { [weak self] in self?.poll() }
            self.timer = timer
            timer.resume()
        }
    }

    /// After this returns, no observation callback from this monitor can execute. A late SDK
    /// completion can only release its static native-request lease and discard its result.
    func stop() async {
        await withCheckedContinuation { continuation in
            self.queue.async {
                guard !self.stopped else { continuation.resume(); return }
                self.stopped = true
                let wasRunning = self.running
                self.running = false
                self.generation &+= 1
                self.timer?.cancel()
                self.timer = nil
                self.pttListener?.stop()
                self.pttListener = nil
                if let observer = self.activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
                self.activationObserver = nil
                self.pending = nil
                self.content = nil
                self.locator.invalidate()
                self.lastPositiveAt = nil
                if wasRunning { self.publish(.unknown, at: mach_absolute_time(), whileStopped: true) }
                continuation.resume()
            }
        }
    }

    private var platform: MeetingMuteControlLocator.Platform? {
        switch self.application?.bundleIdentifier {
        case "us.zoom.xos": return .zoom
        case "com.google.Chrome": return .googleMeet
        default: return nil
        }
    }

    private func poll() {
        guard self.running else { return }
        self.checkPTTFocus()
        let began = mach_absolute_time()
        if let lastPositiveAt = self.lastPositiveAt,
           Self.elapsed(since: lastPositiveAt, until: began) > Self.maximumPositiveAge {
            self.publish(.unknown, at: began)
        }
        if var pending = self.pending {
            let age = Self.elapsed(since: pending.started, until: began)
            if age > (pending.metadata ? Self.nativeTimeoutSeconds : Self.maximumPositiveAge), !pending.timedOut {
                pending.timedOut = true
                self.pending = pending
                self.publish(.unknown, at: began)
            }
            // A timed-out native request is not replaced while it still owns the lease.
            return
        }
        guard self.platform != nil, AXIsProcessTrusted(), CGPreflightScreenCaptureAccess() else {
            self.publish(.unknown, at: began)
            return
        }
        guard self.content != nil else {
            self.requestMetadata(at: began)
            return
        }
        guard let control = self.resolveControl() else {
            self.publish(.unknown, at: mach_absolute_time())
            return
        }
        if self.geometryRevision != control.geometryRevision {
            self.geometryRevision = control.geometryRevision
            self.publish(.unknown, at: mach_absolute_time())
        }
        // A negative action is safe to close immediately. Only pixels may affirm the muted icon.
        if control.semanticState != .unmuted, self.lastState == .unmuted {
            self.publish(.unknown, at: mach_absolute_time())
        }
        self.requestImage(control, began: began)
    }

    private func requestMetadata(at began: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - self.lastMetadataAttempt >= 1 else { return }
        self.lastMetadataAttempt = now
        guard let id = Self.nativeRequests.acquire() else {
            self.publish(.unknown, at: began); return
        }
        let request = PendingRequest(id: id, generation: self.generation, started: began, metadata: true)
        self.pending = request
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, _ in
            Self.nativeRequests.release(id)
            self?.queue.async { [weak self] in
                guard let self, self.running, self.generation == request.generation, self.pending?.id == id else { return }
                self.pending = nil
                guard !request.timedOut,
                      Self.elapsed(since: began, until: mach_absolute_time()) <= Self.nativeTimeoutSeconds,
                      let content else { self.publish(.unknown, at: mach_absolute_time()); return }
                self.content = content
            }
        }
    }

    private func resolveControl() -> MeetingMuteControlLocator.LocatedControl? {
        guard let content = self.content, let platform = self.platform,
              let application = self.application, let pid = application.processID else { return nil }
        let selectedID = self.boundWindowID ?? application.windowID
        var currentFrame: CGRect?
        if let id = selectedID,
           let record = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
           let bounds = record[kCGWindowBounds as String] as? [String: Any] {
            currentFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
        }
        let windows = content.windows.compactMap { window -> MeetingMuteControlLocator.WindowDescriptor? in
            guard let owner = window.owningApplication, owner.processID == pid,
                  owner.bundleIdentifier == application.bundleIdentifier,
                  selectedID == nil || window.windowID == selectedID else { return nil }
            if self.boundWindowID != nil, currentFrame == nil { return nil }
            return .init(windowID: window.windowID, processID: pid, bundleIdentifier: owner.bundleIdentifier,
                frame: window.windowID == selectedID ? (currentFrame ?? window.frame) : window.frame)
        }
        guard let control = self.locator.resolve(platform: platform, windows: windows) else { return nil }
        if self.boundWindowID != nil, control.documentURL != self.boundDocumentURL { return nil }
        self.boundWindowID = control.windowID
        self.boundDocumentURL = control.documentURL
        return control
    }

    private func requestImage(_ control: MeetingMuteControlLocator.LocatedControl, began: UInt64) {
        guard let content = self.content,
              let window = content.windows.first(where: { $0.windowID == control.windowID }),
              let display = content.displays.first(where: { $0.frame.contains(control.iconFrame) }) else {
            self.publish(.unknown, at: mach_absolute_time()); return
        }
        guard let id = Self.nativeRequests.acquire() else {
            self.publish(.unknown, at: mach_absolute_time()); return
        }
        let request = PendingRequest(id: id, generation: self.generation, started: began, metadata: false)
        self.pending = request
        let filter = SCContentFilter(display: display, including: [window])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = control.iconFrame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = 48
        configuration.height = 48
        configuration.showsCursor = false
        configuration.capturesAudio = false
        if #available(macOS 15.0, *) { configuration.captureMicrophone = false }
        SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { [weak self] image, _ in
            Self.nativeRequests.release(id)
            self?.queue.async { [weak self] in
                guard let self, self.running, self.generation == request.generation, self.pending?.id == id else { return }
                self.pending = nil
                guard Self.elapsed(since: began, until: mach_absolute_time()) <= Self.maximumPositiveAge,
                      let image, let fresh = self.resolveControl(),
                      fresh.windowID == control.windowID, fresh.geometryRevision == control.geometryRevision,
                      let sample = MeetingMuteIconProof.sample(image) else {
                    self.publish(.unknown, at: mach_absolute_time()); return
                }
                let visual = MeetingMuteIconProof.classify(rgb: sample)
                if visual == .muted { self.ptt.confirmedMuted(captureStarted: began) }
                var state = MeetingMuteObservationPolicy.state(before: control.semanticState, after: fresh.semanticState, visual: visual)
                if state == .unmuted,
                   (!self.ptt.permitsPositive(captureStarted: began)
                    || Self.elapsed(since: began, until: mach_absolute_time()) > Self.maximumPositiveAge) {
                    state = .unknown
                }
                let timestamp = state == .unmuted ? began : mach_absolute_time()
                self.publish(state, at: timestamp)
            }
        }
    }

    private func publish(_ state: MeetingMicrophoneMuteState, at time: UInt64, whileStopped: Bool = false) {
        guard self.running || whileStopped else { return }
        self.lastState = state
        self.lastObservationAt = time
        self.lastPositiveAt = state == .unmuted ? time : nil
        self.handler(MeetingMicrophoneMuteObservation(state: state, observedAtHostTime: time, generation: self.generation))
    }

    private func handlePTT(_ event: MeetingMutePTTListener.Event) {
        guard self.running else { return }
        let now = mach_absolute_time()
        switch event {
        case .disabled:
            if self.ptt.release(at: now) { self.publish(.unknown, at: now) }
        case let .key(held, timestamp):
            if held {
                guard let pid = self.application?.processID,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.locator.ownsFocusedWindow(processID: pid) else { return }
                self.ptt.keyDown(at: timestamp.map(Self.hostTime(nanoseconds:)),
                    persistentlyUnmuted: self.lastState == .unmuted, latestObservation: self.lastObservationAt)
            } else if self.ptt.release(at: now) {
                self.publish(.unknown, at: now)
            }
        }
    }

    private func checkPTTFocus() {
        guard self.ptt.held, self.ptt.possiblePTT else { return }
        guard let pid = self.application?.processID,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              self.locator.ownsFocusedWindow(processID: pid) else {
            if self.ptt.release(at: mach_absolute_time()) { self.publish(.unknown, at: mach_absolute_time()) }
            return
        }
    }

    private static func hostTime(nanoseconds: UInt64) -> UInt64 {
        let divisor = UInt64(self.timebase.numer), multiplier = UInt64(self.timebase.denom)
        return (nanoseconds / divisor) * multiplier + (nanoseconds % divisor) * multiplier / divisor
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info); return info
    }()

    private static func elapsed(since start: UInt64, until end: UInt64) -> Double {
        guard end >= start else { return .infinity }
        return Double(end - start) * Double(self.timebase.numer) / Double(self.timebase.denom) / 1_000_000_000
    }
}

nonisolated enum MeetingMuteObservationPolicy {
    static func state(before: MeetingMuteSemanticState, after: MeetingMuteSemanticState,
        visual: MeetingMuteVisualState) -> MeetingMicrophoneMuteState {
        if visual == .muted { return .muted }
        if before == .unmuted, after == .unmuted, visual == .unmuted { return .unmuted }
        return .unknown
    }
}
#endif
