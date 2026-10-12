//
//  fluidApp.swift
//  fluid
//
//  Created by Barathwaj Anandan on 7/30/25.
//

import AppKit
import ApplicationServices
import SwiftUI

@main
struct FluidApp: App {
    @StateObject private var menuBarManager = MenuBarManager()
    @ObservedObject private var settings = SettingsStore.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() { PichiLocalization.configureApplicationLanguage() }

    var body: some Scene {
        WindowGroup(AppBrand.appName, id: "main") {
            #if DEBUG
            if MeetingExternalReferenceTrialAGate.autorunEnabled(environment: ProcessInfo.processInfo.environment)
                || MeetingSCKPairedDiagnosticGate.autorunEnabled()
                || MeetingStage05EvidenceAutorun.requested()
                || ProcessInfo.processInfo.environment["FLUIDVOICE_MIC_PHASE1"] != nil
                || ProcessInfo.processInfo.environment["FLUIDVOICE_VPIO_ACOUSTIC"] == "1"
            {
                Color.clear
            } else {
                self.applicationContent
            }
            #else
            self.applicationContent
            #endif
        }
        .defaultSize(width: 1000, height: 700)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            // Own these labels in SwiftUI, so native role validation cannot restore bundle names.
            CommandGroup(replacing: .appInfo) {
                Button(PichiLocalization.format("application.about", AppBrand.appName)) {
                    NSApplication.shared.orderFrontStandardAboutPanel(options:
                        BrandAppearanceController.aboutPanelOptions(appName: AppBrand.appName, icon: PichiBrandMark.appIcon))
                }
            }
            CommandGroup(replacing: .appVisibility) {
                Button(PichiLocalization.format("Hide %@", AppBrand.appName)) {
                    NSApplication.shared.hide(nil)
                }
                .keyboardShortcut("h", modifiers: .command)
                Button(PichiLocalization.text("Hide Others")) {
                    NSApplication.shared.hideOtherApplications(nil)
                }
                .keyboardShortcut("h", modifiers: [.command, .option])
                Button(PichiLocalization.text("Show All")) {
                    NSApplication.shared.unhideAllApplications(nil)
                }
            }
            CommandGroup(replacing: .appTermination) {
                Button(PichiLocalization.format("Quit %@", AppBrand.appName)) {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button(PichiLocalization.text("Settings...")) {
                    self.menuBarManager.openPreferencesFromUI()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .textEditing) {
                Button(PichiLocalization.text("Find")) {
                    NotificationCenter.default.post(name: .sidebarSearchFocusRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
    }

    private var applicationContent: some View {
        AdaptiveAppTheme(accent: self.settings.accentColor) {
            ContentView()
                .environmentObject(self.menuBarManager)
                // Resolve the singleton only when the normal application content branch is built.
                // The DEBUG C2 autorun branch returns Color.clear before this view is evaluated.
                .environmentObject(AppServices.shared)
                .environment(\.locale, PichiLocalization.locale)
        }
    }
}
