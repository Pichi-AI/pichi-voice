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
/// in the attributes; the elapsed timer is rendered by the system from the session start.
struct MobileRecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MobileRecordingActivityAttributes.self) { context in
            MobileRecordingLockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            let attributes = context.attributes
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
                    MobileActivityElapsedTimer(startedAt: context.state.startedAt)
                        .font(.system(.title3, design: attributes.titleDesign.font).weight(.semibold))
                        .foregroundStyle(accent)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 96, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MobileActivityStatusLine(attributes: attributes, accent: accent, isSingleLine: true)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                }
            } compactLeading: {
                MobileActivityBrandMark(asset: attributes.markAsset, color: accent, size: 20)
            } compactTrailing: {
                MobileActivityElapsedTimer(startedAt: context.state.startedAt)
                    .font(.system(.subheadline, design: attributes.bodyDesign.font).weight(.semibold))
                    .foregroundStyle(accent)
                    .multilineTextAlignment(.trailing)
                    // A running timer otherwise reserves the width of its longest value.
                    .frame(maxWidth: 56, alignment: .trailing)
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

    var body: some View {
        let accent = (self.colorScheme == .dark ? self.attributes.accentDark : self.attributes.accentLight).color
        HStack(alignment: .center, spacing: 12) {
            MobileActivityBrandMark(asset: self.attributes.markAsset, color: accent, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: self.attributes.productName)
                    .font(.system(.headline, design: self.attributes.bodyDesign.font))
                    .lineLimit(1)
                MobileActivityStatusLine(attributes: self.attributes, accent: accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            MobileActivityElapsedTimer(startedAt: self.state.startedAt)
                .font(.system(.title2, design: self.attributes.titleDesign.font).weight(.bold))
                .foregroundStyle(accent)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120, alignment: .trailing)
        }
        .padding(16)
    }
}

/// The app's recording label and symbol, followed by the meeting kind.
private struct MobileActivityStatusLine: View {
    let attributes: MobileRecordingActivityAttributes
    let accent: Color
    var isSingleLine = false

    var body: some View {
        let layout = self.isSingleLine
            ? AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
        layout {
            Label {
                Text(verbatim: self.attributes.recordingLabel)
            } icon: {
                Image(systemName: "record.circle")
            }
            .font(.system(.subheadline, design: self.attributes.bodyDesign.font).weight(.medium))
            .foregroundStyle(self.accent)
            .lineLimit(1)
            .layoutPriority(1)
            Text(verbatim: self.attributes.meetingKind)
                .font(.system(self.isSingleLine ? .subheadline : .caption, design: self.attributes.bodyDesign.font))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
