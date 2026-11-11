import AVFoundation
import CoreMedia
import CryptoKit
import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

private final class MeetingPCMFailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { self.lock.lock(); self.count += 1; self.lock.unlock() }
    func value() -> Int { self.lock.lock(); defer { lock.unlock() }; return self.count }
}

private final class MeetingWriterEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeetingCaptureEvent] = []

    func record(_ event: MeetingCaptureEvent) {
        self.lock.withLock { self.events.append(event) }
    }

    func snapshot() -> [MeetingCaptureEvent] {
        self.lock.withLock { self.events }
    }
}

private final class MeetingCaptureFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    private var first = true
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func blockOnce() {
        let block = self.lock.withLock { let value = self.first; self.first = false; return value }
        if block { self.entered.fulfill(); _ = self.release.wait(timeout: .now() + 10) }
    }
}

private final class MeetingJournalFailureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true
    func recover() { self.lock.withLock { self.failing = false } }
    func check(_ operation: MeetingAudioRecordingJournal.Operation) throws {
        if self.lock.withLock({ self.failing }), case .manifest = operation {
            throw MeetingAudioChunkLedgerError.durabilityFailure("synthetic metadata failure")
        }
    }
}

private final class MeetingRejectedSpeechConsumer: MeetingMemoryAudioConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var accepted = 0
    private var finished = 0
    var finishCount: Int { self.lock.withLock { self.finished } }
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        self.lock.withLock { self.accepted += 1; return self.accepted < 3 }
    }
    func finish() async throws {
        self.lock.withLock { self.finished += 1 }
        throw MeetingCapturePCMError.transcriptionStopped
    }
}

