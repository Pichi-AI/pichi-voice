import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import PichiGigaAM
import XCTest
#if os(iOS)
@testable import PichiVoiceMobile
#else
@testable import FluidVoice_Debug
#endif

/// Test-only staging root shared by desktop and app-hosted mobile integration tests.
/// The sentinel avoids putting a host path or a changing device-container UUID in xctestrun.
nonisolated enum MobileInferenceTestAssets {
    static let environmentKey = "PICHI_MOBILE_INFERENCE_ASSETS"
    static let applicationSupportLocation = "application-support"

    enum ResolutionError: Error, Equatable {
        case invalidRoot
        case applicationSupportUnavailable
    }

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportDirectory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) throws -> URL {
        guard let location = environment[self.environmentKey], !location.isEmpty else {
            throw XCTSkip("Set PICHI_MOBILE_INFERENCE_ASSETS to an absolute public-model/synthetic-audio directory or application-support.")
        }
        if location == self.applicationSupportLocation {
            guard let directory = applicationSupportDirectory, directory.isFileURL else {
                throw ResolutionError.applicationSupportUnavailable
            }
            return directory.appendingPathComponent("MobileInferenceAssets", isDirectory: true)
        }
        guard (location as NSString).isAbsolutePath else { throw ResolutionError.invalidRoot }
        return URL(fileURLWithPath: location, isDirectory: true)
    }
}

@MainActor
final class MobileInferenceTestAssetsTests: XCTestCase {
    func testMissingOrEmptyConfigurationSkipsOptInInference() {
        for environment in [[:], [MobileInferenceTestAssets.environmentKey: ""]] {
            XCTAssertThrowsError(try MobileInferenceTestAssets.resolve(environment: environment)) { error in
                XCTAssertTrue(error is XCTSkip)
            }
        }
    }

    func testApplicationSupportSentinelUsesTheCurrentAppContainer() throws {
        let directory = URL(fileURLWithPath: "/test-app-container/Library/Application Support", isDirectory: true)
        let root = try MobileInferenceTestAssets.resolve(
            environment: [MobileInferenceTestAssets.environmentKey: "application-support"],
            applicationSupportDirectory: directory
        )
        XCTAssertEqual(root.path, "/test-app-container/Library/Application Support/MobileInferenceAssets")
        XCTAssertTrue(root.hasDirectoryPath)
    }

    func testAbsoluteHostFixturePathRemainsUnchanged() throws {
        let root = try MobileInferenceTestAssets.resolve(
            environment: [MobileInferenceTestAssets.environmentKey: "/test-host/public fixtures"],
            applicationSupportDirectory: nil
        )
        XCTAssertEqual(root.path, "/test-host/public fixtures")
    }

    func testInvalidConfigurationFailsInsteadOfUsingTheWorkingDirectory() {
        XCTAssertThrowsError(try MobileInferenceTestAssets.resolve(
            environment: [MobileInferenceTestAssets.environmentKey: "relative-fixtures"]
        )) { error in
            XCTAssertEqual(error as? MobileInferenceTestAssets.ResolutionError, .invalidRoot)
        }
        XCTAssertThrowsError(try MobileInferenceTestAssets.resolve(
            environment: [MobileInferenceTestAssets.environmentKey: "application-support"],
            applicationSupportDirectory: nil
        )) { error in
            XCTAssertEqual(error as? MobileInferenceTestAssets.ResolutionError, .applicationSupportUnavailable)
        }
    }
}

