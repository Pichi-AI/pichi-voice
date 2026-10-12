import Foundation

@main
struct MeetingSummaryEvidenceTests {
    static func main() throws {
        let id = UUID()
        let source = PichiMeetingSummaryTurn(id: id, seconds: 0, speaker: "Мария",
            text: "Обсудили отчёт. Иван займётся другим проектом к пятнице.")
        let citation = PichiMeetingSummaryEvidence(segmentID: id, quote: "Обсудили отчёт.")
        var document = PichiMeetingSummaryDocument(summary: [.init(text: "Обсудили отчёт.", evidence: [citation])],
            decisions: [], actions: [.init(text: "Уточнить отчёт.", evidence: [citation])], openQuestions: [])
        document.actions[0].owner = "Иван"
        try reject(document, turns: [source], issue: .unsupportedOwner)
        document.actions[0].owner = nil
        document.actions[0].deadline = "к пятнице"
        try reject(document, turns: [source], issue: .unsupportedDeadline)
        document.actions[0].deadline = nil
        _ = try document.validated(against: [source])

        let legacyData = try JSONEncoder().encode(document)
        let legacy = try JSONDecoder().decode(PichiMeetingSummaryDocument.self, from: legacyData).validated(against: [source])
        guard legacy.actions[0].title == nil, legacy.actions[0].status == nil, legacy.actions[0].urgency == nil
        else { throw Failure("Legacy metadata became an inferred task state") }
        do { _ = try PichiMeetingSummaryDocument.decode(String(decoding: legacyData, as: UTF8.self), turns: [source]); throw Failure("Fresh generation accepted missing task metadata as legacy") }
        catch PichiMeetingSummaryError.invalidOutput {}
        document.actions[0].title = "Уточнить отчёт"
        do { _ = try document.validated(against: [source]); throw Failure("Partial task metadata was accepted") }
        catch PichiMeetingSummaryError.invalidOutput {}
        document.actions[0].status = .requested
        document.actions[0].urgency = .unspecified
        _ = try document.validated(against: [source])
        let structured = try PichiMeetingSummaryDocument.decode(String(decoding: JSONEncoder().encode(document), as: UTF8.self), turns: [source])
        guard structured == document else { throw Failure("Structured task metadata did not round trip") }
        let invalidStatus = String(decoding: try JSONEncoder().encode(document), as: UTF8.self)
            .replacingOccurrences(of: "\"requested\"", with: "\"pending\"")
        do { _ = try PichiMeetingSummaryDocument.decode(invalidStatus, turns: [source]); throw Failure("Unknown task status was accepted") }
        catch PichiMeetingSummaryError.invalidOutput {}
        document.summary[0].status = .agreed
        do { _ = try document.validated(against: [source]); throw Failure("Task metadata was accepted on a recap item") }
        catch PichiMeetingSummaryError.invalidOutput {}
        document.summary[0].status = nil
        document.actions[0] = .init(text: "Проверить *поля* и <данные>.", evidence: document.actions[0].evidence,
                                   title: "Уточнить [PX-17]", status: .requested, urgency: .unspecified)
        let markdown = document.copyMarkdown(language: .english, sources: [.init(id: id, seconds: 65, speaker: "Мария [Speaker]", text: source.text)])
        guard markdown.contains("### Уточнить \\[PX\\-17\\]"), markdown.contains("Проверить \\*поля\\* и \\<данные\\>\\."),
              markdown.contains("1\\:05 · Мария \\[Speaker\\]"), markdown.contains("Status\\: Requested"), !markdown.contains(id.uuidString)
        else { throw Failure("Structured Markdown omitted fields, source time or safe literal punctuation") }
        try literalMarkdownRoundTrip(id: id)
        document.actions[0].superseded = true
        guard !document.copyMarkdown(language: .english).contains("Status\\: Requested")
        else { throw Failure("Superseded action retained an advertised current state") }
        document.actions[0].superseded = nil

        let commitment = PichiMeetingSummaryTurn(id: id, seconds: 0, speaker: "Иван, к пятнице", text: "Я подготовлю отчёт.")
        let commitmentEvidence = PichiMeetingSummaryEvidence(segmentID: id, quote: commitment.text)
        document.summary[0].evidence = [commitmentEvidence]
        document.actions[0] = .init(text: "Подготовить отчёт.", evidence: [commitmentEvidence], owner: commitment.speaker)
        _ = try document.validated(against: [commitment])
        document.actions[0].deadline = "к пятнице"
        try reject(document, turns: [commitment], issue: .unsupportedDeadline)

        let sources: [PichiMeetingSummaryTurn] = [
            .init(id: id, seconds: 0, speaker: "Иван", text: "Подготовлю отчёт завтра"),
            .init(id: UUID(), seconds: 1, speaker: "после", text: "обеда обсудим другую тему"),
        ]
        document.summary[0].evidence = [.init(segmentID: id, quote: sources[0].text)]
        document.actions[0] = .init(text: "Подготовить отчёт.", evidence: sources.map { .init(segmentID: $0.id, quote: $0.text) },
                                    deadline: "завтра после обеда")
        try reject(document, turns: sources, issue: .unsupportedDeadline)

        // The selected source itself still supports a literal name and deadline.
        document.actions[0] = .init(text: "Подготовить отчёт.", evidence: [.init(segmentID: id, quote: source.text)],
                                    owner: "Иван", deadline: "к пятнице")
        document.summary[0].evidence = [.init(segmentID: id, quote: source.text)]
        _ = try document.validated(against: [source])

        let text = "Обсуждаем подготовку. " + String(repeating: "Подробности. ", count: 11)
            + "Иван, подготовь отчёт к пятнице. Согласен, подготовлю. "
        let turn = PichiMeetingSummaryTurn(id: id, seconds: 0, speaker: "Мария", text: text)
        let small = PichiMeetingSummaryInput.evidenceChoices([turn], maximumCharacters: 160)
        let choices = PichiMeetingSummaryInput.evidenceChoices([turn])
        guard small.count > choices.count, choices.count == 1,
              choices[0].quote.contains("Иван, подготовь отчёт к пятнице. Согласен, подготовлю."),
              PichiMeetingSummaryInput.normalized(choices.map(\.quote).joined(separator: " ")) == PichiMeetingSummaryInput.normalized(text)
        else { throw Failure("Evidence windows lost source coverage or split the bounded task context") }
        func encodedSize(_ evidence: [PichiMeetingSummaryEvidence]) throws -> Int {
            try JSONEncoder().encode(evidence.enumerated().map { index, item in
                PichiMeetingSummarySource(sourceIndex: index, id: id, seconds: 0, speaker: "Мария", text: item.quote)
            }).count
        }
        guard try encodedSize(choices) < encodedSize(small) else { throw Failure("Repeated source metadata did not shrink") }

        // Adversarial word lengths and Russian graphemes still fit the unchanged
        // extraction window and all source characters remain represented in order.
        for text in [String(repeating: "Ёж сказал: съешь ещё.\n", count: 1200),
                     String(repeating: "а " + String(repeating: "б", count: 399) + " ", count: 80),
                     String(repeating: "Ж", count: 10000)] {
            let long = PichiMeetingSummaryTurn(id: id, seconds: 0, speaker: "Мария", text: text)
            let chunks = PichiMeetingSummaryInput.chunks([long])
            guard chunks.flatMap({ $0 }).map(\.text).joined() == text else { throw Failure("Chunking lost source text") }
            for chunk in chunks {
                let evidence = PichiMeetingSummaryInput.evidenceChoices(chunk)
                guard evidence.count <= 128, evidence.allSatisfy({ !$0.quote.isEmpty && $0.quote.count <= 400 && text.contains($0.quote) }),
                      evidence.map(\.quote).joined().filter({ !$0.isWhitespace })
                        == chunk.map(\.text).joined().filter({ !$0.isWhitespace })
                else { throw Failure("Evidence or context admission bounds regressed") }
            }
        }
        print("Meeting summary evidence checks passed: cited fields, source coverage, admission bounds, legacy/typed task metadata and literal structured Markdown round trips.")
    }

