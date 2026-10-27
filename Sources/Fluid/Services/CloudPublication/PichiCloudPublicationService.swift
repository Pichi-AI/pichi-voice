import Combine
import Foundation

nonisolated enum PichiCloudPublicationAvailability: String, Sendable {
    case unconfigured, signedOut, profileUnavailable, ready, pausing, paused, protectedDataUnavailable, transportUnavailable, storageUnavailable
}

nonisolated enum PichiCloudPublicationControlFailure: String, Error, Sendable { case cloudSyncDisabled }

nonisolated enum PichiCloudPublicationStatus: Equatable, Sendable {
    case localOnly
    case waitingForSource
    case withheld(PichiPublicationWithholdingReason)
    case queued, sending
    case retryScheduled(Date)
    case paused(PichiPublicationPauseReason)
    case accepted(PichiPublicationReceipt)
    case acceptedNeedsReview(PichiPublicationReceipt, PichiPublicationPauseReason)
    case conflict
}

nonisolated struct PichiCloudPublicationSnapshot: Equatable, Sendable {
    let availability: PichiCloudPublicationAvailability
    let cloudSyncEnabled: Bool
    /// A bounded current-profile projection. status(for:) loads any known history ID.
    let items: [MeetingSessionID: PichiCloudPublicationStatus]
    var deleteLocalAfterAcceptance: Bool = false
    var automaticRecordingIDs: Set<MeetingSessionID> = []
}

/// The single platform-shared facade. N2 composition retains this observer/participant;
/// it does not install another AccountSessionLifecycle or enable account readiness.
@MainActor final class PichiCloudPublicationService: ObservableObject, PrivateProfileRecordingObserver, PrivateProfileTransitionParticipant {
    @Published private(set) var snapshot = PichiCloudPublicationSnapshot(availability: .unconfigured,
        cloudSyncEnabled: false, items: [:])

    var isLegacySession: Bool { account.isLegacySession }
    var legacyDestinationURL: URL? { account.legacyConfiguration?.apiBaseURL }

    private let account: AccountSessionService
    private let meetings: PrivateProfileMeetingStore
    private let profiles: PrivateProfileService
    private let http: (any PichiPublicationHTTPPerforming)?
    private let recordingCipherProvider: (@MainActor @Sendable (PrivateProfileSnapshot) async throws -> MeetingRecordingCipher)?
    private let deleteAcceptedRecording: (@MainActor @Sendable (MeetingSessionID, MeetingProfileOwnership, String) async throws -> Void)?
    private var recordingCipher: MeetingRecordingCipher?
    private var workerDelay: Task<Void, Never>?
    private var scope: PrivateProfileSnapshot?
    private var outbox: PichiPublicationOutboxStore?
    private var consent: PichiPublicationConsentStore?
    private var installed = false
    private var closing = false
    private var closedGeneration: UUID?
    private var userPaused = true
    private var shutDown = false
    private var locals: [UUID: Task<Void, Never>] = [:]
    private var cleanupLocals = Set<UUID>()
    private struct OwnedCommand { let cancel: @Sendable () -> Void; let joined: Task<Void, Never> }
    private var commands: [UUID: OwnedCommand] = [:]
    private var requests: [UUID: Task<PichiPublicationHTTPResponse, Error>] = [:]
    private var delivering = Set<MeetingSessionID>()
    private var cleaning = Set<MeetingSessionID>()
    private var worker: (id: UUID, task: Task<Void, Never>)?
    private var shutdownTask: Task<Void, Never>?
    private var cloudToggle: (id: UUID, task: Task<Void, Error>)?
    private var offLatch: (profileID: String, failed: Bool)?
    private var itemOrder: [MeetingSessionID] = []
    // Only already observed receipts are polled, with a finite per-observation budget.
    private var analysisPolls: [MeetingSessionID: (attempts: Int, notBefore: Date)] = [:]
    private var storageDrain: (id: UUID, task: Task<Void, Never>)?

    init(account: AccountSessionService, meetings: PrivateProfileMeetingStore = .shared,
         profiles: PrivateProfileService? = nil, http: (any PichiPublicationHTTPPerforming)? = nil,
         recordingCipher: (@MainActor @Sendable (PrivateProfileSnapshot) async throws -> MeetingRecordingCipher)? = nil,
         deleteAcceptedRecording: (@MainActor @Sendable (MeetingSessionID, MeetingProfileOwnership, String) async throws -> Void)? = nil) {
        self.account = account; self.meetings = meetings; self.profiles = profiles ?? .shared; self.http = http
        self.recordingCipherProvider = recordingCipher; self.deleteAcceptedRecording = deleteAcceptedRecording
    }

    /// Composition calls once and retains this service. No restore/login/readiness or
    /// networking is triggered. N2 remains the sole owner of profile activation.
    func install() async throws {
        guard !self.installed, !self.shutDown else { throw AccountError.busy }
        try await self.meetings.installRecordingObserver(self)
        self.profiles.register(self)
        self.installed = true
    }

    /// Parent capture composition freezes memory-only audio and the existing Privacy
    /// operation only after this encrypted future-capture queue has passed preflight.
    func prepareAutomaticCapture() async throws -> Bool {
        return try await command {
            guard self.account.isLegacySession, let selectedContext = self.account.context,
                  selectedContext.organizationID != nil, selectedContext.workspaceID != nil else { return false }
            let (profile, context, store, consent) = try self.currentScope()
            guard try await consent.automaticPublicationEnabled(for: context) else { return false }
            try await self.ensureRecordingCipher(profile: profile, context: context, store: store)
            try await store.preflightAutomaticCapture()
            try self.check(profile, context: context)
            return true
        }
    }

    func setDeleteLocalAfterAcceptance(_ enabled: Bool) async throws {
        try await command {
            let (profile, context, _, consent) = try self.currentScope()
            try await consent.setDeleteLocalAfterAcceptance(enabled, for: context)
            try self.check(profile, context: context)
            try await self.refreshBody()
        }
    }

    /// Availability wakes the same bounded worker. Only real authenticated HTTP and
    /// a checked receipt establish server acceptance or authorize local cleanup.
    func notifyServerAvailabilityChanged() async {
        // Restoration may invoke the existing profile lifecycle. It must never be
        // enclosed by a publication task that the lifecycle would then try to join.
        if account.isAwaitingLegacyServerValidation || account.isAwaitingProtectedData {
            await joinOwnedWork()
            await account.restoreAfterConnectivity()
        }
        await localOperation {
            guard !self.closing, !self.shutDown else { return }
            self.workerDelay?.cancel()
            do {
                try await self.activateBody(resumeUserPauses: false)
                if let (_, _, store, _) = try? self.currentScope() { try await store.expediteAutomaticNetworkRetries() }
                self.workerDelay?.cancel()
            } catch is ProtectedDataAccessError { self.waitForProtectedData() }
            catch { /* Durable queue state is retained for the next scoped wake. */ }
        }
    }

    func notifySceneActive(_ active: Bool) async {
        if active { await notifyServerAvailabilityChanged() }
    }

    private func ensureRecordingCipher(profile: PrivateProfileSnapshot, context: AccountContext,
                                       store: PichiPublicationOutboxStore) async throws {
        guard account.isLegacySession else { return }
        if let cipher = recordingCipher, cipher.profileID == profile.id {
            try await store.installCipher(cipher)
            try await meetings.installEncryptionCipher(cipher, for: profile)
            try check(profile, context: context)
            return
        }
        guard let recordingCipherProvider else { throw PichiPublicationOutboxFailure.unavailable }
        let cipher = try await recordingCipherProvider(profile)
        try check(profile, context: context)
        guard cipher.profileID == profile.id else { throw PichiPublicationOutboxFailure.invalidScope }
        try await store.installCipher(cipher)
        try await meetings.installEncryptionCipher(cipher, for: profile)
        try check(profile, context: context)
        recordingCipher = cipher
    }

