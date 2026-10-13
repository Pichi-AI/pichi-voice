import SwiftUI

struct PrototypeOptions {
    var layout = "A"
    var screen: PrototypeScreen = .active
    var width: CGFloat = 1194
    var height: CGFloat = 834
    var dark = false
    var language = "ru"
    var exportPath: String?
    var saveAudio = true

    init(arguments: [String] = CommandLine.arguments) {
        // Frozen native preview bundles can carry a scenario without a shell launch.
        // Explicit CLI arguments still take priority. This is design-only configuration.
        let arguments: [String] = if arguments.count == 1,
            let url = Bundle.main.url(forResource: "preview-arguments", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let scenario = try? JSONDecoder().decode([String].self, from: data) {
            arguments + scenario
        } else {
            arguments
        }
        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            if flag == "--dark" { dark = true; index += 1; continue }
            if flag == "--audio-off" { saveAudio = false; index += 1; continue }
            guard index + 1 < arguments.count else { break }
            let value = arguments[index + 1]
            switch flag {
            case "--layout": layout = ["A", "B", "C"].contains(value.uppercased()) ? value.uppercased() : "A"
            case "--screen": screen = PrototypeScreen(rawValue: value) ?? .active
            case "--width": width = max(320, CGFloat(Double(value) ?? 1194))
            case "--height": height = max(500, CGFloat(Double(value) ?? 834))
            case "--language": language = value
            case "--export": exportPath = value
            default: break
            }
            index += 2
        }
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
            Copy.bundle = bundle
        }
    }
}

#if os(macOS)
import AppKit

@main
struct PrototypeApp {
    @MainActor static func main() {
        let options = PrototypeOptions()
        let app = NSApplication.shared
        let view = PrototypeRoot(options: options)
            .frame(width: options.width, height: options.height)
            .environment(\.locale, Locale(identifier: options.language))
            .environment(\.colorScheme, options.dark ? .dark : .light)

        if let exportPath = options.exportPath {
            // Offscreen view render: useful for concept comparison, not a device screenshot.
            // ImageRenderer omits AppKit-backed scroll views. Attach the hosting view to
            // an offscreen native window and cache its complete view tree instead.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: options.width, height: options.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
            let hosting = NSHostingView(rootView: view)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.15))
            hosting.layoutSubtreeIfNeeded()
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(options.width * 2),
                                          pixelsHigh: Int(options.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                          hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                          bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: options.width, height: options.height)
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: exportPath))
            return
        }

        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: options.dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: options.width, height: options.height),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "\(PrototypeBrand.shared.profile.appName) | \(Copy.text("prototype")) \(options.layout)"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
#else
@main
struct PrototypeApp: App {
    private let options = PrototypeOptions()
    var body: some Scene {
        WindowGroup {
            PrototypeRoot(options: options)
                .environment(\.locale, Locale(identifier: options.language))
                .preferredColorScheme(options.dark ? .dark : .light)
        }
    }
}
#endif
