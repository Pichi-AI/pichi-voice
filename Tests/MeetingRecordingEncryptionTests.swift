import Foundation

extension MeetingSessionStoreCheckpointTests {
    /// Real CryptoKit and filesystem stores with injected synthetic keys only. No Security
    /// API, account credential, microphone, model, simulator or user profile is accessed.
    static func checkRecordingEncryption(root: URL, check report: (Bool, String) -> Void) async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; report(value, message) }
        let manager = FileManager.default
        let profile = "synthetic-encrypted-profile-a"
        let cipher = try MeetingRecordingCipher(profileID: profile, key: Data(repeating: 0x31, count: 32))
        let wrongKey = try MeetingRecordingCipher(profileID: profile, key: Data(repeating: 0x32, count: 32))
        let wrongProfile = try MeetingRecordingCipher(profileID: "synthetic-encrypted-profile-b", key: Data(repeating: 0x31, count: 32))
        let id = UUID(), sentinel = Data("SYNTHETIC-PRIVATE-TEXT-CANARY-Ёё".utf8)
        let box = try cipher.seal(sentinel, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 1024)
        let second = try cipher.seal(sentinel, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 1024)
        check(MeetingRecordingCipher.isEncryptedEnvelope(box) && box != second,
              "Every authenticated write has a fresh nonce and a versioned envelope")
        check(box.range(of: sentinel) == nil, "Encrypted bytes do not contain the plaintext sentinel")
        check(try cipher.open(box, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 1024) == sentinel,
              "Authenticated bytes round-trip through the production codec")
        func reject(_ operation: () throws -> Void, _ message: String) {
            do { try operation(); check(false, message) } catch { check(true, message) }
        }
        reject({ _ = try wrongKey.open(box, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 1024) },
               "A replacement key cannot decrypt an old recording")
        reject({ _ = try wrongProfile.open(box, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 1024) },
               "Another profile cannot decrypt even when supplied the same synthetic secret")
        reject({ _ = try cipher.open(box, sessionID: UUID(), artifactKind: .sessionManifest, maximumPlaintextBytes: 1024) },
               "A ciphertext cannot move to a different session")
        reject({ _ = try cipher.open(box, sessionID: id, artifactKind: .publicationOutbox, maximumPlaintextBytes: 1024) },
               "A manifest ciphertext cannot be replayed as a publication record")
        var damaged = box; damaged[damaged.count - 1] ^= 1
        reject({ _ = try cipher.open(damaged, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 1024) },
               "Modified ciphertext fails authentication")
        reject({ _ = try cipher.open(sentinel, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 1024) },
               "The cipher never treats plaintext as an envelope")
        reject({ _ = try cipher.seal(sentinel, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 2) },
               "Plaintext is bounded before sealing")
        reject({ _ = try cipher.open(box, sessionID: id, artifactKind: .sessionManifest, maximumPlaintextBytes: 2) },
               "Ciphertext is bounded before opening")
        reject({ _ = try MeetingRecordingCipher(profileID: profile, key: Data(repeating: 1, count: 31)) },
               "Only a 256-bit key is admitted")

        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: .init(mode: .inRoom,
            title: "PRIVATE-TITLE-CANARY-Ёё", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        session.audioStorageMode = .memoryOnly
        session.piiRedactionEnabled = true
        session.requiresEncryptedPersistence = true
        session.profileOwnership = .init(profileID: profile, issuer: nil, subject: nil,
            internalUserID: "17", organizationID: "19", workspaceID: "23")
        let storeRoot = root.appendingPathComponent("encrypted", isDirectory: true)
        let store = MeetingSessionStore(rootDirectory: storeRoot, encryptionCipher: cipher)
        try await store.create(session)
        let directory = storeRoot.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let manifest = directory.appendingPathComponent("session.json")
        let encryptedBytes = try Data(contentsOf: manifest)
        check(MeetingRecordingCipher.isEncryptedEnvelope(encryptedBytes)
              && encryptedBytes.range(of: Data(session.title.utf8)) == nil,
              "The existing store writes ciphertext before publishing its manifest")
        check(try await store.load(id: session.id) == session, "The encrypted manifest is readable through the ordinary store")
        let restarted = MeetingSessionStore(rootDirectory: storeRoot, encryptionCipher: cipher)
        check(try await restarted.loadTranscript(id: session.id) == session,
              "A restarted store reads the same encrypted session with its injected profile key")
        let unconfigured = MeetingSessionStore(rootDirectory: storeRoot)
        check(try await unconfigured.hasEncryptedPersistenceData(), "Missing-key preflight discovers existing encrypted data from the index")
        let index = storeRoot.appendingPathComponent("index.json")
        let indexBytes = try Data(contentsOf: index)
        try manager.removeItem(at: index)
        let noIndex = MeetingSessionStore(rootDirectory: storeRoot)
        check(try await noIndex.hasEncryptedPersistenceData(), "A bounded header scan finds ciphertext even when the index is missing")
        try indexBytes.write(to: index)
        do { _ = try await unconfigured.load(id: session.id); check(false, "A missing key cannot reveal encrypted history") }
        catch { check(true, "A missing key cannot reveal encrypted history") }
        do { try await restarted.installEncryptionCipher(wrongKey); check(false, "A loaded store cannot silently rotate its key") }
        catch { check(true, "A loaded store cannot silently rotate its key") }

        var downgrade = session; downgrade.requiresEncryptedPersistence = nil
        do { try await restarted.save(downgrade); check(false, "Saving a known encrypted session cannot downgrade protection") }
        catch { check(true, "Saving a known encrypted session cannot downgrade protection") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(downgrade).write(to: manifest)
        let afterDowngrade = MeetingSessionStore(rootDirectory: storeRoot, encryptionCipher: cipher)
        do { _ = try await afterDowngrade.load(id: session.id); check(false, "Index membership rejects a plaintext downgrade after restart") }
        catch { check(true, "Index membership rejects a plaintext downgrade after restart") }
        try encryptedBytes.write(to: manifest)
        var tampered = encryptedBytes; tampered[tampered.count - 1] ^= 1
        try tampered.write(to: manifest)
        do { _ = try await restarted.load(id: session.id); check(false, "Store reads fail closed on modified ciphertext") }
        catch { check(true, "Store reads fail closed on modified ciphertext") }
        try encryptedBytes.write(to: manifest)
        check(try await restarted.load(id: session.id) == session, "A failed decrypt does not destroy the original recoverable recording")

        let unavailableRoot = root.appendingPathComponent("unavailable-key", isDirectory: true)
        let unavailable = MeetingSessionStore(rootDirectory: unavailableRoot)
        do { try await unavailable.create(session); check(false, "Capture requires its cipher before the first manifest") }
        catch { check(true, "Capture requires its cipher before the first manifest") }
        check(!manager.fileExists(atPath: unavailableRoot.path), "Missing-key preflight creates no session directory or plaintext artifact")
        try await unavailable.installEncryptionCipher(cipher)
        try await unavailable.create(session)
        check(try await unavailable.load(id: session.id) == session, "Installing the preflighted key permits the same admitted capture")
        var retained = session; retained.id = UUID(); retained.audioStorageMode = .retainedFiles
        do { try await store.create(retained); check(false, "Encrypted mode cannot quietly create unencrypted retained audio") }
        catch { check(true, "Encrypted mode cannot quietly create unencrypted retained audio") }
        var noPrivacy = session; noPrivacy.id = UUID(); noPrivacy.piiRedactionEnabled = false
        do { try await store.create(noPrivacy); check(false, "The secure delivery mode keeps the existing Privacy requirement") }
        catch { check(true, "The secure delivery mode keeps the existing Privacy requirement") }
        var otherOwner = session; otherOwner.id = UUID()
        otherOwner.profileOwnership = .init(profileID: "another-profile", issuer: nil, subject: nil,
            internalUserID: "18", organizationID: "19", workspaceID: "23")
        do { try await store.create(otherOwner); check(false, "A source cannot select another profile's cipher") }
        catch { check(true, "A source cannot select another profile's cipher") }

        let legacyRoot = root.appendingPathComponent("legacy", isDirectory: true)
        let legacy = MeetingSessionStore(rootDirectory: legacyRoot)
        check(try await legacy.hasEncryptedPersistenceData() == false, "An absent legacy store contains no encrypted data")
        var ordinary = session; ordinary.id = UUID(); ordinary.requiresEncryptedPersistence = nil
        try await legacy.create(ordinary)
        let ordinaryURL = legacyRoot.appendingPathComponent(ordinary.id.uuidString).appendingPathComponent("session.json")
        let ordinaryBytes = try Data(contentsOf: ordinaryURL)
        let ordinaryRead = try await legacy.load(id: ordinary.id)
        check(!MeetingRecordingCipher.isEncryptedEnvelope(ordinaryBytes) && ordinaryRead == ordinary,
              "Ordinary legacy recordings retain their existing codec and readability")
        try await store.delete(id: session.id)
        check(!manager.fileExists(atPath: directory.path), "The existing delete operation removes encrypted session data")
        let allFiles = manager.enumerator(at: storeRoot, includingPropertiesForKeys: [.isRegularFileKey])
        var leaked = false
        while let url = allFiles?.nextObject() as? URL {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if let bytes = try? Data(contentsOf: url), bytes.range(of: Data(session.title.utf8)) != nil { leaked = true }
        }
        check(!leaked, "No protected title remains in manifest, index or atomic temporary files")
        var guarded = session; guarded.id = UUID(); guarded.title = "Accepted local version"
        try await store.create(guarded)
        let owned = guarded.profileOwnership!
        var edited = guarded; edited.title = "Newer unsent local edit"
        try await store.save(edited)
        do {
            try await store.delete(id: guarded.id, expectedOwnership: owned, validating: { source in
                guard source.title == "Accepted local version" else { throw EncryptionDeletionProbeFailure.changed }
            })
            check(false, "Deletion must reject a local edit committed before its atomic validation")
        } catch { check(true, "Deletion rejects a newer local edit before touching its files") }
        let preserved = try await store.load(id: guarded.id)
        check(preserved == edited, "Rejected cleanup retains the full newer encrypted recording")
        let race = EncryptionDeletionGate()
        let deletionID = guarded.id
        let deletion = Task {
            try await store.delete(id: deletionID, expectedOwnership: owned, validating: { source in
                guard source.title == "Newer unsent local edit" else { throw EncryptionDeletionProbeFailure.changed }
                race.enterAndWait()
            })
        }
        for _ in 0..<200 where !race.entered { try await Task.sleep(for: .milliseconds(5)) }
        check(race.entered, "Production delete invokes validation under its actor-owned deletion turn")
        let lateEdit = edited
        let writer = Task { try await store.save(lateEdit) }
        race.release()
        try await deletion.value
        do { try await writer.value; check(false, "A writer cannot slip between validation and removal") }
        catch { check(true, "A writer queued during atomic deletion receives the existing tombstone rejection") }
        let deleted = try await store.load(id: deletionID)
        check(deleted == nil, "Successful guarded deletion leaves no resurrected session")
        print("Encrypted recording persistence: \(count) synthetic CryptoKit/filesystem checks passed; no Keychain access")
    }
}

private nonisolated enum EncryptionDeletionProbeFailure: Error { case changed }
private nonisolated final class EncryptionDeletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didEnter = false
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    func enterAndWait() {
        lock.lock(); didEnter = true; lock.unlock()
        precondition(semaphore.wait(timeout: .now() + 3) == .success, "Deletion fixture gate timed out")
    }
    func release() { semaphore.signal() }
}
