import Foundation
import PichiGigaAM
@testable import FluidVoice_Debug
import XCTest

/// Opt-in local replay. Audio, labels, weights and exported profiles stay outside Git.
@MainActor
final class GigaAMEncoderDictionaryLiveTests: XCTestCase {
    private struct Clip: Decodable {
        let name: String
        let path: String
        let kind: String
        let label: String?
        let focal_start: Double?
        let focal_end: Double?
    }
    private struct Manifest: Decodable { let terms: [String: String]; let cases: [Clip] }

    func testSavedDictionaryThroughActualNativeProviderWhenEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["PICHI_RUN_ENCODER_DICTIONARY_LIVE"] == "1",
              let planPath = env["PICHI_ENCODER_DICTIONARY_PLAN"],
              let modelPath = env["PICHI_GIGAAM_MODEL_DIR"],
              let outputPath = env["PICHI_ENCODER_DICTIONARY_RESULTS"] else {
            throw XCTSkip("Local encoder dictionary replay is opt-in")
        }
        guard GigaAMRuntime.encoderFeatureAPIAvailable else {
            throw XCTSkip("This native SDK does not expose encoder snapshots")
        }
        XCTAssertNil(env["TRANSCRIBE_DUMP_DIR"], "The live API must not depend on debug dumps")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: planPath)))
        let root = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let priorProfile = PrivateProfileStorage.current
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        let settings = SettingsStore.shared
        let priorEntries = settings.customDictionaryEntries
        let keys = ["DictionarySharedFeatureMatcherEnabled", "DictionaryPronunciationGeneration", "DictionaryNegativeLearningEnabled", "DictionaryNegativeComparisonEnabled"]
        let priorValues = keys.map { settings.defaults.object(forKey: $0) }
        defer {
            settings.customDictionaryEntries = priorEntries
            for (key, value) in zip(keys, priorValues) { settings.defaults.set(value, forKey: key) }
            PrivateProfileStorage.select(priorProfile)
        }
        DictionaryMatcherExperiment.setEnabled(true)
        settings.defaults.set(false, forKey: "DictionaryNegativeLearningEnabled")
        settings.defaults.set(false, forKey: "DictionaryNegativeComparisonEnabled")
        let entries = manifest.terms.keys.sorted().map {
            SettingsStore.CustomDictionaryEntry(triggers: [manifest.terms[$0]!.lowercased()], replacement: manifest.terms[$0]!)
        }
        settings.customDictionaryEntries = entries
        let store = PronunciationDictionaryStore(fileURL: root.appendingPathComponent("pronunciation-dictionary-v1.json"), profile: profile)
        try await store.replaceAllProfiles([])
        let modelStore = PichiGigaAMModelStore(directory: URL(fileURLWithPath: modelPath),
            downloadDescriptor: GigaAMModelCatalog.downloadableModel,
            environment: ["PICHI_GIGAAM_MODEL_DIR": modelPath])
        let provider = PichiGigaAMProvider(modelStore: modelStore, pronunciationStore: store)
        do {
            try await provider.prepare(progressHandler: nil)
            var captures: [String: [PronunciationEnrollmentCapture]] = [:]
            var key: String?
            for clip in manifest.cases where clip.kind == "reference" {
                let samples = try Self.samples(clip.path)
                let result = try await provider.transcribeFinal(samples)
                let alignment = try XCTUnwrap(result.dictionaryLearningAlignment)
                XCTAssertFalse(alignment.featureFrames.isEmpty)
                XCTAssertTrue(alignment.featureFrames.allSatisfy { $0.extractorVersion == GigaAMEncoderFeatures.extractorVersion })
                key = alignment.modelKey
                let lower = Int((try XCTUnwrap(clip.focal_start)) * 16_000)
                let upper = Int((try XCTUnwrap(clip.focal_end)) * 16_000)
                let selected = alignment.words.filter { ($0.start + $0.end) / 2 >= Double(lower) / 16_000 && ($0.start + $0.end) / 2 <= Double(upper) / 16_000 }
                let heard = selected.map(\.text).joined(separator: " ")
                let evidence = DictionaryLearningAudioEvidence(recordingID: UUID(), modelKey: alignment.modelKey,
                    observedText: heard, sourceWordRange: 0..<max(1, selected.count),
                    sourceSampleRange: 0..<samples.count, focalSampleRange: lower..<upper, samples: samples,
                    featureFrames: alignment.featureFrames)
                let extracted = try await provider.originalAudioEnrollment(evidence)
                let capture = try XCTUnwrap(extracted)
                XCTAssertEqual(capture.values.count, 768)
                captures[try XCTUnwrap(clip.label), default: []].append(capture)
            }
            for term in manifest.terms.keys.sorted() {
                let values = try XCTUnwrap(captures[term])
                XCTAssertTrue((3...10).contains(values.count))
                XCTAssertEqual(GigaAMDictionaryAcoustics.activeCaptures(values).count, 3)
                let valid = try await provider.validateDictionaryPronunciations(values)
                XCTAssertTrue(valid)
                let entry = try XCTUnwrap(entries.first { $0.replacement == manifest.terms[term] })
                try await store.upsert(dictionaryEntryID: entry.id, label: entry.replacement,
                    modelKey: try XCTUnwrap(key), enrollments: values, automaticMatchingEnabled: true)
            }
            let saved = await store.allProfiles()
            XCTAssertEqual(saved.count, manifest.terms.count)
            for term in manifest.terms.keys {
                let profile = try XCTUnwrap(saved.first { $0.label == manifest.terms[term] })
                XCTAssertEqual(profile.enrollments.count, captures[term]?.count)
            }
            var rows: [[String: Any]] = []
            for clip in manifest.cases where clip.kind != "reference" {
                let samples = try Self.samples(clip.path)
                let start = Date()
                let result = try await provider.transcribeFinal(samples)
                let alignment = try XCTUnwrap(result.dictionaryLearningAlignment)
                rows.append(["name": clip.name, "kind": clip.kind, "label": clip.label as Any? ?? NSNull(),
                    "corrected": result.text, "raw_words": alignment.words.map { ["text": $0.text, "start": $0.start, "end": $0.end] as [String: Any] },
                    "model_key": alignment.modelKey, "same_pass_feature_windows": alignment.featureFrames.count,
                    "accepted": alignment.acousticEvidence.map { ["label": $0.label, "word_lower": $0.sourceWordRange.lowerBound, "word_upper": $0.sourceWordRange.upperBound - 1] as [String: Any] },
                    "elapsed_seconds": Date().timeIntervalSince(start)])
            }
            try JSONSerialization.data(withJSONObject: ["scope": "Actual provider, native snapshot API, profile persistence, admitted reads, final correction and original-audio enrollment; no debug dumps or second model", "results": rows], options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("provider-results.json"))
            await provider.unloadModel()
            XCTAssertFalse(provider.isReady)
        } catch {
            await provider.unloadModel()
            throw error
        }
    }

    private static func samples(_ path: String) throws -> [Float] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty, data.count % 4 == 0, data.count <= 240_000 * 4 else { throw GigaAMError.invalidAudio }
        return data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map { Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self))) }
        }
    }
}
