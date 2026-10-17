import Foundation
import CoreML
import PichiGigaAM
import CryptoKit
import Darwin

/// Offline PCM input. The private corpus owns its files, and model calls read bounded ranges.
nonisolated final class WAVSource: MeetingPCMReplaySource, @unchecked Sendable {
    let path: String
    let offset: Int
    let totalSampleCount: Int

    init(path: String) throws {
        self.path = path
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
        guard bytes.count >= 44 else { throw Failure.invalidWAV }
        func u16(_ index: Int) -> Int { Int(bytes[index]) | Int(bytes[index + 1]) << 8 }
        func u32(_ index: Int) -> Int { u16(index) | u16(index + 2) << 16 }
        func word(_ index: Int) -> String { String(decoding: bytes[index..<index + 4], as: UTF8.self) }
        guard word(0) == "RIFF", word(8) == "WAVE" else { throw Failure.invalidWAV }
        var cursor = 12
        var foundOffset: Int?
        var foundBytes: Int?
        var validFormat = false
        while cursor + 8 <= bytes.count {
            let count = u32(cursor + 4)
            if word(cursor) == "fmt " {
                guard count >= 16, cursor + 24 <= bytes.count else { throw Failure.invalidWAV }
                validFormat = u16(cursor + 8) == 1 && u16(cursor + 10) == 1 && u32(cursor + 12) == 16_000
                    && u16(cursor + 20) == 2 && u16(cursor + 22) == 16
            }
            if word(cursor) == "data" { foundOffset = cursor + 8; foundBytes = count; break }
            cursor += 8 + count + count % 2
        }
        guard validFormat, let foundOffset, let foundBytes, foundBytes > 0, foundBytes % 2 == 0 else { throw Failure.invalidWAV }
        let size = try handle.seekToEnd()
        guard UInt64(foundOffset) + UInt64(foundBytes) <= size else { throw Failure.invalidWAV }
        self.offset = foundOffset
        self.totalSampleCount = foundBytes / 2
    }

    func readSamples(in range: Range<Int>) async throws -> [Float] {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound <= self.totalSampleCount else { throw Failure.invalidWAV }
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: self.path))
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(self.offset + range.lowerBound * 2))
        let bytes = try handle.read(upToCount: range.count * 2) ?? Data()
        guard bytes.count == range.count * 2 else { throw Failure.invalidWAV }
        var result = [Float](repeating: 0, count: range.count)
        bytes.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: UInt8.self)
            for index in result.indices {
                let value = UInt16(source[index * 2]) | UInt16(source[index * 2 + 1]) << 8
                result[index] = Float(Int16(bitPattern: value)) / 32768
            }
        }
        return result
    }
    enum Failure: Error { case invalidWAV }
}

nonisolated struct NativeClipEvidence: Codable {
    let schemaVersion: Int
    let clipID: String
    let audioSHA256: String
    let sampleCount: Int
    let sampleRate: Int
    let trackID: UUID
    let units: [MeetingFinalTextUnit]
    let activity: [MeetingBackendSpeakerActivity]
    let initialAcousticAssignments: [MeetingBackendSpeakerAssignment]
    let nativeProjectionPolicy: MeetingSpeakerAttributionPolicy
    let baselineCoverageAssignments: [MeetingBackendSpeakerAssignment]
    let baselineAssignments: [MeetingBackendSpeakerAssignment]
    let metadata: Metadata
    struct Metadata: Codable {
        let processID: Int32
        let nativeBuildManifestSHA256: String
        let requestedComputeUnits: String
        let preferredComputeUnits: String
        let asrArtifactFingerprint: String
        let fast32ConfigJSON: String
        let fast32AssetSHA256: [String: String]
        let asrLoadSeconds: Double
        let asrInferenceSeconds: Double
        let diarizerLoadSeconds: Double
        let diarizerInferenceSeconds: Double
        let peakProcessRSSBytes: Int64
        let processRSSCaveat: String
        let asrWindowPolicy: String
        let identityVerification: String
    }
}

nonisolated struct ReplayResult: Codable {
    let schemaVersion: Int
    let evidenceSHA256: String
    let clipID: String
    let policy: MeetingSpeakerAttributionPolicy
    let policyFingerprint: String
    let projectionAssignments: [String: MeetingBackendSpeakerAssignment]
    let resolution: MeetingSpeakerAttributionResolution
    let replaySeconds: Double
    let deterministicRepeatEqual: Bool
    let unchangedOriginalUnitCount: Int
}

