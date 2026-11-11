import Foundation
import SwiftUI

/// One presentation contract for the recording canvas and compact microphone indicator.
/// This only describes the capture gate's published state; it never infers mute from a level.
nonisolated struct MeetingMicrophoneMutePresentation {
    let state: MeetingMicrophoneMuteState

    var isMonitored: Bool { self.state != .notApplicable }

    var blocksMicrophone: Bool { !self.state.admitsMicrophone }

    var symbolName: String { self.blocksMicrophone ? "mic.slash.fill" : "mic.fill" }

    func actionTitle(language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        PichiLocalization.text(self.state == .manuallyMuted ? "Enable microphone recording" : "Pause microphone recording", language: language, bundle: bundle)
    }

    func title(language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        switch self.state {
        case .notApplicable: PichiLocalization.text("Microphone", language: language, bundle: bundle)
        case .unmuted: PichiLocalization.text("Microphone recording enabled", language: language, bundle: bundle)
        case .muted: PichiLocalization.text("Mute detected in meeting", language: language, bundle: bundle)
        case .manuallyMuted: PichiLocalization.text("Microphone recording paused manually", language: language, bundle: bundle)
        }
    }

    func detail(language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        switch self.state {
        case .notApplicable: PichiLocalization.text("Microphone", language: language, bundle: bundle)
        case .unmuted: PichiLocalization.text("Pause recording your voice in Pichi. Other participants continue to be recorded.", language: language, bundle: bundle)
        case .muted: PichiLocalization.text("Mute detected. Microphone recording stays paused until an unmute transition is detected.", language: language, bundle: bundle)
        case .manuallyMuted: PichiLocalization.text("Your voice stays paused until you enable it here. Meeting unmute does not resume it.", language: language, bundle: bundle)
        }
    }
}

struct MeetingMicrophoneMuteIndicator: View {
    let state: MeetingMicrophoneMuteState
    var onToggle: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale

    private var presentation: MeetingMicrophoneMutePresentation { .init(state: self.state) }
    private var language: PichiInterfaceLanguage {
        PichiInterfaceLanguage(rawValue: self.locale.identifier) ?? PichiLocalization.language
    }
    private var tone: Color {
        switch self.state {
        case .muted, .manuallyMuted: self.theme.palette.readableText(.red)
        case .notApplicable, .unmuted: self.theme.palette.secondaryText
        }
    }

    var body: some View {
        if let onToggle, self.presentation.isMonitored {
            Button(action: onToggle) { self.icon }
                .buttonStyle(.plain)
                .frame(minWidth: 28, minHeight: 22)
                .contentShape(Rectangle())
                .help(self.presentation.actionTitle(language: self.language) + "\n" + self.presentation.detail(language: self.language))
                .accessibilityLabel(self.presentation.actionTitle(language: self.language))
                .accessibilityValue(self.presentation.title(language: self.language))
                .accessibilityHint(self.presentation.detail(language: self.language))
                .accessibilityIdentifier("meeting.microphone.recording-toggle")
        } else {
            self.icon
                .help(self.presentation.detail(language: self.language))
                .accessibilityLabel(self.presentation.title(language: self.language))
                .accessibilityIdentifier("meeting.microphone.mute-indicator")
        }
    }

    private var icon: some View {
        Image(systemName: self.presentation.symbolName)
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(self.tone)
            .frame(width: 18, height: 18)
    }
}
