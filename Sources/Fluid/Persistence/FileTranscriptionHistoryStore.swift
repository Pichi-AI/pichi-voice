//
//  FileTranscriptionHistoryStore.swift
//  Fluid
//
//  Persistence for file (meeting) transcription history so results survive navigation.
//

import Combine
import Foundation

// MARK: - File Transcription Entry Model

nonisolated struct FileTranscriptionEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let fileName: String
    /// User-facing name; never changes the source file or its original filename.
    var customTitle: String?
    var searchRevision: UInt64?
    var displayTitle: String { self.customTitle ?? self.fileName }
    let duration: TimeInterval
    let processingTime: TimeInterval
    let confidence: Float
    let text: String
    /// Speaker-attributed segments when diarization was enabled; empty otherwise.
    let speakerSegments: [SpeakerTranscriptSegment]
    let speakerLabelingNotice: String?
    let speakerLabelingGaps: [SpeakerTranscriptGap]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        fileName: String,
        duration: TimeInterval,
        processingTime: TimeInterval,
        confidence: Float,
        text: String,
        speakerSegments: [SpeakerTranscriptSegment] = [],
        speakerLabelingNotice: String? = nil,
        speakerLabelingGaps: [SpeakerTranscriptGap] = []
    ) {
        self.id = id
        self.timestamp = timestamp
        self.fileName = fileName
        self.duration = duration
        self.processingTime = processingTime
        self.confidence = confidence
        self.text = text
        self.speakerSegments = speakerSegments
        self.speakerLabelingNotice = speakerLabelingNotice
        self.speakerLabelingGaps = speakerLabelingGaps
    }

    init(from result: TranscriptionResult) {
        self.id = result.id
        self.timestamp = result.timestamp
        self.fileName = result.fileName
        self.duration = result.duration
        self.processingTime = result.processingTime
        self.confidence = result.confidence
        self.text = result.text
        self.speakerSegments = result.speakerSegments
        self.speakerLabelingNotice = result.speakerLabelingNotice
        self.speakerLabelingGaps = result.speakerLabelingGaps
    }

    enum CodingKeys: String, CodingKey {
        case id, timestamp, fileName, duration, processingTime, confidence, text, speakerSegments
        case speakerLabelingNotice, speakerLabelingGaps, customTitle, searchRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.timestamp = try c.decode(Date.self, forKey: .timestamp)
        self.fileName = try c.decode(String.self, forKey: .fileName)
        self.customTitle = try c.decodeIfPresent(String.self, forKey: .customTitle)
        self.searchRevision = try c.decodeIfPresent(UInt64.self, forKey: .searchRevision)
        self.duration = try c.decode(TimeInterval.self, forKey: .duration)
        self.processingTime = try c.decode(TimeInterval.self, forKey: .processingTime)
        self.confidence = try c.decode(Float.self, forKey: .confidence)
        self.text = try c.decode(String.self, forKey: .text)
        // Older history entries predate speaker labels — tolerate a missing key.
        self.speakerSegments = try c.decodeIfPresent([SpeakerTranscriptSegment].self, forKey: .speakerSegments) ?? []
        self.speakerLabelingNotice = try c.decodeIfPresent(String.self, forKey: .speakerLabelingNotice)
        self.speakerLabelingGaps = try c.decodeIfPresent([SpeakerTranscriptGap].self, forKey: .speakerLabelingGaps) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(self.id, forKey: .id)
        try c.encode(self.timestamp, forKey: .timestamp)
        try c.encode(self.fileName, forKey: .fileName)
        try c.encodeIfPresent(self.customTitle, forKey: .customTitle)
        try c.encodeIfPresent(self.searchRevision, forKey: .searchRevision)
        try c.encode(self.duration, forKey: .duration)
        try c.encode(self.processingTime, forKey: .processingTime)
        try c.encode(self.confidence, forKey: .confidence)
        try c.encode(self.text, forKey: .text)
        if !self.speakerSegments.isEmpty {
            try c.encode(self.speakerSegments, forKey: .speakerSegments)
        }
        try c.encodeIfPresent(self.speakerLabelingNotice, forKey: .speakerLabelingNotice)
        if !self.speakerLabelingGaps.isEmpty {
            try c.encode(self.speakerLabelingGaps, forKey: .speakerLabelingGaps)
        }
    }

    /// Preview text for list display (first 80 chars)
    var previewText: String {
        let leadingTrimmed = self.text.drop(while: { $0.isWhitespace })
        let prefix = leadingTrimmed.prefix(81)
        if prefix.count > 80, !leadingTrimmed.dropFirst(80).allSatisfy(\.isWhitespace) {
            return String(prefix.prefix(77)) + "..."
        }
        return String(prefix.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Relative time string for display
    var relativeTimeString: String {
        self.relativeTimeString(locale: .current)
    }

    func relativeTimeString(locale: Locale, relativeTo reference: Date = Date()) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        formatter.locale = locale
        return formatter.localizedString(for: self.timestamp, relativeTo: reference)
    }

    /// Full formatted date string
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self.timestamp)
    }

    /// Convert to TranscriptionResult for reuse of export/copy UI
    func toTranscriptionResult() -> TranscriptionResult {
        TranscriptionResult(
            id: self.id,
            text: self.text,
            confidence: self.confidence,
            duration: self.duration,
            processingTime: self.processingTime,
            fileName: self.fileName,
            timestamp: self.timestamp,
            speakerSegments: self.speakerSegments,
            speakerLabelingNotice: self.speakerLabelingNotice,
            speakerLabelingGaps: self.speakerLabelingGaps
        )
    }
}

