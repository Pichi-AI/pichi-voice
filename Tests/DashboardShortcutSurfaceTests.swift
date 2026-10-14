import AppKit
import SwiftUI

// These are source-bound fragments rendered offscreen. No persistent settings,
// shortcut registration, navigation service, model or input is initialized.
enum DashboardShortcutSurfaceTests {
    enum Destination { case customDictionary, cleanupStyles }
    struct Shortcut { let displayString: String }
    struct Settings {
        let primaryDictationShortcuts: [Shortcut]
        var primaryDictationShortcutDisplayString: String {
            self.primaryDictationShortcuts.map(\.displayString).joined(separator: ", ")
        }
    }
    @MainActor final class Observations {
        struct Item {
            var roles = [ButtonRole?]()
            var enabled = [Bool]()
            var trigger: (() -> Void)?
        }
        var items = [String: Item]()
    }
    @MainActor final class State: ObservableObject {
        let settings: Settings
        let busy: Bool
        let observations = Observations()
        var destination: Destination?
        var shortcutActivations = 0
        init(busy: Bool, shortcuts: [String] = ["⌃⌥⇧⌘\nЁё", "F13"]) {
            self.busy = busy
            self.settings = Settings(primaryDictationShortcuts: shortcuts.map(Shortcut.init))
        }
    }
    struct InspectionStyle: PrimitiveButtonStyle {
        let observations: Observations
        let identity: String
        @Environment(\.isEnabled) private var isEnabled
        func makeBody(configuration: Configuration) -> some View {
            var item = self.observations.items[self.identity] ?? Observations.Item()
            item.roles.append(configuration.role)
            item.enabled.append(self.isEnabled)
            item.trigger = configuration.trigger
            self.observations.items[self.identity] = item
            return configuration.label.padding(4).background(.yellow)
        }
    }

    private struct Raster {
        let image: CGImage
        let bytes: [UInt8]
        let scale = 2
        func count(ink: Color, rect: CGRect) -> Int {
            let expected = UIContrastTests.components(ink)
            var count = 0
            for y in max(0, Int(rect.minY) * self.scale)..<min(self.image.height, Int(rect.maxY) * self.scale) {
                for x in max(0, Int(rect.minX) * self.scale)..<min(self.image.width, Int(rect.maxX) * self.scale) {
                    let offset = (y * self.image.width + x) * 4
                    if self.bytes[offset + 3] == 255 && (0..<3).allSatisfy({
                        abs(Double(self.bytes[offset + $0]) / 255 - expected[$0]) < 0.025
                    }) { count += 1 }
                }
            }
            return count
        }
        func surface(at point: CGPoint, expected: Color, name: String) {
            let offset = (Int(point.y) * self.scale * self.image.width + Int(point.x) * self.scale) * 4
            let values = UIContrastTests.components(expected)
            precondition(self.bytes[offset + 3] == 255, "\(name): opaque production surface")
            precondition((0..<3).allSatisfy {
                abs(Double(self.bytes[offset + $0]) / 255 - values[$0]) < 0.025
            }, "\(name): production surface must pair with its validated ink")
        }
    }

