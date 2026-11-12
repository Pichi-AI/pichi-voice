import CryptoKit
import Darwin
import Foundation

/// Self-describing capture metadata is stored inside its CAF as well as in the optional
/// journal. A damaged index must not orphan PCM or require guessing its clock or provenance.
nonisolated struct MeetingAudioRecoveryCapsule: Codable, Sendable {
    var trackID: MeetingAudioTrackID
    var kind: MeetingAudioTrackKind
    var chunk: MeetingAudioChunk
    var sessionID: MeetingSessionID? = nil
    var captureEras: [MeetingCaptureEra]? = nil
}

/// P0b writer-ledger facts. These are intentionally standalone and optional at the session layer:
/// old session JSON never contains them, while the PCM-first writer durably checkpoints each new
/// capture chunk. Legacy AAC sessions continue to decode without these records.
nonisolated struct MeetingAudioChunkLedgerIntent: Codable, Equatable, Sendable {
    var chunkID: MeetingAudioChunkID
    var sequence: Int
    var canonicalStart: MeetingMediaTime
    var producerEpoch: UInt64
    var sourceFormat: MeetingAudioFormat
    var partialRelativeFilePath: String
    var createdAt: Date
}

nonisolated struct MeetingAudioChunkLedgerCheckpoint: Codable, Equatable, Sendable {
    var chunkID: MeetingAudioChunkID
    var expectedFrames: Int64
    var writtenFrames: Int64
    var lastCanonicalPTS: MeetingMediaTime?
    var updatedAt: Date
}

nonisolated enum MeetingAudioChunkLedgerTerminalStatus: Equatable, Sendable {
    case ready
    case failed
    case unknown(String)

    var rawValue: String {
        switch self {
        case .ready: return "ready"
        case .failed: return "failed"
        case let .unknown(raw): return raw
        }
    }

    init(rawValue: String) { self = rawValue == "ready" ? .ready : rawValue == "failed" ? .failed : .unknown(rawValue) }
}

