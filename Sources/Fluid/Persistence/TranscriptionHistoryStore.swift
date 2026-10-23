//
//  TranscriptionHistoryStore.swift
//  Fluid
//
//  Persistence manager for Transcription Mode history
//

import AppKit
import Combine
import Foundation

nonisolated struct AudioBudgetMeasurementGate: Equatable, Sendable {
    let revision: UInt64
    let budgetBytes: Int64

    func accepts(currentRevision: UInt64, currentBudgetBytes: Int64) -> Bool {
        self.revision == currentRevision && self.budgetBytes == currentBudgetBytes
    }
}

// MARK: - Transcription History Entry Model

nonisolated struct TranscriptionHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let rawText: String
    let processedText: String
    let appName: String
    let windowTitle: String
    let characterCount: Int
    let wasAIProcessed: Bool
    let processingModel: String?
    let transcriptionDurationMilliseconds: Int?
    let parakeetProcessingDurationMilliseconds: Int?
    let aiProcessingDurationMilliseconds: Int?
    let aiTokensPerSecond: Double?
    /// Non-nil when AI post-processing was configured but failed and we fell
    /// back to typing the raw transcription. The string carries the error
    /// message for display / debugging.
    let aiProcessingError: String?
    let audio: DictationAudioMetadata?
    var isStarred: Bool
    /// Rises when a restore gives this id different text. Nil on entries written
    /// before the field existed, and on entries that were never restored.
    var searchRevision: UInt64?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String,
        wasAIProcessed: Bool,
        processingModel: String? = nil,
        transcriptionDurationMilliseconds: Int? = nil,
        parakeetProcessingDurationMilliseconds: Int? = nil,
        aiProcessingDurationMilliseconds: Int? = nil,
        aiTokensPerSecond: Double? = nil,
        aiProcessingError: String? = nil,
        audio: DictationAudioMetadata? = nil,
        isStarred: Bool = false,
        searchRevision: UInt64? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.processedText = processedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.characterCount = processedText.count
        self.wasAIProcessed = wasAIProcessed
        self.processingModel = processingModel
        self.transcriptionDurationMilliseconds = transcriptionDurationMilliseconds
        self.parakeetProcessingDurationMilliseconds = parakeetProcessingDurationMilliseconds
        self.aiProcessingDurationMilliseconds = aiProcessingDurationMilliseconds
        self.aiTokensPerSecond = aiTokensPerSecond
        self.aiProcessingError = aiProcessingError
        self.audio = audio
        self.isStarred = isStarred
        self.searchRevision = searchRevision
    }

    private init(
        id: UUID,
        timestamp: Date,
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String,
        characterCount: Int,
        wasAIProcessed: Bool,
        processingModel: String?,
        transcriptionDurationMilliseconds: Int?,
        parakeetProcessingDurationMilliseconds: Int?,
        aiProcessingDurationMilliseconds: Int?,
        aiTokensPerSecond: Double?,
        aiProcessingError: String?,
        audio: DictationAudioMetadata?,
        isStarred: Bool,
        searchRevision: UInt64?
    ) {
        self.id = id
        self.timestamp = timestamp
        self.rawText = rawText
        self.processedText = processedText
        self.appName = appName
        self.windowTitle = windowTitle
        self.characterCount = characterCount
        self.wasAIProcessed = wasAIProcessed
        self.processingModel = processingModel
        self.transcriptionDurationMilliseconds = transcriptionDurationMilliseconds
        self.parakeetProcessingDurationMilliseconds = parakeetProcessingDurationMilliseconds
        self.aiProcessingDurationMilliseconds = aiProcessingDurationMilliseconds
        self.aiTokensPerSecond = aiTokensPerSecond
        self.aiProcessingError = aiProcessingError
        self.audio = audio
        self.isStarred = isStarred
        self.searchRevision = searchRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.timestamp = try container.decode(Date.self, forKey: .timestamp)
        self.rawText = try container.decode(String.self, forKey: .rawText)
        self.processedText = try container.decode(String.self, forKey: .processedText)
        self.appName = try container.decode(String.self, forKey: .appName)
        self.windowTitle = try container.decode(String.self, forKey: .windowTitle)
        self.characterCount = try container.decode(Int.self, forKey: .characterCount)
        self.wasAIProcessed = try container.decode(Bool.self, forKey: .wasAIProcessed)
        self.processingModel = try container.decodeIfPresent(String.self, forKey: .processingModel)
        self.transcriptionDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .transcriptionDurationMilliseconds
        )
        self.parakeetProcessingDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .parakeetProcessingDurationMilliseconds
        )
        self.aiProcessingDurationMilliseconds = try container.decodeIfPresent(
            Int.self,
            forKey: .aiProcessingDurationMilliseconds
        )
        self.aiTokensPerSecond = try container.decodeIfPresent(Double.self, forKey: .aiTokensPerSecond)
        self.aiProcessingError = try container.decodeIfPresent(String.self, forKey: .aiProcessingError)
        self.audio = try container.decodeIfPresent(DictationAudioMetadata.self, forKey: .audio)
        self.isStarred = try container.decodeIfPresent(Bool.self, forKey: .isStarred) ?? false
        self.searchRevision = try container.decodeIfPresent(UInt64.self, forKey: .searchRevision)
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, rawText, processedText, appName, windowTitle
        case characterCount, wasAIProcessed, processingModel
        case transcriptionDurationMilliseconds, parakeetProcessingDurationMilliseconds, aiProcessingDurationMilliseconds
        case aiTokensPerSecond
        case aiProcessingError, audio, searchRevision, isStarred
    }

    /// Preview text for list display (first 80 chars)
    var previewText: String {
        let text = self.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 80 {
            return String(text.prefix(77)) + "..."
        }
        return text
    }

    var clipboardText: String? {
        let processed = self.processedText.trimmingCharacters(in: .whitespacesAndNewlines)
        let raw = self.rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = processed.isEmpty ? raw : processed
        return text.isEmpty ? nil : text
    }

    /// Relative time string for display
    var relativeTimeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self.timestamp, relativeTo: Date())
    }

    /// Full formatted date string
    var fullDateString: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: self.timestamp)
    }

    var hasAudioMetadata: Bool {
        self.audio != nil
    }

    static func formattedDuration(milliseconds: Int) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds) ms"
        }
        return String(format: "%.1f s", Double(milliseconds) / 1000)
    }

    static func formattedTokensPerSecond(_ tokensPerSecond: Double, compact: Bool = false) -> String {
        let rounded = tokensPerSecond >= 100
            ? String(Int(tokensPerSecond.rounded()))
            : String(format: "%.1f", tokensPerSecond)
        return compact ? "\(rounded) tok/s" : "\(rounded) tokens/sec"
    }

    func replacingAudio(_ audio: DictationAudioMetadata?) -> TranscriptionHistoryEntry {
        TranscriptionHistoryEntry(
            id: self.id,
            timestamp: self.timestamp,
            rawText: self.rawText,
            processedText: self.processedText,
            appName: self.appName,
            windowTitle: self.windowTitle,
            characterCount: self.characterCount,
            wasAIProcessed: self.wasAIProcessed,
            processingModel: self.processingModel,
            transcriptionDurationMilliseconds: self.transcriptionDurationMilliseconds,
            parakeetProcessingDurationMilliseconds: self.parakeetProcessingDurationMilliseconds,
            aiProcessingDurationMilliseconds: self.aiProcessingDurationMilliseconds,
            aiTokensPerSecond: self.aiTokensPerSecond,
            aiProcessingError: self.aiProcessingError,
            audio: audio,
            isStarred: self.isStarred,
            searchRevision: self.searchRevision
        )
    }

    /// A restore can hand an existing id different text, and the search index only
    /// replaces a row whose revision rose. Bumping past the restored revision, the
    /// indexed one and the wall clock keeps that true whichever backup the text came
    /// from, including one written before this field existed.
    mutating func markRestored(over indexed: UInt64?, at date: Date = Date()) {
        let now = UInt64(max(1, date.timeIntervalSince1970 * 1000))
        let base = max(now, self.searchRevision ?? 1, indexed ?? 1)
        self.searchRevision = base == .max ? .max : base + 1
    }
}