/// P1a's sink fixtures intentionally use real ready CMSampleBuffers.  These tests stay in the
/// integration target because the sink is an internal harness type, not a package product.
final class MeetingAudioChunkSinkTests: XCTestCase {
    func testStopJoinsJournalEvenWhenAllOptionalAcknowledgementSlotsAreOccupied() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "journal held")
        let gate = MeetingCaptureFaultGate(entered)
        defer { gate.release.signal() }
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic",
            format: nil, timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [])
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: { _ in }, persistenceHook: { op in if case .manifest = op { gate.blockOnce() } })
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 0)))
        let acknowledged = MeetingPCMFailureCounter()
        for _ in 0..<128 { writer.enqueueMetadata(failClosed: true, mutate: { _ in }, completion: { _ in acknowledged.increment() }) }
        _ = await writer.snapshot()
        let earlyReturn = expectation(description: "Stop must wait for its terminal receipt")
        earlyReturn.isInverted = true
        let stop = Task { let track = await writer.stop(); earlyReturn.fulfill(); return track }
        await fulfillment(of: [earlyReturn], timeout: 0.05)
        gate.release.signal()
        let captured = await stop.value
        XCTAssertEqual(acknowledged.value(), 128)
        XCTAssertEqual(captured.chunks.first?.captureAnalysisAsset?.frameCount, 480)
        XCTAssertEqual(captured.chunks.first?.finalizationState, .finalized)
    }

    @MainActor
    func testRejectedSpeechConsumerDoesNotStopRealWriterAndJoinsItsResources() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic ASR failure",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"), speakerProcessingMode: .streaming)
        let timebase = MeetingTimebaseMetadata(startedHostTime: AVAudioTime.hostTime(forSeconds: 1_000),
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        let session = MeetingSession(configuration: configuration, timebase: timebase)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic",
            format: nil, timebase: timebase, health: .waiting, chunks: [])
        let consumer = MeetingRejectedSpeechConsumer(), events = MeetingWriterEventRecorder()
        let prepared = try await MeetingMultiTrackCaptureTee.prepare(session: session, configuration: configuration,
            tracks: [track], consumerFactory: { _, _, _, _ in consumer }, eventHandler: events.record,
            liveAudioHandler: nil, privacyGate: nil, clockContexts: [:])
        let tee = try XCTUnwrap(prepared)
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: events.record, diagnosticSampleObserver: { sample, _ in tee.offer(kind: .microphone, sample: sample) })
        for index in 0..<30 {
            XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil,
                frameCount: 480, pts: 1_000 + Double(index) / 100)))
            _ = await writer.snapshot(); await tee.drainEnqueuedPackets()
        }
        let captured = await writer.stop()
        do { try await tee.finish(); XCTFail("Recognition error must remain visible") } catch {}
        XCTAssertEqual(consumer.finishCount, 1)
        XCTAssertEqual(captured.chunks.compactMap { $0.captureAnalysisAsset?.frameCount }.reduce(0, +), 14_400)
        XCTAssertEqual(captured.health.droppedSampleCount, 0)
        XCTAssertTrue(events.snapshot().contains { if case .interrupted(.liveTranscriptionDeferred, _, _) = $0 { return true }; return false })
        XCTAssertFalse(events.snapshot().contains { if case .interrupted(.captureStoppedUnexpectedly, _, _) = $0 { return true }; return false })
    }

    func testClosedPCMIsRecoveredFromChunkJournalWhenTrackIndexIsMissing() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic index recovery",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"))
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
            firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic",
            format: nil, timebase: timebase, health: .waiting, chunks: [])
        session.audioTracks = [track]
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: directory, chunkDuration: 60,
            eventHandler: { _ in }, persistenceHook: { operation in
                if case .finalize = operation { throw MeetingAudioChunkLedgerError.durabilityFailure("synthetic verifier failure") }
            })
        for index in 0..<20 {
            XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil,
                frameCount: 480, pts: Double(index) / 100)))
        }
        let pending = await writer.stop()
        XCTAssertEqual(pending.chunks.first?.finalizationState, .writing)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("tracks/microphone/track.json"))
        try FileManager.default.removeItem(at: directory.appendingPathComponent("chunk-ledger"))
        let loaded = try await store.load(id: session.id)
        let recovered = try XCTUnwrap(loaded?.audioTracks.first?.chunks.first)
        XCTAssertEqual(recovered.finalizationState, .finalized)
        XCTAssertEqual(recovered.captureAnalysisAsset?.frameCount, 9_600)
        let audio = try AVAudioFile(forReading: directory.appendingPathComponent(recovered.relativeFilePath))
        XCTAssertEqual(audio.length, 9_600)
    }

    func testBlockedMetadataCannotBlockPCMOrGrowTheCaptureQueue() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "optional metadata worker entered")
        let gate = MeetingCaptureFaultGate(entered)
        defer { gate.release.signal() }
        let events = MeetingWriterEventRecorder()
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [])
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: events.record, persistenceHook: { operation in
                if case .manifest = operation { gate.blockOnce() }
            })
        await fulfillment(of: [entered], timeout: 2)
        for index in 0..<200 {
            XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil,
                frameCount: 480, pts: Double(index) / 100, exactPTS: CMTime(value: Int64(index * 480), timescale: 48_000))))
            if index % 20 == 19 { _ = await writer.snapshot() }
        }
        _ = await writer.beginSplice()
        let blocked = await writer.snapshot()
        XCTAssertEqual(blocked.chunks.first?.captureAnalysisAsset?.frameCount, 96_000)
        XCTAssertEqual(blocked.chunks.first?.finalizationState, .writing)
        XCTAssertEqual(writer.retainedPCMBytes, 0, "A blocked metadata worker must retain no capture PCM")
        let partial = try XCTUnwrap(blocked.chunks.first?.captureAnalysisAsset?.relativeFilePath)
        let captured = try AVAudioFile(forReading: root.appendingPathComponent(partial))
        XCTAssertEqual(captured.length, 96_000, "Audio is readable before the metadata worker resumes")
        XCTAssertFalse(events.snapshot().contains { if case .interrupted(.captureStoppedUnexpectedly, _, _) = $0 { return true }; return false })
        gate.release.signal()
        let stopped = await writer.stop()
        XCTAssertEqual(stopped.chunks.first?.finalizationState, .finalized)
        XCTAssertEqual(stopped.chunks.first?.captureAnalysisAsset?.frameCount, 96_000)
    }

    func testPCMQueueOverflowRecordsItsGapAndAcceptsLaterAudio() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = expectation(description: "controlled audio stall")
        let gate = MeetingCaptureFaultGate(entered)
        defer { gate.release.signal() }
        let events = MeetingWriterEventRecorder()
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [])
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: events.record, pendingSlotLimit: 1, diagnosticSampleObserver: { _, _ in gate.blockOnce() })
        XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 0)))
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertFalse(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 0.01)))
        gate.release.signal(); _ = await writer.snapshot()
        XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 1)))
        let stopped = await writer.stop()
        XCTAssertEqual(stopped.health.droppedSampleCount, 1)
        XCTAssertEqual(stopped.chunks.compactMap { $0.captureAnalysisAsset?.frameCount }.reduce(0, +), 960)
        XCTAssertEqual(stopped.chunks.last?.presentationEnd.seconds ?? 0, 1.01, accuracy: 1e-8)
        XCTAssertEqual(writer.retainedPCMBytes, 0)
        XCTAssertFalse(events.snapshot().contains { if case .interrupted(.captureStoppedUnexpectedly, _, _) = $0 { return true }; return false })
    }

    func testMetadataFailurePreservesPCMAndCanRecoverWithoutRestartingCapture() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = MeetingWriterEventRecorder()
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [])
        let fault = MeetingJournalFailureSwitch()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: events.record, persistenceHook: fault.check)
        for index in 0..<10 {
            XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil,
                frameCount: 480, pts: Double(index) / 100)))
        }
        do { try await writer.updateTrackMetadata { _ in }; XCTFail("Injected metadata failure must be surfaced") }
        catch {}
        _ = await writer.beginSplice()
        let duringFailure = await writer.snapshot()
        XCTAssertEqual(duringFailure.chunks.first?.captureAnalysisAsset?.frameCount, 4_800)
        fault.recover()
        XCTAssertTrue(try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 1)))
        let stopped = await writer.stop()
        XCTAssertEqual(stopped.chunks.compactMap { $0.captureAnalysisAsset?.frameCount }.reduce(0, +), 5_280)
        XCTAssertTrue(stopped.chunks.allSatisfy { $0.finalizationState == .finalized })
        XCTAssertTrue(events.snapshot().contains { if case .interrupted(.metadataPersistenceDelayed, _, _) = $0 { return true }; return false })
        XCTAssertTrue(events.snapshot().contains { if case .interrupted(.metadataPersistenceRecovered, _, _) = $0 { return true }; return false })
    }

    func testTwoHourMicrophoneAndApplicationCaptureKeepEveryFrameAndBoundedManifests() async throws {
        for kind in [MeetingAudioTrackKind.microphone, .applicationAudio] {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil, recordingTimePolicy: .hostMonotonicV1)
        let track = MeetingAudioTrack(id: UUID(), kind: kind, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic long call", format: nil, timebase: timebase, health: .waiting, chunks: [])
        let context = try MeetingRecordingClock(timebase: timebase).source(track.id)
        let events = MeetingWriterEventRecorder(), terminalFailures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: events.record, clockContext: context)
        let gate = MeetingMicrophoneTranscriptGate(.unprotected)
        let liveOffers = MeetingPCMFailureCounter()
        let committer = MeetingAECOutputCommitter(writer: writer, transcriptGate: gate,
            liveAudioHandler: { _, _ in liveOffers.increment() }, terminalFailure: { _ in terminalFailures.increment() })
        let seconds = 120 * 60, rate = 48_000, baseTicks: Int64 = 586_026_000_000_000
        // One-second synthetic packets retain the native 512/1024-frame clock breakpoints.
        // Each source clock and PCM cover two hours; no microphone, model or wall-clock wait is used.
        func host(_ frame: Int) -> MeetingMediaTime {
            .init(value: baseTicks + Int64((Double(frame) * 1_000_000_000 / Double(rate)).rounded()),
                  timescale: 1_000_000_000)
        }
        for second in 0..<seconds {
            let sample = try self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: rate,
                pts: Double(baseTicks) / 1_000_000_000 + Double(second))
            var spans: [MeetingAudioClockSpan] = [], frame = 0, packet = 0
            while frame < rate {
                let end = min(rate, frame + (packet % 3 == 2 ? 1_024 : 512))
                spans.append(.init(frameStart: Double(frame), frameEnd: Double(end),
                    hostStart: host(second * rate + frame), hostEnd: host(second * rate + end),
                    discontinuityBefore: second == 0 && frame == 0))
                frame = end; packet += 1
            }
            let mapping = MeetingAudioClockMapping(frameCount: Int64(rate), spans: spans)
            try MeetingCaptureClockMetadata.attach(mapping: mapping, clockID: context.clockID,
                sourceID: context.sourceID, producerEpoch: 1, to: sample)
            if kind == .microphone { committer.commitCaptured(sample, protection: .acousticallyClosed) }
            else { XCTAssertTrue(writer.enqueue(sample, onConsumed: { liveOffers.increment() })) }
            if second % 8 == 7 { await committer.waitForPendingCommits(); _ = await writer.snapshot() }
            // Splicing only seals the native handle. Optional verification/indexing remains
            // asynchronous, so this exercises real journal backlog without a finalizer barrier.
            if second % 60 == 59 {
                await committer.waitForPendingCommits()
                _ = await writer.beginSplice()
            }
        }
        await committer.waitForPendingCommits(); committer.finish()
        let saved = await writer.stop()
        XCTAssertEqual(saved.chunks.count, 120)
        XCTAssertEqual(liveOffers.value(), seconds)
        XCTAssertEqual(terminalFailures.value(), 0)
        XCTAssertEqual(saved.health.droppedSampleCount, 0)
        XCTAssertFalse(events.snapshot().contains { if case .interrupted = $0 { return true }; return false })
        XCTAssertTrue(saved.chunks.allSatisfy { $0.finalizationState == .finalized })
        XCTAssertEqual(saved.chunks.compactMap { $0.captureAnalysisAsset?.frameCount }.reduce(0, +), Int64(seconds * rate))
        for (index, chunk) in saved.chunks.enumerated() {
            let mapping = try XCTUnwrap(chunk.clockMapping)
            XCTAssertLessThanOrEqual(mapping.spans.count, 2, "Rounded native clock packets must not inflate every later manifest")
            XCTAssertEqual(mapping.spans.first?.hostStart, host(index * 60 * rate))
            XCTAssertEqual(mapping.spans.last?.hostEnd, host((index + 1) * 60 * rate))
            let file = try AVAudioFile(forReading: root.appendingPathComponent(chunk.relativeFilePath),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            XCTAssertEqual(file.length, Int64(60 * rate))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
            while file.framePosition < file.length {
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { return XCTFail("Synthetic CAF ended before its declared frame count") }
                let data = try XCTUnwrap(buffer.floatChannelData?[0])
                XCTAssertTrue(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)).allSatisfy { $0 == 0.25 })
            }
        }
        let manifest = try Data(contentsOf: root.appendingPathComponent("tracks/\(kind.rawValue)/track.json"))
        XCTAssertLessThan(manifest.count, 400_000, "A long call must not rewrite tens of megabytes on its PCM queue")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let persisted = try decoder.decode(MeetingAudioTrack.self, from: manifest)
        XCTAssertEqual(persisted.chunks, saved.chunks)
        }
    }

    @MainActor
    func testInRoomStreamingUsesSharedEpochAwareTeeAndExactWriterEndpointsAtRealUptime() async throws {
        for channels in [1, 2] {
        for changesProducer in [false, true] {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        let origin = 203_315.0, base = 203_316.843104167
        let timebase = MeetingTimebaseMetadata(startedHostTime: AVAudioTime.hostTime(forSeconds: origin),
            machTimebaseNumerator: info.numer, machTimebaseDenominator: info.denom,
            firstPresentationTime: nil, recordingTimePolicy: .hostMonotonicV1)
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic native clock",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"), speakerProcessingMode: .streaming)
        let session = MeetingSession(configuration: configuration, timebase: timebase)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])
        let context = try MeetingRecordingClock(timebase: timebase).source(track.id)
        let consumer = try MeetingMicrophoneWriterPrivacyTests.MappedConsumer(originSeconds: origin)
        let events = MeetingWriterEventRecorder()
        let prepared = try await MeetingMultiTrackCaptureTee.prepare(session: session, configuration: configuration,
            tracks: [track], consumerFactory: { requestedSession, _, requestedTrack, _ in
                XCTAssertEqual(requestedSession.id, session.id)
                XCTAssertEqual(requestedTrack.id, track.id)
                return consumer
            }, eventHandler: events.record, liveAudioHandler: nil, privacyGate: nil, clockContexts: [.microphone: context])
        let tee = try XCTUnwrap(prepared)
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: events.record, diagnosticSampleObserver: { sample, _ in tee.offer(kind: .microphone, sample: sample) },
            clockContext: context)
        let clock = MeetingCaptureSourceClock(context: context)
        var epochs = Set<UInt64>(), lastEnd: MeetingMediaTime?
        func offer(_ sample: CMSampleBuffer) throws {
            let packet = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: sample))
            epochs.insert(packet.producerEpoch); lastEnd = packet.mapping.spans.last?.hostEnd
            XCTAssertTrue(writer.enqueue(sample))
        }
        for index in 0..<25 {
            let layout: UInt32? = index.isMultiple(of: 2) ? nil
                : (channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo)
            let raw = try makeRawSampleBuffer(channelCount: channels, layoutTag: layout, frameCount: 512,
                pts: base + Double(index * 512) / 48_000, interleaved: index.isMultiple(of: 2))
            let generation: UInt64 = changesProducer && index >= 12 ? 2 : 1
            for measured in try clock.offer(raw, producerGeneration: generation, sourceFrameStart: Int64(index * 512)) { try offer(measured) }
            _ = await writer.snapshot(); await tee.drainEnqueuedPackets()
        }
        for tail in try clock.finish() { try offer(tail) }
        let saved = await writer.stop(); try await tee.finish()
        XCTAssertEqual(epochs.count, changesProducer ? 2 : 1, "Equivalent PCM layouts cannot invent producer epochs")
        XCTAssertEqual(saved.chunks.count, changesProducer ? 2 : 1, "Only the real producer boundary may split a recording")
        let chunk = try XCTUnwrap(saved.chunks.last)
        XCTAssertEqual(saved.chunks.compactMap { $0.captureAnalysisAsset?.frameCount }.reduce(0, +), 25 * 512)
        XCTAssertEqual(chunk.presentationEnd, lastEnd)
        XCTAssertEqual(chunk.presentationEnd, chunk.clockMapping?.spans.last?.hostEnd)
        if !changesProducer { XCTAssertTrue(chunk.discontinuities.isEmpty) }
        XCTAssertEqual(consumer.timeline.hasGaps, changesProducer)
        XCTAssertEqual(consumer.frameCount, 25 * 512 / 3)
        XCTAssertEqual(consumer.finishCount, 1)
        XCTAssertFalse(events.snapshot().contains { if case .interrupted = $0 { return true }; return false })
        }
        }
    }

    @MainActor
    func testStreamingPreparationJoinsAlreadyPreparedConsumersOnFailure() async throws {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        let configuration = MeetingCaptureConfiguration(mode: .onlineCall, title: "Synthetic failed preparation",
            application: .init(bundleIdentifier: "synthetic", displayName: "Synthetic"),
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"), speakerProcessingMode: .streaming)
        let session = MeetingSession(configuration: configuration, timebase: timebase)
        let mic = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "mic", sourceDisplayName: "Mic",
            format: nil, timebase: timebase, health: .waiting, chunks: [])
        var app = mic; app.id = UUID(); app.kind = .applicationAudio
        let first = try MeetingMicrophoneWriterPrivacyTests.MappedConsumer()
        do {
            let prepared = try await MeetingMultiTrackCaptureTee.prepare(session: session, configuration: configuration,
                tracks: [mic, app], consumerFactory: { _, _, track, _ in
                    if track.kind == .applicationAudio { throw CancellationError() }
                    return first
                }, eventHandler: { _ in }, liveAudioHandler: nil, privacyGate: nil, clockContexts: [:])
            XCTAssertNil(prepared, "A failed recognizer must leave retained capture available")
        } catch { XCTFail("Optional recognition preparation must not veto retained audio: \(error)") }
        XCTAssertEqual(first.finishCount, 1)
        XCTAssertEqual(first.frameCount, 0)
    }
    func testUnsupportedMicrophoneBuffersReportOneFailureAndRecover() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        let events = MeetingWriterEventRecorder()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) {
            events.record($0)
        }
        let integerFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let integerBytes = [Int16](repeating: 100, count: 480).withUnsafeBytes { Data($0) }
        for index in 0..<1_000 {
            let sample = try self.makeSampleBuffer(format: integerFormat, bytes: integerBytes, frameCount: 480, pts: Double(index) * 0.01)
            XCTAssertTrue(writer.enqueue(sample))
            // Drain each callback to test format rejection, rather than producer backpressure.
            _ = await writer.snapshot()
        }
        let rejected = await writer.snapshot()
        XCTAssertEqual(rejected.health.status, .degraded)
        XCTAssertTrue(rejected.chunks.isEmpty)
        XCTAssertEqual(rejected.health.detail, "Unsupported PCM format: native Float32 LPCM required.")
        XCTAssertEqual(events.snapshot().count, 2, "One interruption and one degraded health update for the whole failure episode")
        if case let .trackHealth(trackID, health) = events.snapshot().last {
            XCTAssertEqual(trackID, track.id)
            XCTAssertEqual(health.status, .degraded)
        } else {
            XCTFail("The coordinator must receive degraded track health")
        }

        writer.enqueue(try self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 10))
        let recovered = await writer.snapshot()
        XCTAssertEqual(recovered.health.status, .healthy)
        XCTAssertNil(recovered.health.detail)
        if case let .trackHealth(_, health) = events.snapshot().last {
            XCTAssertEqual(health.status, .healthy)
        } else {
            XCTFail("Recovery must publish healthy track status immediately")
        }

        // The first rejection retires the active sink; later ones fail before a sink exists.
        // Both paths belong to one new failure episode, even though their error strings differ.
        for index in 1_001..<1_101 {
            writer.enqueue(try self.makeSampleBuffer(format: integerFormat, bytes: integerBytes, frameCount: 480, pts: Double(index) * 0.01))
            _ = await writer.snapshot()
        }
        let failures = events.snapshot().filter {
            if case .interrupted(.writerFailure, _, _) = $0 { return true }
            return false
        }
        XCTAssertEqual(failures.count, 2, "Recovery re-arms reporting exactly once")
        writer.enqueue(try self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 11.01))
        let stopped = await writer.stop()
        XCTAssertEqual(stopped.chunks.filter { $0.finalizationState == .finalized }.count, 2, "A rejected later buffer must not delete previously captured PCM")
    }

    func testLayoutlessThreeChannelMicrophoneResolvesCopiesConvertsAndWrites() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sample = try self.makeRawSampleBuffer(channelCount: 3, layoutTag: nil, frameCount: 512, pts: 1.25)
        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(sample))
        XCTAssertNil(MeetingPCMFormatContract.layoutData(description))

        let format = try MeetingPCMFormatResolver.resolve(description)
        XCTAssertEqual(format.channelCount, 3)
        XCTAssertNotNil(format.channelLayout)

        let copied = try XCTUnwrap(MeetingLiveSampleCopy.copy(sample))
        XCTAssertEqual(copied.buffer.format.channelCount, 1)
        XCTAssertEqual(copied.buffer.frameLength, 512)
        XCTAssertEqual(copied.pts.seconds, 1.25, accuracy: 0.000_001)
        let copiedSamples = try Array(UnsafeBufferPointer(
            start: XCTUnwrap(copied.buffer.floatChannelData?[0]),
            count: Int(copied.buffer.frameLength)
        ))
        XCTAssertTrue(copiedSamples.allSatisfy { abs($0 - 0.25) < 0.000_001 })

        let mono = try self.convertToMono(copied.buffer)
        XCTAssertEqual(mono.format.channelCount, 1)
        XCTAssertEqual(mono.format.sampleRate, 16_000)
        XCTAssertGreaterThan(mono.frameLength, 0)

        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(
            track: track, sessionDirectory: root, chunkDuration: 60
        ) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        writer.enqueue(sample)
        let result = await writer.stop()
        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        XCTAssertEqual(chunk.captureAnalysisAsset?.channelCount, 3)
        XCTAssertEqual(chunk.captureAnalysisAsset?.frameCount, 512)
        XCTAssertEqual(failures.value(), 0)
    }

    func testWriterAcceptsEquivalentRawMonoLayoutsWithoutRotatingOrFailing() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .applicationAudio,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        let tags: [UInt32?] = [nil, kAudioChannelLayoutTag_Mono, nil, kAudioChannelLayoutTag_DiscreteInOrder | 1]
        for (index, tag) in tags.enumerated() {
            try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: tag, frameCount: 480, pts: Double(index) * 0.01))
        }
        let result = await writer.stop()
        let chunk = try XCTUnwrap(result.chunks.first)
        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        XCTAssertEqual(chunk.captureAnalysisAsset?.frameCount, 1920)
        XCTAssertEqual(failures.value(), 0)
        XCTAssertEqual(chunk.discontinuities, [])
        let file = try AVAudioFile(forReading: root.appendingPathComponent(chunk.relativeFilePath), commonFormat: .pcmFormatFloat32, interleaved: true)
        XCTAssertEqual(file.length, 1920)
    }

    func testWriterRotatesExactlyOnceForGenuineMonoToStereoChange() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .applicationAudio,
            sourceIdentifier: "test",
            sourceDisplayName: "Test",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        let failures = MeetingPCMFailureCounter()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) { event in
            if case .interrupted(.writerFailure, _, _) = event { failures.increment() }
        }
        try writer.enqueue(self.makeRawSampleBuffer(channelCount: 1, layoutTag: nil, frameCount: 480, pts: 0))
        try writer.enqueue(self.makeRawSampleBuffer(channelCount: 2, layoutTag: kAudioChannelLayoutTag_Stereo, frameCount: 480, pts: 0.01))
        let result = await writer.stop()
        XCTAssertEqual(result.chunks.count, 2)
        XCTAssertEqual(result.chunks.map { $0.captureAnalysisAsset?.frameCount }, [480, 480])
        XCTAssertEqual(result.chunks.map(\.finalizationState), [.finalized, .finalized])
        XCTAssertEqual(failures.value(), 0)
    }

    func testSinkFormatMismatchErrorUsesNormalizedExpectedAndActualContracts() throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        let mono = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        try sink.begin(relativeFilePath: "mismatch.caf", format: mono)
        XCTAssertThrowsError(try sink.append(self.makeRawSampleBuffer(channelCount: 2, layoutTag: kAudioChannelLayoutTag_Stereo, frameCount: 2, pts: 0))) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(message.contains("lpcm-f32 rate=48000.0 channels=1 layout=mono"), message)
            XCTAssertTrue(message.contains("lpcm-f32 rate=48000.0 channels=2 layout=stereo"), message)
        }
        sink.cancel()
    }

    func testPCMFormatContractCanonicalizesEquivalentMonoAndStereoLayouts() throws {
        let monoNil = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let mono = try XCTUnwrap(try AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Mono))
        ))
        let discrete0 = try XCTUnwrap(try AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 1))
        ))
        let stereoNil = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let stereo = try XCTUnwrap(try AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: true,
            channelLayout: XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        ))

        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: monoNil), try MeetingPCMFormatContract(audioFormat: mono))
        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: mono), try MeetingPCMFormatContract(audioFormat: discrete0))
        XCTAssertEqual(try MeetingPCMFormatContract(audioFormat: stereoNil), try MeetingPCMFormatContract(audioFormat: stereo))
        XCTAssertNotEqual(try MeetingPCMFormatContract(audioFormat: monoNil), try MeetingPCMFormatContract(audioFormat: stereoNil))
        XCTAssertThrowsError(try MeetingPCMFormatContract(audioFormat: XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))))
    }

    func testMonoAndStereoPreserveFramesPTSAndPublishCAF() async throws {
        for channels in [1, 2] {
            let root = try self.makeDirectory()
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: true))
            let samples: [Float] = (0..<(17 * channels)).map { Float($0 + 1) / 100 }
            let buffer = try self.makeSampleBuffer(format: format, interleavedSamples: samples, frameCount: 17, pts: 2.25)
            let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
            try sink.begin(relativeFilePath: "tracks/application/000001.caf", format: format)
            let receipt = try sink.append(buffer)
            XCTAssertEqual(receipt.framesAccepted, 17)
            XCTAssertEqual(receipt.framesWritten, 17)
            XCTAssertEqual(receipt.presentationStart.seconds, 2.25, accuracy: 0.000_001)
            XCTAssertEqual(receipt.presentationDuration.seconds, 17.0 / 48_000.0, accuracy: 0.000_001)
            let result = sink.finalize()
            let finalization = try result.get()
            XCTAssertEqual(finalization.frameCount, 17)
            XCTAssertEqual(finalization.channelCount, channels)
            XCTAssertEqual(finalization.sampleRate, 48_000)
            let finalURL = root.appendingPathComponent("tracks/application/000001.caf")
            let file = try AVAudioFile(
                forReading: finalURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            let readBuffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 17))
            try file.read(into: readBuffer)
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            let read = Array(UnsafeBufferPointer(start: readBuffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self), count: samples.count))
            XCTAssertEqual(read, samples)
            let digest = try SHA256.hash(data: Data(contentsOf: finalURL)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(finalization.sha256, digest)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("tracks/application/000001.partial.caf").path))
            let mode = try (FileManager.default.attributesOfItem(atPath: finalURL.path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(mode, Int(0o600))
            let parentMode = try (FileManager.default.attributesOfItem(atPath: finalURL.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
            XCTAssertEqual(parentMode, Int(0o700))
        }
    }

    func testRejectsFormatDriftAndNonFiniteWithoutPublishing() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let otherFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: true))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "chunk.caf", format: format)
        XCTAssertThrowsError(try sink.append(self.makeSampleBuffer(format: otherFormat, interleavedSamples: [0, 1], frameCount: 2, pts: 0)))
        // A format mismatch poisons the sink and closes its file. Subsequent buffers must not be
        // retried against that instance; the writer retires the chunk and opens a fresh one.
        XCTAssertThrowsError(try sink.append(self.makeSampleBuffer(format: format, interleavedSamples: [0], frameCount: 1, pts: .nan))) { error in
            XCTAssertEqual(error as? MeetingPCMSinkError, .alreadyFinalizedOrCancelled)
        }
        sink.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("chunk.caf").path))
    }

    func testConfinementExistingFinalAndStalePartialAreFailClosed() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        XCTAssertThrowsError(try sink.begin(relativeFilePath: "../escape.caf", format: format))
        let partial = root.appendingPathComponent("chunk.partial.caf")
        try Data([1, 2, 3]).write(to: partial)
        try sink.begin(relativeFilePath: "chunk.caf", format: format)
        _ = try sink.append(self.makeSampleBuffer(
            format: format,
            interleavedSamples: [0.25],
            frameCount: 1,
            pts: 0
        ))
        let staleFinalization = sink.finalize()
        _ = try staleFinalization.get()
        XCTAssertEqual(try Data(contentsOf: partial), Data([1, 2, 3]), "stale partial must not be promoted or removed")
        try FileManager.default.removeItem(at: root.appendingPathComponent("chunk.caf"))
        try Data([1]).write(to: root.appendingPathComponent("chunk.caf"))
        let existingFinalSink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        XCTAssertThrowsError(try existingFinalSink.begin(relativeFilePath: "chunk.caf", format: format)) { error in
            XCTAssertEqual(error as? MeetingPCMSinkError, .finalPathAlreadyExists("chunk.caf"))
        }
        let outside = root.deletingLastPathComponent().appendingPathComponent("FluidVoice-P1a-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try MeetingAudioFilePCMChunkSink(sessionDirectory: root).begin(relativeFilePath: "linked/escape.caf", format: format)) { error in
            XCTAssertEqual(error as? MeetingPCMSinkError, .symlinkComponentRejected(link.path))
        }
    }

    func testCancelAndFailedFinalizeNeverCreateFinal() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "cancel.caf", format: format)
        sink.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("cancel.caf").path))
        let failed = sink.finalize()
        XCTAssertEqual(failed, .failure(.alreadyFinalizedOrCancelled))
    }

    func testNonInterleavedStereoIsPackedInChannelOrderAndCountsPackets() async throws {
        let root = try self.makeDirectory()
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            interleaved: false,
            channelLayout: layout
        ))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "noninterleaved.caf", format: format)
        // Planar input: left frames followed by right frames. The file is interleaved L/R.
        let first = try self.makeSampleBuffer(format: format, interleavedSamples: [0.1, 0.2, 0.3, 0.4, 1.1, 1.2, 1.3, 1.4], frameCount: 4, pts: 0)
        let second = try self.makeSampleBuffer(format: format, interleavedSamples: [0.5, 0.6, 1.5, 1.6], frameCount: 2, pts: 4.0 / 48_000.0)
        XCTAssertEqual(try sink.append(first).framesWritten, 4)
        XCTAssertEqual(try sink.append(second).framesWritten, 2)
        let finalization = try sink.finalize().get()
        XCTAssertEqual(finalization.frameCount, 6)
        let file = try AVAudioFile(forReading: root.appendingPathComponent("noninterleaved.caf"), commonFormat: .pcmFormatFloat32, interleaved: true)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 6))
        try file.read(into: buffer)
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let values = Array(UnsafeBufferPointer(start: buffer.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self), count: 12))
        XCTAssertEqual(values, [0.1, 1.1, 0.2, 1.2, 0.3, 1.3, 0.4, 1.4, 0.5, 1.5, 0.6, 1.6])
    }

    func testFinalizeWithoutFramesFailsAndCleansOwnedPartial() async throws {
        let root = try self.makeDirectory()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: true
        ))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: "empty.caf", format: format)

        let result = sink.finalize()

        guard case let .failure(.finalizationVerificationFailed(detail)) = result else {
            return XCTFail("Expected an empty-CAF verification failure, got \(result)")
        }
        XCTAssertEqual(detail, "CAF contains no written frames")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("empty.caf").path))
        let partials = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains(".partial.") }
        XCTAssertTrue(partials.isEmpty)
    }

    private func convertToMono(_ source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let converter = try XCTUnwrap(AVAudioConverter(from: source.format, to: monoFormat))
        let capacity = AVAudioFrameCount(
            (Double(source.frameLength) * monoFormat.sampleRate / source.format.sampleRate).rounded(.up)
        ) + 16
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity))
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if let conversionError { throw conversionError }
        XCTAssertNotEqual(status, .error)
        return output
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoice-P1a-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return url
    }

    private func makeRawSampleBuffer(channelCount: Int, layoutTag: UInt32?, frameCount: Int, pts: Double,
                                     interleaved: Bool = true, exactPTS: CMTime? = nil) throws -> CMSampleBuffer {
        let bytesPerFrame = (interleaved ? channelCount : 1) * MemoryLayout<Float>.size
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | (interleaved ? 0 : kAudioFormatFlagIsNonInterleaved),
            mBytesPerPacket: UInt32(bytesPerFrame),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bytesPerFrame),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let layout = layoutTag.flatMap { AVAudioChannelLayout(layoutTag: $0) }
        let layoutStatus: OSStatus
        if let layout, let layoutData = MeetingPCMFormatContract.layoutData(layout) {
            layoutStatus = layoutData.withUnsafeBytes { bytes in
                CMAudioFormatDescriptionCreate(
                    allocator: kCFAllocatorDefault,
                    asbd: &asbd,
                    layoutSize: layoutData.count,
                    // Fixed test fixture: missing required audio storage or evidence is a setup failure.
                    // swiftlint:disable:next force_unwrapping
                    layout: bytes.baseAddress!.assumingMemoryBound(to: AudioChannelLayout.self),
                    magicCookieSize: 0,
                    magicCookie: nil,
                    extensions: nil,
                    formatDescriptionOut: &description
                )
            }
        } else {
            layoutStatus = CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                asbd: &asbd,
                layoutSize: 0,
                layout: nil,
                magicCookieSize: 0,
                magicCookie: nil,
                extensions: nil,
                formatDescriptionOut: &description
            )
        }
        XCTAssertEqual(layoutStatus, noErr)
        let values = Array(repeating: Float(0.25), count: frameCount * channelCount)
        let bytes = values.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block
        ), noErr)
        let blockBuffer = try XCTUnwrap(block)
        XCTAssertEqual(
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            bytes.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes.count) },
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: exactPTS ?? CMTime(seconds: pts, preferredTimescale: 48_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            try CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: XCTUnwrap(description),
                sampleCount: frameCount,
                sampleTimingEntryCount: 1,
                sampleTimingArray: &timing,
                sampleSizeEntryCount: 0,
                sampleSizeArray: nil,
                sampleBufferOut: &sample
            ),
            noErr
        )
        return try XCTUnwrap(sample)
    }

    private func makeSampleBuffer(format: AVAudioFormat, interleavedSamples: [Float], frameCount: Int, pts: Double) throws -> CMSampleBuffer {
        try self.makeSampleBuffer(
            format: format, bytes: interleavedSamples.withUnsafeBytes { Data($0) }, frameCount: frameCount, pts: pts
        )
    }

    private func makeSampleBuffer(format: AVAudioFormat, bytes: Data, frameCount: Int, pts: Double) throws -> CMSampleBuffer {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: bytes.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: bytes.count,
            flags: 0,
            blockBufferOut: &block
        )
        guard status == noErr, let block else { throw NSError(domain: "P1a", code: Int(status)) }
        status = bytes.withUnsafeBytes { ptr in
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            CMBlockBufferReplaceDataBytes(with: ptr.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard status == noErr else { throw NSError(domain: "P1a", code: Int(status)) }
        let presentationTimeStamp = pts.isFinite
            ? CMTime(seconds: pts, preferredTimescale: 1_000_000)
            : .invalid
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: Int32(format.sampleRate)),
            presentationTimeStamp: presentationTimeStamp,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: format.formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw NSError(domain: "P1a", code: Int(status)) }
        return sampleBuffer
    }
}

