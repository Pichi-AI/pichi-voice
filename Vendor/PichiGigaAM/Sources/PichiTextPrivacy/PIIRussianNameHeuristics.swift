import Foundation

/// Pichi Transcribe's first-name/morphology layer, constrained for uncased ASR.
/// Inflected dictionary guesses require a neighboring patronymic/surname or an
/// explicit person context; standalone surname suffixes never mask ordinary
/// lower-case words. This supplements real NER rather than replacing it.
enum PIIRussianNameHeuristics {
    private static let firstNames = Set("""
    александр алексей анатолий андрей антон аркадий арсений артем артём артур богдан борис вадим валентин валерий василий виктор виталий
    владимир владислав всеволод вячеслав геннадий георгий герман глеб григорий даниил данил данила денис дмитрий евгений егор захар иван
    игорь илья иннокентий кирилл константин лев леонид макар максим марк матвей михаил никита николай олег павел петр пётр
    платон роман ростислав руслан святослав семен семён сергей станислав степан тимофей тимур федор фёдор филипп юрий ярослав александра
    алена алёна алина алиса алла анастасия ангелина анна антонина валентина валерия варвара вера вероника виктория галина дарья диана
    евгения екатерина елена елизавета жанна зинаида зоя инна ирина карина кира кристина ксения лариса лидия лилия любовь людмила
    маргарита марина мария милана надежда наталья наталия нина оксана ольга полина раиса регина светлана софия софья тамара татьяна
    ульяна юлия яна саша алёша алеша толя андрюша антоша аркаша сеня артёмка тёма боря вадик валера вася витя
    виталик вова володя слава гена гера гриша даня дима женя егорка ваня гоша илюша кеша костя лёва лёня
    макс марик мотя миша коля олежка паша петя рома руслик сева серёжа сережа стас стёпа тима федя филя
    юра аля алинка настя настенька аня анечка валя лера варя вика галя даша дашенька катя катюша лена леночка
    лиза жанночка ира иришка кристя ксюша лида лиля люба люда рита маша машенька мила надя наташа нина оля
    поля рая света соня тома таня уля юля янка асель айгуль айдар айрат азамат алмаз алия амир аружан
    бахыт гульнара дамир данияр динара жанна зарина ильдар ильнур камиль карим ленар мадина марат нурлан радик рамиль ренат
    рустам самат тимур фарида эльвира эльмира венера айзек исаак иосиф осип эдуард эмиль эльдар давид феликс тарас назар
    остап мирослав савелий елисей аристарх никифор прохор савва арсен армен тигран ашот сурен вардан анаит лусине гаяне сосо
    гиви вахтанг зураб нодар реваз тамаз шота нино манана ираклий леван отар нугзар арина ярослава злата василиса василина
    милена эвелина элина амина аделина ева таисия лея есения агния стефания каролина олеся снежана нелли влада инга элла
    эмма нонна лина лана аида альбина гузель ляйсан жазира айжан айгерим гульмира сауле айнур артемий мирон демид тихон
    трофим гордей добрыня ратмир эмир ильяс рамазан тимерлан ринат рафаэль эльмир нияз искандер алишер бекзат нурсултан ерлан серик
    аскар бауржан талгат ержан ануар олжас санжар павла павлу павлом павле
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))

    private static let ambiguousNames = Set("вера любовь надежда роман марк лев поля лилия мирон света слава".split(separator: " ").map(String.init))
    private static let personTitles = Set("врач доктор профессор пациент пациента пациенту пациентом пациентка представителю представитель коллега коллегой господин госпожа".split(separator: " ").map(String.init))
    private static let nameTriggers = Set("зовут фамилия фамилию фамилии отчество отчеству".split(separator: " ").map(String.init))
    private static let token = try! NSRegularExpression(pattern: "[А-ЯЁа-яё]+")
    private static let patronymic = try! NSRegularExpression(pattern: #"^[а-яё]{2,}(?:(?:ович|евич|ьевич|иевич)(?:а|у|ем|е|и)?|(?:ов|ев|ьев|иев)н(?:а|ы|е|у|ой|ою)|(?:ичн|иничн)(?:а|ы|е|у|ой|ою))$"#)
    private static let surname = try! NSRegularExpression(pattern: #"(?:ов|ев|ёв|ин|ын)(?:а|у|е|ым|ем|ой|ою|ы|ых|ыми)?$|(?:ск|цк)(?:ий|ого|ому|им|ом|ая|ой|ую|ое|ие|их|ими)$|(?:енко|ко|ук|юк|чук|швили|дзе|заде|оглы|ян|янц|ых|их)(?:а|у|ом|е)?$"#)
    private static let adjective = try! NSRegularExpression(pattern: #"(?:ическ|ческ|ийск|ейск|анск|ецк|атск|русск|московск|советск|городск|сельск|детск|женск|мужск|морск|светск|украинск|белорусск|казахск|польск|чешск|финск|шведск|датск|латинск|английск|французск|итальянск|китайск|японск|корейск|петербургск|ленинградск|сибирск|уральск|кавказск|тверск|невск|курск|киевск|минск|смоленск|донск|волжск|дружеск|братск|отцовск|родительск|материнск|октябрьск|заводск|деревенск|крестьянск|славянск|армянск|дворянск|царск|королевск|банковск|рыбацк|казацк|солдатск|воинск)(?:ий|ого|ому|им|ом|ая|ой|ую|ое|ие|их|ими)$"#)

    private struct Word {
        let text: String
        let lower: String
        let range: NSRange
    }

    private static func matching(_ regex: NSRegularExpression, _ word: String) -> Bool {
        regex.firstMatch(in: word, range: NSRange(location: 0, length: word.utf16.count)) != nil
    }

    private static func nameLemma(_ word: String) -> String? {
        guard !blocked.contains(word) else { return nil }
        if firstNames.contains(word) { return word }
        guard word.count >= 4 else { return nil }
        let stem1 = String(word.dropLast())
        let stem2 = String(word.dropLast(2))
        for candidate in [stem1, stem1 + "а", stem1 + "я", stem1 + "й", stem2, stem2 + "а", stem2 + "я"] {
            if candidate.count >= 3 && firstNames.contains(candidate) { return candidate }
        }
        return nil
    }

    private static func surnameLike(_ word: String) -> Bool {
        word.count >= 4 && !blocked.contains(word) && matching(surname, word) && !matching(adjective, word)
    }

    static func hasGivenNameEvidence(_ word: String) -> Bool {
        self.nameLemma(word.lowercased()) != nil
    }

    static func detect(_ text: String) -> [PIIDetection] {
        let source = text as NSString
        let words = token.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let value = source.substring(with: match.range)
            return Word(text: value, lower: value.lowercased(), range: match.range)
        }
        guard !words.isEmpty else { return [] }
        let lemmas = words.map { nameLemma($0.lower) }
        let patronymics = words.map { $0.lower.count >= 7 && !blocked.contains($0.lower) && matching(patronymic, $0.lower) }
        let surnames = words.map { surnameLike($0.lower) }
        var marked = Array(repeating: false, count: words.count)

        func whitespaceBetween(_ a: Int, _ b: Int) -> Bool {
            guard a >= 0, b < words.count, a < b else { return false }
            let gap = source.substring(with: NSRange(location: NSMaxRange(words[a].range), length: words[b].range.location - NSMaxRange(words[a].range)))
            return !gap.isEmpty && gap.allSatisfy { $0.isWhitespace }
        }
        func personContext(_ i: Int) -> Bool {
            guard i > 0, whitespaceBetween(i - 1, i) else { return false }
            return personTitles.contains(words[i - 1].lower) || nameTriggers.contains(words[i - 1].lower)
        }
        for i in words.indices {
            if patronymics[i] { marked[i] = true; continue }
            let adjacentShape = (i > 0 && whitespaceBetween(i - 1, i) && (patronymics[i - 1] || surnames[i - 1])) ||
                (i + 1 < words.count && whitespaceBetween(i, i + 1) && (patronymics[i + 1] || surnames[i + 1]))
            if let lemma = lemmas[i] {
                let exactUnambiguous = firstNames.contains(words[i].lower) && !ambiguousNames.contains(lemma)
                // Exact names retain the original Transcribe behavior. Morphology
                // guesses cannot turn "надо" or "поле" into private names.
                if exactUnambiguous || adjacentShape || personContext(i) { marked[i] = true }
            } else if surnames[i] && personContext(i) { marked[i] = true }
        }
        for _ in 0..<3 {
            for i in words.indices where marked[i] {
                for neighbor in [i - 1, i + 1] where neighbor >= 0 && neighbor < words.count && !marked[neighbor] {
                    let a = min(i, neighbor), b = max(i, neighbor)
                    guard whitespaceBetween(a, b), !blocked.contains(words[neighbor].lower) else { continue }
                    if patronymics[neighbor] || surnames[neighbor] || lemmas[neighbor] != nil { marked[neighbor] = true }
                }
            }
        }
        var entities: [PIIDetection] = []
        var i = 0
        while i < words.count {
            guard marked[i] else { i += 1; continue }
            var last = i
            while last + 1 < words.count && marked[last + 1] && whitespaceBetween(last, last + 1) { last += 1 }
            entities.append(.init(range: NSUnionRange(words[i].range, words[last].range), kind: .person, contextual: false))
            i = last + 1
        }
        return entities
    }

    /// Preview admission is more conservative than durable name precision. A
    /// partial first name or an isolated inflected surname must wait for context.
    /// Reuse this detector's vocabulary/morphology instead of a second name list.
    static func provisionalCandidates(_ text: String, doseQualifiedWords: Set<NSRange> = []) -> [NSRange] {
        let source = text as NSString
        let matches = token.matches(in: text, range: NSRange(location: 0, length: source.length))
        let words = matches.map { source.substring(with: $0.range).lowercased() }
        let shortGrammar = Set("на по за от до из со во не ни но он мы вы ты ее её я и а у о в к с".split(separator: " ").map(String.init))
        let splitEndings = Set("ву ва ве вым вых вич вичу вича вна вну вной ович евич овна евна".split(separator: " ").map(String.init))
        let partialNamePrefixes = words.map { word in
            word.count >= 2 && firstNames.contains(where: { $0.hasPrefix(word) })
        }
        let nameShapes = words.enumerated().map { index, word in
            !blocked.contains(word) && (nameLemma(word) != nil
                || (surnameLike(word) && !doseQualifiedWords.contains(matches[index].range))
                || matching(patronymic, word) || splitEndings.contains(word))
        }
        var result: [NSRange] = []
        for index in words.indices {
            let word = words[index]
            guard !blocked.contains(word), !shortGrammar.contains(word) else { continue }
            // A dictionary prefix is unfinished evidence at the lexical edge or
            // beside another name fragment. Once it is an isolated whole word
            // with an ordinary continuation, it must not freeze every later
            // sentence merely because a longer name starts with those letters.
            let adjacentNameEvidence = [index - 1, index + 1].contains { neighbor in
                words.indices.contains(neighbor) && (nameShapes[neighbor] || partialNamePrefixes[neighbor])
            }
            let personContext = index > 0 && (personTitles.contains(words[index - 1]) || nameTriggers.contains(words[index - 1]))
            let capitalizedCandidate = source.substring(with: matches[index].range).first?.isUppercase == true
            let partialFirstName = partialNamePrefixes[index]
                && (index == words.count - 1 || adjacentNameEvidence || personContext || capitalizedCandidate)
            // An explicit numeric dose and unit can disambiguate surname-shaped
            // medication words. First-name and patronymic evidence still wins.
            let candidate = nameShapes[index] || partialFirstName
            guard candidate else { continue }
            var range = matches[index].range
            if splitEndings.contains(word), index > 0, !blocked.contains(words[index - 1]),
               !shortGrammar.contains(words[index - 1]) {
                range = NSUnionRange(matches[index - 1].range, range)
            }
            result.append(range)
        }
        return result
    }
    private static let blocked = Set("""
    адреналин адресов азов анальгин апельсин армян аспирин багов баян бензин берлин бич близко блин вазелин вариантов ваших величина
    витамин внук вопросов врач всех высоко глубина глубоко годов голова городов господин готов готова готово гражданин громко далеко
    дельфин длина доза доктор документ документов долина долларов домов дофамин дрова других дублин желатин женщина заказов запросов звонков
    звук здоров здорова здорово изъян инструкция инсулин их каких каков какова кальян камин карантин картина керосин кирпич классов
    клиентов клич коммитов компонентов корова королева коротко кофеин крепко крестьян кувшин легко лет лечения лизиноприл логов лук львов
    магазин машина мелатонин мелко месяцев методов метотрексат метров метформин минусов многих много моих молоко моментов москва москвич мужчина
    надо наук наших недалеко немного несколько никаких никотин нов новых номеров облако община объектов огурцов один одних оземпик
    около основ основа остров ответов отзывов пальцев параметров парафин паук пациент пекин пенициллин первых пингвин плохих плюсов поле
    половина представитель причина продуктов проектов протеин профессор процентов процессов псков пунктов раб раз разов редко резко результатов родина
    россия ростов рублей рук самых саратов сахалин своих сервисов середина серотонин сколько славян слов слова снов снова способов
    столько стук таких таков такова таллин тамбов твоих тестов тех тишина товаров токенов только файлов харьков хороших часов
    четко чётко шагов ширина широко штук элементов этих яблоко языков ярко
    """.split(whereSeparator: { $0.isWhitespace }).map(String.init))
}