/// One pending sidebar reveal. Repeated clicks replace it; it is never persisted.
nonisolated struct HistorySearchSelectionRequest: Equatable {
    let token = UUID()
    let entryID: UUID
}

/// One recording's local output lifetime, frozen before capture starts. The only hidden
/// write authority is the writer's unforgeable entry-scoped admission, never a visibility flag.
@MainActor final class DictationHistoryWriteAdmission {
    let entryID: UUID
    fileprivate let history: TranscriptionHistoryStore
    fileprivate let write: TranscriptionHistoryWriteAdmission
    fileprivate var finishing = false
    fileprivate var finished = false
    fileprivate var revoked = false
    fileprivate var entry: TranscriptionHistoryEntry?
    fileprivate var audio: DictationAudioSaveAdmission?
    fileprivate init(history: TranscriptionHistoryStore, write: TranscriptionHistoryWriteAdmission) {
        self.history = history; self.write = write; self.entryID = write.entryID
    }
    func admitAudioSave(timestamp: Date) throws -> DictationAudioSaveAdmission {
        try self.history.admitAudioSave(for: self, timestamp: timestamp)
    }
    func attachAudio(_ metadata: DictationAudioMetadata, from audio: DictationAudioSaveAdmission) throws {
        try self.history.attachAudio(metadata, admission: self, from: audio)
    }
    func finish() async throws { try await self.history.finishRecordingWrite(self) }
    func retryPersistence() async throws { try await self.history.retryRecordingWrite(self) }
}

// MARK: - Transcription History Store

@MainActor
final class TranscriptionHistoryStore: ObservableObject {
    static var shared: TranscriptionHistoryStore {
        PrivateProfileObjectCache.value(key: "TranscriptionHistoryStore") {
            TranscriptionHistoryStore(profile: PrivateProfileStorage.current)
        }
    }

    private let writer: TranscriptionHistoryWriter
    private let profile: PrivateProfileSnapshot?
    private let audioStore: DictationAudioHistoryStore
    private var transitioning = false
    private var retired = false
    private var canAccess: Bool {
        !self.transitioning && !self.retired && self.profile.map(PrivateProfileStorage.isReadable) != false
    }
    private var recordingWrites: [UUID: DictationHistoryWriteAdmission] = [:]
    private var recordingJoinWaiters: [CheckedContinuation<Void, Never>] = []
    var admittedRecordingWriteCount: Int { self.recordingWrites.count }
    private var retainedEntries: [TranscriptionHistoryEntry] = []
    private var loadTask: Task<Void, Never>?
    @Published private var hasLoaded = false
    private var pendingUpserts: [UUID: TranscriptionHistoryEntry] = [:]
    private var pendingDeletes: Set<UUID> = []
    private var pendingReplacement = false
    @Published private(set) var isLoading = true
    @Published private(set) var persistenceError: String?

    @Published private var visibleEntries: [TranscriptionHistoryEntry] = []
    private(set) var entries: [TranscriptionHistoryEntry] {
        get { self.canAccess ? self.visibleEntries : [] }
        set {
            self.retainedEntries = newValue
            if self.canAccess { self.visibleEntries = newValue }
        }
    }
    var entriesPublisher: AnyPublisher<[TranscriptionHistoryEntry], Never> {
        self.$visibleEntries.map { [weak self] entries in self?.canAccess == true ? entries : [] }.eraseToAnyPublisher()
    }

    /// Replays the current snapshot only after loading and merging pending edits succeed.
    /// An empty loaded history is authoritative; an unloaded or failed one is not.
    var loadedEntriesPublisher: AnyPublisher<[TranscriptionHistoryEntry], Never> {
        self.$visibleEntries.combineLatest(self.$hasLoaded)
            .compactMap { [weak self] entries, hasLoaded in hasLoaded && self?.canAccess == true ? entries : nil }
            .eraseToAnyPublisher()
    }

    @Published var selectedEntryID: UUID?
    @Published private(set) var searchSelectionRequest: HistorySearchSelectionRequest?

    func selectEntryFromSearch(id: UUID) {
        guard self.canAccess else { return }
        self.selectedEntryID = id
        self.searchSelectionRequest = HistorySearchSelectionRequest(entryID: id)
    }

    func consumeSearchSelectionRequest(_ request: HistorySearchSelectionRequest) {
        guard self.canAccess else { return }
        guard self.searchSelectionRequest == request else { return }
        self.searchSelectionRequest = nil
    }

