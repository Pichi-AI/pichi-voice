import Foundation
import CryptoKit

@main
struct SensitiveTopicClassifierTests {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { fatalError("artifact, cases and output paths required") }
        let artifactURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: artifactURL)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let selected = SensitiveTopicClassifierSnapshot.supportedTopicIDs
        let classifier = try SensitiveTopicClassifierSnapshot.load(artifactURL: artifactURL, expectedSHA256: digest, selectedTopicIDs: selected)
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1
        }
        func fails(_ expected: SensitiveTopicClassifierError, _ block: () throws -> Void) {
            do { try block(); preconditionFailure("expected \(expected)") }
            catch { check(error as? SensitiveTopicClassifierError == expected, "wrong error \(error)") }
        }
        check(classifier.artifactSHA256 == digest, "frozen digest")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("topic-artifact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let link = temporary.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: artifactURL)
        fails(.invalidArtifact) { _ = try SensitiveTopicClassifierSnapshot.readArtifact(at: link) }
        fails(.invalidArtifact) { _ = try SensitiveTopicClassifierSnapshot.readArtifact(at: temporary) }
        let oversized = temporary.appendingPathComponent("oversized.json")
        try Data(repeating: 0, count: SensitiveTopicClassifierSnapshot.maximumArtifactBytes + 1).write(to: oversized)
        fails(.invalidArtifact) { _ = try SensitiveTopicClassifierSnapshot.readArtifact(at: oversized) }
        check(classifier.identity.contains("commercial-metrics,illicit-remuneration,procurement-collusion"), "sorted immutable topic selection")
        fails(.checksumMismatch) {
            _ = try SensitiveTopicClassifierSnapshot(data: data, expectedSHA256: String(repeating: "0", count: 64), selectedTopicIDs: selected)
        }
        fails(.unsupportedTopic) {
            _ = try SensitiveTopicClassifierSnapshot(data: data, expectedSHA256: digest, selectedTopicIDs: ["unknown"])
        }
        let metadata = try SensitiveTopicClassifierSnapshot(data: data, expectedSHA256: digest, selectedTopicIDs: [])
        check(metadata.availableTopicIDs == selected, "metadata import permits no selected topics")
        var malformed = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        malformed["dimensions"] = 1000
        let malformedBytes = try JSONSerialization.data(withJSONObject: malformed)
        let malformedSHA = SHA256.hash(data: malformedBytes).map { String(format: "%02x", $0) }.joined()
        fails(.invalidArtifact) {
            _ = try SensitiveTopicClassifierSnapshot(data: malformedBytes, expectedSHA256: malformedSHA, selectedTopicIDs: selected)
        }
        let incomplete = "Привет. Обсудим детали"
        let provisional = try classifier.detect(in: incomplete, complete: false)
        check(provisional.safeUTF16 == "Привет.".utf16.count, "hold entire undecided tail")
        check(try classifier.detect(in: incomplete, complete: true).safeUTF16 == incomplete.utf16.count, "final tail admitted after classification")
        check(try classifier.detect(in: "Без точки", complete: false).safeUTF16 == 0, "no punctuation means no provisional publication")
        check(try classifier.detect(in: "10.5 процента", complete: false).safeUTF16 == 0, "decimal point is not sentence boundary")
        check(try SensitiveTopicClassifierSnapshot.completedPrefixUTF16(in: "Один\nдва") == 0, "ASR newline is not a semantic boundary")
        check(try SensitiveTopicClassifierSnapshot.completedPrefixUTF16(in: "т.е. сообщение") == 0, "abbreviations stay behind publication")
        let sensitive = "🙂 За решение вопроса посредник попросил личное вознаграждение."
        let redactions = try classifier.detect(in: sensitive, complete: true)
        check(!redactions.spans.isEmpty, "native actual learned-model positive")
        check(redactions.spans.first?.range == NSRange(location: 0, length: sensitive.utf16.count), "original UTF16 including emoji")
        // The unterminated last sentence is classified like any other when an earlier sentence exists.
        let trailingSentence = String(sensitive[sensitive.startIndex...]).trimmingCharacters(in: CharacterSet(charactersIn: " .!?"))
        let trailing = "Привет всем. " + trailingSentence
        let trailingRedactions = try classifier.detect(in: trailing, complete: true)
        check(trailingRedactions.spans.contains { NSMaxRange($0.range) == trailing.utf16.count }, "final unterminated sentence is classified")
        let technical = try classifier.detect(in: "Откат обновления восстановил работу сервера.", complete: true)
        check(technical.spans.isEmpty, "technical rollback negative")
        fails(.sentenceTooLong) {
            _ = try classifier.detect(in: String(repeating: "я", count: 2049), complete: false)
        }
        fails(.inputTooLong) {
            _ = try classifier.detect(in: String(repeating: "я", count: 65537), complete: true)
        }

        let casesURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let cases = try String(contentsOf: casesURL, encoding: .utf8).split(separator: "\n")
        var results: [[String: Any]] = []
        var durations: [Double] = []
        for line in cases {
            let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
            let text = row["text"] as! String
            let start = ContinuousClock.now
            let result = try classifier.detect(in: text, complete: true)
            let elapsed = start.duration(to: .now).components
            durations.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            var scores: [String: Double] = [:]
            for decision in result.decisions { scores[decision.topicID] = max(scores[decision.topicID] ?? 0, decision.score) }
            results.append(["id": row["id"]!, "scores": scores,
                            "spans": result.spans.map { ["location": $0.range.location, "length": $0.range.length] },
                            "safeUTF16": result.safeUTF16])
        }
        let report: [String: Any] = ["checks": checks, "artifactSHA256": digest, "predictions": results,
                                      "featureProbes": ["взя́тка Ё Й", "İ Δ² café", "🙂 ОТКАТ_17"].map {
                                          ["text": $0, "indices": SensitiveTopicClassifierSnapshot.features(in: $0, dimensions: 16384).sorted()] as [String: Any]
                                      },
                                      "nativeMilliseconds": ["total": durations.reduce(0, +), "maximum": durations.max() ?? 0,
                                                             "median": durations.sorted()[durations.count / 2]],
                                      "measurementScope": "Mac standalone process; concurrent work may be active; no iPad measurement"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[3]))
        print("Sensitive topic native checks: \(checks); evaluated \(results.count) synthetic inputs")
    }
}
