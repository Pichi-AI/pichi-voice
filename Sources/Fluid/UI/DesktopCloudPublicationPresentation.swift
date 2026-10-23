import Combine
import Foundation

/// UI command lifetime and sanitized feedback only. N5 owns consent, delivery,
/// polling and persistence; N2 owns profile activation and the retained facade.
@MainActor final class DesktopCloudPublicationPresentation: ObservableObject, PrivateProfileTransitionParticipant {
    enum Action {
        case refresh, setEnabled(Bool), pause, resume
        case status(MeetingSessionID), send(MeetingSessionID), retry(MeetingSessionID), reconcile(MeetingSessionID)
        case options(MeetingSessionID, epoch: UUID, cursor: String?)
        case resolve(MeetingSessionID, epoch: UUID, participantID: UUID, criteriaIDs: [String])
    }
    nonisolated enum Failure { case busy, operation }
    struct AssessmentSession: Identifiable {
        let id = UUID()
        let sessionID: MeetingSessionID
        let importID: String
        let recordingID: String
    }

    @Published private(set) var isWorking = false
    @Published private(set) var failure: Failure?
    @Published private(set) var loadedStatus: PichiCloudPublicationStatus?
    @Published private(set) var assessmentSession: AssessmentSession?
    @Published private(set) var assessmentPage: PichiPublicationAssessmentOptions?
    @Published private(set) var currentAssessment: PichiPublicationAssessment?
    @Published private(set) var selectedParticipantID: UUID?
    @Published private(set) var selectedCriteria: [String: PichiPublicationAssessmentOptions.Criterion] = [:]
    private let publication: PichiCloudPublicationService
    private let account: AccountSessionService
    private let profiles: PrivateProfileService
    private let profile = PrivateProfileStorage.current
    private let context: AccountContext?
    private let revision: UUID
    private let operations = PrivateProfileOperationOwner()
    private var active = false
    private var retired = false
    private var work: (id: UUID, task: Task<Void, Never>)?
    private var assessmentDrain: Task<Void, Never>?
    private var accountObservation: AnyCancellable?
    private var concealObservation: AnyCancellable?