    private func waitForProtectedData() {
        userPaused = true
        workerDelay?.cancel()
        snapshot = .init(availability: .protectedDataUnavailable,
            cloudSyncEnabled: snapshot.cloudSyncEnabled, items: snapshot.items,
            deleteLocalAfterAcceptance: snapshot.deleteLocalAfterAcceptance,
            automaticRecordingIDs: snapshot.automaticRecordingIDs)
    }

    func refresh() async throws { try await self.command { try await self.refreshBody() } }
    func status(for id: MeetingSessionID) async throws -> PichiCloudPublicationStatus { try await self.command { try await self.statusBody(id) } }
    func send(_ id: MeetingSessionID) async throws { try await self.command { try await self.sendBody(id) } }
    func legacyAssessmentOptions(for id: MeetingSessionID) async throws -> LegacyPublicationOptions {
        try await self.command { try await self.legacyAssessmentOptionsBody(id) }
    }
    func sendLegacy(_ id: MeetingSessionID, userID: String, participantID: UUID, criteriaIDs: [String]) async throws {
        try await self.command {
            let (profile, context, store, _) = try self.currentScope()
            guard self.account.isLegacySession else { throw AccountError.invalidConfiguration }
            let selection = LegacyPublicationSelection(userID: userID, participantID: participantID, criteriaIDs: criteriaIDs.sorted())
            if try await store.record(id: id)?.legacySelection == nil {
                let options = try await self.legacyAssessmentOptionsBody(id)
                guard options.employees.contains(where: { $0.id == userID }),
                      Set(criteriaIDs).isSubset(of: Set(options.criteria.map(\.id))) else { throw AccountError.permissionDenied }
            }
            try self.check(profile, context: context)
            _ = try await store.freezeLegacySelection(id: id, selection: selection)
            try self.check(profile, context: context)
            try await self.sendBody(id)
        }
    }
    func retry(_ id: MeetingSessionID) async throws { try await self.command { try await self.retryBody(id) } }
    func resume() async throws { try await self.command { try await self.resumeBody() } }
    func activateCurrentProfile() async throws { try await self.command { try await self.activateBody(resumeUserPauses: false) } }
    func reconcile(_ id: MeetingSessionID) async throws { try await self.command { try await self.reconcileBody(id) } }
    func assessmentOptions(for id: MeetingSessionID, cursor: String? = nil, limit: Int = 50) async throws -> PichiPublicationAssessmentOptions {
        try await self.command { try await self.assessmentOptionsBody(id, cursor: cursor, limit: limit) }
    }
    func resolveAssessment(_ id: MeetingSessionID, participantID: UUID, criteriaIDs: [String]) async throws {
        try await self.command { try await self.resolveAssessmentBody(id, participantID: participantID, criteriaIDs: criteriaIDs) }
    }

