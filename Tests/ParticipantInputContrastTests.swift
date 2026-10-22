import AppKit
import SwiftUI

/// The complete production participant editor in a retained, never-visible host.
/// No application services, stored meeting data or physical input are involved.
// Inert metadata only; the actual ProviderConnectionFields view is compiled.
struct CloudTextProvider {
    struct Field: Identifiable {
        let id: String
        let title: String
        let defaultValue: String
        let choices: [String]
    }
    let fields: [Field]
}

// Shape-only meeting metadata for compiling the complete production sheet.
// No persistence, session services, recordings or personal names are available.
typealias SessionSpeakerID = UUID
struct MeetingSessionSpeaker: Identifiable {
    let id: SessionSpeakerID
    var displayName: String
    var isLocalUser: Bool
    var mergedIntoSpeakerID: SessionSpeakerID? = nil
    var generatedParticipantNumber: Int? = nil
}
struct MeetingTranscriptSegment {
    enum Status { case final, partial }
    struct Time { let seconds: Double }
    let speakerID: SessionSpeakerID?
    let isEcho: Bool
    let status: Status
    let start: Time
    let text: String
}

enum ParticipantInputContrastTests {
    @MainActor final class State: ObservableObject {
        @Published var theme: AppTheme
        @Published var drafts = ["synthetic": "Ёжик ёлка"]
        @Published var saving = false
        init(theme: AppTheme) { self.theme = theme }
    }

    private struct Host: View {
        @ObservedObject var state: State
        var body: some View {
            ProductionParticipantInputFixture(drafts: self.$state.drafts, isSaving: self.state.saving)
                .frame(width: 400)
                .padding(4)
                .appTheme(self.state.theme)
                .tint(self.state.theme.palette.accent)
                .background(self.state.theme.palette.windowBackground)
        }
    }

    @MainActor private final class SheetObservations {
        var saveCalls = [[SessionSpeakerID: String]]()
        var cancelCalls = 0
    }
    private struct SheetHost: View {
        @ObservedObject var state: State
        let observations: SheetObservations
        let inheritedTintIsOpposed: Bool
        static let speakerID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        var body: some View {
            MeetingAssignSpeakersSheet(
                speakers: [.init(id: Self.speakerID, displayName: "Ёжик ёлка", isLocalUser: false)],
                quotesBySpeaker: [:], tints: [:],
                onSave: { self.observations.saveCalls.append($0); return nil },
                onCancel: { self.observations.cancelCalls += 1 })
                // The presentation adapter passes custom theme and caller tint.
                // Root font/foreground/native colorScheme must come FROM SHEET.
                .environment(\.theme, self.state.theme)
                .tint(self.inheritedTintIsOpposed ? .cyan : self.state.theme.palette.accent)
        }
    }

    @MainActor private static func selectionContrast(_ editor: NSTextView) -> Double {
        var result = 0.0
        editor.effectiveAppearance.performAsCurrentDrawingAppearance {
            let attributes = editor.selectedTextAttributes
            let ink = ((attributes[.foregroundColor] as? NSColor) ?? editor.textColor ?? .textColor).usingColorSpace(.sRGB)!
            let fill = ((attributes[.backgroundColor] as? NSColor) ?? .selectedTextBackgroundColor).usingColorSpace(.sRGB)!
            result = UIContrastTests.contrast([Double(ink.redComponent), Double(ink.greenComponent), Double(ink.blueComponent)],
                [Double(fill.redComponent), Double(fill.greenComponent), Double(fill.blueComponent)])
        }
        return result
    }

