import AVFoundation
import CryptoKit
import Darwin
import Foundation
import PichiGigaAM
import XCTest
#if os(macOS)
@testable import FluidVoice_Debug
#else
@testable import PichiVoiceMobile
#endif

/// Opt-in raw provider replay. One engine per test process is required for memory comparisons.
/// No microphone, history, enhancement, dictionary admission or download is performed here.
@MainActor
final class QwenGigaAMBenchmarkTests: XCTestCase {
    func testManifestRejectsDuplicateIDsAndUnsafePaths() throws {
        var manifest = Self.syntheticManifest()
        XCTAssertNoThrow(try manifest.validate())
        manifest.clips.append(manifest.clips[0])
        XCTAssertThrowsError(try manifest.validate())
        for path in ["../a.wav", "/a.wav", "a//b.wav", "a/./b.wav", "a\\b.wav", "a.mp3"] {
            manifest = Self.syntheticManifest(path: path)
            XCTAssertThrowsError(try manifest.validate(), path)
        }
    }

    func testManifestRejectsUnscorableOrUnboundedInputs() throws {
        for reference in ["", "  \n"] {
            XCTAssertThrowsError(try Self.syntheticManifest(reference: reference).validate())
        }
        for duration in [Double.nan, .infinity, -1, 0, 61] {
            XCTAssertThrowsError(try Self.syntheticManifest(duration: duration).validate())
        }
        XCTAssertThrowsError(try Self.syntheticManifest(hash: "not-a-digest").validate())
    }

