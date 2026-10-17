import CryptoKit
import Darwin
import Foundation

/// Private working state is allowed only beside an explicitly retained recording. It never
/// becomes a transcript/export and has the same deletion lifetime as its source audio. The
/// separate local key and ciphertext both use the existing private-file protection policy;
/// this is not a claim of protection from someone who can read the application's entire sandbox.
nonisolated struct MeetingRetainedProcessingCheckpoint: Sendable {
    static let fileName = "processing-resume.bin"
    static let keyFileName = "processing-resume.key"
    static let maximumBytes = 64 * 1_024 * 1_024

    struct Pin: Codable, Equatable, Sendable {
        let schema: Int
        let sessionID: UUID
        let backendID: MeetingBackendID
        let backendVersion: String
        let configuration: MeetingFinalProcessingConfiguration
        let piiRedactionEnabled: Bool
        let privacyFingerprint: String?
    }
    struct Value: Sendable {
        let pin: Pin
        let inputFingerprint: String
        let ownerVoiceIdentity: String?
        let runtimeFingerprint: String?
        let payload: Data
    }
    private struct Header: Codable {
        let pin: Pin
        let inputFingerprint: String
        let ownerVoiceIdentity: String?
        let runtimeFingerprint: String?
    }
    private struct Envelope: Codable {
        let header: Data
        let ciphertext: Data
    }
    enum Failure: LocalizedError {
        case invalid, changedInput, changedConfiguration, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return PichiLocalization.text("The saved processing checkpoint is damaged. Keep the recording and restart processing.")
            case .changedInput, .changedConfiguration:
                return PichiLocalization.text("The recording or processing models changed since the checkpoint. Restart processing with the retained audio.")
            case .unavailable: return PichiLocalization.text("The processing checkpoint could not be saved safely.")
            }
        }
    }

    let sessionDirectory: URL

    /// The guard precedes even filesystem observation. Strict mode neither creates nor reads
    /// audio-working-state files, including a stale file from a different storage-mode snapshot.
    func read(session: MeetingSession) throws -> Value? {
        guard session.audioStorageMode == .retainedFiles, session.retention.audioDeletedAt == nil else { return nil }
        let url = try self.confinedURL(Self.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Self.privateRead(url, limit: Self.maximumBytes)
            let envelope = try PropertyListDecoder().decode(Envelope.self, from: data)
            let header = try PropertyListDecoder().decode(Header.self, from: envelope.header)
            guard header.pin.schema == 1, header.pin.sessionID == session.id,
                  header.pin.configuration.languageCode == session.languageCode,
                  header.pin.configuration.speakerLabelsEnabled == (session.speakerLabelsEnabled ?? true),
                  header.pin.configuration.effectiveSpeakerProcessingMode == session.effectiveSpeakerProcessingMode,
                  header.pin.piiRedactionEnabled == (session.piiRedactionEnabled == true),
                  header.pin.configuration.pipelineVersion == MeetingFinalProcessingConfiguration.defaultPipelineVersion
            else { throw Failure.changedConfiguration }
            let key = try SymmetricKey(data: Self.privateRead(try self.confinedURL(Self.keyFileName), limit: 32))
            let sealed = try AES.GCM.SealedBox(combined: envelope.ciphertext)
            let payload = try AES.GCM.open(sealed, using: key, authenticating: envelope.header)
            return Value(pin: header.pin, inputFingerprint: header.inputFingerprint,
                         ownerVoiceIdentity: header.ownerVoiceIdentity,
                         runtimeFingerprint: header.runtimeFingerprint, payload: payload)
        } catch let failure as Failure { throw failure }
        catch { throw Failure.invalid }
    }

    func write(_ value: Value, session: MeetingSession) throws {
        guard session.audioStorageMode == .retainedFiles, session.retention.audioDeletedAt == nil,
              value.pin.sessionID == session.id,
              value.pin.configuration.effectiveSpeakerProcessingMode == session.effectiveSpeakerProcessingMode
        else { throw Failure.changedConfiguration }
        try Task.checkCancellation()
        let root = self.sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let properties = try FileManager.default.attributesOfItem(atPath: root.path)
        guard properties[.type] as? FileAttributeType == .typeDirectory else { throw Failure.unavailable }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let keyURL = try self.confinedURL(Self.keyFileName)
        let key: SymmetricKey
        if FileManager.default.fileExists(atPath: keyURL.path) {
            let bytes = try Self.privateRead(keyURL, limit: 32)
            guard bytes.count == 32 else { throw Failure.invalid }
            key = SymmetricKey(data: bytes)
        } else {
            key = SymmetricKey(size: .bits256)
            try self.atomicWrite(key.withUnsafeBytes { Data($0) }, to: keyURL)
        }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let header = try encoder.encode(Header(pin: value.pin, inputFingerprint: value.inputFingerprint,
                                               ownerVoiceIdentity: value.ownerVoiceIdentity,
                                               runtimeFingerprint: value.runtimeFingerprint))
        guard let ciphertext = try AES.GCM.seal(value.payload, using: key, authenticating: header).combined else {
            throw Failure.unavailable
        }
        let bytes = try encoder.encode(Envelope(header: header, ciphertext: ciphertext))
        guard bytes.count <= Self.maximumBytes else { throw Failure.unavailable }
        try Task.checkCancellation()
        try self.atomicWrite(bytes, to: self.confinedURL(Self.fileName))
        guard try self.read(session: session)?.payload == value.payload else { throw Failure.invalid }
    }

    static func remove(in directory: URL) throws {
        let present = try Self.workingFileNames(in: directory)
        // Remove the decryption key before ciphertext, including an atomic write interrupted
        // before its temporary file could be renamed or removed by defer.
        let temporary = present.filter { $0 != Self.fileName && $0 != Self.keyFileName }.sorted()
        for name in [Self.keyFileName, Self.fileName] + temporary {
            let url = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    static func hasWorkingState(in directory: URL) throws -> Bool {
        try !Self.workingFileNames(in: directory).isEmpty
    }

    private static func workingFileNames(in directory: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let prefix = ".processing-resume-", suffix = ".tmp"
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { name in
            if name == Self.fileName || name == Self.keyFileName { return true }
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
            return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
        }
    }

    private func confinedURL(_ name: String) throws -> URL {
        let root = self.sessionDirectory.standardizedFileURL.resolvingSymlinksInPath()
        let url = root.appendingPathComponent(name).standardizedFileURL
        guard url.resolvingSymlinksInPath() == url,
              url.deletingLastPathComponent() == root else { throw Failure.invalid }
        return url
    }
    private static func privateRead(_ url: URL, limit: Int) throws -> Data {
        let properties = try FileManager.default.attributesOfItem(atPath: url.path)
        guard properties[.type] as? FileAttributeType == .typeRegular,
              let size = properties[.size] as? NSNumber, size.intValue > 0, size.intValue <= limit else { throw Failure.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw Failure.invalid }
        return data
    }
    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let temporary = try self.confinedURL(".processing-resume-\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        #if os(iOS)
        try data.write(to: temporary, options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: temporary, options: .withoutOverwriting)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let file = try FileHandle(forWritingTo: temporary); defer { try? file.close() }
        try file.synchronize()
        try Task.checkCancellation()
        guard rename(temporary.path, destination.path) == 0 else { throw Failure.unavailable }
        let directoryFD = open(self.sessionDirectory.path, O_RDONLY)
        guard directoryFD >= 0 else { throw Failure.unavailable }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw Failure.unavailable }
        var url = destination; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
