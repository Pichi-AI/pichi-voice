import SwiftUI

/// The actual dictation bars, driven only by the existing synthetic replay clock.
/// No microphone, audio files or independent animation/sampling task is created.
struct PrototypeMeetingWaveform: View {
    @ObservedObject var replay: MeetingLiveReplayController
    let theme: PrototypeTheme
    @Environment(\.scenePhase) private var scenePhase

    private var isAnimating: Bool { replay.isPlaying && scenePhase == .active }

    private var demonstrationLevel: CGFloat {
        guard isAnimating else { return 0 }
        let time = replay.currentTime
        let syllable = 0.5 + 0.5 * sin(time * 13)
        let phrase = 0.5 + 0.5 * sin(time * 2.1)
        return CGFloat(time.truncatingRemainder(dividingBy: 7) > 5.5 ? 0.2 : 0.42 + 0.48 * syllable * phrase)
    }

    var body: some View {
        // Existing Medium overlay geometry, including its 130 x 32 canvas.
        AudioWaveformBars(color: theme.accent, barCount: 8, barWidth: 3.5, barSpacing: 4.5,
                          minHeight: 6, maxHeight: 28, level: { demonstrationLevel }, noiseThreshold: 0.4,
                          isAnimating: isAnimating, isIdleWaveEnabled: isAnimating,
                          glowIntensity: 0.5, glowRadius: 4)
            .foregroundStyle(theme.accent)
            .frame(width: 130, height: 32)
            .accessibilityHidden(true)
    }
}
