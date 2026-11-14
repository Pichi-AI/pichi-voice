import CryptoKit
import Foundation
import SQLite3

/// Owned by the history writer's serial queue. One JSON payload per entry, not per history.
nonisolated final class TranscriptionHistoryDatabase {
    struct Record: Equatable {
        let id: UUID
        let payload: Data
    }

    private let connection: OpaquePointer

    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open history."
            if let handle { sqlite3_close(handle) }
            throw NSError(domain: "HistoryDatabase", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
        }
        self.connection = handle
        do {
            try self.execute("PRAGMA busy_timeout=2000")
            try self.execute("PRAGMA journal_mode=WAL")
            try self.execute("PRAGMA synchronous=FULL")
            try self.execute("PRAGMA secure_delete=ON")
            try self.execute("CREATE TABLE IF NOT EXISTS history (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try self.execute("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY)")
            try self.transaction {
                if try !self.containsMetadata("legacy_accounting_v1") {
                    // Old Pichi receipts know the source bytes, but not which imported IDs were
                    // subsequently cleared. Unknown IDs in a changed source are ambiguous.
                    if let digest = try self.legacySourceDigest {
                        try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_unaccounted_sha256:\(digest)')")
                    }
                    try self.execute("INSERT OR IGNORE INTO metadata(key) SELECT 'legacy_seen:' || id FROM history")
                    try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_accounting_v1')")
                }
            }
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit { sqlite3_close(self.connection) }

    var isMigrated: Bool {
        get throws {
            let statement = try self.prepare("SELECT 1 FROM metadata WHERE key='legacy_imported'")
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            guard result == SQLITE_ROW || result == SQLITE_DONE else { throw self.error() }
            return result == SQLITE_ROW
        }
    }

    var legacySourceDigest: String? {
        get throws {
            let statement = try self.prepare("SELECT key FROM metadata WHERE key LIKE 'legacy_source_sha256:%' LIMIT 1")
            defer { sqlite3_finalize(statement) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { throw self.error() }
            return String(cString: text).replacingOccurrences(of: "legacy_source_sha256:", with: "")
        }
    }

    /// Compatibility for callers that deliberately request the original one-time migration.
    func migrate(_ records: [Record], legacySourceDigest: String? = nil) throws {
        guard try !self.isMigrated else { return }
        try self.importLegacy(records, legacySourceDigest: legacySourceDigest)
    }

    /// Repeatable imports admit unseen IDs, but never resurrect explicitly deleted history.
    /// Both tombstones and digest receipts commit with the imported rows.
    @discardableResult func importLegacy(_ records: [Record], legacySourceDigest: String? = nil) throws -> Bool {
        if let digest = legacySourceDigest {
            guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw NSError(domain: "HistoryDatabase", code: 2)
            }
        }
        var imported = false
        try self.transaction {
            if let digest = legacySourceDigest, try self.containsMetadata("legacy_unaccounted_sha256:\(digest)") {
                // The original exact source can establish the missing deletion ledger safely.
                for record in records {
                    try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_seen:\(record.id.uuidString)')")
                    if try !self.containsHistory(record.id) {
                        try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_deleted:\(record.id.uuidString)')")
                    }
                }
                try self.execute("DELETE FROM metadata WHERE key='legacy_unaccounted_sha256:\(digest)'")
            }
            guard try self.canImportLegacy(records, legacySourceDigest: legacySourceDigest) else { return }
            imported = true
            if let digest = legacySourceDigest, try self.containsMetadata("legacy_source_sha256:\(digest)") { return }
            for record in records {
                try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_seen:\(record.id.uuidString)')")
                if try !self.containsMetadata("legacy_deleted:\(record.id.uuidString)") {
                    try self.upsert(record, overwriting: false)
                }
            }
            try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_imported')")
            if let digest = legacySourceDigest {
                try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_source_sha256:\(digest)')")
            }
        }
        return imported
    }

    func canImportLegacy(_ records: [Record], legacySourceDigest: String? = nil) throws -> Bool {
        if let digest = legacySourceDigest, try self.containsMetadata("legacy_unaccounted_sha256:\(digest)") { return true }
        let statement = try self.prepare("SELECT 1 FROM metadata WHERE key LIKE 'legacy_unaccounted_sha256:%' LIMIT 1")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw self.error() }
        guard result == SQLITE_ROW else { return true }
        for record in records {
            if try !self.containsHistory(record.id) && !self.containsMetadata("legacy_deleted:\(record.id.uuidString)") { return false }
        }
        return true
    }

    private func containsHistory(_ id: UUID) throws -> Bool {
        let statement = try self.prepare("SELECT 1 FROM history WHERE id='\(id.uuidString)'")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw self.error() }
        return result == SQLITE_ROW
    }

    private func containsMetadata(_ key: String) throws -> Bool {
        let statement = try self.prepare("SELECT 1 FROM metadata WHERE key='\(key)'")
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw self.error() }
        return result == SQLITE_ROW
    }

    func read() throws -> [Record] {
        let statement = try self.prepare("SELECT id, payload FROM history")
        defer { sqlite3_finalize(statement) }
        var records: [Record] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW,
                  let text = sqlite3_column_text(statement, 0),
                  let id = UUID(uuidString: String(cString: text)),
                  let bytes = sqlite3_column_blob(statement, 1)
            else { throw self.error() }
            records.append(Record(id: id, payload: Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 1)))))
        }
    }

    func write(upserts: [Record], deletes: [UUID], replacing: Bool) throws {
        try self.transaction {
            if replacing {
                try self.execute("INSERT OR IGNORE INTO metadata(key) SELECT 'legacy_deleted:' || id FROM history")
                try self.execute("INSERT OR IGNORE INTO metadata(key) SELECT replace(key, 'legacy_seen:', 'legacy_deleted:') FROM metadata WHERE key LIKE 'legacy_seen:%'")
                try self.execute("DELETE FROM history")
            }
            for id in deletes {
                // UUID's canonical representation contains no SQL metacharacters.
                try self.execute("INSERT OR IGNORE INTO metadata(key) VALUES ('legacy_deleted:\(id.uuidString)')")
                try self.execute("DELETE FROM history WHERE id='\(id.uuidString)'")
            }
            for record in upserts {
                try self.upsert(record)
            }
        }
    }

    private func upsert(_ record: Record, overwriting: Bool = true) throws {
        let conflict = overwriting ? "REPLACE" : "IGNORE"
        let statement = try self.prepare("INSERT OR \(conflict) INTO history(id,payload) VALUES ('\(record.id.uuidString)',?)")
        defer { sqlite3_finalize(statement) }
        let result = record.payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw self.error() }
    }

    private func transaction(_ body: () throws -> Void) throws {
        try self.execute("BEGIN IMMEDIATE")
        do {
            try body()
            try self.execute("COMMIT")
        } catch {
            try? self.execute("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(self.connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw self.error()
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(self.connection, sql, nil, nil, nil) == SQLITE_OK else { throw self.error() }
    }

    private func error() -> Error {
        NSError(domain: "HistoryDatabase", code: Int(sqlite3_errcode(self.connection)), userInfo: [
            NSLocalizedDescriptionKey: String(cString: sqlite3_errmsg(self.connection)),
        ])
    }
}

/// Unforgeable, entry-scoped write capability. Visibility can close without retargeting an
/// admitted recording; replacing its owner/generation or finishing it revokes further writes.
nonisolated final class TranscriptionHistoryWriteAdmission: @unchecked Sendable {
    let entryID: UUID
    let saveGeneration: UInt64
    let profile: PrivateProfileSnapshot
    fileprivate let writerID: UUID
    fileprivate let legacyData: Data?
    private let lock = NSLock()
    private var active = true
    private var failure: Error?

    fileprivate init(entryID: UUID, saveGeneration: UInt64, profile: PrivateProfileSnapshot,
                     writerID: UUID, legacyData: Data?) {
        self.entryID = entryID; self.saveGeneration = saveGeneration; self.profile = profile
        self.writerID = writerID; self.legacyData = legacyData
    }
    var isActiveForCurrentOwner: Bool {
        self.lock.withLock {
            let current = PrivateProfileStorage.current
            return self.active && current.id == self.profile.id && current.generation == self.profile.generation
        }
    }
    fileprivate func close() { self.lock.withLock { self.active = false } }
    fileprivate func recordFailure(_ error: Error) { self.lock.withLock { self.failure = error } }
    fileprivate func recordSuccess() { self.lock.withLock { self.failure = nil } }
    fileprivate var recordedFailure: Error? { self.lock.withLock { self.failure } }
}

/// All disk queries and Codable work happen here, including repeatable profile-local legacy imports.
nonisolated final class TranscriptionHistoryWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let writerID = UUID()
    private let admissionsLock = NSLock()
    private var activeAdmissions: Set<ObjectIdentifier> = []
    private let didReadSnapshot: @Sendable () -> Void
    private let didEnqueueDrain: @Sendable () -> Void
    private var database: TranscriptionHistoryDatabase?
    private var writeError: Error?
    private var admittedWriteFailures: [UUID: Error] = [:]
    private let defaults: UserDefaults
    private let otherInstallDefaults: [UserDefaults]
    private let url: URL
    private let legacyKey = "TranscriptionHistoryEntries"
    private let profile: PrivateProfileSnapshot?

    init(defaults: UserDefaults? = nil, url: URL? = nil, profile: PrivateProfileSnapshot? = nil,
         otherInstallDefaults: [UserDefaults] = [],
         queue: DispatchQueue? = nil, didReadSnapshot: @escaping @Sendable () -> Void = {},
         didEnqueueDrain: @escaping @Sendable () -> Void = {}) {
        self.didReadSnapshot = didReadSnapshot
        self.didEnqueueDrain = didEnqueueDrain
        self.queue = queue ?? DispatchQueue(label: "fluid.history.persistence", qos: .utility)
        let selected = profile ?? (defaults == nil && url == nil ? PrivateProfileStorage.current : nil)
        self.profile = selected
        // Additional sources require an explicitly injected, authorized test store and URL.
        self.otherInstallDefaults = defaults != nil && url != nil ? otherInstallDefaults : []
        self.defaults = defaults ?? PrivateProfileDefaults.bound(to: selected ?? PrivateProfileStorage.current)
        self.url = url ?? (selected ?? PrivateProfileStorage.current).rootDirectory
            .appendingPathComponent("TranscriptionHistory.sqlite3")
    }

    private var canAccess: Bool { self.profile.map(PrivateProfileStorage.isReadable) != false }

    func admitRecordingWrite(entryID: UUID, saveGeneration: UInt64) throws -> TranscriptionHistoryWriteAdmission {
        guard self.canAccess, PrivateProfileStorage.acceptsNewWork else { throw CancellationError() }
        let profile = self.profile ?? PrivateProfileStorage.current
        let legacyData = self.defaults.data(forKey: self.legacyKey)
        guard self.canAccess, PrivateProfileStorage.acceptsNewWork,
              PrivateProfileStorage.isReadable(profile) else { throw CancellationError() }
        let admission = TranscriptionHistoryWriteAdmission(entryID: entryID, saveGeneration: saveGeneration,
            profile: profile, writerID: self.writerID, legacyData: legacyData)
        self.admissionsLock.withLock { _ = self.activeAdmissions.insert(ObjectIdentifier(admission)) }
        return admission
    }

    var hasUnimportedLegacyHistory: Bool {
        guard self.canAccess else { return true }
        return ([self.defaults] + self.otherInstallDefaults).contains { $0.data(forKey: self.legacyKey) != nil }
    }

    func load() async throws -> [TranscriptionHistoryEntry] {
        guard self.canAccess else { throw CancellationError() }
        // Defaults are visibility-gated. Reading them after dispatch could turn a real
        // legacy source into an empty migration when logout conceals the profile.
        let snapshots = ([self.defaults] + self.otherInstallDefaults).compactMap { source in
            source.data(forKey: self.legacyKey).map { (source, $0) }
        }
        guard self.canAccess else { throw CancellationError() }
        let entries: [TranscriptionHistoryEntry] = try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                do {
                    let database = try self.database ?? TranscriptionHistoryDatabase(url: self.url)
                    self.database = database
                    var imported: [(UserDefaults, Data)] = []
                    for (source, data) in snapshots {
                        do {
                            let legacy = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data)
                            if try database.importLegacy(legacy.map { try self.record($0) }, legacySourceDigest: Self.digest(data)) {
                                imported.append((source, data))
                            }
                        } catch is DecodingError {
                            // Preserve unreadable bytes for explicit recovery without hiding valid SQLite rows.
                            DebugLogger.shared.warning("Skipped unreadable legacy history; recovery is available in Settings", source: "TranscriptionHistoryStore")
                        }
                    }
                    if try !database.isMigrated { try database.migrate([]) }
                    let entries = try database.read().map {
                        try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: $0.payload)
                    }.sorted { $0.timestamp > $1.timestamp }
                    self.didReadSnapshot()
                    // The transaction is committed and every payload decoded before retiring legacy storage.
                    if self.canAccess {
                        for (source, data) in imported where source.data(forKey: self.legacyKey) == data {
                            guard self.canAccess else { break }
                            source.removeObject(forKey: self.legacyKey)
                        }
                    }
                    DebugLogger.shared.debug("HISTORY_BENCH loaded entries=\(entries.count) storage=sqlite", source: "TranscriptionHistoryStore")
                    continuation.resume(returning: entries)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        guard self.canAccess else { throw CancellationError() }
        return entries
    }

    /// Only the original entry is writable after conceal. No deletion, replacement,
    /// arbitrary batch or read privilege is granted by this recording capability.
    func write(_ entry: TranscriptionHistoryEntry, admission: TranscriptionHistoryWriteAdmission,
               completion: @escaping @Sendable (Error?) -> Void) {
        guard admission.writerID == self.writerID, admission.entryID == entry.id,
              admission.isActiveForCurrentOwner else { completion(CancellationError()); return }
        self.queue.async {
            do {
                let database = try self.database ?? TranscriptionHistoryDatabase(url: self.url)
                self.database = database
                if let data = admission.legacyData {
                    do {
                        let legacy = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data)
                        try database.importLegacy(legacy.map { try self.record($0) }, legacySourceDigest: Self.digest(data))
                    } catch is DecodingError {
                        // Corrupt legacy bytes remain recoverable and do not block admitted new audio/history.
                    }
                }
                try database.write(upserts: [self.record(entry)], deletes: [], replacing: false)
                admission.recordSuccess()
                self.admittedWriteFailures.removeValue(forKey: admission.entryID)
                completion(nil)
            } catch {
                admission.recordFailure(error)
                self.admittedWriteFailures[admission.entryID] = error
                completion(error)
            }
        }
    }

    func revoke(_ admission: TranscriptionHistoryWriteAdmission) {
        guard admission.writerID == self.writerID else { return }
        admission.close()
        self.admissionsLock.withLock { _ = self.activeAdmissions.remove(ObjectIdentifier(admission)) }
        // Preserve FIFO: accepted upserts may still finish, then their now-obsolete
        // failure retires before the user's deletion/replacement is enqueued.
        self.queue.async {
            admission.recordSuccess()
            self.admittedWriteFailures.removeValue(forKey: admission.entryID)
        }
    }

    func finish(_ admission: TranscriptionHistoryWriteAdmission) async throws {
        guard admission.writerID == self.writerID else { throw CancellationError() }
        _ = await self.drain()
        if let error = admission.recordedFailure { throw error }
        admission.close()
        self.admissionsLock.withLock { _ = self.activeAdmissions.remove(ObjectIdentifier(admission)) }
    }

    func pendingLegacyHistory() async -> Bool {
        await withCheckedContinuation { continuation in
            self.queue.async { continuation.resume(returning: self.hasUnimportedLegacyHistory) }
        }
    }

    /// Only called after the user agrees to resume cleanup of potentially unrecoverable old audio.
    /// Save every original byte before retiring any key; failed copies and concurrent rewrites leave keys intact.
    func archiveUnreadableLegacyHistory() async throws -> URL {
        guard self.canAccess else { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                continuation.resume(with: Result { try self.archiveUnreadableLegacyHistoryOnQueue() })
            }
        }
    }

    private func archiveUnreadableLegacyHistoryOnQueue() throws -> URL {
        guard self.canAccess else { throw CancellationError() }
        guard self.admissionsLock.withLock({ self.activeAdmissions.isEmpty }) else {
            throw NSError(domain: "HistoryRecovery", code: 5, userInfo: [NSLocalizedDescriptionKey: PichiLocalization.text("Finish pending recordings before saving a recovery copy.")])
        }
        let snapshots = ([self.defaults] + self.otherInstallDefaults).compactMap { source in
            source.data(forKey: self.legacyKey).map { (source, $0) }
        }
        for (_, data) in snapshots {
            do {
                let legacy = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: data)
                let database = try self.database ?? TranscriptionHistoryDatabase(url: self.url)
                self.database = database
                if try database.canImportLegacy(legacy.map { try self.record($0) }, legacySourceDigest: Self.digest(data)) {
                    throw NSError(domain: "HistoryRecovery", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: AppBrand.text("Older history can be imported. Restart the app before resuming audio cleanup."),
                    ])
                }
                // A readable but ambiguous pre-ledger snapshot also requires an exact recovery
                // export, not automatic restoration of possibly deleted IDs.
            } catch is DecodingError {
                // Only unreadable data takes this explicit recovery path. Valid history is imported at startup.
            }
        }
        let recoveryRoot = self.url.deletingLastPathComponent().appendingPathComponent("History Recovery", isDirectory: true)
        let anchor = self.profile?.legacyRootDirectory ?? self.url.deletingLastPathComponent()
        try Self.validateRecoveryDirectory(recoveryRoot, anchor: anchor)
        let directory = recoveryRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        var completed = false
        defer {
            // Only this attempt's copies are disposable; originals are untouched on every failure.
            if !completed { try? FileManager.default.removeItem(at: directory) }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Self.validateRecoveryDirectory(directory, anchor: anchor)
        for (index, snapshot) in snapshots.enumerated() {
            let file = directory.appendingPathComponent("legacy-\(index).json")
            try snapshot.1.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            guard try Data(contentsOf: file) == snapshot.1 else { throw NSError(domain: "HistoryRecovery", code: 3) }
        }
        // The normal export only includes loaded rows. Preserve the entire shared audio folder,
        // including files whose references are trapped in unreadable legacy data, before cleanup resumes.
        let audioDirectory = self.url.deletingLastPathComponent().appendingPathComponent("DictationAudioHistory", isDirectory: true)
        var hasAudioDirectory = true
        do {
            _ = try FileManager.default.attributesOfItem(atPath: audioDirectory.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            hasAudioDirectory = false
        }
        var audioManifest: [String: Data]?
        if hasAudioDirectory {
            let before = try Self.recoveryManifest(audioDirectory)
            audioManifest = before
            let copy = directory.appendingPathComponent("audio", isDirectory: true)
            try FileManager.default.copyItem(at: audioDirectory, to: copy)
            guard try Self.recoveryManifest(copy) == before,
                  try Self.recoveryManifest(audioDirectory) == before else {
                throw NSError(domain: "HistoryRecovery", code: 3)
            }
        }
        guard self.canAccess, snapshots.allSatisfy({ $0.0.data(forKey: self.legacyKey) == $0.1 }) else {
            throw NSError(domain: "HistoryRecovery", code: 2, userInfo: [
                NSLocalizedDescriptionKey: AppBrand.text("Older history changed while saving its recovery copy. Close other running builds of this app and try again. No history was removed."),
            ])
        }
        guard self.admissionsLock.withLock({ self.activeAdmissions.isEmpty }) else { throw NSError(domain: "HistoryRecovery", code: 5) }
        if let audioManifest {
            guard try Self.recoveryManifest(audioDirectory) == audioManifest else { throw NSError(domain: "HistoryRecovery", code: 3) }
        } else if FileManager.default.fileExists(atPath: audioDirectory.path) {
            throw NSError(domain: "HistoryRecovery", code: 3)
        }
        // From the first retirement onward the verified export is needed even if visibility
        // changes between explicitly injected sources. Never discard the only copy on error.
        completed = true
        for (source, _) in snapshots {
            guard self.canAccess else { throw CancellationError() }
            source.removeObject(forKey: self.legacyKey)
        }
        return directory
    }

    private static func validateRecoveryDirectory(_ directory: URL, anchor: URL) throws {
        let root = anchor.standardizedFileURL
        let components = directory.standardizedFileURL.pathComponents
        guard components.starts(with: root.pathComponents) else { throw NSError(domain: "HistoryRecovery", code: 4) }
        var folder = root
        for part in [""] + Array(components.dropFirst(root.pathComponents.count)) {
            if !part.isEmpty { folder.appendPathComponent(part) }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NSError(domain: "HistoryRecovery", code: 4) }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        }
    }

    private static func recoveryManifest(_ directory: URL) throws -> [String: Data] {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw NSError(domain: "HistoryRecovery", code: 4) }
        var result: [String: Data] = [:]
        func visit(_ folder: URL, prefix: String) throws {
            for item in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                let name = prefix + item.lastPathComponent
                let attributes = try fm.attributesOfItem(atPath: item.path)
                switch attributes[.type] as? FileAttributeType {
                case .typeDirectory:
                    result[name + "/"] = Data()
                    try visit(item, prefix: name + "/")
                case .typeRegular:
                    result[name] = try self.recoveryFileDigest(item)
                default: throw NSError(domain: "HistoryRecovery", code: 4)
                }
            }
        }
        try visit(directory, prefix: "")
        return result
    }

    private static func recoveryFileDigest(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let bytes = try handle.read(upToCount: 64 * 1024), !bytes.isEmpty { digest.update(data: bytes) }
        return Data(digest.finalize())
    }

    /// Audio referenced by the database, including rows another running install added after this load.
    /// Both run after every write already queued here.
    func savedAudioFileNames() throws -> Set<String> {
        try self.queue.sync { try self.readSavedAudioFileNames() }
    }

    func savedAudioFileNames() async throws -> Set<String> {
        try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                continuation.resume(with: Result { try self.readSavedAudioFileNames() })
            }
        }
    }

    private func readSavedAudioFileNames() throws -> Set<String> {
        guard let database = self.database else {
            throw NSError(domain: "HistoryDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: "History is not loaded."])
        }
        return try Set(database.read().compactMap {
            try JSONDecoder().decode(AudioReference.self, from: $0.payload).audio?.fileName
        })
    }

    private nonisolated struct AudioReference: Decodable {
        nonisolated struct Audio: Decodable { let fileName: String }
        let audio: Audio?
    }

    func write(
        upserts: [TranscriptionHistoryEntry], deletes: [UUID] = [], replacing: Bool = false,
        completion: @escaping @Sendable (Error?) -> Void
    ) {
        guard self.canAccess else { completion(CancellationError()); return }
        self.queue.async {
            let startedAt = ProcessInfo.processInfo.systemUptime
            do {
                guard let database = self.database else {
                    throw NSError(domain: "HistoryDatabase", code: 1, userInfo: [NSLocalizedDescriptionKey: "History is not loaded."])
                }
                let records = try upserts.map { try self.record($0) }
                try database.write(upserts: records, deletes: deletes, replacing: replacing)
                if replacing { self.writeError = nil }
                let finishedAt = ProcessInfo.processInfo.systemUptime
                DebugLogger.shared.debug(
                    "HISTORY_BENCH t=\(finishedAt) background=true upserts=\(upserts.count) deletes=\(deletes.count) " +
                        "replace=\(replacing) bytes=\(records.reduce(0) { $0 + $1.payload.count }) totalMs=\((finishedAt - startedAt) * 1000)",
                    source: "TranscriptionHistoryStore"
                )
                completion(nil)
            } catch {
                self.writeError = error
                completion(error)
            }
        }
    }

    func drain() async -> Error? {
        await withCheckedContinuation { continuation in
            self.queue.async { continuation.resume(returning: self.writeError ?? self.admittedWriteFailures.values.first) }
            self.didEnqueueDrain()
        }
    }

    private static func digest(_ data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    private func record(_ entry: TranscriptionHistoryEntry) throws -> TranscriptionHistoryDatabase.Record {
        try TranscriptionHistoryDatabase.Record(id: entry.id, payload: JSONEncoder().encode(entry))
    }
}
