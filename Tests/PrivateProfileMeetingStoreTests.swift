import CryptoKit
import Foundation

extension MeetingSessionStoreCheckpointTests {
    static func checkPrivateProfileMeetingStore(root: URL, check: (Bool, String) -> Void) async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        func account(_ subject: String, workspace: String = "workspace") throws -> PrivateProfileSnapshot {
            try PrivateProfileStorage.proposed(context: .init(identity: .init(issuer: "https://identity.invalid/realms/synthetic",
                subject: subject, internalUserID: "user-" + subject), organizationID: "organization",
                workspaceID: workspace, generation: UUID()), generation: UUID(), legacyRootDirectory: root)
        }
        let a = try account("A/../../escape"), b = try account("B"), otherWorkspace = try account("A/../../escape", workspace: "other")
        check(a.id != b.id && a.id != otherWorkspace.id && a.id.count == 64,
            "Verified identity/workspace scopes must have distinct bounded opaque keys")
        check(!a.rootDirectory.path.contains("escape") && a.rootDirectory.deletingLastPathComponent().lastPathComponent == "Profiles",
            "Remote identity strings cannot become filesystem paths")
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        let id = UUID()
        var legacy = MeetingSession(id: id, configuration: .init(mode: .inRoom, title: "Synthetic guest",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")), timebase: timebase)
        legacy.state = .completed
        legacy.transcriptTimeDomain = .meetingRelative
        legacy.audioStorageMode = .memoryOnly
        legacy.audioTracks = [.init(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])]
        let legacyStore = MeetingSessionStore(rootDirectory: guest.directory("Meetings"))
        try await legacyStore.create(legacy)
        let legacyURL = guest.directory("Meetings").appendingPathComponent(id.uuidString).appendingPathComponent("session.json")
        let before = try Data(contentsOf: legacyURL)
        let store = PrivateProfileMeetingStore()
        PrivateProfileStorage.select(guest)
        let loadedGuest = try await store.load(id: id)
        check(loadedGuest?.profileOwnership == nil && loadedGuest?.title == legacy.title,
            "Legacy unowned history stays readable as guest without attribution")
        await store.finishProfileTransition()
        PrivateProfileStorage.select(a)
        let aHistory = try await store.loadAll()
        check(aHistory.isEmpty, "First account login cannot claim or list legacy guest history")
        var aSession = legacy
        aSession.title = "Synthetic account A"
        aSession.profileOwnership = try await store.captureOwnership(for: id)
        let aAdmission = try await store.admission()
        try await store.create(aSession)
        let savedA = try await store.load(id: id)!
        check(savedA.profileOwnership?.matches(a) == true, "Account ownership is persisted at admission")
        check(try Data(contentsOf: legacyURL) == before, "Account admission must preserve original guest manifest bytes")

        // Logout can conceal account data immediately while the admitted writer drains locally.
        PrivateProfileStorage.conceal(generation: UUID())
        do { _ = try await store.loadAll(); check(false, "Concealed history must reject reads") }
        catch { check(true, "Concealed history rejects new reads") }
        aSession.title = "Synthetic A finalization"
        try await store.save(aSession)
        let pinnedDirectory = try await store.sessionDirectory(for: id)
        check(pinnedDirectory.path.hasPrefix(a.rootDirectory.path + "/"),
            "Logout finalization keeps the admitted writer in A's immutable root")
        do { _ = try await store.existingSessionDirectory(for: id); check(false, "Concealed playback/export must reject directory reads") }
        catch { check(true, "Concealed playback/export directory is unavailable") }

        await store.finishProfileTransition()
        PrivateProfileStorage.select(b)
        check(try await store.load(id: id) == nil, "B cannot read A or guest by a known UUID")
        var bSession = legacy
        bSession.title = "Synthetic account B"
        bSession.profileOwnership = try await store.captureOwnership(for: id)
        try await store.create(bSession)
        do { try await store.save(savedA); check(false, "An old A snapshot cannot overwrite B's same-UUID session") }
        catch { check(true, "Stale explicit owner is rejected") }
        var unownedA = savedA; unownedA.profileOwnership = nil
        do { try await store.save(unownedA); check(false, "Missing account ownership cannot become B-owned at save") }
        catch { check(true, "Missing account ownership is rejected") }
        do { _ = try await store.persistedSource(id: id, admission: aAdmission); check(false, "N5 may not reload A's source as B") }
        catch { check(true, "Owner-bound source reload rejects another account") }
        check(try await store.load(id: id)?.title == bSession.title, "Rejected A writes preserve B's manifest")
        await store.finishProfileTransition()
        PrivateProfileStorage.select(a)
        check(try await store.load(id: id)?.title == aSession.title, "A's admitted finalization survives logout and return")
        let staleGeneration = PrivateProfileSnapshot(id: a.id, context: a.context, generation: UUID(),
            rootDirectory: a.rootDirectory, legacyRootDirectory: a.legacyRootDirectory, isReadable: true)
        check(!PrivateProfileStorage.isReadable(staleGeneration), "Same-profile stale generations fail closed")
        await store.finishProfileTransition()
        PrivateProfileStorage.select(guest)
        check(try await store.load(id: id)?.profileOwnership == nil, "Guest is not assigned after A/logout/B/logout")
        check(try Data(contentsOf: legacyURL) == before, "Guest source hash remains unchanged after all profile transitions")
        try PrivateProfileStorage.persistAccessMarker(guest)
        let markerURL = root.appendingPathComponent("Profiles/active-profile-v1.json")
        let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as! [String: Any]
        check(marker["profileID"] as? String == "guest" && marker["isReadable"] as? Bool == true,
            "Atomic helper marker selects only the visible guest profile")
    }
}
