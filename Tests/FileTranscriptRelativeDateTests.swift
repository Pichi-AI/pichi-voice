import AppKit
import Foundation
import SwiftUI

/// Instrumentation observes the production formatter and the existing in-memory defaults double.
nonisolated final class RelativeDateTimeProbe: @unchecked Sendable {
    struct Event {
        let locale: String
        let reference: Date
        let value: String
    }
    static let shared = RelativeDateTimeProbe()
    private let lock = NSLock()
    private var events: [Event] = []
    private var writes = 0
    func record(locale: Locale, reference: Date, value: String) {
        self.lock.withLock { self.events.append(Event(locale: locale.identifier, reference: reference, value: value)) }
    }
    func recordWrite() { self.lock.withLock { self.writes += 1 } }
    func resetEvents() { self.lock.withLock { self.events = [] } }
    func snapshot() -> (events: [Event], writes: Int) { self.lock.withLock { (self.events, self.writes) } }
}

@MainActor private final class FixtureState: ObservableObject {
    @Published var isPresent = true
    @Published var isPageVisible = true
    @Published var scrollTarget = "caption"
}

private struct Fixture: View {
    @ObservedObject var state: FixtureState
    let entry: FileTranscriptionEntry
    let locale: Locale
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if self.state.isPresent {
                        FileTranscriptRelativeDateLabel(entry: self.entry, locale: self.locale, refreshInterval: 0.05)
                            .font(.system(size: 13))
                            .foregroundStyle(.black)
                            .frame(height: 40)
                            .id("caption")
                    }
                    Color.clear.frame(height: 800)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .environment(\.fluidPageToolbarVisible, self.state.isPageVisible)
            .onChange(of: self.state.scrollTarget) { _, target in
                proxy.scrollTo(target, anchor: target == "caption" ? .top : .bottom)
            }
        }
        .frame(width: 360, height: 80)
        .background(.white)
    }
}

