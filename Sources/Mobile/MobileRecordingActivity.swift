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
    private let waitForRefresh: @Sendable () async throws -> Void
    private var plan = MobileRecordingActivityPlan()
    private var activity: Activity<Attributes>?
    private var refresh: Task<Void, Never>?
    private var pendingEnd: Task<Void, Never>?
    private var pendingStart: Task<Void, Never>?
    private var observation: AnyCancellable?
    private var terminationObserver: AnyCancellable?
    private weak var coordinator: MeetingSessionCoordinator?
    private var revision = UUID()
    private var concealed = true
    private var terminating = false
    private var lastObservedSessionID: MeetingSessionID?
    private var suppressedSessionID: MeetingSessionID?
    #if DEBUG
    private var reviewStaleAfter: TimeInterval?
    #endif

    init(settings: SettingsStore? = nil,
         waitForRefresh: @escaping @Sendable () async throws -> Void = {
             try await Task.sleep(for: .seconds(MobileRecordingActivityPlan.refreshInterval))
         }) {
        self.settings = settings ?? SettingsStore.shared
        self.waitForRefresh = waitForRefresh
        // Cleanup is owned and joined before any new request, including startup races.
        self.enqueueEnd(Activity<Attributes>.activities)
        // UIKit delivers this notification on the main actor. The cancellable owns its observer.
        self.terminationObserver = NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    if let self, !self.endBeforeExit() {
                        DebugLogger.shared.warning("Recording Live Activity cleanup exceeded the termination deadline", source: "LiveActivity")
                    }
                }
            }
    }

    /// Read the coordinator after publication commits, then enforce the existing profile boundary.
    func observe(_ coordinator: MeetingSessionCoordinator) {
        self.coordinator = coordinator
        self.observation = coordinator.$state.combineLatest(coordinator.$activeSession)
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak coordinator] _ in
                guard let coordinator else { return }
                self?.applyCurrentRecording(coordinator)
            }
    }

    private func applyCurrentRecording(_ coordinator: MeetingSessionCoordinator) {
        let profile = PrivateProfileStorage.current
        let session = coordinator.activeSession
        let owned = session.map { $0.profileOwnership?.matches(profile) ?? profile.isGuest } ?? true
        let desired = owned ? MobileRecordingActivityPlan.recording(state: coordinator.state, session: session) : nil
        self.apply(desired)
    }

    /// Composition calls this only after the account/profile source set has committed.
    func resumeAfterProfileCommit() async {
        let profile = PrivateProfileStorage.current
        await self.pendingEnd?.value
        guard !Task.isCancelled, !self.terminating,
              PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile) else { return }
        self.concealed = false
        if let coordinator { self.applyCurrentRecording(coordinator) }
    }

    func apply(_ desired: MobileRecordingActivityPlan.Recording?) {
        if let desired { self.lastObservedSessionID = desired.sessionID }
        let profile = PrivateProfileStorage.current
        let permitted = !self.concealed && !self.terminating
            && PrivateProfileStorage.acceptsNewWork && PrivateProfileStorage.isReadable(profile)
            && desired?.sessionID != self.suppressedSessionID ? desired : nil
        let actions = self.plan.update(permitted)
        guard !actions.isEmpty else { return }
        let revision = UUID()
        self.revision = revision
        let previousStart = self.pendingStart
        previousStart?.cancel()
        self.pendingStart = nil
        for action in actions {
            switch action {
            case let .end(sessionID): self.end(sessionID)
            case let .start(recording):
                let previousEnd = self.pendingEnd
                self.pendingStart = Task { [weak self] in
                    defer { if self?.revision == revision { self?.pendingStart = nil } }
                    await previousStart?.value
                    await previousEnd?.value
                    guard let self, !Task.isCancelled, self.revision == revision,
                          !self.concealed, !self.terminating,
                          PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile),
                          self.plan.sessionID == recording.sessionID else { return }
                    self.start(recording, profile: profile)
                }
            }
        }
        if self.pendingStart == nil, let previousStart {
            self.pendingStart = Task { [weak self] in
                await previousStart.value
                if self?.revision == revision { self?.pendingStart = nil }
            }
        }
    }

    /// Busy logout conceals presentation and joins updates/ends without stopping admitted capture.
    func conceal(admittedSessionID: MeetingSessionID? = nil) async {
        self.suppressedSessionID = admittedSessionID ?? self.lastObservedSessionID ?? self.plan.sessionID
        self.concealed = true
        self.revision = UUID()
        let start = self.pendingStart
        start?.cancel()
        self.pendingStart = nil
        _ = self.plan.update(nil)
        let current = self.activity
        self.activity = nil
        let refresh = self.refresh
        refresh?.cancel()
        self.refresh = nil
        self.enqueueEnd(current.map { [$0] } ?? [], after: refresh)
        await start?.value
        await self.pendingEnd?.value
    }

    func shutdown() async {
        self.terminating = true
        self.terminationObserver?.cancel()
        self.terminationObserver = nil
        self.observation?.cancel()
        self.observation = nil
        await self.conceal()
    }

    #if DEBUG
    /// Synthetic visual review uses the same admitted request path after guest restoration.
    func showReviewSample() {
        let environment = ProcessInfo.processInfo.environment
        let elapsed = environment["PICHI_UI_LIVE_ACTIVITY_REVIEW_ELAPSED"].flatMap(TimeInterval.init) ?? 754
        self.reviewStaleAfter = environment["PICHI_UI_LIVE_ACTIVITY_REVIEW_STALE_AFTER"].flatMap(TimeInterval.init)
        let sample = MobileRecordingActivityPlan.Recording(sessionID: UUID(),
            startedAt: Date().addingTimeInterval(-elapsed), mode: .inRoom)
        self.observation?.cancel()
        self.observation = nil
        self.apply(sample)
    }
    #endif

    private func start(_ recording: MobileRecordingActivityPlan.Recording, profile: PrivateProfileSnapshot) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = Attributes.ContentState(startedAt: recording.startedAt)
        do {
            #if DEBUG
            let reviewDeadline = self.reviewStaleAfter.map { Date().addingTimeInterval($0) }
            #else
            let reviewDeadline: Date? = nil
            #endif
            let activity = try Activity.request(attributes: self.presentation(for: recording),
                content: ActivityContent(state: state, staleDate: reviewDeadline ?? MobileRecordingActivityPlan.staleDate(refreshedAt: Date())),
                pushType: nil)
            self.activity = activity
            guard reviewDeadline == nil else { return }
            let wait = self.waitForRefresh
            let activityID = activity.id
            // Cancellation and OS update completion must not need the main actor, which
            // willTerminate may temporarily block while waiting for the final end request.
            self.refresh = Task.detached {
                while !Task.isCancelled {
                    do { try await wait() } catch { return }
                    guard !Task.isCancelled, PrivateProfileStorage.acceptsNewWork,
                          PrivateProfileStorage.isReadable(profile) else { return }
                    guard let current = Activity<Attributes>.activities.first(where: { $0.id == activityID }) else { return }
                    await current.update(ActivityContent(state: state,
                        staleDate: MobileRecordingActivityPlan.staleDate(refreshedAt: Date())))
                }
            }
        } catch {
            DebugLogger.shared.warning("Recording Live Activity was not started: \(error)", source: "LiveActivity")
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

    /// A concrete background cleanup chain survives main-actor termination waiting.
    private func enqueueEnd(_ activities: [Activity<Attributes>], after refresh: Task<Void, Never>? = nil) {
        let previous = self.pendingEnd
        let activityIDs = activities.map(\.id)
        self.pendingEnd = Task.detached {
            await previous?.value
            await refresh?.value
            // Activity is not Sendable. Resolve its process-owned proxy on this executor;
            // only immutable IDs cross the actor boundary.
            for id in activityIDs {
                guard let activity = Activity<Attributes>.activities.first(where: { $0.id == id }) else { continue }
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Returns false on the OS's bounded termination deadline; startup/stale cleanup remains the fallback.
    @discardableResult
    func endBeforeExit(timeout: TimeInterval = 2) -> Bool {
        self.terminating = true
        self.concealed = true
        self.revision = UUID()
        self.observation?.cancel()
        self.observation = nil
        self.pendingStart?.cancel()
        self.pendingStart = nil
        let refresh = self.refresh
        refresh?.cancel()
        self.refresh = nil
        var activities = Activity<Attributes>.activities
        if let activity = self.activity, !activities.contains(where: { $0.id == activity.id }) { activities.append(activity) }
        self.activity = nil
        _ = self.plan.update(nil)
        self.enqueueEnd(activities, after: refresh)
        let cleanup = self.pendingEnd
        let done = DispatchSemaphore(value: 0)
        Task.detached { await cleanup?.value; done.signal() }
        return done.wait(timeout: .now() + max(0, timeout)) == .success
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
