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
    var ownership: MeetingProfileOwnership { .init(profile: profile) }
}

/// N5's local policy observer. These callbacks must remain bounded local operations, without
/// network/model work. Delivery failures must never prevent a local recording from being saved.
nonisolated protocol PrivateProfileRecordingObserver: Sendable {
    func captureAdmitted(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
    func sourceDidPersist(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
    func captureAdmissionCancelled(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async
}

extension PrivateProfileRecordingObserver {
    nonisolated func captureAdmissionCancelled(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {}
}

/// One adapter for existing callers. Reads follow the visible profile; admitted capture writes
/// retain their original immutable root even when logout conceals that profile.
actor PrivateProfileMeetingStore: MeetingSessionStoring {
    static let shared = PrivateProfileMeetingStore()
    private var stores: [String: MeetingSessionStore] = [:]
    private var admissions: [MeetingSessionID: MeetingPrivateProfileAdmission] = [:]
    private var recordingObserver: (any PrivateProfileRecordingObserver)?

    func installRecordingObserver(_ observer: any PrivateProfileRecordingObserver) throws {
        guard recordingObserver == nil else { throw AccountError.busy }
        recordingObserver = observer
    }

    func admission() throws -> MeetingPrivateProfileAdmission {
        let profile = PrivateProfileStorage.current
        guard profile.isReadable, PrivateProfileStorage.acceptsNewWork else { throw AccountError.busy }
        return .init(profile: profile)
    }

    func captureOwnership(for id: MeetingSessionID) async throws -> MeetingProfileOwnership? {
        guard admissions[id] == nil else { throw AccountError.busy }
        let captured = try admission()
        admissions[id] = captured
        await recordingObserver?.captureAdmitted(id: id, admission: captured)
        return captured.ownership
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
        admissions[session.id] = admitted
        do { try await store(for: admitted.profile).create(session) }
        catch { admissions.removeValue(forKey: session.id); throw error }
    }

    func save(_ source: MeetingSession) async throws {
        let profile: PrivateProfileSnapshot
        if let admitted = admissions[source.id] {
            profile = admitted.profile
        } else {
            profile = try readableProfile()
            guard let existing = try await store(for: profile).load(id: source.id), permits(existing, in: profile)
            else { throw AccountError.staleOperation }
            try checkReadable(profile)
        }
        guard profile.isGuest || source.profileOwnership != nil else { throw AccountError.staleOperation }
        if let owner = source.profileOwnership, !owner.matches(profile) { throw AccountError.staleOperation }
        var session = source
        // Older guest manifests gain only an explicit guest marker, never the next login's owner.
        session.profileOwnership = .init(profile: profile)
        try await store(for: profile).save(session)
        if session.state == .completed, let admitted = admissions[session.id] {
            await recordingObserver?.sourceDidPersist(id: session.id, admission: admitted)
        }
    }

    func load(id: MeetingSessionID) async throws -> MeetingSession? {
        let profile = try readableProfile()
        let session = try await store(for: profile).load(id: id)
        try checkReadable(profile)
        guard let session, permits(session, in: profile) else { return nil }
        return session
    }

    /// History/transcript reads preserve the same owner fence without reopening or hashing audio.
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession? {
        let profile = try readableProfile()
        let session = try await store(for: profile).loadTranscript(id: id)
        try checkReadable(profile)
        guard let session, permits(session, in: profile) else { return nil }
        return session
    }

    func loadHistory() async throws -> [MeetingSession] {
        let profile = try readableProfile()
        let sessions = try await store(for: profile).loadHistory()
        try checkReadable(profile)
        return sessions.filter { permits($0, in: profile) }
    }

    func loadAll() async throws -> [MeetingSession] {
        let profile = try readableProfile()
        let sessions = try await store(for: profile).loadAll()
        try checkReadable(profile)
        return sessions.filter { permits($0, in: profile) }
    }

    func loadRecoverable() async throws -> [MeetingSession] {
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
        let profile = try readableProfile()
        guard let session = try await store(for: profile).load(id: id), permits(session, in: profile)
        else { throw AccountError.staleOperation }
        try checkReadable(profile)
        return try await store(for: profile).sessionDirectory(for: id)
    }

    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        let profile = try readableProfile()
        guard let session = try await store(for: profile).load(id: id), permits(session, in: profile) else { return nil }
        let directory = try await store(for: profile).existingSessionDirectory(for: id)
        try checkReadable(profile)
        return directory
    }

    func delete(id: MeetingSessionID) async throws {
        let profile = try readableProfile()
        guard let session = try await store(for: profile).load(id: id), permits(session, in: profile) else { return }
        try checkReadable(profile)
        try await store(for: profile).delete(id: id)
        admissions.removeValue(forKey: id)
    }

    func deleteAudioFiles(for id: MeetingSessionID) async throws {
        let profile = try readableProfile()
        guard let session = try await store(for: profile).load(id: id), permits(session, in: profile) else { return }
        try checkReadable(profile)
        try await store(for: profile).deleteAudioFiles(for: id)
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
    func finishProfileTransition() { admissions.removeAll(); stores.removeAll() }

    private func store(for profile: PrivateProfileSnapshot) -> MeetingSessionStore {
        if let existing = stores[profile.id] { return existing }
        let store = MeetingSessionStore(rootDirectory: profile.directory("Meetings"))
        stores[profile.id] = store
        return store
    }
    private func readableProfile() throws -> PrivateProfileSnapshot {
        let profile = PrivateProfileStorage.current
        guard profile.isReadable, PrivateProfileStorage.acceptsNewWork else { throw AccountError.busy }
        return profile
    }
    private func checkReadable(_ expected: PrivateProfileSnapshot) throws {
        let current = PrivateProfileStorage.current
        guard current.isReadable, PrivateProfileStorage.acceptsNewWork,
              current.id == expected.id, current.generation == expected.generation
        else { throw AccountError.staleOperation }
    }
    private func permits(_ session: MeetingSession, in profile: PrivateProfileSnapshot) -> Bool {
        if let ownership = session.profileOwnership { return ownership.matches(profile) }
        return profile.isGuest
    }
}