    func testAudioLoaderChecksDigestChannelsAndPhysicalDuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paired-asr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("a.wav")
        try Self.writeSilence(url, channels: 1)
        var clip = Self.syntheticManifest().clips[0]
        clip.audioSHA256 = try PairedASRFixture.sha256(url)
        XCTAssertEqual(try PairedASRFixture.samples(clip, root: root).count, 16_000)
        clip.audioSHA256 = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try PairedASRFixture.samples(clip, root: root))
        clip.audioSHA256 = try PairedASRFixture.sha256(url)
        clip.durationSeconds = 2
        XCTAssertThrowsError(try PairedASRFixture.samples(clip, root: root))
        try FileManager.default.removeItem(at: url)
        try Self.writeSilence(url, channels: 2)
        clip.audioSHA256 = try PairedASRFixture.sha256(url)
        clip.durationSeconds = 1
        XCTAssertThrowsError(try PairedASRFixture.samples(clip, root: root))
    }

    func testAudioLoaderRejectsSymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("paired-asr-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a.wav"),
            withDestinationURL: root.deletingLastPathComponent().appendingPathComponent("outside.wav"))
        XCTAssertThrowsError(try PairedASRFixture.samples(Self.syntheticManifest().clips[0], root: root))
    }

    func testOptInRussianPairedBenchmark() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PICHI_ASR_BENCH_RUN"] == "1" else {
            throw XCTSkip("Opt-in public-fixture benchmark: PICHI_ASR_BENCH_RUN=1")
        }
        guard env["PICHI_ASR_BENCH_PUBLIC_FIXTURES"] == "1",
              let engine = env["PICHI_ASR_BENCH_ENGINE"], ["qwen", "gigaam"].contains(engine),
              let revision = env["PICHI_ASR_BENCH_REVISION"],
              revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw PairedASRFixture.Failure.invalid("Explicit public-fixture, engine and revision gates required")
        }
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("QwenGigaAMBenchmark", isDirectory: true)
        let manifestURL = env["PICHI_ASR_BENCH_MANIFEST"].flatMap { $0 == "application-support" ? nil : URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("manifest.json")
        let root = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let manifestData = try PairedASRFixture.boundedData(manifestURL, maximum: 2_097_152)
        let manifest = try JSONDecoder().decode(PairedASRFixture.Manifest.self, from: manifestData)
        try manifest.validate()
        let maximum = try Self.boundedInteger(env["PICHI_ASR_BENCH_MAX_CLIPS"], fallback: manifest.clips.count, range: 1...500)
        let repetitions = try Self.boundedInteger(env["PICHI_ASR_BENCH_REPETITIONS"], fallback: 1, range: 1...3)
        let clips = Array(manifest.clips.prefix(maximum))
        let modelDirectory = env["PICHI_ASR_BENCH_MODEL_DIR"].flatMap { $0 == "application-support" ? nil : URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("models/\(engine)", isDirectory: true)
        let suiteName = "paired-asr-\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        let provider: any TranscriptionProvider
        if engine == "qwen" {
            provider = WhisperProvider(modelDirectory: modelDirectory, modelOverride: .qwen3Asr06BQ4,
                useAutomaticLanguageDetection: true)
        } else {
            let descriptor = GigaAMModelCatalog.downloadableModel
            provider = PichiGigaAMProvider(modelStore: .init(directory: modelDirectory,
                downloadDescriptor: descriptor, importDescriptors: [descriptor],
                preferences: preferences, environment: [:]), expectedModelFingerprint: descriptor.fingerprint)
        }
        guard provider.modelsExistOnDisk() else {
            throw PairedASRFixture.Failure.invalid("Verified model must be staged before benchmark; downloads are disabled")
        }
        var report = PairedASRReport(engine: engine, manifestSHA256: PairedASRFixture.hash(manifestData),
            revision: revision, fixtureCount: clips.count, repetitions: repetitions)
        report.providerName = provider.name
        report.modelID = engine == "qwen" ? "qwen3-asr-0.6b-q4" : GigaAMModelCatalog.downloadableModel.id
        report.modelArtifactSHA256 = engine == "qwen"
            ? TranscribeSpeechModelCatalog.qwen06Q4.sha256
            : GigaAMModelCatalog.downloadableModel.modelSHA256
        if engine == "qwen" {
            let descriptor = TranscribeSpeechModelCatalog.qwen06Q4
            report.modelArtifact = ["fileName": descriptor.fileName, "repository": descriptor.repository,
                "revision": descriptor.revision, "expectedBytes": String(descriptor.expectedBytes)]
        } else {
            let descriptor = GigaAMModelCatalog.downloadableModel
            report.modelArtifact = ["fileName": descriptor.modelFile,
                "source": descriptor.downloadBaseURL?.absoluteString ?? "unavailable",
                "fingerprint": descriptor.fingerprint]
        }
        let sampler = PairedASRMemorySampler()
        sampler.mark("baseline")
        do {
            sampler.mark("load")
            var began = ProcessInfo.processInfo.systemUptime
            try await provider.prepare(progressHandler: nil)
            report.loadSeconds = ProcessInfo.processInfo.systemUptime - began
            if let gigaam = provider as? PichiGigaAMProvider {
                report.loadedModelFingerprint = gigaam.loadedModelFingerprint
                guard gigaam.loadedModelFingerprint == GigaAMModelCatalog.downloadableModel.fingerprint else {
                    throw PairedASRFixture.Failure.invalid("Prepared GigaAM artifact differs from the pinned Q8 model")
                }
            }
            // Decode outside the measured provider call. The first real inference is reported
            // separately; scored runs are warm, without claiming a cold filesystem/cache.
            let warmup = try PairedASRFixture.samples(try XCTUnwrap(clips.first), root: root)
            sampler.mark("warmup")
            began = ProcessInfo.processInfo.systemUptime
            _ = try await provider.transcribe(warmup)
            report.warmupSeconds = ProcessInfo.processInfo.systemUptime - began
            if let status = provider.executionStatus {
                report.executionStatus = ["providerReportedBackend": status.backend.rawValue,
                    "fallbackReason": status.fallbackReason ?? "none",
                    "scope": "Provider execution status; hardware utilization not traced"]
            } else if engine == "qwen" {
                report.executionStatus = ["requestedBackend": String(describing: WhisperProvider.platformBackend),
                    "scope": "Configured backend; actual hardware utilization not traced"]
            }
            for iteration in 0..<repetitions {
                for clip in clips {
                    try Task.checkCancellation()
                    sampler.mark("decode")
                    let samples = try PairedASRFixture.samples(clip, root: root)
                    sampler.mark("inference")
                    began = ProcessInfo.processInfo.systemUptime
                    let result = try await provider.transcribe(samples)
                    let wall = ProcessInfo.processInfo.systemUptime - began
                    report.runs.append(.init(clipID: clip.id, audioSHA256: clip.audioSHA256,
                        reference: clip.reference, hypothesis: result.text, durationSeconds: clip.durationSeconds,
                        iteration: iteration, wallSeconds: wall, phase: "warm"))
                }
            }
        } catch {
            report.status = "failed"
            report.failure = String(describing: type(of: error))
            sampler.mark("release")
            await Task { @MainActor in await provider.releaseResidency() }.value
            report.memory = sampler.stop()
            try self.attach(report, output: env["PICHI_ASR_BENCH_OUTPUT"])
            throw error
        }
        sampler.mark("release")
        await Task { @MainActor in await provider.releaseResidency() }.value
        report.memory = sampler.stop()
        guard !provider.isReady else {
            report.status = "failed"
            report.failure = "Owned model did not unload after replay"
            try self.attach(report, output: env["PICHI_ASR_BENCH_OUTPUT"])
            throw PairedASRFixture.Failure.invalid("Owned model did not unload after replay")
        }
        report.status = "completed"
        try self.attach(report, output: env["PICHI_ASR_BENCH_OUTPUT"])
    }

    private func attach(_ report: PairedASRReport, output: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "PairedASR-\(report.engine)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let output {
            let destination = URL(fileURLWithPath: output)
            try data.write(to: destination, options: .atomic)
        }
    }

    private static func boundedInteger(_ raw: String?, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        guard let raw else { return fallback }
        guard let value = Int(raw), range.contains(value) else { throw PairedASRFixture.Failure.invalid("Out-of-range benchmark count") }
        return value
    }

    private static func syntheticManifest(path: String = "a.wav", reference: String = "Проверка ёлки.",
                                          duration: Double = 1, hash: String = String(repeating: "a", count: 64)) -> PairedASRFixture.Manifest {
        .init(schemaVersion: 1, dataset: "synthetic", source: "https://example.org/fixture", revision: "test-v1",
            license: "CC0-1.0", split: "test", clips: [.init(id: "one", path: path, audioSHA256: hash,
                reference: reference, durationSeconds: duration)])
    }

    private static func writeSilence(_ url: URL, channels: AVAudioChannelCount) throws {
        // A complete PCM fixture must be closed before the loader hashes or opens it.
        // A small RIFF container avoids an autoreleased audio writer in this fixture.
        let channelCount = UInt16(channels)
        let dataBytes = UInt32(16_000) * UInt32(channelCount) * 2
        var data = Data()
        func append16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func append32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append32(36 + dataBytes)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append32(16)
        append16(1)
        append16(channelCount)
        append32(16_000)
        append32(16_000 * UInt32(channelCount) * 2)
        append16(channelCount * 2)
        append16(16)
        data.append(contentsOf: "data".utf8)
        append32(dataBytes)
        data.append(Data(repeating: 0, count: Int(dataBytes)))
        try data.write(to: url)
    }
}

