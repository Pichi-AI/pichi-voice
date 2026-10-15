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
    func testNativeLivePIIRetagsCompletedRowsAcrossPartialUpdates() async throws {
        let assets = try MobileInferenceTestAssets.resolve()
        let models = assets.appendingPathComponent("models/privacy", isDirectory: true)
        guard FileManager.default.fileExists(atPath: models.appendingPathComponent(PichiTranscriptPrivacyModelStore.descriptor.id).appendingPathComponent("model_int8.onnx").path) else { throw XCTSkip("Stage public privacy model under models/privacy/rubert-tiny-news-int8") }
        let privacy = PichiTranscriptPrivacyService(modelStore: .init(directory: models))
        try await privacy.prepare()
        let cases: [(String, [String], [String], String)] = [
            ("документ передали сидорову", ["ивану", "ивану петровичу метформин 500 мг"], ["сидорову", "ивану", "петровичу"], "метформин 500 мг"),
            ("телефон 273", ["55", "55 11 метотрексат 15 мг"], ["273", "55 11"], "метотрексат 15 мг"),
            ("дата рождения 12", ["мая", "мая 1980 инсулин 10 единиц"], ["12", "мая 1980"], "инсулин 10 единиц"),
            ("домашний адрес улица Примерная", ["дом", "дом 12 квартира 7 лизиноприл 10 мг"], ["Примерная", "квартира 7"], "лизиноприл 10 мг"),
            ("карта 4111", ["1111", "1111 1111", "1111 1111 1111 508 рублей оземпик"], ["4111", "1111"], "508 рублей оземпик"),
        ]
        for (initial, partials, privateWords, medication) in cases {
            let utterance = MeetingLiveUtterance(id: UUID(), speaker: .you, text: initial, start: 0, end: 1)
            let partialID = UUID()
            var raw = MeetingLiveTranscriptSnapshot.empty
            raw.utterances = [utterance]; raw.availability = .available; raw.revision = 1
            let completed = partials.last! + ". Подготовим материалы к следующей встрече и проверим условия хранения."
            let observations = partials + [completed, completed]
            for (index, text) in observations.enumerated() {
                raw = raw.settingPartial(.init(id: partialID, text: text, start: 1), for: .you)
                raw.revision += 1
                let safe = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: privacy)
                for row in safe.utterances {
                    XCTAssertEqual(row.id, utterance.id)
                    XCTAssertEqual(row.start, 0); XCTAssertEqual(row.end, 1)
                }
                if let partial = safe.partials[.you] {
                    XCTAssertEqual(partial.id, partialID); XCTAssertEqual(partial.start, 1)
                }
                XCTAssertEqual(raw.utterances[0].text, initial)
                let joined = safe.utterances.map(\.text).joined(separator: " ") + " " + (safe.partials[.you]?.text ?? "")
                for value in privateWords { XCTAssertFalse(joined.contains(value), "Every admitted observation must be protected") }
                if index == observations.count - 1 { XCTAssertTrue(joined.contains(medication), "Case: \(initial); safe: \(joined)") }
            }
            raw = raw.settingPartial(nil, for: .you).inserting(.init(id: partialID, speaker: .you, text: completed, start: 1, end: 4))
            raw.revision += 1
            let final = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: privacy)
            XCTAssertTrue(final.utterances.allSatisfy { [utterance.id, partialID].contains($0.id) })
            if let admitted = final.utterances.first(where: { $0.id == partialID }) {
                XCTAssertEqual(admitted.start, 1); XCTAssertEqual(admitted.end, 4)
            }
            XCTAssertTrue(final.partials.isEmpty)
            for value in privateWords { XCTAssertFalse(final.utterances.map(\.text).joined(separator: " ").contains(value)) }
        }
        try await privacy.unload()
    }

    func testNativePIIAcrossSegmentsAndStrictWindowsBeforePersistence() async throws {
        let assets = try MobileInferenceTestAssets.resolve()
        let models = assets.appendingPathComponent("models/privacy", isDirectory: true)
        let installed = models.appendingPathComponent(PichiTranscriptPrivacyModelStore.descriptor.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: installed.appendingPathComponent("model_int8.onnx").path) else {
            throw XCTSkip("Stage public privacy model under models/privacy/rubert-tiny-news-int8")
        }
        let privacy = PichiTranscriptPrivacyService(modelStore: .init(directory: models))
        try await privacy.prepare()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        var original = fixture()
        let track = try XCTUnwrap(original.audioTracks.first?.id)
        func segment(_ text: String, _ start: Int64) -> MeetingTranscriptSegment {
            .init(id: UUID(), start: .init(value: start, timescale: 1), end: .init(value: start + 1, timescale: 1),
                  sourceTrackID: track, speakerID: nil, text: text, originalText: text, revision: 1,
                  status: .final, overlap: .none, completeness: .complete)
        }
        let wordText = "карта 4111 1111 1111 1111 дата рождения 12 мая 1980 метформин 500 мг"
        let words = wordText.split(separator: " ").enumerated().map { segment(String($0.element), Int64($0.offset)) }
        let safeWords = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: words), using: privacy)
        let joinedWords = safeWords.segments.map(\.text).joined(separator: " ")
        XCTAssertFalse(joinedWords.contains("4111"))
        XCTAssertFalse(joinedWords.contains("1111"))
        XCTAssertFalse(joinedWords.contains("1980"))
        XCTAssertTrue(joinedWords.contains("метформин 500 мг"))
        XCTAssertEqual(safeWords.segments.map(\.id), words.map(\.id))
        XCTAssertEqual(safeWords.segments.map(\.start), words.map(\.start))
        let cardAndAmount = "карта 3782 822463 10005 1008 рублей метформин 500 мг"
        let amountWords = cardAndAmount.split(separator: " ").enumerated().map { segment(String($0.element), Int64($0.offset)) }
        let safeAmount = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: amountWords), using: privacy)
        XCTAssertEqual(safeAmount.segments.suffix(5).map(\.text), ["1008", "рублей", "метформин", "500", "мг"])
        for privatePart in ["3782", "822463", "10005"] {
            XCTAssertFalse(safeAmount.segments.map(\.text).joined(separator: " ").contains(privatePart))
        }
        let wordAddress = "домашний адрес улица Примерная дом 12 квартира 7 метотрексат 15 мг"
        let addressWords = wordAddress.split(separator: " ").enumerated().map { segment(String($0.element), Int64($0.offset)) }
        let safeAddress = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: addressWords), using: privacy)
        XCTAssertFalse(safeAddress.segments.map(\.text).joined(separator: " ").contains("Примерная"))
        XCTAssertEqual(safeAddress.segments.suffix(3).map(\.text), ["метотрексат", "15", "мг"])
        XCTAssertEqual(safeAddress.segments.map(\.id), addressWords.map(\.id))
        XCTAssertEqual(safeAddress.segments.map(\.start), addressWords.map(\.start))
        original.transcriptSegments = [segment("телефон", 0), segment("273 55 11", 1),
            segment("дата рождения", 2), segment("12 мая 1980", 3), segment("домашний адрес", 4),
            segment("улица Примерная дом 12", 5), segment("метформин 500 мг", 6)]
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: original, using: privacy)
        XCTAssertEqual(safe.transcriptSegments.map(\.id), original.transcriptSegments.map(\.id))
        XCTAssertEqual(safe.transcriptSegments.map(\.start), original.transcriptSegments.map(\.start))
        XCTAssertEqual(safe.transcriptSegments.last?.text, "метформин 500 мг")
        try await store.create(safe)
        let loadedValue = try await store.load(id: safe.id)
        let loaded = try XCTUnwrap(loadedValue)
        for value in ["273 55 11", "12 мая 1980", "улица Примерная дом 12", "Иван Тестов"] {
            XCTAssertFalse(String(decoding: try MeetingTranscriptExporter.json(for: loaded), as: UTF8.self).contains(value))
        }

        // A possible first-half phone remains in bounded RAM, and both halves
        // are filtered before any strict checkpoint/export can observe them.
        let context = MeetingTranscriptPrivacyContext(redactor: privacy)
        let first = try await context.redact(.init(segments: [segment("телефон 8 999", 0)]))
        XCTAssertTrue(first.segments.isEmpty)
        let second = try await context.redact(.init(segments: [segment("123 45 67", 8), segment("метотрексат 15 мг", 9)]))
        let tail = try await context.finish()
        var strict = safe
        strict.transcriptSegments = first.segments + second.segments + (tail?.segments ?? [])
        try await store.save(strict)
        let strictValue = try await store.load(id: strict.id)
        let saved = try XCTUnwrap(strictValue)
        XCTAssertEqual(saved.transcriptSegments.last?.text, "метотрексат 15 мг")
        let json = String(decoding: try MeetingTranscriptExporter.json(for: saved), as: UTF8.self)
        XCTAssertFalse(json.contains("8 999")); XCTAssertFalse(json.contains("123 45 67"))
        XCTAssertTrue(saved.transcriptSegments.allSatisfy { $0.originalText == nil })

        // A word-granularity PAN split between PCM windows must not leak its
        // first group through an earlier durable checkpoint or native export.
        for amount in ["500", "508"] {
            let cards = MeetingTranscriptPrivacyContext(redactor: privacy)
            let cardA = ["карта", "4111", "1111"].enumerated().map { segment($0.element, Int64($0.offset)) }
            let cardB = ["1111", "1111", amount, "мг", "метформин500мг"].enumerated().map { segment($0.element, 8 + Int64($0.offset)) }
            let checkpointA = try await cards.redact(.init(segments: cardA))
            let checkpointB = try await cards.redact(.init(segments: cardB))
            let checkpointC = try await cards.finish()
            strict.transcriptSegments = []
            for checkpoint in [checkpointA, checkpointB] + (checkpointC.map { [$0] } ?? []) {
                strict.transcriptSegments += checkpoint.segments
                try await store.save(strict)
                let value = try await store.load(id: strict.id)
                let persisted = try XCTUnwrap(value)
                for text in [MeetingTranscriptExporter.text(for: persisted), String(decoding: try MeetingTranscriptExporter.json(for: persisted), as: UTF8.self)] {
                    XCTAssertFalse(text.contains("4111")); XCTAssertFalse(text.contains("1111"))
                }
            }
            XCTAssertEqual(strict.transcriptSegments.map(\.id), (cardA + cardB).map(\.id))
            XCTAssertEqual(strict.transcriptSegments.map(\.start), (cardA + cardB).map(\.start))
            XCTAssertEqual(strict.transcriptSegments.suffix(3).map(\.text), [amount, "мг", "метформин500мг"])
            XCTAssertTrue(strict.transcriptSegments.allSatisfy { $0.originalText == nil })
        }

        let names = MeetingTranscriptPrivacyContext(redactor: privacy)
        let nameA = ["доктор", "анна"].enumerated().map { segment($0.element, Int64($0.offset)) }
        let nameB = ["сергеевна", "кузнецова", "метотрексат", "15", "мг"].enumerated().map { segment($0.element, 8 + Int64($0.offset)) }
        let namesA = try await names.redact(.init(segments: nameA))
        let namesB = try await names.redact(.init(segments: nameB))
        let namesC = try await names.finish()
        strict.transcriptSegments = []
        for checkpoint in [namesA, namesB] + (namesC.map { [$0] } ?? []) {
            strict.transcriptSegments += checkpoint.segments
            try await store.save(strict)
            let exported = String(decoding: try MeetingTranscriptExporter.json(for: strict), as: UTF8.self)
            for privateWord in ["анна", "сергеевна", "кузнецова"] { XCTAssertFalse(exported.contains(privateWord)) }
        }
        XCTAssertEqual(strict.transcriptSegments.map(\.id), (nameA + nameB).map(\.id))
        XCTAssertEqual(strict.transcriptSegments.map(\.start), (nameA + nameB).map(\.start))
        XCTAssertEqual(strict.transcriptSegments.suffix(3).map(\.text), ["метотрексат", "15", "мг"])
        try await privacy.unload()
    }

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
            #if targetEnvironment(simulator)
            if let actual = attributes[.protectionKey] as? String {
                XCTAssertEqual(actual, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
            }
            #else
            XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
            #endif
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
