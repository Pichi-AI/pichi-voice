import SwiftUI

/// Desktop presentation of the composition-owned account service. No credentials or profile lifecycle live here.
struct DesktopAccountView: View {
    @ObservedObject var account: AccountSessionService
    var onActivityChanged: (Bool) -> Void = { _ in }

    @Environment(\.theme) private var theme
    @State private var operationID: UUID?
    @State private var isCancelling = false
    @State private var actionError: AccountError?
    @State private var actionErrorGeneration: UUID?

    private enum Action {
        case signIn, signOut, switchPerson
        case workspace(organizationID: String, workspaceID: String, context: AccountContext)
    }

    private var isWorking: Bool { self.operationID != nil || self.isCancelling }

    var body: some View {
        // Actions from a fading or retained menu cannot target a newer account generation.
        let generation = self.account.generation
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Label(PichiLocalization.text("account.title", defaultValue: "Account"), systemImage: "person.crop.circle")
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)

            self.identity
            if self.account.state == .signedIn, let snapshot = self.account.account, let context = self.account.context {
                self.workspacePicker(snapshot: snapshot, context: context)
            }

            if let error = self.visibleError {
                Label(DesktopAccountCopy.error(error), systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.error")
            }

            self.actions(generation: generation)
                .font(self.theme.typography.bodySmallStrong)
                .buttonStyle(.bordered)
                .tint(self.theme.palette.accent)

            Text(PichiLocalization.text("account.history.local", defaultValue: "Signing in does not upload existing recordings."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.panel")
        .onChange(of: self.isWorking) { _, value in self.onActivityChanged(value) }
        .onChange(of: self.account.generation) { _, _ in
            self.actionError = nil
            self.actionErrorGeneration = nil
        }
        .onDisappear { self.onActivityChanged(false) }
    }

    @ViewBuilder
    private var identity: some View {
        if let snapshot = self.account.account,
           self.account.state == .signedIn || self.account.state == .reauthenticationRequired {
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
        } else if self.account.state == .signingIn {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ProgressView().controlSize(.small)
                Text(PichiLocalization.text("account.state.signingIn", defaultValue: "Complete sign-in in your browser."))
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        } else {
            Text(PichiLocalization.text("account.optional", defaultValue: "Sign-in is optional. You can keep using this device as a guest."))
                .font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func workspacePicker(snapshot: AccountSnapshot, context: AccountContext) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text(PichiLocalization.text("account.workspace.title", defaultValue: "Workspace"))
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            if snapshot.organizations.allSatisfy({ $0.workspaces.isEmpty }) {
                Text(PichiLocalization.text("account.workspace.none", defaultValue: "No workspaces are available for this account."))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Menu {
                    ForEach(snapshot.organizations, id: \.id) { organization in
                        Section {
                            ForEach(organization.workspaces, id: \.id) { workspace in
                                Button {
                                    self.perform(.workspace(organizationID: organization.id, workspaceID: workspace.id, context: context), generation: context.generation)
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
                .accessibilityIdentifier("account.workspace")
            }
        }
    }

    @ViewBuilder
    private func actions(generation: UUID) -> some View {
        if self.account.state == .signingIn {
            Button(PichiLocalization.text("account.action.cancelSignIn", defaultValue: "Cancel sign-in")) {
                self.cancelSignIn(generation: generation)
            }
            .disabled(self.isCancelling)
            .accessibilityIdentifier("account.cancel")
        } else if self.account.state == .signedIn || self.account.state == .reauthenticationRequired {
            ViewThatFits(in: .horizontal) {
                HStack { self.signedInActions(generation: generation) }
                VStack(alignment: .leading) { self.signedInActions(generation: generation) }
            }
        } else if self.account.configuration != nil {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Button(PichiLocalization.text("account.action.signIn", defaultValue: "Sign in")) {
                    self.perform(.signIn, generation: generation)
                }
                .disabled(self.isWorking || !self.account.isSignInAvailable)
                .accessibilityIdentifier("account.sign-in")
                if !self.account.isSignInAvailable && !self.isWorking {
                    Text(PichiLocalization.text("account.state.unavailable", defaultValue: "Sign-in is currently unavailable. You can continue as a guest."))
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    if self.account.presentationError != nil {
                        Button(PichiLocalization.text("account.action.retrySignOut", defaultValue: "Retry sign-out")) {
                            self.perform(.signOut, generation: generation)
                        }
                        .accessibilityIdentifier("account.retry-sign-out")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func signedInActions(generation: UUID) -> some View {
        if self.account.state == .reauthenticationRequired {
            Button(PichiLocalization.text("account.action.reauthenticate", defaultValue: "Sign in again")) {
                self.perform(.signIn, generation: generation)
            }
            .disabled(self.isWorking || !self.account.isSignInAvailable)
        }
        Button(PichiLocalization.text("account.action.switchPerson", defaultValue: "Switch account")) {
            self.perform(.switchPerson, generation: generation)
        }
        .disabled(self.isWorking || !self.account.isSignInAvailable)
        .accessibilityIdentifier("account.switch")
        Button(PichiLocalization.text("account.action.signOut", defaultValue: "Sign out")) {
            self.perform(.signOut, generation: generation)
        }
        .disabled(self.isWorking)
        .accessibilityIdentifier("account.sign-out")
    }

    private var visibleError: AccountError? {
        if self.actionErrorGeneration == self.account.generation, let actionError { return actionError }
        return self.account.presentationError
    }

    private func perform(_ action: Action, generation: UUID) {
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
            switch action {
            case .signIn: await self.account.signIn()
            case .signOut: await self.account.logout()
            case .switchPerson: await self.account.switchPerson()
            case let .workspace(organizationID, workspaceID, context):
                guard self.account.isCurrent(context) else { return }
                do {
                    try await self.account.selectWorkspace(organizationID: organizationID, workspaceID: workspaceID)
                } catch {
                    // A failed transition's own presentationError is authoritative. A local
                    // pre-admission error belongs only to the unchanged originating context.
                    if self.operationID == id, self.account.context == context, self.account.generation == generation {
                        self.actionError = (error as? AccountError) ?? .invalidResponse
                        self.actionErrorGeneration = generation
                    }
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
        case .unconfigured, .invalidConfiguration:
            PichiLocalization.text("account.error.configuration", defaultValue: "Sign-in is unavailable for this installation.")
        case .isolationRequired:
            PichiLocalization.text("account.state.unavailable", defaultValue: "Sign-in is currently unavailable. You can continue as a guest.")
        case .busy:
            PichiLocalization.text("account.error.busy", defaultValue: "An account action is still finishing. Please wait.")
        case .cancelled:
            PichiLocalization.text("account.error.cancelled", defaultValue: "Sign-in was cancelled.")
        case .invalidCallback, .invalidState, .invalidToken, .invalidAccount, .invalidResponse:
            PichiLocalization.text("account.error.verification", defaultValue: "Sign-in could not be verified. Try again.")
        case .credentialsUnavailable:
            PichiLocalization.text("account.error.credentials", defaultValue: "Account access could not be saved or cleared. Try signing out again.")
        case .networkUnavailable:
            PichiLocalization.text("account.error.network", defaultValue: "Unable to connect. Try again when you are online.")
        case .reauthenticationRequired:
            PichiLocalization.text("account.error.reauthentication", defaultValue: "Sign in again to continue using your account.")
        case .permissionDenied:
            PichiLocalization.text("account.error.permission", defaultValue: "Your account no longer has access. Sign in again to review available workspaces.")
        case .workspaceUnavailable:
            PichiLocalization.text("account.error.workspace", defaultValue: "This workspace is no longer available. Choose another workspace.")
        case .staleOperation:
            PichiLocalization.text("account.error.stale", defaultValue: "The account changed. Try the action again.")
        case .revocationUnavailable:
            PichiLocalization.text("account.error.revocation", defaultValue: "You are signed out on this device. The server could not confirm revocation.")
        case .previousAccountReturned:
            PichiLocalization.text("account.error.previousAccountReturned", defaultValue: "The browser returned the previous account. Switch account again and choose a different account.")
        }
    }
}
