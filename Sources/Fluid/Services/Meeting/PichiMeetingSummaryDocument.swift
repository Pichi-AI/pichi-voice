import CryptoKit
import Foundation

// Pichi's public-runtime summary path is independent of Fluid Intelligence.
nonisolated struct PichiMeetingSummaryEvidence: Codable, Hashable, Sendable {
    let segmentID: UUID
    let quote: String
}

/// A safe, machine-readable rejection reason. Never include private source text in
/// diagnostics or repair instructions; the same immutable input supplies evidence.
nonisolated enum PichiMeetingSummaryValidationIssue: Error, LocalizedError, Equatable {
    case unknownSource, nonliteralQuote, unsupportedOwner, unsupportedDeadline

    var errorDescription: String? { PichiMeetingSummaryError.invalidEvidence.errorDescription }

    var repairInstruction: String {
        switch self {
        case .unknownSource:
            "A citation used an unknown source. Select only a numeric sourceIndex from the supplied source catalog."
        case .nonliteralQuote:
            "A citation quote was not an exact substring of its cited segment. Copy a SHORT contiguous excerpt literally from that segment. Keep its spelling, word order, punctuation and grammatical mistakes unchanged. Never repair or paraphrase source speech inside a quote."
        case .unsupportedOwner:
            "An action owner was not present in its cited source speaker or speech. Copy an explicitly stated name literally, or use null when unspecified."
        case .unsupportedDeadline:
            "An action deadline was not present in its cited source speech. Copy an explicitly stated deadline literally, including prepositions and grammatical case, or use null when unspecified."
        }
    }
}

/// Task lifecycle and urgency are output data, independent of any model or UI language.
nonisolated enum PichiMeetingSummaryActionStatus: String, Codable, CaseIterable, Sendable {
    case requested, proposed, agreed, completed, cancelled

    func text(language: PichiInterfaceLanguage = PichiLocalization.language, bundle: Bundle = .main) -> String {
        switch self {
        case .requested: PichiLocalization.text("Requested", language: language, bundle: bundle)
        case .proposed: PichiLocalization.text("Proposed", language: language, bundle: bundle)
        case .agreed: PichiLocalization.text("Agreed", language: language, bundle: bundle)
        case .completed: PichiLocalization.text("task.status.completed", language: language, bundle: bundle, defaultValue: "Completed")
        case .cancelled: PichiLocalization.text("Cancelled", language: language, bundle: bundle)
        }
    }
}

nonisolated enum PichiMeetingSummaryActionUrgency: String, Codable, CaseIterable, Sendable {
    case urgent, normal, unspecified

    func text(language: PichiInterfaceLanguage = PichiLocalization.language, bundle: Bundle = .main) -> String {
        switch self {
        case .urgent: PichiLocalization.text("Urgent", language: language, bundle: bundle)
        case .normal: PichiLocalization.text("Not urgent", language: language, bundle: bundle)
        case .unspecified: PichiLocalization.text("Urgency not specified", language: language, bundle: bundle)
        }
    }
}

nonisolated struct PichiMeetingSummaryItem: Codable, Equatable, Sendable {
    let text: String
    var evidence: [PichiMeetingSummaryEvidence]
    var owner: String? = nil
    var deadline: String? = nil
    var superseded: Bool? = nil
    var resolved: Bool? = nil
    // Optional only for saved legacy documents. New structured actions supply all
    // three fields; the existing text remains the task's description/essence.
    var title: String? = nil
    var status: PichiMeetingSummaryActionStatus? = nil
    var urgency: PichiMeetingSummaryActionUrgency? = nil

    var hasActionMetadata: Bool { self.title != nil || self.status != nil || self.urgency != nil }
}

