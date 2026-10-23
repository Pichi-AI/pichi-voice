import CryptoKit
import Darwin
import Foundation

nonisolated enum PichiPublicationConsentFailure: String, Error, Sendable {
    case unconfigured, workspaceUnavailable, invalidScope, invalidStorage, corruptConsent, unavailable
}

/// A small private setting store, not a profile registry. N2 supplies a dedicated existing
/// private directory. The shared publication operation authorizes its frozen N1 context
/// before reading or changing consent. This store has no account selection or capture hook.
actor PichiPublicationConsentStore {
    private nonisolated struct Scope: Codable, Equatable {
        let configuration: AccountConfiguration
        let identity: AccountIdentity
        let organizationID: String
        let workspaceID: String
    }

    private nonisolated struct Record: Codable, Equatable {
        let schemaVersion: Int
        let scope: Scope
        let automaticPublicationEnabled: Bool
        let deliveryPaused: Bool?
    }

    private let directory: URL
    private let configuration: AccountConfiguration?
    private static let maximumRecordBytes = 16_384

    init(directory: URL, configuration: AccountConfiguration?) {
        self.directory = directory
        self.configuration = configuration
    }

    /// Missing trusted configuration, an unselected workspace or an absent record means off.
    /// A damaged existing record throws a stable code so the UI can show that consent is
    /// unavailable. It is never interpreted as permission to publish or silently repaired.
    func automaticPublicationEnabled(for context: AccountContext) throws -> Bool {
        try Task.checkCancellation()
        guard self.configuration != nil, context.organizationID != nil, context.workspaceID != nil else { return false }
        let scope = try self.scope(for: context)
        guard let directoryFD = try self.openDirectory() else { return false }
        defer { Darwin.close(directoryFD) }
        return try self.read(scope: scope, directoryFD: directoryFD)?.automaticPublicationEnabled ?? false
    }

    /// Changes future-capture consent only. This operation never enumerates history or
    /// changes the policy/owner of an already admitted recording or queued source.
    func setAutomaticPublicationEnabled(_ enabled: Bool, for context: AccountContext) throws {
        try Task.checkCancellation()
        let scope = try self.scope(for: context)
        guard let directoryFD = try self.openDirectory() else { throw PichiPublicationConsentFailure.unavailable }
        defer { Darwin.close(directoryFD) }
        // Preserve evidence of corruption or a foreign copied record instead of overwriting it.
        let previous = try self.read(scope: scope, directoryFD: directoryFD)
        let record = Record(schemaVersion: 1, scope: scope, automaticPublicationEnabled: enabled,
            deliveryPaused: previous?.deliveryPaused ?? false)
        let bytes = try self.encode(record)
        guard bytes.count <= Self.maximumRecordBytes else { throw PichiPublicationConsentFailure.invalidScope }
        try self.write(bytes, name: self.name(for: scope), directoryFD: directoryFD)
        guard try self.read(scope: scope, directoryFD: directoryFD) == record else {
            throw PichiPublicationConsentFailure.unavailable
        }
    }

    func deliveryPaused(for context: AccountContext) throws -> Bool {
        try Task.checkCancellation()
        guard self.configuration != nil, context.organizationID != nil, context.workspaceID != nil else { return false }
        let scope = try self.scope(for: context)
        guard let directoryFD = try self.openDirectory() else { return false }
        defer { Darwin.close(directoryFD) }
        return try self.read(scope: scope, directoryFD: directoryFD)?.deliveryPaused ?? false
    }

    func setDeliveryPaused(_ paused: Bool, for context: AccountContext) throws {
        try Task.checkCancellation()
        let scope = try self.scope(for: context)
        guard let directoryFD = try self.openDirectory() else { throw PichiPublicationConsentFailure.unavailable }
        defer { Darwin.close(directoryFD) }
        let previous = try self.read(scope: scope, directoryFD: directoryFD)
        let record = Record(schemaVersion: 1, scope: scope,
            automaticPublicationEnabled: previous?.automaticPublicationEnabled ?? false, deliveryPaused: paused)
        let bytes = try self.encode(record)
        guard bytes.count <= Self.maximumRecordBytes else { throw PichiPublicationConsentFailure.invalidScope }
        try self.write(bytes, name: self.name(for: scope), directoryFD: directoryFD)
        guard try self.read(scope: scope, directoryFD: directoryFD) == record else { throw PichiPublicationConsentFailure.unavailable }
    }

    /// The public Cloud sync toggle changes both delivery admission and future-capture
    /// consent in one atomic scoped preference record.
    func setCloudSyncEnabled(_ enabled: Bool, for context: AccountContext) throws {
        try Task.checkCancellation()
        let scope = try self.scope(for: context)
        guard let directoryFD = try self.openDirectory() else { throw PichiPublicationConsentFailure.unavailable }
        defer { Darwin.close(directoryFD) }
        _ = try self.read(scope: scope, directoryFD: directoryFD)
        let record = Record(schemaVersion: 1, scope: scope, automaticPublicationEnabled: enabled, deliveryPaused: !enabled)
        let bytes = try self.encode(record)
        guard bytes.count <= Self.maximumRecordBytes else { throw PichiPublicationConsentFailure.invalidScope }
        try self.write(bytes, name: self.name(for: scope), directoryFD: directoryFD)
        guard try self.read(scope: scope, directoryFD: directoryFD) == record else { throw PichiPublicationConsentFailure.unavailable }
    }

    private func scope(for context: AccountContext) throws -> Scope {
        guard let configuration else { throw PichiPublicationConsentFailure.unconfigured }
        do { try configuration.validate() } catch { throw PichiPublicationConsentFailure.invalidScope }
        guard let organizationID = context.organizationID, let workspaceID = context.workspaceID else {
            throw PichiPublicationConsentFailure.workspaceUnavailable
        }
        let identifiers = [context.identity.subject, context.identity.internalUserID, organizationID, workspaceID]
        guard context.identity.issuer == configuration.issuer.absoluteString,
              identifiers.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                  && $0.utf8.count <= 512 && $0.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw PichiPublicationConsentFailure.invalidScope
        }
        return Scope(configuration: configuration, identity: context.identity,
            organizationID: organizationID, workspaceID: workspaceID)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(value)
        } catch { throw PichiPublicationConsentFailure.invalidScope }
    }

    private func name(for scope: Scope) throws -> String {
        // Sorting makes this stable across launches. A generation is intentionally absent:
        // it gates in-flight authorization, not the durable identity of a user's setting.
        let bytes = try self.encode(scope)
        guard bytes.count <= Self.maximumRecordBytes / 2 else { throw PichiPublicationConsentFailure.invalidScope }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() + ".json"
    }

    private func openDirectory() throws -> Int32? {
        guard self.directory.isFileURL,
              self.directory.path == self.directory.standardizedFileURL.path,
              self.directory.path == self.directory.resolvingSymlinksInPath().path else {
            throw PichiPublicationConsentFailure.invalidStorage
        }
        let fd = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw PichiPublicationConsentFailure.invalidStorage
        }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            Darwin.close(fd)
            throw PichiPublicationConsentFailure.invalidStorage
        }
        return fd
    }

    private func read(scope: Scope, directoryFD: Int32) throws -> Record? {
        let name = try self.name(for: scope)
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw PichiPublicationConsentFailure.invalidStorage
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o077 == 0, info.st_size > 0,
              info.st_size <= Self.maximumRecordBytes else { throw PichiPublicationConsentFailure.corruptConsent }
        do {
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            var bytes = Data()
            while true {
                try Task.checkCancellation()
                let next = try handle.read(upToCount: Self.maximumRecordBytes + 1 - bytes.count) ?? Data()
                if next.isEmpty { break }
                bytes.append(next)
                guard bytes.count <= Self.maximumRecordBytes else { throw PichiPublicationConsentFailure.corruptConsent }
            }
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.schemaVersion == 1, record.scope == scope else {
                throw PichiPublicationConsentFailure.corruptConsent
            }
            return record
        } catch is CancellationError { throw CancellationError() }
        catch let failure as PichiPublicationConsentFailure { throw failure }
        catch { throw PichiPublicationConsentFailure.corruptConsent }
    }

    private func write(_ bytes: Data, name: String, directoryFD: Int32) throws {
        let temporary = ".consent-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PichiPublicationConsentFailure.unavailable }
        defer { Darwin.close(fd); unlinkat(directoryFD, temporary, 0) }
        do {
            #if os(iOS)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: self.directory.appendingPathComponent(temporary).path)
            #endif
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: bytes)
            guard fsync(fd) == 0 else { throw PichiPublicationConsentFailure.unavailable }
            try Task.checkCancellation()
            guard renameat(directoryFD, temporary, directoryFD, name) == 0, fsync(directoryFD) == 0 else {
                throw PichiPublicationConsentFailure.unavailable
            }
        } catch is CancellationError { throw CancellationError() }
        catch { throw PichiPublicationConsentFailure.unavailable }
    }
}
