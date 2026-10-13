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
}

struct PIIDetection: Sendable {
    var range: NSRange
    let kind: PIIKind
    let contextual: Bool
    var priority: Int { kind.priority + (contextual && [.passport, .snils].contains(kind) ? 2 : 0) }
}

public enum PIIRedactor {
    private static let boundary = #"(?<![\p{L}\p{N}])"#
    private static let end = #"(?![\p{L}\p{N}])"#
    // These are precision guards also present in the Transcribe detector. They
    // are not a name dictionary or a substitute for real token classification.
    private static let nonNames = Set("аспирин инсулин витамин пенициллин анальгин метформин оземпик лизиноприл метотрексат дофамин серотонин адреналин мелатонин кофеин никотин протеин проверь проведи изучите сделай готов хорошо спасибо здравствуйте русский английский".split(separator: " ").map(String.init))

    public static func redact(_ text: String, ner: [PIINERSpan]) throws -> PIIRedactionResult {
        guard text.utf16.count <= PIIWordPieceTokenizer.maximumInputUTF16 else { throw TextPrivacyError.inputTooLong }
        var entities = try structured(text) + PIIRussianNameHeuristics.detect(text)
        let utf16 = Array(text.utf16)
        for span in ner {
            guard span.range.location >= 0, span.range.length > 0,
                  span.range.location <= utf16.count, span.range.length <= utf16.count - span.range.location,
                  validBoundary(span.range.location, utf16), validBoundary(NSMaxRange(span.range), utf16),
                  let range = Range(span.range, in: text), span.score.isFinite, (0...1).contains(span.score) else { throw TextPrivacyError.invalidSpan }
            // News NER supplies persons only. Its LOC/ORG labels must not become
            // an address or drug-removal toggle via translated/UI label matching.
            guard span.label == "PER", span.score >= 0.5 else { continue }
            let value = String(text[range])
            let letters = value.unicodeScalars.filter { CharacterSet.letters.contains($0) }
            guard letters.count >= 3 else { continue }
            let words = value.split(whereSeparator: { $0.isWhitespace }).map { $0.lowercased() }
            guard !words.contains(where: { nonNames.contains($0) }) else { continue }
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
        return .init(text: output, counts: counts, spans: merged.map { .init(range: $0.range, replacement: $0.kind.placeholder) })
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
                entities.append(.init(range: range, kind: kind, contextual: contextual))
            }
        }
        try matches(#"[\p{L}\p{N}._%+-]+@[\p{L}\p{N}.-]+\.[\p{L}]{2,}"#, .email)
        try matches(boundary + #"[\p{L}\p{N}_-]+(?:(?:\.|\s+(?:точка|dot|дефис|нижнее подч[её]ркивание)\s+)[\p{L}\p{N}_-]+|\s+\d+)*[\s.,;]*(?:собака|собачка|sobaka|sobachka|at)[\s.,;]*[\p{L}\p{N}-]+(?:(?:\.|\s+(?:точка|dot)\s+)[\p{L}\p{N}-]+)*(?:\.|\s+(?:точка|dot)\s+)(?:com|net|org|info|biz|dev|app|io|me|su|ru|рф|ком|ру)"# + end, .email)
        try matches(#"(?:\+\s?7|(?<!\d)[78])(?:[\s()-]*\d){10}(?!\d)"#, .phone)
        try matches(#"\+\d{1,3}(?:[\s()-]*\d){8,12}(?!\d)"#, .phone)
        try matches(boundary + #"9(?:[\s()-]*\d){9}(?!\d)"#, .phone)
        try matches(#"(?:телефон[а-яё]*|тел\.?|позвон[а-яё]*|мобильн[а-яё]*|phone|call)\D{0,25}?((?<!\d)\d(?:[ -]?\d){4,6}(?![ -]?\d))"#, .phone, capture: 1, contextual: true)
        try matches(boundary + #"\d{3}-\d{3}-\d{3}[ -]?\d{2}"# + end, .snils, validate: { snilsValid(digits($0)) })
        try matches(#"снилс[^\d\n]{0,25}?((?<!\d)\d(?:[ -]?\d){8,10}(?![ -]?\d))"#, .snils, capture: 1, contextual: true)
        try matches(#"(?:паспорт[а-яё]*|сери[яи]|passport)[^.\n]{0,30}?((?<!\d)\d(?:\s?\d){5,9}(?!\s?\d))"#, .passport, capture: 1, contextual: true)
        try matches(boundary + #"инн[^\d\n]{0,15}(\d{12}|\d{10})"# + end, .inn, capture: 1, contextual: true)
        try matches(boundary + #"(?:\d{12}|\d{10})"# + end, .inn, validate: { innValid(digits($0)) })
        try matches(#"(?:родил[а-яё]*|дата рождения|день рождения|года рождения|г\.р\.|date of birth|born)[^.\n]{0,25}?(\d{1,2}[. /-]\d{1,2}[. /-]\d{2,4}|\d{1,2}\s+[а-яё]+\s+\d{4}|\d{4})(?!\d)"#, .birthDate, capture: 1, contextual: true)
        try matches(boundary + #"(?:\d[ -]?){13,19}"# + end, .card, validate: { luhnValid(digits($0)) })
        try matches(boundary + #"[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}"# + end, .account)
        try matches(#"(?:лицевой сч[её]т|номер сч[её]та|account number|р/с)\D{0,15}?((?<!\d)\d(?:[ -]?\d){9,24}(?![ -]?\d))"#, .account, capture: 1, contextual: true)
        // Context is required: blindly masking every 6-digit number destroys
        // dosages, study counts and product codes in this pharma scenario.
        try matches(#"(?:номер договора|номер полиса|номер документа|идентификатор|policy number|document id)\D{0,15}?([A-Z0-9][A-Z0-9 -]{5,30})"#, .identifier, capture: 1, contextual: true)
        try matches(#"(?:пароль|секретный ключ|password|api key)\s*[:=]?\s*([^\s,;.!?]{4,128})"#, .secret, capture: 1, contextual: true)
        try matches(#"(?:логин|username|login)\s*[:=]?\s*([\p{L}\p{N}_.@-]{3,128})"#, .login, capture: 1, contextual: true)
        try matches(#"(?:адрес проживания|домашний адрес|жив[уёе]т? по адресу|home address)\s*[:=]?\s*([^\n;!?]{5,160})"#, .address, capture: 1, contextual: true)
        return entities
    }

    static func merge(_ candidates: [PIIDetection]) -> [PIIDetection] {
        let ordered = candidates.sorted { $0.range.location < $1.range.location || ($0.range.location == $1.range.location && $0.priority > $1.priority) }
        var result: [PIIDetection] = []
        for entity in ordered {
            if let last = result.last, NSIntersectionRange(last.range, entity.range).length > 0 {
                // Keep the whole union, unlike dropping the lower-priority match:
                // overlapping detection must not expose the unmatched tail.
                let winner = entity.priority > last.priority ? entity : last
                result[result.count - 1] = .init(range: NSUnionRange(last.range, entity.range), kind: winner.kind, contextual: winner.contextual)
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