    @MainActor private static func render(_ view: some View, theme: AppTheme, scheme: ColorScheme,
                                         name: String, directory: URL) throws -> Raster {
        let renderer = ImageRenderer(content: view.appTheme(theme).environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage else {
            preconditionFailure("\(name): source-bound Dashboard fragment failed to rasterize")
        }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Raster(image: image, bytes: bytes)
    }

    @MainActor private static func key(theme: AppTheme, scheme: ColorScheme, busy: Bool,
                                      name: String, directory: URL) throws {
        let state = State(busy: busy)
        let raster = try self.render(ProductionDashboardKeyFixture(state: state, horizontal: false),
                                     theme: theme, scheme: scheme, name: name, directory: directory)
        precondition(raster.image.width == 252 && raster.image.height == 128, "Actual keycap remains 126x64 points")
        let surface = theme.palette.elevatedCardBackground
        let ink = busy ? theme.palette.secondaryText : theme.palette.primaryText
        precondition(UIContrastTests.contrast(UIContrastTests.components(ink), UIContrastTests.components(surface)) >= (busy ? 3 : 4.5))
        raster.surface(at: CGPoint(x: 7, y: 32), expected: surface, name: name)
        // Inset glyph regions exclude the outline and horizontal style padding.
        // Explicit two-line synthetic user data proves both lines are rendered.
        for rect in [CGRect(x: 16, y: 10, width: 94, height: 22), CGRect(x: 16, y: 32, width: 94, height: 22)] {
            precondition(raster.count(ink: ink, rect: rect) >= 12, "\(name): actual key glyph line must be visible without counting the border")
        }
        precondition(state.settings.primaryDictationShortcuts[0].displayString == "⌃⌥⇧⌘\nЁё")
        precondition(state.shortcutActivations == 0 && state.destination == nil, "Rendering cannot activate actions")
    }

    @MainActor private static func panel(theme: AppTheme, scheme: ColorScheme, busy: Bool, horizontal: Bool,
                                        shortcuts: [String]? = nil, name: String, directory: URL) throws {
        let state = shortcuts.map { State(busy: busy, shortcuts: $0) } ?? State(busy: busy)
        let width: CGFloat = horizontal ? 680 : 300
        let raster = try self.render(ProductionDashboardShortcutsFixture(state: state, horizontal: horizontal).frame(width: width),
                                     theme: theme, scheme: scheme, name: name, directory: directory)
        precondition(raster.image.width == Int(width * 2))
        precondition(raster.image.height > 150 && raster.image.height < 1100, "Full production card stays bounded")
        raster.surface(at: CGPoint(x: width / 2, y: 8), expected: theme.palette.cardBackground, name: name)
        precondition(state.shortcutActivations == 0 && state.destination == nil)
    }

    @MainActor private static func construction(theme: AppTheme, scheme: ColorScheme, directory: URL) throws -> Int {
        var checks = 0
        for busy in [false, true] {
            for horizontal in [false, true] {
                for empty in [false, true] {
                    let state = State(busy: busy, shortcuts: empty ? [] : ["⌃⌥⇧⌘ Ёё", "F13"])
                    _ = try self.render(ProductionDashboardConstructionFixture(state: state, horizontal: horizontal)
                        .frame(width: horizontal ? 680 : 300), theme: theme, scheme: scheme,
                        name: "dashboard-construction-\(busy)-\(horizontal)-\(empty)", directory: directory)
                    let expected = empty ? ["Vocabulary", "Writing style"] : ["key", "change", "Vocabulary", "Writing style"]
                    precondition(Set(state.observations.items.keys) == Set(expected), "Empty shortcuts hide only the shortcut column")
                    for identity in expected {
                        let item = state.observations.items[identity]!
                        precondition(!item.roles.isEmpty && item.roles.allSatisfy { $0 == nil }, "Actual Dashboard Button retains ordinary role")
                        precondition(!item.enabled.isEmpty && item.enabled.allSatisfy { $0 == !busy }, "Busy disables actual inherited Button environment")
                        precondition(item.trigger != nil)
                        checks += 1
                    }
                    precondition(state.shortcutActivations == 0 && state.destination == nil)
                    if !busy {
                        for identity in expected {
                            let before = state.shortcutActivations
                            state.observations.items[identity]!.trigger?()
                            switch identity {
                            case "key", "change": precondition(state.shortcutActivations == before + 1)
                            case "Vocabulary": precondition(state.destination == .customDictionary)
                            case "Writing style": precondition(state.destination == .cleanupStyles)
                            default: preconditionFailure("Unexpected construction identity")
                            }
                        }
                    }
                }
            }
        }
        return checks
    }

    private static func synthetic(background: String, primary: String, secondary: String, accent: String) throws -> BrandPackage {
        let surfaces: Set<String> = ["windowBackground", "contentBackground", "sidebarBackground", "cardBackground", "elevatedCardBackground", "toolbarBackground"]
        var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, surfaces.contains($0) ? background : primary) })
        colors["secondaryText"] = secondary
        colors["tertiaryText"] = secondary
        // White on white is a legacy saved accent, not an importable package.
        // Validate an ordinary package, then exercise that saved accent through
        // the real AppTheme.adaptive override at the call site.
        let packageAccent = accent == "#FFFFFF" && background == "#FFFFFF" ? "#000000" : accent
        colors["accentForeground"] = UIContrastTests.contrast(UIContrastTests.components(Color(hex: packageAccent)!), [0, 0, 0]) >= 4.5 ? "#000000" : "#FFFFFF"
        let profile = BrandProfile(appName: "Synthetic", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic fixture",
            accentLight: packageAccent, accentDark: packageAccent, website: "https://example.invalid", support: "https://example.invalid")
        let palette = BrandPalette(colors: colors)
        return try BrandPackage.decode(BrandPackage(profile: profile, theme: BrandTheme(light: palette, dark: palette)).encoded())
    }

    @MainActor private static func row(theme: AppTheme, scheme: ColorScheme, enabled: Bool,
                                        name: String, directory: URL) throws {
        let raster = try self.render(ProductionDashboardRowFixture(title: "Visible Ёё title", detail: "Visible Ёё detail", icon: "text.book.closed", action: {})
            .disabled(!enabled).frame(width: 300).background(theme.palette.cardBackground),
            theme: theme, scheme: scheme, name: name, directory: directory)
        let surface = theme.palette.elevatedCardBackground
        raster.surface(at: CGPoint(x: 150, y: 8), expected: surface, name: name)
        let height = CGFloat(raster.image.height) / 2
        // Title/detail have distinct marginal inks. Exclude row outline, icon
        // and chevron so one cannot stand in for a missing text label.
        let title = CGRect(x: 46, y: 12, width: 225, height: height / 2 - 12)
        let detail = CGRect(x: 46, y: height / 2, width: 225, height: height / 2 - 12)
        let titleInk = enabled ? theme.palette.primaryText : theme.palette.secondaryText
        precondition(UIContrastTests.contrast(UIContrastTests.components(titleInk), UIContrastTests.components(surface)) >= (enabled ? 4.5 : 3))
        precondition(UIContrastTests.contrast(UIContrastTests.components(theme.palette.secondaryText), UIContrastTests.components(surface)) >= 3)
        let titlePixels = raster.count(ink: titleInk, rect: title)
        let detailPixels = raster.count(ink: theme.palette.secondaryText, rect: detail)
        print("\(name): title \(titlePixels) pixels, detail \(detailPixels) pixels in disjoint regions")
        precondition(titlePixels >= 12, "\(name): title must render without counting detail, icon or outline")
        precondition(detailPixels >= 12, "\(name): detail must render without counting antialiased title, icon or outline")
        precondition(raster.count(ink: theme.palette.secondaryText, rect: CGRect(x: 12, y: 12, width: 23, height: height - 24)) >= 8,
                     "\(name): icon must render independently of text and outline")
    }

    @MainActor static func run(directory: URL) async throws {
        var rasterChecks = 0
        let stock = [("pichi", "Sources/Fluid/Branding/brand-package.json"), ("sber", "Configuration/BrandExamples/sber-demo.json"), ("alfa", "Configuration/BrandExamples/alfa-demo.json")]
        for (name, path) in stock {
            let package = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            for scheme: ColorScheme in [.light, .dark] {
                let accent = Color(hex: scheme == .light ? package.profile.accentLight : package.profile.accentDark)!
                let theme = AppTheme.adaptive(accent: accent, colorScheme: scheme, package: package)
                for busy in [false, true] {
                    let suffix = "\(name)-\(scheme == .light ? "light" : "dark")-\(busy ? "busy" : "idle")"
                    try self.key(theme: theme, scheme: scheme, busy: busy, name: "dashboard-key-\(suffix)", directory: directory)
                    for horizontal in [false, true] {
                        try self.panel(theme: theme, scheme: scheme, busy: busy, horizontal: horizontal,
                            name: "dashboard-panel-\(suffix)-\(horizontal ? "horizontal" : "vertical")", directory: directory)
                    }
                    rasterChecks += 3
                }
            }
        }
        for (name, background, primary, accent) in [("white-accent", "#FFFFFF", "#000000", "#FFFFFF"),
            ("gray-accent", "#FFFFFF", "#000000", "#949494"), ("opposite-inks", "#606060", "#FFFFFF", "#000000"),
            ("inverted", "#000000", "#FFFFFF", "#FFFFFF")] {
            let package = try self.synthetic(background: background, primary: primary, secondary: primary, accent: accent)
            for scheme: ColorScheme in [.light, .dark] {
                let theme = AppTheme.adaptive(accent: Color(hex: accent)!, colorScheme: scheme, package: package)
                for busy in [false, true] {
                    let suffix = "\(name)-\(scheme == .light ? "light" : "dark")-\(busy ? "busy" : "idle")"
                    try self.key(theme: theme, scheme: scheme, busy: busy, name: "dashboard-key-\(suffix)", directory: directory)
                    try self.panel(theme: theme, scheme: scheme, busy: busy, horizontal: busy,
                        name: "dashboard-panel-\(suffix)", directory: directory)
                    rasterChecks += 2
                }
            }
        }
        let pichi = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: stock[0].1)))
        for design in BrandStyle.FontDesign.allCases {
            var package = pichi
            package.style = BrandStyle(bodyFontDesign: design, titleFontDesign: design)
            for scheme: ColorScheme in [.light, .dark] {
                let theme = AppTheme.adaptive(accent: Color(hex: package.profile.accentLight)!, colorScheme: scheme, package: package)
                try self.panel(theme: theme, scheme: scheme, busy: false, horizontal: design == .rounded,
                    name: "dashboard-card-font-\(design.rawValue)-\(scheme == .light ? "light" : "dark")", directory: directory)
                rasterChecks += 1
            }
        }
        let marginal = try self.synthetic(background: "#FFFFFF", primary: "#767676", secondary: "#949494", accent: "#000000")
        for scheme: ColorScheme in [.light, .dark] {
            let theme = AppTheme.adaptive(accent: .black, colorScheme: scheme, package: marginal)
            for enabled in [true, false] {
                try self.row(theme: theme, scheme: scheme, enabled: enabled,
                    name: "dashboard-marginal-row-\(scheme == .light ? "light" : "dark")-\(enabled)", directory: directory)
                rasterChecks += 1
            }
        }
        let theme = AppTheme.adaptive(accent: Color(hex: pichi.profile.accentLight)!, colorScheme: .light, package: pichi)
        for horizontal in [true, false] {
            try self.panel(theme: theme, scheme: .light, busy: false, horizontal: horizontal, shortcuts: [],
                name: "dashboard-empty-shortcuts-\(horizontal)", directory: directory)
            rasterChecks += 1
        }
        let constructionChecks = try self.construction(theme: theme, scheme: .light, directory: directory)
        print("Dashboard source-bound surfaces: \(rasterChecks) rendering checks passed; \(constructionChecks) role/enabled checks and 12 enabled trigger-forwarding checks passed")
        print("SKIP: Dashboard native glass container effects, physical hover/input, AX activation and translated RU/EN app copy require parent frozen-app screenshots. Card typography roles cover three designs; keycap global-brand font variants are not overridden.")
    }
}

