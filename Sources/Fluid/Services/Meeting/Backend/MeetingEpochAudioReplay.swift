@preconcurrency import AVFoundation
import Foundation

/// Retained recordings already have durable audio. A scoped PCM derivative removes the old
/// whole-epoch Float allocation while letting the diarizer replay a track with one shared state.
/// Only span mappings and file ownership survive conversion, never the decoded recording.
nonisolated struct MeetingEpochAudioReplay: Sendable {
    let source: any MeetingPCMReplaySource
    let sampleRate: Double
    let spanSamples: [MeetingMaterializedSpanSamples]
}

nonisolated extension MeetingEpochAudioMaterializing {
    func makeReplay(epoch: MeetingAnalysisEpochRecord, track: MeetingAnalysisTrackManifest,
                    manifest: MeetingAnalysisManifest, sessionDirectory: URL) async throws -> MeetingEpochAudioReplay {
        guard epoch.analysisInterval.duration <= 20 else {
            throw MeetingEpochMaterializationError.sampleLimitExceeded(
                spanID: epoch.spanIDs.first ?? "unknown", sampleCount: Int.max)
        }
        let value = try await self.materialize(epoch: epoch, track: track, manifest: manifest,
                                               sessionDirectory: sessionDirectory)
        guard value.samples.count <= 320_000 else {
            throw MeetingEpochMaterializationError.sampleLimitExceeded(
                spanID: epoch.spanIDs.first ?? "unknown", sampleCount: value.samples.count)
        }
        return MeetingEpochAudioReplay(source: MeetingArrayPCMReplay(samples: value.samples),
                                       sampleRate: value.sampleRate, spanSamples: value.spanSamples)
    }
}

private nonisolated struct MeetingArrayPCMReplay: MeetingPCMReplaySource {
    let samples: [Float]
    var totalSampleCount: Int { self.samples.count }
    func readSamples(in range: Range<Int>) async throws -> [Float] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= self.samples.count else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        return Array(self.samples[range])
    }
}

/// Its only mutable resource is a read handle protected by the lock. Destruction owns both
/// handle closure and deletion, including inference failure and cancellation paths.
private final nonisolated class MeetingScopedPCMReplayFile: MeetingPCMReplaySource, @unchecked Sendable {
    let totalSampleCount: Int
    private let url: URL
    private let handle: FileHandle
    private let lock = NSLock()

    init(url: URL, sampleCount: Int) throws {
        self.url = url
        self.totalSampleCount = sampleCount
        self.handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? self.handle.close()
        try? FileManager.default.removeItem(at: self.url)
    }

    func readSamples(in range: Range<Int>) async throws -> [Float] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= self.totalSampleCount,
              range.count <= 30 * 16_000 else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
        return try self.lock.withLock {
            try self.handle.seek(toOffset: UInt64(range.lowerBound) * 4)
            let expected = range.count * MemoryLayout<Float>.stride
            var data = Data()
            while data.count < expected {
                try Task.checkCancellation()
                guard let next = try self.handle.read(upToCount: expected - data.count), !next.isEmpty else {
                    throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                }
                data.append(next)
            }
            var result = [Float](repeating: 0, count: range.count)
            _ = result.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return result
        }
    }
}

