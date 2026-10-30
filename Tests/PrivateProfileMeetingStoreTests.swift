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
        check(aHistory.count == 1 && aHistory.first?.id == id
              && aHistory.first?.profileOwnership?.matches(guest) == true,
            "First account login lists shared guest history with guest provenance, never account ownership")
        check(try await store.loadHistoryForMaintenance().isEmpty,
            "An account's automatic maintenance cannot apply its policy to shared guest history")
        var aSession = legacy
        aSession.title = "Synthetic account A"
        aSession.profileOwnership = try await store.captureOwnership(for: id)
        let aAdmission = try await store.admission()
        try await store.create(aSession)
        let savedA = try await store.load(id: id)!
        check(savedA.profileOwnership?.matches(a) == true, "Account ownership is persisted at admission")
        check(try await store.loadHistory().map(\.id) == [id],
            "A same-UUID account record takes precedence without duplicate catalog identities")
        var shadowedGuest = aHistory[0]
        shadowedGuest.title = "Rejected shadowed guest edit"
        do { try await store.save(shadowedGuest); check(false, "A shadowed guest snapshot cannot overwrite a same-UUID account record") }
        catch { check(true, "Current-owner UUID precedence rejects a shadowed guest save") }
        do { try await store.delete(id: id, expectedOwnership: .init(profile: guest)); check(false, "Pinned guest deletion cannot select a colliding account record") }
        catch { check(true, "Current-owner UUID precedence rejects shadowed guest deletion") }
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
        let bGuest = try await store.load(id: id)
        check(bGuest?.title == legacy.title && bGuest?.profileOwnership?.matches(guest) == true,
            "B reads the shared guest sibling while A's same-UUID record stays private")
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

        try await checkSharedGuestLibrary(root: root.appendingPathComponent("shared-library"), check: check)
        try await checkSharedGuestCipherGeneration(root: root.appendingPathComponent("shared-cipher"), check: check)
        try await checkOwnerBoundExistingSource(root: root.appendingPathComponent("playback-source"), check: check)
    }

    private static func checkOwnerBoundExistingSource(root: URL, check: (Bool, String) -> Void) async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        let account = try PrivateProfileStorage.proposed(context: .init(identity: .init(
            issuer: "https://identity.invalid/playback", subject: "source", internalUserID: "source"),
            organizationID: "organization", workspaceID: "workspace", generation: UUID()),
            generation: UUID(), legacyRootDirectory: root)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var legacy = MeetingSession(configuration: .init(mode: .inRoom, title: "Original guest playback",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")), timebase: timebase)
        legacy.state = .completed; legacy.transcriptTimeDomain = .meetingRelative
        legacy.audioTracks = [.init(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])]
        legacy.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
            end: .init(value: 1, timescale: 1), sourceTrackID: legacy.audioTracks[0].id, speakerID: nil,
            text: "Original source words", revision: 0, status: .final, overlap: .none, completeness: .complete)]
        let guestStore = MeetingSessionStore(rootDirectory: guest.directory("Meetings"))
        let accountStore = MeetingSessionStore(rootDirectory: account.directory("Meetings"))
        try await guestStore.create(legacy)
        let guestDirectory = guest.directory("Meetings").appendingPathComponent(legacy.id.uuidString)
        let concrete = try await guestStore.loadExistingSource(id: legacy.id, expectedOwnership: .guest)
        let existential: any MeetingSessionStoring = guestStore
        let protocolRead = try await existential.loadExistingSource(id: legacy.id, expectedOwnership: .guest)
        check(concrete?.session.id == legacy.id && protocolRead?.session.id == legacy.id
              && concrete?.directory == protocolRead?.directory,
            "Concrete and protocol calls use the actual async atomic source witness, never the unsupported default")
        let originalBytes = try Data(contentsOf: guestDirectory.appendingPathComponent("session.json"))
        PrivateProfileStorage.select(account)
        let initial = PrivateProfileMeetingStore()
        let displayed = try await initial.loadTranscript(id: legacy.id)!
        check(displayed.profileOwnership == .guest && displayed.resultSidecarReference == nil,
            "Displayed legacy guest playback has explicit source ownership without requiring a sidecar")
        var replacement = legacy
        replacement.profileOwnership = .init(profile: account); replacement.title = "Colliding account source"
        let frozenReplacement = replacement
        // The existing key-provider suspension is after account-root visibility was checked,
        // and before the chosen guest source returns. Insert the collision at that exact seam.
        let racing = PrivateProfileMeetingStore(sharedGuestCipherProvider: {
            try await accountStore.create(frozenReplacement)
            return nil
        })
        let paired = try await racing.loadExistingSource(id: displayed.id, expectedOwnership: .guest)
        check(paired?.session.title == legacy.title && paired?.session.profileOwnership == .guest
              && paired?.directory.standardizedFileURL == guestDirectory.standardizedFileURL,
            "An in-flight guest source read keeps metadata and directory in the same owner root")
        check(try await accountStore.loadTranscript(id: legacy.id)?.title == replacement.title,
            "The deterministic collision exists before the paired source read finishes")
        let independentlyResolved = try await initial.existingSessionDirectory(for: legacy.id)
        check(independentlyResolved?.standardizedFileURL != guestDirectory.standardizedFileURL,
            "The old split-directory lookup would now select the account sibling")
        do {
            _ = try await racing.loadExistingSource(id: displayed.id, expectedOwnership: .guest)
            check(false, "A stale displayed guest cannot retarget before its first source lookup")
        } catch { check(true, "A before-first-read account collision rejects the displayed guest ownership") }
        let current = try await racing.loadExistingSource(id: replacement.id, expectedOwnership: .init(profile: account))
        check(current?.session.title == replacement.title
              && current?.directory.standardizedFileURL == independentlyResolved?.standardizedFileURL,
            "A freshly displayed account source still reads its own matching directory")
        let guestMarker = guestDirectory.appendingPathComponent("tracks/source-marker.bin")
        let accountMarker = account.directory("Meetings").appendingPathComponent(legacy.id.uuidString)
            .appendingPathComponent("tracks/source-marker.bin")
        let guestAudio = Data("synthetic guest audio".utf8), accountAudio = Data("synthetic private audio".utf8)
        try guestAudio.write(to: guestMarker); try accountAudio.write(to: accountMarker)
        do {
            try await racing.deleteAudioFiles(for: displayed.id, expectedOwnership: .guest)
            check(false, "A stale guest audio deletion cannot select the account directory")
        } catch { check(true, "Pinned guest audio deletion rejects a colliding current source") }
        check(try Data(contentsOf: guestMarker) == guestAudio && Data(contentsOf: accountMarker) == accountAudio,
            "Rejected owner-bound audio removal preserves both roots' original bytes")
        check(try Data(contentsOf: guestDirectory.appendingPathComponent("session.json")) == originalBytes,
            "Owner-bound playback resolution never rewrites the original legacy guest manifest")
    }

    private static func checkSharedGuestLibrary(root: URL, check: (Bool, String) -> Void) async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let manager = FileManager.default
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        func account(_ subject: String, workspace: String = "workspace") throws -> PrivateProfileSnapshot {
            try PrivateProfileStorage.proposed(context: .init(identity: .init(issuer: "https://identity.invalid/shared",
                subject: subject, internalUserID: "shared-" + subject), organizationID: "organization",
                workspaceID: workspace, generation: UUID()), generation: UUID(), legacyRootDirectory: root)
        }
        let a = try account("A"), b = try account("B"), workspace = try account("A", workspace: "other")
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        func source(_ title: String, owner: PrivateProfileSnapshot?, offset: TimeInterval) -> MeetingSession {
            var value = MeetingSession(configuration: .init(mode: .inRoom, title: title,
                microphone: .init(captureDeviceID: "synthetic-shared", displayName: "Synthetic")),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset), timebase: timebase)
            value.state = .completed; value.endedAt = value.startedAt.addingTimeInterval(5)
            value.transcriptTimeDomain = .meetingRelative; value.audioStorageMode = .retainedFiles
            value.profileOwnership = owner.map { .init(profile: $0) }
            let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic-shared",
                sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])
            value.audioTracks = [track]
            value.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
                end: .init(value: 1, timescale: 1), sourceTrackID: track.id, speakerID: nil,
                text: "Synthetic shared guest sentence.", revision: 0, status: .final,
                overlap: .none, completeness: .complete, attributionState: .unassigned)]
            return value
        }
        let legacy = source("Shared legacy guest", owner: nil, offset: 0)
        let explicit = source("Shared explicit guest", owner: guest, offset: 1)
        var interrupted = source("Shared interrupted guest", owner: nil, offset: 2)
        interrupted.state = .interrupted
        let ownedA = source("Private A only", owner: a, offset: 10)
        let ownedB = source("Private B only", owner: b, offset: 20)
        let ownedWorkspace = source("Private other workspace", owner: workspace, offset: 30)
        let guestStore = MeetingSessionStore(rootDirectory: guest.directory("Meetings"))
        let aStore = MeetingSessionStore(rootDirectory: a.directory("Meetings"))
        let bStore = MeetingSessionStore(rootDirectory: b.directory("Meetings"))
        let workspaceStore = MeetingSessionStore(rootDirectory: workspace.directory("Meetings"))
        for session in [legacy, explicit, interrupted] { try await guestStore.create(session) }
        try await aStore.create(ownedA); try await bStore.create(ownedB); try await workspaceStore.create(ownedWorkspace)
        func manifest(_ profile: PrivateProfileSnapshot, _ id: MeetingSessionID) -> URL {
            profile.directory("Meetings").appendingPathComponent(id.uuidString).appendingPathComponent("session.json")
        }
        let guestBefore = try Data(contentsOf: manifest(guest, legacy.id))
        let explicitBefore = try Data(contentsOf: manifest(guest, explicit.id))
        let privateABefore = try Data(contentsOf: manifest(a, ownedA.id))
        let store = PrivateProfileMeetingStore()
        let guestIDs = Set([legacy.id, explicit.id, interrupted.id])
        for (profile, privateID) in [(a, ownedA.id), (b, ownedB.id), (workspace, ownedWorkspace.id)] {
            await store.finishProfileTransition(); PrivateProfileStorage.select(profile)
            let expected = guestIDs.union([privateID])
            check(Set(try await store.loadHistory().map(\.id)) == expected,
                "Every account/workspace catalog contains the shared guests plus only its own private meeting")
            check(Set(try await store.loadAll().map(\.id)) == expected,
                "Full API reads follow the same shared guest visibility as native History")
            check(try await store.loadHistoryForMaintenance().map(\.id) == [privateID],
                "Automatic audio maintenance is limited to the selected account's own storage")
            check(try await store.loadRecoverable().isEmpty,
                "Account startup cannot automatically recover or rewrite an interrupted shared guest")
            let loaded = try await store.loadTranscript(id: legacy.id)
            check(loaded?.title == legacy.title && loaded?.profileOwnership?.matches(guest) == true,
                "Lightweight shared legacy reads carry explicit guest provenance without adopting the account")
            for foreign in [ownedA, ownedB, ownedWorkspace] where foreign.id != privateID {
                let foreignSession = try await store.load(id: foreign.id)
                let foreignTranscript = try await store.loadTranscript(id: foreign.id)
                check(foreignSession == nil && foreignTranscript == nil,
                    "A foreign account/workspace meeting stays inaccessible even with its exact UUID")
                check(try await store.existingSessionDirectory(for: foreign.id) == nil,
                    "Foreign account UUIDs cannot expose playback or export directories")
                do { _ = try await store.sessionDirectory(for: foreign.id); check(false, "A foreign UUID cannot obtain a writable recording directory") }
                catch { check(true, "Foreign recording directory resolution rejects access") }
            }
        }
        check(try Data(contentsOf: manifest(guest, legacy.id)) == guestBefore
              && Data(contentsOf: manifest(guest, explicit.id)) == explicitBefore,
            "Shared catalog/transcript reads never rewrite or move guest source bytes")

        await store.finishProfileTransition(); PrivateProfileStorage.select(a)
        var edited = try await store.loadTranscript(id: legacy.id)!
        edited.title = "Guest edited from A"; edited.transcriptSegments[0].text = "Shared edit remains guest-owned."
        try await store.save(edited)
        let storedEdit = try await guestStore.loadTranscript(id: legacy.id)
        check(storedEdit?.title == edited.title && storedEdit?.profileOwnership?.matches(guest) == true,
            "Editing a shared legacy meeting persists in its original guest root with guest ownership")
        check(!manager.fileExists(atPath: manifest(a, legacy.id).path),
            "A guest edit must not create an account copy")
        let guestDirectory = guest.directory("Meetings").appendingPathComponent(legacy.id.uuidString)
        let tracks = guestDirectory.appendingPathComponent("tracks")
        try Data("synthetic disposable audio bytes".utf8).write(to: tracks.appendingPathComponent("synthetic.bin"))
        let writeDirectory = try await store.sessionDirectory(for: legacy.id)
        let readDirectory = try await store.existingSessionDirectory(for: legacy.id)
        check(writeDirectory.standardizedFileURL.path == guestDirectory.standardizedFileURL.path
              && readDirectory?.standardizedFileURL.path == guestDirectory.standardizedFileURL.path,
            "Shared playback/export and write-side paths resolve the original guest directory")
        await store.finishProfileTransition(); PrivateProfileStorage.select(b)
        check(try await store.loadTranscript(id: legacy.id)?.transcriptSegments == edited.transcriptSegments,
            "A guest edit made from A is visible from B without transferring ownership")
        try await store.deleteAudioFiles(for: legacy.id)
        check(!manager.fileExists(atPath: tracks.path) && manager.fileExists(atPath: manifest(guest, legacy.id).path),
            "Deleting guest audio from B removes only original guest audio and keeps the transcript")
        do { try await store.save(ownedA); check(false, "B cannot save a known A-only record") }
        catch { check(true, "Known foreign-owner snapshots remain rejected") }
        try await store.delete(id: ownedA.id)
        try await store.deleteAudioFiles(for: ownedA.id)
        do { try await store.delete(id: ownedA.id, expectedOwnership: .init(profile: a)); check(false, "B cannot delete A using pinned A ownership") }
        catch { check(true, "Foreign expected-ownership deletion stays fenced") }
        check(try Data(contentsOf: manifest(a, ownedA.id)) == privateABefore,
            "Foreign read/write/delete attempts leave A's original manifest unchanged")

        let interruptedBefore = try Data(contentsOf: manifest(guest, interrupted.id))
        do {
            try await store.delete(id: interrupted.id, expectedOwnership: .init(profile: guest), validating: { _ in
                throw CocoaError(.fileWriteNoPermission)
            })
            check(false, "A failed atomic validator cannot delete a shared legacy guest")
        } catch { check(true, "Shared guest deletion preserves the atomic validator") }
        check(try Data(contentsOf: manifest(guest, interrupted.id)) == interruptedBefore,
            "Failed guest deletion preserves the original unowned manifest bytes")
        let expectedInterruptedTitle = interrupted.title
        try await store.delete(id: interrupted.id, expectedOwnership: .init(profile: guest), validating: { session in
            guard session.title == expectedInterruptedTitle else { throw CocoaError(.fileWriteNoPermission) }
        })
        try await store.delete(id: interrupted.id, expectedOwnership: .init(profile: guest))
        check(try await guestStore.load(id: interrupted.id) == nil,
            "Pinned shared deletion supports legacy ownerless source bytes and is idempotent")
        var replacementB = ownedB; replacementB.id = interrupted.id; replacementB.title = "New private B sibling"
        try await bStore.create(replacementB)
        do { try await store.delete(id: interrupted.id, expectedOwnership: .init(profile: guest)); check(false, "A repeated guest delete cannot fall through to a new account sibling") }
        catch { check(true, "Repeated guest deletion rejects a colliding account replacement") }
        check(try await bStore.loadTranscript(id: replacementB.id)?.title == replacementB.title,
            "The account replacement survives repeated pinned guest deletion")

        // A current-root directory is authoritative even if its manifest cannot be used.
        let shadowDirectory = b.directory("Meetings").appendingPathComponent(explicit.id.uuidString)
        try manager.createDirectory(at: shadowDirectory, withIntermediateDirectories: true)
        let shadowManifest = shadowDirectory.appendingPathComponent("session.json")
        try Data("invalid current-profile manifest".utf8).write(to: shadowManifest)
        do { _ = try await store.loadTranscript(id: explicit.id); check(false, "A corrupt current record must not fall through to guest") }
        catch { check(true, "A corrupt current UUID fails closed instead of selecting a guest sibling") }
        check(!(try await store.loadHistory()).contains { $0.id == explicit.id },
            "The merged catalog suppresses a guest UUID shadowed by an unreadable current record")
        var foreignShadow = ownedA; foreignShadow.id = explicit.id
        foreignShadow.defaultTitleBase = "Meeting"
        foreignShadow.endedAt = foreignShadow.startedAt.addingTimeInterval(MeetingAutomaticNaming.minimumDuration)
        let shadowTrackID = foreignShadow.audioTracks[0].id
        foreignShadow.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
            end: .init(value: 1_800, timescale: 1), sourceTrackID: shadowTrackID, speakerID: nil,
            text: String(repeating: "Я думаю о вопросе, почему возникает этот вопрос. ", count: 60),
            revision: 0, status: .final, overlap: .none, completeness: .complete)]
        try await bStore.save(foreignShadow)
        let foreignTitleBytes = try Data(contentsOf: shadowManifest)
        check(try await store.load(id: explicit.id) == nil,
            "A foreign-owned current-root record cannot expose its guest sibling through fallback")
        check(!(try await store.loadHistory()).contains { $0.id == explicit.id },
            "Current-root ownership failure does not create duplicate or substituted guest rows")
        check(try Data(contentsOf: shadowManifest) == foreignTitleBytes,
            "Rejecting a long default-named foreign shadow cannot migrate its title before ownership filtering")
        var forgedGuest = explicit; forgedGuest.title = "Rejected shadowed guest write"
        do { try await store.save(forgedGuest); check(false, "An explicit guest snapshot cannot bypass current-root collision precedence") }
        catch { check(true, "Guest mutation rejects a foreign-owned colliding current-root record") }
        try await store.delete(id: explicit.id)
        check(try Data(contentsOf: manifest(guest, explicit.id)) == explicitBefore,
            "Collision rejection and no-op deletion preserve the shared guest original")

        try await store.delete(id: legacy.id)
        await store.finishProfileTransition(); PrivateProfileStorage.select(a)
        check(try await store.loadTranscript(id: legacy.id) == nil,
            "Deleting a unique shared guest from B is reflected when A reloads")
        await store.finishProfileTransition(); PrivateProfileStorage.select(guest)
        check(Set(try await store.loadHistory().map(\.id)) == [explicit.id],
            "Guest mode sees its surviving guest record and no account or workspace records")
        check(try Data(contentsOf: manifest(a, ownedA.id)) == privateABefore,
            "Shared guest edits and deletions never change private A data")
    }

    private static func checkSharedGuestCipherGeneration(root: URL, check: (Bool, String) -> Void) async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        func account(_ subject: String) throws -> PrivateProfileSnapshot {
            try PrivateProfileStorage.proposed(context: .init(identity: .init(issuer: "https://identity.invalid/cipher",
                subject: subject, internalUserID: subject), organizationID: "organization",
                workspaceID: "workspace", generation: UUID()), generation: UUID(), legacyRootDirectory: root)
        }
        let a = try account("A"), b = try account("B")
        let cipher = try MeetingRecordingCipher(profileID: guest.id, key: Data(repeating: 0x43, count: 32))
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var source = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic protected guest",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")), timebase: timebase)
        source.audioStorageMode = .memoryOnly; source.requiresEncryptedPersistence = true
        source.profileOwnership = .init(profile: guest)
        let writer = MeetingSessionStore(rootDirectory: guest.directory("Meetings"), encryptionCipher: cipher)
        try await writer.create(source)
        let manifest = guest.directory("Meetings").appendingPathComponent(source.id.uuidString).appendingPathComponent("session.json")
        let bytes = try Data(contentsOf: manifest)
        var plainGuest = source
        plainGuest.id = UUID(); plainGuest.requiresEncryptedPersistence = nil; plainGuest.profileOwnership = nil
        plainGuest.title = "Ordinary guest next to unavailable ciphertext"
        try await writer.create(plainGuest)
        var own = plainGuest
        own.id = UUID(); own.profileOwnership = .init(profile: a); own.title = "Ordinary account meeting"
        let accountWriter = MeetingSessionStore(rootDirectory: a.directory("Meetings"))
        try await accountWriter.create(own)
        PrivateProfileStorage.select(a)
        let noKey = PrivateProfileMeetingStore()
        do { _ = try await noKey.loadTranscript(id: source.id); check(false, "Missing guest key cannot become plaintext or successful absent history") }
        catch { check(true, "Missing guest-key shared reads fail without inventing a replacement") }
        check(try await noKey.loadTranscript(id: plainGuest.id)?.title == plainGuest.title,
            "An unavailable encrypted guest sibling cannot block an ordinary guest transcript")
        check(Set(try await noKey.loadHistory().map(\.id)) == [plainGuest.id, own.id],
            "An unavailable guest key preserves healthy account and ordinary guest catalog rows")
        try await writer.delete(id: plainGuest.id)
        check(try await noKey.loadHistory().map(\.id) == [own.id],
            "An entirely locked guest catalog cannot hide healthy account history")
        var rootProbe = plainGuest; rootProbe.id = UUID()
        try await writer.create(rootProbe)
        func replacingRootWithFile(_ directory: URL, operation: () async throws -> Void) async throws {
            let retained = directory.appendingPathExtension("synthetic-backup")
            try FileManager.default.moveItem(at: directory, to: retained)
            defer {
                try? FileManager.default.removeItem(at: directory)
                try? FileManager.default.moveItem(at: retained, to: directory)
            }
            try Data("Synthetic invalid directory".utf8).write(to: directory)
            try await operation()
        }
        try await replacingRootWithFile(guest.directory("Meetings")) {
            check(try await noKey.loadHistory().map(\.id) == [own.id],
                "An unreadable guest root cannot hide healthy account history")
        }
        try await replacingRootWithFile(a.directory("Meetings")) {
            check(try await noKey.loadHistory().map(\.id) == [rootProbe.id],
                "An unreadable account root cannot hide healthy shared guest history")
        }
        let wrong = try MeetingRecordingCipher(profileID: b.id, key: Data(repeating: 0x43, count: 32))
        let wrongOwner = PrivateProfileMeetingStore(sharedGuestCipherProvider: { wrong })
        do { _ = try await wrongOwner.loadTranscript(id: source.id); check(false, "Another profile key cannot open guest data") }
        catch { check(true, "Shared guest key preflight validates the returned profile ownership") }
        let gate = SharedGuestCipherGate(cipher: cipher)
        let store = PrivateProfileMeetingStore(sharedGuestCipherProvider: { await gate.load() })
        let loading = Task { try await store.loadTranscript(id: source.id) }
        var started = false
        for _ in 0..<10_000 {
            if await gate.isWaiting { started = true; break }
            await Task.yield()
        }
        if !started {
            await gate.release(); _ = await loading.result
            check(false, "Shared guest key preflight must reach the bounded explicit test gate")
            return
        }
        PrivateProfileStorage.select(b)
        await gate.release()
        do { _ = try await loading.value; check(false, "A late shared guest key cannot publish into a new profile generation") }
        catch { check(true, "Shared key completion revalidates the original reader generation") }
        await store.finishProfileTransition()
        let restored = try await store.loadTranscript(id: source.id)
        check(restored == source && restored?.requiresEncryptedPersistence == true && restored?.isLocalContentConcealed == false,
            "A fresh account read restores viewable guest history through the original cipher without changing encryption")
        check(try Data(contentsOf: manifest) == bytes,
            "Missing, wrong and late key attempts preserve the original guest ciphertext")
    }
}

private actor SharedGuestCipherGate {
    let cipher: MeetingRecordingCipher
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var isWaiting = false
    init(cipher: MeetingRecordingCipher) { self.cipher = cipher }
    func load() async -> MeetingRecordingCipher? {
        if !released {
            await withCheckedContinuation { continuation = $0; isWaiting = true }
            isWaiting = false
        }
        return cipher
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
