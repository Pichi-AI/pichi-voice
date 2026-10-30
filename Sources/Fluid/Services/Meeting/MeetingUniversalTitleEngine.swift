import Foundation

/// Deterministic universal titles, ported from the frozen strict_safety benchmark.
/// This engine only classifies the current transcript. Duration admission, persistence,
/// interface localization and user-edited-title ownership stay with the caller.
nonisolated enum MeetingUniversalTitleEngine {
    static let algorithmVersion = "universal-strict-safety-v1"
    static let maximumTextUTF8Bytes = 16 * 1_024 * 1_024
    static let maximumTurns = 100_000
    static let maximumTurnTextUTF8Bytes = 32 * 1_024 * 1_024
    static let maximumSpeakerLabels = 4_096

    enum SpeakerEvidence: Sendable {
        /// ASR clusters and display labels do not prove distinct human participants.
        case unverified
        /// Independently attributed human identities, as in the evaluated Fathom metadata.
        case identifiedPeople
    }

    struct Turn: Sendable {
        let speaker: String?
        let text: String
        init(speaker: String?, text: String) { self.speaker = speaker; self.text = text }
    }

    struct Input: Sendable {
        let text: String
        let turns: [Turn]
        let speakerEvidence: SpeakerEvidence
        /// Set only for an independently verified exact count, never a cluster count.
        let exactParticipantCount: Int?
        init(text: String, turns: [Turn], speakerEvidence: SpeakerEvidence = .unverified,
             exactParticipantCount: Int? = nil) {
            self.text = text
            self.turns = turns
            self.speakerEvidence = speakerEvidence
            self.exactParticipantCount = exactParticipantCount
        }
    }

    struct Selection: Equatable, Sendable {
        let candidateID: String
        /// Full English source phrase for the existing String Catalog lookup boundary.
        let localizationKey: String
        let formID: String
        let purposeID: String?
        let isGroup: Bool
        let isFallback: Bool
    }

    enum Purpose: String, CaseIterable, Sendable {
        case plans, outcomes, questions, ideas, decisions, tasks, opinions, experience, results, proposals
    }

    struct Feature: Equatable, Sendable {
        let count: Int
        let sections: Int
        var score: Double { Double(self.count) * (1 + Double(self.sections) / 8) }
        var supported: Bool { self.count >= 3 && self.sections >= 2 }
    }

    struct Analysis: Sendable {
        let selection: Selection
        let features: [Purpose: Feature]
        let activeSpeakerLabels: Int
        let resourceLimitExceeded: Bool
    }

    static var catalog: [Selection] { self.candidates.map(\.selection) }

    static func select(_ input: Input) -> Selection { self.analyze(input).selection }

    static func analyze(_ input: Input) -> Analysis {
        func limited() -> Analysis {
            Analysis(selection: self.candidates[0].selection, features: [:], activeSpeakerLabels: 0,
                     resourceLimitExceeded: true)
        }
        guard input.text.utf8.count <= self.maximumTextUTF8Bytes,
              input.turns.count <= self.maximumTurns else { return limited() }
        var speakerWords: [String: Int] = [:]
        var speakerTurns: [String: Int] = [:]
        var turnBytes = 0
        for turn in input.turns {
            let bytes = turn.text.utf8.count
            guard bytes <= self.maximumTurnTextUTF8Bytes - turnBytes else { return limited() }
            turnBytes += bytes
            guard let speaker = turn.speaker else { continue }
            if speakerWords[speaker] == nil && speakerWords.count >= self.maximumSpeakerLabels { return limited() }
            speakerWords[speaker, default: 0] += self.wordRegex.numberOfMatches(in: turn.text,
                range: NSRange(turn.text.startIndex..., in: turn.text))
            speakerTurns[speaker, default: 0] += 1
        }
        let active = speakerWords.reduce(into: 0) { count, element in
            if element.value >= 30 && speakerTurns[element.key, default: 0] >= 2 { count += 1 }
        }
        let trusted = input.speakerEvidence == .identifiedPeople
        var participantClass: ParticipantClass = trusted && active >= 3 ? .group : trusted && active == 2 ? .pair : .unknown
        let lower = input.text.lowercased()
        let scalarLength = max(1, input.text.unicodeScalars.count)
        var features: [Purpose: Feature] = [:]
        for purpose in Purpose.allCases {
            let found = self.scan(self.purposeRegex[purpose]!, in: lower, scalarLength: scalarLength)
            features[purpose] = Feature(count: found.count, sections: found.sections)
        }
        let interaction = self.scan(self.interactionRegex, in: lower, scalarLength: scalarLength, kinds: true)
        let reciprocal = (trusted && active >= 2)
            || (active >= 2 && input.turns.count >= 4 && interaction.distinctKinds >= 3 && interaction.sections >= 2)
        func count(_ regex: NSRegularExpression) -> Int {
            regex.numberOfMatches(in: lower, range: NSRange(lower.startIndex..., in: lower))
        }
        let reflection = count(self.reflectionRegex) >= 3
        let reasoned = count(self.reasonedRegex) >= 3 && reciprocal
        var claims: Set<Claim> = []
        if reciprocal {
            claims.formUnion([.reciprocalConversation, .deliberativeExchange])
            if input.turns.count >= 8 { claims.insert(.sustainedThematicExchange) }
            if trusted { claims.formUnion([.meetingEvent, .meetingDiscussionPurpose]) }
            if features[.opinions]!.supported || features[.experience]!.supported { claims.insert(.mutualSubstantiveExchange) }
        }
        if reasoned { claims.insert(.reasonedPositionsExchange) }
        if participantClass == .pair { claims.insert(.exactlyTwoParticipants) }
        if participantClass == .group { claims.insert(.atLeastThreeSpeakingParticipants) }
        if reflection { claims.insert(.reflectiveReasoning) }
        if count(self.notesRegex) > 0 { claims.insert(.noteCapturePurpose) }
        if count(self.interviewRegex) > 0 { claims.insert(.interviewFormat) }
        if count(self.presentationRegex) >= 2 { claims.insert(.presentationFormat) }
        if count(self.lectureRegex) >= 2 { claims.insert(.lectureFormat) }
        for (purpose, feature) in features where feature.supported { claims.insert(.focus(purpose)) }

        // Preserve the benchmark's candidate order and exact scoring, including stable ties.
        let maximumScore = max(1, features.values.map(\.score).max() ?? 1)
        var best = self.candidates[0]
        var bestScore = -Double.infinity
        for candidate in self.candidates {
            guard candidate.allowed.contains(participantClass), candidate.claims.isSubset(of: claims) else { continue }
            let focusScore = candidate.purpose.map { features[$0]!.score / maximumScore } ?? 0
            let score = 0.55 * focusScore + 0.35 * self.preference(candidate.form) + (candidate.group ? 0.1 : 0)
            if score > bestScore { best = candidate; bestScore = score }
        }
        // The minimal safety repair weakens only the exact-two claim. It intentionally
        // keeps the winning purpose, instead of reranking the entire catalog.
        if input.exactParticipantCount != 2 {
            if participantClass == .pair { participantClass = .unknown }
            if best.form == "dialogue" {
                let replacement = "conversation" + (best.purpose.map { "__" + $0.rawValue } ?? "")
                if let safe = self.candidates.first(where: { $0.id == replacement }) { best = safe }
            }
        }
        return Analysis(selection: best.selection, features: features, activeSpeakerLabels: active,
                        resourceLimitExceeded: false)
    }

    private enum ParticipantClass: Hashable, Sendable { case unknown, solo, pair, group }
    private enum Claim: Hashable, Sendable {
        case reciprocalConversation, sustainedThematicExchange, deliberativeExchange, reasonedPositionsExchange
        case meetingEvent, exactlyTwoParticipants, atLeastThreeSpeakingParticipants, trustedSoloMode, monologicDelivery
        case reflectiveReasoning, noteCapturePurpose, interviewFormat, presentationFormat, lectureFormat
        case mutualSubstantiveExchange, meetingDiscussionPurpose
        case focus(Purpose)
    }
    private struct Candidate: Sendable {
        let id: String
        let key: String
        let form: String
        let purpose: Purpose?
        let group: Bool
        let allowed: Set<ParticipantClass>
        let claims: Set<Claim>
        var selection: Selection {
            Selection(candidateID: self.id, localizationKey: self.key, formID: self.form,
                      purposeID: self.purpose?.rawValue, isGroup: self.group, isFallback: self.id == "recording")
        }
    }

    private static func preference(_ form: String) -> Double {
        switch form {
        case "meeting": return 0.35
        case "conversation": return 0.55
        case "talk": return 0.45
        case "discussion": return 0.8
        case "debate": return 0.7
        case "dialogue": return 0.85
        case "monologue": return 0.7
        case "reflection": return 0.25
        case "notes": return 0.4
        case "interview", "presentation": return 0.75
        case "lecture": return 0.6
        case "exchange": return 0.5
        default: return 0
        }
    }

    private struct Matches { let count: Int; let sections: Int; let distinctKinds: Int }

    /// Enumerate matches without retaining a match array or a UTF-32 copy of the transcript.
    /// Python's benchmark offsets are Unicode scalars, not Swift graphemes or UTF-16 units.
    private static func scan(_ regex: NSRegularExpression, in text: String, scalarLength: Int,
                             kinds: Bool = false) -> Matches {
        var count = 0
        var sectionMask: UInt8 = 0
        var matchedKinds: Set<String> = []
        var previousUTF16 = 0
        var previousScalarOffset = 0
        let utf16 = text.utf16
        var previousIndex = utf16.startIndex
        regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match else { return }
            let start = utf16.index(previousIndex, offsetBy: match.range.location - previousUTF16)
            if let from = previousIndex.samePosition(in: text.unicodeScalars),
               let to = start.samePosition(in: text.unicodeScalars) {
                previousScalarOffset += text.unicodeScalars[from..<to].count
            }
            previousUTF16 = match.range.location
            previousIndex = start
            let section = min(7, 8 * previousScalarOffset / scalarLength)
            sectionMask |= UInt8(1 << section)
            count += 1
            // Only the >= 3 predicate is consumed; retain at most three cue strings.
            if kinds && matchedKinds.count < 3, let range = Range(match.range, in: text) {
                matchedKinds.insert(String(text[range]))
            }
        }
        return Matches(count: count, sections: sectionMask.nonzeroBitCount, distinctKinds: matchedKinds.count)
    }

    // ICU's default \w includes combining marks, unlike Python's str regex. Spell out
    // Python's Unicode letters/numbers/underscore and its matching word boundaries.
    private static func regex(_ pattern: String) -> NSRegularExpression {
        let word = #"[\p{L}\p{N}_]"#
        let boundary = "(?:(?<=\(word))(?!\(word))|(?<!\(word))(?=\(word)))"
        let normalized = pattern.replacingOccurrences(of: #"\b"#, with: boundary)
            .replacingOccurrences(of: #"\w"#, with: word)
        guard let compiled = try? NSRegularExpression(pattern: normalized) else {
            preconditionFailure("Invalid built-in meeting title cue")
        }
        return compiled
    }

    private static let wordRegex = Self.regex(#"\w+"#)
    private static let purposeRegex: [Purpose: NSRegularExpression] = [
        .plans: Self.regex(#"\bплан(?:ы|а|у|ом|е|ов|ам|ами|ах)?\b|\bпланир(?:ую|уем|уете|уют|ует|овать|овал|овали|овала|овани(?:е|я|ю|ем|и))\b|\bбудем\b|\bсобираемся\b|\bзавтра\b|\bnext week\b|\bplan\w*"#),
        .outcomes: Self.regex(#"\bитог\w*|\bза прошл\w*|\bза прошедш\w*|\blast week\b|\bsummar\w*"#),
        .questions: Self.regex(#"\bвопрос\w*|\bпочему\b|\bчто такое\b|\bподскаж\w*|\bquestion\w*"#),
        .ideas: Self.regex(#"\bиде(?:я|и|ю|ей|е|ям|ями|ях)\b|\bвариант\w*|\bпридум\w*|\bчто если\b|\bidea\w*|\bwhat if\b"#),
        .decisions: Self.regex(#"\bрешени\w*|\bрешить\b|\bвыбрать\b|\bвыбор\w*|\bdecision\w*|\bdecide\w*"#),
        .tasks: Self.regex(#"\bзадач\w*|\bпоруч\w*|\bответствен\w*|\bназнач\w*|\btask\w*|\baction item\w*"#),
        .opinions: Self.regex(#"\bмнение\w*|\bсчитаю\b|\bточк\w* зрения\b|\bна мой взгляд\b|\bopinion\w*|\bpoint of view\b"#),
        .experience: Self.regex(#"\bопыт\w*|\bпрактик(?:а|и|у|е|ой|ами|ах)\b|\bкогда я\b|\bу нас было\b|\bexperience\w*|\bi used to\b"#),
        .results: Self.regex(#"\bрезультат\w*|\bполучилось\b|\bсделали\b|\bдостиг\w*|\bresult\w*|\bcompleted\b"#),
        .proposals: Self.regex(#"\bпредлаг\w*|\bпредлож\w*|\bможно попробовать\b|\bдавайте попробуем\b|\bsuggest\w*|\bpropos\w*"#)
    ]
    private static let interactionRegex = Self.regex(#"слушай|согласен|ты говорил|ты говоришь|давай|что ты|а ты|you mean|i agree|what do you think|let me answer|that.s right"#)
    private static let reflectionRegex = Self.regex(#"я думаю|думаю|может быть|не знаю|сомнев|i think|maybe|not sure"#)
    private static let reasonedRegex = Self.regex(#"не соглас|с другой стороны|возраж|i disagree|however"#)
    private static let notesRegex = Self.regex(#"запишу себе|заметка для себя|note to self|record my thoughts"#)
    private static let interviewRegex = Self.regex(#"начнем собеседование|начнём собеседование|это интервью|start the interview"#)
    private static let presentationRegex = Self.regex(#"сейчас представлю|покажу презентацию|let me present|i will present"#)
    private static let lectureRegex = Self.regex(#"сегодня на лекции|сегодня на занятии|today.s lecture"#)

    private static let candidates: [Candidate] = [
        .init(id: "recording", key: "Audio recording", form: "recording", purpose: nil, group: false, allowed: [.unknown, .solo, .pair, .group], claims: []),
        .init(id: "meeting", key: "Meeting", form: "meeting", purpose: nil, group: false, allowed: [.unknown, .pair, .group], claims: [.meetingEvent]),
        .init(id: "meeting__plans", key: "Meeting to discuss plans", form: "meeting", purpose: .plans, group: false, allowed: [.unknown, .pair, .group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.plans)]),
        .init(id: "meeting__tasks", key: "Meeting to discuss tasks", form: "meeting", purpose: .tasks, group: false, allowed: [.unknown, .pair, .group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.tasks)]),
        .init(id: "meeting__results", key: "Meeting to discuss results", form: "meeting", purpose: .results, group: false, allowed: [.unknown, .pair, .group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.results)]),
        .init(id: "meeting__proposals", key: "Meeting to discuss proposals", form: "meeting", purpose: .proposals, group: false, allowed: [.unknown, .pair, .group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.proposals)]),
        .init(id: "conversation", key: "Conversation", form: "conversation", purpose: nil, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation]),
        .init(id: "conversation__plans", key: "Conversation about plans", form: "conversation", purpose: .plans, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.plans)]),
        .init(id: "conversation__outcomes", key: "Conversation about outcomes", form: "conversation", purpose: .outcomes, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.outcomes)]),
        .init(id: "conversation__ideas", key: "Conversation about ideas", form: "conversation", purpose: .ideas, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.ideas)]),
        .init(id: "conversation__decisions", key: "Conversation about decisions", form: "conversation", purpose: .decisions, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.decisions)]),
        .init(id: "conversation__tasks", key: "Conversation about tasks", form: "conversation", purpose: .tasks, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.tasks)]),
        .init(id: "conversation__experience", key: "Conversation about experience", form: "conversation", purpose: .experience, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.experience)]),
        .init(id: "conversation__results", key: "Conversation about results", form: "conversation", purpose: .results, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.results)]),
        .init(id: "conversation__proposals", key: "Conversation about proposals", form: "conversation", purpose: .proposals, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .focus(.proposals)]),
        .init(id: "talk", key: "Talk", form: "talk", purpose: nil, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .sustainedThematicExchange]),
        .init(id: "talk__plans", key: "Talk about plans", form: "talk", purpose: .plans, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .sustainedThematicExchange, .focus(.plans)]),
        .init(id: "talk__outcomes", key: "Talk about outcomes", form: "talk", purpose: .outcomes, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .sustainedThematicExchange, .focus(.outcomes)]),
        .init(id: "talk__ideas", key: "Talk about ideas", form: "talk", purpose: .ideas, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .sustainedThematicExchange, .focus(.ideas)]),
        .init(id: "talk__experience", key: "Talk about experience", form: "talk", purpose: .experience, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .sustainedThematicExchange, .focus(.experience)]),
        .init(id: "talk__proposals", key: "Talk about proposals", form: "talk", purpose: .proposals, group: false, allowed: [.unknown, .pair, .group], claims: [.reciprocalConversation, .sustainedThematicExchange, .focus(.proposals)]),
        .init(id: "discussion", key: "Discussion", form: "discussion", purpose: nil, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange]),
        .init(id: "discussion__plans", key: "Discussion of plans", form: "discussion", purpose: .plans, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.plans)]),
        .init(id: "discussion__outcomes", key: "Discussion of outcomes", form: "discussion", purpose: .outcomes, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.outcomes)]),
        .init(id: "discussion__questions", key: "Discussion of questions", form: "discussion", purpose: .questions, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.questions)]),
        .init(id: "discussion__ideas", key: "Discussion of ideas", form: "discussion", purpose: .ideas, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.ideas)]),
        .init(id: "discussion__decisions", key: "Discussion of decisions", form: "discussion", purpose: .decisions, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.decisions)]),
        .init(id: "discussion__tasks", key: "Discussion of tasks", form: "discussion", purpose: .tasks, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.tasks)]),
        .init(id: "discussion__opinions", key: "Discussion of opinions", form: "discussion", purpose: .opinions, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.opinions)]),
        .init(id: "discussion__experience", key: "Discussion of experience", form: "discussion", purpose: .experience, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.experience)]),
        .init(id: "discussion__results", key: "Discussion of results", form: "discussion", purpose: .results, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.results)]),
        .init(id: "discussion__proposals", key: "Discussion of proposals", form: "discussion", purpose: .proposals, group: false, allowed: [.unknown, .pair, .group], claims: [.deliberativeExchange, .focus(.proposals)]),
        .init(id: "debate", key: "Debate", form: "debate", purpose: nil, group: false, allowed: [.unknown, .pair, .group], claims: [.reasonedPositionsExchange]),
        .init(id: "debate__ideas", key: "Debate on ideas", form: "debate", purpose: .ideas, group: false, allowed: [.unknown, .pair, .group], claims: [.reasonedPositionsExchange, .focus(.ideas)]),
        .init(id: "debate__decisions", key: "Debate on decisions", form: "debate", purpose: .decisions, group: false, allowed: [.unknown, .pair, .group], claims: [.reasonedPositionsExchange, .focus(.decisions)]),
        .init(id: "debate__results", key: "Debate on results", form: "debate", purpose: .results, group: false, allowed: [.unknown, .pair, .group], claims: [.reasonedPositionsExchange, .focus(.results)]),
        .init(id: "debate__proposals", key: "Debate on proposals", form: "debate", purpose: .proposals, group: false, allowed: [.unknown, .pair, .group], claims: [.reasonedPositionsExchange, .focus(.proposals)]),
        .init(id: "dialogue", key: "Dialogue", form: "dialogue", purpose: nil, group: false, allowed: [.pair], claims: [.reciprocalConversation, .exactlyTwoParticipants]),
        .init(id: "dialogue__plans", key: "Dialogue about plans", form: "dialogue", purpose: .plans, group: false, allowed: [.pair], claims: [.reciprocalConversation, .exactlyTwoParticipants, .focus(.plans)]),
        .init(id: "dialogue__ideas", key: "Dialogue about ideas", form: "dialogue", purpose: .ideas, group: false, allowed: [.pair], claims: [.reciprocalConversation, .exactlyTwoParticipants, .focus(.ideas)]),
        .init(id: "dialogue__decisions", key: "Dialogue about decisions", form: "dialogue", purpose: .decisions, group: false, allowed: [.pair], claims: [.reciprocalConversation, .exactlyTwoParticipants, .focus(.decisions)]),
        .init(id: "dialogue__experience", key: "Dialogue about experience", form: "dialogue", purpose: .experience, group: false, allowed: [.pair], claims: [.reciprocalConversation, .exactlyTwoParticipants, .focus(.experience)]),
        .init(id: "monologue", key: "Monologue", form: "monologue", purpose: nil, group: false, allowed: [.solo], claims: [.monologicDelivery, .trustedSoloMode]),
        .init(id: "monologue__plans", key: "Monologue about plans", form: "monologue", purpose: .plans, group: false, allowed: [.solo], claims: [.monologicDelivery, .trustedSoloMode, .focus(.plans)]),
        .init(id: "monologue__ideas", key: "Monologue about ideas", form: "monologue", purpose: .ideas, group: false, allowed: [.solo], claims: [.monologicDelivery, .trustedSoloMode, .focus(.ideas)]),
        .init(id: "monologue__experience", key: "Monologue about experience", form: "monologue", purpose: .experience, group: false, allowed: [.solo], claims: [.monologicDelivery, .trustedSoloMode, .focus(.experience)]),
        .init(id: "reflection", key: "Reflections", form: "reflection", purpose: nil, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning]),
        .init(id: "reflection__plans", key: "Reflections about plans", form: "reflection", purpose: .plans, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.plans)]),
        .init(id: "reflection__outcomes", key: "Reflections about outcomes", form: "reflection", purpose: .outcomes, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.outcomes)]),
        .init(id: "reflection__questions", key: "Reflections about questions", form: "reflection", purpose: .questions, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.questions)]),
        .init(id: "reflection__ideas", key: "Reflections about ideas", form: "reflection", purpose: .ideas, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.ideas)]),
        .init(id: "reflection__decisions", key: "Reflections about decisions", form: "reflection", purpose: .decisions, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.decisions)]),
        .init(id: "reflection__tasks", key: "Reflections about tasks", form: "reflection", purpose: .tasks, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.tasks)]),
        .init(id: "reflection__experience", key: "Reflections about experience", form: "reflection", purpose: .experience, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.experience)]),
        .init(id: "reflection__results", key: "Reflections about results", form: "reflection", purpose: .results, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.results)]),
        .init(id: "reflection__proposals", key: "Reflections about proposals", form: "reflection", purpose: .proposals, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.reflectiveReasoning, .focus(.proposals)]),
        .init(id: "notes", key: "Notes", form: "notes", purpose: nil, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose]),
        .init(id: "notes__plans", key: "Notes about plans", form: "notes", purpose: .plans, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.plans)]),
        .init(id: "notes__outcomes", key: "Notes about outcomes", form: "notes", purpose: .outcomes, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.outcomes)]),
        .init(id: "notes__ideas", key: "Notes about ideas", form: "notes", purpose: .ideas, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.ideas)]),
        .init(id: "notes__decisions", key: "Notes about decisions", form: "notes", purpose: .decisions, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.decisions)]),
        .init(id: "notes__tasks", key: "Notes about tasks", form: "notes", purpose: .tasks, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.tasks)]),
        .init(id: "notes__experience", key: "Notes about experience", form: "notes", purpose: .experience, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.experience)]),
        .init(id: "notes__results", key: "Notes about results", form: "notes", purpose: .results, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.results)]),
        .init(id: "notes__proposals", key: "Notes about proposals", form: "notes", purpose: .proposals, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.noteCapturePurpose, .focus(.proposals)]),
        .init(id: "interview", key: "Interview", form: "interview", purpose: nil, group: false, allowed: [.unknown, .pair, .group], claims: [.interviewFormat]),
        .init(id: "interview__plans", key: "Interview about plans", form: "interview", purpose: .plans, group: false, allowed: [.unknown, .pair, .group], claims: [.interviewFormat, .focus(.plans)]),
        .init(id: "interview__outcomes", key: "Interview about outcomes", form: "interview", purpose: .outcomes, group: false, allowed: [.unknown, .pair, .group], claims: [.interviewFormat, .focus(.outcomes)]),
        .init(id: "interview__ideas", key: "Interview about ideas", form: "interview", purpose: .ideas, group: false, allowed: [.unknown, .pair, .group], claims: [.interviewFormat, .focus(.ideas)]),
        .init(id: "interview__decisions", key: "Interview about decisions", form: "interview", purpose: .decisions, group: false, allowed: [.unknown, .pair, .group], claims: [.interviewFormat, .focus(.decisions)]),
        .init(id: "interview__experience", key: "Interview about experience", form: "interview", purpose: .experience, group: false, allowed: [.unknown, .pair, .group], claims: [.interviewFormat, .focus(.experience)]),
        .init(id: "presentation", key: "Presentation", form: "presentation", purpose: nil, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat]),
        .init(id: "presentation__plans", key: "Presentation of plans", form: "presentation", purpose: .plans, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.plans)]),
        .init(id: "presentation__outcomes", key: "Presentation of outcomes", form: "presentation", purpose: .outcomes, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.outcomes)]),
        .init(id: "presentation__ideas", key: "Presentation of ideas", form: "presentation", purpose: .ideas, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.ideas)]),
        .init(id: "presentation__decisions", key: "Presentation of decisions", form: "presentation", purpose: .decisions, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.decisions)]),
        .init(id: "presentation__tasks", key: "Presentation of tasks", form: "presentation", purpose: .tasks, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.tasks)]),
        .init(id: "presentation__experience", key: "Presentation of experience", form: "presentation", purpose: .experience, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.experience)]),
        .init(id: "presentation__results", key: "Presentation of results", form: "presentation", purpose: .results, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.results)]),
        .init(id: "presentation__proposals", key: "Presentation of proposals", form: "presentation", purpose: .proposals, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.presentationFormat, .focus(.proposals)]),
        .init(id: "lecture", key: "Lecture", form: "lecture", purpose: nil, group: false, allowed: [.unknown, .solo, .pair, .group], claims: [.lectureFormat]),
        .init(id: "exchange__opinions", key: "Exchange of opinions", form: "exchange", purpose: .opinions, group: false, allowed: [.unknown, .pair, .group], claims: [.mutualSubstantiveExchange, .focus(.opinions)]),
        .init(id: "exchange__experience", key: "Exchange of experience", form: "exchange", purpose: .experience, group: false, allowed: [.unknown, .pair, .group], claims: [.mutualSubstantiveExchange, .focus(.experience)]),
        .init(id: "group__meeting", key: "Group meeting", form: "meeting", purpose: nil, group: true, allowed: [.group], claims: [.meetingEvent, .atLeastThreeSpeakingParticipants]),
        .init(id: "group__meeting__plans", key: "Group meeting to discuss plans", form: "meeting", purpose: .plans, group: true, allowed: [.group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.plans), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__meeting__tasks", key: "Group meeting to discuss tasks", form: "meeting", purpose: .tasks, group: true, allowed: [.group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.tasks), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__meeting__results", key: "Group meeting to discuss results", form: "meeting", purpose: .results, group: true, allowed: [.group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.results), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__meeting__proposals", key: "Group meeting to discuss proposals", form: "meeting", purpose: .proposals, group: true, allowed: [.group], claims: [.meetingEvent, .meetingDiscussionPurpose, .focus(.proposals), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion", key: "Group discussion", form: "discussion", purpose: nil, group: true, allowed: [.group], claims: [.deliberativeExchange, .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__plans", key: "Group discussion of plans", form: "discussion", purpose: .plans, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.plans), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__outcomes", key: "Group discussion of outcomes", form: "discussion", purpose: .outcomes, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.outcomes), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__questions", key: "Group discussion of questions", form: "discussion", purpose: .questions, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.questions), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__ideas", key: "Group discussion of ideas", form: "discussion", purpose: .ideas, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.ideas), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__decisions", key: "Group discussion of decisions", form: "discussion", purpose: .decisions, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.decisions), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__tasks", key: "Group discussion of tasks", form: "discussion", purpose: .tasks, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.tasks), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__opinions", key: "Group discussion of opinions", form: "discussion", purpose: .opinions, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.opinions), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__experience", key: "Group discussion of experience", form: "discussion", purpose: .experience, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.experience), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__results", key: "Group discussion of results", form: "discussion", purpose: .results, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.results), .atLeastThreeSpeakingParticipants]),
        .init(id: "group__discussion__proposals", key: "Group discussion of proposals", form: "discussion", purpose: .proposals, group: true, allowed: [.group], claims: [.deliberativeExchange, .focus(.proposals), .atLeastThreeSpeakingParticipants]),
    ]
}