    @MainActor private static func verifyWholeSheet(state: State, name: String, theme: (ColorScheme) -> AppTheme, inheritedTintIsOpposed: Bool, directory: URL) async throws {
        let observations = SheetObservations()
        let host = NSHostingView(rootView: SheetHost(state: state, observations: observations, inheritedTintIsOpposed: inheritedTintIsOpposed))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        var originalField: NSTextField?
        var expectedDraft = "Ёжик ёлка"
        let tintCase = inheritedTintIsOpposed ? "opposed-inherited-tint" : "brand-inherited-tint"
        for (step, scheme) in [ColorScheme.dark, .light, .dark].enumerated() {
            let opposite: ColorScheme = scheme == .dark ? .light : .dark
            NSApp.appearance = NSAppearance(named: opposite == .dark ? .darkAqua : .aqua)
            window.appearance = NSApp.appearance
            state.theme = theme(scheme)
            await self.settle(host)
            let field = self.fields(host).first { $0.isEditable }!
            if let originalField { precondition(originalField === field, "Whole sheet theme changes retain the existing field") }
            originalField = field
            precondition(field.stringValue == expectedDraft, "Whole sheet theme changes preserve the actual draft")
            let physical = state.theme.palette.nativeColorScheme(fallback: scheme)
            precondition(field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (physical == .dark ? .darkAqua : .aqua), "Actual sheet itself must establish its portable native appearance")
            precondition(window.makeFirstResponder(field))
            let editor = window.fieldEditor(false, for: field) as! NSTextView
            editor.setSelectedRange(NSRange(location: 0, length: 4))
            await self.settle(host)
            let contrast = self.selectionContrast(editor)
            fputs("Whole hidden non-key sheet \(name)-\(tintCase)-\(step)-\(scheme): selected contrast=\(contrast), editor=\(editor.effectiveAppearance.name)\n", stderr)
            // Inactive native selection has the original >=3 legibility gate.
            // A strict >=4.5 experiment failed Sber Dark at 4.06 and is retained
            // separately. This never establishes active physical selection PASS.
            precondition(contrast >= 3, "Whole-sheet inactive native selection must remain legible")
            var caret = NSColor.clear
            editor.effectiveAppearance.performAsCurrentDrawingAppearance { caret = editor.insertionPointColor.usingColorSpace(.sRGB)! }
            precondition(UIContrastTests.contrast([Double(caret.redComponent), Double(caret.greenComponent), Double(caret.blueComponent)], UIContrastTests.components(state.theme.palette.elevatedCardBackground)) >= 3)
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("whole-participant-sheet-\(name)-\(tintCase)-\(step)-\(scheme).png"))
            let draft = step == 0 ? "Нативный Ёжик" : "Нативный Ёжик ёлка"
            editor.string = draft
            field.stringValue = draft
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            _ = window.makeFirstResponder(nil)
            await self.settle(host)
            precondition(field.stringValue == draft)
            expectedDraft = draft
            precondition(observations.saveCalls.isEmpty && observations.cancelCalls == 0, "Theme, focus and native edits cannot invoke save/cancel")
            precondition(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
        }
    }

    private struct ProviderHost: View {
        @ObservedObject var state: State
        var body: some View {
            FluidManagementSheet(title: "Synthetic", subtitle: "Synthetic", symbol: "gear", height: 250, close: {}) {
                ProviderConnectionFields(provider: CloudTextProvider(fields: [.init(id: "synthetic", title: "Synthetic", defaultValue: "", choices: [])]), options: self.$state.drafts)
            }
            .appTheme(self.state.theme)
        }
    }

