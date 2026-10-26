import ActivityKit
import Combine
import Foundation
import SwiftUI
import UIKit

/// Recording-to-Live-Activity decisions without ActivityKit, so the start-once, end-on-exit and
/// stale-date rules are testable without the system activity service.
nonisolated struct MobileRecordingActivityPlan: Equatable, Sendable {
    nonisolated struct Recording: Equatable, Sendable {
        let sessionID: MeetingSessionID
        let startedAt: Date
        let mode: MeetingCaptureMode
    }

    nonisolated enum Action: Equatable, Sendable {
        case start(Recording)
        case end(MeetingSessionID)
    }

    /// A crash or memory kill ends the process without ending its activity, and nothing can update
    /// it again. The system then marks it stale within this interval, and the extension stops
    /// claiming a live recording instead of running the timer for the system's eight-hour limit.
    static let staleInterval: TimeInterval = 300
    /// While recording, the app runs in the background audio mode and moves the stale date forward
    /// this often, so one delayed or missed refresh still keeps a live recording fresh.
    static let refreshInterval: TimeInterval = 120

    /// The recording this process asked the system to show, whether or not the request was granted.
    /// A refused or unavailable request is therefore not retried for the same session.
    private(set) var sessionID: MeetingSessionID?

    /// Only active capture shows the indicator. Preparing, stopping, processing, interruption,
    /// failure and an idle or completed coordinator mean that nothing is being recorded.
    static func recording(state: MeetingCoordinatorState, session: MeetingSession?) -> Recording? {
        switch state {
        case let .recording(id), let .recordingDegraded(id):
            guard let session, session.id == id else { return nil }
            return Recording(sessionID: id, startedAt: session.startedAt, mode: session.mode)
        case .idle, .preparing, .stopping, .processing, .completed, .interrupted, .failed:
            return nil
        }
    }

    static func staleDate(refreshedAt date: Date) -> Date {
        date.addingTimeInterval(self.staleInterval)
    }

    mutating func update(_ desired: Recording?) -> [Action] {
        guard desired?.sessionID != self.sessionID else { return [] }
        var actions = self.sessionID.map { [Action.end($0)] } ?? []
        self.sessionID = desired?.sessionID
        if let desired { actions.append(.start(desired)) }
        return actions
    }
}

/// Owns at most one recording Live Activity for this process and is the only ActivityKit caller.
/// AppServices feeds it coordinator state; the coordinator and processing pipeline stay unaware of it.
/// The process exits through `willTerminate` or, without notice, leaves a stale activity that the
/// next launch ends.
@MainActor
final class MobileRecordingActivityOwner {
    typealias Attributes = MobileRecordingActivityAttributes

    private let settings: SettingsStore
    private var plan = MobileRecordingActivityPlan()
    private var activity: Activity<Attributes>?
    private var refresh: Task<Void, Never>?
    private var pendingEnd: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?