    /// Last completed snapshot while a coalesced background refresh is pending.
    /// Rendering must never scan history or schedule work.
    @Published private var visibleTodaySummary = TodaySummary(words: 0, transcriptions: 0)
    private(set) var todaySummary: TodaySummary {
        get { self.canAccess ? self.visibleTodaySummary : TodaySummary(words: 0, transcriptions: 0) }
        set { if self.canAccess { self.visibleTodaySummary = newValue } }
    }
    var todaySummaryPublisher: AnyPublisher<TodaySummary, Never> {
        self.$visibleTodaySummary.map { [weak self] summary in
            self?.canAccess == true ? summary : TodaySummary(words: 0, transcriptions: 0)
        }.eraseToAnyPublisher()
    }
    private var todaySummaryTask: Task<Void, Never>?
    private var todaySummaryRevision: UInt64 = 0
    private var todaySummaryDay: DateInterval?
    private var audioBudgetRevision: UInt64 = 0
    private var automaticAudioBudgetTask: Task<Void, Never>?
    private(set) var audioSaveGeneration: UInt64 = 0
    private var calendarObservers: [NSObjectProtocol] = []
    private let summaryNow: () -> Date
    private let summaryCalendar: () -> Calendar
    private let deleteAllAudioFiles: () -> Void

    init(
        writer: TranscriptionHistoryWriter? = nil,
        profile: PrivateProfileSnapshot? = nil,
        audioStore: DictationAudioHistoryStore? = nil,
        summaryNow: @escaping () -> Date = Date.init,
        summaryCalendar: @escaping () -> Calendar = { Calendar.current },
        deleteAllAudioFiles: (() -> Void)? = nil
    ) {
        let selected = profile ?? (writer == nil ? PrivateProfileStorage.current : nil)
        let audioStore = audioStore ?? selected.map(DictationAudioHistoryStore.scoped)
            ?? DictationAudioHistoryStore.shared
        self.profile = selected
        self.audioStore = audioStore
        self.writer = writer ?? TranscriptionHistoryWriter(profile: selected)
        self.summaryNow = summaryNow
        self.summaryCalendar = summaryCalendar
        self.deleteAllAudioFiles = deleteAllAudioFiles ?? { audioStore.deleteAllAudioFiles() }
        self.observeSummaryCalendarChanges()
        self.loadEntries()
    }

