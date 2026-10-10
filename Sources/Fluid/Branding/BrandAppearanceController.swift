import AppKit
import Combine

/// Refresh owned shell surfaces. Native commands and user document labels remain data.
@MainActor
enum BrandAppearanceController {
    static func apply() {
        self.refreshApplicationMenu(NSApplication.shared.mainMenu, appName: AppBrand.appName, language: PichiLocalization.language)
        // SwiftUI owns its WindowGroup title; MenuBarManager refreshes its own hosted window
        // through appearanceChanged. Never infer window ownership from a user-visible title.
        NSApplication.shared.applicationIconImage = PichiBrandMark.appIcon
        SettingsStore.shared.objectWillChange.send()
        NotificationCenter.default.post(name: AppBrand.appearanceChanged, object: nil)
    }

    /// Override only the visual identity; AppKit retains bundle version and legal credits.
    static func aboutPanelOptions(appName: String, icon: NSImage) -> [NSApplication.AboutPanelOptionKey: Any] {
        [.applicationName: appName, .applicationIcon: icon]
    }

    static func refreshApplicationMenu(_ mainMenu: NSMenu?, appName: String, language: PichiInterfaceLanguage, bundle: Bundle = .main) {
        guard let applicationItem = mainMenu?.items.first, let applicationMenu = applicationItem.submenu else { return }
        applicationItem.title = appName
        applicationMenu.title = appName
        for item in applicationMenu.items {
            let template: String
            switch item.action {
            case #selector(NSApplication.orderFrontStandardAboutPanel(_:)):
                template = "application.about"
            case #selector(NSApplication.hide(_:)):
                template = "Hide %@"
            case #selector(NSApplication.terminate(_:)):
                template = "Quit %@"
            default:
                continue
            }
            item.title = PichiLocalization.format(template, language: language, bundle: bundle, arguments: [appName])
        }
    }
}
