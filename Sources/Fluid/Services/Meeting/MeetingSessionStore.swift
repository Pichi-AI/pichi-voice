import CryptoKit
import Darwin
import Foundation

nonisolated protocol MeetingSessionStoring: Sendable {
    /// Freeze local ownership under the existing capture admission, before the first manifest.
    func prepareAutomaticCapture() async throws -> Bool
    func prepareCapturePersistencePolicy() async throws -> MeetingCapturePersistencePolicy
    func captureOwnership(for id: MeetingSessionID) async throws -> MeetingProfileOwnership?
    func captureOwnership(for id: MeetingSessionID, configuration: MeetingCaptureConfiguration) async throws -> MeetingProfileOwnership?
    func cancelCaptureAdmission(for id: MeetingSessionID) async
    func create(_ session: MeetingSession) async throws
    func save(_ session: MeetingSession) async throws
    func load(id: MeetingSessionID) async throws -> MeetingSession?
    func loadAll() async throws -> [MeetingSession]
    func loadHistory() async throws -> [MeetingSession]
    /// Automatic cleanup uses only records governed by the selected profile's settings.
    func loadHistoryForMaintenance() async throws -> [MeetingSession]
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession?
    func loadRecoverable() async throws -> [MeetingSession]
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL?
    func delete(id: MeetingSessionID) async throws
    func delete(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership) async throws
    func delete(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership, validating: @Sendable (MeetingSession) throws -> Void) async throws
    /// Removes the `tracks/` directory and any processing checkpoint, leaving the manifest and
    /// transcript untouched. Idempotent — missing paths are not an error.
    func deleteAudioFiles(for id: MeetingSessionID) async throws
}

// Test/custom stores retain their existing behavior unless they provide the lighter reads.
nonisolated extension MeetingSessionStoring {
    func prepareAutomaticCapture() async throws -> Bool { false }
    func prepareCapturePersistencePolicy() async throws -> MeetingCapturePersistencePolicy {
        let protectedPublication = try await self.prepareAutomaticCapture()
        return .init(requiresEncryptedPersistence: protectedPublication, requiresPIIRedaction: protectedPublication)
    }
    func loadHistory() async throws -> [MeetingSession] { try await self.loadAll() }
    func loadHistoryForMaintenance() async throws -> [MeetingSession] { try await self.loadHistory() }
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession? { try await self.load(id: id) }
    func captureOwnership(for id: MeetingSessionID) async throws -> MeetingProfileOwnership? { nil }
    func cancelCaptureAdmission(for id: MeetingSessionID) async {}
    func captureOwnership(for id: MeetingSessionID, configuration: MeetingCaptureConfiguration) async throws -> MeetingProfileOwnership? {
        guard configuration.requiresEncryptedPersistence != true else { throw CocoaError(.featureUnsupported) }
        return try await self.captureOwnership(for: id)
    }
    func delete(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership) async throws {
        guard let session = try await self.load(id: id) else { return }
        guard session.profileOwnership == expectedOwnership else { throw CocoaError(.fileWriteNoPermission) }
        try await self.delete(id: id)
    }
    func delete(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership, validating: @Sendable (MeetingSession) throws -> Void) async throws {
        // A custom store must provide an atomic implementation, not a load/await/delete approximation.
        throw CocoaError(.featureUnsupported)
    }

}

private final nonisolated class MeetingSessionFileSystem: @unchecked Sendable {
    let manager: FileManager

    init(manager: FileManager) {
        self.manager = manager
    }
}

