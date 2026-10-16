import Foundation

/// Stable identifiers and placeholders, carried over from Pichi Transcribe.
/// General dates, organizations, locations, drug names and ordinary numbers are
/// deliberately excluded from this privacy policy.
public enum PIIKind: String, CaseIterable, Sendable, Codable {
    case person = "PER", phone = "PHONE", email = "EMAIL", card = "CARD"
    case passport = "PASSPORT", snils = "SNILS", inn = "INN", birthDate = "DOB"
    case address = "ADDRESS", account = "ACCOUNT", identifier = "NUMBER"
    case login = "LOGIN", secret = "SECRET"
    public var placeholder: String {
        switch self {
        case .person: "[ИМЯ]"
        case .phone: "[ТЕЛЕФОН]"
        case .email: "[EMAIL]"
        case .card: "[КАРТА]"
        case .passport: "[ПАСПОРТ]"
        case .snils: "[СНИЛС]"
        case .inn: "[ИНН]"
        case .birthDate: "[ДАТА_РОЖДЕНИЯ]"
        case .address: "[АДРЕС]"
        case .account: "[СЧЁТ]"
        case .identifier: "[НОМЕР]"
        case .login: "[ЛОГИН]"
        case .secret: "[СЕКРЕТ]"
        }
    }
    var priority: Int {
        switch self {
        case .email, .secret: 9
        case .card, .account: 8
        case .phone: 7
        case .address, .passport, .snils: 6
        case .inn, .birthDate, .login: 5
        case .person: 4
        case .identifier: 1
        }
    }
}

public struct PIIRedactionResult: Sendable, Equatable {
    public let text: String
    public let counts: [PIIKind: Int]
    public let spans: [PIIRedactedSpan]
    // Raw strings and canonical identifiers intentionally do not escape the
    // detector. A checkpoint/export cannot accidentally serialize a recovery map.
}

public struct PIIRedactedSpan: Sendable, Equatable {
    public let range: NSRange
    public let replacement: String
    /// Full source match of a validated contextual field. This is evidence for
    /// its cue only, not permission to publish unmasked words within the context.
    public let resolvedContextRange: NSRange?
    init(range: NSRange, replacement: String, resolvedContextRange: NSRange? = nil) {
        self.range = range; self.replacement = replacement; self.resolvedContextRange = resolvedContextRange
    }
}

struct PIIDetection: Sendable {
    var range: NSRange
    let kind: PIIKind
    let contextual: Bool
    var resolvedContextRange: NSRange? = nil
    var priority: Int { kind.priority + (contextual && [.passport, .snils].contains(kind) ? 2 : 0) }
}

public enum PIIRedactor {
    // Canonical PAN detection and provisional admission must agree on explicit
    // amounts. A currency unit is quantity evidence, not a drug/name qualifier.
    static let quantityUnitPattern = #"^\s*(?:[.,]\d{1,2}\s*)?(?:₽|руб(?:лей|ля|ль)?\.?|доллар(?:ов|а)?|евро|USD|RUB|EUR|мг|мкг|мл|mg|mcg|ml|грамм(?:ов|а)?|килограмм(?:ов|а)?|единиц(?:ы|а)?|шт\.?)(?![\p{L}\p{N}])"#
    static let quantityUnitWords = Set("мг мкг мл г mg mcg ml gram grams единиц единицы ед iu".split(separator: " ").map(String.init))
    static let unambiguousDoseUnitWords = quantityUnitWords.subtracting(["г", "ед", "единиц", "единицы"])
    private static let boundary = #"(?<![\p{L}\p{N}])"#
    private static let end = #"(?![\p{L}\p{N}])"#
    // The same field cue owns durable masks and unfinished-preview admission.
    static let loginCuePattern = #"(?:логин|username|login)(?:\s+(?:для\s+(?:входа|доступа)|в\s+систему))?"#
    static let secretCuePattern = #"(?:пароль|секретный\s+ключ|password|api\s+key)(?:\s+(?:для\s+(?:входа|доступа)|от\s+аккаунта))?"#
    // These are precision guards also present in the Transcribe detector. They
    // are not a name dictionary or a substitute for real token classification.
    private static let nonNames = Set("аспирин инсулин витамин пенициллин анальгин метформин оземпик лизиноприл метотрексат дофамин серотонин адреналин мелатонин кофеин никотин протеин проверь проведи изучите сделай готов хорошо спасибо здравствуйте русский английский".split(separator: " ").map(String.init))

