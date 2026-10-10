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

    func testLiteralEvidenceChoicesKeepUnicodeSourceCoverageAndBoundSchema() throws {
        let text = (0..<310).map { "Ёж \($0) сказал: \"съешь ещё\".\n" }.joined()
        let turns = [PichiMeetingSummaryTurn(id: self.id, seconds: 3, speaker: "Иван", text: text)]
        for chunk in PichiMeetingSummaryInput.chunks(turns) {
            let choices = PichiMeetingSummaryInput.evidenceChoices(chunk)
            XCTAssertLessThanOrEqual(choices.count, 128)
            XCTAssertTrue(choices.allSatisfy { $0.segmentID == self.id && !$0.quote.isEmpty && $0.quote.count <= 160 && text.contains($0.quote) })
            XCTAssertEqual(PichiMeetingSummaryInput.normalized(choices.map(\.quote).joined(separator: " ")),
                           PichiMeetingSummaryInput.normalized(chunk.map(\.text).joined()))
            XCTAssertTrue(choices.contains { $0.quote.contains("Ёж") })
            let indexes = Array(choices.indices)
            let schema = PichiMeetingSummaryTransport.schema(ledger: false, sourceIndexes: indexes)
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: schema).count, 64_000)
            let definitions = try XCTUnwrap(schema["$defs"] as? [String: Any])
            let evidence = try XCTUnwrap(definitions["evidence"] as? [String: Any])
            let fields = try XCTUnwrap(evidence["properties"] as? [String: Any])
            XCTAssertEqual((fields["sourceIndex"] as? [String: Any])?["enum"] as? [Int], indexes)
            XCTAssertNil(fields["quote"], "The model selects a source, never rewrites its quote")
            XCTAssertNil(fields["segmentID"])
        }
        let longWord = PichiMeetingSummaryTurn(id: self.id, seconds: 0, speaker: "Иван", text: String(repeating: "Ж", count: 510))
        let pieces = PichiMeetingSummaryInput.evidenceChoices([longWord])
        XCTAssertEqual(pieces.map(\.quote.count), [160, 160, 160, 30], "Repeated passages and the final tail must remain in their original order")
    }

    func testExistingChunkBudgetPreservesManyShortTurnsAndDifficultWordBoundaries() {
        let shortTurns = (0..<2000).map { index in
            PichiMeetingSummaryTurn(id: UUID(), seconds: Double(index), speaker: "", text: "да")
        }
        let fragments = PichiMeetingSummaryInput.chunks(shortTurns)
        XCTAssertEqual(fragments.flatMap { $0 }.count, shortTurns.count)
        XCTAssertTrue(fragments.allSatisfy { PichiMeetingSummaryInput.evidenceChoices($0).count <= 128 })
        let difficult = String(repeating: "а " + String(repeating: "б", count: 159) + " ", count: 50)
        let source = PichiMeetingSummaryTurn(id: self.id, seconds: 0, speaker: "", text: difficult)
        let chunks = PichiMeetingSummaryInput.chunks([source])
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.text).joined(), difficult)
        XCTAssertTrue(chunks.allSatisfy { PichiMeetingSummaryInput.evidenceChoices($0).count <= 128 })
    }

    func testRepeatedSourcePassagesRemainInOrderInCompactInput() async throws {
        var session = self.session()
        let agreement = "Решили выпустить релиз в пятницу. " + String(repeating: "А", count: 125) + " "
        let cancellation = "Отменяем выпуск. " + String(repeating: "Б", count: 142) + " "
        XCTAssertEqual(agreement.count, 160)
        XCTAssertEqual(cancellation.count, 160)
        session.transcriptSegments[0].text = agreement + cancellation + agreement
        let transport = RepairTransport(responses: [try self.referenceResponse(2)])
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        _ = try await generator.generate(session: session, configuration: self.configuration())
        let requests = await transport.requests
        let request = try XCTUnwrap(requests.first)
        let content = try XCTUnwrap(request.messages[1]["content"] as? String)
        let input = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
        let sources = try XCTUnwrap(input["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[0]["text"] as? String, sources[2]["text"] as? String)
        XCTAssertNotEqual(sources[0]["text"] as? String, sources[1]["text"] as? String)
        XCTAssertEqual(sources.compactMap { $0["sourceIndex"] as? Int }, [0, 1, 2])
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

    func testNativeOllamaBoundsContextAndUsesStructuredNonThinkingOutput() throws {
        let config = LLMClient.Config(messages: [["role": "system", "content": "Summarize a meeting"]], model: "fixture-model",
                                      baseURL: "http://127.0.0.1:11434/v1", apiKey: "", streaming: false)
        let request = try PichiMeetingSummaryTransport.ollamaRequest(config)
        XCTAssertEqual(request.url?.path, "/api/chat")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 8192, "Do not reserve the model's maximum context on an 8 GB Mac")
        XCTAssertEqual(options["num_predict"] as? Int, 3000)
        XCTAssertEqual(options["temperature"] as? Int, 0)
        XCTAssertEqual(body["think"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual(body["keep_alive"] as? Int, 0, "Release this model before ASR resumes")
        let schema = try XCTUnwrap(body["format"] as? [String: Any])
        XCTAssertTrue((schema["required"] as? [String] ?? []).contains("actions"))
        XCTAssertTrue((schema["required"] as? [String] ?? []).contains("decisions"))
    }

    func testNativeOllamaAdapterLeavesOtherEndpointsOnExistingTransport() {
        for endpoint in ["http://localhost:1234/v1", "http://localhost:11434/proxy/v1", "https://api.example.com/v1"] {
            let config = LLMClient.Config(messages: [], model: "fixture", baseURL: endpoint, apiKey: "", streaming: false)
            XCTAssertFalse(PichiMeetingSummaryTransport.usesNativeOllama(config))
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
        XCTAssertNotNil(requests[0].extraParameters["response_format"])
    }

    func testOtherCompatibleEndpointsKeepTheirExistingRequestFormat() async throws {
        let transport = RepairTransport(responses: [try self.referenceResponse(0)])
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let result = try await generator.generate(session: self.session(), configuration: self.configuration(endpoint: "http://127.0.0.1:1234/v1"))
        XCTAssertEqual(result.summary[0].evidence, [.init(segmentID: self.id, quote: self.turns[0].text)])
        let requests = await transport.requests
        XCTAssertNil(requests[0].extraParameters["response_format"])
    }

    func testRewrittenASRQuoteRegeneratesOnceWithSamePrivateInput() async throws {
        var session = self.session()
        session.transcriptSegments[0].text = "мы так и не получили согласования на перенос"
        let evidence = PichiMeetingSummaryEvidence(segmentID: self.id, quote: session.transcriptSegments[0].text)
        let valid = PichiMeetingSummaryDocument(summary: [.init(text: "Согласование переноса не получено.", evidence: [evidence])],
                                               decisions: [], actions: [], openQuestions: [])
        var invalid = valid
        invalid.summary[0].evidence = [.init(segmentID: self.id, quote: "мы так и не получили разрешения на перенос")]
        let transport = RepairTransport(responses: [try self.json(invalid), try self.json(valid)])
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let fingerprint = PichiMeetingSummaryInput.fingerprint(session)
        let result = try await generator.generate(session: session, configuration: self.configuration())
        XCTAssertEqual(result, valid)
        XCTAssertEqual(PichiMeetingSummaryInput.fingerprint(session), fingerprint)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].messages[1]["content"] as? String, requests[1].messages[1]["content"] as? String)
        XCTAssertEqual(requests[0].model, requests[1].model)
        XCTAssertEqual(requests[0].baseURL, requests[1].baseURL)
        XCTAssertEqual(requests[0].maxTokens, requests[1].maxTokens)
        let repair = requests[1].messages[0]["content"] as? String ?? ""
        XCTAssertTrue(repair.contains("SHORT contiguous excerpt"))
        XCTAssertFalse(repair.contains(invalid.summary[0].evidence[0].quote), "Do not double the context with rejected private output")
    }

    func testSecondInvalidResultRemainsRejectedWithoutFurtherCompletion() async throws {
        let invalid = try self.json(self.document(quote: "Иван подготовит отчет к пятнице."))
        let transport = RepairTransport(responses: [invalid, invalid])
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        do {
            _ = try await generator.generate(session: self.session(), configuration: self.configuration())
            XCTFail("A changed source spelling must remain invalid after the repair attempt")
        } catch {
            XCTAssertEqual(error as? PichiMeetingSummaryValidationIssue, .nonliteralQuote)
            XCTAssertEqual(error.localizedDescription, PichiMeetingSummaryError.invalidEvidence.localizedDescription)
        }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testCancellationAfterInvalidResultNeverStartsRepair() async throws {
        let invalid = try self.json(self.document(quote: "Изменённая цитата"))
        let transport = RepairTransport(responses: [invalid])
        let generator = PichiMeetingSummaryGenerator { config in
            let output = try await transport.complete(config)
            withUnsafeCurrentTask { $0?.cancel() }
            return output
        }
        let task = Task { try await generator.generate(session: self.session(), configuration: self.configuration()) }
        do { _ = try await task.value; XCTFail("Cancellation must stop before repair") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testTransportFailureDoesNotStartValidationRepair() async {
        let transport = RepairTransport(responses: [], failTransport: true)
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        do { _ = try await generator.generate(session: self.session(), configuration: self.configuration()); XCTFail("Transport error must propagate") }
        catch { XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testMalformedOutputAndUnsupportedAttributionHaveBoundedSpecificRepair() async throws {
        for (invalid, expected) in [
            ("{}", "JSON structure"),
            (try self.json(self.document(evidenceID: UUID())), "unknown source"),
            (try self.json(self.document(owner: "Мария")), "action owner"),
            (try self.json(self.document(deadline: "пятница")), "action deadline"),
        ] {
            let transport = RepairTransport(responses: [invalid, try self.json(self.document())])
            let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
            let result = try await generator.generate(session: self.session(), configuration: self.configuration())
            XCTAssertEqual(result, self.document())
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertTrue((requests[1].messages[0]["content"] as? String ?? "").contains(expected))
        }
    }

    func testCompactCitationResolvesFromImmutableCatalogWithoutChangingSavedDocumentFormat() async throws {
        let response = try self.referenceResponse(0)
        let transport = RepairTransport(responses: [response])
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let result = try await generator.generate(session: self.session(), configuration: self.configuration())
        XCTAssertEqual(result.summary[0].evidence, [.init(segmentID: self.id, quote: self.turns[0].text)])
        let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        let summary = try XCTUnwrap(canonical?["summary"] as? [[String: Any]])
        let evidence = try XCTUnwrap(summary[0]["evidence"] as? [[String: Any]])
        XCTAssertEqual(evidence[0]["segmentID"] as? String, self.id.uuidString)
        XCTAssertEqual(evidence[0]["quote"] as? String, self.turns[0].text)
        XCTAssertNil(evidence[0]["sourceIndex"], "Compact indices are request-local and must never reach persisted documents")
    }

    func testUnknownBooleanAndAugmentedCompactCitationsRemainRejected() async throws {
        for reference: Any in [999, true, "0", -1, 0.5] {
            let invalid = try self.referenceResponse(reference)
            let transport = RepairTransport(responses: [invalid, invalid])
            let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
            do { _ = try await generator.generate(session: self.session(), configuration: self.configuration()); XCTFail("Invalid source choice must remain rejected") }
            catch { XCTAssertEqual(error as? PichiMeetingSummaryValidationIssue, .unknownSource) }
            let count = await transport.requests.count
            XCTAssertEqual(count, 2)
        }
        let invalid = try self.referenceResponse(0, additionalQuote: "Подменённая цитата")
        let transport = RepairTransport(responses: [invalid, invalid])
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        do { _ = try await generator.generate(session: self.session(), configuration: self.configuration()); XCTFail("Compact choices must not carry an extra model-written quote") }
        catch { XCTAssertEqual(error as? PichiMeetingSummaryValidationIssue, .unknownSource) }
    }

    private func referenceResponse(_ index: Any, additionalQuote: String? = nil) throws -> String {
        var evidence: [String: Any] = ["sourceIndex": index]
        if let additionalQuote { evidence["quote"] = additionalQuote }
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "summary": [["text": "Обсудили отчёт.", "evidence": [evidence]]],
            "decisions": [], "actions": [], "openQuestions": [], "changes": [], "answers": [],
        ]), as: UTF8.self)
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

    func testMergedCorrectionRespectsCanonicalEvidenceLimitWithoutClipping() async throws {
        for count in [15, 16] {
            let fixture = self.evidenceBudgetFixture(count: count)
            let turns = PichiMeetingSummaryInput.turns(for: fixture.session)
            XCTAssertNoThrow(try fixture.document.validated(against: turns), "Each source document is valid before reconciliation")
            let response = try self.json(fixture.document)
            let update = String(decoding: try JSONSerialization.data(withJSONObject: ["updates": [[
                "index": 0, "evidence": [["segmentID": fixture.correction.segmentID.uuidString, "quote": fixture.correction.quote]],
            ]]]), as: UTF8.self)
            let transport = RepairTransport(responses: [response, update])
            let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
            let fingerprint = PichiMeetingSummaryInput.fingerprint(fixture.session)
            do {
                let result = try await generator.generate(session: fixture.session, configuration: self.configuration(endpoint: "http://127.0.0.1:1234/v1"))
                XCTAssertEqual(count, 15, "A valid 16-citation source plus a later correction must be rejected before returning")
                let decision = try XCTUnwrap(result.decisions.first)
                XCTAssertEqual(decision.superseded, true)
                XCTAssertEqual(decision.evidence.count, 16)
                XCTAssertEqual(Set(decision.evidence), Set(fixture.document.decisions[0].evidence + [fixture.correction]),
                               "Do not clip original evidence or drop the correcting source to fit")
                XCTAssertNoThrow(try result.validated(against: turns))
            } catch PichiMeetingSummaryError.invalidOutput {
                XCTAssertEqual(count, 16)
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 2, "The final gate rejects deterministically without another model request")
            XCTAssertNil(requests[0].extraParameters["response_format"], "Exercise the compatible API's 16-citation contract")
            XCTAssertEqual(fixture.document.decisions[0].evidence.count, count)
            XCTAssertEqual(PichiMeetingSummaryInput.fingerprint(fixture.session), fingerprint)
        }
    }

    @MainActor
    func testControllerEvidenceBudgetFailureRestoresResourcesBeforePublication() async throws {
        let fixture = self.evidenceBudgetFixture(count: 16)
        let update = String(decoding: try JSONSerialization.data(withJSONObject: ["updates": [[
            "index": 0, "evidence": [["segmentID": fixture.correction.segmentID.uuidString, "quote": fixture.correction.quote]],
        ]]]), as: UTF8.self)
        let transport = RepairTransport(responses: [try self.json(fixture.document), update])
        let owner = MeetingModelResidencyCoordinator()
        let resources = SummaryResidentResources(owner: owner)
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = resources.participants
        let controller = PichiMeetingSummaryController(generator: .init { try await transport.complete($0) })
        do {
            _ = try await controller.generate(session: fixture.session, configuration: self.configuration(endpoint: "http://127.0.0.1:1234/v1"), asr: asr)
            XCTFail("Do not return an oversized document to the caller that publishes and saves it")
        } catch PichiMeetingSummaryError.invalidOutput {}
        XCTAssertNil(controller.document)
        resources.assertRestored()
        XCTAssertEqual(owner.phase, .normal)
        XCTAssertFalse(owner.isExclusive)
        XCTAssertNil(asr.activeExclusiveActivity)
    }

    func testIdenticalDecisionAndTaskReinstatementStayActiveAfterEarlierCancellation() async throws {
        let transport = FixtureTransport(cancellationMode: true)
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let session = self.reinstatementSession(includeLaterCancellation: false)
        let result = try await generator.generate(session: session, configuration: self.configuration())
        let releases = result.decisions.filter { $0.text == "Выпустить в пятницу." }
        XCTAssertEqual(releases.count, 2)
        XCTAssertEqual(releases.first?.superseded, true)
        XCTAssertNil(releases.last?.superseded)
        XCTAssertEqual(result.actions.count, 2)
        XCTAssertEqual(result.actions.first?.superseded, true)
        XCTAssertNil(result.actions.last?.superseded)
        XCTAssertEqual(result.actions.last?.evidence.map(\.segmentID), [session.transcriptSegments[2].id])
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
    }

    func testRepeatedLaterCancellationAlsoSupersedesReinstatedTask() async throws {
        let transport = FixtureTransport(cancellationMode: true)
        let generator = PichiMeetingSummaryGenerator { try await transport.complete($0) }
        let session = self.reinstatementSession(includeLaterCancellation: true)
        let result = try await generator.generate(session: session, configuration: self.configuration())
        XCTAssertEqual(result.actions.count, 2)
        XCTAssertTrue(result.actions.allSatisfy { $0.superseded == true })
        XCTAssertEqual(Set(result.actions[0].evidence.map(\.segmentID)), Set([session.transcriptSegments[0].id, session.transcriptSegments[1].id]))
        XCTAssertEqual(Set(result.actions[1].evidence.map(\.segmentID)), Set([session.transcriptSegments[2].id, session.transcriptSegments[3].id]))
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
    }

    @MainActor
    func testControllerSuspendsAllResidentResourcesBeforeGenerationAndRestoresOnError() async {
        let owner = MeetingModelResidencyCoordinator()
        let resources = SummaryResidentResources(owner: owner)
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = resources.participants
        let controller = PichiMeetingSummaryController(generator: .init { _ in
            await resources.observeGeneration()
            throw LLMError.invalidResponse
        })
        do {
            _ = try await controller.generate(session: self.session(), configuration: self.configuration(), asr: asr)
            XCTFail("Expected inference failure")
        } catch { XCTAssertTrue(error is LLMError) }
        resources.assertRestored()
        XCTAssertEqual(owner.phase, .normal)
        XCTAssertFalse(owner.isExclusive)
        XCTAssertNil(asr.activeExclusiveActivity)
    }

    @MainActor
    func testControllerCancellationDrainsGenerationBeforeUncancelledResourceRestoration() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let resources = SummaryResidentResources(owner: owner)
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = resources.participants
        let entered = expectation(description: "Summary inference entered after model suspension")
        let drain = SummaryInferenceDrain()
        let transport = FixtureTransport()
        let controller = PichiMeetingSummaryController(generator: .init { config in
            await resources.observeGeneration()
            entered.fulfill()
            await drain.wait() // Deliberately non-cooperative inference must drain before restoration.
            await resources.observeInferenceReturn()
            return try await transport.complete(config)
        })
        let session = self.session()
        let configuration = self.configuration()
        let task = Task { try await controller.generate(session: session, configuration: configuration, asr: asr) }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        XCTAssertTrue(owner.isExclusive)
        XCTAssertEqual(owner.phase, .summary)
        XCTAssertFalse(resources.events.contains { $0.hasPrefix("restore:") })
        drain.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        resources.assertRestored()
        let returned = try XCTUnwrap(resources.events.firstIndex(of: "inference-returned"))
        let restored = try XCTUnwrap(resources.events.firstIndex(where: { $0.hasPrefix("restore:") }))
        XCTAssertLessThan(returned, restored)
        XCTAssertEqual(owner.phase, .normal)
        XCTAssertNil(asr.activeExclusiveActivity)
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
                          "Opt-in local inference check. Requires an installed local model in Ollama.")
        let modelID = ProcessInfo.processInfo.environment["PICHI_MEETING_SUMMARY_LIVE_MODEL_ID"] ?? "qwen3.5:4b"
        let configuration = PichiMeetingSummaryConfiguration(providerID: "pichi-local", modelID: modelID,
                                                             baseURL: "http://127.0.0.1:11434/v1", apiKey: "", language: "ru")
        let session = self.session()
        let result = try await PichiMeetingSummaryGenerator().generate(session: session, configuration: configuration)
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertFalse(result.decisions.isEmpty, "An explicitly stated pricing decision should be retained")
        XCTAssertTrue(result.decisions.allSatisfy { !$0.text.contains("Иван") },
                      "The collective pricing decision must not invent an individual decision maker")
        XCTAssertFalse(result.actions.isEmpty, "An explicitly assigned report should be retained")
        XCTAssertTrue(result.actions.contains { $0.owner == "Иван" })
        XCTAssertTrue(result.actions.contains { $0.deadline == "к пятнице" }, "Dates must retain their exact source wording")
        XCTAssertFalse(result.summary.contains { $0.text.contains("Иван согласовал") || $0.text.contains("Иван решил") || $0.text.contains("Иван поддержал") },
                       "The recap must not infer individual approval from an assigned task")
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
    }

    func testLiveUnansweredQuestionCannotBeResolvedByUnrelatedLaterStatusWhenEnabled() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PICHI_MEETING_SUMMARY_LIVE"] == "1",
                          "Opt-in semantic regression using synthetic speech, never a private recording.")
        let modelID = ProcessInfo.processInfo.environment["PICHI_MEETING_SUMMARY_LIVE_MODEL_ID"] ?? "qwen3.5:4b"
        let configuration = PichiMeetingSummaryConfiguration(providerID: "pichi-local", modelID: modelID,
                                                             baseURL: "http://127.0.0.1:11434/v1", apiKey: "", language: "ru")
        var session = self.session()
        session.transcriptSegments[0].text = "Оборудование установлено. Можно ли уже отправить итоговые материалы клиенту?"
        var closing = session.transcriptSegments[0]
        closing.id = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        closing.start = .init(value: 60_000, timescale: 1000)
        closing.end = .init(value: 61_000, timescale: 1000)
        closing.text = "Какие вопросы ещё остались? Нужно выяснить, можно ли вернуть платёж. Решения о возврате пока нет."
        session.transcriptSegments.append(closing)
        let fingerprint = PichiMeetingSummaryInput.fingerprint(session)
        let result = try await PichiMeetingSummaryGenerator().generate(session: session, configuration: configuration)
        let opening = try XCTUnwrap(result.openQuestions.first { item in
            item.text.localizedCaseInsensitiveContains("отправ") && item.text.localizedCaseInsensitiveContains("материал")
                && item.evidence.contains { $0.segmentID == self.id }
        }, "Retain the explicitly unanswered opening question, not only a recap of its topic")
        XCTAssertNotEqual(opening.resolved, true, "The later refund status does not answer whether materials can be sent")
        XCTAssertTrue(result.openQuestions.contains { item in
            (item.text.localizedCaseInsensitiveContains("верн") || item.text.localizedCaseInsensitiveContains("возврат"))
                && (item.text.localizedCaseInsensitiveContains("плат") || item.text.localizedCaseInsensitiveContains("средств"))
                && item.evidence.contains { $0.segmentID == closing.id } && item.resolved != true
        }, "The closing requested check must also remain unanswered")
        XCTAssertTrue(result.decisions.isEmpty, "No agreed choice was spoken")
        XCTAssertTrue(result.actions.allSatisfy { $0.owner == nil && $0.deadline == nil },
                      "Requested work may be retained, but no owner or deadline was assigned")
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
        XCTAssertEqual(PichiMeetingSummaryInput.fingerprint(session), fingerprint)
    }

    func testLiveSavedSessionSummaryWhenExplicitlyEnabled() async throws {
        let path = ProcessInfo.processInfo.environment["PICHI_MEETING_SUMMARY_LIVE_SESSION_PATH"] ?? ""
        try XCTSkipIf(path.isEmpty, "Opt-in local verification of an explicitly authorized private saved session.")
        let modelID = ProcessInfo.processInfo.environment["PICHI_MEETING_SUMMARY_LIVE_MODEL_ID"] ?? "qwen3.5:4b"
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(MeetingSession.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let fingerprint = PichiMeetingSummaryInput.fingerprint(session)
        let result = try await PichiMeetingSummaryGenerator().generate(session: session, configuration: .init(
            providerID: "pichi-local", modelID: modelID, baseURL: "http://127.0.0.1:11434/v1", apiKey: "", language: "ru"
        ))
        XCTAssertFalse(result.summary.isEmpty)
        XCTAssertNoThrow(try result.validated(against: PichiMeetingSummaryInput.turns(for: session)))
        XCTAssertEqual(PichiMeetingSummaryInput.fingerprint(session), fingerprint)
    }

    func testNativeOutputLimitClassificationExcludesIncompleteAndEmptyResponses() throws {
        func response(done: Bool, reason: String?, content: String) throws -> Data {
            var fields: [String: Any] = ["done": done, "message": ["content": content]]
            if let reason { fields["done_reason"] = reason }
            return try JSONSerialization.data(withJSONObject: fields)
        }
        for content in ["", "partial"] {
            XCTAssertThrowsError(try PichiMeetingSummaryTransport.ollamaContent(response(done: true, reason: "length", content: content))) {
                guard case PichiMeetingSummaryError.outputLimit = $0 else { return XCTFail("Only explicit length must classify as output-limit") }
            }
        }
        for (done, reason, content) in [(false, "length", "partial"), (true, "stop", ""), (false, "stop", "partial")] {
            XCTAssertThrowsError(try PichiMeetingSummaryTransport.ollamaContent(response(done: done, reason: reason, content: content))) {
                guard case LLMError.invalidResponse = $0 else { return XCTFail("Incomplete or empty output is not a budget exhaustion") }
            }
        }
        XCTAssertEqual(try PichiMeetingSummaryTransport.ollamaContent(response(done: true, reason: nil, content: "{}")), "{}")
    }

    func testOutputLimitRecoveryVisitsEverySourceInChronologicalOrderAndKeepsConfiguration() async throws {
        var session = self.session()
        let template = session.transcriptSegments[0]
        session.transcriptSegments = (0..<12).map { index in
            var segment = template
            segment.id = UUID()
            segment.start = .init(value: Int64(index * 1000), timescale: 1000)
            segment.text = "Пункт \(index). " + String(repeating: "Русская речь с Ё и ё. ", count: 25)
            return segment
        }
        let transport = OutputBudgetTransport(maximumSourceCharacters: 1800)
        let result = try await PichiMeetingSummaryGenerator { try await transport.complete($0) }
            .generate(session: session, configuration: self.configuration())
        let successful = await transport.successfulExtractionSources
        let sources = PichiMeetingSummaryInput.turns(for: session)
        for source in sources {
            let excerpts = successful.filter { $0.id == source.id }
            XCTAssertEqual(PichiMeetingSummaryInput.normalized(excerpts.map(\.text).joined(separator: " ")),
                           PichiMeetingSummaryInput.normalized(source.text))
            XCTAssertTrue(excerpts.allSatisfy { $0.seconds == source.seconds && $0.speaker == source.speaker })
        }
        XCTAssertEqual(successful.map(\.seconds), successful.map(\.seconds).sorted())
        let truncations = await transport.truncations
        XCTAssertGreaterThan(truncations, 1, "Exercise multiple extraction retries")
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.model == "fixture-model" && $0.baseURL == self.configuration().baseURL })
        for request in requests {
            let native = try PichiMeetingSummaryTransport.ollamaRequest(request)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(native.httpBody)) as? [String: Any])
            XCTAssertEqual((body["options"] as? [String: Int])?["num_ctx"], 8192)
            XCTAssertEqual((body["options"] as? [String: Int])?["num_predict"], 3000)
        }
        XCTAssertNoThrow(try result.validated(against: sources))
    }

    func testRecapOutputLimitFailsClosedInsteadOfIsolatingEarlierCommitmentFromCancellation() async throws {
        // The two original extraction documents are independently valid. A recap
        // must see both together; splitting would repeat a stale earlier commitment.
        let source = self.cancellationSession()
        let transport = FixtureTransport(cancellationMode: true)
        let calls = OutputBudgetTransport(maximumSourceCharacters: Int.max)
        let generator = PichiMeetingSummaryGenerator { config in
            let input = config.messages.last?["content"] as? String ?? ""
            let fields = try JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any]
            if fields?["recap"] != nil {
                _ = try await calls.complete(config)
                throw PichiMeetingSummaryError.outputLimit
            }
            return try await transport.complete(config)
        }
        do {
            _ = try await generator.generate(session: source, configuration: self.configuration())
            XCTFail("A recap cannot split away the later correction")
        } catch { guard case PichiMeetingSummaryError.outputLimit = error else { return XCTFail("Expected typed reduction rejection") } }
        let reductionRequests = await calls.requests.count
        XCTAssertEqual(reductionRequests, 1, "No independent child recaps can be published after combined reduction exhaustion")
    }

    func testOutputLimitRecoveryStopsAtFloorAndDepth() async throws {
        for count in [10, 20000] {
            var session = self.session()
            session.transcriptSegments[0].text = String(repeating: "Ж", count: count)
            let transport = OutputBudgetTransport(maximumSourceCharacters: 0)
            do {
                _ = try await PichiMeetingSummaryGenerator { try await transport.complete($0) }
                    .generate(session: session, configuration: self.configuration())
                XCTFail("A model that always exhausts output must remain rejected")
            } catch { guard case PichiMeetingSummaryError.outputLimit = error else { return XCTFail("Expected typed exhaustion") } }
            let count = await transport.requests.count
            XCTAssertLessThanOrEqual(count, 4)
        }
    }

    func testOutputLimitOnValidationRegenerationDoesNotSplitRejectedEvidence() async throws {
        let transport = OutputBudgetTransport(maximumSourceCharacters: 0, invalidFirst: true)
        do {
            _ = try await PichiMeetingSummaryGenerator { try await transport.complete($0) }
                .generate(session: self.session(), configuration: self.configuration())
            XCTFail("Regeneration exhaustion must reject rather than hide an evidence/schema rejection")
        } catch { guard case PichiMeetingSummaryError.outputLimit = error else { return XCTFail("Expected typed exhaustion") } }
        let count = await transport.requests.count
        XCTAssertEqual(count, 2)
    }

    func testAllCompletionStagesShareTheAttemptRequestBudget() async throws {
        var session = self.session()
        let template = session.transcriptSegments[0]
        session.transcriptSegments = (0..<129).map { index in
            var segment = template
            segment.id = UUID()
            segment.start = .init(value: Int64(index * 1000), timescale: 1000)
            segment.text = String(repeating: "Ж", count: 7000)
            return segment
        }
        let transport = OutputBudgetTransport(maximumSourceCharacters: Int.max, invalidFirst: true, alternateInvalid: true)
        do {
            _ = try await PichiMeetingSummaryGenerator { try await transport.complete($0) }
                .generate(session: session, configuration: self.configuration())
            XCTFail("Repairs must also consume the 256-call operation budget")
        } catch { guard case PichiMeetingSummaryError.tooManyChunks = error else { return XCTFail("Expected operation budget rejection") } }
        let count = await transport.requests.count
        XCTAssertEqual(count, 256)
    }

    @MainActor
    func testOutputLimitCancellationJoinsInferenceBeforeRestorationAndStartsNoChildren() async throws {
        let owner = MeetingModelResidencyCoordinator()
        let resources = SummaryResidentResources(owner: owner)
        let asr = ASRService(meetingModelResidency: owner)
        asr.meetingModelParticipantsForTesting = resources.participants
        let entered = expectation(description: "Budget-limited inference entered")
        let drain = SummaryInferenceDrain()
        let transport = OutputBudgetTransport(maximumSourceCharacters: 0)
        let controller = PichiMeetingSummaryController(generator: .init { config in
            await resources.observeGeneration()
            entered.fulfill()
            await drain.wait()
            await resources.observeInferenceReturn()
            return try await transport.complete(config)
        })
        var session = self.session()
        session.transcriptSegments[0].text = String(repeating: "Русская речь. ", count: 500)
        let task = Task { try await controller.generate(session: session, configuration: self.configuration(), asr: asr) }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        XCTAssertTrue(owner.isExclusive)
        XCTAssertFalse(resources.events.contains { $0.hasPrefix("restore:") })
        drain.release()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        resources.assertRestored()
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
        XCTAssertNil(controller.document, "Rejected recovery must never publish a partial document")
    }

    @MainActor
    func testExhaustedRecoveryRetainsThePriorSavedSummaryAndRestoresResources() async throws {
        // The controller owns publication/storage. A unique synthetic session exercises
        // its existing shared-store contract without replacing any personal recording.
        let session = self.session()
        let configuration = self.configuration()
        let store = MeetingSessionStore.shared
        try await store.create(session)
        do {
            let existingDirectory = try await store.existingSessionDirectory(for: session.id)
            let directory = try XCTUnwrap(existingDirectory)
            let artifactURL = directory.appendingPathComponent("pichi-meeting-summary.json")
            let prior = self.document()
            let bytes = try JSONEncoder().encode(PichiMeetingSummaryArtifact(version: 5,
                transcriptHash: PichiMeetingSummaryInput.fingerprint(session), configurationIdentity: configuration.cacheIdentity,
                generatedAt: Date(), document: prior))
            try bytes.write(to: artifactURL, options: .atomic)
            let owner = MeetingModelResidencyCoordinator()
            let resources = SummaryResidentResources(owner: owner)
            let asr = ASRService(meetingModelResidency: owner)
            asr.meetingModelParticipantsForTesting = resources.participants
            let transport = OutputBudgetTransport(maximumSourceCharacters: 0)
            let controller = PichiMeetingSummaryController(generator: .init { try await transport.complete($0) })
            await controller.refresh(session: session, configuration: configuration)
            XCTAssertEqual(controller.document, prior)
            controller.summarize(session: session, configuration: configuration, asr: asr)
            for _ in 0..<100 {
                if !controller.generating { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(controller.generating, "Exhausted operation must settle within the bounded fixture wait")
            XCTAssertNotNil(controller.error)
            XCTAssertEqual(controller.document, prior)
            XCTAssertEqual(try Data(contentsOf: artifactURL), bytes)
            resources.assertRestored()
            XCTAssertFalse(owner.isExclusive)
        } catch {
            try await store.delete(id: session.id)
            throw error
        }
        try await store.delete(id: session.id)
    }

    private actor OutputBudgetTransport {
        var requests: [LLMClient.Config] = []
        var successfulExtractionSources: [PichiMeetingSummarySource] = []
        var truncations = 0
        let maximumSourceCharacters: Int
        var truncateFirstReduction: Bool
        let invalidFirst: Bool
        let alternateInvalid: Bool

        init(maximumSourceCharacters: Int, truncateFirstReduction: Bool = false,
             invalidFirst: Bool = false, alternateInvalid: Bool = false) {
            self.maximumSourceCharacters = maximumSourceCharacters
            self.truncateFirstReduction = truncateFirstReduction
            self.invalidFirst = invalidFirst
            self.alternateInvalid = alternateInvalid
        }

        func complete(_ config: LLMClient.Config) throws -> String {
            self.requests.append(config)
            if self.invalidFirst, self.requests.count == 1 || (self.alternateInvalid && self.requests.count % 2 == 1) { return "{}" }
            let input = try XCTUnwrap(config.messages.last?["content"] as? String)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(input.utf8)) as? [String: Any])
            let data = try JSONSerialization.data(withJSONObject: XCTUnwrap(fields["sources"]))
            let sources = try JSONDecoder().decode([PichiMeetingSummarySource].self, from: data)
            let reducing = fields["recap"] != nil
            if sources.reduce(0, { $0 + $1.text.count }) > self.maximumSourceCharacters || (reducing && self.truncateFirstReduction) {
                self.truncations += 1
                self.truncateFirstReduction = false
                throw PichiMeetingSummaryError.outputLimit
            }
            if !reducing { self.successfulExtractionSources += sources }
            let response: [String: Any] = ["summary": [["text": "Обсудили пункт.", "evidence": [["sourceIndex": 0]]]],
                                           "decisions": [], "actions": [], "openQuestions": [], "changes": [], "answers": []]
            return String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
        }
    }

    private func json(_ document: PichiMeetingSummaryDocument) throws -> String {
        String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
    }

    private actor RepairTransport {
        var requests: [LLMClient.Config] = []
        let responses: [String]
        let failTransport: Bool

        init(responses: [String], failTransport: Bool = false) {
            self.responses = responses
            self.failTransport = failTransport
        }

        func complete(_ config: LLMClient.Config) throws -> String {
            self.requests.append(config)
            if self.failTransport { throw URLError(.cannotConnectToHost) }
            let index = self.requests.count - 1
            guard self.responses.indices.contains(index) else { throw URLError(.badServerResponse) }
            return self.responses[index]
        }
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

    private func evidenceBudgetFixture(count: Int) -> (session: MeetingSession, document: PichiMeetingSummaryDocument, correction: PichiMeetingSummaryEvidence) {
        var session = self.session()
        let quotes = (0..<count).map { "Согласовали пункт \($0)." }
        session.transcriptSegments[0].text = quotes.joined(separator: " ")
        var later = session.transcriptSegments[0]
        later.id = UUID()
        later.start = .init(value: 60_000, timescale: 1000)
        later.end = .init(value: 61_000, timescale: 1000)
        later.text = "Отменяем согласованные пункты."
        session.transcriptSegments.append(later)
        let evidence = quotes.map { PichiMeetingSummaryEvidence(segmentID: self.id, quote: $0) }
        let correction = PichiMeetingSummaryEvidence(segmentID: later.id, quote: later.text)
        let document = PichiMeetingSummaryDocument(summary: [.init(text: "Обсудили согласованные пункты.", evidence: [evidence[0]])],
                                                  decisions: [.init(text: "Согласованные пункты.", evidence: evidence)], actions: [], openQuestions: [],
                                                  changes: [.init(text: later.text, evidence: [correction])])
        return (session, document, correction)
    }

    private func questionSession() -> MeetingSession {
        var session = self.cancellationSession()
        session.transcriptSegments[0].text = "Когда будет готов отчёт? " + String(repeating: "Подробности разговора. ", count: 300)
        session.transcriptSegments[1].text = "Ответ: отчёт будет готов в пятницу. " + String(repeating: "Другие подробности. ", count: 300)
        return session
    }

    private func reinstatementSession(includeLaterCancellation: Bool) -> MeetingSession {
        var session = self.cancellationSession()
        var reinstated = session.transcriptSegments[0]
        reinstated.id = UUID()
        reinstated.start = .init(value: 120_000, timescale: 1000)
        session.transcriptSegments.append(reinstated)
        if includeLaterCancellation {
            var cancelledAgain = session.transcriptSegments[1]
            cancelledAgain.id = UUID()
            cancelledAgain.start = .init(value: 180_000, timescale: 1000)
            session.transcriptSegments.append(cancelledAgain)
        }
        return session
    }

    @MainActor
    private final class SummaryResidentResources {
        let owner: MeetingModelResidencyCoordinator
        var buffers = Dictionary(uniqueKeysWithValues: ["speech", "fluid", "dictionary"].map { ($0, Data(count: 1024)) })
        var events: [String] = []

        init(owner: MeetingModelResidencyCoordinator) { self.owner = owner }

        var participants: [MeetingModelParticipant] {
            ["speech", "fluid", "dictionary"].map { name in
                MeetingModelParticipant(owner: name, snapshot: {
                    self.events.append("snapshot:\(name)")
                    return self.buffers[name].map { _ in .init(id: name, configuration: "original") }
                }, suspend: {
                    self.buffers.removeValue(forKey: name)
                    self.events.append("suspend:\(name)")
                }, restore: { model in
                    XCTAssertFalse(Task.isCancelled, "Restoration must run in the joined uncancelled cleanup")
                    self.buffers[model.id] = Data(count: 1024)
                    self.events.append("restore:\(model.id)")
                })
            }
        }

        func observeGeneration() {
            XCTAssertTrue(self.buffers.isEmpty, "ASR, private AI and dictionary resources must retire before LLM inference")
            XCTAssertEqual(self.owner.phase, .summary, "Mark the coordinator owned by this ASR instance")
            XCTAssertThrowsError(try self.owner.beginOperation(owner: "speech", modelID: "ordinary-warmup"))
            self.events.append("generation")
        }

        func observeInferenceReturn() { self.events.append("inference-returned") }
        func assertRestored() {
            XCTAssertEqual(Set(self.buffers.keys), Set(["speech", "fluid", "dictionary"]))
            for name in ["speech", "fluid", "dictionary"] {
                XCTAssertEqual(self.events.filter { $0 == "restore:\(name)" }.count, 1)
            }
        }
    }

    @MainActor
    private final class SummaryInferenceDrain {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if self.open { return }
            await withCheckedContinuation { self.waiters.append($0) }
        }
        func release() {
            self.open = true
            for waiter in self.waiters { waiter.resume() }
            self.waiters.removeAll()
        }
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
                let updates = candidates.compactMap { candidate -> [String: Any]? in
                    guard let index = candidate["index"] as? Int,
                          let time = candidate["lastSourceSeconds"] as? Double,
                          let event = events.first(where: { self.wrongChronology || ($0["sourceSeconds"] as? Double ?? 0) > time }),
                          let eventItem = event["item"] as? [String: Any],
                          let evidence = eventItem["evidence"] as? [[String: Any]] else { return nil }
                    return ["index": index, "evidence": evidence]
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: ["updates": updates]), as: UTF8.self)
            }
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let sourceObjects = try XCTUnwrap(request["sources"] as? [[String: Any]])
            let sources = try JSONDecoder().decode([PichiMeetingSummarySource].self, from: JSONSerialization.data(withJSONObject: sourceObjects))
            let item: PichiMeetingSummaryItem
            if prompt.contains("Condense") {
                let wireItems = try XCTUnwrap(request["recap"] as? [[String: Any]])
                let canonical = try wireItems.map { fields -> [String: Any] in
                    var copy = fields
                    let citations = try XCTUnwrap(fields["evidence"] as? [[String: Any]])
                    copy["evidence"] = try citations.map { citation -> [String: Any] in
                        let index = try XCTUnwrap(citation["sourceIndex"] as? Int)
                        let source = try XCTUnwrap(sources.first { $0.sourceIndex == index })
                        return ["segmentID": source.id.uuidString, "quote": source.text]
                    }
                    return copy
                }
                let items = try JSONDecoder().decode([PichiMeetingSummaryItem].self, from: JSONSerialization.data(withJSONObject: canonical))
                item = try XCTUnwrap(self.cancellationMode || self.answerMode ? items.last : items.first)
            } else {
                let source = try XCTUnwrap(sources.first)
                let turn = PichiMeetingSummaryTurn(id: source.id, seconds: source.seconds, speaker: source.speaker, text: source.text)
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
