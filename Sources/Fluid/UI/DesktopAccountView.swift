import SwiftUI

/// Desktop presentation of the composition-owned account service. No credentials or profile lifecycle live here.
struct DesktopAccountView: View {
    @ObservedObject var account: AccountSessionService
    @ObservedObject var publication: PichiCloudPublicationService
    @ObservedObject var profiles: PrivateProfileService = .shared
    var onActivityChanged: (Bool) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @State private var operationID: UUID?
    @State private var isCancelling = false
    @State private var actionError: AccountError?
    @State private var actionErrorGeneration: UUID?
    @State private var cloudIsWorking = false

    private enum Action {
        case signIn, signOut, switchPerson
        case workspace(organizationID: String, workspaceID: String, context: AccountContext)
    }

    private var isWorking: Bool { self.operationID != nil || self.isCancelling || self.cloudIsWorking }

    private var hasVisibleAccountProjection: Bool {
        DesktopAccountProjection.isVisible(account: self.account,
                                           isPrivateDataVisible: self.profiles.isPrivateDataVisible,
                                           isTransitioning: self.profiles.isTransitioning)
    }

    var body: some View {
        // Actions from a fading or retained menu cannot target a newer account generation.
        let generation = self.account.generation
        let projectionRevision = self.profiles.projectionRevision
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Label(PichiLocalization.text("account.title", defaultValue: "Account"), systemImage: "person.crop.circle")
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)

            self.identity
            if self.hasVisibleAccountProjection, self.account.state == .signedIn,
               let snapshot = self.account.account, let context = self.account.context {
                self.workspacePicker(snapshot: snapshot, context: context, projectionRevision: projectionRevision)
            }

