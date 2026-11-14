import Foundation
import PichiGigaAM
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class GigaAMPreviewFinalizationXCTests: XCTestCase {
    private actor PreparationGate {
        private var suspended: CheckedContinuation<Void, Never>?
        private var waiter: CheckedContinuation<Void, Never>?
        func suspend() async {
            await withCheckedContinuation {
                self.suspended = $0
                self.waiter?.resume()
                self.waiter = nil
            }
        }
        func waitUntilSuspended() async {
            if self.suspended != nil { return }
            await withCheckedContinuation { self.waiter = $0 }
        }
        func resume() { self.suspended?.resume(); self.suspended = nil }
    }

    private actor NativeFixture: PichiGigaAMInferenceRuntime {
        struct Call: Sendable {
            let samples: Int
            let features: Bool
            let session: UUID?
        }

        var isReady = true
        var executionStatus: GigaAMExecutionStatus? { .init(backend: .cpu) }
        private(set) var calls: [Call] = []
        private(set) var discarded: [UUID] = []
        private(set) var attempts = 0
        var output: GigaAMTranscript
        var failNext = false
        private var holdBegin = false
        private var heldBegin: CheckedContinuation<Void, Never>?
        private var beginWaiter: CheckedContinuation<Void, Never>?

        init(output: GigaAMTranscript) { self.output = output }
        func load(descriptor: GigaAMModelDescriptor, directory: URL, executionProvider: GigaAMExecutionProvider) {}
        func beginAttempt() async {
            self.attempts += 1
            if self.holdBegin {
                self.holdBegin = false
                await withCheckedContinuation { continuation in
                    self.heldBegin = continuation
                    self.beginWaiter?.resume()
                    self.beginWaiter = nil
                }
            }
        }
        func holdNextBegin() { self.holdBegin = true }
        func waitForHeldBegin() async {
            if self.heldBegin != nil { return }
            await withCheckedContinuation { self.beginWaiter = $0 }
        }
        func resumeHeldBegin() {
            self.heldBegin?.resume()
            self.heldBegin = nil
        }
        func transcribe(_ samples: [Float], captureEncoderFeatures: Bool, reusingWindowsFor session: GigaAMWindowReuseSession?) throws -> GigaAMTranscript {
            try Task.checkCancellation()
            self.calls.append(.init(samples: samples.count, features: captureEncoderFeatures, session: session?.id))
            if self.failNext {
                self.failNext = false
                throw CocoaError(.fileReadUnknown)
            }
            return self.output
        }
        func setFailure() { self.failNext = true }
        func discardWindowReuse(for sessionID: UUID) { self.discarded.append(sessionID) }
        func unload() { self.isReady = false }
    }

    private func withProvider(
        descriptor: GigaAMModelDescriptor = GigaAMModelCatalog.downloadableModel,
        output: GigaAMTranscript,
        body: (PichiGigaAMProvider, NativeFixture, PronunciationDictionaryStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let priorProfile = PrivateProfileStorage.current
        let priorEntries = SettingsStore.shared.customDictionaryEntries
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        SettingsStore.shared.customDictionaryEntries = []
        PrivateProfileDefaults.shared.set(true, forKey: "DictionarySharedFeatureMatcherEnabled")
        let store = PronunciationDictionaryStore(fileURL: root.appendingPathComponent("pronunciations.json"), profile: profile)
        let provider = PichiGigaAMProvider(modelStore: .init(directory: root, downloadDescriptor: descriptor),
            expectedModelFingerprint: descriptor.fingerprint, pronunciationStore: store)
        let native = NativeFixture(output: output)
        await provider.usePreparedRuntimeForTesting(native, fingerprint: descriptor.fingerprint)
        defer {
            PrivateProfileStorage.select(priorProfile)
            SettingsStore.shared.customDictionaryEntries = priorEntries
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await body(provider, native, store)
            await provider.unloadModel()
        } catch {
            await provider.unloadModel()
            throw error
        }
    }

    private func transcript() throws -> GigaAMTranscript {
        var values = [Float](repeating: 0, count: 25 * GigaAMEncoderFeatures.dimension)
        for frame in 0..<25 { values[frame * GigaAMEncoderFeatures.dimension] = 1 }
        let window = try GigaAMEncoderWindow(offset: 0, ownership: 0..<1,
            features: GigaAMEncoderFeatures(values: values))
        return GigaAMTranscript(text: "Ёжик здесь.", confidence: 0.8,
            words: [.init(text: "Ёжик", start: 0.08, end: 0.24, confidence: 0.8,
                          sourceContext: .init(sampleRange: 0..<16_000, wordIndex: 0)),
                    .init(text: "здесь.", start: 0.64, end: 0.88, confidence: 0.8,
                          sourceContext: .init(sampleRange: 0..<16_000, wordIndex: 1))],
            endOfUtteranceProbability: nil, processingDuration: 0, encoderWindows: [window])
    }

    func testAdmittedPreviewAndFinalShareSessionAndRetainWordAndEncoderEvidence() async throws {
        let output = try self.transcript()
        try await self.withProvider(output: output) { provider, native, _ in
            let lease = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            do {
                let preview = try await provider.transcribeStreaming([Float](repeating: 0.1, count: 16_000))
                let final = try await provider.transcribeFinal([Float](repeating: 0.1, count: 16_000))
                XCTAssertEqual(preview.text, output.text)
                XCTAssertEqual(final.text, output.text)
                let alignment = try XCTUnwrap(final.dictionaryLearningAlignment)
                XCTAssertEqual(alignment.words.map(\.start), output.words.map(\.start))
                XCTAssertEqual(alignment.words.map(\.end), output.words.map(\.end))
                XCTAssertEqual(alignment.words.first?.timingProvenance?.sourceWindowID, "ctc:0:16000")
                XCTAssertEqual(!alignment.featureFrames.isEmpty, GigaAMRuntime.encoderFeatureAPIAvailable)
                let calls = await native.calls
                XCTAssertEqual(calls.map(\.session), [lease, lease])
                XCTAssertTrue(calls.allSatisfy { $0.features == GigaAMRuntime.encoderFeatureAPIAvailable },
                    "Preview must acquire the same supported evidence required by final dictionary processing")
                let attempts = await native.attempts
                XCTAssertEqual(attempts, 1, "Finalization must not reset the native attempt and its reusable windows")
                await provider.endAdmittedTranscription(leaseID: lease)
                let discarded = await native.discarded
                XCTAssertEqual(discarded, [lease])
            } catch {
                await provider.endAdmittedTranscription(leaseID: lease)
                throw error
            }
        }
    }

    func testCaptionCallsAndFinalOnlyRequestsDoNotReuseAnotherRecording() async throws {
        try await self.withProvider(output: self.transcript()) { provider, native, _ in
            _ = try await provider.transcribeStreaming([0.1])
            _ = try await provider.transcribeFinal([0.2])
            let calls = await native.calls
            XCTAssertTrue(calls.allSatisfy { $0.session == nil })
            let discarded = await native.discarded
            XCTAssertTrue(discarded.isEmpty)
        }
    }

    func testNewAdmissionAndStaleCleanupCannotReuseOrDiscardThePreviousSession() async throws {
        try await self.withProvider(output: self.transcript()) { provider, native, _ in
            let first = UUID(), second = UUID()
            try provider.beginAdmittedTranscription(leaseID: first)
            _ = try await provider.transcribeStreaming([0.1])
            await provider.endAdmittedTranscription(leaseID: first)
            try provider.beginAdmittedTranscription(leaseID: second)
            do {
                await provider.endAdmittedTranscription(leaseID: first)
                _ = try await provider.transcribeFinal([0.2])
                let calls = await native.calls
                XCTAssertEqual(calls.map(\.session), [first, nil])
                let discarded = await native.discarded
                XCTAssertEqual(discarded, [first])
                await provider.endAdmittedTranscription(leaseID: second)
            } catch {
                await provider.endAdmittedTranscription(leaseID: second)
                throw error
            }
        }
    }

    func testFailedFinalizationStillJoinsTheAdmittedCacheCleanup() async throws {
        try await self.withProvider(output: self.transcript()) { provider, native, _ in
            let lease = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            _ = try await provider.transcribeStreaming([0.1])
            await native.setFailure()
            do {
                _ = try await provider.transcribeFinal([0.1])
                XCTFail("The native failure must not be published as a complete transcript")
            } catch {}
            await provider.endAdmittedTranscription(leaseID: lease)
            let discarded = await native.discarded
            XCTAssertEqual(discarded, [lease])
        }
    }

    func testEndingAdmissionWhilePreviewIsSuspendedPreventsLateReuseAndPublication() async throws {
        try await self.withProvider(output: self.transcript()) { provider, native, _ in
            let lease = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            await native.holdNextBegin()
            let preview = Task { try await provider.transcribeStreaming([0.1]) }
            await native.waitForHeldBegin()
            await provider.endAdmittedTranscription(leaseID: lease)
            await native.resumeHeldBegin()
            do {
                _ = try await preview.value
                XCTFail("An ended recording must not publish its late preview")
            } catch { XCTAssertTrue(error is CancellationError) }
            let calls = await native.calls
            XCTAssertTrue(calls.isEmpty)
            let discarded = await native.discarded
            XCTAssertEqual(discarded, [lease])
        }
    }

    func testUnchangedDictionaryReusesPreparationAcrossActualProviderAdmissions() async throws {
        try await self.withProvider(output: self.transcript()) { provider, _, _ in
            SettingsStore.shared.customDictionaryEntries = [.init(triggers: ["fixture"], replacement: "Fixture")]
            for index in 0..<2 {
                let lease = UUID()
                try provider.beginAdmittedTranscription(leaseID: lease)
                do {
                    _ = try await provider.transcribeStreaming([Float](repeating: 0.1, count: 16_000))
                    _ = try await provider.transcribeFinal([Float](repeating: 0.1, count: 16_000))
                    let metrics = try XCTUnwrap(provider.lastFinalizationMetrics)
                    XCTAssertTrue(metrics.succeeded)
                    XCTAssertEqual(metrics.referenceCacheHit, index == 1)
                    XCTAssertGreaterThanOrEqual(metrics.totalMilliseconds, metrics.nativeMilliseconds)
                    await provider.endAdmittedTranscription(leaseID: lease)
                } catch {
                    await provider.endAdmittedTranscription(leaseID: lease)
                    throw error
                }
            }
        }
    }

    func testClosedAdmissionCannotPoisonTheNextRecordsPreparedReferenceCache() async throws {
        for descriptor in [GigaAMModelCatalog.downloadableModel, GigaAMModelCatalog.compactONNXModel] {
            try await self.withProvider(descriptor: descriptor, output: self.transcript()) { provider, _, _ in
                SettingsStore.shared.customDictionaryEntries = [.init(triggers: ["fixture"], replacement: "Fixture")]
                let gate = PreparationGate(), lease = UUID()
                provider.beforeReferencePreparationForTesting = { await gate.suspend() }
                try provider.beginAdmittedTranscription(leaseID: lease)
                _ = try await provider.transcribeStreaming([Float](repeating: 0.1, count: 16_000))
                let final = Task { try await provider.transcribeFinal([Float](repeating: 0.1, count: 16_000)) }
                await gate.waitUntilSuspended()
                await provider.endAdmittedTranscription(leaseID: lease)
                await gate.resume()
                do { _ = try await final.value; XCTFail("Closed admission must not cache or publish a partial preparation") }
                catch { XCTAssertTrue(error is CancellationError) }
                provider.beforeReferencePreparationForTesting = nil
                let next = UUID()
                try provider.beginAdmittedTranscription(leaseID: next)
                do {
                    _ = try await provider.transcribeFinal([Float](repeating: 0.1, count: 16_000))
                    XCTAssertFalse(try XCTUnwrap(provider.lastFinalizationMetrics).referenceCacheHit)
                    await provider.endAdmittedTranscription(leaseID: next)
                } catch {
                    await provider.endAdmittedTranscription(leaseID: next)
                    throw error
                }
            }
        }
    }

    func testIncompletePronunciationsDoNotPreventCachingOtherPreparedReferences() async throws {
        try await self.withProvider(output: self.transcript()) { provider, _, store in
            let entry = SettingsStore.CustomDictionaryEntry(triggers: ["fixture"], replacement: "Fixture")
            SettingsStore.shared.customDictionaryEntries = [entry]
            let modelKey = GigaAMEncoderDictionaryStorage.modelKey(fingerprint: GigaAMModelCatalog.downloadableModel.fingerprint)
            var values = [Float](repeating: 0, count: GigaAMEncoderFeatures.dimension)
            values[0] = 1
            let capture = PronunciationEnrollmentCapture(values: values, sourceFrameCount: 10, modelKey: modelKey,
                extractorVersion: GigaAMEncoderFeatures.extractorVersion)
            try await store.upsert(dictionaryEntryID: entry.id, label: entry.replacement, modelKey: modelKey,
                enrollments: [capture, capture], automaticMatchingEnabled: false)
            for index in 0..<2 {
                let lease = UUID()
                try provider.beginAdmittedTranscription(leaseID: lease)
                do {
                    let output = try await provider.transcribeFinal([Float](repeating: 0.1, count: 16_000))
                    XCTAssertEqual(output.text, "Ёжик здесь.", "An incomplete profile must not become eligible for acoustic replacement")
                    let metrics = try XCTUnwrap(provider.lastFinalizationMetrics)
                    XCTAssertEqual(metrics.referenceCacheHit, index == 1)
                    await provider.endAdmittedTranscription(leaseID: lease)
                } catch {
                    await provider.endAdmittedTranscription(leaseID: lease)
                    throw error
                }
            }
        }
    }

    func testFinalizationStillAppliesSavedAcousticPronunciations() async throws {
        func tone(_ frequency: Float, seconds: Double) -> [Float] {
            (0..<Int(seconds * 16_000)).map { 0.2 * sin(2 * .pi * frequency * Float($0) / 16_000) }
        }
        let descriptor = GigaAMModelCatalog.compactONNXModel
        let reference = tone(440, seconds: 1.2)
        let samples = tone(880, seconds: 0.6) + reference + tone(660, seconds: 0.6)
        let output = GigaAMTranscript(text: "До ошибка после.", confidence: 0.4,
            words: [.init(text: "До", start: 0, end: 0.6, confidence: 0.4),
                    .init(text: "ошибка", start: 0.6, end: 1.8, confidence: 0.4),
                    .init(text: "после.", start: 1.8, end: 2.4, confidence: 0.4)],
            endOfUtteranceProbability: nil, processingDuration: 0)
        try await self.withProvider(descriptor: descriptor, output: output) { provider, native, store in
            let entry = SettingsStore.CustomDictionaryEntry(triggers: ["термин"], replacement: "Термин")
            SettingsStore.shared.customDictionaryEntries = [entry]
            let modelKey = GigaAMDictionaryAcoustics.modelKey(fingerprint: descriptor.fingerprint)
            var captures: [PronunciationEnrollmentCapture] = []
            for gain: Float in [0.5, 0.7, 1] {
                let capture = try await GigaAMDictionaryAcoustics.enrollment(
                    samples: reference.map { $0 * gain }, modelKey: modelKey, words: [])
                captures.append(try XCTUnwrap(capture))
            }
            try await store.upsert(dictionaryEntryID: entry.id, label: entry.replacement,
                modelKey: modelKey, enrollments: captures, automaticMatchingEnabled: true)
            let lease = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            do {
                let preview = try await provider.transcribeStreaming(samples)
                let final = try await provider.transcribeFinal(samples)
                XCTAssertEqual(preview.text, output.text)
                XCTAssertEqual(final.text, "До Термин после.")
                let alignment = try XCTUnwrap(final.dictionaryLearningAlignment)
                XCTAssertEqual(alignment.words.map(\.start), output.words.map(\.start))
                XCTAssertEqual(alignment.words.map(\.end), output.words.map(\.end))
                XCTAssertFalse(alignment.acousticEvidence.isEmpty)
                let calls = await native.calls
                XCTAssertEqual(calls.map(\.session), [lease, lease])
                await provider.endAdmittedTranscription(leaseID: lease)
            } catch {
                await provider.endAdmittedTranscription(leaseID: lease)
                throw error
            }
        }
    }

    func testActualASRStopPreservesTextRulesAndCaptureCompletionWithReusedProvider() async throws {
        try await self.withProvider(output: self.transcript()) { provider, native, _ in
            let settings = SettingsStore.shared
            let priorModel = settings.selectedSpeechModel
            let priorHistory = settings.saveTranscriptionHistory
            let priorLearning = settings.automaticDictionaryLearningEnabled
            settings.selectedSpeechModel = .gigaam
            settings.saveTranscriptionHistory = false
            settings.automaticDictionaryLearningEnabled = true
            settings.customDictionaryEntries = [.init(triggers: ["Ёжик"], replacement: "Pichi")]
            defer {
                settings.selectedSpeechModel = priorModel
                settings.saveTranscriptionHistory = priorHistory
                settings.automaticDictionaryLearningEnabled = priorLearning
            }
            // A private coordinator: shutdownForTermination() must not end the process-wide one that later tests use.
            let residency = MeetingModelResidencyCoordinator()
            let asr = ASRService(meetingModelResidency: residency)
            asr.modelProvidersForTesting[.gigaam] = provider
            asr.isAsrReady = true
            let lease = try asr.acquireExclusiveActivity(.dictation)
            asr.configureDictationModeSwitchForTesting(ownedLease: lease)
            _ = try asr.beginAdmittedTranscription(lease: lease)
            let samples = [Float](repeating: 0.1, count: 16_000)
            _ = try await provider.transcribeStreaming(samples)
            let capture = DirectCoreAudioLifecycleController(
                packetHandler: asr.recoveryPacketHandlerForTesting,
                inputFactory: { _, _ in throw CocoaError(.fileReadUnknown) },
                fingerprintReader: { _ in throw CocoaError(.fileReadUnknown) },
                installsHardwareListeners: false,
                deviceSnapshotReader: { _ in throw CocoaError(.fileReadUnknown) },
                deviceLivenessReader: { _ in nil },
                deviceResolver: { _ in throw CocoaError(.fileReadUnknown) },
                onFormatInvalidated: { _ in })
            asr.configureAudioRouteRecoveryForTesting(controller: capture, devices: [], initialSamples: samples)
            asr.partialTranscription = "Ёжик здесь."
            var stopped = 0
            let result = await asr.stop(onCaptureStopped: { stopped += 1 })
            XCTAssertEqual(result, "Pichi здесь.")
            XCTAssertEqual(stopped, 1)
            XCTAssertFalse(asr.isRunning)
            let learning = asr.consumeDictionaryLearningRecording()
            XCTAssertEqual(learning?.alignment.words.map(\.text), ["Ёжик", "здесь."])
            let calls = await native.calls
            XCTAssertEqual(calls.map(\.session), [lease.id, lease.id])
            await asr.shutdownForTermination()
            XCTAssertEqual(residency.phase, .terminating)
            let ordinary = try MeetingModelResidencyCoordinator.shared.beginOperation(owner: "gigaam-fixture-isolation", modelID: "synthetic")
            MeetingModelResidencyCoordinator.shared.endOperation(ordinary)
            await provider.endAdmittedTranscription(leaseID: lease.id)
            let discarded = await native.discarded
            XCTAssertEqual(discarded, [lease.id])
        }
    }

    /// Opt-in replay of approved public/synthetic audio. It exercises the actual
    /// native model and production provider without a microphone or user settings.
    func testRealModelLongDictationReusesWindowsAndMatchesFullFinalizationWhenEnabled() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["PICHI_GIGAAM_REUSE_MODEL_DIR"],
              let audioPath = environment["PICHI_GIGAAM_REUSE_AUDIO"],
              let reportPath = environment["PICHI_GIGAAM_REUSE_REPORT"] else {
            throw XCTSkip("Set approved local GigaAM weights, public/synthetic audio and a private report path for real replay")
        }
        let reader = try LocalAPIAudioDecoder.ChunkReader(fileURL: URL(fileURLWithPath: audioPath))
        var samples: [Float] = []
        while true {
            let chunk = try await reader.nextSamples()
            if chunk.isEmpty { break }
            samples.append(contentsOf: chunk)
        }
        XCTAssertGreaterThan(samples.count, 60 * 16_000)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("gigaam-real-reuse-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let priorProfile = PrivateProfileStorage.current
        let priorEntries = SettingsStore.shared.customDictionaryEntries
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        SettingsStore.shared.customDictionaryEntries = []
        PrivateProfileDefaults.shared.set(true, forKey: "DictionarySharedFeatureMatcherEnabled")
        defer {
            PrivateProfileStorage.select(priorProfile)
            SettingsStore.shared.customDictionaryEntries = priorEntries
            try? FileManager.default.removeItem(at: root)
        }
        let descriptor = GigaAMModelCatalog.downloadableModel
        let runtime = try GigaAMRuntime()
        let provider = PichiGigaAMProvider(modelStore: .init(directory: URL(fileURLWithPath: modelPath)),
            expectedModelFingerprint: descriptor.fingerprint,
            pronunciationStore: .init(fileURL: root.appendingPathComponent("pronunciations.json"), profile: profile))
        let lease = UUID()
        do {
            try await runtime.load(descriptor: descriptor, directory: URL(fileURLWithPath: modelPath))
            await provider.usePreparedRuntimeForTesting(runtime, fingerprint: descriptor.fingerprint)
            try provider.beginAdmittedTranscription(leaseID: lease)
            let lastPreviewCount = samples.count - 16_000
            for end in stride(from: 10 * 16_000, to: lastPreviewCount, by: 10 * 16_000) {
                _ = try await provider.transcribeStreaming(Array(samples.prefix(end)))
            }
            _ = try await provider.transcribeStreaming(Array(samples.prefix(lastPreviewCount)))
            let stopStart = ProcessInfo.processInfo.systemUptime
            let final = try await provider.transcribeFinal(samples)
            let stopMilliseconds = (ProcessInfo.processInfo.systemUptime - stopStart) * 1_000
            let work = await runtime.lastTranscriptionWork
            // A one-second tail can straddle a core boundary and invalidate
            // both adjacent overlapping windows.
            XCTAssertLessThanOrEqual(work.inferredWindows, 2)
            XCTAssertLessThanOrEqual(work.inferredSamples, 44 * 16_000)
            XCTAssertGreaterThan(work.reusedWindows, 0)
            let unchangedStart = ProcessInfo.processInfo.systemUptime
            let unchanged = try await provider.transcribeFinal(samples)
            let unchangedMilliseconds = (ProcessInfo.processInfo.systemUptime - unchangedStart) * 1_000
            let unchangedWork = await runtime.lastTranscriptionWork
            XCTAssertEqual(unchangedWork.inferredWindows, 0)
            XCTAssertEqual(unchanged.text, final.text)
            await provider.endAdmittedTranscription(leaseID: lease)
            let baselineStart = ProcessInfo.processInfo.systemUptime
            let baseline = try await provider.transcribeFinal(samples)
            let baselineMilliseconds = (ProcessInfo.processInfo.systemUptime - baselineStart) * 1_000
            let baselineWork = await runtime.lastTranscriptionWork
            XCTAssertGreaterThan(baselineWork.inferredWindows, work.inferredWindows)
            XCTAssertFalse(final.text.isEmpty)
            XCTAssertEqual(final.text, baseline.text)
            let alignment = try XCTUnwrap(final.dictionaryLearningAlignment)
            let baselineAlignment = try XCTUnwrap(baseline.dictionaryLearningAlignment)
            XCTAssertEqual(alignment.words.map(\.text), baselineAlignment.words.map(\.text))
            XCTAssertEqual(alignment.words.map(\.start), baselineAlignment.words.map(\.start))
            XCTAssertEqual(alignment.words.map(\.end), baselineAlignment.words.map(\.end))
            XCTAssertEqual(alignment.words.map(\.timingProvenance), baselineAlignment.words.map(\.timingProvenance))
            XCTAssertEqual(alignment.featureFrames.count, baselineAlignment.featureFrames.count)
            XCTAssertFalse(alignment.featureFrames.isEmpty)
            let status = await runtime.executionStatus
            let report: [String: Any] = ["sampleCount": samples.count, "wordCount": alignment.words.count,
                "stopMilliseconds": stopMilliseconds, "unchangedMilliseconds": unchangedMilliseconds,
                "baselineMilliseconds": baselineMilliseconds, "inferredWindows": work.inferredWindows,
                "reusedWindows": work.reusedWindows, "inferredSamples": work.inferredSamples,
                "baselineInferredWindows": baselineWork.inferredWindows, "featureWindows": alignment.featureFrames.count,
                "backend": status?.backend.rawValue ?? "unknown", "textAndTimingsMatch": final.text == baseline.text
                    && alignment.words.map(\.start) == baselineAlignment.words.map(\.start)
                    && alignment.words.map(\.end) == baselineAlignment.words.map(\.end)]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
            await provider.unloadModel()
        } catch {
            await provider.endAdmittedTranscription(leaseID: lease)
            await provider.unloadModel()
            await runtime.unload()
            throw error
        }
    }
}
