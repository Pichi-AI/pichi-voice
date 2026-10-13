import SwiftUI

struct CommandShimmerText: View {
    let text: String
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: self.reduceMotion)) { timeline in
            let duration = 1.15
            let progress = timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: duration) / duration
            let center = self.reduceMotion ? 0.5 : CGFloat(progress)
            let leadingEdge = max(0, center - 0.18)
            let trailingEdge = min(1, center + 0.18)

            Text(self.text)
                .font(.fluidSystem(size: 13, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        stops: [
                            .init(color: self.theme.palette.secondaryText, location: 0),
                            .init(color: self.theme.palette.secondaryText, location: leadingEdge),
                            .init(color: self.theme.palette.primaryText, location: center),
                            .init(color: self.theme.palette.secondaryText, location: trailingEdge),
                            .init(color: self.theme.palette.secondaryText, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        }
        .accessibilityLabel(Text(self.text))
    }
}
