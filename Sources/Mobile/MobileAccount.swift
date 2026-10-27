import Combine
import Foundation

/// Transient UI commands only. The shared service owns authentication, credentials,
/// profile transitions and cancellation. One action lock also covers workspace selection,
/// whose service contract deliberately has no separate published busy state.
@MainActor
final class MobileAccountInteraction: ObservableObject {
    enum Action { case signIn, switchPerson, workspace, organization, logout, cancel, guest }
    @Published private(set) var action: Action?
    @Published private(set) var presentationRevision = UUID()
    @Published private var selectionError: (generation: UUID, code: AccountError)?
    let session: AccountSessionService
    private let requireTransitionAdmission: @MainActor () throws -> Void
    private var operation: Task<Void, Never>?
    private var operationID: UUID?

    init(session: AccountSessionService, requireTransitionAdmission: @escaping @MainActor () throws -> Void) {
        self.session = session; self.requireTransitionAdmission = requireTransitionAdmission
    }

    var error: AccountError? {
        selectionError?.generation == session.generation ? selectionError?.code : nil
    }

    var canSignIn: Bool {
        action == nil && session.isSignInAvailable
            && (session.state == .signedOut || session.state == .reauthenticationRequired)
    }

    func signIn() {
        guard canSignIn else { return }
        begin(.signIn) { await self.session.signIn() }
    }

    func signIn(email: String, password: String) {
        guard canSignIn else { return }
        begin(.signIn) { await self.session.signIn(email: email, password: password) }
    }

    func switchPerson() {
        guard action == nil, session.state == .signedIn, session.isSignInAvailable,
              let expected = session.context, session.isCurrent(expected) else { return }
        begin(.switchPerson) {
            guard self.session.isCurrent(expected) else { return }
            do { try self.requireTransitionAdmission() }
            catch { self.selectionError = (expected.generation, error as? AccountError ?? .busy); return }
            await self.session.switchPerson()
        }
    }

    func selectWorkspace(organizationID: String, workspaceID: String) {
        guard action == nil, session.state == .signedIn, session.isSignInAvailable,
              let expected = session.context, session.isCurrent(expected) else { return }
        begin(.workspace) {
            guard self.session.isCurrent(expected) else { return }
            do {
                try self.requireTransitionAdmission()
                try await self.session.selectWorkspace(organizationID: organizationID, workspaceID: workspaceID)
            }
            catch {
                // Validation may fail before the service publishes an error. A replaced
                // account/generation must never acquire this former selection's error.
                if self.session.context == expected, self.session.generation == expected.generation {
                    self.selectionError = (expected.generation, error as? AccountError ?? .networkUnavailable)
                }
            }
        }
    }

    func selectLegacyOrganization(_ organizationID: String) {
        guard action == nil, session.isLegacySession, let expected = session.context,
              session.isCurrent(expected) else { return }
        begin(.organization) {
            guard self.session.isCurrent(expected) else { return }
            do {
                try self.requireTransitionAdmission()
                try await self.session.selectLegacyOrganization(organizationID)
            } catch {
                if self.session.generation == expected.generation {
                    self.selectionError = (expected.generation, error as? AccountError ?? .networkUnavailable)
                }
            }
        }
    }

    func logout() {
        guard action == nil else { return }
        begin(.logout) { await self.session.logout() }
    }

    func cancelSignIn() {
        guard action == .signIn || action == .switchPerson || session.state == .signingIn else { return }
        let previous = operation
        begin(.cancel) {
            await self.session.cancelSignIn()
            await previous?.value
        }
    }

    func continueAsGuest(_ completion: @escaping @MainActor () -> Void) {
        guard action == nil || action == .signIn || action == .switchPerson else { return }
        let previous = operation
        begin(.guest) {
            // Restoration retains signedOut while doing work. Explicit guest choice
            // must join all shared account work, rather than infer it from view state.
            if self.session.isLegacySession { await self.session.retireLegacySession() }
            else { await self.session.logout() }
            await previous?.value
            guard self.session.context == nil,
                  self.session.presentationError == nil || self.session.presentationError == .revocationUnavailable,
                  self.session.state == .signedOut || self.session.state == .unconfigured else { return }
            completion()
        }
    }

    func cancelOwnedSignInOnDisappear(profileBoundaryChanged: Bool = false) {
        // Native tab/split navigation can retain a hidden Account panel. Retire its
        // transient draft and focus even when no authentication task is running.
        presentationRevision = UUID()
        guard !profileBoundaryChanged, action == .signIn || action == .switchPerson else { return }
        cancelSignIn()
    }

    func privateProjectionDidChange() { selectionError = nil }

    /// Focused synthetic tests can join the actual command without polling view state.
    func waitUntilIdle() async {
        while let pending = operation { await pending.value }
    }

    private func begin(_ action: Action, perform: @escaping @MainActor () async -> Void) {
        let id = UUID()
        operationID = id; self.action = action; selectionError = nil
        operation = Task { @MainActor in
            await perform()
            guard self.operationID == id else { return }
            self.operation = nil; self.operationID = nil; self.action = nil
        }
    }
}

/// Serializes transient view commands only. The injected facade owns durable settings,
/// delivery, polling and network cancellation. Existing private publication jobs retain
/// each command until it joins, including a coherent OFF operation during navigation.
@MainActor
final class MobileCloudInteraction: ObservableObject {
    enum Action: Equatable {
        case toggle(Bool), retention(Bool), pause, resume, send(UUID), retry(UUID), reconcile(UUID), options(UUID), assessment(UUID)
    }
    @Published private(set) var action: Action?
    @Published private(set) var failed = false
    let publications: MobilePrivatePublicationTasks
    private var observers = Set<AnyCancellable>()
    private var retirement: Task<Void, Never>?
    private let statusSource: @MainActor () -> MobilePrivatePublicationContext?
    private let readinessDelay: @MainActor () async throws -> Void
    private var statusReads: [UUID: Task<Void, Never>] = [:]
    static let maximumStatusReads = 32
    var pendingStatusReadCount: Int { statusReads.count }