/// Explicitly enabled public artifacts plus synthetic audio only. The same source runs
/// in the hosted mobile target; that execution uses the adapters' actual CPU-only route.
@MainActor
final class MobileRegisteredModelInferenceTests: XCTestCase {
    private final nonisolated class TinyQualityReport: @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [[String: Any]] = []
        func append(_ row: [String: Any]) { lock.withLock { rows.append(row) } }
        func data() throws -> Data {
            try lock.withLock { try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) }
        }
    }
    private final nonisolated class LiveObservations: @unchecked Sendable {
        private let lock = NSLock()
        private var ready = false
        private var partials: [String] = []
        private var utterances: [String] = []
        private var failures: [String] = []
        func markReady() { self.lock.withLock { self.ready = true } }
        func partial(_ text: String) { self.lock.withLock { self.partials.append(text) } }
        func utterance(_ text: String) { self.lock.withLock { self.utterances.append(text) } }
        func failure(_ text: String) { self.lock.withLock { self.failures.append(text) } }
        func snapshot() -> (ready: Bool, partials: [String], utterances: [String], failures: [String]) {
            self.lock.withLock { (self.ready, self.partials, self.utterances, self.failures) }
        }
    }
    private struct Observation: Codable {
        let modelID: String
        let fixture: String
        let languagePolicy: String
        let sampleCount: Int
        let streamingText: String
        let finalText: String
        let wordCount: Int
        let streamingMilliseconds: Int
        let finalMilliseconds: Int
        let normalizedParity: Bool
        let russianAnchor: Bool
        let englishAnchor: Bool
        let platform: String
    }

    private func assets() throws -> URL {
        try MobileInferenceTestAssets.resolve()
    }

    private func pcm(_ file: String, in root: URL) throws -> [Float] {
        let input = try AVAudioFile(forReading: root.appendingPathComponent("audio/\(file).wav"))
        XCTAssertEqual(input.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(input.processingFormat.channelCount, 1)
        guard input.length > 0, input.length <= 320_000,
              let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: AVAudioFrameCount(input.length)) else {
            throw NSError(domain: "MobileInferenceFixture", code: 1)
        }
        try input.read(into: buffer)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?[0]), count: Int(buffer.frameLength)))
    }

    private func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
    }

    /// Explicitly staged public TTS with known text, rather than a nonempty-result
    /// assertion. Exact inputs/outputs remain in private XCTest artifacts only.
    func testWhisperTinyKnownRussianAndEnglishQuality() async throws {
        guard ProcessInfo.processInfo.environment["PICHI_TINY_GROUNDTRUTH_E2E"] == "1" else {
            throw XCTSkip("Explicitly stage the approved Tiny groundtruth fixtures")
        }
        let root = try self.assets()
        let fixtures = [
            ("ru-long", "Сегодня обсуждаем инструкцию к препарату. После встречи я пришлю документ.",
             "a943c582f68746f7d56f8ba232dd574b305a45789992430d21a7ac33f849b2e0"),
            ("en-long", "We will review the document and discuss the results after the meeting.",
             "641ffa1e07997b723733c2ca86442c1f21899f6d108388a4c0da28fc991a5757")
        ]
        let configuration = try await self.installedConfiguration(model: .whisperTiny, assets: root)
        XCTAssertEqual(configuration.languageCode, "auto")
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { service },
                                                    modelLocator: MeetingNemotronModelLocator())
        let attempt = UUID()
        let observations = TinyQualityReport()
        defer {
            if let data = try? observations.data() {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "Tiny-approved-groundtruth-\(ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "unknown")"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        do {
            #if os(macOS)
            try await service.retireDictationASRResourcesForMeeting(lease: lease)
            #endif
            try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.withPreparedASR(attemptID: attempt, configuration: configuration) { session in
                    for (name, expected, hash) in fixtures {
                        let file = root.appendingPathComponent("audio/\(name).wav")
                        let actualHash = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
                        XCTAssertEqual(actualHash, hash, "The expected text must refer to this exact approved fixture")
                        guard actualHash == hash else { throw NSError(domain: "UnapprovedTinyFixture", code: 1) }
                        let samples = try await self.pcm(name, in: root)
                        for scale: Float in [1, 0.01] {
                            let input = scale == 1 ? samples : samples.map { $0 * scale }
                            let began = ProcessInfo.processInfo.systemUptime
                            let result = try await session.transcribeWithTimings(input)
                            let elapsed = ProcessInfo.processInfo.systemUptime - began
                            let expectedWords = await self.normalized(expected).split(separator: " ").map(String.init)
                            let outputWords = await self.normalized(result.result.text).split(separator: " ").map(String.init)
                            let errors = Self.wordEditDistance(expectedWords, outputWords)
                            let rate = Double(errors) / Double(expectedWords.count)
                            observations.append(["fixture": name, "sha256": actualHash, "amplitudeScale": scale,
                                "inputText": expected, "outputText": result.result.text,
                                "wordErrors": errors, "wordErrorRate": rate, "samples": input.count,
                                "durationSeconds": Double(input.count) / 16_000, "inferenceSeconds": elapsed,
                                "nativeSegmentCount": result.result.segmentTimings.count, "wordTimingCount": result.words.count])
                            XCTAssertFalse(result.result.segmentTimings.isEmpty,
                                "The segment-only native fallback must retain its actual utterance intervals")
                            XCTAssertEqual(ASRSegmentTiming.validated(result.result.segmentTimings,
                                text: result.result.text, duration: Double(input.count) / 16_000), result.result.segmentTimings)
                            XCTAssertLessThanOrEqual(rate, 0.10, "Tiny must recognize the known full sentence in its original language")
                            XCTAssertLessThan(elapsed, Double(input.count) / 16_000,
                                              "Native Tiny inference must keep up with the duration of this fixture")
                        }
                    }
                    let zero = try await session.transcribeWithTimings([Float](repeating: 0, count: 48_000))
                    XCTAssertTrue(zero.result.text.isEmpty)
                    return MeetingParakeetPhaseResult()
                }
            }
            XCTAssertFalse(service.hasActiveModelPreparation)
            await service.shutdownForTermination()
        } catch {
            await service.shutdownForTermination()
            throw error
        }
    }

    private nonisolated static func wordEditDistance(_ expected: [String], _ actual: [String]) -> Int {
        var previous = Array(0...actual.count)
        for (index, word) in expected.enumerated() {
            var current = [index + 1]
            for (column, output) in actual.enumerated() {
                current.append(min(current[column] + 1, previous[column + 1] + 1,
                                   previous[column] + (word == output ? 0 : 1)))
            }
            previous = current
        }
        return previous.last ?? expected.count
    }

    private func configuration(modelID: String, root: URL, fingerprint: String? = nil) -> MeetingFinalProcessingConfiguration {
        MeetingFinalProcessingConfiguration(
            asrModel: modelID, asrArtifactFingerprint: fingerprint,
            asrArtifactDirectory: root, languageCode: PichiMeetingProviderFactory.defaultLanguageCode(for: modelID) ?? "auto",
            diarizationFingerprint: PichiMeetingProviderFactory.transcriptOnlyDiarizationFingerprint,
            speakerLabelsEnabled: false
        )
    }

    private func installedConfiguration(model: SettingsStore.SpeechModel, assets: URL) async throws -> MeetingFinalProcessingConfiguration {
        let root = assets.appendingPathComponent("models/\(model.rawValue)", isDirectory: true)
        let installation: MeetingFinalProcessingConfiguration
        if model == .parakeetTDT {
            installation = MeetingFinalProcessingConfiguration(
                asrModel: model.rawValue, languageCode: "auto",
                diarizationFingerprint: PichiMeetingProviderFactory.transcriptOnlyDiarizationFingerprint,
                speakerLabelsEnabled: false
            )
        } else {
            installation = self.configuration(modelID: model.rawValue, root: root)
        }
        let provider = try PichiMeetingProviderFactory.make(installation)
        #if arch(arm64) && DEBUG
        if let parakeet = provider as? FluidAudioProvider { parakeet.modelCacheRootForTesting = root }
        #endif
        do {
            try await provider.prepare(progressHandler: nil)
            XCTAssertTrue(provider.isReady)
            await provider.releaseResidency()
        } catch {
            await provider.releaseResidency()
            throw error
        }
        switch model {
        case .gigaam:
            let installed = try PichiGigaAMModelStore(directory: root).installedModel()
            XCTAssertEqual(installed.descriptor, GigaAMModelCatalog.downloadableModel)
            return self.configuration(modelID: model.rawValue, root: installed.directory,
                                      fingerprint: installed.descriptor.fingerprint)
        case .whisperTiny:
            return self.configuration(modelID: model.rawValue, root: root,
                                      fingerprint: try WhisperProvider.installedArtifactFingerprint(for: model, directory: root))
        case .parakeetTDT:
            let descriptor = ParakeetSpeechModelCatalog.v3
            let directory = descriptor.cacheDirectory(in: root)
            return self.configuration(modelID: model.rawValue, root: directory,
                                      fingerprint: try descriptor.installedArtifactFingerprint(at: directory))
        default:
            throw MeetingProviderOptionsError.unsupportedASRModel(model.rawValue)
        }
    }

    func testPCMAdmissionRejectsAnUnpreparedOrChangedAttemptBeforeInference() async throws {
        var serviceRequested = false
        let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: {
            serviceRequested = true
            return ASRService()
        }, modelLocator: MeetingNemotronModelLocator())
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", languageCode: "ru",
                                                                diarizationFingerprint: PichiMeetingProviderFactory.transcriptOnlyDiarizationFingerprint,
                                                                speakerLabelsEnabled: false)
        let attempt = UUID()
        do {
            _ = try await runtime.recognizePCM(samples: [Float](repeating: 0.1, count: 16_000), offset: 0,
                                               trackID: UUID(), attemptID: attempt, configuration: configuration)
            XCTFail("An unprepared attempt must fail before requesting the inference owner.")
        } catch { XCTAssertEqual(error as? MeetingModelResidencyError, .staleGrant) }
        try await runtime.preparePCMResources(attemptID: attempt, configuration: configuration)
        let changed = MeetingFinalProcessingConfiguration(asrModel: "gigaam-v3-eou", asrArtifactFingerprint: "changed",
                                                          languageCode: "ru", diarizationFingerprint: configuration.diarizationFingerprint,
                                                          speakerLabelsEnabled: false)
        do {
            try await runtime.preparePCMResources(attemptID: attempt, configuration: changed)
            XCTFail("A prepared attempt cannot replace its frozen configuration.")
        } catch { XCTAssertEqual(error as? MeetingModelResidencyError, .staleGrant) }
        XCTAssertFalse(serviceRequested)
    }

    func testPublicMobileArtifactsRecognizeRUENMixedAndPreserveStreamingTiming() async throws {
        let root = try self.assets()
        var report: [Observation] = []
        let reportDirectory = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        func saveReport() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportDirectory.appendingPathComponent("registered-model-inference.json"), options: .atomic)
        }
        for model: SettingsStore.SpeechModel in [.gigaam, .whisperTiny, .parakeetTDT] {
            let configuration = try await self.installedConfiguration(model: model, assets: root)
            let provider = try PichiMeetingProviderFactory.make(configuration)
            do {
                try await provider.prepare(progressHandler: nil)
                for fixture in model == .gigaam ? ["ru"] : ["ru", "en", "mixed", "tail"] {
                    let samples = try self.pcm(fixture, in: root)
                    let streamingStart = ProcessInfo.processInfo.systemUptime
                    let streaming = try await provider.transcribeStreaming(samples)
                    let streamingMilliseconds = Int((ProcessInfo.processInfo.systemUptime - streamingStart) * 1000)
                    let finalStart = ProcessInfo.processInfo.systemUptime
                    let output = try await provider.transcribeWithWordTimings(samples)
                    let finalMilliseconds = Int((ProcessInfo.processInfo.systemUptime - finalStart) * 1000)
                    let duration = Double(samples.count) / 16_000
                    XCTAssertTrue(output.words.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 1e-6 })
                    if fixture != "tail" { XCTAssertFalse(output.result.text.isEmpty) }
                    let text = self.normalized(output.result.text)
                    report.append(Observation(modelID: model.rawValue, fixture: fixture,
                                              languagePolicy: configuration.languageCode, sampleCount: samples.count,
                                              streamingText: streaming.text, finalText: output.result.text,
                                              wordCount: output.words.count, streamingMilliseconds: streamingMilliseconds,
                                              finalMilliseconds: finalMilliseconds,
                                              normalizedParity: self.normalized(streaming.text) == text,
                                              russianAnchor: text.contains("документ") || text.contains("инструкци"),
                                              englishAnchor: text.contains("document") || text.contains("instruction"),
                                              platform: ProcessInfo.processInfo.operatingSystemVersionString))
                    try saveReport()
                }
                await provider.releaseResidency()
                XCTAssertFalse(provider.isReady)
            } catch {
                await provider.releaseResidency()
                try saveReport()
                throw error
            }
        }
        XCTAssertEqual(report.count, 9)
    }

    func testRegisteredStrictPCMWindowsCreateTranscriptWithoutAudioFiles() async throws {
        let root = try self.assets()
        let samples = try self.pcm("ru", in: root)
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        do {
            #if os(macOS)
            try await service.retireDictationASRResourcesForMeeting(lease: lease)
            #endif
            let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { service }, modelLocator: MeetingNemotronModelLocator())
            let track = UUID()
            for model: SettingsStore.SpeechModel in [.gigaam, .whisperTiny, .parakeetTDT] {
                let configuration = try await self.installedConfiguration(model: model, assets: root)
                let attempt = UUID()
                try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                    try await runtime.preparePCMResources(attemptID: attempt, configuration: configuration)
                }
                let batch = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                    try await runtime.recognizePCM(samples: samples, offset: 12, trackID: track,
                                                   attemptID: attempt, configuration: configuration)
                }
                XCTAssertFalse(batch.segments.isEmpty)
                XCTAssertTrue(batch.segments.allSatisfy { $0.start.seconds >= 12 && $0.end.seconds <= 12 + Double(samples.count) / 16_000 + 0.001 })
                XCTAssertTrue(batch.segments.allSatisfy { $0.speakerID == nil })
                XCTAssertTrue(batch.speakers.isEmpty)
                let files = FileManager.default.enumerator(at: root.appendingPathComponent("models"), includingPropertiesForKeys: nil)
                let audioExtensions: Set<String> = ["wav", "aiff", "aif", "caf", "m4a", "pcm", "flac"]
                XCTAssertFalse((files?.allObjects as? [URL] ?? []).contains { audioExtensions.contains($0.pathExtension.lowercased()) })
            }
            await service.shutdownForTermination()
        } catch {
            await service.shutdownForTermination()
            throw error
        }
    }

    func testOriginalBufferedCaptionEngineUsesEachRegisteredPublicArtifact() async throws {
        let root = try self.assets()
        let samples = try self.pcm("ru", in: root)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                         interleaved: false) else { throw NSError(domain: "MobileInferenceFixture", code: 2) }
        var report: [[String: String]] = []
        for model: SettingsStore.SpeechModel in [.gigaam, .whisperTiny, .parakeetTDT] {
            let configuration = try await self.installedConfiguration(model: model, assets: root)
            let provider = try PichiMeetingProviderFactory.make(configuration)
            let recognizer = PichiMeetingCaptionRecognizer(provider: provider)
            let engine = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: recognizer)
            let observations = LiveObservations()
            await engine.configure(onPartial: { _, _, text, _, _ in observations.partial(text) },
                                   onUtterance: { _, _, text, _, _ in observations.utterance(text) },
                                   onDegraded: { _, text in observations.failure(text) },
                                   onReady: { _ in observations.markReady() })
            await engine.start()
            do {
                let deadline = ProcessInfo.processInfo.systemUptime + 60
                while !observations.snapshot().ready, observations.snapshot().failures.isEmpty,
                      ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                XCTAssertTrue(observations.snapshot().ready)
                let offered = samples + [Float](repeating: 0, count: 16_000)
                // Live previews describe current audio. Pace the capture fixture instead of
                // making every prefix obsolete by queueing the complete recording at once.
                let pacingStart = ProcessInfo.processInfo.systemUptime
                for start in stride(from: 0, to: offered.count, by: 1600) {
                    let delay = pacingStart + Double(start) / 16_000 - ProcessInfo.processInfo.systemUptime
                    if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                    let end = min(offered.count, start + 1600)
                    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(end - start)))
                    buffer.frameLength = AVAudioFrameCount(end - start)
                    let target = try XCTUnwrap(buffer.floatChannelData?[0])
                    for index in start..<end { target[index - start] = offered[index] }
                    engine.offer(.init(buffer: buffer, pts: CMTime(value: Int64(start), timescale: 16_000),
                                       duration: CMTime(value: Int64(end - start), timescale: 16_000)))
                }
                let drainDeadline = ProcessInfo.processInfo.systemUptime + 60
                while observations.snapshot().utterances.isEmpty, observations.snapshot().failures.isEmpty,
                      ProcessInfo.processInfo.systemUptime < drainDeadline {
                    try await Task.sleep(for: .milliseconds(20))
                }
                let actual = observations.snapshot()
                XCTAssertTrue(actual.failures.isEmpty, actual.failures.joined(separator: "; "))
                XCTAssertFalse(actual.partials.isEmpty)
                XCTAssertFalse(actual.utterances.isEmpty)
                report.append(["modelID": model.rawValue, "partialCount": String(actual.partials.count),
                               "committedText": actual.utterances.joined(separator: "\n")])
                await engine.stop()
                await recognizer.unload()
            } catch {
                await engine.stop()
                await recognizer.unload()
                throw error
            }
        }
        let reportDirectory = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportDirectory.appendingPathComponent("buffered-live-inference.json"), options: .atomic)
    }

    func testPinnedNemotronAndLocalWeSpeakerSeparateTwoSyntheticVoicesAcrossPCMWindows() async throws {
        let root = try self.assets()
        let samples = try self.pcm("two-voices", in: root)
        let speakerRoot = root.appendingPathComponent("models/speaker-resources", isDirectory: true)
        let package = speakerRoot.appendingPathComponent("nemotron/v1/\(MeetingNemotronModelLocator.packageFileName)", isDirectory: true)
        let voicePackage = speakerRoot.appendingPathComponent("voice/\(MeetingSpeakerVoiceModelArtifacts.packageName)", isDirectory: true)
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: {
                _ = try MeetingModelInstaller.validatedSilenceEmbedding(at: MeetingModelInstaller.silenceEmbeddingURL(besides: package))
                return try MeetingModelInstaller.validate(package)
            },
            install: { progress in try await MeetingDiarizationModelStore.downloadAndInstall(to: package, progress: progress) },
            validateVoice: { try MeetingSpeakerVoiceModelArtifacts.validate(at: voicePackage) },
            installVoice: { progress in try await MeetingSpeakerVoiceModelArtifacts.ensureInstalled(at: voicePackage, progress: progress) }
        )
        // Same common resource preflight used by the mobile settings/start owner.
        try await store.prepare(dependencies: [.speakerSeparation, .voiceMatching])
        XCTAssertTrue(store.allSpeakerResourcesReady)
        try MeetingSpeakerVoiceModelArtifacts.validate(at: voicePackage)
        let installed = try await self.installedConfiguration(model: .parakeetTDT, assets: root)
        let configuration = MeetingFinalProcessingConfiguration(
            asrModel: installed.asrModel, asrArtifactFingerprint: installed.asrArtifactFingerprint,
            asrArtifactDirectory: installed.asrArtifactDirectory, languageCode: "auto",
            diarizationFingerprint: MeetingProcessingCheckpoint.currentDiarizationFingerprint,
            speakerLabelsEnabled: true
        )
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        do {
            #if os(macOS)
            try await service.retireDictationASRResourcesForMeeting(lease: lease)
            #endif
            let locator = MeetingNemotronModelLocator(injectedURL: package)
            let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { service }, modelLocator: locator,
                                                        voiceModelDirectory: voicePackage)
            let track = UUID()
            let attempt = UUID()
            let duration = Double(samples.count) / 16_000
            try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.preparePCMResources(attemptID: attempt, configuration: configuration)
            }
            let archive = try MeetingMemoryAudioArchive()
            try samples.withUnsafeBufferPointer { try archive.append($0) }
            try archive.seal()
            defer { archive.clear() }
            let live = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.recognizePCM(samples: samples, offset: 0, trackID: track,
                    attemptID: attempt, configuration: configuration)
            }
            XCTAssertTrue(live.speakers.isEmpty)
            XCTAssertTrue(live.segments.allSatisfy { $0.speakerID == nil }, "Recording must not assign speakers")
            let first = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.diarizePCMRecording(source: archive, transcript: live, trackID: track,
                    attemptID: attempt, configuration: configuration)
            }
            let second = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.diarizePCMRecording(source: archive, transcript: live, trackID: track,
                    attemptID: attempt, configuration: configuration)
            }
            XCTAssertEqual(first.segments.map(\.id), live.segments.map(\.id))
            XCTAssertEqual(first.segments.map(\.text), live.segments.map(\.text))
            XCTAssertEqual(first.segments.map(\.start), live.segments.map(\.start))
            XCTAssertEqual(first.segments.map(\.end), live.segments.map(\.end))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let reportDirectory = root.appendingPathComponent("reports", isDirectory: true)
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            try encoder.encode([first.speakers, second.speakers]).write(to: reportDirectory.appendingPathComponent("two-voice-speakers.json"), options: .atomic)
            try encoder.encode([first.segments, second.segments]).write(to: reportDirectory.appendingPathComponent("two-voice-segments.json"), options: .atomic)
            XCTAssertGreaterThanOrEqual(first.speakers.count, 2, "Two public synthetic voices should yield distinct measured identities.")
            XCTAssertTrue(first.speakers.allSatisfy { !$0.isLocalUser })
            XCTAssertFalse(first.segments.filter { $0.speakerID != nil }.isEmpty)
            XCTAssertTrue(Set(second.speakers.map(\.id)).isSubset(of: Set(first.speakers.map(\.id))),
                          "Explicit local embedding evidence should reconnect the repeated voices, not slot equality.")
            XCTAssertEqual(second.segments.map(\.id), first.segments.map(\.id))
            await service.shutdownForTermination()
        } catch {
            await service.shutdownForTermination()
            throw error
        }
    }

    func testDefaultEightSecondSpeakerWindowsForAllRegisteredModels() async throws {
        let root = try self.assets()
        let samples = try self.pcm("two-voices", in: root)
        let speakerRoot = root.appendingPathComponent("models/speaker-resources", isDirectory: true)
        let package = speakerRoot.appendingPathComponent("nemotron/v1/\(MeetingNemotronModelLocator.packageFileName)", isDirectory: true)
        let voicePackage = speakerRoot.appendingPathComponent("voice/\(MeetingSpeakerVoiceModelArtifacts.packageName)", isDirectory: true)
        let store = MeetingDiarizationModelStore(
            canDownload: { true }, validate: { try MeetingModelInstaller.validate(package) },
            install: { try await MeetingDiarizationModelStore.downloadAndInstall(to: package, progress: $0) },
            validateVoice: { try MeetingSpeakerVoiceModelArtifacts.validate(at: voicePackage) },
            installVoice: { try await MeetingSpeakerVoiceModelArtifacts.ensureInstalled(at: voicePackage, progress: $0) }
        )
        try await store.prepare(dependencies: [.speakerSeparation, .voiceMatching])
        var report: [[String: Any]] = []
        let reportDirectory = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        for model: SettingsStore.SpeechModel in [.gigaam, .whisperTiny, .parakeetTDT] {
            let installed = try await self.installedConfiguration(model: model, assets: root)
            let configuration = MeetingFinalProcessingConfiguration(
                asrModel: installed.asrModel, asrArtifactFingerprint: installed.asrArtifactFingerprint,
                asrArtifactDirectory: installed.asrArtifactDirectory, languageCode: installed.languageCode,
                diarizationFingerprint: MeetingProcessingCheckpoint.currentDiarizationFingerprint,
                speakerLabelsEnabled: true
            )
            let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
            let lease = try service.acquireExclusiveActivity(.meeting)
            defer { service.releaseExclusiveActivity(lease) }
            do {
                #if os(macOS)
                try await service.retireDictationASRResourcesForMeeting(lease: lease)
                #endif
                let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { service },
                                                            modelLocator: MeetingNemotronModelLocator(injectedURL: package),
                                                            voiceModelDirectory: voicePackage)
                let track = UUID()
                let attempt = UUID()
                try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                    try await runtime.preparePCMResources(attemptID: attempt, configuration: configuration)
                }
                let archive = try MeetingMemoryAudioArchive()
                try samples.withUnsafeBufferPointer { try archive.append($0) }
                try archive.seal()
                defer { archive.clear() }
                var speech = MeetingPCMTranscriptBatch(segments: [])
                for start in stride(from: 0, to: samples.count, by: 128_000) {
                    let end = min(samples.count, start + 128_000)
                    let input = Array(samples[start..<end])
                    let batch = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                        try await runtime.recognizePCM(samples: input, offset: Double(start) / 16_000, trackID: track,
                            attemptID: attempt, configuration: configuration)
                    }
                    XCTAssertTrue(batch.speakers.isEmpty)
                    XCTAssertTrue(batch.segments.allSatisfy { $0.speakerID == nil })
                    speech.segments.append(contentsOf: batch.segments)
                }
                let final = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                    try await runtime.diarizePCMRecording(source: archive, transcript: speech, trackID: track,
                        attemptID: attempt, configuration: configuration)
                }
                XCTAssertGreaterThanOrEqual(final.speakers.count, 2)
                XCTAssertGreaterThan(final.segments.filter { $0.speakerID != nil }.count, 0)
                XCTAssertEqual(final.segments.map(\.id), speech.segments.map(\.id))
                XCTAssertEqual(final.segments.map(\.text), speech.segments.map(\.text))
                report.append(["modelID": model.rawValue, "segments": final.segments.count,
                    "speakerCount": final.speakers.count, "stage": "after-stop"])
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: reportDirectory.appendingPathComponent("post-stop-speaker-windows.json"), options: .atomic)
                await service.shutdownForTermination()
            } catch {
                await service.shutdownForTermination()
                throw error
            }
        }
        XCTAssertEqual(report.count, 3)
    }

    /// Measures the complete sequential model workload on synthetic speech. This does not
    /// use a microphone or change app preferences, and is not an hour-long thermal test.
    func testStrictGigaAMWindowCadenceBenchmark() async throws {
        guard ProcessInfo.processInfo.environment["PICHI_STRICT_CADENCE_PROBE"] == "1" else {
            throw XCTSkip("Enable the public-model strict cadence measurement explicitly")
        }
        let root = try self.assets()
        let source = try self.pcm("two-voices", in: root)
        XCTAssertFalse(source.isEmpty)
        let resources = root.appendingPathComponent("models/speaker-resources", isDirectory: true)
        let package = resources.appendingPathComponent("nemotron/v1/\(MeetingNemotronModelLocator.packageFileName)", isDirectory: true)
        let voice = resources.appendingPathComponent("voice/\(MeetingSpeakerVoiceModelArtifacts.packageName)", isDirectory: true)
        let installed = try await self.installedConfiguration(model: .gigaam, assets: root)
        let configuration = MeetingFinalProcessingConfiguration(asrModel: installed.asrModel,
            asrArtifactFingerprint: installed.asrArtifactFingerprint, asrArtifactDirectory: installed.asrArtifactDirectory,
            languageCode: installed.languageCode, diarizationFingerprint: MeetingProcessingCheckpoint.currentDiarizationFingerprint,
            speakerLabelsEnabled: true)
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        let lease = try service.acquireExclusiveActivity(.meeting)
        defer { service.releaseExclusiveActivity(lease) }
        do {
            #if os(macOS)
            try await service.retireDictationASRResourcesForMeeting(lease: lease)
            #endif
            let runtime = MeetingParakeetNemotronRuntime(asrServiceProvider: { service },
                modelLocator: MeetingNemotronModelLocator(injectedURL: package), voiceModelDirectory: voice)
            let attempt = UUID()
            let track = UUID()
            try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.preparePCMResources(attemptID: attempt, configuration: configuration)
            }
            var offset: Double = 0
            for seconds in [12, 20] {
                let samples = (0..<(seconds * 16_000)).map { source[$0 % source.count] }
                for repetition in 0..<3 {
                    let began = ProcessInfo.processInfo.systemUptime
                    let batch = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                        try await runtime.recognizePCM(samples: samples, offset: offset, trackID: track,
                            attemptID: attempt, configuration: configuration)
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - began
                    XCTAssertFalse(batch.segments.isEmpty)
                    XCTAssertTrue(batch.segments.allSatisfy { $0.start.seconds >= offset - 0.001 && $0.end.seconds <= offset + Double(seconds) + 0.001 })
                    print("[STRICT_CADENCE] audioSeconds=\(seconds) repetition=\(repetition) computeSeconds=\(elapsed) segments=\(batch.segments.count)")
                    offset += Double(seconds)
                }
            }
            await service.shutdownForTermination()
        } catch {
            await service.shutdownForTermination()
            throw error
        }
    }
}

