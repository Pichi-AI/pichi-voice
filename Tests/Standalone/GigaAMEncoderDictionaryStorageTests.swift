#if GIGAAM_ENCODER_STORAGE_STANDALONE
import Foundation
import PichiGigaAM

// Storage neighbors are in-memory, observable and have no global store or model API.
// The bridge, feature values, calibration, preparation and projected pure policies are production code.
nonisolated enum SettingsStore {
    struct CustomDictionaryEntry: Sendable { let id: UUID; let triggers: [String]; let replacement: String }
}
nonisolated struct ASRWordTiming: Sendable { let text: String; let start: Double; let end: Double }
nonisolated struct DictionaryAcousticEvidence: Sendable {}
nonisolated struct DictionaryMatchFrames: Sendable {
    let hiddenSize: Int; let values: [Float]
    var count: Int { values.count / max(1, hiddenSize) }
}
nonisolated enum DictionaryMatchPlaygroundError: Error { case unavailable(String) }
nonisolated enum DictionaryMatcherExperiment { static let version = "synthetic-encoder-storage-test" }
nonisolated enum DictionaryLexicalEvidence {
    static func hasRequiredLexicons(_ languages: [String]) -> Bool { preconditionFailure("Storage preparation must not query lexicons") }
    static func isUnknownTerm(_ text: String, requiredLanguages: [String]) -> Bool { preconditionFailure("Storage preparation must not query lexicons") }
}

actor PronunciationDictionaryStore {
    private let inspections: [UUID: DictionaryAudioInspection]
    private(set) var reads = 0
    init(inspections: [UUID: DictionaryAudioInspection] = [:]) { self.inspections = inspections }
    func inspection(for id: UUID) throws -> DictionaryAudioInspection {
        reads += 1
        guard let result = inspections[id] else { throw PronunciationDictionaryStoreError.staleEvidence }
        return result
    }
    // ACTUAL_MATCHING_ENROLLMENTS
    nonisolated final class CaptureRead: @unchecked Sendable {
        let profiles: [PronunciationDictionaryProfile]
        private let pinned: [String: [PronunciationEnrollmentCapture]]
        private let inspections: [UUID: DictionaryAudioInspection]
        private let lock = NSLock()
        private var reads = 0
        var readCount: Int { lock.withLock { reads } }
        init(profiles: [PronunciationDictionaryProfile], inspections: [UUID: DictionaryAudioInspection],
             pinned: [String: [PronunciationEnrollmentCapture]]? = nil) {
            self.profiles = profiles; self.inspections = inspections
            self.pinned = pinned ?? Dictionary(uniqueKeysWithValues: profiles.map {
                ($0.id, GigaAMDictionaryAcoustics.activeCaptures($0.enrollments))
            })
        }
        func matchingEnrollments(for profile: PronunciationDictionaryProfile) -> [PronunciationEnrollmentCapture] { pinned[profile.id] ?? [] }
        func inspection(for id: UUID) throws -> DictionaryAudioInspection {
            try lock.withLock {
                reads += 1
                guard let value = inspections[id] else { throw PronunciationDictionaryStoreError.staleEvidence }
                return value
            }
        }
    }
}
nonisolated enum DictionaryNegativeExampleStore {
    final class CaptureRead: @unchecked Sendable {
        let entryID: UUID; let profileKey: String; let modelKey: String; let values: [DictionaryMatchFrames]
        init(entryID: UUID, profileKey: String, modelKey: String, values: [DictionaryMatchFrames]) {
            self.entryID = entryID; self.profileKey = profileKey; self.modelKey = modelKey; self.values = values
        }
        func frames(entryID: UUID, profileKey: String, modelKey: String) -> [DictionaryMatchFrames] {
            entryID == self.entryID && profileKey == self.profileKey && modelKey == self.modelKey ? values : []
        }
    }
}

