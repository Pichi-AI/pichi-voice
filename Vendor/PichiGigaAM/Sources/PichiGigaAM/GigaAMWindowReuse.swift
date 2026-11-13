import CryptoKit
import Foundation

/// The owner closes this handle before awaiting native cleanup. Late work can
/// never recreate a cache for an ended recording, even across actor suspension.
public final class GigaAMWindowReuseSession: @unchecked Sendable {
    public let id: UUID
    private let lock = NSLock()
    private var open = true

    public init(id: UUID = UUID()) { self.id = id }

    public var isOpen: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.open
    }

    public func invalidate() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.open = false
    }
}

/// Only native outputs are retained. Exact PCM hashes permit reuse even when
/// callers replace a same-length prefix or retract a provisional tail.
struct GigaAMWindowReuse {
    struct Entry {
        let sampleRange: Range<Int>
        let digest: SHA256.Digest
        let capturedFeatures: Bool
        let output: GigaAMTranscript
        let bytes: Int
    }

    private(set) var session: GigaAMWindowReuseSession?
    var sessionID: UUID? { self.session?.id }
    private(set) var entries: [Int: Entry] = [:]
    private(set) var retainedBytes = 0
    private let maximumBytes: Int
    private let maximumWindows: Int

    init(maximumBytes: Int = 128 * 1_024 * 1_024, maximumWindows: Int = 256) {
        self.maximumBytes = maximumBytes
        self.maximumWindows = maximumWindows
    }

    mutating func prepare(session: GigaAMWindowReuseSession?, sampleCount: Int) {
        guard let session, session.isOpen else { self.removeAll(); return }
        if self.session !== session { self.removeAll() }
        self.session = session
        for start in self.entries.keys.filter({ $0 >= sampleCount }) { self.remove(start) }
    }

    mutating func removeAll() {
        self.entries.removeAll()
        self.retainedBytes = 0
        self.session = nil
    }

    mutating func discard(for sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        self.session?.invalidate()
        self.removeAll()
    }

    private mutating func remove(_ start: Int) {
        if let entry = self.entries.removeValue(forKey: start) { self.retainedBytes -= entry.bytes }
    }

    static func digest(_ samples: [Float]) -> SHA256.Digest {
        samples.withUnsafeBytes { SHA256.hash(data: Data($0)) }
    }

    func output(coreStart: Int, sampleRange: Range<Int>, digest: SHA256.Digest,
                captureFeatures: Bool) -> GigaAMTranscript? {
        guard self.session?.isOpen == true, let entry = self.entries[coreStart],
              entry.sampleRange == sampleRange, entry.digest == digest,
              !captureFeatures || entry.capturedFeatures else { return nil }
        if captureFeatures { return entry.output }
        return GigaAMTranscript(text: entry.output.text, confidence: entry.output.confidence,
            words: entry.output.words, endOfUtteranceProbability: entry.output.endOfUtteranceProbability,
            processingDuration: 0)
    }

    mutating func store(_ output: GigaAMTranscript, coreStart: Int, sampleRange: Range<Int>,
                        digest: SHA256.Digest, capturedFeatures: Bool) {
        guard self.session?.isOpen == true else { return }
        self.remove(coreStart)
        let featureBytes = output.encoderWindows.reduce(0) { $0 + $1.features.values.count * MemoryLayout<Float>.size }
        let bytes = featureBytes + output.text.utf8.count
            + output.words.reduce(0) { $0 + MemoryLayout<GigaAMWordTiming>.stride + $1.text.utf8.count }
        guard self.entries.count < self.maximumWindows,
              bytes <= self.maximumBytes - self.retainedBytes else { return }
        self.entries[coreStart] = .init(sampleRange: sampleRange, digest: digest,
            capturedFeatures: capturedFeatures, output: output, bytes: bytes)
        self.retainedBytes += bytes
    }
}

/// Work counters describe inference calls, independently of wall-clock noise.
public struct GigaAMTranscriptionWork: Sendable, Equatable {
    public internal(set) var inferredWindows = 0
    public internal(set) var reusedWindows = 0
    public internal(set) var inferredSamples = 0
}