#if canImport(Darwin)
import Darwin

/// Explicit performance probe for a staged public GigaAM artifact. It uses the production
/// buffered recognizer/engine but synthetic PCM and bypasses the admission gate under evaluation.
/// It provides model throughput/capacity evidence, not microphone or background-recording proof.
extension MobileRegisteredModelInferenceTests {
    func testGigaAMSustainedSixtySecondPacedBufferedCaptions() async throws {
        guard ProcessInfo.processInfo.environment["PICHI_MOBILE_GIGA_SUSTAINED"] == "1" else {
            throw XCTSkip("Set PICHI_MOBILE_GIGA_SUSTAINED=1 for the bounded sixty-second GigaAM benchmark")
        }
        let root = try self.assets()
        let modelRoot = root.appendingPathComponent("models/\(SettingsStore.SpeechModel.gigaam.rawValue)", isDirectory: true)
        guard PichiGigaAMModelStore(directory: modelRoot).modelsExistOnDisk() else {
            throw XCTSkip("Stage the verified public GigaAM artifact before the performance probe; this test does not install missing weights")
        }
        let source = try self.pcm("ru", in: root)
        let reportDirectory = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        let reportURL = reportDirectory.appendingPathComponent("gigaam-sixty-second-paced-caption-capacity.json")
        let started = ProcessInfo.processInfo.systemUptime
        let observations = SustainedGigaObservations()
        var measurements: [[String: Any]] = []
        var report: [String: Any] = [
            "modelID": SettingsStore.SpeechModel.gigaam.rawValue,
            "fixture": "audio/ru.wav", "sampleRate": 16_000, "packetFrames": 1600,
            "pacedSeconds": 60, "silenceTailSeconds": 2,
            "microphone": "synthetic-PCM", "productionAdmissionApplied": false,
            "productionMemoryPressureMonitorApplied": false,
            "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "processorCount": ProcessInfo.processInfo.processorCount,
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "status": "preparing",
        ]
        var memoryReadFailures = 0
        let sampler = Task { @MainActor in
            while !Task.isCancelled {
                if let memory = Self.sustainedGigaMemory() {
                    let current = observations.snapshot()
                    measurements.append(["elapsedMilliseconds": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                                         "residentBytes": memory.resident, "physicalFootprintBytes": memory.footprint,
                                         "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                                         "partials": current.partials, "utterances": current.utterances])
                } else { memoryReadFailures += 1 }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
        func saveReport() throws {
            report["memoryReadFailures"] = memoryReadFailures
            report["memorySamples"] = measurements
            report["peakResidentBytes"] = measurements.compactMap { $0["residentBytes"] as? UInt64 }.max() ?? 0
            report["peakPhysicalFootprintBytes"] = measurements.compactMap { $0["physicalFootprintBytes"] as? UInt64 }.max() ?? 0
            let current = observations.snapshot()
            report["partialCount"] = current.partials
            report["clearedPartialCallbacks"] = current.clears
            report["utteranceCount"] = current.utterances
            report["lastCommittedEndSeconds"] = current.lastEnd
            report["russianAnchor"] = current.russianAnchor
            report["degradationCount"] = current.failures.count
            report["degradationReasons"] = current.failures
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: reportURL, options: .atomic)
        }
        var engine: PichiMeetingBufferedTrackEngine?
        var recognizer: PichiMeetingCaptionRecognizer?
        do {
            let configuration = try await self.installedConfiguration(model: .gigaam, assets: root)
            report["artifactFingerprint"] = configuration.asrArtifactFingerprint ?? "unavailable"
            report["verifiedPreparationMilliseconds"] = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
            let provider = try PichiMeetingProviderFactory.make(configuration)
            let preparedRecognizer = PichiMeetingCaptionRecognizer(provider: provider)
            let buffered = PichiMeetingBufferedTrackEngine(kind: .microphone, recognizer: preparedRecognizer)
            engine = buffered; recognizer = preparedRecognizer
            await buffered.configure(
                onPartial: { _, _, text, _, _ in observations.partial(text) },
                onUtterance: { _, _, text, _, end in observations.utterance(text, end: end.seconds) },
                onDegraded: { _, reason in observations.failure(reason) },
                onReady: { _ in observations.markReady() })
            let loading = ProcessInfo.processInfo.systemUptime
            await buffered.start()
            let readyDeadline = loading + 60
            while !observations.snapshot().ready, observations.snapshot().failures.isEmpty,
                  ProcessInfo.processInfo.systemUptime < readyDeadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
            guard observations.snapshot().ready else { throw SustainedGigaProbeError.notReady }
            report["bufferedLoadMilliseconds"] = Int((ProcessInfo.processInfo.systemUptime - loading) * 1000)
            report["status"] = "feeding"
            try saveReport()
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                                    channels: 1, interleaved: false))
            let beginFeed = ProcessInfo.processInfo.systemUptime
            let periodFrames = source.count + 16_000
            var maximumLateness: Double = 0
            var lastVoicedEnd = 0.0
            let signalThreshold: Float = 0.006
            // Sixty seconds of repeated public speech plus one-second inter-turn pauses, then a
            // two-second silence tail. Only this small source and one 100ms packet are allocated.
            for packet in 0..<620 {
                try Task.checkCancellation()
                let scheduled = beginFeed + Double(packet) / 10
                let wait = scheduled - ProcessInfo.processInfo.systemUptime
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                maximumLateness = max(maximumLateness, ProcessInfo.processInfo.systemUptime - scheduled)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
                buffer.frameLength = 1600
                let target = try XCTUnwrap(buffer.floatChannelData?[0])
                var squareSum: Float = 0
                for frame in 0..<1600 {
                    let position = (packet * 1600 + frame) % periodFrames
                    target[frame] = packet < 600 && position < source.count ? source[position] : 0
                    squareSum += target[frame] * target[frame]
                }
                if (squareSum / 1600).squareRoot() >= signalThreshold { lastVoicedEnd = Double(packet + 1) / 10 }
                buffered.offer(.init(buffer: buffer, pts: CMTime(value: Int64(packet * 1600), timescale: 16_000),
                                     duration: CMTime(value: 1600, timescale: 16_000)))
                if !observations.snapshot().failures.isEmpty { throw SustainedGigaProbeError.degraded }
            }
            report["pacedFeedMilliseconds"] = Int((ProcessInfo.processInfo.systemUptime - beginFeed) * 1000)
            report["maximumPacingLatenessMilliseconds"] = Int(maximumLateness * 1000)
            report["status"] = "draining"
            try saveReport()
            let drainStart = ProcessInfo.processInfo.systemUptime
            let drainDeadline = drainStart + 20
            let endpointTolerance = 0.2
            let minimumLastEnd = max(0, lastVoicedEnd - endpointTolerance)
            report["generatedLastVoicedEndSeconds"] = lastVoicedEnd
            report["signalEnergyThreshold"] = signalThreshold
            report["endpointToleranceSeconds"] = endpointTolerance
            while observations.snapshot().lastEnd < minimumLastEnd, observations.snapshot().failures.isEmpty,
                  ProcessInfo.processInfo.systemUptime < drainDeadline {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(50))
            }
            report["drainMilliseconds"] = Int((ProcessInfo.processInfo.systemUptime - drainStart) * 1000)
            await buffered.stop()
            await preparedRecognizer.unload()
            let actual = observations.snapshot()
            let expectedFullTurns = Int(60 * 16_000 / periodFrames)
            report["expectedFullTurns"] = expectedFullTurns
            report["minimumAcceptedUtterances"] = max(1, expectedFullTurns - 1)
            report["minimumAcceptedCommittedEndSeconds"] = minimumLastEnd
            XCTAssertTrue(actual.failures.isEmpty, "A degradation invalidates admission evidence")
            XCTAssertTrue(actual.russianAnchor)
            XCTAssertFalse(measurements.isEmpty, "Capacity evidence requires actual memory samples")
            XCTAssertEqual(memoryReadFailures, 0, "Missing memory observations invalidate capacity evidence")
            XCTAssertGreaterThan(actual.partials, 0)
            XCTAssertGreaterThanOrEqual(actual.utterances, max(1, expectedFullTurns - 1), "Paced turns must not silently disappear")
            XCTAssertGreaterThanOrEqual(actual.lastEnd, minimumLastEnd, "Recognition must catch up with the end of the paced input")
            XCTAssertLessThanOrEqual(maximumLateness, 0.5, "Main-actor stalls invalidate real-time pacing evidence")
            report["status"] = actual.failures.isEmpty && actual.russianAnchor && actual.partials > 0 && actual.lastEnd >= minimumLastEnd
                && actual.utterances >= max(1, expectedFullTurns - 1) && maximumLateness <= 0.5
                && !measurements.isEmpty && memoryReadFailures == 0 ? "passed" : "failed"
            sampler.cancel(); await sampler.value
            try saveReport()
        } catch {
            await engine?.stop()
            await recognizer?.unload()
            sampler.cancel(); await sampler.value
            report["status"] = "error"
            report["errorType"] = String(describing: type(of: error))
            try saveReport()
            throw error
        }
    }

