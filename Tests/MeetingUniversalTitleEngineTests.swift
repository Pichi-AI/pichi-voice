import Foundation

@main
struct MeetingUniversalTitleEngineTests {
    typealias Engine = MeetingUniversalTitleEngine
    static func main() throws {
        if CommandLine.arguments.contains("--classify-json-lines") { try self.classifyLines(); return }
        var checks = 0
        func check(_ value: Bool, _ description: String) {
            precondition(value, description)
            checks += 1
        }
        func attributedTurns(_ people: Int) -> [Engine.Turn] {
            (0..<(people * 2)).map { index in
                Engine.Turn(speaker: "synthetic-\(index % people)", text: String(repeating: "word ", count: 30))
            }
        }
        let catalog = Engine.catalog
        check(catalog.count == 99 && Set(catalog.map(\.candidateID)).count == 99, "The frozen catalog has 99 distinct candidates")
        check(Set(catalog.map(\.localizationKey)).count == 99, "Every full source phrase identifies one candidate")
        check(catalog.first?.candidateID == "recording" && catalog.first?.localizationKey == "Audio recording", "The fallback keeps its source key")
        check(Engine.select(.init(text: "", turns: [])).isFallback, "Empty text is neutral")
        let falseCues = Engine.analyze(.init(text: "планшет идеально идет практически планшеты идеальный практический", turns: []))
        check(falseCues.features[.plans]?.count == 0, "Tablet words do not imply plans")
        check(falseCues.features[.ideas]?.count == 0, "Unrelated Russian prefixes do not imply ideas")
        check(falseCues.features[.experience]?.count == 0, "Practical adjectives do not imply experience")
        let exactCues = Engine.analyze(.init(text: "план планы планами планируем планирование идея идеями практика практикой", turns: []))
        check(exactCues.features[.plans]?.count == 5, "Accepted Russian plan inflections match the frozen rules")
        check(exactCues.features[.ideas]?.count == 2 && exactCues.features[.experience]?.count == 2, "Idea and practice inflections match")
        let ideas = String(repeating: "идея " + String(repeating: "neutral ", count: 20), count: 8)
        let pair = attributedTurns(2)
        let unverified = Engine.analyze(.init(text: ideas, turns: pair))
        check(unverified.activeSpeakerLabels == 2 && unverified.selection.isFallback, "Two ASR labels alone do not prove conversation")
        let identified = Engine.select(.init(text: ideas, turns: pair, speakerEvidence: .identifiedPeople))
        check(identified.candidateID == "conversation__ideas", "Unverified exact count weakens dialogue without changing purpose")
        let exactPair = Engine.select(.init(text: ideas, turns: pair, speakerEvidence: .identifiedPeople, exactParticipantCount: 2))
        check(exactPair.candidateID == "dialogue__ideas", "Only independently verified exact pairs retain dialogue")
        let groups = Engine.select(.init(text: ideas, turns: attributedTurns(3), speakerEvidence: .identifiedPeople))
        check(groups.candidateID == "group__discussion__ideas" && groups.isGroup, "Verified group evidence supports a group modifier")
        let unknown = Engine.analyze(.init(text: ideas, turns: [Engine.Turn(speaker: nil, text: ideas), Engine.Turn(speaker: nil, text: ideas)], speakerEvidence: .identifiedPeople))
        check(unknown.activeSpeakerLabels == 0 && unknown.selection.isFallback, "Unassigned turns never establish participants")
        let interactive = "слушай согласен давай " + String(repeating: "neutral ", count: 40) + " а ты " + ideas
        let native = Engine.select(.init(text: interactive, turns: pair))
        check(native.candidateID == "discussion__ideas" && !native.isGroup, "Distributed reciprocal cues support discussion without asserting a count")
        let clustered = "план план план " + String(repeating: "neutral ", count: 100)
        let clusteredAnalysis = Engine.analyze(.init(text: clustered, turns: pair, speakerEvidence: .identifiedPeople))
        check(clusteredAnalysis.features[.plans]?.supported == false, "One isolated cluster cannot establish a whole-recording focus")
        let tie = String(repeating: "план идея " + String(repeating: "neutral ", count: 20), count: 8)
        check(Engine.select(.init(text: tie, turns: attributedTurns(3), speakerEvidence: .identifiedPeople)).candidateID == "group__discussion__plans", "Equal scores retain frozen catalog order")
        let unicode = Engine.analyze(.init(text: "😀 идея e\u{301} идея Ⅳидея \u{301}идея идея_2", turns: []))
        check(unicode.features[.ideas]?.count == 3, "Python word semantics treat combining marks as separators and Unicode numbers as word characters")
        let oversized = Engine.analyze(.init(text: String(repeating: "x", count: Engine.maximumTextUTF8Bytes + 1), turns: []))
        check(oversized.resourceLimitExceeded && oversized.selection.isFallback, "Oversized input is bounded before regex scans")
        let tooMany = Engine.analyze(.init(text: "", turns: Array(repeating: .init(speaker: nil, text: ""), count: Engine.maximumTurns + 1)))
        check(tooMany.resourceLimitExceeded, "Pathological turn counts are bounded")
        let labels = (0...Engine.maximumSpeakerLabels).map { Engine.Turn(speaker: "synthetic-\($0)", text: "word") }
        check(Engine.analyze(.init(text: "", turns: labels)).resourceLimitExceeded, "Pathological label maps are bounded")
        check(Engine.select(.init(text: ideas, turns: pair, speakerEvidence: .identifiedPeople)) == identified, "Repeated calls remain deterministic")
        print("Meeting universal title engine: \(checks) checks passed")
    }

    /// Optional private replay input is supplied externally and never bundled into the tests.
    private struct ReplayRecord: Decodable {
        let id: String
        let text: String
        let turns: [ReplayTurn]
        let identifiedPeople: Bool
        let exactParticipantCount: Int?
    }
    private struct ReplayTurn: Decodable { let speaker: String?; let text: String }
    private struct ReplayFeature: Encodable { let count: Int; let sections: Int; let score: Double; let supported: Bool }
    private struct ReplayResult: Encodable {
        let id: String
        let candidateID: String
        let localizationKey: String
        let activeSpeakerLabels: Int
        let resourceLimitExceeded: Bool
        let features: [String: ReplayFeature]
    }
    private static func classifyLines() throws {
        let decoder = JSONDecoder(); let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        while let line = readLine() {
            let record = try decoder.decode(ReplayRecord.self, from: Data(line.utf8))
            let result = Engine.analyze(.init(text: record.text,
                turns: record.turns.map { .init(speaker: $0.speaker, text: $0.text) },
                speakerEvidence: record.identifiedPeople ? .identifiedPeople : .unverified,
                exactParticipantCount: record.exactParticipantCount))
            let features = Dictionary(uniqueKeysWithValues: result.features.map { key, value in
                (key.rawValue, ReplayFeature(count: value.count, sections: value.sections, score: value.score, supported: value.supported))
            })
            let output = ReplayResult(id: record.id, candidateID: result.selection.candidateID,
                localizationKey: result.selection.localizationKey, activeSpeakerLabels: result.activeSpeakerLabels,
                resourceLimitExceeded: result.resourceLimitExceeded, features: features)
            print(String(decoding: try encoder.encode(output), as: UTF8.self))
        }
    }
}
