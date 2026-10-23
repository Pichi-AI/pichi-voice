import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Synthetic isolated scope/lifecycle services. Actual production UI owner, drop
// bridge, native FileDocument and exporter binding are extracted by the runner.
nonisolated struct PrivateProfileSnapshot: Sendable {
    let id: String
    let generation: UUID
    let isReadable: Bool
}
nonisolated enum PrivateProfileStorage {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var profile = PrivateProfileSnapshot(id: "synthetic-A", generation: UUID(), isReadable: true)
        var admitted = true
    }
    private static let state = State()
    static var current: PrivateProfileSnapshot { state.lock.withLock { state.profile } }
    static var acceptsNewWork: Bool { state.lock.withLock { state.admitted && state.profile.isReadable } }
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool {
        let selected = current
        return selected.isReadable && profile.id == selected.id && profile.generation == selected.generation
    }
    static func select(_ value: PrivateProfileSnapshot, admitted: Bool = true) {
        state.lock.withLock { state.profile = value; state.admitted = admitted }
    }
}
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
@MainActor final class ASRService: ObservableObject {}
@MainActor final class FileTranscriptionService: ObservableObject {}
nonisolated enum AppSearchHit { enum Target: Hashable { case synthetic } }
@MainActor final class PrivateProfileService: ObservableObject {
    static let shared = PrivateProfileService()
    @Published var sourceRevision = UUID()
    @Published var projectionRevision = UUID()
    var isPrivateDataVisible = true
    var isTransitioning = false
    weak var participant: (any PrivateProfileTransitionParticipant)?
    func register(_ participant: any PrivateProfileTransitionParticipant) { self.participant = participant }
}
nonisolated struct FileTranscriptionEntry {
    let id = UUID()
    var displayTitle = "Synthetic ёж"
    func toTranscriptionResult() -> SyntheticResult { SyntheticResult() }
}
nonisolated struct SyntheticResult {
    var textExportData: Data { Data("Synthetic ёж\n42".utf8) }
    func jsonExportData() throws -> Data { Data(#"{"text":"Synthetic ёж"}"#.utf8) }
}
@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    func info(_: String, source _: String) {}
    func error(_: String, source _: String) {}
}

actor SyntheticGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if self.open { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
    func release() { self.open = true; self.waiters.forEach { $0.resume() }; self.waiters = [] }
}

nonisolated final class DelayedDrop: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Data?, Error?) -> Void)?
    var started: Bool { self.lock.withLock { self.callback != nil } }
    func install(_ callback: @escaping @Sendable (Data?, Error?) -> Void) {
        self.lock.withLock { self.callback = callback }
    }
    func complete() {
        let callback = self.lock.withLock { let result = self.callback; self.callback = nil; return result }
        callback?(URL(fileURLWithPath: "/synthetic-late.wav").dataRepresentation, nil)
    }
}

