import Foundation
import SwiftUI

// In-memory UI seams only. N5 contract values and N2 operation ownership are
// production declarations; no account, preferences, filesystem or HTTP is used.
#if !PICHI_REAL_LOCALIZATION
nonisolated struct PichiInterfaceLanguage {
    let locale: Locale
    static let english = Self(locale: Locale(identifier: "en"))
}
nonisolated enum PichiLocalization {
    static let language = PichiInterfaceLanguage.english
    static func text(_ key: String, defaultValue: String) -> String { defaultValue }
    static func text(_ key: String, language: PichiInterfaceLanguage, bundle: Bundle, defaultValue: String? = nil) -> String {
        defaultValue ?? key
    }
    static func format(_ key: String, language: PichiInterfaceLanguage, bundle: Bundle,
                       arguments: [CVarArg], defaultValue: String? = nil) -> String {
        String(format: defaultValue ?? key, locale: language.locale, arguments: arguments)
    }
}
#endif
nonisolated enum CloudUIFixture {
    static let context = AccountContext(
        identity: .init(issuer: "https://synthetic.invalid", subject: "synthetic", internalUserID: "person"),
        organizationID: "organization", workspaceID: "workspace", generation: UUID())
}
nonisolated struct PrivateProfileSnapshot: Equatable, Sendable {
    let id: String
    let context: AccountContext?
    let generation: UUID
    let isReadable: Bool
    var isGuest: Bool { self.id == "guest" }
}
nonisolated enum PrivateProfileStorage {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var value = PrivateProfileSnapshot(id: "synthetic-A", context: CloudUIFixture.context,
                                          generation: CloudUIFixture.context.generation, isReadable: true)
        var admitted = true
    }
    private static let state = State()
    static var current: PrivateProfileSnapshot { self.state.lock.withLock { self.state.value } }
    static var acceptsNewWork: Bool { self.state.lock.withLock { self.state.admitted } }
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool {
        self.current == profile && profile.isReadable
    }
    static func select(_ value: PrivateProfileSnapshot, admitted: Bool = true) {
        self.state.lock.withLock { self.state.value = value; self.state.admitted = admitted }
    }
}
@MainActor final class PrivateProfileService: ObservableObject {
    static let shared = PrivateProfileService()
    static let willConceal = Notification.Name("synthetic.cloud-ui.will-conceal")
    @Published var projectionRevision = UUID()
    @Published var sourceRevision = UUID()
    @Published var isPrivateDataVisible = true
    @Published var isTransitioning = false
    private final class Participant {
        weak var value: (any PrivateProfileTransitionParticipant)?
        init(_ value: any PrivateProfileTransitionParticipant) { self.value = value }
    }
    private var participants: [Participant] = []
    func register(_ value: any PrivateProfileTransitionParticipant) { self.participants.append(.init(value)) }
}
@MainActor final class AccountSessionService: ObservableObject {
    @Published var state = AccountSessionState.signedIn
    @Published var context: AccountContext? = CloudUIFixture.context
    @Published var generation = CloudUIFixture.context.generation
    var account: AccountSnapshot? = .init(schemaVersion: 1,
        account: .init(id: "person", displayName: "Synthetic person", email: nil),
        identity: .init(issuer: "https://synthetic.invalid", subject: "synthetic"), organizations: [])
    // N1 clears its command slot without necessarily publishing a new context.
    var commandInFlight = false
    func isCurrent(_ context: AccountContext) -> Bool {
        !self.commandInFlight && self.state == .signedIn && self.context == context
    }
}
actor CloudUIFixtureGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if self.released { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
    func release() {
        self.released = true
        let pending = self.waiters; self.waiters = []
        for waiter in pending { waiter.resume() }
    }
}
@MainActor final class PichiCloudPublicationService: ObservableObject {
    enum UnsafeFailure: Error { case syntheticServerDetail }
    @Published var snapshot = PichiCloudPublicationSnapshot(availability: .ready, cloudSyncEnabled: true, items: [:])
    var calls: [String] = []
    var gate: CloudUIFixtureGate?
    var shouldFail = false
    var ignoreCancellation = false
    var result = PichiCloudPublicationStatus.localOnly
    var optionsPages: [String: PichiPublicationAssessmentOptions] = [:]
    var optionsRequests: [(cursor: String?, limit: Int)] = []
    var resolutions: [(id: MeetingSessionID, participantID: UUID, criteriaIDs: [String])] = []
    private func run(_ name: String) async throws {
        self.calls.append(name)
        if let gate { await gate.wait() }
        if !self.ignoreCancellation { try Task.checkCancellation() }
        if self.shouldFail { throw UnsafeFailure.syntheticServerDetail }
    }
    func refresh() async throws { try await self.run("refresh") }
    func status(for id: MeetingSessionID) async throws -> PichiCloudPublicationStatus {
        try await self.run("status"); return self.result
    }
    func send(_ id: MeetingSessionID) async throws { try await self.run("send") }
    func retry(_ id: MeetingSessionID) async throws { try await self.run("retry") }
    func reconcile(_ id: MeetingSessionID) async throws { try await self.run("reconcile") }
    func assessmentOptions(for id: MeetingSessionID, cursor: String? = nil,
                           limit: Int = 50) async throws -> PichiPublicationAssessmentOptions {
        self.optionsRequests.append((cursor, limit))
        try await self.run("options")
        let page = self.optionsPages[cursor ?? ""]!
        var items = self.snapshot.items; items[id] = .accepted(page.receipt)
        self.snapshot = .init(availability: self.snapshot.availability, cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: items)
        return page
    }
    func resolveAssessment(_ id: MeetingSessionID, participantID: UUID, criteriaIDs: [String]) async throws {
        self.resolutions.append((id, participantID, criteriaIDs))
        try await self.run("resolve")
        if let old = self.snapshot.items[id].flatMap(DesktopCloudPublicationCopy.receipt) {
            let receipt = PichiPublicationReceipt(schemaVersion: old.schemaVersion, importID: old.importID,
                recordingID: old.recordingID, uploadState: .accepted, analysisState: .queued)
            var items = self.snapshot.items; items[id] = .accepted(receipt)
            self.snapshot = .init(availability: self.snapshot.availability, cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: items)
        }
    }
    func resume() async throws { try await self.run("resume") }
    func setCloudSyncEnabled(_ value: Bool) async throws {
        if !value {
            self.snapshot = .init(availability: .pausing, cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: [:])
        }
        try await self.run("toggle")
        self.snapshot = .init(availability: value ? .ready : .paused, cloudSyncEnabled: value, items: [:])
    }
    func pause() async {
        self.calls.append("pause")
        // Intentionally ignore cancellation until released, to verify caller joining.
        if let gate { await gate.wait() }
        self.snapshot = .init(availability: .paused, cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: [:])
    }
}

// Inert role-compatible theme for native SwiftUI typechecking, not visual evidence.
nonisolated struct CloudUITheme: Sendable {
    nonisolated struct Spacing: Sendable { let sm: CGFloat = 8; let xs: CGFloat = 4 }
    nonisolated struct Metrics: Sendable { let spacing = Spacing() }
    nonisolated struct Typography: Sendable {
        let bodyStrong = Font.body
        let bodySmall = Font.callout
        let bodySmallStrong = Font.callout
        let caption = Font.caption
    }
    nonisolated struct Palette: Sendable {
        let primaryText = Color.primary
        let secondaryText = Color.secondary
        let warning = Color.orange
        let accent = Color.blue
        func readableText(_ color: Color) -> Color { color }
    }
    let metrics = Metrics()
    let typography = Typography()
    let palette = Palette()
}
nonisolated private struct CloudUIThemeKey: EnvironmentKey {
    static let defaultValue = CloudUITheme()
}
extension EnvironmentValues {
    var theme: CloudUITheme {
        get { self[CloudUIThemeKey.self] }
        set { self[CloudUIThemeKey.self] = newValue }
    }
}
