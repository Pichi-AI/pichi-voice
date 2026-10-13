import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class WaveformSimulationTests: XCTestCase {
    private let origin = Date(timeIntervalSinceReferenceDate: 1_000)

    func testSilenceAndLevelsAtNoiseThresholdStayAtFloorWithoutIdleWave() {
        for level: CGFloat in [0, 0.1, 0.3] {
            let simulation = WaveformSimulation()
            for frame in 0...120 {
                let heights = self.step(simulation, frame: frame, level: level, threshold: 0.3)
                XCTAssertEqual(heights, Array(repeating: 3, count: 11))
            }
        }
    }

    func testIncreasingThresholdAttenuatesVoiceAndFullThresholdClosesGate() {
        let open = WaveformSimulation()
        let attenuated = WaveformSimulation()
        let closed = WaveformSimulation()
        var openHeights: [CGFloat] = []
        var attenuatedHeights: [CGFloat] = []
        for frame in 0...120 {
            openHeights = self.step(open, frame: frame, level: 0.5)
            attenuatedHeights = self.step(attenuated, frame: frame, level: 0.5, threshold: 0.4)
            XCTAssertEqual(self.step(closed, frame: frame, level: 1, threshold: 1), Array(repeating: 3, count: 11))
        }
        XCTAssertGreaterThan(attenuatedHeights[5], 3)
        XCTAssertGreaterThan(openHeights[5], attenuatedHeights[5])
    }

    func testOutOfRangeLevelsMatchTheirClampedEndpoints() {
        let levels: [(CGFloat, CGFloat)] = [(-10, 0), (10, 1), (-.infinity, 0), (.infinity, 1)]
        for (outside, endpoint) in levels {
            let clipped = WaveformSimulation()
            let reference = WaveformSimulation()
            for frame in 0...120 {
                XCTAssertEqual(
                    self.step(clipped, frame: frame, level: outside),
                    self.step(reference, frame: frame, level: endpoint)
                )
            }
        }
    }

    func testIdleWaveRequiresHostOptInAndVoiceSettlesAfterSilence() {
        let idle = WaveformSimulation()
        let disabled = WaveformSimulation()
        let voice = WaveformSimulation()
        var idleHeights: [CGFloat] = []
        var voiceHeights: [CGFloat] = []
        for frame in 0...120 {
            idleHeights = self.step(idle, frame: frame, level: 0, idleWave: true)
            XCTAssertEqual(self.step(disabled, frame: frame, level: 0), Array(repeating: 3, count: 11))
            voiceHeights = self.step(voice, frame: frame, level: 1)
        }
        XCTAssertTrue(idleHeights.contains { $0 > 3 })
        XCTAssertGreaterThan(voiceHeights[5], 3)
        for frame in 121...420 {
            voiceHeights = self.step(voice, frame: frame, level: 0)
        }
        XCTAssertTrue(voiceHeights.allSatisfy { abs($0 - 3) < 0.001 })
    }

    func testRepeatedAndBackwardDatesDoNotAdvanceTheSimulation() {
        let simulation = WaveformSimulation()
        let initial = self.step(simulation, frame: 0, level: 1)
        XCTAssertEqual(initial, Array(repeating: 3, count: 11))
        let advanced = self.step(simulation, frame: 1, level: 1)
        XCTAssertEqual(self.step(simulation, frame: 1, level: 0), advanced)
        XCTAssertEqual(self.step(simulation, frame: 0, level: 0), advanced)
    }

    func testLongPausesAndVariableFrameRateKeepEveryHeightFiniteAndBounded() {
        let simulation = WaveformSimulation()
        for (index, seconds) in [0.0, 0.001, 0.05, 10, 10.02, 100_000, 100_000.01].enumerated() {
            let heights = simulation.step(
                at: self.origin.addingTimeInterval(seconds), barCount: 11,
                minHeight: 3, maxHeight: 24, level: index.isMultiple(of: 2) ? 1 : 0,
                noiseThreshold: 0.2, isIdleWaveEnabled: true
            )
            self.assertBounds(heights, count: 11, minimum: 3, maximum: 24)
        }
    }

    func testBarCountTransitionsIncludeZeroAndSingleBarWithoutStaleHeights() {
        let simulation = WaveformSimulation()
        for (frame, count) in [11, 3, 0, 1, 31, 11, 0].enumerated() {
            let heights = self.step(simulation, frame: frame, level: 1, count: count)
            self.assertBounds(heights, count: count, minimum: 3, maximum: 24)
        }
    }

    func testGeometryChangesClampExistingHeightsEvenWithoutAClockTick() {
        let simulation = WaveformSimulation()
        for frame in 0...120 { _ = self.step(simulation, frame: frame, level: 1) }
        let geometry: [(CGFloat, CGFloat)] = [(1, 2), (30, 40), (5, 5)]
        for (minimum, maximum) in geometry {
            let heights = simulation.step(
                at: self.origin.addingTimeInterval(120.0 / 50.0), barCount: 11,
                minHeight: minimum, maxHeight: maximum, level: 1,
                noiseThreshold: 0, isIdleWaveEnabled: false
            )
            self.assertBounds(heights, count: 11, minimum: minimum, maximum: maximum)
        }
    }

    func testSharedSpectrumStillShapesVoiceResponse() {
        AudioSpectrumMeter.shared.reset()
        defer { AudioSpectrumMeter.shared.reset() }
        let withoutSpectrum = WaveformSimulation()
        var baseline: [CGFloat] = []
        for frame in 0...120 { baseline = self.step(withoutSpectrum, frame: frame, level: 1) }
        let samples: [Float] = (0..<512).map { index in
            0.5 * sin(2 * .pi * 1_000 * Float(index) / 16_000)
        }
        AudioSpectrumMeter.shared.ingest(samples)
        XCTAssertTrue(AudioSpectrumMeter.shared.bands(count: 11).contains { $0 > 0 })
        let withSpectrum = WaveformSimulation()
        var shaped: [CGFloat] = []
        for frame in 0...120 { shaped = self.step(withSpectrum, frame: frame, level: 1) }
        XCTAssertTrue(zip(shaped, baseline).contains { $0.0 > $0.1 + 0.01 })
        self.assertBounds(shaped, count: 11, minimum: 3, maximum: 24)
    }

    func testReducedMotionAndHiddenRendererDoNotReadAudioLevels() throws {
        for (animating, reducedMotion) in [(true, true), (false, false), (false, true)] {
            var audioReads = 0
            let renderer = AudioWaveformBars(
                color: .blue, barCount: 11, barWidth: 3, barSpacing: 2,
                minHeight: 3, maxHeight: 24, level: { audioReads += 1; return 1 },
                noiseThreshold: 0, isAnimating: animating, isIdleWaveEnabled: true
            )
            .foregroundStyle(.red)
            .environment(\.accessibilityReduceMotion, reducedMotion)
            .frame(width: 80, height: 30)
            let host = NSHostingView(rootView: renderer)
            host.frame = NSRect(x: 0, y: 0, width: 80, height: 30)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertEqual(audioReads, 0, "Static waveform must not sample or tick the audio simulation")
        }
    }

    private func step(
        _ simulation: WaveformSimulation, frame: Int, level: CGFloat,
        threshold: CGFloat = 0, idleWave: Bool = false, count: Int = 11
    ) -> [CGFloat] {
        simulation.step(
            at: self.origin.addingTimeInterval(Double(frame) / 50), barCount: count,
            minHeight: 3, maxHeight: 24, level: level,
            noiseThreshold: threshold, isIdleWaveEnabled: idleWave
        )
    }

    private func assertBounds(
        _ heights: [CGFloat], count: Int, minimum: CGFloat, maximum: CGFloat,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(heights.count, count, file: file, line: line)
        for height in heights {
            XCTAssertTrue(height.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(height, minimum, file: file, line: line)
            XCTAssertLessThanOrEqual(height, maximum, file: file, line: line)
        }
    }
}
