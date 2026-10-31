import Foundation
import CryptoKit

/// Actual production classifier comparison on caller-supplied synthetic text.
/// No model training or mutable defaults are involved. Output remains private to
/// the task until the owner chooses what to publish.
@main
struct SensitiveTopicVersionComparison {
    struct Corpus: Decodable {
        let schemaVersion: Int
        let id: String
        let policyDefinition: String
        let evaluationNotes: [String]
        let cases: [Input]
    }
    struct Input: Codable {
        let id: String
        let selectedTopicIDs: [String]
        let text: String
        let label: String
        let goldMaskSubstrings: [String]
        let tags: [String]
        let rationale: String
        let scenarioFamily: String
    }
    struct Span: Codable { let location: Int; let length: Int }
    struct Decision: Codable { let topicID: String; let location: Int; let length: Int; let score: Double }
    struct Output: Codable {
        let model: String
        let status: String
        let output: String?
        let spans: [Span]
        let decisions: [Decision]
        let safeUTF16: Int?
        let warmMilliseconds: [Double]
        let error: String?
    }
    struct Row: Codable { let input: Input; let results: [Output] }
    struct Control: Codable { let name: String; let status: String; let detail: String }
    struct Report: Codable {
        let schemaVersion: Int
        let revision: String
        let corpusID: String
        let corpusSHA256: String
        let artifactSHA256: [String: String]
        let policyDefinition: String
        let notes: [String]
        let loadMilliseconds: [String: [String: Double]]
        let controls: [String: [Control]]
        let rows: [Row]
    }
    enum Failure: Error { case usage, invalidCorpus, invalidOutput, emptyFeatures, invalidMode }
    static func milliseconds(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { throw Failure.usage }
        switch args[1] {
        case "compare":
            // compare CORPUS OLD OLD_SHA NEW NEW_SHA OUTPUT REVISION
            guard args.count == 9 else { throw Failure.usage }
            try compare(corpusPath: args[2], oldPath: args[3], oldSHA: args[4],
                        newPath: args[5], newSHA: args[6], outputPath: args[7], revision: args[8])
        case "footprint":
            // footprint ARTIFACT SHA REVISION
            guard args.count == 5 else { throw Failure.usage }
            try footprint(path: args[2], sha: args[3], revision: args[4])
        default: throw Failure.invalidMode
        }
    }

    static func compare(corpusPath: String, oldPath: String, oldSHA: String,
                        newPath: String, newSHA: String, outputPath: String, revision: String) throws {
        let corpusData = try Data(contentsOf: URL(fileURLWithPath: corpusPath))
        guard !corpusData.isEmpty, corpusData.count <= 4_194_304 else { throw Failure.invalidCorpus }
        let corpus = try JSONDecoder().decode(Corpus.self, from: corpusData)
        guard corpus.schemaVersion == 1, !corpus.cases.isEmpty, corpus.cases.count <= 2_000,
              Set(corpus.cases.map(\.id)).count == corpus.cases.count,
              corpus.cases.allSatisfy({ item in
                  item.selectedTopicIDs.count == 1 && Set(item.selectedTopicIDs).isSubset(of: SensitiveTopicClassifierSnapshot.supportedTopicIDs)
                  && ["positive", "negative", "ambiguous"].contains(item.label)
                  && !item.text.isEmpty && item.text.utf16.count <= 65_536
                  && (item.label != "positive" || !item.goldMaskSubstrings.isEmpty)
                  && item.goldMaskSubstrings.allSatisfy({ !$0.isEmpty && item.text.contains($0) })
              }) else { throw Failure.invalidCorpus }
        let artifacts = [("old", oldPath, oldSHA), ("new", newPath, newSHA)]
        var snapshots: [String: [String: SensitiveTopicClassifierSnapshot]] = [:]
        var loads: [String: [String: Double]] = [:]
        var controls: [String: [Control]] = [:]
        for (name, path, sha) in artifacts {
            var byTopic: [String: SensitiveTopicClassifierSnapshot] = [:]
            var topicLoads: [String: Double] = [:]
            for topic in SensitiveTopicClassifierSnapshot.supportedTopicIDs.sorted() {
                let start = DispatchTime.now().uptimeNanoseconds
                byTopic[topic] = try .load(artifactURL: URL(fileURLWithPath: path), expectedSHA256: sha,
                                           selectedTopicIDs: [topic])
                topicLoads[topic] = milliseconds(start)
            }
            let snapshot = byTopic.values.first!
            controls[name] = try runControls(snapshot)
            snapshots[name] = byTopic; loads[name] = topicLoads
        }
        var rows: [Row] = []; rows.reserveCapacity(corpus.cases.count)
        for item in corpus.cases {
            var results: [Output] = []
            for (name, _, _) in artifacts {
                let snapshot = snapshots[name]![item.selectedTopicIDs[0]]!
                do {
                    var elapsed: [Double] = []; var result: SensitiveTopicDetection?
                    for _ in 0..<3 {
                        let measured: (SensitiveTopicDetection, Double) = try autoreleasepool {
                            let start = DispatchTime.now().uptimeNanoseconds
                            let value = try snapshot.detect(in: item.text, complete: true)
                            return (value, milliseconds(start))
                        }
                        result = measured.0; elapsed.append(measured.1)
                    }
                    let detection = result!
                    var last = 0
                    for span in detection.spans.sorted(by: { $0.range.location < $1.range.location }) {
                        guard span.range.location >= last, span.range.length > 0,
                              NSMaxRange(span.range) <= item.text.utf16.count,
                              Range(span.range, in: item.text) != nil else { throw Failure.invalidOutput }
                        last = NSMaxRange(span.range)
                    }
                    let safe = NSMutableString(string: item.text)
                    for span in detection.spans.sorted(by: { $0.range.location > $1.range.location }) {
                        safe.replaceCharacters(in: span.range, with: span.replacement)
                    }
                    results.append(.init(model: name, status: "ok", output: safe as String,
                        spans: detection.spans.map { .init(location: $0.range.location, length: $0.range.length) },
                        decisions: detection.decisions.map { .init(topicID: $0.topicID, location: $0.range.location,
                                                                   length: $0.range.length, score: $0.score) },
                        safeUTF16: detection.safeUTF16, warmMilliseconds: elapsed, error: nil))
                } catch {
                    results.append(.init(model: name, status: "error", output: nil, spans: [], decisions: [],
                                         safeUTF16: nil, warmMilliseconds: [], error: String(describing: error)))
                }
            }
            rows.append(.init(input: item, results: results))
        }
        let report = Report(schemaVersion: 1, revision: revision, corpusID: corpus.id,
            corpusSHA256: SHA256.hash(data: corpusData).map { String(format: "%02x", $0) }.joined(),
            artifactSHA256: ["old": oldSHA, "new": newSHA], policyDefinition: corpus.policyDefinition,
            notes: corpus.evaluationNotes + [
                "Classifier-only: neither the catalog nor base A1 PII detector is applied. Explicit errors never produce a raw successful output.",
                "Three warm detections per input share a frozen per-topic snapshot. Host timings are not iPad or ASR measurements.",
                "Authored labels are hypotheses, not human adjudication; ambiguous inputs are reported separately."
            ], loadMilliseconds: loads, controls: controls, rows: rows)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        print("Compared \(rows.count) synthetic cases with two classifier snapshots.")
    }

