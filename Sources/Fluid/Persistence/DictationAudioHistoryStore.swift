import Foundation

nonisolated struct DictationAudioSnapshot: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let channels: Int

    var durationMilliseconds: Int {
        guard self.sampleRate > 0, self.channels > 0 else { return 0 }
        let frames = Double(self.samples.count) / Double(self.channels)
        return Int((frames / Double(self.sampleRate) * 1000).rounded())
    }
}

nonisolated struct DictationAudioMetadata: Codable, Equatable, Sendable {
    let fileName: String
    let durationMilliseconds: Int
    let byteCount: Int
    let sampleRate: Int
    let channels: Int
    let model: String?
}

enum DictationAudioHistoryError: LocalizedError {
    case applicationSupportUnavailable
    case audioMissing
    case noAudioEntries
    case zipFailed(String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Could not access Application Support."
        case .audioMissing:
            return "Saved audio is missing."
        case .noAudioEntries:
            return "No saved dictation audio is available to export."
        case let .zipFailed(message):
            return "Could not create export zip. \(message)"
        }
    }
}

/// A concrete reserved audio destination. Construction is confined to the store's checked
/// admission path, before a background worker is scheduled. Complete after metadata enqueue.
nonisolated final class DictationAudioSaveAdmission: @unchecked Sendable {
    let fileName: String
    let entryID: UUID
    fileprivate let id = UUID()
    fileprivate let store: DictationAudioHistoryStore
    fileprivate let history: TranscriptionHistoryWriteAdmission?
    fileprivate let profile: PrivateProfileSnapshot
    fileprivate init(store: DictationAudioHistoryStore, entryID: UUID, fileName: String,
                     history: TranscriptionHistoryWriteAdmission?, profile: PrivateProfileSnapshot) {
        self.store = store; self.entryID = entryID; self.fileName = fileName
        self.history = history; self.profile = profile
    }
    func save(snapshot: DictationAudioSnapshot, model: String?) throws -> DictationAudioMetadata {
        try self.store.save(snapshot: snapshot, model: model, admission: self)
    }
    func complete() { self.store.complete(self) }
    func abortIfUnstarted() { self.store.abortIfUnstarted(self) }
    func discardUnattached() { self.store.discardUnattached(self) }
    func waitUntilCompleted() async { await self.store.waitUntilCompleted(self) }
}

