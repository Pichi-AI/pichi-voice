import AVFoundation
import Foundation
import XCTest
@testable import PichiGigaAM

final class GigaAMTests: XCTestCase {
    func testSilenceFrontendShapeAndFloor() throws {
        let frontend = try GigaAMFrontend()
        let output = frontend.features([Float](repeating: 0, count: 16_000))
        XCTAssertEqual(output.frameCount, 99)
        XCTAssertEqual(output.values.count, 64 * 99)
        for value in output.values { XCTAssertEqual(value, Float(log(1e-9)), accuracy: 0.00001) }
        XCTAssertEqual(frontend.features([0]).frameCount, 1)
    }

    func testFrontendMatchesReferenceDFTOnSyntheticPCM() throws {
        let samples: [Float] = (0..<480).map { index in
            let noise = Float((index * 7919) % 32767) / 32767 - 0.5
            return noise * 0.15 + Float(sin(Double(index) * 0.173)) * 0.2
        }
        let frontend = try GigaAMFrontend()
        let result = frontend.features(samples)
        XCTAssertEqual(result.frameCount, 2)
        let maxMel = 2595 * log10(1 + 8000.0 / 700)
        let points = (0..<66).map { 700 * (pow(10, maxMel * Double($0) / 65 / 2595) - 1) }
        for frame in 0..<2 {
            var powers = [Double](repeating: 0, count: 161)
            for bin in 0..<161 {
                var real = 0.0
                var imaginary = 0.0
                for index in 0..<320 {
                    let window = GigaAMFrontend.bf16(Float(0.5 - 0.5 * cos(2 * .pi * Double(index) / 320)))
                    let angle = 2 * .pi * Double(bin * index) / 320
                    let sample = Double(samples[frame * 160 + index])
                    real += Double(Float(cos(angle) * Double(window))) * sample
                    imaginary += Double(Float(-sin(angle) * Double(window))) * sample
                }
                powers[bin] = real * real + imaginary * imaginary
            }
            for mel in 0..<64 {
                var total = 0.0
                for bin in 0..<161 {
                    let frequency = Double(bin) * 50
                    let up = (frequency - points[mel]) / (points[mel + 1] - points[mel])
                    let down = (points[mel + 2] - frequency) / (points[mel + 2] - points[mel + 1])
                    total += powers[bin] * Double(GigaAMFrontend.bf16(Float(max(0, min(up, down)))))
                }
                XCTAssertEqual(Double(result.values[mel * 2 + frame]), log(min(max(total, 1e-9), 1e9)), accuracy: 0.00002)
            }
        }
    }

    func testCTCRepeatedLettersAndBlankTiming() throws {
        let vocabulary = GigaAMVocabulary(tokens: [" ", "а", "б", "<blk>"], blankID: 3, unknownID: nil, subword: false)
        let ids = [3, 1, 1, 3, 1, 0, 2, 2, 3]
        let logits = ids.flatMap { id in (0..<4).map { $0 == id ? Float(0) : -Float(100) } }
        let words = try GigaAMCTC.decode(logProbabilities: logits, frameCount: ids.count, vocabulary: vocabulary, audioDuration: 1)
        XCTAssertEqual(words.map(\.text), ["аа", "б"])
        XCTAssertEqual(words[0].start, 0.04, accuracy: 0.0001)
        XCTAssertEqual(words[0].end, 0.20, accuracy: 0.0001)
        XCTAssertEqual(words[1].start, 0.24, accuracy: 0.0001)
        XCTAssertEqual(words[1].end, 0.32, accuracy: 0.0001)
    }

    func testSubwordVocabularyPunctuationAndUnknown() throws {
        let vocabulary = try GigaAMVocabulary(contents: "<unk> 0\n▁ 1\n▁Привет 2\n. 3\n▁мир 4\n<blk> 5\n")
        let ids = [5, 2, 2, 5, 3, 0, 4, 5]
        let logits = ids.flatMap { id in (0..<6).map { $0 == id ? Float(0) : -Float(100) } }
        let words = try GigaAMCTC.decode(logProbabilities: logits, frameCount: ids.count, vocabulary: vocabulary, audioDuration: 1)
        XCTAssertEqual(words.map(\.text), ["Привет.", "мир"])
        XCTAssertThrowsError(try GigaAMVocabulary(contents: "<unk> 0\nmissing 2\n<blk> 3\n"))
        XCTAssertThrowsError(try GigaAMCTC.decode(logProbabilities: [], frameCount: 1, vocabulary: vocabulary, audioDuration: 1))
    }