    /// One coherent UI operation. OFF does not complete or publish a disabled snapshot
    /// until all owned transfers have joined and both scoped settings are durable.
    func setCloudSyncEnabled(_ enabled: Bool) async throws {
        guard !self.shutDown, self.cloudToggle == nil else { throw AccountError.busy }
        let (profile, context, store, consent) = try self.currentScope()
        let id = UUID()
        let recoveringStorage = self.offLatch?.profileID == profile.id && self.offLatch?.failed == true
        if !enabled {
            self.offLatch = (profile.id, false); self.userPaused = true
            self.snapshot = .init(availability: .pausing, cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: self.snapshot.items,
                deleteLocalAfterAcceptance: self.snapshot.deleteLocalAfterAcceptance,
                automaticRecordingIDs: self.snapshot.automaticRecordingIDs)
        }
        let task = Task { @MainActor in
            do {
                if !enabled || recoveringStorage { await self.joinOwnedWork(excludingToggle: id) }
                try self.check(profile, context: context)
                try await consent.setCloudSyncEnabled(enabled, for: context)
                try self.check(profile, context: context)
                if enabled {
                    if recoveringStorage { try await store.pauseAll(reason: .profileTransition) }
                    if self.offLatch?.profileID == profile.id { self.offLatch = nil }
                    try await self.activateBody(resumeUserPauses: true)
                } else {
                    try await store.pauseAll(reason: .userRequested)
                    try self.check(profile, context: context)
                    try await self.refreshBody()
                }
            } catch is ProtectedDataAccessError {
                if self.scope == profile, PrivateProfileStorage.isReadable(profile) {
                    self.snapshot = .init(availability: .protectedDataUnavailable,
                        cloudSyncEnabled: enabled, items: self.snapshot.items,
                        deleteLocalAfterAcceptance: self.snapshot.deleteLocalAfterAcceptance,
                        automaticRecordingIDs: self.snapshot.automaticRecordingIDs)
                }
                self.userPaused = true
                throw ProtectedDataAccessError.temporarilyUnavailable
            } catch {
                self.userPaused = true; self.offLatch = (profile.id, true)
                await self.joinOwnedWork(excludingToggle: id)
                if self.scope == profile, PrivateProfileStorage.isReadable(profile) {
                    self.snapshot = .init(availability: .storageUnavailable,
                        cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: self.snapshot.items,
                deleteLocalAfterAcceptance: self.snapshot.deleteLocalAfterAcceptance,
                automaticRecordingIDs: self.snapshot.automaticRecordingIDs)
                }
                throw error
            }
        }
        self.cloudToggle = (id, task)
        defer { if self.cloudToggle?.id == id { self.cloudToggle = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func refreshBody() async throws {
        do { try await self.refreshCurrentScope() }
        catch is ProtectedDataAccessError {
            waitForProtectedData()
            throw ProtectedDataAccessError.temporarilyUnavailable
        } catch {
            if error is PichiPublicationOutboxFailure || error is PichiPublicationConsentFailure,
               let profile = self.scope { self.storageFailed(profile: profile, because: error) }
            let visible = PrivateProfileStorage.current
            let availability: PichiCloudPublicationAvailability = !self.account.isConfigured ? .unconfigured
                : !visible.isReadable || self.closing ? .profileUnavailable
                : self.account.context == nil ? .signedOut
                : self.account.state == .reauthenticationRequired ? .paused : .storageUnavailable
            let sameOwner = visible.isReadable && self.scope?.id == visible.id
            self.snapshot = .init(availability: availability,
                cloudSyncEnabled: sameOwner && self.snapshot.cloudSyncEnabled,
                items: sameOwner ? self.snapshot.items : [:],
                deleteLocalAfterAcceptance: sameOwner && self.snapshot.deleteLocalAfterAcceptance,
                automaticRecordingIDs: sameOwner ? self.snapshot.automaticRecordingIDs : [])
            throw error
        }
    }

    private func refreshCurrentScope() async throws {
        let (profile, context, store, consent) = try self.currentScope()
        let enabled = try await consent.automaticPublicationEnabled(for: context)
        if account.isLegacySession, recordingCipherProvider != nil {
            let hasExisting = recordingCipher != nil ? true : try PichiPublicationOutboxStore.hasEncryptedPersistenceData(in: profile)
            if enabled || hasExisting { try await ensureRecordingCipher(profile: profile, context: context, store: store) }
        }
        let deleteLocal = try await consent.deleteLocalAfterAcceptance(for: context)
        let records = try await store.pendingRecords()
        try self.check(profile, context: context)
        var items = self.snapshot.items
        for record in records { items[record.sessionID] = Self.status(record) }
        let availability: PichiCloudPublicationAvailability = self.offLatch?.profileID == profile.id && self.offLatch?.failed == true
            ? .storageUnavailable : self.userPaused ? .paused : (self.http == nil && !self.account.isLegacySession) ? .transportUnavailable : .ready
        let visibleItems = self.bounded(items)
        self.snapshot = .init(availability: availability,
            cloudSyncEnabled: enabled, items: visibleItems, deleteLocalAfterAcceptance: deleteLocal,
            automaticRecordingIDs: self.snapshot.automaticRecordingIDs.union(records.filter { $0.automaticAccountContext == true }.map(\.sessionID)).intersection(Set(visibleItems.keys)))
    }

    private func statusBody(_ id: MeetingSessionID) async throws -> PichiCloudPublicationStatus {
        let (profile, context, store, _) = try self.currentScope()
        if account.isLegacySession, recordingCipherProvider != nil {
            let hasExisting = recordingCipher != nil ? true : try PichiPublicationOutboxStore.hasEncryptedPersistenceData(in: profile)
            if hasExisting { try await ensureRecordingCipher(profile: profile, context: context, store: store) }
        }
        let record = try await store.record(id: id)
        try self.check(profile, context: context)
        let value = record.map(Self.status) ?? (self.snapshot.items[id] == .paused(.storageUnavailable) ? .paused(.storageUnavailable) : .localOnly)
        self.project(id, value, profile: profile, automatic: record?.automaticAccountContext == true)
        return value
    }

    /// Only an existing recording-time admission can be sent. This cannot claim guest
    /// history or grant historical consent. The worker reuses any frozen first payload.
    private func sendBody(_ id: MeetingSessionID) async throws {
        let (profile, context, store, _) = try self.currentScope()
        guard let record = try await store.record(id: id), record.automaticConsent else { throw PichiPublicationOutboxFailure.notAdmitted }
        try self.check(profile, context: context)
        try await self.requireNetworkAdmission(profile: profile, context: context)
        if record.receipt != nil { try await self.reconcile(id); return }
        if self.account.isLegacySession, record.legacySelection == nil, record.automaticAccountContext != true { throw PichiPublicationOutboxFailure.notAdmitted }
        if record.transcriptBytes == nil { await self.prepareSource(id: id, admission: .init(profile: profile), store: store) }
        try self.check(profile, context: context)
        guard let prepared = try await store.record(id: id), prepared.transcriptBytes != nil else { throw PichiPublicationOutboxFailure.invalidSource }
        if prepared.state == .paused || prepared.state == .retryScheduled { _ = try await store.explicitRetry(id: id) }
        let pending = try await store.record(id: id)
        if pending?.state == .queued || (pending?.state == .retryScheduled && (pending?.nextAttemptAt ?? .distantFuture) <= Date()) {
            await self.deliver(id: id, profile: profile, context: context, store: store)
        }
    }

    private func retryBody(_ id: MeetingSessionID) async throws {
        let (profile, context, store, _) = try self.currentScope()
        guard let record = try await store.record(id: id), record.automaticConsent else { throw PichiPublicationOutboxFailure.notAdmitted }
        try self.check(profile, context: context)
        try await self.requireNetworkAdmission(profile: profile, context: context)
        if record.receipt != nil { try await self.reconcile(id); return }
        if self.account.isLegacySession, record.legacySelection == nil, record.automaticAccountContext != true { throw PichiPublicationOutboxFailure.notAdmitted }
        if record.transcriptBytes == nil { await self.prepareSource(id: id, admission: .init(profile: profile), store: store) }
        else { _ = try await store.explicitRetry(id: id) }
        try self.check(profile, context: context)
        let pending = try await store.record(id: id)
        if pending?.state == .queued || (pending?.state == .retryScheduled && (pending?.nextAttemptAt ?? .distantFuture) <= Date()) {
            await self.deliver(id: id, profile: profile, context: context, store: store)
        }
    }

    func pause() async {
        let frozen = try? self.currentScope()
        self.userPaused = true
        await self.joinOwnedWork()
        if let (profile, context, store, consent) = frozen {
            do {
                try await consent.setDeliveryPaused(true, for: context)
                try await store.pauseAll(reason: .userRequested)
                if self.scope == profile, PrivateProfileStorage.isReadable(profile) {
                    self.snapshot = .init(availability: .paused, cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: self.snapshot.items,
                deleteLocalAfterAcceptance: self.snapshot.deleteLocalAfterAcceptance,
                automaticRecordingIDs: self.snapshot.automaticRecordingIDs)
                }
            } catch {
                self.storageFailed(profile: profile, because: error)
            }
        }
    }

    /// Explicit current-owner resume. Only transition/user/uncertain-delivery pauses are
    /// resumed together; billing, permission, validation and exhausted retries need review.
    private func resumeBody() async throws {
        let (profile, context, _, consent) = try self.currentScope()
        try await self.requireNetworkAdmission(profile: profile, context: context)
        try await consent.setDeliveryPaused(false, for: context)
        try self.check(profile, context: context)
        try await self.activateBody(resumeUserPauses: true)
    }

    private func activateBody(resumeUserPauses: Bool) async throws {
        let (profile, context, store, consent) = try self.currentScope()
        let paused = try await consent.deliveryPaused(for: context)
        let enabled = try await consent.automaticPublicationEnabled(for: context)
        try self.check(profile, context: context)
        if paused || !enabled || self.offLatch?.profileID == profile.id {
            self.userPaused = true
            // Pausing new network delivery does not revoke an already accepted
            // capture's frozen local-retention policy. This branch performs no HTTP.
            if account.isLegacySession, recordingCipherProvider != nil {
                let hasExisting = recordingCipher != nil ? true : try PichiPublicationOutboxStore.hasEncryptedPersistenceData(in: profile)
                if hasExisting {
                    try await ensureRecordingCipher(profile: profile, context: context, store: store)
                    for record in try await store.pendingRecords() where record.state == .acceptedCleanupPending {
                        await cleanupAccepted(record, profile: profile, context: context, store: store)
                    }
                }
            }
            try await self.refreshBody()
            return
        }
        guard self.http != nil || self.account.isLegacySession else { throw PichiPublicationNetworkFailure.unavailable }
        if account.isLegacySession { try await ensureRecordingCipher(profile: profile, context: context, store: store) }
        let records = try await store.pendingRecords()
        try self.check(profile, context: context)
        for record in records where record.state == .paused {
            if record.pauseReason == .profileTransition || record.pauseReason == .uncertainDelivery || (resumeUserPauses && record.pauseReason == .userRequested) {
                if record.automaticAccountContext != true && record.attemptCount >= PichiPublicationRetryPolicy.maximumAutomaticAttempts {
                    _ = try await store.pause(id: record.sessionID, reason: .retryBudgetExhausted)
                    continue
                }
                if record.retryAfterRequiresReview == true || (record.retryNotBefore?.timeIntervalSinceNow ?? 0) > PichiPublicationRetryPolicy.maximumAutomaticDelay {
                    _ = try await store.pause(id: record.sessionID, reason: .retryAfterBeyondBudget)
                    continue
                }
                _ = try await store.explicitRetry(id: record.sessionID)
                try self.check(profile, context: context)
            }
        }
        self.userPaused = false
        try await self.refresh()
        self.startWorker(profile: profile, context: context, store: store)
    }

    private func reconcileBody(_ id: MeetingSessionID) async throws {
        let (profile, context, store, _) = try self.currentScope()
        guard let record = try await store.record(id: id), let receipt = record.receipt else { throw PichiPublicationOutboxFailure.notAdmitted }
        try self.check(profile, context: context)
        if case .legacy = record.configuration {
            try await self.reconcileLegacy(record: record, profile: profile, context: context, store: store)
            return
        }
        guard case .oidc(let configuration) = record.configuration else { throw AccountError.invalidConfiguration }
        let request = try PichiPublicationRequest.status(configuration: configuration, context: context, receipt: receipt)
        let _: PichiPublicationReceipt = try await self.performReceiptRequest(request, record: record, profile: profile, store: store) { response in
            let receipt = try request.receipt(from: response, account: self.account)
            return (receipt, receipt)
        }
    }

    private func resolveAssessmentBody(_ id: MeetingSessionID, participantID: UUID, criteriaIDs: [String]) async throws {
        let (profile, context, store, _) = try self.currentScope()
        guard let record = try await store.record(id: id), let receipt = record.receipt,
              let bytes = record.transcriptBytes else { throw PichiPublicationOutboxFailure.notAdmitted }
        try self.check(profile, context: context)
        guard case .oidc(let configuration) = record.configuration else { throw AccountError.invalidConfiguration }
        let request = try PichiPublicationRequest.resolveAssessment(configuration: configuration, context: context,
            receipt: receipt, transcriptBytes: bytes, assessment: .init(participantID: participantID, criteriaIDs: criteriaIDs))
        let _: PichiPublicationReceipt = try await self.performReceiptRequest(request, record: record, profile: profile, store: store) { response in
            let receipt = try request.receipt(from: response, account: self.account)
            return (receipt, receipt)
        }
    }

    private func assessmentOptionsBody(_ id: MeetingSessionID, cursor: String?, limit: Int) async throws -> PichiPublicationAssessmentOptions {
        let (profile, context, store, _) = try self.currentScope()
        guard let record = try await store.record(id: id), let receipt = record.receipt,
              let bytes = record.transcriptBytes else { throw PichiPublicationOutboxFailure.notAdmitted }
        try self.check(profile, context: context)
        guard case .oidc(let configuration) = record.configuration else { throw AccountError.invalidConfiguration }
        let request = try PichiPublicationRequest.assessmentOptions(configuration: configuration, context: context,
            receipt: receipt, transcriptBytes: bytes, cursor: cursor, limit: limit)
        return try await self.performReceiptRequest(request, record: record, profile: profile, store: store) { response in
            let options = try request.assessmentOptions(from: response, account: self.account)
            return (options, options.receipt)
        }
    }

    /// Receipt and options representations share the same lease, grant, deadline,
    /// response ownership and durable review path. This does not aggregate options pages.
    private func performReceiptRequest<Value: Sendable>(_ request: PichiPublicationRequest, record: PichiPublicationOutboxRecord,
        profile: PrivateProfileSnapshot, store: PichiPublicationOutboxStore,
        decode: (PichiPublicationHTTPResponse) throws -> (Value, PichiPublicationReceipt)) async throws -> Value {
        guard self.delivering.insert(record.sessionID).inserted else { throw AccountError.busy }
        defer { self.delivering.remove(record.sessionID) }
        // Reload after taking the per-record lease. A suspended caller may hold a
        // snapshot from before another request committed a review or server deadline.
        guard let current = try await store.record(id: record.sessionID), current.receipt != nil else {
            throw PichiPublicationOutboxFailure.notAdmitted
        }
        try self.check(profile, context: request.context)
        guard current.retryAfterRequiresReview != true, (current.retryNotBefore ?? .distantPast) <= Date() else {
            throw PichiPublicationOutboxFailure.invalidTransition
        }
        do {
            let response = try await self.performResponse(request, profile: profile)
            let (value, receipt) = try decode(response)
            try self.check(profile, context: request.context)
            let updated = try await store.updateReceipt(id: record.sessionID, receipt: receipt)
            try self.check(profile, context: request.context)
            self.project(record.sessionID, Self.status(updated), profile: profile, automatic: updated.automaticAccountContext == true)
            return value
        } catch {
            // Cancellation/concealment leaves the accepted receipt intact. A current
            // owner's safe remote failure remains visible across restart and login.
            guard (try? self.check(profile, context: request.context)) != nil,
                  !(error is PichiCloudPublicationControlFailure) else { throw error }
            if error is PichiPublicationOutboxFailure { self.storageFailed(profile: profile, because: error); throw error }
            let remote = error as? PichiPublicationRemoteFailure
            let reason: PichiPublicationPauseReason
            if let remote { reason = remote.action == .boundedRetry ? .transportUnavailable : Self.pauseReason(remote.action) }
            else if let account = error as? AccountError { reason = account == .permissionDenied ? .permissionReview : .authenticationRequired }
            else if error is PichiPublicationNetworkFailure { reason = .transportUnavailable }
            else { reason = .receiptReview }
            let updated: PichiPublicationOutboxRecord
            do { updated = try await store.pauseReceipt(id: record.sessionID, reason: reason, retryAfter: remote?.retryAfter) }
            catch { self.storageFailed(profile: profile, because: error); throw error }
            try self.check(profile, context: request.context)
            self.project(record.sessionID, Self.status(updated), profile: profile, automatic: updated.automaticAccountContext == true)
            throw error
        }
    }

    private func legacyAssessmentOptionsBody(_ id: MeetingSessionID) async throws -> LegacyPublicationOptions {
        let (profile, context, store, _) = try self.currentScope()
        guard case .legacy(let configuration) = self.account.publicationConfiguration,
              let record = try await store.record(id: id), record.automaticConsent,
              let workspaceID = context.workspaceID, PichiLegacyPublicationRequest.databaseID(workspaceID) != nil else {
            throw PichiPublicationOutboxFailure.notAdmitted
        }
        if record.transcriptBytes == nil { await self.prepareSource(id: id, admission: .init(profile: profile), store: store) }
        try self.check(profile, context: context)
        guard let bytes = try await store.record(id: id)?.transcriptBytes,
              let source = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let sourceSpeakers = source["speakers"] as? [[String: Any]], let title = source["title"] as? String else {
            throw PichiPublicationOutboxFailure.invalidSource
        }
        let represented = try PichiProtectedPublicationPayload.validate(bytes)
        let usersRequest = try PichiLegacyPublicationRequest.endpoint(origin: configuration.apiBaseURL,
            path: "/api/workspaces/" + workspaceID + "/users")
        let criteriaRequest = try PichiLegacyPublicationRequest.endpoint(origin: configuration.apiBaseURL,
            path: "/api/evaluation-criteria/names")
        let usersResponse = try await self.performLegacyResponse(usersRequest, context: context, profile: profile)
        guard let users = try PichiLegacyPublicationRequest.checkedJSON(usersResponse) as? [[String: Any]], users.count <= 1000 else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        let criteriaResponse = try await self.performLegacyResponse(criteriaRequest, context: context, profile: profile)
        guard let criteria = try PichiLegacyPublicationRequest.checkedJSON(criteriaResponse) as? [[String: Any]], criteria.count <= 1000 else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        var employees: [LegacyPublicationOptions.Employee] = []
        for user in users {
            guard let id = PichiLegacyPublicationRequest.jsonID(user["id"]), let active = user["isActive"] as? Bool else {
                throw PichiPublicationWireFailure.invalidResponse
            }
            guard active else { continue }
            let name = (user["fullName"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? user["email"] as? String
            guard let name, !name.isEmpty, name.utf8.count <= 2048 else { throw PichiPublicationWireFailure.invalidResponse }
            employees.append(.init(id: id, name: name))
        }
        var choices: [LegacyPublicationOptions.Criterion] = []
        for criterion in criteria {
            guard let id = PichiLegacyPublicationRequest.jsonID(criterion["id"]), let name = criterion["name"] as? String,
                  !name.isEmpty, name.utf8.count <= 2048 else { throw PichiPublicationWireFailure.invalidResponse }
            choices.append(.init(id: id, name: name))
        }
        guard Set(employees.map(\.id)).count == employees.count, Set(choices.map(\.id)).count == choices.count else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        let participants = sourceSpeakers.compactMap { value -> LegacyPublicationOptions.Participant? in
            guard let raw = value["id"] as? String, let id = UUID(uuidString: raw), represented.contains(id),
                  let name = value["displayName"] as? String else { return nil }
            return .init(id: id, displayName: name)
        }
        try self.check(profile, context: context)
        return LegacyPublicationOptions(employees: employees, criteria: choices, participants: participants, title: title)
    }

    private func performLegacyResponse(_ request: URLRequest, context: AccountContext,
                                       profile: PrivateProfileSnapshot) async throws -> PichiPublicationHTTPResponse {
        guard self.account.isLegacySession, self.requests.count < 4 else { throw PichiPublicationNetworkFailure.unavailable }
        try self.check(profile, context: context)
        try await self.requireNetworkAdmission(profile: profile, context: context)
        let id = UUID()
        let task = Task { @MainActor in
            do {
                let response = try await self.account.performAuthorizedLegacyRequest(for: context, request: request)
                try self.check(profile, context: context)
                return PichiPublicationHTTPResponse(status: response.status, body: response.body, retryAfter: response.retryAfter)
            } catch AccountError.networkUnavailable { throw PichiPublicationNetworkFailure.unavailable }
            catch is LegacyAccountConnectivityFailure { throw PichiPublicationNetworkFailure.unavailable }
        }
        self.requests[id] = task
        defer { self.requests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func reconcileLegacy(record: PichiPublicationOutboxRecord, profile: PrivateProfileSnapshot,
                                 context: AccountContext, store: PichiPublicationOutboxStore) async throws {
        guard self.delivering.insert(record.sessionID).inserted else { throw AccountError.busy }
        defer { self.delivering.remove(record.sessionID) }
        guard case .legacy(let configuration) = record.configuration, let receipt = record.receipt,
              record.retryAfterRequiresReview != true, (record.retryNotBefore ?? .distantPast) <= Date() else {
            throw PichiPublicationOutboxFailure.invalidTransition
        }
        do {
            let request = try PichiLegacyPublicationRequest.status(origin: configuration.apiBaseURL, receipt: receipt)
            let response = try await self.performLegacyResponse(request, context: context, profile: profile)
            let current: PichiPublicationReceipt
            if record.automaticAccountContext == true, let digest = record.canonicalSourceSHA256 {
                current = try PichiLegacyPublicationRequest.accountContextReceipt(from: response, context: context,
                    sessionID: record.sessionID, canonicalSourceSHA256: digest,
                    managerSpeakerID: record.managerSpeakerHint, expected: receipt)
            } else {
                guard let bytes = record.transcriptBytes, let selection = record.legacySelection else {
                    throw PichiPublicationOutboxFailure.invalidTransition
                }
                current = try PichiLegacyPublicationRequest.receipt(from: response, context: context,
                    transcriptBytes: bytes, selection: selection, expected: receipt)
            }
            try self.check(profile, context: context)
            var updated = try await store.updateReceipt(id: record.sessionID, receipt: current)
            if current.billingState?.needsReview == true { updated = try await store.pauseReceipt(id: record.sessionID, reason: .accountReview) }
            try self.check(profile, context: context)
            self.project(record.sessionID, Self.status(updated), profile: profile, automatic: updated.automaticAccountContext == true)
            if updated.state == .acceptedCleanupPending {
                await self.cleanupAccepted(updated, profile: profile, context: context, store: store)
            }
        } catch is ProtectedDataAccessError {
            waitForProtectedData()
            throw ProtectedDataAccessError.temporarilyUnavailable
        } catch {
            guard (try? self.check(profile, context: context)) != nil, !(error is PichiCloudPublicationControlFailure) else { throw error }
            let remote = error as? PichiPublicationRemoteFailure
            let reason: PichiPublicationPauseReason = remote.map { $0.action == .boundedRetry ? .transportUnavailable : Self.pauseReason($0.action) }
                ?? (error is AccountError ? .authenticationRequired : .receiptReview)
            let updated = try await store.pauseReceipt(id: record.sessionID, reason: reason, retryAfter: remote?.retryAfter)
            try self.check(profile, context: context)
            self.project(record.sessionID, Self.status(updated), profile: profile, automatic: updated.automaticAccountContext == true)
            throw error
        }
    }

    private func cleanupAccepted(_ record: PichiPublicationOutboxRecord, profile: PrivateProfileSnapshot,
                                 context: AccountContext, store: PichiPublicationOutboxStore) async {
        guard record.state == .acceptedCleanupPending, record.receipt != nil,
              record.receiptPauseReason != .sourceConflict,
              let expectedDigest = record.localSourceSHA256,
              let deleteAcceptedRecording, cleaning.insert(record.sessionID).inserted else { return }
        defer { cleaning.remove(record.sessionID) }
        do {
            try check(profile, context: context)
            // A user can edit the local source while HTTP is in flight. Never erase
            // that newer work because an older frozen snapshot was accepted.
            if let current = try await meetings.loadTranscript(id: record.sessionID) {
                try check(profile, context: context)
                guard current.profileOwnership == record.owner else { throw AccountError.staleOperation }
                let export = Task.detached { try PichiProtectedPublicationSource.localFingerprint(for: current) }
                let source = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
                try check(profile, context: context)
                guard source == expectedDigest else {
                    let reviewed = try await store.pauseReceipt(id: record.sessionID, reason: .sourceConflict)
                    project(record.sessionID, Self.status(reviewed), profile: profile, automatic: reviewed.automaticAccountContext == true)
                    return
                }
            }
            try check(profile, context: context)
            // Composition must revalidate this digest under the coordinator/store's
            // deletion ownership after flushing writers. The preflight check alone
            // cannot prevent an edit completing between this await and acquisition.
            try await deleteAcceptedRecording(record.sessionID, record.owner, expectedDigest)
            try check(profile, context: context)
            let compacted = try await store.completeLocalRemoval(id: record.sessionID)
            try check(profile, context: context)
            project(record.sessionID, Self.status(compacted), profile: profile, automatic: compacted.automaticAccountContext == true)
        } catch is CancellationError { return }
        catch let failure as PichiPublicationOutboxFailure where failure == .receiptConflict {
            guard (try? check(profile, context: context)) != nil else { return }
            if let reviewed = try? await store.pauseReceipt(id: record.sessionID, reason: .sourceConflict) {
                project(record.sessionID, Self.status(reviewed), profile: profile, automatic: reviewed.automaticAccountContext == true)
            }
        }
        catch is ProtectedDataAccessError { waitForProtectedData() }
        catch is PichiPublicationWithholdingReason {
            guard (try? check(profile, context: context)) != nil else { return }
            if let reviewed = try? await store.pauseReceipt(id: record.sessionID, reason: .sourceConflict) {
                project(record.sessionID, Self.status(reviewed), profile: profile, automatic: reviewed.automaticAccountContext == true)
            }
        } catch {
            // Busy/finalizing coordinator guards stay intact. Only cleanup is retried;
            // the durable accepted receipt can never re-enter upload or billing.
            if error is PichiPublicationOutboxFailure { storageFailed(profile: profile, because: error) }
        }
    }

    // MARK: N2 local-only recording observer

    func captureAdmitted(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {
        await self.localOperation {
            do {
                let (profile, context, store, consent) = try self.currentScope(expected: admission.profile)
                let stored = try await consent.automaticPublicationEnabled(for: context)
                try self.check(profile, context: context)
                let enabled = stored && self.offLatch?.profileID != profile.id && !self.account.isLegacySession
                let record = try await store.capture(id: id, automaticConsent: enabled)
                try self.check(profile, context: context)
                self.project(id, Self.status(record), profile: profile, automatic: record.automaticAccountContext == true)
            } catch {
                // Missing durable admission always means local-only on later callbacks.
                // Recording remains authorized and no exception escapes to N2 persistence.
                self.project(id, .paused(.storageUnavailable), profile: admission.profile)
                if error is PichiPublicationConsentFailure || (error as? PichiPublicationOutboxFailure).map({ $0 != .capacityExceeded }) == true {
                    self.storageFailed(profile: admission.profile, because: error)
                }
            }
        }
    }

    /// A required encrypted capture must fail before recording if reservation or key
    /// validation fails. Unlike the ordinary observer callback this error is not swallowed.
    func prepareRequiredCapture(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async throws {
        try await command {
            let (profile, context, store, consent) = try self.currentScope(expected: admission.profile)
            guard self.account.isLegacySession, admission.requiresEncryptedPersistence else {
                throw PichiPublicationOutboxFailure.invalidScope
            }
            try await self.ensureRecordingCipher(profile: profile, context: context, store: store)
            let enabled = try await consent.automaticPublicationEnabled(for: context)
                && self.offLatch?.profileID != profile.id
            let deleteLocal = try await consent.deleteLocalAfterAcceptance(for: context)
            try self.check(profile, context: context)
            let record = try await store.capture(id: id, automaticConsent: enabled,
                automaticAccountContext: enabled, requiresEncryptedPersistence: true,
                deleteLocalAfterAcceptance: enabled && deleteLocal)
            try self.check(profile, context: context)
            self.project(id, Self.status(record), profile: profile, automatic: record.automaticAccountContext == true)
        }
    }

    func sourceDidPersist(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {
        await self.localOperation {
            guard let (_, _, store, _) = try? self.currentScope(expected: admission.profile) else { return }
            await self.prepareSource(id: id, admission: admission, store: store)
        }
        // Wake only the existing task after this bounded local operation. No HTTP or
        // coordinator deletion is awaited from the persistence callback itself.
        await MainActor.run {
            self.workerDelay?.cancel()
            if let (profile, context, store, _) = try? self.currentScope(expected: admission.profile), !self.userPaused {
                self.startWorker(profile: profile, context: context, store: store)
            }
        }
    }

    func captureAdmissionCancelled(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {
        await self.localOperation(allowClosing: true) {
            guard let configuration = self.account.publicationConfiguration else { return }
            do {
                let store: PichiPublicationOutboxStore
                if self.scope?.id == admission.profile.id, let existing = self.outbox { store = existing }
                else { store = PichiPublicationOutboxStore(profile: admission.profile, destination: configuration) }
                try await store.cancelCapture(id: id)
            } catch { /* A failed local cleanup must not block recording or erase a source. */ }
        }
    }

    func prepareForPrivateProfileTransition() async throws {
        self.closing = true; self.closedGeneration = PrivateProfileStorage.current.generation
        self.userPaused = true
        self.snapshot = .init(availability: .profileUnavailable, cloudSyncEnabled: false, items: [:])
        self.itemOrder.removeAll()
        self.analysisPolls.removeAll()
        await self.joinOwnedWork()
        if let outbox { try await outbox.pauseAll(reason: .profileTransition) }
        self.outbox = nil; self.consent = nil; self.scope = nil; self.recordingCipher = nil
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        self.shutDown = true; self.closing = true; self.userPaused = true
        let task = Task { @MainActor in
            await self.joinOwnedWork()
            if let outbox = self.outbox { try? await outbox.pauseAll(reason: .profileTransition) }
            await self.http?.shutdown()
            self.outbox = nil; self.consent = nil; self.scope = nil; self.recordingCipher = nil
            self.analysisPolls.removeAll()
            self.snapshot = .init(availability: .profileUnavailable, cloudSyncEnabled: false, items: [:])
        }
        self.shutdownTask = task
        await task.value
    }

    private func currentScope(expected: PrivateProfileSnapshot? = nil) throws
        -> (PrivateProfileSnapshot, AccountContext, PichiPublicationOutboxStore, PichiPublicationConsentStore) {
        guard !self.shutDown, let configuration = self.account.publicationConfiguration else { throw AccountError.unconfigured }
        guard let context = self.account.context, self.account.isCurrent(context) else { throw AccountError.staleOperation }
        let profile = PrivateProfileStorage.current
        guard !profile.isGuest, profile.context == context, PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              expected.map({ $0 == profile }) != false else { throw AccountError.staleOperation }
        if self.closing {
            guard profile.generation != self.closedGeneration else { throw AccountError.staleOperation }
            self.closing = false
        }
        if self.scope != profile || self.outbox == nil {
            self.snapshot = .init(availability: .paused, cloudSyncEnabled: false, items: [:]); self.itemOrder.removeAll(); self.analysisPolls.removeAll()
            let rootAttributes = try FileManager.default.attributesOfItem(atPath: profile.rootDirectory.path)
            guard rootAttributes[.type] as? FileAttributeType == .typeDirectory,
                  let rootPermissions = (rootAttributes[.posixPermissions] as? NSNumber)?.intValue,
                  rootPermissions & 0o077 == 0 else {
                throw PichiPublicationOutboxFailure.invalidStorage
            }
            let store = PichiPublicationOutboxStore(profile: profile, destination: configuration,
                cipher: recordingCipher?.profileID == profile.id ? recordingCipher : nil)
            let consentDirectory = profile.directory("CloudPublication").appendingPathComponent("Consent", isDirectory: true)
            try Self.privateDirectory(consentDirectory)
            self.scope = profile; self.outbox = store
            self.consent = PichiPublicationConsentStore(directory: consentDirectory, destination: configuration)
        }
        return (profile, context, self.outbox!, self.consent!)
    }

    private func check(_ profile: PrivateProfileSnapshot, context: AccountContext) throws {
        try Task.checkCancellation()
        guard !self.shutDown, !self.closing, self.account.isCurrent(context),
              PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile),
              PrivateProfileStorage.current.context == context else { throw AccountError.staleOperation }
    }

    private func prepareSource(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission, store: PichiPublicationOutboxStore) async {
        guard let context = admission.profile.context else { return }
        do {
            try self.check(admission.profile, context: context)
            guard let record = try await store.record(id: id), record.automaticConsent, record.transcriptBytes == nil else { return }
            let saved = try await self.meetings.persistedSource(id: id, admission: admission)
            try self.check(admission.profile, context: context)
            guard saved.state == .completed else { return }
            let export = Task.detached { try PichiProtectedPublicationSource.prepare(for: saved) }
            let source = try await withTaskCancellationHandler { try await export.value } onCancel: { export.cancel() }
            try self.check(admission.profile, context: context)
            let updated = try await store.installSource(id: id, source: source)
            try self.check(admission.profile, context: context)
            self.project(id, Self.status(updated), profile: admission.profile, automatic: updated.automaticAccountContext == true)
        } catch let reason as PichiPublicationWithholdingReason {
            guard (try? self.check(admission.profile, context: context)) != nil else { return }
            do {
                let record = try await store.withhold(id: id, reason: reason)
                self.project(id, Self.status(record), profile: admission.profile, automatic: record.automaticAccountContext == true)
            } catch { self.storageFailed(profile: admission.profile, because: error) }
        } catch {
            if let failure = error as? PichiPublicationOutboxFailure, failure != .capacityExceeded {
                self.storageFailed(profile: admission.profile, because: error)
            }
        }
    }

    private func command<T: Sendable>(_ operation: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        guard !self.shutDown, self.commands.count < 32 else { throw AccountError.busy }
        let id = UUID(), task = Task { @MainActor in try await operation() }
        let joined = Task { @MainActor in _ = await task.result }
        self.commands[id] = .init(cancel: { task.cancel() }, joined: joined)
        defer { self.commands.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func localOperation(allowClosing: Bool = false, _ operation: @escaping @MainActor () async -> Void) async {
        guard !self.shutDown, (allowClosing || !self.closing), self.locals.count < 16 else { return }
        let id = UUID(), task = Task { @MainActor in await operation() }
        self.locals[id] = task
        if allowClosing { self.cleanupLocals.insert(id) }
        if allowClosing { await task.value }
        else { await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() } }
        self.locals.removeValue(forKey: id)
        self.cleanupLocals.remove(id)
    }

    private func perform(_ request: PichiPublicationRequest, profile: PrivateProfileSnapshot) async throws -> PichiPublicationReceipt {
        let response = try await self.performResponse(request, profile: profile)
        return try request.receipt(from: response, account: self.account)
    }

    private func performResponse(_ request: PichiPublicationRequest, profile: PrivateProfileSnapshot) async throws -> PichiPublicationHTTPResponse {
        guard let http, self.requests.count < 4 else { throw PichiPublicationNetworkFailure.unavailable }
        try self.check(profile, context: request.context)
        try await self.requireNetworkAdmission(profile: profile, context: request.context)
        let id = UUID()
        let task = Task { @MainActor in
            let authorized = try await request.authorized(using: self.account)
            try self.check(profile, context: request.context)
            let response = try await http.perform(authorized)
            try self.check(profile, context: request.context)
            return response
        }
        self.requests[id] = task
        defer { self.requests.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func requireNetworkAdmission(profile: PrivateProfileSnapshot, context: AccountContext) async throws {
        try self.check(profile, context: context)
        guard self.offLatch?.profileID != profile.id, let consent = self.consent,
              try await consent.automaticPublicationEnabled(for: context) else { throw PichiCloudPublicationControlFailure.cloudSyncDisabled }
        try self.check(profile, context: context)
        guard self.offLatch?.profileID != profile.id else { throw PichiCloudPublicationControlFailure.cloudSyncDisabled }
    }

    private func startWorker(profile: PrivateProfileSnapshot, context: AccountContext, store: PichiPublicationOutboxStore) {
        guard self.worker == nil, !self.userPaused, !self.shutDown else { return }
        let id = UUID()
        let task = Task { @MainActor in
            defer { if self.worker?.id == id { self.worker = nil } }
            while !Task.isCancelled && !self.userPaused {
                do {
                    try self.check(profile, context: context)
                    let records = try await store.pendingRecords()
                    try self.check(profile, context: context)
                    for record in records {
                        try self.check(profile, context: context)
                        guard !self.userPaused else { break }
                        if record.state == .acceptedCleanupPending {
                            await self.cleanupAccepted(record, profile: profile, context: context, store: store)
                        } else if record.state == .waitingForSource {
                            await self.prepareSource(id: record.sessionID, admission: .init(profile: profile), store: store)
                            if let ready = try await store.record(id: record.sessionID), ready.state == .queued,
                               (!self.account.isLegacySession || ready.legacySelection != nil || ready.automaticAccountContext == true) {
                                await self.deliver(id: ready.sessionID, profile: profile, context: context, store: store)
                            }
                        } else if (record.state == .queued || (record.state == .retryScheduled && (record.nextAttemptAt ?? .distantFuture) <= Date()))
                            && (!self.account.isLegacySession || record.legacySelection != nil || record.automaticAccountContext == true) {
                            await self.deliver(id: record.sessionID, profile: profile, context: context, store: store)
                        }
                    }
                    var polls = 0
                    for (id, plan) in self.analysisPolls.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                        try self.check(profile, context: context)
                        guard !self.userPaused else { break }
                        guard polls < 4 else { break }
                        guard plan.attempts < 12, plan.notBefore <= Date() else { continue }
                        self.analysisPolls[id] = (plan.attempts + 1, Date().addingTimeInterval(10))
                        polls += 1
                        do { try await self.reconcileBody(id) }
                        catch { try self.check(profile, context: context) }
                    }
                    // Local notifications never start HTTP. This single resumed worker
                    // checks only its bounded pending IDs; there is no history scan.
                    let delay = Task<Void, Never> { try? await Task.sleep(for: .seconds(5)) }
                    self.workerDelay = delay
                    await withTaskCancellationHandler { await delay.value } onCancel: { delay.cancel() }
                    self.workerDelay = nil
                    try Task.checkCancellation()
                } catch {
                    if error is PichiPublicationOutboxFailure || error is PichiPublicationConsentFailure { self.storageFailed(profile: profile, because: error) }
                    return
                }
            }
        }
        self.worker = (id, task)
    }

    private func deliver(id: MeetingSessionID, profile: PrivateProfileSnapshot, context: AccountContext, store: PichiPublicationOutboxStore) async {
        guard self.delivering.insert(id).inserted else { return }
        defer { self.delivering.remove(id) }
        do {
            try self.check(profile, context: context)
            try await self.requireNetworkAdmission(profile: profile, context: context)
            let record = try await store.beginAttempt(id: id, now: Date())
            guard let bytes = record.transcriptBytes, let digest = record.sourceSHA256 else { throw PichiPublicationOutboxFailure.invalidSource }
            let receipt: PichiPublicationReceipt
            switch record.configuration {
            case .oidc(let configuration):
                let request = try PichiPublicationRequest.importSource(configuration: configuration, context: context,
                    operationID: record.operationID, transcriptBytes: bytes, sourceSHA256: digest,
                    assessment: record.originalAssessment, boundary: record.multipartBoundary)
                receipt = try await self.perform(request, profile: profile)
            case .legacy(let configuration):
                if record.automaticAccountContext == true {
                    guard let canonical = record.canonicalSourceSHA256 else { throw PichiPublicationOutboxFailure.invalidSource }
                    let body = try PichiLegacyPublicationRequest.accountContextBody(context: context,
                        transcriptBytes: bytes, managerSpeakerID: record.managerSpeakerHint)
                    let request = try PichiLegacyPublicationRequest.importSource(origin: configuration.apiBaseURL, frozenBody: body)
                    let response = try await self.performLegacyResponse(request, context: context, profile: profile)
                    receipt = try PichiLegacyPublicationRequest.accountContextReceipt(from: response, context: context,
                        sessionID: record.sessionID, canonicalSourceSHA256: canonical, managerSpeakerID: record.managerSpeakerHint)
                } else {
                    guard let selection = record.legacySelection else { throw PichiPublicationOutboxFailure.notAdmitted }
                    let body = try PichiLegacyPublicationRequest.importBody(context: context, transcriptBytes: bytes, selection: selection)
                    let request = try PichiLegacyPublicationRequest.importSource(origin: configuration.apiBaseURL, frozenBody: body)
                    let response = try await self.performLegacyResponse(request, context: context, profile: profile)
                    receipt = try PichiLegacyPublicationRequest.receipt(from: response, context: context, transcriptBytes: bytes, selection: selection)
                }
            }
            try self.check(profile, context: context)
            var accepted = try await store.accept(id: id, receipt: receipt)
            if receipt.billingState?.needsReview == true { accepted = try await store.pauseReceipt(id: id, reason: .accountReview) }
            try self.check(profile, context: context)
            self.project(id, Self.status(accepted), profile: profile, automatic: accepted.automaticAccountContext == true)
            if accepted.state == .acceptedCleanupPending {
                await self.cleanupAccepted(accepted, profile: profile, context: context, store: store)
            }
        } catch {
            if Task.isCancelled || error is CancellationError {
                // The HTTP task has joined. This task is owned and joined by its
                // enclosing command/worker, but must not inherit caller cancellation:
                // the retained store's one-time crash recovery cannot repair this run.
                let cleanup = Task { @MainActor in
                    guard (try? self.check(profile, context: context)) != nil else { return }
                    do {
                        guard try await store.record(id: id)?.state == .sending else { return }
                        let paused = try await store.pause(id: id, reason: .uncertainDelivery)
                        self.project(id, Self.status(paused), profile: profile, automatic: paused.automaticAccountContext == true)
                    } catch {
                        if self.scope == profile, !self.closing, PrivateProfileStorage.isReadable(profile) {
                            self.snapshot = .init(availability: .storageUnavailable,
                                cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: self.snapshot.items,
                deleteLocalAfterAcceptance: self.snapshot.deleteLocalAfterAcceptance,
                automaticRecordingIDs: self.snapshot.automaticRecordingIDs)
                        }
                    }
                }
                await cleanup.value
                return
            }
            guard (try? self.check(profile, context: context)) != nil else { return }
            do {
                let updated: PichiPublicationOutboxRecord
                if error is ProtectedDataAccessError {
                    let count = try await store.record(id: id)?.attemptCount ?? 1
                    updated = try await store.scheduleRetry(id: id,
                        decision: PichiPublicationRetryPolicy.automaticContextDecision(afterAttempt: count, retryAfter: nil), now: Date())
                    self.waitForProtectedData()
                } else if let remote = error as? PichiPublicationRemoteFailure {
                    if remote.action == .boundedRetry {
                        let count = try await store.record(id: id)?.attemptCount ?? PichiPublicationRetryPolicy.maximumAutomaticAttempts
                        updated = try await store.scheduleRetry(id: id, decision: PichiPublicationRetryPolicy.decision(afterAttempt: count, retryAfter: remote.retryAfter), retryAfter: remote.retryAfter, now: Date())
                    } else { updated = try await store.pause(id: id, reason: Self.pauseReason(remote.action)) }
                } else if error is PichiCloudPublicationControlFailure {
                    updated = try await store.pause(id: id, reason: .userRequested)
                } else if let account = error as? AccountError {
                    updated = try await store.pause(id: id, reason: account == .permissionDenied ? .permissionReview : .authenticationRequired)
                } else if (error as? PichiPublicationNetworkFailure) == .unavailable {
                    let count = try await store.record(id: id)?.attemptCount ?? PichiPublicationRetryPolicy.maximumAutomaticAttempts
                    updated = try await store.scheduleRetry(id: id, decision: PichiPublicationRetryPolicy.decision(afterAttempt: count, retryAfter: nil), now: Date())
                } else { updated = try await store.pause(id: id, reason: .receiptReview) }
                try self.check(profile, context: context)
                self.project(id, Self.status(updated), profile: profile, automatic: updated.automaticAccountContext == true)
            } catch { self.storageFailed(profile: profile, because: error) }
        }
    }

    private func storageFailed(profile: PrivateProfileSnapshot, because error: any Error) {
        guard !Task.isCancelled, !(error is CancellationError), !self.shutDown, !self.closing, self.scope == profile,
              PrivateProfileStorage.isReadable(profile), let context = profile.context,
              self.account.isCurrent(context) else { return }
        self.offLatch = (profile.id, true); self.userPaused = true
        self.snapshot = .init(availability: .storageUnavailable,
            cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: self.snapshot.items,
                deleteLocalAfterAcceptance: self.snapshot.deleteLocalAfterAcceptance,
                automaticRecordingIDs: self.snapshot.automaticRecordingIDs)
        self.workerDelay?.cancel()
        self.worker?.task.cancel()
        let requests = Array(self.requests.values)
        for request in requests { request.cancel() }
        guard self.storageDrain == nil, !requests.isEmpty else { return }
        let id = UUID()
        let task = Task { @MainActor in
            defer { if self.storageDrain?.id == id { self.storageDrain = nil } }
            for request in requests { _ = await request.result }
        }
        self.storageDrain = (id, task)
    }

    private func joinOwnedWork(excludingToggle: UUID? = nil) async {
        let toggle = self.cloudToggle?.id == excludingToggle ? nil : self.cloudToggle
        toggle?.task.cancel()
        self.workerDelay?.cancel()
        self.worker?.task.cancel()
        for (id, task) in self.locals where !self.cleanupLocals.contains(id) { task.cancel() }
        for task in self.requests.values { task.cancel() }
        for command in self.commands.values { command.cancel() }
        if let worker { await worker.task.value }
        if let toggle { _ = await toggle.task.result }
        if let storageDrain { await storageDrain.task.value }
        while !self.locals.isEmpty || !self.requests.isEmpty || !self.commands.isEmpty {
            let locals = Array(self.locals.values), requests = Array(self.requests.values)
            let commands = Array(self.commands.values)
            for task in locals { await task.value }
            for task in requests { _ = await task.result }
            for command in commands { await command.joined.value }
            await Task.yield()
        }
    }

    private func project(_ id: MeetingSessionID, _ status: PichiCloudPublicationStatus, profile: PrivateProfileSnapshot, automatic: Bool? = nil) {
        guard !self.closing, !self.shutDown, self.scope == profile, PrivateProfileStorage.isReadable(profile) else { return }
        var items = self.snapshot.items; items[id] = status
        var automaticIDs = self.snapshot.automaticRecordingIDs
        if let automatic { if automatic { automaticIDs.insert(id) } else { automaticIDs.remove(id) } }
        if case let .accepted(receipt) = status, [.queued, .running].contains(receipt.analysisState) {
            if self.analysisPolls[id] == nil { self.analysisPolls[id] = (0, Date().addingTimeInterval(1)) }
        } else { self.analysisPolls.removeValue(forKey: id) }
        self.itemOrder.removeAll { $0 == id }; self.itemOrder.append(id)
        let visibleItems = self.bounded(items)
        self.snapshot = .init(availability: self.snapshot.availability,
            cloudSyncEnabled: self.snapshot.cloudSyncEnabled, items: visibleItems,
            deleteLocalAfterAcceptance: self.snapshot.deleteLocalAfterAcceptance,
            automaticRecordingIDs: automaticIDs.intersection(Set(visibleItems.keys)))
    }

    private func bounded(_ items: [MeetingSessionID: PichiCloudPublicationStatus]) -> [MeetingSessionID: PichiCloudPublicationStatus] {
        for id in items.keys where !self.itemOrder.contains(id) { self.itemOrder.append(id) }
        while self.itemOrder.count > 128 { self.analysisPolls.removeValue(forKey: self.itemOrder.removeFirst()) }
        let retained = Set(self.itemOrder)
        return items.filter { retained.contains($0.key) }
    }

    private static func status(_ record: PichiPublicationOutboxRecord) -> PichiCloudPublicationStatus {
        guard record.automaticConsent else { return .localOnly }
        switch record.state {
        case .waitingForSource: return .waitingForSource
        case .queued: return .queued
        case .sending: return .sending
        case .retryScheduled: return .retryScheduled(record.nextAttemptAt ?? .distantFuture)
        case .paused: return .paused(record.pauseReason ?? .receiptReview)
        case .accepted, .acceptedCleanupPending:
            guard let receipt = record.receipt else { return .paused(.receiptReview) }
            return record.receiptPauseReason.map { .acceptedNeedsReview(receipt, $0) } ?? .accepted(receipt)
        case .withheld: return record.withholdingReason.map(PichiCloudPublicationStatus.withheld) ?? .localOnly
        case .conflict: return .conflict
        }
    }

    private static func pauseReason(_ action: PichiPublicationRemoteAction) -> PichiPublicationPauseReason {
        switch action {
        case .stopAndShowValidation: return .validationRejected
        case .pauseForReauthentication: return .authenticationRequired
        case .pauseForAccountReview: return .accountReview
        case .pauseForPermissionReview: return .permissionReview
        case .pauseForConflictReview: return .sourceConflict
        case .pauseForReceiptReview, .boundedRetry: return .receiptReview
        }
    }

    private static func privateDirectory(_ url: URL) throws {
        let manager = FileManager.default
        guard url.standardizedFileURL.path == url.path, url.resolvingSymlinksInPath().path == url.path else { throw PichiPublicationOutboxFailure.invalidStorage }
        try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw PichiPublicationOutboxFailure.invalidStorage }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