/// One file import's immutable output admission. Closing visibility never grants read
/// access; only this exact result may commit to the originally admitted preferences writer.
@MainActor final class FileTranscriptionHistoryWriteAdmission {
    let entryID = UUID()
    fileprivate let store: FileTranscriptionHistoryStore
    fileprivate let preferences: PrivateProfileFileHistoryWrite
    fileprivate var pending: TranscriptionResult?
    fileprivate var finished = false
    fileprivate var operationFinished = false
    fileprivate var revoked = false
    fileprivate init(store: FileTranscriptionHistoryStore, preferences: PrivateProfileFileHistoryWrite) {
        self.store = store; self.preferences = preferences
    }
    func finish() { self.store.finish(self) }
}

// MARK: - File Transcription History Store

@MainActor
final class FileTranscriptionHistoryStore: ObservableObject {
    // Explicitly nonisolated: on macOS 15.4+ the synthesized main-actor deinit can abort until the OS runtime has the fix (swiftlang/swift#88036).
    nonisolated deinit {}

    static var shared: FileTranscriptionHistoryStore {
        PrivateProfileObjectCache.value(key: "FileTranscriptionHistoryStore") {
            let profile = PrivateProfileStorage.current
            return FileTranscriptionHistoryStore(defaults: PrivateProfileDefaults.bound(to: profile), profile: profile)
        }
    }

    private let defaults: UserDefaults
    private let profile: PrivateProfileSnapshot?
    private var retired = false
    private var retiring = false
    private var retainedEntries: [FileTranscriptionEntry] = []
    private var admissions: [UUID: FileTranscriptionHistoryWriteAdmission] = [:]
    private var joinWaiters: [CheckedContinuation<Void, Never>] = []
    var admittedWriteCount: Int { self.admissions.count }
    private var canAccess: Bool { !self.retiring && !self.retired && self.profile.map(PrivateProfileStorage.isReadable) != false }
    private let maxEntries = 50

    private enum Keys {
        static let fileTranscriptionHistory = "FileTranscriptionHistoryEntries"
    }

    @Published private var visibleEntries: [FileTranscriptionEntry] = []
    private(set) var entries: [FileTranscriptionEntry] {
        get { self.canAccess ? self.visibleEntries : [] }
        set {
            self.retainedEntries = newValue
            if self.canAccess { self.visibleEntries = newValue }
        }
    }
    var entriesPublisher: AnyPublisher<[FileTranscriptionEntry], Never> {
        self.$visibleEntries.map { [weak self] entries in self?.canAccess == true ? entries : [] }.eraseToAnyPublisher()
    }
    @Published var selectedEntryID: UUID?

    init(defaults: UserDefaults? = nil, profile: PrivateProfileSnapshot? = nil) {
        let selected = profile ?? (defaults == nil ? PrivateProfileStorage.current : nil)
        self.profile = selected
        self.defaults = defaults ?? PrivateProfileDefaults.bound(to: selected!)
        self.loadEntries()
    }

    func concealPrivateProjections() {
        self.visibleEntries = []
        self.selectedEntryID = nil
    }

    func admitWrite() throws -> FileTranscriptionHistoryWriteAdmission {
        guard self.canAccess, PrivateProfileStorage.acceptsNewWork,
              let defaults = self.defaults as? PrivateProfileDefaults else { throw CancellationError() }
        let preferences = try defaults.admittedFileHistoryWrite()
        guard self.profile.map({ $0.id == preferences.profile.id && $0.generation == preferences.profile.generation }) != false else {
            preferences.finish(); throw CancellationError()
        }
        let admission = FileTranscriptionHistoryWriteAdmission(store: self, preferences: preferences)
        self.admissions[admission.entryID] = admission
        return admission
    }