    /// Reuse the existing durable precision guard at the preview boundary too.
    /// A known ordinary word cannot become an unresolved name solely because
    /// the same NER evaluation labels it PER in a longer meeting context.
    static func isKnownNonPersonWord(_ word: String) -> Bool {
        self.nonNames.contains(word.lowercased())
    }

    /// Positive grammatical evidence, not a medication dictionary: exactly one
    /// word explicitly introduced as a drug and immediately qualified by a dose.
    /// Bare quantities and recipient/patient constructions grant no exclusion.
    static func medicationQualifiedWords(in text: String, personRanges: [NSRange]) throws -> Set<NSRange> {
        let source = text as NSString
        let pattern = #"(?<![\p{L}\p{N}])(?:препарат(?:а|у|ом|е|ы|ов|ам|ами|ах)?|лекарств(?:о|а|у|ом|е)|drug|medication|medicine)\s*[:=]?\s+([\p{L}][\p{L}\p{M}'-]{2,63})\s+(\d{1,4}(?:[.,]\d{1,3})?)(?![\d.,])"#
        let medication = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let quantityUnit = try NSRegularExpression(pattern: Self.quantityUnitPattern, options: [.caseInsensitive])
        var qualified: Set<NSRange> = []
        for match in medication.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let wordRange = match.range(at: 1)
            let word = source.substring(with: wordRange)
            guard !PIIRussianNameHeuristics.hasGivenNameEvidence(word),
                  !personRanges.contains(where: { NSIntersectionRange($0, wordRange).length > 0 }) else { continue }
            let amount = source.substring(with: match.range(at: 2)).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(amount), value.isFinite, value > 0 else { continue }
            let suffix = source.substring(from: NSMaxRange(match.range(at: 2)))
            guard let unit = quantityUnit.firstMatch(in: suffix, range: NSRange(location: 0, length: suffix.utf16.count)),
                  Self.unambiguousDoseUnitWords.contains((suffix as NSString).substring(with: unit.range)
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else { continue }
            qualified.insert(wordRange)
        }
        return qualified
    }

    public static func redact(_ text: String, ner: [PIINERSpan]) throws -> PIIRedactionResult {
        guard text.utf16.count <= PIIWordPieceTokenizer.maximumInputUTF16 else { throw TextPrivacyError.inputTooLong }
        var entities = try structured(text) + PIIRussianNameHeuristics.detect(text)
        let medicationWords = try Self.medicationQualifiedWords(in: text,
            personRanges: entities.filter { $0.kind == .person }.map(\.range))
        let utf16 = Array(text.utf16)
        for span in ner {
            guard span.range.location >= 0, span.range.length > 0,
                  span.range.location <= utf16.count, span.range.length <= utf16.count - span.range.location,
                  validBoundary(span.range.location, utf16), validBoundary(NSMaxRange(span.range), utf16),
                  let range = Range(span.range, in: text), span.score.isFinite, (0...1).contains(span.score) else { throw TextPrivacyError.invalidSpan }
            guard span.score >= 0.5 else { continue }
            if span.label != "PER" {
                if let kind = typedKind(for: span, in: text) {
                    entities.append(.init(range: span.range, kind: kind, contextual: false))
                }
                continue
            }
            if medicationWords.contains(span.range) { continue }
            let value = String(text[range])
            let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letters.count >= 3 else { continue }
            let words = value.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
            guard !words.contains(where: self.isKnownNonPersonWord) else { continue }
            if words.count == 1, letters.count < 4, span.score < 0.9 { continue }
            // Mixed alphabets inside one word are common ASR transliteration
            // debris. Separate RU/EN words are still valid mixed-language text.
            if words.contains(where: { word in
                word.range(of: "[A-Za-z]", options: .regularExpression) != nil && word.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil
            }) { continue }
            entities.append(.init(range: span.range, kind: .person, contextual: false))
        }
        let merged = merge(entities)
        var output = ""
        var position = 0
        var counts: [PIIKind: Int] = [:]
        let source = text as NSString
        for entity in merged {
            output += source.substring(with: NSRange(location: position, length: entity.range.location - position))
            output += entity.kind.placeholder
            counts[entity.kind, default: 0] += 1
            position = NSMaxRange(entity.range)
        }
        output += source.substring(from: position)
        return .init(text: output, counts: counts, spans: merged.map {
            .init(range: $0.range, replacement: $0.kind.placeholder, resolvedContextRange: $0.resolvedContextRange)
        })
    }

