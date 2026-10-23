import CryptoKit
import Darwin
import Foundation

nonisolated enum PichiPublicationOutboxFailure: String, Error, Sendable {
    case invalidScope, invalidStorage, corruptRecord, capacityExceeded, unavailable
    case notAdmitted, invalidTransition, invalidSource, receiptConflict
}

nonisolated enum PichiPublicationDeliveryState: String, Codable, Sendable {
    case waitingForSource, queued, sending, retryScheduled, paused, accepted, withheld, conflict
}

nonisolated enum PichiPublicationPauseReason: String, Codable, Sendable {
    case userRequested, profileTransition, uncertainDelivery, authenticationRequired
    case accountReview, permissionReview, receiptReview, validationRejected, sourceConflict
    case retryBudgetExhausted, retryAfterBeyondBudget, transportUnavailable, storageUnavailable
}

/// Local metadata only. No root, process generation, credentials or mutable account
/// selection is serialized. The original POST assessment is deliberately always unbound.
nonisolated struct PichiPublicationOutboxRecord: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let sessionID: MeetingSessionID
    let owner: MeetingProfileOwnership
    let configuration: AccountConfiguration
    let operationID: UUID
    let sourceRevision: Int
    let automaticConsent: Bool
    var transcriptBytes: Data?
    var sourceSHA256: String?
    var attemptCount: Int
    var state: PichiPublicationDeliveryState
    var pauseReason: PichiPublicationPauseReason?
    var withholdingReason: PichiPublicationWithholdingReason?
    var nextAttemptAt: Date?
    var retryNotBefore: Date?
    var receipt: PichiPublicationReceipt?

    var originalAssessment: PichiPublicationAssessment { .init(participantID: nil, criteriaIDs: []) }
    var multipartBoundary: String { "pichi-import-" + operationID.uuidString }
}

