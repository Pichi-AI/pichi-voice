import AppKit
import Combine
import SwiftUI

/// Refresh owned shell surfaces. Native commands and user document labels remain data.
@MainActor
enum BrandAppearanceController {
    /// Logical System appearance comes from the application, independently of
    /// an owned window's physical appearance. Otherwise an inverted palette's
    /// window override can select the other palette on the next SwiftUI update.
    @MainActor final class ApplicationAppearance: ObservableObject {
        static let shared = ApplicationAppearance(application: .shared)
        @Published private(set) var colorScheme: ColorScheme
        private weak var application: NSApplication?
        private var observation: NSKeyValueObservation?

        init(application: NSApplication) {
            self.application = application
            self.colorScheme = Self.scheme(application.effectiveAppearance)
            self.observation = application.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.refresh() }
                } else {
                    Task { @MainActor [weak self] in self?.refresh() }
                }
            }
        }

        private static func scheme(_ appearance: NSAppearance) -> ColorScheme {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }

        private func refresh() {
            guard let application else { return }
            let scheme = Self.scheme(application.effectiveAppearance)
            if scheme != self.colorScheme { self.colorScheme = scheme }
        }
    }

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
        let displayedIcon = (icon.copy() as? NSImage) ?? icon
        displayedIcon.accessibilityDescription = appName
        return [.applicationName: appName, .applicationIcon: displayedIcon]
    }

    /// SwiftUI's color-scheme preference does not reach separately presented AppKit panels.
    /// A nil application appearance restores the system's live light/dark selection.
    static func nativeAppearance(for colorScheme: ColorScheme?) -> NSAppearance? {
        switch colorScheme {
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        case nil: return nil
        @unknown default: return nil
        }
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
