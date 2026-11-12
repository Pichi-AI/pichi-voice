@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Bounds capture callbacks before any PCM copy or asynchronous work is allocated. A rejection
/// closes intake; the platform adapter publishes an interruption instead of silently losing audio.
final nonisolated class MeetingPCMIntakeGate: @unchecked Sendable {
    struct Reservation: Sendable {
        fileprivate let bytes: Int
        fileprivate let seconds: Double
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private let maximumSeconds: Double
    private let closeOnRejection: Bool
    private var accepting = true
    private var queuedBytes = 0
    private var queuedSeconds: Double = 0

    init(maximumBytes: Int = 2 * 1024 * 1024, maximumSeconds: Double = 2, closeOnRejection: Bool = true) {
        precondition(maximumBytes > 0 && maximumSeconds.isFinite && maximumSeconds > 0)
        self.maximumBytes = maximumBytes
        self.maximumSeconds = maximumSeconds
        self.closeOnRejection = closeOnRejection
    }

    func reserve(frames: Int, channels: Int, sampleRate: Double) -> Reservation? {
        self.lock.withLock {
            guard self.accepting else { return nil }
            guard frames > 0, channels > 0, channels <= 8,
                  sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000,
                  frames <= 65_536
            else { if self.closeOnRejection { self.accepting = false }; return nil }
            let bytes = frames * channels * MemoryLayout<Float>.stride
            let seconds = Double(frames) / sampleRate
            guard bytes <= self.maximumBytes - self.queuedBytes,
                  seconds <= self.maximumSeconds - self.queuedSeconds + 0.000_001
            else { if self.closeOnRejection { self.accepting = false }; return nil }
            self.queuedBytes += bytes
            self.queuedSeconds += seconds
            return Reservation(bytes: bytes, seconds: seconds)
        }
    }

    func release(_ reservation: Reservation) {
        self.lock.withLock {
            self.queuedBytes = max(0, self.queuedBytes - reservation.bytes)
            self.queuedSeconds = max(0, self.queuedSeconds - reservation.seconds)
        }
    }

    /// Returns true only for the first close, which bounds terminal-event delivery.
    @discardableResult
    func close() -> Bool {
        self.lock.withLock {
            let wasAccepting = self.accepting
            self.accepting = false
            return wasAccepting
        }
    }

    var retainedBytes: Int { self.lock.withLock { self.queuedBytes } }
}

nonisolated enum MeetingCapturePCMError: LocalizedError, Equatable {
    case invalidBuffer
    case nonFiniteSample
    case invalidPresentationTime
    case timelineDiscontinuity
    case conversionFailed(String)
    case transcriptionStopped
    case transcriptionRejected(String)
    case sampleBufferFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidBuffer: return PichiLocalization.text("The microphone supplied an invalid PCM buffer.")
        case .nonFiniteSample: return PichiLocalization.text("The microphone supplied a non-finite PCM sample.")
        case .invalidPresentationTime: return PichiLocalization.text("The microphone supplied an invalid presentation timestamp.")
        case .timelineDiscontinuity: return PichiLocalization.text("The microphone PCM timeline changed unexpectedly.")
        case let .conversionFailed(detail): return PichiLocalization.format("Microphone PCM conversion failed. %@", detail)
        case .transcriptionStopped: return PichiLocalization.text("In-memory transcription stopped. Completed text was preserved.")
        case .transcriptionRejected(let reason): return reason
        case let .sampleBufferFailed(status): return PichiLocalization.format("Microphone sample-buffer construction failed (%d).", status)
        }
    }
}

