@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Adapts native microphone LPCM before the writer, echo processing and live captions fan out.
/// One converter is retained per producer, rebuilt only when its format changes. No resampling,
/// channel mixing, capture delay or opening-frame discard is involved.
final nonisolated class MeetingMicrophonePCMNormalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Invalid/unsupported input is returned intact so the existing writer still reports its
    /// failure and degraded health. Conversion must never silently discard a capture callback.
    func normalize(_ sample: CMSampleBuffer) -> CMSampleBuffer {
        guard CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample)
        else { return sample }
        if (try? MeetingPCMFormatContract(formatDescription: description)) != nil { return sample }
        return self.lock.withLock {
            (try? self.convert(sample, description: description)) ?? sample
        }
    }

    private func convert(_ sample: CMSampleBuffer, description: CMFormatDescription) throws -> CMSampleBuffer {
        let format = try MeetingPCMFormatResolver.resolve(description)
        let asbd = format.streamDescription.pointee
        let frames = CMSampleBufferGetNumSamples(sample)
        let channels = Int(format.channelCount)
        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0,
              [16, 24, 32].contains(asbd.mBitsPerChannel),
              format.sampleRate.isFinite, format.sampleRate > 0,
              channels > 0, frames > 0,
              // Bound malformed callback metadata to at most 4 MiB of Float32 output.
              frames <= 1_048_576 / channels,
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))
        else { throw MeetingPCMFormatContractError.unsupported("invalid native integer microphone buffer") }
        input.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(frames), into: input.mutableAudioBufferList
        ) == noErr else { throw MeetingPCMFormatContractError.unsupported("invalid microphone PCM payload") }

        if self.sourceFormat != format || self.converter == nil {
            let target: AVAudioFormat?
            if let layout = format.channelLayout {
                target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, interleaved: true, channelLayout: layout)
            } else {
                target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate, channels: format.channelCount, interleaved: true)
            }
            guard let target, let converter = AVAudioConverter(from: format, to: target) else {
                throw MeetingPCMFormatContractError.unsupported("cannot convert microphone PCM")
            }
            self.sourceFormat = format
            self.converter = converter
        }
        guard let converter = self.converter,
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: input.frameLength)
        else { throw MeetingPCMFormatContractError.unsupported("cannot allocate microphone PCM") }
        try converter.convert(to: output, from: input)
        guard output.frameLength == input.frameLength else {
            throw MeetingPCMFormatContractError.unsupported("incomplete microphone PCM conversion")
        }
        return try Self.makeSample(output, timingFrom: sample)
    }

    private static func makeSample(_ buffer: AVAudioPCMBuffer, timingFrom source: CMSampleBuffer) throws -> CMSampleBuffer {
        let audio = buffer.audioBufferList.pointee.mBuffers
        let byteCount = Int(audio.mDataByteSize)
        var block: CMBlockBuffer?
        guard let data = audio.mData,
              CMBlockBufferCreateWithMemoryBlock(
                  allocator: kCFAllocatorDefault,
                  memoryBlock: nil,
                  blockLength: byteCount,
                  blockAllocator: nil,
                  customBlockSource: nil,
                  offsetToData: 0,
                  dataLength: byteCount,
                  flags: kCMBlockBufferAssureMemoryNowFlag,
                  blockBufferOut: &block
              ) == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: data, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) == noErr
        else { throw MeetingPCMFormatContractError.unsupported("cannot own converted microphone PCM") }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(source, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0, count <= CMSampleBufferGetNumSamples(source)
        else { throw MeetingPCMFormatContractError.unsupported("invalid microphone timing") }
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(source, entryCount: count, arrayToFill: &timing, entriesNeededOut: nil) == noErr else {
            throw MeetingPCMFormatContractError.unsupported("cannot preserve microphone timing")
        }
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            formatDescription: buffer.format.formatDescription,
            sampleCount: Int(buffer.frameLength),
            sampleTimingEntryCount: count,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &result
        ) == noErr, let result else { throw MeetingPCMFormatContractError.unsupported("cannot create converted microphone sample") }
        if let attachments = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: source, attachmentMode: kCMAttachmentMode_ShouldPropagate) {
            CMSetAttachments(result, attachments: attachments, attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        return result
    }
}

// MARK: - CMSampleBuffer synthesis (free function, no AVAudioEngine dependency)

/// Owns a fresh copy of the bytes — never wraps the source's storage — because `writer.enqueue`
/// consumes asynchronously and the sample outlives the tap callback.
nonisolated func meetingMicrophoneSynthesizeSampleBuffer(
    from buffer: AVAudioPCMBuffer,
    presentationTime: CMTime
) -> CMSampleBuffer? {
    guard buffer.frameLength > 0 else { return nil }
    let frameCount = Int(buffer.frameLength)
    let channelCount = Int(buffer.format.channelCount)
    guard channelCount > 0 else { return nil }

    var asbd = buffer.format.streamDescription.pointee
    // CMSampleBuffer's block buffer below is canonical interleaved LPCM, regardless of whether
    // the tap supplied planar or interleaved AVAudioPCMBuffer storage. Keep the description and
    // payload topology truthful so downstream sinks can validate frame/byte totals.
    asbd.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved
    asbd.mBytesPerFrame = UInt32(channelCount * MemoryLayout<Float>.size)
    asbd.mBytesPerPacket = asbd.mBytesPerFrame
    var formatDescription: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard formatStatus == noErr, let formatDescription else { return nil }

    let byteCount = frameCount * channelCount * MemoryLayout<Float>.size
    var interleaved = Data(count: byteCount)
    if buffer.format.isInterleaved {
        guard let source = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
        interleaved.withUnsafeMutableBytes { destination in
            destination.copyBytes(from: UnsafeRawBufferPointer(start: source, count: byteCount))
        }
    } else {
        guard let channelData = buffer.floatChannelData else { return nil }
        interleaved.withUnsafeMutableBytes { destination in
            // Buffer size and channel topology are validated before this synchronous C call.
            // swiftlint:disable:next force_unwrapping
            let output = destination.baseAddress!.assumingMemoryBound(to: Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    output[frame * channelCount + channel] = channelData[channel][frame]
                }
            }
        }
    }

    var blockBuffer: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault,
        memoryBlock: nil,
        blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault,
        customBlockSource: nil,
        offsetToData: 0,
        dataLength: byteCount,
        flags: kCMBlockBufferAssureMemoryNowFlag,
        blockBufferOut: &blockBuffer
    )
    guard blockStatus == noErr, let blockBuffer else { return nil }

    let copyStatus = interleaved.withUnsafeBytes { bytes in
        CMBlockBufferReplaceDataBytes(
            // Buffer size and channel topology are validated before this synchronous C call.
            // swiftlint:disable:next force_unwrapping
            with: bytes.baseAddress!,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
    }
    guard copyStatus == noErr else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate.rounded())),
        presentationTimeStamp: presentationTime,
        decodeTimeStamp: .invalid
    )

    var sampleBuffer: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreate(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        dataReady: true,
        makeDataReadyCallback: nil,
        refcon: nil,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        sampleTimingEntryCount: 1,
        sampleTimingArray: &timing,
        sampleSizeEntryCount: 0,
        sampleSizeArray: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard sampleStatus == noErr else { return nil }
    return sampleBuffer
}
