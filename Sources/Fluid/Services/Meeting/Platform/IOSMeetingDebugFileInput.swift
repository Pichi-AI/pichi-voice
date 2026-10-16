#if os(iOS) && DEBUG
@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation

/// An explicit development input for the real capture owner. It replaces only the hardware
/// producer; Start, Stop, PCM sinks, storage choice, inference and attribution remain unchanged.
/// The private fixture is staged by the developer and is never created from microphone audio.
nonisolated struct IOSMeetingDebugFileInput: Sendable {
    let fileURL: URL
    let speed: Double
    private let directoryURL: URL

    static var isRequested: Bool { ProcessInfo.processInfo.environment["PICHI_DEBUG_AUDIO_INPUT"] == "1" }
    static var identity: MeetingMicrophoneIdentity {
        .init(captureDeviceID: "debug-file-input", coreAudioUID: "debug-file-input",
              displayName: PichiLocalization.text("Microphone"))
    }

    static func requested(environment: [String: String] = ProcessInfo.processInfo.environment,
                          applicationSupport: URL? = nil) throws -> Self? {
        guard environment["PICHI_DEBUG_AUDIO_INPUT"] == "1" else { return nil }
        guard let path = environment["PICHI_DEBUG_AUDIO_FILE"], !path.isEmpty,
              !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                  !$0.isEmpty && $0 != "." && $0 != ".."
              }),
              let speed = Double(environment["PICHI_DEBUG_AUDIO_SPEED"] ?? "1"),
              speed.isFinite, (0.1...32).contains(speed) else {
            throw InputError.invalidConfiguration
        }
        let support = try applicationSupport ?? FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
        let root = support.appendingPathComponent("DebugAudioInput", isDirectory: true)
        return Self(fileURL: root.appendingPathComponent(path), speed: speed, directoryURL: root)
    }

    func validateFile() throws {
        // Both lexical traversal and symlinks must stay inside the one explicit debug area.
        let allowed = self.directoryURL.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolved = self.fileURL.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(allowed),
              try resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw InputError.invalidFile
        }
    }

    enum InputError: LocalizedError {
        case invalidConfiguration, invalidFile, sourceChanged
        var errorDescription: String? {
            // These diagnostics are confined to an explicitly requested development build.
            switch self {
            case .invalidConfiguration: return "Invalid DEBUG audio input configuration."
            case .invalidFile: return "DEBUG audio input must be a regular file in Application Support/DebugAudioInput."
            case .sourceChanged: return "DEBUG audio input changed during capture."
            }
        }
    }
}

