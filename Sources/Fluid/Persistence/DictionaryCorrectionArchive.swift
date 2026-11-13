import AVFoundation
import Foundation

/// Frozen at capture admission. Pronunciation consent never supplies this capability.
nonisolated struct DictionaryCorrectionArchiveAdmission: Sendable, Equatable {
    let profileID: String
    let generation: UUID
    let rootDirectory: URL

    fileprivate init(profileID: String, generation: UUID, rootDirectory: URL) {
        self.profileID = profileID
        self.generation = generation
        self.rootDirectory = rootDirectory
    }

    #if !DICTIONARY_ARCHIVE_STANDALONE
    @MainActor static func capture(filePersistenceAllowed: Bool) -> Self? {
        guard filePersistenceAllowed, PrivateProfileStorage.acceptsNewWork,
              SettingsStore.shared.dictionaryCorrectionArchiveEnabled else { return nil }
        let profile = PrivateProfileStorage.current
        guard PrivateProfileStorage.isReadable(profile) else { return nil }
        return Self(profileID: profile.id, generation: profile.generation, rootDirectory: profile.rootDirectory)
    }

    func belongs(to profile: PrivateProfileSnapshot) -> Bool {
        self.profileID == profile.id && self.generation == profile.generation && self.rootDirectory == profile.rootDirectory
    }
    #endif
}

/// Kept only in memory until a correction is explicitly saved. Independent of pronunciation matching.
nonisolated struct DictionaryCorrectionRecording: Sendable {
    static let sampleRate = 16_000
    static let maximumSamples = sampleRate * 60 * 15
    static let lifetime: TimeInterval = 120

    let id = UUID()
    let capturedAt: Date
    let model: String
    let rawTranscript: String
    let samples: [Float]
    let archiveAdmission: DictionaryCorrectionArchiveAdmission?

    init?(model: String, rawTranscript: String, samples: [Float], now: Date = Date(), archiveAdmission: DictionaryCorrectionArchiveAdmission? = nil) {
        guard !model.isEmpty, !rawTranscript.isEmpty, rawTranscript.utf16.count <= 100_000,
              !samples.isEmpty, samples.count <= Self.maximumSamples else { return nil }
        self.capturedAt = now
        self.model = model
        self.rawTranscript = rawTranscript
        self.samples = samples
        self.archiveAdmission = archiveAdmission
    }
}

nonisolated struct DictionaryCorrectionExample: Sendable {
    let id: UUID
    let recording: DictionaryCorrectionRecording
    let originalText: String
    let correctedText: String
    let heardWord: String
    let correctedWord: String

    /// Store only the dictated insertion, never the surrounding document or conversation.
    static func make(
        id: UUID, recording: DictionaryCorrectionRecording, before: String, after: String,
        insertedRange: NSRange, heardWord: String, correctedWord: String, now: Date = Date()
    ) -> Self? {
        let old = before as NSString, new = after as NSString
        let start = insertedRange.location, length = insertedRange.length
        guard now >= recording.capturedAt, now.timeIntervalSince(recording.capturedAt) < DictionaryCorrectionRecording.lifetime,
              old.length <= 100_000, new.length <= 100_000,
              start >= 0, length > 0, start <= old.length, length <= old.length - start,
              start <= new.length, !heardWord.isEmpty, !correctedWord.isEmpty else { return nil }
        let newLength = length + new.length - old.length
        guard newLength > 0, newLength <= new.length - start,
              old.substring(to: start) == new.substring(to: start),
              old.substring(from: start + length) == new.substring(from: start + newLength) else { return nil }
        let original = old.substring(with: insertedRange)
        let corrected = new.substring(with: NSRange(location: start, length: newLength))
        guard original != corrected else { return nil }
        return Self(
            id: id,
            recording: recording,
            originalText: original,
            correctedText: corrected,
            heardWord: heardWord,
            correctedWord: correctedWord
        )
    }
}

