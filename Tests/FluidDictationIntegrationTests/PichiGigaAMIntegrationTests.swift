import Foundation
import PichiGigaAM
@testable import FluidVoice_Debug
import XCTest

final class PichiGigaAMIntegrationTests: XCTestCase {
    @MainActor
    func testImportedExportControlsLibraryCapabilitiesAndMeasurementProvenance() throws {
        let model = SettingsStore.SpeechModel.gigaam
        let preferred = try XCTUnwrap(GigaAMModelCatalog.models.first)
        let metadata = try XCTUnwrap(model.libraryMetadata)
        XCTAssertEqual(metadata, preferred.libraryMetadata)
        XCTAssertEqual(model.supportedLanguageCodes, "RU")
        XCTAssertEqual(model.supportedLanguageNames, "Russian")
        XCTAssertTrue(metadata.features.contains("Punctuation"))
        XCTAssertTrue(metadata.features.contains("capitalization"))
        XCTAssertTrue(metadata.features.contains("normalization"))
        XCTAssertTrue(metadata.performance.explanation.contains("excluding model loading"))
        XCTAssertTrue(metadata.performance.explanation.contains("has not been evaluated"))
        XCTAssertFalse(model.hasPerformanceRatings, "Published base WER is not a relative product score")

        for descriptor in GigaAMModelCatalog.models.dropFirst() {
            let older = descriptor.libraryMetadata
            XCTAssertNotEqual(older.size, metadata.size)
            XCTAssertTrue(older.features.contains("does not add punctuation or capitalization"))
            XCTAssertEqual(older.performance.speed, "CPU inference")
            XCTAssertNotEqual(older.performance.accuracy, metadata.performance.accuracy)
            XCTAssertTrue(older.performance.explanation.contains("has not been benchmarked"))
        }
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
        XCTAssertFalse(model.hasPerformanceRatings)
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
