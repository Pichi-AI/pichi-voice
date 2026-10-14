#if os(macOS)
import AppKit
#endif
import SwiftUI

#if os(macOS)

/// Passive opt-in evidence for native toolbar appearance which ImageRenderer
/// cannot observe. Uses the existing owned-window bridge and file logger only.
@MainActor
enum ToolbarAppearanceTrace {
    static let enabledKey = "FluidDebugToolbarAppearanceTraceEnabled"
    static let isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    private static var stream = Stream()
    private static var pendingWindows: [ObjectIdentifier: (logical: String, physical: String)] = [:]
    private static weak var ownedWindow: NSWindow?
    private static var ownedContext = (logical: "unknown", physical: "unknown")

    /// Pure encoding/budget boundary is testable without creating an app/window,
    /// reading defaults, or opening the production log.
    struct Stream {
        let maxEvents: Int
        let maxBytes: Int
        private(set) var events = 0
        private(set) var bytes = 0
        private var previous: [String: Data] = [:]

        init(maxEvents: Int = 256, maxBytes: Int = 512 * 1024) {
            self.maxEvents = maxEvents
            self.maxBytes = maxBytes
        }

        mutating func encode(enabled: Bool, kind: String, source: String, payload: [String: Any],
                             pid: Int32, uptime: TimeInterval, timestamp: TimeInterval) -> String? {
            guard enabled, self.events < self.maxEvents,
                  JSONSerialization.isValidJSONObject(payload),
                  let fingerprint = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
                  self.previous[kind + ":" + source] != fingerprint else { return nil }
            let record: [String: Any] = ["kind": kind, "source": source, "payload": payload,
                "pid": pid, "uptime": uptime, "timestamp": timestamp, "sequence": self.events + 1]
            guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
                  self.bytes + data.count + "[ToolbarAppearance] ".utf8.count + 1 <= self.maxBytes,
                  let line = String(data: data, encoding: .utf8) else { return nil }
            self.previous[kind + ":" + source] = fingerprint
            self.events += 1
            self.bytes += data.count + "[ToolbarAppearance] ".utf8.count + 1
            return "[ToolbarAppearance] " + line
        }
    }

    static func emit(kind: String, source: String, payload: [String: Any]) {
        guard self.isEnabled else { return }
        let process = ProcessInfo.processInfo
        guard let line = self.stream.encode(enabled: true, kind: kind, source: source, payload: payload,
            pid: process.processIdentifier, uptime: process.systemUptime, timestamp: Date().timeIntervalSince1970) else { return }
        // Bypass any observable UI logger; this is the existing disk-only sink.
        FileLogger.shared.append(line: line)
    }

    static func schedule(window: NSWindow?, logical: String, physical: String) {
        guard self.isEnabled, let window else { return }
        let key = ObjectIdentifier(window)
        guard self.pendingWindows.count < 8 || self.pendingWindows[key] != nil else { return }
        self.ownedWindow = window
        self.ownedContext = (logical, physical)
        let alreadyScheduled = self.pendingWindows[key] != nil
        self.pendingWindows[key] = (logical, physical)
        guard !alreadyScheduled else { return }
        DispatchQueue.main.async { [weak window] in
            let latest = self.pendingWindows.removeValue(forKey: key)
            guard let window, let latest else { return }
            self.record(window: window, logical: latest.logical, physical: latest.physical)
        }
    }

    static func sampleOwnedWindowAfterLabelUpdate() {
        // The label event does not assert a window association. Independently
        // sample the existing bridge's owned window so route-only updates are
        // captured even when the sizing representable itself did not update.
        self.schedule(window: self.ownedWindow, logical: self.ownedContext.logical, physical: self.ownedContext.physical)
    }

    private static func appearance(_ value: NSAppearance?) -> String {
        value?.name.rawValue ?? "inherited"
    }

    private static func viewRecord(_ view: NSView) -> [String: Any] {
        ["class": String(describing: type(of: view)), "identity": String(describing: ObjectIdentifier(view)),
         "explicit": self.appearance(view.appearance), "effective": self.appearance(view.effectiveAppearance),
         "hidden": view.isHidden]
    }

