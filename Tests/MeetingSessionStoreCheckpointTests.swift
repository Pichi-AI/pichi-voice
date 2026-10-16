import Foundation

// Standalone store tests use the production codecs and filesystem store. Only unrelated
// application logging/branding and canonical-sidecar migration are isolated in the runner.
@main
struct MeetingSessionStoreCheckpointTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic long checkpoint",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture microphone")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        session.state = .recording
        session.audioStorageMode = .memoryOnly
        session.piiRedactionEnabled = true
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "fixture",
            sourceDisplayName: "Fixture microphone", format: nil, timebase: timebase, health: .waiting, chunks: [])
        session.audioTracks = [track]
        let speaker = MeetingSessionSpeaker(id: UUID(), displayName: "Fixture speaker", diarizationClusterID: "fixture",
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        session.speakers = [speaker]
        session.transcriptTimeDomain = .meetingRelative
        session.transcriptIsComplete = false
        session.transcriptCoverageGaps = [.init(trackID: track.id, start: 10, end: 11, reason: .processingFailed)]
        let segmentCount = 20_000
        session.transcriptSegments = (0..<segmentCount).map { index in
            MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64(index * 2), timescale: 1),
                end: .init(value: Int64(index * 2 + 1), timescale: 1), sourceTrackID: track.id,
                speakerID: speaker.id, text: "Synthetic \(index) Ёё: escaped \"quote\", slash / and newline\nnext line",
                originalText: index % 2 == 0 ? "Original \(index)" : nil, revision: index % 3, status: .final,
                overlap: .none, completeness: .complete, attributionState: .assigned)
        }
        let indexURL = root.appendingPathComponent("index.json")
        let directory = root.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("session.json")
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }

        let start = ProcessInfo.processInfo.systemUptime
        try await store.create(session)
        let createSeconds = ProcessInfo.processInfo.systemUptime - start
        let compact = try Data(contentsOf: manifestURL)
        check(!compact.contains(10), "Canonical JSON has no formatting newlines, while escaped user newlines remain data")
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyStart = ProcessInfo.processInfo.systemUptime
        let legacy = try legacyEncoder.encode(session)
        let legacyEncodeSeconds = ProcessInfo.processInfo.systemUptime - legacyStart
        check(compact.count < legacy.count, "Checkpoints omit formatting without truncating records")
        let loaded = try await store.load(id: session.id)
        check(loaded == session, "All 20,000 segments, Unicode, edits, speaker and gap metadata round trip exactly")
        let recoverable = try await store.loadRecoverable()
        check(recoverable == [session], "Long strict recording remains recoverable without audio files")

        // A saved pre-change human-readable manifest is still accepted, then compacted on save.
        try legacy.write(to: manifestURL, options: .atomic)
        let legacyLoaded = try await store.load(id: session.id)
        check(legacyLoaded == session, "Historical pretty/sorted manifests decode unchanged")
        try await store.save(session)
        let recompacted = try Data(contentsOf: manifestURL)
        check(!recompacted.contains(10), "Saving an old manifest uses the compact canonical encoding")

        // Touching the index once per audio window was redundant and caused another atomic write.
        let initialIndex = try Data(contentsOf: indexURL)
        let sentinel = Date(timeIntervalSince1970: 1_600_000_000)
        try manager.setAttributes([.modificationDate: sentinel], ofItemAtPath: indexURL.path)
        session.title = "Newest durable title"
        session.transcriptSegments[0].text = "Corrected synthetic text"
        session.transcriptSegments[0].revision += 1
        session.updatedAt = session.startedAt.addingTimeInterval(60)
        let saveStart = ProcessInfo.processInfo.systemUptime
        try await store.save(session)
        let saveSeconds = ProcessInfo.processInfo.systemUptime - saveStart
        let indexAfterSave = try Data(contentsOf: indexURL)
        check(indexAfterSave == initialIndex, "An existing session checkpoint preserves the index bytes")
        let indexDate = try manager.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date
        check(indexDate == sentinel, "An existing session checkpoint does not replace or touch the index")
        let latest = try await MeetingSessionStore(rootDirectory: root).load(id: session.id)
        check(latest == session, "A fresh store recovers the complete latest checkpoint and revisions")

        // No process-only membership cache may suppress repair after disk loss/corruption.
        try manager.removeItem(at: indexURL)
        try await store.save(session)
        check(try self.indexIDs(at: indexURL) == [session.id.uuidString], "Missing index is reconstructed")
        try Data("invalid JSON".utf8).write(to: indexURL)
        try await store.save(session)
        check(try self.indexIDs(at: indexURL) == [session.id.uuidString], "Corrupt index is reconstructed")
        var sibling = session
        sibling.id = UUID()
        sibling.title = "Sibling synthetic checkpoint"
        try await store.save(sibling)
        check(try Set(self.indexIDs(at: indexURL)) == Set([session.id.uuidString, sibling.id.uuidString]),
            "A newly saved session still extends index membership")

        for url in [manifestURL, indexURL] {
            let permissions = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o600, "Canonical files retain private permissions")
        }
        for url in [root, directory, directory.appendingPathComponent("tracks")] {
            let permissions = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o700, "Canonical directories retain private permissions")
        }

        let beforeInvalidSave = try Data(contentsOf: manifestURL)
        var invalid = session
        invalid.transcriptSegments.append(invalid.transcriptSegments[0])
        do {
            try await store.save(invalid)
            preconditionFailure("Duplicate transcript IDs must fail validation")
        } catch MeetingModelValidationError.duplicateSegmentID {
            checks += 1
        }
        check(try Data(contentsOf: manifestURL) == beforeInvalidSave, "Invalid checkpoint never replaces the last valid manifest")
        try await store.delete(id: session.id)
        do {
            try await store.save(session)
            preconditionFailure("A stale checkpoint must not resurrect a deleted meeting")
        } catch MeetingSessionStoreError.sessionDeleted {
            checks += 1
        }
        check(!manager.fileExists(atPath: directory.path), "Deletion removes the entire session directory")
        let deleted = try await store.load(id: session.id)
        check(deleted == nil, "Tombstoned meeting stays absent")
        check(try self.indexIDs(at: indexURL) == [sibling.id.uuidString], "Deletion preserves sibling membership")
        let all = try await MeetingSessionStore(rootDirectory: root).loadAll()
        check(all == [sibling], "Fresh discovery and index loading retain every surviving complete record")
        print("Meeting session checkpoint tests passed: \(checks) checks; \(segmentCount) segments; "
            + "compactBytes=\(compact.count) legacyBytes=\(legacy.count) "
            + "createSeconds=\(createSeconds) saveSeconds=\(saveSeconds) legacyEncodeSeconds=\(legacyEncodeSeconds)")
    }

    private static func indexIDs(at url: URL) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let ids = object?["sessionIDs"] as? [String] else { preconditionFailure("Missing index IDs") }
        return ids
    }
}