    isolated deinit {
        for observer in self.calendarObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Parent calls immediately on conceal; retained durability state stays private for retry.
    func concealPrivateProjections() {
        self.visibleEntries = []
        self.visibleTodaySummary = TodaySummary(words: 0, transcriptions: 0)
        self.selectedEntryID = nil
        self.searchSelectionRequest = nil
        self.todaySummaryTask?.cancel()
        self.automaticAudioBudgetTask?.cancel()
    }

    func admitRecordingWrite(entryID: UUID = UUID()) throws -> DictationHistoryWriteAdmission {
        guard self.canAccess, PrivateProfileStorage.acceptsNewWork,
              self.recordingWrites[entryID] == nil else { throw CancellationError() }
        let write = try self.writer.admitRecordingWrite(entryID: entryID, saveGeneration: self.audioSaveGeneration)
        let admission = DictationHistoryWriteAdmission(history: self, write: write)
        self.recordingWrites[entryID] = admission
        return admission
    }

    private func validates(_ admission: DictationHistoryWriteAdmission, allowFinishing: Bool = false) -> Bool {
        admission.history === self && self.recordingWrites[admission.entryID] === admission
            && !admission.finished && !admission.revoked && (allowFinishing || !admission.finishing)
            && admission.write.isActiveForCurrentOwner
    }

    fileprivate func admitAudioSave(for admission: DictationHistoryWriteAdmission, timestamp: Date) throws -> DictationAudioSaveAdmission {
        guard self.validates(admission), admission.audio == nil,
              admission.write.saveGeneration == self.audioSaveGeneration else { throw CancellationError() }
        let audio = try self.audioStore.admitSave(for: admission.write, timestamp: timestamp)
        admission.audio = audio
        return audio
    }

    fileprivate func attachAudio(_ metadata: DictationAudioMetadata, admission: DictationHistoryWriteAdmission,
                                 from audio: DictationAudioSaveAdmission) throws {
        guard admission.history === self, admission.audio === audio else { throw CancellationError() }
        defer { audio.complete() }
        guard self.validates(admission, allowFinishing: true), admission.write.saveGeneration == self.audioSaveGeneration,
              let entry = self.retainedEntries.first(where: { $0.id == admission.entryID }) ?? admission.entry,
              self.audioStore.claimMetadata(metadata, from: audio, history: admission.write) else {
            audio.discardUnattached()
            throw CancellationError()
        }
        let updated = entry.replacingAudio(metadata)
        admission.entry = updated
        self.writeAdmitted(updated, admission: admission)
    }

    fileprivate func finishRecordingWrite(_ admission: DictationHistoryWriteAdmission) async throws {
        guard admission.history === self, !admission.finished else { return }
        admission.finishing = true
        // Canceled capture may never start its reserved worker. Started workers own their
        // completion through metadata enqueue and must still be joined.
        admission.audio?.abortIfUnstarted()
        if admission.revoked || admission.entry == nil {
            admission.audio?.discardUnattached()
            admission.audio?.complete()
        }
        await admission.audio?.waitUntilCompleted()
        await self.loadTask?.value
        do { try await self.writer.finish(admission.write) }
        catch { admission.finishing = false; throw error }
        admission.finished = true
        self.recordingWrites.removeValue(forKey: admission.entryID)
        if self.recordingWrites.isEmpty {
            let waiters = self.recordingJoinWaiters; self.recordingJoinWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }

    fileprivate func retryRecordingWrite(_ admission: DictationHistoryWriteAdmission) async throws {
        guard self.validates(admission),
              let entry = self.retainedEntries.first(where: { $0.id == admission.entryID }) ?? admission.entry else { throw CancellationError() }
        admission.entry = entry
        self.writeAdmitted(entry, admission: admission)
        try await self.finishRecordingWrite(admission)
    }

    /// Retries only retained failed recording payloads under their original capabilities.
    func retryAdmittedRecordingWrites() async throws {
        for admission in Array(self.recordingWrites.values) { try await self.retryRecordingWrite(admission) }
    }

    func joinAdmittedRecordingWrites() async {
        guard !self.recordingWrites.isEmpty else { return }
        await withCheckedContinuation { self.recordingJoinWaiters.append($0) }
    }

    private func writeAdmitted(_ entry: TranscriptionHistoryEntry, admission: DictationHistoryWriteAdmission) {
        if self.canAccess {
            if let index = self.retainedEntries.firstIndex(where: { $0.id == entry.id }) { self.retainedEntries[index] = entry }
            else { self.retainedEntries.insert(entry, at: 0) }
            self.visibleEntries = self.retainedEntries
            self.refreshTodaySummary()
            if entry.audio != nil { self.scheduleAutomaticAudioPruneToBudget() }
        }
        self.writer.write(entry, admission: admission.write) { error in
            guard let error else { return }
            Task { @MainActor in
                if self.canAccess { self.persistenceError = error.localizedDescription }
            }
        }
    }

    // MARK: - Public Methods

    /// Get selected entry
    var selectedEntry: TranscriptionHistoryEntry? {
        guard self.canAccess else { return nil }
        guard let id = selectedEntryID else { return nil }
        return self.entries.first(where: { $0.id == id })
    }

    var latestClipboardText: String? {
        guard self.canAccess else { return nil }
        return self.entries.first?.clipboardText
    }

    /// Add a new transcription entry
    func addEntry(
        id: UUID? = nil,
        timestamp: Date = Date(),
        rawText: String,
        processedText: String,
        appName: String,
        windowTitle: String,
        wasAIProcessed: Bool? = nil,
        processingModel: String? = nil,
        transcriptionDurationMilliseconds: Int? = nil,
        parakeetProcessingDurationMilliseconds: Int? = nil,
        aiProcessingDurationMilliseconds: Int? = nil,
        aiTokensPerSecond: Double? = nil,
        aiProcessingError: String? = nil,
        audio: DictationAudioMetadata? = nil,
        admission: DictationHistoryWriteAdmission? = nil
    ) {
        let id = id ?? admission?.entryID ?? UUID()
        if let admission {
            guard self.validates(admission), admission.entryID == id else { return }
        } else { guard self.canAccess else { return } }
        // Skip empty transcriptions
        guard !processedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let entry = TranscriptionHistoryEntry(
            id: id,
            timestamp: timestamp,
            rawText: rawText,
            processedText: processedText,
            appName: appName,
            windowTitle: windowTitle,
            wasAIProcessed: wasAIProcessed ?? (processingModel != nil && aiProcessingError == nil),
            processingModel: processingModel,
            transcriptionDurationMilliseconds: transcriptionDurationMilliseconds,
            parakeetProcessingDurationMilliseconds: parakeetProcessingDurationMilliseconds,
            aiProcessingDurationMilliseconds: aiProcessingDurationMilliseconds,
            aiTokensPerSecond: aiTokensPerSecond,
            aiProcessingError: aiProcessingError,
            audio: audio
        )

        if let admission {
            admission.entry = entry
            self.writeAdmitted(entry, admission: admission)
            return
        }
        // Insert at beginning (newest first)
        self.entries.insert(entry, at: 0)
        self.refreshTodaySummary()

        self.persist(upserts: [entry])
        if audio != nil {
            self.scheduleAutomaticAudioPruneToBudget()
        }

        DebugLogger.shared.debug("Added transcription to history (total: \(self.entries.count))", source: "TranscriptionHistoryStore")
    }

    func toggleStar(id: UUID) {
        guard self.canAccess else { return }
        guard let index = self.entries.firstIndex(where: { $0.id == id }) else { return }
        self.entries[index].isStarred.toggle()
        self.persist(upserts: [self.entries[index]])
    }

    private func revokeRecordingWrite(for entryID: UUID) {
        guard let admission = self.recordingWrites[entryID] else { return }
        admission.revoked = true
        self.writer.revoke(admission.write)
        admission.audio?.discardUnattached()
        admission.audio?.complete()
    }

    /// Delete a specific entry
    func deleteEntry(id: UUID) {
        guard self.canAccess else { return }
        self.revokeRecordingWrite(for: id)
        self.invalidateAutomaticAudioBudgetMeasurement()
        if let audio = self.entries.first(where: { $0.id == id })?.audio {
            self.audioStore.deleteAudio(fileName: audio.fileName)
        }
        let previousCount = self.entries.count
        self.entries.removeAll { $0.id == id }
        if self.entries.count != previousCount {
            self.refreshTodaySummary()
        }

        // Clear selection if deleted
        if self.selectedEntryID == id {
            self.selectedEntryID = self.entries.first?.id
        }

        self.persist(deletes: [id])
    }

    /// Delete multiple entries
    func deleteEntries(ids: Set<UUID>) {
        guard self.canAccess else { return }
        for id in ids { self.revokeRecordingWrite(for: id) }
        self.invalidateAutomaticAudioBudgetMeasurement()
        for entry in self.entries where ids.contains(entry.id) {
            if let audio = entry.audio {
                self.audioStore.deleteAudio(fileName: audio.fileName)
            }
        }
        let previousCount = self.entries.count
        self.entries.removeAll { ids.contains($0.id) }
        if self.entries.count != previousCount {
            self.refreshTodaySummary()
        }

        if let selected = selectedEntryID, ids.contains(selected) {
            self.selectedEntryID = self.entries.first?.id
        }

        self.persist(deletes: Array(ids))
    }

    /// Clear all history
    func clearAllHistory() {
        guard self.canAccess else { return }
        for id in self.recordingWrites.keys { self.revokeRecordingWrite(for: id) }
        self.audioSaveGeneration &+= 1
        self.invalidateAutomaticAudioBudgetMeasurement()
        self.deleteAllAudioFiles()
        self.entries.removeAll()
        self.refreshTodaySummary()
        self.selectedEntryID = nil
        self.persist(replacing: true)

        DebugLogger.shared.info("Cleared all transcription history", source: "TranscriptionHistoryStore")
    }

    /// Search entries by text content
    func search(query: String, starredOnly: Bool = false, pinnedFirst: Bool = false) -> [TranscriptionHistoryEntry] {
        guard self.canAccess else { return [] }
        let entries = starredOnly ? self.entries.filter(\.isStarred) : self.entries
        let matches: [TranscriptionHistoryEntry]
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            matches = entries
        } else {
            let lowercased = query.lowercased()
            matches = entries.filter { entry in
                entry.rawText.lowercased().contains(lowercased) ||
                    entry.processedText.lowercased().contains(lowercased) ||
                    entry.appName.lowercased().contains(lowercased) ||
                    entry.windowTitle.lowercased().contains(lowercased)
            }
        }
        guard pinnedFirst, !starredOnly else { return matches }
        // Stable, linear partition for History's display; stored chronology and other readers stay unchanged.
        return matches.filter(\.isStarred) + matches.filter { !$0.isStarred }
    }

    /// Get entries filtered by date range
    func entriesInRange(from startDate: Date, to endDate: Date) -> [TranscriptionHistoryEntry] {
        guard self.canAccess else { return [] }
        return self.entries.filter { $0.timestamp >= startDate && $0.timestamp <= endDate }
    }

    /// Get total character count across all entries
    var totalCharacterCount: Int {
        self.entries.reduce(0) { $0 + $1.characterCount }
    }

    /// Get count of AI-processed entries
    var aiProcessedCount: Int {
        self.entries.filter { $0.wasAIProcessed }.count
    }

    func makeBackupPayload() -> [TranscriptionHistoryEntry] {
        guard self.canAccess else { return [] }
        return self.entries
    }

    func restore(from payload: [TranscriptionHistoryEntry]) {
        guard self.canAccess else { return }
        for id in self.recordingWrites.keys { self.revokeRecordingWrite(for: id) }
        self.audioSaveGeneration &+= 1
        self.invalidateAutomaticAudioBudgetMeasurement()
        let indexed = Dictionary(self.entries.map { ($0.id, $0.searchRevision ?? 1) }) { first, _ in first }
        self.entries = payload
            .map { entry in
                var entry = entry
                entry.markRestored(over: indexed[entry.id])
                return entry
            }
            .sorted { $0.timestamp > $1.timestamp }
        self.refreshTodaySummary()
        self.selectedEntryID = self.entries.first?.id
        self.persist(upserts: self.entries, replacing: true)
    }

    func attachAudio(
        _ audio: DictationAudioMetadata,
        to entryID: UUID,
        expectedSaveGeneration: UInt64? = nil
    ) {
        guard self.canAccess else { return }
        if let expectedSaveGeneration, expectedSaveGeneration != self.audioSaveGeneration {
            self.audioStore.deleteAudio(fileName: audio.fileName)
            return
        }
        guard let index = self.entries.firstIndex(where: { $0.id == entryID }) else {
            self.audioStore.deleteAudio(fileName: audio.fileName)
            return
        }
        self.entries[index] = self.entries[index].replacingAudio(audio)
        self.persist(upserts: [self.entries[index]])
        self.scheduleAutomaticAudioPruneToBudget()
    }

    @discardableResult
    func deleteAllSavedAudio() -> Int {
        guard self.canAccess else { return 0 }
        guard self.hasLoaded else { return 0 }
        self.audioSaveGeneration &+= 1
        for admission in self.recordingWrites.values {
            admission.audio?.discardUnattached()
            admission.audio?.complete()
        }
        self.invalidateAutomaticAudioBudgetMeasurement()
        let removedCount = self.entries.filter { $0.audio != nil }.count
        self.deleteAllAudioFiles()
        let changed = self.entries.filter { $0.audio != nil }.map { $0.replacingAudio(nil) }
        self.entries = self.entries.map { $0.replacingAudio(nil) }
        self.persist(upserts: changed)
        DebugLogger.shared.info("Deleted saved dictation audio (\(removedCount) entries)", source: "TranscriptionHistoryStore")
        return removedCount
    }

    @discardableResult
    func pruneAudioToBudget() -> Int {
        guard self.canAccess else { return 0 }
        // An incomplete startup snapshot must never classify older recordings as orphaned.
        guard self.hasLoaded else { return 0 }
        self.invalidateAutomaticAudioBudgetMeasurement()
        let budgetBytes = SettingsStore.shared.audioHistoryBudgetBytes
        let currentBytes = self.audioStore.audioUsageBytes()
        return self.pruneAudioToBudget(currentBytes: currentBytes, budgetBytes: budgetBytes)
    }

    private func pruneAudioToBudget(currentBytes initialCurrentBytes: Int64, budgetBytes: Int64) -> Int {
        guard budgetBytes > 0 else {
            return self.deleteAllSavedAudio()
        }

        var currentBytes = initialCurrentBytes
        guard currentBytes > budgetBytes else { return 0 }

        var updatedEntries = self.entries
        let referencedFileNames = Set(updatedEntries.compactMap { $0.audio?.fileName })
        let orphanedAudio = self.audioStore.deleteUnreferencedAudioFiles(referencedFileNames: referencedFileNames)
        if orphanedAudio.fileCount > 0 {
            currentBytes = max(0, currentBytes - orphanedAudio.byteCount)
            DebugLogger.shared.info("Pruned orphaned dictation audio (\(orphanedAudio.fileCount) files)", source: "TranscriptionHistoryStore")
        }
        guard currentBytes > budgetBytes else { return 0 }

        var prunedCount = 0
        var changed: [TranscriptionHistoryEntry] = []
        for index in updatedEntries.indices.reversed() {
            guard let audio = updatedEntries[index].audio else { continue }
            let removedBytes = self.audioStore.deleteAudio(fileName: audio.fileName)
            currentBytes = max(0, currentBytes - removedBytes)
            updatedEntries[index] = updatedEntries[index].replacingAudio(nil)
            changed.append(updatedEntries[index])
            prunedCount += 1
            if currentBytes <= budgetBytes {
                break
            }
        }

        if prunedCount > 0 {
            self.entries = updatedEntries
            self.persist(upserts: changed)
            DebugLogger.shared.info("Pruned saved dictation audio (\(prunedCount) entries)", source: "TranscriptionHistoryStore")
        }
        return prunedCount
    }

    private func invalidateAutomaticAudioBudgetMeasurement() {
        self.audioBudgetRevision &+= 1
    }

    private func scheduleAutomaticAudioPruneToBudget() {
        self.audioBudgetRevision &+= 1
        guard self.hasLoaded, self.automaticAudioBudgetTask == nil else { return }

        self.automaticAudioBudgetTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while true {
                let gate = AudioBudgetMeasurementGate(
                    revision: self.audioBudgetRevision,
                    budgetBytes: SettingsStore.shared.audioHistoryBudgetBytes
                )
                guard !Task.isCancelled else { self.automaticAudioBudgetTask = nil; return }
                let audioStore = self.audioStore
                let currentBytes = await Task.detached(priority: .utility) {
                    audioStore.audioUsageBytes()
                }.value
                guard !Task.isCancelled, self.canAccess else { self.automaticAudioBudgetTask = nil; return }
                guard gate.accepts(
                    currentRevision: self.audioBudgetRevision,
                    currentBudgetBytes: SettingsStore.shared.audioHistoryBudgetBytes
                ) else {
                    continue
                }

                _ = self.pruneAudioToBudget(
                    currentBytes: currentBytes,
                    budgetBytes: gate.budgetBytes
                )
                self.automaticAudioBudgetTask = nil
                return
            }
        }
    }

