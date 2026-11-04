import Foundation
import PichiGigaAM
@testable import FluidVoice_Debug
import XCTest
#if os(macOS)
import AppKit
#endif

extension PichiGigaAMIntegrationTests {
    func testEncoderCohortsKeepCompatibleManualAndContextReferences() throws {
        func feature(_ frames: Int, axis: Int = 0) throws -> GigaAMEncoderFeatures {
            var row = [Float](repeating: 0, count: GigaAMEncoderFeatures.dimension)
            row[axis] = 1
            return try GigaAMEncoderFeatures(values: Array(repeating: row, count: frames).flatMap { $0 })
        }
        let slow = try feature(60), quick = try feature(20), other = try feature(20, axis: 1)
        let entry = UUID(), key = "cohort-test"
        let term = GigaAMEncoderDictionary.Term(entryID: entry, label: "Example", modelKey: key,
            references: [slow, slow, slow, quick, quick, quick], observedVariants: [])
        let prepared = try GigaAMEncoderDictionary.prepare(terms: [term], modelKey: key)
        let word = try XCTUnwrap(prepared.words.first)
        XCTAssertEqual(prepared.words.count, 1)
        XCTAssertTrue(word.cohorts.contains { $0.references.allSatisfy { $0.frameCount == 60 } })
        let contextual = try XCTUnwrap(word.cohorts.first { $0.references.allSatisfy { $0.frameCount == 20 } })
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: quick,
            references: contextual.references, calibration: contextual.calibration)).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: quick,
            references: contextual.references, calibration: contextual.calibration, negativeReferences: [quick])).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: other,
            references: contextual.references, calibration: contextual.calibration)).accepted)
    }

    func testEncoderRecordedSubrangePreservesAdjacentWordsAndRoleGuards() throws {
        let row = [Float(1)] + [Float](repeating: 0, count: GigaAMEncoderFeatures.dimension - 1)
        let feature = try GigaAMEncoderFeatures(values: Array(repeating: row, count: 20).flatMap { $0 })
        let term = GigaAMEncoderDictionary.Term(entryID: UUID(), label: "Example", modelKey: "test",
            references: [feature, feature, feature], observedVariants: ["Eksample"])
        let words = [GigaAMWordTiming(text: "Eksample", start: 0, end: 0.5, confidence: 0.4),
                     GigaAMWordTiming(text: "then", start: 0.5, end: 0.8, confidence: 0.4)]
        XCTAssertEqual(GigaAMEncoderDictionary.recordedSubrange(0...1, words: words, term: term), 0...0)
        let role = GigaAMEncoderDictionary.Term(entryID: UUID(), label: "Example", modelKey: "test",
            references: [feature, feature, feature], observedVariants: ["I"])
        let protected = [GigaAMWordTiming(text: "I", start: 0, end: 0.3, confidence: 0.4), words[1]]
        XCTAssertNil(GigaAMEncoderDictionary.recordedSubrange(0...1, words: protected, term: role))
    }

    /// Exercise the complete saved-template path with generated signals, independent
    /// from model weights, user preferences, microphones and network services.
    @MainActor
    func testAcousticDictionaryPersistsSamplesAndReplacesOnlyTheOriginalWordSpan() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-dictionary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let prior = PrivateProfileStorage.current
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        defer {
            PrivateProfileStorage.select(prior)
            try? FileManager.default.removeItem(at: root)
        }
        let key = GigaAMDictionaryAcoustics.modelKey(fingerprint: "synthetic-artifact-v1")
        let entry = SettingsStore.CustomDictionaryEntry(triggers: ["термин"], replacement: "Термин")
        let store = PronunciationDictionaryStore(fileURL: root.appendingPathComponent("profiles.json"), profile: profile)
        let reference = Self.acousticTone(440, duration: 1.2)
        var captures: [PronunciationEnrollmentCapture] = []
        for gain: Float in [0.5, 0.7, 1] {
            let capture = try await GigaAMDictionaryAcoustics.enrollment(
                samples: reference.map { $0 * gain }, modelKey: key, words: [])
            captures.append(try XCTUnwrap(capture))
        }
        try await store.upsert(dictionaryEntryID: entry.id, label: entry.replacement,
            modelKey: key, enrollments: captures, automaticMatchingEnabled: true)
        let reopened = PronunciationDictionaryStore(fileURL: root.appendingPathComponent("profiles.json"), profile: profile)
        let savedProfiles = await reopened.profiles(modelKey: key)
        let saved = try XCTUnwrap(savedProfiles.first)
        XCTAssertEqual(saved.enrollments.count, 3)
        XCTAssertTrue(saved.enrollments.allSatisfy { $0.extractorVersion == GigaAMAcousticFeatures.extractorVersion && $0.inspectionID != nil })
        let original = try await reopened.inspection(for: XCTUnwrap(saved.enrollments.first?.inspectionID))
        XCTAssertEqual(original.samples, reference.map { $0 * 0.5 })
        XCTAssertEqual(original.frames.first?.frameDuration, 0.04)

        let lease = UUID()
        let read = try reopened.admitCaptureRead(leaseID: lease, modelKey: key, entryIDs: [entry.id])
        defer { read.close(leaseID: lease) }
        let snapshot = GigaAMDictionaryAcoustics.Snapshot(modelKey: key, generation: "test", enabled: true,
            entries: [entry], pronunciation: read, negatives: nil)
        let words = try await GigaAMDictionaryAcoustics.preparedWords(snapshot)
        XCTAssertEqual(words.count, 1)
        let samples = Self.acousticTone(880, duration: 0.6) + reference + Self.acousticTone(660, duration: 0.6)
        let result = GigaAMTranscript(text: "До ошибка после.", confidence: 0.4,
            words: [.init(text: "До", start: 0, end: 0.6, confidence: 0.4),
                    .init(text: "ошибка", start: 0.6, end: 1.8, confidence: 0.4),
                    .init(text: "после.", start: 1.8, end: 2.4, confidence: 0.4)],
            endOfUtteranceProbability: nil, processingDuration: 0)
        let output = try await GigaAMDictionaryAcoustics.correct(transcript: result, samples: samples, snapshot: snapshot, words: words)
        XCTAssertEqual(output.text, "До Термин после.")
        XCTAssertEqual(output.evidence.first?.sourceWordRange, 1..<2)
        XCTAssertFalse(entry.triggers.contains("ошибка"), "An acoustic match must not grant a global text replacement")

        // Another artifact's references must never be reused merely because the
        // dictionary word or vector dimension happens to be the same.
        let other = GigaAMDictionaryAcoustics.Snapshot(modelKey: key + "-other", generation: "test", enabled: true,
            entries: [entry], pronunciation: read, negatives: nil)
        let incompatible = try await GigaAMDictionaryAcoustics.preparedWords(other)
        XCTAssertTrue(incompatible.isEmpty)
    }

    @MainActor
    func testAcousticDictionaryRefusesConfidentWordsAndAmbiguousLabels() async throws {
        let samples = Self.acousticTone(440, duration: 1.2)
        let features = try GigaAMAcousticFeatures.extract(samples)
        let references = [features, features, features]
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: references))
        let first = GigaAMDictionaryAcoustics.Word(entryID: UUID(), label: "Первый", profileKey: "first",
            references: references, calibration: calibration, negatives: [])
        let second = GigaAMDictionaryAcoustics.Word(entryID: UUID(), label: "Второй", profileKey: "second",
            references: references, calibration: calibration, negatives: [])
        let snapshot = GigaAMDictionaryAcoustics.Snapshot(modelKey: "test", generation: "test", enabled: true,
            entries: [], pronunciation: nil, negatives: nil)
        func transcript(confidence: Float) -> GigaAMTranscript {
            GigaAMTranscript(text: "Слово.", confidence: confidence,
                words: [.init(text: "Слово.", start: 0, end: 1.2, confidence: confidence)],
                endOfUtteranceProbability: nil, processingDuration: 0)
        }
        let confident = try await GigaAMDictionaryAcoustics.correct(transcript: transcript(confidence: 0.95), samples: samples,
            snapshot: snapshot, words: [first])
        XCTAssertEqual(confident.text, "Слово.")
        let ambiguous = try await GigaAMDictionaryAcoustics.correct(transcript: transcript(confidence: 0.4), samples: samples,
            snapshot: snapshot, words: [first, second])
        XCTAssertEqual(ambiguous.text, "Слово.")
        XCTAssertTrue(ambiguous.evidence.isEmpty)
    }

    @MainActor
    func testOriginalAcousticEnrollmentKeepsExactSelectedOccurrence() async throws {
        let samples = Self.acousticTone(880, duration: 0.5) + Self.acousticTone(440, duration: 1.2)
            + Self.acousticTone(660, duration: 0.5)
        let selected = 8_000..<27_200
        let captured = try await GigaAMDictionaryAcoustics.enrollment(
            samples: samples, modelKey: "synthetic-key", words: [], focalRange: selected)
        let capture = try XCTUnwrap(captured)
        let inspection = try XCTUnwrap(capture.pendingInspection)
        XCTAssertEqual(inspection.samples, samples)
        XCTAssertEqual(inspection.selectedStart, 0.5)
        XCTAssertEqual(inspection.selectedEnd, 1.7)
        let features = try GigaAMAcousticFeatures.extract(samples)
        XCTAssertEqual(inspection.frames.first?.offset, 0.48)
        XCTAssertEqual(inspection.frames.first?.values, Array(features.values[(12 * 40)..<(43 * 40)]))
        let invalid = try await GigaAMDictionaryAcoustics.enrollment(samples: samples, modelKey: "synthetic-key",
            words: [], focalRange: 0..<(samples.count + 1))
        XCTAssertNil(invalid)
    }

    @MainActor
    func testAcousticDictionaryChecksCompetitorsBeyondTwentyFourLabels() async throws {
        let samples = Self.acousticTone(440, duration: 1.2)
        let features = try GigaAMAcousticFeatures.extract(samples)
        let references = [features, features, features]
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: references))
        let words = (0..<40).map { index in
            GigaAMDictionaryAcoustics.Word(entryID: UUID(), label: "Термин\(index)", profileKey: "\(index)",
                references: references, calibration: calibration, negatives: [])
        }
        let snapshot = GigaAMDictionaryAcoustics.Snapshot(modelKey: "test", generation: "test", enabled: true,
            entries: [], pronunciation: nil, negatives: nil)
        let raw = GigaAMTranscript(text: "Слово.", confidence: 0.4,
            words: [.init(text: "Слово.", start: 0, end: 1.2, confidence: 0.4)],
            endOfUtteranceProbability: nil, processingDuration: 0)
        let output = try await GigaAMDictionaryAcoustics.correct(transcript: raw, samples: samples, snapshot: snapshot, words: words)
        XCTAssertEqual(output.text, raw.text)
        XCTAssertTrue(output.evidence.isEmpty)
    }

    @MainActor
    func testAcousticDictionaryFindsLateTermWithLargeVocabulary() async throws {
        let reference = try GigaAMAcousticFeatures.extract(Self.acousticTone(440, duration: 1.2))
        let other = try GigaAMAcousticFeatures.extract(Self.acousticTone(880, duration: 1.2))
        let targetReferences = [reference, reference, reference]
        let distractorReferences = [other, other, other]
        let targetCalibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: targetReferences))
        let otherCalibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: distractorReferences))
        var terms = (0..<127).map { index in
            GigaAMDictionaryAcoustics.Word(entryID: UUID(), label: "Другой\(index)", profileKey: "other\(index)",
                references: distractorReferences, calibration: otherCalibration, negatives: [])
        }
        terms.append(.init(entryID: UUID(), label: "Термин", profileKey: "target", references: targetReferences,
                           calibration: targetCalibration, negatives: []))
        let samples = Self.acousticTone(880, duration: 10.8) + Self.acousticTone(440, duration: 1.2)
        let rawWords = (0..<270).map { index in
            GigaAMWordTiming(text: "слово", start: Double(index) * 0.04, end: Double(index + 1) * 0.04, confidence: 0.4)
        } + [.init(text: "ошибка.", start: 10.8, end: 12, confidence: 0.4)]
        let rawText = rawWords.map(\.text).joined(separator: " ")
        let snapshot = GigaAMDictionaryAcoustics.Snapshot(modelKey: "test", generation: "test", enabled: true,
            entries: [], pronunciation: nil, negatives: nil)
        let raw = GigaAMTranscript(text: rawText, confidence: 0.4, words: rawWords,
            endOfUtteranceProbability: nil, processingDuration: 0)
        let output = try await GigaAMDictionaryAcoustics.correct(transcript: raw, samples: samples, snapshot: snapshot, words: terms)
        XCTAssertEqual(output.text, Array(rawWords.dropLast()).map(\.text).joined(separator: " ") + " Термин.")
        XCTAssertEqual(output.evidence.first?.sourceWordRange, 270..<271)
    }

    @MainActor
    func testPronunciationReadinessRejectsInconsistentFeaturesWithoutLoadingModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-readiness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let fingerprint = GigaAMModelCatalog.downloadableModel.fingerprint
        let key = GigaAMDictionaryAcoustics.modelKey(fingerprint: fingerprint)
        let provider = PichiGigaAMProvider(modelStore: PichiGigaAMModelStore(directory: root), expectedModelFingerprint: fingerprint)
        let samples = Self.acousticTone(440, duration: 0.48)
        func capture(coordinate: Int) -> PronunciationEnrollmentCapture {
            let row = (0..<40).map { Float($0 == coordinate ? 1 : 0) }
            let inspection = DictionaryAudioInspection(samples: samples, recordedSampleCount: samples.count,
                frames: [.init(offset: 0, frameDuration: 0.04, hiddenSize: 40,
                               values: Array(repeating: row, count: 12).flatMap { $0 })],
                words: [], selectedStart: 0, selectedEnd: 0.48)
            return .init(values: row, sourceFrameCount: 12, modelKey: key,
                extractorVersion: GigaAMAcousticFeatures.extractorVersion, pendingInspection: inspection)
        }
        let consistent = try await provider.validateDictionaryPronunciations([capture(coordinate: 0), capture(coordinate: 0), capture(coordinate: 0)])
        let inconsistent = try await provider.validateDictionaryPronunciations([capture(coordinate: 0), capture(coordinate: 1), capture(coordinate: 2)])
        XCTAssertTrue(consistent)
        XCTAssertFalse(inconsistent)
        XCTAssertFalse(provider.isReady)
    }

    func testCorrectedContextAnchorStillRequiresItsSpellingAndRejectsNegativeAudio() throws {
        let anchorRow: [Float] = [1] + Array(repeating: 0, count: 39)
        let alternateRow: [Float] = [0.86, sqrt(1 - 0.86 * 0.86)] + Array(repeating: 0, count: 38)
        let anchor = try GigaAMAcousticFeatures(values: Array(repeating: anchorRow, count: 20).flatMap { $0 })
        let alternate = try GigaAMAcousticFeatures(values: Array(repeating: alternateRow, count: 20).flatMap { $0 })
        let references = [anchor, alternate, alternate]
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: references))
        let normal = try XCTUnwrap(GigaAMAcousticMatcher.match(query: anchor, references: references, calibration: calibration))
        XCTAssertFalse(normal.accepted, "One contextual pronunciation must not silently relax the regular two-reference threshold")
        let word = GigaAMDictionaryAcoustics.Word(entryID: UUID(), label: "Термин", profileKey: "test",
            references: references, calibration: calibration, negatives: [],
            anchors: [.init(features: anchor, observedText: "ошибка")])
        XCTAssertNotNil(try GigaAMDictionaryAcoustics.acceptedDistance(query: anchor, word: word, heard: "Ошибка!"))
        XCTAssertNil(try GigaAMDictionaryAcoustics.acceptedDistance(query: anchor, word: word, heard: "Другое"))
        let vetoed = GigaAMDictionaryAcoustics.Word(entryID: word.entryID, label: word.label, profileKey: word.profileKey,
            references: references, calibration: calibration, negatives: [anchor], anchors: word.anchors)
        XCTAssertNil(try GigaAMDictionaryAcoustics.acceptedDistance(query: anchor, word: vetoed, heard: "ошибка"))
        let observed = GigaAMDictionaryAcoustics.Word(entryID: word.entryID, label: word.label, profileKey: word.profileKey,
            references: references, calibration: calibration, negatives: [], observedSpellings: ["Бимчик"])
        XCTAssertNotNil(try GigaAMDictionaryAcoustics.corroboratedDistance(query: anchor, word: observed, heard: "Бимчик!"))
        XCTAssertNil(try GigaAMDictionaryAcoustics.corroboratedDistance(query: anchor, word: observed, heard: "Другое"))
        let observedNegative = GigaAMDictionaryAcoustics.Word(entryID: word.entryID, label: word.label, profileKey: word.profileKey,
            references: references, calibration: calibration, negatives: [anchor], observedSpellings: ["Бимчик"])
        XCTAssertNil(try GigaAMDictionaryAcoustics.corroboratedDistance(query: anchor, word: observedNegative, heard: "Бимчик"))
    }

    @MainActor
    func testLocalLexicalEvidenceProtectsWordsAndFailsClosedWithoutCoverage() throws {
        #if os(macOS)
        guard NSSpellChecker.shared.availableLanguages.contains(where: { $0.lowercased().hasPrefix("ru") }) else {
            throw XCTSkip("Installed Russian spelling lexicons are required for this native evidence probe")
        }
        XCTAssertFalse(DictionaryLexicalEvidence.isUnknownTerm("печи", requiredLanguages: ["ru"]))
        XCTAssertFalse(DictionaryLexicalEvidence.isUnknownTerm("модель", requiredLanguages: ["ru"]))
        XCTAssertFalse(DictionaryLexicalEvidence.isUnknownTerm("очень Бимчик", requiredLanguages: ["ru"]))
        XCTAssertTrue(DictionaryLexicalEvidence.isUnknownTerm("Бимчик", requiredLanguages: ["ru"]))
        XCTAssertTrue(DictionaryLexicalEvidence.isUnknownTerm("GigM", requiredLanguages: ["ru"]))
        XCTAssertFalse(DictionaryLexicalEvidence.isUnknownTerm("GigM", requiredLanguages: ["zz"]))
        XCTAssertFalse(DictionaryLexicalEvidence.isUnknownTerm("1234", requiredLanguages: ["ru"]))
        #endif
    }

    nonisolated private static func acousticTone(_ frequency: Double, duration: Double) -> [Float] {
        let count = Int(duration * 16_000)
        return (0..<count).map { index in
            let time = Double(index) / 16_000
            let edge = min(1, min(Double(index), Double(count - index - 1)) / 160)
            return Float((sin(2 * .pi * frequency * time) + 0.2 * sin(2 * .pi * frequency * 2 * time)) * 0.25 * edge)
        }
    }
}

