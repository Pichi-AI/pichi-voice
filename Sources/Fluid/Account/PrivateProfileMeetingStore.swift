import Foundation

nonisolated extension MeetingProfileOwnership {
    init(profile: PrivateProfileSnapshot) {
        profileID = profile.id; legacyOrigin = profile.context?.identity.legacyOrigin
        issuer = profile.context?.identity.isLegacySession == true ? nil : profile.context?.identity.issuer
        subject = profile.context?.identity.isLegacySession == true ? nil : profile.context?.identity.subject; internalUserID = profile.context?.identity.internalUserID
        organizationID = profile.context?.organizationID; workspaceID = profile.context?.workspaceID
    }

    func matches(_ profile: PrivateProfileSnapshot) -> Bool { self == Self(profile: profile) }
}

extension MeetingSessionStore {
    static let shared: any MeetingSessionStoring = PrivateProfileMeetingStore.shared
}

/// N5 receives this frozen source at recording admission, separately from its own consent snapshot.
nonisolated struct MeetingPrivateProfileAdmission: Sendable {
    let profile: PrivateProfileSnapshot
    var requiresEncryptedPersistence = false
    var ownership: MeetingProfileOwnership { .init(profile: profile) }
}

/// N5's local policy observer. These callbacks must remain bounded local operations, without
/// network/model work. Delivery failures must never prevent a local recording from being saved.
nonisolated protocol PrivateProfileRecordingObserver: AnyObject, Sendable {
    func captureAdmitted(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
    func prepareRequiredCapture(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async throws
    func prepareAutomaticCapture() async throws -> Bool
    func prepareCapturePersistencePolicy() async throws -> MeetingCapturePersistencePolicy
    func sourceDidPersist(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
    func captureAdmissionCancelled(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
}

extension PrivateProfileRecordingObserver {
    nonisolated func prepareAutomaticCapture() async throws -> Bool { false }
    nonisolated func prepareCapturePersistencePolicy() async throws -> MeetingCapturePersistencePolicy {
        let required = try await prepareAutomaticCapture()
        return .init(requiresEncryptedPersistence: required, requiresPIIRedaction: required)
    }
    nonisolated func prepareRequiredCapture(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async throws {
        throw CocoaError(.featureUnsupported)
    }
    nonisolated func captureAdmissionCancelled(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {}
}

/// Guest recordings belong to the device and remain visible alongside the selected account.
/// Account recordings and admitted capture writes retain their original immutable roots.
actor PrivateProfileMeetingStore: MeetingSessionStoring {
    static let shared = PrivateProfileMeetingStore(sharedGuestCipherProvider: {
        try await MeetingRecordingKeychainStore(namespace: MeetingRecordingKeychainStore.defaultNamespace)
            .load(profileID: MeetingProfileOwnership.guest.profileID)
    })
    private var stores: [String: MeetingSessionStore] = [:]
    private var admissions: [MeetingSessionID: MeetingPrivateProfileAdmission] = [:]
    // Composition owns the observer; retaining it here would form a facade/store cycle.
    private weak var recordingObserver: (any PrivateProfileRecordingObserver)?
    private var hasInstalledRecordingObserver = false
    private var encryptedProfiles = Set<String>()
    private let sharedGuestCipherProvider: (@Sendable () async throws -> MeetingRecordingCipher?)?
    private var preparedGuestReaderGeneration: UUID?

    /// Custom stores never access production Keychain. The production facade can restore only
    /// an existing device-guest key, without changing the account's key or creating a new one.
    init(sharedGuestCipherProvider: (@Sendable () async throws -> MeetingRecordingCipher?)? = nil) {
        self.sharedGuestCipherProvider = sharedGuestCipherProvider
    }

    func installRecordingObserver(_ observer: any PrivateProfileRecordingObserver) throws {
        guard recordingObserver == nil else { throw AccountError.busy }
        recordingObserver = observer
        hasInstalledRecordingObserver = true
    }

    private func currentRecordingObserver() throws -> (any PrivateProfileRecordingObserver)? {
        guard let observer = recordingObserver else {
            // Losing an installed policy owner must not silently select unprotected capture.
            guard !hasInstalledRecordingObserver else { throw AccountError.isolationRequired }
            return nil
        }
        return observer
    }

    /// Resolves the existing observer's secure-mode resource preflight before the
    /// platform builds its immutable capture configuration. No second policy owner.
    func prepareAutomaticCapture() async throws -> Bool {
        try await prepareCapturePersistencePolicy().requiresEncryptedPersistence
    }

    func prepareCapturePersistencePolicy() async throws -> MeetingCapturePersistencePolicy {
        let profile = try readableProfile()
        let observer = try currentRecordingObserver()
        let policy = try await observer?.prepareCapturePersistencePolicy() ?? .init()
        try checkReadable(profile)
        guard !policy.requiresEncryptedPersistence || encryptedProfiles.contains(profile.id) else {
            throw MeetingRecordingCipher.Failure.unavailableKey
        }
        return policy
    }

    func admission() throws -> MeetingPrivateProfileAdmission {
        let profile = PrivateProfileStorage.current
        guard profile.isReadable, PrivateProfileStorage.acceptsNewWork else { throw AccountError.busy }
        return .init(profile: profile)
    }

    func captureOwnership(for id: MeetingSessionID) async throws -> MeetingProfileOwnership? {
        try await captureOwnership(for: id, configuration: nil)
    }

    func captureOwnership(for id: MeetingSessionID, configuration: MeetingCaptureConfiguration) async throws -> MeetingProfileOwnership? {
        try await captureOwnership(for: id, configuration: Optional(configuration))
    }

    private func captureOwnership(for id: MeetingSessionID, configuration: MeetingCaptureConfiguration?) async throws -> MeetingProfileOwnership? {
        guard admissions[id] == nil else { throw AccountError.busy }
        // Keep this admission's observer alive through its joined local preflight.
        let observer = try currentRecordingObserver()
        var captured = try admission()
        captured.requiresEncryptedPersistence = configuration?.requiresEncryptedPersistence == true
        if captured.requiresEncryptedPersistence {
            guard encryptedProfiles.contains(captured.profile.id),
                  configuration?.audioStorageMode == .memoryOnly, observer != nil else {
                throw MeetingRecordingCipher.Failure.invalidConfiguration
            }
        }
        admissions[id] = captured
        do {
            if captured.requiresEncryptedPersistence {
                try await observer?.prepareRequiredCapture(id: id, admission: captured)
            } else { await observer?.captureAdmitted(id: id, admission: captured) }
            try checkReadable(captured.profile)
            return captured.ownership
        } catch {
            admissions.removeValue(forKey: id)
            await observer?.captureAdmissionCancelled(id: id, admission: captured)
            throw error
        }
    }

    /// Composition installs the off-main Keychain result before admitting a protected capture.
    func installEncryptionCipher(_ cipher: MeetingRecordingCipher, for profile: PrivateProfileSnapshot) async throws {
        guard PrivateProfileStorage.isReadable(profile), cipher.profileID == profile.id else { throw AccountError.staleOperation }
        try await store(for: profile).installEncryptionCipher(cipher)
        guard PrivateProfileStorage.isReadable(profile) else { throw AccountError.staleOperation }
        encryptedProfiles.insert(profile.id)
    }

    func hasEncryptedPersistenceData(in profile: PrivateProfileSnapshot) async throws -> Bool {
        guard PrivateProfileStorage.isReadable(profile) else { throw AccountError.staleOperation }
        let result = try await store(for: profile).hasEncryptedPersistenceData()
        guard PrivateProfileStorage.isReadable(profile) else { throw AccountError.staleOperation }
        return result
    }

    func cancelCaptureAdmission(for id: MeetingSessionID) async {
        guard let admitted = admissions[id],
              (try? await store(for: admitted.profile).load(id: id)) == nil else { return }
        admissions.removeValue(forKey: id)
        await recordingObserver?.captureAdmissionCancelled(id: id, admission: admitted)
    }

    func create(_ source: MeetingSession) async throws {
        let admitted = try admissions[source.id] ?? admission()
        var session = source
        if let owner = session.profileOwnership, !owner.matches(admitted.profile) { throw AccountError.staleOperation }
        session.profileOwnership = admitted.ownership
        guard (session.requiresEncryptedPersistence == true) == admitted.requiresEncryptedPersistence else { throw AccountError.staleOperation }
        admissions[session.id] = admitted
        do { try await store(for: admitted.profile).create(session) }
        catch {
            admissions.removeValue(forKey: session.id)
            if admitted.requiresEncryptedPersistence { await recordingObserver?.captureAdmissionCancelled(id: session.id, admission: admitted) }
            throw error
        }
    }

    func save(_ source: MeetingSession) async throws {
        let profile: PrivateProfileSnapshot
        if let admitted = admissions[source.id] {
            guard (source.requiresEncryptedPersistence == true) == admitted.requiresEncryptedPersistence else { throw AccountError.staleOperation }
            profile = admitted.profile
        } else {
            let reader = try readableProfile()
            guard let resolved = try await visibleSession(id: source.id, reader: reader, transcriptOnly: false),
                  source.profileOwnership?.matches(resolved.profile) == true
                    || (reader.isGuest && source.profileOwnership == nil && resolved.profile.isGuest)
            else { throw AccountError.staleOperation }
            try checkReadable(reader)
            profile = resolved.profile
        }
        guard profile.isGuest || source.profileOwnership != nil else { throw AccountError.staleOperation }
        if let owner = source.profileOwnership, !owner.matches(profile) { throw AccountError.staleOperation }
        var session = source
        // A shared guest edit keeps guest provenance; reading never rewrites the legacy file.
        session.profileOwnership = .init(profile: profile)
        try await store(for: profile).save(session)
        if session.state == .completed, let admitted = admissions[session.id] {
            await recordingObserver?.sourceDidPersist(id: session.id, admission: admitted)
        }
    }

    func load(id: MeetingSessionID) async throws -> MeetingSession? {
        let reader = try readableProfile()
        return try await visibleSession(id: id, reader: reader, transcriptOnly: false)?.session
    }

    func loadExistingSource(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership) async throws -> (session: MeetingSession, directory: URL)? {
        let reader = try readableProfile()
        guard let resolved = try await visibleSession(id: id, reader: reader, transcriptOnly: true) else { return nil }
        guard expectedOwnership.matches(resolved.profile) else { throw AccountError.staleOperation }
        // Resolve visibility once, then keep both full metadata and directory within that
        // exact source. A later account sibling cannot redirect the second half of the read.
        let source = try await store(for: resolved.profile).loadExistingSource(id: id, expectedOwnership: expectedOwnership)
        try checkReadable(reader)
        guard let source else { return nil }
        guard permits(source.session, in: resolved.profile) else { throw AccountError.staleOperation }
        return (projected(source.session, source: resolved.profile, reader: reader), source.directory)
    }

    /// History/transcript reads preserve the same owner fence without reopening or hashing audio.
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession? {
        let reader = try readableProfile()
        return try await visibleSession(id: id, reader: reader, transcriptOnly: true)?.session
    }

    func loadHistory() async throws -> [MeetingSession] {
        try await visibleCatalog(transcriptOnly: true)
    }

    func loadAll() async throws -> [MeetingSession] {
        try await visibleCatalog(transcriptOnly: false)
    }

    func loadHistoryForMaintenance() async throws -> [MeetingSession] {
        let profile = try readableProfile()
        let sessions = try await store(for: profile).loadHistory()
        try checkReadable(profile)
        return sessions.filter { permits($0, in: profile) }.map { session in
            var value = session
            // Maintenance can outlive this catalog read. Give legacy guest snapshots the
            // same explicit source pin as shared reads, without rewriting their manifests.
            if profile.isGuest, value.profileOwnership == nil { value.profileOwnership = .guest }
            return value
        }
    }

    func loadRecoverable() async throws -> [MeetingSession] {
        // Startup recovery rewrites state. Shared guest recordings stay available for explicit
        // user actions, without applying another profile's processing settings automatically.
        let profile = try readableProfile()
        let sessions = try await store(for: profile).loadRecoverable()
        try checkReadable(profile)
        return sessions.filter { permits($0, in: profile) }
    }

    func sessionDirectory(for id: MeetingSessionID) async throws -> URL {
        // Capture and final processing use this write-side path after create admission.
        if let admission = admissions[id] {
            return try await store(for: admission.profile).sessionDirectory(for: id)
        }
        let reader = try readableProfile()
        guard let resolved = try await visibleSession(id: id, reader: reader, transcriptOnly: false)
        else { throw AccountError.staleOperation }
        let directory = try await store(for: resolved.profile).sessionDirectory(for: id)
        try checkReadable(reader)
        return directory
    }

    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        let reader = try readableProfile()
        guard let resolved = try await visibleSession(id: id, reader: reader, transcriptOnly: false) else { return nil }
        let directory = try await store(for: resolved.profile).existingSessionDirectory(for: id)
        try checkReadable(reader)
        return directory
    }

    func delete(id: MeetingSessionID) async throws {
        let reader = try readableProfile()
        guard let resolved = try await visibleSession(id: id, reader: reader, transcriptOnly: false) else { return }
        try await delete(id: id, expectedOwnership: .init(profile: resolved.profile))
    }

    /// A frozen current-profile owner permits an idempotent cleanup retry even when a
    /// prior filesystem removal deleted the manifest before returning an error.
    func delete(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership) async throws {
        try await delete(id: id, expectedOwnership: expectedOwnership, validating: { _ in })
    }

    func delete(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership,
                validating: @Sendable (MeetingSession) throws -> Void) async throws {
        let reader = try readableProfile()
        let profile = try await deletionProfile(id: id, expectedOwnership: expectedOwnership, reader: reader)
        try await store(for: profile).delete(id: id, expectedOwnership: expectedOwnership, validating: { session in
            guard self.permits(session, in: profile) else { throw AccountError.staleOperation }
            try validating(session)
        })
        try checkReadable(reader)
        admissions.removeValue(forKey: id)
    }

    func deleteAudioFiles(for id: MeetingSessionID) async throws {
        let reader = try readableProfile()
        guard let resolved = try await visibleSession(id: id, reader: reader, transcriptOnly: false) else { return }
        try await deleteAudioFiles(for: id, expectedOwnership: .init(profile: resolved.profile))
        try checkReadable(reader)
    }

    func deleteAudioFiles(for id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership) async throws {
        let reader = try readableProfile()
        let profile = try await deletionProfile(id: id, expectedOwnership: expectedOwnership, reader: reader)
        try await store(for: profile).deleteAudioFiles(for: id, expectedOwnership: expectedOwnership)
        try checkReadable(reader)
    }

    /// Reload a terminal source using its original admission. Never resolve a replacement owner
    /// or return an in-memory coordinator copy. N5 separately evaluates consent/export eligibility.
    func persistedSource(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async throws -> MeetingSession {
        try checkReadable(admission.profile)
        guard let session = try await store(for: admission.profile).load(id: id),
              session.profileOwnership == admission.ownership else { throw AccountError.staleOperation }
        try checkReadable(admission.profile)
        return session
    }

    /// Lifecycle calls only after coordinator capture/finalization and private mutations join.
    func finishProfileTransition() {
        admissions.removeAll(); stores.removeAll(); encryptedProfiles.removeAll()
        preparedGuestReaderGeneration = nil
    }

    private func guestProfile(for reader: PrivateProfileSnapshot) -> PrivateProfileSnapshot {
        .init(id: MeetingProfileOwnership.guest.profileID, context: nil, generation: reader.generation,
            rootDirectory: reader.legacyRootDirectory, legacyRootDirectory: reader.legacyRootDirectory, isReadable: true)
    }

    private func sharedGuestStore(for reader: PrivateProfileSnapshot) async throws -> (PrivateProfileSnapshot, MeetingSessionStore) {
        let guest = guestProfile(for: reader)
        let target = store(for: guest)
        if preparedGuestReaderGeneration != reader.generation, let provider = sharedGuestCipherProvider {
            do {
                let cipher = try await provider()
                try checkReadable(reader)
                if let cipher {
                    guard cipher.profileID == guest.id else { throw MeetingRecordingCipher.Failure.unavailableKey }
                    try await target.installEncryptionCipher(cipher)
                    try checkReadable(reader)
                    preparedGuestReaderGeneration = reader.generation
                }
            } catch {
                try checkReadable(reader)
                // Each manifest enforces its own encryption. An unavailable protected sibling
                // must not make unrelated plaintext guest or account meetings disappear.
                DebugLogger.shared.warning("Shared guest recording key unavailable", source: "PrivateProfileMeetingStore")
            }
        }
        return (guest, target)
    }

    private nonisolated func projected(_ session: MeetingSession, source: PrivateProfileSnapshot,
                                      reader: PrivateProfileSnapshot) -> MeetingSession {
        var value = session
        // Explicit in-memory provenance lets later edits route to guest without adopting an
        // arbitrary ownerless account snapshot. The original manifest is untouched on read.
        if !reader.isGuest, source.isGuest, value.profileOwnership == nil { value.profileOwnership = .guest }
        return value
    }

    private func visibleSession(id: MeetingSessionID, reader: PrivateProfileSnapshot,
                                transcriptOnly: Bool) async throws -> (profile: PrivateProfileSnapshot, session: MeetingSession)? {
        let primary = store(for: reader)
        let own = try await transcriptOnly ? primary.loadTranscript(id: id) : primary.load(id: id)
        try checkReadable(reader)
        if let own {
            guard permits(own, in: reader) else { return nil }
            return (reader, own)
        }
        // UUID is the existing UI/API identity. The current profile has precedence, even if
        // its directory is incomplete or contains a foreign record. Never route around it.
        let ownDirectory = try await primary.existingSessionDirectory(for: id)
        try checkReadable(reader)
        guard !reader.isGuest, ownDirectory == nil else { return nil }
        let guest = guestProfile(for: reader)
        let guestDirectory = try await store(for: guest).existingSessionDirectory(for: id)
        try checkReadable(reader)
        guard guestDirectory != nil else { return nil }
        let (_, shared) = try await sharedGuestStore(for: reader)
        let session = try await transcriptOnly ? shared.loadTranscript(id: id) : shared.load(id: id)
        try checkReadable(reader)
        guard let session, permits(session, in: guest) else { return nil }
        return (guest, projected(session, source: guest, reader: reader))
    }

    private func visibleCatalog(transcriptOnly: Bool) async throws -> [MeetingSession] {
        let reader = try readableProfile()
        let primary = store(for: reader)
        let own = try await catalog(from: primary, reader: reader, transcriptOnly: transcriptOnly)
        var sessions = (own ?? []).filter { permits($0, in: reader) }
        guard !reader.isGuest else {
            guard own != nil else { throw MeetingSessionStoreError.historyUnavailable }
            return sessions
        }
        let (guest, shared) = try await sharedGuestStore(for: reader)
        let guests = try await catalog(from: shared, reader: reader, transcriptOnly: transcriptOnly)
        let ownIDs = Set((own ?? []).map(\.id))
        for session in guests ?? [] where !ownIDs.contains(session.id) && permits(session, in: guest) {
            let ownDirectory = try await primary.existingSessionDirectory(for: session.id)
            try checkReadable(reader)
            guard ownDirectory == nil else { continue }
            sessions.append(projected(session, source: guest, reader: reader))
        }
        guard !sessions.isEmpty || (own != nil && guests != nil) else {
            throw MeetingSessionStoreError.historyUnavailable
        }
        return sessions.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString < $1.id.uuidString : $0.startedAt > $1.startedAt
        }
    }

    private func catalog(from source: MeetingSessionStore, reader: PrivateProfileSnapshot,
                         transcriptOnly: Bool) async throws -> [MeetingSession]? {
        do {
            let sessions = try await transcriptOnly ? source.loadHistory() : source.loadAll()
            try checkReadable(reader)
            return sessions
        } catch {
            try checkReadable(reader)
            DebugLogger.shared.warning("One meeting history source is unavailable", source: "PrivateProfileMeetingStore")
            return nil
        }
    }

    private func deletionProfile(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership,
                                 reader: PrivateProfileSnapshot) async throws -> PrivateProfileSnapshot {
        let source: PrivateProfileSnapshot
        if expectedOwnership.matches(reader) {
            source = reader
        } else {
            guard !reader.isGuest, expectedOwnership == .guest else { throw AccountError.staleOperation }
            let ownDirectory = try await store(for: reader).existingSessionDirectory(for: id)
            try checkReadable(reader)
            guard ownDirectory == nil else { throw AccountError.staleOperation }
            (source, _) = try await sharedGuestStore(for: reader)
        }
        if let existing = try await store(for: source).load(id: id) {
            guard permits(existing, in: source), expectedOwnership.matchesPersistedOwner(existing.profileOwnership)
            else { throw AccountError.staleOperation }
        }
        try checkReadable(reader)
        return source
    }

    private func store(for profile: PrivateProfileSnapshot) -> MeetingSessionStore {
        if let existing = stores[profile.id] { return existing }
        let store = MeetingSessionStore(rootDirectory: profile.directory("Meetings"),
            automaticTitleOwnership: .init(profile: profile))
        stores[profile.id] = store
        return store
    }
    private func readableProfile() throws -> PrivateProfileSnapshot {
        let profile = PrivateProfileStorage.current
        guard profile.isReadable, PrivateProfileStorage.acceptsNewWork else { throw AccountError.busy }
        return profile
    }
    private func checkReadable(_ expected: PrivateProfileSnapshot) throws {
        try Task.checkCancellation()
        let current = PrivateProfileStorage.current
        guard current.isReadable, PrivateProfileStorage.acceptsNewWork,
              current.id == expected.id, current.generation == expected.generation
        else { throw AccountError.staleOperation }
    }
    private nonisolated func permits(_ session: MeetingSession, in profile: PrivateProfileSnapshot) -> Bool {
        if let ownership = session.profileOwnership { return ownership.matches(profile) }
        return profile.isGuest
    }
}
