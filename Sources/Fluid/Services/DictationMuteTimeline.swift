import Foundation

/// Acquisition-time exclusions, accessed under AudioCapturePipeline's capture lock.
/// Retaining recent closed intervals rejects audio delivered after key release.
/// Older intervals collapse into a conservative excluded prefix so both memory
/// and per-packet work stay bounded even while typing spaces in a long session.
nonisolated struct DictationMuteTimeline {
    static let maximumRetainedIntervals = 256
    private struct Interval {
        let start: UInt64
        var end: UInt64?
    }

    private var intervals: [Interval] = []
    private var excludedThroughHostTime: UInt64?
    private(set) var isMuted = false
    var hasExclusions: Bool { self.excludedThroughHostTime != nil || !self.intervals.isEmpty }
    var retainedIntervalCount: Int { self.intervals.count }

    mutating func setMuted(_ muted: Bool, at hostTime: UInt64) {
        guard muted != self.isMuted else { return }
        self.isMuted = muted
        if muted {
            self.intervals.append(Interval(start: hostTime))
            if self.intervals.count > Self.maximumRetainedIntervals {
                let retired = self.intervals.removeFirst()
                // All retired intervals are closed. Fail closed if this invariant
                // ever changes, rather than admitting previously muted PCM.
                let end = retired.end ?? UInt64.max
                self.excludedThroughHostTime = max(self.excludedThroughHostTime ?? 0, end)
            }
        } else if let last = self.intervals.indices.last {
            self.intervals[last].end = max(hostTime, self.intervals[last].start)
        }
    }

    func audibleRanges(
        in range: Range<Int>,
        packetHostTime: UInt64,
        sampleRate: Double,
        hostTicksPerSecond: Double
    ) -> [Range<Int>] {
        guard !range.isEmpty else { return [] }
        guard self.hasExclusions else { return [range] }
        // Once a session has muted audio, an untimestamped packet cannot safely be
        // attributed to either side of a mute boundary. Do not leak it into ASR.
        guard packetHostTime > 0 else { return [] }
        var cursor = range.lowerBound
        var result: [Range<Int>] = []
        if let excludedThroughHostTime = self.excludedThroughHostTime {
            let end = (Double(excludedThroughHostTime) - Double(packetHostTime)) * sampleRate / hostTicksPerSecond
            cursor = Int(max(Double(range.lowerBound), min(Double(range.upperBound), ceil(end))))
        }
        for interval in self.intervals {
            let start = (Double(interval.start) - Double(packetHostTime)) * sampleRate / hostTicksPerSecond
            let end = interval.end.map { (Double($0) - Double(packetHostTime)) * sampleRate / hostTicksPerSecond }
                ?? Double(range.upperBound)
            let lower = Int(max(Double(range.lowerBound), min(Double(range.upperBound), floor(start))))
            let upper = Int(max(Double(range.lowerBound), min(Double(range.upperBound), ceil(end))))
            if lower > cursor {
                result.append(cursor..<lower)
            }
            cursor = max(cursor, upper)
        }
        if cursor < range.upperBound {
            result.append(cursor..<range.upperBound)
        }
        return result
    }
}