private struct DashboardObservationsKey: EnvironmentKey {
    static var defaultValue: DashboardShortcutSurfaceTests.Observations? { nil }
}
extension EnvironmentValues {
    var dashboardObservations: DashboardShortcutSurfaceTests.Observations? {
        get { self[DashboardObservationsKey.self] }
        set { self[DashboardObservationsKey.self] = newValue }
    }
}

// The source-extracted captions use their actual unmodified shared font call.
// Compiled String Catalogs and volatile process language drive both localization
// paths: explicit PichiLocalization lookup and SwiftUI Text's locale lookup.
enum OverlaySliderCaptionTests {
    private static func pixels(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
    @MainActor private static func render(_ view: some View, theme: AppTheme, locale: Locale,
                                         name: String, directory: URL) throws -> CGImage {
        let renderer = ImageRenderer(content: view.appTheme(theme).environment(\.locale, locale)
            .background(theme.palette.cardBackground))
        renderer.scale = 2
        guard let image = renderer.cgImage else { preconditionFailure("Caption renderer must produce an image") }
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        return image
    }

    @MainActor static func run(directory: URL) async throws {
        precondition(Set(Bundle.main.localizations).isSuperset(of: ["en", "ru"]), "Use the actual compiled RU/EN catalog")
        let legacy = CommandLine.arguments.contains("--overlay-captions-legacy-negative")
        precondition(!legacy || ProductionOverlayCaptionMetadata.legacyAvailable,
                     "Compile the explicit historical negative with PICHI_OVERLAY_CAPTION_LEGACY_REVISION")
        let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let package = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: "Sources/Fluid/Branding/brand-package.json")))
        precondition(AppBrand.package.style == package.style, "Read back the actual production-default brand style")
        let captionDesign = AppBrand.package.style?.bodyFontDesign?.rawValue ?? "system-default"
        var checks = 0
        var report = [[String: Any]]()
        for language in ["ru", "en"] {
            var domain = previous
            domain[PichiInterfaceLanguage.defaultsKey] = language
            UserDefaults.standard.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            precondition(PichiLocalization.language.rawValue == language, "Process language must drive actual explicit catalog calls")
            let locale = Locale(identifier: language)
            let strings = ProductionOverlayCaptionMetadata.expected[language]!
            precondition(PichiLocalization.text("scale.more", defaultValue: "More") == strings[0])
            precondition(PichiLocalization.text("Less") == strings[1])
            for scheme: ColorScheme in [.light, .dark] {
                let theme = AppTheme.adaptive(accent: .purple, colorScheme: scheme, package: package)
                for index in 0..<4 {
                    let suffix = "\(legacy ? "legacy" : "current")-\(language)-\(scheme == .light ? "light" : "dark")-\(index)"
                    let natural = try self.render(Text(verbatim: strings[index]).font(.fluidSystem(.caption))
                        .foregroundStyle(theme.palette.primaryText).fixedSize(), theme: theme, locale: locale,
                        name: "overlay-caption-natural-\(suffix)", directory: directory)
                    let image = try self.render(ProductionOverlayCaptionFixture(index: index, legacy: legacy),
                        theme: theme, locale: locale, name: "overlay-caption-\(suffix)", directory: directory)
                    let expectedWidth = max(72, natural.width)
                    let naturalHeight = natural.height
                    let geometryFits = abs(image.width - expectedWidth) <= 1 && abs(image.height - naturalHeight) <= 1
                    let row: [String: Any] = ["language": language, "scheme": scheme == .light ? "light" : "dark",
                        "index": index, "text": strings[index], "widthPixels": image.width,
                        "heightPixels": image.height, "naturalWidthPixels": natural.width,
                        "naturalHeightPixels": natural.height, "fullWordSingleLine": geometryFits,
                        "actualGlobalCaptionBodyFontDesign": captionDesign, "captionFontWeight": "regular"]
                    report.append(row)
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: directory.appendingPathComponent("overlay-caption-\(legacy ? "legacy-negative" : "current")-results.json"))
                    // This fails from the actual legacy raster's constrained
                    // width/wrapped height. No source-property guard fakes it.
                    precondition(geometryFits, "\(suffix): complete localized word must keep natural width and single-line height; actual \(image.width)x\(image.height), natural \(natural.width)x\(natural.height)")
                    // A verbatim reference from the real compiled catalog must
                    // render identically. This observes SwiftUI Text("Less")'s
                    // actual localization as well as explicit More lookup.
                    let expected = try self.render(Text(verbatim: strings[index]).font(.fluidSystem(.caption))
                        .foregroundStyle(theme.palette.primaryText).lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 36, alignment: index == 0 || index == 2 ? .trailing : .leading),
                        theme: theme, locale: locale, name: "overlay-caption-expected-\(suffix)", directory: directory)
                    let bytes = self.pixels(image)
                    // CoreGraphics can round an individual channel by one 8-bit
                    // level between equivalent render trees. Keep every pixel
                    // in place and require its full glyph shape within that
                    // quantization bound, with no spatial/content tolerance.
                    let expectedBytes = self.pixels(expected)
                    precondition(image.width == expected.width && image.height == expected.height &&
                                 zip(bytes, expectedBytes).allSatisfy({ abs(Int($0) - Int($1)) <= 1 }),
                                 "Actual explicit/SwiftUI localized caption must match the complete catalog word")
                    let expectedInk = UIContrastTests.components(theme.palette.primaryText)
                    var glyphPixels = 0
                    for offset in stride(from: 0, to: bytes.count, by: 4) {
                        if bytes[offset + 3] == 255 && (0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - expectedInk[$0]) < 0.025 }) {
                            glyphPixels += 1
                        }
                    }
                    precondition(glyphPixels >= 12, "Actual localized caption glyphs must render")
                    checks += 1
                }
            }
        }
        print("Overlay slider captions: \(checks) actual source-bound RU/EN Light/Dark natural-width/single-line/glyph checks passed; actual global shared caption font unchanged")
        print("SKIP: other global brand font designs and the native 800-point Overlay viewport require parent frozen-app screenshots. No slider input or bindings are executed.")
    }
}
