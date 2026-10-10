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
    @MainActor static func main() {
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
            BrandAppearanceController.refreshApplicationMenu(main, appName: name, language: .english)
            precondition(applicationItem.title == name && application.title == name)
            let icon = NSImage(size: NSSize(width: 16, height: 16))
            let options = BrandAppearanceController.aboutPanelOptions(appName: name, icon: icon)
            precondition(options[.applicationName] as? String == name)
            precondition(options[.applicationIcon] as? NSImage === icon)
            precondition(Set(options.keys) == [.applicationName, .applicationIcon], "About options must not override bundle version or legal credits")
            precondition(about.title == "About " + name && hide.title == "Hide " + name && quit.title == "Quit " + name)
            precondition(hideOthers.title == "Hide Others" && settings.title == "Settings")
            precondition(fileItem.title == "File" && file.title == "File")
            precondition(recentItem.title == "Recent Documents" && recent.title == "Recent Documents")
            precondition(document.title == "File Settings Old Brand %lld draft.txt")
            precondition(nestedAbout.title == "About File Template")
            precondition(nestedApplicationItem.title == "File Settings reference" && nestedDocument.title == "Settings File user note")
        }
        BrandAppearanceController.refreshApplicationMenu(nil, appName: "No Menu", language: .english)
        print("Owned native application actions update; standard menus and user labels stay unchanged")
    }
}