/// Owns conversion on the adapter's serialized non-real-time queue. It creates no file and
/// produces the same CMSampleBuffer boundary consumed by the existing chunk writer/live engine.
final nonisolated class MeetingCapturePCMConverter {
    static let sampleRate: Double = 16_000
    private let targetFormat: AVAudioFormat
    private let targetSampleRate: Double
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var origin: CMTime?
    private var expectedNativePTS: CMTime?
    private var producedFrames: Int64 = 0
    private var clockMode: Bool?
    private var clockContext: MeetingCaptureClockMetadata.Packet?
    private var clockSpans: [MeetingAudioClockSpan] = []
    private var acceptedInputFrames: Int64 = 0
    private var lastInputHostEnd: Double?

    init(targetSampleRate: Double = MeetingCapturePCMConverter.sampleRate) throws {
        guard targetSampleRate.isFinite, (8_000...192_000).contains(targetSampleRate),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: targetSampleRate, channels: 1, interleaved: false)
        else { throw MeetingCapturePCMError.invalidBuffer }
        self.targetFormat = format
        self.targetSampleRate = targetSampleRate
    }

    /// Copy/downmix occurs inside the bounded reservation, before the system reuses its tap PCM.
    static func ownedMonoCopy(of source: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        guard frames > 0, frames <= 65_536, channels > 0, channels <= 8,
              source.format.commonFormat == .pcmFormatFloat32,
              source.format.sampleRate.isFinite,
              source.format.sampleRate >= 8_000, source.format.sampleRate <= 192_000,
              let input = source.floatChannelData,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: source.format.sampleRate, channels: 1, interleaved: false),
              let copied = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: source.frameLength),
              let output = copied.floatChannelData?[0]
        else { throw MeetingCapturePCMError.invalidBuffer }
        copied.frameLength = source.frameLength
        for frame in 0..<frames {
            var value: Float = 0
            for channel in 0..<channels {
                let sample = source.format.isInterleaved
                    ? input[0][frame * channels + channel] : input[channel][frame]
                guard sample.isFinite else { throw MeetingCapturePCMError.nonFiniteSample }
                value += sample / Float(channels)
            }
            output[frame] = value
        }
        return copied
    }

    func convert(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime,
                 clockPacket: MeetingCaptureClockMetadata.Packet? = nil) throws -> CMSampleBuffer? {
        guard presentationTime.isNumeric, presentationTime >= .zero else {
            throw MeetingCapturePCMError.invalidPresentationTime
        }
        guard self.clockMode.map({ $0 == (clockPacket != nil) }) ?? true else {
            throw MeetingCapturePCMError.timelineDiscontinuity
        }
        if clockPacket == nil, let expectedNativePTS,
           abs(CMTimeGetSeconds(presentationTime - expectedNativePTS)) > 0.02 {
            throw MeetingCapturePCMError.timelineDiscontinuity
        }
        self.expectedNativePTS = presentationTime + CMTime(seconds: Double(buffer.frameLength) / buffer.format.sampleRate,
                                                            preferredTimescale: 1_000_000_000)
        if self.origin == nil { self.origin = presentationTime }
        if let sourceFormat, sourceFormat != buffer.format {
            throw MeetingCapturePCMError.timelineDiscontinuity
        }
        // Matching mono PCM already has the required frame contract. Avoid a rate converter's
        // priming delay and finite short-epoch loss when no resampling is needed.
        if let packet = clockPacket, buffer.format == self.targetFormat {
            self.sourceFormat = buffer.format
            try self.appendClockPacket(packet, frames: Int64(buffer.frameLength))
            self.clockMode = true
            let mapping = try self.outputClockMapping(frames: Int64(buffer.frameLength), nativeFramesPerOutput: 1)
            guard let start = mapping.hostTime(atFrame: 0) else { throw MeetingCapturePCMError.invalidPresentationTime }
            let sample = try Self.sampleBuffer(buffer: buffer,
                presentationTime: CMTime(value: start.value, timescale: start.timescale), sampleRate: self.targetSampleRate)
            try MeetingCaptureClockMetadata.attach(mapping: mapping, clockID: packet.clockID,
                sourceID: packet.sourceID, producerEpoch: packet.producerEpoch, to: sample)
            self.producedFrames += Int64(buffer.frameLength)
            return sample
        }
        if self.converter == nil {
            guard let converter = AVAudioConverter(from: buffer.format, to: self.targetFormat) else {
                throw MeetingCapturePCMError.conversionFailed(PichiLocalization.text("Unsupported source format."))
            }
            self.sourceFormat = buffer.format
            self.converter = converter
        }
        if let clockPacket { try self.appendClockPacket(clockPacket, frames: Int64(buffer.frameLength)) }
        self.clockMode = clockPacket != nil
        return try self.run(input: buffer, finishing: false)
    }

    /// Drains the converter's finite resampling tail before the strict consumer/writer is joined.
    func finish() throws -> CMSampleBuffer? {
        guard self.converter != nil else { return nil }
        return try self.run(input: nil, finishing: true)
    }

    private func run(input: AVAudioPCMBuffer?, finishing: Bool) throws -> CMSampleBuffer? {
        guard let converter = self.converter, let origin else { return nil }
        let ratio = self.targetSampleRate / (self.sourceFormat?.sampleRate ?? self.targetSampleRate)
        let capacity = AVAudioFrameCount(ceil(Double(input?.frameLength ?? 0) * ratio) + 512)
        guard let output = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else {
            throw MeetingCapturePCMError.invalidBuffer
        }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, inputStatus in
            if let input, !supplied {
                supplied = true
                inputStatus.pointee = .haveData
                return input
            }
            inputStatus.pointee = finishing ? .endOfStream : .noDataNow
            return nil
        }
        guard status != .error, failure == nil else {
            throw MeetingCapturePCMError.conversionFailed(failure?.localizedDescription ?? PichiLocalization.text("Unknown converter error."))
        }
        guard output.frameLength > 0 else {
            if finishing { self.clockSpans.removeAll() }
            return nil
        }
        let sample: CMSampleBuffer
        if let context = self.clockContext {
            let available = Int64(floor(Double(self.acceptedInputFrames) * ratio + 1e-7)) - self.producedFrames
            guard available > 0 else {
                if finishing { self.clockSpans.removeAll() }
                return nil
            }
            // Converter padding beyond measured input has no acquisition authority.
            output.frameLength = AVAudioFrameCount(min(Int64(output.frameLength), available))
            let mapping = try self.outputClockMapping(frames: Int64(output.frameLength), nativeFramesPerOutput: 1 / ratio)
            guard let first = mapping.hostTime(atFrame: 0) else { throw MeetingCapturePCMError.invalidPresentationTime }
            sample = try Self.sampleBuffer(buffer: output, presentationTime: CMTime(value: first.value, timescale: first.timescale),
                                           sampleRate: self.targetSampleRate)
            try MeetingCaptureClockMetadata.attach(mapping: mapping, clockID: context.clockID,
                sourceID: context.sourceID, producerEpoch: context.producerEpoch, to: sample)
        } else {
            let pts = origin + CMTime(value: self.producedFrames, timescale: CMTimeScale(self.targetSampleRate.rounded()))
            sample = try Self.sampleBuffer(buffer: output, presentationTime: pts, sampleRate: self.targetSampleRate)
        }
        self.producedFrames += Int64(output.frameLength)
        if finishing { self.clockSpans.removeAll() }
        return sample
    }

    var retainedClockSpanCount: Int { self.clockSpans.count }

    private func appendClockPacket(_ packet: MeetingCaptureClockMetadata.Packet, frames: Int64) throws {
        _ = try packet.mapping.validated(expectedFrameCount: frames)
        guard frames > 0, let first = packet.mapping.spans.first else {
            throw MeetingAudioClockMapping.Failure.invalidMapping
        }
        if let previous = self.clockContext {
            guard previous.clockID == packet.clockID, previous.sourceID == packet.sourceID,
                  previous.producerEpoch == packet.producerEpoch,
                  packet.mapping.spans.first?.discontinuityBefore != true else {
                throw MeetingCaptureClockMetadata.Failure.contextMismatch
            }
        }
        guard !packet.mapping.spans.dropFirst().contains(where: { $0.discontinuityBefore }),
              self.lastInputHostEnd.map({ abs(first.hostStart.seconds - $0) <= 1e-9 }) ?? true,
              self.clockSpans.count + packet.mapping.spans.count <= MeetingAudioClockMapping.maximumSpans,
              frames > 0, self.acceptedInputFrames <= Int64.max - frames else {
            throw MeetingAudioClockMapping.Failure.invalidMapping
        }
        for var span in packet.mapping.spans {
            span.frameStart += Double(self.acceptedInputFrames)
            span.frameEnd += Double(self.acceptedInputFrames)
            self.clockSpans.append(span)
        }
        self.clockContext = packet
        self.acceptedInputFrames += frames
        self.lastInputHostEnd = packet.mapping.spans.last?.hostEnd.seconds
    }

    private func outputClockMapping(frames: Int64, nativeFramesPerOutput: Double) throws -> MeetingAudioClockMapping {
        let lower = Double(self.producedFrames) * nativeFramesPerOutput
        let upper = Double(self.producedFrames + frames) * nativeFramesPerOutput
        var spans: [MeetingAudioClockSpan] = []
        for span in self.clockSpans {
            let start = max(lower, span.frameStart), end = min(upper, span.frameEnd)
            guard end - start > 1e-7 else { continue }
            let slope = (span.hostEnd.seconds - span.hostStart.seconds) / (span.frameEnd - span.frameStart)
            spans.append(.init(frameStart: (start - lower) / nativeFramesPerOutput,
                               frameEnd: (end - lower) / nativeFramesPerOutput,
                               hostStart: MeetingAudioClockMapping.mediaTime(span.hostStart.seconds + (start - span.frameStart) * slope),
                               hostEnd: MeetingAudioClockMapping.mediaTime(span.hostStart.seconds + (end - span.frameStart) * slope),
                               discontinuityBefore: span.discontinuityBefore && abs(start - span.frameStart) <= 1e-7))
        }
        let mapping = try MeetingAudioClockMapping(frameCount: frames, spans: spans).validated()
        self.clockSpans.removeAll { $0.frameEnd <= upper + 1e-7 }
        if let first = self.clockSpans.first, first.frameStart < upper {
            let fraction = (upper - first.frameStart) / (first.frameEnd - first.frameStart)
            self.clockSpans[0].hostStart = MeetingAudioClockMapping.mediaTime(first.hostStart.seconds
                + fraction * (first.hostEnd.seconds - first.hostStart.seconds))
            self.clockSpans[0].frameStart = upper
            self.clockSpans[0].discontinuityBefore = false
        }
        return mapping
    }

    static func sampleBuffer(buffer: AVAudioPCMBuffer, presentationTime: CMTime,
                             sampleRate: Double = MeetingCapturePCMConverter.sampleRate) throws -> CMSampleBuffer {
        guard sampleRate.isFinite, (8_000...192_000).contains(sampleRate),
              buffer.format.commonFormat == .pcmFormatFloat32, buffer.format.sampleRate == sampleRate,
              buffer.format.channelCount == 1, buffer.frameLength > 0, buffer.frameLength <= 65_536,
              presentationTime.isNumeric, presentationTime >= .zero,
              let samples = buffer.floatChannelData?[0] else { throw MeetingCapturePCMError.invalidBuffer }
        guard (0..<Int(buffer.frameLength)).allSatisfy({ samples[$0].isFinite }) else {
            throw MeetingCapturePCMError.nonFiniteSample
        }
        var description: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                                                        asbd: buffer.format.streamDescription,
                                                        layoutSize: 0, layout: nil,
                                                        magicCookieSize: 0, magicCookie: nil,
                                                        extensions: nil, formatDescriptionOut: &description)
        guard formatStatus == noErr, let description else { throw MeetingCapturePCMError.sampleBufferFailed(formatStatus) }
        var result: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate.rounded())),
                                        presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
        let createStatus = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
                                               dataReady: false, makeDataReadyCallback: nil, refcon: nil,
                                               formatDescription: description, sampleCount: Int(buffer.frameLength),
                                               sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                               sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result)
        guard createStatus == noErr, let result else { throw MeetingCapturePCMError.sampleBufferFailed(createStatus) }
        let dataStatus = CMSampleBufferSetDataBufferFromAudioBufferList(result, blockBufferAllocator: kCFAllocatorDefault,
                                                                       blockBufferMemoryAllocator: kCFAllocatorDefault,
                                                                       flags: 0, bufferList: buffer.audioBufferList)
        guard dataStatus == noErr else { throw MeetingCapturePCMError.sampleBufferFailed(dataStatus) }
        let readyStatus = CMSampleBufferSetDataReady(result)
        guard readyStatus == noErr else { throw MeetingCapturePCMError.sampleBufferFailed(readyStatus) }
        return result
    }
}