final class PichiGigaAMIntegrationTests: XCTestCase {
    /// Opt-in synthetic audio through the real shared download, file-ASR and cleanup APIs.
    @MainActor
    func testSyntheticRussianGigaAMAndS1DefaultPipelineWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelDirectory = environment["PICHI_GIGAAM_CHAIN_MODEL_DIR"],
              let audioPath = environment["PICHI_GIGAAM_CHAIN_AUDIO"],
              let cleanupModel = environment["PICHI_S1_MINI_MODEL_PATH"] else {
            throw XCTSkip("Set isolated GigaAM, S1-mini and synthetic audio paths for the native pipeline.")
        }
        let settings = SettingsStore.shared
        let defaults = UserDefaults.standard
        let keys = ["SelectedSpeechModel", "FileTranscriptionSpeakerLabelsEnabled", "CustomDictionaryEntries",
                    "S1MiniSelectedModelID", "S1MiniLocalModelPath", "SelectedModelByProvider",
                    "VerifiedPrivateAIModelFingerprints", "SelectedDictationPromptID", "DictationPromptOff",
                    "PrivateAIProviderContextTokenLimit", "HasUsedFluidIntelligence"]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = originals[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
            PrivateAIIntegrationService.invalidateInstalledModelCache()
        }
        settings.selectedSpeechModel = .gigaam
        settings.fileTranscriptionSpeakerLabelsEnabled = false
        settings.customDictionaryEntries = []
        settings.privateAIContextTokenLimit = 4096
        let store = PichiGigaAMModelStore(directory: URL(fileURLWithPath: modelDirectory, isDirectory: true))
        let provider = PichiGigaAMProvider(modelStore: store)
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.modelProvidersForTesting[.gigaam] = provider
        func cleanup() async {
            await Task { @MainActor in
                await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: "synthetic pipeline complete")
                await asr.shutdownForTermination()
                await provider.unloadModel()
            }.value
        }
        do {
            try await asr.downloadModel(.gigaam, progressHandler: nil)
            XCTAssertTrue(provider.isReady)
            let artifact = try store.installedModel()
            XCTAssertEqual(artifact.descriptor, GigaAMModelCatalog.downloadableModel)
            XCTAssertNil(artifact.descriptor.endOfUtteranceThreshold)
            let raw = try await FileTranscriptionService(asrService: asr).transcribeFile(URL(fileURLWithPath: audioPath))
            XCTAssertFalse(raw.text.isEmpty)

            let feature = PrivateAIProviderFeature.shared
            let model = PrivateAIModelRegistry.defaultModel
            defaults.set(cleanupModel, forKey: feature.localModelPathDefaultsKey)
            defaults.set(model.id, forKey: feature.selectedModelDefaultsKey)
            settings.selectedModelByProvider[feature.providerID] = model.id
            PrivateAIIntegrationService.invalidateInstalledModelCache()
            let ready = try await PrivateAIIntegrationService.shared.verifyModel(model)
            XCTAssertEqual(ready.state, .ready)
            settings.verifiedPrivateAIModelFingerprints[model.id] = PrivateAIProviderFeature.verificationFingerprint(for: model.id)
            settings.setDictationPromptSelection(.privateAI)
            XCTAssertTrue(DictationAIPostProcessingGate.isConfigured(for: .primary, appBundleID: nil))
            let polished = try await DictationPostProcessingService.shared.process(raw.text)
            XCTAssertEqual(polished.providerID, feature.providerID)
            XCTAssertEqual(polished.model, model.id)
            XCTAssertTrue(polished.text.lowercased().contains("четверг"))
            XCTAssertFalse(polished.text.lowercased().contains("пятниц"))
            XCTAssertFalse(polished.text.contains("<think>"))
            let evidence = "GigaAM: \(raw.text)\nS1-mini: \(polished.text)"
            print("Synthetic GigaAM + S1-mini pipeline:\n\(evidence)")
            let attachment = XCTAttachment(string: evidence)
            attachment.name = "Synthetic Russian native pipeline"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @MainActor
    func testImportedExportControlsLibraryCapabilitiesAndMeasurementProvenance() throws {
        let model = SettingsStore.SpeechModel.gigaam
        let preferred = try XCTUnwrap(GigaAMModelCatalog.models.first)
        let metadata = preferred.libraryMetadata
        XCTAssertEqual(model.libraryMetadata, GigaAMModelCatalog.downloadableModel.libraryMetadata)
        XCTAssertEqual(model.supportedLanguageCodes, "RU")
        XCTAssertEqual(model.supportedLanguageNames, "Russian")
        XCTAssertTrue(metadata.features.contains("Punctuation"))
        XCTAssertTrue(metadata.features.contains("capitalization"))
        XCTAssertTrue(metadata.features.contains("normalization"))
        XCTAssertTrue(metadata.performanceExplanation.contains("excluding model loading"))
        XCTAssertTrue(metadata.performanceExplanation.contains("has not been evaluated"))
        XCTAssertTrue(model.hasPerformanceRatings)
        XCTAssertEqual(model.speedPercent, metadata.performanceRatings.speedPercent)
        XCTAssertEqual(model.accuracyPercent, metadata.performanceRatings.accuracyPercent)
        XCTAssertEqual(model.speedRating, metadata.performanceRatings.speedRating)
        XCTAssertEqual(model.accuracyRating, metadata.performanceRatings.accuracyRating)
        XCTAssertTrue(metadata.performanceExplanation.contains("not measured transcription accuracy"))

        for descriptor in GigaAMModelCatalog.models.dropFirst() where descriptor.downloadBaseURL == nil {
            let older = descriptor.libraryMetadata
            XCTAssertNotEqual(older.size, metadata.size)
            XCTAssertTrue(older.features.contains("does not add punctuation or capitalization"))
            XCTAssertFalse(older.performanceExplanation.contains("8.48 seconds"))
            XCTAssertTrue(older.performanceExplanation.contains("9.1%"))
            XCTAssertTrue(older.performanceExplanation.contains("has not been benchmarked"))
        }
    }

    @MainActor
    func testPublicDownloadMetadataDoesNotInheritPrivateExportCapabilities() {
        let descriptor = GigaAMModelCatalog.downloadableModel
        let metadata = descriptor.libraryMetadata
        XCTAssertEqual(metadata.size, "~259.5 MiB")
        XCTAssertTrue(metadata.features.contains("Q8"))
        XCTAssertEqual(metadata.processor, "GPU preferred; CPU fallback")
        XCTAssertTrue(metadata.features.contains("Punctuation"))
        XCTAssertFalse(metadata.features.contains("FP16"))
        XCTAssertFalse(metadata.features.contains("end-of-utterance"))
        XCTAssertNil(descriptor.endOfUtteranceThreshold)
        XCTAssertFalse(metadata.performanceExplanation.contains("0.97 seconds"))
        XCTAssertTrue(metadata.performanceExplanation.contains("not measured accuracy"))
    }

    @MainActor
    func testRealLocalAudioThroughProviderFilesAndAPIWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["PICHI_GIGAAM_APP_TEST_MODEL_DIR"],
              let audioPath = environment["PICHI_GIGAAM_APP_TEST_AUDIO"] else {
            throw XCTSkip("Set local model and approved audio paths to run real inference.")
        }
        let file = URL(fileURLWithPath: audioPath)
        let defaults = UserDefaults.standard
        let keys = ["SelectedSpeechModel", "FileTranscriptionSpeakerLabelsEnabled"]
        let originals = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer {
            for key in keys {
                if let value = originals[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let provider = PichiGigaAMProvider(modelStore: .init(directory: URL(fileURLWithPath: modelPath)))
        var asrForCleanup: ASRService?
        var meetingASRForCleanup: ASRService?
        var meetingLeaseForCleanup: ASRActivityLease?
        @MainActor
        func cleanup() async {
            let meetingASR = meetingASRForCleanup
            let meetingLease = meetingLeaseForCleanup
            let asr = asrForCleanup
            // An already cancelled fixture must still join every cleanup hook.
            await Task { @MainActor in
                if let meetingASR {
                    // Retain the meeting lease until owned executor/provider hooks join.
                    await meetingASR.shutdownForTermination()
                    if let meetingLease { meetingASR.releaseExclusiveActivity(meetingLease) }
                }
                if let asr { await asr.shutdownForTermination() }
                await provider.unloadModel()
            }.value
            meetingLeaseForCleanup = nil
            meetingASRForCleanup = nil
            asrForCleanup = nil
        }
        do {
            try await provider.prepare()
            let reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: file)
            let samples = try await reader.nextSamples()
            XCTAssertFalse(samples.isEmpty)
            let live = try await provider.transcribeStreaming(samples)
            let final = try await provider.transcribeFinal(samples)
            let training = try await provider.transcribeDictionaryTraining(samples)
            let timed = try await provider.transcribeWithWordTimings(samples)
            XCTAssertFalse(final.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(live.text, final.text)
            XCTAssertEqual(training.text, final.text)
            XCTAssertEqual(timed.result.text, final.text)
            XCTAssertFalse(timed.words.isEmpty)
            XCTAssertTrue(timed.words.allSatisfy { $0.start >= 0 && $0.end >= $0.start && $0.end <= Double(samples.count) / 16_000 })

            let settings = SettingsStore.shared
            settings.selectedSpeechModel = .gigaam
            settings.fileTranscriptionSpeakerLabelsEnabled = false
            let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
            asrForCleanup = asr
            asr.modelProvidersForTesting[.gigaam] = provider
            let controller = InferenceAPIController { url in
                let result = try await asr.transcribeFileForAPI(url)
                return .init(text: result.result.text, confidence: result.result.confidence,
                             sampleCount: result.sampleCount, provider: SettingsStore.SpeechModel.gigaam.displayName)
            }
            let payload = try JSONSerialization.data(withJSONObject: ["path": audioPath])
            let response = await controller.handle(.init(method: "POST", path: "/v1/transcribe", query: [:],
                                                        headers: ["content-type": "application/json"], body: payload))
            XCTAssertEqual(response.status, 200)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
            XCTAssertFalse((body["text"] as? String ?? "").isEmpty)
            XCTAssertEqual(body["sampleCount"] as? Int, samples.count)
            XCTAssertEqual(body["provider"] as? String, SettingsStore.SpeechModel.gigaam.displayName)
            let imported = try await FileTranscriptionService(asrService: asr).transcribeFile(file)
            XCTAssertFalse(imported.text.isEmpty)
            await cleanup()
            XCTAssertFalse(provider.isReady)

            let meetingASR = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
            meetingASRForCleanup = meetingASR
            meetingLeaseForCleanup = try meetingASR.acquireExclusiveActivity(.meeting)
            let attemptID = UUID()
            let store = PichiGigaAMModelStore(directory: URL(fileURLWithPath: modelPath))
            let configuration = MeetingFinalProcessingConfiguration(
                asrModel: SettingsStore.SpeechModel.gigaam.id,
                asrArtifactFingerprint: try store.installedModelFingerprint(),
                asrArtifactDirectory: store.directory,
                languageCode: "ru",
                diarizationFingerprint: PichiMeetingProviderFactory.transcriptOnlyDiarizationFingerprint
            )
            let meetingResult = try await meetingASR.withMeetingModelResidency(attemptID: attemptID) {
                try await meetingASR.withPreparedMeetingASR(attemptID: attemptID, configuration: configuration) { prepared in
                    XCTAssertTrue(prepared is PichiGigaAMProvider)
                    return try await meetingASR.transcribeMeetingSamplesWithTimings(samples, provider: prepared)
                }
            }
            XCTAssertEqual(meetingResult.result.text, final.text)
            XCTAssertFalse(meetingResult.words.isEmpty)
            await cleanup()
        } catch {
            await cleanup()
            throw error
        }
    }

    @MainActor
    func testGigaAMIsRussianUniversalAndUsesItsOwnProvider() throws {
        let model = SettingsStore.SpeechModel.gigaam
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertFalse(model.requiresAppleSilicon)
        XCTAssertTrue(model.hasPerformanceRatings)
        XCTAssertEqual(model.provider, .saluteDevices)
        XCTAssertEqual(model.analyticsDescriptor.model, "gigaam-v3-eou")
        XCTAssertEqual(model.analyticsDescriptor.provider, "salutedevices")
        // The publisher is credited; the host product's brand never names a third-party model.
        XCTAssertEqual(model.displayName, "GigaAM v3")
        XCTAssertEqual(PichiGigaAMProvider(modelStore: .init(directory: FileManager.default.temporaryDirectory)).name, model.displayName)
        XCTAssertEqual(model.brandName, "SaluteDevices")
        XCTAssertEqual(model.creditLine, "Built on GigaAM-v3 by SaluteDevices.")
        XCTAssertNil(model.badgeText)
        XCTAssertTrue(SettingsStore.SpeechModel.availableModels.contains(model))
        let russian = try XCTUnwrap(VoiceEngineLanguageCatalog.language(id: "ru", availableModels: [model]))
        XCTAssertEqual(VoiceEngineLanguageCatalog.routes(for: russian, availableModels: [model]).map(\.model), [model])
        XCTAssertNil(VoiceEngineLanguageCatalog.language(id: "en", availableModels: [model]))
    }

    @MainActor
    func testLocalAPIKeepsGigaAMResponseForAudioPath() async throws {
        var receivedURL: URL?
        let controller = InferenceAPIController { url in
            receivedURL = url
            return .init(text: "Обсудили план встречи.", confidence: 0.9, sampleCount: 16_000, provider: "GigaAM v3")
        }
        let payload = try JSONSerialization.data(withJSONObject: ["path": "/tmp/synthetic-meeting.wav"])
        let response = await controller.handle(.init(
            method: "POST", path: "/v1/transcribe", query: [:],
            headers: ["content-type": "application/json"], body: payload
        ))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(receivedURL?.path, "/tmp/synthetic-meeting.wav")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(result["text"] as? String, "Обсудили план встречи.")
        XCTAssertEqual(result["provider"] as? String, "GigaAM v3")
        XCTAssertEqual(result["sampleCount"] as? Int, 16_000)
    }

    @MainActor
    func testInvalidBase64DoesNotStartInference() async throws {
        var called = false
        let controller = InferenceAPIController { _ in
            called = true
            return .init(text: "", confidence: 0, sampleCount: 0, provider: "GigaAM v3")
        }
        let payload = try JSONSerialization.data(withJSONObject: ["audioBase64": "not base64!"])
        let response = await controller.handle(.init(
            method: "POST", path: "/v1/transcribe", query: [:],
            headers: ["content-type": "application/json"], body: payload
        ))
        XCTAssertEqual(response.status, 400)
        XCTAssertFalse(called)
    }
}

#if DEBUG
/// The optional source reset shares import's exclusive maintenance and joined native cleanup.
@MainActor
final class PichiGigaAMSourceSelectionTests: XCTestCase {
    private final class Gate {
        var isOpen: Bool
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(open: Bool = false) { self.isOpen = open }
        func wait() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.waiters.append($0) }
        }
        func open() {
            self.isOpen = true
            let pending = self.waiters
            self.waiters.removeAll()
            pending.forEach { $0.resume() }
        }
    }

    private final class Provider: TranscriptionProvider {
        let name = "Synthetic source selection"
        let isAvailable = true
        var isReady = true
        var restored = false
        var restoreCalls = 0
        var releaseCalls = 0
        var clearCalls = 0
        var probeCalls = 0
        var releaseWasCancelled = false
        let sourceEntered = Gate()
        let sourceGate = Gate(open: true)
        let releaseEntered = Gate()
        let releaseGate = Gate(open: true)
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult { .init(text: "", confidence: 0) }
        func restoreDefaultModelSource() async throws {
            self.restoreCalls += 1
            self.sourceEntered.open()
            await self.sourceGate.wait()
            try Task.checkCancellation()
            self.restored = true
        }
        func releaseResidency() async {
            self.releaseCalls += 1
            self.releaseEntered.open()
            await self.releaseGate.wait()
            self.releaseWasCancelled = Task.isCancelled
            self.isReady = false
        }
        func modelsExistOnDisk() -> Bool { self.probeCalls += 1; return self.restored }
        func clearCache() async throws { self.clearCalls += 1 }
        func openGates() { self.sourceGate.open(); self.releaseGate.open() }
    }

    private func fixture() -> (ASRService, Provider) {
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let provider = Provider()
        service.modelProvidersForTesting[.gigaam] = provider
        self.addTeardownBlock { @MainActor in provider.openGates() }
        return (service, provider)
    }

    private func waitUntil(_ predicate: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !predicate(), Date() < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return predicate()
    }

    func testDefaultSourceRejectsActiveActivitiesBeforeProviderMutation() async throws {
        let (service, provider) = self.fixture()
        for activity in [ASRExclusiveActivity.dictation, .fileTranscription, .localAPI, .meeting, .settingsRestore, .modelMaintenance] {
            let lease = try service.acquireExclusiveActivity(activity)
            do {
                try await service.useDefaultModelSource(.gigaam)
                XCTFail("Changing sources must not interrupt \(activity)")
            } catch let error as ASRActivityError {
                guard case let .activityInProgress(blocked) = error else { return XCTFail("Unexpected admission error") }
                XCTAssertEqual(blocked, activity)
            }
            XCTAssertEqual(service.activeExclusiveActivity, activity)
            service.releaseExclusiveActivity(lease)
        }
        XCTAssertEqual(provider.restoreCalls, 0)
        XCTAssertEqual(provider.releaseCalls, 0)
    }

    func testSelectedSourceRestorationJoinsCleanupAndResetWithoutDeletingWeights() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = previous }
        settings.selectedSpeechModel = .gigaam
        let (service, provider) = self.fixture()
        provider.releaseGate.isOpen = false
        service.isAsrReady = true
        var finished = false
        let operation = Task { try await service.useDefaultModelSource(.gigaam); finished = true }
        let entered = await self.waitUntil { provider.releaseEntered.isOpen }
        guard entered else { provider.openGates(); _ = try? await operation.value; return XCTFail("Cleanup was never entered") }
        XCTAssertTrue(provider.restored)
        XCTAssertFalse(finished)
        XCTAssertEqual(service.activeExclusiveActivity, .modelMaintenance)
        XCTAssertTrue(service.hasActiveModelDownload)
        XCTAssertTrue(service.isAsrReady)
        XCTAssertEqual(provider.probeCalls, 0)
        provider.releaseGate.open()
        try await operation.value
        XCTAssertTrue(finished)
        XCTAssertFalse(provider.releaseWasCancelled)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertGreaterThan(provider.probeCalls, 0)
        XCTAssertFalse(service.isAsrReady)
        XCTAssertTrue(service.modelsExistOnDisk)
        XCTAssertNil(service.activeExclusiveActivity)
        XCTAssertFalse(service.hasActiveModelDownload)
        let lease = try service.acquireExclusiveActivity(.dictation)
        service.releaseExclusiveActivity(lease)
    }

    func testCancelledSourceRestorationKeepsAdmissionThroughUncancelledCleanup() async throws {
        let (service, provider) = self.fixture()
        provider.sourceGate.isOpen = false
        provider.releaseGate.isOpen = false
        var finished = false
        let operation = Task {
            defer { finished = true }
            try await service.useDefaultModelSource(.gigaam)
        }
        let entered = await self.waitUntil { provider.sourceEntered.isOpen }
        guard entered else { provider.openGates(); _ = try? await operation.value; return XCTFail("Source mutation was never entered") }
        operation.cancel()
        provider.sourceGate.open()
        let cleanupEntered = await self.waitUntil { provider.releaseEntered.isOpen }
        guard cleanupEntered else { provider.openGates(); _ = try? await operation.value; return XCTFail("Cancelled operation skipped cleanup") }
        XCTAssertFalse(finished)
        XCTAssertEqual(service.activeExclusiveActivity, .modelMaintenance)
        XCTAssertTrue(service.hasActiveModelDownload)
        XCTAssertThrowsError(try service.acquireExclusiveActivity(.dictation))
        provider.releaseGate.open()
        do { try await operation.value; XCTFail("Cancelled source selection must fail") }
        catch is CancellationError {}
        XCTAssertFalse(provider.restored)
        XCTAssertFalse(provider.releaseWasCancelled)
        XCTAssertEqual(provider.releaseCalls, 1)
        XCTAssertEqual(provider.clearCalls, 0)
        XCTAssertNil(service.activeExclusiveActivity)
        XCTAssertFalse(service.hasActiveModelDownload)
    }
}
#endif
