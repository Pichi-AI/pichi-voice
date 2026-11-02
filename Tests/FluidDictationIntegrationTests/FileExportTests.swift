@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class FileExportTests: XCTestCase {
    private func requireOwnedTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let configured = ProcessInfo.processInfo.environment["FLUID_EXPORT_TEST_SANDBOX_TEMP"]
        guard let configured,
              directory.path == URL(fileURLWithPath: configured).resolvingSymlinksInPath().standardizedFileURL.path
        else {
            throw XCTSkip("Use a disposable test account or runner and set FLUID_EXPORT_TEST_SANDBOX_TEMP to its Foundation temporary directory")
        }
        return directory
    }

    private func fixture(_ index: Int = 0, confidence: Float = 0.95) -> TranscriptionResult {
        TranscriptionResult(
            text: "Synthetic transcript \(index): Привет, Ёж!",
            confidence: confidence,
            duration: 12.5,
            processingTime: 0.75,
            fileName: "fixture-\(index).wav",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            speakerSegments: [SpeakerTranscriptSegment(
                speaker: "Speaker 1", startSeconds: 0, endSeconds: 2, text: "Synthetic speech"
            )],
            speakerLabelingNotice: "Synthetic notice",
            speakerLabelingGaps: [SpeakerTranscriptGap(startSeconds: 2, endSeconds: 2.5)]
        )
    }

    private func document(
        _ result: TranscriptionResult,
        format: FileTranscriptionView.ExportFormat
    ) throws -> TranscriptionDocument {
        try TranscriptionDocument(entry: FileTranscriptionEntry(from: result), format: format)
    }

    func testExportLeavesExistingTemporaryFilesUntouched() throws {
        let directory = try self.requireOwnedTemporaryDirectory()
        let urls = ["temp.txt", "temp.json"].map { directory.appendingPathComponent($0) }
        guard urls.allSatisfy({ !FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Refusing to replace pre-existing temporary files")
        }
        let sentinel = Data("Owned export test sentinel".utf8)
        for url in urls {
            try sentinel.write(to: url, options: .withoutOverwriting)
        }
        defer { for url in urls {
            try? FileManager.default.removeItem(at: url)
        } }

        for format in FileTranscriptionView.ExportFormat.allCases {
            _ = try self.document(self.fixture(), format: format).fileWrapper()
            for url in urls {
                XCTAssertEqual(try? Data(contentsOf: url), sentinel, "Export changed \(url.lastPathComponent)")
            }
        }
    }

    func testConcurrentDocumentsKeepTheirOwnPayloads() throws {
        let directory = try self.requireOwnedTemporaryDirectory()
        guard ["temp.txt", "temp.json"].allSatisfy({
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }) else {
            throw XCTSkip("Refusing to replace pre-existing temporary files")
        }
        let documents = try (0..<128).map { index in
            try self.document(self.fixture(index), format: index.isMultiple(of: 2) ? .text : .json)
        }
        let expected = try (0..<128).map { index in
            let result = self.fixture(index)
            return try index.isMultiple(of: 2) ? result.textExportData : result.jsonExportData()
        }
        let outcomes = ExportOutcomes()

        DispatchQueue.concurrentPerform(iterations: documents.count) { index in
            do {
                let bytes = try documents[index].fileWrapper().regularFileContents
                if bytes != expected[index] {
                    outcomes.record("Wrong payload for document \(index)")
                }
            } catch {
                outcomes.record("Document \(index) failed: \(error)")
            }
        }

        XCTAssertEqual(outcomes.failures, [])
        for name in ["temp.txt", "temp.json"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
        }
    }

    func testTextPreservesExistingMetadataAndUTF8() throws {
        let result = self.fixture()
        let wrapper = try self.document(result, format: .text).fileWrapper()
        XCTAssertTrue(wrapper.isRegularFile)
        XCTAssertEqual(wrapper.regularFileContents, result.textExportData)
        XCTAssertNil(wrapper.preferredFilename)
    }

    func testJSONPreservesExistingSchemaAndFormatting() throws {
        let result = self.fixture()
        let wrapper = try self.document(result, format: .json).fileWrapper()
        let bytes = try XCTUnwrap(wrapper.regularFileContents)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        XCTAssertEqual(bytes, try encoder.encode(result))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(json.keys), [
            "text", "confidence", "duration", "processingTime", "fileName", "timestamp",
            "speakerSegments", "speakerLabelingNotice", "speakerLabelingGaps",
        ])
        XCTAssertEqual(json["fileName"] as? String, "fixture-0.wav")
        XCTAssertEqual(json["timestamp"] as? String, "2023-11-14T22:13:20Z")
        XCTAssertNil(json["id"])
    }

    func testDocumentRetainsCapturedEntryTitlePayloadAndFormat() throws {
        var selectedEntry = FileTranscriptionEntry(from: self.fixture())
        selectedEntry.customTitle = "Обзор Ёж 42"
        var selectedFormat = FileTranscriptionView.ExportFormat.text
        let expected = self.fixture().textExportData
        let document = try TranscriptionDocument(entry: selectedEntry, format: selectedFormat)
        selectedEntry = FileTranscriptionEntry(from: self.fixture(1))
        selectedEntry.customTitle = "Changed after export began"
        selectedFormat = .json

        _ = try TranscriptionDocument(entry: selectedEntry, format: selectedFormat).fileWrapper()
        XCTAssertEqual(document.format, .text)
        XCTAssertEqual(document.defaultFilename, "Обзор Ёж 42_transcript.txt")
        XCTAssertEqual(try document.fileWrapper().regularFileContents, expected)
        var callerBytes = try XCTUnwrap(document.fileWrapper().regularFileContents)
        callerBytes[0] = 0
        XCTAssertEqual(try document.fileWrapper().regularFileContents, expected)
    }

    func testJSONEncodingFailureReachesSnapshotConstruction() throws {
        // Snapshot construction owns serialization, so an invalid payload must never
        // become a document retained by the operating system's export sheet.
        for _ in 0..<2 {
            XCTAssertThrowsError(try self.document(self.fixture(confidence: .nan), format: .json)) { error in
                guard case EncodingError.invalidValue = error else {
                    return XCTFail("Expected JSON encoding failure, got \(error)")
                }
            }
        }
    }
}

private final class ExportOutcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    nonisolated func record(_ failure: String) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.storage.append(failure)
    }

    nonisolated var failures: [String] {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.storage
    }
}
