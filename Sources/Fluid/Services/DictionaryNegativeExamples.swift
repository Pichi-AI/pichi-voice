import CryptoKit
import Foundation
import Darwin

/// A capture retains read authority to one already selected regular file, never its path.
/// The lock joins a bounded read/decode with close, including cancellation cleanup.
nonisolated final class DictionaryCaptureEvidenceFile: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?
    private let maximumBytes: Int

    init?(url: URL, maximumBytes: Int, profile: PrivateProfileSnapshot? = nil) throws {
        guard let descriptor = try Self.openDescriptor(url: url, profile: profile) else { return nil }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              attributes.st_size >= 0, attributes.st_size <= maximumBytes else {
            Darwin.close(descriptor)
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.maximumBytes = maximumBytes
    }

    private static func openDescriptor(url: URL, profile: PrivateProfileSnapshot?) throws -> Int32? {
        let flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        guard let profile else { return try self.validateOpen(open(url.path, flags)) }
        // The legacy root is the trusted storage anchor. Every profile and evidence
        // component below it is opened relative to a descriptor without symlink traversal.
        let profileComponents = profile.isGuest ? [] : ["Profiles", profile.id]
        let expectedRoot = profileComponents.reduce(profile.legacyRootDirectory) { $0.appendingPathComponent($1) }
        let rootComponents = expectedRoot.standardizedFileURL.pathComponents
        let fileComponents = url.standardizedFileURL.pathComponents
        guard expectedRoot.standardizedFileURL == profile.rootDirectory.standardizedFileURL,
              fileComponents.starts(with: rootComponents), fileComponents.count > rootComponents.count else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        let relative = Array(fileComponents.dropFirst(rootComponents.count))
        let components = profileComponents + relative
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") }) else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        guard var directory = try self.validateOpen(open(profile.legacyRootDirectory.path, flags | O_DIRECTORY)) else { return nil }
        defer { Darwin.close(directory) }
        for component in components.dropLast() {
            guard let next = try self.validateOpen(openat(directory, component, flags | O_DIRECTORY)) else { return nil }
            Darwin.close(directory)
            directory = next
        }
        return try self.validateOpen(openat(directory, components[components.count - 1], flags))
    }

    private static func validateOpen(_ descriptor: Int32) throws -> Int32? {
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        return descriptor
    }

    func read<Value>(_ decode: (Data) throws -> Value) throws -> Value {
        self.lock.lock(); defer { self.lock.unlock() }
        guard let handle = self.handle else { throw PronunciationDictionaryStoreError.staleEvidence }
        try Task.checkCancellation()
        try handle.seek(toOffset: 0)
        let data = try handle.read(upToCount: self.maximumBytes + 1) ?? Data()
        guard data.count <= self.maximumBytes else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let value = try decode(data)
        try Task.checkCancellation()
        return value
    }

    func close() {
        self.lock.lock(); defer { self.lock.unlock() }
        try? self.handle?.close()
        self.handle = nil
    }

    deinit { self.close() }
}

nonisolated struct DictionaryAcousticEvidence: Sendable {
    let id: UUID
    let entryID: UUID
    let label: String
    let profileKey: String
    let modelKey: String
    let sourceWordRange: Range<Int>
    let frames: DictionaryMatchFrames
    var matchFrameRange: Range<Int>? = nil

    func aligned(to wordRange: Range<Int>, label: String) -> Self {
        Self(id: self.id, entryID: self.entryID, label: label, profileKey: self.profileKey, modelKey: self.modelKey, sourceWordRange: wordRange, frames: self.frames, matchFrameRange: self.matchFrameRange)
    }
}

nonisolated struct DictionaryNegativeCorrection: Sendable {
    let evidence: DictionaryAcousticEvidence
    let correctedText: String
    let expiresAt: Date
}

