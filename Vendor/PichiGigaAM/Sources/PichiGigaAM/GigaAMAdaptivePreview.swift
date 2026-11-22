import CryptoKit
import Foundation

/// One growing dictation. Both decoder inputs and word times use the original 16 kHz clock.
/// Align overlapping observations before deciding which words may leave the short window.
public actor GigaAMAdaptivePreview {
    public typealias Decoder = @Sendable ([Float], Bool) async throws -> [GigaAMWordTiming]

    public struct Stats: Sendable {
        public fileprivate(set) var shortCalls = 0
        public fileprivate(set) var longCalls = 0
    }

    public struct Result: Sendable {
        public let words: [GigaAMWordTiming]
        public let stats: Stats
    }

    private static let rate = 16_000
    private static let core = 4 * rate
    private static let margin = rate
    private static let longLimit = 22 * rate
    private let decode: Decoder
    private var state = State()
    private var working = false

    private struct State {
        var count = 0
        var digest: SHA256.Digest?
        var coreStart = 0
        var committed: [GigaAMWordTiming] = []
        var previousTail: [GigaAMWordTiming] = []
        var previousEnd = 0
        var lastLongEnd = 0
        var last: [GigaAMWordTiming] = []
    }

    public init(decode: @escaping Decoder) { self.decode = decode }

    public func preview(growingSamples samples: [Float]) async throws -> Result {
        try Task.checkCancellation()
        guard !self.working, samples.count >= self.state.count else { throw GigaAMError.invalidAudio }
        self.working = true
        defer { self.working = false }
        var next = self.state
        // The provider API also accepts replacement buffers. Do not confirm words against
        // stale PCM. Hash borrowed storage, retaining neither PCM nor a second full buffer.
        next.digest = try samples.withUnsafeBytes { bytes in
            var hash = SHA256()
            let split = next.count * MemoryLayout<Float>.stride
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<split]))
            if let expected = next.digest, hash.finalize() != expected { throw GigaAMError.invalidAudio }
            hash.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[split...]))
            return hash.finalize()
        }
        var stats = Stats()
        if samples.count == next.count { return Result(words: next.last, stats: stats) }

        // A delayed or muted scheduler can jump arbitrarily far. The normal GGUF path
        // covers gaps exceeding the neural model's context; never silently drop them.
        guard samples.count - next.coreStart <= Self.longLimit - Self.margin else { throw GigaAMError.invalidAudio }
        var output = next.last
        while next.previousEnd < samples.count {
            let seal = next.coreStart + Self.core + Self.margin
            let end = min(samples.count, seal)
            let start = max(0, next.coreStart - Self.margin)
            let observed = try await self.recognize(samples, range: start..<end, long: false)
            stats.shortCalls += 1
            var splice = Self.splice(previous: next.committed, observed: observed,
                                     boundary: Double(next.coreStart) / Double(Self.rate),
                                     windowStart: Double(start) / Double(Self.rate))
            let boundary = Double(next.coreStart + Self.core) / Double(Self.rate)
            let pendingCore = splice.tail.prefix { Self.midpoint($0) < boundary }
            let previousCore = next.previousTail.prefix { Self.midpoint($0) < boundary }
            let isSeal = end == seal
            let agreed = previousCore.count == pendingCore.count && zip(previousCore, pendingCore).allSatisfy(Self.sameObservation)
            // A disagreement at a cut (including omissions) needs more evidence.
            // Re-anchor periodically as well: a consistently wrong short draft can agree
            // with itself. During a disputed splice coalesce repairs to one per second.
            let due = end - next.lastLongEnd >= Self.rate
            if (splice.ambiguous && due) || (isSeal && (!agreed || end - next.lastLongEnd >= 2 * Self.core)) {
                let longStart = max(0, end - Self.longLimit)
                let extended = try await self.recognize(samples, range: longStart..<end, long: true)
                stats.longCalls += 1
                next.lastLongEnd = end
                splice = Self.splice(previous: next.committed, observed: extended,
                                     boundary: Double(next.coreStart) / Double(Self.rate),
                                     windowStart: Double(longStart) / Double(Self.rate))
                // Use the expanded observation to replace the provisional segment. If
                // the committed seam itself cannot be recovered, canonical GGUF owns it.
                guard !splice.ambiguous else { throw GigaAMError.invalidOutput }
            }
            output = next.committed + splice.tail
            if isSeal {
                let frozen = splice.tail.prefix { Self.midpoint($0) < boundary }
                next.committed.append(contentsOf: frozen)
                next.previousTail = Array(splice.tail.dropFirst(frozen.count))
                next.coreStart += Self.core
            } else {
                next.previousTail = splice.tail
            }
            next.previousEnd = end
        }
        try Task.checkCancellation()
        next.last = output
        next.count = samples.count
        self.state = next
        return Result(words: output, stats: stats)
    }

    private func recognize(_ samples: [Float], range: Range<Int>, long: Bool) async throws -> [GigaAMWordTiming] {
        try Task.checkCancellation()
        let words = try await self.decode(Array(samples[range]), long)
        try Task.checkCancellation()
        let offset = Double(range.lowerBound) / Double(Self.rate)
        let duration = Double(range.count) / Double(Self.rate)
        var lastStart = 0.0
        return try words.map { word in
            guard word.start.isFinite, word.end.isFinite, word.start >= lastStart,
                  word.end >= word.start, word.end <= duration + 0.000_001 else { throw GigaAMError.invalidOutput }
            lastStart = word.start
            return GigaAMWordTiming(text: word.text, start: word.start + offset,
                                    end: word.end + offset, confidence: word.confidence)
        }
    }

    private static func midpoint(_ word: GigaAMWordTiming) -> Double { (word.start + word.end) / 2 }

    private static func lexicalKey(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "ё", with: "е")
            .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func sameObservation(_ left: GigaAMWordTiming, _ right: GigaAMWordTiming) -> Bool {
        guard abs(midpoint(left) - midpoint(right)) <= 0.24 else { return false }
        let key = lexicalKey(left.text)
        return !key.isEmpty && key == lexicalKey(right.text)
    }

    private static func splice(previous: [GigaAMWordTiming], observed: [GigaAMWordTiming],
                               boundary: Double, windowStart: Double) -> (tail: [GigaAMWordTiming], ambiguous: Bool) {
        guard let last = previous.last else {
            return (observed.filter { midpoint($0) >= boundary }, false)
        }
        // A preceding silent gap may put the anchor outside this window.
        if last.end < windowStart {
            return (observed.filter { midpoint($0) >= boundary }, observed.contains { midpoint($0) < boundary })
        }
        var best = 0
        var unique: Int?
        for end in observed.indices where sameObservation(last, observed[end]) {
            var length = 1
            while length < previous.count, length <= end,
                  sameObservation(previous[previous.count - 1 - length], observed[end - length]) {
                length += 1
            }
            if length > best {
                best = length
                unique = end
            } else if length == best {
                unique = nil
            }
        }
        if let unique { return (Array(observed.dropFirst(unique + 1)), false) }
        return (observed.filter { midpoint($0) >= boundary }, true)
    }
}