nonisolated extension MeetingEpochAudioMaterializer {
    func makeReplay(epoch: MeetingAnalysisEpochRecord, track: MeetingAnalysisTrackManifest,
                    manifest _: MeetingAnalysisManifest, sessionDirectory: URL) async throws -> MeetingEpochAudioReplay {
        let spansByID = Dictionary(track.spans.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let spans = try epoch.spanIDs.map { id in
            guard let span = spansByID[id] else { throw MeetingEpochMaterializationError.unknownSpan(spanID: id) }
            return span
        }
        let url = sessionDirectory.appendingPathComponent(".analysis-replay-\(UUID().uuidString).pcm")
        guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                             attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw MeetingEpochMaterializationError.unreadable(spanID: spans.first?.id ?? "unknown")
        }
        var adopted = false
        defer { if !adopted { try? FileManager.default.removeItem(at: url) } }
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        var sampleCount = 0
        var mappings: [MeetingMaterializedSpanSamples] = []
        var start = 0
        while start < spans.count {
            try Task.checkCancellation()
            var end = start + 1
            while end < spans.count,
                  spans[end].captureEra.index == spans[start].captureEra.index,
                  spans[end].observed.decoded.sampleRate == spans[start].observed.decoded.sampleRate,
                  spans[end].observed.decoded.channelCount == spans[start].observed.decoded.channelCount,
                  spans[end].observed.decoded.processingFormatDescription == spans[start].observed.decoded.processingFormatDescription {
                end += 1
            }
            let reader = MeetingPCMConversionRun(spans: Array(spans[start..<end]), directory: sessionDirectory)
            let offset = sampleCount
            try autoreleasepool {
                try reader.convert(sampleRate: self.sampleRate) { buffer in
                    try Task.checkCancellation()
                    guard let samples = buffer.floatChannelData?[0] else {
                        throw MeetingEpochMaterializationError.unreadable(spanID: spans[start].id)
                    }
                    let count = Int(buffer.frameLength)
                    try writer.write(contentsOf: Data(bytes: samples, count: count * MemoryLayout<Float>.stride))
                    sampleCount += count
                }
            }
            let runCount = sampleCount - offset
            var sourceOffset = 0
            for (index, span) in spans[start..<end].enumerated() {
                let frames = reader.spanFrameCounts[index]
                let lower = min(runCount, Int((Double(sourceOffset) / reader.nativeSampleRate * self.sampleRate).rounded()))
                sourceOffset += frames
                let upper = index == end - start - 1 ? runCount
                    : min(runCount, Int((Double(sourceOffset) / reader.nativeSampleRate * self.sampleRate).rounded()))
                mappings.append(.init(spanID: span.id, sampleRange: (offset + lower)..<(offset + max(lower, upper))))
            }
            start = end
        }
        try writer.synchronize()
        try writer.close()
        let source = try MeetingScopedPCMReplayFile(url: url, sampleCount: sampleCount)
        adopted = true
        return MeetingEpochAudioReplay(source: source, sampleRate: self.sampleRate, spanSamples: mappings)
    }
}

