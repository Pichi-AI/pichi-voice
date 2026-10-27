import AppKit
import Combine
import Foundation

// Synthetic profile/store/reporter contracts only. The extracted production owner
// is exercised without production storage, account operations, audio or network.
struct PrivateProfileSnapshot: Equatable, Sendable {
    let id: String
    let generation: UUID
}
@MainActor enum PrivateProfileStorage {
    static var current = PrivateProfileSnapshot(id: "synthetic-guest", generation: UUID())
    static var visible = true
    static var acceptsNewWork = true
    static func isReadable(_ snapshot: PrivateProfileSnapshot) -> Bool { visible && current == snapshot }
}
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    static let willConceal = Notification.Name("synthetic.historyPrivateProfileWillConceal")
    var isPrivateDataVisible = true
    var isTransitioning = false
    var projectionRevision = UUID()
    private struct WeakParticipant { weak var value: (any PrivateProfileTransitionParticipant)? }
    private var participants: [WeakParticipant] = []
    func register(_ participant: any PrivateProfileTransitionParticipant) {
        participants.append(.init(value: participant))
    }
    func conceal() {
        isPrivateDataVisible = false
        projectionRevision = UUID()
        PrivateProfileStorage.visible = false
        PrivateProfileStorage.acceptsNewWork = false
        NotificationCenter.default.post(name: Self.willConceal, object: nil)
    }
    func prepareRegistered() async throws {
        for participant in participants.compactMap(\.value) {
            try await participant.prepareForPrivateProfileTransition()
        }
    }
    func select(_ name: String) {
        PrivateProfileStorage.current = .init(id: name, generation: UUID())
        PrivateProfileStorage.visible = true
        PrivateProfileStorage.acceptsNewWork = true
        isPrivateDataVisible = true
        isTransitioning = false
        projectionRevision = UUID()
    }
}
struct HistoryPinRevealRequest { let entryID: UUID }
struct TranscriptionHistoryEntry: Identifiable, Sendable {
    let id: UUID
    let rawText: String
    let processedText: String
    let processingModel: String?
    let audio: Audio?
    struct Audio: Sendable { let fileName: String }
}
@MainActor final class TranscriptionHistoryStore {
    static let shared = TranscriptionHistoryStore()
    var entries: [TranscriptionHistoryEntry] = []
    var selectedEntryID: UUID?
}
nonisolated final class DictationAudioHistoryStore: @unchecked Sendable {
    static func scoped(to _: PrivateProfileSnapshot) -> DictationAudioHistoryStore { .init() }
    func audioFileExists(fileName: String) -> Bool { fileName == "synthetic.wav" }
    func suggestedPairExportFilename(for _: TranscriptionHistoryEntry) -> String { "synthetic.zip" }
    func exportPair(entry _: TranscriptionHistoryEntry, to _: URL) throws {
        preconditionFailure("Compile-only save-panel fixture must never export")
    }
}
enum DictationAudioHistoryError: Error { case audioMissing }
@MainActor final class HistoryProjectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.started = true
        }
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor enum TranscriptionFeedbackReporter {
    struct Payload {
        let rawText: String
        let processedText: String
        let processingModel: String
        let comments: String
    }
    static var gate: HistoryProjectionGate?
    static var submitted: [Payload] = []
    static var completed = 0
    static var shouldFail = false
    enum SyntheticFailure: Error { case rejected }
    static func submit(_ payload: Payload) async throws {
        defer { completed += 1 }
        submitted.append(payload)
        if let gate { await gate.wait() }
        if shouldFail { throw SyntheticFailure.rejected }
    }
}

@main struct HistoryPrivateProjectionTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        precondition(value(), message)
    }
    @MainActor static func until(_ condition: () -> Bool) async {
        for _ in 0..<10000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("Synthetic test did not reach its bounded checkpoint")
    }
    @MainActor static func main() async throws {
        let profiles = PrivateProfileService.shared
        let history = TranscriptionHistoryStore.shared
        let entry = TranscriptionHistoryEntry(id: UUID(), rawText: "synthetic raw", processedText: "synthetic output",
            processingModel: "synthetic model", audio: .init(fileName: "synthetic.wav"))
        history.entries = [entry]
        history.selectedEntryID = entry.id
        let owner = HistoryPrivateProjection()
        expect(owner.isVisible, "Unchanged guest projection stays visible")
        let ticket = owner.capture()!
        expect(owner.isCurrent(ticket), "Fresh exact profile/revision ticket accepted")
        PrivateProfileStorage.acceptsNewWork = false
        expect(owner.capture() == nil && !owner.isCurrent(ticket), "Closed operation admission rejects new and late private work")
        PrivateProfileStorage.acceptsNewWork = true
        profiles.projectionRevision = UUID()
        expect(!owner.isCurrent(ticket), "Projection-only revision invalidates held completion")
        let generationTicket = owner.capture()!
        PrivateProfileStorage.current = .init(id: "synthetic-guest", generation: UUID())
        expect(!owner.isCurrent(generationTicket), "Same profile ID with a new generation is rejected")
        expect(!owner.isVisible, "Old source never rebinds to a new generation")
        profiles.select("synthetic-account-a")
        let active = HistoryPrivateProjection()
        active.scanAudio(fileNames: ["missing.wav", "synthetic.wav"])
        await until { active.availableAudioFiles == ["synthetic.wav"] }
        expect(active.availableAudioFiles == ["synthetic.wav"], "Real scan publishes only available synthetic filenames")
        active.openReport(entry)
        active.comment = "synthetic private draft"
        active.searchQuery = "synthetic search"
        active.pinnedOnly = true
        active.pinRevealRequest = .init(entryID: entry.id)
        active.showClearConfirmation = true
        active.showReportConfirmation = true
        active.audioEntryID = entry.id
        active.exportError = "synthetic private export error"
        active.showCopyFeedback(entryID: entry.id)
        let gate = HistoryProjectionGate()
        var latePublication = false
        active.start { token in
            await gate.wait() // Deliberately ignores cancellation to test joined cleanup.
            if active.isCurrent(token) { latePublication = true }
        }
        await until { gate.started }
        profiles.conceal()
        expect(!active.isVisible, "Conceal hides private content before asynchronous cleanup")
        expect(active.comment.isEmpty && active.selectedReportEntry == nil && active.exportError == nil,
            "Synchronous conceal notification clears payloads even before the async participant is called")
        var finished = false
        var cleanupStarted = false
        let transition = Task { @MainActor in
            cleanupStarted = true
            try await profiles.prepareRegistered()
            finished = true
        }
        await until { cleanupStarted }
        expect(!finished, "Registered transition waits for cancellation-ignoring owned work")
        expect(active.selectedReportEntry == nil && active.inputText.isEmpty && active.outputText.isEmpty && active.comment.isEmpty,
            "Retained report payload and every draft are removed before join")
        expect(active.processingModel.isEmpty && active.errorMessage == nil && !active.isSending, "Report state is cleared")
        expect(active.availableAudioFiles.isEmpty && active.audioEntryID == nil, "Audio selection/availability cleared")
        expect(active.copiedEntryID == nil && active.exportError == nil, "Copy and export feedback cleared")
        expect(history.selectedEntryID == nil, "Selection is cleared through the captured old history store")
        expect(active.searchQuery.isEmpty && !active.pinnedOnly && active.pinRevealRequest == nil, "Search/filter/reveal payloads cleared")
        expect(!active.showClearConfirmation && !active.showReportConfirmation, "Delete/report confirmations cleared")
        gate.release()
        try await transition.value
        expect(finished && !latePublication, "Cleanup joins work and rejects its late private completion")
        expect(active.start { _ in preconditionFailure("Retired owner started work") } == nil, "Retired owner refuses new tasks")
        profiles.select("synthetic-account-b")
        expect(!active.isVisible, "Retired old view remains hidden after another profile activates")
        let fresh = HistoryPrivateProjection()
        expect(fresh.isVisible, "Composition can supply a fresh visible owner for new source")
        let reportGate = HistoryProjectionGate()
        TranscriptionFeedbackReporter.gate = reportGate
        fresh.openReport(entry)
        fresh.sendReport()
        await until { reportGate.started }
        expect(fresh.isSending && TranscriptionFeedbackReporter.submitted.count == 1, "One explicit synthetic report starts")
        profiles.conceal()
        let reportTransition = Task { try await profiles.prepareRegistered() }
        await until { fresh.selectedReportEntry == nil }
        reportGate.release()
        try await reportTransition.value
        expect(!fresh.showReportConfirmation && fresh.errorMessage == nil, "Stale successful report cannot publish confirmation or error")
        profiles.select("synthetic-account-c")
        let reopened = HistoryPrivateProjection()
        let oldReportGate = HistoryProjectionGate()
        TranscriptionFeedbackReporter.gate = oldReportGate
        TranscriptionFeedbackReporter.shouldFail = true
        reopened.openReport(entry)
        reopened.sendReport()
        await until { oldReportGate.started }
        reopened.closeReport()
        reopened.openReport(entry)
        reopened.comment = "new draft"
        let completedBeforeRelease = TranscriptionFeedbackReporter.completed
        oldReportGate.release()
        await until { TranscriptionFeedbackReporter.completed > completedBeforeRelease }
        expect(reopened.errorMessage == nil && reopened.comment == "new draft", "Old report failure cannot overwrite reopened sheet")
        expect(reopened.selectedReportEntry?.id == entry.id && !reopened.isSending, "Reopened sheet keeps its own state")
        profiles.conceal()
        try await profiles.prepareRegistered()
        print("History private projection: \(checks) synthetic assertions passed; no production profile, audio, network or native UI exercised.")
    }
}
