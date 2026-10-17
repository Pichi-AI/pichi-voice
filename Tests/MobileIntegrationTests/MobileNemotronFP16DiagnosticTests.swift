@preconcurrency import AVFoundation
@preconcurrency import CoreML
import CryptoKit
import Foundation
import XCTest
@testable import PichiVoiceMobile

#if arch(arm64)
/// Private, opt-in experiments only. No model registration, settings mutation,
/// recording, installer, compute-plan probe, ASR or application session is involved.
private nonisolated struct NemotronFP16DiagnosticOptions: Sendable {
    enum Failure: Error { case invalidOptions, invalidArtifact, invalidAudio, invalidModelShape, invalidOutput }
    enum Candidate: String, Sendable {
        case fast32, fast128
        var config: Nemotron3Config { self == .fast32 ? .fast32 : .fast128 }
        var files: [(String, Int, String)] {
            if self == .fast32 {
                return [
                    ("weights/weight.bin", 198_566_016, "7353d8e7a5d29a8d15edf86dbf40bed4e82b7b8f456f302d5cdcbf850ed25358"),
                    ("model.mil", 501_830, "e2f0cbbf88e824385475779b637c36281c5f98f339783840bdf7b3dfcd08c123"),
                    ("coremldata.bin", 755, "fbc2d4dc25147427269e4774a5b8e3dd6b613e8c8458d74c7462a1a377dbae75"),
                    ("analytics/coremldata.bin", 243, "7932ba85d07f09ba8feff996e1278f376a9139e31141d2827021f1c225e590ae"),
                ]
            }
            return [
                ("weights/weight.bin", 198_590_592, "e8c90d2d0e16787a420de6805fd5b7a95c116fac0163208b5bc4d8a9ae459ca4"),
                ("model.mil", 502_794, "e7c029a46d9f327bec4c47fc34e5d32ee2cec9ce596950af0c403d05146b4ead"),
                ("coremldata.bin", 758, "ebcca7245d8d774305752b9f2b79433ad1858f8a06df3b326e0ae6305d981d25"),
                ("analytics/coremldata.bin", 243, "a71e06616a3ae7bddef06ce5dfc7fe523a286e489f63a8da2fc4f1e940d560a4"),
            ]
        }
    }
    static let silenceSHA256 = "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"
    static let modelRevision = "25a90f97f254428d4b30374b76af9c74fdee8327"
    let candidate: Candidate
    let cpuOnly: Bool
    let durationSeconds: Int
    let traceReadySeconds: Int
    let testedRevision: String
    let audioSHA256: String
    var computeUnits: MLComputeUnits { cpuOnly ? .cpuOnly : .cpuAndGPU }
    var sampleCount: Int { durationSeconds * 16_000 }
    // Match computeMel(final:) and AudioMelSpectrogram defaults: FFT 512, window
    // 400, hop 160. Both allowlisted prefixes give 1 + floor(sampleCount / 160).
    var expectedFrames: Int { 1 + (sampleCount + 512 - 400) / 160 }
    var expectedChunks: Int { (expectedFrames + candidate.config.chunkLen * 8 - 1) / (candidate.config.chunkLen * 8) }

    init(environment: [String: String]) throws {
        guard environment["PICHI_COMBINED_MEETING_E2E"] == "1",
              environment["PICHI_COMBINED_MEETING_PRIVATE_EVALUATION"] == "1",
              environment["PICHI_MEETING_DETAILED_PROFILE"] == "1",
              let candidate = Candidate(rawValue: environment["PICHI_NEMOTRON_FP16_CANDIDATE"] ?? "") else {
            throw Failure.invalidOptions
        }
        let compute = environment["PICHI_NEMOTRON_FP16_COMPUTE_UNITS"] ?? "cpuAndGPU"
        let duration = environment["PICHI_NEMOTRON_FP16_DURATION_SECONDS"] ?? "180"
        let traceReady = environment["PICHI_NEMOTRON_FP16_TRACE_READY_SECONDS"] ?? "0"
        let revision = environment["PICHI_COMBINED_MEETING_TESTED_REVISION"] ?? ""
        let audioDigest = environment["PICHI_NEMOTRON_FP16_AUDIO_SHA256"] ?? ""
        guard ["cpuOnly", "cpuAndGPU"].contains(compute), ["20", "180"].contains(duration),
              ["0", "10"].contains(traceReady), revision.count == 40,
              revision.allSatisfy({ $0.isHexDigit && !$0.isUppercase }), audioDigest.count == 64,
              audioDigest.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw Failure.invalidOptions }
        self.candidate = candidate
        self.cpuOnly = compute == "cpuOnly"
        self.durationSeconds = Int(duration)!
        self.traceReadySeconds = Int(traceReady)!
        self.testedRevision = revision
        self.audioSHA256 = audioDigest
    }

    static func digest(_ url: URL, size: Int) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == size else {
            throw Failure.invalidArtifact
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty {
            try Task.checkCancellation()
            bytes += data.count
            guard bytes <= size else { throw Failure.invalidArtifact }
            hasher.update(data: data)
        }
        guard bytes == size else { throw Failure.invalidArtifact }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func validateAssets(root: URL) throws -> (audio: URL, model: URL, silence: URL) {
        let directory = root.appendingPathComponent("diagnostics/NemotronFP16", isDirectory: true)
        let model = directory.appendingPathComponent(candidate.config.modelFileName, isDirectory: true)
        guard try model.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
              try model.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              let entries = FileManager.default.enumerator(at: model,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]) else {
            throw Failure.invalidArtifact
        }
        let expected = Set(candidate.files.map(\.0))
        var found = Set<String>()
        var entryCount = 0
        for case let url as URL in entries {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= 6 else { throw Failure.invalidArtifact }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw Failure.invalidArtifact }
            if values.isRegularFile == true {
                let relative = String(url.path.dropFirst(model.path.count + 1))
                guard expected.contains(relative), found.insert(relative).inserted else { throw Failure.invalidArtifact }
            } else if values.isDirectory != true { throw Failure.invalidArtifact }
        }
        guard found == expected else { throw Failure.invalidArtifact }
        for (path, size, digest) in candidate.files {
            guard try Self.digest(model.appendingPathComponent(path), size: size) == digest else { throw Failure.invalidArtifact }
        }
        let silence = directory.appendingPathComponent("learnable_sil_emb.bin")
        guard try Self.digest(silence, size: 2_048) == Self.silenceSHA256 else { throw Failure.invalidArtifact }
        let audio = root.appendingPathComponent("audio/combined-ru.wav")
        guard try Self.digest(audio, size: 5_760_044) == audioSHA256 else { throw Failure.invalidAudio }
        let input = try AVAudioFile(forReading: audio)
        guard input.length == 2_880_000, input.processingFormat.sampleRate == 16_000,
              input.processingFormat.channelCount == 1 else { throw Failure.invalidAudio }
        return (audio, model, silence)
    }
}

