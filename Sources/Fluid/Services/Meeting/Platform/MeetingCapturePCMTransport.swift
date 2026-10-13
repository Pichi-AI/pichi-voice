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
    private var accepting = true
    private var queuedBytes = 0
    private var queuedSeconds: Double = 0

    init(maximumBytes: Int = 2 * 1024 * 1024, maximumSeconds: Double = 2) {
        precondition(maximumBytes > 0 && maximumSeconds.isFinite && maximumSeconds > 0)
        self.maximumBytes = maximumBytes
        self.maximumSeconds = maximumSeconds
    }

    func reserve(frames: Int, channels: Int, sampleRate: Double) -> Reservation? {
        self.lock.withLock {
            guard self.accepting else { return nil }
            guard frames > 0, channels > 0, channels <= 8,
                  sampleRate.isFinite, sampleRate >= 8_000, sampleRate <= 192_000,
                  frames <= 65_536
            else { self.accepting = false; return nil }
            let bytes = frames * channels * MemoryLayout<Float>.stride
            let seconds = Double(frames) / sampleRate
            guard bytes <= self.maximumBytes - self.queuedBytes,
                  seconds <= self.maximumSeconds - self.queuedSeconds + 0.000_001
            else { self.accepting = false; return nil }
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

    var isAccepting: Bool { self.lock.withLock { self.accepting } }
    var retainedBytes: Int { self.lock.withLock { self.queuedBytes } }
}

nonisolated enum MeetingCapturePCMError: LocalizedError, Equatable {
    case invalidBuffer
    case nonFiniteSample
    case invalidPresentationTime
    case timelineDiscontinuity
    case conversionFailed(String)
    case sampleBufferFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidBuffer: return PichiLocalization.text("The microphone supplied an invalid PCM buffer.")
        case .nonFiniteSample: return PichiLocalization.text("The microphone supplied a non-finite PCM sample.")
        case .invalidPresentationTime: return PichiLocalization.text("The microphone supplied an invalid presentation timestamp.")
        case .timelineDiscontinuity: return PichiLocalization.text("The microphone PCM timeline changed unexpectedly.")
        case let .conversionFailed(detail): return PichiLocalization.format("Microphone PCM conversion failed. %@", detail)
        case let .sampleBufferFailed(status): return PichiLocalization.format("Microphone sample-buffer construction failed (%d).", status)
        }
    }
}

/// Owns conversion on the adapter's serialized non-real-time queue. It creates no file and
/// produces the same CMSampleBuffer boundary consumed by the existing chunk writer/live engine.
final nonisolated class MeetingCapturePCMConverter {
    static let sampleRate: Double = 16_000
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var origin: CMTime?
    private var expectedNativePTS: CMTime?
    private var producedFrames: Int64 = 0

    init() throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: Self.sampleRate, channels: 1, interleaved: false)
        else { throw MeetingCapturePCMError.invalidBuffer }
        self.targetFormat = format
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

    func convert(_ buffer: AVAudioPCMBuffer, presentationTime: CMTime) throws -> CMSampleBuffer? {
        guard presentationTime.isNumeric, presentationTime >= .zero else {
            throw MeetingCapturePCMError.invalidPresentationTime
        }
        if let expectedNativePTS,
           abs(CMTimeGetSeconds(presentationTime - expectedNativePTS)) > 0.02 {
            throw MeetingCapturePCMError.timelineDiscontinuity
        }
        self.expectedNativePTS = presentationTime + CMTime(seconds: Double(buffer.frameLength) / buffer.format.sampleRate,
                                                            preferredTimescale: 1_000_000_000)
        if self.origin == nil { self.origin = presentationTime }
        if let sourceFormat, sourceFormat != buffer.format {
            throw MeetingCapturePCMError.timelineDiscontinuity
        }
        if self.converter == nil {
            guard let converter = AVAudioConverter(from: buffer.format, to: self.targetFormat) else {
                throw MeetingCapturePCMError.conversionFailed(PichiLocalization.text("Unsupported source format."))
            }
            self.sourceFormat = buffer.format
            self.converter = converter
        }
        return try self.run(input: buffer, finishing: false)
    }

    /// Drains the converter's finite resampling tail before the strict consumer/writer is joined.
    func finish() throws -> CMSampleBuffer? {
        guard self.converter != nil else { return nil }
        return try self.run(input: nil, finishing: true)
    }

    private func run(input: AVAudioPCMBuffer?, finishing: Bool) throws -> CMSampleBuffer? {
        guard let converter = self.converter, let origin else { return nil }
        let ratio = Self.sampleRate / (self.sourceFormat?.sampleRate ?? Self.sampleRate)
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
        guard output.frameLength > 0 else { return nil }
        let pts = origin + CMTime(value: self.producedFrames, timescale: 16_000)
        let sample = try Self.sampleBuffer(buffer: output, presentationTime: pts)
        self.producedFrames += Int64(output.frameLength)
        return sample
    }

    static func sampleBuffer(buffer: AVAudioPCMBuffer, presentationTime: CMTime) throws -> CMSampleBuffer {
        guard buffer.format.commonFormat == .pcmFormatFloat32, buffer.format.sampleRate == Self.sampleRate,
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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
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
