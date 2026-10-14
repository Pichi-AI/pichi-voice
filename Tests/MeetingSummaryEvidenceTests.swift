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
        try retainedChangesAndAnswers()
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

    static func retainedChangesAndAnswers() throws {
        let correction = PichiMeetingSummaryTurn(id: UUID(), seconds: 65, speaker: "Синтетический участник А",
            text: #"Предложение <old> отменили. Остаётся https://example.org/api и C:\reports."#)
        let answer = PichiMeetingSummaryTurn(id: UUID(), seconds: 90, speaker: "Синтетический участник Б",
            text: "Проверка каталога завершена: доступно семь записей.")
        let change = PichiMeetingSummaryItem(text: correction.text,
            evidence: [.init(segmentID: correction.id, quote: correction.text)])
        let response = PichiMeetingSummaryItem(text: answer.text,
            evidence: [.init(segmentID: answer.id, quote: answer.text)])
        let sources = [correction, answer]
        var document = PichiMeetingSummaryDocument(summary: [response], decisions: [], actions: [], openQuestions: [],
                                                   changes: [change], answers: [response])
        _ = try document.validated(against: sources)
        let roundTrip = try JSONDecoder().decode(PichiMeetingSummaryDocument.self, from: JSONEncoder().encode(document))
        guard roundTrip == document else { throw Failure("Retained change/answer facts did not round trip") }
        let markdown = document.copyMarkdown(language: .english, sources: sources)
        let blocks = CommandMarkdownParser.parse(markdown)
        let headings: [String] = blocks.compactMap {
            if case let .heading(text, level) = $0.content, level == 2 { return String(text.characters) }
            return nil
        }
        let quotes: [AttributedString] = blocks.compactMap {
            if case let .quote(text) = $0.content { return text }
            return nil
        }
        guard headings.suffix(2) == ["Corrections", "Answers"],
              quotes.contains(where: { String($0.characters) == correction.text }),
              quotes.contains(where: { String($0.characters) == answer.text }),
              quotes.allSatisfy({ $0.runs.allSatisfy { $0.link == nil && $0.inlinePresentationIntent == nil } }),
              !markdown.contains(correction.id.uuidString), !markdown.contains(answer.id.uuidString)
        else { throw Failure("Change/answer Markdown lost literal sources, activated markup or omitted its sections") }
        let text = document.copyText(language: .english)
        guard text.contains("Corrections\n"), text.contains("Answers\n"),
              text.contains(correction.text), text.contains(answer.text)
        else { throw Failure("Plain copy omitted retained change/answer facts or translated source text") }
        // Exercise Foundation's real localized lookup with the current catalog's
        // units, rather than giving the copy methods a test-only translator.
        let catalogURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/Fluid/Localization/Localizable.xcstrings")
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as! [String: Any]
        let strings = catalog["strings"] as! [String: Any]
        let bundleURL = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticSummaryCopy-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        var headingsByLanguage: [PichiInterfaceLanguage: [String]] = [:]
        for language in [PichiInterfaceLanguage.english, .russian] {
            var units: [String: String] = [:]
            for key in ["Corrections", "Answers"] {
                let entry = strings[key] as! [String: Any]
                let locales = entry["localizations"] as! [String: Any]
                let locale = locales[language.rawValue] as! [String: Any]
                units[key] = (locale["stringUnit"] as! [String: Any])["value"] as? String
            }
            headingsByLanguage[language] = [units["Corrections"]!, units["Answers"]!]
            let localeURL = bundleURL.appendingPathComponent("\(language.rawValue).lproj")
            try FileManager.default.createDirectory(at: localeURL, withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: units, format: .binary, options: 0)
                .write(to: localeURL.appendingPathComponent("Localizable.strings"))
        }
        guard let bundle = Bundle(url: bundleURL) else { throw Failure("Synthetic localized copy bundle unavailable") }
        for language in [PichiInterfaceLanguage.english, .russian] {
            let localizedMarkdown = document.copyMarkdown(language: language, bundle: bundle, sources: sources)
            let localizedText = document.copyText(language: language, bundle: bundle)
            for heading in headingsByLanguage[language]! {
                guard localizedMarkdown.contains("## \(heading)"), localizedText.contains("\(heading)\n")
                else { throw Failure("Localized change/answer headers fell back or disappeared") }
            }
            let localizedQuotes = CommandMarkdownParser.parse(localizedMarkdown).compactMap { block -> String? in
                if case let .quote(value) = block.content { return String(value.characters) }
                return nil
            }
            guard localizedQuotes.contains(correction.text), localizedQuotes.contains(answer.text),
                  localizedText.contains(correction.text), localizedText.contains(answer.text)
            else { throw Failure("Interface localization changed source facts or evidence") }
        }
        for empty in [nil, []] as [[PichiMeetingSummaryItem]?] {
            document.changes = empty; document.answers = empty
            let legacyMarkdown = document.copyMarkdown(language: .english)
            let legacyText = document.copyText(language: .english)
            guard !legacyMarkdown.contains("## Corrections"), !legacyMarkdown.contains("## Answers"),
                  !legacyText.contains("Corrections\n"), !legacyText.contains("Answers\n")
            else { throw Failure("Legacy or empty supplemental ledgers created phantom copy sections") }
        }
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
