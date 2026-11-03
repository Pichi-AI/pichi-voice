import Foundation
import CryptoKit

/// One frozen production policy per process, for external peak-RSS measurement.
/// Compile with optimized production Swift/C++ sources. Run each mode in a fresh
/// process using the same executable and host, without concurrent expensive jobs.
/// This synthetic text probe does not measure an iPad, microphone, ASR or A1 NER.
@main
struct SensitivePolicyFootprint {
    enum Mode: String, Codable { case literal, wordForms, groups, groupsAndClassifier }
    enum Failure: Error { case usage, invalidMode }
    struct Report: Encodable {
        let schemaVersion: Int
        let revision: String
        let mode: Mode
        let snapshotFingerprint: String
        let artifactSHA256: String?
        let workloadSHA256: String
        let workloadUTF16: Int
        let iterations: Int
        let userSeedCount: Int
        let catalogGroupCount: Int
        let catalogTermCount: Int
        let classifierTopicIDs: [String]
        let preparationMilliseconds: Double
        let firstDetectionMilliseconds: Double
        let warmupSpanCount: Int
        let warmMilliseconds: [Double]
        let totalSpanCount: Int
        let totalMaskedUTF16: Int
        let outputDigest: String
        let limitations: [String]
    }

    static func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    static func main() throws {
        let args = CommandLine.arguments
        // MODE ARTIFACT_PATH ARTIFACT_SHA256 [TESTED_REVISION]
        guard args.count == 4 || args.count == 5 else { throw Failure.usage }
        guard let mode = Mode(rawValue: args[1]) else { throw Failure.invalidMode }
        let groups = Set(SensitiveBusinessGroupCatalog.groups.map(\.id))
        let useGroups = mode == .groups || mode == .groupsAndClassifier
        let topics = mode == .groupsAndClassifier ? SensitiveTopicClassifierSnapshot.supportedTopicIDs : []
        let prepStart = DispatchTime.now().uptimeNanoseconds
        // A single autorelease boundary drops temporary import and compilation
        // objects. The one immutable production snapshot remains alive below.
        let snapshot: TranscriptSensitiveDictionarySnapshot = try autoreleasepool {
            let classifier: SensitiveTopicClassifierSnapshot? = mode == .groupsAndClassifier
                ? try .load(artifactURL: URL(fileURLWithPath: args[2]),
                    expectedSHA256: args[3], selectedTopicIDs: topics) : nil
            let entries: [SensitiveDataDictionaryEntry] = useGroups ? [] : ["взятка", "откат"].map {
                .init(phrase: $0, matchMode: mode == .literal ? .exact : .wordForms)
            }
            return try .init(entries: entries, selectedGroupIDs: useGroups ? groups : [], topicClassifier: classifier)
        }
        let preparation = elapsed(prepStart)
        let input = "Взятка и откат упомянуты в примере. О взятках и откатах говорили в учебном кейсе. Валовая маржа составляет двадцать процентов. План встречи перенесли на завтра."
        let firstDetection: (milliseconds: Double, spanCount: Int) = try autoreleasepool {
            let start = DispatchTime.now().uptimeNanoseconds
            let spans = try snapshot.spans(in: input)
            return (elapsed(start), spans.count)
        }
        let iterations = 100
        var timings: [Double] = []; timings.reserveCapacity(iterations)
        var spanCount = 0
        var maskedCount = 0
        var digest = SHA256()
        for _ in 0..<iterations {
            // Foundation regex temporaries cannot accumulate across iterations.
            let result: (milliseconds: Double, spans: Int, masked: Int, proof: Data) = try autoreleasepool {
                let start = DispatchTime.now().uptimeNanoseconds
                let spans = try snapshot.spans(in: input)
                let milliseconds = elapsed(start)
                let ordered = spans.sorted {
                    $0.range.location == $1.range.location ? $0.range.length < $1.range.length : $0.range.location < $1.range.location
                }
                // Consume actual offsets and replacements after the measured call;
                // outputCount/digest prevent an unused-result benchmark.
                let proof = ordered.map { "\($0.range.location):\($0.range.length):\($0.replacement)" }.joined(separator: "|")
                return (milliseconds, spans.count, spans.reduce(0) { $0 + $1.range.length }, Data(proof.utf8))
            }
            timings.append(result.milliseconds)
            spanCount += result.spans
            maskedCount += result.masked
            digest.update(data: result.proof)
        }
        let report = Report(schemaVersion: 1, revision: args.count == 5 ? args[4] : "unspecified",
            mode: mode, snapshotFingerprint: snapshot.fingerprint,
            artifactSHA256: mode == .groupsAndClassifier ? args[3] : nil,
            workloadSHA256: SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined(),
            workloadUTF16: input.utf16.count, iterations: iterations,
            userSeedCount: useGroups ? 0 : 2,
            catalogGroupCount: useGroups ? groups.count : 0,
            catalogTermCount: useGroups ? Set(SensitiveBusinessGroupCatalog.groups.flatMap(\.terms)).count : 0,
            classifierTopicIDs: topics.sorted(), preparationMilliseconds: preparation,
            firstDetectionMilliseconds: firstDetection.milliseconds, warmupSpanCount: firstDetection.spanCount,
            warmMilliseconds: timings, totalSpanCount: spanCount, totalMaskedUTF16: maskedCount,
            outputDigest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
            limitations: [
                "One immutable production snapshot per fresh process. Peak RSS must be obtained externally and includes Foundation, executable and other process overhead.",
                "Exact and morphology modes contain two seed words; groups modes contain all six catalog groups. This compares stated configurations, not equal dictionary sizes.",
                "The classifier is CPU-only, explicitly experimental and loaded only for groupsAndClassifier.",
                "Timings cover synchronous span detection only. UTF16 mask counts may include overlapping detector evidence and are an output checksum, not a coverage metric.",
                "This is a synthetic macOS text workload, not an incremental iPad memory, battery, thermal, ASR, microphone or A1 NER measurement.",
                "Repeated identical input is a bounded throughput probe; quality is evaluated separately on the independent corpus."
            ])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        withExtendedLifetime(snapshot) {}
    }
}
