@preconcurrency import AVFoundation
import Foundation

nonisolated enum MeetingMemoryAudioArchiveError: LocalizedError, Equatable {
    case invalidConfiguration
    case invalidPCM
    case unavailable
    case notSealed
    case invalidRange
    case capacityExceeded
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return PichiLocalization.text("The in-memory audio archive configuration is invalid.")
        case .invalidPCM: return PichiLocalization.text("In-memory transcription requires finite mono 16 kHz PCM.")
        case .unavailable: return PichiLocalization.text("The in-memory recording has already been released.")
        case .notSealed: return PichiLocalization.text("The in-memory recording must be stopped before analysis.")
        case .invalidRange: return PichiLocalization.text("The requested in-memory audio range is invalid.")
        case .capacityExceeded: return PichiLocalization.text("The in-memory recording reached its audio memory limit. Completed text was preserved.")
        case .conversionFailed: return PichiLocalization.text("The in-memory audio recording could not be converted.")
        }
    }
}

/// Ephemeral audio for post-stop analysis. There are no file URLs, files or fallback stores.
/// PCM is bounded to one 30-second capture tail and one decoded segment, irrespective of the
/// recording duration. AAC payload grows at 48 kbps (32 kbps on codecs without 48 kbps support),
/// subject to an explicit byte ceiling. Eight hours at 48 kbps is approximately 173 MB of
/// payload, instead of 1.84 GB of mono Float32 PCM. AAC is lossy; this is an analysis copy.
///
/// The existing capture worker calls append synchronously, then seals after intake has joined.
/// The existing analysis worker performs bounded replay. The lock serializes ownership, so
/// clear cannot release storage while a decoder is using it. No detached work outlives a call.
final nonisolated class MeetingMemoryAudioArchive: MeetingPCMReplaySource, @unchecked Sendable {
    static let sampleRate = 16_000
    static let maximumReadSamples = 30 * MeetingMemoryAudioArchive.sampleRate

    private struct Block {
        let data: Data
        let packets: [AudioStreamPacketDescription]
        // Rounded payload allocation plus packet storage and conservative object/array overhead.
        var retainedBytes: Int { ((data.count + 15) / 16) * 16 + packets.count * MemoryLayout<AudioStreamPacketDescription>.stride + 128 }
    }

    private struct Segment {
        let startSample: Int
        let sampleCount: Int
        let format: AVAudioFormat
        let cookie: Data
        let leadingFrames: Int
        let blocks: [Block]
        var retainedBytes: Int { blocks.reduce(cookie.count + 256) { $0 + $1.retainedBytes } }
    }

    private enum State { case recording, sealed, cleared }
    private let lock = NSLock()
    private let maximumRetainedBytes: Int
    private let segmentSamples: Int
    private let pcmFormat: AVAudioFormat
    private let compressedFormat: AVAudioFormat
    private let chosenBitRate: Int
    private var state = State.recording
    private var tail: AVAudioPCMBuffer?
    private var segments: [Segment] = []
    private var sampleCount = 0
    private var encodedBytes = 0
    private var decodedSegmentIndex: Int?
    private var decodedSegment: [Float] = []

    init(maximumRetainedBytes: Int = 256 * 1024 * 1024, segmentSeconds: Int = 30) throws {
        guard maximumRetainedBytes > 0, maximumRetainedBytes <= 1024 * 1024 * 1024,
              (1...30).contains(segmentSeconds),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate),
                                         channels: 1, interleaved: false),
              let tail = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(segmentSeconds * Self.sampleRate))
        else { throw MeetingMemoryAudioArchiveError.invalidConfiguration }
        let (compressed, bitRate): (AVAudioFormat, Int) = try autoreleasepool {
            guard let compressed = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                            AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1]),
                  let probe = AVAudioConverter(from: format, to: compressed) else {
                throw MeetingMemoryAudioArchiveError.conversionFailed
            }
            let supported = Set((probe.applicableEncodeBitRates ?? []).map(\.intValue))
            guard let bitRate = [48_000, 32_000].first(where: { supported.contains($0) }) else {
                throw MeetingMemoryAudioArchiveError.conversionFailed
            }
            probe.bitRate = bitRate
            probe.bitRateStrategy = AVAudioBitRateStrategy_Constant
            guard probe.bitRate == bitRate, probe.maximumOutputPacketSize > 0, probe.maximumOutputPacketSize <= 4096 else {
                throw MeetingMemoryAudioArchiveError.conversionFailed
            }
            return (compressed, bitRate)
        }
        self.maximumRetainedBytes = maximumRetainedBytes
        self.segmentSamples = segmentSeconds * Self.sampleRate
        self.pcmFormat = format
        self.compressedFormat = compressed
        self.chosenBitRate = bitRate
        self.tail = tail
    }

    var totalSampleCount: Int { self.lock.withLock { self.sampleCount } }
    var retainedEncodedBytes: Int { self.lock.withLock { self.encodedBytes } }
    var retainedSegmentCount: Int { self.lock.withLock { self.segments.count } }
    var encodingBitRate: Int? { self.lock.withLock { self.chosenBitRate } }
    var bufferedPCMSampleCount: Int { self.lock.withLock { Int(self.tail?.frameLength ?? 0) + self.decodedSegment.count } }

    /// Validated mono 16 kHz samples, with at most one existing capture callback per call.
    /// A failed append retires all owned audio atomically instead of leaving partial input.
    func append(_ samples: UnsafeBufferPointer<Float>) throws {
        try self.lock.withLock {
            guard self.state == .recording else { throw MeetingMemoryAudioArchiveError.unavailable }
            do {
                guard !samples.isEmpty, samples.count <= 65_536, samples.allSatisfy(\.isFinite),
                      samples.count <= Int.max - self.sampleCount,
                      let tail = self.tail, let destination = tail.floatChannelData?[0]
                else { throw MeetingMemoryAudioArchiveError.invalidPCM }
                var position = 0
                while position < samples.count {
                    let count = min(self.segmentSamples - Int(tail.frameLength), samples.count - position)
                    destination.advanced(by: Int(tail.frameLength)).update(from: samples.baseAddress!.advanced(by: position), count: count)
                    tail.frameLength += AVAudioFrameCount(count)
                    self.sampleCount += count
                    position += count
                    if Int(tail.frameLength) == self.segmentSamples { try self.encodeTailLocked() }
                }
            } catch {
                self.clearLocked()
                throw error
            }
        }
    }

    /// Seal is idempotent. Only sealed recordings can be replayed, preventing live diarization.
    func seal() throws {
        try self.lock.withLock {
            if self.state == .sealed { return }
            guard self.state == .recording else { throw MeetingMemoryAudioArchiveError.unavailable }
            do {
                if self.tail?.frameLength ?? 0 > 0 { try self.encodeTailLocked() }
                self.tail = nil
                self.state = .sealed
            } catch {
                self.clearLocked()
                throw error
            }
        }
    }

    /// Samples are addressed on the original capture timeline, independent of AAC packet size.
    /// The decoder strips the encoder's measured leading frames and drops padded tail frames.
    /// This prevents the 2112-frame AAC priming delay from accumulating at segment boundaries.
    /// A single decoded-segment cache makes sequential short reads linear in recording length.
    func readSamples(in range: Range<Int>) async throws -> [Float] {
        try Task.checkCancellation()
        return try self.lock.withLock {
            guard self.state != .cleared else { throw MeetingMemoryAudioArchiveError.unavailable }
            guard self.state == .sealed else { throw MeetingMemoryAudioArchiveError.notSealed }
            guard range.lowerBound >= 0, range.upperBound <= self.sampleCount,
                  range.count <= Self.maximumReadSamples else { throw MeetingMemoryAudioArchiveError.invalidRange }
            var result: [Float] = []
            result.reserveCapacity(range.count)
            var position = range.lowerBound
            while position < range.upperBound {
                try Task.checkCancellation()
                let index = position / self.segmentSamples
                guard self.segments.indices.contains(index) else { throw MeetingMemoryAudioArchiveError.invalidRange }
                let segment = self.segments[index]
                if self.decodedSegmentIndex != index {
                    // Release the previous cache before allocating its replacement.
                    self.decodedSegment = []
                    self.decodedSegmentIndex = nil
                    self.decodedSegment = try autoreleasepool { try self.decode(segment) }
                    self.decodedSegmentIndex = index
                }
                let relative = position - segment.startSample
                let count = min(range.upperBound - position, segment.sampleCount - relative)
                guard count > 0 else { throw MeetingMemoryAudioArchiveError.invalidRange }
                result.append(contentsOf: self.decodedSegment[relative..<(relative + count)])
                position += count
            }
            return result
        }
    }

    /// The caller joins capture and analysis before clearing. An already-entered synchronous
    /// decode completes under the lock; subsequent replay fails and every retained buffer ends.
    func clear() { self.lock.withLock { self.clearLocked() } }

    private func clearLocked() {
        self.state = .cleared
        self.tail = nil
        self.segments = []
        self.decodedSegment = []
        self.decodedSegmentIndex = nil
        self.sampleCount = 0
        self.encodedBytes = 0
    }

    private func encodeTailLocked() throws {
        guard let tail, tail.frameLength > 0 else { return }
        let segment = try autoreleasepool { try self.encode(tail) }
        guard segment.retainedBytes <= self.maximumRetainedBytes - self.encodedBytes else {
            throw MeetingMemoryAudioArchiveError.capacityExceeded
        }
        self.segments.append(segment)
        self.encodedBytes += segment.retainedBytes
        tail.frameLength = 0
    }

    private func encode(_ input: AVAudioPCMBuffer) throws -> Segment {
        let format = self.compressedFormat
        guard let converter = AVAudioConverter(from: self.pcmFormat, to: format) else {
            throw MeetingMemoryAudioArchiveError.conversionFailed
        }
        converter.bitRate = self.chosenBitRate
        converter.bitRateStrategy = AVAudioBitRateStrategy_Constant
        guard converter.bitRate == self.chosenBitRate,
              converter.maximumOutputPacketSize > 0, converter.maximumOutputPacketSize <= 4096 else {
            throw MeetingMemoryAudioArchiveError.conversionFailed
        }
        var position = 0
        var blocks: [Block] = []
        var retained = 256
        var stalled = 0
        // A finite segment limits input callbacks, packet count and converter drain even if a
        // platform codec returns an unexpected nonterminal status without consuming anything.
        for _ in 0..<(self.segmentSamples / 1024 + 16) {
            let output = AVAudioCompressedBuffer(format: format, packetCapacity: 64,
                                                maximumPacketSize: converter.maximumOutputPacketSize)
            let priorPosition = position
            var callbackFailed = false
            var ownedInput: AVAudioPCMBuffer?
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                guard position < Int(input.frameLength) else { inputStatus.pointee = .endOfStream; return nil }
                let count = min(Int(requested), Int(input.frameLength) - position, 65_536)
                guard count > 0, let buffer = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: AVAudioFrameCount(count)),
                      let destination = buffer.floatChannelData?[0], let source = input.floatChannelData?[0]
                else { callbackFailed = true; inputStatus.pointee = .endOfStream; return nil }
                buffer.frameLength = AVAudioFrameCount(count)
                destination.update(from: source.advanced(by: position), count: count)
                position += count
                ownedInput = buffer
                inputStatus.pointee = .haveData
                return buffer
            }
            withExtendedLifetime(ownedInput) {}
            guard status != .error, error == nil, !callbackFailed else { throw MeetingMemoryAudioArchiveError.conversionFailed }
            if output.packetCount > 0 {
                guard output.packetCount <= 64, output.byteLength <= output.byteCapacity,
                      let descriptions = output.packetDescriptions else { throw MeetingMemoryAudioArchiveError.conversionFailed }
                let block = Block(data: Data(bytes: output.data, count: Int(output.byteLength)),
                                  packets: Array(UnsafeBufferPointer(start: descriptions, count: Int(output.packetCount))))
                guard block.packets.allSatisfy({ $0.mStartOffset >= 0 && $0.mDataByteSize > 0 &&
                    $0.mStartOffset + Int64($0.mDataByteSize) <= Int64(block.data.count) }) else {
                    throw MeetingMemoryAudioArchiveError.conversionFailed
                }
                guard block.retainedBytes <= self.maximumRetainedBytes - self.encodedBytes - retained else {
                    throw MeetingMemoryAudioArchiveError.capacityExceeded
                }
                retained += block.retainedBytes
                blocks.append(block)
            }
            if status == .endOfStream {
                guard position == Int(input.frameLength), !blocks.isEmpty,
                      let cookie = converter.magicCookie, cookie.count <= 4096,
                      converter.primeInfo.leadingFrames <= 8192 else { throw MeetingMemoryAudioArchiveError.conversionFailed }
                return Segment(startSample: self.sampleCount - Int(input.frameLength), sampleCount: Int(input.frameLength),
                               format: format, cookie: cookie, leadingFrames: Int(converter.primeInfo.leadingFrames), blocks: blocks)
            }
            stalled = priorPosition == position && output.packetCount == 0 ? stalled + 1 : 0
            guard stalled < 4 else { throw MeetingMemoryAudioArchiveError.conversionFailed }
        }
        throw MeetingMemoryAudioArchiveError.conversionFailed
    }

    private func decode(_ segment: Segment) throws -> [Float] {
        guard let converter = AVAudioConverter(from: segment.format, to: self.pcmFormat),
              let output = AVAudioPCMBuffer(pcmFormat: self.pcmFormat, frameCapacity: 4096) else {
            throw MeetingMemoryAudioArchiveError.conversionFailed
        }
        converter.magicCookie = segment.cookie
        var blockIndex = 0
        var packetIndex = 0
        var rawFrames = 0
        var result: [Float] = []
        result.reserveCapacity(segment.sampleCount)
        for _ in 0..<(self.segmentSamples / 1024 + 32) {
            try Task.checkCancellation()
            var callbackFailed = false
            var ownedInput: AVAudioCompressedBuffer?
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, inputStatus in
                guard blockIndex < segment.blocks.count else { inputStatus.pointee = .endOfStream; return nil }
                let block = segment.blocks[blockIndex]
                let count = min(Int(requested), block.packets.count - packetIndex, 64)
                guard count > 0 else { callbackFailed = true; inputStatus.pointee = .endOfStream; return nil }
                let packets = block.packets[packetIndex..<(packetIndex + count)]
                let maximumSize = packets.map { Int($0.mDataByteSize) }.max() ?? 0
                guard maximumSize > 0, maximumSize <= 4096 else {
                    callbackFailed = true; inputStatus.pointee = .endOfStream; return nil
                }
                let buffer = AVAudioCompressedBuffer(format: segment.format, packetCapacity: AVAudioPacketCount(count), maximumPacketSize: maximumSize)
                var offset = 0
                for (index, packet) in packets.enumerated() {
                    block.data.withUnsafeBytes { bytes in
                        buffer.data.advanced(by: offset).copyMemory(from: bytes.baseAddress!.advanced(by: Int(packet.mStartOffset)), byteCount: Int(packet.mDataByteSize))
                    }
                    buffer.packetDescriptions?[index] = AudioStreamPacketDescription(mStartOffset: Int64(offset),
                        mVariableFramesInPacket: packet.mVariableFramesInPacket, mDataByteSize: packet.mDataByteSize)
                    offset += Int(packet.mDataByteSize)
                }
                buffer.byteLength = UInt32(offset)
                buffer.packetCount = AVAudioPacketCount(count)
                packetIndex += count
                if packetIndex == block.packets.count { blockIndex += 1; packetIndex = 0 }
                ownedInput = buffer
                inputStatus.pointee = .haveData
                return buffer
            }
            withExtendedLifetime(ownedInput) {}
            guard status != .error, error == nil, !callbackFailed,
                  let samples = output.floatChannelData?[0] else { throw MeetingMemoryAudioArchiveError.conversionFailed }
            let count = Int(output.frameLength)
            let begin = max(0, segment.leadingFrames - rawFrames)
            let end = min(count, segment.leadingFrames + segment.sampleCount - rawFrames)
            if begin < end { result.append(contentsOf: UnsafeBufferPointer(start: samples.advanced(by: begin), count: end - begin)) }
            rawFrames += count
            if status == .endOfStream {
                guard result.count == segment.sampleCount, result.allSatisfy(\.isFinite) else {
                    throw MeetingMemoryAudioArchiveError.conversionFailed
                }
                return result
            }
            guard count > 0 else { throw MeetingMemoryAudioArchiveError.conversionFailed }
        }
        throw MeetingMemoryAudioArchiveError.conversionFailed
    }
}
