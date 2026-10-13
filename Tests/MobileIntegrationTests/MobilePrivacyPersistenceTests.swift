import Foundation
@testable import PichiVoiceMobile
import XCTest

private struct FixturePersonRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let source = text as NSString
        let range = source.range(of: "Иван Тестов")
        guard range.location != NSNotFound else { return .init(text: text, spans: []) }
        return .init(text: source.replacingCharacters(in: range, with: "[PERSON]"),
                     spans: [.init(range: range, replacement: "[PERSON]")])
    }
}

/// Exercises the actual iOS store, shared publication policy and native export payloads.
/// Synthetic text isolates data handling from probabilistic model accuracy.
@MainActor
final class MobilePrivacyPersistenceTests: XCTestCase {
    func testStrictTranscriptPersistsAndExportsWithoutAudioOrOriginalPII() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let source = fixture()
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: source, using: FixturePersonRedactor())
        try await store.create(safe)
        let stored = try await store.load(id: safe.id)
        let loaded = try XCTUnwrap(stored)
        XCTAssertEqual(loaded.audioStorageMode, .memoryOnly)
        XCTAssertEqual(loaded.transcriptSegments.first?.text, "Врач [PERSON] просит инструкцию. Метформин 500 мг.")
        XCTAssertNil(loaded.transcriptSegments.first?.originalText)
        XCTAssertEqual(loaded.transcriptSegments.first?.start, source.transcriptSegments.first?.start)
        XCTAssertEqual(loaded.transcriptSegments.first?.end, source.transcriptSegments.first?.end)
        XCTAssertFalse(loaded.hasFinalizedAudio)

        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            XCTAssertEqual(url.pathExtension, "json", url.lastPathComponent)
            XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Иван Тестов"))
        }

        for (data, ext) in [(Data(MeetingTranscriptExporter.text(for: loaded).utf8), "txt"),
                            (try MeetingTranscriptExporter.json(for: loaded), "json")] {
            let payload = try MeetingSharePayload.transcript(data: data, title: loaded.title, fileExtension: ext)
            defer { payload.cleanup() }
            let url = try XCTUnwrap(payload.items.first as? URL)
            XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Иван Тестов"))
            XCTAssertFalse(payload.includesAudio)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        }
        let sessionDirectory = try await store.sessionDirectory(for: loaded.id)
        do {
            _ = try await MeetingSharePayload.audio(session: loaded, directory: sessionDirectory)
            XCTFail("A strict transcript has no exportable audio")
        } catch {
            XCTAssertEqual((error as NSError).code, CocoaError.fileNoSuchFile.rawValue)
        }
    }

    func testLegacyExportCopyDoesNotRewriteStoredOriginal() async throws {
        let source = fixture()
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: source, using: FixturePersonRedactor())
        XCTAssertTrue(source.title.contains("Иван Тестов"))
        XCTAssertTrue(source.transcriptSegments[0].text.contains("Иван Тестов"))
        XCTAssertNotNil(source.transcriptSegments[0].originalText)
        XCTAssertFalse(safe.title.contains("Иван Тестов"))
        XCTAssertNil(safe.transcriptSegments[0].originalText)
        XCTAssertFalse(String(decoding: try MeetingTranscriptExporter.json(for: safe), as: UTF8.self).contains("Иван Тестов"))
    }

    private func fixture() -> MeetingSession {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "synthetic", displayName: "Иван Тестов")
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Встреча: Иван Тестов", microphone: microphone,
            audioStorageMode: .memoryOnly, speakerLabelsEnabled: false, piiRedactionEnabled: true)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Иван Тестов", format: nil, timebase: timebase, health: .waiting, chunks: [])
        session.audioTracks = [track]
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(3)
        session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
            end: .init(value: 3, timescale: 1), sourceTrackID: track.id, speakerID: nil,
            text: "Врач Иван Тестов просит инструкцию. Метформин 500 мг.", originalText: "Иван Тестов",
            revision: 1, status: .final, overlap: .none, completeness: .complete)]
        return session
    }
}
