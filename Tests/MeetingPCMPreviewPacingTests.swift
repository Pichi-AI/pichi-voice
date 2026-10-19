import Foundation

private final class FakeComputeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    func read() -> TimeInterval { self.lock.withLock { self.time } }
    func advance(_ seconds: TimeInterval) { self.lock.withLock { self.time += seconds } }
}

@main
struct MeetingPCMPreviewPacingTests {
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: "MeetingPCMPreviewPacingTests", code: 1,
                                   userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() throws {
        var pacing = MeetingPCMPreviewPacing()
        try require(pacing.permitsIntermediateObservations, "First startup window retains previews")
        pacing.record(computeSeconds: 7.2, audioSeconds: 12)
        try require(!pacing.permitsIntermediateObservations, "60 percent work must reserve speaker/CPU headroom")
        pacing.record(computeSeconds: 4.8, audioSeconds: 12)
        try require(!pacing.permitsIntermediateObservations, "Recovery boundary retains hysteresis")
        pacing.record(computeSeconds: 4.7, audioSeconds: 12)
        try require(pacing.permitsIntermediateObservations, "Clear sealed-window headroom restores previews")
        pacing.record(computeSeconds: 6.9, audioSeconds: 12)
        try require(pacing.permitsIntermediateObservations, "Healthy windows retain intermediate observations")
        for (compute, audio) in [(Double.nan, 12.0), (Double.infinity, 12.0), (-1.0, 12.0), (10.0, 0.0)] {
            pacing.record(computeSeconds: compute, audioSeconds: audio)
            try require(pacing.permitsIntermediateObservations, "Invalid measurements cannot alter pacing")
        }
        print("PASS startup, headroom and recovery hysteresis")

        pacing.record(computeSeconds: 0.1, audioSeconds: 20,
            chargedPendingFrames: 36 * 16_000, maximumPendingFrames: 60 * 16_000)
        try require(!pacing.permitsIntermediateObservations,
                    "Charged PCM pressure suppresses optional prefixes before the 60-second ceiling")
        pacing.record(computeSeconds: 0.1, audioSeconds: 20,
            chargedPendingFrames: 24 * 16_000, maximumPendingFrames: 60 * 16_000)
        try require(!pacing.permitsIntermediateObservations, "Queue recovery boundary retains hysteresis")
        pacing.record(computeSeconds: 0.1, audioSeconds: 20,
            chargedPendingFrames: 23 * 16_000, maximumPendingFrames: 60 * 16_000)
        try require(pacing.permitsIntermediateObservations, "Both compute and charged queue must recover")
        for (pending, maximum) in [(-1, 960_000), (960_001, 960_000), (0, 0)] {
            pacing.record(computeSeconds: 100, audioSeconds: 20,
                chargedPendingFrames: pending, maximumPendingFrames: maximum)
            try require(pacing.permitsIntermediateObservations, "Invalid budget feedback cannot alter pacing")
        }
        print("PASS charged budget pressure and independent recovery hysteresis")

        for permits in [true, false] {
            var sampleCount = 0
            var inferenceFrames: [Int] = []
            // Simulate 3/6/9/12-second deltas, with both a final data update and
            // an empty final marker. Suppression changes optional work only.
            for index in 0..<4 {
                sampleCount += 48_000
                if MeetingPCMPreviewPacing.shouldInfer(hasNewPCM: true, isFinal: index == 3,
                    permitsIntermediateObservations: permits) { inferenceFrames.append(sampleCount) }
            }
            try require(inferenceFrames == (permits ? [48_000, 96_000, 144_000, 192_000] : [192_000]),
                        "Under pressure exactly one final pass must consume all physical PCM")
            try require(MeetingPCMPreviewPacing.shouldInfer(hasNewPCM: false, isFinal: true,
                permitsIntermediateObservations: permits) == !permits,
                        "An empty final marker must infer buffered PCM when intermediate passes were skipped")
            try require(!MeetingPCMPreviewPacing.shouldInfer(hasNewPCM: false, isFinal: false,
                permitsIntermediateObservations: permits), "Empty nonfinal updates cannot trigger inference")
        }
        print("PASS complete sealed audio with and without optional previews")

        let clock = FakeComputeClock()
        let timing = MeetingPCMWindowComputeTiming(now: { clock.read() })
        clock.advance(1.4) // Provider preparation.
        let pcmWait = timing.beginExclusion()
        clock.advance(90) // The capture source can pause for arbitrarily long.
        timing.endExclusion(since: pcmWait)
        clock.advance(3.3) // Buffered ASR inference.
        clock.advance(120) // Protected publication delays the next owned window too.
        clock.advance(0.2 + 4.3 + 2.7) // Sequential model load, diarization and voice.
        try require(abs(timing.computeSeconds - 131.9) < 0.000_001,
                    "Owned work includes protected publication and excludes only future PCM waits")
        pacing.record(computeSeconds: timing.computeSeconds, audioSeconds: 12)
        try require(!pacing.permitsIntermediateObservations, "Measured slow decoder suppresses repeated growing-prefix work")
        print("PASS fake-clock compute accounting across sequential phases")

        // Eight hours of windows remain scalar state. Simulate intermittent slow bursts,
        // then ample sealed-window headroom. No final audio or inference is discarded.
        for window in 0..<(8 * 60 * 60 / 12) {
            let compute: Double = window % 100 < 8 ? 13 : 3
            pacing.record(computeSeconds: compute, audioSeconds: 12)
            try require(pacing.permitsIntermediateObservations == (compute < 4.8),
                        "Pacing must follow current measured headroom without historical accumulation")
        }
        try require(MemoryLayout<MeetingPCMPreviewPacing>.size == MemoryLayout<Bool>.size,
                    "Preview scheduling must retain no duration-dependent history")
        print("PASS accelerated eight-hour pacing without accumulated state")
    }
}
