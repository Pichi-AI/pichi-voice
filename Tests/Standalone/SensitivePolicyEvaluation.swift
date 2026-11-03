import Foundation
import CryptoKit

/// Synthetic-only comparison CLI. Compile this against the actual policy sources;
/// it contains no substitute detector, morphology implementation, or model weights.
@main
struct SensitivePolicyEvaluation {
    struct Corpus: Decodable {
        let schemaVersion: Int
        let id: String
        let policyDefinition: String
        let evaluationNotes: [String]
        let cases: [Case]
    }
    struct Case: Codable {
        let id: String
        let enabledGroupIDs: [String]
        let text: String
        let expectedTopicMatch: Bool
        let goldMaskSubstrings: [String]
        let tags: [String]
        let rationale: String
    }
    struct Span: Codable { let location: Int; let length: Int }
    struct Result: Codable {
        let method: String
        let status: String
        let classifierSupported: Bool
        let output: String?
        let spans: [Span]
        let preparationMilliseconds: Double
        let warmMilliseconds: [Double]
        let error: String?
    }
    struct Row: Codable { let input: Case; let results: [Result] }
    struct Report: Codable {
        let schemaVersion: Int
        let revision: String
        let corpusID: String
        let corpusSHA256: String
        let artifactSHA256: String
        let policyDefinition: String
        let notes: [String]
        let seeds: [String: [String]]
        let rows: [Row]
    }
    enum Failure: Error { case usage, invalidCorpus, invalidSpan }
    static let seeds: [String: [String]] = [
        "illicit-remuneration": ["взятка", "откат"],
        "procurement-collusion": ["картель", "сговор"],
        "commercial-metrics": ["маржа", "себестоимость"],
        "planned-transactions": ["сделка", "инвестиция"],
        "employee-compensation": ["зарплата", "бонус"],
        "personal-health": ["диагноз", "болезнь"],
    ]
    static func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 6 else { throw Failure.usage }
        // corpus.json artifact.json artifact-sha256 output.json tested-revision
        let corpusURL = URL(fileURLWithPath: args[1])
        let corpusData = try Data(contentsOf: corpusURL)
        guard corpusData.count <= 2_097_152 else { throw Failure.invalidCorpus }
        let corpus = try JSONDecoder().decode(Corpus.self, from: corpusData)
        guard corpus.schemaVersion == 1, !corpus.cases.isEmpty, corpus.cases.count <= 1_000,
              Set(corpus.cases.map(\.id)).count == corpus.cases.count,
              corpus.cases.allSatisfy({ !$0.enabledGroupIDs.isEmpty && $0.text.utf16.count <= 65_536
                  && $0.enabledGroupIDs.allSatisfy({ seeds[$0] != nil })
                  && $0.goldMaskSubstrings.allSatisfy({ $0.isEmpty == false }) }) else { throw Failure.invalidCorpus }
        let artifactURL = URL(fileURLWithPath: args[2])
        let metadata = try SensitiveTopicClassifierSnapshot.load(artifactURL: artifactURL,
            expectedSHA256: args[3], selectedTopicIDs: [])
        var rows: [Row] = []
        for item in corpus.cases {
            let selected = Set(item.enabledGroupIDs)
            let supported = selected.isSubset(of: metadata.availableTopicIDs)
            var results: [Result] = []
            for method in ["literal", "wordForms", "groups", "groupsAndClassifier"] {
                let start = DispatchTime.now().uptimeNanoseconds
                var preparation = 0.0
                do {
                    let snapshot: TranscriptSensitiveDictionarySnapshot
                    if method == "literal" || method == "wordForms" {
                        let words = Set(item.enabledGroupIDs.flatMap { seeds[$0] ?? [] }).sorted()
                        snapshot = try .init(entries: words.map { .init(phrase: $0,
                            matchMode: method == "literal" ? .exact : .wordForms) })
                    } else {
                        let classifier: SensitiveTopicClassifierSnapshot? = method == "groupsAndClassifier" && supported
                            ? try .load(artifactURL: artifactURL, expectedSHA256: args[3], selectedTopicIDs: selected) : nil
                        snapshot = try .init(entries: [], selectedGroupIDs: selected, topicClassifier: classifier)
                    }
                    preparation = elapsed(start)
                    var timings: [Double] = []
                    var finalSpans: [TranscriptRedactedSpan] = []
                    for _ in 0..<5 {
                        let clock = DispatchTime.now().uptimeNanoseconds
                        let spans = try snapshot.spans(in: item.text)
                        timings.append(elapsed(clock))
                        finalSpans = try merged(spans, in: item.text)
                    }
                    let output = NSMutableString(string: item.text)
                    for span in finalSpans.reversed() {
                        output.replaceCharacters(in: span.range, with: span.replacement)
                    }
                    results.append(.init(method: method, status: "ok", classifierSupported: supported,
                        output: output as String, spans: finalSpans.map { .init(location: $0.range.location, length: $0.range.length) },
                        preparationMilliseconds: preparation, warmMilliseconds: timings, error: nil))
                } catch {
                    // Failure is explicit and never represented as raw successful output.
                    results.append(.init(method: method, status: "error", classifierSupported: supported,
                        output: nil, spans: [], preparationMilliseconds: preparation == 0 ? elapsed(start) : preparation,
                        warmMilliseconds: [], error: String(describing: error)))
                }
            }
            rows.append(.init(input: item, results: results))
        }
        let report = Report(schemaVersion: 1, revision: args[5], corpusID: corpus.id,
            corpusSHA256: SHA256.hash(data: corpusData).map { String(format: "%02x", $0) }.joined(),
            artifactSHA256: metadata.artifactSHA256, policyDefinition: corpus.policyDefinition,
            notes: corpus.evaluationNotes + [
                "CPU timings were measured on the execution host, not on an iPad. Concurrent workload must be reported separately.",
                "Preparation includes morphology/regex compilation and selected classifier artifact validation. Warm spans timings exclude preparation and rendering.",
                "Literal and word-form stages use the documented small seeds. Group and classifier stages use the selected catalog group.",
                "Unsupported classifier topics explicitly use group rules only and must be excluded from classifier-supported aggregate claims."
            ], seeds: seeds, rows: rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
        print("Wrote \(rows.count) synthetic rows and \(rows.count * 4) method results")
    }
    private static func merged(_ spans: [TranscriptRedactedSpan], in text: String) throws -> [TranscriptRedactedSpan] {
        var result: [TranscriptRedactedSpan] = []
        for span in spans.sorted(by: { $0.range.location < $1.range.location }) {
            guard span.range.location >= 0, span.range.length > 0, NSMaxRange(span.range) <= text.utf16.count,
                  Range(span.range, in: text) != nil else { throw Failure.invalidSpan }
            if let last = result.last, NSIntersectionRange(last.range, span.range).length > 0 {
                result[result.count - 1] = .init(range: NSUnionRange(last.range, span.range), replacement: last.replacement)
            } else { result.append(span) }
        }
        return result
    }
}
