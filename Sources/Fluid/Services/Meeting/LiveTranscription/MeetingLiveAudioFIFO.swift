import AudioToolbox
@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// Growing live-caption backlog for retained-file capture only. This is plaintext disk storage,
/// even though its private inode is unlinked before the first audio byte is written. It must not
/// replace a memory-only or encrypted-persistence contract.
///
/// Enqueue transfers immutable ownership of the already copied PCM buffer. The producer must not
/// mutate it afterwards. Capture performs bounded metadata validation/reservation, never file I/O.
/// A serial worker persists packets while the recognizer is loading or busy; RAM holds only the
/// bounded write backlog and one bounded read batch. Failures reject new input instead of evicting
/// the oldest speech. Close joins accepted work; deinit also closes the anonymous descriptor.
final nonisolated class MeetingLiveAudioFIFO: @unchecked Sendable {
    struct Input: Sendable {
        let sample: MeetingLiveSampleCopy.Sample
        let epoch: UInt64
    }

    struct Limits: Sendable {
        var maximumPendingPackets = 512
        var maximumPendingBytes = 8 * 1024 * 1024
        var maximumDiskBytes = 512 * 1024 * 1024
        var maximumBatchPackets = 32
        var maximumBatchBytes = 1024 * 1024
    }

    enum Failure: String, Error, Sendable {
        case invalidInput, pendingCapacity, diskCapacity, storageUnavailable, corruptRecord
    }

    private struct TimeRecord: Codable {
        let value: Int64
        let timescale: Int32
        let flags: UInt32
        let epoch: Int64
        init(_ time: CMTime) {
            value = time.value; timescale = time.timescale
            flags = time.flags.rawValue; epoch = time.epoch
        }
        var time: CMTime { CMTime(value: value, timescale: timescale, flags: CMTimeFlags(rawValue: flags), epoch: epoch) }
    }

    private struct Header: Codable {
        let version: Int
        let asbd: Data
        let layout: Data?
        let frames: UInt32
        let bufferBytes: [UInt32]
        let bufferChannels: [UInt32]
        let pts: TimeRecord
        let duration: TimeRecord
        let epoch: UInt64
        var clockPacket: MeetingCaptureClockMetadata.Packet? = nil
    }

    private struct Packet: @unchecked Sendable {
        let input: Input
        let header: Data
        let payloadBytes: Int
        let memoryBytes: Int
        var recordBytes: Int { 8 + header.count + payloadBytes }
    }

    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumChannels = 64
    private let lock = NSLock()
    private let ioQueue: DispatchQueue
    private let limits: Limits
    private let temporaryDirectory: URL
    // Admission state is protected by lock. Queue submission shares that lock so a close/read
    // cannot overtake an accepted write from a concurrent capture callback.
    private var accepting = true
    private var pendingPackets = 0
    private var pendingBytes = 0
    private var dropped = 0
    private var failure: Failure?
    private var unreportedFailure: Failure?
    // File state belongs exclusively to ioQueue. Queued work retains self, so deinit cannot race it.
    private var descriptor: Int32 = -1
    private var readOffset = 0
    private var writeOffset = 0
    private var closed = false
    private var readFailed = false
    private var unreadPackets = 0

    init(limits: Limits = Limits(), temporaryDirectory: URL = FileManager.default.temporaryDirectory,
         ioQueue: DispatchQueue? = nil) {
        precondition(limits.maximumPendingPackets > 0 && limits.maximumPendingPackets <= 512)
        precondition(limits.maximumPendingBytes > 0 && limits.maximumPendingBytes <= 8 * 1024 * 1024)
        precondition(limits.maximumDiskBytes > 0 && limits.maximumDiskBytes <= 512 * 1024 * 1024)
        precondition(limits.maximumBatchPackets > 0 && limits.maximumBatchPackets <= 32)
        precondition(limits.maximumBatchBytes > 0 && limits.maximumBatchBytes <= 1024 * 1024)
        self.limits = limits
        self.temporaryDirectory = temporaryDirectory
        self.ioQueue = ioQueue ?? DispatchQueue(label: "meeting.live-caption.audio-fifo", qos: .userInitiated)
    }

    deinit {
        // Every queued operation owns self until it finishes. No synchronous queue hop is needed,
        // including when the final reference is released by the I/O queue itself.
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    /// True means accepted. A rejection increments the loss count and never removes older input.
    @discardableResult
    func enqueue(_ input: Input) -> Bool {
        let packet: Packet
        do { packet = try Self.packet(input, maximumRecordBytes: limits.maximumBatchBytes) }
        catch { recordFailure(.invalidInput, losses: 1); return false }
        return lock.withLock {
            guard accepting else { addLossesLocked(1); return false }
            guard pendingPackets < limits.maximumPendingPackets,
                  packet.memoryBytes <= limits.maximumPendingBytes - pendingBytes else {
                failLocked(.pendingCapacity, losses: 1)
                return false
            }
            pendingPackets += 1; pendingBytes += packet.memoryBytes
            ioQueue.async { [self, packet] in
                defer { lock.withLock { pendingPackets -= 1; pendingBytes -= packet.memoryBytes } }
                guard lock.withLock({ failure == nil }) else { lock.withLock { addLossesLocked(1) }; return }
                do { try write(packet) }
                catch let reason as Failure { recordFailure(reason, losses: 1) }
                catch { recordFailure(.storageUnavailable, losses: 1) }
            }
            return true
        }
    }

    /// Cancellation before submission leaves the FIFO untouched. Once submitted, this bounded
    /// read is joined and returned even if its caller is cancelled, so a consumed batch is never
    /// silently abandoned by an internal cancellation check.
    func drainBatch() async throws -> [Input] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                ioQueue.async { [self] in
                    if let reason = lock.withLock({ () -> Failure? in
                        defer { unreportedFailure = nil }; return unreportedFailure
                    }) {
                        continuation.resume(throwing: reason)
                        return
                    }
                    do { continuation.resume(returning: try readBatch()) }
                    catch let reason as Failure {
                        readFailed = true
                        recordFailure(reason, losses: unreadPackets)
                        lock.withLock { unreportedFailure = nil }
                        continuation.resume(throwing: reason)
                    } catch {
                        readFailed = true
                        recordFailure(.storageUnavailable, losses: unreadPackets)
                        lock.withLock { unreportedFailure = nil }
                        continuation.resume(throwing: Failure.storageUnavailable)
                    }
                }
            }
        }
    }

    func takeDroppedCount() -> Int {
        lock.withLock { defer { dropped = 0 }; return dropped }
    }

    func close() async {
        await withCheckedContinuation { continuation in
            lock.withLock {
                accepting = false
                ioQueue.async { [self] in
                    if descriptor >= 0 { _ = Darwin.close(descriptor); descriptor = -1 }
                    closed = true; readOffset = 0; writeOffset = 0
                    unreadPackets = 0
                    continuation.resume()
                }
            }
        }
    }

    private func recordFailure(_ reason: Failure, losses: Int) { lock.withLock { failLocked(reason, losses: losses) } }
    private func failLocked(_ reason: Failure, losses: Int) {
        if failure == nil { failure = reason; unreportedFailure = reason }
        accepting = false
        addLossesLocked(losses)
    }
    private func addLossesLocked(_ count: Int) { dropped += min(count, Int.max - dropped) }

    private static func packet(_ input: Input, maximumRecordBytes: Int) throws -> Packet {
        let sample = input.sample, buffer = sample.buffer
        let frames = Int(buffer.frameLength), channels = Int(buffer.format.channelCount)
        guard frames > 0, frames <= maximumRecordBytes / 4, buffer.frameLength <= buffer.frameCapacity,
              (1...Self.maximumChannels).contains(channels),
              UInt64(buffer.frameCapacity) * UInt64(channels) * 4 <= 8 * 1024 * 1024,
              sample.pts.isValid, sample.pts.isNumeric, sample.pts.seconds.isFinite,
              sample.duration.isValid, sample.duration.isNumeric, sample.duration.seconds.isFinite,
              sample.duration > .zero else { throw Failure.invalidInput }
        _ = try MeetingPCMFormatContract(audioFormat: buffer.format)
        if let packet = sample.clockPacket {
            _ = try packet.mapping.validated(expectedFrameCount: Int64(frames))
            guard let start = packet.mapping.spans.first?.hostStart,
                  abs(start.seconds - sample.pts.seconds) <= 1e-9 else { throw Failure.invalidInput }
        }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let interleaved = buffer.format.isInterleaved
        guard buffers.count == (interleaved ? 1 : channels) else { throw Failure.invalidInput }
        let expected = frames * 4 * (interleaved ? channels : 1)
        guard buffers.allSatisfy({ Int($0.mDataByteSize) == expected && $0.mData != nil
            && Int($0.mNumberChannels) == (interleaved ? channels : 1) }) else { throw Failure.invalidInput }
        let payloadBytes = expected * buffers.count
        let asbd = Data(bytes: buffer.format.streamDescription, count: MemoryLayout<AudioStreamBasicDescription>.size)
        let layout = MeetingPCMFormatContract.layoutData(buffer.format.channelLayout)
        guard (layout?.count ?? 0) <= 4096 else { throw Failure.invalidInput }
        let header = try JSONEncoder().encode(Header(version: 1, asbd: asbd, layout: layout,
            frames: buffer.frameLength, bufferBytes: buffers.map(\.mDataByteSize), bufferChannels: buffers.map(\.mNumberChannels),
            pts: TimeRecord(sample.pts), duration: TimeRecord(sample.duration), epoch: input.epoch,
            clockPacket: sample.clockPacket))
        guard header.count <= maximumHeaderBytes, payloadBytes <= maximumRecordBytes - min(maximumRecordBytes, 8 + header.count)
        else { throw Failure.invalidInput }
        let memoryBytes = Int(buffer.frameCapacity) * channels * 4 + header.count + 512
        return Packet(input: input, header: header, payloadBytes: payloadBytes, memoryBytes: memoryBytes)
    }

    private func openIfNeeded() throws {
        guard descriptor < 0 else { return }
        let url = temporaryDirectory.appendingPathComponent(".meeting-live-fifo-\(UUID().uuidString)")
        let fd = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.storageUnavailable }
        guard Darwin.fchmod(fd, 0o600) == 0, Darwin.unlink(url.path) == 0 else {
            _ = Darwin.close(fd); _ = Darwin.unlink(url.path)
            throw Failure.storageUnavailable
        }
        descriptor = fd
    }

    private func write(_ packet: Packet) throws {
        guard !closed else { throw Failure.storageUnavailable }
        // This bounds physical high-water size, not just unread bytes. Partial draining never
        // permits an unlimited append-only file; a complete drain resets both offsets below.
        guard packet.recordBytes <= limits.maximumDiskBytes - writeOffset else { throw Failure.diskCapacity }
        try openIfNeeded()
        let buffers = UnsafeMutableAudioBufferListPointer(packet.input.sample.buffer.mutableAudioBufferList)
        var payload = Data(capacity: packet.payloadBytes)
        for buffer in buffers {
            guard let bytes = buffer.mData else { throw Failure.invalidInput }
            let values = UnsafeBufferPointer(start: bytes.assumingMemoryBound(to: Float.self), count: Int(buffer.mDataByteSize) / 4)
            guard values.allSatisfy(\.isFinite) else { throw Failure.invalidInput }
            payload.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(buffer.mDataByteSize))
        }
        guard payload.count == packet.payloadBytes else { throw Failure.invalidInput }
        var prefix = Data()
        for value in [UInt32(packet.header.count), UInt32(packet.payloadBytes)] {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { prefix.append(contentsOf: $0) }
        }
        try writeAll(prefix, offset: writeOffset)
        try writeAll(packet.header, offset: writeOffset + 8)
        try writeAll(payload, offset: writeOffset + 8 + packet.header.count)
        writeOffset += packet.recordBytes
        unreadPackets += 1
    }

    private func readBatch() throws -> [Input] {
        guard !closed, !readFailed, descriptor >= 0, readOffset < writeOffset else { return [] }
        var cursor = readOffset, used = 0
        var output: [Input] = []
        while cursor < writeOffset, output.count < limits.maximumBatchPackets {
            let prefix = try readExact(8, offset: cursor)
            let headerBytes = Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            let payloadBytes = Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) })
            let total = 8 + headerBytes + payloadBytes
            guard headerBytes > 0, headerBytes <= Self.maximumHeaderBytes, payloadBytes > 0,
                  total <= limits.maximumBatchBytes, total <= writeOffset - cursor else { throw Failure.corruptRecord }
            if used + total > limits.maximumBatchBytes { break }
            let header = try JSONDecoder().decode(Header.self, from: readExact(headerBytes, offset: cursor + 8))
            let payload = try readExact(payloadBytes, offset: cursor + 8 + headerBytes)
            output.append(try Self.decode(header, payload: payload))
            cursor += total; used += total
        }
        // Do not commit any consumed offset until the complete bounded batch has decoded.
        if cursor == writeOffset {
            guard Darwin.ftruncate(descriptor, 0) == 0 else { throw Failure.storageUnavailable }
            readOffset = 0; writeOffset = 0
        } else {
            readOffset = cursor
            try reclaimConsumedPrefix()
        }
        unreadPackets -= output.count
        return output
    }

    /// Reclaim a consumed prefix even when a busy recognizer never quite empties the FIFO.
    /// Otherwise a small steady backlog could exhaust the file bound over a long meeting.
    private func reclaimConsumedPrefix() throws {
        let threshold = min(8 * 1024 * 1024, max(1, limits.maximumDiskBytes / 4))
        guard readOffset >= threshold, readOffset >= writeOffset / 2 else { return }
        let remaining = writeOffset - readOffset
        var copied = 0
        while copied < remaining {
            // Source stays ahead of destination, including with small synthetic limits.
            let count = min(1024 * 1024, readOffset, remaining - copied)
            let bytes = try readExact(count, offset: readOffset + copied)
            try writeAll(bytes, offset: copied)
            copied += count
        }
        guard Darwin.ftruncate(descriptor, off_t(remaining)) == 0 else { throw Failure.storageUnavailable }
        readOffset = 0
        writeOffset = remaining
    }

    private static func decode(_ header: Header, payload: Data) throws -> Input {
        guard header.version == 1, header.asbd.count == MemoryLayout<AudioStreamBasicDescription>.size,
              header.frames > 0, !header.bufferBytes.isEmpty,
              header.bufferBytes.count <= Self.maximumChannels, header.bufferBytes.count == header.bufferChannels.count,
              header.bufferBytes.reduce(UInt64(0), { $0 + UInt64($1) }) == UInt64(payload.count)
        else { throw Failure.corruptRecord }
        var asbd = header.asbd.withUnsafeBytes { $0.loadUnaligned(as: AudioStreamBasicDescription.self) }
        guard (1...UInt32(Self.maximumChannels)).contains(asbd.mChannelsPerFrame),
              UInt64(header.frames) * UInt64(asbd.mChannelsPerFrame) * 4 == UInt64(payload.count)
        else { throw Failure.corruptRecord }
        _ = try MeetingPCMFormatContract(asbd: asbd, layoutData: header.layout)
        let layout: AVAudioChannelLayout?
        if let data = header.layout {
            guard data.count >= 12, data.count <= 4096 else { throw Failure.corruptRecord }
            let descriptions = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self) }
            let tag = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard descriptions <= UInt32(Self.maximumChannels),
                  data.count == (tag == kAudioChannelLayoutTag_UseChannelDescriptions ? 12 + Int(descriptions) * MemoryLayout<AudioChannelDescription>.stride : 12)
            else { throw Failure.corruptRecord }
            let bytes = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, MemoryLayout<AudioChannelLayout>.size), alignment: MemoryLayout<AudioChannelLayout>.alignment)
            defer { bytes.deallocate() }
            bytes.initializeMemory(as: UInt8.self, repeating: 0, count: max(data.count, MemoryLayout<AudioChannelLayout>.size))
            data.copyBytes(to: bytes.assumingMemoryBound(to: UInt8.self), count: data.count)
            layout = AVAudioChannelLayout(layout: bytes.assumingMemoryBound(to: AudioChannelLayout.self))
        } else if asbd.mChannelsPerFrame > 2 {
            layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | asbd.mChannelsPerFrame)
        } else { layout = nil }
        guard let format = AVAudioFormat(streamDescription: &asbd, channelLayout: layout),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: header.frames) else { throw Failure.corruptRecord }
        buffer.frameLength = header.frames
        let targets = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard targets.count == header.bufferBytes.count else { throw Failure.corruptRecord }
        var offset = 0
        for index in targets.indices {
            let count = Int(header.bufferBytes[index])
            guard targets[index].mDataByteSize == header.bufferBytes[index], targets[index].mNumberChannels == header.bufferChannels[index],
                  let target = targets[index].mData else { throw Failure.corruptRecord }
            payload.withUnsafeBytes { bytes in target.copyMemory(from: bytes.baseAddress!.advanced(by: offset), byteCount: count) }
            offset += count
        }
        if let packet = header.clockPacket {
            _ = try packet.mapping.validated(expectedFrameCount: Int64(header.frames))
            guard let start = packet.mapping.spans.first?.hostStart,
                  abs(start.seconds - header.pts.time.seconds) <= 1e-9 else { throw Failure.corruptRecord }
        }
        let sample = MeetingLiveSampleCopy.Sample(buffer: buffer, pts: header.pts.time,
            duration: header.duration.time, clockPacket: header.clockPacket)
        let input = Input(sample: sample, epoch: header.epoch)
        _ = try packet(input, maximumRecordBytes: 1024 * 1024)
        return input
    }

    private func writeAll(_ data: Data, offset: Int) throws {
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < data.count {
                let count = Darwin.pwrite(descriptor, bytes.baseAddress!.advanced(by: written), data.count - written, off_t(offset + written))
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.storageUnavailable }
                written += count
            }
        }
    }

    private func readExact(_ count: Int, offset: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var read = 0
            while read < count {
                let size = Darwin.pread(descriptor, bytes.baseAddress!.advanced(by: read), count - read, off_t(offset + read))
                if size < 0, errno == EINTR { continue }
                guard size > 0 else { throw Failure.corruptRecord }
                read += size
            }
        }
        return data
    }

    #if DEBUG
    struct TestingState: Sendable { let pendingPackets: Int; let pendingBytes: Int; let diskBytes: Int; let links: UInt16; let permissions: UInt16 }
    func testingState() async -> TestingState {
        await withCheckedContinuation { continuation in
            lock.withLock { ioQueue.async { [self] in
                var info = stat()
                let status = descriptor >= 0 ? Darwin.fstat(descriptor, &info) : -1
                let pending = lock.withLock { (pendingPackets, pendingBytes) }
                continuation.resume(returning: TestingState(pendingPackets: pending.0, pendingBytes: pending.1,
                    diskBytes: writeOffset, links: status == 0 ? UInt16(info.st_nlink) : 0,
                    permissions: status == 0 ? UInt16(info.st_mode & 0o777) : 0))
            } }
        }
    }
    #endif
}