@main nonisolated struct Runner {
    static func write<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func floats(_ path: URL) throws -> [Float] {
        let data = try Data(contentsOf: path)
        guard data.count % 4 == 0 else { throw WAVSource.Failure.invalidWAV }
        return data.withUnsafeBytes { raw in
            (0..<data.count / 4).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self))) }
        }
    }

    static func peakRSS() -> Int64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return -1 }
        return Int64(usage.ru_maxrss)
    }

    static func computeName(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpuOnly"
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        case .all: return "all"
        @unknown default: return "unknown-\(units.rawValue)"
        }
    }

    static func stableUUID(_ digest: String) -> UUID {
        let chars = Array(digest.prefix(32))
        let groups = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }
        return UUID(uuidString: groups.joined(separator: "-"))!
    }

    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { fatalError("Use infer WAV GIGAAM_DIR FAST32_DIR OUTPUT CLIP_ID COMPUTE or replay EVIDENCE OUTPUT [POLICY].") }
        if args[1] == "write-policy" {
            guard args.count == 3 else { fatalError("write-policy expects one new output path") }
            try self.write(MeetingSpeakerAttributionPolicy.standard, to: args[2])
            print("PASS exported current native policy version=\(MeetingSpeakerAttributionPolicy.currentVersion)")
        } else if args[1] == "infer" {
            guard args.count == 8 else { fatalError("infer expects six arguments") }
            let source = try WAVSource(path: args[2])
            let gigaDirectory = URL(fileURLWithPath: args[3], isDirectory: true)
            let bundle = URL(fileURLWithPath: args[4], isDirectory: true)
            let outputPath = args[5]
            let audioSHA = try GigaAMModelDescriptor.sha256(of: URL(fileURLWithPath: args[2]))
            let track = self.stableUUID(audioSHA)
            let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
            let config = Nemotron3Config.preset(named: "fast32-split-w8a8")!
            let assetPaths = [config.modelFileName + "/weights/weight.bin", config.modelFileName + "/model.mil", config.modelFileName + "/coremldata.bin", config.modelFileName + "/analytics/coremldata.bin", "learnable_sil_emb.bin", "pre_encode_proj_t.bin"]
            var assetSHA: [String: String] = [:]
            for path in assetPaths { assetSHA[path] = try GigaAMModelDescriptor.sha256(of: bundle.appendingPathComponent(path)) }
            let expected: [String: String] = [
                config.modelFileName + "/coremldata.bin": "b349771fbdb19443fb0af32b6c061fdb183d58e54c0b6376c2fbdca0a9941b70",
                config.modelFileName + "/analytics/coremldata.bin": "3241bd5be194abbf0f625be8bd639b5c2035359594a6a513d70e9159e294ce39",
                config.modelFileName + "/weights/weight.bin": "99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed",
                config.modelFileName + "/model.mil": "560f87a4a5124712d51ac7aecfee9a97278cac9087919719b031917a0160b508",
                "learnable_sil_emb.bin": "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7",
                "pre_encode_proj_t.bin": "eb15b89e7af9813331a7d8db02e83e30bf97463d272c748e72086bafd4e81c60"]
            guard assetSHA == expected else { fatalError("Pinned fast32 artifact differs") }
            let descriptor = GigaAMModelCatalog.downloadableModel
            let runtime = try GigaAMRuntime()
            var began = ProcessInfo.processInfo.systemUptime
            try await runtime.load(descriptor: descriptor, directory: gigaDirectory, executionProvider: .cpu)
            let asrLoad = ProcessInfo.processInfo.systemUptime - began
            began = ProcessInfo.processInfo.systemUptime
            var words: [GigaAMWordTiming] = []
            // The stopped meeting backend uses 20-second cores with 2-second context and
            // midpoint ownership. The registered provider's actual native runtime supplies CTC
            // words; no temporal interpolation or replacement recognizer is used here.
            for start in stride(from: 0, to: source.totalSampleCount, by: 320_000) {
                try Task.checkCancellation()
                let end = min(source.totalSampleCount, start + 320_000)
                let lower = max(0, start - 32_000)
                let upper = min(source.totalSampleCount, end + 32_000)
                let transcript = try await runtime.transcribe(try await source.readSamples(in: lower..<upper))
                for word in transcript.words {
                    let midpoint = (word.start + word.end) * 8_000 + Double(lower)
                    guard midpoint >= Double(start), midpoint < Double(end) || end == source.totalSampleCount else { continue }
                    words.append(.init(text: word.text, start: word.start + Double(lower) / 16_000,
                                       end: word.end + Double(lower) / 16_000, confidence: word.confidence))
                }
            }
            let asrSeconds = ProcessInfo.processInfo.systemUptime - began
            await runtime.unload()
            let mlconfig = MLModelConfiguration()
            switch args[7] {
            case "cpuAndGPU": mlconfig.computeUnits = .cpuAndGPU
            case "cpuAndNeuralEngine": mlconfig.computeUnits = .cpuAndNeuralEngine
            case "cpuOnly": mlconfig.computeUnits = .cpuOnly
            case "preferred": mlconfig.computeUnits = MeetingFast32ComputePolicy.preferredUnits
            default: fatalError("Unknown explicit compute policy")
            }
            began = ProcessInfo.processInfo.systemUptime
            let graph = try MLModel(contentsOf: bundle.appendingPathComponent(config.modelFileName), configuration: mlconfig)
            let models = try Nemotron3Models(config: config, model: graph,
                silenceEmbedding: self.floats(bundle.appendingPathComponent("learnable_sil_emb.bin")),
                preEncodeProjection: self.floats(bundle.appendingPathComponent("pre_encode_proj_t.bin")))
            let diarizerLoad = ProcessInfo.processInfo.systemUptime - began
            let factory = Fast32NemotronDiarizerFactory(config: config, models: models)
            defer { factory.cleanup() }
            let diarizer = try await factory.makeDiarizer(epoch: epoch)
            began = ProcessInfo.processInfo.systemUptime
            let intervals = try await diarizer.diarize(source: source)
            let diarizerSeconds = ProcessInfo.processInfo.systemUptime - began
            let activity = intervals.map { MeetingBackendSpeakerActivity(token: .init(analysisEpochID: epoch, label: String($0.slotIndex)), start: $0.start, end: $0.end) }
            var baselineCoverageAssignments: [MeetingBackendSpeakerAssignment] = []
            var baselineAssignments: [MeetingBackendSpeakerAssignment] = []
            var units: [MeetingFinalTextUnit] = []
            var previous: (token: MeetingBackendSpeakerToken, end: Double)?
            for (index, word) in words.enumerated() {
                let raw = LegacyAttribution.assignment(start: word.start, end: word.end, activity: activity, allowDominance: true)
                let baseline = LegacyAttribution.handoffAssignment(raw, start: word.start, end: word.end, activity: activity, previousAssignedWord: previous)
                baselineCoverageAssignments.append(raw)
                baselineAssignments.append(baseline)
                if case let .assigned(token) = baseline { previous = (token, word.end) } else { previous = nil }
                units.append(.init(id: audioSHA + ":word:" + String(index), trackID: track, analysisEpochID: epoch, precision: .word,
                    text: word.text, analysisStart: word.start, analysisEnd: word.end, speaker: .unassigned, analysisSpanIDs: [audioSHA + ":span:0"], confidence: Double(word.confidence)))
            }
            let nativeAssignments = try MeetingSpeakerAttribution.acousticAssignments(units: units, activity: activity)
            // Re-observe every input artifact after native inference. A concurrent replacement
            // fails this attempt before publication rather than mixing two model/audio versions.
            guard try GigaAMModelDescriptor.sha256(of: URL(fileURLWithPath: args[2])) == audioSHA else {
                fatalError("Audio changed during native inference")
            }
            try descriptor.verify(in: gigaDirectory)
            for path in assetPaths {
                guard try GigaAMModelDescriptor.sha256(of: bundle.appendingPathComponent(path)) == assetSHA[path] else {
                    fatalError("Fast32 artifact changed during native inference")
                }
            }
            let buildManifestURL = URL(fileURLWithPath: args[0]).standardizedFileURL.deletingLastPathComponent().appendingPathComponent("build-manifest.json")
            let metadata = NativeClipEvidence.Metadata(processID: ProcessInfo.processInfo.processIdentifier,
                nativeBuildManifestSHA256: try GigaAMModelDescriptor.sha256(of: buildManifestURL),
                requestedComputeUnits: args[7], preferredComputeUnits: self.computeName(MeetingFast32ComputePolicy.preferredUnits),
                asrArtifactFingerprint: descriptor.fingerprint, fast32ConfigJSON: String(decoding: try JSONEncoder().encode(config), as: UTF8.self), fast32AssetSHA256: assetSHA,
                asrLoadSeconds: asrLoad, asrInferenceSeconds: asrSeconds, diarizerLoadSeconds: diarizerLoad,
                diarizerInferenceSeconds: diarizerSeconds, peakProcessRSSBytes: self.peakRSS(),
                processRSSCaveat: "Mac process peak resident set only; excludes CoreML service allocations and is not iPad memory.",
                asrWindowPolicy: "Stopped meeting 20s core / 2s context / native CTC midpoint ownership. CTC emission spans are approximate, not forced alignment.",
                identityVerification: "Anonymous epoch-local native slots only. No speaker enrollment or experimental identity reassignment.")
            let evidence = NativeClipEvidence(schemaVersion: 2, clipID: args[6], audioSHA256: audioSHA, sampleCount: source.totalSampleCount,
                sampleRate: 16_000, trackID: track, units: units, activity: activity, initialAcousticAssignments: units.map { nativeAssignments[$0.id]! }, nativeProjectionPolicy: .standard, baselineCoverageAssignments: baselineCoverageAssignments, baselineAssignments: baselineAssignments, metadata: metadata)
            try self.write(evidence, to: outputPath)
            print("PASS native audioSeconds=\(Double(source.totalSampleCount) / 16_000) words=\(units.count) activityIntervals=\(activity.count)")
        } else if args[1] == "replay" {
            guard (4...5).contains(args.count) else { fatalError("replay expects evidence, output and optional policy") }
            let inputURL = URL(fileURLWithPath: args[2])
            let evidence = try JSONDecoder().decode(NativeClipEvidence.self, from: Data(contentsOf: inputURL))
            guard evidence.schemaVersion == 2 else { fatalError("Unsupported evidence schema") }
            let policy = try args.count == 5 ? JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self, from: Data(contentsOf: URL(fileURLWithPath: args[4]))) : .standard
            let began = ProcessInfo.processInfo.systemUptime
            // Native source units remain unchanged and unassigned. Acoustic projection is
            // part of the frozen policy and must be rerun too when comparing policy versions.
            let projection = try MeetingSpeakerAttribution.acousticAssignments(units: evidence.units, activity: evidence.activity, policy: policy)
            let projectedUnits = evidence.units.map { unit in
                MeetingFinalTextUnit(id: unit.id, trackID: unit.trackID, analysisEpochID: unit.analysisEpochID,
                    precision: unit.precision, text: unit.text, analysisStart: unit.analysisStart,
                    analysisEnd: unit.analysisEnd, speaker: projection[unit.id]!,
                    analysisSpanIDs: unit.analysisSpanIDs, confidence: unit.confidence)
            }
            let resolved = try MeetingSpeakerAttribution.resolveWithDiagnostics(units: projectedUnits, activity: evidence.activity, policy: policy)
            let repeatedProjection = try MeetingSpeakerAttribution.acousticAssignments(units: evidence.units, activity: evidence.activity, policy: policy)
            let repeated = try MeetingSpeakerAttribution.resolveWithDiagnostics(units: projectedUnits, activity: evidence.activity, policy: policy)
            let result = ReplayResult(schemaVersion: 1, evidenceSHA256: try GigaAMModelDescriptor.sha256(of: inputURL), clipID: evidence.clipID,
                policy: policy, policyFingerprint: policy.fingerprint, projectionAssignments: projection, resolution: resolved, replaySeconds: ProcessInfo.processInfo.systemUptime - began,
                deterministicRepeatEqual: projection == repeatedProjection && resolved == repeated, unchangedOriginalUnitCount: evidence.units.count)
            guard result.deterministicRepeatEqual else { fatalError("Nondeterministic core replay") }
            try self.write(result, to: args[3])
            print("PASS replay units=\(resolved.decisions.count) deterministic=true")
        } else { fatalError("Unknown mode") }
    }
}
