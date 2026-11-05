import Foundation
import SwiftUI

/// One presentation contract for the recording canvas and compact microphone indicator.
/// This only describes the capture gate's published state; it never infers mute from a level.
nonisolated struct MeetingMicrophoneMutePresentation {
    let state: MeetingMicrophoneMuteState

    var isMonitored: Bool { self.state != .notApplicable }

    var blocksMicrophone: Bool { !self.state.admitsMicrophone }

    var showsQuestionBadge: Bool {
        switch self.state {
        case .checking, .unknown: true
        case .notApplicable, .unmuted, .muted: false
        }
    }

    var symbolName: String { self.state == .muted ? "mic.slash.fill" : "mic.fill" }

    func title(language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        switch self.state {
        case .notApplicable: PichiLocalization.text("Microphone", language: language, bundle: bundle)
        case .checking: PichiLocalization.text("Checking meeting mute", language: language, bundle: bundle)
        case .unmuted: PichiLocalization.text("Microphone unmuted in meeting", language: language, bundle: bundle)
        case .muted: PichiLocalization.text("Mute detected in meeting", language: language, bundle: bundle)
        case .unknown: PichiLocalization.text("Meeting mute state unknown", language: language, bundle: bundle)
        }
    }

    func detail(language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        switch self.state {
        case .notApplicable: PichiLocalization.text("Microphone", language: language, bundle: bundle)
        case .checking: PichiLocalization.text("Meeting mute is being checked. Your microphone is not being recorded.", language: language, bundle: bundle)
        case .unmuted: PichiLocalization.text("The meeting microphone is unmuted.", language: language, bundle: bundle)
        case .muted: PichiLocalization.text("Meeting mute detected. Your microphone is not being recorded.", language: language, bundle: bundle)
        case .unknown: PichiLocalization.text("Meeting mute could not be determined. Your microphone is not being recorded.", language: language, bundle: bundle)
        }
    }
}

struct MeetingMicrophoneMuteIndicator: View {
    let state: MeetingMicrophoneMuteState
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale

    private var presentation: MeetingMicrophoneMutePresentation { .init(state: self.state) }
    private var language: PichiInterfaceLanguage {
        PichiInterfaceLanguage(rawValue: self.locale.identifier) ?? PichiLocalization.language
    }
    private var tone: Color {
        switch self.state {
        case .muted: self.theme.palette.readableText(.red)
        case .unknown: self.theme.palette.readableText(self.theme.palette.warning)
        case .notApplicable, .checking, .unmuted: self.theme.palette.secondaryText
        }
    }

    var body: some View {
        Image(systemName: self.presentation.symbolName)
            .font(self.theme.typography.captionStrong)
            .foregroundStyle(self.tone)
            .frame(width: 18, height: 18)
            .overlay(alignment: .bottomTrailing) {
                if self.presentation.showsQuestionBadge {
                    Image(systemName: "questionmark.circle.fill")
                        .font(self.theme.typography.tinyStrong)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(self.theme.palette.foreground(on: self.tone), self.tone)
                        .background(self.theme.palette.windowBackground, in: Circle())
                        .offset(x: 3, y: 2)
                }
            }
            .help(self.presentation.detail(language: self.language))
            .accessibilityLabel(self.presentation.title(language: self.language))
            .accessibilityHint(self.presentation.detail(language: self.language))
            .accessibilityIdentifier("meeting.microphone.mute-indicator")
    }
}