@main @MainActor struct FileTranscriptRelativeDateTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        precondition(condition(), message)
    }

    static func pump(_ interval: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    static func awaitCondition(timeout: TimeInterval = 3, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline { self.pump(0.01) }
        if !predicate() {
            let events = RelativeDateTimeProbe.shared.snapshot().events
            print("Fixture timeout: \(events.count) formatter calls, latest labels \(events.suffix(3).map(\.value))")
            fflush(stdout)
        }
        self.check(predicate(), "Native fixture did not reach its expected state")
    }

    static func capture(_ host: NSView, name: String, directory: URL) throws {
        host.layoutSubtreeIfNeeded()
        guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            preconditionFailure("Offscreen fixture must support native snapshots")
        }
        host.cacheDisplay(in: host.bounds, to: image)
        try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
    }

    static func verifyClockAndLifetime(locale: Locale, directory: URL) throws {
        let defaults = InMemoryFileHistoryDefaults()
        let store = FileTranscriptionHistoryStore(defaults: defaults)
        store.addEntry(TranscriptionResult(
            id: UUID(), text: "FluidVoice ё Synthetic transcript", confidence: 1, duration: 1,
            processingTime: 1, fileName: "synthetic.wav", timestamp: Date().addingTimeInterval(-118),
            speakerSegments: [], speakerLabelingNotice: nil, speakerLabelingGaps: []
        ))
        let id = store.entries[0].id
        store.renameEntry(id: id, to: "Обзор Ёжика")
        let entry = store.entries[0]
        let entries = store.entries
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(entries)
        let writes = RelativeDateTimeProbe.shared.snapshot().writes
        RelativeDateTimeProbe.shared.resetEvents()

        let state = FixtureState()
        let host = NSHostingView(rootView: Fixture(state: state, entry: entry, locale: locale))
        host.frame = NSRect(x: 0, y: 0, width: 360, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let desktop = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        window.setFrameOrigin(NSPoint(x: desktop.minX - 1360, y: desktop.minY - 1080))
        window.orderFront(nil) // Never key, activated or within any physical display.
        defer { window.contentView = nil; window.orderOut(nil); window.close() }
        self.check(!NSApplication.shared.isActive, "The native fixture must not activate its app")
        self.awaitCondition { RelativeDateTimeProbe.shared.snapshot().events.count >= 3 }
        try self.capture(host, name: "relative-\(locale.identifier)-01-visible", directory: directory)
        self.awaitCondition {
            Set(RelativeDateTimeProbe.shared.snapshot().events.map(\.value)).count >= 2
        }
        try self.capture(host, name: "relative-\(locale.identifier)-02-aged", directory: directory)
        let aged = RelativeDateTimeProbe.shared.snapshot().events
        self.check(aged.allSatisfy { $0.locale == locale.identifier }, "Timeline refresh must retain the interface locale")
        self.check(aged.last!.reference > aged.first!.reference, "The visible label must advance its reference date")

        state.scrollTarget = "end"
        self.pump(0.25)
        try self.capture(host, name: "relative-\(locale.identifier)-03-outside-viewport", directory: directory)
        let offscreenCount = RelativeDateTimeProbe.shared.snapshot().events.count
        self.pump(0.25)
        self.check(RelativeDateTimeProbe.shared.snapshot().events.count == offscreenCount, "A retained offscreen row must not keep refreshing")

        state.scrollTarget = "caption"
        self.awaitCondition { RelativeDateTimeProbe.shared.snapshot().events.count > offscreenCount + 1 }
        try self.capture(host, name: "relative-\(locale.identifier)-04-visible-again", directory: directory)
        let returned = RelativeDateTimeProbe.shared.snapshot().events.last!.reference
        state.isPageVisible = false
        self.pump(0.15)
        try self.capture(host, name: "relative-\(locale.identifier)-05-page-hidden", directory: directory)
        let hiddenCount = RelativeDateTimeProbe.shared.snapshot().events.count
        self.pump(0.25)
        self.check(RelativeDateTimeProbe.shared.snapshot().events.count == hiddenCount, "Mounted content behind Settings must not keep refreshing")
        state.isPageVisible = true
        self.awaitCondition { RelativeDateTimeProbe.shared.snapshot().events.count > hiddenCount + 1 }
        self.check(RelativeDateTimeProbe.shared.snapshot().events.last!.reference > returned, "Showing the page must immediately use current time")
        try self.capture(host, name: "relative-\(locale.identifier)-06-page-visible", directory: directory)

        state.isPresent = false
        self.pump(0.15)
        try self.capture(host, name: "relative-\(locale.identifier)-07-disappeared", directory: directory)
        let removedCount = RelativeDateTimeProbe.shared.snapshot().events.count
        self.pump(0.25)
        self.check(RelativeDateTimeProbe.shared.snapshot().events.count == removedCount, "Disappearance must retire the label timeline")
        self.check(store.entries == entries && store.selectedEntryID == id, "Clock refresh must not mutate history or selection")
        let after = try encoder.encode(store.entries)
        self.check(after == encoded, "Transcript, title, timestamp and revisions must stay byte-for-byte unchanged")
        self.check(RelativeDateTimeProbe.shared.snapshot().writes == writes, "Time passing must never write history")
        self.check(!NSApplication.shared.isActive, "Fixture must leave the parent app focus alone")
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let timestamp = Date(timeIntervalSince1970: 1_790_000_000)
        let entry = FileTranscriptionEntry(timestamp: timestamp, fileName: "synthetic.wav", duration: 1,
                                           processingTime: 1, confidence: 1, text: "FluidVoice ё Synthetic")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(entry)
        for (identifier, first, later) in [
            ("en_US", "1 minute ago", "15 minutes ago"),
            ("ru_RU", "1 минуту назад", "15 минут назад"),
        ] {
            let locale = Locale(identifier: identifier)
            self.check(entry.relativeTimeString(locale: locale, relativeTo: timestamp.addingTimeInterval(60)) == first,
                       "The first relative minute must use the requested locale")
            self.check(entry.relativeTimeString(locale: locale, relativeTo: timestamp.addingTimeInterval(900)) == later,
                       "Time advances without a history update")
            let after = try encoder.encode(entry)
            self.check(after == encoded, "Formatting must leave the archived entry unchanged")
            try self.verifyClockAndLifetime(locale: locale, directory: directory)
        }
        print("File transcript relative date: \(self.checks) checks passed; actual visible Timeline ticks, scroll/page/disappearance retirement, locale and write-free history")
    }
}
