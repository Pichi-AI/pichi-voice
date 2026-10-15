import SwiftUI

/// Visual capture feedback only. These shapes never become transcript words.
struct MeetingPendingSpeechView: View {
    let pending: MeetingPendingSpeechSnapshot
    @Environment(\.theme) private var theme

    var body: some View {
        let animatedIDs = Set(pending.tokens.suffix(3).map(\.id))
        FlowLayout(spacing: theme.metrics.spacing.xs) {
            ForEach(pending.tokens) { token in
                MeetingPendingSpeechTokenView(token: token, isAnimating: animatedIDs.contains(token.id))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PichiLocalization.text("Audio captured, waiting for transcription"))
        .accessibilityIdentifier("meeting.liveTranscript.pendingSpeech")
    }
}

/// The same word-shaped waveform is used in the standalone flow and native inline attachments.
struct MeetingPendingSpeechTokenView: View {
    let token: MeetingPendingSpeechToken
    let isAnimating: Bool
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var wordHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var wordWidth: CGFloat = 56

    var body: some View {
        let width = wordWidth * CGFloat(token.widthHint)
        let count = max(5, min(16, Int(width / 4)))
        let maximum = wordHeight * 0.85
        let heights = (0..<count).map { index -> CGFloat in
            let position = CGFloat(index) / CGFloat(max(count - 1, 1))
            let envelope = 0.25 + 0.75 * sin(position * .pi)
            let variation = 0.7 + 0.3 * sin(CGFloat(index * 3 + Int(token.id % 11)))
            let energy = CGFloat(max(0.2, min(1, token.level)))
            return 2 + (maximum - 2) * envelope * variation * energy
        }
        AudioWaveformBars(color: theme.palette.secondaryText,
            barCount: count, barWidth: 2, barSpacing: 2,
            minHeight: 2, maxHeight: maximum, level: { CGFloat(token.level) }, noiseThreshold: 0,
            isAnimating: scenePhase != .background && isAnimating,
            isIdleWaveEnabled: true, frozenHeights: heights, animationInterval: 1.0 / 20.0)
            .foregroundStyle(theme.palette.secondaryText.opacity(0.75))
            .frame(width: width, height: wordHeight)
            .accessibilityHidden(true)
            .transition(.opacity)
    }
}