    static func runControls(_ snapshot: SensitiveTopicClassifierSnapshot) throws -> [Control] {
        var result: [Control] = []
        func add(_ name: String, _ body: () throws -> Bool) {
            do { result.append(.init(name: name, status: try body() ? "pass" : "fail", detail: "production detector")) }
            catch { result.append(.init(name: name, status: "fail", detail: String(describing: error))) }
        }
        add("input-length-bound") {
            do { _ = try snapshot.detect(in: String(repeating: "я", count: 65_537), complete: true); return false }
            catch SensitiveTopicClassifierError.inputTooLong { return true }
        }
        add("sentence-length-bound") {
            do { _ = try snapshot.detect(in: String(repeating: "я", count: 2_049), complete: true); return false }
            catch SensitiveTopicClassifierError.sentenceTooLong { return true }
        }
        add("decimal-unsealed") { try snapshot.detect(in: "Сумма 1.5 и далее", complete: false).safeUTF16 == 0 }
        add("newline-unsealed") { try snapshot.detect(in: "Сначала\nпотом", complete: false).safeUTF16 == 0 }
        add("unicode-safe-offset") {
            let text = "🙂 Ёжик обсуждает следующий вопрос."
            let detection = try snapshot.detect(in: text, complete: true)
            return detection.spans.allSatisfy { Range($0.range, in: text) != nil }
                && detection.decisions.allSatisfy { Range($0.range, in: text) != nil }
        }
        add("incomplete-tail-held") {
            let text = "Закончено. Незавершённый разговор"
            return try snapshot.detect(in: text, complete: false).safeUTF16 == "Закончено.".utf16.count
        }
        return result
    }

    static func footprint(path: String, sha: String, revision: String) throws {
        let loadStart = DispatchTime.now().uptimeNanoseconds
        let snapshot: SensitiveTopicClassifierSnapshot = try autoreleasepool {
            try .load(artifactURL: URL(fileURLWithPath: path), expectedSHA256: sha,
                      selectedTopicIDs: SensitiveTopicClassifierSnapshot.supportedTopicIDs)
        }
        let load = milliseconds(loadStart)
        let input = "Подрядчик просил лично ему вернуть процент от заказа. Технический откат обновления прошёл без ошибок. Мы обсудили реальные затраты и прибыль проекта."
        let inputSHA = SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
        let firstStart = DispatchTime.now().uptimeNanoseconds
        let first = try snapshot.detect(in: input, complete: true)
        let firstTime = milliseconds(firstStart)
        var timings: [Double] = []; timings.reserveCapacity(1_000)
        var outputHash = SHA256()
        var masks = 0
        for _ in 0..<1_000 {
            let measurement: (Double, Data, Int) = try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let value = try snapshot.detect(in: input, complete: true)
                let time = milliseconds(start)
                let proof = value.spans.map { "\($0.range.location):\($0.range.length):\($0.replacement)" }.joined(separator: "|")
                return (time, Data(proof.utf8), value.spans.count)
            }
            timings.append(measurement.0); outputHash.update(data: measurement.1); masks += measurement.2
        }
        let payload: [String: Any] = [
            "schemaVersion": 1, "revision": revision, "artifactSHA256": sha,
            "artifactBytes": try Data(contentsOf: URL(fileURLWithPath: path)).count,
            "loadMilliseconds": load, "firstDetectionMilliseconds": firstTime,
            "initialSpanCount": first.spans.count, "warmMilliseconds": timings,
            "iterations": 1_000, "totalSpanCount": masks,
            "outputDigest": outputHash.finalize().map { String(format: "%02x", $0) }.joined(),
            "workloadSHA256": inputSHA, "workloadUTF16": input.utf16.count,
            "limitations": ["One classifier snapshot in a fresh Mac process; peak RSS is externally measured whole-process memory.",
                "One repeated synthetic input measures warm inference, not accuracy, ASR, iPad latency, incremental memory, thermal or battery behavior."]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        withExtendedLifetime(snapshot) {}
    }
}