@main @MainActor struct GigaAMEncoderDictionaryStorageTests {
    static var checks = 0
    static func expect(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    static func window(offset: Double = 0, first: Int = 0, count: Int = 25,
                       recipe: String = GigaAMEncoderFeatures.extractorVersion) -> DictionaryLearningFeatureFrames {
        var values = [Float](repeating: 0, count: count * 768)
        for i in 0..<count { values[i * 768 + (first + i) % 768] = 1 }
        return .init(extractorVersion: recipe, frames: .init(offset: offset, frameDuration: 0.04, hiddenSize: 768, values: values))
    }
    static func main() async throws {
        let key = GigaAMEncoderDictionaryStorage.modelKey(fingerprint: "synthetic-artifact-sha256")
        var pcm = [Float](repeating: 0.2, count: 16_000)
        pcm[0] = -1.75; pcm[1] = 2.125
        let words = [ASRWordTiming(text: "Alfa", start: 0.1, end: 0.3), .init(text: "Alfa", start: 0.61, end: 0.77)]
        guard let capture = try await GigaAMEncoderDictionaryStorage.enrollment(samples: pcm, modelKey: key,
            featureFrames: [window(offset: 0.4, first: 20, count: 15)], words: words, focalRange: 9_760..<12_320),
              let inspection = capture.pendingInspection else { preconditionFailure("Missing synthetic enrollment") }
        expect(inspection.samples == pcm && inspection.samples[0] == -1.75 && inspection.samples[1] == 2.125,
            "Original Float32 PCM, including overshoots, is retained without clipping or signal processing")
        expect(capture.extractorVersion == GigaAMEncoderFeatures.extractorVersion && capture.modelKey == key && capture.values.count == 768,
            "Enrollment preserves exact artifact key and native feature recipe")
        expect(capture.sourceFrameCount == 5 && inspection.frames[0].values[25] == 1 && abs(inspection.frames[0].offset - 0.6) < 1e-9,
            "Repeated-word focal range crops the supplied window using its actual nonzero origin")
        expect(inspection.selectedStart == 0.61 && inspection.selectedEnd == 0.77 && inspection.words.count == 2,
            "Selected PCM timing and original word metadata survive enrollment")
        let encoded = try PropertyListEncoder().encode(inspection)
        expect(try PropertyListDecoder().decode(DictionaryAudioInspection.self, from: encoded) == inspection,
            "Float32 audio and learned feature evidence survive the existing inspection format")
        var quiet = [Float](repeating: 0, count: 16_000)
        for i in 4_800..<9_600 { quiet[i] = 0.2 }
        let trimmed = try await GigaAMEncoderDictionaryStorage.enrollment(samples: quiet, modelKey: key,
            featureFrames: [window()], words: [])
        expect(trimmed?.pendingInspection?.samples == quiet && trimmed?.pendingInspection?.selectedStart == 0.18 &&
            trimmed?.pendingInspection?.selectedEnd == 0.72, "Manual enrollment uses existing quiet-edge selection without modifying PCM")
        expect(try await GigaAMEncoderDictionaryStorage.enrollment(samples: pcm, modelKey: key,
            featureFrames: [], words: words) == nil, "Missing learned features cannot trigger another inference")
        expect(try await GigaAMEncoderDictionaryStorage.enrollment(samples: pcm, modelKey: key,
            featureFrames: [window(recipe: "gigaam-mfcc20-delta40ms-v1")], words: words) == nil,
            "Old MFCC evidence is never interpreted as learned encoder states")
        expect(try await GigaAMEncoderDictionaryStorage.enrollment(samples: pcm, modelKey: "old-mfcc-model", featureFrames: [window()], words: words) == nil,
            "A nonnative model key is rejected")
        expect(try await GigaAMEncoderDictionaryStorage.enrollment(samples: pcm, modelKey: key,
            featureFrames: [window(count: 10), window(offset: 0.4, count: 15)], words: [], focalRange: 5_760..<7_040) == nil,
            "A focal occurrence crossing separate windows never stitches feature states")
        var nanPCM = pcm; nanPCM[3] = .nan
        expect(try await GigaAMEncoderDictionaryStorage.enrollment(samples: nanPCM, modelKey: key,
            featureFrames: [window()], words: []) == nil, "Nonfinite PCM fails closed")

        let store = PronunciationDictionaryStore()
        expect(try await GigaAMEncoderDictionaryStorage.validate(captures: [capture, capture, capture], modelKey: key, store: store),
            "Three pending native samples use actual reference calibration")
        expect(await store.reads == 0, "Pending evidence needs no disk read or model access")
        var old = capture; old.extractorVersion = "gigaam-mfcc20-delta40ms-v1"
        expect(!(try await GigaAMEncoderDictionaryStorage.validate(captures: [capture, old, capture], modelKey: key, store: store)), "Mixed feature recipes cannot validate")
        let changedKey = GigaAMEncoderDictionaryStorage.modelKey(fingerprint: "different-artifact-sha256")
        expect(!(try await GigaAMEncoderDictionaryStorage.validate(captures: [capture, capture, capture], modelKey: changedKey, store: store)),
            "Equal feature dimensions cannot authorize evidence from a different model fingerprint")
        var missing = capture; missing.pendingInspection = nil
        expect(!(try await GigaAMEncoderDictionaryStorage.validate(captures: [missing, missing, missing], modelKey: key, store: store)), "Missing persisted features never fall back to PCM re-encoding")
        var badFocal = capture
        badFocal.pendingInspection = .init(samples: pcm, recordedSampleCount: pcm.count, frames: inspection.frames,
            words: [], selectedStart: 0.1, selectedEnd: 0.3)
        expect(!(try await GigaAMEncoderDictionaryStorage.validate(captures: [badFocal, badFocal, badFocal], modelKey: key, store: store)),
            "Stored features must cover the actual selected focal range")

        var inspections: [UUID: DictionaryAudioInspection] = [:]
        var saved = (0..<3).map { i -> PronunciationEnrollmentCapture in
            var value = capture; let id = UUID(); value.inspectionID = id; value.pendingInspection = nil
            value.observedText = "Alfa\(i)"; inspections[id] = inspection; return value
        }
        let savedStore = PronunciationDictionaryStore(inspections: inspections)
        expect(try await GigaAMEncoderDictionaryStorage.validate(captures: saved, modelKey: key, store: savedStore), "Saved samples use only the explicitly passed store")
        expect(await savedStore.reads == 3, "All saved references are read once")
        expect(!(try await GigaAMEncoderDictionaryStorage.validate(captures: saved, modelKey: key, store: store)),
            "Unavailable saved features fail closed without an alternate reader or inference")
        var original = saved[0]; let originalID = UUID(); original.inspectionID = originalID
        inspections[originalID] = inspection; original.sourceRecordingID = UUID(); original.observedText = "Alfo"; original.capturedAt = Date().addingTimeInterval(1)
        saved.append(original)
        let entry = UUID()
        let profile = PronunciationDictionaryProfile(dictionaryEntryID: entry, label: "Alpha", modelKey: key, hiddenSize: 768, enrollments: saved)
        let entries = [SettingsStore.CustomDictionaryEntry(id: entry, triggers: [], replacement: "Alpha")]
        let read = PronunciationDictionaryStore.CaptureRead(profiles: [profile], inspections: inspections)
        let snapshot = GigaAMDictionaryAcoustics.Snapshot(modelKey: key, generation: "frozen", enabled: true, entries: entries, pronunciation: read, negatives: nil)
        let prepared = try await GigaAMEncoderDictionaryStorage.preparedWords(snapshot)
        expect(prepared.words.count == 1 && prepared.words[0].term.references.count == 3, "Pinned original and two isolated samples prepare one native term")
        expect(prepared.words[0].term.observedVariants == ["Alfa0", "Alfa1", "Alfa2", "Alfo"], "All retained observed variants survive active-reference selection")
        expect(read.readCount == 3, "Preparation uses only the pinned capture reader")
        let wrongPins = PronunciationDictionaryStore.CaptureRead(profiles: [profile], inspections: inspections, pinned: [profile.id: Array(saved.prefix(3))])
        let unpinned = try await GigaAMEncoderDictionaryStorage.preparedWords(.init(modelKey: key, generation: "frozen", enabled: true,
            entries: entries, pronunciation: wrongPins, negatives: nil))
        expect(unpinned.words.isEmpty && wrongPins.readCount == 0, "A newly active original must already be pinned before preparation")
        let changed = PronunciationDictionaryStore.CaptureRead(profiles: [profile], inspections: inspections)
        let wrongLabel = try await GigaAMEncoderDictionaryStorage.preparedWords(.init(modelKey: key, generation: "frozen", enabled: true,
            entries: [.init(id: entry, triggers: [], replacement: "Beta")], pronunciation: changed, negatives: nil))
        expect(wrongLabel.words.isEmpty && changed.readCount == 0, "A changed dictionary label fails before reading audio")
        let negativeKey = DictionaryNegativeEvidenceResolver.profileKey(profile) + ":shared-features-v1"
        let negatives = DictionaryNegativeExampleStore.CaptureRead(entryID: entry, profileKey: negativeKey, modelKey: key,
            values: [.init(hiddenSize: 768, values: inspection.frames[0].values)])
        let vetoed = try await GigaAMEncoderDictionaryStorage.preparedWords(.init(modelKey: key, generation: "frozen", enabled: true,
            entries: entries, pronunciation: read, negatives: negatives))
        expect(vetoed.words.isEmpty && vetoed.diagnostics.contains { $0.reason == .uncalibrated }, "Exact native negatives prevent contradictory reference calibration")
        let corruptNegatives = DictionaryNegativeExampleStore.CaptureRead(entryID: entry, profileKey: negativeKey, modelKey: key,
            values: [.init(hiddenSize: 40, values: [1])])
        let corrupt = try await GigaAMEncoderDictionaryStorage.preparedWords(.init(modelKey: key, generation: "frozen", enabled: true,
            entries: entries, pronunciation: read, negatives: corruptNegatives))
        expect(corrupt.words.isEmpty, "Corrupt negative evidence disables a term rather than silently removing its veto")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GigaAMEncoderDictionaryStorage.enrollment(samples: pcm, modelKey: key, featureFrames: [window()], words: [])
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled enrollment returned") }
        catch is CancellationError { checks += 1 }
        print("PASS: encoder storage bridge \(checks) assertions; actual native calibration and preparation, inert scoped storage, no inference")
    }
}
#endif