private nonisolated final class NemotronFP16DiagnosticExecution {
    private var diarizer: Nemotron3Diarizer?
    let modelLoadSeconds: Double
    let adapterInitializationSeconds: Double
    let options: NemotronFP16DiagnosticOptions
    private(set) var chunks: [[String: Any]] = []
    private(set) var segments: [MeetingNemotronSpeakerSegment] = []
    private(set) var deliveredSamples = 0
    private(set) var sourceReadSeconds: Double = 0
    private(set) var intervalAppendSeconds: Double = 0
    private(set) var finalizationSeconds: Double = 0
    private(set) var profile = Nemotron3Diarizer.PipelineProfile()

    init(options: NemotronFP16DiagnosticOptions, modelURL: URL, silenceURL: URL) throws {
        self.options = options
        let began = ProcessInfo.processInfo.systemUptime
        let configuration = MLModelConfiguration()
        configuration.computeUnits = options.computeUnits
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        modelLoadSeconds = ProcessInfo.processInfo.systemUptime - began
        try Task.checkCancellation()
        let config = options.candidate.config
        let inputs = model.modelDescription.inputDescriptionsByName
        let outputs = model.modelDescription.outputDescriptionsByName
        func array(_ description: MLFeatureDescription?, _ shape: [Int], _ type: MLMultiArrayDataType) -> Bool {
            description?.multiArrayConstraint?.shape.map(\.intValue) == shape
                && description?.multiArrayConstraint?.dataType == type
        }
        guard Set(inputs.keys) == Set(["chunk", "chunk_lengths", "spkcache", "spkcache_lengths", "fifo", "fifo_lengths"]),
              array(inputs["chunk"], [1, config.chunkMelFrames, 128], .float16),
              array(inputs["spkcache"], [1, 264, 512], .float16), array(inputs["fifo"], [1, 40, 512], .float16),
              ["chunk_lengths", "spkcache_lengths", "fifo_lengths"].allSatisfy({ array(inputs[$0], [1], .int32) }),
              array(outputs["speaker_preds"], [1, config.packedFrames, 8], .float16),
              array(outputs["speaker_preds_10ms"], [1, config.packedFrames * 8, 8], .float16),
              array(outputs["chunk_pre_encode_embs"], [1, config.chunkEncFrames, 512], .float16) else {
            throw NemotronFP16DiagnosticOptions.Failure.invalidModelShape
        }
        let adapterBegan = ProcessInfo.processInfo.systemUptime
        let silenceData = try Data(contentsOf: silenceURL)
        let silence = silenceData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard silence.count == 512, silence.allSatisfy(\.isFinite) else { throw NemotronFP16DiagnosticOptions.Failure.invalidArtifact }
        let models = try Nemotron3Models(config: config, model: model, silenceEmbedding: silence)
        diarizer = Nemotron3Diarizer(config: config, models: models)
        adapterInitializationSeconds = ProcessInfo.processInfo.systemUptime - adapterBegan
    }

    func process(audioURL: URL) throws {
        guard let diarizer else { throw NemotronFP16DiagnosticOptions.Failure.invalidOutput }
        let input = try AVAudioFile(forReading: audioURL)
        var intervals = MeetingFast32SpeakerIntervals(speakerCount: 8)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000))
        func consume(_ results: [Nemotron3ChunkResult]) throws {
            // At most one 2.56/10.24 second chunk completes per one-second append.
            guard results.count <= 1 else { throw NemotronFP16DiagnosticOptions.Failure.invalidOutput }
            for chunk in results {
                let began = ProcessInfo.processInfo.systemUptime
                try intervals.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
                intervalAppendSeconds += ProcessInfo.processInfo.systemUptime - began
                let row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(diarizer.lastProfile))
                chunks.append(["chunkIndex": chunks.count + 1, "inputSampleCursor": deliveredSamples,
                               "outputFrameCursor": diarizer.streamedFrameCount, "profile": row])
                guard chunks.count <= options.expectedChunks else { throw NemotronFP16DiagnosticOptions.Failure.invalidOutput }
            }
        }
        while deliveredSamples < options.sampleCount {
            try Task.checkCancellation()
            try autoreleasepool {
                let readBegan = ProcessInfo.processInfo.systemUptime
                let requested = min(16_000, options.sampleCount - deliveredSamples)
                try input.read(into: buffer, frameCount: AVAudioFrameCount(requested))
                guard Int(buffer.frameLength) == requested, let channel = buffer.floatChannelData?[0] else {
                    throw NemotronFP16DiagnosticOptions.Failure.invalidAudio
                }
                let samples = Array(UnsafeBufferPointer(start: channel, count: requested))
                guard samples.allSatisfy(\.isFinite) else { throw NemotronFP16DiagnosticOptions.Failure.invalidAudio }
                sourceReadSeconds += ProcessInfo.processInfo.systemUptime - readBegan
                deliveredSamples += requested
                diarizer.appendAudio(samples)
                try consume(diarizer.processBufferedAudio())
            }
        }
        try Task.checkCancellation()
        try autoreleasepool { try consume(diarizer.finishStream()) }
        profile = diarizer.lastProfile
        let finalizationBegan = ProcessInfo.processInfo.systemUptime
        segments = intervals.finish(duration: Double(options.durationSeconds))
        finalizationSeconds = ProcessInfo.processInfo.systemUptime - finalizationBegan
        guard deliveredSamples == options.sampleCount, diarizer.streamedFrameCount == options.expectedFrames,
              profile.outputFrameCount == options.expectedFrames, profile.melFrameCount == options.expectedFrames,
              profile.chunkCount == options.expectedChunks, chunks.count == options.expectedChunks,
              profile.failedChunkCount == 0, profile.skippedChunks == 0,
              segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0
                  && $0.end <= Double(options.durationSeconds) && $0.end > $0.start }) else {
            throw NemotronFP16DiagnosticOptions.Failure.invalidOutput
        }
    }

    func cleanup() { autoreleasepool { diarizer?.reset(); diarizer = nil } }
}

