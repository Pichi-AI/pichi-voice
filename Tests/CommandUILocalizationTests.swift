import AppKit
import Combine
import Foundation
import SwiftUI

// These doubles never read/write the installed app's preferences or clipboard.
nonisolated final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func string(forKey key: String) -> String? { self.values[key] as? String }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value }
}

@MainActor final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    @Published var showThinkingTokens = false
    var accentColor: Color { .blue }
}

@MainActor final class ChatHistoryStore: ObservableObject {
    static let shared = ChatHistoryStore()
    @Published var sessions: [ChatSession] = []
    @Published var currentChatID: String?
    func renameChat(id: String, to title: String) {
        preconditionFailure("This localization fixture never renames user data")
    }
}

@MainActor enum ClipboardService {
    static var copiedPayload: String?
    static func copyToClipboard(_ text: String) -> Bool {
        self.copiedPayload = text
        return true
    }
}

@MainActor enum CommandCopyLabelProbe {
    struct Event {
        let value: String
        let key: String
        let copied: Bool
        let locale: String
    }
    static var events: [Event] = []
    static func record(_ value: String, key: String, copied: Bool, locale: Locale) -> String {
        self.events.append(Event(value: value, key: key, copied: copied, locale: locale.identifier))
        return value
    }
}

/// Stands in for the sleep of the copy button's feedback timer. It records the
/// requested duration and returns only after the probe sets `released`.
@MainActor enum CommandCopyFeedbackClock {
    static var requested: [Duration] = []
    static var released = false
    static func sleep(for duration: Duration) async throws {
        self.requested.append(duration)
        while !self.released { try await Task.sleep(for: .milliseconds(10)) }
    }
}

@MainActor private final class FixtureState: ObservableObject {
    @Published var locale = Locale(identifier: "en_US")
}

private struct CopyFixture: View {
    @ObservedObject var state: FixtureState
    let scheme: ColorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            CommandMessageView(message: .init(role: .user, content: "Copy response Ёжик"))
            CommandMessageView(message: .init(role: .assistant, content: "Synthetic response Ёжик"))
            CommandCodeBlock(code: "printf 'Copy message Ёжик'", language: "Shell")
        }
        .padding(20)
        .background(self.scheme == .light ? AppTheme.light.palette.contentBackground : AppTheme.dark.palette.contentBackground)
        .environment(\.locale, self.state.locale)
        .environment(\.theme, self.scheme == .light ? AppTheme.light : AppTheme.dark)
        .preferredColorScheme(self.scheme)
        .frame(width: 640, height: 300)
    }
}

private struct SingleCopyFixture: View {
    @ObservedObject var state: FixtureState
    let scheme: ColorScheme
    var body: some View {
        CommandCopyButton(text: "Copy response Ёжик", label: "Copy message")
            .environment(\.locale, self.state.locale)
            .environment(\.theme, self.scheme == .light ? AppTheme.light : AppTheme.dark)
            .frame(width: 120, height: 80)
            .background(self.scheme == .light ? AppTheme.light.palette.contentBackground : AppTheme.dark.palette.contentBackground)
            .preferredColorScheme(self.scheme)
    }
}