/// Reads at most 32K native frames at a time. One converter remains alive across every span
/// in a continuous format/era run, matching the existing epoch materializer's filter ownership.
private final nonisolated class MeetingPCMConversionRun {
    let spans: [MeetingAnalysisSpan]
    let directory: URL
    var spanFrameCounts: [Int] = []
    var nativeSampleRate: Double { self.spans[0].observed.decoded.sampleRate }
    private var index = 0
    private var current: (file: AVAudioFile, url: URL, end: AVAudioFramePosition)?

    init(spans: [MeetingAnalysisSpan], directory: URL) { self.spans = spans; self.directory = directory }

    private func verify(_ span: MeetingAnalysisSpan, url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MeetingEpochMaterializationError.fileMissing(spanID: span.id)
        }
        guard (attributes[.size] as? NSNumber)?.int64Value == span.storedByteCount else {
            throw MeetingEpochMaterializationError.byteCountChanged(spanID: span.id)
        }
        guard MeetingChunkPathConfinement.sha256Hex(contentsOf: url) == span.storedSHA256.lowercased() else {
            try Task.checkCancellation()
            throw MeetingEpochMaterializationError.hashChanged(spanID: span.id)
        }
    }

    private func next(maximumFrames: Int) throws -> AVAudioPCMBuffer? {
        while self.index < self.spans.count {
            try Task.checkCancellation()
            let span = self.spans[self.index]
            if self.current == nil {
                if let encoding = span.chunk.analysisEncoding, encoding != .linearPCMFloat32CAFV1 {
                    throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
                }
                let url: URL
                do { url = try MeetingChunkPathConfinement.containedURL(sessionDirectory: self.directory,
                                                                        relativePath: span.chunk.relativeFilePath) }
                catch { throw MeetingEpochMaterializationError.pathRejected(spanID: span.id) }
                try self.verify(span, url: url)
                let file = try AVAudioFile(forReading: url)
                let observed = span.observed.decoded
                guard file.processingFormat.sampleRate == observed.sampleRate,
                      Int(file.processingFormat.channelCount) == observed.channelCount,
                      file.length == observed.frameCount else {
                    throw MeetingEpochMaterializationError.decodedFactsChanged(spanID: span.id, detail: "replay format changed")
                }
                let first = AVAudioFramePosition((span.sourceLocalInterval.start * observed.sampleRate).rounded(.down))
                let last = min(file.length, AVAudioFramePosition((span.sourceLocalInterval.end * observed.sampleRate).rounded(.up)))
                guard last > first else { throw MeetingEpochMaterializationError.emptySlice(spanID: span.id) }
                self.spanFrameCounts.append(Int(last - first))
                file.framePosition = first
                self.current = (file, url, last)
            }
            guard let current = self.current else { continue }
            if current.file.framePosition >= current.end {
                try self.verify(span, url: current.url)
                self.current = nil
                self.index += 1
                continue
            }
            let count = AVAudioFrameCount(min(Int64(maximumFrames), current.end - current.file.framePosition))
            guard let input = AVAudioPCMBuffer(pcmFormat: current.file.processingFormat, frameCapacity: count),
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.nativeSampleRate,
                                             channels: 1, interleaved: false),
                  let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else {
                throw MeetingEpochMaterializationError.unreadable(spanID: span.id)
            }
            try current.file.read(into: input, frameCount: count)
            guard input.frameLength > 0, let channels = input.floatChannelData,
                  let target = mono.floatChannelData?[0] else {
                throw MeetingEpochMaterializationError.decodedFactsChanged(spanID: span.id, detail: "replay short read")
            }
            mono.frameLength = input.frameLength
            let channelCount = Int(input.format.channelCount)
            for frame in 0..<Int(input.frameLength) {
                var value: Float = 0
                for channel in 0..<channelCount {
                    value += input.format.isInterleaved ? channels[0][frame * channelCount + channel] : channels[channel][frame]
                }
                target[frame] = value / Float(channelCount)
            }
            return mono
        }
        return nil
    }

    func convert(sampleRate: Double, emit: (AVAudioPCMBuffer) throws -> Void) throws {
        if sampleRate == self.nativeSampleRate {
            while true {
                let hasNext = try autoreleasepool {
                    guard let buffer = try self.next(maximumFrames: 32_768) else { return false }
                    try emit(buffer)
                    return true
                }
                if !hasNext { break }
            }
            return
        }
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.nativeSampleRate,
                                        channels: 1, interleaved: false),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input, to: output),
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 32_768) else {
            throw MeetingEpochMaterializationError.unreadable(spanID: self.spans[0].id)
        }
        var inputError: Error?
        var retainedInput: AVAudioPCMBuffer?
        while true {
            try Task.checkCancellation()
            buffer.frameLength = 0
            var conversionError: NSError?
            let status = try autoreleasepool {
                let status = converter.convert(to: buffer, error: &conversionError) { requested, state in
                    do {
                        retainedInput = try self.next(maximumFrames: max(1, min(Int(requested), 32_768)))
                        state.pointee = retainedInput == nil ? .endOfStream : .haveData
                        return retainedInput
                    } catch {
                        inputError = error
                        state.pointee = .endOfStream
                        return nil
                    }
                }
                if let inputError { throw inputError }
                if let conversionError { throw conversionError }
                if buffer.frameLength > 0 { try emit(buffer) }
                return status
            }
            if status == .endOfStream { break }
            if status == .error { throw MeetingEpochMaterializationError.unreadable(spanID: self.spans[0].id) }
        }
    }
}