    init(publications: MobilePrivatePublicationTasks,
         statusSource: @escaping @MainActor () -> MobilePrivatePublicationContext? = { nil },
         readinessDelay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .milliseconds(100)) }) {
        self.publications = publications; self.statusSource = statusSource; self.readinessDelay = readinessDelay
    }

    /// Wait only for local command retirement. N1 can release its operation slot
    /// without publishing a changed context, so a row task cannot rely on another
    /// SwiftUI identity change. The actual read retains the strict publication fence;
    /// its result is true only when the still-current row projected that local read.
    @discardableResult
    func readStatus(presentationID: UUID,
                    report: @escaping @MainActor (Error) -> Void,
                    operation: @escaping @MainActor (MobilePrivatePublicationTasks.Admission) async throws -> Bool) -> Task<Void, Never>? {
        if let pending = statusReads[presentationID] { return pending }
        guard retirement == nil, !Task.isCancelled,
              let source = statusSource() else { return nil }
        guard statusReads.count < Self.maximumStatusReads else {
            guard !Task.isCancelled, statusSource() == source else { return nil }
            report(AccountError.busy)
            return nil
        }
        let task = Task { @MainActor in
            defer { self.statusReads.removeValue(forKey: presentationID) }
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            do {
                for _ in 0..<600 {
                    try Task.checkCancellation()
                    guard self.statusSource() == source else { return }
                    if let admission = self.publications.admit(), admission.context == source {
                        var completed = false, reported = false
                        if let read = self.publications.start(affectsBusy: false, report: { error in
                            reported = true; report(error)
                        }, operation: { admission in
                            do { completed = try await operation(admission) }
                            catch {
                                // status(for:) is a local read. An N1 command can
                                // start before its facade task enters currentScope.
                                let transient = error as? AccountError == .busy || error as? AccountError == .staleOperation
                                if !transient || self.publications.canPublish(admission) { throw error }
                            }
                        }) {
                            await withTaskCancellationHandler { await read.value } onCancel: { read.cancel() }
                            // N1 can acquire its command slot between admission and
                            // task entry. A skipped read still needs the local wait.
                            if completed || reported { return }
                        }
                    }
                    guard ContinuousClock.now < deadline else { break }
                    try await self.readinessDelay()
                }
                guard !Task.isCancelled, self.retirement == nil, self.statusSource() == source else { return }
                report(AccountError.busy)
            } catch { /* Local cancellation has no private error projection. */ }
        }
        statusReads[presentationID] = task
        return task
    }

    func cancelStatusRead(presentationID: UUID) { statusReads[presentationID]?.cancel() }

    @discardableResult
    func run(_ action: Action,
             operation: @escaping @MainActor (MobilePrivatePublicationTasks.Admission) async throws -> Void) -> Task<Void, Never>? {
        guard self.action == nil else { return nil }
        self.action = action; self.failed = false
        let task = publications.start(affectsBusy: false, report: { [weak self] error in
            if error as? AccountError != .staleOperation, error as? AccountError != .cancelled,
               !(error is ProtectedDataAccessError) {
                self?.failed = true
            }
        }, finished: { self.action = nil }) { admission in
            try await operation(admission)
        }
        if task == nil { self.action = nil }
        return task
    }

    func invalidate() {
        failed = false
        for pending in statusReads.values { pending.cancel() }
        publications.cancel()
        guard retirement == nil else { return }
        let pendingReads = Array(statusReads.values)
        retirement = Task { @MainActor in
            for pending in pendingReads { await pending.value }
            await self.publications.cancelAndJoin()
            self.failed = false
            self.retirement = nil
            self.publications.resume()
        }
    }

    func waitUntilFinished() async { await retirement?.value }
}

/// A bounded, explicit assessment draft. Pages remain owned by the presentation;
/// only user-selected opaque identifiers and their unchanged labels are retained here.
nonisolated struct MobileCloudAssessmentSelection {
    static let maximumCriteria = 100
    private(set) var participantID: UUID?
    private(set) var criteria: [String: String] = [:]

    @discardableResult
    mutating func selectParticipant(_ id: UUID, offered: Set<UUID>) -> Bool {
        guard offered.contains(id) else { return false }
        participantID = id
        return true
    }

    @discardableResult
    mutating func toggleCriterion(_ id: String, name: String, offered: Set<String>) -> Bool {
        guard offered.contains(id) else { return false }
        if criteria.removeValue(forKey: id) != nil { return true }
        guard criteria.count < Self.maximumCriteria else { return false }
        criteria[id] = name
        return true
    }

    mutating func removeCriterion(_ id: String) { criteria.removeValue(forKey: id) }

    mutating func clear() {
        participantID = nil
        criteria.removeAll()
    }

    func canSubmit(canResolvePending: Bool, receiptPending: Bool, offeredParticipants: Set<UUID>) -> Bool {
        guard canResolvePending, receiptPending, let participantID,
              offeredParticipants.contains(participantID) else { return false }
        return !criteria.isEmpty && criteria.count <= Self.maximumCriteria
    }
}

/// These are presentation-safe service codes, never raw provider errors or user data.
/// The shared catalog owns the wording for both native platforms.
nonisolated enum MobileAccountCopy {
    static func error(_ error: AccountError, language: PichiInterfaceLanguage = PichiLocalization.language,
                      bundle: Bundle = .main) -> String {
        let fallback: String
        switch error {
        case .unconfigured: fallback = "Sign-in is not configured for this app. You can continue using this device."
        case .isolationRequired: fallback = "Sign-in is not available yet. You can continue using this device."
        case .busy: fallback = "An account operation is still finishing. Try again shortly."
        case .cancelled: fallback = "Sign-in was cancelled. You can continue as guest."
        case .invalidCallback, .invalidState: fallback = "Sign-in could not be verified. Please try again."
        case .invalidToken, .invalidAccount: fallback = "Your account could not be verified. Please sign in again."
        case .invalidConfiguration: fallback = "Sign-in is unavailable in this app configuration."
        case .invalidResponse: fallback = "The account service returned an invalid response. Please try again."
        case .credentialsUnavailable: fallback = "Account cleanup could not finish. Retry sign-out before signing in again."
        case .networkUnavailable: fallback = "The account service could not be reached. Check your connection and try again."
        case .reauthenticationRequired: fallback = "Please sign in again to reconnect your account."
        case .permissionDenied: fallback = "Your account does not have access to this workspace."
        case .workspaceUnavailable: fallback = "This workspace is no longer available. Choose another workspace."
        case .staleOperation: fallback = "Your account changed. Please try again from the current account."
        case .revocationUnavailable: fallback = "Signed out on this device. The server could not confirm revocation of this device's session."
        case .previousAccountReturned: fallback = "The same account was returned. Try switching again and choose a different account."
        case .captchaRequired: fallback = "This sign-in requires a browser verification that this app cannot complete. Wait for the sign-in limit to expire before trying again."
        case .browserLoginRequired: fallback = "This account requires browser sign-in. Password sign-in is unavailable for this account."
        case .rateLimited: fallback = "Too many sign-in attempts. Wait before trying again."
        }
        return PichiLocalization.text("account.error.\(error.rawValue)", language: language, bundle: bundle, defaultValue: fallback)
    }
}

#if os(iOS)
import SwiftUI

struct MobileAccountSettings: View {
    @ObservedObject var session: AccountSessionService
    var interaction: MobileAccountInteraction? = nil
    var cloudPublication: PichiCloudPublicationService? = nil
    var cloudInteraction: MobileCloudInteraction? = nil
    var body: some View {
        Form {
            Section { MobileAccountPanel(session: session, interaction: interaction) }
            if let cloudPublication {
                Section {
                    MobileCloudSyncSettings(service: cloudPublication, session: session, interaction: cloudInteraction)
                }
            }
        }
            .navigationTitle(PichiLocalization.text("account.title", defaultValue: "Account"))
            .accessibilityIdentifier("account.settings")
    }
}

/// Reused on the Ready page without inserting or renumbering persisted setup steps.
struct MobileAccountOnboarding: View {
    @ObservedObject var session: AccountSessionService
    let continueAsGuest: @MainActor () -> Void
    let actionChanged: (Bool) -> Void
    var cloudPublication: PichiCloudPublicationService? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            Text(PichiLocalization.text("account.onboarding.title", defaultValue: "Optional account"))
                .font(theme.typography.sectionTitle)
            MobileAccountPanel(session: session, continueAsGuest: continueAsGuest, actionChanged: actionChanged)
            if let cloudPublication {
                Divider()
                MobileCloudSyncSettings(service: cloudPublication, session: session)
            }
        }.padding(16)
            .background(theme.palette.secondaryText.opacity(0.06), in: RoundedRectangle(cornerRadius: theme.metrics.corners.md))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("onboarding.account")
    }
}

/// Account operations stay separate from optional cloud consent.
private struct MobileAccountPanel: View {
    @ObservedObject var session: AccountSessionService
    @ObservedObject private var privateProfile = PrivateProfileService.shared
    var continueAsGuest: (@MainActor () -> Void)?
    var actionChanged: (Bool) -> Void
    @StateObject private var interaction: MobileAccountInteraction
    @State private var presentedProjectionRevision: UUID?
    @State private var legacyEmail = ""
    @State private var legacyPassword = ""
    @State private var confirmingLegacyLogout = false
    @State private var legacyLogoutContext: AccountContext?
    private enum LegacyField: Hashable { case email, password }
    @FocusState private var legacyFocus: LegacyField?
    @Environment(\.theme) private var theme

