import AVFoundation
@testable import FluidVoice_Debug
import Foundation
import XCTest

// Regression tests for file-type acceptance in meeting/file transcription.
// WhatsApp voice notes are Ogg Opus files with a `.opus` extension. macOS maps
// `.opus` (and `.oga`) to the same UTType as `.ogg` (`org.xiph.ogg-audio`) and can
// decode them natively, but the accepted-extension set was built from each UTType's
// single `preferredFilenameExtension`, which dropped every alternate extension —
// so drag-and-dropping a WhatsApp `.opus` file was rejected as unsupported.

@MainActor
final class SupportedFileExtensionsTests: XCTestCase {
    func testWhatsAppOpusExtensionsAreAccepted() {
        let supported = FileTranscriptionService.supportedFileExtensions

        XCTAssertTrue(supported.contains("opus"), "WhatsApp voice notes use .opus — macOS decodes them as Ogg Opus")
        XCTAssertTrue(supported.contains("oga"), ".oga is an alternate Ogg audio extension macOS decodes natively")
        XCTAssertTrue(supported.contains("ogg"), ".ogg must remain accepted")
    }

    func testCommonFormatsRemainAccepted() {
        let supported = FileTranscriptionService.supportedFileExtensions

        for ext in ["wav", "mp3", "m4a", "mp4", "mov", "flac", "aac"] {
            XCTAssertTrue(supported.contains(ext), ".\(ext) must remain accepted")
        }
    }

    func testOnlyDecodableExtensionsAreAccepted() {
        let supported = FileTranscriptionService.supportedFileExtensions

        // Every accepted extension must map to a UTType AVFoundation reports as decodable
        // audio/video — the set must not drift into subtitles, playlists, or arbitrary types.
        XCTAssertFalse(supported.contains("srt"), "subtitle files are not transcribable audio")
        XCTAssertFalse(supported.contains("m3u"), "playlists are not transcribable audio")
        XCTAssertFalse(supported.contains("txt"))
    }
}

@MainActor
final class FileTranscriptionBufferedAudioTests: XCTestCase {
    private final class Provider: TranscriptionProvider {
        struct Input {
            let sampleCount: Int
            let prefix: [Float]
            let suffix: [Float]
            let silenceStartsAt: Int?
        }

        let name = "Synthetic buffered provider"
        let isAvailable = true
        let isReady = true
        private(set) var inputs: [Input] = []

        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}

        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            self.inputs.append(Input(
                sampleCount: samples.count,
                prefix: Array(samples.prefix(3)),
                suffix: Array(samples.suffix(3)),
                silenceStartsAt: samples.firstIndex(of: 0)
            ))
            // Avoid changing shared history while checking the real decoding/service path.
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
    }

    func testSubsecondFileReachesProviderWithOnlyTrailingSilenceAdded() async throws {
        try await self.withTranscription(frameCount: 8_000) { result, provider, service, asr in
            XCTAssertEqual(provider.inputs.count, 1)
            guard let input = provider.inputs.first else { return }
            XCTAssertEqual(input.sampleCount, 16_000)
            XCTAssertEqual(input.prefix, [0.125, 0.125, 0.125])
            XCTAssertEqual(input.suffix, [0, 0, 0])
            XCTAssertEqual(input.silenceStartsAt, 8_000)
            XCTAssertEqual(result.duration, 0.5, accuracy: 0.0001)
            XCTAssertEqual(service.currentFileURL?.lastPathComponent, "synthetic.wav")
            XCTAssertFalse(service.isTranscribing)
            XCTAssertNil(asr.activeExclusiveActivity)
        }
    }

    func testSubsecondTailAfterFullChunkIsTranscribedWithoutChangingDuration() async throws {
        let completeChunkFrames = 20 * 60 * 16_000
        try await self.withTranscription(frameCount: completeChunkFrames + 4_000) { result, provider, _, asr in
            XCTAssertEqual(provider.inputs.count, 2)
            guard provider.inputs.count == 2 else { return }
            XCTAssertEqual(provider.inputs[0].sampleCount, completeChunkFrames)
            XCTAssertEqual(provider.inputs[0].prefix, [0.125, 0.125, 0.125])
            XCTAssertEqual(provider.inputs[0].suffix, [0.125, 0.125, 0.125])
            XCTAssertNil(provider.inputs[0].silenceStartsAt)
            XCTAssertEqual(provider.inputs[1].sampleCount, 16_000)
            XCTAssertEqual(provider.inputs[1].prefix, [0.125, 0.125, 0.125])
            XCTAssertEqual(provider.inputs[1].suffix, [0, 0, 0])
            XCTAssertEqual(provider.inputs[1].silenceStartsAt, 4_000)
            XCTAssertEqual(result.duration, 1200.25, accuracy: 0.0001)
            XCTAssertNil(asr.activeExclusiveActivity)
        }
    }

    func testEmptyFileDoesNotCreatePaddedInference() async throws {
        try await self.withTranscription(frameCount: 0) { result, provider, _, asr in
            XCTAssertTrue(provider.inputs.isEmpty)
            XCTAssertTrue(result.text.isEmpty)
            XCTAssertEqual(result.duration, 0)
            XCTAssertNil(asr.activeExclusiveActivity)
        }
    }

    func testSubsecondSilenceKeepsDurationAndEmptyTranscript() async throws {
        try await self.withTranscription(frameCount: 8_000, sample: 0) { result, provider, _, asr in
            XCTAssertEqual(provider.inputs.count, 1)
            guard let input = provider.inputs.first else { return }
            XCTAssertEqual(input.sampleCount, 16_000)
            XCTAssertEqual(input.prefix, [0, 0, 0])
            XCTAssertEqual(input.suffix, [0, 0, 0])
            XCTAssertEqual(input.silenceStartsAt, 0)
            XCTAssertTrue(result.text.isEmpty)
            XCTAssertEqual(result.duration, 0.5, accuracy: 0.0001)
            XCTAssertNil(asr.activeExclusiveActivity)
        }
    }

    private func withTranscription(
        frameCount: Int,
        sample: Float = 0.125,
        check: (TranscriptionResult, Provider, FileTranscriptionService, ASRService) -> Void
    ) async throws {
        let settings = SettingsStore.shared
        let oldModel = settings.selectedSpeechModel
        let oldSpeakerLabels = settings.fileTranscriptionSpeakerLabelsEnabled
        settings.selectedSpeechModel = .gigaam
        settings.fileTranscriptionSpeakerLabelsEnabled = false
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BufferedFileAudio-\(UUID().uuidString)", isDirectory: true)
        defer {
            settings.selectedSpeechModel = oldModel
            settings.fileTranscriptionSpeakerLabelsEnabled = oldSpeakerLabels
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("synthetic.wav")
        try Self.writeAudio(to: fileURL, frameCount: frameCount, sample: sample)

        let provider = Provider()
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.modelProvidersForTesting[.gigaam] = provider
        asr.isAsrReady = true
        let service = FileTranscriptionService(asrService: asr)
        do {
            let result = try await service.transcribeFile(fileURL)
            check(result, provider, service, asr)
            await asr.shutdownForTermination()
        } catch {
            await asr.shutdownForTermination()
            throw error
        }
    }

    private static func writeAudio(to url: URL, frameCount: Int, sample: Float) throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let capacity: AVAudioFrameCount = 16_000
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity))
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.update(repeating: sample, count: Int(capacity))
        var remaining = frameCount
        while remaining > 0 {
            let count = min(Int(capacity), remaining)
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
            remaining -= count
        }
    }
}