    private static func structured(_ text: String) throws -> [PIIDetection] {
        var entities: [PIIDetection] = []
        func matches(_ pattern: String, _ kind: PIIKind, capture: Int = 0, contextual: Bool = false,
                     validate: ((String) -> Bool)? = nil) throws {
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let source = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let range = match.range(at: capture)
                guard range.location != NSNotFound, range.length > 0, Range(range, in: text) != nil else { continue }
                if let validate, !validate(source.substring(with: range)) { continue }
                entities.append(.init(range: range, kind: kind, contextual: contextual,
                                      resolvedContextRange: capture > 0 ? match.range : nil))
            }
        }
        try matches(#"[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}"#, .email)
        // Preserve exact ASR offsets rather than reconstructing an address.
        // Spoken separators are permitted only inside a complete email grammar.
        let emailAtom = #"[\p{L}\p{N}_%+-]+"#
        let emailJoin = #"(?:\.|\s+(?:точка|dot|дефис|hyphen|минус|нижнее\s+подч[её]ркивание|underscore|плюс|plus)\s+)"#
        let domainJoin = #"(?:\.|\s+(?:точка|dot)\s+)"#
        try matches(boundary + emailAtom + "(?:" + emailJoin + emailAtom + #"|\s+\d+)*[\s,;]*(?:@|собака|собачка|sobaka|sobachka|at)[\s,;]*[\p{L}\p{N}-]+(?:"# + domainJoin + #"[\p{L}\p{N}-]+)*"# + domainJoin + #"(?:com|net|org|info|biz|dev|app|io|me|su|ru|рф|ком|ру)"# + end, .email)
        try matches(#"(?:\+\s?7|(?<!\d)[78])(?:[\s()-]*\d){10}(?!\d)"#, .phone)
        try matches(#"\+\d{1,3}(?:[\s()-]*\d){8,12}(?!\d)"#, .phone)
        try matches(boundary + #"9(?:[\s()-]*\d){9}(?!\d)"#, .phone)
        try matches(boundary + #"(?:телефон[а-яё]*|тел\.?|позвон[а-яё]*|мобильн[а-яё]*|phone|call)\s*[:=]?\s*((?<!\d)\d(?:[ -]?\d){4,6}(?![ -]?\d))"#, .phone, capture: 1, contextual: true)
        entities += try spokenPhones(in: text)
        try matches(boundary + #"\d{3}-\d{3}-\d{3}[ -]?\d{2}"# + end, .snils, validate: { snilsValid(digits($0)) })
        try matches(#"снилс[^\d]{0,25}?((?<!\d)\d(?:[ -]?\d){8,10}(?![ -]?\d))"#, .snils, capture: 1, contextual: true)
        try matches(#"(?:паспорт[а-яё]*|сери[яи]|passport)[^.]{0,30}?((?<!\d)\d(?:\s?\d){5,9}(?!\s?\d))"#, .passport, capture: 1, contextual: true)
        try matches(boundary + #"инн[^\d]{0,15}(\d{12}|\d{10})"# + end, .inn, capture: 1, contextual: true)
        try matches(boundary + #"(?:\d{12}|\d{10})"# + end, .inn, validate: { innValid(digits($0)) })
        try matches(#"(?:родил[а-яё]*|дата рождения|день рождения|года рождения|г\.р\.|date of birth|born)[^.]{0,25}?(\d{1,2}[. /-]\d{1,2}[. /-]\d{2,4}|\d{1,2}\s+[а-яё]+\s+\d{4}|\d{4})(?!\d)"#, .birthDate, capture: 1, contextual: true)
        entities += try paymentCards(in: text)
        try matches(boundary + #"[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}"# + end, .account)
        try matches(#"(?:лицевой сч[её]т|номер сч[её]та|account number|р/с)\D{0,15}?((?<!\d)\d(?:[ -]?\d){9,24}(?![ -]?\d))"#, .account, capture: 1, contextual: true)
        // Context is required: blindly masking every 6-digit number destroys
        // dosages, study counts and product codes in this pharma scenario.
        try matches(#"(?:номер договора|номер полиса|номер документа|идентификатор|policy number|document id)\D{0,15}?([A-Z0-9][A-Z0-9 -]{5,30})"#, .identifier, capture: 1, contextual: true)
        entities += try credentials(in: text)
        // ASR word units have no reliable sentence boundary. A free-form tail
        // after an address cue would absorb the next drug/dose phrase. Match
        // explicitly marked address fields and stop at the last numbered field.
        // Unmarked/free-form and English addresses require separate detection.
        let addressCue = #"(?:адрес проживания|домашний адрес|жив[уёе]т? по адресу)\s*[:=]?\s*"#
        let addressWord = #"[\p{L}\p{N}][\p{L}\p{N}.'-]*"#
        let city = #"(?:(?:город|г\.)\s+"# + addressWord + #"(?:\s+"# + addressWord + #"){0,2}?\s*,?\s+)?"#
        let street = #"(?:улица|ул\.?|проспект|пр-кт|переулок|пер\.?|проезд|шоссе|бульвар|б-р|набережная|наб\.?|площадь|пл\.?)\s+"#
        let number = #"\d{1,4}(?:[а-яa-z])?(?:[/\-]\d{1,4}[а-яa-z]?)?(?:[кс]\d{1,4}[а-яa-z]?)?(?![\p{L}\p{N}])"#
        let house = #"\s*,?\s*(?:дом|д\.?)\s*№?\s*"# + number
        let building = #"(?:\s*,?\s*(?:корпус|корп\.?|к\.|строение|стр\.?)\s*№?\s*"# + number + #"){0,2}"#
        let unit = #"(?:\s*,?\s*(?:квартира|кв\.?|офис|оф\.?)\s*№?\s*"# + number + #")?"#
        try matches(addressCue + "(" + city + street + addressWord + #"(?:\s+"# + addressWord + #"){0,5}?"# + house + building + unit + ")",
                    .address, capture: 1, contextual: true)
        return entities
    }

    /// Inference adapters supply canonical policy kinds, never a blanket grant
    /// from generic geographic/date labels. Personal fields still require cues.
    private static func typedKind(for span: PIINERSpan, in text: String) -> PIIKind? {
        guard let kind = PIIKind(rawValue: span.label) else { return nil }
        switch kind {
        case .address, .birthDate:
            let source = text as NSString
            var begin = max(0, span.range.location - 100)
            if begin < source.length, (0xDC00...0xDFFF).contains(source.character(at: begin)) { begin += 1 }
            let prefix = source.substring(with: NSRange(location: begin, length: span.range.location - begin))
            let cue = kind == .address
                ? #"(?:домашний\s+адрес|адрес\s+проживания|жив[уёе]т?\s+по\s+адресу|home\s+address)\s*[:=]?\s*$"#
                : #"(?:дата\s+рождения|день\s+рождения|родил[а-яё]*|date\s+of\s+birth|born)\s*[:=]?\s*$"#
            return prefix.range(of: Self.boundary + cue, options: [.regularExpression, .caseInsensitive]) != nil
                ? kind : nil
        default: return kind
        }
    }

    private static func credentials(in text: String) throws -> [PIIDetection] {
        let source = text as NSString
        var result: [PIIDetection] = []
        let prose = Set("нужно надо можно нельзя изменим сменим поменяем обсудим уточним забыли забыть изменить сменить поменять восстановить используется должен должна будет был была для от в не это нужен нужна требуется я мы вы ты он она они его её их сейчас is should must needs required changed reset".split(separator: " ").map(String.init))
        for (kind, cue) in [(PIIKind.login, loginCuePattern), (.secret, secretCuePattern)] {
            // A whole whitespace-delimited token is atomic. Length limits or
            // punctuation exclusions would expose the rest of a secret (A!b).
            let pattern = boundary + "(?:" + cue + ")" + end + #"\s*(?:[:=]\s*|(?:это|is)\s+)?(?:«([^»\n]+)»|"([^"\n]+)"|([^\s«"]+))"#
            let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
                let range = (1...3).map { match.range(at: $0) }.first { $0.location != NSNotFound }!
                let value = source.substring(with: range)
                // Keep placeholders idempotent and avoid ordinary instructions.
                if PIIKind.allCases.contains(where: { value == $0.placeholder }) { continue }
                let word = value.trimmingCharacters(in: .punctuationCharacters).lowercased()
                let prefix = source.substring(with: NSRange(location: match.range.location,
                    length: range.location - match.range.location))
                let explicitlyDelimited = prefix.contains(":") || prefix.contains("=")
                if range == match.range(at: 3), !explicitlyDelimited {
                    // Sentence punctuation attached to the cue is not a value.
                    // Quoted or explicitly delimited punctuation remains valid.
                    if prefix.last?.isWhitespace != true || prose.contains(word) { continue }
                }
                guard kind == .secret || value.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
                result.append(.init(range: range, kind: kind, contextual: true, resolvedContextRange: match.range))
            }
        }
        return result
    }

    private static func spokenPhones(in text: String) throws -> [PIIDetection] {
        // Number words are values only after an immediate phone cue. Do not
        // interpret arbitrary quantities, part numbers or medication doses.
        let values: [String: Int] = ["ноль": 0, "нуль": 0, "один": 1, "одна": 1, "два": 2, "две": 2,
            "три": 3, "четыре": 4, "пять": 5, "шесть": 6, "семь": 7, "восемь": 8, "девять": 9,
            "десять": 10, "одиннадцать": 11, "двенадцать": 12, "тринадцать": 13, "четырнадцать": 14,
            "пятнадцать": 15, "шестнадцать": 16, "семнадцать": 17, "восемнадцать": 18, "девятнадцать": 19,
            "двадцать": 20, "тридцать": 30, "сорок": 40, "пятьдесят": 50, "шестьдесят": 60,
            "семьдесят": 70, "восемьдесят": 80, "девяносто": 90, "сто": 100, "двести": 200,
            "триста": 300, "четыреста": 400, "пятьсот": 500, "шестьсот": 600, "семьсот": 700,
            "восемьсот": 800, "девятьсот": 900]
        let atom = #"(?:\d+|"# + values.keys.sorted { $0.count > $1.count }.joined(separator: "|") + #")(?![\p{L}\p{N}])"#
        let pattern = boundary + #"(?:телефон[а-яё]*|тел\.?|мобильный|phone)(?:\s+(?:для\s+связи|номер))?\s*[:=]?\s*((?:(?:плюс|plus)\s+|\+\s*)?"# + atom + #"(?:[ -]+"# + atom + #")*)"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            let range = match.range(at: 1)
            let tokens = source.substring(with: range).lowercased().split { $0.isWhitespace || $0 == "-" || $0 == "+" }.map(String.init)
            var digits = 0, group: Int? = nil
            func flush() { if let value = group { digits += String(value).count }; group = nil }
            for token in tokens where token != "плюс" && token != "plus" {
                guard let value = values[token] else { flush(); digits += token.count; continue }
                if let current = group, (current >= 100 && current % 100 == 0 && value < 100)
                    || (current >= 20 && current % 10 == 0 && value > 0 && value < 10) {
                    group = current + value
                } else { flush(); group = value }
            }
            flush()
            guard (7...15).contains(digits), tokens.contains(where: { values[$0] != nil || $0 == "плюс" || $0 == "plus" }) else { return nil }
            return .init(range: range, kind: .phone, contextual: true, resolvedContextRange: match.range)
        }
    }

    /// Candidate ends must be actual numeric-group boundaries. A greedy run may
    /// contain a valid 16-digit PAN followed by a separate three-digit amount;
    /// rejecting that 19-digit run must not discard the complete earlier PAN.
    private static func paymentCards(in text: String) throws -> [PIIDetection] {
        let runs = try NSRegularExpression(pattern: boundary + #"\d{1,19}(?:[\s-]+\d{1,19})*"# + end)
        let groups = try NSRegularExpression(pattern: #"\d+"#)
        let amountUnit = try NSRegularExpression(pattern: Self.quantityUnitPattern, options: [.caseInsensitive])
        let source = text as NSString
        var result: [PIIDetection] = []
        for run in runs.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let parts = groups.matches(in: text, range: run.range).map(\.range)
            guard let last = parts.last else { continue }
            let suffix = source.substring(from: NSMaxRange(last))
            let hasAmountUnit = amountUnit.firstMatch(in: suffix, range: NSRange(location: 0, length: suffix.utf16.count)) != nil
            var amountSuffixStart = parts.count
            if hasAmountUnit {
                amountSuffixStart = parts.count - 1
                if last.length == 3 {
                    while amountSuffixStart > 0, parts[amountSuffixStart - 1].length == 3 { amountSuffixStart -= 1 }
                    if amountSuffixStart > 0, (1...2).contains(parts[amountSuffixStart - 1].length) { amountSuffixStart -= 1 }
                }
            }
            var start = 0
            while start < parts.count {
                var candidateDigits: [Int] = []
                var validEnds: [Int] = []
                for finish in start..<parts.count {
                    candidateDigits += digits(source.substring(with: parts[finish]))
                    if candidateDigits.count > 19 { break }
                    if luhnValid(candidateDigits) { validEnds.append(finish) }
                }
                var bestEnd = validEnds.last
                if hasAmountUnit {
                    // A trailing explicit amount unit distinguishes a quantity
                    // from a PAN group, even if PAN + quantity also passes Luhn.
                    // Ungrouped quantities have no three-digit size limit. Grouped
                    // amounts use a short leading group and three-digit groups.
                    // Unmarked ambiguous runs keep the
                    // longest valid boundary candidate instead of guessing.
                    for finish in validEnds where finish + 1 < parts.count && finish + 1 >= amountSuffixStart {
                        bestEnd = finish; break
                    }
                }
                if let finish = bestEnd {
                    result.append(.init(range: NSUnionRange(parts[start], parts[finish]), kind: .card, contextual: false))
                    start = finish + 1
                } else { start += 1 }
            }
        }
        return result
    }

    static func merge(_ candidates: [PIIDetection]) -> [PIIDetection] {
        let ordered = candidates.sorted { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.priority > $1.priority) }
        var result: [PIIDetection] = []
        for entity in ordered {
            if let last = result.last, NSIntersectionRange(last.range, entity.range).length > 0 {
                // Keep the whole union, unlike dropping the lower-priority match:
                // overlapping detection must not expose the unmatched tail.
                let winner = entity.priority > last.priority ? entity : last
                result[result.count - 1] = .init(range: NSUnionRange(last.range, entity.range), kind: winner.kind,
                    contextual: winner.contextual, resolvedContextRange: winner.resolvedContextRange)
            } else { result.append(entity) }
        }
        return result
    }

    private static func digits(_ text: String) -> [Int] { text.compactMap { $0.wholeNumberValue } }
    private static func validBoundary(_ offset: Int, _ utf16: [UInt16]) -> Bool {
        // Range(NSRange,in:) can represent UTF-16 positions inside a surrogate
        // pair. Those are not valid source character offsets for replacement.
        offset == 0 || offset == utf16.count || !(0xDC00...0xDFFF).contains(utf16[offset])
    }
    static func luhnValid(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        let sum = digits.reversed().enumerated().reduce(0) { total, item in
            let value = item.offset % 2 == 1 ? item.element * 2 : item.element
            return total + (value > 9 ? value - 9 : value)
        }
        return sum % 10 == 0
    }
    static func innValid(_ d: [Int]) -> Bool {
        guard Set(d).count > 1 else { return false }
        func check(_ weights: [Int]) -> Int { zip(d, weights).reduce(0) { $0 + $1.0 * $1.1 } % 11 % 10 }
        if d.count == 10 { return check([2,4,10,3,5,9,4,6,8]) == d[9] }
        if d.count == 12 { return check([7,2,4,10,3,5,9,4,6,8]) == d[10] && check([3,7,2,4,10,3,5,9,4,6,8]) == d[11] }
        return false
    }
    static func snilsValid(_ d: [Int]) -> Bool {
        guard d.count == 11, Set(d).count > 1 else { return false }
        let raw = zip(d.prefix(9), (1...9).reversed()).reduce(0) { $0 + $1.0 * $1.1 } % 101
        return (raw == 100 ? 0 : raw) == d[9] * 10 + d[10]
    }
}