    init(session: AccountSessionService, interaction suppliedInteraction: MobileAccountInteraction? = nil,
         continueAsGuest: (@MainActor () -> Void)? = nil,
         actionChanged: @escaping (Bool) -> Void = { _ in }) {
        self.session = session; self.continueAsGuest = continueAsGuest
        self.actionChanged = actionChanged
        self._interaction = StateObject(wrappedValue: suppliedInteraction ?? MobileAccountInteraction(session: session,
            requireTransitionAdmission: { try PrivateProfileService.shared.requireTransitionAdmission() }))
    }

    var body: some View {
        Group {
            if session.isAwaitingProtectedData {
                Text(PichiLocalization.text("account.legacy.protectedData", defaultValue: "Unlock this device to restore your account and protected recordings."))
                    .font(theme.typography.bodySmall).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.protectedDataUnavailable")
            } else if !privateProfile.isPrivateDataVisible {
                if privateProfile.isTransitioning {
                    ProgressView(PichiLocalization.text("account.state.updating", defaultValue: "Updating account"))
                        .accessibilityIdentifier("account.updating")
                } else {
                    Text(PichiLocalization.text("account.profile.unavailable", defaultValue: "Account data is temporarily hidden. Finish the current recording or operation, then retry sign-out."))
                        .font(theme.typography.bodySmall).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.profile.hidden")
                }
                Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out")) { requestLogout() }
                    .disabled(interaction.action != nil).accessibilityIdentifier("account.signOut")
            } else if session.state == .signedIn {
                if let account = session.account, let context = session.context,
                   account.stableIdentity == context.identity, session.generation == context.generation {
                    signedIn(account, context: context)
                } else {
                    ProgressView(PichiLocalization.text("account.state.updating", defaultValue: "Updating account"))
                        .accessibilityIdentifier("account.updating")
                }
            } else {
                signedOut
            }
            if let error = session.presentationError ?? interaction.error {
                Text(session.isLegacySession && error == .revocationUnavailable
                    ? PichiLocalization.text("account.legacy.revocationUnavailable", defaultValue: "Signed out on this device. The server could not confirm sign-out on all devices.")
                    : MobileAccountCopy.error(error)).font(theme.typography.bodySmall)
                    .foregroundStyle(theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.error")
            }
        }
        .onChange(of: interaction.action != nil) { _, active in actionChanged(active) }
        .onChange(of: interaction.presentationRevision) { _, _ in
            legacyFocus = nil; legacyEmail = ""; legacyPassword = ""
            confirmingLegacyLogout = false; legacyLogoutContext = nil
        }
        .onChange(of: privateProfile.projectionRevision) { _, _ in
            legacyFocus = nil; legacyEmail = ""; legacyPassword = ""; confirmingLegacyLogout = false; legacyLogoutContext = nil
            interaction.privateProjectionDidChange()
        }
        .onChange(of: privateProfile.isPrivateDataVisible) { _, visible in
            if !visible { legacyFocus = nil; legacyEmail = ""; legacyPassword = ""; confirmingLegacyLogout = false; legacyLogoutContext = nil }
            interaction.privateProjectionDidChange()
        }
        .onAppear { presentedProjectionRevision = privateProfile.projectionRevision }
        .onChange(of: session.generation) { _, _ in
            legacyFocus = nil; legacyEmail = ""; legacyPassword = ""; confirmingLegacyLogout = false; legacyLogoutContext = nil
        }
        .confirmationDialog(PichiLocalization.text("account.legacy.logoutTitle", defaultValue: "Sign out on all devices?"),
                            isPresented: $confirmingLegacyLogout, titleVisibility: .visible) {
            Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out"), role: .destructive) {
                guard let expected = legacyLogoutContext, session.context == expected,
                      session.generation == expected.generation else { return }
                legacyLogoutContext = nil; interaction.logout()
            }
        } message: {
            Text(PichiLocalization.text("account.legacy.logoutWarning", defaultValue: "Signing out ends your account sessions on every device, including the web app."))
        }
        .onDisappear {
            legacyFocus = nil; legacyEmail = ""; legacyPassword = ""
            // N2 can conceal/remove this presentation during the command's own
            // admission. That is not a user request to cancel authentication.
            interaction.cancelOwnedSignInOnDisappear(
                profileBoundaryChanged: presentedProjectionRevision != privateProfile.projectionRevision)
        }
    }

    private func requestLogout() {
        if session.isLegacySession, let context = session.context {
            legacyLogoutContext = context; confirmingLegacyLogout = true
        } else { interaction.logout() }
    }