    // MARK: - Private Methods

    private func loadEntries() {
        self.isLoading = true
        self.loadTask = Task { @MainActor in
            do {
                let loaded = try await self.writer.load()
                var upserts = self.pendingUpserts
                for admission in self.recordingWrites.values {
                    if !admission.revoked, !self.pendingDeletes.contains(admission.entryID),
                       let entry = admission.entry, upserts[entry.id] == nil {
                        upserts[entry.id] = self.retainedEntries.first(where: { $0.id == entry.id }) ?? entry
                    }
                }
                var merged = self.pendingReplacement ? [] : loaded.filter { !self.pendingDeletes.contains($0.id) && upserts[$0.id] == nil }
                merged.append(contentsOf: upserts.values)
                self.entries = merged.sorted { $0.timestamp > $1.timestamp }
                if self.canAccess { self.refreshTodaySummary() }
                self.hasLoaded = true
                self.persistenceError = nil
                if self.pendingReplacement || !self.pendingUpserts.isEmpty || !self.pendingDeletes.isEmpty {
                    self.persist(upserts: Array(self.pendingUpserts.values), deletes: Array(self.pendingDeletes), replacing: self.pendingReplacement)
                }
                self.pendingUpserts.removeAll()
                self.pendingDeletes.removeAll()
                self.pendingReplacement = false
            } catch {
                self.persistenceError = "History could not be loaded. New dictations are kept in memory until you retry. \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }

    /// Only immutable changed entries cross to the writer. No full-history encoding on the main actor.
    private func persist(upserts: [TranscriptionHistoryEntry] = [], deletes: [UUID] = [], replacing: Bool = false) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        guard self.hasLoaded else {
            if replacing {
                self.pendingReplacement = true
                self.pendingUpserts.removeAll()
                self.pendingDeletes.removeAll()
            }
            for id in deletes {
                self.pendingUpserts.removeValue(forKey: id)
                self.pendingDeletes.insert(id)
            }
            for entry in upserts {
                self.pendingDeletes.remove(entry.id)
                self.pendingUpserts[entry.id] = entry
            }
            return
        }
        self.writer.write(upserts: upserts, deletes: deletes, replacing: replacing) { error in
            guard let error else { return }
            Task { @MainActor in
                self.persistenceError = AppBrand.format("History could not be saved. Keep FluidVoice open and retry. %@", error.localizedDescription)
            }
        }
        DebugLogger.shared.debug(
            "HISTORY_BENCH enqueueMs=\((ProcessInfo.processInfo.systemUptime - startedAt) * 1000) upserts=\(upserts.count) deletes=\(deletes.count)",
            source: "TranscriptionHistoryStore"
        )
    }

    /// Search retries may reload unavailable history, but must never rewrite it.
    func retryLoadingIfNeeded() {
        guard !self.hasLoaded else { return }
        self.retryPersistence()
    }

    func retryPersistence() {
        guard self.canAccess else { return }
        guard !self.isLoading else { return }
        guard self.hasLoaded else {
            self.loadEntries()
            return
        }
        self.writer.write(upserts: self.entries, replacing: true) { error in
            Task { @MainActor in
                self.persistenceError = error.map { "History could not be saved. \($0.localizedDescription)" }
            }
        }
    }

    func waitUntilLoaded() async throws {
        guard self.canAccess else { throw CancellationError() }
        await self.loadTask?.value
        guard self.canAccess else { throw CancellationError() }
        guard self.hasLoaded else {
            throw NSError(domain: "HistoryPersistence", code: 1, userInfo: [NSLocalizedDescriptionKey: self.persistenceError ?? "History is unavailable."])
        }
    }

    func finishPendingWrites() async {
        await self.loadTask?.value
        await self.automaticAudioBudgetTask?.value
        if let error = await self.writer.drain(), self.canAccess {
            self.persistenceError = AppBrand.format("History could not be saved. Keep FluidVoice open and retry. %@", error.localizedDescription)
        }
    }

    /// Join all admitted work before clearing the Published projections and replacing sources.
    /// A persistence failure keeps this profile selected so the user can retry without data loss.
    func prepareForProfileTransition() async throws {
        guard !self.retired else { return }
        guard self.recordingWrites.isEmpty else { throw AccountError.busy }
        self.transitioning = true
        self.todaySummaryTask?.cancel()
        self.automaticAudioBudgetTask?.cancel()
        await self.loadTask?.value
        await self.todaySummaryTask?.value
        await self.automaticAudioBudgetTask?.value
        if let error = await self.writer.drain() {
            self.transitioning = false
            throw error
        }
        guard self.pendingUpserts.isEmpty, self.pendingDeletes.isEmpty, !self.pendingReplacement else {
            self.transitioning = false
            throw AccountError.busy
        }
        self.retired = true
        self.audioSaveGeneration &+= 1
        self.retainedEntries = []
        self.concealPrivateProjections()
        for observer in self.calendarObservers { NotificationCenter.default.removeObserver(observer) }
        self.calendarObservers = []
    }

    // MARK: - Event-driven Today Snapshot

    private func observeSummaryCalendarChanges() {
        let names: [Notification.Name] = [
            .NSCalendarDayChanged, .NSSystemTimeZoneDidChange, .NSSystemClockDidChange,
            NSLocale.currentLocaleDidChangeNotification, NSApplication.didBecomeActiveNotification,
        ]
        self.calendarObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshTodaySummaryForCalendarChange()
                }
            }
        }
    }

    func refreshTodaySummaryForCalendarChange() {
        guard self.canAccess else { return }
        let day = self.summaryCalendar().dateInterval(of: .day, for: self.summaryNow())
        guard day != self.todaySummaryDay else { return }
        self.refreshTodaySummary()
    }

    private func refreshTodaySummary() {
        self.todaySummaryRevision &+= 1
        guard self.todaySummaryTask == nil else { return }
        self.todaySummaryTask = Task { @MainActor [weak self] in
            // Coalesce synchronous load/restore/delete bursts into one immutable snapshot.
            await Task.yield()
            guard let self else { return }
            while true {
                let revision = self.todaySummaryRevision
                let day = self.summaryCalendar().dateInterval(of: .day, for: self.summaryNow())
                let snapshot = self.entries
                guard !Task.isCancelled else { self.todaySummaryTask = nil; return }
                let summary = await Task.detached(priority: .utility) {
                    Self.calculateTodaySummary(entries: snapshot, day: day)
                }.value
                guard !Task.isCancelled else { self.todaySummaryTask = nil; return }
                guard revision == self.todaySummaryRevision,
                      day == self.summaryCalendar().dateInterval(of: .day, for: self.summaryNow())
                else { continue }
                self.todaySummaryDay = day
                if self.todaySummary != summary {
                    self.todaySummary = summary
                }
                // Published subscribers may synchronously mutate history again.
                guard revision == self.todaySummaryRevision else { continue }
                self.todaySummaryTask = nil
                return
            }
        }
    }

    func waitForTodaySummary() async {
        await self.todaySummaryTask?.value
    }

    private nonisolated static func calculateTodaySummary(entries: [TranscriptionHistoryEntry], day: DateInterval?) -> TodaySummary {
        guard let day else { return TodaySummary(words: 0, transcriptions: 0) }
        let totals = entries.reduce(into: (words: 0, transcriptions: 0)) { result, entry in
            guard entry.timestamp >= day.start, entry.timestamp < day.end else { return }
            result.words += Self.countWords(in: entry.processedText)
            result.transcriptions += 1
        }
        return TodaySummary(words: totals.words, transcriptions: totals.transcriptions)
    }
}