nonisolated struct PichiMeetingSummaryDocument: Codable, Equatable, Sendable {
    var summary: [PichiMeetingSummaryItem]
    var decisions: [PichiMeetingSummaryItem]
    var actions: [PichiMeetingSummaryItem]
    var openQuestions: [PichiMeetingSummaryItem]
    var changes: [PichiMeetingSummaryItem]? = nil
    var answers: [PichiMeetingSummaryItem]? = nil

    var allItems: [PichiMeetingSummaryItem] { self.summary + self.decisions + self.actions + self.openQuestions + (self.changes ?? []) + (self.answers ?? []) }

    func validated(against turns: [PichiMeetingSummaryTurn]) throws -> Self {
        guard !self.summary.isEmpty, self.allItems.count <= 30_000 else { throw PichiMeetingSummaryError.invalidOutput }
        guard (self.summary + self.decisions + self.openQuestions + (self.changes ?? []) + (self.answers ?? [])).allSatisfy({ $0.owner == nil && $0.deadline == nil && !$0.hasActionMetadata }),
              (self.summary + self.decisions + self.actions + (self.changes ?? []) + (self.answers ?? [])).allSatisfy({ $0.resolved != true }),
              self.openQuestions.allSatisfy({ $0.superseded != true })
        else { throw PichiMeetingSummaryError.invalidOutput }
        for action in self.actions where action.hasActionMetadata {
            guard let title = action.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  title.count <= 160, title.rangeOfCharacter(from: .newlines) == nil,
                  action.status != nil, action.urgency != nil
            else { throw PichiMeetingSummaryError.invalidOutput }
        }
        let sources = Dictionary(grouping: turns, by: \.id)
        for item in self.allItems {
            guard !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  item.text.count <= 2000, (1...16).contains(item.evidence.count)
            else { throw PichiMeetingSummaryError.invalidOutput }
            var citedSpeech: [String] = []
            var citedSpeakers: [String] = []
            for evidence in item.evidence {
                let quote = PichiMeetingSummaryInput.normalized(evidence.quote)
                guard let candidates = sources[evidence.segmentID] else { throw PichiMeetingSummaryValidationIssue.unknownSource }
                guard !quote.isEmpty, quote.count <= 500,
                      let source = candidates.first(where: { PichiMeetingSummaryInput.normalized($0.text).contains(quote) })
                else { throw PichiMeetingSummaryValidationIssue.nonliteralQuote }
                citedSpeech.append(evidence.quote)
                citedSpeakers.append(source.speaker)
            }
            // Keep owners and dates verbatim. Do not accept a model-invented attribution/date.
            // A value elsewhere in the original turn is not evidence for the
            // selected excerpt. Keep each excerpt separate so a field cannot be
            // assembled across citation boundaries. Speaker labels can support
            // names, but cannot supply a task's deadline.
            for (value, issue, choices) in [(item.owner, PichiMeetingSummaryValidationIssue.unsupportedOwner, citedSpeech + citedSpeakers),
                                            (item.deadline, PichiMeetingSummaryValidationIssue.unsupportedDeadline, citedSpeech)] {
                guard let value else { continue }
                guard !value.isEmpty, value.count <= 200,
                      choices.contains(where: { $0.localizedCaseInsensitiveContains(value) })
                else { throw issue }
            }
        }
        return self
    }

    static func decode(_ response: String, turns: [PichiMeetingSummaryTurn], recapOnly: Bool = false) throws -> Self {
        let json = self.unfenced(response)
        guard let data = json.data(using: .utf8), data.count <= 200_000,
              let document = try? JSONDecoder().decode(Self.self, from: data)
        else { throw PichiMeetingSummaryError.invalidOutput }
        // Reduction cannot introduce or replace the separately preserved ledgers,
        // even when a compatible endpoint ignores its structured-output schema.
        guard !recapOnly || ((1...8).contains(document.summary.count)
            && [document.decisions, document.actions, document.openQuestions, document.changes ?? [], document.answers ?? []].allSatisfy(\.isEmpty))
        else { throw PichiMeetingSummaryError.invalidOutput }
        guard document.allItems.count <= 100, document.allItems.allSatisfy({ $0.superseded != true && $0.resolved != true }),
              document.actions.allSatisfy({ $0.title != nil && $0.status != nil && $0.urgency != nil })
        else { throw PichiMeetingSummaryError.invalidOutput }
        return try document.validated(against: turns)
    }

    static func unfenced(_ response: String) -> String {
        var json = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if json.hasPrefix("```"), json.hasSuffix("```") {
            let lines = json.components(separatedBy: "\n")
            json = lines.dropFirst().dropLast().joined(separator: "\n")
        }
        return json
    }

    static func unique(_ items: [PichiMeetingSummaryItem], preserveOccurrences: Bool = false) -> [PichiMeetingSummaryItem] {
        var seen = Set<String>()
        return items.filter { item in
            var key = PichiMeetingSummaryInput.normalized(item.text).lowercased()
                + "|" + (item.owner ?? "") + "|" + (item.deadline ?? "")
                + "|" + (item.title ?? "") + "|" + (item.status?.rawValue ?? "") + "|" + (item.urgency?.rawValue ?? "")
            if preserveOccurrences { key += "|" + item.evidence.map { $0.segmentID.uuidString }.sorted().joined(separator: ",") }
            return seen.insert(key).inserted
        }
    }
}

