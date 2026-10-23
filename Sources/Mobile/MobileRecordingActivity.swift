import ActivityKit
import Combine
import Foundation
import SwiftUI
import UIKit

/// Recording-to-Live-Activity decisions without ActivityKit, so the start-once, end-on-exit and
/// stale-cleanup rules are testable without the system activity service.
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

    mutating func update(_ desired: Recording?) -> [Action] {
        guard desired?.sessionID != self.sessionID else { return [] }
        var actions = self.sessionID.map { [Action.end($0)] } ?? []
        self.sessionID = desired?.sessionID
        if let desired { actions.append(.start(desired)) }
        return actions
    }

    /// An activity this process did not request belongs to an earlier process, whose recording
    /// cannot still be running.
    static func staleActivityIDs(existing: [String], owned: String?) -> [String] {
        existing.filter { $0 != owned }
    }
}

/// Owns at most one recording Live Activity for this process and is the only ActivityKit caller.
/// AppServices feeds it coordinator state; the coordinator and processing pipeline stay unaware of it.
@MainActor
final class MobileRecordingActivityOwner {
    typealias Attributes = MobileRecordingActivityAttributes

    private let settings: SettingsStore
    private var plan = MobileRecordingActivityPlan()
    private var activity: Activity<Attributes>?
    private var pendingEnd: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var terminationObserver: NSObjectProtocol?

    init(settings: SettingsStore? = nil) {
        self.settings = settings ?? SettingsStore.shared
        // Read before this process can request its own activity, so only earlier ones are ended.
        let existing = Activity<Attributes>.activities
        let stale = Set(MobileRecordingActivityPlan.staleActivityIDs(existing: existing.map(\.id), owned: nil))
        self.enqueueEnd(existing.filter { stale.contains($0.id) })
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

    /// Joined cleanup for an orderly shutdown.
    func shutdown() async {
        self.observation = nil
        self.apply(nil)
        await self.pendingEnd?.value
    }

    #if DEBUG
    /// Review only: the production request path with a synthetic session and no microphone.
    func showReviewSample(elapsed: TimeInterval = 754) {
        self.observation = nil
        self.apply(.init(sessionID: UUID(), startedAt: Date().addingTimeInterval(-elapsed), mode: .inRoom))
    }
    #endif

    private func start(_ recording: MobileRecordingActivityPlan.Recording) {
        // Live Activities are optional: iPad, a disabled setting or a refusal never affect recording.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            self.activity = try Activity.request(attributes: self.presentation(for: recording),
                content: ActivityContent(state: .init(startedAt: recording.startedAt), staleDate: nil), pushType: nil)
        } catch {
            DebugLogger.shared.warning("Recording Live Activity was not started: \(error)", source: "LiveActivity")
        }
    }

    private func end(_ sessionID: MeetingSessionID) {
        guard let activity = self.activity, activity.attributes.sessionID == sessionID else { return }
        self.activity = nil
        self.enqueueEnd([activity])
    }

    private func enqueueEnd(_ activities: [Activity<Attributes>]) {
        guard !activities.isEmpty else { return }
        let previous = self.pendingEnd
        self.pendingEnd = Task {
            await previous?.value
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
            recordingLabel: PichiLocalization.text("Recording"),
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
