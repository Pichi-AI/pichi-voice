import Foundation
import PichiGigaAM
@testable import FluidVoice_Debug
import XCTest

/// Optional local acceptance using a public 16 kHz float fixture and verified model artifacts.
/// Models must already exist; this test never requests a model download.
@MainActor
final class GigaAMNeuralReplayTests: XCTestCase {
    func testHalfSecondDictationThroughPreparedProviderWhenEnabled() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["PICHI_GIGAAM_NEURAL_REPLAY_DIR"] else {
            throw XCTSkip("Set PICHI_GIGAAM_NEURAL_REPLAY_DIR to an isolated public replay fixture")
        }
        let root = URL(fileURLWithPath: path)
        let suite = "PichiNeuralReplay.\(UUID().uuidString)"
        let prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { prefs.removePersistentDomain(forName: suite) }
        let store = PichiGigaAMModelStore(directory: root.appendingPathComponent("Models"), preferences: prefs, environment: [:])
        let selection = try store.selectedArtifact()
        guard selection.descriptor == GigaAMModelCatalog.coreMLModel, store.modelsExistOnDisk(selection: selection) else {
            XCTFail("The verified public Core ML model directory is required")
            return
        }
        let prior = PrivateProfileStorage.current
        let previousEntries = SettingsStore.shared.customDictionaryEntries
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        SettingsStore.shared.customDictionaryEntries = []
        defer {
            PrivateProfileStorage.select(prior)
            SettingsStore.shared.customDictionaryEntries = previousEntries
        }
        let pronunciations = PronunciationDictionaryStore(fileURL: root.appendingPathComponent("words.json"), profile: profile)
        let provider = PichiGigaAMProvider(modelStore: store, pronunciationStore: pronunciations)
        let raw = try Data(contentsOf: root.appendingPathComponent("public.f32"))
        XCTAssertTrue(raw.count.isMultiple(of: 4))
        let pcm = raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard pcm.count > 96_000, pcm.count <= 16_000 * 300 else {
            XCTFail("Supply a public fixture longer than one short window and at most five minutes")
            return
        }
        var active: UUID?
        do {
            @MainActor func prepareAndCheck() async throws -> Bool {
                try await provider.prepare()
                return provider.isReady && provider.hasAdaptiveDecoderForTesting
            }
            async let first = prepareAndCheck()
            async let second = prepareAndCheck()
            let readiness = try await (first, second)
            XCTAssertTrue(readiness.0 && readiness.1)
            var finals: [String] = []
            var timings: [[Double]] = []
            var reports: [[String: Any]] = []
            for neural in [true, false] {
                if !neural { provider.setNeuralDecoderForTesting(nil) }
                let lease = UUID()
                try provider.beginAdmittedTranscription(leaseID: lease)
                active = lease
                var draft = "", ticks = 0, end = 0, checkpoints = 0, deltaCalls = 0
                while end < pcm.count {
                    end = min(pcm.count, end + 8_000)
                    let result: ASRTranscriptionResult
                    if let from = provider.incrementalPreviewDeltaStart(totalSampleCount: end) {
                        deltaCalls += 1
                        do { result = try await provider.transcribeStreamingDelta(Array(pcm[from..<end]), totalSampleCount: end) }
                        catch IncrementalPreviewRequest.needsFullAudio {
                            checkpoints += 1
                            result = try await provider.transcribeStreaming(Array(pcm[..<end]))
                        }
                    } else {
                        result = try await provider.transcribeStreaming(Array(pcm[..<end]))
                    }
                    XCTAssertEqual(provider.usesFixedPreviewCadence, neural)
                    draft = result.text
                    ticks += 1
                }
                let final = try await provider.transcribeFinal(pcm)
                let alignment = try XCTUnwrap(final.dictionaryLearningAlignment)
                finals.append(final.text)
                timings.append(alignment.words.flatMap { [$0.start, $0.end] })
                XCTAssertFalse(final.text.isEmpty)
                XCTAssertEqual(deltaCalls, neural ? ticks - 1 : 0)
                reports.append(["neural": neural, "ticks": ticks, "deltas": deltaCalls, "checkpoints": checkpoints,
                                "lastDraft": draft, "final": final.text, "timings": timings.last!])
                await provider.endAdmittedTranscription(leaseID: lease)
                active = nil
            }
            XCTAssertEqual(finals.first, finals.last)
            XCTAssertEqual(timings.first, timings.last)
            try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("replay-report.json"), options: .atomic)
            await provider.unloadModel()
        } catch {
            if let active { await provider.endAdmittedTranscription(leaseID: active) }
            await provider.unloadModel()
            throw error
        }
    }
}