    @MainActor private static func verifyProviderComparison(state: State, name: String, directory: URL) async throws {
        let host = NSHostingView(rootView: ProviderHost(state: state))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 250)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        for app: ColorScheme in [.light, .dark] {
            window.appearance = NSAppearance(named: app == .dark ? .darkAqua : .aqua)
            await self.settle(host)
            let field = self.fields(host).first!
            let physical = state.theme.palette.nativeColorScheme(fallback: state.theme.variant!)
            precondition(field.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (physical == .dark ? .darkAqua : .aqua), "Actual management provider field follows its explicit appTheme boundary")
            precondition(field.stringValue == state.drafts["synthetic"])
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("provider-comparison-\(name)-parent-\(app).png"))
            var contrast = 0.0
            field.effectiveAppearance.performAsCurrentDrawingAppearance {
                let ink = field.textColor!.usingColorSpace(.sRGB)!
                let background = NSColor.textBackgroundColor.usingColorSpace(.sRGB)!
                contrast = UIContrastTests.contrast([Double(ink.redComponent), Double(ink.greenComponent), Double(ink.blueComponent)], [Double(background.redComponent), Double(background.greenComponent), Double(background.blueComponent)])
            }
            precondition(contrast >= 4.5, "Management native text/background contrast must remain readable")
            precondition(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
        }
    }

    private static func fields(_ view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap(self.fields)
    }

    @MainActor private static func settle(_ host: NSView) async {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor private static func raster(_ host: NSView, name: String, theme: AppTheme, empty: Bool, disabled: Bool, directory: URL) throws {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        let image = bitmap.cgImage!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let surface = UIContrastTests.components(theme.palette.elevatedCardBackground)
        let ink = UIContrastTests.components(empty ? theme.palette.secondaryText : theme.palette.primaryText)
        precondition(UIContrastTests.contrast(ink, surface) >= (empty ? 3 : 4.5))
        var surfacePixels = 0, inkPixels = 0
        let scale = Double(image.width) / host.bounds.width
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                guard bytes[offset + 3] == 255 else { continue }
                if (0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - surface[$0]) < 0.02 }) { surfacePixels += 1 }
                // Exclude the field border and focus ring from the text count.
                if x > Int(12 * scale), x < Int(200 * scale), y > Int(12 * scale), y < image.height - Int(12 * scale),
                   (disabled && !empty
                    ? UIContrastTests.contrast((0..<3).map { Double(bytes[offset + $0]) / 255 }, surface) >= 3
                    : (0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - ink[$0]) < 0.04 })) { inkPixels += 1 }
            }
        }
        fputs("\(name): surface=\(surfacePixels), text=\(inkPixels)\n", stderr)
        precondition(surfacePixels > image.width * image.height / 3, "\(name): paired opaque field surface is absent")
        precondition(inkPixels >= 20, "\(name): typed text or empty hint is invisible")
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
        let backgrounds = Set(["windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground"])
        func palette(surface: String, ink: String, accentInk: String) -> BrandPalette {
            var values = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, backgrounds.contains($0) ? surface : ink) })
            values["accentForeground"] = accentInk
            return BrandPalette(colors: values)
        }
        let profile = BrandProfile(appName: "Synthetic", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic",
            accentLight: "#A98CFF", accentDark: "#6845AD", website: "https://example.invalid", support: "https://example.invalid")
        let inverted = BrandPackage(profile: profile, theme: BrandTheme(
            light: palette(surface: "#201A2C", ink: "#FFFFFF", accentInk: "#000000"),
            dark: palette(surface: "#F4F0FA", ink: "#000000", accentInk: "#FFFFFF")))
        packages.append(("inverted", try BrandPackage.decode(inverted.encoded())))
        var checks = 0
        for (name, package) in packages {
            func theme(_ scheme: ColorScheme) -> AppTheme {
                AppTheme.adaptive(accent: Color(hex: scheme == .dark ? package.profile.accentDark : package.profile.accentLight)!, colorScheme: scheme, package: package)
            }
            let state = State(theme: theme(.dark))
            let host = NSHostingView(rootView: Host(state: state))
            host.frame = NSRect(x: 0, y: 0, width: 408, height: 56)
            // Native field editor ownership requires a window, but it is never
            // shown, activated or made key. The user's app remains untouched.
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            await self.settle(host)
            let field = self.fields(host).first!
            for (step, scheme) in [ColorScheme.dark, .light, .dark].enumerated() {
                // Deliberately oppose the native window and selected palette.
                // The field's portable fill and explicit ink must stay paired.
                NSApp.appearance = NSAppearance(named: scheme == .dark ? .aqua : .darkAqua)
                window.appearance = NSApp.appearance
                state.theme = theme(scheme)
                await self.settle(host)
                precondition(self.fields(host).first === field, "Theme updates must retain the native editor")
                for saving in [false, true] {
                    state.saving = saving
                    for empty in [false, true] {
                        state.drafts["synthetic"] = empty ? "" : "Ёжик ёлка"
                        await self.settle(host)
                        precondition(field.stringValue == state.drafts["synthetic"] && field.isEnabled == !saving)
                        try self.raster(host, name: "participant-\(name)-\(step)-\(scheme)-\(saving ? "disabled" : "enabled")-\(empty ? "empty" : "typed")", theme: state.theme, empty: empty, disabled: saving, directory: directory)
                        checks += 1
                    }
                }
                state.saving = false
                state.drafts["synthetic"] = "Ёжик ёлка"
                await self.settle(host)
                precondition(window.makeFirstResponder(field))
                guard let editor = window.fieldEditor(false, for: field) as? NSTextView else { preconditionFailure("Native field editor must exist") }
                editor.setSelectedRange(NSRange(location: 0, length: 4))
                let selected = editor.selectedRange()
                var selectionContrast = 0.0
                editor.effectiveAppearance.performAsCurrentDrawingAppearance {
                    let attributes = editor.selectedTextAttributes
                    let selectedInk = ((attributes[.foregroundColor] as? NSColor) ?? editor.textColor ?? .textColor).usingColorSpace(.sRGB)!
                    let selectedFill = ((attributes[.backgroundColor] as? NSColor) ?? .selectedTextBackgroundColor).usingColorSpace(.sRGB)!
                    selectionContrast = UIContrastTests.contrast(
                        [Double(selectedInk.redComponent), Double(selectedInk.greenComponent), Double(selectedInk.blueComponent)],
                        [Double(selectedFill.redComponent), Double(selectedFill.greenComponent), Double(selectedFill.blueComponent)])
                }
                // This window is deliberately non-key. The system's inactive
                // selection treatment is tested at the same minimum as disabled
                // controls, rather than claiming active selection rasterization.
                precondition(selectionContrast >= 3, "Inactive native selection ink and fill remain readable")
                let surface = UIContrastTests.components(state.theme.palette.elevatedCardBackground)
                var caret = NSColor.clear
                editor.effectiveAppearance.performAsCurrentDrawingAppearance { caret = editor.insertionPointColor.usingColorSpace(.sRGB)! }
                let caretContrast = UIContrastTests.contrast([Double(caret.redComponent), Double(caret.greenComponent), Double(caret.blueComponent)], surface)
                fputs("Field caret \(name)-\(scheme): \(caret) contrast=\(caretContrast)\n", stderr)
                precondition(caretContrast >= 3, "Native caret remains readable on the paired surface")
                let opposite: ColorScheme = scheme == .dark ? .light : .dark
                state.theme = theme(opposite)
                await self.settle(host)
                precondition(editor.selectedRange() == selected && self.fields(host).first === field, "Hot theme changes preserve native selection/editor identity")
                state.theme = theme(scheme)
                await self.settle(host)
                precondition(editor.selectedRange() == selected && self.fields(host).first === field, "Rerender preserves native selection/editor identity")
                editor.string = "Нативный Ёжик"
                field.stringValue = editor.string
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                await self.settle(host)
                precondition(state.drafts["synthetic"] == "Нативный Ёжик", "Native edits update the existing draft binding")
                _ = window.makeFirstResponder(nil)
                precondition(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
            }
            for inheritedTintIsOpposed in [false, true] {
                try await self.verifyWholeSheet(state: state, name: name, theme: theme, inheritedTintIsOpposed: inheritedTintIsOpposed, directory: directory)
            }
            try await self.verifyProviderComparison(state: state, name: name, directory: directory)
        }
        print("Whole production sheet: 24 hidden non-key appearance/selection cases, outside custom theme + brand/opposed tint; inactive selection >=3, caret >=3, draft/editor retention; active physical selection >=4.5 remains SKIP")
        print("Provider comparison: actual rounded-border fields in FluidManagementSheet follow the portable native scheme under both opposing window appearances; no offscreen provider mismatch reproduced")
        print("Participant input: \(checks) source-bound typed/empty, enabled/disabled, hot dark/light/dark checks across three brands and a validated inverted palette; native editor, caret and inactive selection retained")
        print("SKIP: exact frozen application sheet, physical focus/selection and native screenshots remain parent-owned acceptance gates")
    }
}
