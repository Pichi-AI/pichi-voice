import SwiftUI

/// Replace only source-bound cloud presentation, preserving the account/capture owners.
struct DesktopCloudPublicationView: View {
    @ObservedObject var publication: PichiCloudPublicationService
    @ObservedObject var account: AccountSessionService
    @ObservedObject var profiles: PrivateProfileService
    var onActivityChanged: (Bool) -> Void = { _ in }

    var body: some View {
        if DesktopAccountProjection.isVisible(account: self.account,
                                             isPrivateDataVisible: self.profiles.isPrivateDataVisible,
                                             isTransitioning: self.profiles.isTransitioning) {
            DesktopCloudPublicationPanel(publication: self.publication, account: self.account,
                                         profiles: self.profiles, onActivityChanged: self.onActivityChanged)
                .id(self.profiles.sourceRevision)
        }
    }
}

private struct DesktopCloudPublicationPanel: View {
    @ObservedObject var publication: PichiCloudPublicationService
    @ObservedObject var account: AccountSessionService
    @StateObject private var state: DesktopCloudPublicationPresentation
    let onActivityChanged: (Bool) -> Void
    @Environment(\.theme) private var theme

    init(publication: PichiCloudPublicationService, account: AccountSessionService,
         profiles: PrivateProfileService, onActivityChanged: @escaping (Bool) -> Void) {
        self.publication = publication
        self.account = account
        self._state = StateObject(wrappedValue: DesktopCloudPublicationPresentation(
            publication: publication, account: account, profiles: profiles))
        self.onActivityChanged = onActivityChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Divider()
            if self.account.state == .reauthenticationRequired {
                Text(DesktopCloudPublicationCopy.pause(.authenticationRequired))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud.reauthenticate")
            } else {
                self.controls
                    .disabled(!self.state.isCurrent || self.state.isWorking)
                if self.state.failure != nil {
                    Button(DesktopCloudPublicationCopy.action(.reconcile)) {
                        self.state.retryProjectionObservation()
                    }
                    .disabled(self.state.isWorking)
                    .accessibilityIdentifier("cloud.refresh")
                }
            }
        }
        .buttonStyle(.bordered)
        .tint(self.theme.palette.accent)
        .task { await self.state.activateAndStart(.refresh) }
        .onChange(of: self.state.isWorking) { _, value in self.onActivityChanged(value) }
        .onDisappear { self.state.deactivate(); self.onActivityChanged(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud.panel")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Toggle(isOn: Binding(get: { self.publication.snapshot.cloudSyncEnabled },
                                 set: { self.state.start(.setEnabled($0)) })) {
                Text(PichiLocalization.text("cloud.title", defaultValue: "Cloud sync"))
                    .font(self.theme.typography.bodyStrong)
            }
            .toggleStyle(.switch)
            .disabled(!self.state.isCurrent || self.state.isWorking ||
                      !DesktopCloudPublicationPolicy.canToggle(self.publication.snapshot, accountState: self.account.state))
            .accessibilityIdentifier("cloud.toggle")
            Text(PichiLocalization.text("cloud.consent.futureOnly", defaultValue: "Enable uploads for future eligible recordings in this workspace. Existing local history is not added."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(PichiLocalization.text("cloud.consent.payload", defaultValue: "Protected transcripts and their metadata can be uploaded. Audio stays on this device."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: self.theme.metrics.spacing.sm) {
                if self.state.isWorking || self.publication.snapshot.availability == .pausing {
                    ProgressView().controlSize(.small)
                }
                Text(DesktopCloudPublicationCopy.availability(self.publication.snapshot, accountState: self.account.state))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if DesktopCloudPublicationPolicy.canUseNetwork(self.publication.snapshot, accountState: self.account.state) {
                if self.publication.snapshot.availability == .paused {
                    Button(PichiLocalization.text("cloud.action.resume", defaultValue: "Resume uploads")) { self.state.start(.resume) }
                        .accessibilityIdentifier("cloud.resume")
                } else {
                    Button(PichiLocalization.text("cloud.action.pause", defaultValue: "Pause uploads")) { self.state.start(.pause) }
                        .accessibilityIdentifier("cloud.pause")
                }
            }
            if let failure = self.state.failure {
                Text(DesktopCloudPublicationCopy.failure(failure))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("cloud.error")
            }
        }
    }
}

struct DesktopCloudRecordingStatusView: View {
    let sessionID: MeetingSessionID
    @ObservedObject var publication: PichiCloudPublicationService
    @ObservedObject var account: AccountSessionService
    @ObservedObject var profiles: PrivateProfileService
    var showsActions = true
    @Environment(\.theme) private var theme

    var body: some View {
        if DesktopAccountProjection.isVisible(account: self.account,
                                             isPrivateDataVisible: self.profiles.isPrivateDataVisible,
                                             isTransitioning: self.profiles.isTransitioning) {
            if self.account.state == .reauthenticationRequired {
                Text(DesktopCloudPublicationCopy.pause(.authenticationRequired))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                DesktopCloudRecordingPanel(sessionID: self.sessionID, publication: self.publication,
                                           account: self.account, profiles: self.profiles, showsActions: showsActions)
                    .id(self.profiles.sourceRevision.uuidString + self.sessionID.uuidString)
            }
        }
    }
}

private struct DesktopCloudRecordingPanel: View {
    let sessionID: MeetingSessionID
    let showsActions: Bool
    @ObservedObject var publication: PichiCloudPublicationService
    @ObservedObject var account: AccountSessionService
    @StateObject private var state: DesktopCloudPublicationPresentation
    @Environment(\.theme) private var theme

    init(sessionID: MeetingSessionID, publication: PichiCloudPublicationService,
         account: AccountSessionService, profiles: PrivateProfileService, showsActions: Bool) {
        self.showsActions = showsActions
        self.sessionID = sessionID
        self.publication = publication
        self.account = account
        self._state = StateObject(wrappedValue: DesktopCloudPublicationPresentation(
            publication: publication, account: account, profiles: profiles))
    }

    private var status: PichiCloudPublicationStatus? {
        guard self.state.isCurrent else { return nil }
        return self.publication.snapshot.items[self.sessionID] ?? self.state.loadedStatus
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Label(PichiLocalization.text("cloud.title", defaultValue: "Cloud sync"), systemImage: "icloud")
                .font(self.theme.typography.bodySmallStrong)
            if let status {
                Text(DesktopCloudPublicationCopy.status(status))
                    .font(self.theme.typography.bodySmall)
                if let receipt = DesktopCloudPublicationCopy.receipt(status) {
                    Text(DesktopCloudPublicationCopy.analysis(receipt.analysisState))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                if case let .acceptedNeedsReview(_, reason) = status {
                    Text(DesktopCloudPublicationCopy.pause(reason))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                }
                if showsActions, let action = DesktopCloudPublicationPolicy.action(for: status) {
                    Button(DesktopCloudPublicationCopy.action(action)) { self.perform(action) }
                        .buttonStyle(.bordered)
                        .disabled(!self.state.isCurrent || self.state.isWorking ||
                                  !DesktopCloudPublicationPolicy.canUseNetwork(self.publication.snapshot, accountState: self.account.state))
                        .accessibilityIdentifier("cloud.recording.action")
                }
                if showsActions, let receipt = DesktopCloudPublicationCopy.receipt(status),
                   DesktopCloudPublicationPolicy.needsAssessment(receipt) {
                    Button(PichiLocalization.text("cloud.assessment.open", defaultValue: "Choose participant and criteria")) {
                        self.state.beginAssessment(for: self.sessionID, status: status)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!self.state.isCurrent || self.state.isWorking ||
                              !DesktopCloudPublicationPolicy.canUseNetwork(self.publication.snapshot, accountState: self.account.state))
                    .accessibilityIdentifier("cloud.assessment.open")
                }
            } else {
                Text(self.state.failure.map(DesktopCloudPublicationCopy.failure)
                     ?? PichiLocalization.text("cloud.status.loading", defaultValue: "Checking cloud status"))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                if showsActions, self.state.failure != nil {
                    Button(DesktopCloudPublicationCopy.action(.reconcile)) {
                        self.state.retryStatusObservation(self.sessionID)
                    }
                    .disabled(self.state.isWorking)
                }
            }
            if self.state.isWorking { ProgressView().controlSize(.small) }
            if let failure = self.state.failure, self.status != nil {
                Text(DesktopCloudPublicationCopy.failure(failure))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
            }
        }
        .foregroundStyle(self.theme.palette.primaryText)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await self.state.activateAndStart(.status(self.sessionID)) }
        .onDisappear { self.state.deactivate() }
        .sheet(item: self.assessmentBinding) { session in
            DesktopCloudAssessmentSheet(state: self.state, publication: self.publication, session: session)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cloud.recording.status")
    }

    private var assessmentBinding: Binding<DesktopCloudPublicationPresentation.AssessmentSession?> {
        let epoch = self.state.assessmentSession?.id
        return Binding(get: { self.state.isCurrent ? self.state.assessmentSession : nil }, set: { value in
            if value == nil, let epoch { self.state.dismissAssessment(epoch: epoch) }
        })
    }

    private func perform(_ action: DesktopCloudPublicationPolicy.RecordingAction) {
        switch action {
        case .send: self.state.start(.send(self.sessionID))
        case .retry: self.state.start(.retry(self.sessionID))
        case .reconcile: self.state.start(.reconcile(self.sessionID))
        }
    }
}

private struct DesktopCloudAssessmentSheet: View {
    @ObservedObject var state: DesktopCloudPublicationPresentation
    @ObservedObject var publication: PichiCloudPublicationService
    let session: DesktopCloudPublicationPresentation.AssessmentSession
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Text(PichiLocalization.text("cloud.assessment.title", defaultValue: "Assessment selection"))
                .font(self.theme.typography.bodyStrong)
            if self.state.isCurrent, self.state.assessmentSession?.id == self.session.id {
                ScrollView {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        Text(PichiLocalization.text("cloud.assessment.explicitChoice", defaultValue: "Choose a represented participant and at least one criterion. Nothing is selected automatically."))
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                        self.currentBinding
                        if let page = self.state.assessmentPage {
                            self.choices(page)
                        } else if self.state.isWorking {
                            ProgressView(PichiLocalization.text("cloud.assessment.loading", defaultValue: "Loading assessment options"))
                        }
                        if let failure = self.state.failure {
                            Text(DesktopCloudPublicationCopy.failure(failure))
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                        }
                        Button(PichiLocalization.text("cloud.assessment.reload", defaultValue: "Reload options")) {
                            self.state.reloadAssessment(epoch: self.session.id)
                        }
                        .disabled(!self.state.canLoadAssessmentOptions)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Divider()
                HStack {
                    Button(PichiLocalization.text("cloud.assessment.cancel", defaultValue: "Cancel")) {
                        self.state.dismissAssessment(epoch: self.session.id)
                    }
                    .keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(PichiLocalization.text("cloud.assessment.confirm", defaultValue: "Confirm selection")) {
                        self.state.confirmAssessment(epoch: self.session.id)
                    }
                    .disabled(!self.state.canConfirmAssessment)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cloud.assessment.confirm")
                }
            }
        }
        .font(self.theme.typography.bodySmall)
        .foregroundStyle(self.theme.palette.primaryText)
        .padding()
        .frame(minWidth: 420, idealWidth: 560, maxWidth: 640, minHeight: 300, idealHeight: 520, maxHeight: 680)
        .onDisappear { self.state.dismissAssessment(epoch: self.session.id) }
        .accessibilityIdentifier("cloud.assessment.sheet")
    }

    @ViewBuilder private var currentBinding: some View {
        if let current = self.state.currentAssessment {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(PichiLocalization.text("cloud.assessment.current", defaultValue: "Current selection"))
                    .font(self.theme.typography.bodySmallStrong)
                Text(PichiLocalization.text("cloud.assessment.unchanged", defaultValue: "The current selection stays unchanged until you confirm a replacement."))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                if let participantID = current.participantID {
                    Text(verbatim: self.state.assessmentPage?.participants.first(where: { $0.id == participantID })?.displayName
                         ?? participantID.uuidString)
                }
                ForEach(Array(current.criteriaIDs.enumerated()), id: \.offset) { _, id in
                    Text(verbatim: self.state.assessmentPage?.criteria.data.first(where: { $0.id == id })?.name ?? id)
                        .font(self.theme.typography.caption)
                        .textSelection(.enabled)
                }
                if current.participantID == nil && current.criteriaIDs.isEmpty {
                    Text(PichiLocalization.text("cloud.assessment.currentEmpty", defaultValue: "No current selection"))
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
            }
        }
    }

    private func choices(_ page: PichiPublicationAssessmentOptions) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            if !page.canResolvePending {
                Text(PichiLocalization.text("cloud.assessment.unavailable", defaultValue: "Assessment selection is unavailable for this upload."))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            if page.participants.isEmpty {
                Text(PichiLocalization.text("cloud.assessment.noParticipants", defaultValue: "No represented participants"))
            } else {
                Picker(PichiLocalization.text("cloud.assessment.participant", defaultValue: "Represented participant"),
                       selection: Binding(get: { self.state.selectedParticipantID },
                                          set: { self.state.selectParticipant($0, epoch: self.session.id) })) {
                    Text(PichiLocalization.text("cloud.assessment.chooseParticipant", defaultValue: "Choose a participant"))
                        .tag(Optional<UUID>.none)
                    ForEach(page.participants, id: \.id) { participant in
                        Text(verbatim: participant.displayName).tag(Optional(participant.id))
                    }
                }
                .pickerStyle(.menu)
                .disabled(!page.canResolvePending || self.state.isWorking)
            }
            Text(PichiLocalization.text("cloud.assessment.criteria", defaultValue: "Assessment criteria"))
                .font(self.theme.typography.bodySmallStrong)
            if page.criteria.data.isEmpty {
                Text(PichiLocalization.text("cloud.assessment.noCriteria", defaultValue: "No assessment criteria available"))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            ForEach(page.criteria.data, id: \.id) { criterion in
                Toggle(isOn: Binding(get: { self.state.selectedCriteria[criterion.id] != nil },
                                     set: { self.state.selectCriterion(criterion.id, selected: $0, epoch: self.session.id) })) {
                    Text(verbatim: criterion.name).lineLimit(3)
                }
                .toggleStyle(.checkbox)
                .disabled(!page.canResolvePending || self.state.isWorking ||
                          (self.state.selectedCriteria[criterion.id] == nil && self.state.selectedCriteria.count >= 100))
            }
            Text(PichiLocalization.text("cloud.assessment.limit", defaultValue: "Select up to 100 criteria."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
            if !self.state.selectedCriteria.isEmpty {
                Text(PichiLocalization.text("cloud.assessment.selected", defaultValue: "Selected criteria"))
                    .font(self.theme.typography.bodySmallStrong)
                ForEach(self.state.selectedCriteria.keys.sorted(), id: \.self) { id in
                    HStack {
                        Text(verbatim: self.state.selectedCriteria[id]?.name ?? id).lineLimit(3)
                        Spacer()
                        Button(PichiLocalization.text("cloud.assessment.remove", defaultValue: "Remove")) {
                            self.state.selectCriterion(id, selected: false, epoch: self.session.id)
                        }
                        .disabled(self.state.isWorking || !page.canResolvePending)
                    }
                }
            }
            if page.criteria.pagination.hasMore, page.canResolvePending {
                Button(PichiLocalization.text("cloud.assessment.nextPage", defaultValue: "Next criteria page")) {
                    self.state.loadNextCriteria(epoch: self.session.id)
                }
                .disabled(!self.state.canLoadAssessmentOptions)
            }
        }
    }
}
