import CryptoKit
import Foundation
import XCTest
#if os(iOS)
@testable import PichiVoiceMobile
#else
@testable import FluidVoice_Debug
#endif

@MainActor
private final class QwenPreparationFixture: TranscriptionProvider {
    let name = "Qwen preparation fixture"
    let isAvailable = true
    var isReady = false
    var calls = 0
    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        self.calls += 1
        progressHandler?(.loading)
        self.isReady = true
    }
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult { .init(text: "fixture") }
    func modelsExistOnDisk() -> Bool { true }
    func releaseResidency() async { self.isReady = false }
}

@MainActor
final class QwenCompactIntegrationTests: XCTestCase {
    func testCatalogPublishesDistinctPinnedQ4WithoutWhisperControlsOrInventedRatings() throws {
        let model = SettingsStore.SpeechModel.qwen3Asr06BQ4
        let descriptor = try XCTUnwrap(TranscribeSpeechModelCatalog.descriptor(for: model))
        XCTAssertNotEqual(model.rawValue, SettingsStore.SpeechModel.qwen3Asr.rawValue)
        XCTAssertNotEqual(model.rawValue, SettingsStore.SpeechModel.qwen3Asr17B.rawValue)
        XCTAssertEqual(descriptor.expectedBytes, 589_560_480)
        XCTAssertEqual(model.expectedDownloadBytes, descriptor.expectedBytes)
        XCTAssertEqual(model.whisperModelFile, descriptor.fileName)
        XCTAssertEqual(WhisperProvider.modelDownloadURL(for: model)?.absoluteString,
                       "https://huggingface.co/handy-computer/Qwen3-ASR-0.6B-gguf/resolve/7e7c69a577fa2725dfedbe34b5e999336e30a19b/Qwen3-ASR-0.6B-Q4_K_M.gguf")
        XCTAssertEqual(descriptor.sha256, "5b58f32a58ffa2c8783e0b0963485623e286e6272d953dfc9e28bc3447dee0c0")
        XCTAssertFalse(model.isWhisperModel)
        XCTAssertFalse(model.supportsStreaming)
        XCTAssertFalse(model.hasPerformanceRatings)
        XCTAssertFalse(model.requiresIOS18)
        XCTAssertEqual(model.provider, .qwen)
        XCTAssertEqual(descriptor.maximumChunkSamples, 480_000)
        XCTAssertEqual(descriptor.contextTokens, 2_048)
    }