// MARK: - Stats Computation Extension

extension TranscriptionHistoryStore {
    nonisolated struct TodaySummary: Equatable, Sendable {
        let words: Int
        let transcriptions: Int

        func timeSavedMinutes(typingWPM: Int = 40, speakingWPM: Int = 150) -> Double {
            guard typingWPM > 0 && speakingWPM > 0 else { return 0 }

            let words = Double(self.words)
            let typingTime = words / Double(typingWPM)
            let speakingTime = words / Double(speakingWPM)

            return max(0, typingTime - speakingTime)
        }

        func formattedTimeSaved(typingWPM: Int = 40) -> String {
            PichiLocalization.formattedTimeSaved(minutes: self.timeSavedMinutes(typingWPM: typingWPM))
        }
    }

    // MARK: - Word Counting

    /// Count words in a string (handles multiple spaces, newlines)
    private func wordCount(in text: String) -> Int {
        Self.countWords(in: text)
    }

    private nonisolated static func countWords(in text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let words = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        return words.count
    }

    /// Total words across all transcriptions
    var totalWords: Int {
        self.entries.reduce(0) { $0 + self.wordCount(in: $1.processedText) }
    }

    /// Words transcribed today
    var wordsToday: Int {
        self.todaySummary.words
    }

    /// Number of transcriptions recorded today
    var transcriptionsToday: Int {
        self.todaySummary.transcriptions
    }