extension MeetingAudioChunkSinkTests {
    func testNativeIntegerMicrophonesConvertWithoutChangingFramesChannelsOrTiming() throws {
        let normalizer = MeetingMicrophonePCMNormalizer()
        // One producer changes between USB/Bluetooth-style rates, widths and channel layouts.
        for rate in [16_000.0, 44_100.0, 48_000.0, 96_000.0] {
            for bits in [16, 24, 32] {
                for channels in [1, 2, 3] {
                    for planar in [false, true] {
                        let (source, expected) = try self.integerMicrophoneSample(bits: bits, channels: channels, rate: rate, planar: planar)
                        XCTAssertThrowsError(try MeetingPCMFormatContract(formatDescription: XCTUnwrap(CMSampleBufferGetFormatDescription(source))))
                        let normalized = normalizer.normalize(source)
                        XCTAssertFalse(normalized === source)
                        let description = try XCTUnwrap(CMSampleBufferGetFormatDescription(normalized))
                        let contract = try MeetingPCMFormatContract(formatDescription: description)
                        XCTAssertEqual(contract.sampleRate, rate)
                        XCTAssertEqual(contract.channelCount, channels)
                        XCTAssertEqual(MeetingPCMFormatContract.layoutData(description), try MeetingPCMFormatContract.layoutData(XCTUnwrap(CMSampleBufferGetFormatDescription(source))))
                        XCTAssertEqual(CMSampleBufferGetNumSamples(normalized), CMSampleBufferGetNumSamples(source))
                        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(normalized), CMSampleBufferGetPresentationTimeStamp(source))
                        XCTAssertEqual(CMSampleBufferGetDuration(normalized), CMSampleBufferGetDuration(source))
                        XCTAssertEqual(CMSampleBufferGetDecodeTimeStamp(normalized), CMSampleBufferGetDecodeTimeStamp(source))
                        let format = try MeetingPCMFormatResolver.resolve(description)
                        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12))
                        pcm.frameLength = 12
                        XCTAssertEqual(CMSampleBufferCopyPCMDataIntoAudioBufferList(normalized, at: 0, frameCount: 12, into: pcm.mutableAudioBufferList), noErr)
                        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
                        for index in expected.indices {
                            XCTAssertEqual(samples[index], expected[index], accuracy: 0.000_001)
                        }
                        // The callback's storage and integer format must remain untouched.
                        XCTAssertThrowsError(try MeetingPCMFormatContract(formatDescription: XCTUnwrap(CMSampleBufferGetFormatDescription(source))))
                    }
                }
            }
        }
    }

    func testFloat32MicrophonePassesThroughWithoutCopyingOrChangingEchoAdmission() throws {
        let source = try self.makeRawSampleBuffer(channelCount: 3, layoutTag: nil, frameCount: 480, pts: 1)
        let normalizer = MeetingMicrophonePCMNormalizer()
        XCTAssertTrue(normalizer.normalize(source) === source)
        let gate = MeetingMicrophoneTranscriptGate(.unprotected)
        XCTAssertFalse(gate.observeAndAdmit(normalizer.normalize(source)))
        XCTAssertFalse(gate.admitsTranscript(), "Format conversion must not bless unprotected speaker echo")
        let (integer, _) = try self.integerMicrophoneSample(bits: 16, channels: 1, rate: 48_000, planar: false)
        XCTAssertFalse(gate.observeAndAdmit(normalizer.normalize(integer)))
    }

    func testNormalizedIntegerMicrophoneReachesWriterAndLiveCopyWithNoLostOpeningFrames() async throws {
        let root = try self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "integer-mic",
            sourceDisplayName: "Integer microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: []
        )
        let events = MeetingWriterEventRecorder()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60) { events.record($0) }
        let normalizer = MeetingMicrophonePCMNormalizer()
        for index in 0..<100 {
            let (source, _) = try self.integerMicrophoneSample(bits: index.isMultiple(of: 2) ? 16 : 24, channels: 1, rate: 48_000, planar: false, pts: Double(index * 12) / 48_000)
            let normalized = normalizer.normalize(source)
            let live = try XCTUnwrap(MeetingLiveSampleCopy.copy(normalized))
            XCTAssertEqual(live.buffer.frameLength, 12)
            XCTAssertEqual(try XCTUnwrap(live.buffer.floatChannelData?[0])[0], -0.5, accuracy: 0.000_001)
            XCTAssertTrue(writer.enqueue(normalized))
            _ = await writer.snapshot()
        }
        let saved = await writer.stop()
        XCTAssertEqual(saved.chunks.count, 1, "Changing native bit width must not split the normalized capture")
        let chunk = try XCTUnwrap(saved.chunks.first)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        XCTAssertEqual(chunk.captureAnalysisAsset?.frameCount, 1200)
        let file = try AVAudioFile(forReading: root.appendingPathComponent(chunk.relativeFilePath), commonFormat: .pcmFormatFloat32, interleaved: true)
        let recorded = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1200))
        try file.read(into: recorded)
        XCTAssertEqual(recorded.frameLength, 1200)
        let values = try XCTUnwrap(recorded.floatChannelData?[0])
        for index in 0..<1200 {
            XCTAssertEqual(values[index], Float((index % 3) - 1) * 0.5, accuracy: 0.000_001)
        }
        XCTAssertFalse(events.snapshot().contains { if case .interrupted(.writerFailure, _, _) = $0 { return true }; return false })
    }

    func testUnsupportedAndMalformedBuffersRemainReportableAndDoNotPoisonLaterConversion() throws {
        let normalizer = MeetingMicrophonePCMNormalizer()
        let integerFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let shortPayload = try self.makeSampleBuffer(format: integerFormat, bytes: Data([0]), frameCount: 12, pts: 0)
        XCTAssertTrue(normalizer.normalize(shortPayload) === shortPayload)
        let oversized = try self.makeSampleBuffer(format: integerFormat, bytes: Data([0]), frameCount: 1_048_577, pts: 0)
        XCTAssertTrue(normalizer.normalize(oversized) === oversized)
        let doubleFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat64, sampleRate: 48_000, channels: 1, interleaved: true))
        let unsupported = try self.makeSampleBuffer(format: doubleFormat, bytes: Data(repeating: 0, count: 96), frameCount: 12, pts: 0)
        XCTAssertTrue(normalizer.normalize(unsupported) === unsupported)
        let (valid, _) = try self.integerMicrophoneSample(bits: 16, channels: 1, rate: 48_000, planar: false)
        let first = normalizer.normalize(valid)
        XCTAssertNoThrow(try MeetingPCMFormatContract(formatDescription: XCTUnwrap(CMSampleBufferGetFormatDescription(first))))
        let (invalid, _) = try self.integerMicrophoneSample(bits: 16, channels: 1, rate: 48_000, planar: false)
        CMSampleBufferInvalidate(invalid)
        XCTAssertTrue(normalizer.normalize(invalid) === invalid)
        let second = normalizer.normalize(valid)
        XCTAssertFalse(first === second, "Each asynchronously retained callback must own its output bytes")
        XCTAssertNoThrow(try MeetingPCMFormatContract(formatDescription: XCTUnwrap(CMSampleBufferGetFormatDescription(second))))
    }

    private func integerMicrophoneSample(bits: Int, channels: Int, rate: Double, planar: Bool, pts: Double = 1.25) throws -> (CMSampleBuffer, [Float]) {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: UInt32(bits / 8 * (planar ? 1 : channels)),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(bits / 8 * (planar ? 1 : channels)),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(bits),
            mReserved: 0
        )
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)))
        let format = try XCTUnwrap(AVAudioFormat(streamDescription: &asbd, channelLayout: layout))
        let expected: [Float] = (0..<(12 * channels)).map { Float(($0 % 3) - 1) * 0.5 }
        var bytes = Data()
        for offset in expected.indices {
            let index = planar ? (offset % 12) * channels + offset / 12 : offset
            let value = Int64(Double(expected[index]) * pow(2, Double(bits - 1)))
            for byte in 0..<(bits / 8) {
                bytes.append(UInt8(truncatingIfNeeded: value >> (byte * 8)))
            }
        }
        return try (self.makeSampleBuffer(format: format, bytes: bytes, frameCount: 12, pts: pts), expected)
    }
}