nonisolated extension MeetingAudioChunkLedgerTerminalStatus: Codable {
    init(from decoder: Decoder) throws { try self.init(rawValue: decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(self.rawValue) }
}

nonisolated struct MeetingAudioChunkLedgerTerminal: Codable, Equatable, Sendable {
    var chunkID: MeetingAudioChunkID
    var status: MeetingAudioChunkLedgerTerminalStatus
    var updatedAt: Date
    var detail: String?
}

nonisolated enum MeetingAudioChunkLedgerError: Error, Equatable, Sendable {
    case invalidChunkID
    case pathRejected
    case conflictingIntent
    case checkpointRegression
    case incompleteReadyTerminal
    case terminalAlreadyExists
    case durabilityFailure(String)
}

/// A serialized-queue-only ledger store. It does no dispatching or locking itself, and must never
/// be called by a real-time callback. Intent is immutable/no-overwrite; checkpoints are atomic
/// replacements; terminal status is immutable/no-overwrite. Every record is fsynced before its
/// rename and the containing directory is fsynced after publication.
final nonisolated class MeetingAudioChunkLedgerStore: @unchecked Sendable {
    let sessionDirectory: URL
    private let ledgerDirectoryName = "chunk-ledger"

    init(sessionDirectory: URL) { self.sessionDirectory = sessionDirectory.standardizedFileURL }

    struct CaptureRecord: Codable, Sendable {
        var trackID: MeetingAudioTrackID
        var kind: MeetingAudioTrackKind
        var chunk: MeetingAudioChunk
    }

    func writeCapture(_ record: CaptureRecord) throws {
        try self.validate(record.chunk.relativeFilePath)
        try self.ensureLedgerDirectory()
        try self.writeReplacing(self.encode(record), to: self.recordURL(chunkID: record.chunk.id, suffix: "capture"))
    }

    func readCaptures(trackID: MeetingAudioTrackID, kind: MeetingAudioTrackKind) throws -> [MeetingAudioChunk] {
        let directory = self.sessionDirectory.appendingPathComponent(self.ledgerDirectoryName)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { throw MeetingAudioChunkLedgerError.pathRejected }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        guard names.count <= 100_000 else { throw MeetingAudioChunkLedgerError.pathRejected }
        var chunks: [MeetingAudioChunk] = []
        for name in names where name.hasSuffix(".capture.json") {
            let url = directory.appendingPathComponent(name)
            var file = stat()
            guard lstat(url.path, &file) == 0, (file.st_mode & S_IFMT) == S_IFREG,
                  file.st_size > 0, file.st_size <= 8 * 1024 * 1024,
                  let record = try? self.read(CaptureRecord.self, at: url),
                  record.trackID == trackID, record.kind == kind else { continue }
            try self.validate(record.chunk.relativeFilePath)
            chunks.append(record.chunk)
        }
        return chunks.sorted { $0.sequence < $1.sequence }
    }

    func writeIntent(_ intent: MeetingAudioChunkLedgerIntent) throws {
        try self.validate(intent.partialRelativeFilePath)
        try self.ensureLedgerDirectory()
        let url = try recordURL(chunkID: intent.chunkID, suffix: "intent")
        try self.writeImmutable(self.encode(intent), to: url, conflict: .conflictingIntent)
    }

    func writeCheckpoint(_ checkpoint: MeetingAudioChunkLedgerCheckpoint, for chunkID: MeetingAudioChunkID) throws {
        guard checkpoint.chunkID == chunkID else { throw MeetingAudioChunkLedgerError.invalidChunkID }
        guard try self.readIntent(for: chunkID) != nil else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("checkpoint has no intent")
        }
        guard checkpoint.expectedFrames >= 0, checkpoint.writtenFrames >= 0,
              checkpoint.writtenFrames <= checkpoint.expectedFrames
        else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("invalid checkpoint frame totals")
        }
        if let previous = try readCheckpoint(for: chunkID) {
            guard checkpoint.expectedFrames >= previous.expectedFrames,
                  checkpoint.writtenFrames >= previous.writtenFrames,
                  Self.isNondecreasing(previous.lastCanonicalPTS, checkpoint.lastCanonicalPTS)
            else { throw MeetingAudioChunkLedgerError.checkpointRegression }
        }
        try self.ensureLedgerDirectory()
        try self.writeReplacing(self.encode(checkpoint), to: self.recordURL(chunkID: chunkID, suffix: "checkpoint"))
    }

    func writeTerminal(_ terminal: MeetingAudioChunkLedgerTerminal, for chunkID: MeetingAudioChunkID) throws {
        guard terminal.chunkID == chunkID else { throw MeetingAudioChunkLedgerError.invalidChunkID }
        guard try self.readIntent(for: chunkID) != nil else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("terminal has no intent")
        }
        if terminal.status == .ready {
            guard let checkpoint = try readCheckpoint(for: chunkID),
                  checkpoint.expectedFrames > 0,
                  checkpoint.expectedFrames == checkpoint.writtenFrames
            else { throw MeetingAudioChunkLedgerError.incompleteReadyTerminal }
        }
        try self.ensureLedgerDirectory()
        try self.writeImmutable(self.encode(terminal), to: self.recordURL(chunkID: chunkID, suffix: "terminal"), conflict: .terminalAlreadyExists)
    }

    func readIntent(for chunkID: MeetingAudioChunkID) throws -> MeetingAudioChunkLedgerIntent? { try self.read(
        MeetingAudioChunkLedgerIntent.self,
        at: self.recordURL(chunkID: chunkID, suffix: "intent")
    ) }
    func readCheckpoint(for chunkID: MeetingAudioChunkID) throws -> MeetingAudioChunkLedgerCheckpoint? { try self.read(
        MeetingAudioChunkLedgerCheckpoint.self,
        at: self.recordURL(chunkID: chunkID, suffix: "checkpoint")
    ) }
    func readTerminal(for chunkID: MeetingAudioChunkID) throws -> MeetingAudioChunkLedgerTerminal? { try self.read(
        MeetingAudioChunkLedgerTerminal.self,
        at: self.recordURL(chunkID: chunkID, suffix: "terminal")
    ) }

    private func validate(_ relative: String) throws {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw MeetingAudioChunkLedgerError.pathRejected }
    }

    private func recordURL(chunkID: UUID, suffix: String) throws -> URL {
        let directory = self.sessionDirectory.appendingPathComponent(self.ledgerDirectoryName, isDirectory: true)
        return directory.appendingPathComponent("\(chunkID.uuidString).\(suffix).json")
    }

    private func ensureLedgerDirectory() throws {
        var rootInfo = stat()
        guard lstat(self.sessionDirectory.path, &rootInfo) == 0,
              (rootInfo.st_mode & S_IFMT) == S_IFDIR
        else { throw MeetingAudioChunkLedgerError.pathRejected }
        let directory = self.sessionDirectory.appendingPathComponent(self.ledgerDirectoryName, isDirectory: true)
        var directoryInfo = stat()
        if lstat(directory.path, &directoryInfo) == 0 {
            guard (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
                throw MeetingAudioChunkLedgerError.pathRejected
            }
        } else {
            guard errno == ENOENT else { throw MeetingAudioChunkLedgerError.pathRejected }
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
        }
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            throw MeetingAudioChunkLedgerError.durabilityFailure("chmod directory")
        }
    }

    private static func isNondecreasing(_ previous: MeetingMediaTime?, _ next: MeetingMediaTime?) -> Bool {
        guard let previous else { return true }
        guard let next else { return false }
        return next.seconds >= previous.seconds
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return try encoder
        .encode(value)
    }

    private func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? { guard FileManager.default.fileExists(atPath: url.path)
        else { return nil }; let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return try decoder.decode(
            type,
            from: Data(contentsOf: url, options: .mappedIfSafe)
        )
    }

    private func writeImmutable(_ data: Data, to destination: URL, conflict: MeetingAudioChunkLedgerError) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            guard (try? Data(contentsOf: destination)) == data else { throw conflict }
            return
        }
        try self.writeTemp(data, destination: destination, exclusive: true, conflict: conflict)
    }

    private func writeReplacing(_ data: Data, to destination: URL) throws { try self.writeTemp(data, destination: destination, exclusive: false) }
    private func writeTemp(_ data: Data, destination: URL, exclusive: Bool, conflict: MeetingAudioChunkLedgerError? = nil) throws {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: temp, options: [])
        guard chmod(temp.path, mode_t(0o600)) == 0 else { try? FileManager.default.removeItem(at: temp); throw MeetingAudioChunkLedgerError.durabilityFailure("chmod") }
        let fd = open(temp.path, O_RDONLY); guard fd >= 0 else { try? FileManager.default.removeItem(at: temp); throw MeetingAudioChunkLedgerError.durabilityFailure("open") }; defer { close(fd) }
        guard fcntl(fd, F_FULLFSYNC) == 0 else { try? FileManager.default.removeItem(at: temp); throw MeetingAudioChunkLedgerError.durabilityFailure("F_FULLFSYNC") }
        let flags = exclusive ? UInt32(RENAME_EXCL) : 0
        guard renameatx_np(AT_FDCWD, temp.path, AT_FDCWD, destination.path, flags) == 0
        else { let e = errno; try? FileManager.default.removeItem(at: temp); if exclusive,
                                                                                e == EEXIST { throw conflict ?? .terminalAlreadyExists }; throw MeetingAudioChunkLedgerError
                .durabilityFailure("rename errno \(e)")
        }
        let dirFD = open(destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY); guard dirFD >= 0
        else { throw MeetingAudioChunkLedgerError.durabilityFailure("open directory") }; defer { close(dirFD) }; guard fsync(dirFD) == 0
        else { throw MeetingAudioChunkLedgerError.durabilityFailure("directory fsync") }
    }
}

