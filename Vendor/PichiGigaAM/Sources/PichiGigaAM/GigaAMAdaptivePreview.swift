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
        public let needsCanonicalCheckpoint: Bool
    }

    private static let rate = 16_000
    private static let core = 4 * rate
    private static let margin = rate
    private static let longLimit = 22 * rate
    private let decode: Decoder
    private var state = State()
    private var working = false
    private var closed = false
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    private struct State {
        var count = 0
        var digest: SHA256.Digest?
        var coreStart = 0
        var committed: [GigaAMWordTiming] = []
        var verifiedBoundary = 0
        var verifiedCount = 0
        var previousTail: [GigaAMWordTiming] = []
        var previousEnd = 0
        var lastLongEnd = 0
        var isVerifiedPause = false
        var settledCheckpoint = false
        var needsCheckpoint = false
        var checkpointEnd = 0
        var last: [GigaAMWordTiming] = []

        mutating func adoptCanonical(_ words: [GigaAMWordTiming]) {
            let edge = Double(self.coreStart) / Double(GigaAMAdaptivePreview.rate)
            let prefix = words.prefix { GigaAMAdaptivePreview.midpoint($0) < edge }
            self.committed = Array(prefix)
            self.verifiedBoundary = self.coreStart
            self.verifiedCount = prefix.count
            self.previousTail = Array(words.dropFirst(prefix.count))
        }
    }

    public init(decode: @escaping Decoder) { self.decode = decode }

    private var retained: [Float] = []
    private var hash = SHA256()

    /// A caller with a complete buffer can replace or retract it. Fail closed to the
    /// canonical path if previous observations do not describe these samples.
    public func preview(growingSamples samples: [Float]) async throws -> Result {
        try Task.checkCancellation()
        guard !self.closed, !self.working, samples.count >= self.state.count else { throw GigaAMError.invalidAudio }
        self.working = true
        defer { self.finishWork() }
        let hash = try samples.withUnsafeBytes { bytes in
            var h = SHA256()
            let split = self.state.count * MemoryLayout<Float>.stride
            h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[..<split]))
            if let expected = self.state.digest, h.finalize() != expected { throw GigaAMError.invalidAudio }
            h.update(bufferPointer: UnsafeRawBufferPointer(rebasing: bytes[split...]))
            return h
        }
        return try await self.process(samples, offset: 0, count: samples.count, hash: hash)
    }

    /// The recording service owns the append-only buffer for this admitted capture.
    /// The count check guards missed, repeated, late and out-of-order deltas.
    public func preview(appendingSamples delta: [Float], totalSampleCount: Int) async throws -> Result {
        try Task.checkCancellation()
        guard !self.closed, !self.working, totalSampleCount >= self.state.count,
              totalSampleCount - self.state.count == delta.count,
              delta.count <= Self.longLimit else { throw GigaAMError.invalidAudio }
        self.working = true
        defer { self.finishWork() }
        var hash = self.hash
        delta.withUnsafeBytes { hash.update(bufferPointer: $0) }
        return try await self.process(self.retained + delta, offset: self.state.count - self.retained.count,
                                      count: totalSampleCount, hash: hash)
    }

    private func process(_ samples: [Float], offset: Int, count: Int, hash: SHA256) async throws -> Result {
        var next = self.state
        var stats = Stats()
        if count == next.count { return Result(words: next.last, stats: stats, needsCanonicalCheckpoint: next.needsCheckpoint) }

        // A delayed or muted scheduler can jump arbitrarily far. The normal GGUF path
        // covers gaps exceeding the neural model's context; never silently drop them.
        guard count - next.coreStart <= Self.longLimit - Self.margin else { throw GigaAMError.invalidAudio }
        var output = next.last
        while next.previousEnd < count {
            let seal = next.coreStart + Self.core + Self.margin
            let end = min(count, seal)
            let start = max(0, next.coreStart - Self.margin)
            let observed = try await self.recognize(samples, offset: offset, range: start..<end, long: false)
            stats.shortCalls += 1
            var splice = Self.splice(previous: next.committed, observed: observed,
                                     boundary: Double(next.coreStart) / Double(Self.rate),
                                     windowStart: Double(start) / Double(Self.rate))
            let boundary = Double(next.coreStart + Self.core) / Double(Self.rate)
            let pendingCore = splice.tail.prefix { Self.midpoint($0) < boundary }
            let previousCore = next.previousTail.prefix { Self.midpoint($0) < boundary }
            let isSeal = end == seal
            var usedLong = false
            let agreed = previousCore.count == pendingCore.count && zip(previousCore, pendingCore).allSatisfy(Self.sameObservation)
            // A disagreement at a cut (including omissions) needs more evidence.
            // Re-anchor periodically as well: a consistently wrong short draft can agree
            // with itself. During a disputed splice coalesce repairs to one per second.
            let due = end - next.lastLongEnd >= Self.rate
            if (splice.ambiguous && due) || (isSeal && (!agreed || end - next.lastLongEnd >= 2 * Self.core)) {
                let longStart = max(0, end - Self.longLimit)
                let extended = try await self.recognize(samples, offset: offset, range: longStart..<end, long: true)
                stats.longCalls += 1
                next.lastLongEnd = end
                // Reconcile everything since the previous long-context confirmation.
                // This can restore an omitted short word even if short windows agreed
                // on the omission. Earlier verified words remain on their own clock.
                let verified = Array(next.committed.prefix(next.verifiedCount))
                let repaired = Self.splice(previous: verified, observed: extended,
                                           boundary: Double(next.verifiedBoundary) / Double(Self.rate),
                                           windowStart: Double(longStart) / Double(Self.rate))
                let oldBoundary = Double(next.coreStart) / Double(Self.rate)
                let restored = repaired.tail.prefix { Self.midpoint($0) < oldBoundary }
                next.committed = verified + restored
                splice = (Array(repaired.tail.dropFirst(restored.count)), false)
                next.verifiedCount = next.committed.count
                next.verifiedBoundary = next.coreStart
                usedLong = true
            }
            output = next.committed + splice.tail
            if isSeal {
                let frozen = splice.tail.prefix { Self.midpoint($0) < boundary }
                next.committed.append(contentsOf: frozen)
                next.previousTail = Array(splice.tail.dropFirst(frozen.count))
                next.coreStart += Self.core
                if usedLong {
                    next.verifiedCount = next.committed.count
                    next.verifiedBoundary = next.coreStart
                }
            } else {
                next.previousTail = splice.tail
            }
            next.previousEnd = end
        }
        try Task.checkCancellation()
        guard !self.closed else { throw CancellationError() }
        // A pause is a chance to reconcile even confident omissions against the exact
        // delivery model. The microphone keeps capturing. Short recognition continues
        // on quiet inputs as well, so a softly spoken new word can reopen the draft.
        let quiet = Self.hasTrailingQuiet(samples, end: count - offset)
        let newSpeech = output.last.map { Self.midpoint($0) > Double(next.checkpointEnd) / Double(Self.rate) } ?? false
        if !quiet || newSpeech {
            next.isVerifiedPause = false
            next.settledCheckpoint = false
        }
        let settlePause = next.isVerifiedPause && !next.settledCheckpoint &&
            count - next.checkpointEnd >= Self.rate / 2
        if quiet && next.isVerifiedPause {
            output = next.last
            next.adoptCanonical(output)
        }
        next.needsCheckpoint = quiet && !output.isEmpty && (settlePause ||
            (!next.isVerifiedPause && (next.checkpointEnd == 0 || count - next.checkpointEnd >= Self.rate)))
        next.last = output
        next.count = count
        next.digest = hash.finalize()
        self.hash = hash
        self.retained = Array(samples.suffix(Self.longLimit))
        self.state = next
        return Result(words: output, stats: stats, needsCanonicalCheckpoint: next.needsCheckpoint)
    }

    /// Only accept the response for the exact request still owning this lease/PCM.
    public func acceptCanonicalCheckpoint(_ words: [GigaAMWordTiming], sampleCount: Int) throws {
        try Task.checkCancellation()
        guard !self.closed, !self.working, self.state.needsCheckpoint, self.state.count == sampleCount else { throw CancellationError() }
        self.state.adoptCanonical(words)
        self.state.last = words
        self.state.settledCheckpoint = self.state.isVerifiedPause
        self.state.isVerifiedPause = true
        self.state.needsCheckpoint = false
        self.state.checkpointEnd = sampleCount
    }

    public func close() async {
        self.closed = true
        if self.working {
            await withCheckedContinuation { self.closeWaiters.append($0) }
        }
        self.retained = []
        self.state = State()
        self.hash = SHA256()
    }

    private func finishWork() {
        self.working = false
        let waiters = self.closeWaiters
        self.closeWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func recognize(_ samples: [Float], offset inputOffset: Int, range: Range<Int>, long: Bool) async throws -> [GigaAMWordTiming] {
        try Task.checkCancellation()
        guard range.lowerBound >= inputOffset, range.upperBound - inputOffset <= samples.count else {
            throw GigaAMError.invalidAudio
        }
        let localRange = (range.lowerBound - inputOffset)..<(range.upperBound - inputOffset)
        let words = try await self.decode(Array(samples[localRange]), long)
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

    private static func hasTrailingQuiet(_ samples: [Float], end: Int) -> Bool {
        // Require 320 ms of quiet in every 20 ms frame; one loud burst breaks the pause.
        let frame = 320
        let start = end - 16 * frame
        guard start >= 0 else { return false }
        for first in stride(from: start, to: end, by: frame) {
            var sum: Float = 0
            for i in first..<(first + frame) { sum += samples[i] * samples[i] }
            if sum > 0.000_032 * Float(frame) { return false } // -45 dBFS
        }
        return true
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
