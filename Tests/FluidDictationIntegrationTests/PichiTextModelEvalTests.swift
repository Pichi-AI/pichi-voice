@testable import FluidVoice_Debug
import CryptoKit
import Foundation
import XCTest

/// Opt-in quality matrix. Model output is evidence to review, not an assertion
/// that a candidate is safe to select as the application's default.
@MainActor
final class PichiTextModelEvalTests: XCTestCase {
    func testRussianTextModelEvaluationWhenExplicitlyEnabled() async throws {
        let path = ProcessInfo.processInfo.environment["PICHI_TEXT_MODEL_EVAL_PLAN"] ?? ""
        try XCTSkipIf(path.isEmpty, "Opt-in local model evaluation; no model download or server call in normal CI.")
        let plan = try self.decode(EvaluationPlan.self, at: path)
        try plan.validate()
        try self.verifyAliasManifest(plan)
        let fixtureData = try self.boundedData(at: plan.fixturePath)
        let corpus = try JSONDecoder().decode(EvaluationCorpus.self, from: fixtureData)
        try corpus.validate()
        let output = URL(fileURLWithPath: plan.outputDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let prompt = SettingsStore.combineBasePrompt(for: .dictate, with: SettingsStore.defaultDictationPromptBodyText())
        var report = EvaluationReport(sourceCommit: plan.sourceCommit, corpusSHA256: digest(fixtureData),
                                      enhancementPromptSHA256: digest(Data(prompt.utf8)), serverProfileSHA256: plan.serverProfileSHA256,
                                      sourceFilesSHA256: try self.sourceHashes(plan.sourceRoot),
                                      enhancementFormattingFlags: self.formattingFlags(), enhancementStreaming: plan.enhancementStreaming ?? false,
                                      startedAt: ISO8601DateFormatter().string(from: Date()), models: plan.models,
                                      corpusCases: corpus.cases.map { .init(id: $0.id, task: $0.task, critical: $0.repeatForFinalists) },
                                      finalists: plan.finalists ?? [], completed: false, isolationStatus: "running", results: [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        for model in plan.models {
            try await self.verifyInstalledAlias(model)
            for fixture in corpus.cases where plan.caseIDs == nil || plan.caseIDs!.contains(fixture.id) {
                let repetitions = fixture.repeatForFinalists && (plan.finalists ?? []).contains(model.id)
                    ? max(2, plan.repetitions ?? 1) : (plan.repetitions ?? 1)
                for repetition in 1...repetitions {
                    try Task.checkCancellation()
                    guard self.formattingFlags() == report.enhancementFormattingFlags else {
                        throw EvaluationInputError.changedFormatting
                    }
                    try await self.verifyInstalledAlias(model)
                    let audit = EvaluationRequestAudit()
                    var cancelled: Error?
                    let started = Date()
                    var result = EvaluationResult(modelID: model.id, caseID: fixture.id, task: fixture.task,
                                                  repetition: repetition, structuralStatus: "not-run",
                                                  checks: [], reviewRubric: fixture.rubric,
                                                  humanReviewStatus: "pending", startedAt: ISO8601DateFormatter().string(from: started),
                                                  finishedAt: "", elapsedSeconds: 0, completionCalls: [])
                    do {
                        if fixture.task == "summary" {
                            let session = fixture.session()
                            let fingerprint = PichiMeetingSummaryInput.fingerprint(session)
                            let generator = PichiMeetingSummaryGenerator { config in
                                await audit.begin(config)
                                let content = try await PichiMeetingSummaryTransport.complete(config)
                                await audit.finish(content)
                                return content
                            }
                            let document = try await generator.generate(session: session, configuration: .init(
                                providerID: "local-evaluation", modelID: model.id,
                                baseURL: "http://127.0.0.1:11434/v1", apiKey: "", language: "ru"))
                            _ = try document.validated(against: PichiMeetingSummaryInput.turns(for: session))
                            guard fingerprint == PichiMeetingSummaryInput.fingerprint(session) else {
                                throw EvaluationInputError.changedSource
                            }
                            result.summary = document
                            result.structuralStatus = "accepted"
                            result.checks = fixture.rules.map { $0.evaluate(document: document) }
                        } else {
                            let request = DictationPromptRequest(promptText: prompt, transcript: fixture.transcript!)
                            // Reuse the production cleanup prompt, data envelope and client.
                            // The explicitly selected eval aliases fix server context at
                            // 8192; existing request options fix output at 3000. This is
                            // configured behavior, not the default original-model profile.
                            var config = LLMClient.Config(messages: request.messages, model: model.id,
                                                          baseURL: "http://127.0.0.1:11434/v1", apiKey: "",
                                                          streaming: plan.enhancementStreaming ?? false, tools: [], temperature: 0.2, maxTokens: 3000,
                                                          extraParameters: ["reasoning_effort": "none"])
                            config.timeoutSeconds = 120
                            await audit.begin(config)
                            let response = try await LLMClient.shared.call(config)
                            // The existing client can fall back to raw content when a
                            // response contains only thought tags. The eval boundary
                            // must reject that fallback before persistence or judgment.
                            let answer = try self.enhancementAnswer(response.content)
                            await audit.finish(answer)
                            guard self.formattingFlags() == report.enhancementFormattingFlags else {
                                throw EvaluationInputError.changedFormatting
                            }
                            let cleaned = ASRService.applyGAAVFormatting(answer)
                            result.rawEnhancement = answer
                            result.enhancement = cleaned
                            result.structuralStatus = "accepted"
                            result.checks = fixture.rules.map { $0.evaluate(text: answer) }
                        }
                    } catch {
                        if error is CancellationError || Task.isCancelled { cancelled = error }
                        result.structuralStatus = cancelled == nil ? "rejected" : "cancelled"
                        result.failure = cancelled == nil ? self.safeFailure(error) : "cancelled"
                    }
                    if self.formattingFlags() != report.enhancementFormattingFlags {
                        cancelled = EvaluationInputError.changedFormatting
                        result.structuralStatus = "rejected"
                        result.failure = "changed-formatting-profile"
                    }
                    result.elapsedSeconds = Date().timeIntervalSince(started)
                    result.finishedAt = ISO8601DateFormatter().string(from: Date())
                    result.completionCalls = await audit.records
                    report.results.append(result)
                    do {
                        // Explicit test-only cleanup; await before starting another row.
                        // Failure aborts the run rather than yielding misleading RAM/latency comparisons.
                        let cleanup = Task.detached { try await Self.unloadAlias(model.id) }
                        do { try await cleanup.value } catch {
                            report.isolationStatus = "cleanup-failed"
                            try self.write(encoder.encode(report), to: output.appendingPathComponent("evaluation.json"))
                            throw error
                        }
                    }
                    try self.write(encoder.encode(report), to: output.appendingPathComponent("evaluation.json"))
                    if let cancelled { throw cancelled }
                    // Content deliberately stays in ignored JSON rather than test logs.
                    print("TEXT_MODEL_EVAL model=\(model.id) case=\(fixture.id) repetition=\(repetition) structural=\(result.structuralStatus) gates=\(result.checks.filter(\.passed).count)/\(result.checks.count) completionCalls=\(result.completionCalls.count) seconds=\(String(format: "%.3f", result.elapsedSeconds))")
                }
            }
        }
        XCTAssertFalse(report.results.isEmpty, "The configured case selection must run at least one case")
        report.completed = !report.results.isEmpty
        report.isolationStatus = "clean"
        try self.write(encoder.encode(report), to: output.appendingPathComponent("evaluation.json"))
    }

    func testSemanticGatesRejectUnsupportedClaimsWithoutRequiringExactParaphrases() throws {
        let question = EvaluationRule(id: "question", kind: "item", section: "openQuestions", tokens: ["материал"], resolved: false)
        let evidence = PichiMeetingSummaryEvidence(segmentID: UUID(), quote: "Можно ли отправить материалы?")
        let correct = PichiMeetingSummaryItem(text: "Допускается ли отправка материалов?", evidence: [evidence], resolved: false)
        let wrong = PichiMeetingSummaryItem(text: correct.text, evidence: [evidence], resolved: true)
        XCTAssertTrue(question.evaluate(document: .init(summary: [correct], decisions: [], actions: [], openQuestions: [correct])).passed)
        XCTAssertFalse(question.evaluate(document: .init(summary: [wrong], decisions: [], actions: [], openQuestions: [wrong])).passed)
        let task = EvaluationRule(id: "task", kind: "item", section: "actions", tokens: ["отч"], owner: "Иван", deadline: "к пятнице")
        let unsupported = PichiMeetingSummaryItem(text: "Подготовить отчёт", evidence: [evidence], owner: "Пётр", deadline: "в понедельник")
        XCTAssertFalse(task.evaluate(document: .init(summary: [correct], decisions: [], actions: [unsupported], openQuestions: [])).passed)
        let entities = EvaluationRule(id: "names", kind: "contains", section: "all", values: ["Алёна", "PX-17"])
        XCTAssertTrue(entities.evaluate(text: "Алёна, проверь PX-17.").passed)
        XCTAssertFalse(entities.evaluate(text: "Алена, проверь PX-18.").passed)
    }

    func testEnhancementEvalRejectsThoughtOnlyClientFallback() {
        for content in ["<think>Synthetic reasoning only.</think>", "Synthetic reasoning only.</thinking>"] {
            XCTAssertThrowsError(try self.enhancementAnswer(content)) { error in
                guard let error = error as? LLMError, case .invalidResponse = error else {
                    return XCTFail("Thought-only content must be rejected as an invalid response")
                }
            }
        }
    }

    func testEnhancementEvalUsesOnlyAnswerAfterThoughtTags() throws {
        let answer = try self.enhancementAnswer("<think>Synthetic reasoning only.</think>Материалы пока не отправляй.")
        XCTAssertEqual(answer, "Материалы пока не отправляй.")
        XCTAssertFalse(answer.contains("Synthetic reasoning"))
        XCTAssertTrue(EvaluationRule(id: "negation", kind: "contains", section: "all", values: ["не отправляй"])
            .evaluate(text: answer).passed)
    }

    private func enhancementAnswer(_ content: String) throws -> String {
        let answer = LLMClient.shared.stripThinkingTags(content).content
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LLMError.invalidResponse }
        return answer
    }

    private func formattingFlags() -> [String: Bool] {
        ["gaavLowercaseFirstLetterEnabled": SettingsStore.shared.gaavLowercaseFirstLetterEnabled,
         "gaavRemoveTrailingPeriodEnabled": SettingsStore.shared.gaavRemoveTrailingPeriodEnabled]
    }

    private func verifyAliasManifest(_ plan: EvaluationPlan) throws {
        struct Manifest: Decodable {
            struct Alias: Decodable {
                let id: String; let digest: String; let baseModelID: String; let baseDigest: String
                let numCtx: Int; let numPredict: Int; let usesLibraryAlias: Bool
            }
            let aliases: [Alias]
        }
        let data = try self.boundedData(at: plan.aliasManifestPath)
        guard digest(data) == plan.serverProfileSHA256 else { throw EvaluationInputError.invalidPlan }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        for model in plan.models {
            guard manifest.aliases.contains(where: {
                $0.id == model.id && $0.digest == model.digest && $0.baseModelID == model.baseModelID &&
                    $0.baseDigest == model.baseDigest && $0.numCtx == 8192 && $0.numPredict == 3000 && $0.usesLibraryAlias
            }) else { throw EvaluationInputError.invalidPlan }
        }
    }

    private func sourceHashes(_ root: String) throws -> [String: String] {
        let files = ["Sources/Fluid/Services/Meeting/PichiMeetingSummary.swift",
                     "Sources/Fluid/Services/Meeting/PichiMeetingSummaryTransport.swift",
                     "Sources/Fluid/Services/DictationPromptRequest.swift",
                     "Sources/Fluid/Services/LLMClient.swift", "Sources/Fluid/Persistence/SettingsStore.swift",
                     "Sources/Fluid/Services/ASRService.swift",
                     "Tests/FluidDictationIntegrationTests/PichiTextModelEvalTests.swift"]
        var result: [String: String] = [:]
        for file in files {
            let data = try Data(contentsOf: URL(fileURLWithPath: root).appendingPathComponent(file))
            result[file] = digest(data)
        }
        return result
    }

    private func verifyInstalledAlias(_ model: EvaluationModel) async throws {
        struct Tags: Decodable {
            struct Entry: Decodable { let name: String; let digest: String }
            let models: [Entry]
        }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        request.timeoutInterval = 30
        let (data, response) = try await PichiMeetingSummaryTransport.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else {
            throw EvaluationInputError.aliasDigestMismatch
        }
        let entries = try JSONDecoder().decode(Tags.self, from: data).models
        guard entries.contains(where: { $0.name == model.id && $0.digest == model.digest }),
              entries.contains(where: { $0.name == model.baseModelID && $0.digest == model.baseDigest })
        else { throw EvaluationInputError.aliasDigestMismatch }
    }

    nonisolated private static func unloadAlias(_ id: String) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": id, "keep_alive": 0, "stream": false])
        let (data, response) = try await PichiMeetingSummaryTransport.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 200_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["done"] as? Bool == true
        else { throw EvaluationInputError.isolationCleanupFailed }
    }

    private func boundedData(at path: String) throws -> Data {
        let url = URL(fileURLWithPath: path)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= 200_000 else { throw EvaluationInputError.invalidPlan }
        return try Data(contentsOf: url)
    }

    private func decode<T: Decodable>(_ type: T.Type, at path: String) throws -> T {
        try JSONDecoder().decode(type, from: self.boundedData(at: path))
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func safeFailure(_ error: Error) -> String {
        if let error = error as? PichiMeetingSummaryValidationIssue { return "evidence:\(error)" }
        if error is PichiMeetingSummaryError { return "summary-validation-rejected" }
        if let llmError = error as? LLMError {
            switch llmError {
            case let .httpError(status, _): return "http:\(status)"
            case .timeout: return "timeout"
            default: return "llm-request"
            }
        }
        if error is URLError { return "network" }
        return String(reflecting: type(of: error))
    }
}

private enum EvaluationInputError: Error {
    case invalidPlan, invalidCorpus, changedSource, changedFormatting, aliasDigestMismatch, isolationCleanupFailed
}

private struct EvaluationPlan: Decodable {
    let sourceCommit: String
    let sourceRoot: String
    let fixturePath: String
    let outputDirectory: String
    let serverProfileSHA256: String
    let aliasManifestPath: String
    let models: [EvaluationModel]
    let caseIDs: [String]?
    let repetitions: Int?
    let finalists: [String]?
    let enhancementStreaming: Bool?

    func validate() throws {
        guard sourceCommit.count == 40, sourceCommit.allSatisfy({ $0.isHexDigit }),
              (1...12).contains(models.count), Set(models.map(\.id)).count == models.count,
              models.allSatisfy({ !$0.id.isEmpty && $0.id.count < 200 && !$0.digest.isEmpty &&
                  $0.usesLibraryAlias && !$0.baseDigest.isEmpty && $0.id != $0.baseModelID }),
              (1...3).contains(repetitions ?? 1), outputDirectory.hasPrefix("/"),
              URL(fileURLWithPath: outputDirectory).standardizedFileURL.path.contains("/.build/")
        else { throw EvaluationInputError.invalidPlan }
    }
}

private struct EvaluationModel: Codable, Sendable {
    let id: String
    let digest: String
    let baseModelID: String
    let baseDigest: String
    let usesLibraryAlias: Bool
    let quantization: String
    let parameterSize: String
    let modelBytes: Int64
}

private struct EvaluationCorpus: Decodable {
    let schemaVersion: Int
    let language: String
    let provenance: String
    let cases: [EvaluationCase]

    func validate() throws {
        guard schemaVersion == 1, language == "ru", !provenance.isEmpty,
              (1...64).contains(cases.count), Set(cases.map(\.id)).count == cases.count,
              cases.allSatisfy({ !$0.id.isEmpty && !$0.rubric.isEmpty && !$0.rules.isEmpty &&
                  (($0.task == "summary" && !($0.turns ?? []).isEmpty) || ($0.task == "enhancement" && $0.transcript != nil)) })
        else { throw EvaluationInputError.invalidCorpus }
    }
}

private struct EvaluationCase: Decodable {
    struct Turn: Decodable { let seconds: Double; let speaker: String; let text: String }
    let id: String
    let task: String
    let rubric: [String]
    let rules: [EvaluationRule]
    let turns: [Turn]?
    let transcript: String?
    let repeatForFinalists: Bool
    let hasCoverageGap: Bool?

    func session() -> MeetingSession {
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "synthetic-eval", displayName: "Synthetic")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: id, languageCode: "ru", microphone: microphone),
                                     timebase: .init(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                                                     firstPresentationTime: .init(value: 0, timescale: 1000)))
        let trackID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        session.audioTracks = [.init(id: trackID, kind: .microphone, sourceIdentifier: "synthetic-eval", sourceDisplayName: "Synthetic",
                                     format: nil, timebase: session.timebase, health: .waiting, chunks: [])]
        for (index, turn) in (turns ?? []).enumerated() {
            let speakerID = UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", index + 1))!
            session.speakers.append(.init(id: speakerID, displayName: turn.speaker, diarizationClusterID: "synthetic-\(index)",
                                          trackKind: .microphone, isLocalUser: false, identityCandidates: []))
            session.transcriptSegments.append(.init(id: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", index + 1))!,
                start: .init(value: Int64(turn.seconds * 1000), timescale: 1000),
                end: .init(value: Int64((turn.seconds + 1) * 1000), timescale: 1000),
                sourceTrackID: trackID, speakerID: speakerID, text: turn.text,
                revision: 0, status: .final, overlap: .none, completeness: .complete))
        }
        if hasCoverageGap == true {
            session.transcriptCoverageGaps = [.init(trackID: trackID, start: 30, end: 90, reason: .excludedUnitIncompleteCoverage)]
        }
        return session
    }
}

