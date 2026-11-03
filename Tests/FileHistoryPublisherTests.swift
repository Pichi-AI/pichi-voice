import AppKit
import Combine
import Foundation
import SwiftUI

@MainActor private final class Projection: ObservableObject {
    @Published var entries: [FileTranscriptionEntry] = []
    @Published var unrelatedRevision = 0
    var callbackCount = 0
    var exceededReplayLimit = false

    func receive(_ entries: [FileTranscriptionEntry]) {
        self.callbackCount += 1
        // The broken implementation must fail without exhausting memory or trapping
        // the main run loop forever. Real projection assignments are unconditional.
        guard self.callbackCount <= 64 else { self.exceededReplayLimit = true; return }
        self.entries = entries
    }
}

private struct Fixture: View {
    @ObservedObject var store: FileTranscriptionHistoryStore
    @ObservedObject var projection: Projection

    var body: some View {
        Text("\(self.projection.entries.count) / \(self.projection.unrelatedRevision)")
            .frame(width: 240, height: 60)
            .onReceive(self.store.entriesPublisher) { self.projection.receive($0) }
    }
}

@main @MainActor struct FileHistoryPublisherTests {
    static var checks = 0
    static var failed = false

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        if !condition() { print("FAIL: \(message)"); self.failed = true }
    }

    static func pump(_ duration: TimeInterval = 0.15) {
        RunLoop.main.run(until: Date().addingTimeInterval(duration))
    }

    private static func settled(_ projection: Projection, phase: String) {
        self.pump()
        let count = projection.callbackCount
        self.pump()
        self.check(!projection.exceededReplayLimit, "\(phase): repeated initial-value replay (\(count) callbacks)")
        self.check(projection.callbackCount == count, "\(phase): idle projection must stop receiving snapshots")
    }

    static func result() -> TranscriptionResult {
        .init(id: UUID(), text: "Synthetic transcript Ёжик", confidence: 1, duration: 1,
              processingTime: 1, fileName: "synthetic.wav", timestamp: Date(),
              speakerSegments: [], speakerLabelingNotice: nil, speakerLabelingGaps: [])
    }

    static func verifyNativeConsumer(prepopulated: Bool) async throws {
        let store = FileTranscriptionHistoryStore(defaults: InMemoryFileHistoryDefaults())
        if prepopulated { store.addEntry(self.result()) }
        let projection = Projection()
        let host = NSHostingView(rootView: Fixture(store: store, projection: projection))
        host.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let desktop = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        window.setFrameOrigin(NSPoint(x: desktop.minX - 1240, y: desktop.minY - 1060))
        window.orderFront(nil)
        defer { window.contentView = nil; window.orderOut(nil); window.close() }

        self.settled(projection, phase: "initial prepopulated=\(prepopulated)")
        self.check(projection.callbackCount == 1, "Mounting must deliver exactly one initial snapshot")
        self.check(projection.entries == store.entries, "Mounting must project saved entries")
        // Stop the negative control here, after the native window is cleaned up.
        guard !projection.exceededReplayLimit else { return }

        let initialCallbacks = projection.callbackCount
        for _ in 0..<5 { projection.unrelatedRevision += 1; self.pump(0.03) }
        self.settled(projection, phase: "unrelated invalidations")
        self.check(projection.callbackCount == initialCallbacks, "View invalidation must not resubscribe and replay history")

        let added = self.result()
        store.addEntry(added)
        self.settled(projection, phase: "add")
        self.check(projection.callbackCount > initialCallbacks && projection.entries == store.entries,
                   "A real addition must still reach the mounted consumer")
        let beforeRename = projection.callbackCount
        store.renameEntry(id: added.id, to: "Обзор Ёжика")
        self.settled(projection, phase: "rename")
        self.check(projection.callbackCount > beforeRename && projection.entries.first?.displayTitle == "Обзор Ёжика",
                   "A real rename must still reach the mounted consumer")
        store.deleteEntry(id: added.id)
        self.settled(projection, phase: "delete")
        self.check(!projection.entries.contains(where: { $0.id == added.id }), "Delete must remove the projected entry")
        store.addEntry(self.result())
        self.pump()
        store.concealPrivateProjections()
        self.settled(projection, phase: "conceal")
        self.check(projection.entries.isEmpty, "Concealment must clear a mounted projection")
        try await store.prepareForProfileTransition()
        self.settled(projection, phase: "retire")
        let retiredCallbacks = projection.callbackCount
        store.addEntry(self.result())
        self.pump()
        self.check(projection.entries.isEmpty && projection.callbackCount == retiredCallbacks,
                   "Retired store must not publish newly admitted private data")
        self.check(!NSApplication.shared.isActive, "Fixture must never activate or take keyboard focus")
    }

    static func verifyLifetimeAndAccess() async throws {
        var store: FileTranscriptionHistoryStore? = FileTranscriptionHistoryStore(defaults: InMemoryFileHistoryDefaults())
        weak let weakStore = store
        let publisher = store!.entriesPublisher
        var entries: [FileTranscriptionEntry] = []
        let subscription = publisher.sink { entries = $0 }
        store!.addEntry(self.result())
        self.check(entries.count == 1, "Stable publisher must deliver real snapshots to non-UI subscribers")
        try await store!.prepareForProfileTransition()
        self.check(entries.isEmpty, "Retirement must clear an existing subscription")
        var retired: [FileTranscriptionEntry]?
        let retiredSubscription = publisher.sink { retired = $0 }
        self.check(retired?.isEmpty == true, "Late subscription to a retired store must fail closed")
        retiredSubscription.cancel()
        store = nil
        self.check(weakStore == nil, "Publisher and subscriber must not retain their private history store")
        var replayed: [FileTranscriptionEntry]?
        let lateSubscription = publisher.sink { replayed = $0 }
        self.check(replayed?.isEmpty == true, "A retained publisher must fail closed after its owner is released")
        subscription.cancel(); lateSubscription.cancel()

        let original = PrivateProfileStorage.current
        let scoped = FileTranscriptionHistoryStore(defaults: InMemoryFileHistoryDefaults(), profile: original)
        scoped.addEntry(self.result())
        let scopedPublisher = scoped.entriesPublisher
        PrivateProfileStorage.conceal(generation: UUID())
        defer { PrivateProfileStorage.select(original) }
        var concealed: [FileTranscriptionEntry]?
        let concealedSubscription = scopedPublisher.sink { concealed = $0 }
        self.check(concealed?.isEmpty == true, "Stable identity must keep the per-emission private-access check")
        concealedSubscription.cancel()
    }

    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        try await self.verifyNativeConsumer(prepopulated: false)
        if !self.failed { try await self.verifyNativeConsumer(prepopulated: true) }
        if !self.failed { try await self.verifyLifetimeAndAccess() }
        print("File history publisher: \(self.checks) checks; \(self.failed ? "FAIL" : "PASS")")
        if self.failed { exit(1) }
    }
}
