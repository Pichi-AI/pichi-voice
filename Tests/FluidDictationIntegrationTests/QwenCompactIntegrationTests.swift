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
private final class QwenInferenceTestGate {
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if self.opened { return }
        await withCheckedContinuation { self.waiting.append($0) }
    }
    func open() {
        self.opened = true
        let pending = self.waiting
        self.waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }
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

    func testRetirementClosesAdmissionThroughNativeJoinAndCleanupAndCoalescesRelease() async throws {
        let owner = TranscribeBoundedInferenceOwner()
        let entered = expectation(description: "native call entered")
        let cleanupEntered = expectation(description: "cleanup entered after native joined")
        let nativeGate = QwenInferenceTestGate()
        let cleanupGate = QwenInferenceTestGate()
        var nativeStarted = false
        var cleanupStarted = false
        defer { nativeGate.open(); cleanupGate.open() }
        var cleanupCalls = 0
        var successorCalls = 0
        let running = Task {
            try await owner.run {
                nativeStarted = true
                entered.fulfill()
                await nativeGate.wait()
                try Task.checkCancellation()
                return .init(text: "cancelled output")
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        guard nativeStarted else {
            nativeGate.open(); cleanupGate.open(); running.cancel()
            _ = await running.result
            return XCTFail("Native fixture did not start")
        }
        let retirement = owner.beginRetirement {
            cleanupCalls += 1
            cleanupStarted = true
            cleanupEntered.fulfill()
            await cleanupGate.wait()
        }
        let secondRetirement = owner.beginRetirement { XCTFail("Concurrent release must reuse the same cleanup") }
        XCTAssertTrue(owner.isRetiring)
        do {
            _ = try await owner.run { successorCalls += 1; return .init(text: "must not enter") }
            XCTFail("Retirement must synchronously close admission")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        nativeGate.open()
        await fulfillment(of: [cleanupEntered], timeout: 1)
        guard cleanupStarted else {
            cleanupGate.open()
            await retirement.value
            _ = await running.result
            return XCTFail("Retirement cleanup did not start")
        }
        do {
            _ = try await owner.run { successorCalls += 1; return .init(text: "must not enter during cleanup") }
            XCTFail("A completed native call must not reopen admission during cleanup")
        } catch { XCTAssertTrue(error is MeetingModelResidencyError) }
        XCTAssertEqual(successorCalls, 0)
        cleanupGate.open()
        await retirement.value
        await secondRetirement.value
        do { _ = try await running.value; XCTFail("Retired output must not return") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cleanupCalls, 1)
        XCTAssertFalse(owner.isRetiring)
        let successor = try await owner.run { .init(text: "successor") }
        XCTAssertEqual(successor.text, "successor")
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

    func testNewRecordingResolvesSelectedCapabilitiesWithoutMigratingStoredOrExplicitRequests() throws {
        let suite = "QwenRecordingMode.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.meetingSpeakerProcessingMode = .streaming
        settings.meetingSaveAudio = false
        settings.meetingPIIRedactionEnabled = true
        settings.selectedSpeechModel = .qwen3Asr06BQ4
        XCTAssertEqual(settings.meetingSpeakerProcessingMode(for: .inRoom), .streaming)
        XCTAssertEqual(settings.recordingSpeakerProcessingMode(for: .inRoom), .afterRecording)
        XCTAssertEqual(settings.recordingSpeakerProcessingMode(for: .onlineCall), .afterRecording)
        XCTAssertEqual(defaults.string(forKey: SettingsStore.Keys.meetingSpeakerProcessingMode), "streaming")
        XCTAssertFalse(settings.meetingSaveAudio)
        XCTAssertTrue(settings.meetingPIIRedactionEnabled)

        let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(
            for: SettingsStore.SpeechModel.qwen3Asr06BQ4.rawValue))
        let explicit = MeetingFinalProcessingConfiguration(asrModel: SettingsStore.SpeechModel.qwen3Asr06BQ4.rawValue,
            languageCode: "auto", speakerProcessingMode: .streaming)
        XCTAssertThrowsError(try descriptor.validateSpeakerProcessingMode(configuration: explicit, mode: .inRoom),
            "An explicit pinned unsupported request must still fail admission")
        settings.selectedSpeechModel = .gigaam
        XCTAssertEqual(settings.recordingSpeakerProcessingMode(for: .inRoom), .streaming,
            "Returning to a capable model restores the unchanged saved preference")
        XCTAssertEqual(settings.recordingSpeakerProcessingMode(for: .onlineCall),
                       settings.meetingSpeakerProcessingMode(for: .onlineCall),
            "Input topology is validated by admission, not silently changed by request resolution")
    }

    func testRecordingPresentationUsesRegisteredCapabilityAndRequestedMode() {
        let factory = PichiMeetingProviderFactory.self
        let qwenID = SettingsStore.SpeechModel.qwen3Asr06BQ4.rawValue
        let qwen = factory.recordingPresentation(for: qwenID, requestedMode: .streaming)
        XCTAssertFalse(qwen.updatesDuringRecording,
                       "An unsupported saved live preference must not advertise live Qwen output")
        XCTAssertEqual(qwen, factory.recordingPresentation(for: qwenID, requestedMode: .afterRecording))
        XCTAssertEqual(qwen.selectionDescription,
                       "Selected for new recordings. Text and speaker labels appear after recording stops.")
        XCTAssertEqual(qwen.progressDescription,
                       "Text and participant labels appear after recording stops. Processing can take some time.")
        XCTAssertEqual(qwen.speakerLabelsDescription,
                       "Speaker labels appear automatically after recording stops. Short or overlapping speech can be uncertain. You can correct participant names later.")

        for model in [SettingsStore.SpeechModel.gigaam, .whisperTiny, .parakeetTDT] {
            let live = factory.recordingPresentation(for: model.rawValue, requestedMode: .streaming)
            XCTAssertTrue(live.updatesDuringRecording)
            XCTAssertEqual(live.selectionDescription,
                           "Selected for new recordings. Text and speaker labels update during recording.")
            XCTAssertFalse(factory.recordingPresentation(for: model.rawValue,
                requestedMode: .afterRecording).updatesDuringRecording,
                "A live-capable model must still describe the explicitly selected offline mode")
        }
        XCTAssertFalse(factory.recordingPresentation(for: "unknown-future-model",
            requestedMode: .streaming).updatesDuringRecording)
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