    @ViewBuilder private var signedOut: some View {
        Text(PichiLocalization.text("account.guest.explanation", defaultValue: "Sign-in is optional. You can record and export without an account."))
            .font(theme.typography.bodySmall).fixedSize(horizontal: false, vertical: true)
        if session.state == .signingIn {
            ProgressView(PichiLocalization.text("account.state.signingIn", defaultValue: "Signing in"))
                .accessibilityIdentifier("account.signingIn")
            Button(PichiLocalization.text("account.action.cancelSignIn", defaultValue: "Cancel sign-in")) { interaction.cancelSignIn() }
                .disabled(interaction.action == .cancel || interaction.action == .guest)
                .accessibilityIdentifier("account.cancelSignIn")
        } else if session.isConfigured {
            if session.isLegacySession {
                if let destination = session.legacyConfiguration?.apiBaseURL.host {
                    Text(verbatim: destination).font(theme.typography.captionStrong)
                        .accessibilityIdentifier("account.legacy.destination")
                }
                TextField(PichiLocalization.text("account.legacy.email", defaultValue: "Email"), text: $legacyEmail,
                          prompt: Text(PichiLocalization.text("account.legacy.email", defaultValue: "Email"))
                            .foregroundStyle(theme.palette.secondaryText))
                    .textContentType(.username).keyboardType(.emailAddress)
                    .focused($legacyFocus, equals: .email)
                    .submitLabel(.next).onSubmit { legacyFocus = .password }
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .disabled(!interaction.canSignIn).accessibilityIdentifier("account.legacy.email")
                SecureField(PichiLocalization.text("account.legacy.password", defaultValue: "Password"), text: $legacyPassword,
                            prompt: Text(PichiLocalization.text("account.legacy.password", defaultValue: "Password"))
                                .foregroundStyle(theme.palette.secondaryText))
                    .textContentType(.password).focused($legacyFocus, equals: .password)
                    .submitLabel(.done).onSubmit { legacyFocus = nil }
                    .disabled(!interaction.canSignIn)
                    .accessibilityIdentifier("account.legacy.password")
                Text(PichiLocalization.text("account.legacy.sessionOnly", defaultValue: "Your password is used only to sign in. This device stores your session securely."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button(PichiLocalization.text(session.state == .reauthenticationRequired ? "account.action.reauthenticate" : "account.action.signIn",
                defaultValue: session.state == .reauthenticationRequired ? "Sign in again" : "Sign in")) {
                    if session.isLegacySession {
                        let email = legacyEmail.trimmingCharacters(in: .whitespacesAndNewlines), password = legacyPassword
                        legacyFocus = nil; legacyPassword = ""
                        interaction.signIn(email: email, password: password)
                    } else { interaction.signIn() }
                }
                .disabled(!interaction.canSignIn || (session.isLegacySession && (legacyEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || legacyPassword.isEmpty)))
                .accessibilityIdentifier("account.signIn")
            if !session.isSignInAvailable {
                Text(PichiLocalization.text("account.unavailable", defaultValue: "Sign-in is not available yet. You can continue using this device."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    .accessibilityIdentifier("account.unavailable")
            }
            if session.state == .reauthenticationRequired || (session.presentationError != nil && !session.isSignInAvailable) {
                Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out")) { requestLogout() }
                    .disabled(interaction.action != nil).accessibilityIdentifier("account.signOut")
            }
        }
        if let continueAsGuest {
            Button(PichiLocalization.text("account.action.guest", defaultValue: "Continue as guest")) { interaction.continueAsGuest(continueAsGuest) }
                .disabled(interaction.action != nil && interaction.action != .signIn && interaction.action != .switchPerson)
                .accessibilityIdentifier("account.continueAsGuest")
        }
    }

    @ViewBuilder private func signedIn(_ account: AccountSnapshot, context: AccountContext) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
            Text(account.account.displayName).font(theme.typography.bodyStrong)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("account.displayName")
            if let email = account.account.email, !email.isEmpty {
                Text(email).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.accessibilityElement(children: .combine)
        if session.isAwaitingLegacyServerValidation {
            Text(PichiLocalization.text("account.legacy.offline", defaultValue: "Offline. Your account will be checked again before anything is sent."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("account.legacy.offline")
        }
        Text(PichiLocalization.text("account.workspace.choose", defaultValue: "Choose a workspace"))
            .font(theme.typography.bodyStrong)
        if account.organizations.allSatisfy({ $0.workspaces.isEmpty }) {
            Text(PichiLocalization.text("account.workspace.empty", defaultValue: "No workspaces are available for this account. You can continue recording on this device."))
                .font(theme.typography.bodySmall).accessibilityIdentifier("account.workspaces.empty")
        }
        ForEach(account.organizations, id: \.id) { organization in
            VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
                Text(organization.name).font(theme.typography.captionStrong).foregroundStyle(theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if session.isLegacySession && account.activeOrganizationID != organization.id {
                    Button(PichiLocalization.text("account.legacy.chooseOrganization", defaultValue: "Choose this organization")) {
                        interaction.selectLegacyOrganization(organization.id)
                    }.disabled(interaction.action != nil || !session.isCurrent(context))
                        .accessibilityIdentifier("account.organization.\(organization.id)")
                }
                ForEach(organization.workspaces, id: \.id) { workspace in
                    let selected = context.organizationID == organization.id && context.workspaceID == workspace.id
                    Button { interaction.selectWorkspace(organizationID: organization.id, workspaceID: workspace.id) } label: {
                        HStack {
                            Text(workspace.name).font(theme.typography.body).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.palette.accent) }
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .disabled(interaction.action != nil || !session.isSignInAvailable || !session.isCurrent(context))
                        .accessibilityIdentifier("account.workspace.\(organization.id).\(workspace.id)")
                        .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        if interaction.action != nil {
            ProgressView(PichiLocalization.text("account.state.updating", defaultValue: "Updating account"))
                .accessibilityIdentifier("account.updating")
        }
        Button(PichiLocalization.text("account.action.switchPerson", defaultValue: "Switch account")) {
            interaction.switchPerson()
        }
            .disabled(interaction.action != nil || !session.isSignInAvailable)
            .accessibilityIdentifier("account.switchPerson")
        Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out"), role: .destructive) {
            requestLogout()
        }
            .disabled(interaction.action != nil).accessibilityIdentifier("account.signOut")
    }
}

/// A window retains only UI commands and sanitized errors. It registers with the
/// existing profile owner, and receives the same facade instance as every other view.
extension MobileCloudInteraction: PrivateProfileTransitionParticipant {
    convenience init(session: AccountSessionService, profiles: PrivateProfileService = .shared) {
        // Freeze the presenting view's owner. A delayed A control must never capture
        // B's current scope at click time, especially for facade-wide pause or OFF.
        let presentedProfile = PrivateProfileStorage.current
        let presentedRevision = profiles.projectionRevision
        let source: @MainActor () -> MobilePrivatePublicationContext? = {
            guard PrivateProfileStorage.current == presentedProfile,
                  profiles.projectionRevision == presentedRevision,
                  profiles.isPrivateDataVisible, !profiles.isTransitioning,
                  PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(presentedProfile),
                  let context = presentedProfile.context, !presentedProfile.isGuest,
                  session.context == context, session.generation == context.generation,
                  session.state == .signedIn else { return nil }
            return .init(profile: presentedProfile, projectionRevision: presentedRevision)
        }
        let jobs = MobilePrivatePublicationTasks(capture: {
            let profile = PrivateProfileStorage.current
            guard profile == presentedProfile, profiles.projectionRevision == presentedRevision,
                  profiles.isPrivateDataVisible, !profiles.isTransitioning,
                  PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile),
                  let context = profile.context, session.isCurrent(context), !profile.isGuest else { return nil }
            return .init(profile: profile, projectionRevision: profiles.projectionRevision)
        }, validate: { token in
            token.profile == presentedProfile && token.projectionRevision == presentedRevision
                && profiles.isPrivateDataVisible && !profiles.isTransitioning
                && profiles.projectionRevision == token.projectionRevision
                && PrivateProfileStorage.acceptsNewWork && PrivateProfileStorage.isReadable(token.profile)
                && PrivateProfileStorage.current == token.profile
                && token.profile.context.map { session.isCurrent($0) } == true
        })
        self.init(publications: jobs, statusSource: source)
        profiles.register(self)
        profiles.$projectionRevision.dropFirst().sink { [weak self] _ in self?.invalidate() }.store(in: &observers)
        profiles.$isPrivateDataVisible.dropFirst().sink { [weak self] visible in
            if !visible { self?.invalidate() }
        }.store(in: &observers)
    }

    func prepareForPrivateProfileTransition() async throws {
        invalidate()
        await waitUntilFinished()
    }
}

/// All text is shared catalog copy. Server prose and opaque receipt IDs never reach UI.
nonisolated enum MobileCloudCopy {
    static func text(_ suffix: String) -> String { PichiLocalization.text("cloud." + suffix) }
    static func availability(_ value: PichiCloudPublicationAvailability) -> String {
        text("availability." + value.rawValue)
    }
    static func pause(_ value: PichiPublicationPauseReason) -> String { text("pause." + value.rawValue) }
    static func lines(_ value: PichiCloudPublicationStatus) -> [String] {
        switch value {
        case .localOnly: return [text("status.localOnly")]
        case .waitingForSource: return [text("status.waitingForSource")]
        case .withheld(let reason): return [text("status.withheld"), text("withheld." + reason.rawValue)]
        case .queued: return [text("status.queued")]
        case .sending: return [text("status.sending")]
        case .retryScheduled(let date):
            return [PichiLocalization.format("cloud.status.retryScheduled",
                date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(PichiLocalization.locale)))]
        case .paused(let reason): return [pause(reason)]
        case .accepted(let receipt): return [text("status.accepted"), text("analysis." + receipt.analysisState.rawValue)]
        case .acceptedNeedsReview(let receipt, let reason):
            return [text("status.accepted"), text("analysis." + receipt.analysisState.rawValue), pause(reason)]
        case .conflict: return [text("pause.sourceConflict")]
        }
    }
    static func canUseNetwork(_ value: PichiCloudPublicationSnapshot) -> Bool {
        value.cloudSyncEnabled && (value.availability == .ready || value.availability == .paused)
    }
}

struct MobileCloudSyncSettings: View {
    @ObservedObject var service: PichiCloudPublicationService
    @ObservedObject var session: AccountSessionService
    @ObservedObject private var profiles = PrivateProfileService.shared
    @StateObject private var interaction: MobileCloudInteraction
    @Environment(\.theme) private var theme

    init(service: PichiCloudPublicationService, session: AccountSessionService,
         interaction supplied: MobileCloudInteraction? = nil) {
        self.service = service; self.session = session
        self._interaction = StateObject(wrappedValue: supplied ?? MobileCloudInteraction(session: session))
    }

    var body: some View {
        if interaction.publications.admit() != nil {
            VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
                if service.isLegacySession, let host = service.legacyDestinationURL?.host {
                    LabeledContent(MobileCloudCopy.text("automatic.destination")) {
                        Text(verbatim: host).font(theme.typography.captionStrong)
                    }.accessibilityIdentifier("cloud.automatic.destination")
                }
                Toggle(MobileCloudCopy.text(service.isLegacySession ? "automatic.title" : "title"), isOn: Binding(
                    get: { service.snapshot.cloudSyncEnabled },
                    set: { enabled in command(.toggle(enabled)) { try await service.setCloudSyncEnabled(enabled) } }))
                    .disabled(isBusy || unavailable)
                    .accessibilityIdentifier("cloud.sync.toggle")
                Text(MobileCloudCopy.text(service.isLegacySession ? "automatic.consent" : "consent"))
                    .font(theme.typography.bodySmall).fixedSize(horizontal: false, vertical: true)
                if service.isLegacySession {
                    Toggle(MobileCloudCopy.text("automatic.deleteLocal"), isOn: Binding(
                        get: { service.snapshot.deleteLocalAfterAcceptance },
                        set: { enabled in command(.retention(enabled)) { try await service.setDeleteLocalAfterAcceptance(enabled) } }))
                        .disabled(isBusy || unavailable || !service.snapshot.cloudSyncEnabled)
                        .accessibilityIdentifier("cloud.automatic.deleteLocal")
                    Text(MobileCloudCopy.text("automatic.retention"))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(MobileCloudCopy.text("automatic.runtime"))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(MobileCloudCopy.text("history"))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MobileCloudCopy.availability(service.snapshot.availability))
                    .font(theme.typography.bodySmall).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud.sync.availability")
                if isBusy {
                    ProgressView().accessibilityIdentifier("cloud.sync.progress")
                } else if service.snapshot.availability == .storageUnavailable {
                    Button(MobileCloudCopy.text("action.recover")) {
                        let enabled = service.snapshot.cloudSyncEnabled
                        command(.toggle(enabled)) { try await service.setCloudSyncEnabled(enabled) }
                    }.accessibilityIdentifier("cloud.sync.recover")
                    Text(MobileCloudCopy.text("storageRecovery"))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                } else if service.snapshot.cloudSyncEnabled && service.snapshot.availability == .paused {
                    Button(MobileCloudCopy.text("action.resume")) { command(.resume) { try await service.resume() } }
                        .accessibilityIdentifier("cloud.sync.resume")
                } else if service.snapshot.cloudSyncEnabled && service.snapshot.availability == .ready {
                    Button(MobileCloudCopy.text("action.pause")) { command(.pause) { await service.pause() } }
                        .accessibilityIdentifier("cloud.sync.pause")
                }
                if interaction.failed { cloudFailure }
            }
            .foregroundStyle(theme.palette.primaryText)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("cloud.sync.settings")
        }
    }

    private var isBusy: Bool { interaction.action != nil || service.snapshot.availability == .pausing }
    private var unavailable: Bool {
        guard let context = session.context, context.organizationID != nil, context.workspaceID != nil else { return true }
        switch service.snapshot.availability {
        case .unconfigured, .signedOut, .profileUnavailable, .protectedDataUnavailable: return true
        default: return false
        }
    }
    private var cloudFailure: some View {
        Text(MobileCloudCopy.text("commandFailed")).font(theme.typography.bodySmall)
            .foregroundStyle(theme.palette.warning).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("cloud.sync.error")
    }
    private func command(_ action: MobileCloudInteraction.Action, operation: @escaping @MainActor () async throws -> Void) {
        interaction.run(action) { _ in try await operation() }
    }
}

/// A view can outlive its visible pixels during cleanup. Keep its loaded receipt
/// projection in the existing synchronous profile boundary so concealment erases
/// it immediately; the window's publication jobs separately join the caller.
@MainActor private final class MobileCloudRecordingProjection: ObservableObject, PrivateProfileTransitionParticipant {
    @Published var loaded: (context: MobilePrivatePublicationContext, status: PichiCloudPublicationStatus)?
    @Published var loadFailed = false
    @Published var assessmentTarget: MobileCloudAssessmentTarget?
    @Published var legacyTarget: MobileLegacySendTarget?
    private var observers = Set<AnyCancellable>()

    init(profiles: PrivateProfileService = .shared) {
        profiles.register(self)
        profiles.$projectionRevision.dropFirst().sink { [weak self] _ in self?.clear() }.store(in: &observers)
        profiles.$isPrivateDataVisible.dropFirst().sink { [weak self] visible in
            if !visible { self?.clear() }
        }.store(in: &observers)
    }

    private func clear() { loaded = nil; loadFailed = false; assessmentTarget = nil; legacyTarget = nil }
    func prepareForPrivateProfileTransition() async throws { clear() }
}

/// A visible known recording can load its own status once. Analysis polling belongs
/// exclusively to the facade; cache absence never means that an upload is local-only.
struct MobileCloudRecordingStatus: View {
    @ObservedObject var service: PichiCloudPublicationService
    @ObservedObject var interaction: MobileCloudInteraction
    let recordingID: MeetingSessionID
    var showsActions = false
    @Environment(\.theme) private var theme
    @StateObject private var projection = MobileCloudRecordingProjection()
    @State private var statusPresentationID = UUID()

    var body: some View {
        Group {
            if let admission = interaction.publications.admit() {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
                    if let status = service.snapshot.items[recordingID] ?? currentLoaded(admission.context) {
                        let lines = MobileCloudCopy.lines(status)
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line).font(index == 0 ? theme.typography.captionStrong : theme.typography.caption)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if showsActions { actions(status) }
                    } else {
                        Text(MobileCloudCopy.text(projection.loadFailed ? "status.unavailable" : "status.loading"))
                            .font(theme.typography.caption).fixedSize(horizontal: false, vertical: true)
                        if showsActions && projection.loadFailed && canLoad {
                            Button(MobileCloudCopy.text("action.refresh")) { _ = loadStatus() }
                                .disabled(interaction.action != nil)
                        }
                    }
                    if showsActions && interaction.failed {
                        Text(MobileCloudCopy.text("commandFailed")).font(theme.typography.caption)
                            .foregroundStyle(theme.palette.warning)
                    }
                }.foregroundStyle(theme.palette.secondaryText)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("cloud.recording.\(recordingID)")
            }
        }
        .task(id: canLoad) {
            guard canLoad else {
                interaction.cancelStatusRead(presentationID: statusPresentationID)
                return
            }
            let pending = loadStatus()
            await withTaskCancellationHandler { await pending?.value } onCancel: { pending?.cancel() }
        }
        .onDisappear { interaction.cancelStatusRead(presentationID: statusPresentationID) }
        .sheet(item: $projection.assessmentTarget) { target in
            MobileCloudAssessmentSheet(target: target, service: service, interaction: interaction)
        }
        .sheet(item: $projection.legacyTarget) { target in
            MobileLegacySendSheet(target: target, service: service, interaction: interaction)
        }
    }

    private var canLoad: Bool {
        switch service.snapshot.availability {
        case .unconfigured, .signedOut, .profileUnavailable, .pausing, .protectedDataUnavailable: return false
        default: return true
        }
    }
    private func currentLoaded(_ context: MobilePrivatePublicationContext) -> PichiCloudPublicationStatus? {
        projection.loaded?.context == context ? projection.loaded?.status : nil
    }
    @discardableResult private func loadStatus() -> Task<Void, Never>? {
        interaction.cancelStatusRead(presentationID: statusPresentationID)
        statusPresentationID = UUID()
        guard canLoad else { return nil }
        projection.loadFailed = false
        return interaction.readStatus(presentationID: statusPresentationID, report: { _ in projection.loadFailed = true }) { admission in
            let status = try await service.status(for: recordingID)
            guard interaction.publications.canPublish(admission) else { return false }
            projection.loaded = (admission.context, status)
            return true
        }
    }
    @ViewBuilder private func actions(_ status: PichiCloudPublicationStatus) -> some View {
        if MobileCloudCopy.canUseNetwork(service.snapshot) {
            switch status {
            case .queued:
                if service.isLegacySession && !service.snapshot.automaticRecordingIDs.contains(recordingID) {
                    Button(MobileCloudCopy.text("action.send")) {
                        guard interaction.publications.admit() != nil else { return }
                        projection.legacyTarget = .init(recordingID: recordingID)
                    }.disabled(interaction.action != nil)
                        .accessibilityIdentifier("cloud.legacy.open.\(recordingID)")
                } else {
                    cloudButton("action.send", action: .send(recordingID)) { try await service.send(recordingID) }
                }
            case .retryScheduled(let date):
                cloudButton("action.retry", action: .retry(recordingID)) { try await service.retry(recordingID) }
                    .disabled(date > Date())
            case .paused(let reason):
                switch reason {
                case .userRequested, .profileTransition, .uncertainDelivery, .retryBudgetExhausted, .transportUnavailable:
                    cloudButton("action.retry", action: .retry(recordingID)) { try await service.retry(recordingID) }
                default: EmptyView()
                }
            case .accepted(let receipt), .acceptedNeedsReview(let receipt, _):
                cloudButton("action.refresh", action: .reconcile(recordingID)) { try await service.reconcile(recordingID) }
                if receipt.analysisState == .needsParticipant || receipt.analysisState == .needsCriteria {
                    Button(MobileCloudCopy.text("assessment.title")) {
                        guard interaction.publications.admit() != nil else { return }
                        projection.assessmentTarget = .init(recordingID: recordingID, receipt: receipt)
                    }.disabled(interaction.action != nil)
                        .accessibilityIdentifier("cloud.assessment.open.\(recordingID)")
                }
            default: EmptyView()
            }
        }
    }
    private func cloudButton(_ key: String, action: MobileCloudInteraction.Action,
                             operation: @escaping @MainActor () async throws -> Void) -> some View {
        Button(MobileCloudCopy.text(key)) { interaction.run(action) { _ in try await operation() } }
            .disabled(interaction.action != nil)
            .accessibilityIdentifier("cloud.recording.action.\(recordingID)")
    }
}

private struct MobileLegacySendTarget: Identifiable {
    let id = UUID()
    let recordingID: MeetingSessionID
}

/// A private, transient selection draft. Delivery and frozen bytes remain in the shared outbox.
@MainActor private final class MobileLegacySendState: ObservableObject, PrivateProfileTransitionParticipant {
    @Published private(set) var options: LegacyPublicationOptions?
    @Published var employeeID = ""
    @Published var participantID: UUID?
    @Published var criteriaIDs = Set<String>()
    @Published private(set) var working = false
    @Published private(set) var failed = false
    @Published private(set) var completed = false
    @Published var confirming = false
    private let target: MobileLegacySendTarget
    private let service: PichiCloudPublicationService
    private let interaction: MobileCloudInteraction
    private let admission: MobilePrivatePublicationTasks.Admission?
    private var task: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var closed = false
    private var observers = Set<AnyCancellable>()

    init(target: MobileLegacySendTarget, service: PichiCloudPublicationService,
         interaction: MobileCloudInteraction, profiles: PrivateProfileService = .shared) {
        self.target = target; self.service = service; self.interaction = interaction
        self.admission = interaction.publications.admit()
        profiles.register(self)
        profiles.$projectionRevision.dropFirst().sink { [weak self] _ in self?.close() }.store(in: &observers)
        profiles.$isPrivateDataVisible.dropFirst().sink { [weak self] visible in
            if !visible { self?.close() }
        }.store(in: &observers)
    }
    private var isCurrent: Bool {
        !closed && admission.map { interaction.publications.canPublish($0) } == true
    }
    var destinationAccountID: String? { isCurrent ? admission?.context.profile.context?.identity.internalUserID : nil }
    var destinationWorkspaceID: String? { isCurrent ? admission?.context.profile.context?.workspaceID : nil }
    var canSubmit: Bool {
        guard isCurrent, !working, MobileCloudCopy.canUseNetwork(service.snapshot),
              let options, options.employees.contains(where: { $0.id == employeeID }),
              let participantID, options.participants.contains(where: { $0.id == participantID }) else { return false }
        return !criteriaIDs.isEmpty && criteriaIDs.count <= MobileCloudAssessmentSelection.maximumCriteria
            && criteriaIDs.isSubset(of: Set(options.criteria.map(\.id)))
    }
    func load() {
        guard isCurrent, !working else { return }
        options = nil; employeeID = ""; participantID = nil; criteriaIDs = []; confirming = false
        run(.options(target.recordingID)) { current in
            let page = try await self.service.legacyAssessmentOptions(for: self.target.recordingID)
            guard self.accepts(current) else { return }
            self.options = page
        }
    }
    func toggleCriterion(_ id: String) {
        guard isCurrent, !working, options?.criteria.contains(where: { $0.id == id }) == true else { return }
        if criteriaIDs.contains(id) { criteriaIDs.remove(id) }
        else if criteriaIDs.count < MobileCloudAssessmentSelection.maximumCriteria { criteriaIDs.insert(id) }
    }
    func submit() {
        confirming = false
        guard canSubmit, let participantID else { return }
        let employee = employeeID, criteria = criteriaIDs.sorted()
        run(.send(target.recordingID)) { current in
            try await self.service.sendLegacy(self.target.recordingID, userID: employee,
                participantID: participantID, criteriaIDs: criteria)
            guard self.accepts(current) else { return }
            self.options = nil; self.employeeID = ""; self.participantID = nil; self.criteriaIDs = []
            self.completed = true
        }
    }
    private func accepts(_ current: MobilePrivatePublicationTasks.Admission) -> Bool {
        isCurrent && admission?.context == current.context && interaction.publications.canPublish(current)
    }
    private func run(_ action: MobileCloudInteraction.Action,
                     operation: @escaping @MainActor (MobilePrivatePublicationTasks.Admission) async throws -> Void) {
        guard isCurrent, !working else { return }
        working = true; failed = false
        task = interaction.run(action) { current in
            defer { self.working = false; self.task = nil }
            guard self.accepts(current) else { return }
            do { try await operation(current) }
            catch {
                guard self.accepts(current) else { return }
                self.options = nil; self.employeeID = ""; self.participantID = nil; self.criteriaIDs = []
                self.failed = true
            }
        }
        if task == nil { working = false; failed = true }
    }
    func close() {
        closed = true; options = nil; employeeID = ""; participantID = nil; criteriaIDs = []
        confirming = false; failed = false
        let pending = task; pending?.cancel()
        guard retirement == nil else { return }
        retirement = Task { @MainActor in
            await pending?.value
            self.working = false; self.task = nil; self.retirement = nil
        }
    }
    func prepareForPrivateProfileTransition() async throws { close(); await retirement?.value }
}

private struct MobileLegacySendSheet: View {
    @ObservedObject var service: PichiCloudPublicationService
    @ObservedObject var interaction: MobileCloudInteraction
    @StateObject private var state: MobileLegacySendState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    init(target: MobileLegacySendTarget, service: PichiCloudPublicationService, interaction: MobileCloudInteraction) {
        self.service = service; self.interaction = interaction
        self._state = StateObject(wrappedValue: MobileLegacySendState(target: target, service: service, interaction: interaction))
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(MobileCloudCopy.text("legacy.destination")) {
                    if let destination = service.legacyDestinationURL?.host {
                        Text(verbatim: destination).font(theme.typography.bodyStrong)
                    }
                    if let account = state.destinationAccountID {
                        LabeledContent(MobileCloudCopy.text("legacy.accountID")) { Text(verbatim: account) }
                    }
                    if let workspace = state.destinationWorkspaceID {
                        LabeledContent(MobileCloudCopy.text("legacy.workspaceID")) { Text(verbatim: workspace) }
                    }
                    if let title = state.options?.title { Text(verbatim: title).font(theme.typography.bodyStrong) }
                    Text(MobileCloudCopy.text("legacy.protectedOnly"))
                        .font(theme.typography.bodySmall).fixedSize(horizontal: false, vertical: true)
                }
                if state.working { ProgressView(MobileCloudCopy.text("assessment.loading")) }
                if state.failed {
                    Text(MobileCloudCopy.text("commandFailed")).foregroundStyle(theme.palette.warning)
                    Button(PichiLocalization.text("Try again")) { state.load() }.disabled(state.working)
                }
                if let options = state.options {
                    Section(MobileCloudCopy.text("legacy.employee")) {
                        ForEach(options.employees, id: \.id) { employee in
                            choice(employee.name, selected: state.employeeID == employee.id) { state.employeeID = employee.id }
                                .accessibilityIdentifier("cloud.legacy.employee.\(employee.id)")
                        }
                    }
                    Section(MobileCloudCopy.text("assessment.participant")) {
                        ForEach(options.participants, id: \.id) { participant in
                            choice(participant.displayName, selected: state.participantID == participant.id) { state.participantID = participant.id }
                                .accessibilityIdentifier("cloud.legacy.participant.\(participant.id)")
                        }
                    }
                    Section(MobileCloudCopy.text("assessment.criteria")) {
                        ForEach(options.criteria, id: \.id) { criterion in
                            choice(criterion.name, selected: state.criteriaIDs.contains(criterion.id)) { state.toggleCriterion(criterion.id) }
                                .accessibilityIdentifier("cloud.legacy.criterion.\(criterion.id)")
                        }
                    }
                }
                Button(MobileCloudCopy.text("action.send")) { state.confirming = true }
                    .disabled(!state.canSubmit || interaction.action != nil)
                    .accessibilityIdentifier("cloud.legacy.send")
            }.font(theme.typography.body).foregroundStyle(theme.palette.primaryText)
                .navigationTitle(MobileCloudCopy.text("legacy.title"))
                .toolbar { ToolbarItem(placement: .cancellationAction) {
                    Button(PichiLocalization.text("Cancel")) { state.close(); dismiss() }
                } }
                .confirmationDialog(MobileCloudCopy.text("legacy.confirm"), isPresented: $state.confirming, titleVisibility: .visible) {
                    Button(MobileCloudCopy.text("action.send")) { state.submit() }
                        .disabled(!state.canSubmit)
                } message: {
                    Text(verbatim: [service.legacyDestinationURL?.absoluteString, state.destinationAccountID,
                        state.destinationWorkspaceID, state.options?.title].compactMap { $0 }.joined(separator: "\n"))
                }
        }
        .task { state.load() }
        .onChange(of: state.completed) { _, done in if done { dismiss() } }
        .onDisappear { state.close() }
    }
    private func choice(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(verbatim: name).fixedSize(horizontal: false, vertical: true)
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.palette.accent) }
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(state.working)
    }
}