    init(publication: PichiCloudPublicationService, account: AccountSessionService,
         profiles: PrivateProfileService) {
        self.publication = publication
        self.account = account
        self.profiles = profiles
        self.context = account.context
        self.revision = profiles.projectionRevision
        profiles.register(self)
        self.accountObservation = account.$state.combineLatest(account.$generation, account.$context)
            .dropFirst().sink { [weak self] value in
                guard let self else { return }
                if value.0 != .signedIn || value.1 != self.profile.generation || value.2 != self.context,
                   let session = self.assessmentSession {
                    self.dismissAssessment(epoch: session.id)
                }
            }
        self.concealObservation = NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate() }
            }
    }

    private var matchesVisibleScope: Bool {
        guard self.active, !self.retired, let context,
              self.account.state == .signedIn, self.account.context == context,
              self.account.generation == context.generation,
              self.profile.context == context, !self.profile.isGuest,
              self.profiles.projectionRevision == self.revision,
              self.profiles.isPrivateDataVisible, !self.profiles.isTransitioning,
              PrivateProfileStorage.acceptsNewWork else { return false }
        return PrivateProfileStorage.isReadable(self.profile)
    }

    var isCurrent: Bool {
        self.matchesVisibleScope && self.context.map(self.account.isCurrent) == true
    }

    func activate() { self.active = true }

    func activateAndStart(_ action: Action) async {
        self.activate()
        let pending = self.work?.task
        await pending?.value
        await self.assessmentDrain?.value
        guard !Task.isCancelled else { return }
        self.start(action, waitsForReadiness: true)
    }

    func start(_ action: Action) {
        self.start(action, waitsForReadiness: false)
    }

    private func start(_ action: Action, waitsForReadiness: Bool) {
        guard (waitsForReadiness ? self.matchesVisibleScope : self.isCurrent),
              self.work == nil, self.assessmentDrain == nil else { return }
        if self.assessmentSession != nil {
            switch action {
            case .options, .resolve: break
            default: return
            }
        }
        let id = UUID()
        self.failure = nil
        self.isWorking = true
        let task = Task { @MainActor in
            defer {
                if self.work?.id == id {
                    self.work = nil
                    self.isWorking = false
                }
            }
            do {
                try await self.operations.perform {
                    if waitsForReadiness { try await self.waitForAccountReadiness() }
                    guard self.isCurrent, !Task.isCancelled else { throw CancellationError() }
                    switch action {
                    case .refresh: try await self.publication.refresh()
                    case let .setEnabled(value): try await self.publication.setCloudSyncEnabled(value)
                    case .pause: await self.publication.pause()
                    case .resume: try await self.publication.resume()
                    case let .status(sessionID):
                        let status = try await self.publication.status(for: sessionID)
                        if self.isCurrent, !Task.isCancelled { self.loadedStatus = status }
                    case let .send(sessionID): try await self.publication.send(sessionID)
                    case let .retry(sessionID): try await self.publication.retry(sessionID)
                    case let .reconcile(sessionID): try await self.publication.reconcile(sessionID)
                    case let .options(sessionID, epoch, cursor):
                        guard self.acceptsAssessment(sessionID, epoch: epoch) else { throw CancellationError() }
                        let page = try await self.publication.assessmentOptions(for: sessionID, cursor: cursor, limit: 50)
                        guard self.isCurrent, !Task.isCancelled,
                              self.acceptsAssessment(sessionID, epoch: epoch) else { throw CancellationError() }
                        try self.applyAssessmentPage(page, cursor: cursor)
                    case let .resolve(sessionID, epoch, participantID, criteriaIDs):
                        guard self.acceptsAssessment(sessionID, epoch: epoch) else { throw CancellationError() }
                        try await self.publication.resolveAssessment(sessionID, participantID: participantID, criteriaIDs: criteriaIDs)
                        guard self.isCurrent, !Task.isCancelled,
                              self.acceptsAssessment(sessionID, epoch: epoch) else { throw CancellationError() }
                        if let status = self.publication.snapshot.items[sessionID] { self.loadedStatus = status }
                        self.clearAssessment()
                    }
                }
                if self.isCurrent, !Task.isCancelled,
                   self.publication.snapshot.availability == .storageUnavailable {
                    self.failure = .operation
                }
            } catch {
                guard self.matchesVisibleScope, !Task.isCancelled, !(error is CancellationError) else { return }
                if (error as? AccountError) == .staleOperation {
                    if waitsForReadiness, !self.isCurrent { self.failure = .busy }
                    return
                }
                switch action {
                case let .options(sessionID, epoch, _), let .resolve(sessionID, epoch, _, _):
                    guard self.acceptsAssessment(sessionID, epoch: epoch) else { return }
                    self.assessmentPage = nil
                default: break
                }
                self.failure = (error as? AccountError) == .busy ? .busy : .operation
            }
        }
        self.work = (id, task)
    }

    /// N1 publishes a committed context before its command slot clears. This
    /// waits only for that local tail, then performs a single facade read.
    private func waitForAccountReadiness() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !self.isCurrent {
            guard self.matchesVisibleScope, !Task.isCancelled else { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw AccountError.busy }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func retryStatusObservation(_ sessionID: MeetingSessionID) {
        self.start(.status(sessionID), waitsForReadiness: true)
    }

    func retryProjectionObservation() {
        self.start(.refresh, waitsForReadiness: true)
    }

    func deactivate() {
        self.active = false
        self.failure = nil
        self.loadedStatus = nil
        if let session = self.assessmentSession { self.dismissAssessment(epoch: session.id) }
        self.work?.task.cancel()
    }

    func prepareForPrivateProfileTransition() async throws {
        self.deactivate()
        self.retired = true
        let pending = self.work?.task
        let closing = self.assessmentDrain
        await self.operations.retireAndJoin()
        await pending?.value
        await closing?.value
    }

    func beginAssessment(for sessionID: MeetingSessionID, status: PichiCloudPublicationStatus) {
        guard self.isCurrent, !self.isWorking, self.assessmentDrain == nil, self.assessmentSession == nil,
              DesktopCloudPublicationPolicy.canUseNetwork(self.publication.snapshot, accountState: self.account.state),
              (self.publication.snapshot.items[sessionID] ?? self.loadedStatus) == status,
              let receipt = DesktopCloudPublicationCopy.receipt(status),
              DesktopCloudPublicationPolicy.needsAssessment(receipt) else { return }
        self.clearAssessment()
        let session = AssessmentSession(sessionID: sessionID, importID: receipt.importID, recordingID: receipt.recordingID)
        self.assessmentSession = session
        self.start(.options(sessionID, epoch: session.id, cursor: nil))
    }

    private func acceptsAssessment(_ sessionID: MeetingSessionID, epoch: UUID) -> Bool {
        self.assessmentSession?.id == epoch && self.assessmentSession?.sessionID == sessionID
    }

    private func applyAssessmentPage(_ page: PichiPublicationAssessmentOptions, cursor: String?) throws {
        guard let context, let session = self.assessmentSession,
              page.context.accountID == context.identity.internalUserID,
              page.context.organizationID == context.organizationID,
              page.context.workspaceID == context.workspaceID,
              page.receipt.importID == session.importID, page.receipt.recordingID == session.recordingID,
              page.criteria.pagination.cursor == cursor, page.criteria.pagination.limit == 50,
              page.criteria.data.count <= 50, page.participants.count <= 100 else { throw AccountError.invalidResponse }
        if let currentAssessment, currentAssessment != page.currentAssessment { throw AccountError.invalidResponse }
        self.assessmentPage = page
        if self.currentAssessment == nil { self.currentAssessment = page.currentAssessment }
    }

    func loadNextCriteria(epoch: UUID) {
        guard self.assessmentSession?.id == epoch, let session = self.assessmentSession,
              let page = self.assessmentPage, page.criteria.pagination.hasMore,
              let cursor = page.criteria.pagination.nextCursor else { return }
        self.start(.options(session.sessionID, epoch: epoch, cursor: cursor))
    }

    func reloadAssessment(epoch: UUID) {
        guard self.isCurrent, !self.isWorking, self.assessmentSession?.id == epoch,
              let session = self.assessmentSession else { return }
        self.assessmentPage = nil; self.currentAssessment = nil
        self.selectedParticipantID = nil; self.selectedCriteria = [:]
        self.start(.options(session.sessionID, epoch: epoch, cursor: nil))
    }

    func selectParticipant(_ id: UUID?, epoch: UUID) {
        guard self.isCurrent, !self.isWorking, self.assessmentSession?.id == epoch,
              self.assessmentPage?.canResolvePending == true else { return }
        guard let id else { self.selectedParticipantID = nil; return }
        guard self.assessmentPage?.participants.contains(where: { $0.id == id }) == true else { return }
        self.selectedParticipantID = id
    }

    func selectCriterion(_ id: String, selected: Bool, epoch: UUID) {
        guard self.isCurrent, !self.isWorking, self.assessmentSession?.id == epoch,
              self.assessmentPage?.canResolvePending == true else { return }
        if !selected { self.selectedCriteria.removeValue(forKey: id); return }
        guard self.selectedCriteria.count < 100,
              let criterion = self.assessmentPage?.criteria.data.first(where: { $0.id == id }) else { return }
        self.selectedCriteria[id] = criterion
    }

    var canConfirmAssessment: Bool {
        guard self.isCurrent, !self.isWorking,
              DesktopCloudPublicationPolicy.canUseNetwork(self.publication.snapshot, accountState: self.account.state),
              let session = self.assessmentSession, let page = self.assessmentPage, page.canResolvePending,
              let participantID = self.selectedParticipantID,
              page.participants.contains(where: { $0.id == participantID }),
              !self.selectedCriteria.isEmpty, self.selectedCriteria.count <= 100,
              DesktopCloudPublicationPolicy.needsAssessment(page.receipt) else { return false }
        let current = self.publication.snapshot.items[session.sessionID] ?? self.loadedStatus
        if let receipt = current.flatMap(DesktopCloudPublicationCopy.receipt) {
            return receipt.importID == session.importID && receipt.recordingID == session.recordingID &&
                DesktopCloudPublicationPolicy.needsAssessment(receipt)
        }
        return false
    }

    var canLoadAssessmentOptions: Bool {
        self.isCurrent && !self.isWorking && self.assessmentSession != nil &&
            DesktopCloudPublicationPolicy.canUseNetwork(self.publication.snapshot, accountState: self.account.state)
    }

    func confirmAssessment(epoch: UUID) {
        guard self.assessmentSession?.id == epoch, self.canConfirmAssessment,
              let session = self.assessmentSession, let participant = self.selectedParticipantID else { return }
        let criteria = self.selectedCriteria.keys.sorted()
        self.start(.resolve(session.sessionID, epoch: epoch, participantID: participant, criteriaIDs: criteria))
    }

    private func clearAssessment() {
        self.assessmentSession = nil; self.assessmentPage = nil; self.currentAssessment = nil
        self.selectedParticipantID = nil; self.selectedCriteria = [:]; self.failure = nil
    }

    func dismissAssessment(epoch: UUID) {
        guard self.assessmentSession?.id == epoch else { return }
        self.clearAssessment()
        let pending = self.work?.task
        pending?.cancel()
        self.assessmentDrain = Task { @MainActor in
            await pending?.value
            self.assessmentDrain = nil
        }
    }

    func joinAssessmentDismissal() async { await self.assessmentDrain?.value }
}

