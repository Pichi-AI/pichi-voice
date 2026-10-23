import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// Extension entry point. It declares only the recording Live Activity and adds no Home Screen widget.
@main
struct MobileActivityBundle: WidgetBundle {
    var body: some Widget {
        MobileRecordingActivityWidget()
    }
}

/// Lock Screen and Dynamic Island presentation of one meeting recording. Copy and appearance arrive
/// in the attributes; the elapsed timer is rendered by the system from the session start. Once the
/// app stops refreshing the activity, the system marks it stale and it no longer claims a recording.
struct MobileRecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MobileRecordingActivityAttributes.self) { context in
            MobileRecordingLockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let isStale = context.isStale
            // The Dynamic Island is always drawn on black, so it uses the dark appearance accent.
            let accent = attributes.accentDark.color
            return DynamicIsland {
                // The side regions flank the camera and are too narrow for the product name,
                // which therefore sits in the center region below it.
                DynamicIslandExpandedRegion(.leading) {
                    MobileActivityBrandMark(asset: attributes.markAsset, color: accent, size: 32)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: attributes.productName)
                        .font(.system(.headline, design: attributes.bodyDesign.font))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !isStale {
                        MobileActivityElapsedTimer(startedAt: context.state.startedAt)
                            .font(.system(.title3, design: attributes.titleDesign.font).weight(.semibold))
                            .foregroundStyle(accent)
                            .multilineTextAlignment(.trailing)
                            .frame(maxWidth: 96, alignment: .trailing)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MobileActivityStatusLine(attributes: attributes, accent: accent, isStale: isStale, alignment: .center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                }
            } compactLeading: {
                MobileActivityBrandMark(asset: attributes.markAsset, color: accent, size: 20)
            } compactTrailing: {
                if isStale {
                    MobileActivityStatusSymbol(isStale: true)
                        .font(.system(.subheadline).weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    MobileActivityElapsedTimer(startedAt: context.state.startedAt)
                        .font(.system(.subheadline, design: attributes.bodyDesign.font).weight(.semibold))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                        // A running timer otherwise reserves the width of its longest value.
                        // This width holds h:mm:ss; a recording activity ends within eight hours.
                        .frame(maxWidth: 66, alignment: .trailing)
                }
            } minimal: {
                MobileActivityBrandMark(asset: attributes.markAsset, color: accent, size: 18)
            }
            .keylineTint(accent)
        }
    }
}

/// The Lock Screen banner, which follows the system appearance.
private struct MobileRecordingLockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme
    let attributes: MobileRecordingActivityAttributes
    let state: MobileRecordingActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let accent = (self.colorScheme == .dark ? self.attributes.accentDark : self.attributes.accentLight).color
        HStack(alignment: .center, spacing: 12) {
            MobileActivityBrandMark(asset: self.attributes.markAsset, color: accent, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: self.attributes.productName)
                    .font(.system(.headline, design: self.attributes.bodyDesign.font))
                    .lineLimit(1)
                MobileActivityStatusLine(attributes: self.attributes, accent: accent, isStale: self.isStale, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !self.isStale {
                MobileActivityElapsedTimer(startedAt: self.state.startedAt)
                    .font(.system(.title2, design: self.attributes.titleDesign.font).weight(.bold))
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 120, alignment: .trailing)
            }
        }
        .padding(16)
    }
}

/// The recording status with its symbol, followed by the meeting kind. A stale activity shows the
/// interrupted status in secondary ink, without the accent that marks a live recording.
private struct MobileActivityStatusLine: View {
    let attributes: MobileRecordingActivityAttributes
    let accent: Color
    let isStale: Bool
    let alignment: HorizontalAlignment

    var body: some View {
        VStack(alignment: self.alignment, spacing: 2) {
            Label {
                Text(verbatim: self.isStale ? self.attributes.interruptedStatus : self.attributes.liveStatus)
            } icon: {
                MobileActivityStatusSymbol(isStale: self.isStale)
            }
            .font(.system(.subheadline, design: self.attributes.bodyDesign.font).weight(.medium))
            .foregroundStyle(self.isStale ? AnyShapeStyle(.secondary) : AnyShapeStyle(self.accent))
            .lineLimit(1)
            Text(verbatim: self.attributes.meetingKind)
                .font(.system(.caption, design: self.attributes.bodyDesign.font))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The app's recording symbol, or a notice symbol once the recording cannot be live.
private struct MobileActivityStatusSymbol: View {
    let isStale: Bool

    var body: some View {
        Image(systemName: self.isStale ? "exclamationmark.circle" : "record.circle")
    }
}

/// Counts up from the recording start without any update from the app.
private struct MobileActivityElapsedTimer: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: self.startedAt...Date.distantFuture, countsDown: false)
            .monospacedDigit()
    }
}

/// The packaged brand mark, tinted with the accent, or the app's symbol fallback.
private struct MobileActivityBrandMark: View {
    let asset: String?
    let color: Color
    let size: CGFloat

    var body: some View {
        Group {
            if let asset, let image = UIImage(named: asset) {
                Image(uiImage: image).resizable().renderingMode(.template)
            } else {
                Image(systemName: "waveform").resizable()
            }
        }
        .aspectRatio(contentMode: .fit)
        .foregroundStyle(self.color)
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}

private extension MobileRecordingActivityAttributes.Swatch {
    var color: Color { Color(.sRGB, red: self.red, green: self.green, blue: self.blue) }
}

private extension MobileRecordingActivityAttributes.TypeDesign {
    var font: Font.Design {
        switch self {
        case .standard: .default
        case .serif: .serif
        case .rounded: .rounded
        }
    }
}