nonisolated enum DictionaryNegativeEvidenceResolver {
    static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Only an unchanged delivered utterance and a unique, complete inserted label qualify.
    /// Repeated names, AI rewrites, partial selections, and stale audio are deliberately ignored.
    static func resolve(context: DictionaryLearningCorrectionContext, heard: String, corrected: String, now: Date = Date()) -> DictionaryNegativeCorrection? {
        guard DictionaryCorrectionEditPolicy.allows(heard: heard, corrected: corrected) else { return nil }
        let beforeWords = self.normalized(heard).split(separator: " ")
        let afterWords = self.normalized(corrected).split(separator: " ")
        if afterWords.count > beforeWords.count, !beforeWords.isEmpty,
           (0...(afterWords.count - beforeWords.count)).contains(where: {
               afterWords[$0..<($0 + beforeWords.count)].elementsEqual(beforeWords)
           }) {
            // Adding a modifier keeps the recognized term; it is not evidence
            // that this term's acoustic match was wrong.
            return nil
        }
        let alignment = context.recording.alignment
        guard now < context.recording.expiresAt, alignment.acousticOutput == context.deliveredTextBeforeEdit,
              !self.normalized(corrected).isEmpty, self.normalized(heard) != self.normalized(corrected) else { return nil }
        let source = context.deliveredTextBeforeEdit as NSString
        let selected = context.selectedUTF16Range
        guard selected.location >= 0, selected.length > 0, selected.location <= source.length,
              selected.length <= source.length - selected.location,
              source.substring(with: selected).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) == heard else { return nil }
        let selectedLabel = source.range(of: heard, range: selected)
        let eligible = alignment.acousticEvidence.filter { evidence in
            guard evidence.label == heard, evidence.frames.isValid else { return false }
            let range = source.range(of: evidence.label)
            guard range == selectedLabel else { return false }
            let after = NSMaxRange(range)
            return source.range(of: evidence.label, range: NSRange(location: after, length: source.length - after)).location == NSNotFound
        }
        guard eligible.count == 1 else { return nil }
        return DictionaryNegativeCorrection(evidence: eligible[0], correctedText: corrected, expiresAt: context.recording.expiresAt)
    }

    static func profileKey(_ profile: PronunciationDictionaryProfile) -> String {
        // Retraining, replacement spelling, model changes, and extraction changes invalidate examples.
        var hash = SHA256()
        hash.update(data: Data((DictionaryMatcherExperiment.version + profile.modelKey + profile.label).utf8))
        for e in profile.enrollments {
            hash.update(data: Data((e.inspectionID?.uuidString ?? e.originalAudioID?.uuidString ?? "").utf8))
            e.values.withUnsafeBytes { hash.update(data: Data($0)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Separate, removable experimental store; never mutates positive enrollments or dictionary text.
actor DictionaryNegativeExampleStore {
    private static let cache = PrivateProfileStoreCache<DictionaryNegativeExampleStore>()
    static var shared: DictionaryNegativeExampleStore {
        cache.value { profile in DictionaryNegativeExampleStore(
            url: profile.rootDirectory.appendingPathComponent("dictionary-negative-examples-v1.plist"), profile: profile) }
    }
    struct Example: Codable, Sendable {
        let id: UUID
        let entryID: UUID
        let profileKey: String
        let modelKey: String
        let frames: DictionaryMatchFrames
    }

    private let profile: PrivateProfileSnapshot?
    private var retired = false
    private var canAccess: Bool { !self.retired && self.profile.map(PrivateProfileStorage.isReadable) != false }
    private let url: URL
    private var generation = UUID()
    private let collectionEnabled: @Sendable () -> Bool

    nonisolated final class CaptureRead: @unchecked Sendable {
        let profile: PrivateProfileSnapshot
        let revision = UUID()
        private let leaseID: UUID
        private let lock = NSLock()
        private var examples: [Example]
        private var closed = false

        fileprivate init(profile: PrivateProfileSnapshot, leaseID: UUID, examples: [Example]) {
            self.profile = profile
            self.leaseID = leaseID
            self.examples = examples
        }

        func frames(entryID: UUID, profileKey: String, modelKey: String) -> [DictionaryMatchFrames] {
            self.lock.lock(); defer { self.lock.unlock() }
            guard !self.closed,
                  ParakeetSpeechModelCatalog.descriptor(forInstalledPronunciationModelKey: modelKey) != nil
                    || !ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(modelKey) else { return [] }
            return self.examples.filter {
                $0.entryID == entryID && $0.profileKey == profileKey && $0.modelKey == modelKey
            }.map(\.frames)
        }

        func close(leaseID: UUID) {
            self.lock.lock(); defer { self.lock.unlock() }
            guard self.leaseID == leaseID else { return }
            self.closed = true
            self.examples.removeAll()
        }
    }

    /// Called synchronously by the admitted provider before its first suspension. The
    /// value is independent of later store selection and has no write authority.
    nonisolated func admitCaptureRead(leaseID: UUID, modelKey: String, entryIDs: Set<UUID>) throws -> CaptureRead {
        try Task.checkCancellation()
        guard let profile = self.profile, PrivateProfileStorage.isReadable(profile),
              PrivateProfileStorage.acceptsNewWork else { throw PronunciationDictionaryStoreError.staleEvidence }
        var examples: [Example] = []
        if let file = try DictionaryCaptureEvidenceFile(url: self.url, maximumBytes: 32_000_000, profile: profile) {
            defer { file.close() }
            examples = try file.read { data in
                let all = try PropertyListDecoder().decode([Example].self, from: data)
                guard all.count <= 32, all.allSatisfy({ $0.frames.isValid }) else {
                    throw PronunciationDictionaryStoreError.inconsistentEnrollment
                }
                return all.filter { $0.modelKey == modelKey && entryIDs.contains($0.entryID) }
            }
        }
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else {
            throw PronunciationDictionaryStoreError.staleEvidence
        }
        try Task.checkCancellation()
        return CaptureRead(profile: profile, leaseID: leaseID, examples: examples)
    }

    init(
        url: URL? = nil,
        profile: PrivateProfileSnapshot? = nil,
        collectionEnabled: @escaping @Sendable () -> Bool = { DictionaryMatcherExperiment.collectNegatives }
    ) {
        let selected = profile ?? (url == nil ? PrivateProfileStorage.current : nil)
        self.profile = selected
        self.url = url ?? selected!.rootDirectory.appendingPathComponent("dictionary-negative-examples-v1.plist")
        self.collectionEnabled = collectionEnabled
    }

    func revision() -> UUID { self.generation }

    func prepareForProfileTransition() {
        self.retired = true
        self.generation = UUID()
    }

    private func read() throws -> [Example] {
        guard self.canAccess else { throw PronunciationDictionaryStoreError.staleEvidence }
        guard FileManager.default.fileExists(atPath: self.url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 32_000_000 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        let examples = try PropertyListDecoder().decode([Example].self, from: Data(contentsOf: self.url))
        guard examples.count <= 32, examples.allSatisfy({ $0.frames.isValid }) else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        return examples
    }

    func frames(entryID: UUID, profileKey: String, modelKey: String) -> [DictionaryMatchFrames] {
        guard ParakeetSpeechModelCatalog.descriptor(forInstalledPronunciationModelKey: modelKey) != nil
            || !ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(modelKey)
        else { return [] }
        return ((try? self.read()) ?? []).filter { $0.entryID == entryID && $0.profileKey == profileKey && $0.modelKey == modelKey }.map(\.frames)
    }

    func save(_ correction: DictionaryNegativeCorrection, expectedRevision: UUID) throws {
        guard self.canAccess else { throw PronunciationDictionaryStoreError.staleEvidence }
        guard self.generation == expectedRevision, self.collectionEnabled(), correction.expiresAt > Date() else { throw PronunciationDictionaryStoreError.staleEvidence }
        let e = correction.evidence
        guard e.frames.isValid else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        var all = try read()
        if all.contains(where: { $0.id == e.id }) { return }
        // Six examples per word; 32 globally. Only frame features are persisted, no PCM or transcript.
        all.removeAll { $0.entryID == e.entryID && $0.profileKey != e.profileKey }
        while all.filter({ $0.entryID == e.entryID }).count >= 6 {
            if let index = all.firstIndex(where: { $0.entryID == e.entryID }) { all.remove(at: index) }
        }
        all.append(Example(id: e.id, entryID: e.entryID, profileKey: e.profileKey, modelKey: e.modelKey, frames: e.frames))
        all = Array(all.suffix(32))
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(all)
        guard data.count <= 32_000_000 else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        try FileManager.default.createDirectory(at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: self.url, options: .atomic)
    }

    func clear() throws {
        guard self.canAccess else { throw PronunciationDictionaryStoreError.staleEvidence }
        self.generation = UUID()
        if FileManager.default.fileExists(atPath: self.url.path) { try FileManager.default.removeItem(at: self.url) }
    }

    func remove(id: UUID) throws {
        guard self.canAccess else { throw PronunciationDictionaryStoreError.staleEvidence }
        let all = try read().filter { $0.id != id }
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        try encoder.encode(all).write(to: self.url, options: .atomic)
    }
}