actor MeetingSessionStore: MeetingSessionStoring {
    private struct SessionIndex: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var sessionIDs: [MeetingSessionID]
        // UUID membership only. No transcript, title, account or speaker metadata.
        var encryptedSessionIDs: [MeetingSessionID]? = nil
        var updatedAt: Date
    }

    private let fileSystem: MeetingSessionFileSystem
    private let rootDirectory: URL
    private let automaticTitleOwnership: MeetingProfileOwnership
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var tombstonedIDs: Set<MeetingSessionID> = []
    private var encryptedSessionIDs: Set<MeetingSessionID> = []
    private var encryptionCipher: MeetingRecordingCipher?

    init(rootDirectory: URL? = nil, fileManager: FileManager = .default,
         encryptionCipher: MeetingRecordingCipher? = nil,
         automaticTitleOwnership: MeetingProfileOwnership = .guest) {
        self.automaticTitleOwnership = automaticTitleOwnership
        self.encryptionCipher = encryptionCipher
        self.fileSystem = MeetingSessionFileSystem(manager: fileManager)
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let applicationSupport = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
            self.rootDirectory = applicationSupport
                .appendingPathComponent(AppBrand.storageNamespace, isDirectory: true)
                .appendingPathComponent("Meetings", isDirectory: true)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = MeetingSessionDateCodec.encodingStrategy
        // This canonical manifest is also the strict capture checkpoint. Formatting every
        // growing transcript adds sorting, whitespace and temporary allocations to each audio
        // window's critical path; readers only depend on its schema, never JSON key order.
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeetingSessionDateCodec.decodingStrategy
        self.decoder = decoder
    }

    /// Existing profile composition preflights the key before capture admission. Replacing a
    /// live key would make pending records unreadable, so a different key is rejected.
    func installEncryptionCipher(_ cipher: MeetingRecordingCipher) throws {
        if let existing = self.encryptionCipher {
            guard existing.hasSameKey(as: cipher) else { throw MeetingRecordingCipher.Failure.invalidConfiguration }
        } else { self.encryptionCipher = cipher }
    }

    /// A missing Keychain item must not become a new key while recoverable ciphertext
    /// remains. Probe only bounded metadata and eight-byte headers in confined session roots.
    func hasEncryptedPersistenceData() throws -> Bool {
        if !self.encryptedSessionIDs.isEmpty { return true }
        guard self.fileSystem.manager.fileExists(atPath: self.rootDirectory.path) else { return false }
        let indexURL = self.rootDirectory.appendingPathComponent("index.json")
        if self.fileSystem.manager.fileExists(atPath: indexURL.path) {
            let indexBytes = try self.readEncryptionProbeFile(indexURL, maximumBytes: 8 * 1_024 * 1_024)
            let index = try self.decoder.decode(SessionIndex.self, from: indexBytes)
            if index.encryptedSessionIDs?.isEmpty == false { return true }
        }
        let entries = try self.boundedEncryptionProbeEntries(in: self.rootDirectory, maximumCount: 20_000)
        var inspected = entries.count
        for name in entries where UUID(uuidString: name) != nil {
            let directory = self.rootDirectory.appendingPathComponent(name, isDirectory: true)
            let attributes = try self.fileSystem.manager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MeetingRecordingCipher.Failure.invalidEnvelope
            }
            let files = try self.boundedEncryptionProbeEntries(in: directory, maximumCount: 20_000 - inspected)
            inspected += files.count
            for file in files {
                let url = directory.appendingPathComponent(file)
                let properties = try self.fileSystem.manager.attributesOfItem(atPath: url.path)
                if properties[.type] as? FileAttributeType == .typeDirectory { continue }
                let prefix = try self.readEncryptionProbeFile(url,
                    maximumBytes: MeetingRecordingCipher.envelopePrefixBytes, prefixOnly: true)
                if MeetingRecordingCipher.isEncryptedEnvelope(prefix) { return true }
            }
        }
        return false
    }

    private func boundedEncryptionProbeEntries(in directory: URL, maximumCount: Int) throws -> [String] {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MeetingRecordingCipher.Failure.invalidEnvelope }
        guard let stream = fdopendir(descriptor) else {
            Darwin.close(descriptor)
            throw MeetingRecordingCipher.Failure.invalidEnvelope
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw MeetingRecordingCipher.Failure.invalidEnvelope }
                return names
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard names.count < maximumCount else { throw MeetingRecordingCipher.Failure.limitExceeded }
            names.append(name)
        }
    }

    private func readEncryptionProbeFile(_ url: URL, maximumBytes: Int, prefixOnly: Bool = false) throws -> Data {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw MeetingRecordingCipher.Failure.invalidEnvelope }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == geteuid(), info.st_size >= 0,
              prefixOnly || info.st_size <= maximumBytes else { throw MeetingRecordingCipher.Failure.invalidEnvelope }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        while data.count < maximumBytes {
            let next = try handle.read(upToCount: min(64 * 1_024, maximumBytes - data.count)) ?? Data()
            if next.isEmpty { break }
            data.append(next)
        }
        return data
    }

    func create(_ session: MeetingSession) throws {
        guard !self.tombstonedIDs.contains(session.id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try session.validateForPersistence()
        try self.validateEncryptionSelection(session)
        try self.prepareRootDirectory()
        let directory = self.sessionDirectoryURL(for: session.id)
        guard !self.fileSystem.manager.fileExists(atPath: directory.path) else {
            throw MeetingSessionStoreError.sessionAlreadyExists
        }
        try self.createPrivateDirectory(directory)
        try self.createPrivateDirectory(directory.appendingPathComponent("tracks", isDirectory: true))
        try self.writeSession(session)
        try self.addToIndex(session.id, encrypted: session.requiresEncryptedPersistence == true)
    }

    func save(_ session: MeetingSession) throws {
        guard !self.tombstonedIDs.contains(session.id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try session.validateForPersistence()
        try self.validateEncryptionSelection(session)
        try self.prepareRootDirectory()
        let directory = self.sessionDirectoryURL(for: session.id)
        if !self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.createPrivateDirectory(directory)
            try self.createPrivateDirectory(directory.appendingPathComponent("tracks", isDirectory: true))
        }
        try self.writeSession(session)
        try self.addToIndex(session.id, encrypted: session.requiresEncryptedPersistence == true)
    }

    func load(id: MeetingSessionID) throws -> MeetingSession? {
        guard !self.tombstonedIDs.contains(id) else { return nil }
        let url = self.sessionManifestURL(for: id)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else { return nil }
        let session = try self.decodeSession(at: url)
        let reconciled = try self.reconcileTrackManifests(in: session)
        let timeline = self.migrateCanonicalTranscriptTimelineIfNeeded(reconciled)
        if timeline != session {
            try self.writeSession(timeline)
        }
        return self.migrateAutomaticTitle(in: timeline)
    }

    /// Reading transcript/history never opens or hashes audio. Recovery and audio consumers
    /// keep using load(id:), which still reconciles and validates the requested recording.
    func loadTranscript(id: MeetingSessionID) async throws -> MeetingSession? {
        try self.readTranscript(id: id)
    }

    private func readTranscript(id: MeetingSessionID) throws -> MeetingSession? {
        guard !self.tombstonedIDs.contains(id) else { return nil }
        let url = self.sessionManifestURL(for: id)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else { return nil }
        let session = try self.decodeSession(at: url)
        let timeline = self.migrateCanonicalTranscriptTimelineIfNeeded(session)
        if timeline != session { try self.writeSession(timeline) }
        return self.migrateAutomaticTitle(in: timeline)
    }

    /// The actor serializes this one-record migration with renames and other manifest writes.
    /// Read paths retain their existing no-audio contract and use the same encrypted writer.
    private func migrateAutomaticTitle(in session: MeetingSession) -> MeetingSession {
        // A raw read may precede the facade's ownership filter. Never rename another
        // profile's shadowed manifest merely because it exists in this physical root.
        guard self.automaticTitleOwnership.matchesPersistedOwner(session.profileOwnership) else { return session }
        if session.automaticTitle != nil {
            let validated = MeetingAutomaticNaming.validatingMetadata(in: session)
            guard validated.automaticTitle == session.automaticTitle else { return validated }
            // A supported old artifact can still need its content-language backfill.
            // Existing frozen languages and future versions are no-ops in the helper.
        }
        let named = MeetingAutomaticNaming.applying(to: session)
        guard named.automaticTitle != session.automaticTitle else { return session }
        do {
            try MeetingSavedSummary.migrateLegacySummaries(in: self.sessionDirectoryURL(for: session.id), for: session)
            try self.writeSession(named)
            return named
        } catch {
            // A cosmetic title upgrade must not remove otherwise readable history.
            DebugLogger.shared.warning("Could not update automatic meeting title: \(error.localizedDescription)",
                source: "MeetingSessionStore")
            return session
        }
    }

    func loadHistory() async throws -> [MeetingSession] {
        try self.loadCatalog(reconcileAudio: false)
    }

    func loadAll() throws -> [MeetingSession] {
        try self.loadCatalog(reconcileAudio: true)
    }

    private func loadCatalog(reconcileAudio: Bool) throws -> [MeetingSession] {
        try self.prepareRootDirectory()
        let indexedIDs = (try? self.readIndex().sessionIDs) ?? []
        let discoveredIDs = try self.discoverSessionIDs()
        let allIDs = Array(Set(indexedIDs).union(discoveredIDs))

        var sessions: [MeetingSession] = []
        var hadReadFailure = false
        sessions.reserveCapacity(allIDs.count)
        for id in allIDs {
            do {
                let session = try reconcileAudio ? self.load(id: id) : self.readTranscript(id: id)
                if let session { sessions.append(session) }
            } catch {
                hadReadFailure = true
                DebugLogger.shared.error(
                    "Failed to load meeting session \(id): \(error.localizedDescription)",
                    source: "MeetingSessionStore"
                )
            }
        }
        // Missing indexed files are ordinary stale membership, but unreadable manifests
        // must not replace the window's last snapshot with a successful empty history.
        guard !sessions.isEmpty || !hadReadFailure else {
            throw MeetingSessionStoreError.historyUnavailable
        }
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    func loadRecoverable() throws -> [MeetingSession] {
        // Completed history must not make startup hash the whole audio library. Only the
        // recordings that may actually be resumed need full audio reconciliation here.
        var recovered: [MeetingSession] = []
        for candidate in try self.loadCatalog(reconcileAudio: false) where Self.needsRecoveryInspection(candidate) {
            do {
                if let session = try self.load(id: candidate.id), Self.isRecoverable(session) {
                    recovered.append(session)
                }
            } catch {
                DebugLogger.shared.warning(
                    "Could not inspect interrupted meeting \(candidate.id): \(error.localizedDescription)",
                    source: "MeetingSessionStore"
                )
            }
        }
        return recovered
    }

    private static func needsRecoveryInspection(_ session: MeetingSession) -> Bool {
        guard session.recoveryResolvedAt == nil, session.retention.audioDeletedAt == nil else { return false }
        switch session.state {
        case .preparing, .recording, .recordingDegraded, .stopping, .processing, .interrupted:
            return true
        case .failed:
            // A track manifest can contain finalized audio missing from session.json after a crash.
            return session.failures.last?.recoverable == true && session.endedAt != nil
        case .completed:
            return false
        }
    }

    private static func isRecoverable(_ session: MeetingSession) -> Bool {
        guard self.needsRecoveryInspection(session) else { return false }
        guard session.state == .failed else { return true }
        return session.audioTracks.contains { track in
            track.chunks.contains { $0.finalizationState == .finalized && $0.byteCount > 0 }
        }
    }

    func sessionDirectory(for id: MeetingSessionID) throws -> URL {
        guard !self.tombstonedIDs.contains(id) else {
            throw MeetingSessionStoreError.sessionDeleted
        }
        try self.prepareRootDirectory()
        let directory = self.sessionDirectoryURL(for: id)
        if !self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.createPrivateDirectory(directory)
            try self.createPrivateDirectory(directory.appendingPathComponent("tracks", isDirectory: true))
        }
        return directory
    }

    func existingSessionDirectory(for id: MeetingSessionID) throws -> URL? {
        let directory = self.sessionDirectoryURL(for: id)
        return self.fileSystem.manager.fileExists(atPath: directory.path) ? directory : nil
    }

    func delete(id: MeetingSessionID) throws {
        self.tombstonedIDs.insert(id)
        let directory = self.sessionDirectoryURL(for: id)
        if self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.fileSystem.manager.removeItem(at: directory)
        }
        try self.removeFromIndex(id)
    }

    /// Validation and removal execute in one actor turn with no suspension, so an
    /// admitted save cannot overwrite the source between comparison and deletion.
    func delete(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership,
                validating: @Sendable (MeetingSession) throws -> Void) async throws {
        try Task.checkCancellation()
        if let session = try self.load(id: id) {
            guard expectedOwnership.matchesPersistedOwner(session.profileOwnership) else { throw CocoaError(.fileWriteNoPermission) }
            try validating(session)
        }
        try self.delete(id: id)
    }

    func deleteAudioFiles(for id: MeetingSessionID) throws {
        let directory = self.sessionDirectoryURL(for: id)
        let tracksURL = directory.appendingPathComponent("tracks", isDirectory: true)
        if self.fileSystem.manager.fileExists(atPath: tracksURL.path) {
            try self.fileSystem.manager.removeItem(at: tracksURL)
        }
        let checkpointURL = directory.appendingPathComponent("checkpoint.json", isDirectory: false)
        if self.fileSystem.manager.fileExists(atPath: checkpointURL.path) {
            try self.fileSystem.manager.removeItem(at: checkpointURL)
        }
        try MeetingRetainedProcessingCheckpoint.remove(in: directory)
    }

    private func requiresEncryption(for id: MeetingSessionID) -> Bool {
        if self.encryptedSessionIDs.contains(id) { return true }
        if let index = try? self.readIndex(), index.encryptedSessionIDs?.contains(id) == true {
            self.encryptedSessionIDs.insert(id)
            return true
        }
        return false
    }

    private func validateEncryptionSelection(_ session: MeetingSession) throws {
        let encrypted = session.requiresEncryptedPersistence == true
        guard encrypted || !self.requiresEncryption(for: session.id) else {
            throw MeetingRecordingCipher.Failure.invalidConfiguration
        }
        if encrypted {
            guard let cipher = self.encryptionCipher else { throw MeetingRecordingCipher.Failure.unavailableKey }
            guard session.audioStorageMode == .memoryOnly,
                  session.profileOwnership?.profileID == cipher.profileID else {
                throw MeetingRecordingCipher.Failure.invalidConfiguration
            }
        }
    }

    private func writeSession(_ session: MeetingSession) throws {
        try self.validateEncryptionSelection(session)
        let encrypted = session.requiresEncryptedPersistence == true
        var data = try self.encoder.encode(session)
        if encrypted {
            guard let cipher = self.encryptionCipher else { throw MeetingRecordingCipher.Failure.unavailableKey }
            data = try cipher.seal(data, sessionID: session.id, artifactKind: .sessionManifest,
                maximumPlaintextBytes: MeetingRecordingCipher.maximumManifestBytes)
        }
        // Ciphertext is complete before Foundation can create an atomic temporary file.
        try self.atomicPrivateWrite(data, to: self.sessionManifestURL(for: session.id))
        if encrypted { self.encryptedSessionIDs.insert(session.id) }
    }

    private func decodeSession(at url: URL) throws -> MeetingSession {
        guard let id = UUID(uuidString: url.deletingLastPathComponent().lastPathComponent) else {
            throw MeetingRecordingCipher.Failure.invalidConfiguration
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let prefix = try file.read(upToCount: MeetingRecordingCipher.envelopePrefixBytes) ?? Data()
        let isEnvelope = MeetingRecordingCipher.isEncryptedEnvelope(prefix)
        let knownEncrypted = self.requiresEncryption(for: id)
        let data: Data
        if isEnvelope || knownEncrypted {
            guard isEnvelope else { throw MeetingRecordingCipher.Failure.invalidEnvelope }
            guard let cipher = self.encryptionCipher else { throw MeetingRecordingCipher.Failure.unavailableKey }
            let maximum = MeetingRecordingCipher.maximumManifestBytes + MeetingRecordingCipher.envelopeOverhead
            var envelope = prefix
            while envelope.count <= maximum {
                let next = try file.read(upToCount: min(64 * 1_024, maximum + 1 - envelope.count)) ?? Data()
                if next.isEmpty { break }
                envelope.append(next)
            }
            guard envelope.count <= maximum else { throw MeetingRecordingCipher.Failure.limitExceeded }
            data = try cipher.open(envelope, sessionID: id, artifactKind: .sessionManifest,
                maximumPlaintextBytes: MeetingRecordingCipher.maximumManifestBytes)
        } else {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        }
        let session = try self.decoder.decode(MeetingSession.self, from: data)
        try session.validateForPersistence()
        guard session.id == id else { throw MeetingRecordingCipher.Failure.invalidConfiguration }
        if isEnvelope {
            guard session.requiresEncryptedPersistence == true,
                  session.audioStorageMode == .memoryOnly,
                  session.profileOwnership?.profileID == self.encryptionCipher?.profileID else {
                throw MeetingRecordingCipher.Failure.invalidConfiguration
            }
            self.encryptedSessionIDs.insert(id)
        } else if session.requiresEncryptedPersistence == true {
            throw MeetingRecordingCipher.Failure.invalidEnvelope
        }
        return session
    }

    /// Canonical sessions published before the explicit timeline-domain marker stored product
    /// segment/gap times in absolute host presentation seconds. The immutable sidecar remains in
    /// analysis time and carries the verified presentation origin, so migrate only `session.json`
    /// once and never rewrite the sidecar it references.
    private func migrateCanonicalTranscriptTimelineIfNeeded(
        _ inputSession: MeetingSession
    ) -> MeetingSession {
        guard inputSession.transcriptTimeDomain == nil,
              let reference = inputSession.resultSidecarReference,
              let attempt = inputSession.processingAttempts.last(where: {
                  $0.backendID != nil
                      && MeetingResultSidecarStore.fileName(for: $0.id) == reference.fileName
              }),
              let backendID = attempt.backendID.map({ MeetingBackendID(rawValue: $0) })
        else { return inputSession }

        let directory = self.sessionDirectoryURL(for: inputSession.id)
        let verifiedOrigin: TimeInterval?
        do {
            let sidecar = try MeetingResultSidecarStore(sessionDirectory: directory).read(
                expectedAttemptID: attempt.id,
                expectedBackendID: backendID,
                reference: reference
            )
            verifiedOrigin = sidecar.analysisManifest.presentationOriginSeconds
        } catch {
            verifiedOrigin = nil
            DebugLogger.shared.warning(
                "Could not verify canonical transcript sidecar while migrating timeline for "
                    + "\(inputSession.id): \(error.localizedDescription)",
                source: "MeetingSessionStore"
            )
        }

        let origin = verifiedOrigin ?? inputSession.timebase.firstPresentationTime?.seconds
        guard let origin,
              let migrated = Self.migratingCanonicalTimelineToMeetingRelative(
                  inputSession,
                  presentationOriginSeconds: origin
              )
        else {
            DebugLogger.shared.warning(
                "Canonical transcript timeline for \(inputSession.id) could not be migrated safely.",
                source: "MeetingSessionStore"
            )
            return inputSession
        }
        DebugLogger.shared.info(
            "Migrated canonical transcript timeline to meeting-relative seconds for \(inputSession.id).",
            source: "MeetingSessionStore"
        )
        return migrated
    }

    /// Pure migration seam used by load-time recovery and tests. A negative result beyond the
    /// rounding tolerance means the supplied origin does not describe this transcript, so refuse
    /// the whole migration instead of partially shifting or guessing.
    nonisolated static func migratingCanonicalTimelineToMeetingRelative(
        _ inputSession: MeetingSession,
        presentationOriginSeconds origin: TimeInterval
    ) -> MeetingSession? {
        guard inputSession.transcriptTimeDomain == nil, origin.isFinite, origin >= 0 else {
            return nil
        }
        let tolerance = MeetingAnalysisManifestSchema.mappingToleranceSeconds
        var migrated = inputSession

        for index in migrated.transcriptSegments.indices {
            let start = migrated.transcriptSegments[index].start.seconds - origin
            let end = migrated.transcriptSegments[index].end.seconds - origin
            guard start.isFinite, end.isFinite,
                  start >= -tolerance,
                  end + tolerance >= start,
                  let shiftedStart = Self.mediaTime(
                      seconds: max(0, start),
                      timescale: migrated.transcriptSegments[index].start.timescale
                  ),
                  let shiftedEnd = Self.mediaTime(
                      seconds: max(max(0, start), end),
                      timescale: migrated.transcriptSegments[index].end.timescale
                  )
            else { return nil }
            migrated.transcriptSegments[index].start = shiftedStart
            migrated.transcriptSegments[index].end = shiftedEnd
        }

        if var gaps = migrated.transcriptCoverageGaps {
            for index in gaps.indices {
                let start = gaps[index].start - origin
                let end = gaps[index].end - origin
                guard start.isFinite, end.isFinite,
                      start >= -tolerance,
                      end + tolerance >= start
                else { return nil }
                gaps[index].start = max(0, start)
                gaps[index].end = max(gaps[index].start, end)
            }
            migrated.transcriptCoverageGaps = gaps
        }

        migrated.transcriptTimeDomain = .meetingRelative
        return migrated
    }

    private nonisolated static func mediaTime(
        seconds: TimeInterval,
        timescale: Int32
    ) -> MeetingMediaTime? {
        guard seconds.isFinite, seconds >= 0, timescale > 0 else { return nil }
        let scaled = seconds * Double(timescale)
        guard scaled.isFinite,
              scaled >= Double(Int64.min),
              scaled <= Double(Int64.max)
        else { return nil }
        return MeetingMediaTime(value: Int64(scaled.rounded()), timescale: timescale)
    }

    private func reconcileTrackManifests(in inputSession: MeetingSession) throws -> MeetingSession {
        var session = inputSession

        // Audio was already deleted: never re-import a leftover tracks/ manifest from the crash
        // window between the cleared save and file removal — audioDeletedAt is authoritative.
        guard session.retention.audioDeletedAt == nil else {
            for index in session.audioTracks.indices where !session.audioTracks[index].chunks.isEmpty {
                session.audioTracks[index].chunks = []
            }
            try session.validateForPersistence()
            return session
        }

        let expectedKinds: Set<MeetingAudioTrackKind> = session.mode == .onlineCall
            ? [.applicationAudio, .microphone]
            : [.microphone]
        let sessionDirectory = self.sessionDirectoryURL(for: session.id)

        for kind in expectedKinds {
            let manifestURL = sessionDirectory
                .appendingPathComponent("tracks", isDirectory: true)
                .appendingPathComponent(kind.rawValue, isDirectory: true)
                .appendingPathComponent("track.json", isDirectory: false)
            guard self.fileSystem.manager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL, options: .mappedIfSafe),
                  var track = try? self.decoder.decode(MeetingAudioTrack.self, from: data),
                  track.kind == kind
            else { continue }

            track.chunks = track.chunks.map { chunk in
                self.reconcileChunkFile(chunk, sessionDirectory: sessionDirectory)
            }.sorted { $0.sequence < $1.sequence }

            var candidate = session
            if let index = candidate.audioTracks.firstIndex(where: { $0.kind == kind }) {
                guard candidate.audioTracks[index].id == track.id else { continue }
                candidate.audioTracks[index] = track
            } else {
                candidate.audioTracks.append(track)
            }
            candidate.audioTracks.sort { $0.kind.rawValue < $1.kind.rawValue }
            candidate.timebase.firstPresentationTime = candidate.audioTracks
                .flatMap(\.chunks)
                .map(\.presentationStart)
                .min()
            do {
                try candidate.validateForPersistence()
                session = candidate
            } catch {
                // A crash-window track manifest is subordinate to the last valid session snapshot.
                // Never let one malformed track make its sibling audio and recovery state unloadable.
                DebugLogger.shared.warning(
                    "Ignored invalid \(kind.rawValue) track recovery manifest: \(error.localizedDescription)",
                    source: "MeetingSessionStore"
                )
            }
        }

        session.audioTracks.sort { $0.kind.rawValue < $1.kind.rawValue }
        let firstPresentationTime = session.audioTracks
            .flatMap(\.chunks)
            .map(\.presentationStart)
            .min()
        if let firstPresentationTime {
            session.timebase.firstPresentationTime = firstPresentationTime
        }
        try session.validateForPersistence()
        return session
    }

    private func reconcileChunkFile(
        _ inputChunk: MeetingAudioChunk,
        sessionDirectory: URL
    ) -> MeetingAudioChunk {
        // New asset metadata is an explicit one-way boundary. Never apply the legacy
        // size-repair rule to it: a staged/foreign file must not become trusted merely because it
        // exists. Sessions with no new metadata retain the exact historical AAC behavior below.
        if inputChunk.audioSchemaVersion != nil || inputChunk.captureAnalysisAsset != nil || inputChunk.playbackArchiveAsset != nil {
            return self.reconcileNewAssetChunk(inputChunk, sessionDirectory: sessionDirectory)
        }
        guard inputChunk.finalizationState == .finalized else { return inputChunk }
        let fileURL = inputChunk.fileURL(relativeTo: sessionDirectory).standardizedFileURL
        let rootPath = sessionDirectory.standardizedFileURL.path + "/"
        guard fileURL.path.hasPrefix(rootPath),
              self.fileSystem.manager.fileExists(atPath: fileURL.path),
              let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize > 0
        else {
            var failedChunk = inputChunk
            failedChunk.sha256 = ""
            failedChunk.byteCount = 0
            failedChunk.finalizationState = .failed
            return failedChunk
        }
        var reconciled = inputChunk
        reconciled.byteCount = Int64(fileSize)
        return reconciled
    }

    private func reconcileNewAssetChunk(
        _ inputChunk: MeetingAudioChunk,
        sessionDirectory: URL
    ) -> MeetingAudioChunk {
        var failed = inputChunk
        func failCapture(_ chunk: inout MeetingAudioChunk) {
            chunk.sha256 = ""
            chunk.byteCount = 0
            chunk.finalizationState = .failed
            if var asset = chunk.captureAnalysisAsset, asset.presence == .ready { asset.presence = .failed; chunk.captureAnalysisAsset = asset }
        }
        guard let capture = inputChunk.captureAnalysisAsset,
              capture.role == .captureAnalysis,
              capture.presence == .ready,
              capture.validationIssues().isEmpty,
              self.assetMatchesDisk(capture, sessionDirectory: sessionDirectory)
        else {
            failCapture(&failed)
            return failed
        }
        var reconciled = inputChunk
        if var archive = reconciled.playbackArchiveAsset,
           archive.presence == .ready,
           !archive.validationIssues().isEmpty || !self.assetMatchesDisk(archive, sessionDirectory: sessionDirectory)
        {
            // The archive is derived and optional. Quarantine only it; authoritative PCM remains
            // finalized and retryable for a later archive job.
            archive.presence = .failed
            reconciled.playbackArchiveAsset = archive
        }
        reconciled.byteCount = capture.byteCount
        reconciled.sha256 = capture.sha256 ?? ""
        reconciled.finalizationState = .finalized
        return reconciled
    }

    private func assetMatchesDisk(_ asset: MeetingAudioAsset, sessionDirectory: URL) -> Bool {
        guard let url = self.confinedRegularAssetURL(
            relativePath: asset.relativeFilePath,
            sessionDirectory: sessionDirectory
        ), let attributes = try? self.fileSystem.manager.attributesOfItem(atPath: url.path),
        let size = (attributes[.size] as? NSNumber)?.int64Value,
        size == asset.byteCount,
        size > 0,
        let expectedHash = asset.sha256,
        let hash = self.sha256(of: url),
        hash == expectedHash
        else { return false }
        return true
    }

    /// Lexical confinement plus an lstat walk. A descriptor-relative walk is intentionally outside
    /// this additive foundation; concurrent path replacement remains a documented TOCTOU limit.
    private func confinedRegularAssetURL(relativePath: String, sessionDirectory: URL) -> URL? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        var current = sessionDirectory.standardizedFileURL
        var rootStat = stat()
        guard lstat(current.path, &rootStat) == 0, (rootStat.st_mode & S_IFMT) != S_IFLNK else { return nil }
        for part in parts {
            current.appendPathComponent(part, isDirectory: false)
            var info = stat()
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else { return nil }
        }
        var final = stat()
        guard lstat(current.path, &final) == 0, (final.st_mode & S_IFMT) == S_IFREG else { return nil }
        return current
    }

    private func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var digest = SHA256()
        while true {
            let data: Data
            do { data = try handle.read(upToCount: 1 << 20) ?? Data() } catch { return nil }
            guard !data.isEmpty else { break }
            digest.update(data: data)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func prepareRootDirectory() throws {
        if !self.fileSystem.manager.fileExists(atPath: self.rootDirectory.path) {
            try self.createPrivateDirectory(self.rootDirectory)
        }
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try self.fileSystem.manager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try self.fileSystem.manager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        #if os(iOS)
        try self.fileSystem.manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        var protectedURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        #endif
    }

    private func atomicPrivateWrite(_ data: Data, to destination: URL) throws {
        #if os(iOS)
        try data.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: destination, options: .atomic)
        #endif
        try self.fileSystem.manager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: destination.path
        )
        if MeetingRecordingCipher.isEncryptedEnvelope(data)
            || (self.encryptionCipher != nil && destination.lastPathComponent == "index.json") {
            let file = try FileHandle(forWritingTo: destination)
            defer { try? file.close() }
            try file.synchronize()
            let directory = Darwin.open(destination.deletingLastPathComponent().path,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { Darwin.close(directory) }
            guard fsync(directory) == 0 else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    private func readIndex() throws -> SessionIndex {
        let url = self.rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else {
            return SessionIndex(
                schemaVersion: SessionIndex.currentSchemaVersion,
                sessionIDs: [],
                updatedAt: Date()
            )
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try self.decoder.decode(SessionIndex.self, from: data)
    }

    private func addToIndex(_ id: MeetingSessionID, encrypted: Bool = false) throws {
        var index = (try? self.readIndex()) ?? SessionIndex(
            schemaVersion: SessionIndex.currentSchemaVersion,
            sessionIDs: [],
            updatedAt: Date()
        )
        // Membership does not change during a recording. Keep the on-disk read so a removed or
        // damaged index is repaired, without another atomic replacement on every checkpoint.
        let needsMembership = !index.sessionIDs.contains(id)
        let needsEncryptionMarker = encrypted && index.encryptedSessionIDs?.contains(id) != true
        guard needsMembership || needsEncryptionMarker else { return }
        if needsMembership { index.sessionIDs.append(id) }
        if needsEncryptionMarker {
            index.encryptedSessionIDs = Array(Set((index.encryptedSessionIDs ?? []) + [id]))
                .sorted { $0.uuidString < $1.uuidString }
        }
        index.updatedAt = Date()
        let data = try self.encoder.encode(index)
        try self.atomicPrivateWrite(
            data,
            to: self.rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        )
    }

    private func removeFromIndex(_ id: MeetingSessionID) throws {
        var index = (try? self.readIndex()) ?? SessionIndex(
            schemaVersion: SessionIndex.currentSchemaVersion,
            sessionIDs: [],
            updatedAt: Date()
        )
        index.sessionIDs.removeAll { $0 == id }
        index.encryptedSessionIDs?.removeAll { $0 == id }
        if index.encryptedSessionIDs?.isEmpty == true { index.encryptedSessionIDs = nil }
        self.encryptedSessionIDs.remove(id)
        index.updatedAt = Date()
        let data = try self.encoder.encode(index)
        try self.atomicPrivateWrite(
            data,
            to: self.rootDirectory.appendingPathComponent("index.json", isDirectory: false)
        )
    }

    private func discoverSessionIDs() throws -> [MeetingSessionID] {
        let urls = try self.fileSystem.manager.contentsOfDirectory(
            at: self.rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }
            return UUID(uuidString: url.lastPathComponent)
        }
    }

    private func sessionDirectoryURL(for id: MeetingSessionID) -> URL {
        self.rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func sessionManifestURL(for id: MeetingSessionID) -> URL {
        self.sessionDirectoryURL(for: id)
            .appendingPathComponent("session.json", isDirectory: false)
    }
}

enum MeetingSessionStoreError: LocalizedError {
    case sessionAlreadyExists
    case unsupportedSchema(Int)
    case sessionDeleted
    case historyUnavailable

    var errorDescription: String? {
        switch self {
        case .sessionAlreadyExists:
            return "A meeting session with this identifier already exists."
        case let .unsupportedSchema(version):
            return "This meeting was created with unsupported schema version \(version)."
        case .sessionDeleted:
            return "This meeting has been deleted."
        case .historyUnavailable:
            return PichiLocalization.text("Meeting history could not be loaded.")
        }
    }
}
