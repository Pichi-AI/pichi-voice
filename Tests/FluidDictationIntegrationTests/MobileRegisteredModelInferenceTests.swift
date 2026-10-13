import AVFoundation
import CoreMedia
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
                for start in stride(from: 0, to: offered.count, by: 1600) {
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
            let diagnostic = try await service.withMeetingModelResidency(attemptID: UUID(), acceptsCompletedCancellation: { _ in false }) {
                try await runtime.withNemotronDiarization(artifact: locator.locate()) { factory in
                    let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
                    let diarizer = try await factory.makeDiarizer(epoch: epoch)
                    let actual = try await diarizer.diarize(samples: samples)
                    return MeetingNemotronPhaseResult(
                        activity: actual.map { .init(token: .init(analysisEpochID: epoch, label: "slot-\($0.slotIndex)"), start: $0.start, end: $0.end) },
                        voiceSamples: MeetingSpeakerVoiceSamples.collect(epoch: epoch, samples: samples, segments: actual)
                    )
                }
            }
            let diagnosticDirectory = root.appendingPathComponent("reports", isDirectory: true)
            try FileManager.default.createDirectory(at: diagnosticDirectory, withIntermediateDirectories: true)
            let diagnosticReport: [String: Any] = [
                "activity": diagnostic.activity.map { ["slot": $0.token.label, "start": $0.start, "end": $0.end] as [String: Any] },
                "eligibleVoiceSamples": diagnostic.voiceSamples.map { ["slot": $0.token.label, "clipLengths": $0.clips.map(\.count)] as [String: Any] },
            ]
            try JSONSerialization.data(withJSONObject: diagnosticReport, options: [.prettyPrinted, .sortedKeys])
                .write(to: diagnosticDirectory.appendingPathComponent("two-voice-diarization-evidence.json"), options: .atomic)
            let voiceProfiles = try await runtime.speakerVoiceProfiles(samples: diagnostic.voiceSamples)
            XCTAssertEqual(voiceProfiles.count, diagnostic.voiceSamples.count)
            let first = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.recognizePCM(samples: samples, offset: 0, trackID: track,
                                               attemptID: attempt, configuration: configuration)
            }
            let second = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                try await runtime.recognizePCM(samples: samples, offset: duration, trackID: track,
                                               attemptID: attempt, configuration: configuration)
            }
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
            XCTAssertTrue(second.segments.allSatisfy { $0.start.seconds >= duration - 0.001 })
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
            let firstReportIndex = report.count
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
                for start in stride(from: 0, to: samples.count, by: 128_000) {
                    let end = min(samples.count, start + 128_000)
                    let input = Array(samples[start..<end])
                    let batch = try await service.withMeetingModelResidency(attemptID: attempt, acceptsCompletedCancellation: { _ in false }) {
                        try await runtime.recognizePCM(samples: input, offset: Double(start) / 16_000, trackID: track,
                                                       attemptID: attempt, configuration: configuration)
                    }
                    XCTAssertTrue(batch.segments.allSatisfy { $0.start.seconds >= Double(start) / 16_000 - 0.001 && $0.end.seconds <= Double(end) / 16_000 + 0.001 })
                    report.append(["modelID": model.rawValue, "start": Double(start) / 16_000,
                                   "end": Double(end) / 16_000, "speakerIDs": batch.speakers.map { $0.id.uuidString },
                                   "assignedSegments": batch.segments.filter { $0.speakerID != nil }.count,
                                   "ambiguousSegments": batch.segments.filter { $0.attributionState == .overlappingSpeakers }.count,
                                   "unassignedSegments": batch.segments.filter { $0.attributionState == .unassigned }.count,
                                   "text": batch.segments.map(\.text).joined(separator: " ")])
                    try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                        .write(to: reportDirectory.appendingPathComponent("eight-second-speaker-windows.json"), options: .atomic)
                }
                XCTAssertFalse((report[firstReportIndex]["speakerIDs"] as? [String] ?? []).isEmpty,
                               "The first single-voice window has sufficient measured identity evidence.")
                if model != .whisperTiny {
                    XCTAssertGreaterThan(report[firstReportIndex + 1]["assignedSegments"] as? Int ?? 0, 0,
                                         "Word-timed adapters should label the second voice inside the transition window.")
                }
                await service.shutdownForTermination()
            } catch {
                await service.shutdownForTermination()
                throw error
            }
        }
        XCTAssertEqual(report.count, 9)
    }
}