    init(settings: SettingsStore? = nil) {
        self.settings = settings ?? SettingsStore.shared
        // Every activity present before this process requests one belongs to an earlier process,
        // whose recording cannot still be running.
        self.enqueueEnd(Activity<Attributes>.activities)
        self.terminationObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in Self.endAllBeforeExit() }
    }

    /// The published values are delivered before they are stored, so ActivityKit work runs after
    /// the coordinator has finished its transition.
    func observe(_ coordinator: MeetingSessionCoordinator) {
        self.observation = coordinator.$state.combineLatest(coordinator.$activeSession)
            .map { MobileRecordingActivityPlan.recording(state: $0, session: $1) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.apply($0) }
    }

    func apply(_ desired: MobileRecordingActivityPlan.Recording?) {
        for action in self.plan.update(desired) {
            switch action {
            case let .start(recording): self.start(recording)
            case let .end(sessionID): self.end(sessionID)
            }
        }
    }

    #if DEBUG
    /// Review only: the production request path with a synthetic session and no microphone.
    /// `PICHI_UI_LIVE_ACTIVITY_REVIEW_ELAPSED` sets the elapsed seconds.
    /// `PICHI_UI_LIVE_ACTIVITY_REVIEW_STALE_AFTER` stops refreshes and lets the shown activity become
    /// stale after that many seconds, as after a crash; the system does not present an activity that
    /// is already stale when requested.
    func showReviewSample() {
        let environment = ProcessInfo.processInfo.environment
        let elapsed = environment["PICHI_UI_LIVE_ACTIVITY_REVIEW_ELAPSED"].flatMap(TimeInterval.init) ?? 754
        let staleAfter = environment["PICHI_UI_LIVE_ACTIVITY_REVIEW_STALE_AFTER"].flatMap(TimeInterval.init)
        let sample = MobileRecordingActivityPlan.Recording(sessionID: UUID(),
            startedAt: Date().addingTimeInterval(-elapsed), mode: .inRoom)
        self.observation = nil
        for action in self.plan.update(sample) {
            guard case let .start(recording) = action else { continue }
            self.start(recording, staleDate: staleAfter.map { Date().addingTimeInterval($0) })
        }
    }
    #endif

    /// A nil stale date starts a live activity whose stale date the refresh keeps ahead.
    private func start(_ recording: MobileRecordingActivityPlan.Recording, staleDate: Date? = nil) {
        // Live Activities are optional: iPad, a disabled setting or a refusal never affect recording.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = Attributes.ContentState(startedAt: recording.startedAt)
        do {
            let activity = try Activity.request(attributes: self.presentation(for: recording),
                content: ActivityContent(state: state, staleDate: staleDate ?? MobileRecordingActivityPlan.staleDate(refreshedAt: Date())),
                pushType: nil)
            self.activity = activity
            if staleDate == nil { self.keepFresh(activity, state: state) }
        } catch {
            DebugLogger.shared.warning("Recording Live Activity was not started: \(error)", source: "LiveActivity")
        }
    }

    private func keepFresh(_ activity: Activity<Attributes>, state: Attributes.ContentState) {
        self.refresh = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: .seconds(MobileRecordingActivityPlan.refreshInterval)) } catch { return }
                guard let self, self.activity?.id == activity.id else { return }
                await activity.update(ActivityContent(state: state,
                    staleDate: MobileRecordingActivityPlan.staleDate(refreshedAt: Date())))
            }
        }
    }

    private func end(_ sessionID: MeetingSessionID) {
        guard let activity = self.activity, activity.attributes.sessionID == sessionID else { return }
        self.activity = nil
        let refresh = self.refresh
        refresh?.cancel()
        self.refresh = nil
        self.enqueueEnd([activity], after: refresh)
    }

    /// Ends run in order, after any refresh update already in flight for the same activity.
    private func enqueueEnd(_ activities: [Activity<Attributes>], after refresh: Task<Void, Never>? = nil) {
        guard !activities.isEmpty else { return }
        let previous = self.pendingEnd
        self.pendingEnd = Task {
            await previous?.value
            await refresh?.value
            // A recording indicator must not outlive the recording on the Lock Screen.
            for activity in activities { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// A force quit during background recording terminates without a coordinator stop. The bounded
    /// wait lets the end requests reach the system before the process exits; launch cleanup remains
    /// the fallback when the process is killed without this notification.
    nonisolated private static func endAllBeforeExit() {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in Activity<Attributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Resolves copy, brand and appearance with the same contracts the app interface uses.
    private func presentation(for recording: MobileRecordingActivityPlan.Recording) -> Attributes {
        let profile = AppBrand.profile
        let option = self.settings.accentColorOption
        // AdaptiveAppTheme resolves the brand option per appearance and other options as one color.
        let light = option == .brand ? profile.accentLight : option.hex
        let dark = option == .brand ? profile.accentDark : option.hex
        return Attributes(
            sessionID: recording.sessionID,
            productName: AppBrand.meetingName,
            liveStatus: PichiLocalization.text("Meeting recording in progress"),
            interruptedStatus: PichiLocalization.text("Meeting recording was interrupted"),
            meetingKind: recording.mode == .inRoom ? PichiLocalization.text("In-room meeting") : PichiLocalization.text("Online call"),
            accentLight: self.swatch(light),
            accentDark: self.swatch(dark),
            markAsset: BrandPackageStore.shared.hasOverride ? nil : AppBrand.distribution.markAsset,
            titleDesign: Self.design(FluidTypography.systemDesign(for: .default, role: .title)),
            bodyDesign: Self.design(FluidTypography.systemDesign(for: .default, role: .body)))
    }

    private func swatch(_ hex: String) -> Attributes.Swatch {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(Color(hex: hex) ?? self.settings.accentColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return .init(red: Double(red), green: Double(green), blue: Double(blue))
    }

    private static func design(_ design: Font.Design) -> Attributes.TypeDesign {
        switch design {
        case .serif: .serif
        case .rounded: .rounded
        default: .standard
        }
    }
}