/// Owns one bounded reader/converter task. There is no AVAudioEngine, session activation or
/// output device. Cancellation joins the producer and flushes its finite resampling tail before
/// the existing capture owner finishes its writer/strict consumer.
final nonisolated class IOSMeetingDebugFileRuntime: IOSMeetingCaptureRuntime, @unchecked Sendable {
    private let input: IOSMeetingDebugFileInput
    private let trackID: MeetingAudioTrackID
    private let originHostTime: UInt64
    private let writer: MeetingAudioChunkWriter?
    private let memoryConsumer: (any MeetingMemoryAudioConsuming)?
    private let eventHandler: @Sendable (MeetingCaptureEvent) -> Void
    private let liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    private let lock = NSLock()
    private var worker: Task<Void, Error>?
    private var health = MeetingTrackHealth.waiting
    private var started = false
    private var stopping = false
    private var lastHealthEmission = -Double.infinity

    init(input: IOSMeetingDebugFileInput, trackID: MeetingAudioTrackID, originHostTime: UInt64,
         writer: MeetingAudioChunkWriter?, memoryConsumer: (any MeetingMemoryAudioConsuming)?,
         eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
         liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) throws {
        self.input = input; self.trackID = trackID; self.originHostTime = originHostTime
        self.writer = writer; self.memoryConsumer = memoryConsumer
        self.eventHandler = eventHandler; self.liveAudioHandler = liveAudioHandler
    }

    func start() async throws {
        try Task.checkCancellation()
        try self.input.validateFile()
        let file = try AVAudioFile(forReading: self.input.fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, file.processingFormat.sampleRate.isFinite,
              (8_000...192_000).contains(file.processingFormat.sampleRate),
              (1...8).contains(file.processingFormat.channelCount) else { throw MeetingCaptureError.unsupportedAudioFormat }
        let converter = try MeetingCapturePCMConverter()
        let facts = try self.fileFacts()
        try self.lock.withLock {
            guard !self.started, !self.stopping else { throw MeetingCaptureError.captureAlreadyActive }
            self.started = true
            self.worker = Task.detached(priority: .userInitiated) { [self] in
                do { try await self.run(file: file, converter: converter, facts: facts) }
                catch {
                    self.lock.withLock { self.health.status = .unavailable; self.health.detail = error.localizedDescription }
                    self.eventHandler(.interrupted(kind: .sourceLost, trackID: self.trackID, detail: error.localizedDescription))
                    self.eventHandler(.interrupted(kind: .captureStoppedUnexpectedly, trackID: self.trackID, detail: error.localizedDescription))
                    throw error
                }
            }
        }
    }

    func stop() async throws {
        let worker = self.lock.withLock { self.stopping = true; return self.worker }
        worker?.cancel()
        let result = await worker?.result
        self.lock.withLock { self.worker = nil; self.health.status = .stopped }
        try result?.get()
    }

    func healthSnapshot() -> MeetingTrackHealth { self.lock.withLock { self.health } }

    private struct FileFacts: Equatable { let size: UInt64; let inode: UInt64?; let modified: Date? }
    private func fileFacts() throws -> FileFacts {
        try self.input.validateFile()
        let values = try FileManager.default.attributesOfItem(atPath: self.input.fileURL.path)
        guard let size = values[.size] as? NSNumber else { throw IOSMeetingDebugFileInput.InputError.invalidFile }
        return FileFacts(size: size.uint64Value, inode: (values[.systemFileNumber] as? NSNumber)?.uint64Value,
                         modified: values[.modificationDate] as? Date)
    }

    private func run(file: AVAudioFile, converter: MeetingCapturePCMConverter, facts: FileFacts) async throws {
        let origin = AVAudioTime.seconds(forHostTime: self.originHostTime)
        let rate = file.processingFormat.sampleRate
        // 100 ms native blocks, capped independently of format or meeting duration.
        let capacity = AVAudioFrameCount(min(32_768, max(1, Int(rate / 10))))
        let began = ProcessInfo.processInfo.systemUptime
        var frames: Int64 = 0
        var acceptedFrames: Int64 = 0
        var lastDiagnostic = -Double.infinity
        var reachedEOF = false
        self.diagnostic(event: "begin", frames: 0, began: began, totalSeconds: Double(file.length) / rate)
        do {
            while true {
                try Task.checkCancellation()
                let hasInput = try autoreleasepool {
                    guard file.framePosition < file.length else { return false }
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
                        throw MeetingCapturePCMError.invalidBuffer
                    }
                    try file.read(into: buffer, frameCount: AVAudioFrameCount(min(Int64(capacity), file.length - file.framePosition)))
                    guard buffer.frameLength > 0 else { return false }
                    let mono = try MeetingCapturePCMConverter.ownedMonoCopy(of: buffer)
                    let pts = CMTime(seconds: origin + Double(frames) / rate, preferredTimescale: 1_000_000_000)
                    frames += Int64(buffer.frameLength)
                    if let sample = try converter.convert(mono, presentationTime: pts) {
                        try self.deliver(sample)
                        acceptedFrames += Int64(CMSampleBufferGetNumSamples(sample))
                    }
                    return true
                }
                guard hasInput else { reachedEOF = true; break }
                let elapsed = ProcessInfo.processInfo.systemUptime - began
                if elapsed - lastDiagnostic >= 5 {
                    self.diagnostic(event: "progress", frames: acceptedFrames, began: began)
                    lastDiagnostic = elapsed
                }
                let wait = Double(frames) / rate / self.input.speed - elapsed
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            }
        } catch is CancellationError { /* Stop owns all PCM admitted before its join. */ }
        try autoreleasepool {
            if let tail = try converter.finish() {
                try self.deliver(tail)
                acceptedFrames += Int64(CMSampleBufferGetNumSamples(tail))
            }
        }
        guard try self.fileFacts() == facts else { throw IOSMeetingDebugFileInput.InputError.sourceChanged }
        // EOF does not manufacture an interruption. The real visible Stop action owns the
        // transition into final ASR/diarization and may be pressed after this marker appears.
        self.diagnostic(event: reachedEOF ? "eof" : "stopped", frames: acceptedFrames, began: began)
    }

    private func deliver(_ sample: CMSampleBuffer) throws {
        if let writer, !writer.enqueue(sample) { throw MeetingCapturePCMError.transcriptionStopped }
        if let memoryConsumer, !memoryConsumer.enqueue(sample) {
            throw memoryConsumer.rejectionReason.map(MeetingCapturePCMError.transcriptionRejected)
                ?? .transcriptionStopped
        }
        self.liveAudioHandler?(.microphone, sample)
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let snapshot: MeetingTrackHealth? = self.lock.withLock {
            self.health.status = .healthy; self.health.lastSampleAt = Date()
            self.health.lastPresentationTime = MeetingMediaTime(value: pts.value, timescale: pts.timescale)
            let uptime = ProcessInfo.processInfo.systemUptime
            guard uptime - self.lastHealthEmission >= 0.1 else { return nil }
            self.lastHealthEmission = uptime
            var peak: Float = 0
            if let buffer = MeetingLiveSampleCopy.copy(sample)?.buffer, let values = buffer.floatChannelData?[0] {
                for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(values[index])) }
            }
            self.health.level = min(1, peak)
            return self.health
        }
        if let snapshot { self.eventHandler(.trackHealth(trackID: self.trackID, health: snapshot)) }
    }

    private func diagnostic(event: String, frames: Int64, began: Double, totalSeconds: Double? = nil) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        let footprint = status == KERN_SUCCESS ? String(info.phys_footprint) : "unavailable"
        let wall = ProcessInfo.processInfo.systemUptime - began
        let total = totalSeconds.map { " totalAudioSeconds=\($0)" } ?? ""
        DebugLogger.shared.log("debug_audio_input event=\(event) acceptedFrames=\(frames) audioSeconds=\(Double(frames) / 16_000) wallSeconds=\(wall) speed=\(self.input.speed) physicalFootprintBytes=\(footprint)\(total)", source: "IOSMeetingDebugFileRuntime")
    }
}
#endif
