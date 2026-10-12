import Foundation
import XCTest
@testable import NativeTextInference

final class NativeTextInferenceTests: XCTestCase {
    func testUTF8FragmentsPreserveRussianEmojiAndASCII() throws {
        let expected = "Hello, Ёжик ёлка 🦔!"
        for chunkSize in 1...7 {
            var decoder = IncrementalUTF8Decoder()
            let bytes = Array(expected.utf8)
            var actual = ""
            for start in stride(from: 0, to: bytes.count, by: chunkSize) {
                actual += try decoder.append(Array(bytes[start..<min(bytes.count, start + chunkSize)]))
            }
            try decoder.finish()
            XCTAssertEqual(actual, expected)
        }
    }

    func testUTF8RejectsInvalidScalarsAndIncompleteFinalPiece() throws {
        for bytes: [UInt8] in [[0x80], [0xC0, 0xAF], [0xE0, 0x80, 0x80], [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xC2, 0x41]] {
            var decoder = IncrementalUTF8Decoder()
            XCTAssertThrowsError(try decoder.append(bytes)) { error in
                XCTAssertEqual(error as? NativeTextInferenceError, .invalidUTF8)
            }
        }
        var decoder = IncrementalUTF8Decoder()
        XCTAssertEqual(try decoder.append([0xF0, 0x9F]), "")
        XCTAssertThrowsError(try decoder.finish())
    }

    func testRejectsUnloadedGenerationAndInvalidLoadBeforeNativeAllocation() async throws {
        let runtime = NativeTextInference()
        do {
            _ = try await runtime.generate(prompt: "Hello", maxOutputTokens: 32)
            XCTFail("Generation must require a model")
        } catch {
            XCTAssertEqual(error as? NativeTextInferenceError, .modelNotLoaded)
        }
        for context in [0, 255, 32769, Int.max] {
            do {
                try await runtime.load(modelURL: URL(fileURLWithPath: "/missing.gguf"), contextTokenLimit: context)
                XCTFail("Context must be bounded")
            } catch {
                XCTAssertEqual(error as? NativeTextInferenceError, .invalidContextLimit)
            }
        }
        do {
            try await runtime.load(modelURL: URL(string: "https://example.com/model.gguf")!, contextTokenLimit: 256)
            XCTFail("Remote runtime loading must be rejected")
        } catch {
            XCTAssertEqual(error as? NativeTextInferenceError, .invalidModelURL)
        }
        await runtime.unload()
        let isLoaded = await runtime.isLoaded
        XCTAssertFalse(isLoaded)
    }

    func testInvalidGGUFThrowsAndDoesNotRetainSession() async throws {
        let runtime = NativeTextInference()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("synthetic-invalid.gguf")
        try Data("synthetic invalid GGUF".utf8).write(to: path)
        do {
            try await runtime.load(modelURL: path, contextTokenLimit: 256)
            XCTFail("Invalid weights must not load")
        } catch {
            XCTAssertEqual(error as? NativeTextInferenceError, .modelLoadFailed)
        }
        let isLoaded = await runtime.isLoaded
        XCTAssertFalse(isLoaded)
    }

    func testAlreadyCancelledTaskNeverLoadsWeights() async throws {
        let runtime = NativeTextInference()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            try await runtime.load(modelURL: URL(fileURLWithPath: "/missing.gguf"), contextTokenLimit: 256)
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("A cancelled task must fail before loading")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let isLoaded = await runtime.isLoaded
        XCTAssertFalse(isLoaded)
    }

    /// No downloads or private fixture paths are committed. Use an approved local GGUF.
    func testOptInRealInferenceCompletesAndRejectsTruncation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["PICHI_NATIVE_TEXT_TEST_MODEL"],
              let prompt = environment["PICHI_NATIVE_TEXT_TEST_PROMPT"], !prompt.isEmpty else {
            throw XCTSkip("Set PICHI_NATIVE_TEXT_TEST_MODEL and PICHI_NATIVE_TEXT_TEST_PROMPT for real inference")
        }
        let runtime = NativeTextInference()
        try await runtime.load(modelURL: URL(fileURLWithPath: path), contextTokenLimit: 8192)
        do {
            let stream = StreamCapture()
            let output = try await runtime.generate(prompt: prompt, maxOutputTokens: 512, streamHandler: { stream.append($0) })
            XCTAssertEqual(stream.text, output)
            XCTAssertFalse(output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let expected = environment["PICHI_NATIVE_TEXT_TEST_EXPECTED"] { XCTAssertEqual(output, expected) }
            do {
                _ = try await runtime.generate(prompt: prompt, maxOutputTokens: 1)
                XCTFail("A multi-token fixture must reject truncation")
            } catch {
                XCTAssertEqual(error as? NativeTextInferenceError, .outputLimitExceeded)
            }
            let cancellation = CancellationTrigger()
            let cancelled = Task {
                while !cancellation.isInstalled { await Task.yield() }
                return try await runtime.generate(prompt: prompt, maxOutputTokens: 512, streamHandler: { _ in cancellation.cancel() })
            }
            cancellation.install { cancelled.cancel() }
            do {
                _ = try await cancelled.value
                XCTFail("Cancellation during successful inference must reject partial output")
            } catch { XCTAssertTrue(error is CancellationError) }
            // Failed and cancelled generation must clear state rather than contaminate a retry.
            let retry = try await runtime.generate(prompt: prompt, maxOutputTokens: 512)
            XCTAssertEqual(retry, output)
            do {
                _ = try await runtime.generate(prompt: String(repeating: "hello ", count: 9000), maxOutputTokens: 512)
                XCTFail("Oversized prompt must be rejected before decode")
            } catch {
                guard case .contextLimitExceeded = error as? NativeTextInferenceError else {
                    XCTFail("Expected context overflow, got \(error)")
                    await runtime.unload()
                    return
                }
            }
            await runtime.unload()
        } catch {
            await runtime.unload()
            throw error
        }
        let isLoaded = await runtime.isLoaded
        XCTAssertFalse(isLoaded)
    }
}

private final class StreamCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var fragments = ""
    func append(_ text: String) { self.lock.withLock { self.fragments += text } }
    var text: String { self.lock.withLock { self.fragments } }
}

private final class CancellationTrigger: @unchecked Sendable {
    private let lock = NSLock()
    private var action: (@Sendable () -> Void)?
    var isInstalled: Bool { self.lock.withLock { self.action != nil } }
    func install(_ action: @escaping @Sendable () -> Void) { self.lock.withLock { self.action = action } }
    func cancel() { self.lock.withLock { self.action }?() }
}
