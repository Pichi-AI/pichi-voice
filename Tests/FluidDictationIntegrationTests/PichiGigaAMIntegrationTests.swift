import Foundation
import PichiGigaAM
@testable import FluidVoice_Debug
import XCTest

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
            await PrivateAIIntegrationService.shared.unloadCachedRuntime(reason: "synthetic pipeline complete")
            await asr.shutdownForTermination()
            await provider.unloadModel()
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
        XCTAssertEqual(metadata.size, "~214.5 MiB")
        XCTAssertTrue(metadata.features.contains("INT8"))
        XCTAssertTrue(metadata.features.contains("Punctuation"))
        XCTAssertFalse(metadata.features.contains("FP16"))
        XCTAssertFalse(metadata.features.contains("end-of-utterance"))
        XCTAssertNil(descriptor.endOfUtteranceThreshold)
        XCTAssertFalse(metadata.performanceExplanation.contains("0.97 seconds"))
        XCTAssertTrue(metadata.performanceExplanation.contains("not measured transcription accuracy"))
    }

    @MainActor
    func testRealLocalAudioThroughProviderFilesAndAPIWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["PICHI_GIGAAM_APP_TEST_MODEL_DIR"],
              let audioPath = environment["PICHI_GIGAAM_APP_TEST_AUDIO"] else {
            throw XCTSkip("Set local model and approved audio paths to run real inference.")
        }
        let file = URL(fileURLWithPath: audioPath)
        let provider = PichiGigaAMProvider(modelStore: .init(directory: URL(fileURLWithPath: modelPath)))
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
        let originalModel = settings.selectedSpeechModel
        let originalSpeakerLabels = settings.fileTranscriptionSpeakerLabelsEnabled
        settings.selectedSpeechModel = .gigaam
        settings.fileTranscriptionSpeakerLabelsEnabled = false
        defer {
            settings.selectedSpeechModel = originalModel
            settings.fileTranscriptionSpeakerLabelsEnabled = originalSpeakerLabels
        }
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
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
        await provider.unloadModel()
        await asr.shutdownForTermination()
        XCTAssertFalse(provider.isReady)

        let meetingASR = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let meetingLease = try meetingASR.acquireExclusiveActivity(.meeting)
        defer { meetingASR.releaseExclusiveActivity(meetingLease) }
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
        await meetingASR.shutdownForTermination()
    }

    @MainActor
    func testGigaAMIsRussianUniversalAndUsesItsOwnProvider() throws {
        let model = SettingsStore.SpeechModel.gigaam
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertFalse(model.requiresAppleSilicon)
        XCTAssertTrue(model.hasPerformanceRatings)
        XCTAssertEqual(model.provider, .pichi)
        XCTAssertEqual(model.analyticsDescriptor.model, "gigaam-v3-eou")
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
            return .init(text: "Обсудили план встречи.", confidence: 0.9, sampleCount: 16_000, provider: "Pichi GigaAM v3")
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
        XCTAssertEqual(result["provider"] as? String, "Pichi GigaAM v3")
        XCTAssertEqual(result["sampleCount"] as? Int, 16_000)
    }

    @MainActor
    func testInvalidBase64DoesNotStartInference() async throws {
        var called = false
        let controller = InferenceAPIController { _ in
            called = true
            return .init(text: "", confidence: 0, sampleCount: 0, provider: "Pichi GigaAM v3")
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