private struct MobileCloudAssessmentTarget: Identifiable {
    let id = UUID()
    let recordingID: MeetingSessionID
    let receipt: PichiPublicationReceipt
}

/// Owns one sheet's private page and explicit draft. It uses the window's existing
/// command admission, retains only its own task for dismissal, and never owns delivery.
@MainActor private final class MobileCloudAssessmentState: ObservableObject, PrivateProfileTransitionParticipant {
    @Published private(set) var page: PichiPublicationAssessmentOptions?
    @Published private(set) var selection = MobileCloudAssessmentSelection()
    @Published private(set) var working = false
    @Published private(set) var failed = false
    @Published var confirming = false
    @Published private(set) var completed = false
    private var confirmation: (participantID: UUID, criteriaIDs: [String])?
    private var target: MobileCloudAssessmentTarget?
    private let service: PichiCloudPublicationService
    private let interaction: MobileCloudInteraction
    private let presentationAdmission: MobilePrivatePublicationTasks.Admission?
    private var task: Task<Void, Never>?
    private var retirement: Task<Void, Never>?
    private var closed = false
    private var observers = Set<AnyCancellable>()

    init(target: MobileCloudAssessmentTarget, service: PichiCloudPublicationService,
         interaction: MobileCloudInteraction, profiles: PrivateProfileService = .shared) {
        self.target = target; self.service = service; self.interaction = interaction
        self.presentationAdmission = interaction.publications.admit()
        profiles.register(self)
        profiles.$projectionRevision.dropFirst().sink { [weak self] _ in self?.close() }.store(in: &observers)
        profiles.$isPrivateDataVisible.dropFirst().sink { [weak self] visible in
            if !visible { self?.close() }
        }.store(in: &observers)
    }