    /// Average words per transcription
    var averageWordsPerTranscription: Int {
        guard !self.entries.isEmpty else { return 0 }
        return self.totalWords / self.entries.count
    }

    // MARK: - Time Saved Calculation

    /// Calculate time saved in minutes
    /// - Parameters:
    ///   - typingWPM: User's typing speed (default 40)
    ///   - speakingWPM: Average speaking speed (default 150)
    func timeSavedMinutes(typingWPM: Int = 40, speakingWPM: Int = 150) -> Double {
        guard typingWPM > 0 && speakingWPM > 0 else { return 0 }

        let words = Double(totalWords)
        let typingTime = words / Double(typingWPM) // minutes to type
        let speakingTime = words / Double(speakingWPM) // minutes to speak

        return max(0, typingTime - speakingTime)
    }

    /// Time saved in the selected interface language.
    func formattedTimeSaved(typingWPM: Int = 40) -> String {
        PichiLocalization.formattedTimeSaved(minutes: self.timeSavedMinutes(typingWPM: typingWPM))
    }

    // MARK: - Today Time Saved

    /// Calculate time saved today in minutes
    /// - Parameters:
    ///   - typingWPM: User's typing speed (default 40)
    ///   - speakingWPM: Average speaking speed (default 150)
    func timeSavedTodayMinutes(typingWPM: Int = 40, speakingWPM: Int = 150) -> Double {
        self.todaySummary.timeSavedMinutes(typingWPM: typingWPM, speakingWPM: speakingWPM)
    }

    /// Today's time saved in the selected interface language.
    func formattedTimeSavedToday(typingWPM: Int = 40) -> String {
        self.todaySummary.formattedTimeSaved(typingWPM: typingWPM)
    }

    // MARK: - Streak Calculation

    /// Get unique days with activity (sorted newest first)
    private var activeDays: [Date] {
        let calendar = Calendar.current
        var uniqueDays = Set<Date>()

        for entry in self.entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            uniqueDays.insert(day)
        }