private struct EvaluationRule: Codable {
    let id: String
    let kind: String
    let section: String
    var tokens: [String]? = nil
    var anyTokens: [String]? = nil
    var values: [String]? = nil
    var anyValues: [String]? = nil
    var owner: String? = nil
    var deadline: String? = nil
    var superseded: Bool? = nil
    var resolved: Bool? = nil
    var owners: [String]? = nil
    var deadlines: [String]? = nil

    func evaluate(document: PichiMeetingSummaryDocument) -> EvaluationCheck {
        let items: [PichiMeetingSummaryItem]
        switch section {
        case "summary": items = document.summary
        case "decisions": items = document.decisions
        case "actions": items = document.actions
        case "openQuestions": items = document.openQuestions
        default: items = document.allItems
        }
        let passed: Bool
        switch kind {
        case "empty": passed = items.isEmpty
        case "item": passed = items.contains { item in
            matches(item.text, all: tokens, any: anyTokens) &&
                (owner == nil || item.owner == owner) && (deadline == nil || item.deadline == deadline) &&
                (superseded == nil || (item.superseded == true) == superseded) &&
                (resolved == nil || (item.resolved == true) == resolved)
        }
        case "attribution": passed = items.allSatisfy { item in
            (item.owner == nil || (owners ?? []).contains(item.owner!)) &&
                (item.deadline == nil || (deadlines ?? []).contains(item.deadline!))
        }
        default: return evaluate(text: items.map(\.text).joined(separator: "\n"))
        }
        return .init(id: id, passed: passed)
    }

