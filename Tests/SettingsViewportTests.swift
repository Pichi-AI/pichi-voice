import AppKit
import SwiftUI

@MainActor private final class SettingsViewportTestState: ObservableObject {
    @Published var scheme = ColorScheme.light
}

@MainActor enum Probe {
    static var markers: [String: NSView] = [:]
}

struct Marker: NSViewRepresentable {
    let name: String
    func makeNSView(context _: Context) -> NSView {
        let view = NSView()
        Probe.markers[self.name] = view
        return view
    }
    func updateNSView(_: NSView, context _: Context) {}
}

private struct SettingsViewportRoot: View {
    @ObservedObject var state: SettingsViewportTestState
    let coordinator: SettingsSearchScrollCoordinator

    var body: some View {
        NavigationSplitView {
            Text("Sidebar").fluidViewport()
                .frame(minWidth: 264, maxWidth: 360)
                .navigationSplitViewColumnWidth(min: 264, ideal: 300, max: 360)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            ZStack {
                Color.white.ignoresSafeArea()
                Text("Preserved app content").opacity(0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                SettingsPersistentScrollView(
                    theme: self.state.scheme == .light ? .light : .dark,
                    colorScheme: self.state.scheme,
                    searchScrollCoordinator: self.coordinator,
                    searchScrollTarget: nil, searchScrollRequest: 0
                ) {
                    RealContent()
                }
            }
            .navigationTitle("General").fluidViewport()
        }
        .navigationSplitViewStyle(.balanced).fluidViewport()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Sidebar", systemImage: "sidebar.left") {}
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Theme", systemImage: "sun.max") {}
                Button("Report", systemImage: "ladybug") {}
            }
        }
        .toolbar(removing: .sidebarToggle)
    }
}

@main private struct SettingsViewportTests {
    @MainActor static func settle(_ window: NSWindow) {
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.025))
        }
    }

    @MainActor static func scroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView is NSHostingView<AnyView> { return scroll }
        return view.subviews.lazy.compactMap { self.scroll(in: $0) }.first
    }

    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        defer { window.close() }
        let state = SettingsViewportTestState()
        let coordinator = SettingsSearchScrollCoordinator()
        window.contentView = NSHostingView(rootView: SettingsViewportRoot(state: state, coordinator: coordinator))
        self.settle(window)
        let scroll = self.scroll(in: window.contentView!)!
        let document = scroll.documentView!
        let header = Probe.markers["header"]!
        let lower = Probe.markers["row2"]!
        var states = [[String: Any]]()
        var failures = [String]()
        func record(_ phase: String, target: NSView = header) {
            let targetRect = target.convert(target.bounds, to: nil)
            let clearance = window.contentLayoutRect.maxY - targetRect.maxY
            let expected = target === header ? 50.0 : 16.0
            if abs(clearance - expected) > 1 { failures.append("\(phase): clearance \(clearance), expected \(expected)") }
            if Probe.markers["header"] !== header || Probe.markers["row2"] !== lower || scroll.documentView !== document {
                failures.append("\(phase): hosting or anchor identity changed")
            }
            if window.isVisible || window.isKeyWindow { failures.append("\(phase): window became visible or key") }
            states.append([
                "phase": phase, "clearance": clearance, "documentWidth": document.frame.width,
                "documentHeight": document.frame.height, "clipWidth": scroll.contentView.bounds.width,
                "clipHeight": scroll.contentView.bounds.height, "topInset": scroll.contentInsets.top,
                "visible": window.isVisible, "key": window.isKeyWindow,
            ])
        }
        record("initial")
        window.setContentSize(NSSize(width: 850, height: 520))
        self.settle(window)
        record("narrower")
        state.scheme = .dark
        self.settle(window)
        record("content-update")
        coordinator.register(lower, for: .lower)
        coordinator.requestScroll(to: .lower, requestID: 1)
        self.settle(window)
        record("search", target: lower)
        coordinator.requestScroll(to: nil, requestID: 2)
        window.setContentSize(NSSize(width: 1000, height: 700))
        self.settle(window)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
        scroll.reflectScrolledClipView(scroll.contentView)
        self.settle(window)
        record("wider-return-to-top")
        let report: [String: Any] = ["states": states, "failures": failures, "scope": "Offscreen production hosting geometry, not app screenshot evidence"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        assert(!NSApplication.shared.windows.contains(where: { $0.isVisible }))
    }
}
