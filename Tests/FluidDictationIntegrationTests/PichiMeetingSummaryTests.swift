@testable import FluidVoice_Debug
import Foundation
import XCTest

final class PichiMeetingSummaryTests: XCTestCase {
    private let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private var turns: [PichiMeetingSummaryTurn] {
        [.init(id: self.id, seconds: 0, speaker: "Иван", text: "Иван подготовит отчёт к пятнице. Решили оставить текущую цену.")]
    }

    private func document(quote: String = "Иван подготовит отчёт к пятнице.", owner: String? = "Иван",
                          deadline: String? = "к пятнице", evidenceID: UUID? = nil) -> PichiMeetingSummaryDocument {
        let evidence = PichiMeetingSummaryEvidence(segmentID: evidenceID ?? self.id, quote: quote)
        return .init(summary: [.init(text: "Обсудили отчёт.", evidence: [evidence])],
                     decisions: [], actions: [.init(text: "Подготовить отчёт.", evidence: [evidence], owner: owner, deadline: deadline)],
                     openQuestions: [])
    }

    func testAcceptsRussianEvidenceAndVerbatimAttribution() throws {
        let expected = self.document()
        let json = String(decoding: try JSONEncoder().encode(expected), as: UTF8.self)
        XCTAssertEqual(try PichiMeetingSummaryDocument.decode(json, turns: self.turns), expected)
        XCTAssertEqual(try PichiMeetingSummaryDocument.decode("```json\n\(json)\n```", turns: self.turns), expected)
    }

    func testRejectsInventedSourceQuoteOwnerAndDate() {
        XCTAssertThrowsError(try self.document(evidenceID: UUID()).validated(against: self.turns))
        XCTAssertThrowsError(try self.document(quote: "Цена выросла.").validated(against: self.turns))
        XCTAssertThrowsError(try self.document(owner: "Мария").validated(against: self.turns))
        XCTAssertThrowsError(try self.document(deadline: "12 октября").validated(against: self.turns))
        XCTAssertThrowsError(try PichiMeetingSummaryDocument.decode("Сделайте отчёт", turns: self.turns))
    }

    func testEmptyDecisionsAndTasksAreValidButEveryClaimNeedsEvidence() throws {
        var doc = self.document()
        doc.actions = []
        XCTAssertNoThrow(try doc.validated(against: self.turns))
        doc.summary = [.init(text: "Необоснованный вывод", evidence: [])]
        XCTAssertThrowsError(try doc.validated(against: self.turns))
    }

