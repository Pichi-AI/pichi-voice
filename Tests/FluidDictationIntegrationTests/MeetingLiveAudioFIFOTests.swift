import AudioToolbox
import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class MeetingLiveAudioFIFOTests: XCTestCase {
    private func fixture(limits: MeetingLiveAudioFIFO.Limits = .init(), queue: DispatchQueue? = nil) throws -> (MeetingLiveAudioFIFO, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-fifo-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fifo = MeetingLiveAudioFIFO(limits: limits, temporaryDirectory: directory, ioQueue: queue)
        addTeardownBlock { await fifo.close(); try? FileManager.default.removeItem(at: directory) }
        return (fifo, directory)
    }

    private func input(_ index: Int, frames: UInt32 = 16, channels: UInt32 = 1, interleaved: Bool = false,
                       layout: AVAudioChannelLayout? = nil) throws -> MeetingLiveAudioFIFO.Input {
        let format: AVAudioFormat
        if let layout {
            format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: interleaved, channelLayout: layout))
        } else {
            format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: interleaved))
        }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for (channel, audio) in buffers.enumerated() {
            let values = try XCTUnwrap(audio.mData?.assumingMemoryBound(to: Float.self))
            for sample in 0..<(Int(audio.mDataByteSize) / 4) { values[sample] = Float(index) / 1024 + Float(channel + sample) / 65_536 }
        }
        let pts = CMTime(value: Int64(index * 16), timescale: 48_000, flags: [.valid, .hasBeenRounded], epoch: 7)
        let duration = CMTime(value: Int64(frames), timescale: 48_000, flags: [.valid, .hasBeenRounded], epoch: 0)
        return .init(sample: .init(buffer: buffer, pts: pts, duration: duration), epoch: UInt64(index))
    }

    func testColdBacklogBeyond512PacketsPreservesFirstPacketAndFIFOOrder() async throws {
        let (fifo, directory) = try fixture()
        for group in 0..<12 {
            for index in (group * 64)..<((group + 1) * 64) { XCTAssertTrue(fifo.enqueue(try input(index))) }
            // Join only disk writes. The recognizer/consumer has not read anything yet.
            _ = await fifo.testingState()
        }
        let state = await fifo.testingState()
        XCTAssertGreaterThan(state.diskBytes, 0)
        XCTAssertEqual(state.links, 0)
        XCTAssertEqual(state.permissions, 0o600)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        var indexes: [UInt64] = []
        while true {
            let batch = try await fifo.drainBatch()
            if batch.isEmpty { break }
            XCTAssertLessThanOrEqual(batch.count, 32)
            indexes.append(contentsOf: batch.map(\.epoch))
        }
        XCTAssertEqual(indexes, (0..<768).map(UInt64.init))
        XCTAssertEqual(fifo.takeDroppedCount(), 0)
        let drained = await fifo.testingState()
        XCTAssertEqual(drained.diskBytes, 0, "the fully consumed anonymous spool must truncate")
    }

    func testConsumedPrefixIsReclaimedWithoutWaitingForAnEmptyFIFO() async throws {
        var limits = MeetingLiveAudioFIFO.Limits()
        limits.maximumDiskBytes = 64 * 1024
        limits.maximumBatchPackets = 1
        let (fifo, _) = try fixture(limits: limits)
        for index in 0..<20 { XCTAssertTrue(fifo.enqueue(try input(index, frames: 256))) }
        _ = await fifo.testingState()
        var observed: [UInt64] = []
        for round in 0..<10 {
            // Always retain at least four unread packets. A never-empty FIFO must still
            // reclaim old physical file bytes rather than fail a long meeting later.
            for _ in 0..<16 {
                let batch = try await fifo.drainBatch()
                observed.append(try XCTUnwrap(batch.first).epoch)
            }
            for index in (20 + round * 16)..<(36 + round * 16) {
                XCTAssertTrue(fifo.enqueue(try input(index, frames: 256)))
            }
            let state = await fifo.testingState()
            XCTAssertLessThanOrEqual(state.diskBytes, limits.maximumDiskBytes)
        }
        while true {
            let batch = try await fifo.drainBatch()
            if batch.isEmpty { break }
            observed.append(contentsOf: batch.map(\.epoch))
        }
        XCTAssertEqual(observed, (0..<180).map(UInt64.init))
        XCTAssertEqual(fifo.takeDroppedCount(), 0)
    }

    func testPCMFormatLayoutBytesTimestampsAndEpochRoundTripExactly() async throws {
        let (fifo, _) = try fixture()
        let surround = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
        let originals = [try input(3), try input(4, channels: 2, interleaved: true), try input(5, channels: 6, layout: surround)]
        for value in originals { XCTAssertTrue(fifo.enqueue(value)) }
        let decoded = try await fifo.drainBatch()
        XCTAssertEqual(decoded.count, originals.count)
        for (expected, actual) in zip(originals, decoded) {
            XCTAssertEqual(actual.epoch, expected.epoch)
            for (left, right) in [(actual.sample.pts, expected.sample.pts), (actual.sample.duration, expected.sample.duration)] {
                XCTAssertEqual(left.value, right.value); XCTAssertEqual(left.timescale, right.timescale)
                XCTAssertEqual(left.flags, right.flags); XCTAssertEqual(left.epoch, right.epoch)
            }
            XCTAssertEqual(actual.sample.buffer.format, expected.sample.buffer.format)
            XCTAssertEqual(actual.sample.buffer.frameLength, expected.sample.buffer.frameLength)
            let a = UnsafeMutableAudioBufferListPointer(actual.sample.buffer.mutableAudioBufferList)
            let b = UnsafeMutableAudioBufferListPointer(expected.sample.buffer.mutableAudioBufferList)
            XCTAssertEqual(a.count, b.count)
            for index in a.indices {
                XCTAssertEqual(a[index].mNumberChannels, b[index].mNumberChannels)
                XCTAssertEqual(a[index].mDataByteSize, b[index].mDataByteSize)
                let left = Data(bytes: try XCTUnwrap(a[index].mData), count: Int(a[index].mDataByteSize))
                let right = Data(bytes: try XCTUnwrap(b[index].mData), count: Int(b[index].mDataByteSize))
                XCTAssertEqual(left, right)
            }
        }
    }

    func testPendingCapacityRejectsNewInputAndReportsOneFailureWithoutOldestEviction() async throws {
        let queue = DispatchQueue(label: "test.live-fifo.suspended")
        queue.suspend()
        var limits = MeetingLiveAudioFIFO.Limits(); limits.maximumPendingPackets = 2
        let (fifo, _) = try fixture(limits: limits, queue: queue)
        XCTAssertTrue(fifo.enqueue(try input(0)))
        XCTAssertTrue(fifo.enqueue(try input(1)))
        XCTAssertFalse(fifo.enqueue(try input(2)))
        queue.resume()
        _ = await fifo.testingState()
        do { _ = try await fifo.drainBatch(); XCTFail("bounded admission must report failure") }
        catch { XCTAssertEqual(error as? MeetingLiveAudioFIFO.Failure, .pendingCapacity) }
        let afterFailure = try await fifo.drainBatch()
        XCTAssertTrue(afterFailure.isEmpty)
        XCTAssertEqual(fifo.takeDroppedCount(), 3)
        XCTAssertEqual(fifo.takeDroppedCount(), 0)
        let state = await fifo.testingState()
        XCTAssertEqual(state.pendingPackets, 0); XCTAssertEqual(state.pendingBytes, 0)
    }

    func testByteAndDiskBudgetsRejectExplicitlyAndCloseJoinsLateInput() async throws {
        var memory = MeetingLiveAudioFIFO.Limits(); memory.maximumPendingBytes = 1
        let (memoryFIFO, _) = try fixture(limits: memory)
        XCTAssertFalse(memoryFIFO.enqueue(try input(0)))
        do { _ = try await memoryFIFO.drainBatch(); XCTFail("byte budget must report failure") }
        catch { XCTAssertEqual(error as? MeetingLiveAudioFIFO.Failure, .pendingCapacity) }
        var disk = MeetingLiveAudioFIFO.Limits(); disk.maximumDiskBytes = 128
        let (diskFIFO, _) = try fixture(limits: disk)
        XCTAssertTrue(diskFIFO.enqueue(try input(0)))
        _ = await diskFIFO.testingState()
        do { _ = try await diskFIFO.drainBatch(); XCTFail("disk budget must report failure") }
        catch { XCTAssertEqual(error as? MeetingLiveAudioFIFO.Failure, .diskCapacity) }
        let (fifo, directory) = try fixture()
        XCTAssertTrue(fifo.enqueue(try input(0)))
        await fifo.close()
        XCTAssertFalse(fifo.enqueue(try input(1)))
        let late = try await fifo.drainBatch()
        XCTAssertTrue(late.isEmpty)
        XCTAssertEqual(fifo.takeDroppedCount(), 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testInvalidInputIsRejectedBeforeDiskAndAnonymousStorageIsReleasedOnDeinit() async throws {
        let (invalid, _) = try fixture()
        let original = try input(0)
        let bad = MeetingLiveAudioFIFO.Input(sample: .init(buffer: original.sample.buffer, pts: .invalid, duration: original.sample.duration), epoch: 0)
        XCTAssertFalse(invalid.enqueue(bad))
        do { _ = try await invalid.drainBatch(); XCTFail("invalid input must report failure") }
        catch { XCTAssertEqual(error as? MeetingLiveAudioFIFO.Failure, .invalidInput) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-fifo-deinit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var fifo: MeetingLiveAudioFIFO? = MeetingLiveAudioFIFO(temporaryDirectory: directory)
        weak var weakFIFO = fifo
        XCTAssertTrue(try XCTUnwrap(fifo).enqueue(input(1)))
        _ = await fifo?.testingState()
        fifo = nil
        for _ in 0..<100 where weakFIFO != nil { await Task.yield() }
        XCTAssertNil(weakFIFO)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