    func evaluate(text: String) -> EvaluationCheck {
        let passed: Bool
        switch kind {
        case "contains": passed = matches(text, all: values, any: anyValues)
        case "notContains": passed = !(values ?? []).contains { contains(text, $0) }
        default: passed = false
        }
        return .init(id: id, passed: passed)
    }

    private func matches(_ text: String, all: [String]?, any: [String]?) -> Bool {
        (all ?? []).allSatisfy { contains(text, $0) } && (any == nil || any!.contains { contains(text, $0) })
    }

    private func contains(_ text: String, _ value: String) -> Bool {
        text.range(of: value, options: [.caseInsensitive], locale: Locale(identifier: "ru")) != nil
    }
}

private struct EvaluationCheck: Codable { let id: String; let passed: Bool }

private struct EvaluationResult: Codable {
    let modelID: String
    let caseID: String
    let task: String
    let repetition: Int
    var structuralStatus: String
    var checks: [EvaluationCheck]
    let reviewRubric: [String]
    var humanReviewStatus: String
    let startedAt: String
    var finishedAt: String
    var elapsedSeconds: Double
    var completionCalls: [EvaluationRequestRecord]
    var summary: PichiMeetingSummaryDocument? = nil
    var enhancement: String? = nil
    var rawEnhancement: String? = nil
    var failure: String? = nil
}