final nonisolated class DictationAudioHistoryStore: @unchecked Sendable {
    private static let cache = PrivateProfileStoreCache<DictationAudioHistoryStore>()
    static var shared: DictationAudioHistoryStore { scoped(to: PrivateProfileStorage.current) }
    static func scoped(to profile: PrivateProfileSnapshot) -> DictationAudioHistoryStore {
        cache.value(for: profile) { profile in DictationAudioHistoryStore(rootDirectory: profile.rootDirectory, profile: profile) }
    }

    private let rootDirectory: URL
    private let profile: PrivateProfileSnapshot?
    private var retired = false
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private let audioFolder = "DictationAudioHistory"
    private let fileManager = FileManager.default
    private let pendingSaveLock = NSLock()
    private var pendingSaveFileNames: Set<String> = []
    private struct PendingSave {
        let admission: DictationAudioSaveAdmission
        var isWriting = false
        var didWrite = false
        var metadataAttached = false
        var metadata: DictationAudioMetadata?
        var completionRequested = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }
    private var pendingSaves: [UUID: PendingSave] = [:]

    init(rootDirectory: URL? = nil, profile: PrivateProfileSnapshot? = nil) {
        let selected = profile ?? (rootDirectory == nil ? PrivateProfileStorage.current : nil)
        self.profile = selected
        self.rootDirectory = rootDirectory ?? selected!.rootDirectory
    }

    /// New saves are denied while admitted saves finish metadata attachment.
    func prepareForProfileTransition() async {
        await withCheckedContinuation { continuation in
            self.pendingSaveLock.withLock {
                self.retired = true
                if self.pendingSaveFileNames.isEmpty { continuation.resume() }
                else { self.transitionWaiters.append(continuation) }
            }
        }
    }

    /// A rejected transition must leave the selected profile's recording path usable.
    @discardableResult
    func resumeAfterFailedProfileTransition() -> Bool {
        self.pendingSaveLock.withLock {
            guard self.pendingSaveFileNames.isEmpty,
                  self.profile.map(PrivateProfileStorage.isReadable) != false else { return false }
            self.retired = false
            return true
        }
    }

    /// Called through a history recording capability, including after conceal. It grants
    /// only one concrete entry's reserved file, never a general hidden audio-store privilege.
    func admitSave(for history: TranscriptionHistoryWriteAdmission, timestamp: Date) throws -> DictationAudioSaveAdmission {
        guard history.isActiveForCurrentOwner,
              self.profile.map({ $0.id == history.profile.id && $0.generation == history.profile.generation }) != false
        else { throw CancellationError() }
        return try self.reserve(entryID: history.entryID, timestamp: timestamp, history: history, profile: history.profile)
    }

    private func reserve(entryID: UUID, timestamp: Date, history: TranscriptionHistoryWriteAdmission?,
                         profile: PrivateProfileSnapshot) throws -> DictationAudioSaveAdmission {
        try self.pendingSaveLock.withLock {
            guard !self.retired else { throw CancellationError() }
            let name = self.audioFileName(entryID: entryID, timestamp: timestamp)
            // A reservation owns a unique path even when caller-supplied entry prefixes collide.
            let fileName = history == nil ? name : String(name.dropLast(4)) + "_" + UUID().uuidString + ".wav"
            let admission = DictationAudioSaveAdmission(store: self, entryID: entryID,
                fileName: fileName, history: history, profile: profile)
            self.pendingSaves[admission.id] = PendingSave(admission: admission)
            self.pendingSaveFileNames.insert(admission.fileName)
            return admission
        }
    }

    func save(snapshot: DictationAudioSnapshot, entryID: UUID, timestamp: Date, model: String?) throws -> DictationAudioMetadata {
        guard PrivateProfileStorage.acceptsNewWork, self.profile.map(PrivateProfileStorage.isReadable) != false else {
            throw CancellationError()
        }
        let admission = try self.reserve(entryID: entryID, timestamp: timestamp, history: nil,
            profile: self.profile ?? PrivateProfileStorage.current)
        return try admission.save(snapshot: snapshot, model: model)
    }

    fileprivate func save(snapshot: DictationAudioSnapshot, model: String?,
                          admission: DictationAudioSaveAdmission) throws -> DictationAudioMetadata {
        try self.pendingSaveLock.withLock {
            let current = PrivateProfileStorage.current
            guard admission.store === self, var pending = self.pendingSaves[admission.id],
                  !pending.isWriting, !pending.didWrite, !pending.completionRequested,
                  current.id == admission.profile.id, current.generation == admission.profile.generation,
                  admission.history?.isActiveForCurrentOwner != false else { throw CancellationError() }
            pending.isWriting = true; self.pendingSaves[admission.id] = pending
        }
        do {
            let directory = self.rootDirectory.appendingPathComponent(self.audioFolder, isDirectory: true)
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = Self.wavData(from: snapshot)
            try data.write(to: directory.appendingPathComponent(admission.fileName), options: .atomic)
            let metadata = DictationAudioMetadata(fileName: admission.fileName, durationMilliseconds: snapshot.durationMilliseconds,
                byteCount: data.count, sampleRate: snapshot.sampleRate, channels: snapshot.channels, model: model)
            self.pendingSaveLock.withLock {
                guard var pending = self.pendingSaves[admission.id] else { return }
                pending.isWriting = false; pending.didWrite = true; pending.metadata = metadata
                self.pendingSaves[admission.id] = pending
                if pending.completionRequested { self.removePending(admission) }
            }
            return metadata
        } catch {
            self.pendingSaveLock.withLock {
                if var pending = self.pendingSaves[admission.id] {
                    pending.isWriting = false; self.pendingSaves[admission.id] = pending
                }
                self.removePending(admission)
            }
            throw error
        }
    }

    /// Claims metadata once while the reserved WAV still has pending-save protection.
    func claimMetadata(_ metadata: DictationAudioMetadata, from audio: DictationAudioSaveAdmission,
                       history: TranscriptionHistoryWriteAdmission) -> Bool {
        self.pendingSaveLock.withLock {
            guard audio.store === self, audio.history === history, audio.entryID == history.entryID,
                  metadata.fileName == audio.fileName, history.isActiveForCurrentOwner,
                  var pending = self.pendingSaves[audio.id], pending.didWrite, !pending.isWriting,
                  pending.metadata == metadata, !pending.completionRequested, !pending.metadataAttached else { return false }
            pending.metadataAttached = true; self.pendingSaves[audio.id] = pending
            return true
        }
    }

    fileprivate func discardUnattached(_ admission: DictationAudioSaveAdmission) {
        self.pendingSaveLock.withLock {
            guard admission.store === self, let pending = self.pendingSaves[admission.id],
                  pending.didWrite, !pending.isWriting, !pending.metadataAttached else { return }
            // This exact random reservation path was written by this capability. Never
            // resolve a current-profile root or delete a different reservation's file.
            try? self.fileManager.removeItem(at: self.rootDirectory.appendingPathComponent(self.audioFolder)
                .appendingPathComponent(admission.fileName))
        }
    }

    fileprivate func abortIfUnstarted(_ admission: DictationAudioSaveAdmission) {
        self.pendingSaveLock.withLock {
            guard let pending = self.pendingSaves[admission.id], !pending.isWriting, !pending.didWrite else { return }
            self.removePending(admission)
        }
    }

    fileprivate func complete(_ admission: DictationAudioSaveAdmission) {
        self.pendingSaveLock.withLock {
            guard admission.store === self, var pending = self.pendingSaves[admission.id] else { return }
            if pending.isWriting {
                pending.completionRequested = true; self.pendingSaves[admission.id] = pending
            } else { self.removePending(admission) }
        }
    }

    /// Caller holds pendingSaveLock. A never-started canceled worker releases here as well.
    private func removePending(_ admission: DictationAudioSaveAdmission) {
        guard let pending = self.pendingSaves.removeValue(forKey: admission.id) else { return }
        if pending.admission.history != nil, pending.didWrite, !pending.metadataAttached {
            try? self.fileManager.removeItem(at: self.rootDirectory.appendingPathComponent(self.audioFolder)
                .appendingPathComponent(admission.fileName))
        }
        if !self.pendingSaves.values.contains(where: { $0.admission.fileName == admission.fileName }) {
            self.pendingSaveFileNames.remove(admission.fileName)
        }
        for waiter in pending.waiters { waiter.resume() }
        if self.pendingSaves.isEmpty {
            let waiters = self.transitionWaiters; self.transitionWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    fileprivate func waitUntilCompleted(_ admission: DictationAudioSaveAdmission) async {
        await withCheckedContinuation { continuation in
            self.pendingSaveLock.withLock {
                guard var pending = self.pendingSaves[admission.id] else { continuation.resume(); return }
                pending.waiters.append(continuation); self.pendingSaves[admission.id] = pending
            }
        }
    }

    /// Legacy callers still finish metadata attachment by the reserved concrete filename.
    func completePendingSave(fileName: String) {
        self.pendingSaveLock.withLock {
            let saves = self.pendingSaves.values.filter { $0.admission.fileName == fileName }.map(\.admission)
            for save in saves {
                guard var pending = self.pendingSaves[save.id] else { continue }
                if pending.isWriting { pending.completionRequested = true; self.pendingSaves[save.id] = pending }
                else { self.removePending(save) }
            }
        }
    }

    func audioFileURL(for entry: TranscriptionHistoryEntry) -> URL? {
        guard let audio = entry.audio else { return nil }
        return self.audioFileURL(fileName: audio.fileName, createIfNeeded: false)
    }

    func audioFileExists(for entry: TranscriptionHistoryEntry) -> Bool {
        guard let url = self.audioFileURL(for: entry) else { return false }
        return self.fileManager.fileExists(atPath: url.path)
    }

    func audioFileExists(fileName: String) -> Bool {
        guard let url = self.audioFileURL(fileName: fileName, createIfNeeded: false) else { return false }
        return self.fileManager.fileExists(atPath: url.path)
    }

    @discardableResult
    func deleteAudio(fileName: String) -> Int64 {
        guard let url = self.audioFileURL(fileName: fileName, createIfNeeded: false) else {
            return 0
        }

        return self.deleteAudioFile(at: url) ?? 0
    }

    func deleteUnreferencedAudioFiles(referencedFileNames: Set<String>) -> (fileCount: Int, byteCount: Int64) {
        guard let directory = try? self.audioDirectory(createIfNeeded: false),
              self.fileManager.fileExists(atPath: directory.path)
        else {
            return (0, 0)
        }

        let files = (try? self.fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let pendingFileNames = self.pendingSaveLock.withLock { self.pendingSaveFileNames }
        var fileCount = 0
        var byteCount: Int64 = 0
        for file in files where Self.shouldDeleteUnreferencedAudioFile(
            fileName: file.lastPathComponent,
            referencedFileNames: referencedFileNames,
            pendingFileNames: pendingFileNames
        ) {
            guard let removedBytes = self.deleteAudioFile(at: file) else { continue }
            fileCount += 1
            byteCount += removedBytes
        }

        return (fileCount, byteCount)
    }

    static func shouldDeleteUnreferencedAudioFile(
        fileName: String,
        referencedFileNames: Set<String>,
        pendingFileNames: Set<String>
    ) -> Bool {
        URL(fileURLWithPath: fileName).pathExtension.lowercased() == "wav"
            && !referencedFileNames.contains(fileName)
            && !pendingFileNames.contains(fileName)
    }

    private func deleteAudioFile(at url: URL) -> Int64? {
        guard self.fileManager.fileExists(atPath: url.path) else {
            return nil
        }

        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        do {
            try self.fileManager.removeItem(at: url)
            return fileSize
        } catch {
            return nil
        }
    }

    func deleteAllAudioFiles() {
        guard let directory = try? self.audioDirectory(createIfNeeded: false),
              self.fileManager.fileExists(atPath: directory.path)
        else {
            return
        }
        let files = (try? self.fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension.lowercased() == "wav" {
            try? self.fileManager.removeItem(at: file)
        }
    }

    func audioUsageBytes() -> Int64 {
        guard let directory = try? self.audioDirectory(createIfNeeded: false),
              let files = try? self.fileManager.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey],
                  options: [.skipsHiddenFiles]
              )
        else {
            return 0
        }

        return files.reduce(Int64(0)) { total, url in
            guard url.pathExtension.lowercased() == "wav",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize
            else {
                return total
            }
            return total + Int64(size)
        }
    }

    func exportAudioArchive(entries: [TranscriptionHistoryEntry], to destinationURL: URL) throws {
        try self.exportArchive(entries: entries, to: destinationURL)
    }

    func exportPair(entry: TranscriptionHistoryEntry, to destinationURL: URL) throws {
        try self.exportArchive(entries: [entry], to: destinationURL)
    }

    func suggestedAudioExportFilename(for date: Date = Date()) -> String {
        "\(AppBrand.filenamePrefix)_Audio_\(Self.fileTimestampFormatter.string(from: date)).zip"
    }

    func suggestedPairExportFilename(for entry: TranscriptionHistoryEntry) -> String {
        "\(AppBrand.filenamePrefix)_Pair_\(Self.fileTimestampFormatter.string(from: entry.timestamp))_\(entry.id.uuidString.prefix(8)).zip"
    }

    static func formattedGigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824.0
        if gb < 0.1 {
            return String(format: "%.2f GB", gb)
        }
        return String(format: "%.1f GB", gb)
    }

    static func bytes(forGigabytes gigabytes: Double) -> Int64 {
        Int64((gigabytes * 1_073_741_824.0).rounded())
    }

    private func exportArchive(entries: [TranscriptionHistoryEntry], to destinationURL: URL) throws {
        let exportEntries = entries.filter { self.audioFileExists(for: $0) }
        guard !exportEntries.isEmpty else { throw DictationAudioHistoryError.noAudioEntries }

        let staging = self.fileManager.temporaryDirectory
            .appendingPathComponent("fluidvoice-audio-\(UUID().uuidString)", isDirectory: true)
        let audioDirectory = staging.appendingPathComponent("audio", isDirectory: true)

        try self.fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        defer { try? self.fileManager.removeItem(at: staging) }

        var manifestLines: [String] = []
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        for entry in exportEntries.sorted(by: { $0.timestamp < $1.timestamp }) {
            guard let sourceURL = self.audioFileURL(for: entry),
                  let audio = entry.audio
            else {
                continue
            }

            let exportFileName = "\(Self.fileTimestampFormatter.string(from: entry.timestamp))_\(entry.id.uuidString.prefix(8)).wav"
            let relativeAudioPath = "audio/\(exportFileName)"
            try self.fileManager.copyItem(
                at: sourceURL,
                to: audioDirectory.appendingPathComponent(exportFileName, isDirectory: false)
            )

            let row = AudioManifestRow(
                audio: relativeAudioPath,
                text: entry.rawText,
                rawTranscript: entry.rawText,
                finalTranscript: entry.processedText,
                timestamp: Self.isoFormatter.string(from: entry.timestamp),
                durationMilliseconds: audio.durationMilliseconds,
                sampleRate: audio.sampleRate,
                channels: audio.channels,
                app: entry.appName,
                model: audio.model ?? ""
            )
            let data = try encoder.encode(row)
            if let line = String(data: data, encoding: .utf8) {
                manifestLines.append(line)
            }
        }

        guard !manifestLines.isEmpty else { throw DictationAudioHistoryError.noAudioEntries }
        let manifestURL = staging.appendingPathComponent("manifest.jsonl", isDirectory: false)
        try (manifestLines.joined(separator: "\n") + "\n").write(to: manifestURL, atomically: true, encoding: .utf8)

        if self.fileManager.fileExists(atPath: destinationURL.path) {
            try self.fileManager.removeItem(at: destinationURL)
        }
        try self.zip(stagingDirectory: staging, destinationURL: destinationURL)
    }

    private func audioDirectory(createIfNeeded: Bool = true) throws -> URL {
        guard self.pendingSaveLock.withLock({ !self.retired }),
              self.profile.map(PrivateProfileStorage.isReadable) != false else { throw CancellationError() }
        let directory = self.rootDirectory.appendingPathComponent(self.audioFolder, isDirectory: true)
        if createIfNeeded {
            try self.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func audioFileURL(fileName: String, createIfNeeded: Bool) -> URL? {
        guard let safeFileName = self.safeAudioFileName(fileName),
              let directory = try? self.audioDirectory(createIfNeeded: createIfNeeded)
        else {
            return nil
        }
        return directory.appendingPathComponent(safeFileName, isDirectory: false)
    }

    private func safeAudioFileName(_ fileName: String) -> String? {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        guard trimmed == lastPathComponent,
              lastPathComponent != ".",
              lastPathComponent != "..",
              URL(fileURLWithPath: lastPathComponent).pathExtension.lowercased() == "wav"
        else {
            return nil
        }

        return lastPathComponent
    }

    private func audioFileName(entryID: UUID, timestamp: Date) -> String {
        "\(Self.fileTimestampFormatter.string(from: timestamp))_\(entryID.uuidString.prefix(8)).wav"
    }

    private func zip(stagingDirectory: URL, destinationURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-qr", destinationURL.path, "manifest.jsonl", "audio"]
        process.currentDirectoryURL = stagingDirectory

        let errorPipe = Pipe()
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            throw DictationAudioHistoryError.zipFailed(message)
        }
    }

    private static func wavData(from snapshot: DictationAudioSnapshot) -> Data {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataByteCount = snapshot.samples.count * bytesPerSample
        let byteRate = snapshot.sampleRate * snapshot.channels * bytesPerSample
        let blockAlign = snapshot.channels * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        Self.appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        Self.appendUInt32LE(16, to: &data)
        Self.appendUInt16LE(1, to: &data)
        Self.appendUInt16LE(UInt16(snapshot.channels), to: &data)
        Self.appendUInt32LE(UInt32(snapshot.sampleRate), to: &data)
        Self.appendUInt32LE(UInt32(byteRate), to: &data)
        Self.appendUInt16LE(UInt16(blockAlign), to: &data)
        Self.appendUInt16LE(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: Array("data".utf8))
        Self.appendUInt32LE(UInt32(dataByteCount), to: &data)

        for sample in snapshot.samples {
            let clamped = max(-1.0, min(1.0, sample))
            let scaled = Int16((clamped * Float(Int16.max)).rounded())
            Self.appendInt16LE(scaled, to: &data)
        }
        return data
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendInt16LE(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static let fileTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
        return formatter
    }()

    private static var isoFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private nonisolated struct AudioManifestRow: Encodable {
    let audio: String
    let text: String
    let rawTranscript: String
    let finalTranscript: String
    let timestamp: String
    let durationMilliseconds: Int
    let sampleRate: Int
    let channels: Int
    let app: String
    let model: String

    enum CodingKeys: String, CodingKey {
        case audio
        case text
        case rawTranscript = "raw_transcript"
        case finalTranscript = "final_transcript"
        case timestamp
        case durationMilliseconds = "duration_ms"
        case sampleRate = "sample_rate"
        case channels
        case app
        case model
    }
}