        return uniqueDays.sorted(by: >) // newest first
    }

    /// Current streak (consecutive days including today or yesterday)
    var currentStreak: Int {
        let calendar = Calendar.current
        let skipWeekends = SettingsStore.shared.weekendsDontBreakStreak

        // Filter out weekend days if setting is enabled (so weekend usage doesn't interfere)
        let days: [Date]
        if skipWeekends {
            days = self.activeDays.filter { !calendar.isDateInWeekend($0) }
        } else {
            days = self.activeDays
        }

        guard !days.isEmpty else { return 0 }

        let today = calendar.startOfDay(for: Date())
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else {
            return 0
        }

        // Find the most recent "valid" day (skip weekends if setting enabled)
        var checkDay = today
        if skipWeekends {
            // Find the last weekday (today or before)
            while calendar.isDateInWeekend(checkDay) {
                guard let prev = calendar.date(byAdding: .day, value: -1, to: checkDay) else { break }
                checkDay = prev
            }
        }

        // Must have activity on a recent valid day to have an active streak
        guard let firstActiveDay = days.first else { return 0 }

        // Check if the first active day is recent enough (today, yesterday, or last valid weekday)
        let isRecent: Bool
        if skipWeekends {
            // Find previous weekday from today
            var lastValidDay = today
            while calendar.isDateInWeekend(lastValidDay) {
                guard let prev = calendar.date(byAdding: .day, value: -1, to: lastValidDay) else { break }
                lastValidDay = prev
            }
            // Allow one weekday gap (the previous weekday before lastValidDay)
            guard let prevWeekday = self.previousWeekday(before: lastValidDay, calendar: calendar) else {
                isRecent = firstActiveDay == lastValidDay
                return isRecent ? 1 : 0
            }
            isRecent = firstActiveDay == lastValidDay || firstActiveDay == prevWeekday
        } else {
            isRecent = firstActiveDay == today || firstActiveDay == yesterday
        }

        guard isRecent else { return 0 }

        var streak = 1
        var previousDay = firstActiveDay

        for day in days.dropFirst() {
            let expectedPrevious: Date?
            if skipWeekends {
                expectedPrevious = self.previousWeekday(before: previousDay, calendar: calendar)
            } else {
                expectedPrevious = calendar.date(byAdding: .day, value: -1, to: previousDay)
            }

            guard let expected = expectedPrevious else { break }

            if day == expected {
                streak += 1
                previousDay = day
            } else {
                break
            }
        }

        return streak
    }

    /// Helper: get the previous weekday (skipping weekends)
    private func previousWeekday(before date: Date, calendar: Calendar) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: -1, to: date)
        while let c = candidate, calendar.isDateInWeekend(c) {
            candidate = calendar.date(byAdding: .day, value: -1, to: c)
        }
        return candidate
    }

    /// Best streak ever achieved
    var bestStreak: Int {
        let calendar = Calendar.current
        let skipWeekends = SettingsStore.shared.weekendsDontBreakStreak

        // Filter out weekend days if setting is enabled (so weekend usage doesn't interfere)
        let days: [Date]
        if skipWeekends {
            days = self.activeDays.filter { !calendar.isDateInWeekend($0) }.sorted()
        } else {
            days = self.activeDays.sorted() // oldest first for this calculation
        }

        guard !days.isEmpty else { return 0 }

        var maxStreak = 1
        var currentStreakCount = 1
        var previousDay = days[0]

        for day in days.dropFirst() {
            let expectedNext: Date?
            if skipWeekends {
                expectedNext = self.nextWeekday(after: previousDay, calendar: calendar)
            } else {
                expectedNext = calendar.date(byAdding: .day, value: 1, to: previousDay)
            }

            if let expected = expectedNext, day == expected {
                currentStreakCount += 1
                maxStreak = max(maxStreak, currentStreakCount)
            } else {
                currentStreakCount = 1
            }
            previousDay = day
        }

        return maxStreak
    }

    /// Helper: get the next weekday (skipping weekends)
    private func nextWeekday(after date: Date, calendar: Calendar) -> Date? {
        var candidate = calendar.date(byAdding: .day, value: 1, to: date)
        while let c = candidate, calendar.isDateInWeekend(c) {
            candidate = calendar.date(byAdding: .day, value: 1, to: c)
        }
        return candidate
    }

    // MARK: - Daily Activity Data (for charts)

    /// Daily word counts for the last N days
    func dailyWordCounts(days: Int) -> [(date: Date, words: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var result: [(date: Date, words: Int)] = []

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }

            let dayEntries = self.entries.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }
            let words = dayEntries.reduce(0) { $0 + self.wordCount(in: $1.processedText) }

            result.append((date: date, words: words))
        }

        return result.reversed() // oldest to newest for chart display
    }

    /// Daily transcription counts for the last N days
    func dailyTranscriptionCounts(days: Int) -> [(date: Date, count: Int)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())

        var result: [(date: Date, count: Int)] = []

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }

            let count = self.entries.filter { calendar.isDate($0.timestamp, inSameDayAs: date) }.count
            result.append((date: date, count: count))
        }

        return result.reversed()
    }

    // MARK: - Top Apps

    /// Most used apps (sorted by usage count)
    var topApps: [(app: String, count: Int)] {
        var appCounts: [String: Int] = [:]

        for entry in self.entries {
            let app = entry.appName.isEmpty ? "Unknown" : entry.appName
            appCounts[app, default: 0] += 1
        }

        return appCounts
            .map { (app: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    /// Top N apps formatted for display
    func topAppsFormatted(limit: Int = 5) -> [String] {
        self.topApps.prefix(limit).map { $0.app }
    }

    // MARK: - AI Enhancement Rate

    /// Percentage of transcriptions that were AI-enhanced (0-100)
    var aiEnhancementRate: Int {
        guard !self.entries.isEmpty else { return 0 }
        return (self.aiProcessedCount * 100) / self.entries.count
    }

    // MARK: - Peak Usage Hours

    /// Hour of day with most transcriptions (0-23)
    var peakHour: Int? {
        guard !self.entries.isEmpty else { return nil }

        let calendar = Calendar.current
        var hourCounts: [Int: Int] = [:]

        for entry in self.entries {
            let hour = calendar.component(.hour, from: entry.timestamp)
            hourCounts[hour, default: 0] += 1
        }

        return hourCounts.max(by: { $0.value < $1.value })?.key
    }

    /// Formatted peak hour range (e.g., "2-3 PM")
    var peakHourFormatted: String {
        guard let hour = peakHour else { return "N/A" }

        let formatter = DateFormatter()
        formatter.dateFormat = "h a"

        let calendar = Calendar.current
        var components = DateComponents()
        components.hour = hour

        guard let startDate = calendar.date(from: components),
              let endDate = calendar.date(byAdding: .hour, value: 1, to: startDate)
        else {
            return "N/A"
        }

        let startStr = formatter.string(from: startDate)
        let endStr = formatter.string(from: endDate)

        return "\(startStr)-\(endStr)"
    }

    // MARK: - Personal Records

    /// Longest single transcription (word count)
    var longestTranscriptionWords: Int {
        self.entries.map { self.wordCount(in: $0.processedText) }.max() ?? 0
    }

    /// Most words in a single day
    var mostWordsInDay: Int {
        let calendar = Calendar.current
        var dayTotals: [Date: Int] = [:]

        for entry in self.entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            dayTotals[day, default: 0] += self.wordCount(in: entry.processedText)
        }

        return dayTotals.values.max() ?? 0
    }

    /// Most transcriptions in a single day
    var mostTranscriptionsInDay: Int {
        let calendar = Calendar.current
        var dayCounts: [Date: Int] = [:]

        for entry in self.entries {
            let day = calendar.startOfDay(for: entry.timestamp)
            dayCounts[day, default: 0] += 1
        }

        return dayCounts.values.max() ?? 0
    }

    // MARK: - Milestones

    /// Word count milestones and whether they've been achieved
    var wordMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (1000, "1K"),
            (10_000, "10K"),
            (50_000, "50K"),
            (100_000, "100K"),
            (500_000, "500K"),
            (1_000_000, "1M"),
        ]

        let total = self.totalWords
        return milestones.map { (target: $0.0, achieved: total >= $0.0, label: $0.1) }
    }

    /// Transcription count milestones
    var transcriptionMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (50, "50"),
            (100, "100"),
            (500, "500"),
            (1000, "1K"),
            (5000, "5K"),
            (10_000, "10K"),
        ]

        let total = self.entries.count
        return milestones.map { (target: $0.0, achieved: total >= $0.0, label: $0.1) }
    }

    /// Streak milestones
    var streakMilestones: [(target: Int, achieved: Bool, label: String)] {
        let milestones = [
            (7, "7 days"),
            (14, "14 days"),
            (30, "30 days"),
            (60, "60 days"),
            (100, "100 days"),
            (365, "1 year"),
        ]

        let best = self.bestStreak
        return milestones.map { (target: $0.0, achieved: best >= $0.0, label: $0.1) }
    }

    /// Total milestones achieved
    var totalMilestonesAchieved: Int {
        self.wordMilestones.filter { $0.achieved }.count +
            self.transcriptionMilestones.filter { $0.achieved }.count +
            self.streakMilestones.filter { $0.achieved }.count
    }

    /// Total possible milestones
    var totalMilestonesPossible: Int {
        self.wordMilestones.count + self.transcriptionMilestones.count + self.streakMilestones.count
    }
}