    private static func record(window: NSWindow, logical: String, physical: String) {
        var itemCount = 0
        func itemRecord(_ item: NSToolbarItem, depth: Int) -> [String: Any] {
            guard depth < 3, itemCount < 48 else { return ["truncated": true] }
            itemCount += 1
            var row: [String: Any] = ["identifier": item.itemIdentifier.rawValue,
                "class": String(describing: type(of: item)),
                "identity": String(describing: ObjectIdentifier(item)), "enabled": item.isEnabled]
            var chain: [[String: Any]] = []
            var view = item.view
            for _ in 0..<8 {
                guard let current = view else { break }
                chain.append(self.viewRecord(current))
                view = current.superview
            }
            row["viewAncestors"] = chain
            if let group = item as? NSToolbarItemGroup {
                row["subitems"] = group.subitems.prefix(12).map { itemRecord($0, depth: depth + 1) }
            }
            return row
        }
        let items = (window.toolbar?.items ?? []).prefix(24).map { itemRecord($0, depth: 0) }
        // Some native items have no public item.view. Capture only structural
        // appearance metadata from bounded toolbar/glass frame descendants.
        var chrome: [[String: Any]] = []
        var queue: [(NSView, Int)] = window.contentView?.superview.map { [($0, 0)] } ?? []
        var cursor = 0
        // Breadth first keeps a large document subtree from exhausting the
        // bound before the sibling native titlebar/toolbar can be sampled.
        while cursor < queue.count, cursor < 160, chrome.count < 32 {
            let (view, depth) = queue[cursor]
            cursor += 1
            let name = String(describing: type(of: view))
            if name.localizedCaseInsensitiveContains("toolbar") || name.localizedCaseInsensitiveContains("glass") {
                chrome.append(self.viewRecord(view))
            }
            if depth < 8 {
                for child in view.subviews.prefix(max(0, 160 - queue.count)) { queue.append((child, depth + 1)) }
            }
        }
        var payload: [String: Any] = [
            "logical": logical, "physical": physical, "windowNumber": window.windowNumber,
            "windowIdentity": String(describing: ObjectIdentifier(window)), "isKey": window.isKeyWindow,
            "isMain": window.isMainWindow, "isVisible": window.isVisible, "applicationActive": NSApp.isActive,
            "applicationExplicit": self.appearance(NSApp.appearance),
            "applicationEffective": self.appearance(NSApp.effectiveAppearance),
            "windowExplicit": self.appearance(window.appearance),
            "windowEffective": self.appearance(window.effectiveAppearance),
            "toolbarItems": items, "chrome": chrome,
        ]
        if let frame = window.contentView?.superview { payload["frame"] = self.viewRecord(frame) }
        self.emit(kind: "window", source: "owned-window-\(window.windowNumber)", payload: payload)
    }
}

private struct ToolbarLabelAppearanceTrace: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.appearsActive) private var active
    @Environment(\.isEnabled) private var enabled
    let source: String

    private func record(_ phase: String) {
        ToolbarAppearanceTrace.emit(kind: "label", source: self.source, payload: [
            "phase": phase, "colorScheme": self.scheme == .dark ? "dark" : "light",
            "appearsActive": self.active, "enabled": self.enabled,
        ])
        ToolbarAppearanceTrace.sampleOwnedWindowAfterLabelUpdate()
    }

    func body(content: Content) -> some View {
        content
            .onAppear { self.record("appear") }
            .onDisappear { self.record("disappear") }
            .onChange(of: self.scheme) { _, _ in self.record("environment") }
            .onChange(of: self.active) { _, _ in self.record("environment") }
            .onChange(of: self.enabled) { _, _ in self.record("environment") }
    }
}
#endif

extension View {
    @ViewBuilder
    func traceToolbarAppearance(file: StaticString = #fileID, line: UInt = #line) -> some View {
        #if os(macOS)
        if ToolbarAppearanceTrace.isEnabled {
            self.modifier(ToolbarLabelAppearanceTrace(source: "\(file):\(line)"))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
