//
//  AppNavigationState.swift
//  fluid
//
//  Navigation state shared by the main app and settings sidebars.
//

import Foundation

enum SidebarItem: Hashable {
    case welcome
    case voiceEngine
    case aiEnhancements
    case cleanupStyles
    case fileTranscription
    case meetingTranscription
    case customDictionary
    case stats
    case history
    case changelog
    case feedback
    case commandMode
    case rewriteMode

    var title: String {
        switch self {
        case .welcome: PichiLocalization.text("Dashboard")
        case .voiceEngine: PichiLocalization.text("Voice Engine")
        case .aiEnhancements: PichiLocalization.text("AI Providers")
        case .cleanupStyles: PichiLocalization.text("Cleanup Styles")
        case .fileTranscription: PichiLocalization.text("File Transcription")
        case .meetingTranscription: AppBrand.text("FluidMeet")
        case .customDictionary: PichiLocalization.text("Custom Dictionary")
        case .stats: PichiLocalization.text("Stats")
        case .history: PichiLocalization.text("History")
        case .changelog: PichiLocalization.text("Change logs")
        case .feedback: PichiLocalization.text("Feedback")
        case .commandMode: PichiLocalization.text("Command Mode")
        case .rewriteMode: PichiLocalization.text("Edit Mode")
        }
    }
}

/// Read-only projection; changing chrome cannot navigate or alter a page's state.
struct AppPagePresentation: Equatable {
    let title: String
    let showsPageActions: Bool

    init(destination: SidebarItem?, settings: SettingsNavigationState) {
        self.title = settings.selectedSection?.title ?? (destination ?? .welcome).title
        self.showsPageActions = !settings.isPresented
    }
}

enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case dictation
    case dictationFormatting
    case shortcuts
    case notifications
    case audio
    case overlay
    case dataAndDiagnostics
    case experimental

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .general: return PichiLocalization.text("General")
        case .dictation: return PichiLocalization.text("Dictation")
        case .dictationFormatting: return PichiLocalization.text("Dictation Formatting")
        case .shortcuts: return PichiLocalization.text("Shortcuts")
        case .notifications: return PichiLocalization.text("Notifications")
        case .audio: return PichiLocalization.text("Audio")
        case .overlay: return PichiLocalization.text("Overlay")
        case .dataAndDiagnostics: return PichiLocalization.text("Data & Diagnostics")
        case .experimental: return PichiLocalization.text("Experimental")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .dictation: return "mic"
        case .dictationFormatting: return "textformat"
        case .shortcuts: return "keyboard"
        case .notifications: return "bell"
        case .audio: return "speaker.wave.2"
        case .overlay: return "rectangle.on.rectangle"
        case .dataAndDiagnostics: return "wrench.and.screwdriver"
        case .experimental: return "flask"
        }
    }
}

struct SettingsNavigationState: Equatable {
    var selectedSection: SettingsSection?
    private(set) var returnDestination: SidebarItem = .welcome

    var isPresented: Bool {
        self.selectedSection != nil
    }

    func isLeaving(_ section: SettingsSection, for destination: SettingsSection?) -> Bool {
        self.selectedSection == section && destination != section
    }

    mutating func present(_ section: SettingsSection, returningTo currentDestination: SidebarItem?) {
        if !self.isPresented {
            self.returnDestination = currentDestination ?? .welcome
        }
        self.selectedSection = section
    }

    mutating func dismiss() -> SidebarItem {
        self.selectedSection = nil
        return self.returnDestination
    }

    mutating func leaveForApp() {
        self.selectedSection = nil
    }
}
