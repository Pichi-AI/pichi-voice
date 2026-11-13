import CryptoKit
import Foundation
import PichiGigaAM
@testable import FluidVoice_Debug
import XCTest

/// Explicitly opted-in local profiling. Inputs are copied into ignored private
/// storage by the operator; neither audio nor pronunciation data is a fixture.
@MainActor
final class GigaAMPrivateLatencyReplayXCTests: XCTestCase {
    private struct Clip: Decodable {
        let clip: String
        let sha256: String
        let durationMilliseconds: Int
        let recordedTranscriptionMs: Int
    }

    func testRecentLocalDictationsWithTheirActualPronunciationSnapshotWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let fixturePath = environment["PICHI_GIGAAM_PRIVATE_REPLAY_DIR"],
              let modelPath = environment["PICHI_GIGAAM_PRIVATE_MODEL_DIR"],
              let reportPath = environment["PICHI_GIGAAM_PRIVATE_REPORT"] else {
            throw XCTSkip("Set explicitly approved private replay, model and report paths")
        }
        let root = URL(fileURLWithPath: fixturePath, isDirectory: true)
        let clips = try JSONDecoder().decode([Clip].self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let profileRoot = root.appendingPathComponent("profile", isDirectory: true)
        let prior = PrivateProfileStorage.current
        let priorEntries = SettingsStore.shared.customDictionaryEntries
        let preferenceKeys = ["DictionarySharedFeatureMatcherEnabled", "DictionaryPronunciationGeneration",
                              "DictionaryNegativeLearningEnabled", "DictionaryNegativeComparisonEnabled"]
        let previousPreferences = Dictionary(uniqueKeysWithValues: preferenceKeys.map {
            ($0, PrivateProfileDefaults.shared.object(forKey: $0))
        })
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: profileRoot)
        PrivateProfileStorage.select(profile)
        defer {
            PrivateProfileStorage.select(prior)
            SettingsStore.shared.customDictionaryEntries = priorEntries
            for key in preferenceKeys {
                if let value = previousPreferences[key] ?? nil { PrivateProfileDefaults.shared.set(value, forKey: key) }
                else { PrivateProfileDefaults.shared.removeObject(forKey: key) }
            }
        }
        SettingsStore.shared.customDictionaryEntries = try JSONDecoder().decode([SettingsStore.CustomDictionaryEntry].self,
            from: Data(contentsOf: root.appendingPathComponent("entries.json")))
        let preferences = try PropertyListSerialization.propertyList(from: Data(contentsOf: root.appendingPathComponent("preferences.plist")), format: nil)
        guard let preferences = preferences as? [String: Any],
              Set(preferences.keys).isSubset(of: Set(preferenceKeys)) else { throw CocoaError(.fileReadCorruptFile) }
        for (key, value) in preferences { PrivateProfileDefaults.shared.set(value, forKey: key) }
        PrivateProfileDefaults.shared.set(true, forKey: "DictionarySharedFeatureMatcherEnabled")
        let descriptor = GigaAMModelCatalog.downloadableModel
        let runtime = try GigaAMRuntime()
        let provider = PichiGigaAMProvider(modelStore: .init(directory: URL(fileURLWithPath: modelPath)),
            expectedModelFingerprint: descriptor.fingerprint,
            pronunciationStore: .init(fileURL: profileRoot.appendingPathComponent("pronunciation-dictionary-v1.json"), profile: profile))
        var report: [[String: Any]] = []
        var activeLease: UUID?
        do {
            try await runtime.load(descriptor: descriptor, directory: URL(fileURLWithPath: modelPath))
            await provider.usePreparedRuntimeForTesting(runtime, fingerprint: descriptor.fingerprint)
            for (index, clip) in clips.enumerated() {
                let path = root.appendingPathComponent(clip.clip)
                let digest = SHA256.hash(data: try Data(contentsOf: path)).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, clip.sha256)
                let reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: path)
                let samples = try await reader.nextSamples()
                for pass in 0..<3 {
                    // Pass 0/2 reproduce the previous forced recalibration. Pass 1
                    // proves that a new admission may reuse unchanged evidence.
                    if pass != 1 { provider.resetPronunciationReferenceCacheForTesting() }
                    let lease = UUID()
                    activeLease = lease
                    try provider.beginAdmittedTranscription(leaseID: lease)
                    _ = try await provider.transcribeStreaming(samples)
                    let output = try await provider.transcribeFinal(samples)
                    let work = await runtime.lastTranscriptionWork
                    let metrics = try XCTUnwrap(provider.lastFinalizationMetrics)
                    XCTAssertEqual(work.inferredWindows, 0, "This exact-input final must perform no native transcription")
                    XCTAssertTrue(metrics.succeeded)
                    if pass == 1 { XCTAssertTrue(metrics.referenceCacheHit) }
                    let textDigest = SHA256.hash(data: Data(output.text.utf8)).map { String(format: "%02x", $0) }.joined()
                    report.append(["clip": index + 1, "pass": pass, "durationMs": clip.durationMilliseconds,
                        "previousLiveFinalMs": clip.recordedTranscriptionMs, "nativeMs": metrics.nativeMilliseconds,
                        "preparationMs": metrics.referencePreparationMilliseconds, "dictionaryMs": metrics.dictionaryMilliseconds,
                        "totalMs": metrics.totalMilliseconds, "referenceCacheHit": metrics.referenceCacheHit,
                        "preparedTerms": metrics.preparedTerms, "retryableReferenceIssues": metrics.retryableReferenceIssues,
                        "inferredWindows": work.inferredWindows, "reusedWindows": work.reusedWindows,
                        "textSHA256": textDigest])
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                    await provider.endAdmittedTranscription(leaseID: lease)
                    activeLease = nil
                }
                let hashes = report.suffix(3).compactMap { $0["textSHA256"] as? String }
                XCTAssertEqual(Set(hashes).count, 1, "Cache reuse must not alter the corrected output")
            }
            await provider.unloadModel()
        } catch {
            if let activeLease { await provider.endAdmittedTranscription(leaseID: activeLease) }
            await provider.unloadModel()
            await runtime.unload()
            throw error
        }
    }
}
