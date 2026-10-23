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

    func migrate(_ records: [Record], legacySourceDigest: String? = nil) throws {
        guard try !self.isMigrated else { return }
        try self.transaction {
            for record in records {
                try self.upsert(record)
            }
            try self.execute("INSERT INTO metadata(key) VALUES ('legacy_imported')")
            if let digest = legacySourceDigest {
                guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    throw NSError(domain: "HistoryDatabase", code: 2)
                }
                try self.execute("INSERT INTO metadata(key) VALUES ('legacy_source_sha256:\(digest)')")
            }
        }
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
            if replacing { try self.execute("DELETE FROM history") }
            for id in deletes {
                // UUID's canonical representation contains no SQL metacharacters.
                try self.execute("DELETE FROM history WHERE id='\(id.uuidString)'")
            }
            for record in upserts {
                try self.upsert(record)
            }
        }
    }

    private func upsert(_ record: Record) throws {
        let statement = try self.prepare("INSERT OR REPLACE INTO history(id,payload) VALUES ('\(record.id.uuidString)',?)")
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

/// All disk queries and Codable work happen here, including the one-time legacy import.
nonisolated final class TranscriptionHistoryWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let writerID = UUID()
    private let didReadSnapshot: @Sendable () -> Void
    private var database: TranscriptionHistoryDatabase?
    private var writeError: Error?
    private var admittedWriteFailures: [UUID: Error] = [:]
    private let defaults: UserDefaults
    private let url: URL
    private let legacyKey = "TranscriptionHistoryEntries"
    private let profile: PrivateProfileSnapshot?

    init(defaults: UserDefaults? = nil, url: URL? = nil, profile: PrivateProfileSnapshot? = nil,
         queue: DispatchQueue? = nil, didReadSnapshot: @escaping @Sendable () -> Void = {}) {
        self.didReadSnapshot = didReadSnapshot
        self.queue = queue ?? DispatchQueue(label: "fluid.history.persistence", qos: .utility)
        let selected = profile ?? (defaults == nil && url == nil ? PrivateProfileStorage.current : nil)
        self.profile = selected
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
        return TranscriptionHistoryWriteAdmission(entryID: entryID, saveGeneration: saveGeneration,
            profile: profile, writerID: self.writerID, legacyData: legacyData)
    }

    func load() async throws -> [TranscriptionHistoryEntry] {
        guard self.canAccess else { throw CancellationError() }
        // Defaults are visibility-gated. Reading them after dispatch could turn a real
        // legacy source into an empty migration when logout conceals the profile.
        let legacyData = self.defaults.data(forKey: self.legacyKey)
        guard self.canAccess else { throw CancellationError() }
        let entries: [TranscriptionHistoryEntry] = try await withCheckedThrowingContinuation { continuation in
            self.queue.async {
                do {
                    let database = try self.database ?? TranscriptionHistoryDatabase(url: self.url)
                    self.database = database
                    if try !database.isMigrated {
                        let legacy = try legacyData.map {
                            try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: $0)
                        } ?? []
                        try database.migrate(legacy.map { try self.record($0) }, legacySourceDigest: Self.digest(legacyData))
                    }
                    let entries = try database.read().map {
                        try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: $0.payload)
                    }.sorted { $0.timestamp > $1.timestamp }
                    self.didReadSnapshot()
                    // The transaction is committed and every payload decoded before retiring legacy storage.
                    if let legacyData, try database.legacySourceDigest == Self.digest(legacyData),
                       self.defaults.data(forKey: self.legacyKey) == legacyData {
                        self.defaults.removeObject(forKey: self.legacyKey)
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
                if try !database.isMigrated {
                    let legacy = try admission.legacyData.map { try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: $0) } ?? []
                    try database.migrate(legacy.map { try self.record($0) }, legacySourceDigest: Self.digest(admission.legacyData))
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
        }
    }

    private static func digest(_ data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }

    private func record(_ entry: TranscriptionHistoryEntry) throws -> TranscriptionHistoryDatabase.Record {
        try TranscriptionHistoryDatabase.Record(id: entry.id, payload: JSONEncoder().encode(entry))
    }
}
