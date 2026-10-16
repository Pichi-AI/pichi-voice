import AppKit
import SwiftUI

@MainActor private final class SettingsViewportTestState: ObservableObject {
    @Published var scheme = ColorScheme.light
    @Published var themeOverride: AppTheme?
    var theme: AppTheme { self.themeOverride ?? AppTheme.adaptive(accent: .purple, colorScheme: self.scheme) }
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
                self.state.theme.palette.contentBackground.ignoresSafeArea()
                Text("Preserved app content").opacity(0)
                    .allowsHitTesting(false).accessibilityHidden(true)
                SettingsPersistentScrollView(
                    theme: self.state.theme,
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

    // Cache actual native track pixels from the attached production scroller.
    // No visible/key window or custom drawing substitutes for AppKit painting.
    @MainActor static func track(_ scroller: NSScroller, phase: String, background: Color) throws -> [String: Any] {
        guard let image = scroller.bitmapImageRepForCachingDisplay(in: scroller.bounds) else {
            throw NSError(domain: "SettingsViewportTests", code: 1)
        }
        scroller.cacheDisplay(in: scroller.bounds, to: image)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PICHI_SETTINGS_VIEWPORT_OUTPUT_DIR"] ?? ".build/settings-viewport-tests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("scroller-\(phase).png")
        guard let data = image.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SettingsViewportTests", code: 2)
        }
        try data.write(to: path)
        let knob = scroller.rect(for: .knob)
        let surface = NSColor(background).usingColorSpace(.sRGB)!
        var luminances = [Double]()
        var alphas = [Double]()
        var rawLuminances = [Double]()
        for y in 2..<(image.pixelsHigh - 2) {
            for x in 2..<(image.pixelsWide - 2) {
                let point = NSPoint(x: CGFloat(x) * scroller.bounds.width / CGFloat(image.pixelsWide),
                                    y: (scroller.isFlipped ? CGFloat(y) : CGFloat(image.pixelsHigh - y)) * scroller.bounds.height / CGFloat(image.pixelsHigh))
                guard !knob.insetBy(dx: -2, dy: -2).contains(point),
                      let color = image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      color.alphaComponent > 0.01 else { continue }
                let alpha = Double(color.alphaComponent)
                alphas.append(alpha)
                rawLuminances.append(Double(color.redComponent) * 0.2126 + Double(color.greenComponent) * 0.7152 + Double(color.blueComponent) * 0.0722)
                let red = Double(color.redComponent) * alpha + Double(surface.redComponent) * (1 - alpha)
                let green = Double(color.greenComponent) * alpha + Double(surface.greenComponent) * (1 - alpha)
                let blue = Double(color.blueComponent) * alpha + Double(surface.blueComponent) * (1 - alpha)
                luminances.append(red * 0.2126 + green * 0.7152 + blue * 0.0722)
            }
        }
        return ["image": path.path, "paintedTrackPixels": luminances.count,
                "trackMinimumAlpha": alphas.min() ?? 0, "trackMaximumAlpha": alphas.max() ?? 0,
                "rawTrackMeanRGBLuminance": rawLuminances.isEmpty ? -1.0 : rawLuminances.reduce(0, +) / Double(rawLuminances.count),
                "compositionSurfaceRGB": [Double(surface.redComponent), Double(surface.greenComponent), Double(surface.blueComponent)],
                "trackMeanRGBLuminance": luminances.isEmpty ? -1.0 : luminances.reduce(0, +) / Double(luminances.count),
                "effectiveAppearance": scroller.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])?.rawValue ?? "unknown",
                "explicitAppearance": scroller.appearance?.name.rawValue ?? "inherited"]
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
        let application = NSApplication.shared
        let originalApplicationAppearance = application.appearance
        let originalWindowAppearance = window.appearance
        defer {
            application.appearance = originalApplicationAppearance
            window.appearance = originalWindowAppearance
        }
        let scroller = scroll.verticalScroller!
        let clip = scroll.contentView
        var appearanceStates = [[String: Any]]()
        let lightTheme = AppTheme.adaptive(accent: .purple, colorScheme: .light)
        let darkTheme = AppTheme.adaptive(accent: .purple, colorScheme: .dark)
        let surfaces: Set<String> = ["windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground"]
        func palette(surface: String, ink: String) -> BrandPalette {
            var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, surfaces.contains($0) ? surface : ink) })
            colors["accentForeground"] = "#000000"
            return BrandPalette(colors: colors)
        }
        let package = try BrandPackage.decode(BrandPackage(
            profile: BrandProfile(appName: "Scroller fixture", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic fixture",
                accentLight: "#949494", accentDark: "#949494", website: "https://example.invalid", support: "https://example.invalid"),
            theme: BrandTheme(light: palette(surface: "#151515", ink: "#FFFFFF"), dark: palette(surface: "#FFFFFF", ink: "#000000"))
        ).encoded())
        let invertedLight = AppTheme.adaptive(accent: Color(hex: "#949494")!, colorScheme: .light, package: package)
        let invertedDark = AppTheme.adaptive(accent: Color(hex: "#949494")!, colorScheme: .dark, package: package)
        let appearanceCases: [(String, ColorScheme, ColorScheme, ColorScheme, AppTheme)] = [
            ("app-light-window-dark", .light, .dark, .dark, darkTheme),
            ("app-dark-window-light", .dark, .light, .light, lightTheme),
            ("system-flip-theme-light", .light, .light, .light, lightTheme),
            ("live-theme-dark", .light, .light, .dark, darkTheme),
            ("inverted-logical-light", .light, .light, .light, invertedLight),
            ("inverted-logical-dark", .dark, .dark, .dark, invertedDark),
        ]
        coordinator.requestScroll(to: .lower, requestID: 3)
        self.settle(window)
        for (phase, appScheme, windowScheme, logicalScheme, theme) in appearanceCases {
            let previousPosition = clip.bounds.origin
            application.appearance = NSAppearance(named: appScheme == .dark ? .darkAqua : .aqua)
            window.appearance = NSAppearance(named: windowScheme == .dark ? .darkAqua : .aqua)
            state.scheme = logicalScheme
            state.themeOverride = theme
            self.settle(window)
            let expected = theme.palette.nativeColorScheme(fallback: theme.variant ?? logicalScheme)
            let expectedName = expected == .dark ? NSAppearance.Name.darkAqua : .aqua
            var sample = try self.track(scroller, phase: phase, background: theme.palette.contentBackground)
            sample["phase"] = phase
            sample["expectedAppearance"] = expectedName.rawValue
            sample["appAppearance"] = application.effectiveAppearance.name.rawValue
            sample["windowAppearance"] = window.effectiveAppearance.name.rawValue
            sample["scrollAppearance"] = scroll.effectiveAppearance.name.rawValue
            sample["clipAppearance"] = clip.effectiveAppearance.name.rawValue
            sample["scrollDrawsBackground"] = scroll.drawsBackground
            sample["clipDrawsBackground"] = clip.drawsBackground
            clip.effectiveAppearance.performAsCurrentDrawingAppearance {
                let background = clip.backgroundColor.usingColorSpace(.sRGB)!
                sample["clipBackgroundRGBA"] = [Double(background.redComponent), Double(background.greenComponent), Double(background.blueComponent), Double(background.alphaComponent)]
            }
            sample["positionY"] = clip.bounds.origin.y
            if scroll.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != expectedName || clip.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != expectedName || scroller.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != expectedName {
                failures.append("\(phase): scroller inherits the wrong physical appearance")
            }
            let pixels = sample["paintedTrackPixels"] as! Int
            let luminance = (sample["trackMeanRGBLuminance"] as! NSNumber).doubleValue
            if pixels < 100 { failures.append("\(phase): native track failed to rasterize") }
            if expected == .dark ? luminance >= 0.5 : luminance <= 0.5 {
                failures.append("\(phase): track luminance \(luminance) disagrees with palette appearance")
            }
            if application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != (appScheme == .dark ? .darkAqua : .aqua) || window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != (windowScheme == .dark ? .darkAqua : .aqua) {
                failures.append("\(phase): local update changed application or window appearance")
            }
            if scroll.documentView !== document || scroll.verticalScroller !== scroller || scroll.contentView !== clip || Probe.markers["header"] !== header || Probe.markers["row2"] !== lower {
                failures.append("\(phase): palette change replaced hosting, anchor, clip or scroller identity")
            }
            if abs(clip.bounds.origin.y - previousPosition.y) > 1 {
                failures.append("\(phase): palette change moved the current scroll position")
            }
            if window.isVisible || window.isKeyWindow { failures.append("\(phase): window became visible or key") }
            appearanceStates.append(sample)
        }
        // Cover makeNSView as well as live updateNSView. Deliberately retain an
        // opposite native ancestor, as may occur before owned chrome refreshes.
        for (phase, scheme, theme): (String, ColorScheme, AppTheme) in [
            ("make-dark-under-aqua", .dark, darkTheme),
            ("make-light-under-dark-aqua", .light, lightTheme),
        ] {
            let initialState = SettingsViewportTestState()
            initialState.scheme = scheme
            initialState.themeOverride = theme
            let initialWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            initialWindow.isReleasedWhenClosed = false
            defer { initialWindow.close() }
            let opposite = NSAppearance(named: scheme == .dark ? .aqua : .darkAqua)!
            application.appearance = opposite
            initialWindow.appearance = opposite
            initialWindow.contentView = NSHostingView(rootView: SettingsViewportRoot(state: initialState, coordinator: SettingsSearchScrollCoordinator()))
            self.settle(initialWindow)
            let initialScroll = self.scroll(in: initialWindow.contentView!)!
            let expectedName = scheme == .dark ? NSAppearance.Name.darkAqua : .aqua
            var sample = try self.track(initialScroll.verticalScroller!, phase: phase, background: theme.palette.contentBackground)
            sample["phase"] = phase
            sample["expectedAppearance"] = expectedName.rawValue
            sample["appAppearance"] = application.effectiveAppearance.name.rawValue
            sample["windowAppearance"] = initialWindow.effectiveAppearance.name.rawValue
            sample["scrollDrawsBackground"] = initialScroll.drawsBackground
            sample["clipDrawsBackground"] = initialScroll.contentView.drawsBackground
            let luminance = (sample["trackMeanRGBLuminance"] as! NSNumber).doubleValue
            if initialScroll.verticalScroller!.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) != expectedName {
                failures.append("\(phase): initial scroller inherits the wrong physical appearance")
            }
            if (sample["paintedTrackPixels"] as! Int) < 100 || (scheme == .dark ? luminance >= 0.5 : luminance <= 0.5) {
                failures.append("\(phase): initial native track disagrees with palette appearance")
            }
            if initialWindow.isVisible || initialWindow.isKeyWindow { failures.append("\(phase): window became visible or key") }
            appearanceStates.append(sample)
        }
        let report: [String: Any] = ["states": states, "appearanceStates": appearanceStates,
            "failures": failures, "scope": "Offscreen production hosting geometry and attached native scroller pixels, not app screenshot evidence"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
        assert(!NSApplication.shared.windows.contains(where: { $0.isVisible }))
    }
}