    private var isCurrent: Bool {
        !closed && presentationAdmission.map { interaction.publications.canPublish($0) } == true
    }
    var canSubmit: Bool { !working && selectionIsAuthorized }
    private var selectionIsAuthorized: Bool {
        guard isCurrent, let page, let target,
              MobileCloudCopy.canUseNetwork(service.snapshot) else { return false }
        let pending: Bool
        if let status = service.snapshot.items[target.recordingID] {
            if case .accepted(let receipt) = status {
                pending = receipt.importID == target.receipt.importID && receipt.recordingID == target.receipt.recordingID
                    && Self.isPending(receipt)
            } else { pending = false }
        } else { pending = Self.isPending(page.receipt) }
        return selection.canSubmit(canResolvePending: page.canResolvePending, receiptPending: pending,
            offeredParticipants: Set(page.participants.map(\.id)))
    }
    private static func isPending(_ receipt: PichiPublicationReceipt) -> Bool {
        receipt.analysisState == .needsParticipant || receipt.analysisState == .needsCriteria
    }

    func loadFirst() { selection.clear(); load(cursor: nil) }
    func loadNext() {
        guard let page, page.criteria.pagination.hasMore, let cursor = page.criteria.pagination.nextCursor else { return }
        load(cursor: cursor)
    }
    private func load(cursor: String?) {
        guard !working, let target else { return }
        page = nil; confirming = false; confirmation = nil
        start(.options(target.recordingID)) { admission in
            let result = try await self.service.assessmentOptions(for: target.recordingID, cursor: cursor, limit: 50)
            guard self.accepts(admission) else { return }
            guard let context = admission.context.profile.context,
                  result.context.accountID == context.identity.internalUserID,
                  result.context.organizationID == context.organizationID, result.context.workspaceID == context.workspaceID,
                  result.receipt.importID == target.receipt.importID, result.receipt.recordingID == target.receipt.recordingID else {
                throw AccountError.staleOperation
            }
            self.page = result
        }
    }
    func chooseParticipant(_ id: UUID) {
        guard isCurrent, !working, let page, page.canResolvePending else { return }
        _ = selection.selectParticipant(id, offered: Set(page.participants.map(\.id)))
    }
    func chooseCriterion(_ id: String) {
        guard isCurrent, !working, let page, page.canResolvePending,
              let item = page.criteria.data.first(where: { $0.id == id }) else { return }
        _ = selection.toggleCriterion(id, name: item.name, offered: Set(page.criteria.data.map(\.id)))
    }
    func removeCriterion(_ id: String) { if isCurrent && !working { selection.removeCriterion(id) } }
    func requestConfirmation() {
        guard canSubmit, let participant = selection.participantID else { return }
        confirmation = (participant, selection.criteria.keys.sorted()); confirming = true
    }
    func cancelConfirmation() { confirming = false; confirmation = nil }
    func submitConfirmed() {
        guard canSubmit, let confirmed = confirmation, let target,
              confirmed.participantID == selection.participantID,
              confirmed.criteriaIDs == selection.criteria.keys.sorted() else { cancelConfirmation(); return }
        cancelConfirmation()
        start(.assessment(target.recordingID)) { admission in
            guard self.selectionIsAuthorized, confirmed.participantID == self.selection.participantID,
                  confirmed.criteriaIDs == self.selection.criteria.keys.sorted() else { return }
            try await self.service.resolveAssessment(target.recordingID,
                participantID: confirmed.participantID, criteriaIDs: confirmed.criteriaIDs)
            guard self.accepts(admission) else { return }
            self.page = nil; self.selection.clear(); self.completed = true
        }
    }
    private func accepts(_ admission: MobilePrivatePublicationTasks.Admission) -> Bool {
        isCurrent && presentationAdmission?.context == admission.context && interaction.publications.canPublish(admission)
    }
    private func start(_ action: MobileCloudInteraction.Action,
                       operation: @escaping @MainActor (MobilePrivatePublicationTasks.Admission) async throws -> Void) {
        guard isCurrent, !working, MobileCloudCopy.canUseNetwork(service.snapshot) else { return }
        working = true; failed = false
        task = interaction.run(action) { admission in
            defer { self.working = false; self.task = nil }
            guard self.accepts(admission) else { return }
            do { try await operation(admission) }
            catch {
                guard self.accepts(admission) else { return }
                // A failed authorization/options request cannot leave usable old choices.
                self.page = nil; self.selection.clear(); self.cancelConfirmation(); self.failed = true
            }
        }
        if task == nil { working = false; failed = true }
    }
    func close() {
        closed = true; target = nil; page = nil; selection.clear(); cancelConfirmation(); failed = false
        let pending = task
        pending?.cancel()
        guard retirement == nil else { return }
        retirement = Task { @MainActor in
            await pending?.value
            self.working = false; self.task = nil; self.retirement = nil
        }
    }
    func prepareForPrivateProfileTransition() async throws { close(); await retirement?.value }
}