nonisolated final class MobileNemotronFP16DiagnosticTests: XCTestCase {
    @MainActor
    func testPinnedFP16DiagnosticReplay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PICHI_NEMOTRON_FP16_CANDIDATE"] != nil else {
            throw XCTSkip("Explicitly opt in to the pinned private FP16 diagnostic")
        }
        let options = try NemotronFP16DiagnosticOptions(environment: environment)
        let root = try MobileInferenceTestAssets.resolve(environment: environment)
        let task = Task.detached(priority: .userInitiated) {
            try await Self.run(options: options, root: root)
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
        let attachment = XCTAttachment(data: result.data, uniformTypeIdentifier: "public.json")
        attachment.name = "NemotronFP16Diagnostic-\(options.candidate.rawValue)-\(options.cpuOnly ? "cpuOnly" : "cpuAndGPU")-\(options.durationSeconds)s.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(result.success, "The diagnostic failed; inspect the metadata attachment, not a partial speed result")
    }

    nonisolated private static func run(options: NemotronFP16DiagnosticOptions, root: URL) async throws -> (data: Data, success: Bool) {
        let validationBegan = ProcessInfo.processInfo.systemUptime
        let assets = try options.validateAssets(root: root)
        let validationSeconds = ProcessInfo.processInfo.systemUptime - validationBegan
        let began = ProcessInfo.processInfo.systemUptime
        let cpuBegan = DiagnosticProcessCPUTime.capture()
        let sampler = try CombinedResourceSamples()
        sampler.capture(since: began)
        let task = Task.detached(priority: .utility) {
            while !Task.isCancelled {
                sampler.capture(since: began)
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { break }
            }
        }
        var execution: NemotronFP16DiagnosticExecution?
        var success = false
        var failureStage: String? = nil
        var failureCode: Int? = nil
        var stage = "modelLoad"
        var inferenceSeconds: Double = 0
        var inferenceProcessCPUTimeMilliseconds: Int64? = nil
        var traceReadySeconds: Double = 0
        do {
            sampler.setPhase(stage)
            DebugLogger.shared.log("candidate.model_load event=begin preset=\(options.candidate.rawValue)", source: "NemotronFP16Diagnostic")
            execution = try autoreleasepool { try NemotronFP16DiagnosticExecution(options: options, modelURL: assets.model, silenceURL: assets.silence) }
            if options.traceReadySeconds > 0 {
                stage = "traceReady"
                sampler.setPhase(stage)
                DebugLogger.shared.log("candidate.trace_ready event=begin delaySeconds=10", source: "NemotronFP16Diagnostic")
                let readyBegan = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(nanoseconds: 10_000_000_000)
                traceReadySeconds = ProcessInfo.processInfo.systemUptime - readyBegan
            }
            stage = "inference"
            sampler.setPhase(stage)
            DebugLogger.shared.log("candidate.inference event=begin", source: "NemotronFP16Diagnostic")
            let inferenceBegan = ProcessInfo.processInfo.systemUptime
            let inferenceCPU = DiagnosticProcessCPUTime.capture()
            try execution?.process(audioURL: assets.audio)
            inferenceSeconds = ProcessInfo.processInfo.systemUptime - inferenceBegan
            inferenceProcessCPUTimeMilliseconds = inferenceCPU.flatMap { DiagnosticProcessCPUTime.capture()?.milliseconds(since: $0) }
            success = true
        } catch {
            failureStage = stage
            failureCode = (error as NSError).code
        }
        sampler.setPhase("cleanup")
        let cleanupBegan = ProcessInfo.processInfo.systemUptime
        execution?.cleanup()
        let cleanupSeconds = ProcessInfo.processInfo.systemUptime - cleanupBegan
        sampler.capture(since: began)
        task.cancel()
        await task.value
        sampler.capture(since: began)
        let totalSeconds = ProcessInfo.processInfo.systemUptime - began
        let samples = sampler.snapshot()
        let cpuMilliseconds = cpuBegan.flatMap { DiagnosticProcessCPUTime.capture()?.milliseconds(since: $0) }
        var report: [String: Any] = [
            "schemaVersion": 1, "success": success, "testedRevision": options.testedRevision,
            "purpose": "Explicit private model-local diagnostic, not the production meeting pipeline",
            "candidate": options.candidate.rawValue, "modelRevision": NemotronFP16DiagnosticOptions.modelRevision,
            "runtimeRevision": "82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8",
            "computeUnitsRequested": options.cpuOnly ? "cpuOnly" : "cpuAndGPU",
            "computePlacement": "Requested policy only; actual GPU execution requires a process-attributed trace",
            "sourceSHA256": options.audioSHA256, "sourceFrameCount": 2_880_000,
            "prefixSampleCount": options.sampleCount, "durationSeconds": options.durationSeconds,
            "expectedOutputFrames": options.expectedFrames, "expectedChunks": options.expectedChunks,
            "sampleRate": 16_000, "configuration": try JSONSerialization.jsonObject(with: JSONEncoder().encode(options.candidate.config)),
            "modelFiles": options.candidate.files.map { ["path": $0.0, "bytes": $0.1, "sha256": $0.2] as [String: Any] },
            "silenceSHA256": NemotronFP16DiagnosticOptions.silenceSHA256,
            "validationSecondsExcludedFromRun": validationSeconds, "totalWallSeconds": totalSeconds,
            "traceReadinessDelaySeconds": traceReadySeconds, "inferenceWallSeconds": inferenceSeconds,
            "cleanupHostScopedReleaseSeconds": cleanupSeconds,
            "resourceSampleIntervalSeconds": sampler.intervalSeconds, "resourceSamples": samples.samples.map(\.json),
            "resourceClockOrigin": "After exact artifact/audio validation, immediately before model loading; ends after host-scoped release and joined sampler, before report JSON allocation",
            "missingResourceSamples": samples.missing, "omittedResourceSamples": samples.omitted,
            "maximumResourceSampleGapSeconds": samples.maximumGap, "missedResourceSampleIntervals": samples.missedIntervals,
            "maximumThermalState": samples.maximumThermalState,
            "limitations": "Unpaced WAV-prefix diarization only. No ASR, word attribution, PII, microphone, background, battery, UI, resume or end-to-end Stop latency. CPU counters cover all app threads. Sampled footprint is not a system-wide/GPU allocation peak. Cleanup records host references, not proof that driver caches were purged. Model configuration differs from W8A8 for fast128. No compute-plan probe runs.",
        ]
        report["failureStage"] = failureStage
        report["failureCode"] = failureCode
        report["processCPUTimeMilliseconds"] = cpuMilliseconds
        report["inferenceProcessCPUTimeMilliseconds"] = inferenceProcessCPUTimeMilliseconds
        if let execution {
            report["modelLoadSeconds"] = execution.modelLoadSeconds
            report["adapterInitializationSeconds"] = execution.adapterInitializationSeconds
            report["sourceReadSeconds"] = execution.sourceReadSeconds
            report["intervalAppendSeconds"] = execution.intervalAppendSeconds
            report["intervalFinalizationSeconds"] = execution.finalizationSeconds
            report["deliveredSamples"] = execution.deliveredSamples
            report["chunks"] = execution.chunks
            report["profile"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(execution.profile))
            report["segments"] = execution.segments.map { ["slot": $0.slotIndex, "startSeconds": $0.start, "endSeconds": $0.end] as [String: Any] }
        }
        DebugLogger.shared.log("candidate.complete success=\(success) preset=\(options.candidate.rawValue)", source: "NemotronFP16Diagnostic")
        return (try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]), success)
    }

    func testCandidateOptionsFreezeOnlyAllowlistedPrivateExperiments() throws {
        let base = ["PICHI_COMBINED_MEETING_E2E": "1", "PICHI_COMBINED_MEETING_PRIVATE_EVALUATION": "1",
                    "PICHI_MEETING_DETAILED_PROFILE": "1", "PICHI_NEMOTRON_FP16_CANDIDATE": "fast32",
                    "PICHI_NEMOTRON_FP16_AUDIO_SHA256": String(repeating: "b", count: 64),
                    "PICHI_COMBINED_MEETING_TESTED_REVISION": String(repeating: "a", count: 40)]
        let options = try NemotronFP16DiagnosticOptions(environment: base)
        XCTAssertEqual(options.sampleCount, 2_880_000)
        XCTAssertEqual(options.expectedFrames, 18_001)
        XCTAssertEqual(options.expectedChunks, 71)
        XCTAssertEqual(options.computeUnits, .cpuAndGPU)
        XCTAssertEqual(options.traceReadySeconds, 0)
        var probe = base
        probe["PICHI_NEMOTRON_FP16_CANDIDATE"] = "fast128"
        probe["PICHI_NEMOTRON_FP16_DURATION_SECONDS"] = "20"
        probe["PICHI_NEMOTRON_FP16_COMPUTE_UNITS"] = "cpuOnly"
        probe["PICHI_NEMOTRON_FP16_TRACE_READY_SECONDS"] = "10"
        let small = try NemotronFP16DiagnosticOptions(environment: probe)
        XCTAssertEqual(small.sampleCount, 320_000)
        XCTAssertEqual(small.expectedFrames, 2_001)
        XCTAssertEqual(small.expectedChunks, 2)
        XCTAssertEqual(small.computeUnits, .cpuOnly)
        for (key, value) in [("PICHI_COMBINED_MEETING_E2E", "0"), ("PICHI_COMBINED_MEETING_PRIVATE_EVALUATION", "0"),
                             ("PICHI_MEETING_DETAILED_PROFILE", "0"), ("PICHI_NEMOTRON_FP16_CANDIDATE", "offline"),
                             ("PICHI_NEMOTRON_FP16_COMPUTE_UNITS", "all"), ("PICHI_NEMOTRON_FP16_DURATION_SECONDS", "3600"),
                             ("PICHI_NEMOTRON_FP16_AUDIO_SHA256", "unverified"),
                             ("PICHI_NEMOTRON_FP16_TRACE_READY_SECONDS", "60"), ("PICHI_COMBINED_MEETING_TESTED_REVISION", "unknown")] {
            var invalid = base
            invalid[key] = value
            XCTAssertThrowsError(try NemotronFP16DiagnosticOptions(environment: invalid))
        }
        XCTAssertEqual(options.candidate.files.reduce(0) { $0 + $1.1 }, 199_068_844)
        XCTAssertEqual(small.candidate.files.reduce(0) { $0 + $1.1 }, 199_094_387)
    }

    func testDiagnosticHasherRequiresAnExactRegularFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("FP16HashProbe.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try NemotronFP16DiagnosticOptions.digest(file, size: 3),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try NemotronFP16DiagnosticOptions.digest(file, size: 2))
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try NemotronFP16DiagnosticOptions.digest(link, size: 3))
    }
}
#endif