/// Synthetic PCM crosses the actual quarantine and writer, including the writer's second
/// admission check. No microphone, meeting application, model or shared preferences are used.
final class MeetingMicrophoneWriterPrivacyTests: XCTestCase {
    fileprivate final class MappedConsumer: MeetingMemoryAudioConsuming, @unchecked Sendable {
        let timeline: MeetingPCMSourceTimeline
        private let lock = NSLock()
        private var frames = 0
        private var finishes = 0
        private var failure: Error?
        init(originSeconds: Double = 1_000) throws {
            timeline = try MeetingPCMSourceTimeline(originSeconds: originSeconds, recordingTimePolicy: .hostMonotonicV1)
        }
        func enqueue(_ sample: CMSampleBuffer) -> Bool {
            lock.withLock {
                do {
                    let count = CMSampleBufferGetNumSamples(sample)
                    let mapping = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: sample)).mapping
                    try timeline.record(sourceStartSample: frames, frameCount: count,
                        presentationTime: CMSampleBufferGetPresentationTimeStamp(sample).seconds, clockMapping: mapping)
                    frames += count
                    return true
                } catch { failure = error; return false }
            }
        }
        func finish() async throws {
            let error = lock.withLock { finishes += 1; return failure }
            if let error { throw error }
        }
        var frameCount: Int { lock.withLock { frames } }
        var finishCount: Int { lock.withLock { finishes } }
    }

    func testSharedClockSourceMuteWriterAndLiveConsumerKeepTheSameMeasuredGaps() async throws {
        let fixture = try Fixture(admissionPolicy: .latchedTransitions, recordingClockPolicy: true)
        defer { fixture.gate.close(); fixture.removeDirectory() }
        let gate = fixture.gate, clock = fixture.clock
        let context = try XCTUnwrap(fixture.clockContext)
        let source = MeetingCaptureSourceClock(context: context)
        let consumer = try MappedConsumer()
        let tee = try MeetingMultiTrackCaptureTee(consumers: [.microphone: consumer],
            originHostTime: Clock.ticks(1_000), eventHandler: { _ in }, liveAudioHandler: nil,
            sampleAdmission: { _, sample in gate.permitsReleasedSample(sample) }, clockContexts: [.microphone: context])
        fixture.observations.setForward { tee.offer(kind: .microphone, sample: $0) }
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        let duration = 0.1 * 1.0003
        for index in 0..<42 {
            let acquired = 1_000.1 + Double(index) * duration
            clock.set(acquired + 0.00001)
            if index == 20 { gate.setAdmitted(false, observedAtHostTime: clock.now(), unsafeStartHostTime: Clock.ticks(acquired)) }
            if index == 21 { gate.setAdmitted(true, observedAtHostTime: clock.now()) }
            let raw = try sample(marker: index == 20 ? 0.9 : 0.25, at: Double(index) * 0.1, frames: 4_800)
            for measured in try source.offer(raw, producerGeneration: 1,
                acquisitionStart: CMTime(seconds: acquired, preferredTimescale: 1_000_000_000), sourceFrameStart: Int64(index * 4_800)) {
                _ = gate.submit(measured, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) }
            }
            gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
            _ = await fixture.writer.snapshot(); await tee.drainEnqueuedPackets()
        }
        clock.set(1_006)
        for measured in try source.finish() {
            _ = gate.submit(measured, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) }
        }
        gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        _ = await fixture.writer.snapshot(); await tee.drainEnqueuedPackets()
        await gate.stop()
        let track = await fixture.writer.stop()
        try await tee.finish()
        let stored = try readSamples(track, in: fixture.directory)
        XCTAssertFalse(stored.isEmpty)
        XCTAssertTrue(stored.allSatisfy { abs($0 - 0.25) < 0.001 }, "Muted PCM must never reach persistence")
        XCTAssertEqual(fixture.observations.writerFailures, 0)
        XCTAssertEqual(Int64(stored.count), track.chunks.compactMap { $0.clockMapping?.frameCount }.reduce(0, +))
        let mappings = track.chunks.compactMap(\.clockMapping)
        XCTAssertGreaterThanOrEqual(mappings.count, 2)
        XCTAssertTrue(consumer.timeline.hasGaps)
        XCTAssertEqual(try XCTUnwrap(consumer.timeline.mapTime(0)), try XCTUnwrap(mappings.first?.spans.first).hostStart.seconds - 1_000, accuracy: 2e-9)
        XCTAssertEqual(try XCTUnwrap(consumer.timeline.mapEndTime(Double(consumer.frameCount) / 16_000)),
            try XCTUnwrap(mappings.last?.spans.last).hostEnd.seconds - 1_000, accuracy: 2e-9)
        let quietStart = 1_000.1 + 20 * duration
        let quietEnd = 1_000.1 + 21 * duration
        XCTAssertTrue(mappings.flatMap(\.spans).allSatisfy { $0.hostEnd.seconds <= quietStart + 1e-9 || $0.hostStart.seconds >= quietEnd - 1e-9 })
    }
    @MainActor
    func testStoppingDrainsQueuedMuteToRealWriterWithoutReopeningAdmission() async throws {
        let fixture = try Fixture(admissionPolicy: .latchedTransitions)
        defer { fixture.gate.close(); fixture.removeDirectory() }
        let gate = fixture.gate, clock = fixture.clock
        let control = MeetingMicrophoneRecordingControl(gate: gate, hostTime: { clock.now() }, publish: { _ in })
        let service = MeetingCallObservationService(automaticScheduling: false,
            microphoneFactory: { _, handler in
                StopDrainMicrophone(handler: handler, onStop: {
                    control.setManuallyMuted(true)
                    control.setManuallyMuted(false)
                    handler(.init(state: .muted, observedAtHostTime: clock.now(), generation: 1,
                                  unsafeStartHostTime: Clock.ticks(1_001.49)))
                    // This later positive cannot reopen the epoch while finishing.
                    handler(.init(state: .unmuted, observedAtHostTime: clock.now(), generation: 1))
                })
            }, keyListenerFactory: { _ in StopDrainKeys() })
        let token = service.makeMicrophoneObservation(application: nil, handler: control.observe)
        try token.start()
        clock.set(1_000.12)
        let confirmed = try self.sample(marker: 0.25, at: 1_000.1)
        XCTAssertTrue(gate.submit(confirmed, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        clock.set(1_001.3); gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        _ = await fixture.writer.snapshot()
        clock.set(1_001.52)
        let privateTail = try self.sample(marker: 0.9, at: 1_001.5)
        XCTAssertTrue(gate.submit(privateTail, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        clock.set(1_001.72)
        control.beginFinishing()
        await token.stop()
        XCTAssertFalse(gate.permitsReleasedSample(privateTail))
        // Check the controller independently of the service's positive fence as well.
        control.observe(.init(state: .unmuted, observedAtHostTime: clock.now(), generation: 1))
        XCTAssertFalse(gate.permitsReleasedSample(privateTail))
        control.finish()
        await gate.stop()
        let result = await fixture.writer.stop()
        await service.shutdown()
        let persisted = try self.readSamples(result, in: fixture.directory)
        XCTAssertEqual(persisted, [Float](repeating: 0.25, count: 480),
                       "Stop preserves confirmed speech and removes the queued release tail")
        XCTAssertEqual(fixture.observations.writerFailures, 0)
    }

    private final nonisolated class StopDrainMicrophone: MeetingMicrophoneObservationPolling, @unchecked Sendable {
        let handler: MeetingMicrophoneMuteMonitor.Handler
        let onStop: @Sendable () -> Void
        init(handler: @escaping MeetingMicrophoneMuteMonitor.Handler, onStop: @escaping @Sendable () -> Void) {
            self.handler = handler; self.onStop = onStop
        }
        func start(externallyDriven: Bool) {}
        func requestPoll() {}
        func handleSharedPTT(_ event: MeetingMutePTTListener.Event) {}
        func stop() async { self.onStop() }
    }

    private final nonisolated class StopDrainKeys: MeetingCallKeyListening, @unchecked Sendable {
        func start() -> Bool { false }
        func stop() {}
    }

    func testManualAndMeetingMuteExcludeRealWriterAndDiagnosticsThenResumeWithoutReplay() async throws {
        let finalized = self.expectation(description: "The first real PCM epoch finalized")
        finalized.assertForOverFulfill = false
        let fixture = try Fixture(admissionPolicy: .latchedTransitions, onChunkFinalized: { finalized.fulfill() })
        defer { fixture.removeDirectory() }
        let clock = fixture.clock, gate = fixture.gate, writer = fixture.writer
        let live = Observations()
        let control = MeetingMicrophoneRecordingControl(gate: gate, hostTime: { clock.now() }, publish: { _ in })
        func observe(_ state: MeetingMicrophoneMuteState, release: Double? = nil, resumed: Double? = nil) {
            control.observe(.init(state: state, observedAtHostTime: clock.now(), generation: 1,
                unsafeStartHostTime: release.map(Clock.ticks), refinementUntilHostTime: resumed.map(Clock.ticks)))
        }
        func offer(_ marker: Float, at time: Double) throws -> CMSampleBuffer {
            let sample = try self.sample(marker: marker, at: time)
            _ = gate.submit(sample, deliveryQueue: fixture.deliveryQueue) { sample in
                guard gate.permitsReleasedSample(sample) else { return }
                live.observe(sample)
                writer.enqueue(sample)
            }
            return sample
        }
        clock.set(1_000.12)
        _ = try offer(0.25, at: 1_000.1)
        clock.set(1_001.2); gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        clock.set(1_001.3); control.setManuallyMuted(true)
        clock.set(1_001.52)
        let denied = try offer(0.9, at: 1_001.5)
        clock.set(1_001.6); observe(.unmuted)
        clock.set(1_001.7); observe(.unmuted, release: 1_001.4, resumed: 1_001.6)
        clock.set(1_001.82); _ = try offer(0.9, at: 1_001.8)
        XCTAssertEqual(gate.statistics.retainedBuffers, 0, "Manual mute must not quarantine disabled speech for later replay")
        clock.set(1_002); control.setManuallyMuted(false)
        clock.set(1_002.12); _ = try offer(0.5, at: 1_002.1)
        clock.set(1_003.2); gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        // Virtual time advances faster than filesystem I/O. Join the first closed chunk
        // before opening another, preserving production's bounded finalization backpressure.
        await fulfillment(of: [finalized], timeout: 2)
        XCTAssertFalse(gate.permitsReleasedSample(denied), "Unmute and PTT refinement cannot reopen a manually closed interval")
        clock.set(1_003.3); observe(.muted)
        clock.set(1_003.4); control.setManuallyMuted(true)
        clock.set(1_003.5); control.setManuallyMuted(false)
        clock.set(1_003.62); _ = try offer(0.9, at: 1_003.6)
        clock.set(1_004); observe(.unmuted)
        clock.set(1_004.12); _ = try offer(0.75, at: 1_004.1)
        clock.set(1_005.3); gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        control.finish()
        control.setManuallyMuted(true)
        await gate.stop()
        let track = await writer.stop()
        XCTAssertEqual(fixture.observations.writerFailures, 0, fixture.observations.failureDetails.joined(separator: "\n"))
        guard track.chunks.allSatisfy({ $0.finalizationState == .finalized }) else {
            return XCTFail("Synthetic writer did not finalize: \(fixture.observations.failureDetails)")
        }
        let samples = try self.readSamples(track, in: fixture.directory)
        XCTAssertEqual(live.markers, [0.25, 0.5, 0.75])
        XCTAssertEqual(fixture.observations.markers, [0.25, 0.5, 0.75])
        XCTAssertTrue(samples.contains { abs($0 - 0.25) < 0.001 })
        XCTAssertTrue(samples.contains { abs($0 - 0.5) < 0.001 })
        XCTAssertTrue(samples.contains { abs($0 - 0.75) < 0.001 })
        XCTAssertFalse(samples.contains { abs($0 - 0.9) < 0.001 })
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
        XCTAssertEqual(fixture.observations.writerFailures, 0)
    }

    func testLatchedTransitionsKeepRecordingWithoutVisibleControlsAndExcludeMuteTail() async throws {
        let fixture = try Fixture(admissionPolicy: .latchedTransitions)
        defer { fixture.gate.close(); fixture.removeDirectory() }
        let gate = fixture.gate, clock = fixture.clock
        gate.setAdmitted(true, observedAtHostTime: clock.now())

        // Ten minutes without another frame must preserve the initial enabled state.
        clock.set(1_600.2)
        let first = try self.sample(marker: 0.25, at: 1_600.1)
        XCTAssertTrue(gate.submit(first, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        clock.set(1_601.2); gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        _ = await fixture.writer.snapshot()
        XCTAssertEqual(fixture.observations.markers, [0.25])

        clock.set(1_601.49)
        let privateTail = try self.sample(marker: -0.75, at: 1_601.47)
        XCTAssertTrue(gate.submit(privateTail, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        clock.set(1_601.5)
        gate.setAdmitted(false, observedAtHostTime: clock.now(), unsafeStartHostTime: Clock.ticks(1_601.48))
        clock.set(2_200.2)
        XCTAssertFalse(gate.submit(privateTail, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        XCTAssertTrue(fixture.writer.enqueue(privateTail), "Final writer admission must exclude even a bypassed private block")

        gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(2_200.3)
        let resumed = try self.sample(marker: -0.375, at: 2_200.25)
        XCTAssertTrue(gate.submit(resumed, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        clock.set(2_201.4); gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        await gate.stop()
        let result = await fixture.writer.stop()
        XCTAssertEqual(fixture.observations.markers, [0.25, -0.375])
        XCTAssertEqual(fixture.observations.writerFailures, 0)
        XCTAssertEqual(result.chunks.reduce(0) { $0 + ($1.captureAnalysisAsset?.frameCount ?? 0) }, 960)
        let persisted = try self.readSamples(result, in: fixture.directory)
        XCTAssertEqual(Array(persisted.prefix(480)), [Float](repeating: 0.25, count: 480))
        XCTAssertEqual(Array(persisted.suffix(480)), [Float](repeating: -0.375, count: 480))
        XCTAssertFalse(persisted.contains(-0.75))
        XCTAssertEqual(gate.statistics.retainedBytes, 0)
    }

    func testMutePreservesConfirmedSpeechButExcludesPrivateTailAndDiagnostics() async throws {
        let fixture = try Fixture()
        defer { fixture.gate.close(); fixture.removeDirectory() }
        let gate = fixture.gate
        let clock = fixture.clock

        // Unknown intake is closed, and even an adapter that erroneously enqueues it directly
        // cannot bypass the writer's final admission check.
        let unknown = try self.sample(marker: -0.875, at: 1_000.01)
        clock.set(1_000.03)
        XCTAssertFalse(gate.submit(unknown, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        XCTAssertTrue(fixture.writer.enqueue(unknown))
        _ = await fixture.writer.snapshot()
        XCTAssertTrue(fixture.observations.markers.isEmpty)

        gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_000.10)
        let speech = try self.sample(marker: 0.25, at: 1_000.05)
        XCTAssertTrue(gate.submit(speech, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })
        clock.set(1_000.25)
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_000.45)
        let privateTail = try self.sample(marker: -0.75, at: 1_000.40)
        XCTAssertTrue(gate.submit(privateTail, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })

        clock.set(1_000.50)
        gate.setAdmitted(false, observedAtHostTime: clock.now(), unsafeStartHostTime: clock.now())
        // The old confirmation covers speech ending before 1000.20, never the private tail.
        XCTAssertFalse(gate.permitsReleasedSample(privateTail))
        XCTAssertTrue(fixture.writer.enqueue(privateTail))
        gate.finishInput()
        clock.set(1_001.51)
        gate.checkFreshnessAndDrain()
        fixture.deliveryQueue.sync {}
        await gate.stop()
        let result = await fixture.writer.stop()

        XCTAssertEqual(fixture.observations.markers, [0.25])
        XCTAssertEqual(fixture.observations.writerFailures, 0)
        XCTAssertEqual(result.chunks.count, 1)
        XCTAssertEqual(result.chunks.first?.captureAnalysisAsset?.frameCount, 480)
        let persisted = try self.readSamples(result, in: fixture.directory)
        XCTAssertEqual(persisted.count, 480)
        XCTAssertTrue(persisted.allSatisfy { abs($0 - 0.25) < 0.000_001 }, "Only the confirmed synthetic speech may reach disk")
        XCTAssertEqual(gate.statistics.retainedBytes, 0)
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
    }

    func testWriterRechecksQueuedReleasedPCMWhenAdmissionIsRevoked() async throws {
        let fixture = try Fixture()
        defer { fixture.gate.close(); fixture.removeDirectory() }
        let gate = fixture.gate
        let clock = fixture.clock
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_000.20)
        let sample = try self.sample(marker: -0.625, at: 1_000.10)
        XCTAssertTrue(gate.submit(sample, deliveryQueue: fixture.deliveryQueue) { fixture.writer.enqueue($0) })

        // Occupy the real serial writer queue with its public metadata command. The released
        // PCM queues behind it, then loses admission before consume() can observe or persist it.
        let entered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        fixture.writer.enqueueMetadata(failClosed: true, mutate: { _ in
            entered.signal()
            _ = releaseWriter.wait(timeout: .now() + 5)
        }, completion: { _ in })
        guard entered.wait(timeout: .now() + 2) == .success else {
            releaseWriter.signal()
            gate.close()
            await gate.stop()
            _ = await fixture.writer.stop()
            XCTFail("The actual writer queue did not enter the bounded test barrier")
            return
        }
        clock.set(1_000.60)
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_001.12)
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        gate.checkFreshnessAndDrain()
        fixture.deliveryQueue.sync {}
        XCTAssertEqual(gate.statistics.deliveredBuffers, 1)
        XCTAssertTrue(gate.permitsReleasedSample(sample))
        gate.close()
        XCTAssertFalse(gate.permitsReleasedSample(sample))
        releaseWriter.signal()
        await gate.stop()
        let result = await fixture.writer.stop()

        XCTAssertTrue(result.chunks.isEmpty, "Revoked PCM already queued to the writer must never create an audio chunk")
        XCTAssertTrue(fixture.observations.markers.isEmpty, "Diagnostics must share final admission")
        XCTAssertEqual(fixture.observations.writerFailures, 0, "Intentional privacy exclusion is not a capture or writer failure")
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
    }

    func testDriftingAcquisitionKeepsRealWriterPCMContiguousAfterThirtyThreeMinutes() async throws {
        let fixture = try Fixture(admissionPolicy: .latchedTransitions)
        defer { fixture.gate.close(); fixture.removeDirectory() }
        let host = fixture.clock, gate = fixture.gate
        gate.setAdmitted(true, observedAtHostTime: host.now())
        var clock = MeetingMicrophonePTSClock()
        for index in 0..<20_000 {
            _ = clock.stamp(hostTime: Clock.ticks(1_000 + Double(index) * 0.1 * (1 - 5e-6)), frameCount: 4_800)
        }
        let count = 1_200
        for index in 20_000..<(20_000 + count) {
            let acquisition = 1_000 + Double(index) * 0.1 * (1 - 5e-6)
            let acquiredAt = Clock.ticks(acquisition)
            guard case let .emitted(pts, _, _, _) = clock.stamp(hostTime: acquiredAt, frameCount: 4_800) else {
                return XCTFail("A valid microphone clock unexpectedly stopped")
            }
            host.set(acquisition + 0.102 + Double(index % 7) * 0.0005)
            let sample = try self.sample(marker: 0.25, at: pts.seconds, frames: 4_800)
            XCTAssertTrue(gate.submit(sample, acquisitionHostTime: acquiredAt, deliveryQueue: fixture.deliveryQueue) {
                fixture.writer.enqueue($0)
            })
            gate.checkFreshnessAndDrain()
            if index % 10 == 0 {
                fixture.deliveryQueue.sync {}
                _ = await fixture.writer.snapshot()
            }
        }
        host.set(3_122); gate.checkFreshnessAndDrain(); fixture.deliveryQueue.sync {}
        await gate.stop()
        let track = await fixture.writer.stop()
        XCTAssertEqual(fixture.observations.writerFailures, 0)
        XCTAssertFalse(track.chunks.isEmpty)
        XCTAssertTrue(track.chunks.allSatisfy { $0.finalizationState == .finalized })
        XCTAssertTrue(track.chunks.allSatisfy { $0.discontinuities.isEmpty }, "Allowed PCM cannot acquire artificial source gaps")
        let storedFrames = try track.chunks.map { try XCTUnwrap($0.captureAnalysisAsset?.frameCount) }.reduce(0, +)
        XCTAssertEqual(storedFrames, Int64(count * 4_800), "The finalized CAF packet counts must include every admitted frame")
        let samples = try self.readSamples(track, in: fixture.directory)
        XCTAssertEqual(samples.count, count * 4_800, "The real writer must receive every sample, not compress scattered islands")
        XCTAssertTrue(samples.allSatisfy { abs($0 - 0.25) < 0.001 })
        XCTAssertEqual(gate.statistics.rejectedBuffers, 0)
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
    }

    private func sample(marker: Float, at seconds: Double, frames: Int = 480) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &format), noErr)
        let values = [Float](repeating: marker, count: frames)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: values.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block), noErr)
        let ownedBlock = try XCTUnwrap(block)
        let copyStatus = values.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: ownedBlock,
                offsetIntoDestination: 0, dataLength: bytes.count)
        }
        XCTAssertEqual(copyStatus, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMClockMakeHostTimeFromSystemUnits(Clock.ticks(seconds)), decodeTimeStamp: .invalid)
        var frameBytes = 4
        var sample: CMSampleBuffer?
        XCTAssertEqual(try CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: ownedBlock,
            formatDescription: XCTUnwrap(format), sampleCount: values.count, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &frameBytes,
            sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    private func readSamples(_ track: MeetingAudioTrack, in directory: URL) throws -> [Float] {
        var samples: [Float] = []
        for chunk in track.chunks {
            let file = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativeFilePath),
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let expectedFrames = try XCTUnwrap(chunk.captureAnalysisAsset?.frameCount)
            XCTAssertEqual(file.length, expectedFrames, "The native reader's length must match the sink's verified CAF packet count")
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
            var decodedFrames: Int64 = 0
            // AVAudioFile attempts to fill a buffer; frameLength is the actual read receipt.
            // A successful short read is not EOF. Read the remaining declared frames as well.
            while file.framePosition < file.length {
                let before = file.framePosition
                let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - before))
                try file.read(into: buffer, frameCount: requested)
                guard buffer.frameLength > 0 else {
                    throw NSError(domain: "MeetingWriterPrivacyTests", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "CAF ended before its declared frame count"])
                }
                XCTAssertEqual(file.framePosition - before, Int64(buffer.frameLength))
                decodedFrames += Int64(buffer.frameLength)
                samples.append(contentsOf: UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
            }
            XCTAssertEqual(decodedFrames, expectedFrames, "Every stored PCM frame must be decoded and checked")
        }
        return samples
    }

    private final nonisolated class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Clock.ticks(1_000)
        func now() -> UInt64 { self.lock.withLock { self.value } }
        func set(_ seconds: Double) { self.lock.withLock { self.value = Self.ticks(seconds) } }
        static func ticks(_ seconds: Double) -> UInt64 {
            CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        }
    }

    private final nonisolated class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var observedMarkers: [Float] = []
        private var failures = 0
        private var details: [String] = []
        private var forward: (@Sendable (CMSampleBuffer) -> Void)?
        func setForward(_ value: @escaping @Sendable (CMSampleBuffer) -> Void) { lock.withLock { forward = value } }
        var failureDetails: [String] { self.lock.withLock { self.details } }
        var markers: [Float] { self.lock.withLock { self.observedMarkers } }
        var writerFailures: Int { self.lock.withLock { self.failures } }
        func observe(_ sample: CMSampleBuffer) {
            self.lock.withLock { self.forward }?(sample)
            guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
            var marker: Float = 0
            let status = withUnsafeMutableBytes(of: &marker) {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: $0.baseAddress!)
            }
            if status == noErr { self.lock.withLock { self.observedMarkers.append(marker) } }
        }
        func record(_ event: MeetingCaptureEvent) {
            if case let .interrupted(.writerFailure, _, detail) = event {
                self.lock.withLock { self.failures += 1; self.details.append(detail ?? "unspecified") }
            }
        }
    }

    private final nonisolated class Fixture: @unchecked Sendable {
        let directory: URL
        let clock = Clock()
        let gate: MeetingMicrophonePrivacyGate
        let observations = Observations()
        let deliveryQueue = DispatchQueue(label: "meeting.writer-privacy.tests.delivery")
        let writer: MeetingAudioChunkWriter
        let clockContext: MeetingRecordingClockContext?

        init(admissionPolicy: MeetingMicrophonePrivacyGate.Configuration.AdmissionPolicy = .freshObservations,
             recordingClockPolicy: Bool = false,
             onChunkFinalized: @escaping @Sendable () -> Void = {}) throws {
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("FluidVoice-WriterPrivacy-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
            let clock = self.clock
            var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
            let timebase = MeetingTimebaseMetadata(startedHostTime: Clock.ticks(1_000),
                machTimebaseNumerator: info.numer, machTimebaseDenominator: info.denom, firstPresentationTime: nil,
                recordingTimePolicy: recordingClockPolicy ? .hostMonotonicV1 : nil)
            let trackID = UUID()
            let context = try recordingClockPolicy ? MeetingRecordingClock(timebase: timebase).source(trackID) : nil
            self.clockContext = context
            let gate = MeetingMicrophonePrivacyGate(configuration: .init(admissionPolicy: admissionPolicy),
                clockContext: context,
                hostTime: { clock.now() }, automaticWatchdog: false)
            self.gate = gate
            let observations = self.observations
            let track = MeetingAudioTrack(id: trackID, kind: .microphone,
                sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic",
                format: nil, timebase: timebase,
                health: .waiting, chunks: [])
            self.writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: self.directory, chunkDuration: 60,
                eventHandler: { event in
                    observations.record(event)
                    if case .chunkFinalized = event { onChunkFinalized() }
                }, diagnosticSampleObserver: { sample, _ in observations.observe(sample) },
                sampleAdmission: { gate.permitsReleasedSample($0) }, clockContext: context)
        }

        func removeDirectory() { try? FileManager.default.removeItem(at: self.directory) }
    }
}