nonisolated struct PichiMeetingSummaryTurn: Codable, Equatable, Sendable {
    let id: UUID
    let seconds: TimeInterval
    let speaker: String
    let text: String
}

/// Compact request citations avoid asking small models to retype private quotes
/// or UUIDs. The immutable catalog resolves a choice before strict validation.
nonisolated struct PichiMeetingSummarySource: Codable, Sendable {
    let sourceIndex: Int
    let id: UUID
    let seconds: TimeInterval
    let speaker: String
    let text: String

    var evidence: PichiMeetingSummaryEvidence { .init(segmentID: self.id, quote: self.text) }
}

nonisolated enum PichiMeetingSummaryInput {
    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func turns(for session: MeetingSession) -> [PichiMeetingSummaryTurn] {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        return session.transcriptSegments.filter { $0.status == .final && !$0.isEcho && !normalized($0.text).isEmpty }
            .sorted { $0.start < $1.start }
            .map { .init(id: $0.id, seconds: $0.start.seconds,
                         speaker: MeetingTranscriptExporter.speakerLabel(for: $0, in: session, speakerNames: names), text: $0.text) }
    }

    static func fingerprint(_ session: MeetingSession) -> String {
        // Language, names, corrections, gaps and meeting metadata invalidate the artifact.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        struct Snapshot: Encodable {
            let title: String
            let language: String
            let startedAt: Date
            let endedAt: Date?
            let turns: [PichiMeetingSummaryTurn]
            let gaps: [MeetingTranscriptCoverageGap]?
        }
        let data = (try? encoder.encode(Snapshot(title: session.title, language: session.languageCode,
                                                startedAt: session.startedAt, endedAt: session.endedAt,
                                                turns: turns(for: session), gaps: session.transcriptCoverageGaps))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func chunks(_ turns: [PichiMeetingSummaryTurn], maximumCharacters: Int = 8000) -> [[PichiMeetingSummaryTurn]] {
        let limit = max(1000, maximumCharacters)
        var chunks: [[PichiMeetingSummaryTurn]] = []
        var current: [PichiMeetingSummaryTurn] = []
        var size = 0
        for turn in turns {
            // A single long edited turn must also fit. Keep the original ID for citations.
            var remaining = turn.text[...]
            while !remaining.isEmpty {
                let overhead = turn.speaker.count + 160
                let length = min(remaining.count, max(1, limit - overhead))
                let end = remaining.index(remaining.startIndex, offsetBy: length)
                let part = String(remaining[..<end])
                let cost = part.count + overhead
                if !current.isEmpty, size + cost > limit {
                    chunks.append(current)
                    current = []
                    size = 0
                }
                current.append(.init(id: turn.id, seconds: turn.seconds, speaker: turn.speaker, text: part))
                size += cost
                remaining = remaining[end...]
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    /// Recovery must not create new fragments with the same source identity/time.
    /// Ledger reconciliation accepts only strictly later sources, so tied-time and
    /// repeated-ID groups remain atomic. Choose the safe cut nearest half the cost.
    static func recoveryParts(_ turns: [PichiMeetingSummaryTurn]) -> [[PichiMeetingSummaryTurn]]? {
        guard turns.count > 1 else { return nil }
        let costs = turns.map { $0.text.count + $0.speaker.count + 160 }
        let size = costs.reduce(0, +)
        guard size > 1000 else { return nil }
        var prefixCost = 0
        var bestCut: Int?
        var bestDistance = Int.max
        for cut in 1..<turns.count {
            prefixCost += costs[cut - 1]
            guard turns[cut - 1].seconds < turns[cut].seconds,
                  Set(turns[..<cut].map(\.id)).isDisjoint(with: Set(turns[cut...].map(\.id)))
            else { continue }
            let distance = abs(size - 2 * prefixCost)
            if distance < bestDistance { bestCut = cut; bestDistance = distance }
        }
        guard let cut = bestCut else { return nil }
        return [Array(turns[..<cut]), Array(turns[cut...])]
    }

    /// Bound structured citation choices to short, literal excerpts. Splitting at
    /// word boundaries preserves every source character without rewriting speech.
    static func evidenceChoices(_ turns: [PichiMeetingSummaryTurn], maximumCharacters: Int = 400) -> [PichiMeetingSummaryEvidence] {
        let limit = max(1, min(500, maximumCharacters))
        var choices: [PichiMeetingSummaryEvidence] = []
        for turn in turns {
            var remaining = turn.text[...]
            while !remaining.isEmpty {
                var end = remaining.index(remaining.startIndex, offsetBy: min(limit, remaining.count))
                if end != remaining.endIndex,
                   let boundary = remaining[..<end].lastIndex(where: \.isWhitespace), boundary != remaining.startIndex {
                    end = remaining.index(after: boundary)
                }
                let quote = String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !quote.isEmpty { choices.append(.init(segmentID: turn.id, quote: quote)) }
                remaining = remaining[end...]
            }
        }
        // Repeated passages remain separate chronological occurrences in the
        // request. Dropping a repeated agreement could erase reinstatement.
        return choices
    }
}

/// Per-attempt resource limits and protocol settings. Longer work remains sequential;
/// opting in does not enable reasoning on a model that has no configured support.
nonisolated struct PichiMeetingSummaryExecution: Sendable, Equatable {
    let contextTokens: Int
    let outputTokens: Int
    let requestSeconds: TimeInterval
    let attemptSeconds: TimeInterval
    var reasoningParameter: String? = nil
    var reasoningValue: String? = nil

    static let standard = Self(contextTokens: 8192, outputTokens: 3000, requestSeconds: 180, attemptSeconds: 600)
    static let extended = Self(contextTokens: 16384, outputTokens: 8192, requestSeconds: 900, attemptSeconds: 3600)

    var identity: String {
        "\(self.contextTokens)|\(self.outputTokens)|\(self.requestSeconds)|\(self.attemptSeconds)|\(self.reasoningParameter ?? "")|\(self.reasoningValue ?? "")"
    }

    func validate() throws {
        guard (8192...16384).contains(self.contextTokens), (1...8192).contains(self.outputTokens),
              self.outputTokens < self.contextTokens,
              self.requestSeconds.isFinite, self.attemptSeconds.isFinite,
              self.requestSeconds > 0, self.requestSeconds <= self.attemptSeconds,
              self.attemptSeconds <= 3600,
              (self.reasoningParameter == nil) == (self.reasoningValue == nil)
        else { throw PichiMeetingSummaryError.notConfigured }
        if let parameter = self.reasoningParameter, let value = self.reasoningValue {
            guard ["think", "thinking", "enable_thinking", "reasoning_effort"].contains(parameter),
                  !value.isEmpty, value.count <= 32
            else { throw PichiMeetingSummaryError.notConfigured }
        }
    }
}

nonisolated enum PichiMeetingSummaryError: LocalizedError {
    case notConfigured, localEndpointRequired, insecureEndpoint, unsupportedProvider, emptyTranscript, invalidOutput, invalidEvidence, tooManyChunks, outputLimit, timeLimit
    var errorDescription: String? {
        switch self {
        case .notConfigured: PichiLocalization.text("Choose an installed model and configure its API endpoint before generating a summary.")
        case .localEndpointRequired: PichiLocalization.text("Local mode requires a localhost endpoint. To use a server, select the configured AI provider.")
        case .insecureEndpoint: PichiLocalization.text("Remote summaries require an HTTPS endpoint.")
        case .unsupportedProvider: PichiLocalization.text("Choose an OpenAI-compatible provider in AI Enhancement settings, such as Ollama, LM Studio or OpenRouter.")
        case .emptyTranscript: PichiLocalization.text("This meeting has no completed transcript to summarize.")
        case .invalidOutput: PichiLocalization.text("The model did not return a valid structured summary. Try a different model. The transcript is safe.")
        case .outputLimit: PichiLocalization.text("The model reached the output limit before completing the structured summary. Try turning off thinking or choosing the extended processing budget. The transcript and previous summary are safe.")
        case .invalidEvidence: PichiLocalization.text("The model returned an unsupported source, owner or date. The result was rejected. The transcript is safe.")
        case .timeLimit: PichiLocalization.text("The summary time limit was reached. The transcript and previous summary are safe.")
        case .tooManyChunks: PichiLocalization.text("This transcript is too large to summarize in one operation.")
        }
    }
}


nonisolated struct PichiMeetingSummaryArtifact: Codable, Sendable {
    let version: Int
    let transcriptHash: String
    let configurationIdentity: String
    let generatedAt: Date
    let document: PichiMeetingSummaryDocument
    var baseConfigurationIdentity: String? = nil
    var modelArtifactID: String? = nil

    /// Shared read boundary for the UI and read-only helper. Credentials and
    /// live model discovery are not needed to check source/currentness validity.
    func validated(for session: MeetingSession) throws -> Self {
        guard self.version == 6, self.transcriptHash == PichiMeetingSummaryInput.fingerprint(session) else {
            throw PichiMeetingSummaryError.invalidOutput
        }
        return Self(version: self.version, transcriptHash: self.transcriptHash,
                    configurationIdentity: self.configurationIdentity, generatedAt: self.generatedAt,
                    document: try self.document.validated(against: PichiMeetingSummaryInput.turns(for: session)),
                    baseConfigurationIdentity: self.baseConfigurationIdentity, modelArtifactID: self.modelArtifactID)
    }
}

extension PichiMeetingSummaryDocument {
    /// Assemble readable Markdown from canonical structured fields. Source text
    /// remains literal when rendered; escaped punctuation cannot create links/HTML.
    nonisolated func copyMarkdown(language: PichiInterfaceLanguage, bundle: Bundle = .main, sources: [PichiMeetingSummaryTurn] = []) -> String {
        func literal(_ value: String) -> String {
            value.reduce(into: "") { result, character in
                // Escaping ':' also prevents Foundation's URL scanner from
                // swallowing subsequent literal escapes in a URL or HTML tag.
                if "\\`*_{}[]()#+-.!|><&:".contains(character) { result.append("\\") }
                result.append(character)
            }
        }
        let sections: [(String, [PichiMeetingSummaryItem], Bool)] = [
            ("Recap", self.summary, false), ("Decisions", self.decisions, false),
            ("Action items", self.actions, true), ("Questions and answers", self.openQuestions, false),
        ]
        return sections.map { key, items, actions in
            "## " + literal(PichiLocalization.text(key, language: language, bundle: bundle)) + "\n\n" + items.map { item in
                var lines: [String] = []
                if actions, let title = item.title { lines.append("### " + literal(title)) }
                let marker = (item.superseded == true ? PichiLocalization.text(item.status == .completed ? "[Completed later] " : "[Superseded] ", language: language, bundle: bundle) : "")
                    + (item.resolved == true ? PichiLocalization.text("[Answered] ", language: language, bundle: bundle) : "")
                lines.append(literal(marker + item.text))
                if actions {
                    if item.superseded != true {
                        let status = item.status.map { PichiLocalization.format("Status: %@", language: language, bundle: bundle,
                            arguments: [$0.text(language: language, bundle: bundle)]) }
                            ?? PichiLocalization.text("Task status not specified", language: language, bundle: bundle)
                        lines.append("- " + literal(status))
                    }
                    let urgency = item.urgency.flatMap { urgency in urgency == .unspecified ? nil
                        : PichiLocalization.format("Urgency: %@", language: language, bundle: bundle,
                            arguments: [urgency.text(language: language, bundle: bundle)]) }
                        ?? PichiMeetingSummaryActionUrgency.unspecified.text(language: language, bundle: bundle)
                    lines.append("- " + literal(urgency))
                }
                if let owner = item.owner { lines.append("- " + literal(PichiLocalization.text("Owner: ", language: language, bundle: bundle) + owner)) }
                if let deadline = item.deadline { lines.append("- " + literal(PichiLocalization.text("Due: ", language: language, bundle: bundle) + deadline)) }
                for evidence in item.evidence {
                    if let turn = sources.first(where: { $0.id == evidence.segmentID }), turn.seconds.isFinite, turn.seconds < Double(Int.max) {
                        let seconds = Int(max(0, turn.seconds))
                        lines.append("> " + literal("\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(turn.speaker)"))
                    }
                    lines.append(evidence.quote.components(separatedBy: .newlines).map { "> " + literal($0) }.joined(separator: "\n"))
                }
                return lines.joined(separator: "\n\n")
            }.joined(separator: "\n\n")
        }.joined(separator: "\n\n")
    }

    /// Localize export chrome for the requested output language; all model/source data stays verbatim.
    nonisolated func copyText(language: PichiInterfaceLanguage, bundle: Bundle = .main) -> String {
        let sections: [(String, [PichiMeetingSummaryItem])] = [
            ("Recap", self.summary), ("Decisions", self.decisions),
            ("Action items", self.actions), ("Questions and answers", self.openQuestions),
        ]
        return sections.map { key, items in
            PichiLocalization.text(key, language: language, bundle: bundle) + "\n" + items.map { item in
                "- " + (item.superseded == true ? PichiLocalization.text("[Superseded] ", language: language, bundle: bundle) : "")
                    + (item.resolved == true ? PichiLocalization.text("[Answered] ", language: language, bundle: bundle) : "")
                    + item.text + (item.owner.map { " (\($0))" } ?? "") + (item.deadline.map { " [\($0)]" } ?? "")
                    + "\n" + item.evidence.map { "  > \($0.quote)" }.joined(separator: "\n")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
