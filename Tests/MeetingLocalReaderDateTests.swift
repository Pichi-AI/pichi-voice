import Foundation

extension MeetingSessionStoreCheckpointTests {
    static func checkLocalReaderDates(root: URL, check: (Bool, String) -> Void) async throws {
        let profile = "synthetic-local-reader-profile"
        let cipher = try MeetingRecordingCipher(profileID: profile, key: Data(repeating: 0x42, count: 32))
        let store = MeetingSessionStore(rootDirectory: root, encryptionCipher: cipher)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var source = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic precise reader",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000.125_123_4), timebase: timebase)
        source.state = .completed
        source.endedAt = source.startedAt.addingTimeInterval(1.5)
        source.audioStorageMode = .memoryOnly
        let track = UUID()
        source.audioTracks = [.init(id: track, kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])]
        source.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 16_000),
            end: .init(value: 24_000, timescale: 16_000), sourceTrackID: track, speakerID: nil,
            text: "Synthetic local reader transcript.", revision: 0, status: .final,
            overlap: .none, completeness: .complete, attributionState: .unassigned)]
        try await store.create(source)
        var newer = source; newer.id = UUID()
        newer.startedAt = Date(timeIntervalSince1970: 1_700_000_000.875_987_6)
        newer.endedAt = newer.startedAt.addingTimeInterval(1.5)
        try await store.create(newer)

        var legacy = source; legacy.id = UUID()
        try await store.create(legacy)
        let legacyFile = root.appendingPathComponent(legacy.id.uuidString).appendingPathComponent("session.json")
        let oldEncoder = JSONEncoder(); oldEncoder.dateEncodingStrategy = .iso8601
        let legacyBytes = try oldEncoder.encode(legacy)
        try legacyBytes.write(to: legacyFile)
        let oldDecoder = JSONDecoder(); oldDecoder.dateDecodingStrategy = .iso8601
        legacy = try oldDecoder.decode(MeetingSession.self, from: legacyBytes)

        var encrypted = source; encrypted.id = UUID(); encrypted.requiresEncryptedPersistence = true
        encrypted.profileOwnership = .init(profileID: profile, issuer: nil, subject: nil,
            internalUserID: "17", organizationID: "19", workspaceID: "23")
        try await store.create(encrypted)
        let encryptedFile = root.appendingPathComponent(encrypted.id.uuidString).appendingPathComponent("session.json")
        let encryptedBytes = try Data(contentsOf: encryptedFile)
        check(MeetingRecordingCipher.isEncryptedEnvelope(encryptedBytes),
              "The excluded helper fixture is genuine production ciphertext")

        let entries = try FluidServeMeetings.checkedEntries(root: root)
        check(Set(entries.map { $0.meeting.id }) == Set([source.id, newer.id, legacy.id]),
              "The actual helper reads newly stored numeric and legacy ISO manifests while excluding ciphertext")
        for expected in [source, newer, legacy] {
            let actual = try FluidServeMeetings.resolve(expected.id.uuidString, in: entries).meeting
            check(actual.startedAt == expected.startedAt && actual.endedAt == expected.endedAt
                && actual.durationSeconds == expected.duration,
                  "The helper retains exact local dates and durations from both codecs")
            check(actual.turns.map(\.text) == expected.transcriptSegments.map(\.text),
                  "The helper reads the original transcript from the store's manifest")
        }
        check(try FluidServeMeetings.resolve("latest", in: entries).meeting.id == newer.id,
              "Latest selection honors subsecond chronology of newly saved meetings")
        check(try FluidServeMeetings.checkedEntries(root: root, since: newer.startedAt).map { $0.meeting.id } == [newer.id],
              "Since filtering retains subsecond local chronology")
        check(try Data(contentsOf: legacyFile) == legacyBytes && Data(contentsOf: encryptedFile) == encryptedBytes,
              "The read-only helper leaves legacy files and encrypted content unchanged")

        let loadedLegacy = try await store.load(id: legacy.id)!
        try await store.save(loadedLegacy)
        let resaved = try FluidServeMeetings.resolve(legacy.id.uuidString,
            in: FluidServeMeetings.checkedEntries(root: root)).meeting
        check(resaved.startedAt == legacy.startedAt && resaved.endedAt == legacy.endedAt,
              "A legacy meeting remains visible after an ordinary store save writes numeric dates")
    }
}