/// A local, portable dataset. No upload, automatic training, or age-based deletion.
actor DictionaryCorrectionArchive {
    #if !DICTIONARY_ARCHIVE_STANDALONE
    private static let cache = PrivateProfileStoreCache<DictionaryCorrectionArchive>()
    static var shared: DictionaryCorrectionArchive { scoped(to: PrivateProfileStorage.current) }
    static func scoped(to profile: PrivateProfileSnapshot) -> DictionaryCorrectionArchive {
        cache.value(for: profile) {
            DictionaryCorrectionArchive(directory: $0.rootDirectory.appendingPathComponent("Dictionary/TrainingExamples", isDirectory: true),
                profile: $0)
        }
    }
    private let profile: PrivateProfileSnapshot?
    #endif

    struct Metadata: Codable, Sendable, Equatable {
        let schemaVersion: Int
        let profileID: String?
        let profileGeneration: UUID?
        let id: UUID
        let recordingID: UUID
        let capturedAt: Date
        let acceptedAt: Date
        let model: String
        let rawTranscript: String
        let originalText: String
        let correctedText: String
        let heardWord: String
        let correctedWord: String
        let audioFile: String
        let sampleRate: Int
        let frameCount: Int
    }

    enum ArchiveError: Error, Equatable { case capacityReached, invalidAudio, unsafeDirectory, invalidExistingExample, notAuthorized }

    private let directory: URL
    private let maximumBytes: Int
    private let maximumExamples: Int

    init(directory: URL, maximumBytes: Int = 512 * 1024 * 1024, maximumExamples: Int = 2000) {
        #if !DICTIONARY_ARCHIVE_STANDALONE
        self.profile = nil
        #endif
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.maximumExamples = maximumExamples
    }

    #if !DICTIONARY_ARCHIVE_STANDALONE
    private init(directory: URL, profile: PrivateProfileSnapshot) {
        self.directory = directory
        self.profile = profile
        self.maximumBytes = 512 * 1024 * 1024
        self.maximumExamples = 2000
    }
    #endif

    func saveAccepted(_ example: DictionaryCorrectionExample, now: Date = Date()) throws {
        #if !DICTIONARY_ARCHIVE_STANDALONE
        guard let admission = example.recording.archiveAdmission,
              self.profile.map({ admission.belongs(to: $0) }) != false else { throw ArchiveError.notAuthorized }
        try self.validateProfileDirectories()
        #endif
        let samples = example.recording.samples
        guard !samples.isEmpty, samples.count <= DictionaryCorrectionRecording.maximumSamples,
              samples.allSatisfy(\.isFinite) else { throw ArchiveError.invalidAudio }
        let fm = FileManager.default
        try fm.createDirectory(
            at: self.directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        #if !DICTIONARY_ARCHIVE_STANDALONE
        try self.validateProfileDirectories()
        #endif
        guard try self.directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw ArchiveError.unsafeDirectory
        }
        let final = self.directory.appendingPathComponent(example.id.uuidString, isDirectory: true)
        if fm.fileExists(atPath: final.path) {
            try self.validateExisting(final, example: example)
            return
        }
        let items = try fm.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let exampleCount = items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }.count
        guard exampleCount < self.maximumExamples else { throw ArchiveError.capacityReached }
        var usedBytes = 0
        for item in items {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw ArchiveError.unsafeDirectory }
            if values.isDirectory == true {
                // Inspect just our two fixed files, never traverse user-added subdirectories.
                for name in ["audio.wav", "example.json"] {
                    let file = item.appendingPathComponent(name)
                    if fm.fileExists(atPath: file.path) {
                        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isRegularFileKey])
                        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw ArchiveError.unsafeDirectory }
                        usedBytes += values.fileSize ?? 0
                    }
                }
            }
        }
        let metadata = Metadata(
            schemaVersion: 1,
            profileID: example.recording.archiveAdmission?.profileID,
            profileGeneration: example.recording.archiveAdmission?.generation,
            id: example.id,
            recordingID: example.recording.id,
            capturedAt: example.recording.capturedAt,
            acceptedAt: now,
            model: example.recording.model,
            rawTranscript: example.recording.rawTranscript,
            originalText: example.originalText,
            correctedText: example.correctedText,
            heardWord: example.heardWord,
            correctedWord: example.correctedWord,
            audioFile: "audio.wav",
            sampleRate: DictionaryCorrectionRecording.sampleRate,
            frameCount: samples.count
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = try encoder.encode(metadata)
        guard usedBytes + samples.count * MemoryLayout<Float>.size + json.count + 4096 <= self.maximumBytes else {
            throw ArchiveError.capacityReached
        }
        let staging = self.directory.appendingPathComponent(".pending-\(example.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let audio = staging.appendingPathComponent("audio.wav")
        try Self.writeAudio(samples, to: audio)
        let metadataURL = staging.appendingPathComponent("example.json")
        try json.write(to: metadataURL, options: .atomic)
        for file in [audio, metadataURL] {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        let readme = self.directory.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let description = """
            Pichi Voice local correction examples (schema version 1)

            Each UUID folder contains audio.wav and example.json from an explicitly saved dictionary correction.
            Audio is the complete dictation: mono, 16000 Hz, Float32 PCM WAV.
            rawTranscript is the speech result; originalText is the delivered text; correctedText is the user edit.
            AI cleanup may have changed originalText. Review examples before using them for training.
            Surrounding document text is excluded. Nothing is uploaded or automatically trained.
            Saved examples do not expire and are independent of transcription history.
            You can copy or delete these folders. Collection stops at 512 MiB or 2000 folders without deleting examples.
            Folders beginning with .pending- are incomplete writes and should not be used for training.
            """
            try Data(description.utf8).write(to: readme, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: readme.path)
        }
        // Publish only complete audio/text pairs. History cleanup never owns this folder.
        try fm.moveItem(at: staging, to: final)
    }

    #if !DICTIONARY_ARCHIVE_STANDALONE
    private func validateProfileDirectories() throws {
        guard let profile = self.profile else { return } // Explicit temporary test injection.
        let root = profile.legacyRootDirectory.standardizedFileURL
        let components = self.directory.standardizedFileURL.pathComponents
        guard components.starts(with: root.pathComponents) else { throw ArchiveError.unsafeDirectory }
        var folder = root
        for part in [""] + Array(components.dropFirst(root.pathComponents.count)) {
            if !part.isEmpty { folder.appendPathComponent(part) }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: folder.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.unsafeDirectory }
            } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                return // Missing suffix is created and checked again before writing.
            }
        }
    }
    #endif

    /// A directory's presence is not a receipt: verify both identity/text and every PCM frame.
    private func validateExisting(_ folder: URL, example: DictionaryCorrectionExample) throws {
        let audioURL = folder.appendingPathComponent("audio.wav")
        let jsonURL = folder.appendingPathComponent("example.json")
        guard try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ArchiveError.invalidExistingExample }
        for url in [audioURL, jsonURL] {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size <= DictionaryCorrectionRecording.maximumSamples * 4 + 4_000_000 else {
                throw ArchiveError.invalidExistingExample
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(Metadata.self, from: Data(contentsOf: jsonURL))
        let recording = example.recording
        // ISO8601 metadata stores whole seconds; use the same encoder precision for comparison.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let expectedDate = try decoder.decode(Date.self, from: encoder.encode(recording.capturedAt))
        guard metadata.schemaVersion == 1, metadata.id == example.id,
              metadata.profileID == recording.archiveAdmission?.profileID, metadata.profileGeneration == recording.archiveAdmission?.generation, metadata.recordingID == recording.id,
              metadata.capturedAt == expectedDate, metadata.model == recording.model,
              metadata.rawTranscript == recording.rawTranscript, metadata.originalText == example.originalText,
              metadata.correctedText == example.correctedText, metadata.heardWord == example.heardWord,
              metadata.correctedWord == example.correctedWord, metadata.audioFile == "audio.wav",
              metadata.sampleRate == DictionaryCorrectionRecording.sampleRate, metadata.frameCount == recording.samples.count else {
            throw ArchiveError.invalidExistingExample
        }
        let file = try AVAudioFile(forReading: audioURL)
        guard file.length == Int64(recording.samples.count), file.fileFormat.commonFormat == .pcmFormatFloat32,
              file.processingFormat.sampleRate == Double(DictionaryCorrectionRecording.sampleRate),
              file.processingFormat.channelCount == 1,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { throw ArchiveError.invalidExistingExample }
        var offset = 0
        while offset < recording.samples.count {
            try file.read(into: buffer)
            let count = Int(buffer.frameLength)
            guard count > 0, count <= recording.samples.count - offset, let channel = buffer.floatChannelData?[0] else { throw ArchiveError.invalidExistingExample }
            for index in 0..<count where channel[index].bitPattern != recording.samples[offset + index].bitPattern {
                throw ArchiveError.invalidExistingExample
            }
            offset += count
        }
    }

    private static func writeAudio(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(DictionaryCorrectionRecording.sampleRate), channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096),
              let channel = buffer.floatChannelData?[0] else { throw ArchiveError.invalidAudio }
        // Bounded scratch space; retain original Float32 PCM without lossy encoding.
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        for start in stride(from: 0, to: samples.count, by: 4096) {
            let count = min(4096, samples.count - start)
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress { channel.update(from: base.advanced(by: start), count: count) }
            }
            try file.write(from: buffer)
        }
    }
}