@main struct N4FilePrivateProjectionTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            assertions += 1
        }
        let service = PrivateProfileService.shared
        var revealClears = 0
        var pendingReveal: String? = "synthetic-A-target"
        let owner = FileTranscriptionPrivateProjection(clearReveal: { revealClears += 1; pendingReveal = nil })
        check(service.participant === owner, "The real owner registers for joined transitions")
        check(owner.isCurrent, "Initial synthetic profile is usable")
        owner.selectedFileURL = URL(fileURLWithPath: "/synthetic.wav")
        owner.showingFilePicker = true
        owner.showingExportDialog = true
        owner.exportDocument = try TranscriptionDocument(entry: .init(), format: .text)
        owner.showingCopyConfirmation = true
        owner.isDropTargeted = true
        owner.dropErrorMessage = "Synthetic error"
        owner.searchQuery = "Synthetic query"
        owner.pendingDeleteEntry = .init()
        owner.showingClearConfirmation = true
        owner.rowMetadata = [UUID(): .init(preview: "Synthetic private text", fullDate: "Synthetic date")]
        owner.filteredEntries = [.init()]
        owner.pendingRevealID = UUID()
        let document = owner.exportDocument!
        let initialBytes = try document.fileWrapper().regularFileContents
        check(initialBytes == SyntheticResult().textExportData, "Authorized native wrapper preserves bytes")
        var uiStarted = false
        var uiCancelled = false
        var latePublication = false
        owner.performUIWork {
            uiStarted = true
            do { try await Task.sleep(for: .seconds(30)) } catch { uiCancelled = true }
            if !Task.isCancelled, owner.isCurrent { latePublication = true }
        }
        let gate = SyntheticGate()
        var transcriptionStarted = false
        var transcriptionWasCancelled = false
        owner.performTranscription {
            transcriptionStarted = true
            await gate.wait()
            transcriptionWasCancelled = Task.isCancelled
            if owner.isCurrent { latePublication = true }
        }
        while !uiStarted || !transcriptionStarted { await Task.yield() }
        let old = PrivateProfileStorage.current
        service.isPrivateDataVisible = false
        service.projectionRevision = UUID()
        PrivateProfileStorage.select(.init(id: old.id, generation: old.generation, isReadable: false), admitted: false)
        check(!owner.isCurrent, "Conceal rejects even before observation cleanup runs")
        do { _ = try document.fileWrapper(); preconditionFailure("Concealed export must fail") }
        catch { check((error as? CocoaError)?.code == .userCancelled, "Retained export document refuses bytes") }
        var transitionFinished = false
        let transition = Task { @MainActor in
            try await service.participant?.prepareForPrivateProfileTransition()
            transitionFinished = true
        }
        while !uiCancelled { await Task.yield() }
        check(!transitionFinished, "Cleanup waits for the existing transcription owner")
        check(owner.filteredEntries.isEmpty && owner.rowMetadata.isEmpty, "Rows and metadata cleared before join")
        check(owner.exportDocument == nil && !owner.showingExportDialog, "Export payload cleared before join")
        await gate.release()
        try await transition.value
        check(transitionFinished && !transcriptionWasCancelled, "Shared transcription is joined without cancellation")
        check(!latePublication, "Cancelled and shared completions cannot publish stale payloads")
        check(owner.selectedFileURL == nil && !owner.showingFilePicker, "File URL and picker cleared")
        check(!owner.showingCopyConfirmation && !owner.isDropTargeted && owner.dropErrorMessage == nil, "Transient feedback cleared")
        check(owner.searchQuery.isEmpty && owner.pendingDeleteEntry == nil && !owner.showingClearConfirmation, "Search and destructive payloads cleared")
        check(owner.pendingRevealID == nil && revealClears == 1 && pendingReveal == nil, "Held A reveal clears exactly once")
        owner.performUIWork { latePublication = true }
        owner.performTranscription { latePublication = true }
        await Task.yield()
        check(!latePublication, "Retired owner refuses new operations")
        service.isPrivateDataVisible = true
        PrivateProfileStorage.select(.init(id: old.id, generation: UUID(), isReadable: true))
        service.sourceRevision = UUID()
        pendingReveal = "synthetic-B-target"
        owner.conceal()
        try await owner.prepareForPrivateProfileTransition()
        check(pendingReveal == "synthetic-B-target" && revealClears == 1, "Repeated A cleanup cannot clear B's reveal")
        check(!owner.isCurrent, "An old owner never rebinds to a new activation")
        do { _ = try document.fileWrapper(); preconditionFailure("A new generation cannot export old bytes") }
        catch { check(true, "Export is bound to immutable generation") }
        let fresh = FileTranscriptionPrivateProjection(clearReveal: {})
        check(fresh.isCurrent, "Composition can create a fresh owner after activation")
        let deferred = FileTranscriptionPrivateProjection(clearReveal: { pendingReveal = nil })
        service.sourceRevision = UUID()
        deferred.conceal()
        check(pendingReveal == "synthetic-B-target", "First cleanup from a retired source cannot clear the current reveal")
        service.projectionRevision = UUID()
        check(!fresh.isCurrent, "A projection revision alone also rejects stale completion")
        let active = PrivateProfileStorage.current
        PrivateProfileStorage.select(active, admitted: false)
        let closed = FileTranscriptionPrivateProjection(clearReveal: {})
        check(!closed.isCurrent, "Closed admission rejects new UI work")
        PrivateProfileStorage.select(active)

        let delayed = DelayedDrop()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            delayed.install(completion)
            return Progress(totalUnitCount: 1)
        }
        // Exercise the actual callback bridge with a real native provider and synthetic URL.
        let request = FileTranscriptionDropRequest()
        let drop = Task { @MainActor in await request.load(provider) }
        while !delayed.started { await Task.yield() }
        drop.cancel()
        let cancelledDrop = await drop.value
        check(cancelledDrop == nil, "Cancellation promptly joins the UI waiter")
        delayed.complete()
        await Task.yield()
        check(!latePublication, "Late native drop callback has no private view projection")
        let directProvider = NSItemProvider()
        directProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            completion(URL(fileURLWithPath: "/synthetic-current.wav").dataRepresentation, nil)
            return nil
        }
        let success = await FileTranscriptionDropRequest().load(directProvider)
        check(success?.lastPathComponent == "synthetic-current.wav", "Native URL data representation succeeds")
        let neverStarted = DelayedDrop()
        let cancelledProvider = NSItemProvider()
        cancelledProvider.registerDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, visibility: .all) { completion in
            neverStarted.install(completion)
            return nil
        }
        let cancelledBeforeStart = Task { @MainActor in await FileTranscriptionDropRequest().load(cancelledProvider) }
        cancelledBeforeStart.cancel()
        let beforeStartResult = await cancelledBeforeStart.value
        check(beforeStartResult == nil && !neverStarted.started, "Cancellation before start never admits provider loading")
        print("PASS: \(assertions) synthetic file-private-projection assertions; native FileDocument/exporter/drop bridge compiled. No app, models, devices, user data or service inference.")
    }
}