@MainActor
final class TranscriptionExecutionStatusTests: XCTestCase {
    private final class LegacyProvider: TranscriptionProvider {
        let name = "Legacy status control"
        let isAvailable = true
        let isReady = true
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {}
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            ASRTranscriptionResult(text: "", confidence: 0)
        }
    }

    private final class FallbackProvider: TranscriptionProvider {
        let name = "Execution status control"
        let isAvailable = true
        private(set) var isReady = false
        private(set) var executionStatus: TranscriptionExecutionStatus?
        var onTranscribe: (() -> Void)?

        func modelsExistOnDisk() -> Bool { true }
        func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
            self.isReady = true
            self.executionStatus = .init(backend: .gpu)
        }
        func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
            self.onTranscribe?()
            self.executionStatus = .init(backend: .cpu, fallbackReason: "CPU fallback: GPU execution failed.")
            return ASRTranscriptionResult(text: "", confidence: 0)
        }
        func releaseResidency() async {
            self.executionStatus = nil
            self.isReady = false
        }
    }

    func testExistingProvidersDoNotClaimAnExecutionDevice() {
        let provider: any TranscriptionProvider = LegacyProvider()
        XCTAssertNil(provider.executionStatus)
    }

    func testPreparedStatusAndInferenceFallbackReachSelectedModelUIOnly() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        settings.selectedSpeechModel = .gigaam
        defer { settings.selectedSpeechModel = originalModel }
        let provider = FallbackProvider()
        let asr = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        asr.modelProvidersForTesting[.gigaam] = provider
        do {
            try await asr.ensureAsrReady()
            XCTAssertEqual(asr.executionStatus(for: .gigaam), .init(backend: .gpu))
            XCTAssertNil(asr.executionStatus(for: .parakeetTDT))
            provider.onTranscribe = { [weak asr] in
                XCTAssertEqual(asr?.executionStatus(for: .gigaam), .init(backend: .gpu))
            }
            _ = try await asr.transcribeSamplesForAPI([Float](repeating: 0, count: 16_000))
            XCTAssertEqual(asr.executionStatus(for: .gigaam), .init(backend: .cpu, fallbackReason: "CPU fallback: GPU execution failed."))
            XCTAssertNil(asr.executionStatus(for: .parakeetTDT))
            await asr.shutdownForTermination()
            XCTAssertNil(asr.executionStatus)
        } catch {
            await asr.shutdownForTermination()
            throw error
        }
    }
}