private final class FixtureHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@main @MainActor struct CommandUILocalizationTests {
    static var checks = 0
    static var directory: URL!
    static var revision = ""

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        precondition(condition(), message)
    }

    static func pump(_ interval: TimeInterval = 0.1) {
        RunLoop.main.run(until: Date().addingTimeInterval(interval))
    }

    static func awaitCondition(_ message: String, _ predicate: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { self.pump(0.02) }
        self.check(predicate(), message)
    }

    static func host(_ content: some View, width: CGFloat, height: CGFloat, scheme: ColorScheme) -> (NSWindow, NSView) {
        let host = FixtureHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
        window.contentView = host
        let desktop = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
        window.setFrameOrigin(NSPoint(x: desktop.minX - width - 500, y: desktop.minY - height - 500))
        window.orderFront(nil) // Prohibited activation, never key, outside every physical display.
        self.pump()
        self.check(!NSApplication.shared.isActive, "Headless fixture must preserve the user's app focus")
        return (window, host)
    }

    static func capture(_ view: NSView, _ step: String, verifyCopyGlyph: Bool = false) throws {
        func render() -> NSBitmapImageRep {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                  bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { preconditionFailure("Missing native bitmap") }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            return bitmap
        }
        var bitmap = render()
        if verifyCopyGlyph {
            // On macOS 27 the first frame after a click can still show the press or the symbol
            // transition. Render again for up to two seconds; the pixel requirement is unchanged.
            // The copied state stays held meanwhile, so a passing frame shows the checkmark itself.
            let start = Date()
            var counts = [self.contrastingCopyGlyphPixels(in: bitmap)]
            let deadline = start.addingTimeInterval(2)
            while counts.last! < 12, Date() < deadline {
                self.pump(0.05)
                bitmap = render()
                counts.append(self.contrastingCopyGlyphPixels(in: bitmap))
            }
            self.lastCopyGlyphCounts = counts
            print("Copy glyph \(step): contrasting pixels by render \(counts), \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        let data = bitmap.representation(using: .png, properties: [:])!
        try data.write(to: self.directory.appendingPathComponent("command-ui-\(step)-\(self.revision).png"))
        if verifyCopyGlyph {
            // Check actual native pixels, rather than asserting the palette
            // expression. This catches an invisible light-theme icon/checkmark.
            func luminance(_ color: NSColor) -> Double {
                let rgb = color.usingColorSpace(.deviceRGB)!
                func channel(_ value: CGFloat) -> Double {
                    value <= 0.04045 ? Double(value / 12.92) : pow(Double((value + 0.055) / 1.055), 2.4)
                }
                return channel(rgb.redComponent) * 0.2126 + channel(rgb.greenComponent) * 0.7152 + channel(rgb.blueComponent) * 0.0722
            }
            let background = luminance(bitmap.colorAt(x: 0, y: 0)!)
            var contrastingPixels = 0
            for y in (bitmap.pixelsHigh / 4)..<(bitmap.pixelsHigh * 3 / 4) {
                for x in (bitmap.pixelsWide / 3)..<(bitmap.pixelsWide * 2 / 3) {
                    let pixel = luminance(bitmap.colorAt(x: x, y: y)!)
                    let ratio = (max(background, pixel) + 0.05) / (min(background, pixel) + 0.05)
                    if ratio >= 3 { contrastingPixels += 1 }
                }
            }
            self.check(contrastingPixels >= 12,
                       "Native copy/checkmark glyph needs 12 pixels at 3:1 contrast; got \(contrastingPixels) "
                       + "(renders over time: \(self.lastCopyGlyphCounts)): \(step)")
        }
    }

    static var lastCopyGlyphCounts: [Int] = []

    /// The same measurement as the check below, used to wait until the glyph has settled.
    static func contrastingCopyGlyphPixels(in bitmap: NSBitmapImageRep) -> Int {
        func luminance(_ color: NSColor) -> Double {
            let rgb = color.usingColorSpace(.deviceRGB)!
            func channel(_ value: CGFloat) -> Double {
                value <= 0.04045 ? Double(value / 12.92) : pow(Double((value + 0.055) / 1.055), 2.4)
            }
            return channel(rgb.redComponent) * 0.2126 + channel(rgb.greenComponent) * 0.7152 + channel(rgb.blueComponent) * 0.0722
        }
        let background = luminance(bitmap.colorAt(x: 0, y: 0)!)
        var count = 0
        for y in (bitmap.pixelsHigh / 4)..<(bitmap.pixelsHigh * 3 / 4) {
            for x in (bitmap.pixelsWide / 3)..<(bitmap.pixelsWide * 2 / 3) {
                let pixel = luminance(bitmap.colorAt(x: x, y: y)!)
                if (max(background, pixel) + 0.05) / (min(background, pixel) + 0.05) >= 3 { count += 1 }
            }
        }
        return count
    }

    static func close(_ window: NSWindow) {
        window.contentView = nil
        window.orderOut(nil)
        window.close()
        self.pump(0.02)
    }

    static func verifyCopyButtons(scheme: ColorScheme) throws {
        let state = FixtureState()
        state.locale = Locale(identifier: "ru_RU")
        let (window, view) = self.host(CopyFixture(state: state, scheme: scheme), width: 640, height: 300, scheme: scheme)
        defer { self.close(window) }
        for (locale, labels) in [
            ("en_US", ["Copy message", "Copy response", "Copy code"]),
            ("ru_RU", ["Скопировать сообщение", "Скопировать ответ", "Скопировать код"]),
        ] {
            CommandCopyLabelProbe.events = []
            state.locale = Locale(identifier: locale)
            self.awaitCondition("Actual rendered copy buttons must use \(locale) catalog labels") {
                let events = CommandCopyLabelProbe.events.filter { $0.locale == locale }
                return labels.allSatisfy { label in events.contains { $0.value == label && !$0.copied } }
            }
            self.check(CommandCopyLabelProbe.events.allSatisfy { $0.locale == locale }, "Every mounted copy label must use the injected interface locale")
            try self.capture(view, "copy-\(locale)-\(scheme)-01-ready")
        }
    }

    static func verifyCopyFeedback(scheme: ColorScheme) throws {
        let state = FixtureState()
        state.locale = Locale(identifier: "ru_RU")
        CommandCopyLabelProbe.events = []
        CommandCopyFeedbackClock.requested = []
        CommandCopyFeedbackClock.released = false
        let (window, view) = self.host(SingleCopyFixture(state: state, scheme: scheme), width: 120, height: 80, scheme: scheme)
        defer { self.close(window) }
        try self.capture(view, "feedback-ru_RU-\(scheme)-01-ready", verifyCopyGlyph: true)
        let point = view.convert(NSPoint(x: 60, y: 40), to: nil)
        for (index, type) in [NSEvent.EventType.leftMouseDown, .leftMouseUp].enumerated() {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: index + 1, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            self.pump(0.02)
        }
        self.awaitCondition("Successful copy must display localized transient feedback") {
            CommandCopyLabelProbe.events.contains { $0.copied && $0.value == "Скопировано" }
        }
        self.check(ClipboardService.copiedPayload == "Copy response Ёжик", "The action must copy user text verbatim")
        self.awaitCondition("Copied feedback must start one timer with the production duration") {
            CommandCopyFeedbackClock.requested == [.seconds(1.5)]
        }
        try self.capture(view, "feedback-ru_RU-\(scheme)-02-copied", verifyCopyGlyph: true)
        CommandCopyLabelProbe.events = []
        state.locale = Locale(identifier: "en_US")
        self.awaitCondition("Changing locale must preserve the in-progress copied state and relocalize it") {
            CommandCopyLabelProbe.events.contains { $0.copied && $0.value == "Copied" }
        }
        try self.capture(view, "feedback-en_US-\(scheme)-03-copied", verifyCopyGlyph: true)
        self.check(CommandCopyLabelProbe.events.allSatisfy { $0.copied }, "Copied feedback must last until its timer fires")
        CommandCopyLabelProbe.events = []
        CommandCopyFeedbackClock.released = true
        self.awaitCondition("Transient feedback must retire back to the localized copy label") {
            CommandCopyLabelProbe.events.contains { !$0.copied && $0.value == "Copy message" }
        }
        self.check(CommandCopyFeedbackClock.requested == [.seconds(1.5)], "Changing locale must not restart the feedback timer")
        self.check(ClipboardService.copiedPayload == "Copy response Ёжик", "Changing interface language must not repeat or translate the clipboard action")
        try self.capture(view, "feedback-en_US-\(scheme)-04-reset", verifyCopyGlyph: true)
    }

    static func verifyRelativeDatesAndData() throws {
        let reference = Date(timeIntervalSince1970: 1_790_000_000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cases: [(String, [(TimeInterval, String)])] = [
            ("en_US", [(0, "now"), (-60, "1 minute ago"), (-39600, "11 hours ago"), (-86400, "yesterday"), (86400, "tomorrow")]),
            ("ru_RU", [(0, "сейчас"), (-60, "1 минуту назад"), (-39600, "11 часов назад"), (-86400, "вчера"), (86400, "завтра")]),
        ]
        for (identifier, dates) in cases {
            let projection = CommandSessionProjection(locale: Locale(identifier: identifier))
            for (offset, expected) in dates {
                let sessions = [ChatSession(title: "New Chat", updatedAt: reference.addingTimeInterval(offset)),
                                ChatSession(title: "Copy response", updatedAt: reference.addingTimeInterval(offset),
                                            messages: [.init(role: .user, content: "Copy message Ёжик")])]
                let encoded = try encoder.encode(sessions)
                projection.refreshRows(from: sessions, reference: reference)
                self.check(projection.rows.allSatisfy { $0.relativeTime == expected },
                           "\(identifier), \(offset): expected \(expected), got \(projection.rows.map(\.relativeTime))")
                self.check(projection.rows.map(\.title).sorted() == ["Copy response", "New Chat"], "Imported or user titles that match UI keys must stay verbatim")
                self.check(projection.rows.first { $0.title == "Copy response" }?.preview == "Copy message Ёжик", "User message previews must stay verbatim")
                let after = try encoder.encode(sessions)
                self.check(after == encoded, "Presentation must not rewrite stored session data")
            }
        }
    }

    static func verifySidebar(scheme: ColorScheme, locale: String) throws {
        UserDefaults.standard.set(locale, forKey: PichiInterfaceLanguage.defaultsKey)
        let history = ChatHistoryStore()
        history.sessions = [ChatSession(title: "New Chat", updatedAt: Date()),
                            ChatSession(title: "Copy response Ёжик", updatedAt: Date().addingTimeInterval(-39600),
                                        messages: [.init(role: .user, content: "Copy message Ёжик")])]
        let original = history.sessions
        let sidebar = CommandSessionSidebar(history: history, canChangeSession: true, blockingReason: nil,
                                             onNewSession: {}, onSelect: { _ in }, onArchive: { _ in }, onRestore: { _ in })
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.theme, scheme == .light ? AppTheme.light : AppTheme.dark)
            .preferredColorScheme(scheme)
        let (window, view) = self.host(sidebar, width: 340, height: 500, scheme: scheme)
        defer { self.close(window) }
        self.pump(0.2)
        try self.capture(view, "sidebar-\(locale)-\(scheme)-01-rendered")
        self.check(history.sessions == original, "Rendering the sidebar must never translate or mutate user titles/messages")
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        self.directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        self.revision = CommandLine.arguments[2]
        self.check(Bundle.main.localizations.contains("ru"), "Fixture must use the compiled production catalog")
        try self.verifyRelativeDatesAndData()
        for scheme in [ColorScheme.light, .dark] {
            try self.verifyCopyButtons(scheme: scheme)
            try self.verifyCopyFeedback(scheme: scheme)
            for locale in ["en_US", "ru_RU"] { try self.verifySidebar(scheme: scheme, locale: locale) }
        }
        self.check(!NSApplication.shared.isActive, "All native tests must remain headless")
        print("Command UI localization: \(self.checks) checks passed; production views/catalog, native copy actions, RU/EN dates, verbatim user data, light/dark snapshots")
    }
}
