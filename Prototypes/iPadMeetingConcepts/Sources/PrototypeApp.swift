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
    var replayTime: TimeInterval?

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
            case "--replay-time": replayTime = Double(value)
            default: break
            }
            index += 2
        }
        if let path = Bundle.main.path(forResource: language, ofType: "lproj"), let bundle = Bundle(path: path) {
            Copy.bundle = bundle
        }
        // Only the design process: the unchanged production renderer uses this UI preference.
        // A volatile domain makes --language explicit without persisting app settings.
        UserDefaults.standard.setVolatileDomain([PichiInterfaceLanguage.defaultsKey: language], forName: UserDefaults.argumentDomain)
    }
}

#if os(macOS)
import AppKit

/// Native preview controls stay outside the simulated device canvas.
/// One stable root preserves meeting/navigation state while its logical size changes.
@MainActor
final class PrototypeWindowPreview: NSObject, ObservableObject, NSToolbarDelegate, NSWindowDelegate {
    @Published private(set) var canvasSize: CGSize
    private weak var window: NSWindow?
    private let landscapeSize: CGSize
    private static let rotateItem = NSToolbarItem.Identifier("prototype.rotate")

    init(size: CGSize) {
        canvasSize = size
        landscapeSize = CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
        super.init()
    }

    func attach(to window: NSWindow) {
        self.window = window
        window.delegate = self
        let toolbar = NSToolbar(identifier: "prototype.preview")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        let menu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: PrototypeBrand.shared.profile.appName)
        let quit = NSMenuItem(title: Copy.text("preview_quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        applicationMenu.addItem(quit)
        applicationItem.submenu = applicationMenu
        menu.addItem(applicationItem)
        let orientationItem = NSMenuItem()
        let orientationMenu = NSMenu(title: Copy.text("preview_orientation"))
        for (key, action, shortcut) in [("preview_landscape", #selector(landscape(_:)), ""),
                                       ("preview_portrait", #selector(portrait(_:)), ""),
                                       ("preview_rotate", #selector(rotate(_:)), "r")] {
            let item = NSMenuItem(title: Copy.text(key), action: action, keyEquivalent: shortcut)
            item.target = self
            orientationMenu.addItem(item)
        }
        orientationItem.submenu = orientationMenu
        menu.addItem(orientationItem)
        NSApp.mainMenu = menu
        fitWindow()
    }

    @objc private func rotate(_ sender: Any?) {
        canvasSize = CGSize(width: canvasSize.height, height: canvasSize.width)
        fitWindow()
    }

    @objc private func landscape(_ sender: Any?) {
        canvasSize = landscapeSize
        fitWindow()
    }

    @objc private func portrait(_ sender: Any?) {
        canvasSize = CGSize(width: landscapeSize.height, height: landscapeSize.width)
        fitWindow()
    }

    private func fitWindow() {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let available = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        let chromeHeight = window.frame.height - window.contentLayoutRect.height
        let scale = max(0.1, min(1, available.width / canvasSize.width,
                                (available.height - chromeHeight) / canvasSize.height))
        window.setContentSize(NSSize(width: canvasSize.width * scale, height: canvasSize.height * scale))
        window.subtitle = "\(Int(canvasSize.width)) × \(Int(canvasSize.height))"
        window.center()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.rotateItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == Self.rotateItem else { return nil }
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = Copy.text("preview_rotate")
        item.toolTip = Copy.text("preview_orientation")
        item.image = NSImage(systemSymbolName: "rotate.right", accessibilityDescription: item.label)
        item.target = self
        item.action = #selector(rotate(_:))
        return item
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

private struct PrototypeNativeCanvas: View {
    let options: PrototypeOptions
    @ObservedObject var preview: PrototypeWindowPreview

    var body: some View {
        GeometryReader { geometry in
            let size = preview.canvasSize
            let scale = min(1, geometry.size.width / size.width, geometry.size.height / size.height)
            PrototypeRoot(options: options)
                .frame(width: size.width, height: size.height)
                .scaleEffect(scale)
                .frame(width: size.width * scale, height: size.height * scale)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(PrototypeTheme(dark: options.dark).color("windowBackground"))
        .environment(\.locale, Locale(identifier: options.language))
        .environment(\.colorScheme, options.dark ? .dark : .light)
    }
}

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
        let preview = PrototypeWindowPreview(size: CGSize(width: options.width, height: options.height))
        window.contentView = NSHostingView(rootView: PrototypeNativeCanvas(options: options, preview: preview))
        preview.attach(to: window)
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
