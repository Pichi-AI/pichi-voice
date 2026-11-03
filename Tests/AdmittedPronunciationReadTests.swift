import CryptoKit
import Foundation
import Darwin

@main @MainActor struct AdmittedPronunciationReadTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    nonisolated static func wait(_ semaphore: DispatchSemaphore, seconds: Double) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    static func descriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); preconditionFailure(message) }
        catch { checks += 1 }
    }

    struct Original: Encodable {
        let version = 1
        let sampleRate = 16_000
        let encoding = "float32-little-endian"
        let entryID: UUID
        let intendedText = "synthetic"
        let evidenceID: UUID
        let recordingID = UUID()
        let modelKey = "synthetic"
        let observedText = "synthetic"
        let sourceSampleRange = 0..<3
        let focalSampleRange = 1..<3
        let sourceWordRange = 0..<1
        let pcmFloat32: Data
    }

    static func featureEvidenceTransportContracts() throws {
        let now = Date(timeIntervalSince1970: 1000)
        let text = "alpha term beta term omega"
        let words = [ASRWordTiming(text: "alpha", start: 0.2, end: 0.5),
                     ASRWordTiming(text: "term", start: 1.01, end: 1.21),
                     ASRWordTiming(text: "beta", start: 1.5, end: 1.8),
                     ASRWordTiming(text: "term", start: 5.03, end: 5.21),
                     ASRWordTiming(text: "omega", start: 5.5, end: 5.8)]
        let samples = [Float](repeating: 0.2, count: 16_000 * 8)
        func feature(offset: Double = 0, period: Double = 0.04, hidden: Int = 2, count: Int = 200,
                     base: Float = 0, version: String = "synthetic-encoder-v1") -> DictionaryLearningFeatureFrames {
            .init(extractorVersion: version, frames: .init(offset: offset, frameDuration: period, hiddenSize: hidden,
                values: (0..<count).flatMap { row in [Float](repeating: base + Float(row), count: hidden) }))
        }
        func recording(_ features: [DictionaryLearningFeatureFrames], retainAudio: Bool = true) -> DictionaryLearningRecording {
            DictionaryLearningRecording(alignment: .init(modelKey: "synthetic-artifact-hash", words: words,
                featureFrames: features), samples: samples, retainAudio: retainAudio, now: now)!
        }
        func evidence(_ recording: DictionaryLearningRecording) throws -> DictionaryLearningAudioEvidence {
            try DictionaryLearningAlignmentResolver.resolve(recording: recording, deliveredTextBeforeEdit: text,
                selectedUTF16Range: (text as NSString).range(of: "term", options: .backwards), observedText: "term", now: now)
        }
        let native = feature(offset: 0.015, hidden: 768)
        let retained = recording([native])
        expect(retained.alignment.featureFrames == [native], "Valid 40 ms encoder windows retain exact values and origin")
        let cut = try evidence(retained)
        expect(cut.sourceWordRange == 3..<4, "Repeated spelling resolves only the selected second occurrence")
        expect(cut.modelKey == "synthetic-artifact-hash" && cut.featureFrames[0].extractorVersion == native.extractorVersion,
            "Feature transport preserves the source artifact key and extractor version")
        expect(cut.sourceSampleRange.lowerBound == 47_360 && cut.focalSampleRange == 33_120..<36_000,
            "Existing source PCM and focal alignment remain exact")
        expect(cut.featureFrames.count == 1 && cut.featureFrames[0].frames.hiddenSize == 768 &&
            cut.featureFrames[0].frames.count == 5 && cut.featureFrames[0].frames.values.first == 125,
            "Only focal encoder frames from the selected occurrence are copied")
        expect(abs(cut.featureFrames[0].frames.offset - 2.055) < 1e-9,
            "A non-grid encoder origin becomes relative to evidence PCM without losing its offset")
        expect(cut.featureFrames[0].frames.offset <= Double(cut.focalSampleRange.lowerBound) / 16_000 &&
            cut.featureFrames[0].frames.offset + Double(cut.featureFrames[0].frames.count) * 0.04 >= Double(cut.focalSampleRange.upperBound) / 16_000,
            "Outward frame rounding covers the whole selected acoustic occurrence")

        let compoundText = "😀 I use Petch Voice."
        let correctedCompoundText = "😀 I use Pichi Voice."
        let compound = AutomaticDictionaryCorrectionDetector.candidate(
            before: compoundText, after: correctedCompoundText,
            insertedRange: NSRange(location: 0, length: (compoundText as NSString).length),
            knownCanonicalTerms: ["Pichi Voice"]
        )!
        let compoundRecording = DictionaryLearningRecording(alignment: .init(modelKey: "synthetic-compound", words: [
            .init(text: "I", start: 0.1, end: 0.2), .init(text: "use", start: 0.3, end: 0.5),
            .init(text: "Petch", start: 1, end: 1.3), .init(text: "Voice", start: 1.4, end: 1.8),
        ], featureFrames: [feature(count: 75)]), samples: [Float](repeating: 0.2, count: 48_000), now: now)!
        let compoundEvidence = try DictionaryLearningAlignmentResolver.resolve(
            recording: compoundRecording, deliveredTextBeforeEdit: compoundText,
            selectedUTF16Range: compound.sourceUTF16Range!, observedText: compound.heardText, now: now
        )
        expect(compoundEvidence.observedText == "Petch Voice" && compoundEvidence.sourceWordRange == 2..<4 &&
            compoundEvidence.focalSampleRange == 16_000..<28_800,
            "A partial spelling edit preserves both words and their complete original PCM focal range")
        expect(compoundEvidence.featureFrames.count == 1 && compoundEvidence.featureFrames[0].frames.count == 20 &&
            compoundEvidence.featureFrames[0].frames.values.first == 25 && compoundEvidence.featureFrames[0].frames.values.last == 44,
            "Compound correction evidence includes unchanged-word encoder frames without surrounding words")
        let delayedCompoundEvidence = try DictionaryLearningAlignmentResolver.resolve(
            recording: compoundRecording, deliveredTextBeforeEdit: compoundText,
            selectedUTF16Range: compound.sourceUTF16Range!, observedText: compound.heardText,
            now: now.addingTimeInterval(70)
        )
        expect(delayedCompoundEvidence.focalSampleRange == compoundEvidence.focalSampleRange &&
            delayedCompoundEvidence.sourceWordRange == compoundEvidence.sourceWordRange,
            "An edit after 30 seconds still resolves the same original audio while evidence is fresh")
        do {
            _ = try DictionaryLearningAlignmentResolver.resolve(
                recording: compoundRecording, deliveredTextBeforeEdit: compoundText,
                selectedUTF16Range: compound.sourceUTF16Range!, observedText: compound.heardText,
                now: now.addingTimeInterval(DictionaryLearningRecording.lifetime)
            )
            preconditionFailure("Observation must not extend the original audio evidence lifetime")
        } catch DictionaryLearningAlignmentError.expired { checks += 1 }

        let legacy = try evidence(recording([feature(offset: 0.025, period: 0.08, count: 100, version: "synthetic-legacy-v1")]))
        expect(legacy.featureFrames[0].frames.count == 3 && legacy.featureFrames[0].frames.values.first == 62 &&
            abs(legacy.featureFrames[0].frames.offset - 2.025) < 1e-9,
            "Legacy 80 ms feature windows preserve their own origin and frame period")
        let overlapping = recording([feature(count: 135, base: 1000), feature(offset: 3.6, count: 70, base: 2000)])
        let best = try evidence(overlapping)
        expect(best.featureFrames.count == 1 && best.featureFrames[0].frames.values.first == 2035 &&
            best.featureFrames[0].frames.count == 6, "Overlapping windows choose the one with safer context around the whole focal range")
        expect(abs(best.featureFrames[0].frames.offset - 2.04) < 1e-9, "Chosen window retains its recording-relative frame origin")
        let tied = try evidence(recording([feature(base: 3000), feature(base: 4000)]))
        expect(tied.featureFrames[0].frames.values.first == 3125, "Equal-context windows choose the first source window deterministically")
        let wrongOccurrence = try evidence(recording([feature(offset: 0.96, count: 12, base: 5000)]))
        expect(wrongOccurrence.featureFrames.isEmpty && wrongOccurrence.sourceWordRange == 3..<4,
            "Features covering only the earlier repeated word cannot supply the selected occurrence")

        let crossing = DictionaryLearningRecording(alignment: .init(modelKey: "synthetic", words: [
            .init(text: "term", start: 3.16, end: 3.24)], featureFrames: [feature(count: 80), feature(offset: 3.2, count: 80)]),
            samples: samples, now: now)!
        let crossingEvidence = try DictionaryLearningAlignmentResolver.resolve(recording: crossing, deliveredTextBeforeEdit: "term",
            selectedUTF16Range: NSRange(location: 0, length: 4), observedText: "term", now: now)
        expect(crossingEvidence.featureFrames.isEmpty && !crossingEvidence.samples.isEmpty,
            "A focal occurrence crossing separate encoder windows keeps PCM but never stitches feature windows")
        let aligned = DictionaryLearningRecording(alignment: .init(modelKey: "synthetic", words: [
            .init(text: "term", start: 0.04, end: 0.08)], featureFrames: [feature(count: 200)]), samples: samples, now: now)!
        let alignedEvidence = try DictionaryLearningAlignmentResolver.resolve(recording: aligned, deliveredTextBeforeEdit: "term",
            selectedUTF16Range: NSRange(location: 0, length: 4), observedText: "term", now: now)
        expect(alignedEvidence.featureFrames[0].frames.count == 1 && alignedEvidence.featureFrames[0].frames.values.first == 1,
            "Exact frame-boundary selections do not include a neighboring occurrence")
        let noFeatures = try evidence(recording([]))
        expect(noFeatures.featureFrames.isEmpty && noFeatures.sourceWordRange == 3..<4,
            "Legacy initializers and evidence resolution remain unchanged without auxiliary features")
        let longWindow = feature(hidden: 768, count: 550)
        let longRecording = DictionaryLearningRecording(alignment: .init(modelKey: "synthetic-long-window", words: words,
            featureFrames: [longWindow]), samples: [Float](repeating: 0.2, count: 16_000 * 22), now: now)!
        expect(longRecording.alignment.featureFrames.count == 1 && !longWindow.frames.isValid,
            "Raw recording transport accepts a bounded full inference window beyond the shorter persisted-inspection limit")
        let longEvidence = try evidence(longRecording)
        expect(longEvidence.featureFrames.count == 1 && longEvidence.featureFrames[0].frames.isValid,
            "A full inference window is reduced to a bounded persistable focal feature cut")

        var nonfinite = native.frames.values
        nonfinite[0] = .nan
        let invalid: [[DictionaryLearningFeatureFrames]] = [
            [feature(version: "")], [feature(version: "bad recipe")], [feature(offset: -.infinity)],
            [feature(offset: -0.04)], [feature(period: 0.03)], [feature(offset: 9, count: 1)],
            [feature(offset: 0.015, count: 201)],
            [.init(extractorVersion: "synthetic", frames: .init(offset: 0, frameDuration: 0.04, hiddenSize: 768, values: [1]))],
            [.init(extractorVersion: native.extractorVersion, frames: .init(offset: 0, frameDuration: 0.04, hiddenSize: 768, values: nonfinite))],
            [feature(), feature(version: "different-recipe")],
            [feature(), feature(hidden: 3)], [feature(), feature(period: 0.08, count: 100)],
            [feature(offset: 4, count: 20), feature(count: 20)],
            Array(repeating: feature(count: 1), count: DictionaryLearningRecording.maximumFeatureChunks + 1),
        ]
        for frames in invalid {
            let value = recording(frames)
            expect(value.alignment.featureFrames.isEmpty && value.samples == samples,
                "Invalid optional feature metadata or values are dropped without discarding source PCM")
        }
        // Share one synthetic 16 MiB array across windows: retention still accounts for every
        // window's logical payload, without allocating a large model or dataset for the probe.
        let sixteenMiB = [Float](repeating: 0.2, count: 4_194_304)
        let budgetWindow = DictionaryLearningFeatureFrames(extractorVersion: "synthetic-large-v1",
            frames: .init(offset: 0, frameDuration: 0.04, hiddenSize: 2048, values: sixteenMiB))
        let budgetRecording = DictionaryLearningRecording(alignment: .init(modelKey: "synthetic", words: words,
            featureFrames: Array(repeating: budgetWindow, count: 9)), samples: [Float](repeating: 0.2, count: 16_000 * 82), now: now)!
        expect(DictionaryLearningRecording.maximumFeatureBytes == 128 * 1024 * 1024 && budgetRecording.alignment.featureFrames.isEmpty &&
            !budgetRecording.samples.isEmpty, "A payload above the explicit 128 MiB budget drops only auxiliary features")
        let negative = DictionaryAcousticEvidence(id: UUID(), entryID: UUID(), label: "Synthetic", profileKey: "synthetic-profile",
            modelKey: "synthetic", sourceWordRange: 0..<1, frames: .init(hiddenSize: 2, values: [1, 0]))
        let negativeOnly = DictionaryLearningRecording(alignment: .init(modelKey: "synthetic", words: words,
            acousticEvidence: [negative], featureFrames: [native]), samples: samples, retainAudio: false, now: now)!
        expect(negativeOnly.samples.isEmpty && negativeOnly.alignment.featureFrames.isEmpty &&
            negativeOnly.alignment.acousticEvidence.count == 1, "Negative-only retention strips raw PCM and raw feature windows but preserves accepted negative evidence")
    }

    static func featureFormatContracts(in root: URL) async throws {
        let directory = root.appendingPathComponent("synthetic-feature-formats")
        let file = directory.appendingPathComponent("pronunciation-dictionary-v1.json")
        let store = PronunciationDictionaryStore(fileURL: file)
        let samples = (0..<6400).map { Float($0 % 13) / 100 }
        let vector: [Float] = [1] + [Float](repeating: 0, count: 39)
        let values = Array(repeating: vector, count: 10).flatMap { $0 }
        let inspection = DictionaryAudioInspection(samples: samples, recordedSampleCount: samples.count,
            frames: [.init(offset: 0, frameDuration: 0.04, hiddenSize: 40, values: values)],
            words: [.init(text: "synthetic", start: 0.1, end: 0.3)], selectedStart: 0.1, selectedEnd: 0.3)
        let legacy = DictionaryAudioInspection(samples: samples, recordedSampleCount: samples.count,
            frames: [.init(offset: 0, frameDuration: 0.08, hiddenSize: 40, values: Array(values.prefix(200)))],
            words: [], selectedStart: 0.1, selectedEnd: 0.3)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        expect(inspection.isValid && legacy.isValid, "40 ms features and legacy 80 ms inspections validate")
        expect(try PropertyListDecoder().decode(DictionaryAudioInspection.self, from: encoder.encode(inspection)) == inspection,
            "40 ms audio and feature blobs round-trip without loss")
        expect(try PropertyListDecoder().decode(DictionaryAudioInspection.self, from: encoder.encode(legacy)) == legacy,
            "Legacy 80 ms inspection decoding remains compatible")
        let unsupported = DictionaryAudioInspection.Frames(offset: 0, frameDuration: 0.02, hiddenSize: 40, values: values)
        expect(!unsupported.isValid, "Unsupported feature periods are rejected")
        rejects("Unsupported periods reject decoding before feature expansion") {
            _ = try PropertyListDecoder().decode(DictionaryAudioInspection.Frames.self, from: encoder.encode(unsupported))
        }
        let overlong = DictionaryAudioInspection.Frames(offset: 0, frameDuration: 0.04, hiddenSize: 40,
            values: [Float](repeating: 1, count: 381 * 40))
        rejects("40 ms feature chunks cannot exceed 15.2 seconds") {
            _ = try PropertyListDecoder().decode(DictionaryAudioInspection.Frames.self, from: encoder.encode(overlong))
        }
        let nonfinite = DictionaryAudioInspection.Frames(offset: 0, frameDuration: 0.04, hiddenSize: 40,
            values: [Float](repeating: .nan, count: 40))
        rejects("Nonfinite feature values cannot enter decoded evidence") {
            _ = try PropertyListDecoder().decode(DictionaryAudioInspection.Frames.self, from: encoder.encode(nonfinite))
        }
        let tooDense = DictionaryAudioInspection(samples: [Float](repeating: 0, count: 16_000 * 120), recordedSampleCount: 16_000 * 120,
            frames: (0..<8).map { .init(offset: Double($0) * 15, frameDuration: 0.04, hiddenSize: 2048,
                values: [Float](repeating: 1, count: 375 * 2048)) }, words: [], selectedStart: 0, selectedEnd: 0.4)
        expect(!tooDense.isValid, "Denser feature formats retain the old aggregate evidence memory budget")

        let key = "synthetic-model:artifact-and-recipe"
        let recipe = "synthetic-cepstral-40ms-v1"
        let entry = UUID(), evidenceID = UUID(), recording = UUID()
        let evidence = DictionaryLearningAudioEvidence(recordingID: recording, modelKey: key, observedText: "synthetic heard",
            sourceWordRange: 0..<1, sourceSampleRange: 0..<samples.count, focalSampleRange: 1600..<4800, samples: samples)
        let originalCapture = PronunciationEnrollmentCapture(values: vector, sourceFrameCount: 5, modelKey: key,
            extractorVersion: recipe, pendingInspection: inspection)
        let revision = await store.revision(for: entry)
        expect(try await store.learnOriginalAudio(entryID: entry, label: "Synthetic Correct", evidenceID: evidenceID,
            evidence: evidence, capture: originalCapture, expectedRevision: revision), "Original correction clip saved")
        let repeats = (0..<2).map { _ in
            PronunciationEnrollmentCapture(values: vector, sourceFrameCount: 10, modelKey: key,
                extractorVersion: recipe, pendingInspection: inspection)
        }
        try await store.upsert(dictionaryEntryID: entry, label: "Synthetic Correct", modelKey: key, enrollments: repeats,
            automaticMatchingEnabled: true)
        let profiles = await store.allProfiles()
        expect(profiles.count == 1 && profiles[0].enrollments.count == 3, "One original and two repeats share one profile")
        let profile = profiles[0]
        expect(profile.isEligibleForMatching && profile.hasTemporalRecordings, "Generic profile accepts consistent new feature recipe")
        expect(profile.enrollments.allSatisfy { $0.extractorVersion == recipe }, "Provider recipe is preserved instead of relabeled as another encoder")
        let source = profile.enrollments.first { $0.originalAudioID == evidenceID }!
        expect(source.sourceRecordingID == recording && source.sourceFocalRange == 1600..<4800,
            "Correction provenance preserves the exact source occurrence")
        expect(try await store.originalAudioSamples(for: source, entryID: entry) == Array(samples[1600..<4800]),
            "Original focal PCM survives persistence")
        for capture in profile.enrollments {
            expect(try await store.inspection(for: capture.inspectionID!) == inspection,
                "Each retained pronunciation has its own reloadable audio and 40 ms features")
        }
        let reopened = PronunciationDictionaryStore(fileURL: file)
        expect(await reopened.allProfiles() == profiles, "Profiles survive a new store instance without changing recipe or references")
        let encodedProfile = try JSONEncoder().encode(profile)
        expect(try JSONDecoder().decode(PronunciationDictionaryProfile.self, from: encodedProfile) == profile,
            "New recipe metadata survives the existing backup metadata schema")
        var inconsistent = repeats[0]
        inconsistent.extractorVersion = "different-recipe-v1"
        do {
            try await reopened.upsert(dictionaryEntryID: entry, label: profile.label, modelKey: key, enrollments: [inconsistent])
            preconditionFailure("Mixed extractor versions must not append to a profile")
        } catch PronunciationDictionaryStoreError.inconsistentEnrollment { checks += 1 }
        expect(await reopened.allProfiles() == profiles, "Rejected mixed-recipe update preserves the saved profile")
        var mixed = profile
        mixed.enrollments.append(inconsistent)
        expect(!mixed.isEligibleForMatching, "Mixed feature recipes fail common eligibility")
        var duplicate = source
        duplicate.originalAudioID = nil
        duplicate.inspectionID = nil
        duplicate.pendingInspection = inspection
        let beforeDuplicate = try Data(contentsOf: file)
        try await reopened.upsert(dictionaryEntryID: entry, label: profile.label, modelKey: key,
            enrollments: [duplicate, duplicate])
        expect(await reopened.allProfiles() == profiles, "Reusing one selected history occurrence cannot create extra voice examples")
        expect(try Data(contentsOf: file) == beforeDuplicate, "Duplicate-only history enrollment does not rewrite saved data")
        duplicate.sourceFocalRange = 4800..<8000
        try await reopened.upsert(dictionaryEntryID: entry, label: profile.label, modelKey: key,
            enrollments: [duplicate, duplicate])
        expect(await reopened.allProfiles().first?.enrollments.count == 4,
            "Another occurrence in the same recording is retained once")
    }

    static func main() async throws {
        if CommandLine.arguments.contains("--feature-evidence-only") {
            try featureEvidenceTransportContracts()
            print("Feature evidence transport: \(checks) assertions passed")
            return
        }
        let initial = PrivateProfileStorage.current
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-pronunciation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            PrivateProfileStorage.select(initial)
            try? FileManager.default.removeItem(at: root)
        }
        try featureEvidenceTransportContracts()
        try await featureFormatContracts(in: root)
        func account(_ subject: String, generation: UUID = UUID()) throws -> PrivateProfileSnapshot {
            let context = AccountContext(identity: .init(issuer: "https://synthetic.invalid", subject: subject,
                internalUserID: subject), organizationID: nil, workspaceID: nil, generation: generation)
            return try PrivateProfileStorage.proposed(context: context, generation: generation, legacyRootDirectory: root)
        }
        let guestURL = root.appendingPathComponent("pronunciation-dictionary-v1.json")
        let guestBytes = Data("synthetic preserved guest data".utf8)
        try guestBytes.write(to: guestURL)
        let a = try account("A"), b = try account("B")
        PrivateProfileStorage.select(a)
        let file = a.rootDirectory.appendingPathComponent("pronunciation-dictionary-v1.json")
        let store = PronunciationDictionaryStore(fileURL: file, profile: a)
        let negativeURL = a.rootDirectory.appendingPathComponent("dictionary-negative-examples-v1.plist")
        let negativeStore = DictionaryNegativeExampleStore(url: negativeURL, profile: a, collectionEnabled: { true })
        let entry = UUID(), originalEntry = UUID(), evidence = UUID()
        let ids = (0..<4).map { _ in UUID() }
        let inspection = DictionaryAudioInspection(samples: [Float](repeating: 0.25, count: 1280),
            recordedSampleCount: 1280,
            frames: [.init(offset: 0, frameDuration: 0.08, hiddenSize: 2, values: [1, 0])],
            words: [], selectedStart: 0, selectedEnd: 0.08)
        let captures = ids.map { id in
            PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 1, modelKey: "synthetic", inspectionID: id)
        }
        let pinnedID = ids[1]
        let originalCapture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 1,
            modelKey: "synthetic", originalAudioID: evidence)
        let profiles = [PronunciationDictionaryProfile(dictionaryEntryID: entry, label: "A private", modelKey: "synthetic",
            hiddenSize: 2, enrollments: captures),
            PronunciationDictionaryProfile(dictionaryEntryID: originalEntry, label: "A original", modelKey: "synthetic",
            hiddenSize: 2, enrollments: [originalCapture])]
        try await store.replaceAllProfiles(profiles)
        let inspectionDirectory = a.rootDirectory.appendingPathComponent("pronunciation-inspection")
        try FileManager.default.createDirectory(at: inspectionDirectory, withIntermediateDirectories: true)
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        for id in ids { try encoder.encode(inspection).write(to: inspectionDirectory.appendingPathComponent("\(id).plist")) }
        let audioDirectory = a.rootDirectory.appendingPathComponent("pronunciation-audio")
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let audioURL = audioDirectory.appendingPathComponent("\(evidence).json")
        let samples: [Float] = [0.1, 0.2, 0.3]
        let original = Original(entryID: originalEntry, evidenceID: evidence, pcmFloat32: samples.withUnsafeBytes { Data($0) })
        try JSONEncoder().encode(original).write(to: audioURL, options: .atomic)
        let negativeFrames = DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1, 0])
        for _ in 0..<32 {
            let correction = DictionaryNegativeCorrection(evidence: .init(id: UUID(), entryID: UUID(), label: "synthetic",
                profileKey: "other", modelKey: "other", sourceWordRange: 0..<1, frames: negativeFrames),
                correctedText: "synthetic", expiresAt: Date().addingTimeInterval(60))
            try await negativeStore.save(correction, expectedRevision: negativeStore.revision())
        }
        let correction = DictionaryNegativeCorrection(evidence: .init(id: UUID(), entryID: entry, label: "synthetic",
            profileKey: "selected", modelKey: "synthetic", sourceWordRange: 0..<1, frames: negativeFrames),
            correctedText: "synthetic", expiresAt: Date().addingTimeInterval(60))
        try await negativeStore.save(correction, expectedRevision: negativeStore.revision())
        let familyURL = a.rootDirectory.appendingPathComponent("synthetic-family-profiles.json")
        let familyStore = PronunciationDictionaryStore(fileURL: familyURL, profile: a)
        let familyEntry = UUID(), unselectedEntry = UUID()
        func familyProfile(entryID: UUID, key: String, width: Int) -> PronunciationDictionaryProfile {
            .init(dictionaryEntryID: entryID, label: "Synthetic family", modelKey: key, hiddenSize: width,
                enrollments: (0..<3).map { _ in .init(values: Array(repeating: 0.5, count: width), sourceFrameCount: 1, modelKey: key) })
        }
        let sharedFamily = familyProfile(entryID: familyEntry, key: "synthetic-family-a", width: 2)
        let exactDifferentWidth = familyProfile(entryID: familyEntry, key: "synthetic-family-b", width: 3)
        let unrelatedFamily = familyProfile(entryID: unselectedEntry, key: "synthetic-family-a", width: 2)
        let otherModel = familyProfile(entryID: familyEntry, key: "synthetic-other", width: 2)
        try await familyStore.replaceAllProfiles([sharedFamily, exactDifferentWidth, unrelatedFamily, otherModel])
        let familyBytes = try Data(contentsOf: familyURL)
        let familyLease = UUID()
        let exactRead = try familyStore.admitCaptureRead(leaseID: familyLease, modelKey: "synthetic-family-b", entryIDs: [familyEntry])
        expect(exactRead.profiles == [exactDifferentWidth], "Existing exact-model admission remains the default")
        exactRead.close(leaseID: familyLease)
        let familyRead = try familyStore.admitCaptureRead(leaseID: familyLease, modelKey: "synthetic-family-b", entryIDs: [familyEntry], includingSharedFamilies: true)
        expect(familyRead.profiles == [exactDifferentWidth, sharedFamily], "Shared admission pins only selected entry and compatible family candidates")
        expect(PronunciationDictionaryStore.selectSharedProfiles(familyRead.profiles, modelKey: "synthetic-family-b", hiddenSize: 2) == [sharedFamily], "Loaded shape can select a compatible fallback after exact-model shape mismatch")
        expect(PronunciationDictionaryStore.selectSharedProfiles(familyRead.profiles, modelKey: "synthetic-family-b", hiddenSize: 3) == [exactDifferentWidth], "Exact model remains preferred when compatible")
        expect(PronunciationDictionaryStore.selectSharedProfiles(familyRead.profiles, modelKey: "synthetic-family-b", hiddenSize: 4).isEmpty, "Incompatible encoder shape cannot activate retained vectors")
        expect(await familyStore.sharedProfiles(modelKey: "synthetic-family-b", hiddenSize: 2).contains(sharedFamily), "Ordinary shared profile selection works while visible")
        defer { familyRead.close(leaseID: familyLease) }
        let capacityURL = a.rootDirectory.appendingPathComponent("synthetic-capacity-profiles.json")
        let capacityStore = PronunciationDictionaryStore(fileURL: capacityURL, profile: a)
        func capacityProfiles(_ count: Int, variants: [String]) -> [PronunciationDictionaryProfile] {
            (0..<count).flatMap { _ in
                let entryID = UUID()
                return variants.map { familyProfile(entryID: entryID, key: $0, width: 2) }
            }
        }
        let pairs = capacityProfiles(65, variants: ["synthetic-family-a", "synthetic-family-b"])
        try await capacityStore.replaceAllProfiles(pairs)
        let capacityBytes = try Data(contentsOf: capacityURL)
        let capacityLease = UUID()
        let capacityRead = try capacityStore.admitCaptureRead(leaseID: capacityLease, modelKey: "synthetic-family-b",
            entryIDs: Set(pairs.map(\.dictionaryEntryID)), includingSharedFamilies: true)
        expect(capacityRead.profiles.count == 130 && capacityRead.omittedSharedProfileCount == 0,
            "65 words retain both valid model variants within separate word and candidate bounds")
        expect(PronunciationDictionaryStore.selectSharedProfiles(capacityRead.profiles, modelKey: "synthetic-family-b", hiddenSize: 2).count == 65,
            "65 admitted words remain independently matchable")
        capacityRead.close(leaseID: capacityLease)
        expect(try Data(contentsOf: capacityURL) == capacityBytes, "Family capacity selection does not rewrite stored source")
        let fullCapacity = capacityProfiles(128, variants: ["synthetic-family-a", "synthetic-family-b"])
        try await capacityStore.replaceAllProfiles(fullCapacity)
        let fullRead = try capacityStore.admitCaptureRead(leaseID: capacityLease, modelKey: "synthetic-family-b",
            entryIDs: Set(fullCapacity.map(\.dictionaryEntryID)), includingSharedFamilies: true)
        expect(fullRead.profiles.count == 256 && Set(fullRead.profiles.map(\.dictionaryEntryID)).count == 128,
            "Original 128-word capacity survives two compatible profiles per word")
        fullRead.close(leaseID: capacityLease)
        let fallbackRead = try capacityStore.admitCaptureRead(leaseID: capacityLease, modelKey: "synthetic-family-target",
            entryIDs: Set(fullCapacity.map(\.dictionaryEntryID)), includingSharedFamilies: true)
        expect(Set(fallbackRead.profiles.prefix(128).map(\.dictionaryEntryID)).count == 128,
            "One fallback per unrepresented word is admitted before additional family variants")
        expect(fallbackRead.profiles.count == 256 && fallbackRead.omittedSharedProfileCount == 0,
            "All 128 fallback words keep both candidates when the unchanged resource budget permits")
        fallbackRead.close(leaseID: capacityLease)
        let manyVariants = capacityProfiles(128, variants: ["synthetic-family-b"] + (0..<8).map { "synthetic-family-version-\($0)" })
        try await capacityStore.replaceAllProfiles(manyVariants)
        let limitedRead = try capacityStore.admitCaptureRead(leaseID: capacityLease, modelKey: "synthetic-family-b",
            entryIDs: Set(manyVariants.map(\.dictionaryEntryID)), includingSharedFamilies: true)
        expect(limitedRead.profiles.count == 1024 && limitedRead.omittedSharedProfileCount == 128,
            "Excess optional versions stay within eight profiles per word and 1024 total candidates")
        expect(limitedRead.profiles.filter { $0.modelKey == "synthetic-family-b" }.count == 128,
            "Optional metadata overflow cannot remove any mandatory exact word")
        limitedRead.close(leaseID: capacityLease)
        let voicePairs = pairs.map { item -> PronunciationDictionaryProfile in
            var item = item
            item.enrollments = item.enrollments.map { capture in
                var capture = capture; capture.inspectionID = UUID(); return capture
            }
            return item
        }
        for item in voicePairs {
            for capture in item.enrollments {
                try encoder.encode(inspection).write(to: inspectionDirectory.appendingPathComponent("\(capture.inspectionID!).plist"))
            }
        }
        try await capacityStore.replaceAllProfiles(voicePairs)
        let handlesBeforeCapacity = try descriptorCount()
        let voiceRead = try capacityStore.admitCaptureRead(leaseID: capacityLease, modelKey: "synthetic-family-b",
            entryIDs: Set(voicePairs.map(\.dictionaryEntryID)), includingSharedFamilies: true)
        let exactVoice = voicePairs.filter { $0.modelKey == "synthetic-family-b" }
        expect(voiceRead.profiles.prefix(65).map(\.id) == exactVoice.map(\.id),
            "Mandatory exact profiles are pinned before optional family profiles regardless of source order")
        expect(voiceRead.profiles.count >= 65 && voiceRead.omittedSharedProfileCount >= 2,
            "65 words with 195 exact references remain usable when optional variants request 390 unique files")
        expect(try descriptorCount() <= handlesBeforeCapacity + 384,
            "Optional sharing cannot exceed the unchanged 384-reference budget")
        for item in exactVoice {
            for capture in item.enrollments {
                expect(try voiceRead.inspection(for: capture.inspectionID!) == inspection,
                    "Every mandatory exact voice reference remains readable")
            }
        }
        voiceRead.close(leaseID: capacityLease)
        expect(try descriptorCount() == handlesBeforeCapacity, "Closing the bounded expanded snapshot releases every file")
        struct CapacityDocument: Encodable { let version = 1; let profiles: [PronunciationDictionaryProfile] }
        var malformedOptional = sharedFamily; malformedOptional.enrollments[0] = .init(values: [1], sourceFrameCount: 1, modelKey: malformedOptional.modelKey)
        try JSONEncoder().encode(CapacityDocument(profiles: [malformedOptional, exactDifferentWidth])).write(to: capacityURL, options: .atomic)
        let safeExactRead = try capacityStore.admitCaptureRead(leaseID: capacityLease, modelKey: "synthetic-family-b",
            entryIDs: [familyEntry], includingSharedFamilies: true)
        expect(safeExactRead.profiles == [exactDifferentWidth] && safeExactRead.omittedSharedProfileCount == 1,
            "Malformed optional vectors do not invalidate valid mandatory exact admission")
        safeExactRead.close(leaseID: capacityLease)
        var malformedExact = exactDifferentWidth; malformedExact.enrollments[0] = .init(values: [1], sourceFrameCount: 1, modelKey: malformedExact.modelKey)
        try JSONEncoder().encode(CapacityDocument(profiles: [malformedExact])).write(to: capacityURL, options: .atomic)
        rejects("Malformed mandatory exact metadata must still reject admission") {
            _ = try capacityStore.admitCaptureRead(leaseID: capacityLease, modelKey: "synthetic-family-b", entryIDs: [familyEntry], includingSharedFamilies: true)
        }
        let handlesBefore = try descriptorCount()
        let leaseID = UUID()
        let read = try store.admitCaptureRead(leaseID: leaseID, modelKey: "synthetic", entryIDs: [entry, originalEntry])
        let negatives = try negativeStore.admitCaptureRead(leaseID: leaseID, modelKey: "synthetic", entryIDs: [entry])
        defer { read.close(leaseID: leaseID); negatives.close(leaseID: leaseID) }
        expect(try descriptorCount() == handlesBefore + 4, "Admission retains only three inspection and one original descriptor globally")
        expect(read.profile == a && read.profiles == profiles, "Admission freezes original metadata and generation")
        expect(read.matchingEnrollments(for: profiles[0]) == Array(captures.suffix(3)),
            "Admission pins the latest three manual references after deliberate re-recording")
        expect(try read.inspection(for: pinnedID) == inspection, "Selected evidence decodes through the retained descriptor")
        rejects("Unselected oldest reference must not be pinned") { _ = try read.inspection(for: ids[0]) }
        rejects("Unselected entry has no original authority") { _ = try read.originalAudioSamples(for: originalCapture, entryID: UUID()) }
        expect(try read.originalAudioSamples(for: originalCapture, entryID: originalEntry) == [0.2, 0.3], "Original focal extraction keeps existing validation")
        expect(negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic") == [negativeFrames], "Only selected negative records are frozen")
        expect(negatives.frames(entryID: entry, profileKey: "other", modelKey: "synthetic").isEmpty, "Negative metadata keys remain exact")
        let negativeRevision = negatives.revision
        let preserved = try Data(contentsOf: file)
        let preservedNegative = try Data(contentsOf: negativeURL)
        let replacement = DictionaryAudioInspection(samples: [Float](repeating: 0.5, count: 1280),
            recordedSampleCount: 1280, frames: inspection.frames, words: [], selectedStart: 0, selectedEnd: 0.08)
        try encoder.encode(replacement).write(to: inspectionDirectory.appendingPathComponent("\(pinnedID).plist"), options: .atomic)
        expect(try read.inspection(for: pinnedID) == inspection, "Atomic path replacement cannot substitute the pinned reference")
        PrivateProfileStorage.closeAdmission()
        rejects("Closed admission must reject another pronunciation lease") {
            _ = try store.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        rejects("Closed admission must reject another negative lease") {
            _ = try negativeStore.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        PrivateProfileStorage.conceal(generation: UUID())
        await store.prepareForProfileTransition()
        await negativeStore.prepareForProfileTransition()
        expect(await store.allProfiles().isEmpty, "Ordinary pronunciation reads remain concealed")
        expect(await familyStore.sharedProfiles(modelKey: "synthetic-family-b", hiddenSize: 2).isEmpty, "New shared-profile reads obey concealed profile boundary")
        expect(await negativeStore.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic").isEmpty, "Ordinary negative reads remain concealed")
        expect(try read.inspection(for: pinnedID) == inspection, "Admitted original reference survives conceal and store retirement")
        expect(negatives.revision == negativeRevision && negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic") == [negativeFrames], "Admitted negative comparison remains immutable")
        PrivateProfileStorage.select(b)
        expect(await familyStore.sharedProfiles(modelKey: "synthetic-family-b", hiddenSize: 2).isEmpty, "B cannot query A through new shared-profile API")
        expect(familyRead.profiles == [exactDifferentWidth, sharedFamily], "A family candidates remain immutable under admitted lease after B selection")
        rejects("Old A cannot open a shared family read while B is selected") { _ = try familyStore.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic-family-b", entryIDs: [familyEntry], includingSharedFamilies: true) }
        familyRead.close(leaseID: familyLease)
        let familyBytesAfterClose = try Data(contentsOf: familyURL)
        expect(familyRead.profiles.isEmpty && familyBytesAfterClose == familyBytes, "Family read close removes metadata without changing original bytes")
        expect(try read.originalAudioSamples(for: originalCapture, entryID: originalEntry) == [0.2, 0.3], "Account B cannot redirect admitted A reads")
        rejects("Old A store must not admit against B") { _ = try store.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry]) }
        read.close(leaseID: UUID()); negatives.close(leaseID: UUID())
        expect(try read.inspection(for: pinnedID) == inspection, "Foreign lease cannot close the active read")
        expect(!negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic").isEmpty, "Foreign lease cannot close negative snapshot")
        read.close(leaseID: leaseID); negatives.close(leaseID: leaseID)
        expect(try descriptorCount() == handlesBefore, "Exact close releases every retained process descriptor")
        expect(read.profiles.isEmpty, "Exact close removes private metadata")
        rejects("Exact close releases reference authority") { _ = try read.inspection(for: pinnedID) }
        rejects("Exact close releases original authority") { _ = try read.originalAudioSamples(for: originalCapture, entryID: originalEntry) }
        expect(negatives.frames(entryID: entry, profileKey: "selected", modelKey: "synthetic").isEmpty, "Exact close removes negative evidence")
        expect(try Data(contentsOf: file) == preserved && Data(contentsOf: negativeURL) == preservedNegative, "Admission, conceal and close preserve original data")
        let sameAccountNewGeneration = try account("A")
        PrivateProfileStorage.select(sameAccountNewGeneration)
        rejects("Same account with a new generation cannot reuse old admission") { _ = try store.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry]) }
        // Bounded failures reject the whole snapshot rather than silently omitting selected data.
        let failedReference = try FileHandle(forWritingTo: inspectionDirectory.appendingPathComponent("\(ids[2]).plist"))
        try failedReference.truncate(atOffset: 24_000_001); try failedReference.close()
        let partial = PronunciationDictionaryStore(fileURL: file, profile: sameAccountNewGeneration)
        let beforeFailure = try descriptorCount()
        rejects("Oversized second reference must reject the whole admission") {
            _ = try partial.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        expect(try descriptorCount() == beforeFailure, "Partial admission closes both earlier reference and metadata descriptors")
        let largeURL = a.rootDirectory.appendingPathComponent("synthetic-large-metadata.json")
        let large = PronunciationDictionaryStore(fileURL: largeURL, profile: sameAccountNewGeneration)
        let tooMany = (0..<129).map { _ in PronunciationDictionaryProfile(dictionaryEntryID: UUID(),
            label: "synthetic", modelKey: "synthetic", hiddenSize: 2, enrollments: [originalCapture]) }
        try await large.replaceAllProfiles(tooMany)
        rejects("Too many selected profiles must reject admission") {
            _ = try large.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: Set(tooMany.map(\.dictionaryEntryID)))
        }
        let oversized = try FileHandle(forWritingTo: largeURL)
        try oversized.truncate(atOffset: 16_000_001); try oversized.close()
        rejects("Oversized metadata must reject admission before decoding") {
            _ = try large.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [])
        }
        let negativeBank = (0..<33).map { _ in DictionaryNegativeExampleStore.Example(id: UUID(), entryID: entry,
            profileKey: "selected", modelKey: "synthetic", frames: negativeFrames) }
        try encoder.encode(negativeBank).write(to: negativeURL, options: .atomic)
        let freshNegatives = DictionaryNegativeExampleStore(url: negativeURL, profile: sameAccountNewGeneration)
        rejects("Oversized negative bank must reject admission") {
            _ = try freshNegatives.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        let bInspection = b.rootDirectory.appendingPathComponent("pronunciation-inspection")
        try FileManager.default.createDirectory(at: bInspection, withIntermediateDirectories: true)
        try encoder.encode(replacement).write(to: bInspection.appendingPathComponent("\(pinnedID).plist"))
        let savedInspections = a.rootDirectory.appendingPathComponent("synthetic-saved-inspections")
        try FileManager.default.moveItem(at: inspectionDirectory, to: savedInspections)
        try FileManager.default.createSymbolicLink(at: inspectionDirectory, withDestinationURL: bInspection)
        let beforeSymlinkFailure = try descriptorCount()
        rejects("An intermediate evidence directory cannot redirect A admission to B") {
            _ = try partial.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        expect(try descriptorCount() == beforeSymlinkFailure, "Intermediate symlink failure closes all directory and metadata descriptors")
        try FileManager.default.removeItem(at: inspectionDirectory)
        try FileManager.default.moveItem(at: savedInspections, to: inspectionDirectory)
        let savedProfile = a.rootDirectory.appendingPathExtension("synthetic-preserved")
        try FileManager.default.moveItem(at: a.rootDirectory, to: savedProfile)
        try FileManager.default.createSymbolicLink(at: a.rootDirectory, withDestinationURL: b.rootDirectory)
        rejects("A symlinked profile root cannot redirect A metadata admission to B") {
            _ = try partial.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        rejects("A symlinked profile root cannot redirect negative admission") {
            _ = try freshNegatives.admitCaptureRead(leaseID: UUID(), modelKey: "synthetic", entryIDs: [entry])
        }
        expect(try descriptorCount() == beforeSymlinkFailure, "Profile symlink failures release their directory descriptors")
        try FileManager.default.removeItem(at: a.rootDirectory)
        try FileManager.default.moveItem(at: savedProfile, to: a.rootDirectory)
        let rawURL = root.appendingPathComponent("synthetic-joined-read")
        try Data("synthetic".utf8).write(to: rawURL)
        let heldFile = try DictionaryCaptureEvidenceFile(url: rawURL, maximumBytes: 32)!
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let closing = DispatchSemaphore(value: 0), closed = DispatchSemaphore(value: 0)
        let reading = Task.detached { try heldFile.read { data in
            entered.signal()
            guard release.wait(timeout: .now() + 5) == .success else { throw CancellationError() }
            return data
        } }
        expect(await Task.detached { Self.wait(entered, seconds: 5) }.value,
            "Synthetic read entered its bounded decode section")
        let cleanup = Task.detached { closing.signal(); heldFile.close(); closed.signal() }
        expect(await Task.detached { Self.wait(closing, seconds: 5) }.value,
            "Synthetic cleanup started")
        expect(!Self.wait(closed, seconds: 0.02), "Close must join an active read/decode")
        reading.cancel(); release.signal()
        do { _ = try await reading.value; preconditionFailure("Cancelled read must not publish decoded bytes") }
        catch is CancellationError { checks += 1 }
        await cleanup.value
        expect(Self.wait(closed, seconds: 1), "Joined cleanup releases its exact descriptor")
        rejects("Closed evidence cannot be read again") { _ = try heldFile.read { $0 } }
        let symlink = root.appendingPathComponent("synthetic-symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: rawURL)
        rejects("Evidence admission must not follow a replaced symlink") {
            _ = try DictionaryCaptureEvidenceFile(url: symlink, maximumBytes: 32)
        }
        let fifo = root.appendingPathComponent("synthetic-fifo")
        expect(mkfifo(fifo.path, 0o600) == 0, "Synthetic FIFO created without any audio or device input")
        rejects("Evidence admission must reject a FIFO without blocking") {
            _ = try DictionaryCaptureEvidenceFile(url: fifo, maximumBytes: 32)
        }
        expect(try Data(contentsOf: guestURL) == guestBytes, "Account admission never migrates or changes guest data")
        print("Admitted pronunciation reads: \(checks) assertions passed")
    }
}
