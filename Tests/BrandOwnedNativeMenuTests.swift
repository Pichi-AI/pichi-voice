import AppKit
import Combine
import Foundation

// Only controller dependencies are stubbed. Native NSMenu/NSMenuItem and localization are real.
@MainActor final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
}
@MainActor enum PichiBrandMark {
    static var appIcon: NSImage { NSImage(size: NSSize(width: 16, height: 16)) }
}

@main
struct BrandOwnedNativeMenuTests {
    @MainActor static func main() throws {
        let fixtureURL = try self.localizationFixture()
        defer { try? FileManager.default.removeItem(at: fixtureURL) }
        guard let bundle = Bundle(url: fixtureURL) else { fatalError("Localization fixture bundle did not load") }
        let main = NSMenu(title: "Main")
        let applicationItem = NSMenuItem(title: "Old Brand", action: nil, keyEquivalent: "")
        let application = NSMenu(title: "Old Brand")
        applicationItem.submenu = application
        main.addItem(applicationItem)
        let about = NSMenuItem(title: "About Old Brand", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let hide = NSMenuItem(title: "Hide Old Brand", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quit = NSMenuItem(title: "Quit Old Brand", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "")
        let settings = NSMenuItem(title: "Settings", action: NSSelectorFromString("openSettings:"), keyEquivalent: ",")
        for item in [about, hide, hideOthers, settings, quit] { application.addItem(item) }
        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let file = NSMenu(title: "File")
        fileItem.submenu = file
        main.addItem(fileItem)
        let recentItem = NSMenuItem(title: "Recent Documents", action: nil, keyEquivalent: "")
        let recent = NSMenu(title: "Recent Documents")
        recentItem.submenu = recent
        file.addItem(recentItem)
        let document = NSMenuItem(title: "File Settings Old Brand %lld draft.txt", action: NSSelectorFromString("openRecentDocument:"), keyEquivalent: "")
        recent.addItem(document)
        // A nested menu's labels are not owned application commands, even if their selector matches.
        let nestedAbout = NSMenuItem(title: "About File Template", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        recent.addItem(nestedAbout)
        let nestedApplicationItem = NSMenuItem(title: "File Settings reference", action: nil, keyEquivalent: "")
        nestedApplicationItem.submenu = NSMenu(title: "File Settings reference")
        let nestedDocument = NSMenuItem(title: "Settings File user note", action: NSSelectorFromString("openRecentDocument:"), keyEquivalent: "")
        nestedApplicationItem.submenu?.addItem(nestedDocument)
        application.addItem(nestedApplicationItem)

        for name in ["File", "Settings", "%@", "%lld", "100%@ Voice", "Сбер Голос"] {
            BrandAppearanceController.refreshApplicationMenu(main, appName: name, language: .english, bundle: bundle)
            precondition(applicationItem.title == name && application.title == name)
            let icon = NSImage(size: NSSize(width: 16, height: 16))
            icon.accessibilityDescription = "Installed distribution icon"
            let options = BrandAppearanceController.aboutPanelOptions(appName: name, icon: icon)
            precondition(options[.applicationName] as? String == name)
            guard let displayedIcon = options[.applicationIcon] as? NSImage else { fatalError("About icon is missing") }
            precondition(displayedIcon !== icon && displayedIcon.size == icon.size)
            precondition(displayedIcon.accessibilityDescription == name, "About icon accessibility copy must use the active brand as verbatim data")
            precondition(icon.accessibilityDescription == "Installed distribution icon", "About must not mutate a cached or caller-owned image")
            precondition(Set(options.keys) == [.applicationName, .applicationIcon], "About options must not override bundle version or legal credits")
            precondition(about.title == "About " + name && hide.title == "Hide " + name && quit.title == "Quit " + name)
            precondition(hideOthers.title == "Hide Others" && settings.title == "Settings")
            precondition(fileItem.title == "File" && file.title == "File")
            precondition(recentItem.title == "Recent Documents" && recent.title == "Recent Documents")
            precondition(document.title == "File Settings Old Brand %lld draft.txt")
            precondition(nestedAbout.title == "About File Template")
            precondition(nestedApplicationItem.title == "File Settings reference" && nestedDocument.title == "Settings File user note")
            BrandAppearanceController.refreshApplicationMenu(main, appName: name, language: .russian, bundle: bundle)
            precondition(about.title == "О приложении " + name, "Application About must not use model-tooltip copy")
            precondition(hide.title == "Скрыть " + name && quit.title == "Завершить " + name)
            precondition(applicationItem.title == name && application.title == name)
            precondition(nestedAbout.title == "About File Template" && document.title == "File Settings Old Brand %lld draft.txt")
            precondition(PichiLocalization.format("About %@", language: .russian, bundle: bundle, arguments: [name]) == "О модели " + name,
                         "The model showcase About context must remain unchanged")
        }
        precondition(BrandAppearanceController.nativeAppearance(for: .light)?.name == .aqua)
        precondition(BrandAppearanceController.nativeAppearance(for: .dark)?.name == .darkAqua)
        precondition(BrandAppearanceController.nativeAppearance(for: nil) == nil, "System appearance must remain unset so later OS theme changes propagate")
        BrandAppearanceController.refreshApplicationMenu(nil, appName: "No Menu", language: .english)
        print("Owned EN/RU commands and icon descriptions update without changing user labels or cached artwork; native theme mapping restores System")
    }

    /// Compile-free fixture resources come from the actual catalog, never duplicate translations in test code.
    private static func localizationFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("BrandAboutContext-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let catalogURL = URL(fileURLWithPath: "Sources/Fluid/Localization/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
        let entries = catalog["strings"] as! [String: [String: Any]]
        for language in ["en", "ru"] {
            let resourceDirectory = directory.appendingPathComponent("\(language).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: resourceDirectory, withIntermediateDirectories: true)
            var strings: [String: String] = [:]
            for key in ["application.about", "About %@", "Hide %@", "Quit %@"] {
                let localizations = entries[key]!["localizations"] as! [String: [String: Any]]
                let unit = localizations[language]!["stringUnit"] as! [String: String]
                strings[key] = unit["value"]!
            }
            let data = try PropertyListSerialization.data(fromPropertyList: strings, format: .xml, options: 0)
            try data.write(to: resourceDirectory.appendingPathComponent("Localizable.strings"))
        }
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "ai.pichi.about.fixture", "CFBundleDevelopmentRegion": "en"], format: .xml, options: 0)
        try info.write(to: directory.appendingPathComponent("Info.plist"))
        return directory
    }
}