/// Optional persistence has one active snapshot and one coalesced successor, never one task
/// per PCM packet. PCM handles are closed before submission. Only this worker hashes/syncs
/// files, appends per-chunk recovery records, and updates the small track header. The complete
/// compatibility manifest is written once at Stop. Failure never deletes captured audio.
final nonisolated class MeetingAudioRecordingJournal: @unchecked Sendable {
    enum Operation: Sendable { case manifest, intent, checkpoint, capture, finalize }
    typealias Hook = @Sendable (Operation) throws -> Void
    typealias Completion = @Sendable (Result<Void, Error>) -> Void
    struct Snapshot: Sendable {
        var track: MeetingAudioTrack
        var intent: MeetingAudioChunkLedgerIntent?
        var checkpoint: MeetingAudioChunkLedgerCheckpoint?
        var final: Bool = false
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ai.pichi.meeting.capture-journal", qos: .utility)
    private let directory: URL
    private let ledger: MeetingAudioChunkLedgerStore
    private let hook: Hook?
    private let delivery: @Sendable ([MeetingAudioChunk], Error?, [Completion]) -> Void
    private var pending: Snapshot?
    private var completions: [Completion] = []
    private var running = false
    private var finishing = false
    private var recordedThrough = -1
    private var pendingRecovery = Set<UUID>()

    init(directory: URL, hook: Hook? = nil,
         delivery: @escaping @Sendable ([MeetingAudioChunk], Error?, [Completion]) -> Void) {
        self.directory = directory
        self.ledger = MeetingAudioChunkLedgerStore(sessionDirectory: directory)
        self.hook = hook
        self.delivery = delivery
    }

    func submit(_ snapshot: Snapshot, completion: Completion? = nil) {
        let (start, rejected) = self.lock.withLock { () -> (Bool, Bool) in
            guard !self.finishing || snapshot.final else { return (false, completion != nil) }
            if snapshot.final { self.finishing = true }
            self.pending = snapshot
            // The one terminal receipt has its own reserved slot. Backpressure on optional
            // acknowledgements cannot let Stop return while file/journal work is still owned.
            let rejected = completion != nil && self.completions.count >= 128 && !snapshot.final
            if let completion, !rejected { self.completions.append(completion) }
            guard !self.running else { return (false, rejected) }
            self.running = true
            return (true, rejected)
        }
        if rejected { completion?(.failure(MeetingAudioChunkLedgerError.durabilityFailure("metadata acknowledgements saturated"))) }
        if start { self.queue.async { self.drain() } }
    }

    private func drain() {
        while let (snapshot, callbacks) = self.lock.withLock({ () -> (Snapshot, [Completion])? in
            guard let snapshot = self.pending else { self.running = false; return nil }
            self.pending = nil
            let callbacks = self.completions
            self.completions.removeAll(keepingCapacity: true)
            return (snapshot, callbacks)
        }) {
            let result = self.persist(snapshot)
            self.delivery(result.chunks, result.error, callbacks)
        }
    }

    private func persist(_ snapshot: Snapshot) -> (chunks: [MeetingAudioChunk], error: Error?) {
        var failure: Error?
        var track = snapshot.track
        var updates: [MeetingAudioChunk] = []
        // A header failure closes transcription admission, not audio intake. Still finalize
        // already captured files, and retry metadata on the next coalesced snapshot or Stop.
        do { try self.writeManifest(track, includeChunks: false) } catch { failure = failure ?? error }
        if let intent = snapshot.intent {
            do { try self.hook?(.intent); try self.ledger.writeIntent(intent) } catch { failure = failure ?? error }
        }
        if let checkpoint = snapshot.checkpoint {
            do { try self.hook?(.checkpoint); try self.ledger.writeCheckpoint(checkpoint, for: checkpoint.chunkID) }
            catch { failure = failure ?? error }
        }
        let recovered: [UUID: MeetingAudioChunk]
        if snapshot.final {
            recovered = Dictionary((try? self.ledger.readCaptures(trackID: track.id, kind: track.kind))?.map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        } else { recovered = [:] }
        for index in track.chunks.indices {
            var chunk = track.chunks[index]
            if chunk.sequence <= self.recordedThrough, !self.pendingRecovery.contains(chunk.id) {
                if snapshot.final, chunk.finalizationState == .writing,
                   let saved = recovered[chunk.id] {
                    track.chunks[index] = saved; updates.append(saved)
                }
                continue
            }
            if chunk.finalizationState == .writing {
                do {
                    try self.hook?(.finalize)
                    let file = try MeetingAudioFilePCMChunkSink.recoverClosedCapture(chunk, in: self.directory)
                    chunk.relativeFilePath = file.relativeFilePath
                    chunk.byteCount = file.byteCount; chunk.sha256 = file.sha256
                    chunk.finalizationState = .finalized
                    chunk.captureAnalysisAsset = .init(role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1,
                        presence: .ready, relativeFilePath: file.relativeFilePath, byteCount: file.byteCount,
                        sha256: file.sha256, sampleRate: file.sampleRate, channelCount: file.channelCount, frameCount: file.frameCount)
                } catch { failure = failure ?? error }
            }
            // Even a not-yet-verified partial has an exact recovery extent and clock. It is
            // never admitted to inference until recovery independently validates the container.
            do {
                try self.hook?(.capture)
                try self.ledger.writeCapture(.init(trackID: track.id, kind: track.kind, chunk: chunk))
                self.recordedThrough = max(self.recordedThrough, chunk.sequence)
                if chunk.finalizationState == .writing { self.pendingRecovery.insert(chunk.id) }
                else { self.pendingRecovery.remove(chunk.id) }
            } catch { failure = failure ?? error }
            track.chunks[index] = chunk
            updates.append(chunk)
        }
        if snapshot.final {
            do { try self.writeManifest(track, includeChunks: true) } catch { failure = failure ?? error }
        }
        return (updates, failure)
    }

    private func writeManifest(_ track: MeetingAudioTrack, includeChunks: Bool) throws {
        try self.hook?(.manifest)
        var value = track
        if !includeChunks { value.chunks = [] }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        let url = self.directory.appendingPathComponent("tracks/\(track.kind.rawValue)/track.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o600))], ofItemAtPath: url.path)
    }
}
