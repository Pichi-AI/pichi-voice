import SwiftUI
import UIKit

/// Presentation only: both arrangements invoke the root's existing recording and settings actions.
struct MobileMeetingStartBar: View {
    let inline: Bool
    let preparing: Bool
    let processing: Bool
    let startDisabled: Bool
    let settingsDisabled: Bool
    let summary: [String]
    let start: () -> Void
    let openSettings: () -> Void
    @Environment(\.theme) private var theme

    static func usesInlineLayout(idiom: UIUserInterfaceIdiom, verticalSizeClass: UserInterfaceSizeClass?,
                                 dynamicTypeSize: DynamicTypeSize) -> Bool {
        idiom == .phone && verticalSizeClass == .compact && !dynamicTypeSize.isAccessibilitySize
    }

    var body: some View {
        Group {
            if inline {
                HStack(spacing: theme.metrics.spacing.lg) {
                    recordingSettings
                    Spacer(minLength: 16)
                    startButton.fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, 24).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    startButton
                    recordingSettings
                }
                .padding(.horizontal, 24).padding(.top, 12)
                .frame(maxWidth: 560).frame(maxWidth: .infinity)
            }
        }
        .background(theme.palette.toolbarBackground)
    }

    private var startButton: some View {
        Button(action: start) {
            Label(PichiLocalization.text(preparing ? "Preparing recording…" : "Start Recording"), systemImage: "record.circle")
                .foregroundStyle(theme.palette.accentForeground)
                .frame(maxWidth: inline ? nil : .infinity, minHeight: inline ? 32 : 48)
                .animation(nil, value: preparing)
        }.buttonStyle(.borderedProminent)
            .disabled(startDisabled)
            .accessibilityIdentifier("meeting.start")
    }

    @ViewBuilder private var recordingSettings: some View {
        if processing {
            Label(PichiLocalization.text("Preparing your transcript"), systemImage: "text.alignleft")
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                .frame(minHeight: 44)
        } else {
            Button(action: openSettings) {
                HStack(spacing: theme.metrics.spacing.xs) {
                    Image(systemName: "mic")
                    if inline {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(summary.enumerated()), id: \.offset) { _, item in
                                Text(verbatim: item).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    } else {
                        Text(verbatim: summary.joined(separator: " · "))
                    }
                    Image(systemName: "chevron.right").imageScale(.small)
                }
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(settingsDisabled)
                .accessibilityLabel(PichiLocalization.text("Recording settings"))
                .accessibilityValue(summary.joined(separator: ", "))
                .accessibilityIdentifier("meeting.settings")
        }
    }
}