    static func literalMarkdownRoundTrip(id: UUID) throws {
        for quote in [#"<a href="https://example.org">link</a> [x](https://example.org)"#,
                      #"<https://example.org/a?q=1&b=2> &lt;tag&gt; &amp;"#,
                      #"Paths: C:\reports\a.txt and \\server\share; `code`, ``two ` ticks`` and \`literal\`."#,
                      #"**bold** _italic_ ![image](https://example.org/a.png) {x} [ ] # + - . ! | > &"#] {
            let source = PichiMeetingSummaryTurn(id: id, seconds: 65, speaker: "Мария [Speaker]", text: quote)
            let evidence = PichiMeetingSummaryEvidence(segmentID: id, quote: quote)
            let document = PichiMeetingSummaryDocument(summary: [], decisions: [], actions: [
                .init(text: "Проверить *поля* и <данные>.", evidence: [evidence], owner: "Иван [QA]",
                      deadline: "к пятнице", title: "Уточнить [PX-17]", status: .requested, urgency: .unspecified),
            ], openQuestions: [])
            let blocks = CommandMarkdownParser.parse(document.copyMarkdown(language: .english, sources: [source]))
            let quotes: [AttributedString] = blocks.compactMap {
                if case let .quote(text) = $0.content { return text }
                return nil
            }
            guard quotes.map({ String($0.characters) }) == ["1:05 · Мария [Speaker]", quote] else {
                throw Failure("Exported evidence must render verbatim: \(quote); observed: \(quotes.map { String($0.characters) })")
            }
            guard quotes.allSatisfy({ text in text.runs.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil } })
            else { throw Failure("Literal evidence created a link or inline formatting") }
            let headings: [(String, Int)] = blocks.compactMap {
                if case let .heading(text, level) = $0.content { return (String(text.characters), level) }
                return nil
            }
            guard headings.map(\.0) == ["Recap", "Decisions", "Action items", "Уточнить [PX-17]", "Questions and answers"],
                  headings.map(\.1) == [2, 2, 2, 3, 2]
            else { throw Failure("Literal export lost its generated section/task headings") }
            let metadata: [String] = blocks.compactMap {
                if case let .listItem(text, _, _) = $0.content { return String(text.characters) }
                return nil
            }
            guard metadata == ["Status: Requested", "Urgency not specified", "Owner: Иван [QA]", "Due: к пятнице"]
            else { throw Failure("Literal export lost its generated task metadata: \(metadata)") }
            guard blocks.contains(where: {
                if case let .paragraph(text) = $0.content { return String(text.characters) == document.actions[0].text }
                return false
            }) else { throw Failure("Literal export changed task text") }
        }
    }

    static func reject(_ document: PichiMeetingSummaryDocument, turns: [PichiMeetingSummaryTurn], issue: PichiMeetingSummaryValidationIssue) throws {
        do { _ = try document.validated(against: turns) }
        catch let observed as PichiMeetingSummaryValidationIssue {
            guard observed == issue else { throw Failure("Wrong validation reason: \(observed)") }
            return
        }
        throw Failure("Unsupported field was accepted")
    }

    struct Failure: Error { let message: String; init(_ message: String) { self.message = message } }
}