private nonisolated enum PairedASRFixture {
    enum Failure: Error { case invalid(String) }
    struct Clip: Codable {
        let id: String
        let path: String
        var audioSHA256: String
        let reference: String
        var durationSeconds: Double
    }
    struct Manifest: Codable {
        let schemaVersion: Int
        let dataset: String
        let source: String
        let revision: String
        let license: String
        let split: String
        var clips: [Clip]

        func validate() throws {
            guard schemaVersion == 1, !dataset.isEmpty, !revision.isEmpty, !license.isEmpty,
                  !split.isEmpty, URL(string: source)?.scheme == "https", (1...500).contains(clips.count),
                  Set(clips.map(\.id)).count == clips.count,
                  Set(clips.map(\.path)).count == clips.count else { throw Failure.invalid("Invalid manifest identity/coverage") }
            for clip in clips {
                let parts = clip.path.split(separator: "/", omittingEmptySubsequences: false)
                guard !clip.id.isEmpty, clip.id.count <= 128, clip.path.count <= 256,
                      !clip.path.hasPrefix("/"), !clip.path.hasPrefix("~"), !clip.path.contains("\0"),
                      !clip.path.contains("\\"), clip.path.hasSuffix(".wav"),
                      parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                      clip.audioSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                      !clip.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      clip.reference.count <= 10_000, clip.durationSeconds.isFinite,
                      clip.durationSeconds > 0, clip.durationSeconds <= 60 else { throw Failure.invalid("Invalid clip identity/geometry") }
            }
        }
    }

    static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= maximum else { throw Failure.invalid("Fixture is not a bounded regular file") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw Failure.invalid("Fixture exceeded read limit") }
        return data
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func sha256(_ url: URL) throws -> String { hash(try boundedData(url, maximum: 4_194_304)) }

    static func samples(_ clip: Clip, root: URL) throws -> [Float] {
        let canonicalRoot = root.resolvingSymlinksInPath()
        let url = canonicalRoot.appendingPathComponent(clip.path).standardizedFileURL
        guard url.resolvingSymlinksInPath() == url, url.path.hasPrefix(canonicalRoot.path + "/"),
              try sha256(url) == clip.audioSHA256 else { throw Failure.invalid("Fixture path/digest mismatch") }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1,
              file.length > 0, file.length <= 960_000,
              abs(Double(file.length) / 16_000 - clip.durationSeconds) <= 1.0 / 16_000 else { throw Failure.invalid("Fixture PCM geometry mismatch") }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        guard Int64(buffer.frameLength) == file.length, let channel = buffer.floatChannelData?[0] else { throw Failure.invalid("Incomplete fixture decode") }
        let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        guard samples.allSatisfy(\.isFinite) else { throw Failure.invalid("Non-finite fixture PCM") }
        return samples
    }

    static func hardwareModel() -> String? {
        #if os(iOS)
        let key = "hw.machine"
        #else
        let key = "hw.model"
        #endif
        var count = 0
        guard sysctlbyname(key, nil, &count, nil, 0) == 0, (1...256).contains(count) else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = bytes.withUnsafeMutableBytes { sysctlbyname(key, $0.baseAddress, &count, nil, 0) }
        guard status == 0 else { return nil }
        return String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
}

private nonisolated struct PairedASRReport: Encodable {
    struct Run: Encodable {
        let clipID: String
        let audioSHA256: String
        let reference: String
        let hypothesis: String
        let durationSeconds: Double
        let iteration: Int
        let wallSeconds: Double
        let phase: String
    }
    let schemaVersion = 1
    let engine: String
    let manifestSHA256: String
    let revision: String
    let fixtureCount: Int
    let repetitions: Int
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let processorCount = ProcessInfo.processInfo.processorCount
    let hardwareModel = PairedASRFixture.hardwareModel()
    let scope = "Raw production provider; no enhancement/dictionary; one engine per process; filesystem cache uncontrolled"
    #if targetEnvironment(simulator)
    let platform = "iOS-simulator"
    #elseif os(iOS)
    let platform = "iOS-device"
    #else
    let platform = "macOS"
    #endif
    var status = "in-progress"
    var failure: String?
    var loadSeconds = 0.0
    var warmupSeconds = 0.0
    var modelID: String?
    var providerName: String?
    var modelArtifactSHA256: String?
    var modelArtifact: [String: String]?
    var loadedModelFingerprint: String?
    var executionStatus: [String: String]?
    var memory: PairedASRMemorySampler.Snapshot?
    var runs: [Run] = []
}

/// Dedicated queue samples process phys_footprint while inference may block MainActor.
/// Peaks are sampled host-process footprints, not GPU/device allocation peaks.
private final nonisolated class PairedASRMemorySampler: @unchecked Sendable {
    struct Phase: Encodable {
        var samples = 0
        var missingSamples = 0
        var firstBytes: UInt64?
        var lastBytes: UInt64?
        var peakBytes: UInt64?
        var maximumGapSeconds = 0.0
        var maximumThermalState = 0
        var previousTime: Double?
        private enum CodingKeys: String, CodingKey {
            case samples, missingSamples, firstBytes, lastBytes, peakBytes, maximumGapSeconds, maximumThermalState
        }
    }
    struct Snapshot: Encodable {
        let intervalSeconds: Double
        let scope: String
        let phases: [String: Phase]
    }
    private let queue = DispatchQueue(label: "pichi.tests.paired-asr-footprint")
    private let interval = 0.025
    private var timer: DispatchSourceTimer?
    private var phase = "baseline"
    private var phases: [String: Phase] = [:]

    init() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(2))
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()
    }

    func mark(_ value: String) {
        queue.sync {
            if self.phase != value, var prior = self.phases[value] {
                prior.previousTime = nil
                self.phases[value] = prior
            }
            self.phase = value
            self.sample()
        }
    }

    func stop() -> Snapshot {
        timer?.cancel()
        timer = nil
        return queue.sync {
            self.sample()
            return Snapshot(intervalSeconds: self.interval,
                scope: "Sampled task_vm_info.phys_footprint of test host; includes app/test/PCM overhead; no driver-cache purge claimed",
                phases: self.phases)
        }
    }

    deinit { timer?.cancel() }

    private func sample() {
        var value = phases[phase] ?? Phase()
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = value.previousTime { value.maximumGapSeconds = max(value.maximumGapSeconds, now - previous) }
        value.previousTime = now
        value.maximumThermalState = max(value.maximumThermalState, ProcessInfo.processInfo.thermalState.rawValue)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS {
            value.samples += 1
            if value.firstBytes == nil { value.firstBytes = info.phys_footprint }
            value.lastBytes = info.phys_footprint
            value.peakBytes = max(value.peakBytes ?? 0, info.phys_footprint)
        } else { value.missingSamples += 1 }
        phases[phase] = value
    }
}