private struct EvaluationReport: Codable {
    let sourceCommit: String
    let corpusSHA256: String
    let enhancementPromptSHA256: String
    let serverProfileSHA256: String
    let sourceFilesSHA256: [String: String]
    let enhancementFormattingFlags: [String: Bool]
    let enhancementStreaming: Bool
    let startedAt: String
    let models: [EvaluationModel]
    let corpusCases: [CaseManifest]
    let finalists: [String]
    var completed: Bool
    var isolationStatus: String
    var results: [EvaluationResult]

    struct CaseManifest: Codable { let id: String; let task: String; let critical: Bool }
}

private struct EvaluationRequestRecord: Codable {
    let requestSHA256: String
    let promptSHA256: String
    let temperature: Double?
    let maxTokens: Int?
    let baseURL: String
    var responseSHA256: String? = nil
    var content: String? = nil
}

private actor EvaluationRequestAudit {
    private(set) var records: [EvaluationRequestRecord] = []

    func begin(_ config: LLMClient.Config) {
        let data = (try? JSONSerialization.data(withJSONObject: config.messages, options: [.sortedKeys])) ?? Data()
        let body: Data
        if PichiMeetingSummaryTransport.usesNativeOllama(config), config.extraParameters["response_format"] != nil {
            body = (try? PichiMeetingSummaryTransport.ollamaRequest(config).httpBody) ?? Data()
        } else {
            body = (try? JSONSerialization.data(withJSONObject: LLMClient.shared.buildChatCompletionsBody(config), options: [.sortedKeys])) ?? Data()
        }
        records.append(.init(requestSHA256: digest(body), promptSHA256: digest(data),
                             temperature: config.temperature, maxTokens: config.maxTokens, baseURL: config.baseURL))
    }

    func finish(_ content: String) {
        guard !records.isEmpty else { return }
        let answer = LLMClient.shared.stripThinkingTags(content).content
        records[records.count - 1].content = answer
        records[records.count - 1].responseSHA256 = digest(Data(answer.utf8))
    }
}

private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