private struct MobileCloudAssessmentSheet: View {
    @ObservedObject var service: PichiCloudPublicationService
    @ObservedObject var interaction: MobileCloudInteraction
    @StateObject private var state: MobileCloudAssessmentState
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    init(target: MobileCloudAssessmentTarget, service: PichiCloudPublicationService, interaction: MobileCloudInteraction) {
        self.service = service; self.interaction = interaction
        self._state = StateObject(wrappedValue: MobileCloudAssessmentState(target: target, service: service, interaction: interaction))
    }
    var body: some View {
        NavigationStack {
            Form {
                if state.working { ProgressView(MobileCloudCopy.text("assessment.loading")) }
                if state.failed {
                    Text(MobileCloudCopy.text("assessment.unavailable")).foregroundStyle(theme.palette.warning)
                    Button(PichiLocalization.text("Try again")) { state.loadFirst() }
                        .disabled(state.working || interaction.action != nil || !MobileCloudCopy.canUseNetwork(service.snapshot))
                }
                if let page = state.page {
                    Section(MobileCloudCopy.text("assessment.current")) {
                        Text(PichiLocalization.format("cloud.assessment.currentCriteria", Int64(page.currentAssessment.criteriaIDs.count)))
                            .font(theme.typography.caption)
                        if let id = page.currentAssessment.participantID,
                           let participant = page.participants.first(where: { $0.id == id }) {
                            Text(verbatim: participant.displayName).font(theme.typography.body)
                        }
                        Text(MobileCloudCopy.text("assessment.explicitChoices")).font(theme.typography.caption)
                    }
                    if !page.canResolvePending { Text(MobileCloudCopy.text("assessment.notPending")) }
                    Section(MobileCloudCopy.text("assessment.participant")) {
                        if page.participants.isEmpty { Text(MobileCloudCopy.text("assessment.noParticipants")) }
                        ForEach(page.participants, id: \.id) { participant in
                            Button { state.chooseParticipant(participant.id) } label: {
                                HStack {
                                    Text(verbatim: participant.displayName)
                                    Spacer()
                                    if state.selection.participantID == participant.id { Image(systemName: "checkmark.circle.fill") }
                                }.contentShape(Rectangle()).frame(minHeight: 44)
                            }.buttonStyle(.plain).disabled(state.working || !page.canResolvePending)
                                .accessibilityIdentifier("cloud.assessment.participant.\(participant.id)")
                        }
                    }
                    Section(MobileCloudCopy.text("assessment.criteria")) {
                        if page.criteria.data.isEmpty { Text(MobileCloudCopy.text("assessment.noCriteria")) }
                        ForEach(page.criteria.data, id: \.id) { criterion in
                            Button { state.chooseCriterion(criterion.id) } label: {
                                HStack {
                                    Text(verbatim: criterion.name)
                                    Spacer()
                                    if state.selection.criteria[criterion.id] != nil { Image(systemName: "checkmark.circle.fill") }
                                }.contentShape(Rectangle()).frame(minHeight: 44)
                            }.buttonStyle(.plain).disabled(state.working || !page.canResolvePending
                                || (state.selection.criteria.count >= MobileCloudAssessmentSelection.maximumCriteria
                                    && state.selection.criteria[criterion.id] == nil))
                                .accessibilityIdentifier("cloud.assessment.criterion.\(criterion.id)")
                        }
                        if page.criteria.pagination.hasMore {
                            Button(MobileCloudCopy.text("assessment.loadMore")) { state.loadNext() }
                                .disabled(state.working || interaction.action != nil)
                                .accessibilityIdentifier("cloud.assessment.loadMore")
                        }
                    }
                }
                if !state.selection.criteria.isEmpty {
                    Section(MobileCloudCopy.text("assessment.selected")) {
                        ForEach(state.selection.criteria.keys.sorted(), id: \.self) { id in
                            HStack {
                                Text(verbatim: state.selection.criteria[id] ?? "")
                                Spacer()
                                Button(MobileCloudCopy.text("assessment.remove")) { state.removeCriterion(id) }
                                    .disabled(state.working)
                            }
                        }
                        Text(MobileCloudCopy.text("assessment.selectionLimit")).font(theme.typography.caption)
                    }
                }
                Button(MobileCloudCopy.text("assessment.confirm")) { state.requestConfirmation() }
                    .disabled(!state.canSubmit || interaction.action != nil)
                    .accessibilityIdentifier("cloud.assessment.confirm")
            }
            .font(theme.typography.body).foregroundStyle(theme.palette.primaryText)
            .navigationTitle(MobileCloudCopy.text("assessment.title"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(PichiLocalization.text("Cancel")) { state.close(); dismiss() }
                }
            }
            .confirmationDialog(MobileCloudCopy.text("assessment.confirmTitle"), isPresented: $state.confirming,
                                titleVisibility: .visible) {
                Button(MobileCloudCopy.text("assessment.submit")) { state.submitConfirmed() }
                Button(PichiLocalization.text("Cancel"), role: .cancel) { state.cancelConfirmation() }
            } message: {
                if let page = state.page, let id = state.selection.participantID,
                   let participant = page.participants.first(where: { $0.id == id }) {
                    Text(PichiLocalization.format("cloud.assessment.confirmSummary", participant.displayName,
                        Int64(state.selection.criteria.count)))
                }
            }
        }
        .task { state.loadFirst() }
        .onChange(of: state.completed) { _, completed in if completed { dismiss() } }
        .onDisappear { state.close() }
        .presentationDetents([.large])
        .accessibilityIdentifier("cloud.assessment.sheet")
    }
}
#endif
