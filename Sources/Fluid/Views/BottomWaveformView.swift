import SwiftUI

// MARK: - Bottom Waveform View (reads from NotchContentState)

struct BottomWaveformView: View {
    let color: Color
    let layout: BottomOverlayView.LayoutConstants
    let visibleBarCount: Int?

    @ObservedObject private var contentState = NotchContentState.shared
    @ObservedObject private var audioLevel = OverlayAudioLevelState.shared
    private var isWaitingForMicrophone: Bool {
        !self.audioLevel.isLive && !self.contentState.isProcessing && !self.isReleaseAnimationActive
    }

    @State private var noiseThreshold: CGFloat = .init(SettingsStore.shared.visualizerNoiseThreshold)

    private var barCount: Int {
        self.visibleBarCount ?? self.layout.barCount
    }

    private var barWidth: CGFloat {
        self.layout.barWidth
    }

    private var barSpacing: CGFloat {
        self.layout.barSpacing
    }

    private var minHeight: CGFloat {
        self.layout.minBarHeight
    }

    private var maxHeight: CGFloat {
        self.layout.maxBarHeight
    }

    private var isPillStyle: Bool {
        !self.layout.showsModeLabel
    }

    private var isProcessingVisualActive: Bool {
        self.contentState.isProcessing || self.isReleaseAnimationActive
    }

    private var currentGlowIntensity: CGFloat {
        if self.isPillStyle {
            return 0.0
        }
        return self.isProcessingVisualActive ? 0.0 : 0.5
    }

    private var currentGlowRadius: CGFloat {
        if self.isPillStyle {
            return 0.0
        }
        return self.isProcessingVisualActive ? 0.0 : 4
    }

    private var barFillColor: Color {
        if self.isPillStyle {
            return Color.white.opacity(self.isProcessingVisualActive ? 0.32 : 0.88)
        }
        return self.color.opacity(self.isProcessingVisualActive ? 0.16 : 1.0)
    }

    private var isReleaseAnimationActive: Bool {
        self.contentState.isBottomOverlayReleaseTransitioning || self.contentState.isBottomOverlayDismissing
    }

    var body: some View {
        ZStack {
            if self.contentState.isDictationMuted {
                DictationMutedIndicator(compact: self.layout.waveformWidth < 80)
            } else {
                self.barsView
                    .foregroundStyle(self.barFillColor)

                if self.isProcessingVisualActive {
                    CompositorShimmerSweep(duration: 1.05, peakOpacity: 0.9, isActive: self.contentState.isBottomOverlayPresented)
                        .mask {
                            self.barsView
                        }
                        .shadow(color: .white.opacity(0.28), radius: 2.5, x: 0, y: 0)
                }
            }
        }
        .opacity(self.isWaitingForMicrophone && !self.contentState.isDictationMuted ? 0.45 : 1)
        .animation(.easeOut(duration: 0.22), value: self.isWaitingForMicrophone)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            // Update threshold when user changes sensitivity setting
            let newThreshold = CGFloat(SettingsStore.shared.visualizerNoiseThreshold)
            if newThreshold != self.noiseThreshold {
                self.noiseThreshold = newThreshold
            }
        }
    }

    private var barsView: some View {
        AudioWaveformBars(
            color: self.color,
            barCount: self.barCount,
            barWidth: self.barWidth,
            barSpacing: self.barSpacing,
            minHeight: self.minHeight,
            maxHeight: self.maxHeight,
            level: { self.audioLevel.isLive ? OverlayAudioLevelState.shared.level : 0 },
            noiseThreshold: self.noiseThreshold,
            isAnimating: self.contentState.isBottomOverlayPresented && !self.isWaitingForMicrophone && !self.isProcessingVisualActive,
            isIdleWaveEnabled: self.audioLevel.isLive,
            glowIntensity: self.isReleaseAnimationActive ? 0 : self.currentGlowIntensity,
            glowRadius: self.isReleaseAnimationActive ? 0 : self.currentGlowRadius
        )
    }
}