#if !DICTIONARY_ARCHIVE_STANDALONE
/// Accepted saves outlive notices. The existing profile owner cancels/joins them before selection.
@MainActor final class DictionaryCorrectionArchiveSaveCoordinator {
    static var shared: DictionaryCorrectionArchiveSaveCoordinator {
        PrivateProfileObjectCache.value(key: "DictionaryCorrectionArchiveSaveCoordinator") { Self() }
    }
    private let profile = PrivateProfileStorage.current
    private let owner = PrivateProfileOperationOwner(registerForTransitions: true)
    private final class Work { var task: Task<Void, Never>? }
    /// The existing pronunciation queue retains only this bounded optional archive lease.
    /// Dropping/cancelling a queue request releases PCM even when it has no failure callback.
    nonisolated fileprivate final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private let maximumBytes: Int
        private let maximumCount: Int
        private var bytes = 0
        private var count = 0
        init(bytes: Int, count: Int) { self.maximumBytes = max(0, bytes); self.maximumCount = max(0, count) }
        func acquire(_ bytes: Int) -> Bool {
            self.lock.withLock {
                guard self.count < self.maximumCount, bytes <= self.maximumBytes - self.bytes else { return false }
                self.count += 1; self.bytes += bytes
                return true
            }
        }
        func release(_ bytes: Int) { self.lock.withLock { self.count -= 1; self.bytes -= bytes } }
    }
    nonisolated final class PendingExample: @unchecked Sendable {
        let example: DictionaryCorrectionExample
        private let budget: Budget
        private let lock = NSLock()
        private var accepted = false
        fileprivate func claim() -> Bool {
            self.lock.withLock {
                guard !self.accepted else { return false }
                self.accepted = true
                return true
            }
        }
        fileprivate init(example: DictionaryCorrectionExample, budget: Budget) { self.example = example; self.budget = budget }
        deinit { self.budget.release(self.example.recording.samples.count * MemoryLayout<Float>.stride) }
    }
    private let budget: Budget
    init(maximumPendingBytes: Int = 128 * 1024 * 1024, maximumPendingSaves: Int = 32) {
        self.budget = Budget(bytes: maximumPendingBytes, count: maximumPendingSaves)
    }

    func holdForCommit(_ example: DictionaryCorrectionExample) -> PendingExample? {
        guard let admission = example.recording.archiveAdmission, admission.belongs(to: self.profile),
              self.owner.isCurrent, self.budget.acquire(example.recording.samples.count * MemoryLayout<Float>.stride) else { return nil }
        return PendingExample(example: example, budget: self.budget)
    }

    @discardableResult func accept(_ example: DictionaryCorrectionExample,
        archive: (@Sendable (DictionaryCorrectionExample) async throws -> Void)? = nil,
        completion: @escaping @MainActor (String?) -> Void = { _ in }) -> Bool {
        guard let pending = self.holdForCommit(example) else { return false }
        return self.acceptHeld(pending, archive: archive, completion: completion)
    }

    @discardableResult func acceptHeld(_ pending: PendingExample,
        archive: (@Sendable (DictionaryCorrectionExample) async throws -> Void)? = nil,
        completion: @escaping @MainActor (String?) -> Void = { _ in }) -> Bool {
        guard let admission = pending.example.recording.archiveAdmission, admission.belongs(to: self.profile), self.owner.isCurrent, pending.claim() else { return false }
        let store = DictionaryCorrectionArchive.scoped(to: self.profile)
        let save = archive ?? { try await store.saveAccepted($0) }
        let work = Work()
        guard let id = self.owner.admit(cancel: { work.task?.cancel() }, join: { await work.task?.value }) else { return false }
        let owner = self.owner
        work.task = Task(priority: .utility) {
            defer { owner.complete(id) }
            // Do not discard an accepted save on presentation dismissal or cancellation.
            // Transition still waits for the original destination's concrete operation to finish.
            var warning: String?
            do { try await save(pending.example) }
            catch DictionaryCorrectionArchive.ArchiveError.capacityReached {
                warning = PichiLocalization.text("Audio collection is paused: the local archive is full.")
            } catch {
                warning = PichiLocalization.text("The correction is saved, but its audio example could not be stored.")
            }
            if let warning { DebugLogger.shared.warning(warning, source: "DictionaryCorrectionArchive") }
            guard owner.isCurrent, !Task.isCancelled else { return }
            completion(warning)
        }
        return true
    }

    func retireAndJoin() async { await self.owner.retireAndJoin() }
}
#endif
