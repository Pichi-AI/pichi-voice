import Foundation

extension PIIRedactor {
    /// Adapter-approved provisional prefix, derived from the same evaluated NER
    /// and canonical spans. Unfinished fields and recent lexical context are
    /// withheld; this does not change durable detection or certify absence of PII.
    public static func provisionalSafePrefix(in text: String, ner: [PIINERSpan],
                                             redactedSpans: [PIIRedactedSpan]) throws -> Int? {
        guard text.utf16.count <= PIIWordPieceTokenizer.maximumInputUTF16 else { throw TextPrivacyError.inputTooLong }
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let utf16 = Array(text.utf16)
        func valid(_ range: NSRange) -> Bool {
            range.location >= 0 && range.length > 0 && range.location <= source.length
                && range.length <= source.length - range.location
                && (range.location == 0 || !(0xDC00...0xDFFF).contains(utf16[range.location]))
                && (NSMaxRange(range) == source.length || !(0xDC00...0xDFFF).contains(utf16[NSMaxRange(range)]))
        }
        let words = try NSRegularExpression(pattern: #"[\p{L}]+|\p{N}+(?:[.,]\p{N}+)?"#).matches(in: text, range: full)
        guard !words.isEmpty else { return 0 }
        let units = Set("мг мкг мл г mg mcg ml gram grams единиц единицы ед iu".split(separator: " ").map(String.init))
        let quantityUnit = try NSRegularExpression(pattern: Self.quantityUnitPattern, options: [.caseInsensitive])
        // Ambiguous year/count abbreviations are not positive drug evidence.
        let doseUnits = units.subtracting(["г", "ед", "единиц", "единицы"])
        var doseQualifiedWords: Set<NSRange> = []
        for index in words.indices where index + 2 < words.count {
            let quantity = source.substring(with: words[index + 1].range)
            let unit = source.substring(with: words[index + 2].range).lowercased()
            let gap = NSRange(location: NSMaxRange(words[index].range),
                              length: words[index + 1].range.location - NSMaxRange(words[index].range))
            let unitGap = NSRange(location: NSMaxRange(words[index + 1].range),
                                  length: words[index + 2].range.location - NSMaxRange(words[index + 1].range))
            if quantity.first?.isNumber == true, doseUnits.contains(unit),
               source.substring(with: gap).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               source.substring(with: unitGap).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                doseQualifiedWords.insert(words[index].range)
            }
        }
        var limit = source.length
        func retreat(_ location: Int) { limit = min(limit, location) }
        func contains(_ outer: NSRange, _ inner: NSRange) -> Bool {
            outer.location <= inner.location && NSMaxRange(inner) <= NSMaxRange(outer)
        }
        func covered(_ range: NSRange) -> Bool { redactedSpans.contains { contains($0.range, range) } }
        for span in redactedSpans {
            guard valid(span.range) else { throw TextPrivacyError.invalidSpan }
            if let context = span.resolvedContextRange {
                guard valid(context), NSIntersectionRange(context, span.range).length > 0 else {
                    throw TextPrivacyError.invalidSpan
                }
            }
        }
        for span in ner where span.label == "PER" {
            // A candidate dropped by durable precision guards is still unsafe in
            // an unfinished preview, including short and mixed-script fragments.
            guard valid(span.range), span.score.isFinite, (0...1).contains(span.score) else {
                throw TextPrivacyError.invalidSpan
            }
            if !covered(span.range) { retreat(span.range.location) }
        }
        for range in PIIRussianNameHeuristics.provisionalCandidates(text, doseQualifiedWords: doseQualifiedWords)
            where !covered(range) { retreat(range.location) }
        let cuePatterns: [(PIIKind, String)] = [
            (.phone, #"(?:номер\s+)?(?:телефон[а-яё]*|тел\.?|позвон[а-яё]*|мобильн[а-яё]*|phone|call)"#),
            (.card, #"(?:номер\s+)?(?:карта|карты|карту|карточк[а-яё]*|card|cvv)"#),
            (.snils, #"снилс|snils"#), (.inn, #"инн|inn"#), (.passport, #"паспорт[а-яё]*|passport"#),
            (.birthDate, #"дата\s+рождения|день\s+рождения|родил[а-яё]*|birth|birthday|born"#),
            (.address, #"домашн[а-яё]*\s+адрес[а-яё]*|адрес[а-яё]*|address|домашн[а-яё]*|улица|ул\.?|street|дом|д\.?|корпус|корп\.?|к\.|строение|стр\.?|квартира|кв\.?|офис|оф\.?|house|building|apartment|office|suite|floor"#),
            (.email, #"email|e-mail|почт[а-яё]*|mail"#), (.login, #"логин|username|login"#),
            (.secret, #"пароль|password|секретный\s+ключ|api\s+key"#),
            (.account, #"account\s+number"#), (.identifier, #"номер[а-яё]*|document\s+id"#),
            (.person, #"доктор|врач|профессор|пациент[а-яё]*|коллег[а-яё]*|зовут|фамил[а-яё]*|отчеств[а-яё]*|doctor|patient|professor|surname|named|first\s+name"#),
        ]
        var cues: [(PIIKind, NSRange)] = []
        for (kind, pattern) in cuePatterns {
            let regex = try NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])(?:"# + pattern + #")(?![\p{L}\p{N}])"#, options: [.caseInsensitive])
            cues += regex.matches(in: text, range: full).map { (kind, $0.range) }
        }
        // A cue is resolved only by its actual contextual match, or an immediate
        // fully masked value of the same kind. A later unrelated mask is not proof.
        let resolvedCues = cues.compactMap { kind, range -> NSRange? in
            if covered(range) { return range }
            if redactedSpans.contains(where: { span in
                guard span.replacement == kind.placeholder, let context = span.resolvedContextRange,
                      contains(context, range) else { return false }
                // The full match can include unmasked field values (for example
                // a month preceding a year-only DOB capture). Only actual masks
                // and this field's cue words can close its lexical context.
                return words.filter { NSIntersectionRange($0.range, context).length > 0 }.allSatisfy { word in
                    covered(word.range) || cues.contains { $0.0 == kind && contains($0.1, word.range) }
                }
            }) { return range }
            for span in redactedSpans where span.replacement == kind.placeholder && span.range.location >= NSMaxRange(range) {
                let gap = source.substring(with: NSRange(location: NSMaxRange(range), length: span.range.location - NSMaxRange(range)))
                guard gap.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ":=,.-"))).isEmpty else { continue }
                if kind == .person {
                    // A masked first name alone does not close an unknown surname.
                    // Require a source field boundary after the canonical person.
                    let after = source.substring(from: NSMaxRange(span.range)).trimmingCharacters(in: .whitespacesAndNewlines)
                    let nameWords = source.substring(with: span.range).split(whereSeparator: { $0.isWhitespace }).count
                    guard let boundary = after.first,
                          ".!?;:".contains(boundary) || (boundary == "," && nameWords >= 2) else { continue }
                }
                return range
            }
            return nil
        }
        for (_, range) in cues where !resolvedCues.contains(where: { contains($0, range) }) { retreat(range.location) }
        // Literal/spoken email fragments can span many words. Once email syntax
        // appears, withhold the preceding unfinished sentence too, not just '@'.
        // A token boundary and possessive components avoid rescanning/backtracking
        // a long punctuation-free lexical token. Numeric decimals are not aliases.
        let email = try NSRegularExpression(pattern: #"@|(?<![\p{L}\p{N}])(?:собака|собачка|sobaka|sobachka|точка|dot|at|дефис|нижнее\s+подч[её]ркивание|hyphen|underscore)(?![\p{L}\p{N}])|(?<![\p{L}\p{N}_%+-])[\p{L}\p{N}_%+-]++\.[\p{L}\p{N}_%+-]++"#, options: [.caseInsensitive])
        for match in email.matches(in: text, range: full) {
            if covered(match.range) { continue }
            let marker = source.substring(with: match.range)
            guard marker == "@" || marker.contains(where: { $0.isLetter }) else { continue }
            let preceding = source.substring(to: match.range.location)
            let boundary = preceding.range(of: #"[.!?;]\s+"#, options: [.regularExpression, .backwards])
            retreat(boundary.map { NSMaxRange(NSRange($0, in: preceding)) } ?? 0)
        }
        let spokenNumbers = Set("ноль нуль один одна одно два две три четыре пять шесть семь восемь девять десять eleven twelve zero one two three four five six seven eight nine ten".split(separator: " ").map(String.init))
        let numberWord = try NSRegularExpression(pattern: #"^(?:ноля|нуля|одного|одной|одним|одну|двух|двум|двумя|трех|трёх|трем|трём|тремя|четырех|четырёх|четырем|четырём|четырьмя|пяти|пятью|шести|шестью|семи|семью|восьми|восемью|девяти|девятью|десяти|десятью|одиннадцать|двенадцать|тринадцать|четырнадцать|пятнадцать|шестнадцать|семнадцать|восемнадцать|девятнадцать|двадцать|тридцать|сорок|пятьдесят|шестьдесят|семьдесят|восемьдесят|девяносто|сто|ста|двести|триста|четыреста|пятьсот|шестьсот|семьсот|восемьсот|девятьсот|тысяча|тысячи|тысяч|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand)$"#, options: [.caseInsensitive])
        let shortGrammar = Set("я и а у о в к с i we he it an".split(separator: " ").map(String.init))
        let englishSentenceStarts = Set("a an the this that these those i we you they he she it today now hello".split(separator: " ").map(String.init))
        for index in words.indices {
            if covered(words[index].range) || resolvedCues.contains(where: { contains($0, words[index].range) }) { continue }
            let word = source.substring(with: words[index].range)
            let lower = word.lowercased()
            if spokenNumbers.contains(lower) || numberWord.firstMatch(in: word, range: NSRange(location: 0, length: word.utf16.count)) != nil {
                retreat(words[index].range.location)
            }
            if word.first?.isNumber == true {
                let suffix = source.substring(from: NSMaxRange(words[index].range))
                let quantity = (index + 1 < words.count && units.contains(source.substring(with: words[index + 1].range).lowercased()))
                    || quantityUnit.firstMatch(in: suffix, range: NSRange(location: 0, length: suffix.utf16.count)) != nil
                if !quantity {
                    // A preceding street/month/local-part word may already be
                    // private before a numeric continuation supplies its syntax.
                    let preceding = source.substring(to: words[index].range.location)
                    let boundary = preceding.range(of: #"[.!?;]\s+"#, options: [.regularExpression, .backwards])
                    retreat(boundary.map { NSMaxRange(NSRange($0, in: preceding)) } ?? 0)
                }
            }
            // Initials and capitalized noninitial English names are candidate
            // evidence even when the Russian news classifier returns O.
            let capitalizedLatin = word.first?.isUppercase == true && word.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
            let markedInitial = word.count == 1 && word.first?.isUppercase == true
                && NSMaxRange(words[index].range) < source.length
                && source.substring(with: NSRange(location: NSMaxRange(words[index].range), length: 1)) == "."
            if markedInitial || (!shortGrammar.contains(lower) &&
               (word.count == 1 && word.first?.isUppercase == true
                || (capitalizedLatin && !(index == 0 && englishSentenceStarts.contains(lower))))) {
                retreat(words[index].range.location)
                if capitalizedLatin, index > 0 {
                    let previous = source.substring(with: words[index - 1].range)
                    if !covered(words[index - 1].range), previous.first?.isUppercase == true,
                       previous.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil {
                        retreat(words[index - 1].range.location)
                    }
                }
            }
        }
        // Keep a bounded unfinished edge even without recognized syntax. A
        // completed sentence can show earlier words but never its final token.
        let closedSentence = text.trimmingCharacters(in: .whitespacesAndNewlines).last.map { ".!?".contains($0) } ?? false
        let heldWords = closedSentence ? 1 : 4
        retreat(words[max(0, words.count - heldWords)].range.location)
        // Do not show a numeric quantity while its unit is still at the edge.
        for index in words.indices where index + 1 < words.count {
            if covered(words[index].range) { continue }
            if source.substring(with: words[index].range).first?.isNumber == true,
               units.contains(source.substring(with: words[index + 1].range).lowercased()),
               words[index].range.location < limit, NSMaxRange(words[index + 1].range) > limit {
                retreat(words[index].range.location)
            }
        }
        // Replacement spans are atomic even when the lexical edge falls inside
        // a fully resolved entity. Its raw prefix must never reach projection.
        for span in redactedSpans where span.range.location < limit && NSMaxRange(span.range) > limit {
            retreat(span.range.location)
        }
        let prefix = source.substring(to: limit).replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        guard prefix.contains(where: { $0.isLetter }) else { return 0 }
        return prefix.utf16.count
    }
}