    func testNativeFamilyOptionsCannotForwardUnsupportedLanguageOrTimestamps() {
        for model in [SettingsStore.SpeechModel.qwen3Asr06BQ4, .qwen3Asr17B] {
            for language in [nil, "auto", "ru", "en"] as [String?] {
                let options = WhisperProvider.runOptions(languageCode: language, timestamps: .word,
                    model: model, whisperLanguageCode: "ru")
                XCTAssertNil(options.language)
                XCTAssertEqual(options.timestamps, .none)
            }
        }
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "ru", model: .whisperTiny).language, "ru")
        XCTAssertEqual(WhisperProvider.runOptions(languageCode: "ru", model: .whisperTiny).timestamps, .segment)
    }

    func testPinnedArtifactRejectsSameLengthCorruptionAndWrongSize() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.gguf")
        let data = Data("synthetic GGUF metadata".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let descriptor = TranscribeSpeechModelCatalog.Descriptor(fileName: url.lastPathComponent,
            repository: "synthetic/fixture", revision: "fixture", expectedBytes: Int64(data.count), sha256: hash,
            maximumChunkSamples: 4, contextTokens: 32)
        try data.write(to: url)
        XCTAssertNoThrow(try descriptor.validateArtifact(at: url))
        try Data(repeating: 1, count: data.count).write(to: url)
        XCTAssertThrowsError(try descriptor.validateArtifact(at: url))
        try Data([1]).write(to: url)
        XCTAssertThrowsError(try descriptor.validateArtifact(at: url))
    }

    func testChunkPolicyPreservesCoverageAndWordingWithoutFabricatingTiming() async throws {
        var seen: [[Float]] = []
        let result = try await TranscribeAudioChunkPolicy(maximumSamples: 4).transcribe(Array(0..<10).map(Float.init)) { chunk in
            seen.append(chunk)
            return ASRTranscriptionResult(text: " часть\(seen.count) ", confidence: 0.75,
                segmentTimings: [.init(text: "untrusted", start: 0, end: 1)])
        }
        XCTAssertEqual(seen.map(\.count), [4, 4, 2])
        XCTAssertEqual(seen.flatMap { $0 }, Array(0..<10).map(Float.init))
        XCTAssertEqual(result.text, "часть1 часть2 часть3")
        XCTAssertTrue(result.segmentTimings.isEmpty)
        XCTAssertEqual(result.confidence, 0.75)
    }

    func testChunkFailureDoesNotReturnAPartialTranscript() async {
        enum Failure: Error { case native }
        var calls = 0
        do {
            _ = try await TranscribeAudioChunkPolicy(maximumSamples: 2).transcribe([1, 2, 3]) { _ in
                calls += 1
                if calls == 2 { throw Failure.native }
                return .init(text: "partial")
            }
            XCTFail("A partial result must not be published")
        } catch { XCTAssertTrue(error is Failure) }
        XCTAssertEqual(calls, 2)
    }

    func testCancellationAfterNativeChunkJoinsBeforeNextChunk() async {
        var calls = 0
        let task = Task {
            return try await TranscribeAudioChunkPolicy(maximumSamples: 2).transcribe([1, 2, 3]) { _ in
                calls += 1
                withUnsafeCurrentTask { task in task?.cancel() }
                return .init(text: "partial must not return")
            }
        }
        do { _ = try await task.value; XCTFail("Cancellation must be forwarded") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testRetiredAttemptCannotContinueOrPublishEarlierChunkText() async {
        var generation = 1
        var calls = 0
        do {
            _ = try await TranscribeAudioChunkPolicy(maximumSamples: 2).transcribe([1, 2, 3], validate: {
                guard generation == 1 else { throw CancellationError() }
            }) { _ in
                calls += 1
                generation = 2
                return .init(text: "old session output")
            }
            XCTFail("A retired attempt must not return partial wording")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testOnboardingRouteUsesAutomaticModelBindingAndPreservesRussianDefault() throws {
        let russian = VoiceEngineLanguage(id: "ru", displayName: "Russian", aliases: [], isPopular: true)
        let routes = VoiceEngineLanguageCatalog.routes(for: russian, availableModels: [.qwen3Asr06BQ4])
        XCTAssertEqual(routes.count, 1)
        XCTAssertEqual(routes.first?.model, .qwen3Asr06BQ4)
        XCTAssertEqual(routes.first?.binding, .automatic)
        XCTAssertEqual(SettingsStore.SpeechModel.defaultModel, .gigaam)
        XCTAssertTrue(SettingsStore.SpeechModel.models(for: .qwen).contains(.qwen3Asr06BQ4))
    }

    func testMeetingRegistrationAdmitsOnlyTruthfulCapabilities() throws {
        let id = SettingsStore.SpeechModel.qwen3Asr06BQ4.rawValue
        let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: id))
        XCTAssertEqual(descriptor.supportedLanguageCodes, ["auto"])
        XCTAssertEqual(descriptor.supportedFinalPrecisions, [.utterance])
        XCTAssertEqual(descriptor.supportedSpeakerProcessingModes, [.afterRecording])
        let configuration = PichiMeetingProviderFactory.validationConfiguration(backendID: .qwen06Q4,
            languageCode: "auto", diarizationEnabled: false)
        let provider = try WhisperProvider(meetingConfiguration: configuration)
        XCTAssertEqual(provider.modelOverride, .qwen3Asr06BQ4)
        XCTAssertNil(provider.resolvedLanguageCode(explicit: "ru"))
    }

    func testSettingsAndOnboardingUseSamePreparationAdmissionWithoutChangingSelection() async throws {
        let settings = SettingsStore.shared
        let selection = settings.selectedSpeechModel
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let fixture = QwenPreparationFixture()
        service.modelProvidersForTesting[.qwen3Asr06BQ4] = fixture
        do {
            for source in [AnalyticsModelDownloadSource.settings, .onboarding] {
                #if os(iOS)
                try await service.downloadModel(.qwen3Asr06BQ4, progressHandler: nil)
                #else
                try await service.downloadModel(.qwen3Asr06BQ4, source: source, progressHandler: nil)
                #endif
                XCTAssertFalse(service.hasActiveModelDownload)
                XCTAssertNil(service.downloadingModelId)
                XCTAssertEqual(settings.selectedSpeechModel, selection)
            }
            XCTAssertEqual(fixture.calls, 2)
            await service.shutdownForTermination()
        } catch {
            await service.shutdownForTermination()
            throw error
        }
    }
}
