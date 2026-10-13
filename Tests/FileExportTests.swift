import Foundation
import SwiftUI
import UniformTypeIdentifiers

// Standalone persistence dependencies never access the installed application's data.
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
    func set(_ value: Any?, forKey key: String) { self.values[key] = value }
}

@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    func debug(_: String, source _: String) {}
    func info(_: String, source _: String) {}
    func error(_: String, source _: String) {}
}

// Redirect only scratch lookup/deletion into our owned fixture directory and
// require zero interactions. Serialization, FileWrapper, destination writes and
// the SwiftUI FileDocument protocol remain the actual native implementations.
enum FileManager {
    static let `default` = ExportScratchProbe()
}

final class ExportScratchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var requestCount: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.requests }
    private func record() { self.lock.lock(); self.requests += 1; self.lock.unlock() }
    var temporaryDirectory: URL {
        self.record()
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("Temporary", isDirectory: true)
    }
    func removeItem(at url: URL) throws {
        self.record()
        let owned = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).appendingPathComponent("Temporary", isDirectory: true)
        precondition(url.deletingLastPathComponent().resolvingSymlinksInPath().path == owned.resolvingSymlinksInPath().path)
        try Foundation.FileManager.default.removeItem(at: url)
    }
}

@main
struct FileExportTests {
    static func result(text: String = "Привет, мир.\nDo not change 42.") -> TranscriptionResult {
        TranscriptionResult(text: text, confidence: 0.5, duration: 8.5, processingTime: 1.25,
            fileName: "source.wav", timestamp: Date(timeIntervalSince1970: 0),
            speakerSegments: [.init(speaker: "Speaker 1", startSeconds: 0, endSeconds: 4, text: "Hello")],
            speakerLabelingNotice: "Short gap.", speakerLabelingGaps: [.init(startSeconds: 5, endSeconds: 5.5)])
    }

    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let temporary = directory.appendingPathComponent("Temporary", isDirectory: true)
        let sentinels = ["temp.txt", "temp.json"]
        for name in sentinels { try Data("Unowned by export: \(name)".utf8).write(to: temporary.appendingPathComponent(name)) }
        let original = self.result()
        let sourceURL = directory.appendingPathComponent("source.wav")
        let sourceData = Data("Synthetic source audio fixture".utf8)
        try sourceData.write(to: sourceURL)
        let expectedText = """
        Transcription: source.wav
        Date: \(original.timestamp.formatted())
        Duration: 8.5s
        Processing Time: 1.2s
        Confidence: 50.0%
        Speaker labeling: Short gap.
        Unlabeled audio ranges: 0:05.0-0:05.5

        ---

        Привет, мир.
        Do not change 42.
        """
        precondition(original.textExportData == Data(expectedText.utf8), "Text export bytes must preserve metadata, order and Unicode transcript")
        let expectedJSON = #"""
        {
          "confidence" : 0.5,
          "duration" : 8.5,
          "fileName" : "source.wav",
          "processingTime" : 1.25,
          "speakerLabelingGaps" : [
            {
              "endSeconds" : 5.5,
              "startSeconds" : 5
            }
          ],
          "speakerLabelingNotice" : "Short gap.",
          "speakerSegments" : [
            {
              "endSeconds" : 4,
              "speaker" : "Speaker 1",
              "startSeconds" : 0,
              "text" : "Hello"
            }
          ],
          "text" : "Привет, мир.\nDo not change 42.",
          "timestamp" : "1970-01-01T00:00:00Z"
        }
        """#
        let json = try original.jsonExportData()
        precondition(json == Data(expectedJSON.utf8), "JSON must retain exact sorted schema, ISO date and Unicode")
        var entry = FileTranscriptionEntry(from: original)
        entry.customTitle = "Обзор 42"
        let textDocument = try TranscriptionDocument(entry: entry, format: .text)
        let jsonDocument = try TranscriptionDocument(entry: entry, format: .json)
        entry = FileTranscriptionEntry(from: self.result(text: "Changed after export began"))
        entry.customTitle = "Changed after export began"
        precondition(textDocument.defaultFilename == "Обзор 42_transcript.txt")
        precondition(jsonDocument.defaultFilename == "Обзор 42_transcript.json")
        precondition(textDocument.fileWrapper().regularFileContents == Data(expectedText.utf8))
        precondition(jsonDocument.fileWrapper().regularFileContents == json)
        var detachedContents = textDocument.fileWrapper().regularFileContents!
        detachedContents[0] = 0
        precondition(textDocument.fileWrapper().regularFileContents == Data(expectedText.utf8), "A caller's byte mutation cannot alter the immutable snapshot")
        precondition(TranscriptionDocument.writableContentTypes.contains(.plainText) && TranscriptionDocument.writableContentTypes.contains(.json))

        let service = FileTranscriptionService()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<128 {
                group.addTask {
                    let item = self.result(text: "Concurrent transcript \(index): ёж, 42, no.")
                    let entry = FileTranscriptionEntry(from: item)
                    let format: FileTranscriptionView.ExportFormat = index.isMultiple(of: 2) ? .text : .json
                    let document = try TranscriptionDocument(entry: entry, format: format)
                    let expected = format == .text ? item.textExportData : try item.jsonExportData()
                    let wrapper = document.fileWrapper()
                    precondition(wrapper.isRegularFile && wrapper.regularFileContents == expected, "Parallel snapshots must never cross-contaminate")
                    let destination = directory.appendingPathComponent("parallel-\(index).\(format.fileExtension)")
                    if format == .text { try service.exportToText(item, to: destination) }
                    else { try service.exportToJSON(item, to: destination) }
                    let written = try Data(contentsOf: destination)
                    precondition(written == expected, "Service and FileDocument must share exactly the same serialization")
                }
            }
            try await group.waitForAll()
        }
        for name in sentinels {
            let untouched = try Data(contentsOf: temporary.appendingPathComponent(name))
            precondition(untouched == Data("Unowned by export: \(name)".utf8))
        }
        let temporaryNames = try Foundation.FileManager.default.contentsOfDirectory(atPath: temporary.path).sorted()
        precondition(temporaryNames == sentinels.sorted(), "Snapshot export must leave all scratch files untouched")
        precondition(FileManager.default.requestCount == 0, "FileDocument must not claim any shared scratch location")
        let unchangedSource = try Data(contentsOf: sourceURL)
        precondition(unchangedSource == sourceData, "Export must never mutate source audio")
        let protectedDestination = directory.appendingPathComponent("encoding-failure.json")
        let protectedBytes = Data("Existing destination".utf8)
        try protectedBytes.write(to: protectedDestination)
        let invalid = TranscriptionResult(text: "Synthetic", confidence: .nan, duration: 1, processingTime: 1, fileName: "synthetic.wav")
        do {
            try service.exportToJSON(invalid, to: protectedDestination)
            preconditionFailure("Invalid JSON values must propagate serialization failure")
        } catch EncodingError.invalidValue { }
        let intactDestination = try Data(contentsOf: protectedDestination)
        precondition(intactDestination == protectedBytes)
        do {
            _ = try TranscriptionDocument(entry: FileTranscriptionEntry(from: invalid), format: .json)
            preconditionFailure("Invalid JSON must not produce a partial document snapshot")
        } catch EncodingError.invalidValue { }
        print("File export: exact text/JSON fixtures, immutable title/content, 128 parallel document/service exports, source and scratch ownership, encoding failure passed")
    }
}
