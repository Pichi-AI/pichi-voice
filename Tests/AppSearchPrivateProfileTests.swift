import Combine
import Foundation

// The complete production AppSearchService compiles unchanged apart from removing its
// external index import. Index/storage/settings models below are inert synthetic inputs.
nonisolated final class ZeppelinCancellationToken: Sendable {
    static func create() async throws -> ZeppelinCancellationToken { .init() }
    func cancel() async throws {}
}
nonisolated enum SearchIndexKind: String { case history, transcripts, chats }
actor SearchIndex {
    static let shared = SearchIndex()
    struct Hit: Sendable { let id: UUID; let score: Double }
    func query(_: SearchIndexKind, text: String, limit: Int, cancellationToken: ZeppelinCancellationToken?) async throws -> [Hit] { [] }
}
@MainActor final class SearchIndexCoordinator {
    static let shared = SearchIndexCoordinator()
    enum PreparationError: Error { case unavailable }
    func prepareForSearch() async throws {}
}
nonisolated enum ParakeetVocabularyStore {
    enum VocabularyConfig { struct Term: Sendable { let text: String; let aliases: [String] } }
    static func readSearchTerms() async throws -> [VocabularyConfig.Term] { [] }
}
nonisolated extension Notification.Name { static let parakeetVocabularyDidChange = Notification.Name("synthetic-vocabulary-change") }
nonisolated enum SettingsSearchTarget: Hashable, Sendable { case synthetic }
nonisolated struct SearchRecord { let text: String }
nonisolated struct TranscriptionHistoryEntry { let id: UUID; let timestamp: Date; let processedText: String; let searchRecord: SearchRecord }
nonisolated struct FileTranscriptionEntry { let id: UUID; let timestamp: Date; let displayTitle: String; let text: String }
nonisolated struct ChatSession { let id: String; let isArchived: Bool; let title: String; let updatedAt: Date; let searchRecord: SearchRecord? }
@MainActor final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()
    var entries: [TranscriptionHistoryEntry] = []
    func retryLoadingIfNeeded() {}
}
@MainActor final class FileTranscriptionHistoryStore { static let shared = FileTranscriptionHistoryStore(); var entries: [FileTranscriptionEntry] = [] }
@MainActor final class ChatHistoryStore: ObservableObject { static let shared = ChatHistoryStore(); @Published var sessions: [ChatSession] = [] }
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    struct Entry { let id: UUID; let triggers: [String]; let replacement: String }
    struct Prompt { let id: String; let name: String; let prompt: String; let updatedAt: Date }
    struct Punctuation { let id: UUID; let aliases: [String]; let symbol: String }
    var customDictionaryEntries: [Entry] = []
    var dictationPromptProfiles: [Prompt] = []
    var punctuationDictionaryRules: [Punctuation] = []
}
@MainActor enum SettingsSearchIndex {
    enum Availability { case current }
    struct Section { let title: String }
    struct Result { let target: SettingsSearchTarget; let section: Section }
    static func results(for: String, availability: Availability) -> [Result] { [] }
    static func title(for: SettingsSearchTarget) -> String { "Synthetic" }
}
nonisolated final class DebugLogger: Sendable { static let shared = DebugLogger(); func warning(_: String, source: String) {} }
actor SyntheticSearchGate {
    private var reply: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async { started = true; await withCheckedContinuation { reply = $0 } }
    func release() { reply?.resume(); reply = nil }
}
@MainActor final class Completion { var finished = false }
@main struct AppSearchPrivateProfileTests {
    static func main() async throws {
        var checks = 0
        func require(_ condition: @autoclosure () -> Bool, _ code: String) throws {
            checks += 1
            if !condition() { throw NSError(domain: code, code: 1) }
        }
        let original = PrivateProfileStorage.current
        let gate = SyntheticSearchGate()
        let service = AppSearchService(performSearch: { query in
            await gate.wait()
            return [AppSearchGroup(kind: .settings, hits: [AppSearchHit(kind: .settings, target: .settings(.synthetic), title: query, snippet: "", date: nil)])]
        })
        let search = Task { await service.search("synthetic-old-private-query") }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.started), ContinuousClock.now < deadline { await Task.yield() }
        let started = await gate.started
        try require(started, "old-query-started")
        PrivateProfileStorage.conceal(generation: UUID())
        let completion = Completion()
        let join = Task { await service.stopAndJoinForProfileTransition(); completion.finished = true }
        try await Task.sleep(for: .milliseconds(20))
        try require(!completion.finished, "transition-joins-direct-search")
        await gate.release()
        await join.value
        let oldResult = await search.value
        try require(oldResult.isEmpty && service.groups.isEmpty && service.query.isEmpty, "late-old-result-is-hidden")
        PrivateProfileStorage.select(original)
        service.activateCurrentProfile()
        let vocabularyGate = SyntheticSearchGate()
        let vocabulary = AppSearchService(readVocabulary: {
            await vocabularyGate.wait()
            return [.init(text: "synthetic-old-vocabulary", aliases: [])]
        })
        let vocabularySearch = Task { await vocabulary.search("synthetic") }
        let vocabularyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await vocabularyGate.started), ContinuousClock.now < vocabularyDeadline { await Task.yield() }
        let vocabularyStarted = await vocabularyGate.started
        try require(vocabularyStarted, "vocabulary-query-started")
        PrivateProfileStorage.conceal(generation: UUID())
        let vocabularyJoin = Task { await vocabulary.stopAndJoinForProfileTransition() }
        await vocabularyGate.release()
        await vocabularyJoin.value
        let vocabularyResult = await vocabularySearch.value
        try require(vocabularyResult.isEmpty, "late-vocabulary-does-not-publish-or-cache")
        PrivateProfileStorage.select(original)
        await service.stopAndJoinForProfileTransition()
        print("AppSearch profile boundary: \(checks) synthetic direct-query/vocabulary/late-result/join checks passed; index and store inputs are inert")
    }
}
