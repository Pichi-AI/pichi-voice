import AppKit
import SwiftUI

/// Production-derived controls in a retained, nonvisible hosting view. This is
/// raster/lifecycle regression evidence, not a frozen application UI test.
enum NativeInkTransitionTests {
    @MainActor final class State: ObservableObject {
        @Published var theme: AppTheme
        @Published var query = ""
        init(theme: AppTheme) { self.theme = theme }
    }

    private struct Host: View {
        @ObservedObject var state: State
        let family: String
        let locale: Locale
        let period: StatsActivityPeriod
        @ViewBuilder private var component: some View {
            switch self.family {
            case "history": ProductionHistorySearchFixture(searchQuery: self.$state.query)
            case "files": ProductionFilesSearchFixture(searchQuery: self.$state.query)
            case "daily": ProductionDailyChartFixture(period: self.period)
            case "growth": ProductionGrowthChartFixture(period: self.period)
            case "rhythm": ProductionRhythmChartFixture(period: self.period)
            default: ProductionHoursChartFixture(period: self.period)
            }
        }
        var body: some View {
            self.component
                .frame(width: 400)
                .appTheme(self.state.theme)
                .environment(\.locale, self.locale)
                .background(self.state.theme.palette.cardBackground)
        }
    }

    private static func fields(_ view: NSView) -> [NSTextField] {
        if let field = view as? NSTextField { return [field] }
        return view.subviews.flatMap(self.fields)
    }

    @MainActor private static func settle(_ host: NSView) async {
        for _ in 0..<8 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor private static func raster(_ host: NSView, name: String, theme: AppTheme, directory: URL) throws -> (text: Int, bottom: Int, left: Int, grid: Int) {
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        let image = bitmap.cgImage!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let ink = UIContrastTests.components(theme.palette.secondaryText)
        let gridInk = UIContrastTests.components(theme.palette.cardBorder)
        let surface = UIContrastTests.components(theme.palette.cardBackground)
        // A one-pixel line can straddle two raster rows; accept its 50% coverage too.
        let antialiasedGrid = zip(gridInk, surface).map { ($0 + $1) / 2 }
        let scale = Double(image.width) / host.bounds.width
        var text = 0, bottom = 0, left = 0, grid = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = (y * image.width + x) * 4
                guard bytes[offset + 3] == 255 else { continue }
                if (0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - ink[$0]) < 0.04 }) {
                    if x > Int(35 * scale) { text += 1 }
                    if y > image.height - Int(16 * scale) && x > Int(40 * scale) { bottom += 1 }
                    if x < Int(28 * scale) { left += 1 }
                }
                if x > Int(45 * scale) && y > Int(20 * scale) && y < image.height - Int(25 * scale),
                   ((0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - gridInk[$0]) < 0.025 }) ||
                    (0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - antialiasedGrid[$0]) < 0.015 })) { grid += 1 }
            }
        }
        return (text, bottom, left, grid)
    }

    @MainActor static func run(directory: URL) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        var checks = 0
        for (brand, path) in [("pichi", "Sources/Fluid/Branding/brand-package.json"),
                              ("sber", "Configuration/BrandExamples/sber-demo.json"),
                              ("alfa", "Configuration/BrandExamples/alfa-demo.json")] {
            let package = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            func theme(_ scheme: ColorScheme) -> AppTheme {
                AppTheme.adaptive(accent: Color(hex: scheme == .dark ? package.profile.accentDark : package.profile.accentLight)!, colorScheme: scheme, package: package)
            }
            for language in ["en", "ru"] {
                let locale = Locale(identifier: language)
                var calendar = Calendar(identifier: .gregorian)
                calendar.locale = locale
                calendar.timeZone = TimeZone(secondsFromGMT: 0)!
                let start = Date(timeIntervalSince1970: 1_760_054_400)
                let period = StatsActivityPeriod(activity: (0..<30).map {
                    (calendar.date(byAdding: .day, value: $0, to: start)!, 10 + $0 * 3)
                }, calendar: calendar)
                for family in ["history", "files", "daily", "growth", "rhythm", "hours"] {
                    if CommandLine.arguments.contains("--native-ink-charts-only") && ["history", "files"].contains(family) { continue }
                    let state = State(theme: theme(.dark))
                    let host = NSHostingView(rootView: Host(state: state, family: family, locale: locale, period: period))
                    let search = family == "history" || family == "files"
                    let height: CGFloat = search ? (family == "history" ? 34 : 58) : (family == "daily" ? 124 : family == "hours" ? 140 : 150)
                    host.frame = NSRect(x: 0, y: 0, width: 400, height: height)
                    await self.settle(host)
                    let field = self.fields(host).first
                    if search { precondition(field != nil, "Actual native search field must materialize") }
                    for (step, scheme) in [ColorScheme.dark, .light, .dark].enumerated() {
                        NSApp.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        state.theme = theme(scheme)
                        await self.settle(host)
                        let name = "native-ink-\(brand)-\(language)-\(family)-\(step)-\(scheme)"
                        let pixels = try self.raster(host, name: name, theme: state.theme, directory: directory)
                        fputs("\(name): \(pixels)\n", stderr)
                        if search {
                            precondition(self.fields(host).first === field, "Theme updates must retain the native field")
                            precondition(UIContrastTests.contrast(UIContrastTests.components(state.theme.palette.secondaryText), UIContrastTests.components(state.theme.palette.cardBackground)) >= 3)
                            precondition(pixels.text >= 10, "\(name): placeholder ink is absent")
                            state.query = "Synthetic Ёё"
                            await self.settle(host)
                            precondition(field?.stringValue == "Synthetic Ёё", "Native editing binding survives theme changes")
                            field?.stringValue = "Native edit Ёё"
                            if let field {
                                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                            }
                            await self.settle(host)
                            precondition(state.query == "Native edit Ёё", "Native editor changes must still update the binding")
                            state.query = ""
                            await self.settle(host)
                            let cleared = try self.raster(host, name: name + "-cleared", theme: state.theme, directory: directory)
                            precondition(cleared.text >= 10, "\(name): cleared placeholder ink is absent")
                        } else {
                            precondition(pixels.bottom >= 15, "\(name): date/day/hour axis label ink is absent")
                            if family != "daily" {
                                precondition(pixels.left >= 15, "\(name): numeric axis label ink is absent")
                                precondition(pixels.grid >= 30, "\(name): grid ink is absent")
                            }
                        }
                        precondition(host.window == nil, "The regression never opens a window")
                        checks += 1
                    }
                }
            }
        }
        print("Native ink: \(checks) retained-view dark/light/dark checks across three brand packages, RU/EN, two production search fields and four production charts")
        print("SKIP: physical interaction and exact frozen-app appearance remain parent-owned native gates")
    }
}
