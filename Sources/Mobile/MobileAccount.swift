import Combine
import Foundation

/// Transient UI commands only. The shared service owns authentication, credentials,
/// profile transitions and cancellation. One action lock also covers workspace selection,
/// whose service contract deliberately has no separate published busy state.
@MainActor
final class MobileAccountInteraction: ObservableObject {
    enum Action { case signIn, switchPerson, workspace, logout, cancel, guest }
    @Published private(set) var action: Action?
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

    func logout() {
        guard action == nil else { return }
        begin(.logout) { await self.session.logout() }
    }

    func cancelSignIn() {
        guard action == .signIn || action == .switchPerson else { return }
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
            await self.session.logout()
            await previous?.value
            guard self.session.context == nil,
                  self.session.presentationError == nil || self.session.presentationError == .revocationUnavailable,
                  self.session.state == .signedOut || self.session.state == .unconfigured else { return }
            completion()
        }
    }

    func cancelOwnedSignInOnDisappear() { cancelSignIn() }

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
        }
        return PichiLocalization.text("account.error.\(error.rawValue)", language: language, bundle: bundle, defaultValue: fallback)
    }
}

#if os(iOS)
import SwiftUI

struct MobileAccountSettings: View {
    @ObservedObject var session: AccountSessionService
    var body: some View {
        Form { MobileAccountPanel(session: session) }
            .navigationTitle(PichiLocalization.text("account.title", defaultValue: "Account"))
            .accessibilityIdentifier("account.settings")
    }
}

/// Reused on the Ready page without inserting or renumbering persisted setup steps.
struct MobileAccountOnboarding: View {
    @ObservedObject var session: AccountSessionService
    let continueAsGuest: @MainActor () -> Void
    let actionChanged: (Bool) -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.md) {
            Text(PichiLocalization.text("account.onboarding.title", defaultValue: "Optional account"))
                .font(theme.typography.sectionTitle)
            MobileAccountPanel(session: session, continueAsGuest: continueAsGuest, actionChanged: actionChanged)
        }.padding(16)
            .background(theme.palette.secondaryText.opacity(0.06), in: RoundedRectangle(cornerRadius: theme.metrics.corners.md))
            .accessibilityIdentifier("onboarding.account")
    }
}

/// No cloud controls are present until the shared N5 delivery API is released.
private struct MobileAccountPanel: View {
    @ObservedObject var session: AccountSessionService
    @ObservedObject private var privateProfile = PrivateProfileService.shared
    var continueAsGuest: (@MainActor () -> Void)?
    var actionChanged: (Bool) -> Void
    @StateObject private var interaction: MobileAccountInteraction
    @Environment(\.theme) private var theme

    init(session: AccountSessionService, continueAsGuest: (@MainActor () -> Void)? = nil,
         actionChanged: @escaping (Bool) -> Void = { _ in }) {
        self.session = session; self.continueAsGuest = continueAsGuest
        self.actionChanged = actionChanged
        self._interaction = StateObject(wrappedValue: MobileAccountInteraction(session: session,
            requireTransitionAdmission: { try PrivateProfileService.shared.requireTransitionAdmission() }))
    }

    var body: some View {
        Group {
            if !privateProfile.isPrivateDataVisible {
                if privateProfile.isTransitioning {
                    ProgressView(PichiLocalization.text("account.state.updating", defaultValue: "Updating account"))
                        .accessibilityIdentifier("account.updating")
                } else {
                    Text(PichiLocalization.text("account.profile.unavailable", defaultValue: "Account data is temporarily hidden. Finish the current recording or operation, then retry sign-out."))
                        .font(theme.typography.bodySmall).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("account.profile.hidden")
                }
                Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out")) { interaction.logout() }
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
                Text(MobileAccountCopy.error(error)).font(theme.typography.bodySmall)
                    .foregroundStyle(theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.error")
            }
        }
        .onChange(of: interaction.action != nil) { _, active in actionChanged(active) }
        .onChange(of: privateProfile.projectionRevision) { _, _ in interaction.privateProjectionDidChange() }
        .onChange(of: privateProfile.isPrivateDataVisible) { _, _ in interaction.privateProjectionDidChange() }
        .onDisappear { interaction.cancelOwnedSignInOnDisappear() }
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
        } else if session.configuration != nil {
            Button(PichiLocalization.text(session.state == .reauthenticationRequired ? "account.action.reauthenticate" : "account.action.signIn",
                defaultValue: session.state == .reauthenticationRequired ? "Sign in again" : "Sign in")) { interaction.signIn() }
                .disabled(!interaction.canSignIn)
                .accessibilityIdentifier("account.signIn")
            if !session.isSignInAvailable {
                Text(PichiLocalization.text("account.unavailable", defaultValue: "Sign-in is not available yet. You can continue using this device."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    .accessibilityIdentifier("account.unavailable")
            }
            if session.state == .reauthenticationRequired || (session.presentationError != nil && !session.isSignInAvailable) {
                Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out")) { interaction.logout() }
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
        Button(PichiLocalization.text("account.action.switchPerson", defaultValue: "Switch account")) { interaction.switchPerson() }
            .disabled(interaction.action != nil || !session.isSignInAvailable)
            .accessibilityIdentifier("account.switchPerson")
        Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out"), role: .destructive) { interaction.logout() }
            .disabled(interaction.action != nil).accessibilityIdentifier("account.signOut")
    }
}
#endif
