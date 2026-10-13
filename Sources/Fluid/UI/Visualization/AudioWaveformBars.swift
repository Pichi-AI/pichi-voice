import SwiftUI

/// Shared dictation waveform renderer. Hosts supply level, geometry and visibility;
/// desktop overlay state and capture ownership stay outside this view.
struct AudioWaveformBars: View {
    let color: Color
    let barCount: Int
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let level: () -> CGFloat
    let noiseThreshold: CGFloat
    let isAnimating: Bool
    let isIdleWaveEnabled: Bool
    var glowIntensity: CGFloat = 0
    var glowRadius: CGFloat = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var simulation = WaveformSimulation()

    var body: some View {
        if self.isAnimating && !self.reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 50.0)) { timeline in
                self.bars(heights: self.simulation.step(
                    at: timeline.date,
                    barCount: self.barCount,
                    minHeight: self.minHeight,
                    maxHeight: self.maxHeight,
                    level: self.level(),
                    noiseThreshold: self.noiseThreshold,
                    isIdleWaveEnabled: self.isIdleWaveEnabled
                ))
            }
        } else {
            self.bars(heights: Array(repeating: self.minHeight, count: self.barCount))
        }
    }

    private func bars(heights: [CGFloat]) -> some View {
        Canvas { context, size in
            let count = heights.count
            let totalWidth = CGFloat(count) * self.barWidth + CGFloat(max(count - 1, 0)) * self.barSpacing
            var x = (size.width - totalWidth) / 2
            for height in heights {
                let rect = CGRect(x: x, y: (size.height - height) / 2, width: self.barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: self.barWidth / 2), with: .foreground)
                x += self.barWidth + self.barSpacing
            }
        }
        .shadow(color: self.color.opacity(self.glowIntensity), radius: self.glowRadius)
    }
}

/// Per-bar spring physics for the overlay visualizer. Voice energy lands on the center bars
/// first and ripples outward, the spectrum tilts the shape, and a slow idle wave keeps the
/// bars breathing while the user is quiet.
final class WaveformSimulation {
    private var heights: [CGFloat] = []
    private var velocities: [CGFloat] = []
    private var energyHistory: [CGFloat] = Array(repeating: 0, count: 32)
    private var historyIndex = 0
    private var energy: CGFloat = 0
    private var lastDate: Date?
    private var clock: TimeInterval = 0

    func step(
        at date: Date,
        barCount: Int,
        minHeight: CGFloat,
        maxHeight: CGFloat,
        level: CGFloat,
        noiseThreshold: CGFloat,
        isIdleWaveEnabled: Bool
    ) -> [CGFloat] {
        if self.heights.count != barCount {
            self.heights = Array(repeating: minHeight, count: barCount)
            self.velocities = Array(repeating: 0, count: barCount)
        }
        let dt = CGFloat(min(max(date.timeIntervalSince(self.lastDate ?? date), 0), 1.0 / 30.0))
        self.lastDate = date
        self.clock += TimeInterval(dt)
        guard dt > 0 else { return self.heights }

        let adjusted = max(min((min(max(level, 0), 1) - noiseThreshold) / max(1 - noiseThreshold, 0.001), 1), 0)
        let gate = pow(adjusted, 0.5)
        // Level arrives at ~20 Hz; glide toward it so the ripple source is continuous.
        self.energy += (gate - self.energy) * min(dt * 18, 1)
        self.historyIndex = (self.historyIndex + 1) % self.energyHistory.count
        self.energyHistory[self.historyIndex] = self.energy

        let bands = AudioSpectrumMeter.shared.bands(count: barCount)
        let half = max(CGFloat(barCount - 1) / 2, 1)
        let range = maxHeight - minHeight

        for i in 0..<barCount {
            let distance = abs(CGFloat(i) - half) / half
            // Outer bars hear the voice a few frames later than the center.
            let delayFrames = Int((distance * 0.09 / max(dt, 0.001)).rounded())
            let delayed = self.energyHistory[
                (self.historyIndex - min(delayFrames, self.energyHistory.count - 1) + self.energyHistory.count) % self.energyHistory.count
            ]
            let envelope = 0.34 + 0.66 * cos(distance * .pi / 2)
            let band = i < bands.count ? bands[i] : 0
            let wobble = 0.9 + 0.1 * sin(CGFloat(self.clock) * 9 + CGFloat(i) * 2.1)
            let voice = delayed * (0.5 + 0.5 * band) * wobble * envelope
            let idle = isIdleWaveEnabled
                ? (1 - self.energy) * 0.13 * (0.5 + 0.5 * sin(CGFloat(self.clock) * 2.4 - CGFloat(i) * 0.75))
                : 0
            let target = minHeight + range * min(voice + idle, 1)

            // Slightly underdamped spring: lively on the way up, settles without buzzing.
            let acceleration = 260 * (target - self.heights[i]) - 21 * self.velocities[i]
            self.velocities[i] += acceleration * dt
            self.heights[i] = min(maxHeight, max(minHeight, self.heights[i] + self.velocities[i] * dt))
        }
        return self.heights
    }
}