/// N2 supplies an immutable existing private root; N1 remains the only authority for
/// authorizing delivery. One runtime owner retains this actor for a given profile. The
/// filesystem lock also protects duplicate callbacks from separately opened store actors.
actor PichiPublicationOutboxStore {
    static let maximumPendingRecords = 32
    static let maximumPendingBytes = 24 * 1_024 * 1_024
    private static let maximumRecordBytes = 1_048_576
    private static let maximumAttemptCount = 10_000
    private let profile: PrivateProfileSnapshot
    private let configuration: AccountConfiguration
    private var recovered = false

    init(profile: PrivateProfileSnapshot, configuration: AccountConfiguration) {
        self.profile = profile
        self.configuration = configuration
    }

    /// A durable false-consent marker prevents a repeated callback or later opt-in from
    /// converting this capture into historical publication. Capacity failures throw before
    /// admission; a later source cannot manufacture the missing capture record.
    func capture(id: MeetingSessionID, automaticConsent: Bool) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            if let existing = try self.lookup(id, directories) { return existing }
            if automaticConsent {
                let pending = try self.readPending(directories)
                guard pending.count < Self.maximumPendingRecords else { throw PichiPublicationOutboxFailure.capacityExceeded }
            }
            let record = PichiPublicationOutboxRecord(schemaVersion: 1, sessionID: id,
                owner: try self.owner(), configuration: self.configuration, operationID: UUID(),
                sourceRevision: 1, automaticConsent: automaticConsent, attemptCount: 0,
                state: automaticConsent ? .waitingForSource : .withheld)
            try self.commit(record, directories)
            return record
        }
    }

    /// Only an unprepared capture may be removed. Once exact source bytes exist they and
    /// their operation key survive cancellation, logout and response loss.
    func cancelCapture(id: MeetingSessionID) throws {
        try self.withDirectories { directories in
            guard let record = try self.lookup(id, directories), record.automaticConsent,
                  record.transcriptBytes == nil, record.attemptCount == 0,
                  [.waitingForSource, .paused].contains(record.state) else { return }
            guard unlinkat(directories.pending, self.name(id), 0) == 0,
                  fsync(directories.pending) == 0 else { throw PichiPublicationOutboxFailure.unavailable }
        }
    }

    func record(id: MeetingSessionID) throws -> PichiPublicationOutboxRecord? {
        try self.withDirectories { try self.lookup(id, $0) }
    }

    func pendingRecords() throws -> [PichiPublicationOutboxRecord] {
        try self.withDirectories { try self.readPending($0).sorted { $0.sessionID.uuidString < $1.sessionID.uuidString } }
    }

    /// The first eligible save wins even when later saved edits differ. No existing bytes,
    /// digest, boundary, destination or original assessment are ever replaced.
    func installSource(id: MeetingSessionID, source: PichiProtectedPublicationSource) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            guard record.automaticConsent else { throw PichiPublicationOutboxFailure.notAdmitted }
            if record.transcriptBytes != nil { return record }
            guard [.waitingForSource, .paused].contains(record.state), source.sessionID == id else {
                throw PichiPublicationOutboxFailure.invalidTransition
            }
            record.transcriptBytes = source.transcriptBytes
            record.sourceSHA256 = source.sourceSHA256
            if record.state == .waitingForSource { record.state = .queued }
            try self.validate(record, id: id)
            let pending = try self.readPending(directories)
            guard pending.reduce(0, { $0 + ($1.transcriptBytes?.count ?? 0) }) + source.transcriptBytes.count
                    <= Self.maximumPendingBytes else { throw PichiPublicationOutboxFailure.capacityExceeded }
            try self.commit(record, directories)
            return record
        }
    }

    func withhold(id: MeetingSessionID, reason: PichiPublicationWithholdingReason) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            if record.transcriptBytes != nil || record.state == .withheld { return record }
            record.state = .withheld; record.withholdingReason = reason; record.pauseReason = nil
            try self.commit(record, directories)
            return record
        }
    }

    /// Durable attempt advancement precedes I/O. Explicit retries keep the same immutable
    /// operation and monotonic count; after budget exhaustion only another explicit action
    /// can admit one further attempt.
    func beginAttempt(id: MeetingSessionID, now: Date = Date()) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            guard now.timeIntervalSince1970.isFinite, record.transcriptBytes != nil,
                  record.state == .queued || (record.state == .retryScheduled && (record.nextAttemptAt ?? .distantFuture) <= now),
                  record.attemptCount < Self.maximumAttemptCount else { throw PichiPublicationOutboxFailure.invalidTransition }
            record.attemptCount += 1; record.state = .sending; record.nextAttemptAt = nil; record.retryNotBefore = nil; record.pauseReason = nil
            try self.commit(record, directories)
            return record
        }
    }

    /// Receipt acceptance is committed to settled storage before removing pending state.
    /// A crash between these writes leaves a verified settled record authoritative.
    func accept(id: MeetingSessionID, receipt: PichiPublicationReceipt) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            guard record.transcriptBytes != nil, record.state != .withheld, record.state != .conflict else {
                throw PichiPublicationOutboxFailure.invalidTransition
            }
            try self.checkReceipt(receipt, replacing: record.receipt)
            record.receipt = receipt; record.state = .accepted; record.pauseReason = nil; record.nextAttemptAt = nil; record.retryNotBefore = nil
            try self.commit(record, directories)
            return record
        }
    }

    /// Status and effective PATCH replies update only current analysis state, retaining
    /// the original POST fingerprint and exact import/recording IDs.
    func updateReceipt(id: MeetingSessionID, receipt: PichiPublicationReceipt) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            guard record.state == .accepted, record.receipt != nil else { throw PichiPublicationOutboxFailure.invalidTransition }
            try self.checkReceipt(receipt, replacing: record.receipt)
            record.receipt = receipt
            try self.commit(record, directories)
            return record
        }
    }

    func scheduleRetry(id: MeetingSessionID, decision: PichiPublicationRetryDecision,
                       now: Date = Date()) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            guard record.state == .sending, now.timeIntervalSince1970.isFinite else {
                throw PichiPublicationOutboxFailure.invalidTransition
            }
            let bounded: PichiPublicationRetryDecision
            switch decision {
            case let .retry(afterSeconds: delay):
                bounded = PichiPublicationRetryPolicy.decision(afterAttempt: record.attemptCount, retryAfter: .seconds(delay))
            case .pause: bounded = decision
            }
            switch bounded {
            case let .retry(afterSeconds: delay):
                record.state = .retryScheduled; record.nextAttemptAt = now.addingTimeInterval(delay); record.retryNotBefore = record.nextAttemptAt
            case let .pause(reason):
                record.state = .paused; record.nextAttemptAt = nil
                record.pauseReason = reason == .retryBudgetExhausted ? .retryBudgetExhausted : .retryAfterBeyondBudget
            }
            try self.commit(record, directories)
            return record
        }
    }

    func pause(id: MeetingSessionID, reason: PichiPublicationPauseReason) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            if [.accepted, .withheld, .conflict].contains(record.state) { return record }
            record.retryNotBefore = record.nextAttemptAt ?? record.retryNotBefore
            record.state = reason == .sourceConflict ? .conflict : .paused
            record.pauseReason = reason; record.nextAttemptAt = nil
            try self.commit(record, directories)
            return record
        }
    }

    func pauseAll(reason: PichiPublicationPauseReason = .profileTransition) throws {
        try self.withDirectories { directories in
            for var record in try self.readPending(directories) {
                // A profile transition must not turn billing/permission/validation review
                // or an exhausted retry budget into automatically resumable delivery.
                if record.state == .paused, let pause = record.pauseReason,
                   ![.profileTransition, .userRequested, .uncertainDelivery].contains(pause) { continue }
                record.retryNotBefore = record.nextAttemptAt ?? record.retryNotBefore
                record.state = reason == .sourceConflict ? .conflict : .paused
                record.pauseReason = reason; record.nextAttemptAt = nil
                try self.commit(record, directories)
            }
        }
    }

    func explicitRetry(id: MeetingSessionID) throws -> PichiPublicationOutboxRecord {
        try self.withDirectories { directories in
            var record = try self.required(id, directories)
            guard record.automaticConsent,
                  [.paused, .retryScheduled, .queued].contains(record.state),
                  record.attemptCount < Self.maximumAttemptCount else { throw PichiPublicationOutboxFailure.invalidTransition }
            guard record.transcriptBytes != nil || record.attemptCount == 0 else { throw PichiPublicationOutboxFailure.invalidTransition }
            if record.transcriptBytes == nil { record.state = .waitingForSource; record.nextAttemptAt = nil }
            else if let due = record.retryNotBefore, due > Date() { record.state = .retryScheduled; record.nextAttemptAt = due }
            else { record.state = .queued; record.nextAttemptAt = nil }
            record.pauseReason = nil
            try self.commit(record, directories)
            return record
        }
    }

    private struct Directories { let root: Int32; let pending: Int32; let settled: Int32 }

    private func owner() throws -> MeetingProfileOwnership {
        do { try configuration.validate() } catch { throw PichiPublicationOutboxFailure.invalidScope }
        guard !profile.isGuest, let context = profile.context,
              context.identity.issuer == configuration.issuer.absoluteString,
              let organization = context.organizationID, let workspace = context.workspaceID,
              [profile.id, context.identity.subject, context.identity.internalUserID, organization, workspace].allSatisfy(Self.validID)
        else { throw PichiPublicationOutboxFailure.invalidScope }
        return .init(profileID: profile.id, issuer: context.identity.issuer, subject: context.identity.subject,
            internalUserID: context.identity.internalUserID, organizationID: organization, workspaceID: workspace)
    }

    private static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private func context() throws -> AccountContext {
        guard let context = profile.context else { throw PichiPublicationOutboxFailure.invalidScope }
        return context
    }

    private func validate(_ record: PichiPublicationOutboxRecord, id: UUID) throws {
        guard record.schemaVersion == 1, record.sourceRevision == 1, record.sessionID == id,
              record.owner == (try self.owner()), record.configuration == self.configuration,
              (0...Self.maximumAttemptCount).contains(record.attemptCount),
              (record.transcriptBytes == nil) == (record.sourceSHA256 == nil),
              record.nextAttemptAt?.timeIntervalSince1970.isFinite != false,
              record.retryNotBefore?.timeIntervalSince1970.isFinite != false else {
            throw PichiPublicationOutboxFailure.corruptRecord
        }
        if let bytes = record.transcriptBytes, let digest = record.sourceSHA256 {
            do {
                _ = try PichiPublicationRequest.importSource(configuration: configuration, context: self.context(),
                    operationID: record.operationID, transcriptBytes: bytes, sourceSHA256: digest,
                    assessment: record.originalAssessment, boundary: record.multipartBoundary)
                guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                      let sourceID = object["sessionID"] as? String, UUID(uuidString: sourceID) == id else {
                    throw PichiPublicationOutboxFailure.corruptRecord
                }
            } catch is CancellationError { throw CancellationError() }
            catch { throw PichiPublicationOutboxFailure.corruptRecord }
        }
        let hasSource = record.transcriptBytes != nil
        let validState: Bool
        switch record.state {
        case .waitingForSource:
            validState = record.automaticConsent && !hasSource && record.attemptCount == 0 && record.pauseReason == nil
        case .queued:
            validState = record.automaticConsent && hasSource && record.pauseReason == nil
        case .sending:
            validState = record.automaticConsent && hasSource && record.attemptCount > 0 && record.pauseReason == nil
        case .retryScheduled:
            validState = record.automaticConsent && hasSource && (1..<PichiPublicationRetryPolicy.maximumAutomaticAttempts).contains(record.attemptCount)
                && record.nextAttemptAt != nil && record.pauseReason == nil
        case .paused:
            validState = record.automaticConsent && record.pauseReason != nil
                && (record.pauseReason != .uncertainDelivery || record.attemptCount > 0)
                && (record.pauseReason != .retryBudgetExhausted || record.attemptCount >= PichiPublicationRetryPolicy.maximumAutomaticAttempts)
        case .accepted:
            validState = record.automaticConsent && hasSource && record.receipt != nil && record.pauseReason == nil
        case .withheld:
            validState = !hasSource && record.attemptCount == 0 && (record.withholdingReason != nil || !record.automaticConsent) && record.pauseReason == nil
        case .conflict:
            validState = record.automaticConsent && hasSource && record.pauseReason == .sourceConflict
        }
        guard validState, record.attemptCount == 0 || hasSource,
              (record.state == .accepted) == (record.receipt != nil),
              (record.state == .retryScheduled) == (record.nextAttemptAt != nil),
              record.state == .withheld || record.withholdingReason == nil else {
            throw PichiPublicationOutboxFailure.corruptRecord
        }
        if let receipt = record.receipt {
            do { try self.checkReceipt(receipt, replacing: nil) }
            catch { throw PichiPublicationOutboxFailure.corruptRecord }
        }
    }

    private func checkReceipt(_ receipt: PichiPublicationReceipt, replacing old: PichiPublicationReceipt?) throws {
        guard receipt.schemaVersion == 1, Self.validID(receipt.importID), Self.validID(receipt.recordingID),
              old.map({ $0.importID == receipt.importID && $0.recordingID == receipt.recordingID }) != false else {
            throw PichiPublicationOutboxFailure.receiptConflict
        }
    }

    private func withDirectories<T>(_ operation: (Directories) throws -> T) throws -> T {
        try Task.checkCancellation()
        _ = try self.owner()
        let url = profile.rootDirectory
        guard url.isFileURL, url.path == url.standardizedFileURL.path,
              url.path == url.resolvingSymlinksInPath().path else { throw PichiPublicationOutboxFailure.invalidStorage }
        let profileFD = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard profileFD >= 0 else { throw PichiPublicationOutboxFailure.invalidStorage }
        defer { Darwin.close(profileFD) }
        try self.checkDirectory(profileFD)
        let cloud = try self.openSubdirectory("CloudPublication", parent: profileFD)
        defer { Darwin.close(cloud) }
        let root = try self.openSubdirectory("OutboxV1", parent: cloud)
        defer { Darwin.close(root) }
        let lock = openat(root, ".lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw PichiPublicationOutboxFailure.invalidStorage }
        defer { Darwin.close(lock) }
        var info = stat()
        guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw PichiPublicationOutboxFailure.invalidStorage }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw PichiPublicationOutboxFailure.unavailable }
        defer { flock(lock, LOCK_UN) }
        let pending = try self.openSubdirectory("pending", parent: root)
        defer { Darwin.close(pending) }
        let settled = try self.openSubdirectory("settled", parent: root)
        defer { Darwin.close(settled) }
        let directories = Directories(root: root, pending: pending, settled: settled)
        if !recovered {
            for var record in try self.readPending(directories) where record.state == .sending {
                record.state = .paused; record.pauseReason = .uncertainDelivery
                try self.commit(record, directories)
            }
            recovered = true
        }
        return try operation(directories)
    }

    private func checkDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else { throw PichiPublicationOutboxFailure.invalidStorage }
    }

    private func openSubdirectory(_ name: String, parent: Int32) throws -> Int32 {
        if mkdirat(parent, name, 0o700) == 0 {
            guard fsync(parent) == 0 else { throw PichiPublicationOutboxFailure.unavailable }
        } else if errno != EEXIST { throw PichiPublicationOutboxFailure.unavailable }
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw PichiPublicationOutboxFailure.invalidStorage }
        do { try self.checkDirectory(fd); return fd }
        catch { Darwin.close(fd); throw error }
    }

    private func name(_ id: UUID) -> String { id.uuidString.lowercased() + ".json" }

    private func required(_ id: UUID, _ directories: Directories) throws -> PichiPublicationOutboxRecord {
        guard let record = try self.lookup(id, directories) else { throw PichiPublicationOutboxFailure.notAdmitted }
        return record
    }

    private func lookup(_ id: UUID, _ directories: Directories) throws -> PichiPublicationOutboxRecord? {
        if let settled = try self.read(id, directory: directories.settled) {
            guard [.accepted, .withheld, .conflict].contains(settled.state) else { throw PichiPublicationOutboxFailure.corruptRecord }
            // Validate any interrupted pending copy too; preserve either copy on damage.
            if let pending = try self.read(id, directory: directories.pending) {
                guard self.sameSource(pending, settled) else { throw PichiPublicationOutboxFailure.corruptRecord }
            }
            return settled
        }
        return try self.read(id, directory: directories.pending)
    }

    private func sameSource(_ lhs: PichiPublicationOutboxRecord, _ rhs: PichiPublicationOutboxRecord) -> Bool {
        lhs.sessionID == rhs.sessionID && lhs.operationID == rhs.operationID && lhs.owner == rhs.owner
            && lhs.configuration == rhs.configuration && lhs.automaticConsent == rhs.automaticConsent
            && lhs.transcriptBytes == rhs.transcriptBytes && lhs.sourceSHA256 == rhs.sourceSHA256
    }

    private func readPending(_ directories: Directories) throws -> [PichiPublicationOutboxRecord] {
        let duplicated = dup(directories.pending)
        guard duplicated >= 0, let stream = fdopendir(duplicated) else {
            if duplicated >= 0 { Darwin.close(duplicated) }
            throw PichiPublicationOutboxFailure.unavailable
        }
        defer { closedir(stream) }
        var records: [PichiPublicationOutboxRecord] = [], entries = 0, bytes = 0
        // dup shares an offset; explicitly rewind every bounded enumeration.
        rewinddir(stream)
        errno = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            entries += 1
            guard entries <= Self.maximumPendingRecords, name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropLast(5))), self.name(id) == name,
                  let pending = try self.read(id, directory: directories.pending) else { throw PichiPublicationOutboxFailure.corruptRecord }
            if let settled = try self.read(id, directory: directories.settled) {
                guard [.accepted, .withheld, .conflict].contains(settled.state), self.sameSource(pending, settled) else {
                    throw PichiPublicationOutboxFailure.corruptRecord
                }
                guard unlinkat(directories.pending, name, 0) == 0, fsync(directories.pending) == 0 else {
                    throw PichiPublicationOutboxFailure.unavailable
                }
            } else {
                guard ![.accepted, .withheld, .conflict].contains(pending.state) else { throw PichiPublicationOutboxFailure.corruptRecord }
                bytes += pending.transcriptBytes?.count ?? 0
                guard bytes <= Self.maximumPendingBytes else { throw PichiPublicationOutboxFailure.corruptRecord }
                records.append(pending)
            }
            errno = 0
        }
        guard errno == 0 else { throw PichiPublicationOutboxFailure.unavailable }
        return records
    }

    private func read(_ id: UUID, directory: Int32) throws -> PichiPublicationOutboxRecord? {
        let fd = openat(directory, self.name(id), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw PichiPublicationOutboxFailure.invalidStorage
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0, info.st_size > 0,
              info.st_size <= Self.maximumRecordBytes else { throw PichiPublicationOutboxFailure.corruptRecord }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var bytes = Data()
            while bytes.count <= Self.maximumRecordBytes {
                try Task.checkCancellation()
                let next = try handle.read(upToCount: Self.maximumRecordBytes + 1 - bytes.count) ?? Data()
                if next.isEmpty { break }
                bytes.append(next)
            }
            guard bytes.count == info.st_size, bytes.count <= Self.maximumRecordBytes else { throw PichiPublicationOutboxFailure.corruptRecord }
            let record = try JSONDecoder().decode(PichiPublicationOutboxRecord.self, from: bytes)
            try self.validate(record, id: id)
            return record
        } catch is CancellationError { throw CancellationError() }
        catch let failure as PichiPublicationOutboxFailure { throw failure }
        catch { throw PichiPublicationOutboxFailure.corruptRecord }
    }

    private func commit(_ record: PichiPublicationOutboxRecord, _ directories: Directories) throws {
        try self.validate(record, id: record.sessionID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(record)
        guard bytes.count <= Self.maximumRecordBytes else { throw PichiPublicationOutboxFailure.invalidSource }
        let terminal = [.accepted, .withheld, .conflict].contains(record.state)
        let destination = terminal ? directories.settled : directories.pending
        let temporary = ".write-" + UUID().uuidString + ".tmp"
        let fd = openat(directories.root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PichiPublicationOutboxFailure.unavailable }
        defer { Darwin.close(fd); unlinkat(directories.root, temporary, 0) }
        do {
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: profile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/" + temporary).path)
            #endif
            try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
            guard fsync(fd) == 0 else { throw PichiPublicationOutboxFailure.unavailable }
            try Task.checkCancellation()
            guard renameat(directories.root, temporary, destination, self.name(record.sessionID)) == 0,
                  fsync(destination) == 0, fsync(directories.root) == 0 else { throw PichiPublicationOutboxFailure.unavailable }
            guard try self.read(record.sessionID, directory: destination) == record else { throw PichiPublicationOutboxFailure.unavailable }
            if terminal {
                guard unlinkat(directories.pending, self.name(record.sessionID), 0) == 0 || errno == ENOENT else {
                    throw PichiPublicationOutboxFailure.unavailable
                }
                guard fsync(directories.pending) == 0 else { throw PichiPublicationOutboxFailure.unavailable }
            }
        } catch is CancellationError { throw CancellationError() }
        catch let failure as PichiPublicationOutboxFailure { throw failure }
        catch { throw PichiPublicationOutboxFailure.unavailable }
    }
}