    private static func sustainedGigaMemory() -> (resident: UInt64, footprint: UInt64)? {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return (information.resident_size, information.phys_footprint)
    }
}

private enum SustainedGigaProbeError: Error { case notReady, degraded }

private final nonisolated class SustainedGigaObservations: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var partials = 0
    private var clears = 0
    private var utterances = 0
    private var lastEnd = 0.0
    private var russianAnchor = false
    private var failures: [String] = []
    func markReady() { lock.withLock { ready = true } }
    func partial(_ text: String) {
        lock.withLock {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clears += 1; return }
            partials += 1; anchor(text)
        }
    }
    func utterance(_ text: String, end: Double) { lock.withLock { utterances += 1; lastEnd = max(lastEnd, end); anchor(text) } }
    func failure(_ reason: String) { lock.withLock { failures.append(reason) } }
    private func anchor(_ text: String) {
        let lower = text.lowercased()
        if lower.contains("документ") || lower.contains("инструкци") { russianAnchor = true }
    }
    func snapshot() -> (ready: Bool, partials: Int, clears: Int, utterances: Int, lastEnd: Double, russianAnchor: Bool, failures: [String]) {
        lock.withLock { (ready, partials, clears, utterances, lastEnd, russianAnchor, failures) }
    }
}
#endif