    func testChecksumRejectsModifiedArtifact() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("model.onnx")
        try Data("model".utf8).write(to: file)
        let descriptor = GigaAMModelDescriptor(id: "test", modelFile: "model.onnx", modelSHA256: try GigaAMModelDescriptor.sha256(of: file), vocabularyFile: nil, vocabularySHA256: nil, endOfUtteranceThreshold: nil)
        XCTAssertTrue(descriptor.filesExist(in: directory))
        try descriptor.verify(in: directory)
        try Data("corrupted".utf8).write(to: file)
        XCTAssertThrowsError(try descriptor.verify(in: directory))
    }

    func testFrontendParityWithExistingPrototype() throws {
        guard let samplePath = ProcessInfo.processInfo.environment["PICHI_GIGAAM_TEST_WAV"],
              let parityPath = ProcessInfo.processInfo.environment["PICHI_GIGAAM_TEST_PARITY"] else {
            throw XCTSkip("Set local approved WAV and prototype parity JSON paths for parity verification.")
        }
        let samples = try Self.readWAV(URL(fileURLWithPath: samplePath))
        let output = try GigaAMFrontend().features(Array(samples.prefix(16_000)))
        let parity = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: parityPath))) as! [String: Any]
        XCTAssertEqual(output.frameCount, parity["features_lens"] as? Int)
        let expected = parity["frames"] as! [String: [Double]]
        var maximumError: Double = 0
        for (frame, values) in expected {
            for (mel, value) in values.enumerated() {
                let actual = Double(output.values[mel * output.frameCount + Int(frame)!])
                maximumError = max(maximumError, abs(actual - value))
                // Stored parity comes from the bf16 Torch frontend. The original
                // browser frontend has the same < 0.007 log-mel difference.
                XCTAssertEqual(actual, value, accuracy: 0.01)
            }
        }
        print("GigaAM frontend parity maximum absolute log-mel error: \(maximumError)")
    }

    func testRealOptimizedRussianModel() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["PICHI_GIGAAM_TEST_MODEL_DIR"],
              let wavPath = ProcessInfo.processInfo.environment["PICHI_GIGAAM_TEST_WAV"] else {
            throw XCTSkip("Set local optimized GigaAM and approved Russian WAV paths for real-model verification.")
        }
        let directory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let installed = try XCTUnwrap(GigaAMModelCatalog.discover(in: directory))
        let runtime = try GigaAMRuntime()
        let provider: GigaAMExecutionProvider = ProcessInfo.processInfo.environment["PICHI_GIGAAM_TEST_COREML"] == "1" ? .coreML : .cpu
        let loadStart = ProcessInfo.processInfo.systemUptime
        try await runtime.load(descriptor: installed.descriptor, directory: installed.directory, executionProvider: provider)
        print("GigaAM load seconds: \(ProcessInfo.processInfo.systemUptime - loadStart)")
        let samples = try Self.readWAV(URL(fileURLWithPath: wavPath))
        let small = try await runtime.transcribe(Array(samples.prefix(16_000)))
        XCTAssertTrue(small.text.lowercased().contains("привет"), small.text)
        print("GigaAM tiny Russian slice: \(small.text), seconds: \(small.processingDuration)")
        let result = try await runtime.transcribe(samples)
        XCTAssertTrue(result.text.lowercased().contains("русскую речь"), result.text)
        XCTAssertFalse(result.words.isEmpty)
        for word in result.words {
            XCTAssertGreaterThanOrEqual(word.start, 0)
            XCTAssertGreaterThanOrEqual(word.end, word.start)
            XCTAssertLessThanOrEqual(word.end, Double(samples.count) / 16_000)
        }
        print("GigaAM \(provider.rawValue) transcript: \(result.text)")
        print("GigaAM audio seconds: \(Double(samples.count) / 16_000), inference seconds: \(result.processingDuration), words: \(result.words.count)")
        let shortEOU = try await runtime.transcribe(Array(samples.prefix(4 * 16_000)))
        let eou = try XCTUnwrap(shortEOU.endOfUtteranceProbability)
        XCTAssertTrue((0...1).contains(eou))
        let silent = try await runtime.transcribe([Float](repeating: 0, count: 16_000))
        XCTAssertTrue(silent.text.isEmpty, silent.text)
        let empty = try await runtime.transcribe([])
        XCTAssertTrue(empty.words.isEmpty)
        do {
            _ = try await runtime.transcribe([.nan])
            XCTFail("Expected invalid audio error")
        } catch GigaAMError.invalidAudio {}
        if ProcessInfo.processInfo.environment["PICHI_GIGAAM_TEST_LONG"] == "1" {
            let gap = [Float](repeating: 0, count: 2 * 16_000)
            let longAudio = samples + gap + samples + gap + samples
            let longResult = try await runtime.transcribe(longAudio)
            XCTAssertEqual(longResult.words.filter { $0.text.lowercased().hasPrefix("привет") }.count, 3, longResult.text)
            XCTAssertTrue(zip(longResult.words, longResult.words.dropFirst()).allSatisfy { $0.start <= $1.start })
            print("GigaAM long audio seconds: \(Double(longAudio.count) / 16_000), inference seconds: \(longResult.processingDuration)")
        }
        await runtime.unload()
        let ready = await runtime.isReady
        XCTAssertFalse(ready)
        do {
            _ = try await runtime.transcribe([0])
            XCTFail("Expected not-prepared error after unloading")
        } catch GigaAMError.notPrepared {}
    }

    private static func readWAV(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    }
}
