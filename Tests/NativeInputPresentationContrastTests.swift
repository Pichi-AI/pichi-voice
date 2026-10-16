import AppKit
import SwiftUI

/// Exact presentation roots, with inert service delivery only. This exercises
/// their local appearance ownership, not the application's sheet inheritance.
enum NativeInputPresentationContrastTests {
    @MainActor private final class State: ObservableObject {
        @Published var theme: AppTheme
        init(_ theme: AppTheme) { self.theme = theme }
    }
    private struct Host: View {
        @ObservedObject var state: State
        let kind: Int
        @ViewBuilder var body: some View {
            Group {
                switch self.kind {
                case 0: ProductionWPMEditor()
                case 1: MeetingTranscriptTextEditor(text: "Ёжик ёлка synthetic paragraph", onSave: { _ in nil }, onCancel: {})
                default: EditDictionaryEntrySheet(entry: .init(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, triggers: ["синтетика"], replacement: "Ёжик ёлка"), existingTriggers: [], onSave: { _ in })
                }
            }
            // Deliberately no appTheme or colorScheme on the outside adapter.
            .environment(\.theme, self.state.theme)
            .tint(self.state.theme.palette.accent)
        }
    }
    private static func inputs(_ view: NSView) -> [NSView] {
        let own: [NSView] = view is NSTextView || (view as? NSTextField)?.isEditable == true ? [view] : []
        return own + view.subviews.flatMap(self.inputs)
    }
    @MainActor private static func settle(_ host: NSView) async {
        for _ in 0..<8 { host.layoutSubtreeIfNeeded(); try? await Task.sleep(for: .milliseconds(10)) }
    }
    private static func components(_ color: NSColor) -> [Double] {
        let value = color.usingColorSpace(.sRGB)!
        return [Double(value.redComponent), Double(value.greenComponent), Double(value.blueComponent)]
    }
    @MainActor static func run(directory: URL) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let original = NSApp.appearance
        defer { NSApp.appearance = original }
        var packages = try [("pichi", "Sources/Fluid/Branding/brand-package.json"),
                            ("sber", "Configuration/BrandExamples/sber-demo.json"),
                            ("alfa", "Configuration/BrandExamples/alfa-demo.json")].map { name, path in
            (name, try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path))))
        }
        let surfaces = Set(["windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground"])
        func palette(_ fill: String, _ ink: String, _ accentInk: String) -> BrandPalette {
            var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, surfaces.contains($0) ? fill : ink) })
            colors["accentForeground"] = accentInk
            return BrandPalette(colors: colors)
        }
        let profile = BrandProfile(appName: "Synthetic", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic", accentLight: "#A98CFF", accentDark: "#6845AD", website: "https://example.invalid", support: "https://example.invalid")
        let inverted = BrandPackage(profile: profile, theme: BrandTheme(light: palette("#201A2C", "#FFFFFF", "#000000"), dark: palette("#F4F0FA", "#000000", "#FFFFFF")))
        packages.append(("inverted", try BrandPackage.decode(inverted.encoded())))
        var records = [[String: Any]]()
        for (brand, package) in packages {
            func theme(_ scheme: ColorScheme) -> AppTheme {
                AppTheme.adaptive(accent: Color(hex: scheme == .dark ? package.profile.accentDark : package.profile.accentLight)!, colorScheme: scheme, package: package)
            }
            for kind in 0..<3 {
                let state = State(theme(.dark))
                let host = NSHostingView(rootView: Host(state: state, kind: kind))
                host.frame = NSRect(x: 0, y: 0, width: 600, height: 520)
                let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                var retainedInputs = [NSView]()
                for (step, scheme) in [ColorScheme.dark, .light, .dark].enumerated() {
                    state.theme = theme(scheme)
                    let physical = state.theme.palette.nativeColorScheme(fallback: scheme)
                    let opposed: ColorScheme = physical == .dark ? .light : .dark
                    NSApp.appearance = NSAppearance(named: opposed == .dark ? .darkAqua : .aqua)
                    window.appearance = NSApp.appearance
                    await self.settle(host)
                    let current = self.inputs(host)
                    precondition(current.count == (kind == 2 ? 2 : 1), "Exact production roots must mount all native inputs")
                    if !retainedInputs.isEmpty {
                        precondition(zip(current, retainedInputs).allSatisfy { $0 === $1 }, "Hot themes retain native input identity")
                    }
                    retainedInputs = current
                    for input in current {
                        precondition(input.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (physical == .dark ? .darkAqua : .aqua), "Actual input presentation must own its portable native appearance")
                        var contrast = 0.0
                        input.effectiveAppearance.performAsCurrentDrawingAppearance {
                            if let field = input as? NSTextField {
                                precondition(!field.stringValue.isEmpty)
                                let fill = kind == 0 ? self.components(.textBackgroundColor) : UIContrastTests.components(state.theme.palette.windowBackground)
                                contrast = UIContrastTests.contrast(self.components(field.textColor ?? .textColor), fill)
                            } else if let editor = input as? NSTextView {
                                precondition(!editor.string.isEmpty)
                                // Transcript has an explicit card. Dictionary has an
                                // explicit window surface; do not invent a native fill
                                // for its translucent input chrome.
                                let fill = kind == 1 ? state.theme.palette.cardBackground : state.theme.palette.windowBackground
                                contrast = UIContrastTests.contrast(self.components(editor.textColor ?? .textColor), UIContrastTests.components(fill))
                            }
                        }
                        precondition(contrast >= 4.5, "Normal native text requires 4.5 against its production surface")
                        records.append(["brand": brand, "kind": kind, "step": step, "logical": String(describing: scheme), "physical": String(describing: physical), "ambientAppAppearance": NSApp.effectiveAppearance.name.rawValue, "ambientWindowAppearance": window.effectiveAppearance.name.rawValue, "inputAppearance": input.effectiveAppearance.name.rawValue, "contrast": contrast])
                    }
                    let image = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                    host.cacheDisplay(in: host.bounds, to: image)
                    try image.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("native-input-root-\(brand)-\(kind)-\(step)-\(scheme).png"))
                    precondition(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
                }
            }
        }
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("native-input-presentation-results.json"))
        print("Native input roots: 36 retained dark/light/dark cases, 48 native inputs, three brands plus validated inversion, normal text >=4.5; only outside environment(theme) + caller brand tint")
        print("SKIP: no physical focus/active selection, no native app reachability claim. Existing participant probe retains its separate caret >=3 and NONKEY inactive selection >=3 gates.")
    }
}
