#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

nonisolated struct MeetingMicrophoneMuteObservation: Sendable {
    let state: MeetingMicrophoneMuteState
    /// Raw mach_absolute_time units. A visual transition starts before AX and native capture.
    let observedAtHostTime: UInt64
    let generation: UInt64
    /// A passive key event can arrive after a newer frame. Its acquisition boundary must
    /// narrow earlier approvals independently of observation freshness. Zero revokes all.
    var unsafeStartHostTime: UInt64? = nil
}

/// Best-effort observation of the selected conference's actual microphone control. It never
/// opens an audio device, requests a permission or persists an image. Missing observations
/// preserve the last state; a new attempt starts unmuted by the recording policy.
/// The capture owner must apply its bounded quarantine before every microphone PCM sink.
final nonisolated class MeetingMicrophoneMuteMonitor: @unchecked Sendable {
    typealias Handler = @Sendable (MeetingMicrophoneMuteObservation) -> Void
    private static let nativeRequests = NativeRequestLease()
    private static let nativeTimeoutSeconds = 3.0
    private static let maximumSnapshotAge = 0.65

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
    private var lastUnboundGeometryRefresh = -Double.infinity
    private var unboundGeometry: [UInt32: (frame: CGRect, title: String?)] = [:]
    private var boundWindowID: UInt32?
    private var boundDocumentURL: String?
    private var transition = MeetingMuteTransitionState()
    private var lastPublishedState: MeetingMicrophoneMuteState?
    private let zoomStatus = MeetingZoomMuteStatusObserver()
    private var pttListener: MeetingMutePTTListener?

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
    }

    func start() {
        self.queue.async { [weak self] in
            guard let self, !self.started, !self.stopped else { return }
            self.started = true
            self.running = true
            self.generation &+= 1
            self.publish(.unmuted, at: mach_absolute_time())
            guard self.platform != nil, self.application?.processID.map({ $0 > 0 }) == true else {
                return
            }
            let listener = MeetingMutePTTListener { [weak self] event in
                self?.queue.async { [weak self] in self?.handlePTT(event) }
            }
            self.pttListener = listener
            _ = listener.start()
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
                self.running = false
                self.generation &+= 1
                self.timer?.cancel()
                self.timer = nil
                self.pttListener?.stop()
                self.pttListener = nil
                self.pending = nil
                self.content = nil
                self.unboundGeometry.removeAll()
                self.locator.invalidate()
                self.zoomStatus.invalidate()
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
        guard self.running, self.platform != nil, AXIsProcessTrusted() else { return }
        let began = mach_absolute_time()
        if self.platform == .zoom, let pid = self.application?.processID {
            let snapshot = self.zoomStatus.sample(processID: pid, boundWindowID: self.boundWindowID)
            if let windowID = snapshot.callWindowID {
                if snapshot.state != nil || snapshot.temporaryHUDVisible == true { self.boundWindowID = windowID }
                var changed = self.transition.observe(snapshot.state, at: began)
                changed = self.transition.observeTemporaryHUD(snapshot.temporaryHUDVisible, at: began,
                    corroboratedUnmute: snapshot.state == .unmuted) || changed
                if changed { self.publishTransition(at: began) }
                // The local tile supplies an explicit rendered state without capturing an icon.
                if snapshot.state != nil || snapshot.temporaryHUDVisible == true { return }
            }
        }
        if var pending = self.pending {
            let age = Self.elapsed(since: pending.started, until: began)
            if age > (pending.metadata ? Self.nativeTimeoutSeconds : Self.maximumSnapshotAge), !pending.timedOut {
                pending.timedOut = true
                self.pending = pending
            }
            return
        }
        guard CGPreflightScreenCaptureAccess() else { return }
        guard self.content != nil else { self.requestMetadata(at: began); return }
        guard let control = self.resolveControl() else { return }
        self.requestImage(control, began: began)
    }

    private func requestMetadata(at began: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - self.lastMetadataAttempt >= 1 else { return }
        self.lastMetadataAttempt = now
        guard let id = Self.nativeRequests.acquire() else {
            return
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
                      let content else { return }
                self.content = content
            }
        }
    }

    private func resolveControl() -> MeetingMuteControlLocator.LocatedControl? {
        guard let content = self.content, let platform = self.platform,
              let application = self.application, let pid = application.processID else { return nil }
        let selectedID = self.boundWindowID ?? application.windowID
        var currentFrame: CGRect?
        var currentTitle: String?
        if let id = selectedID,
           let record = (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]])?.first,
           (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
           let bounds = record[kCGWindowBounds as String] as? [String: Any] {
            currentFrame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            currentTitle = record[kCGWindowName as String] as? String
        } else if selectedID == nil {
            self.refreshUnboundGeometryIfNeeded(processID: pid)
        }
        let windows = content.windows.compactMap { window -> MeetingMuteControlLocator.WindowDescriptor? in
            guard let owner = window.owningApplication, owner.processID == pid,
                  owner.bundleIdentifier == application.bundleIdentifier,
                  selectedID == nil || window.windowID == selectedID else { return nil }
            let geometry: (frame: CGRect, title: String?)
            if selectedID != nil {
                guard let currentFrame else { return nil }
                geometry = (currentFrame, currentTitle ?? window.title)
            } else {
                // A stale SCK rectangle must not prevent first binding after a move or resize.
                // Missing current geometry supplies no transition until the next bounded refresh.
                guard let current = self.unboundGeometry[window.windowID] else { return nil }
                geometry = current
            }
            return .init(windowID: window.windowID, processID: pid, bundleIdentifier: owner.bundleIdentifier,
                frame: geometry.frame, title: geometry.title ?? window.title)
        }
        guard let control = self.locator.resolve(platform: platform, windows: windows) else { return nil }
        if self.boundWindowID != nil, control.documentURL != self.boundDocumentURL { return nil }
        self.boundWindowID = control.windowID
        self.boundDocumentURL = control.documentURL
        return control
    }

    private func refreshUnboundGeometryIfNeeded(processID: Int32) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - self.lastUnboundGeometryRefresh >= 1 else { return }
        self.lastUnboundGeometryRefresh = now
        self.unboundGeometry.removeAll(keepingCapacity: true)
        let allowedIDs = Set(self.content?.windows.compactMap { window -> UInt32? in
            guard let owner = window.owningApplication, owner.processID == processID,
                  owner.bundleIdentifier == self.application?.bundleIdentifier else { return nil }
            return window.windowID
        } ?? [])
        guard !allowedIDs.isEmpty, allowedIDs.count <= 64 else { return }
        guard let records = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              records.count <= 4_096 else { return }
        for record in records {
            guard (record[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
                  let id = (record[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  allowedIDs.contains(id),
                  let bounds = record[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { continue }
            self.unboundGeometry[id] = (frame, record[kCGWindowName as String] as? String)
        }
    }

    private func requestImage(_ control: MeetingMuteControlLocator.LocatedControl, began: UInt64) {
        guard let content = self.content,
              let window = content.windows.first(where: { $0.windowID == control.windowID }),
              let display = content.displays.first(where: { $0.frame.contains(control.iconFrame) }) else {
            return
        }
        guard let id = Self.nativeRequests.acquire() else {
            return
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
                guard Self.elapsed(since: began, until: mach_absolute_time()) <= Self.maximumSnapshotAge,
                      let image, let fresh = self.resolveControl(),
                      fresh.windowID == control.windowID, fresh.geometryRevision == control.geometryRevision,
                      let sample = MeetingMuteIconProof.sample(image) else {
                    return
                }
                let visual = MeetingMuteIconProof.classify(rgb: sample)
                let state = MeetingMuteObservationPolicy.state(before: control.semanticState, after: fresh.semanticState, visual: visual)
                if self.transition.observe(state, at: began) { self.publishTransition(at: began) }
            }
        }
    }

    private func publishTransition(at snapshotStart: UInt64) {
        let muted = self.transition.state == .muted
        let processedAt = mach_absolute_time()
        self.publish(self.transition.state, at: muted ? processedAt : snapshotStart,
            unsafeStart: muted ? snapshotStart : nil)
    }

    private func publish(_ state: MeetingMicrophoneMuteState, at time: UInt64,
        unsafeStart: UInt64? = nil, refineBoundary: Bool = false) {
        guard self.running,
              self.lastPublishedState != state || refineBoundary else { return }
        self.lastPublishedState = state
        self.handler(MeetingMicrophoneMuteObservation(state: state, observedAtHostTime: time,
            generation: self.generation, unsafeStartHostTime: unsafeStart))
        // The synchronous capture handler installs its negative fence before returning.
        if state == .muted { self.transition.negativeWasProcessed(at: mach_absolute_time()) }
    }

    private func handlePTT(_ event: MeetingMutePTTListener.Event) {
        guard self.running else { return }
        let now = mach_absolute_time()
        switch event {
        case .disabled:
            self.transition.keyListenerUnavailable()
        case let .key(held, timestamp):
            if held {
                guard let pid = self.application?.processID,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      self.zoomStatus.ownsFocusedWindow(processID: pid) || self.locator.ownsFocusedWindow(processID: pid) else { return }
                self.transition.keyDown(at: timestamp.map(Self.hostTime(nanoseconds:)))
            } else {
                let boundary = MeetingMuteTransitionState.releaseBoundary(
                    eventTime: timestamp.map(Self.hostTime(nanoseconds:)), processedAt: now)
                if self.transition.keyUp(processedAt: now, releasedAt: boundary.unsafeStart > 0 ? boundary.unsafeStart : nil) {
                    self.publish(.muted, at: now, unsafeStart: boundary.unsafeStart, refineBoundary: true)
                } else if let newerUnmute = self.transition.historicalReleaseUnmuteAt {
                    // Narrow the old temporary epoch without overriding a newer rendered unmute.
                    self.publish(.unmuted, at: newerUnmute, unsafeStart: boundary.unsafeStart, refineBoundary: true)
                }
            }
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
        visual: MeetingMuteVisualState) -> MeetingMicrophoneMuteState? {
        if visual == .muted { return .muted }
        if before == .unmuted, after == .unmuted, visual == .unmuted { return .unmuted }
        return nil
    }
}
#endif