            if let error = self.visibleError {
                Label(DesktopAccountCopy.error(error), systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.error")
            }

            self.actions(generation: generation, projectionRevision: projectionRevision)
                .font(self.theme.typography.bodySmallStrong)
                .buttonStyle(.bordered)
                .tint(self.theme.palette.accent)

            Text(PichiLocalization.text("account.history.local", defaultValue: "Signing in does not upload existing recordings."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            DesktopCloudPublicationView(publication: self.publication, account: self.account,
                                        profiles: self.profiles, onActivityChanged: { self.cloudIsWorking = $0 })
                .disabled(self.operationID != nil || self.isCancelling)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.panel")
        .onChange(of: self.isWorking) { _, value in self.onActivityChanged(value) }
        .onChange(of: self.account.generation) { _, _ in
            self.actionError = nil
            self.actionErrorGeneration = nil
        }
        .onChange(of: self.profiles.projectionRevision) { _, _ in
            self.actionError = nil
            self.actionErrorGeneration = nil
        }
        .onDisappear { self.onActivityChanged(false) }
    }

    @ViewBuilder
    private var identity: some View {
        if self.hasVisibleAccountProjection, let snapshot = self.account.account {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                // Server names and email are data, never localization keys or identity selectors.
                Text(verbatim: snapshot.account.displayName)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let email = snapshot.account.email, !email.isEmpty {
                    Text(verbatim: email)
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !self.profiles.isPrivateDataVisible, !self.profiles.isTransitioning,
                  self.account.state != .signingIn {
            Text(PichiLocalization.text("account.profile.unavailable", defaultValue: "Account data is temporarily hidden. Finish the current recording or operation, then retry sign-out."))
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.account.state == .signingIn || !self.profiles.isPrivateDataVisible ||
                    self.account.state == .signedIn || self.account.state == .reauthenticationRequired {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ProgressView().controlSize(.small)
                Text(self.account.state == .signingIn
                     ? PichiLocalization.text("account.state.signingIn", defaultValue: "Signing in")
                     : PichiLocalization.text("account.state.updating", defaultValue: "Updating account"))
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        } else {
            Text(PichiLocalization.text("account.guest.explanation", defaultValue: "Sign-in is optional. You can record and export without an account."))
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func workspacePicker(snapshot: AccountSnapshot, context: AccountContext, projectionRevision: UUID) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text(PichiLocalization.text("account.workspace.title", defaultValue: "Workspace"))
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            if snapshot.organizations.allSatisfy({ $0.workspaces.isEmpty }) {
                Text(PichiLocalization.text("account.workspace.empty", defaultValue: "No workspaces are available for this account. You can continue recording on this device."))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Menu {
                    ForEach(snapshot.organizations, id: \.id) { organization in
                        Section {
                            ForEach(organization.workspaces, id: \.id) { workspace in
                                Button {
                                    self.perform(.workspace(organizationID: organization.id, workspaceID: workspace.id, context: context),
                                                 generation: context.generation, projectionRevision: projectionRevision)
                                } label: {
                                    if context.organizationID == organization.id && context.workspaceID == workspace.id {
                                        Label { Text(verbatim: workspace.name) } icon: { Image(systemName: "checkmark") }
                                    } else {
                                        Text(verbatim: workspace.name)
                                    }
                                }
                            }
                        } header: {
                            Text(verbatim: organization.name)
                        }
                    }
                } label: {
                    HStack {
                        if let organization = snapshot.organizations.first(where: { $0.id == context.organizationID }),
                           let workspace = organization.workspaces.first(where: { $0.id == context.workspaceID }) {
                            Text(verbatim: organization.name + " / " + workspace.name)
                        } else {
                            Text(PichiLocalization.text("account.workspace.choose", defaultValue: "Choose a workspace"))
                        }
                    }
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .disabled(self.isWorking || !self.account.isSignInAvailable)
                .id(projectionRevision)
                .accessibilityIdentifier("account.workspace")
            }
        }
    }

    @ViewBuilder
    private func actions(generation: UUID, projectionRevision: UUID) -> some View {
        if self.account.state == .signingIn {
            Button(PichiLocalization.text("account.action.cancelSignIn", defaultValue: "Cancel sign-in")) {
                self.cancelSignIn(generation: generation)
            }
            .disabled(self.isCancelling)
            .accessibilityIdentifier("account.cancel")
        } else if self.account.state == .signedIn || self.account.state == .reauthenticationRequired {
            ViewThatFits(in: .horizontal) {
                HStack { self.signedInActions(generation: generation, projectionRevision: projectionRevision) }
                VStack(alignment: .leading) { self.signedInActions(generation: generation, projectionRevision: projectionRevision) }
            }
        } else if self.account.configuration != nil {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Button(PichiLocalization.text("account.action.signIn", defaultValue: "Sign in")) {
                    self.perform(.signIn, generation: generation, projectionRevision: projectionRevision)
                }
                .disabled(self.isWorking || !self.account.isSignInAvailable)
                .accessibilityIdentifier("account.sign-in")
                if !self.account.isSignInAvailable && !self.isWorking {
                    Text(PichiLocalization.text("account.unavailable", defaultValue: "Sign-in is not available yet. You can continue using this device."))
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if self.account.presentationError != nil {
                        Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out")) {
                            self.perform(.signOut, generation: generation, projectionRevision: projectionRevision)
                        }
                        .accessibilityIdentifier("account.retry-sign-out")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func signedInActions(generation: UUID, projectionRevision: UUID) -> some View {
        if self.account.state == .reauthenticationRequired {
            Button(PichiLocalization.text("account.action.reauthenticate", defaultValue: "Sign in again")) {
                self.perform(.signIn, generation: generation, projectionRevision: projectionRevision)
            }
            .disabled(self.isWorking || !self.account.isSignInAvailable)
        }
        Button(PichiLocalization.text("account.action.switchPerson", defaultValue: "Switch account")) {
            self.perform(.switchPerson, generation: generation, projectionRevision: projectionRevision)
        }
        .disabled(self.isWorking || !self.account.isSignInAvailable)
        .accessibilityIdentifier("account.switch")
        Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out")) {
            self.perform(.signOut, generation: generation, projectionRevision: projectionRevision)
        }
        .disabled(self.isWorking)
        .accessibilityIdentifier("account.sign-out")
    }

    private var visibleError: AccountError? {
        if self.actionErrorGeneration == self.account.generation, let actionError { return actionError }
        return self.account.presentationError
    }

    private func perform(_ action: Action, generation: UUID, projectionRevision: UUID) {
        guard !self.isWorking, self.account.generation == generation else { return }
        let id = UUID()
        self.operationID = id
        self.onActivityChanged(true)
        self.actionError = nil
        self.actionErrorGeneration = nil
        Task { @MainActor in
            defer {
                if self.operationID == id { self.operationID = nil }
                self.onActivityChanged(self.isWorking)
            }
            guard self.account.generation == generation else { return }
            do {
                switch action {
                case .signOut:
                    // Cleanup remains available while private projections are concealed.
                    await self.account.logout()
                case .signIn:
                    guard self.profiles.projectionRevision == projectionRevision, self.profiles.isPrivateDataVisible else { return }
                    try self.profiles.requireTransitionAdmission()
                    await self.account.signIn()
                case .switchPerson:
                    guard self.profiles.projectionRevision == projectionRevision, self.profiles.isPrivateDataVisible else { return }
                    try self.profiles.requireTransitionAdmission()
                    await self.account.switchPerson()
                case let .workspace(organizationID, workspaceID, context):
                    guard self.account.isCurrent(context), self.profiles.projectionRevision == projectionRevision,
                          self.profiles.isPrivateDataVisible else { return }
                    try self.profiles.requireTransitionAdmission()
                    try await self.account.selectWorkspace(organizationID: organizationID, workspaceID: workspaceID)
                }
            } catch {
                // Local admission errors belong only to the original visible projection.
                // A failed account transition publishes its own authoritative error through N1.
                if self.operationID == id, self.account.generation == generation,
                   self.profiles.projectionRevision == projectionRevision, self.profiles.isPrivateDataVisible {
                    self.actionError = (error as? AccountError) ?? .invalidResponse
                    self.actionErrorGeneration = generation
                }
            }
        }
    }

    private func cancelSignIn(generation: UUID) {
        guard !self.isCancelling, self.account.state == .signingIn, self.account.generation == generation else { return }
        self.isCancelling = true
        self.onActivityChanged(true)
        Task { @MainActor in
            defer {
                self.isCancelling = false
                self.onActivityChanged(self.isWorking)
            }
            guard self.account.state == .signingIn, self.account.generation == generation else { return }
            await self.account.cancelSignIn()
        }
    }
}

private enum DesktopAccountCopy {
    static func error(_ error: AccountError) -> String {
        switch error {
        case .unconfigured:
            PichiLocalization.text("account.error.unconfigured", defaultValue: "Sign-in is not configured for this app. You can continue using this device.")
        case .invalidConfiguration:
            PichiLocalization.text("account.error.invalidConfiguration", defaultValue: "Sign-in is unavailable in this app configuration.")
        case .isolationRequired:
            PichiLocalization.text("account.error.isolationRequired", defaultValue: "Sign-in is not available yet. You can continue using this device.")
        case .busy:
            PichiLocalization.text("account.error.busy", defaultValue: "An account operation is still finishing. Try again shortly.")
        case .cancelled:
            PichiLocalization.text("account.error.cancelled", defaultValue: "Sign-in was cancelled. You can continue as guest.")
        case .invalidCallback:
            PichiLocalization.text("account.error.invalidCallback", defaultValue: "Sign-in could not be verified. Please try again.")
        case .invalidState:
            PichiLocalization.text("account.error.invalidState", defaultValue: "Sign-in could not be verified. Please try again.")
        case .invalidToken:
            PichiLocalization.text("account.error.invalidToken", defaultValue: "Your account could not be verified. Please sign in again.")
        case .invalidAccount:
            PichiLocalization.text("account.error.invalidAccount", defaultValue: "Your account could not be verified. Please sign in again.")
        case .invalidResponse:
            PichiLocalization.text("account.error.invalidResponse", defaultValue: "The account service returned an invalid response. Please try again.")
        case .credentialsUnavailable:
            PichiLocalization.text("account.error.credentialsUnavailable", defaultValue: "Account cleanup could not finish. Retry sign-out before signing in again.")
        case .networkUnavailable:
            PichiLocalization.text("account.error.networkUnavailable", defaultValue: "The account service could not be reached. Check your connection and try again.")
        case .reauthenticationRequired:
            PichiLocalization.text("account.error.reauthenticationRequired", defaultValue: "Please sign in again to reconnect your account.")
        case .permissionDenied:
            PichiLocalization.text("account.error.permissionDenied", defaultValue: "Your account does not have access to this workspace.")
        case .workspaceUnavailable:
            PichiLocalization.text("account.error.workspaceUnavailable", defaultValue: "This workspace is no longer available. Choose another workspace.")
        case .staleOperation:
            PichiLocalization.text("account.error.staleOperation", defaultValue: "Your account changed. Please try again from the current account.")
        case .revocationUnavailable:
            PichiLocalization.text("account.error.revocationUnavailable", defaultValue: "Signed out on this device. The server could not confirm revocation of this device's session.")
        case .previousAccountReturned:
            PichiLocalization.text("account.error.previousAccountReturned", defaultValue: "The same account was returned. Try switching again and choose a different account.")
        }
    }
}