    func addEntry(_ result: TranscriptionResult, admission: FileTranscriptionHistoryWriteAdmission) throws {
        guard admission.store === self, self.admissions[admission.entryID] === admission,
              !admission.finished, !admission.revoked, result.id == admission.entryID else { throw CancellationError() }
        let current = PrivateProfileStorage.current
        guard current.id == admission.preferences.profile.id,
              current.generation == admission.preferences.profile.generation else { throw CancellationError() }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        admission.pending = result
        var entries = self.retainedEntries.filter { $0.id != result.id }
        entries.insert(FileTranscriptionEntry(from: result), at: 0)
        if entries.count > self.maxEntries { entries = Array(entries.prefix(self.maxEntries)) }
        let data = try JSONEncoder().encode(entries)
        do { try admission.preferences.save(data) }
        catch is CancellationError { admission.pending = nil; throw CancellationError() }
        catch { throw error }
        self.retainedEntries = entries
        admission.pending = nil
        if self.canAccess {
            self.entries = entries
            self.selectedEntryID = result.id
        }
    }

    private func revokeWrites(ids: Set<UUID>) {
        for admission in Array(self.admissions.values) where ids.contains(admission.entryID) {
            admission.revoked = true
            admission.pending = nil
            admission.preferences.finish()
            if admission.operationFinished { self.finish(admission) }
        }
    }

    private func signalAdmissionChange() {
        let waiters = self.joinWaiters; self.joinWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    fileprivate func finish(_ admission: FileTranscriptionHistoryWriteAdmission) {
        guard admission.store === self, !admission.finished else { return }
        admission.operationFinished = true
        if admission.pending == nil {
            admission.finished = true
            admission.preferences.finish()
            if self.admissions[admission.entryID] === admission { self.admissions.removeValue(forKey: admission.entryID) }
        }
        self.signalAdmissionChange()
    }

    func prepareForProfileTransition() async throws {
        self.retiring = true
        self.concealPrivateProjections()
        while self.admissions.values.contains(where: { !$0.operationFinished }) {
            await withCheckedContinuation { self.joinWaiters.append($0) }
        }
        // A failed durable commit remains pinned and retryable after its inference owner joined.
        for admission in Array(self.admissions.values) {
            if let result = admission.pending {
                do { try self.addEntry(result, admission: admission); self.finish(admission) }
                catch {
                    if admission.pending == nil { self.finish(admission) }
                    self.retiring = false
                    throw error
                }
            } else { self.finish(admission) }
        }
        self.retainedEntries = []
        self.retired = true
    }

    // MARK: - Public Methods

    var selectedEntry: FileTranscriptionEntry? {
        guard self.canAccess else { return nil }
        guard let id = selectedEntryID else { return nil }
        return self.entries.first(where: { $0.id == id })
    }

    /// Add a completed file transcription to history (call after successful transcribeFile).
    func addEntry(_ result: TranscriptionResult) {
        guard self.canAccess else { return }
        guard !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let entry = FileTranscriptionEntry(from: result)
        self.entries.insert(entry, at: 0)

        if self.entries.count > self.maxEntries {
            self.entries.removeLast()
        }

        self.selectedEntryID = entry.id
        self.saveEntries()

        DebugLogger.shared.debug(
            "Added file transcription to history (total: \(self.entries.count))",
            source: "FileTranscriptionHistoryStore"
        )
    }

    func renameEntry(id: UUID, to title: String) {
        guard self.canAccess else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = self.entries.firstIndex(where: { $0.id == id }),
              self.entries[index].displayTitle != trimmed else { return }
        self.entries[index].customTitle = trimmed
        let revision = self.entries[index].searchRevision ?? 1
        self.entries[index].searchRevision = revision == .max ? .max : revision + 1
        self.saveEntries()
    }

    func deleteEntry(id: UUID) {
        guard self.canAccess else { return }
        self.revokeWrites(ids: [id])
        self.entries.removeAll { $0.id == id }
        if self.selectedEntryID == id {
            self.selectedEntryID = self.entries.first?.id
        }
        self.saveEntries()
    }

    func clearAll() {
        guard self.canAccess else { return }
        self.revokeWrites(ids: Set(self.admissions.keys))
        self.entries.removeAll()
        self.selectedEntryID = nil
        self.saveEntries()
        DebugLogger.shared.info("Cleared all file transcription history", source: "FileTranscriptionHistoryStore")
    }

    // MARK: - Persistence

    private func loadEntries() {
        guard self.canAccess else { return }
        // Skip an entry this build cannot read instead of emptying the history;
        // the next save would persist an empty list.
        guard let data = self.defaults.data(forKey: Keys.fileTranscriptionHistory),
              let decoded = PersistedHistory.decode(FileTranscriptionEntry.self, from: data)
        else {
            self.entries = []
            return
        }
        self.entries = decoded.entries
        if decoded.skipped > 0 {
            DebugLogger.shared.info(
                "Skipped \(decoded.skipped) unreadable file transcription entries",
                source: "FileTranscriptionHistoryStore"
            )
        }
    }

    private func saveEntries() {
        guard self.canAccess else { return }
        if let encoded = try? JSONEncoder().encode(self.entries) {
            self.defaults.set(encoded, forKey: Keys.fileTranscriptionHistory)
        }
        self.objectWillChange.send()
    }
}