    func testLongTurnIsChunkedWithoutDroppingTextOrSourceIdentity() {
        let text = String(repeating: "Русская речь. ", count: 1600)
        let turns = [PichiMeetingSummaryTurn(id: self.id, seconds: 7, speaker: "Иван", text: text)]
        let chunks = PichiMeetingSummaryInput.chunks(turns, maximumCharacters: 1000)
        XCTAssertGreaterThan(chunks.count, 10)
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.text).joined(), text)
        XCTAssertTrue(chunks.flatMap { $0 }.allSatisfy { $0.id == self.id && $0.seconds == 7 })
        XCTAssertTrue(chunks.allSatisfy { $0.reduce(0) { $0 + $1.text.count + $1.speaker.count + 160 } <= 1000 })
    }

    func testFingerprintChangesForCorrectionsSpeakersLanguageAndGaps() {
        var session = self.session()
        let original = PichiMeetingSummaryInput.fingerprint(session)
        session.transcriptSegments[0].text = "Исправленная реплика"
        let corrected = PichiMeetingSummaryInput.fingerprint(session)
        XCTAssertNotEqual(original, corrected)
        session.speakers[0].displayName = "Мария"
        let renamed = PichiMeetingSummaryInput.fingerprint(session)
        XCTAssertNotEqual(corrected, renamed)
        session.languageCode = "en"
        let language = PichiMeetingSummaryInput.fingerprint(session)
        XCTAssertNotEqual(renamed, language)
        session.transcriptCoverageGaps = [.init(trackID: session.audioTracks[0].id, start: 2, end: 4, reason: .processingFailed)]
        XCTAssertNotEqual(language, PichiMeetingSummaryInput.fingerprint(session))
    }

    func testProvisionalAndEchoTurnsAreExcluded() {
        var session = self.session()
        XCTAssertEqual(PichiMeetingSummaryInput.turns(for: session).count, 1)
        session.transcriptSegments[0].status = .provisional
        XCTAssertTrue(PichiMeetingSummaryInput.turns(for: session).isEmpty)
        session.transcriptSegments[0].status = .final
        session.transcriptSegments[0].isLikelyEcho = true
        XCTAssertTrue(PichiMeetingSummaryInput.turns(for: session).isEmpty)
    }

    func testLoopbackAndRemoteEndpointPolicy() {
        for endpoint in ["http://localhost:11434/v1", "http://127.0.0.1:1234/v1", "http://[::1]:11434/v1"] {
            XCTAssertTrue(PichiMeetingSummaryConfiguration.isLoopback(endpoint))
        }
        for endpoint in ["https://localhost.example.com", "http://192.168.1.2:11434/v1", "http://127.0.0.1.evil.example/v1"] {
            XCTAssertFalse(PichiMeetingSummaryConfiguration.isLoopback(endpoint))
        }
        XCTAssertThrowsError(try self.configuration(endpoint: "http://api.example.com/v1").validate())
        XCTAssertNoThrow(try self.configuration(endpoint: "https://api.example.com/v1").validate())
        XCTAssertThrowsError(try self.configuration(endpoint: "https://user:password@api.example.com/v1").validate())
    }

    func testLocalTranscriptBodyCannotFollow307Or308Redirect() async throws {
        let source = try XCTUnwrap(URL(string: "http://127.0.0.1:11434/v1/chat/completions"))
        var redirected = URLRequest(url: try XCTUnwrap(URL(string: "https://external.example/v1/chat/completions")))
        redirected.httpMethod = "POST"
        redirected.httpBody = Data("Synthetic private transcript".utf8)
        let task = PichiMeetingSummaryTransport.session.dataTask(with: source)
        for status in [307, 308] {
            let response = try XCTUnwrap(HTTPURLResponse(url: source, statusCode: status, httpVersion: nil,
                                                        headerFields: ["Location": redirected.url!.absoluteString]))
            let admitted: URLRequest? = await withCheckedContinuation { continuation in
                PichiMeetingSummaryTransport.redirectPolicy.urlSession(PichiMeetingSummaryTransport.session, task: task,
                                                                       willPerformHTTPRedirection: response, newRequest: redirected) {
                    continuation.resume(returning: $0)
                }
            }
            XCTAssertNil(admitted)
        }
    }

    @MainActor
    func testRussianLocalDefaultsAndSavedSelectionArePreserved() throws {
        let suite = "PichiMeetingSummaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = PichiMeetingSummarySettings(defaults: defaults)
        XCTAssertEqual(fresh.language, "ru")
        XCTAssertEqual(fresh.mode, .local)
        XCTAssertEqual(fresh.modelID, "qwen3.5:4b")
        fresh.language = "en"
        fresh.modelID = "fixture-model"
        let restored = PichiMeetingSummarySettings(defaults: defaults)
        XCTAssertEqual(restored.language, "en")
        XCTAssertEqual(restored.modelID, "fixture-model")
        restored.baseURL = "https://external.example/v1"
        XCTAssertThrowsError(try restored.configuration(sessionLanguage: "ru"))
    }

    func testGeneratorUsesStructuredRussianPromptAndNoTranscriptMutation() async throws {
        let transport = FixtureTransport()
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let session = self.session()
        let result = try await generator.generate(session: session, configuration: self.configuration())
        XCTAssertEqual(result.summary.count, 1)
        XCTAssertEqual(session.transcriptSegments[0].text, self.turns[0].text)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue((requests[0].messages[0]["content"] as? String ?? "").contains("in Russian"))
        XCTAssertFalse(requests[0].streaming)
        XCTAssertEqual(requests[0].maxRetries, 1)
    }

    func testGeneratorProcessesAllChunksAndReducesRecap() async throws {
        let transport = FixtureTransport()
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        var session = self.session()
        session.transcriptSegments = (0..<20).map { index in
            var segment = session.transcriptSegments[0]
            segment.id = UUID()
            segment.text = "Обсудили вопрос \(index). " + String(repeating: "Подробности разговора. ", count: 170)
            segment.start = .init(value: Int64(index * 1000), timescale: 1000)
            return segment
        }
        let result = try await generator.generate(session: session, configuration: self.configuration())
        let requests = await transport.requests
        XCTAssertGreaterThan(requests.count, 8)
        XCTAssertTrue(requests.contains { ($0.messages[0]["content"] as? String ?? "").contains("Condense") })
        XCTAssertLessThanOrEqual(result.summary.count, 8)
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
    }

    func testCancellationStopsBeforeTransport() async {
        let transport = FixtureTransport()
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let session = self.session()
        let config = self.configuration()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await generator.generate(session: session, configuration: config)
        }
        do { _ = try await task.value; XCTFail("Cancellation must stop generation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testLaterChunkCancelsEarlierDecisionAndTaskWithoutErasingHistory() async throws {
        let transport = FixtureTransport(cancellationMode: true)
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let session = self.cancellationSession()
        let output = try await generator.generate(session: session, configuration: self.configuration())
        XCTAssertEqual(output.decisions.count, 2)
        XCTAssertEqual(output.decisions.first?.superseded, true)
        XCTAssertNil(output.decisions.last?.superseded)
        XCTAssertEqual(output.actions.count, 1)
        XCTAssertEqual(output.actions[0].superseded, true)
        XCTAssertEqual(output.actions[0].owner, "Иван")
        XCTAssertEqual(output.actions[0].deadline, "пятницу")
        XCTAssertEqual(Set(output.actions[0].evidence.map(\.segmentID)), Set(session.transcriptSegments.map(\.id)))
        XCTAssertTrue(output.summary.first?.text.contains("Отменяем") == true)
        XCTAssertNoThrow(try output.validated(against: PichiMeetingSummaryInput.turns(for: session)))
    }

    func testEarlierChangeCannotCancelLaterDecision() async {
        let transport = FixtureTransport(cancellationMode: true, wrongChronology: true)
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        var session = self.cancellationSession()
        session.transcriptSegments[0].start = .init(value: 120_000, timescale: 1000)
        session.transcriptSegments[1].start = .init(value: 0, timescale: 1000)
        do {
            _ = try await generator.generate(session: session, configuration: self.configuration())
            XCTFail("The transport attempted to supersede a later decision using an earlier source")
        } catch { XCTAssertEqual(error.localizedDescription, PichiMeetingSummaryError.invalidEvidence.localizedDescription) }
    }

    func testLaterChunkAnswerResolvesQuestionWithoutRewritingIt() async throws {
        let transport = FixtureTransport(answerMode: true)
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let session = self.questionSession()
        let result = try await generator.generate(session: session, configuration: self.configuration())
        XCTAssertEqual(result.openQuestions.count, 1)
        let question = try XCTUnwrap(result.openQuestions.first)
        XCTAssertEqual(question.text, "Когда будет готов отчёт?")
        XCTAssertEqual(question.resolved, true)
        XCTAssertNil(question.superseded, "Answering a question is distinct from cancelling a task")
        XCTAssertNil(question.owner)
        XCTAssertNil(question.deadline)
        XCTAssertEqual(Set(question.evidence.map(\.segmentID)), Set(session.transcriptSegments.map(\.id)))
        XCTAssertTrue(question.evidence.contains { $0.quote.contains("в пятницу") })
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
    }

    func testEarlierAnswerCannotResolveLaterQuestion() async {
        let transport = FixtureTransport(wrongChronology: true, answerMode: true)
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        var session = self.questionSession()
        session.transcriptSegments[0].start = .init(value: 120_000, timescale: 1000)
        session.transcriptSegments[1].start = .init(value: 0, timescale: 1000)
        do {
            _ = try await generator.generate(session: session, configuration: self.configuration())
            XCTFail("An earlier answer cannot resolve a question asked later")
        } catch { XCTAssertEqual(error.localizedDescription, PichiMeetingSummaryError.invalidEvidence.localizedDescription) }
    }

    func testRepeatedQuestionOccurrencesAreNotMergedAcrossEarlierAnswer() {
        let question = PichiMeetingSummaryItem(text: "Когда будет готов отчёт?", evidence: [.init(segmentID: self.id, quote: "Когда будет готов отчёт?")])
        let repeated = PichiMeetingSummaryItem(text: question.text, evidence: [.init(segmentID: UUID(), quote: "Когда будет готов отчёт?")])
        XCTAssertEqual(PichiMeetingSummaryDocument.unique([question, repeated], preserveOccurrences: true).count, 2)
    }

    func testLiveRussianSummaryWithOllamaWhenEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PICHI_MEETING_SUMMARY_LIVE"] == "1",
                          "Opt-in local inference check. Requires an installed qwen3.5:4b model in Ollama.")
        let configuration = PichiMeetingSummaryConfiguration(providerID: "pichi-local", modelID: "qwen3.5:4b",
                                                             baseURL: "http://127.0.0.1:11434/v1", apiKey: "", language: "ru")
        let session = self.session()
        let result = try await PichiMeetingSummaryGenerator().generate(session: session, configuration: configuration)
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertFalse(result.decisions.isEmpty, "An explicitly stated pricing decision should be retained")
        XCTAssertTrue(result.decisions.allSatisfy { !$0.text.contains("Иван") },
                      "The collective pricing decision must not invent an individual decision maker")
        XCTAssertFalse(result.actions.isEmpty, "An explicitly assigned report should be retained")
        XCTAssertTrue(result.actions.contains { $0.owner == "Иван" })
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
    }

    private func configuration(endpoint: String = "http://127.0.0.1:11434/v1") -> PichiMeetingSummaryConfiguration {
        .init(providerID: "fixture", modelID: "fixture-model", baseURL: endpoint, apiKey: "", language: "ru")
    }

    private func session() -> MeetingSession {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "fixture-microphone", displayName: "Mic")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic meeting", languageCode: "ru", microphone: microphone),
                                     timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                                                     firstPresentationTime: .init(value: 0, timescale: 1000)))
        let trackID = UUID()
        let speakerID = UUID()
        session.audioTracks = [.init(id: trackID, kind: .microphone, sourceIdentifier: "fixture", sourceDisplayName: "Mic",
                                     format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
        session.speakers = [.init(id: speakerID, displayName: "Иван", diarizationClusterID: "fixture",
                                  trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        session.transcriptSegments = [.init(id: self.id, start: .init(value: 0, timescale: 1000), end: .init(value: 1000, timescale: 1000),
                                            sourceTrackID: trackID, speakerID: speakerID, text: self.turns[0].text,
                                            revision: 0, status: .final, overlap: .none, completeness: .complete)]
        return session
    }

    private func cancellationSession() -> MeetingSession {
        var session = self.session()
        var first = session.transcriptSegments[0]
        first.text = "Решили выпустить в пятницу. Иван подготовит релиз в пятницу. " + String(repeating: "Подробности разговора. ", count: 300)
        var second = first
        second.id = UUID()
        second.start = .init(value: 60_000, timescale: 1000)
        second.end = .init(value: 90_000, timescale: 1000)
        second.text = "Отменяем выпуск в пятницу. Иван не должен готовить релиз. " + String(repeating: "Другие подробности. ", count: 300)
        session.transcriptSegments = [first, second]
        return session
    }

    private func questionSession() -> MeetingSession {
        var session = self.cancellationSession()
        session.transcriptSegments[0].text = "Когда будет готов отчёт? " + String(repeating: "Подробности разговора. ", count: 300)
        session.transcriptSegments[1].text = "Ответ: отчёт будет готов в пятницу. " + String(repeating: "Другие подробности. ", count: 300)
        return session
    }

    private actor FixtureTransport {
        var requests: [LLMClient.Config] = []
        let cancellationMode: Bool
        let wrongChronology: Bool
        let answerMode: Bool

        init(cancellationMode: Bool = false, wrongChronology: Bool = false, answerMode: Bool = false) {
            self.cancellationMode = cancellationMode
            self.wrongChronology = wrongChronology
            self.answerMode = answerMode
        }

        func complete(_ config: LLMClient.Config) throws -> String {
            self.requests.append(config)
            let text = config.messages.last?["content"] as? String ?? ""
            let prompt = config.messages[0]["content"] as? String ?? ""
            if prompt.contains("Reconcile meeting") {
                let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                let candidates = try XCTUnwrap(request["candidates"] as? [[String: Any]])
                let events = try XCTUnwrap(request["changes"] as? [[String: Any]])
                let event = try XCTUnwrap(events.first)
                let eventTime = try XCTUnwrap(event["sourceSeconds"] as? Double)
                let eventItem = try XCTUnwrap(event["item"] as? [String: Any])
                let evidence = try XCTUnwrap(eventItem["evidence"] as? [[String: Any]])
                let updates = candidates.compactMap { candidate -> [String: Any]? in
                    guard let index = candidate["index"] as? Int,
                          let time = candidate["lastSourceSeconds"] as? Double,
                          self.wrongChronology || eventTime > time else { return nil }
                    return ["index": index, "evidence": evidence]
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["updates": updates]), as: UTF8.self)
            }
            let start = try XCTUnwrap(text.firstIndex(of: "["))
            let data = Data(text[start...].utf8)
            let item: PichiMeetingSummaryItem
            if prompt.contains("Condense") {
                let items = try JSONDecoder().decode([PichiMeetingSummaryItem].self, from: data)
                item = try XCTUnwrap(self.cancellationMode || self.answerMode ? items.last : items.first)
            } else {
                let turn = try XCTUnwrap(JSONDecoder().decode([PichiMeetingSummaryTurn].self, from: data).first)
                item = .init(text: "Резюме \(turn.id)", evidence: [.init(segmentID: turn.id, quote: String(turn.text.prefix(100)))])
                if self.answerMode {
                    let questioning = turn.text.hasPrefix("Когда")
                    let evidence = [PichiMeetingSummaryEvidence(segmentID: turn.id, quote: String(turn.text.prefix(34)))]
                    let fact = PichiMeetingSummaryItem(text: questioning ? "Когда будет готов отчёт?" : "Отчёт будет готов в пятницу.", evidence: evidence)
                    let document = PichiMeetingSummaryDocument(summary: [fact], decisions: [], actions: [],
                                                               openQuestions: questioning ? [fact] : [], answers: questioning ? [] : [fact])
                    return String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
                }
                if self.cancellationMode {
                    let cancelling = turn.text.hasPrefix("Отменяем")
                    let evidence = [PichiMeetingSummaryEvidence(segmentID: turn.id, quote: String(turn.text.prefix(57)))]
                    let fact = PichiMeetingSummaryItem(text: cancelling ? "Отменяем выпуск." : "Выпустить в пятницу.", evidence: evidence)
                    let action = PichiMeetingSummaryItem(text: "Подготовить релиз.", evidence: evidence, owner: "Иван", deadline: "пятницу")
                    let document = PichiMeetingSummaryDocument(summary: [fact], decisions: [fact],
                                                               actions: cancelling ? [] : [action], openQuestions: [], changes: cancelling ? [fact] : [])
                    return String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
                }
            }
            return String(decoding: try JSONEncoder().encode(PichiMeetingSummaryDocument(summary: [item], decisions: [], actions: [], openQuestions: [])), as: UTF8.self)
        }
    }
}