/// Typed decisions only; copy never selects behavior.
nonisolated enum DesktopCloudPublicationPolicy {
    enum RecordingAction: Equatable { case send, retry, reconcile }

    static func needsAssessment(_ receipt: PichiPublicationReceipt) -> Bool {
        receipt.analysisState == .needsParticipant || receipt.analysisState == .needsCriteria
    }

    static func canToggle(_ snapshot: PichiCloudPublicationSnapshot, accountState: AccountSessionState) -> Bool {
        guard accountState == .signedIn else { return false }
        return switch snapshot.availability {
        case .ready, .paused, .storageUnavailable: true
        case .transportUnavailable: snapshot.cloudSyncEnabled
        case .unconfigured, .signedOut, .profileUnavailable, .pausing: false
        }
    }

    static func canUseNetwork(_ snapshot: PichiCloudPublicationSnapshot, accountState: AccountSessionState) -> Bool {
        accountState == .signedIn && snapshot.cloudSyncEnabled &&
            (snapshot.availability == .ready || snapshot.availability == .paused)
    }

    static func action(for status: PichiCloudPublicationStatus) -> RecordingAction? {
        switch status {
        case .queued: .send
        case .retryScheduled: .retry
        case let .paused(reason):
            switch reason {
            case .userRequested, .profileTransition, .uncertainDelivery,
                 .retryBudgetExhausted, .retryAfterBeyondBudget: .retry
            default: nil
            }
        case .accepted, .acceptedNeedsReview: .reconcile
        case .localOnly, .waitingForSource, .withheld, .sending, .conflict: nil
        }
    }
}
