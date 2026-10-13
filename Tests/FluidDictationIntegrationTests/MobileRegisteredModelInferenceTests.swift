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
        guard let path = ProcessInfo.processInfo.environment["PICHI_MOBILE_INFERENCE_ASSETS"], !path.isEmpty else {
            throw XCTSkip("Set PICHI_MOBILE_INFERENCE_ASSETS to an isolated public-model/synthetic-audio directory.")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
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
}
