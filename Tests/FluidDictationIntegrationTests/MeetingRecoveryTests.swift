// Existing end-to-end fixture suite is kept together to share its setup and helpers.
// swiftlint:disable file_length
import AppKit
import Combine
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import SwiftUI
import XCTest

@MainActor
// Existing recovery suite shares setup across crash and corruption scenarios.
// swiftlint:disable:next type_body_length
final class MeetingRecoveryTests: XCTestCase {
    private var englishBackendFixture: EnglishBackendFixture?

    override func setUp() {
        super.setUp()
        // Recovery fixtures use English and mocked capture/ASR. A fresh installation's
        // Russian-only model must not reject them before their injected controllers run.
        self.englishBackendFixture = EnglishBackendFixture(defaults: .standard)
    }

    override func tearDown() {
        self.englishBackendFixture?.restore()
        self.englishBackendFixture = nil
        super.tearDown()
    }

    private struct EnglishBackendFixture {
        private let defaults: UserDefaults
        private let originalValues: [Any?]
        private static let keys = ["SelectedSpeechModel", "MeetingTranscriptionBackendID"]

        init(defaults: UserDefaults) {
            self.defaults = defaults
            self.originalValues = Self.keys.map { defaults.object(forKey: $0) }
            defaults.set(SettingsStore.SpeechModel.parakeetTDTv2.rawValue, forKey: Self.keys[0])
            defaults.set(MeetingBackendID.productionDefault.rawValue, forKey: Self.keys[1])
        }

        func restore() {
            for (key, value) in zip(Self.keys, self.originalValues) {
                if let value { self.defaults.set(value, forKey: key) }
                else { self.defaults.removeObject(forKey: key) }
            }
        }
    }

    func testEnglishBackendFixtureRestoresAbsentAndGigaAMSelections() throws {
        let suite = "MeetingRecoveryFixtureTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let originals: [(String?, String?)] = [
            (nil, nil),
            (SettingsStore.SpeechModel.gigaam.rawValue, MeetingBackendID.gigaam.rawValue),
            ("future-model", "future-backend"),
        ]
        for (model, backend) in originals {
            defaults.set(model, forKey: "SelectedSpeechModel")
            defaults.set(backend, forKey: "MeetingTranscriptionBackendID")
            let fixture = EnglishBackendFixture(defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: "SelectedSpeechModel"), SettingsStore.SpeechModel.parakeetTDTv2.rawValue)
            XCTAssertEqual(defaults.string(forKey: "MeetingTranscriptionBackendID"), MeetingBackendID.productionDefault.rawValue)
            fixture.restore()
            XCTAssertEqual(defaults.string(forKey: "SelectedSpeechModel"), model, "Restore the stored choice and absence exactly")
            XCTAssertEqual(defaults.string(forKey: "MeetingTranscriptionBackendID"), backend)
        }
    }

    func testEnglishRecoveryFixtureReachesMockCaptureWithCompatibleModel() async throws {
        XCTAssertEqual(UserDefaults.standard.string(forKey: "SelectedSpeechModel"), SettingsStore.SpeechModel.parakeetTDTv2.rawValue)
        XCTAssertEqual(SettingsStore.shared.meetingTranscriptionBackendID, .productionDefault)
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter
        )
        self.addTeardownBlock { @MainActor in await coordinator.shutdownForTermination() }
        let session = try await coordinator.startRecording(configuration: self.makeConfiguration())
        XCTAssertEqual(session.languageCode, "en")
        XCTAssertEqual(session.recordingBackendID, MeetingBackendID.productionDefault.rawValue)
        XCTAssertEqual(session.state, .recording)
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(arbiter.acquireCount, 1)
        await coordinator.shutdownForTermination()
        XCTAssertEqual(arbiter.releaseCount, 1)
    }

    func testStrictBackendInputRefusedBeforeDownloadPermissionLeaseOrPersistence() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalBackend = settings.meetingTranscriptionBackendID
        defer { settings.selectedSpeechModel = originalModel; settings.meetingTranscriptionBackendID = originalBackend }
        settings.selectedSpeechModel = .whisperTiny
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let arbiter = StubArbiter()
        var modelChecks = 0
        var dependencyPreparations = 0
        let processing = MeetingProcessingPipeline(asrServiceProvider: { XCTFail("Refused strict input cannot reach ASR"); return ASRService() },
            managesModelResidency: false, meetingRuntimeFactory: { _ in XCTFail("Refused strict input cannot build runtime"); throw CancellationError() },
            prepareDiarizationDependencies: { _ in XCTFail("Refused strict input cannot prepare pipeline dependencies") })
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: processing, audioArbiter: arbiter,
            validateRecordingModels: { modelChecks += 1 }, prepareRecordingDependencies: { _ in dependencyPreparations += 1 })
        var configuration = self.makeConfiguration()
        configuration.audioStorageMode = .memoryOnly
        configuration.mode = .inRoom
        configuration.languageCode = "en"
        for backendID in [MeetingBackendID.legacyCompatibility, .init(rawValue: "synthetic-unknown")] {
            settings.meetingTranscriptionBackendID = .productionDefault
            configuration.transcriptionBackendID = backendID.rawValue
            do { _ = try await coordinator.startRecording(configuration: configuration); XCTFail("Unsupported strict selection must fail before admission") }
            catch {
                let expected: MeetingBackendError = backendID == .legacyCompatibility
                    ? .unsupportedInput(backend: backendID, input: .boundedMicrophonePCM) : .unknownBackend(backendID)
                XCTAssertEqual(error as? MeetingBackendError, expected)
            }
        }
        XCTAssertEqual(modelChecks, 0)
        XCTAssertEqual(dependencyPreparations, 0)
        XCTAssertEqual(capture.preflightCount, 0)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(arbiter.acquireCount, 0)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(coordinator.isQuiescent)
    }

    func testUnsupportedStreamingModeIsRefusedBeforePreparationForEitherStoragePolicy() async throws {
        let suite = "UnsupportedStreamingCapture.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let arbiter = StubArbiter()
        var preparations = 0
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: {
            XCTFail("Unsupported streaming must not reach ASR"); return ASRService()
        }, managesModelResidency: false, settings: settings)
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: pipeline,
            audioArbiter: arbiter, settings: settings, validateRecordingModels: { preparations += 1 },
            prepareRecordingDependencies: { _ in XCTFail("Unsupported streaming cannot prepare speaker models") })
        for storage in [MeetingAudioStorageMode.memoryOnly, .retainedFiles] {
            var configuration = self.makeConfiguration()
            configuration.mode = .inRoom
            configuration.languageCode = "ru"
            configuration.audioStorageMode = storage
            configuration.speakerLabelsEnabled = true
            configuration.speakerProcessingMode = .streaming
            do {
                _ = try await coordinator.startRecording(configuration: configuration)
                XCTFail("A saved recording must not silently downgrade unsupported streaming")
            } catch {
                XCTAssertEqual(error as? MeetingBackendError,
                    .unsupportedSpeakerProcessingMode(backend: .whisperTiny, mode: .streaming))
            }
        }
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(capture.preflightCount, 0)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(arbiter.acquireCount, 0)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(coordinator.isQuiescent)
    }

    func testExplicitRetainedBackendRefusedBeforePreparationOrPermission() async throws {
        let suite = "ExplicitRetainedBackend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .gigaam
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let arbiter = StubArbiter()
        var preparations = 0
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { XCTFail("Refused request cannot load ASR"); return ASRService() },
            managesModelResidency: false, settings: settings)
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: pipeline,
            audioArbiter: arbiter, settings: settings, validateRecordingModels: { preparations += 1 },
            prepareRecordingDependencies: { _ in XCTFail("Refused request cannot prepare speaker models") })
        let unknown = MeetingBackendID(rawValue: "explicit-unknown")
        for (backend, language, expected) in [
            (unknown, "en", MeetingBackendError.unknownBackend(unknown)),
            (.legacyCompatibility, "ru", .unsupportedLanguage(backend: .legacyCompatibility, languageCode: "ru")),
        ] {
            var configuration = self.makeConfiguration()
            configuration.mode = .inRoom
            configuration.languageCode = language
            configuration.transcriptionBackendID = backend.rawValue
            do { _ = try await coordinator.startRecording(configuration: configuration); XCTFail("Explicit invalid request must be rejected") }
            catch { XCTAssertEqual(error as? MeetingBackendError, expected) }
        }
        XCTAssertEqual(preparations, 0)
        XCTAssertEqual(capture.preflightCount, 0)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(arbiter.acquireCount, 0)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(coordinator.isQuiescent)
    }

    func testUnavailableExplicitTinyArtifactRejectsBeforeAnyPreparationOrCapture() async throws {
        for language in ["en", "auto"] {
            let suite = "UnavailableExplicitTiny.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: defaults)
            settings.selectedSpeechModel = .gigaam
            let ambient = MeetingBackendID(rawValue: "ambient-future-backend")
            settings.meetingTranscriptionBackendID = ambient
            let dir = self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingSessionStore(rootDirectory: dir)
            let capture = StubCaptureController()
            let arbiter = StubArbiter()
            var preparations = 0
            var dependencies = 0
            let pipeline = MeetingProcessingPipeline(asrServiceProvider: { XCTFail("Unavailable artifact cannot reach ASR residency"); return ASRService() },
                managesModelResidency: false, settings: settings,
                meetingRuntimeFactory: { _ in XCTFail("Unavailable artifact cannot construct a runtime"); throw CancellationError() })
            let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: pipeline,
                audioArbiter: arbiter, settings: settings, validateRecordingModels: { preparations += 1 },
                prepareRecordingDependencies: { _ in dependencies += 1 },
                validateFrozenRecordingConfiguration: { _ in
                    // Keep a controlled unavailable-resource outcome even if the developer
                    // cache is populated. The existing validation boundary fails closed too.
                    throw MeetingProcessingError.modelUnavailable
                })
            var configuration = self.makeConfiguration()
            configuration.mode = .inRoom
            configuration.languageCode = language
            configuration.audioStorageMode = .memoryOnly
            configuration.transcriptionBackendID = MeetingBackendID.whisperTiny.rawValue
            // The requested Tiny language/input contract is valid even while GigaAM is selected.
            XCTAssertNoThrow(try pipeline.validateRecordingInput(configuration: configuration, backendID: .whisperTiny))
            do { _ = try await coordinator.startRecording(configuration: configuration); XCTFail("Unavailable explicit artifact must be rejected") }
            catch {
                if case .modelUnavailable? = error as? MeetingProcessingError { }
                else { XCTFail("Expected modelUnavailable, got \(error)") }
            }
            XCTAssertEqual(preparations, 0)
            XCTAssertEqual(dependencies, 0)
            XCTAssertEqual(capture.preflightCount, 0)
            XCTAssertEqual(capture.startCount, 0)
            XCTAssertEqual(arbiter.acquireCount, 0)
            XCTAssertEqual(arbiter.releaseCount, 0)
            XCTAssertEqual(settings.selectedSpeechModel, .gigaam)
            XCTAssertEqual(settings.meetingTranscriptionBackendID, ambient)
            let sessions = try await store.loadAll()
            XCTAssertTrue(sessions.isEmpty)
            XCTAssertTrue(pipeline.memoryAttempts.isEmpty)
            XCTAssertTrue(coordinator.isQuiescent)
        }
    }

    func testExplicitArtifactValidationRequiresNonemptyFrozenIdentity() throws {
        for language in ["en", "auto"] {
            for fingerprint in [nil, "", " \n"] as [String?] {
                let configuration = MeetingFinalProcessingConfiguration(asrModel: PichiMeetingProviderFactory.whisperTinyModelID,
                    asrArtifactFingerprint: fingerprint, languageCode: language, speakerLabelsEnabled: false)
                XCTAssertNoThrow(try PichiMeetingProviderFactory.validateRecordingConfiguration(configuration, isAppleSilicon: true))
                XCTAssertThrowsError(try PichiMeetingProviderFactory.validateRecordingConfiguration(configuration,
                    isAppleSilicon: true, requiresInstalledArtifact: true)) {
                    if case .modelUnavailable? = $0 as? MeetingProcessingError { }
                    else { XCTFail("Expected modelUnavailable, got \($0)") }
                }
            }
            let pinned = MeetingFinalProcessingConfiguration(asrModel: PichiMeetingProviderFactory.whisperTinyModelID,
                asrArtifactFingerprint: "approved-synthetic-tiny-identity", languageCode: language, speakerLabelsEnabled: false)
            XCTAssertNoThrow(try PichiMeetingProviderFactory.validateRecordingConfiguration(pinned,
                isAppleSilicon: true, requiresInstalledArtifact: true))
        }
    }

    func testExplicitBackendRequestRoundTripsWithoutChangingLegacyDefault() throws {
        var configuration = self.makeConfiguration()
        let legacy = try JSONDecoder().decode(MeetingCaptureConfiguration.self,
            from: JSONEncoder().encode(configuration))
        XCTAssertNil(legacy.transcriptionBackendID)
        configuration.transcriptionBackendID = "explicit-request"
        let pinned = try JSONDecoder().decode(MeetingCaptureConfiguration.self,
            from: JSONEncoder().encode(configuration))
        XCTAssertEqual(pinned.transcriptionBackendID, "explicit-request")
    }

    func testBackendChangeDuringPromptCancelsFrozenAdmission() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalBackend = settings.meetingTranscriptionBackendID
        defer { settings.selectedSpeechModel = originalModel; settings.meetingTranscriptionBackendID = originalBackend }
        settings.selectedSpeechModel = .whisperTiny
        settings.meetingTranscriptionBackendID = .productionDefault
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        capture.onPreflight = { await MainActor.run { settings.meetingTranscriptionBackendID = .legacyCompatibility } }
        let arbiter = StubArbiter()
        var modelChecks = 0
        let processing = MeetingProcessingPipeline(asrServiceProvider: { XCTFail("Changed unsupported input cannot reach ASR"); return ASRService() },
            managesModelResidency: false, meetingRuntimeFactory: { _ in XCTFail("Changed unsupported input cannot create a runtime"); throw CancellationError() })
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: processing, audioArbiter: arbiter,
            validateRecordingModels: { modelChecks += 1 }, prepareRecordingDependencies: { _ in XCTFail("Disabled speaker labels cannot prepare dependencies") })
        var configuration = self.makeConfiguration()
        configuration.audioStorageMode = .memoryOnly
        configuration.mode = .inRoom
        configuration.languageCode = "en"
        configuration.speakerLabelsEnabled = false
        do { _ = try await coordinator.startRecording(configuration: configuration); XCTFail("Changed backend must be revalidated") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(modelChecks, 1)
        XCTAssertEqual(capture.preflightCount, 1)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(arbiter.acquireCount, 0)
        XCTAssertEqual(arbiter.releaseCount, 0)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(coordinator.isQuiescent)
    }

    func testOwnedBackendAndFrozenModelIgnoreAnotherSettingsOwnersExplicitSelection() async throws {
        let shared = SettingsStore.shared
        let previousModel = shared.selectedSpeechModel
        let previousBackend = shared.meetingTranscriptionBackendID
        defer { shared.selectedSpeechModel = previousModel; shared.meetingTranscriptionBackendID = previousBackend }
        shared.selectedSpeechModel = .whisperTiny
        shared.meetingTranscriptionBackendID = .whisperTiny
        let suite = "OwnedMeetingBackend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .gigaam
        settings.meetingTranscriptionBackendID = .legacyCompatibility
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let track = self.makeMicrophoneTrack(chunks: [])
        capture.startResult = .init(tracks: [track], firstPresentationTime: nil)
        let processing = MemoryCheckpointProcessingController()
        var frozen: MeetingFinalProcessingConfiguration?
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: processing,
            audioArbiter: StubArbiter(), settings: settings,
            validateFrozenRecordingConfiguration: { frozen = $0 })
        var configuration = self.makeConfiguration()
        configuration.mode = .inRoom
        configuration.languageCode = "ru"
        configuration.audioStorageMode = .memoryOnly
        configuration.speakerLabelsEnabled = false
        let session = try await coordinator.startRecording(configuration: configuration)
        capture.stopResult = .init(tracks: [track], stoppedAt: Date())
        let prepared = try XCTUnwrap(processing.preparedSession)
        let frozenConfiguration = try XCTUnwrap(frozen)
        XCTAssertEqual(processing.validatedBackendIDs, [.gigaam, .gigaam])
        XCTAssertEqual(session.recordingBackendID, MeetingBackendID.gigaam.rawValue)
        XCTAssertEqual(prepared.recordingBackendID, session.recordingBackendID)
        XCTAssertEqual(frozenConfiguration.asrModel, PichiMeetingProviderFactory.gigaamModelID)
        XCTAssertEqual(session.recordingASRArtifactFingerprint, frozenConfiguration.asrArtifactFingerprint)
        XCTAssertEqual(prepared.recordingASRArtifactFingerprint, session.recordingASRArtifactFingerprint)
        let completed = try await coordinator.stopAndTranscribe()
        XCTAssertEqual(completed.recordingBackendID, session.recordingBackendID)
        let persisted = try await store.load(id: session.id)
        XCTAssertEqual(persisted?.recordingBackendID, session.recordingBackendID)
        XCTAssertEqual(shared.meetingTranscriptionBackendID, .whisperTiny)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, .legacyCompatibility)
    }

    func testOrdinaryCaptureRemainsUsableAfterUnavailableExplicitArtifact() async throws {
        let suite = "ExplicitCapturedBackend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        let ambient = MeetingBackendID(rawValue: "ambient-future-backend")
        settings.meetingTranscriptionBackendID = ambient
        let dir = self.makeTempDirectory()
        let loadEntered = (1...4).map { self.expectation(description: "Retention loadAll \($0) entered") }
        let store = GatedLoadAllStore(inner: MeetingSessionStore(rootDirectory: dir)) { index in
            guard loadEntered.indices.contains(index - 1) else { return XCTFail("Unexpected retention loadAll \(index)") }
            loadEntered[index - 1].fulfill()
        }
        let capture = StubCaptureController()
        let track = self.makeMicrophoneTrack(chunks: [])
        capture.startResult = .init(tracks: [track], firstPresentationTime: nil)
        capture.stopResult = .init(tracks: [track], stoppedAt: Date())
        let processing = MemoryCheckpointProcessingController()
        let arbiter = StubArbiter()
        var preparations = 0
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: processing,
            audioArbiter: arbiter, settings: settings, validateRecordingModels: { preparations += 1 }, validateFrozenRecordingConfiguration: { configuration in
                if configuration.asrModel == PichiMeetingProviderFactory.gigaamModelID { throw MeetingProcessingError.modelUnavailable }
            })
        self.addTeardownBlock { @MainActor in
            await store.openAllGates()
            await coordinator.shutdownForTermination()
            try? FileManager.default.removeItem(at: dir)
        }
        // A future change that incorrectly joins held maintenance inside Stop must fail
        // a bounded expectation, then release its controlled store wait before cleanup.
        func stopWithDeadline() async throws -> MeetingSession {
            let returned = self.expectation(description: "Stop returns with joined audio handback")
            var outcome: Result<MeetingSession, Error>?
            let stop = Task { @MainActor in
                do { outcome = .success(try await coordinator.stopAndTranscribe()) }
                catch { outcome = .failure(error) }
                returned.fulfill()
            }
            await self.fulfillment(of: [returned], timeout: 2)
            guard let outcome else {
                await store.openAllGates()
                stop.cancel()
                await stop.value
                throw GateTimeoutError()
            }
            await stop.value
            return try outcome.get()
        }
        var configuration = self.makeConfiguration()
        configuration.mode = .inRoom
        configuration.languageCode = "ru"
        configuration.audioStorageMode = .memoryOnly
        configuration.speakerLabelsEnabled = false
        configuration.transcriptionBackendID = MeetingBackendID.gigaam.rawValue
        do { _ = try await coordinator.startRecording(configuration: configuration); XCTFail("Expected unavailable explicit artifact") }
        catch {
                if case .modelUnavailable? = error as? MeetingProcessingError { }
                else { XCTFail("Expected modelUnavailable, got \(error)") }
            }
        XCTAssertTrue(processing.validatedBackendIDs.allSatisfy { $0 == .gigaam })
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, ambient)
        XCTAssertTrue(coordinator.isQuiescent)
        XCTAssertEqual(preparations, 0)
        // A subsequent ordinary request still uses the selected model and its normal owner.
        configuration.transcriptionBackendID = nil
        configuration.languageCode = "auto"
        for attempt in 1...2 {
            let normal = try await coordinator.startRecording(configuration: configuration)
            XCTAssertEqual(normal.recordingBackendID, MeetingBackendID.whisperTiny.rawValue)
            XCTAssertEqual(capture.startCount, attempt)
            XCTAssertEqual(preparations, attempt)
            let startSweep = (attempt - 1) * 2 + 1
            let stopSweep = startSweep + 1
            // Successful Start also schedules retention. Hold it explicitly so the Stop
            // sweep cannot hide behind a transient quiescent gap between queued tasks.
            await self.fulfillment(of: [loadEntered[startSweep - 1]], timeout: 2)
            capture.stopResult = .init(tracks: [track], stoppedAt: Date())
            let completed = try await stopWithDeadline()
            XCTAssertEqual(completed.state, .completed)
            XCTAssertEqual(coordinator.state, .completed(normal.id))
            XCTAssertEqual(capture.stopCount, attempt)
            XCTAssertEqual(arbiter.acquireCount, attempt)
            XCTAssertEqual(arbiter.releaseCount, attempt, "Stop joins each audio handback exactly once")
            XCTAssertFalse(coordinator.isRecording)
            XCTAssertFalse(coordinator.isProcessing)
            XCTAssertFalse(coordinator.isQuiescent, "Held maintenance must keep the mutation gate closed")
            await store.openGate(startSweep)
            await self.fulfillment(of: [loadEntered[stopSweep - 1]], timeout: 2)
            XCTAssertFalse(coordinator.isQuiescent, "Post-processing maintenance is still held")
            let quiescent = self.expectation(description: "Maintenance releases the real quiescence gate")
            var observing = true
            let subscription = coordinator.objectWillChange.sink { _ in
                // ObservableObject sends in willSet. Inspect on the next MainActor job,
                // after the setter commits the gate's new value.
                Task { @MainActor in
                    guard observing, coordinator.isQuiescent else { return }
                    observing = false
                    quiescent.fulfill()
                }
            }
            await store.openGate(stopSweep)
            await self.fulfillment(of: [quiescent], timeout: 2)
            observing = false
            subscription.cancel()
            XCTAssertTrue(coordinator.isQuiescent)
            XCTAssertEqual(arbiter.releaseCount, attempt)
        }
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, ambient)
    }

    func testOwnedBackendChangeDuringPromptCancelsThatOwnersAdmission() async throws {
        let shared = SettingsStore.shared
        let previousBackend = shared.meetingTranscriptionBackendID
        defer { shared.meetingTranscriptionBackendID = previousBackend }
        shared.meetingTranscriptionBackendID = .whisperTiny
        let suite = "OwnedMeetingBackendPrompt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        settings.meetingTranscriptionBackendID = .productionDefault
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        capture.onPreflight = { await MainActor.run { settings.meetingTranscriptionBackendID = .legacyCompatibility } }
        let arbiter = StubArbiter()
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { XCTFail("Refused input cannot prepare models"); return ASRService() },
            managesModelResidency: false, settings: settings)
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: pipeline,
            audioArbiter: arbiter, settings: settings)
        var configuration = self.makeConfiguration()
        configuration.mode = .inRoom
        configuration.languageCode = "en"
        configuration.audioStorageMode = .memoryOnly
        configuration.speakerLabelsEnabled = false
        do { _ = try await coordinator.startRecording(configuration: configuration); XCTFail("Owned backend change must be revalidated") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(capture.preflightCount, 1)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(arbiter.acquireCount, 0)
        XCTAssertEqual(arbiter.releaseCount, 0)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertEqual(shared.meetingTranscriptionBackendID, .whisperTiny)
    }

    func testMemoryTailCheckpointSurvivesPartialStopFailure() async throws {
        try await self.assertMemoryTailSurvivesTerminalPath("partialFailure")
    }
    func testMemoryTailCheckpointSurvivesUnexpectedStopGenerationInvalidation() async throws {
        try await self.assertMemoryTailSurvivesTerminalPath("unexpected")
    }
    func testMemoryTailCheckpointSurvivesTerminationGenerationInvalidation() async throws {
        try await self.assertMemoryTailSurvivesTerminalPath("termination")
    }
    func testMemoryTailCheckpointSurvivesNormalStop() async throws {
        try await self.assertMemoryTailSurvivesTerminalPath("normal")
    }
    private func assertMemoryTailSurvivesTerminalPath(_ path: String) async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        let originalBackend = settings.meetingTranscriptionBackendID
        defer { settings.selectedSpeechModel = originalModel; settings.meetingTranscriptionBackendID = originalBackend }
        settings.selectedSpeechModel = .whisperTiny
        settings.meetingTranscriptionBackendID = .productionDefault
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let track = self.makeMicrophoneTrack(chunks: [])
        capture.startResult = MeetingCaptureStartResult(tracks: [track], firstPresentationTime: nil)
        capture.stopResult = MeetingCaptureStopResult(tracks: [track], stoppedAt: Date().addingTimeInterval(1))
        let processing = MemoryCheckpointProcessingController()
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: processing, audioArbiter: arbiter)
        var configuration = self.makeConfiguration()
        configuration.audioStorageMode = .memoryOnly
        configuration.languageCode = "en"
        let session = try await coordinator.startRecording(configuration: configuration)
        let first = MeetingTranscriptSegment(id: UUID(), start: .init(value: 0, timescale: 1), end: .init(value: 1, timescale: 1),
            sourceTrackID: track.id, speakerID: nil, text: "Already durable", revision: 0, status: .final, overlap: .none, completeness: .complete)
        let tail = MeetingTranscriptSegment(id: UUID(), start: .init(value: 1, timescale: 1), end: .init(value: 2, timescale: 1),
            sourceTrackID: track.id, speakerID: nil, text: "Joined final tail", revision: 0, status: .final, overlap: .none, completeness: .complete)
        try await processing.checkpoint(.init(segments: [first]))
        let speaker = MeetingSessionSpeaker(id: UUID(), displayName: "Synthetic participant",
            diarizationClusterID: "synthetic-voice", trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        var attributedFirst = first
        attributedFirst.speakerID = speaker.id
        let firstRevision = MeetingPCMTranscriptBatch.SpeakerRevision(attributedFirst)
        XCTAssertEqual(coordinator.liveTranscript.utterances.first?.participant?.label, .unknown,
            "Protected PCM rows use product speaker presentation even before attribution")
        capture.onStop = {
            try await processing.checkpoint(.init(segments: [tail], speakers: [speaker]))
            var revisionOnly = MeetingPCMTranscriptBatch(segments: [])
            revisionOnly.speakerRevisions = [firstRevision]
            try await processing.checkpoint(revisionOnly)
        }
        if path == "partialFailure" {
            capture.stopError = MeetingCaptureError.captureStopFailed("Synthetic partial stop", partialResult: try XCTUnwrap(capture.stopResult))
            do { _ = try await coordinator.stopAndTranscribe(); XCTFail("Expected partial failure") } catch { }
        } else if path == "unexpected" {
            capture.emit(.interrupted(kind: .captureStoppedUnexpectedly, trackID: track.id, detail: "Synthetic stop"))
            for _ in 0..<200 { if arbiter.releaseCount > 0 { break }; try await Task.sleep(nanoseconds: 5_000_000) }
        } else if path == "termination" {
            await coordinator.shutdownForTermination()
        } else {
            let completed = try await coordinator.stopAndTranscribe()
            XCTAssertEqual(completed.transcriptSegments.map(\.text), [first.text, tail.text])
            XCTAssertEqual(completed.transcriptTimeDomain, .meetingRelative)
            XCTAssertEqual(completed.transcriptIsComplete, true)
        }
        let persisted = try await store.load(id: session.id)
        XCTAssertEqual(persisted?.transcriptSegments.map(\.text), [first.text, tail.text], "Terminal snapshot must never roll back joined durable text")
        let patchedFirst = try XCTUnwrap(persisted?.transcriptSegments.first)
        XCTAssertEqual(patchedFirst.speakerID, speaker.id, "Joined speaker-only tail revisions must survive every terminal path")
        XCTAssertEqual(patchedFirst.revision, first.revision + 1)
        XCTAssertEqual(patchedFirst.start, first.start)
        XCTAssertEqual(patchedFirst.end, first.end)
        XCTAssertEqual(patchedFirst.status, first.status)
        XCTAssertEqual(patchedFirst.completeness, first.completeness)
        XCTAssertEqual(arbiter.releaseCount, 1)
        XCTAssertEqual(processing.cancelCount, path == "normal" ? 0 : 1)
    }

    func testUnexpectedStopPublishesQuiescenceAfterDelayedAudioHandback() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(
            tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil
        )
        let leasing = SuspendedHandbackASRActivityLeasing()
        defer { leasing.resumeHandback() }
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: AudioActivityArbiter { leasing }
        )
        let session = try await coordinator.startRecording(configuration: self.makeConfiguration())
        capture.emit(.interrupted(kind: .captureStoppedUnexpectedly, trackID: nil, detail: "Fixture stop"))
        for _ in 0..<200 {
            if leasing.handbackStarted { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(leasing.handbackStarted, "Unexpected stop must reach audio handback")
        XCTAssertEqual(coordinator.state, .interrupted(session.id))
        XCTAssertFalse(coordinator.isQuiescent, "Retry/settings refresh must wait for handback")
        await self.drainCaptureEvents()
        var notifications = 0
        let subscription = coordinator.objectWillChange.sink { notifications += 1 }
        defer { subscription.cancel() }
        leasing.resumeHandback()
        for _ in 0..<200 {
            if coordinator.isQuiescent { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(coordinator.isQuiescent)
        XCTAssertGreaterThan(notifications, 0, "Views must be told when retry/settings refresh becomes safe")
        XCTAssertEqual(coordinator.state, .interrupted(session.id), "Completion must not restart recording")
        XCTAssertEqual(capture.startCount, 1)
        XCTAssertEqual(leasing.handbackCount, 1)
        let saved = try await store.load(id: session.id)
        XCTAssertEqual(saved?.state, .interrupted)
        XCTAssertTrue(saved?.failures.isEmpty == true)
    }

    func testVoiceProcessingFallbackDoesNotDegradeHealthyRecording() async throws {
        for deliverDuringStart in [false, true] {
            let dir = self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingSessionStore(rootDirectory: dir)
            let capture = StubCaptureController()
            var microphone = self.makeMicrophoneTrack(chunks: [])
            microphone.health.status = .healthy
            var applicationAudio = self.makeMicrophoneTrack(chunks: [])
            applicationAudio.kind = .applicationAudio
            applicationAudio.health.status = .healthy
            capture.startResult = MeetingCaptureStartResult(tracks: [microphone, applicationAudio], firstPresentationTime: nil)
            let fallback = MeetingCaptureEvent.interrupted(kind: .voiceProcessingDeclined, trackID: nil, detail: "The output device is Bluetooth.")
            if deliverDuringStart { capture.startupEvents = [fallback] }
            capture.onStart = { @MainActor in await self.drainCaptureEvents() }
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            var configuration = self.makeConfiguration()
            configuration.mode = .onlineCall
            configuration.application = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", displayName: "Zoom")

            let started = try await coordinator.startRecording(configuration: configuration)
            XCTAssertEqual(started.state, .recording)
            let persisted = try await store.load(id: started.id)
            XCTAssertEqual(persisted?.state, .recording)
            if !deliverDuringStart {
                capture.emit(fallback)
                await self.drainCaptureEvents()
            }
            XCTAssertEqual(coordinator.state, .recording(started.id), "Selecting a supported fallback is not a capture failure")
            XCTAssertEqual(coordinator.activeSession?.events.map(\.kind), [.voiceProcessingDeclined])
            capture.emit(.trackHealth(trackID: microphone.id, health: microphone.health))
            capture.emit(.trackHealth(trackID: applicationAudio.id, health: applicationAudio.health))
            await self.drainCaptureEvents()
            XCTAssertEqual(coordinator.state, .recording(started.id))
            XCTAssertEqual(coordinator.trackHealth[.microphone]?.status, .healthy)
            XCTAssertEqual(coordinator.trackHealth[.applicationAudio]?.status, .healthy)
            await coordinator.shutdownForTermination()
        }
    }

    func testWriterFailureDuringStartPreservesEventAndDegradedHealth() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let microphone = self.makeMicrophoneTrack(chunks: [])
        var degradedHealth = microphone.health
        degradedHealth.status = .degraded
        degradedHealth.detail = "Unsupported PCM format"
        // The snapshot can precede the writer failure while capture.start is still suspended.
        capture.startResult = MeetingCaptureStartResult(tracks: [microphone], firstPresentationTime: nil)
        capture.startupEvents = [
            .trackHealth(trackID: microphone.id, health: degradedHealth),
            .interrupted(kind: .writerFailure, trackID: microphone.id, detail: degradedHealth.detail),
        ]
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        capture.onStart = { @MainActor in
            for _ in 0..<100 {
                if coordinator.activeSession?.events.count == 1 { break }
                await Task.yield()
            }
            XCTAssertEqual(coordinator.activeSession?.events.count, 1, "Deliver the failure while capture.start is suspended")
        }
        let started = try await coordinator.startRecording(configuration: self.makeConfiguration())
        XCTAssertEqual(started.events.map(\.kind), [.writerFailure])
        XCTAssertEqual(started.audioTracks.first?.health.status, .degraded)
        XCTAssertEqual(coordinator.state, .recordingDegraded(started.id))
        XCTAssertEqual(coordinator.trackHealth[.microphone]?.status, .degraded)
        let persisted = try await store.load(id: started.id)
        XCTAssertEqual(persisted?.state, .recordingDegraded)
        XCTAssertEqual(persisted?.events.map(\.kind), [.writerFailure])
        XCTAssertEqual(persisted?.audioTracks.first?.health.status, .degraded)
        await coordinator.shutdownForTermination()
    }

    func testRecoveredWriterDuringStartKeepsHistoryWithoutDegradingRecording() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        var microphone = self.makeMicrophoneTrack(chunks: [])
        microphone.health.status = .healthy
        capture.startResult = MeetingCaptureStartResult(tracks: [microphone], firstPresentationTime: nil)
        capture.startupEvents = [
            .interrupted(kind: .writerFailure, trackID: microphone.id, detail: "Temporary writer failure"),
            .trackHealth(trackID: microphone.id, health: microphone.health),
        ]
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        capture.onStart = { @MainActor in
            for _ in 0..<100 {
                if coordinator.activeSession?.events.count == 1 { break }
                await Task.yield()
            }
            XCTAssertEqual(coordinator.activeSession?.events.count, 1)
        }

        let started = try await coordinator.startRecording(configuration: self.makeConfiguration())
        XCTAssertEqual(started.events.map(\.kind), [.writerFailure])
        XCTAssertEqual(started.state, .recording)
        XCTAssertEqual(coordinator.state, .recording(started.id))
        XCTAssertEqual(coordinator.trackHealth[.microphone]?.status, .healthy)
        let persisted = try await store.load(id: started.id)
        XCTAssertEqual(persisted?.state, .recording)
        XCTAssertEqual(persisted?.events.map(\.kind), [.writerFailure])
        await coordinator.shutdownForTermination()
    }

    func testStartupWriterFailureWithoutHealthyTrackRemainsDegraded() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let microphone = self.makeMicrophoneTrack(chunks: [])
        capture.startResult = MeetingCaptureStartResult(tracks: [microphone], firstPresentationTime: nil)
        capture.startupEvents = [
            .interrupted(kind: .writerFailure, trackID: microphone.id, detail: "No successful writes yet"),
        ]
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        capture.onStart = { @MainActor in
            for _ in 0..<100 {
                if coordinator.activeSession?.events.count == 1 { break }
                await Task.yield()
            }
            XCTAssertEqual(coordinator.activeSession?.events.count, 1)
        }

        let started = try await coordinator.startRecording(configuration: self.makeConfiguration())
        XCTAssertEqual(started.state, .recordingDegraded)
        XCTAssertEqual(coordinator.state, .recordingDegraded(started.id))
        let persisted = try await store.load(id: started.id)
        XCTAssertEqual(persisted?.state, .recordingDegraded)
        XCTAssertEqual(persisted?.events.map(\.kind), [.writerFailure])
        await coordinator.shutdownForTermination()
    }

    func testStaleStartupHealthDoesNotClearFailureAndLaterHealthCanRecover() async throws {
        for emitEarlierHealth in [false, true] {
            let dir = self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingSessionStore(rootDirectory: dir)
            let capture = StubCaptureController()
            var microphone = self.makeMicrophoneTrack(chunks: [])
            microphone.health.status = .healthy
            capture.startResult = MeetingCaptureStartResult(tracks: [microphone], firstPresentationTime: nil)
            if emitEarlierHealth {
                capture.startupEvents.append(.trackHealth(trackID: microphone.id, health: microphone.health))
            }
            capture.startupEvents.append(.interrupted(kind: .writerFailure, trackID: microphone.id, detail: "New writer failure"))
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            capture.onStart = { @MainActor in
                for _ in 0..<100 {
                    if coordinator.activeSession?.events.count == 1 { break }
                    await Task.yield()
                }
                XCTAssertEqual(coordinator.activeSession?.events.count, 1)
            }

            let started = try await coordinator.startRecording(configuration: self.makeConfiguration())
            XCTAssertEqual(started.state, .recordingDegraded, "An older healthy snapshot or event cannot prove recovery")
            XCTAssertEqual(coordinator.trackHealth[.microphone]?.status, .degraded)
            var degraded = microphone.health
            degraded.status = .degraded
            degraded.detail = "Delayed failure health"
            capture.emit(.trackHealth(trackID: microphone.id, health: degraded))
            for _ in 0..<100 {
                if coordinator.trackHealth[.microphone]?.detail == degraded.detail { break }
                await Task.yield()
            }
            XCTAssertEqual(coordinator.state, .recordingDegraded(started.id))
            capture.emit(.trackHealth(trackID: microphone.id, health: microphone.health))
            for _ in 0..<100 {
                if coordinator.state == .recording(started.id) { break }
                await Task.yield()
            }
            XCTAssertEqual(coordinator.state, .recording(started.id), "A later healthy callback resolves the startup failure")
            XCTAssertEqual(coordinator.activeSession?.events.map(\.kind), [.writerFailure])
            await coordinator.shutdownForTermination()
        }
    }

    func testStartupWriterRecoveryDoesNotClearAnotherInterruption() async throws {
        for (interruptDuringStart, sourceLost) in [(false, false), (true, false), (false, true), (true, true)] {
            let dir = self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingSessionStore(rootDirectory: dir)
            let capture = StubCaptureController()
            let microphone = self.makeMicrophoneTrack(chunks: [])
            capture.startResult = MeetingCaptureStartResult(tracks: [microphone], firstPresentationTime: nil)
            capture.startupEvents = [.interrupted(kind: .writerFailure, trackID: microphone.id, detail: "Startup failure")]
            if sourceLost { capture.startupEvents.append(.interrupted(kind: .sourceLost, trackID: nil, detail: nil)) }
            let diskFull = MeetingCaptureEvent.interrupted(kind: .diskExhausted, trackID: nil, detail: "Disk full")
            if interruptDuringStart { capture.startupEvents.append(diskFull) }
            capture.onStart = { @MainActor in await self.drainCaptureEvents() }
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            let started = try await coordinator.startRecording(configuration: self.makeConfiguration())
            if !interruptDuringStart {
                capture.emit(diskFull)
                await self.drainCaptureEvents()
            }
            XCTAssertEqual(coordinator.activeSession?.events.count, sourceLost ? 3 : 2)
            var healthy = microphone.health
            healthy.status = .healthy
            capture.emit(.trackHealth(trackID: microphone.id, health: healthy))
            await self.drainCaptureEvents()
            XCTAssertEqual(coordinator.trackHealth[.microphone]?.status, .healthy)
            XCTAssertEqual(coordinator.state, .recordingDegraded(started.id))
            if sourceLost {
                capture.emit(.interrupted(kind: .sourceRecovered, trackID: nil, detail: nil))
                await self.drainCaptureEvents()
                XCTAssertEqual(coordinator.state, .recordingDegraded(started.id), "Source recovery cannot clear a disk failure")
            }
            await coordinator.shutdownForTermination()
        }
    }

    func testStartupSourceLossAndWriterFailureRequireBothRecoveries() async throws {
        for (writerDuringStart, sourceDuringStart) in [(false, false), (true, false), (false, true), (true, true)] {
            for sourceRecoversFirst in [false, true] {
                let dir = self.makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = MeetingSessionStore(rootDirectory: dir)
                let capture = StubCaptureController()
                var microphone = self.makeMicrophoneTrack(chunks: [])
                microphone.health.status = .healthy
                var applicationAudio = self.makeMicrophoneTrack(chunks: [])
                applicationAudio.kind = .applicationAudio
                applicationAudio.health.status = .healthy
                capture.startResult = MeetingCaptureStartResult(tracks: [microphone, applicationAudio], firstPresentationTime: nil)
                capture.startupEvents = [
                    .interrupted(kind: .writerFailure, trackID: microphone.id, detail: "Startup writer failure"),
                    .interrupted(kind: .sourceLost, trackID: nil, detail: "Application audio source lost"),
                ]
                let writerRecovery = MeetingCaptureEvent.trackHealth(trackID: microphone.id, health: microphone.health)
                let sourceRecovery = MeetingCaptureEvent.interrupted(kind: .sourceRecovered, trackID: nil, detail: nil)
                let recoveries: [(event: MeetingCaptureEvent, duringStart: Bool)] = sourceRecoversFirst
                    ? [(sourceRecovery, sourceDuringStart), (writerRecovery, writerDuringStart)]
                    : [(writerRecovery, writerDuringStart), (sourceRecovery, sourceDuringStart)]
                capture.startupEvents += recoveries.filter(\.duringStart).map(\.event)
                capture.onStart = { @MainActor in await self.drainCaptureEvents() }
                let coordinator = MeetingSessionCoordinator(
                    store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
                )

                var configuration = self.makeConfiguration()
                configuration.mode = .onlineCall
                configuration.application = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", displayName: "Zoom")
                let started = try await coordinator.startRecording(configuration: configuration)
                let expectedStart: MeetingSessionState = writerDuringStart && sourceDuringStart ? .recording : .recordingDegraded
                XCTAssertEqual(started.state, expectedStart)
                let persisted = try await store.load(id: started.id)
                XCTAssertEqual(persisted?.state, expectedStart)
                if !writerDuringStart {
                    var degraded = microphone.health
                    degraded.status = .degraded
                    capture.emit(.trackHealth(trackID: microphone.id, health: degraded))
                    await self.drainCaptureEvents()
                    XCTAssertEqual(coordinator.state, .recordingDegraded(started.id))
                }
                let pendingRecoveries = recoveries.filter { !$0.duringStart }
                for (index, recovery) in pendingRecoveries.enumerated() {
                    capture.emit(recovery.event)
                    await self.drainCaptureEvents()
                    let expected: MeetingCoordinatorState = index == pendingRecoveries.count - 1
                        ? .recording(started.id) : .recordingDegraded(started.id)
                    XCTAssertEqual(coordinator.state, expected, "Both the writer and the lost source must recover")
                }
                XCTAssertEqual(coordinator.state, .recording(started.id))
                XCTAssertEqual(coordinator.activeSession?.events.map(\.kind), [.writerFailure, .sourceLost, .sourceRecovered])
                await coordinator.shutdownForTermination()
            }
        }
    }

    func testSourceRecoveryPreservesSilenceWatchdogRecovery() async throws {
        for sourceLostFirst in [false, true] {
            for sourceRecoversFirst in [false, true] {
                let dir = self.makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: dir) }
                let capture = StubCaptureController()
                var microphone = self.makeMicrophoneTrack(chunks: [])
                microphone.health.status = .healthy
                microphone.health.silentForSeconds = 0
                var applicationAudio = self.makeMicrophoneTrack(chunks: [])
                applicationAudio.kind = .applicationAudio
                applicationAudio.health.status = .healthy
                applicationAudio.health.silentForSeconds = 0
                capture.startResult = MeetingCaptureStartResult(tracks: [microphone, applicationAudio], firstPresentationTime: nil)
                let coordinator = MeetingSessionCoordinator(
                    store: MeetingSessionStore(rootDirectory: dir),
                    capture: capture,
                    processing: StubProcessingController(),
                    audioArbiter: StubArbiter()
                )
                var configuration = self.makeConfiguration()
                configuration.mode = .onlineCall
                configuration.application = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", displayName: "Zoom")
                let started = try await coordinator.startRecording(configuration: configuration)
                var silentHealth = applicationAudio.health
                silentHealth.silentForSeconds = 100
                let silence = MeetingCaptureEvent.trackHealth(trackID: applicationAudio.id, health: silentHealth)
                let sourceLoss = MeetingCaptureEvent.interrupted(kind: .sourceLost, trackID: nil, detail: nil)
                for event in sourceLostFirst ? [sourceLoss, silence] : [silence, sourceLoss] {
                    capture.emit(event)
                    await self.drainCaptureEvents()
                    XCTAssertEqual(coordinator.state, .recordingDegraded(started.id))
                }
                XCTAssertEqual(coordinator.trackHealth[.applicationAudio]?.status, .degraded)
                let audioRecovery = MeetingCaptureEvent.trackHealth(trackID: applicationAudio.id, health: applicationAudio.health)
                let sourceRecovery = MeetingCaptureEvent.interrupted(kind: .sourceRecovered, trackID: nil, detail: nil)
                let recoveries = sourceRecoversFirst ? [sourceRecovery, audioRecovery] : [audioRecovery, sourceRecovery]
                capture.emit(recoveries[0])
                await self.drainCaptureEvents()
                XCTAssertEqual(coordinator.state, .recordingDegraded(started.id), "Both the source and captured audio must recover")
                capture.emit(recoveries[1])
                await self.drainCaptureEvents()
                XCTAssertEqual(coordinator.state, .recording(started.id))
                await coordinator.shutdownForTermination()
            }
        }
    }

    private func drainCaptureEvents() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testCaptureStartFailurePersistsStartupWriterEvent() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let trackID = UUID()
        capture.startError = MeetingCaptureError.captureStartFailed("Capture could not finish starting")
        capture.startupEvents = [
            .interrupted(kind: .writerFailure, trackID: trackID, detail: "Unsupported PCM format"),
        ]
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        capture.onStart = { @MainActor in
            for _ in 0..<100 {
                if coordinator.activeSession?.events.count == 1 { break }
                await Task.yield()
            }
            XCTAssertEqual(coordinator.activeSession?.events.count, 1)
        }

        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration())
            XCTFail("Expected capture startup to fail")
        } catch let error as MeetingCaptureError {
            guard case .captureStartFailed = error else { return XCTFail("Unexpected capture error: \(error)") }
        }
        let sessions = try await store.loadAll()
        XCTAssertEqual(sessions.count, 1)
        let failed = try XCTUnwrap(sessions.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.events.map(\.kind), [.writerFailure])
        XCTAssertEqual(failed.events.first?.trackID, trackID)
        XCTAssertEqual(failed.events.first?.detail, "Unsupported PCM format")
        XCTAssertEqual(failed.failures.last?.domain, .capture)
        XCTAssertNil(coordinator.activeSession)
    }

    func testPersistenceCoalescesSlowStoreAndFlushesNewestSnapshot() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let recorder = EventRecorder()
        let store = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        let queue = MeetingSessionPersistenceQueue(store: store)
        var session = self.makeSession(state: .recording, audioTracks: [self.makeMicrophoneTrack(chunks: [])])
        session.events.append(MeetingSessionEvent(id: UUID(), occurredAt: Date(), kind: .writerFailure, trackID: nil, detail: "First failure"))
        await store.closeGate()
        queue.enqueue(session)
        for _ in 0..<100 {
            if await recorder.events.contains("store.save.start") { break }
            await Task.yield()
        }
        let started = await recorder.events.contains("store.save.start")
        XCTAssertTrue(started, "The first snapshot must be in flight before the burst")
        for index in 1..<1000 {
            session.events.append(MeetingSessionEvent(id: UUID(), occurredAt: Date(), kind: .writerFailure, trackID: nil, detail: "Failure \(index)"))
            queue.enqueue(session)
        }
        let firstFlush = Task { await queue.flush() }
        let secondFlush = Task { await queue.flush() }
        await store.openGate()
        await firstFlush.value
        await secondFlush.value

        let savedCounts = await store.savedEventCounts
        XCTAssertEqual(savedCounts, [1, 1000], "Slow storage must not save or retain every intermediate snapshot")
        let persisted = try await store.load(id: session.id)
        XCTAssertEqual(persisted?.events.map(\.id), session.events.map(\.id))
        XCTAssertEqual(persisted?.events.last?.detail, session.events.last?.detail)

        // A direct terminal save after flush must never be overwritten by an older queued state.
        session.state = .interrupted
        session.endedAt = Date()
        try await store.save(session)
        await queue.flush()
        let terminal = try await store.load(id: session.id)
        XCTAssertEqual(terminal?.state, .interrupted)

        session.title = "Worker restarted"
        queue.enqueue(session)
        await queue.flush()
        let restarted = try await store.load(id: session.id)
        XCTAssertEqual(restarted?.title, "Worker restarted")
    }

    func testPersistenceKeepsLatestSnapshotForEachSession() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = EventRecorder()
        let store = GatedThrowingSaveStore(inner: MeetingSessionStore(rootDirectory: dir), recorder: recorder)
        let queue = MeetingSessionPersistenceQueue(store: store)
        var previous = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [self.makeMicrophoneTrack(chunks: [])])
        var current = self.makeSession(state: .recording, audioTracks: [self.makeMicrophoneTrack(chunks: [])])
        await store.closeGate()
        queue.enqueue(previous)
        for _ in 0..<100 {
            if await recorder.events.contains("store.save.start") { break }
            await Task.yield()
        }
        let started = await recorder.events.contains("store.save.start")
        XCTAssertTrue(started)
        queue.enqueue(current)
        previous.recoveryResolvedAt = Date()
        queue.enqueue(previous)
        current.title = "Newest recording snapshot"
        queue.enqueue(current)
        await store.openGate()
        await queue.flush()
        let persistedPrevious = try await store.load(id: previous.id)
        let persistedCurrent = try await store.load(id: current.id)
        XCTAssertNotNil(persistedPrevious?.recoveryResolvedAt)
        XCTAssertEqual(persistedCurrent?.title, current.title)
        let savedCounts = await store.savedEventCounts
        XCTAssertEqual(savedCounts.count, 3, "One in-flight save and one pending save per session")
    }

    func testPersistenceContinuesAfterSaveFailure() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = EventRecorder()
        let store = GatedThrowingSaveStore(inner: MeetingSessionStore(rootDirectory: dir), recorder: recorder)
        let queue = MeetingSessionPersistenceQueue(store: store)
        var session = self.makeSession(state: .recording, audioTracks: [self.makeMicrophoneTrack(chunks: [])])
        let nextSession = self.makeSession(state: .recording, audioTracks: [self.makeMicrophoneTrack(chunks: [])])
        await store.throwOnNextSave()
        queue.enqueue(session)
        queue.enqueue(nextSession)
        await queue.flush()
        let savedNext = try await store.load(id: nextSession.id)
        XCTAssertEqual(savedNext?.id, nextSession.id, "A failed save must not strand another pending session")
        session.title = "Recovered save"
        queue.enqueue(session)
        await queue.flush()
        let persisted = try await store.load(id: session.id)
        XCTAssertEqual(persisted?.title, session.title)
    }

    func testFileTranscriptRenamePreservesSourceAndSelection() throws {
        let suite = "FileRenameTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = FileTranscriptionHistoryStore(defaults: defaults)
        let result = TranscriptionResult(text: "Unchanged transcript", confidence: 0.9, duration: 12, processingTime: 1, fileName: "original.wav")
        store.addEntry(result)
        let original = try XCTUnwrap(store.selectedEntry)
        store.renameEntry(id: original.id, to: "  Weekly review  ")
        let renamed = try XCTUnwrap(store.selectedEntry)
        XCTAssertEqual(renamed.displayTitle, "Weekly review")
        XCTAssertEqual(renamed.fileName, "original.wav")
        XCTAssertEqual(renamed.text, original.text)
        XCTAssertEqual(renamed.speakerSegments, original.speakerSegments)
        XCTAssertEqual(renamed.toTranscriptionResult().fileName, original.fileName)
        XCTAssertEqual(renamed.timestamp, original.timestamp)
        XCTAssertEqual(renamed.searchRevision, 2)
        store.renameEntry(id: original.id, to: "  ")
        store.renameEntry(id: UUID(), to: "Missing")
        store.renameEntry(id: original.id, to: "Weekly review")
        XCTAssertEqual(store.selectedEntry, renamed)
        let reloaded = FileTranscriptionHistoryStore(defaults: defaults)
        XCTAssertEqual(reloaded.entries, [renamed])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(renamed)) as? [String: Any])
        legacy.removeValue(forKey: "customTitle")
        legacy.removeValue(forKey: "searchRevision")
        let decoded = try JSONDecoder().decode(FileTranscriptionEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.displayTitle, "original.wav")
    }

    func testSettingsSheetOnlySaysCloseWhenLeavingDiscardsNothing() {
        typealias Sheet = MeetingRecordingSettingsSheet
        XCTAssertEqual(Sheet.dismissTitle(isFirstSetup: false, section: .integrations, hasUnsavedChanges: false), "Close")
        XCTAssertEqual(
            Sheet.dismissTitle(isFirstSetup: false, section: .integrations, hasUnsavedChanges: true),
            "Cancel",
            "edits made on another tab would be thrown away"
        )
        XCTAssertEqual(Sheet.dismissTitle(isFirstSetup: false, section: .recording, hasUnsavedChanges: false), "Cancel")
        XCTAssertEqual(Sheet.dismissTitle(isFirstSetup: false, section: .automation, hasUnsavedChanges: true), "Cancel")
        XCTAssertEqual(Sheet.dismissTitle(isFirstSetup: true, section: .integrations, hasUnsavedChanges: false), "Not now")
    }

    func testNotesSetupDraftDoesNotPersistDetectionChanges() {
        let native = SettingsStore.shared.meetingAutoDetectEnabled
        let browser = SettingsStore.shared.meetingAutoDetectBrowserEnabled
        let original = MeetingTranscriptionSetupDraft()
        var draft = original
        draft.autoDetectEnabled = !native
        draft.browserDetectionEnabled = !browser
        draft.title = "Unsaved meeting"
        XCTAssertEqual(SettingsStore.shared.meetingAutoDetectEnabled, native)
        XCTAssertEqual(SettingsStore.shared.meetingAutoDetectBrowserEnabled, browser)
        draft = original
        XCTAssertEqual(draft.autoDetectEnabled, native)
        XCTAssertEqual(draft.browserDetectionEnabled, browser)
        XCTAssertEqual(draft.title, original.title)
    }

    func testNotesCanvasStatesRenderWithoutInvokingActions() throws {
        let preferences = MeetingUIPreferences()
        var session = self.makeCorrectionSession(state: .completed).session
        session.title = "Design review"
        session.transcriptSegments[0].text = "The meeting workspace should keep recording sources visible and make the transcript easy to read."
        let live = MeetingLiveTranscriptSnapshot.empty.inserting(MeetingLiveUtterance(
            id: UUID(), speaker: .you, text: "Let's keep the important controls within reach.", start: 0, end: 4
        ))
        let states: [(String, MeetingTranscriptionCanvasState)] = [
            ("setup", .setup(isStarting: false, recentSession: nil)),
            ("starting", .setup(isStarting: true, recentSession: nil)),
            ("recording", .recording(session: session, trackHealth: [:], liveTranscript: live)),
            ("stopping", .stopping(session: session, trackHealth: [:], liveTranscript: live)),
            ("processing", .processing(session: session, stage: .identifyingSpeakers)),
            ("result", .result(session)),
            ("recovery", .failed(session: session, message: "Transcription could not finish. Try again.")),
            ("failure", .failed(session: nil, message: "Choose an available microphone.")),
        ]
        var actionCount = 0
        let action = { actionCount += 1 }
        let output = URL(fileURLWithPath: "/tmp/fluid-notes-ui-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for scheme in [ColorScheme.dark, .light] {
            for width in [CGFloat(520), 1000] {
                for (name, state) in states {
                    let canvas = MeetingTranscriptionCanvas(
                        setupDraft: .constant(MeetingTranscriptionSetupDraft()),
                        state: state,
                        applications: [],
                        microphones: [],
                        readiness: .checking,
                        errorMessage: nil,
                        onStart: action,
                        onStop: action,
                        onRetrySession: { _ in action() },
                        onRevealAudio: { _ in action() },
                        onRecordAgain: { _ in action() },
                        onCopyTranscript: { _, _ in action() },
                        onExportTranscript: { _, _, _ in action() },
                        onReassignSegment: { _, _, _ in action() },
                        onNameUnknownSegment: { _, _, _ in action() },
                        onRenameSpeaker: { _, _, _ in action() },
                        onMergeSpeakers: { _, _, _ in action() },
                        onUndoCorrection: { _ in action() },
                        onRenameSession: { _, _ in action() },
                        onAssignSpeakers: { _, _ in action(); return nil },
                        canUndoCorrection: { _ in false },
                        isQuiescent: true,
                        onRepairSetup: action,
                        isRetrying: false,
                        onCloseSelection: action
                    )
                    .frame(width: width, height: 680)
                    .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
                    .environment(\.colorScheme, scheme)
                    // AppKit-backed ScrollViews are not captured by SwiftUI ImageRenderer.
                    let host = NSHostingView(rootView: canvas)
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: width, height: 680),
                        styleMask: [.borderless],
                        backing: .buffered,
                        defer: false
                    )
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "\(name) must render")
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: output.appendingPathComponent("\(name)-\(scheme)-\(Int(width)).png"))
                }
            }
        }
        XCTAssertEqual(actionCount, 0, "Rendering must not start capture, persist settings, export or modify a transcript")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Rendering must not change saved meeting or audio-device preferences")
    }

    func testMacRecoveryRestartDispatchesExistingActionOnlyForRetainedAudio() {
        var retained = self.makeSession(state: .interrupted, endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])])
        retained.audioStorageMode = .retainedFiles
        var restartedIDs: [MeetingSessionID] = []
        func canvas(_ session: MeetingSession, busy: Bool = false) -> MeetingFailureCanvas {
            MeetingFailureCanvas(session: session, message: "Synthetic failed checkpoint", isRetrying: busy,
                onRetrySession: { _ in XCTFail("Restart must not dispatch the resume callback") },
                onRestartSession: { restartedIDs.append($0.id) },
                onRevealAudio: { _ in XCTFail("Restart must not reveal or rewrite audio") },
                onRecordAgain: { _ in XCTFail("Restart must not start a new recording") }, onClose: nil)
        }
        let recovery = canvas(retained)
        XCTAssertTrue(recovery.canRestartProcessing)
        recovery.restartProcessing()
        XCTAssertEqual(restartedIDs, [retained.id])
        canvas(retained, busy: true).restartProcessing()
        XCTAssertEqual(restartedIDs, [retained.id], "An active operation disables restart dispatch")
        var strict = retained; strict.audioStorageMode = .memoryOnly
        XCTAssertFalse(canvas(strict).canRestartProcessing)
        canvas(strict).restartProcessing()
        var deleted = retained; deleted.retention.audioDeletedAt = Date()
        XCTAssertFalse(canvas(deleted).canRestartProcessing)
        canvas(deleted).restartProcessing()
        XCTAssertEqual(restartedIDs, [retained.id], "Missing or strict input never reaches the durable restart service")
    }

    func testRetainedRecoveryCanvasNativeVisuals() throws {
        guard let path = ProcessInfo.processInfo.environment["PICHI_RETAINED_RECOVERY_VISUAL_DIR"] else {
            throw XCTSkip("Opt-in native retained recovery visual check")
        }
        XCTAssertTrue(path.hasPrefix("/"), "The caller supplies an absolute ignored artifact directory")
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let previousLanguage = ProcessInfo.processInfo.environment["PICHI_INTERFACE_LANGUAGE"]
        defer {
            if let previousLanguage { setenv("PICHI_INTERFACE_LANGUAGE", previousLanguage, 1) }
            else { unsetenv("PICHI_INTERFACE_LANGUAGE") }
        }
        let preferences = MeetingUIPreferences()
        var session = self.makeSession(state: .interrupted, endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])])
        session.audioStorageMode = .retainedFiles
        session.title = "Retained meeting Ёё"
        session.failures = [.init(id: UUID(), occurredAt: Date(), domain: .processing,
            code: "syntheticCheckpointFailure", message: "Synthetic interrupted processing", recoverable: true)]
        try session.validateForPersistence()
        var actions = 0
        let cases: [(PichiInterfaceLanguage, ColorScheme)] = [(.english, .light), (.russian, .dark)]
        for (language, scheme) in cases {
            setenv("PICHI_INTERFACE_LANGUAGE", language.rawValue, 1)
            XCTAssertEqual(PichiLocalization.language, language)
            let view = MeetingFailureCanvas(session: session,
                message: "The saved processing checkpoint is damaged. Keep the recording and restart processing.",
                isRetrying: false, onRetrySession: { _ in actions += 1 }, onRestartSession: { _ in actions += 1 },
                onRevealAudio: { _ in actions += 1 }, onRecordAgain: { _ in actions += 1 }, onClose: { actions += 1 })
                .padding(32)
                .frame(width: 760, height: 640, alignment: .topLeading)
                .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
                .environment(\.colorScheme, scheme)
                .environment(\.locale, language.locale)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.close() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 760)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 640)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 10_000, "The actual native canvas must produce a populated image")
            try png.write(to: output.appendingPathComponent("retained-recovery-\(language.rawValue)-\(scheme).png"))
        }
        XCTAssertEqual(actions, 0, "Rendering cannot retry, reset progress, reveal audio or begin recording")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Visual verification preserves meeting and audio preferences")
    }

    func testFluidMeetSetupReadinessStatesRenderWithoutSideEffects() throws {
        let preferences = MeetingUIPreferences()
        let actions = MeetingUIActionRecorder()
        let fixture = self.makeMeetingUISetupFixture()

        var waitingDraft = fixture.draft
        waitingDraft.selectedApplicationID = nil

        var microphoneDenied = fixture.readiness
        microphoneDenied.microphoneReady = false
        microphoneDenied.microphoneStatus = "Access denied"
        microphoneDenied.showMicrophoneSettingsAction = true
        microphoneDenied.blockingMessage = "Allow microphone access, then refresh sources."

        var meetingAudioDenied = fixture.readiness
        meetingAudioDenied.meetingAudioReady = false
        meetingAudioDenied.meetingAudioStatus = "Access required"
        meetingAudioDenied.showScreenRecordingSettingsAction = true
        meetingAudioDenied.blockingMessage = "Allow Screen & System Audio access, then refresh sources."

        var modelMissing = fixture.readiness
        modelMissing.modelReady = false
        modelMissing.modelStatus = "Load speaker model in Settings"
        modelMissing.blockingMessage = "Load the supplied speaker separation model in FluidMeet settings before recording."

        var inRoomDraft = fixture.draft
        inRoomDraft.mode = .inRoom
        inRoomDraft.selectedApplicationID = nil
        inRoomDraft.title = "In-room planning session"

        let scenarios: [(String, MeetingTranscriptionSetupDraft, MeetingSetupReadiness)] = [
            ("setup-ready", fixture.draft, fixture.readiness),
            ("setup-waiting", waitingDraft, fixture.readiness),
            ("setup-microphone-denied", fixture.draft, microphoneDenied),
            ("setup-meeting-audio-denied", fixture.draft, meetingAudioDenied),
            ("setup-model-missing", fixture.draft, modelMissing),
            ("setup-in-room", inRoomDraft, fixture.readiness),
        ]
        for (name, draft, readiness) in scenarios {
            for scheme in [ColorScheme.dark, .light] {
                for width in [CGFloat(520), 1000] {
                    try self.renderMeetingUI(
                        self.meetingUICanvas(draft: draft, readiness: readiness, fixture: fixture, actions: actions),
                        name: name,
                        width: width,
                        scheme: scheme
                    )
                }
            }
        }
        XCTAssertEqual(actions.count, 0, "Readiness rendering must not invoke actions or write the setup draft")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Readiness rendering must not persist settings or change audio routing")
    }

    func testMeetSummaryComingSoonRendersWithoutChangingPreferences() throws {
        let preferences = MeetingUIPreferences()
        for scheme in [ColorScheme.dark, .light] {
            for width in [CGFloat(520), 1000] {
                try self.renderMeetingUI(MeetingSummaryComingSoon(), name: "summary-coming-soon", width: width, scheme: scheme)
            }
        }
        XCTAssertEqual(MeetingUIPreferences(), preferences, "The planned summary feature must not change settings")
    }

    func testFluidMeetDocumentTabBaselineStaysHorizontalInBothStackAxes() throws {
        let preferences = MeetingUIPreferences()
        let actions = MeetingUIActionRecorder()
        let tabWidth: CGFloat = 420
        for scheme in [ColorScheme.dark, .light] {
            let base = AppTheme.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme)
            // Distinct probe colors isolate geometry from text rasterization and native materials.
            let probeTheme = AppTheme(
                palette: AppTheme.Palette(
                    windowBackground: base.palette.windowBackground,
                    contentBackground: base.palette.contentBackground,
                    sidebarBackground: base.palette.sidebarBackground,
                    cardBackground: base.palette.cardBackground,
                    elevatedCardBackground: base.palette.elevatedCardBackground,
                    toolbarBackground: base.palette.toolbarBackground,
                    cardBorder: base.palette.cardBorder,
                    separator: Color(red: 1, green: 0, blue: 1),
                    primaryText: Color(red: 0, green: 1, blue: 1),
                    secondaryText: base.palette.secondaryText,
                    tertiaryText: base.palette.tertiaryText,
                    accent: base.palette.accent,
                    warning: base.palette.warning,
                    success: base.palette.success
                ),
                typography: base.typography,
                metrics: base.metrics,
                materials: base.materials
            )
            for section in [MeetingDocumentSection.transcript, .summary] {
                for horizontal in [true, false] {
                    let tabs = MeetingDocumentTabs(selection: Binding(get: { section }, set: { _ in actions.record() }))
                        .frame(width: tabWidth)
                    let ancestor: AnyView
                    if horizontal {
                        ancestor = AnyView(HStack(spacing: 0) {
                            tabs
                            Color.clear.frame(width: 40, height: 64)
                        })
                    } else {
                        ancestor = AnyView(VStack(spacing: 0) {
                            tabs
                            Color.clear.frame(height: 24)
                        })
                    }
                    let context = "\(horizontal ? "hstack" : "vstack")-\(section)-\(scheme)"
                    let bitmap = try self.renderMeetingUI(
                        ancestor.appTheme(probeTheme),
                        name: "tabs-baseline-\(context)",
                        width: 500,
                        height: 140,
                        scheme: scheme
                    )
                    let scale = CGFloat(bitmap.pixelsWide) / 500
                    // Color-managed capture can shift RGB values; classify hue, not exact pixels.
                    let baseline = try XCTUnwrap(self.meetingUIPixelBounds(in: bitmap) { color, _ in
                        color.alphaComponent > 0.5 && min(color.redComponent, color.blueComponent) - color.greenComponent > 0.3
                    }, "\(context): the document baseline must render")
                    XCTAssertEqual(baseline.width / scale, tabWidth, accuracy: 2, "\(context): baseline must span both tabs, not turn vertical")
                    XCTAssertLessThanOrEqual(baseline.height / scale, 2, "\(context): baseline must stay one point tall, allowing pixel antialiasing")
                }
            }
        }
        XCTAssertEqual(actions.count, 0, "Layout must not select a document tab")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Tab layout must not change meeting or audio-device preferences")
    }

    func testFluidMeetHoverHighlightRespectsDisabledAndReducedMotionStates() throws {
        let preferences = MeetingUIPreferences()
        for scheme in [ColorScheme.dark, .light] {
            for enabled in [true, false] {
                for hovered in [true, false] {
                    for reducedMotion in [true, false] {
                        let highlight = MeetingHoverHighlight(isHovered: hovered, cornerRadius: 8, reduceMotion: reducedMotion)
                            .frame(width: 120, height: 36)
                            .disabled(!enabled)
                        let bitmap = try self.renderMeetingUI(
                            highlight,
                            name: "hover-\(enabled)-\(hovered)-\(reducedMotion)",
                            width: 160,
                            height: 80,
                            scheme: scheme
                        )
                        let bounds = self.meetingUIPixelBounds(in: bitmap) { color, _ in color.alphaComponent > 0.01 }
                        if enabled, hovered {
                            let visible = try XCTUnwrap(bounds, "Enabled hover must provide feedback even with Reduce Motion")
                            let scale = CGFloat(bitmap.pixelsWide) / 160
                            XCTAssertEqual(visible.width / scale, 120, accuracy: 1, "Hover must not expand the control")
                            XCTAssertEqual(visible.height / scale, 36, accuracy: 1, "Hover must not change control height")
                        } else {
                            XCTAssertNil(bounds, "Idle and disabled controls must not show a hover highlight")
                        }
                    }
                }
            }
        }
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Hover rendering must not change settings or audio routing")
    }

    func testFluidMeetSettingsSectionsRenderWithoutSideEffects() throws {
        let preferences = MeetingUIPreferences()
        let actions = MeetingUIActionRecorder()
        let fixture = self.makeMeetingUISetupFixture()
        let sections: [(String, MeetingSettingsSection)] = [
            ("recording", .recording),
            ("automation", .automation),
            ("integrations", .integrations),
        ]
        for (name, section) in sections {
            let sheet = MeetingRecordingSettingsSheet(
                draft: Binding(get: { fixture.draft }, set: { _ in actions.record() }),
                retentionPolicy: Binding(get: { .days7 }, set: { _ in actions.record() }),
                applications: fixture.applications,
                microphones: fixture.microphones,
                readiness: fixture.readiness,
                isFirstSetup: false,
                onRefreshSources: { actions.record() },
                onOpenMicrophoneSettings: { actions.record() },
                onOpenScreenRecordingSettings: { actions.record() },
                onOpenVoiceEngine: { actions.record() },
                onCancel: { actions.record() },
                onSave: { actions.record() },
                initialSection: section
            )
            for scheme in [ColorScheme.dark, .light] {
                try self.renderMeetingUI(sheet, name: "settings-\(name)", width: 820, height: 700, scheme: scheme)
            }
        }
        XCTAssertEqual(actions.count, 0, "Opening settings sections must not save, request permissions, or write draft bindings")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Opening settings must not change retention, detection, or audio routing")
    }

    func testFluidMeetCompletedActionErrorRendersWithoutSideEffects() throws {
        let preferences = MeetingUIPreferences()
        let actions = MeetingUIActionRecorder()
        let fixture = self.makeMeetingUISetupFixture()
        let session = self.makeCorrectionSession(state: .completed).session
        for scheme in [ColorScheme.dark, .light] {
            for width in [CGFloat(520), 1000] {
                for message in [String?.none, "Export failed: the destination is read-only."] {
                    let bitmap = try self.renderMeetingUI(
                        self.meetingUICanvas(
                            draft: fixture.draft,
                            readiness: fixture.readiness,
                            fixture: fixture,
                            actions: actions,
                            state: .result(session),
                            errorMessage: message
                        ),
                        name: message == nil ? "result-no-action-error" : "result-action-error",
                        width: width,
                        scheme: scheme
                    )
                    let top = Int(100 * CGFloat(bitmap.pixelsWide) / width)
                    let warning = self.meetingUIPixelBounds(in: bitmap) { color, y in
                        y < top && color.redComponent - color.greenComponent > 0.15
                            && color.greenComponent - color.blueComponent > 0.15
                    }
                    XCTAssertEqual(warning != nil, message != nil, "Completed actions must visibly report errors above the transcript")
                }
            }
        }
        XCTAssertEqual(actions.count, 0, "Showing an action failure must not retry, export, or change the transcript")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Showing an action failure must not change recording settings")
    }

    func testFluidMeetLongTranscriptRendersWithoutSideEffects() throws {
        let preferences = MeetingUIPreferences()
        let actions = MeetingUIActionRecorder()
        let fixture = self.makeMeetingUISetupFixture()
        let session = self.makeLongMeetingUIResult()
        let echo = try XCTUnwrap(session.transcriptSegments.first(where: \.isEcho))
        let visibleText = MeetingTranscriptExporter.text(for: session)
        XCTAssertFalse(visibleText.contains(echo.text), "Probable echo is hidden from the default transcript output")
        XCTAssertTrue(MeetingTranscriptExporter.text(for: session, includeEchoes: true).contains(echo.text))
        XCTAssertTrue(visibleText.contains("Amelia Richardson"))
        XCTAssertTrue(visibleText.contains("Rafael Moreno"))
        XCTAssertTrue(visibleText.contains("Unknown speaker"))

        var echoOnly = session
        echoOnly.title = "Meeting with only probable echo remaining"
        echoOnly.transcriptSegments = [echo]
        XCTAssertTrue(MeetingTranscriptExporter.text(for: echoOnly).isEmpty)

        for (name, result) in [("result-long-conversation", session), ("result-echo-only", echoOnly)] {
            for scheme in [ColorScheme.dark, .light] {
                for width in [CGFloat(520), 1000] {
                    try self.renderMeetingUI(
                        self.meetingUICanvas(
                            draft: fixture.draft,
                            readiness: fixture.readiness,
                            fixture: fixture,
                            actions: actions,
                            state: .result(result)
                        ),
                        name: name,
                        width: width,
                        scheme: scheme
                    )
                }
            }
        }
        XCTAssertEqual(actions.count, 0, "Reading a long transcript must not start audio, export, or modify speakers and transcript text")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Transcript rendering must not change saved meeting settings or audio routing")
    }

    func testFluidMeetShortRecordingRendersWithoutSideEffects() throws {
        let preferences = MeetingUIPreferences()
        let actions = MeetingUIActionRecorder()
        let fixture = self.makeMeetingUISetupFixture()
        var session = self.makeLongMeetingUIResult()
        session.state = .recording
        session.startedAt = Date(timeIntervalSinceNow: -94)
        session.endedAt = nil
        session.transcriptSegments = []
        let state = MeetingTranscriptionCanvasState.recording(
            session: session,
            trackHealth: [.microphone: .waiting, .applicationAudio: .waiting],
            liveTranscript: .empty
        )
        for scheme in [ColorScheme.dark, .light] {
            try self.renderMeetingUI(
                self.meetingUICanvas(
                    draft: fixture.draft,
                    readiness: fixture.readiness,
                    fixture: fixture,
                    actions: actions,
                    state: state
                ),
                name: "recording-short-window",
                width: 520,
                height: 500,
                scheme: scheme
            )
        }
        XCTAssertEqual(actions.count, 0, "Rendering recording controls must not start or stop real audio capture")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Recording presentation must not change saved settings or audio routing")
    }

    func testHistoryKeyboardTraversalWalksTheRenderedOrder() {
        let ids = [UUID(), UUID(), UUID()]
        func move(from current: UUID?, _ direction: MoveCommandDirection) -> UUID? {
            MeetingHistoryTraversal.sessionID(movingFrom: current, direction: direction, ordered: ids)
        }
        XCTAssertEqual(move(from: nil, .down), ids[0], "no selection starts at the top")
        XCTAssertEqual(move(from: ids[0], .down), ids[1])
        XCTAssertEqual(move(from: ids[1], .up), ids[0])
        XCTAssertNil(move(from: ids[0], .up), "stops at the first row")
        XCTAssertNil(move(from: ids[2], .down), "stops at the last row")
    }

    // MARK: - Fixtures

    @MainActor
    private final class MeetingUIActionRecorder {
        var count = 0
        func record() { self.count += 1 }
    }

    private struct MeetingUIPreferences: Equatable {
        let recording: MeetingRecordingDefaults
        let retention: MeetingAudioRetentionPolicy
        let nativeDetection: Bool
        let browserDetection: Bool
        let inputDeviceUID: String?
        let outputDeviceUID: String?

        @MainActor
        init() {
            let settings = SettingsStore.shared
            self.recording = settings.meetingRecordingDefaults
            self.retention = settings.meetingAudioRetentionPolicy
            self.nativeDetection = settings.meetingAutoDetectEnabled
            self.browserDetection = settings.meetingAutoDetectBrowserEnabled
            self.inputDeviceUID = settings.preferredInputDeviceUID
            self.outputDeviceUID = settings.preferredOutputDeviceUID
        }
    }

    private struct MeetingUISetupFixture {
        let draft: MeetingTranscriptionSetupDraft
        let applications: [MeetingApplicationOption]
        let microphones: [MeetingMicrophoneOption]
        let readiness: MeetingSetupReadiness
    }

    private func makeMeetingUISetupFixture() -> MeetingUISetupFixture {
        let application = MeetingApplicationOption(identity: MeetingApplicationIdentity(
            bundleIdentifier: "us.zoom.xos", processID: 42, displayName: "Zoom Workplace"
        ))
        let microphone = MeetingMicrophoneOption(identity: MeetingMicrophoneIdentity(
            captureDeviceID: "meeting-ui-fixture-microphone", displayName: "MacBook Pro Microphone"
        ))
        var draft = MeetingTranscriptionSetupDraft()
        draft.mode = .onlineCall
        draft.title = "Product design review and launch planning"
        draft.titleWasEdited = true
        draft.selectedApplicationID = application.id
        draft.usesAutomaticApplication = true
        draft.selectedMicrophoneID = microphone.id
        draft.autoDetectEnabled = true
        draft.browserDetectionEnabled = true
        return MeetingUISetupFixture(
            draft: draft,
            applications: [application],
            microphones: [microphone],
            readiness: MeetingSetupReadiness(
                isCheckingSources: false,
                meetingAudioStatus: "Ready",
                meetingAudioReady: true,
                microphoneStatus: "Ready",
                microphoneReady: true,
                modelStatus: "Speaker model installed",
                modelReady: true,
                storageStatus: "120 GB available",
                storageReady: true,
                activityStatus: "Ready",
                activityReady: true,
                showMicrophoneSettingsAction: false,
                showScreenRecordingSettingsAction: false,
                blockingMessage: nil
            )
        )
    }

    private func meetingUICanvas(
        draft: MeetingTranscriptionSetupDraft,
        readiness: MeetingSetupReadiness,
        fixture: MeetingUISetupFixture,
        actions: MeetingUIActionRecorder,
        state: MeetingTranscriptionCanvasState = .setup(isStarting: false, recentSession: nil),
        errorMessage: String? = nil
    ) -> some View {
        MeetingTranscriptionCanvas(
            setupDraft: Binding(get: { draft }, set: { _ in actions.record() }),
            state: state,
            applications: fixture.applications,
            microphones: fixture.microphones,
            readiness: readiness,
            errorMessage: errorMessage,
            onStart: { actions.record() },
            onStop: { actions.record() },
            onRetrySession: { _ in actions.record() },
            onRevealAudio: { _ in actions.record() },
            onRecordAgain: { _ in actions.record() },
            onCopyTranscript: { _, _ in actions.record() },
            onExportTranscript: { _, _, _ in actions.record() },
            onReassignSegment: { _, _, _ in actions.record() },
            onNameUnknownSegment: { _, _, _ in actions.record() },
            onRenameSpeaker: { _, _, _ in actions.record() },
            onMergeSpeakers: { _, _, _ in actions.record() },
            onUndoCorrection: { _ in actions.record() },
            onRenameSession: { _, _ in actions.record() },
            onAssignSpeakers: { _, _ in actions.record(); return nil },
            canUndoCorrection: { _ in false },
            isQuiescent: true,
            onRepairSetup: { actions.record() },
            onEditSetup: { actions.record() },
            isRetrying: false,
            onCloseSelection: { actions.record() }
        )
    }

    private func makeLongMeetingUIResult() -> MeetingSession {
        var microphone = self.makeMicrophoneTrack(chunks: [])
        microphone.sourceDisplayName = "MacBook Pro Microphone"
        var application = self.makeMicrophoneTrack(chunks: [])
        application.kind = .applicationAudio
        application.sourceIdentifier = "us.zoom.xos"
        application.sourceDisplayName = "Zoom Workplace"
        let startedAt = Date(timeIntervalSince1970: 1_789_996_800)
        var session = self.makeSession(
            state: .completed,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(32 * 60 + 18),
            audioTracks: [microphone, application]
        )
        session.title = "Product design review — simplifying the first meeting experience before our autumn launch"
        session.mode = .onlineCall
        session.capturedApplication = MeetingApplicationIdentity(bundleIdentifier: "us.zoom.xos", displayName: "Zoom Workplace")
        session.selectedMicrophone.displayName = microphone.sourceDisplayName
        session.transcriptTimeDomain = .meetingRelative
        session.transcriptIsComplete = true
        let local = self.makeSpeaker(name: "You", isLocalUser: true)
        let amelia = self.makeSpeaker(name: "Amelia Richardson", trackKind: .applicationAudio)
        let rafael = self.makeSpeaker(name: "Rafael Moreno", trackKind: .applicationAudio)
        session.speakers = [local, amelia, rafael]

        let turns: [(MeetingSessionSpeaker?, String)] = [
            (
                local,
                "Let's start with what someone needs in their first thirty seconds. They should know which meeting we are capturing, see that their microphone is ready, and find the recording control without having to read a settings page."
            ),
            (
                local,
                "Once a conversation has finished, the transcript should read like a document. Keep the title and date nearby, but let the words take up most of the space. We can move less common actions into the menu."
            ),
            (
                amelia,
                // Keep the exact fixture text or diagnostic output together for comparison.
                // swiftlint:disable:next line_length
                "I agree. In the interviews, people went back to a meeting because they remembered a decision, not because they wanted to inspect a recording. The first screen should help them recognize the conversation and pick up where they left off."
            ),
            (
                rafael,
                "The longer examples matter here. A one-line transcript looks fine in almost any layout. We need to see what happens with several speakers, names that wrap, and a paragraph that takes more than two lines on a small laptop."
            ),
            (
                amelia,
                "For speaker corrections, I would keep the name close to the passage. If I notice that the wrong person has been assigned, I should be able to fix it there and continue reading without losing my place."
            ),
            (
                nil,
                "Could we also make it clear when the recording contains an overlap that the model cannot confidently assign? An honest unknown label is more useful than attributing the statement to the wrong person."
            ),
            (
                local,
                // Keep the exact fixture text or diagnostic output together for comparison.
                // swiftlint:disable:next line_length
                "Yes. We should preserve uncertain attribution and avoid making the interface look more confident than the transcript is. The correction remains a deliberate action, and the original recording stays available until the retention policy removes it."
            ),
            (
                rafael,
                "For the launch review, I will test the smallest supported window and both appearances. I will also check a meeting that has no readable transcript, so the recovery action is still obvious when someone needs it."
            ),
            (
                amelia,
                "I'll collect three longer conversations for the design review. We should compare the same content each time, including one where the speaker names are much longer than the labels in our initial mockup."
            ),
            (
                local,
                "The next step is to review those examples together on Thursday. We can then decide whether the meeting list, transcript width, and primary actions feel consistent with the rest of the app."
            ),
        ]
        session.transcriptSegments = turns.enumerated().map { index, turn in
            let trackID = turn.0?.isLocalUser == true ? microphone.id : application.id
            var segment = self.makeTranscriptSegment(sourceTrackID: trackID, speakerID: turn.0?.id)
            segment.start = MeetingMediaTime(value: Int64(index * 32_000), timescale: 1000)
            segment.end = MeetingMediaTime(value: Int64(index * 32_000 + 27_000), timescale: 1000)
            segment.text = turn.1
            segment.attributionState = turn.0 == nil ? .unassigned : .assigned
            return segment
        }
        var echo = self.makeTranscriptSegment(sourceTrackID: microphone.id, speakerID: local.id)
        echo.start = MeetingMediaTime(value: 66_000, timescale: 1000)
        echo.end = MeetingMediaTime(value: 70_000, timescale: 1000)
        echo.text = "This repeated phrase was captured through the speakers and is marked as probable echo."
        echo.isLikelyEcho = true
        echo.attributionState = .assigned
        session.transcriptSegments.append(echo)
        return session
    }

    private func meetingUIPixelBounds(
        in bitmap: NSBitmapImageRep,
        matching predicate: (NSColor, Int) -> Bool
    ) -> CGRect? {
        var bounds: CGRect?
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), predicate(color, y) else { continue }
                let pixel = CGRect(x: x, y: y, width: 1, height: 1)
                bounds = bounds.map { $0.union(pixel) } ?? pixel
            }
        }
        return bounds
    }

    @discardableResult
    private func renderMeetingUI<Content: View>(
        _ content: Content,
        name: String,
        width: CGFloat,
        height: CGFloat = 680,
        scheme: ColorScheme
    ) throws -> NSBitmapImageRep {
        let canvas = content
            .frame(width: width, height: height)
            .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
            .environment(\.colorScheme, scheme)
        let host = NSHostingView(rootView: canvas)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        // AppKit-backed scroll views and native menus need hosting-view capture.
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds), "\(name) must render")
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: "/tmp/meet-assist-ui-review", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent("\(name)-\(scheme)-\(Int(width)).png"))
        return bitmap
    }

    private func makeTempDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeConfiguration(title: String = "Test") -> MeetingCaptureConfiguration {
        MeetingCaptureConfiguration(
            mode: .inRoom,
            title: title,
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
        )
    }

    private func makeTimebase() -> MeetingTimebaseMetadata {
        MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
    }

    private func makeFinalizedChunk(
        sequence: Int = 0,
        path: String = "tracks/microphone/chunk_0.caf"
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
            discontinuities: [],
            sha256: "abc123",
            byteCount: 128,
            finalizationState: .finalized
        )
    }

    private func makeMicrophoneTrack(chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic-1",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: self.makeTimebase(),
            health: .waiting,
            chunks: chunks
        )
    }

    private func makeSession(
        state: MeetingSessionState,
        startedAt: Date = Date(timeIntervalSinceNow: -3600),
        endedAt: Date? = nil,
        audioTracks: [MeetingAudioTrack] = [],
        failures: [MeetingSessionFailure] = [],
        processingAttempts: [MeetingProcessingAttempt] = [],
        recoveryResolvedAt: Date? = nil
    ) -> MeetingSession {
        var session = MeetingSession(configuration: self.makeConfiguration(), startedAt: startedAt, timebase: self.makeTimebase())
        session.state = state
        session.endedAt = endedAt
        session.audioTracks = audioTracks
        session.failures = failures
        session.processingAttempts = processingAttempts
        session.recoveryResolvedAt = recoveryResolvedAt
        session.updatedAt = startedAt
        return session
    }

    // MARK: - Transcript correction fixtures

    private func makeSpeaker(
        id: SessionSpeakerID = UUID(),
        name: String = "Speaker",
        trackKind: MeetingAudioTrackKind = .microphone,
        isLocalUser: Bool = false
    ) -> MeetingSessionSpeaker {
        MeetingSessionSpeaker(
            id: id,
            displayName: name,
            diarizationClusterID: nil,
            trackKind: trackKind,
            isLocalUser: isLocalUser,
            identityCandidates: []
        )
    }

    private func makeTranscriptSegment(
        sourceTrackID: MeetingAudioTrackID,
        speakerID: SessionSpeakerID?
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: UUID(),
            start: MeetingMediaTime(value: 0, timescale: 1000),
            end: MeetingMediaTime(value: 1000, timescale: 1000),
            sourceTrackID: sourceTrackID,
            speakerID: speakerID,
            text: "Hello",
            revision: 1,
            status: .final,
            overlap: .none,
            completeness: .complete
        )
    }

    /// A session with two same-track, non-local speakers and one segment on the first speaker —
    /// enough to exercise rename/reassign/merge without tripping their guards.
    private func makeCorrectionSession(
        state: MeetingSessionState
    ) -> (session: MeetingSession, speakerA: SessionSpeakerID, speakerB: SessionSpeakerID, segmentID: MeetingTranscriptSegmentID) {
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        var session = self.makeSession(state: state, endedAt: Date(), audioTracks: [track])
        let speakerA = self.makeSpeaker(name: "Speaker A")
        let speakerB = self.makeSpeaker(name: "Speaker B")
        let segment = self.makeTranscriptSegment(sourceTrackID: track.id, speakerID: speakerA.id)
        session.speakers = [speakerA, speakerB]
        session.transcriptSegments = [segment]
        return (session, speakerA.id, speakerB.id, segment.id)
    }

    // MARK: - Test 1: loadRecoverable classification

    func testLoadRecoverableClassification() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])

        let recording = self.makeSession(state: .recording, audioTracks: [track])
        let stopping = self.makeSession(state: .stopping, audioTracks: [track])
        let processing = self.makeSession(state: .processing, endedAt: Date(), audioTracks: [track])
        let interrupted = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        let completed = self.makeSession(state: .completed, endedAt: Date(), audioTracks: [track])
        let recoverableFailed = self.makeSession(
            state: .failed,
            endedAt: Date(),
            audioTracks: [track],
            failures: [MeetingSessionFailure(id: UUID(), occurredAt: Date(), domain: .capture, code: "x", message: "m", recoverable: true)]
        )
        let unrecoverableFailed = self.makeSession(
            state: .failed,
            endedAt: Date(),
            audioTracks: [track],
            failures: [MeetingSessionFailure(id: UUID(), occurredAt: Date(), domain: .persistence, code: "x", message: "m", recoverable: false)]
        )
        let dismissedInterrupted = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [track],
            recoveryResolvedAt: Date()
        )

        for session in [recording, stopping, processing, interrupted, completed, recoverableFailed, unrecoverableFailed, dismissedInterrupted] {
            do { try await store.create(session) } catch {
                XCTFail("create failed for state \(session.state): \(error)")
                throw error
            }
        }

        let recoverable = try await store.loadRecoverable()
        let ids = Set(recoverable.map(\.id))

        XCTAssertTrue(ids.contains(recording.id))
        XCTAssertTrue(ids.contains(stopping.id))
        XCTAssertTrue(ids.contains(processing.id))
        XCTAssertTrue(ids.contains(interrupted.id))
        XCTAssertTrue(ids.contains(recoverableFailed.id))
        XCTAssertFalse(ids.contains(completed.id))
        XCTAssertFalse(ids.contains(unrecoverableFailed.id))
        XCTAssertFalse(ids.contains(dismissedInterrupted.id))
    }

    // MARK: - Test 2: multi-session restore

    func testMultiSessionRestoreSelectsNewestViableAndDefersOthers() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let now = Date()
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])

        let older = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-600),
            endedAt: now.addingTimeInterval(-590),
            audioTracks: [track]
        )
        let newer = self.makeSession(
            state: .recording,
            startedAt: now.addingTimeInterval(-60),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let emptyPreparing = self.makeSession(state: .preparing, startedAt: now.addingTimeInterval(-30))

        for session in [older, newer, emptyPreparing] {
            try await store.create(session)
        }

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()

        XCTAssertEqual(coordinator.activeSession?.id, newer.id)
        XCTAssertEqual(coordinator.state, .interrupted(newer.id))

        let persistedOlder = try await store.load(id: older.id)
        XCTAssertEqual(persistedOlder?.state, .interrupted)
        XCTAssertTrue(persistedOlder?.processingAttempts.isEmpty == true)
        XCTAssertEqual(persistedOlder?.events.count, older.events.count)

        let persistedPreparing = try await store.load(id: emptyPreparing.id)
        XCTAssertEqual(persistedPreparing?.state, .failed)
        XCTAssertEqual(persistedPreparing?.failures.last?.recoverable, false)
        XCTAssertEqual(persistedPreparing?.audioTracks.isEmpty, true)

        // Idempotent within the same launch: a second ensureRestored is a no-op.
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)

        // Dismiss the active recovery and simulate the next launch with a fresh coordinator.
        try coordinator.resetForNewMeeting()
        for _ in 0..<100 {
            if let persisted = try await store.load(id: newer.id), persisted.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let coordinator2 = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator2.ensureRestored()
        XCTAssertEqual(coordinator2.activeSession?.id, older.id)
        XCTAssertEqual(coordinator2.state, .interrupted(older.id))
    }

    // MARK: - Test 3: dismissal persists recoveryResolvedAt

    func testDismissalPersistsRecoveryResolvedAt() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        try coordinator.resetForNewMeeting()

        var persisted: MeetingSession?
        for _ in 0..<40 {
            persisted = try await store.load(id: session.id)
            if persisted?.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(persisted?.recoveryResolvedAt)

        let coordinator2 = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator2.ensureRestored()
        XCTAssertNil(coordinator2.activeSession)
        XCTAssertEqual(coordinator2.state, .idle)
    }

    // MARK: - Test 4: retry hygiene

    func testRetryProcessingClosesStaleAttemptAndRejectsWhileProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let staleAttempt = MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date().addingTimeInterval(-120),
            completedAt: nil,
            stage: .transcribing,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [track],
            processingAttempts: [staleAttempt]
        )
        try await store.create(session)

        let processing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: processing,
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.processingAttempts.count, 1)

        let retryTask = Task { try await coordinator.retryProcessing() }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            XCTFail("retryProcessing did not reach .processing state")
            return
        }

        let midFlightAttempts = coordinator.activeSession?.processingAttempts ?? []
        XCTAssertEqual(midFlightAttempts.count, 2)
        XCTAssertEqual(midFlightAttempts.filter { $0.completedAt == nil }.count, 1)
        XCTAssertNotNil(midFlightAttempts.first(where: { $0.id == staleAttempt.id })?.completedAt)

        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw while already processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                XCTFail("Expected .activityInProgress, got \(error)")
                return
            }
        }

        processing.openGate()
        let finalSession = try await retryTask.value
        XCTAssertEqual(finalSession.state, .completed)
        XCTAssertEqual(finalSession.processingAttempts.count, 2)
        XCTAssertTrue(finalSession.processingAttempts.allSatisfy { $0.completedAt != nil })
    }

    // MARK: - Test 5: launch race

    func testStartRecordingAwaitsRestoreBeforeCapturing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let recorder = EventRecorder()
        let gatedStore = GatedRecoverableStore(inner: realStore, recorder: recorder)

        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        capture.onStart = { await recorder.record("capture.start") }

        let coordinator = MeetingSessionCoordinator(
            store: gatedStore,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )

        let startTask = Task { try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Race")) }

        for _ in 0..<40 {
            if await recorder.events.contains("restore.loadRecoverable.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsBeforeGate = await recorder.events
        XCTAssertTrue(eventsBeforeGate.contains("restore.loadRecoverable.start"))
        XCTAssertFalse(eventsBeforeGate.contains("capture.start"))

        await gatedStore.openGate()
        _ = try await startTask.value

        let finalEvents = await recorder.events
        guard let restoreIndex = finalEvents.firstIndex(of: "restore.loadRecoverable.start"),
              let captureIndex = finalEvents.firstIndex(of: "capture.start")
        else {
            XCTFail("Expected both restore and capture events to be recorded")
            return
        }
        XCTAssertLessThan(restoreIndex, captureIndex)
    }

    func testMissingModelBlocksCaptureAndClearsStartReservation() async throws {
        let settingsName = "MissingMeetingModel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: settingsName))
        defer { defaults.removePersistentDomain(forName: settingsName) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = StubCaptureController()
        let recorder = EventRecorder()
        capture.onStart = { await recorder.record("capture.start") }
        let coordinator = MeetingSessionCoordinator(
            store: MeetingSessionStore(rootDirectory: dir),
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter(),
            settings: settings,
            validateRecordingModels: { throw MeetingModelInstaller.InstallError.wrongPackage }
        )
        for _ in 0..<2 {
            do {
                _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Missing model"))
                XCTFail("Recording must not start without the required model")
            } catch is MeetingModelInstaller.InstallError {
                // Both attempts must reach validation, not a stale recording-already-active gate.
            }
            XCTAssertFalse(coordinator.hasPendingStart)
            XCTAssertFalse(coordinator.isRecording)
        }
        let events = await recorder.events
        XCTAssertFalse(events.contains("capture.start"))
    }

    // MARK: - Test 6: salvage current behavior pin

    func testMissingChunkFileIsRetainedAsFailedNotDropped() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let chunk = self.makeFinalizedChunk(path: "tracks/microphone/missing.caf")
        let track = self.makeMicrophoneTrack(chunks: [chunk])
        let session = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        try await store.create(session)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let trackManifestDirectory = sessionDirectory
            .appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent("microphone", isDirectory: true)
        try FileManager.default.createDirectory(at: trackManifestDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(track).write(to: trackManifestDirectory.appendingPathComponent("track.json", isDirectory: false))
        // Deliberately do not write the chunk's audio file, to simulate a missing chunk on disk.

        let loaded = try await store.load(id: session.id)
        let loadedChunk = loaded?.audioTracks.first(where: { $0.kind == .microphone })?.chunks.first

        XCTAssertNotNil(loadedChunk, "A manifest chunk whose file is missing must be retained, not dropped")
        XCTAssertEqual(loadedChunk?.id, chunk.id)
        XCTAssertEqual(loadedChunk?.finalizationState, .failed)
        XCTAssertEqual(loadedChunk?.byteCount, 0)
        XCTAssertEqual(loadedChunk?.sha256, "")
    }

    func testInvalidCrashWindowTrackManifestDoesNotMakeValidSessionSnapshotUnloadable() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let validTrack = self.makeMicrophoneTrack(chunks: [])
        let session = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [validTrack])
        try await store.create(session)

        var invalidTrack = validTrack
        invalidTrack.chunks = [MeetingAudioChunk(
            id: UUID(),
            sequence: 0,
            relativeFilePath: "tracks/microphone/invalid.m4a",
            presentationStart: MeetingMediaTime(value: 2000, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
            discontinuities: [],
            sha256: "invalid",
            byteCount: 1,
            finalizationState: .finalized
        )]
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let manifestDirectory = sessionDirectory.appendingPathComponent("tracks/microphone", isDirectory: true)
        try FileManager.default.createDirectory(at: manifestDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(invalidTrack).write(
            to: manifestDirectory.appendingPathComponent("track.json", isDirectory: false)
        )

        let loadedValue = try await store.load(id: session.id)
        let loaded = try XCTUnwrap(loadedValue)
        XCTAssertEqual(loaded.id, session.id)
        XCTAssertEqual(loaded.audioTracks.first?.id, validTrack.id)
        XCTAssertEqual(loaded.audioTracks.first?.chunks, [])
    }

    // MARK: - Test 7: pre-slice JSON without recoveryResolvedAt decodes

    func testPreSliceSessionJSONWithoutResolvedAtDecodes() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let url = dir.appendingPathComponent(session.id.uuidString).appendingPathComponent("session.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json.removeValue(forKey: "recoveryResolvedAt")
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reloaded = try await store.load(id: session.id)
        XCTAssertNotNil(reloaded)
        XCTAssertNil(reloaded?.recoveryResolvedAt)
        let recoverable = try await store.loadRecoverable()
        XCTAssertTrue(recoverable.contains(where: { $0.id == session.id }))
    }

    // MARK: - Test 8: retry failure before the pipeline leaves a recoverable state

    func testRetryFailureLeavesRecoverableStateAndReleasesGuards() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ThrowingDirectoryStore(wrapping: MeetingSessionStore(rootDirectory: dir))
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertNotNil(coordinator.activeSession)

        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw")
        } catch {}

        guard case .failed = coordinator.state else {
            return XCTFail("Expected .failed after sessionDirectory throw, got \(coordinator.state)")
        }
    }

    // MARK: - Test 9: store delete removes directory + index, idempotent, resurrection-proof

    func testStoreDeleteRemovesSessionIdempotently() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.path))

        try await store.delete(id: session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))

        try await store.delete(id: session.id) // idempotent

        do {
            try await store.save(session)
            XCTFail("Expected save after delete to throw")
        } catch {}

        do {
            _ = try await store.sessionDirectory(for: session.id)
            XCTFail("Expected sessionDirectory after delete to throw")
        } catch {}

        let all = try await store.loadAll()
        XCTAssertFalse(all.contains(where: { $0.id == session.id }))
    }

    // MARK: - Test 10: retry-by-id on a non-active history session

    func testRetryByIDOnNonActiveHistorySessionCompletes() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)
        try coordinator.resetForNewMeeting()

        for _ in 0..<40 {
            if let persisted = try await store.load(id: session.id), persisted.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNil(coordinator.activeSession)

        let result = try await coordinator.retryProcessing(sessionID: session.id)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(coordinator.latestCompletedSession?.id, session.id)
        XCTAssertEqual(coordinator.state, .completed(session.id))
        XCTAssertNil(coordinator.activeSession)
    }

    // MARK: - Test 11: retry-by-id displaces a passive recovery offer

    func testRetryByIDDisplacesPassiveOffer() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let now = Date()
        let older = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-600),
            endedAt: now.addingTimeInterval(-590),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let newer = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-60),
            endedAt: now.addingTimeInterval(-50),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(older)
        try await store.create(newer)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)

        let result = try await coordinator.retryProcessing(sessionID: older.id)
        XCTAssertEqual(result.id, older.id)
        XCTAssertEqual(result.state, .completed)
        XCTAssertEqual(coordinator.latestCompletedSession?.id, older.id)

        let persistedOffer = try await store.load(id: newer.id)
        XCTAssertNotNil(persistedOffer?.recoveryResolvedAt)
    }

    // MARK: - Test 12: retry-by-id refused while recording, and while another retry is in-flight

    func testRetryByIDRefusedWhileRecordingAndWhileRetryInFlight() async throws {
        let recordingDir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: recordingDir) }
        let recordingStore = MeetingSessionStore(rootDirectory: recordingDir)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let recordingCoordinator = MeetingSessionCoordinator(
            store: recordingStore,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        let recordingSession = try await recordingCoordinator.startRecording(configuration: self.makeConfiguration())
        do {
            _ = try await recordingCoordinator.retryProcessing(sessionID: recordingSession.id)
            XCTFail("Expected retryProcessing to throw while recording")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        let retryDir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: retryDir) }
        let retryStore = MeetingSessionStore(rootDirectory: retryDir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await retryStore.create(session)
        let gatedProcessing = GatedProcessingController()
        let retryCoordinator = MeetingSessionCoordinator(
            store: retryStore,
            capture: StubCaptureController(),
            processing: gatedProcessing,
            audioArbiter: StubArbiter()
        )
        await retryCoordinator.ensureRestored()
        let retryTask = Task { try await retryCoordinator.retryProcessing(sessionID: session.id) }

        for _ in 0..<40 {
            if case .processing = retryCoordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = retryCoordinator.state else {
            return XCTFail("First retry did not reach .processing")
        }

        do {
            _ = try await retryCoordinator.retryProcessing(sessionID: session.id)
            XCTFail("Expected second retryProcessing to throw while first is in-flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        gatedProcessing.openGate()
        let finalSession = try await retryTask.value
        XCTAssertEqual(finalSession.state, .completed)
    }

    // MARK: - Test 13: deleteSession on the active recovery offer

    func testDeleteSessionOnActiveRecoveryOffer() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        try await coordinator.deleteSession(id: session.id)

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
    }

    // MARK: - Test 14: deleteSession refused mid-processing

    func testDeleteSessionRefusedMidProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let gatedProcessing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: gatedProcessing,
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let retryTask = Task { try await coordinator.retryProcessing() }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            return XCTFail("retryProcessing did not reach .processing")
        }

        do {
            try await coordinator.deleteSession(id: session.id)
            XCTFail("Expected deleteSession to throw while processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        gatedProcessing.openGate()
        _ = try await retryTask.value
    }

    // MARK: - Test 15: delete-resurrection guard

    func testStoreDeleteResurrectionGuard() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        try await store.delete(id: session.id)

        do {
            try await store.save(session)
            XCTFail("Expected save after delete to throw")
        } catch {}

        let sessionDirectory = try await store.existingSessionDirectory(for: session.id)
        XCTAssertNil(sessionDirectory)
    }

    // MARK: - Test 16: recordAgain from a passive offer

    func testRecordAgainFromPassiveOfferSucceeds() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        let newSession = try await coordinator.recordAgain(
            from: session.id,
            configuration: self.makeConfiguration(title: "Again")
        )
        XCTAssertNotEqual(newSession.id, session.id)
        XCTAssertEqual(coordinator.activeSession?.id, newSession.id)
        guard case .recording = coordinator.state else {
            return XCTFail("Expected .recording after recordAgain, got \(coordinator.state)")
        }

        var persistedOld: MeetingSession?
        for _ in 0..<40 {
            persistedOld = try await store.load(id: session.id)
            if persistedOld?.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertNotNil(persistedOld?.recoveryResolvedAt)
    }

    func testRecordAgainFromPassiveOfferRestoresOnCaptureFailure() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let capture = StubCaptureController()
        capture.startError = MeetingCaptureError.applicationNotSelected
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        do {
            _ = try await coordinator.recordAgain(from: session.id, configuration: self.makeConfiguration(title: "Again"))
            XCTFail("Expected recordAgain to throw when capture start fails")
        } catch {}

        XCTAssertEqual(coordinator.activeSession?.id, session.id)
        XCTAssertEqual(coordinator.activeSession?.state, .interrupted)
        XCTAssertEqual(coordinator.state, .interrupted(session.id))

        let persistedOld = try await store.load(id: session.id)
        XCTAssertNil(persistedOld?.recoveryResolvedAt)
    }

    // A recoverable failed capture is passive after its lease is released; a later
    // auto-detected start must be allowed to replace it without resolving its audio.
    func testOrdinaryStartReplacesPassiveFailedOfferWithoutResolvingIt() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let old = self.makeSession(
            state: .failed,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])],
            failures: [MeetingSessionFailure(id: UUID(), occurredAt: Date(), domain: .capture, code: "teams.noSpeech", message: "No speech", recoverable: true)]
        )
        try await store.create(old)

        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, old.id)

        let fresh = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Zoom"))
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertEqual(coordinator.activeSession?.id, fresh.id)
        let persistedOld = try await store.load(id: old.id)
        XCTAssertNil(persistedOld?.recoveryResolvedAt)
        XCTAssertTrue(persistedOld?.hasFinalizedAudio == true)
    }

    func testStartFailureRestoresPassiveOfferUnchanged() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let old = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(old)
        let capture = StubCaptureController()
        capture.startError = MeetingCaptureError.applicationNotSelected
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter
        )
        await coordinator.ensureRestored()
        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Retry"))
            XCTFail("expected capture start to fail")
        } catch {}
        XCTAssertEqual(coordinator.activeSession?.id, old.id)
        XCTAssertEqual(coordinator.activeSession?.audioTracks, old.audioTracks)
        XCTAssertEqual(coordinator.state, .interrupted(old.id))
        let persistedOld = try await store.load(id: old.id)
        XCTAssertNil(persistedOld?.recoveryResolvedAt)
    }

    func testOrdinaryStartPreservesExpiredInterruptedAudioAndPendingAttempt() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let past = Date(timeIntervalSinceNow: -40 * 24 * 60 * 60)
        let old = self.makeSession(
            state: .interrupted,
            startedAt: past,
            endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])],
            processingAttempts: [MeetingProcessingAttempt(
                id: UUID(),
                startedAt: past,
                completedAt: nil,
                stage: .pending,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )]
        )
        try await store.create(old)
        let sessionDirectory = try await store.sessionDirectory(for: old.id)
        let audio = sessionDirectory.appendingPathComponent("tracks/microphone/chunk_0.caf")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 128).write(to: audio)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let before = try await store.load(id: old.id)
        _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Next app"))
        await coordinator.sweepExpiredAudio()
        let after = try await store.load(id: old.id)
        XCTAssertNil(after?.recoveryResolvedAt)
        XCTAssertNil(after?.retention.audioDeletedAt)
        XCTAssertEqual(after?.processingAttempts, before?.processingAttempts)
        XCTAssertEqual(after?.audioTracks, before?.audioTracks)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio.path))
        XCTAssertFalse(coordinator.hasPendingStart)
    }

    func testDeniedPermissionPreservesPassiveOfferAndReleasesStartReservation() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let old = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(old)
        let capture = StubCaptureController()
        capture.preflightError = MeetingCaptureError.microphonePermissionDenied
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter
        )
        await coordinator.ensureRestored()
        let before = coordinator.activeSession
        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration())
            XCTFail("Permission denial must reject the new recording")
        } catch {
            guard case MeetingCaptureError.microphonePermissionDenied = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(coordinator.activeSession?.id, before?.id)
        XCTAssertEqual(coordinator.activeSession?.audioTracks, before?.audioTracks)
        XCTAssertEqual(arbiter.acquireCount, 0)
        XCTAssertFalse(coordinator.hasPendingStart)
        capture.preflightError = nil
        let fresh = try await coordinator.startRecording(configuration: self.makeConfiguration())
        XCTAssertNotEqual(fresh.id, old.id)
        XCTAssertFalse(coordinator.hasPendingStart)
    }

    func testConcurrentStartAndRecoveryActionsAreBlockedDuringPermissionPreflight() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        var continuation: CheckedContinuation<Void, Never>?
        let preflightReached = self.expectation(description: "preflight suspended")
        capture.onPreflight = {
            await withCheckedContinuation {
                continuation = $0
                preflightReached.fulfill()
            }
        }
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter
        )
        let start = Task { try await coordinator.startRecording(configuration: self.makeConfiguration()) }
        await self.fulfillment(of: [preflightReached], timeout: 2)

        do {
            _ = try await coordinator.retryProcessing(sessionID: UUID())
            XCTFail("retry must be rejected while start is reserved")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else { return XCTFail("expected activityInProgress, got \(error)") }
        }
        XCTAssertEqual(arbiter.acquireCount, 0)

        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Second"))
            XCTFail("duplicate start must be rejected while preflight is suspended")
        } catch let error as MeetingCoordinatorError {
            guard case .recordingAlreadyActive = error else {
                return XCTFail("expected recordingAlreadyActive, got \(error)")
            }
        }
        do {
            try coordinator.resetForNewMeeting()
            XCTFail("reset must be rejected while start is reserved")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("expected activityInProgress, got \(error)")
            }
        }
        do {
            try await coordinator.deleteSession(id: UUID())
            XCTFail("delete must be rejected while start is reserved")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("expected activityInProgress, got \(error)")
            }
        }
        continuation?.resume()
        _ = try await start.value
        XCTAssertEqual(capture.preflightCount, 1)
    }

    func testTerminationInvalidatesSuspendedStartBeforePermissionReturns() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = StubCaptureController()
        var continuation: CheckedContinuation<Void, Never>?
        let preflightReached = self.expectation(description: "preflight suspended")
        capture.onPreflight = {
            await withCheckedContinuation {
                continuation = $0
                preflightReached.fulfill()
            }
        }
        let coordinator = MeetingSessionCoordinator(
            store: MeetingSessionStore(rootDirectory: dir),
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        let start = Task { try await coordinator.startRecording(configuration: self.makeConfiguration()) }
        await self.fulfillment(of: [preflightReached], timeout: 2)
        await coordinator.shutdownForTermination()
        continuation?.resume()
        do {
            _ = try await start.value
            XCTFail("terminated coordinator must not start capture after preflight")
        } catch {}
        XCTAssertEqual(capture.preflightCount, 1)
        XCTAssertEqual(capture.startCount, 0)
    }

    // MARK: - Slice 3: checkpoint fixtures

    private func makeCheckpoint(
        sessionID: MeetingSessionID = UUID(),
        completedTrackID: MeetingAudioTrackID = UUID(),
        trackFingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = [:],
        asrModel: String = "base"
    ) -> MeetingProcessingCheckpoint {
        MeetingProcessingCheckpoint(
            version: MeetingProcessingCheckpoint.currentVersion,
            sessionID: sessionID,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: "apple",
            asrModel: asrModel,
            languageCode: "en",
            diarizationFingerprint: MeetingProcessingCheckpoint.currentDiarizationFingerprint,
            completedTrackID: completedTrackID,
            trackFingerprints: trackFingerprints,
            speakers: [],
            segments: [],
            remoteSpeech: [MeetingProcessingCheckpoint.SpeechInterval(start: 0, end: 1.5)],
            speakerIDByKey: ["remote-cluster:x": UUID()],
            nextRemoteSpeaker: 2,
            nextMicrophoneSpeaker: 1
        )
    }

    // MARK: - Slice 3, test 1: checkpoint round-trip

    func testCheckpointRoundTripEncodesAndDecodesEqual() throws {
        let checkpoint = self.makeCheckpoint(trackFingerprints: [
            UUID(): [MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 100, sha256: "abc")],
        ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(checkpoint)
        let decoded = try decoder.decode(MeetingProcessingCheckpoint.self, from: data)
        XCTAssertEqual(decoded, checkpoint)
    }

    // MARK: - Slice 3, test 2: checkpoint validity matrix

    func testCheckpointValidityMatrix() throws {
        let session = self.makeSession(state: .interrupted, endedAt: Date())
        let trackID = UUID()
        let fingerprint = MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 128, sha256: "abc123")
        let fingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = [trackID: [fingerprint]]
        let checkpoint = self.makeCheckpoint(sessionID: session.id, completedTrackID: trackID, trackFingerprints: fingerprints)

        func isValid(
            pipelineVersion: Int = MeetingProcessingPipeline.pipelineVersion,
            provider: String = "apple",
            model: String = "base",
            language: String = "en",
            diarizationFingerprint: String = MeetingProcessingCheckpoint.currentDiarizationFingerprint,
            completedTrackID: MeetingAudioTrackID = trackID,
            expectedFingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = fingerprints,
            session: MeetingSession = session
        ) -> Bool {
            checkpoint.isValid(
                session: session,
                pipelineVersion: pipelineVersion,
                provider: provider,
                model: model,
                language: language,
                diarizationFingerprint: diarizationFingerprint,
                completedTrackID: completedTrackID,
                expectedFingerprints: expectedFingerprints
            )
        }

        XCTAssertTrue(isValid())
        XCTAssertFalse(isValid(pipelineVersion: MeetingProcessingPipeline.pipelineVersion + 1))
        XCTAssertFalse(isValid(provider: "other"))
        XCTAssertFalse(isValid(model: "other"))
        XCTAssertFalse(isValid(language: "fr"))
        XCTAssertFalse(isValid(diarizationFingerprint: "different-diarizer"))
        XCTAssertFalse(isValid(completedTrackID: UUID()))
        var otherSession = session
        otherSession.id = UUID()
        XCTAssertFalse(isValid(session: otherSession))

        var mutatedByteCount = fingerprints
        mutatedByteCount[trackID]?[0].byteCount = 999
        XCTAssertFalse(isValid(expectedFingerprints: mutatedByteCount))

        var mutatedSha = fingerprints
        mutatedSha[trackID]?[0].sha256 = "different"
        XCTAssertFalse(isValid(expectedFingerprints: mutatedSha))

        var extraChunk = fingerprints
        extraChunk[trackID]?.append(MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 1, sha256: "x"))
        XCTAssertFalse(isValid(expectedFingerprints: extraChunk))

        XCTAssertFalse(isValid(expectedFingerprints: [trackID: []]))

        var versionMismatch = checkpoint
        versionMismatch.version = MeetingProcessingCheckpoint.currentVersion + 1
        XCTAssertFalse(versionMismatch.isValid(
            session: session,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            provider: "apple",
            model: "base",
            language: "en",
            completedTrackID: trackID,
            expectedFingerprints: fingerprints
        ))
    }

    /// A checkpoint must validate a resume on the same model and be invalidated by a model
    /// switch, so a resume can never continue from a stale, wrong-model checkpoint.
    func testResumedVersusCleanCheckpointEquivalenceAcrossAModelSwitch() throws {
        let session = self.makeSession(state: .interrupted, endedAt: Date())
        let trackID = UUID()
        let fingerprint = MeetingProcessingCheckpoint.ChunkFingerprint(id: UUID(), byteCount: 128, sha256: "abc123")
        let fingerprints: [MeetingAudioTrackID: [MeetingProcessingCheckpoint.ChunkFingerprint]] = [trackID: [fingerprint]]

        let checkpoint = self.makeCheckpoint(
            sessionID: session.id,
            completedTrackID: trackID,
            trackFingerprints: fingerprints,
            asrModel: "parakeet-tdt-v2"
        )

        XCTAssertTrue(checkpoint.isValid(
            session: session,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            provider: checkpoint.asrProvider,
            model: "parakeet-tdt-v2",
            language: "en",
            completedTrackID: trackID,
            expectedFingerprints: fingerprints
        ), "resuming with the same resolved model as the clean run must validate")

        XCTAssertFalse(checkpoint.isValid(
            session: session,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            provider: checkpoint.asrProvider,
            model: "whisper-large-turbo",
            language: "en",
            completedTrackID: trackID,
            expectedFingerprints: fingerprints
        ), "a model switch between runs must invalidate the checkpoint rather than resume stale speaker/segment state")
    }

    // MARK: - Slice 3, test 3: coordinator deletes checkpoint after success

    func testCoordinatorDeletesCheckpointAfterProcessingSuccess() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let checkpointURL = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        try Data("{}".utf8).write(to: checkpointURL)
        let retainedCheckpoint = sessionDirectory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.fileName)
        let retainedKey = sessionDirectory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.keyFileName)
        try Data("synthetic working state".utf8).write(to: retainedCheckpoint)
        try Data(repeating: 1, count: 32).write(to: retainedKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))

        var lines: [String] = []
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter(),
            processingLogger: { lines.append($0) }
        )
        await coordinator.ensureRestored()
        let result = try await coordinator.retryProcessing()

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("outcome=completed") == true)
        XCTAssertTrue(lines.first?.contains("stage=completed") == true)
        XCTAssertFalse(lines.first?.contains("errorCode=") == true)
        XCTAssertEqual(result.state, .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedCheckpoint.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedKey.path))
    }

    func testExplicitRestartDiscardsCorruptWorkingStateAndPreservesRetainedAudio() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(state: .interrupted, endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])])
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        let checkpoint = directory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.fileName)
        let key = directory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.keyFileName)
        try Data("damaged checkpoint".utf8).write(to: checkpoint)
        try Data(repeating: 1, count: 32).write(to: key)
        let legacyCheckpoint = directory.appendingPathComponent("checkpoint.json")
        try Data("legacy progress".utf8).write(to: legacyCheckpoint)
        let audio = directory.appendingPathComponent("tracks/microphone/chunk_0.caf")
        try FileManager.default.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sourceBytes = Data(repeating: 7, count: 128); try sourceBytes.write(to: audio)
        let processing = RestartCheckingProcessingController()
        let coordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
            processing: processing, audioArbiter: StubArbiter())
        await coordinator.ensureRestored()
        let completed = try await coordinator.restartProcessing(sessionID: session.id)
        XCTAssertEqual(completed.id, session.id)
        XCTAssertTrue(processing.sawCleanWorkingState)
        XCTAssertEqual(try Data(contentsOf: audio), sourceBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoint.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyCheckpoint.path))
    }

    func testStrictRecordingCannotRestartWithDurableWorkingState() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var session = self.makeSession(state: .interrupted, endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [])])
        session.audioStorageMode = .memoryOnly
        try await store.create(session)
        let coordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
            processing: StubProcessingController(), audioArbiter: StubArbiter())
        do { _ = try await coordinator.restartProcessing(sessionID: session.id); XCTFail("Strict mode has no retained input") }
        catch MeetingCoordinatorError.noRecoverableAudio {}
        let directory = try await store.sessionDirectory(for: session.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.fileName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.keyFileName).path))
    }

    func testTerminationJoinsCancelledRetainedInferenceBeforeRecoveryIsIdle() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(state: .interrupted, endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])])
        try await store.create(session)
        let processing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
            processing: processing, audioArbiter: StubArbiter())
        await coordinator.ensureRestored()
        let retry = Task { try await coordinator.retryProcessing(sessionID: session.id) }
        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else { return XCTFail("Processing did not start") }
        do { _ = try await coordinator.restartProcessing(sessionID: session.id); XCTFail("In-flight work owns its checkpoint") }
        catch {}
        var finishedShutdown = false
        let shutdown = Task { await coordinator.shutdownForTermination(); finishedShutdown = true }
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertFalse(finishedShutdown, "Cancellation cannot declare a non-drained model scope idle")
        processing.openGate()
        await shutdown.value
        _ = try? await retry.value
        XCTAssertTrue(finishedShutdown)
        XCTAssertEqual(coordinator.activeSession?.state, .interrupted)
    }

    func testProcessingDiagnosticsPreserveFailureAndTranscriptAcrossRetries() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var session = self.makeCorrectionSession(state: .interrupted).session
        session.title = "Private meeting title"
        session.transcriptSegments[0].text = "Private transcript content"
        try await store.create(session)
        let message = "Missing model\n" + String(repeating: "x", count: 1000)
        let error = NSError(domain: "MeetingProbe\r", code: 42, userInfo: [NSLocalizedDescriptionKey: message])
        var lines: [String] = []
        let arbiter = StubArbiter()
        let processing = DiagnosticFailingProcessingController(error: error)
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: processing,
            audioArbiter: arbiter,
            processingLogger: { lines.append($0) }
        )
        await coordinator.ensureRestored()
        for attempt in 1...2 {
            do {
                _ = try await coordinator.retryProcessing(sessionID: session.id)
                XCTFail("Expected the processing error")
            } catch {
                XCTAssertEqual((error as NSError).code, 42)
            }
            XCTAssertEqual(lines.count, attempt, "Exactly one terminal diagnostic per attempt")
            let line = try XCTUnwrap(lines.last)
            XCTAssertTrue(line.contains("outcome=failed"))
            XCTAssertTrue(line.contains("stage=transcribing"))
            XCTAssertTrue(line.contains("errorCode=MeetingProbe .42"))
            XCTAssertTrue(line.contains("elapsedMs="))
            XCTAssertLessThan(line.count, 800)
            XCTAssertFalse(line.contains("\n"))
            XCTAssertFalse(line.contains("\r"))
            XCTAssertFalse(line.contains(session.title))
            XCTAssertFalse(line.contains("Private transcript content"))
            let saved = try await store.load(id: session.id)
            let persisted = try XCTUnwrap(saved)
            XCTAssertEqual(persisted.state, .failed)
            XCTAssertEqual(persisted.failures.last?.message, message, "Only log details are shortened")
            XCTAssertEqual(persisted.transcriptSegments, session.transcriptSegments)
            XCTAssertEqual(persisted.audioTracks, session.audioTracks)
            XCTAssertEqual(arbiter.releaseCount, attempt)
        }
        XCTAssertEqual(arbiter.acquireCount, 2)
        processing.emitLateProgress(.completed)
        XCTAssertEqual(lines.count, 2, "Stale progress must not produce a second outcome")
        XCTAssertEqual(coordinator.activeSession?.state, .failed)
        XCTAssertEqual(coordinator.activeSession?.transcriptSegments, session.transcriptSegments)
    }

    func testProcessingCancellationLogsWithoutAddingFailureOrLosingTranscript() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeCorrectionSession(state: .interrupted).session
        try await store.create(session)
        var lines: [String] = []
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: DiagnosticFailingProcessingController(error: CancellationError()),
            audioArbiter: arbiter,
            processingLogger: { lines.append($0) }
        )
        await coordinator.ensureRestored()
        do {
            _ = try await coordinator.retryProcessing(sessionID: session.id)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines.first?.contains("outcome=cancelled") == true)
        XCTAssertFalse(lines.first?.contains("errorCode=") == true)
        let saved = try await store.load(id: session.id)
        let persisted = try XCTUnwrap(saved)
        XCTAssertEqual(persisted.state, .interrupted)
        XCTAssertTrue(persisted.failures.isEmpty)
        XCTAssertEqual(persisted.transcriptSegments, session.transcriptSegments)
        XCTAssertEqual(persisted.audioTracks, session.audioTracks)
        XCTAssertEqual(arbiter.releaseCount, 1)
    }

    // MARK: - Slice 3, test 4: checkpoint survives a failed retry

    func testCheckpointSurvivesProcessingFailure() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let checkpointURL = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        try Data("{}".utf8).write(to: checkpointURL)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: ThrowingProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: checkpointURL.path))
    }

    // MARK: - Slice 3, test 5: skipped-chunk event and chunk failure marking

    func testSkippedChunksProduceEventAndMarkChunksFailed() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let chunk = self.makeFinalizedChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")
        // A second finalized chunk keeps the skip count below the total, so the
        // success+skip combination this test asserts is actually realizable.
        let survivingChunk = self.makeFinalizedChunk(sequence: 1, path: "tracks/microphone/chunk_1.caf")
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [chunk, survivingChunk])]
        )
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: SkippedChunkProcessingController(skippedChunkIDs: [chunk.id]),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let result = try await coordinator.retryProcessing()

        XCTAssertEqual(result.state, .completed)
        XCTAssertTrue(result.events.contains {
            $0.detail == "1 audio chunk(s) could not be read and were skipped."
        })
        let persistedChunk = result.audioTracks.first?.chunks.first(where: { $0.id == chunk.id })
        XCTAssertEqual(persistedChunk?.finalizationState, .failed)
        let persistedSurvivor = result.audioTracks.first?.chunks.first(where: { $0.id == survivingChunk.id })
        XCTAssertEqual(persistedSurvivor?.finalizationState, .finalized)

        let reloaded = try await store.load(id: session.id)
        let reloadedChunk = reloaded?.audioTracks.first?.chunks.first(where: { $0.id == chunk.id })
        XCTAssertEqual(reloadedChunk?.finalizationState, .failed)
    }

    // MARK: - Slice 3, test 6: unreadable-chunk classification

    // MARK: - Regression: arbiter failure during history retry must not strand activeSession

    func testRetryByIDArbiterFailureDoesNotStrandActiveSession() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)

        let now = Date()
        let older = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-600),
            endedAt: now.addingTimeInterval(-590),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let newer = self.makeSession(
            state: .interrupted,
            startedAt: now.addingTimeInterval(-60),
            endedAt: now.addingTimeInterval(-50),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(older)
        try await store.create(newer)

        let arbiter = ThrowOnceArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: arbiter
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)

        do {
            _ = try await coordinator.retryProcessing(sessionID: older.id)
            XCTFail("Expected retryProcessing to throw when the arbiter refuses the lease")
        } catch {}

        // Not wedged: the passive offer was never displaced/adopted, so state and activeSession
        // stay consistent with each other instead of activeSession != nil with state == .idle.
        XCTAssertEqual(coordinator.activeSession?.id, newer.id)
        XCTAssertEqual(coordinator.state, .interrupted(newer.id))

        // A subsequent recording is not permanently blocked by a stranded activeSession.
        try coordinator.resetForNewMeeting()
        for _ in 0..<40 {
            if let persisted = try await store.load(id: newer.id), persisted.recoveryResolvedAt != nil { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        // `older` was never resolved (the failed retry targeted it but never adopted it); clear
        // it too so a fresh coordinator's restore scan has nothing left to re-offer.
        try await store.delete(id: older.id)
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let workingCoordinator = MeetingSessionCoordinator(
            store: store,
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        let started = try await workingCoordinator.startRecording(configuration: self.makeConfiguration(title: "Recovered"))
        guard case .recording = workingCoordinator.state else {
            return XCTFail("Expected .recording, got \(workingCoordinator.state)")
        }
        XCTAssertEqual(workingCoordinator.activeSession?.id, started.id)
    }

    // MARK: - Regression: deleteSession re-checks quiescence after the persistence flush

    func testDeleteSessionBlocksRetryUntilComplete() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedDeleteStore(inner: realStore, recorder: recorder)
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        let deleteTask = Task { try await coordinator.deleteSession(id: session.id) }

        for _ in 0..<40 {
            if await recorder.events.contains("store.delete.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsSoFar = await recorder.events
        XCTAssertTrue(eventsSoFar.contains("store.delete.start"))

        do {
            _ = try await coordinator.retryProcessing(sessionID: session.id)
            XCTFail("Expected retryProcessing to throw while deleteSession is mid-flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        try await deleteTask.value

        XCTAssertNil(coordinator.activeSession)
        let reloaded = try? await realStore.load(id: session.id)
        XCTAssertNil(reloaded)
    }

    func testReadSamplesThrowsAudioUnreadableForGarbageFile() throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garbage.m4a", isDirectory: false)
        try Data((0..<256).map { _ in UInt8.random(in: 0...255) }).write(to: url)

        XCTAssertThrowsError(
            try MeetingProcessingPipeline.readSamples(fileURL: url, startSeconds: 0, endSeconds: nil)
        ) { error in
            guard case MeetingProcessingError.audioUnreadable = error else {
                XCTFail("Expected .audioUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - Transcript corrections: persistence, undo, gating

    func testTranscriptTextEditPersistsExportsAndUndoesWithoutChangingRecording() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var (session, _, _, segmentID) = self.makeCorrectionSession(state: .completed)
        var other = session.transcriptSegments[0]
        other.id = UUID()
        session.transcriptSegments.append(other)
        try await store.create(session)
        let baseline = try await store.load(id: session.id)
        session = try XCTUnwrap(baseline)
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        let original = session.transcriptSegments[0]
        let edited = try await coordinator.editTranscriptText(
            sessionID: session.id, segmentID: segmentID, text: "  Corrected words  ", expectedRevision: original.revision
        )
        var expected = session
        expected.transcriptSegments[0].text = "Corrected words"
        expected.transcriptSegments[0].originalText = original.text
        expected.transcriptSegments[0].revision += 1
        expected.updatedAt = edited.updatedAt
        XCTAssertEqual(edited, expected, "Only this paragraph's text, correction metadata and update time change")
        let loaded = try await store.load(id: session.id)
        let reloaded = try XCTUnwrap(loaded)
        XCTAssertEqual(reloaded.updatedAt.timeIntervalSince1970, floor(edited.updatedAt.timeIntervalSince1970), accuracy: 0.001)
        expected.updatedAt = reloaded.updatedAt // Existing ISO-8601 persistence has second precision.
        XCTAssertEqual(reloaded, expected)
        XCTAssertTrue(MeetingTranscriptExporter.text(for: reloaded).contains("Corrected words"))
        let exportedJSON = try XCTUnwrap(String(data: MeetingTranscriptExporter.json(for: reloaded), encoding: .utf8))
        XCTAssertTrue(exportedJSON.contains("Corrected words"))
        XCTAssertNil(coordinator.activeSession, "Editing history must not start or adopt a recording")

        let editedAgain = try await coordinator.editTranscriptText(
            sessionID: session.id, segmentID: segmentID, text: "Second correction", expectedRevision: original.revision + 1
        )
        XCTAssertEqual(editedAgain.transcriptSegments[0].originalText, original.text)
        let undoSecond = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undoSecond.transcriptSegments, edited.transcriptSegments)
        let undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)
        XCTAssertEqual(undone.audioTracks, session.audioTracks)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testTranscriptTextEditRejectsBlankStaleAndIgnoresNoOp() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var (session, _, _, segmentID) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let baseline = try await store.load(id: session.id)
        session = try XCTUnwrap(baseline)
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        let original = session.transcriptSegments[0]
        for (text, revision, expectedError) in [
            (" \n ", original.revision, MeetingDomainError.emptyTranscriptText),
            ("New text", original.revision - 1, MeetingDomainError.staleTranscriptEdit),
        ] {
            do {
                _ = try await coordinator.editTranscriptText(sessionID: session.id, segmentID: segmentID, text: text, expectedRevision: revision)
                XCTFail("Invalid correction must fail")
            } catch let error as MeetingDomainError {
                XCTAssertEqual(error, expectedError)
            }
        }
        _ = try await coordinator.editTranscriptText(
            sessionID: session.id, segmentID: segmentID, text: "  \(original.text)  ", expectedRevision: original.revision
        )
        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded, session)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testTranscriptTextFailedSaveKeepsOriginalAndAllowsRetry() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var (session, _, _, segmentID) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let baseline = try await store.load(id: session.id)
        session = try XCTUnwrap(baseline)
        let gated = GatedThrowingSaveStore(inner: store, recorder: EventRecorder())
        await gated.throwOnNextSave()
        let coordinator = MeetingSessionCoordinator(
            store: gated, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        do {
            _ = try await coordinator.editTranscriptText(sessionID: session.id, segmentID: segmentID, text: "Corrected", expectedRevision: 1)
            XCTFail("Save failure must propagate")
        } catch {}
        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded, session)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
        let retried = try await coordinator.editTranscriptText(sessionID: session.id, segmentID: segmentID, text: "Corrected", expectedRevision: 1)
        XCTAssertEqual(retried.transcriptSegments[0].text, "Corrected")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testTranscriptEditorRendersWithoutInvokingSaveOrCancel() throws {
        guard let path = ProcessInfo.processInfo.environment["FLUIDVOICE_MEETING_EDIT_SNAPSHOT"] else {
            throw XCTSkip("Opt-in transcript editor visual check")
        }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var actions = 0
        for scheme in [ColorScheme.light, .dark] {
            let view = MeetingTranscriptTextEditor(
                text: "Today we reviewed the project timeline. Our next meeting is on Friday.",
                onSave: { _ in actions += 1; return nil },
                onCancel: { actions += 1 }
            )
            .appTheme(.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme))
            .environment(\.colorScheme, scheme)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 440), styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            host.appearance = window.appearance
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            defer { window.orderOut(nil) }
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("editor-\(scheme).png"))
        }
        XCTAssertEqual(actions, 0)
    }

    func testEachCorrectionOpOnHistorySessionPersists() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, segmentID) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed A")
        var reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed A")

        _ = try await coordinator.reassignSegment(sessionID: session.id, segmentID: segmentID, to: speakerB)
        reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.transcriptSegments.first(where: { $0.id == segmentID })?.speakerID, speakerB)

        _ = try await coordinator.mergeSpeakers(sessionID: session.id, source: speakerB, into: speakerA)
        reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerB })?.mergedIntoSpeakerID, speakerA)
        XCTAssertEqual(reloaded?.transcriptSegments.first(where: { $0.id == segmentID })?.speakerID, speakerA)

        // A history-scoped correction never adopts the session into a coordinator slot.
        XCTAssertNil(coordinator.activeSession)
        XCTAssertNil(coordinator.latestCompletedSession)
    }

    func testCorrectingProjectedOwnerToRawSpeakerPersistsAndUndoRestoresReading() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        session.transcriptCoverageGaps = nil
        session.transcriptTimeDomain = .meetingRelative
        session.transcriptIsComplete = true
        let template = session.transcriptSegments[0]
        session.transcriptSegments = (0..<5).map { index in
            var word = template
            word.id = UUID()
            word.start = .init(value: Int64(index * 4), timescale: 10)
            word.end = .init(value: Int64(index * 4 + 3), timescale: 10)
            word.text = "Synthetic \(index)"
            word.originalText = nil
            word.revision = 0
            word.status = .final
            word.completeness = .complete
            word.speakerID = index == 2 ? speakerB : speakerA
            word.overlap = .none
            word.attributionState = .assigned
            if index == 1 || index == 3 {
                word.speakerID = nil
                word.overlap = .ambiguous
                word.attributionState = .overlappingSpeakers
            }
            return word
        }
        let targetID = session.transcriptSegments[2].id
        XCTAssertEqual(MeetingTranscriptExporter.speakerPresentations(in: session)[targetID]?.participantID, speakerA)
        XCTAssertEqual(session.transcriptSegments[2].speakerID, speakerB)
        XCTAssertNil(session.transcriptSegments[2].speakerAttribution)
        try await store.create(session)
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let corrected = try await coordinator.reassignSegment(sessionID: session.id, segmentID: targetID, to: speakerB)
        XCTAssertEqual(corrected.transcriptSegments[2].speakerID, speakerB)
        XCTAssertEqual(corrected.transcriptSegments[2].revision, 1)
        XCTAssertEqual(MeetingTranscriptExporter.speakerPresentations(in: corrected)[targetID]?.participantID, speakerB)
        for index in session.transcriptSegments.indices {
            var expected = session.transcriptSegments[index]
            if index == 2 { expected.revision = 1 }
            XCTAssertEqual(corrected.transcriptSegments[index], expected)
        }
        let persisted = try await store.load(id: session.id)
        // The archive codec normalizes Date precision; compare the correction evidence exactly.
        XCTAssertEqual(persisted?.transcriptSegments, corrected.transcriptSegments)
        XCTAssertEqual(persisted?.speakers, corrected.speakers)

        let repeated = try await coordinator.reassignSegment(sessionID: session.id, segmentID: targetID, to: speakerB)
        XCTAssertEqual(repeated, persisted)
        let undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)
        XCTAssertEqual(MeetingTranscriptExporter.speakerPresentations(in: undone)[targetID]?.participantID, speakerA)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id), "A no-op selection must not add another undo entry")
        let persistedUndo = try await store.load(id: session.id)
        XCTAssertEqual(persistedUndo?.transcriptSegments, session.transcriptSegments)
    }

    func testUndoRestoresExactPriorStateForEachCorrectionType() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var (session, speakerA, speakerB, segmentID) = self.makeCorrectionSession(state: .completed)
        let targetIndex = try XCTUnwrap(session.transcriptSegments.firstIndex { $0.id == segmentID })
        session.transcriptSegments[targetIndex].speakerAttributionInference = .init(rule: .incomingSpeaker,
            originalState: .unassigned, originalOverlap: .none, precedingSegmentID: UUID(), followingSegmentID: UUID())
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        var undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers, session.speakers)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)

        let reassigned = try await coordinator.reassignSegment(sessionID: session.id, segmentID: segmentID, to: speakerB)
        XCTAssertNil(reassigned.transcriptSegments.first { $0.id == segmentID }?.speakerAttributionInference)
        undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers, session.speakers)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)

        let merged = try await coordinator.mergeSpeakers(sessionID: session.id, source: speakerA, into: speakerB)
        XCTAssertNil(merged.transcriptSegments.first { $0.id == segmentID }?.speakerAttributionInference)
        undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers, session.speakers)
        XCTAssertEqual(undone.transcriptSegments, session.transcriptSegments)

        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testUndoNamingUnknownRestoresOnlyThatUnknownSegment() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let fixture = self.makeCorrectionSession(state: .completed)
        var session = fixture.0
        let segmentID = fixture.3
        session.transcriptSegments[0].speakerID = nil
        session.transcriptSegments[0].overlap = .ambiguous
        session.transcriptSegments[0].attributionState = .overlappingSpeakers
        let original = session.transcriptSegments[0]
        try await store.create(session)
        let coordinator = MeetingSessionCoordinator(
            store: store,
            capture: StubCaptureController(),
            processing: StubProcessingController(),
            audioArbiter: StubArbiter()
        )

        let named = try await coordinator.nameUnknownSegment(
            sessionID: session.id,
            segmentID: segmentID,
            displayName: "Guest"
        )
        XCTAssertEqual(named.speakers.count, session.speakers.count + 1)
        XCTAssertEqual(named.transcriptSegments[0].attributionState, .assigned)

        let undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.transcriptSegments[0], original)
        XCTAssertEqual(undone.speakers, session.speakers)
    }

    func testFailedCorrectionSaveLeavesNoUndoEntryAndDiskUnchanged() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.throwOnNextSave()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        do {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
            XCTFail("Expected the save failure to propagate")
        } catch {}

        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
        let reloaded = try await realStore.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Speaker A")
    }

    func testFailedUndoSaveRePushesCorrectionAndCanUndoStaysTrue() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))

        await gatedStore.throwOnNextSave()
        do {
            _ = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
            XCTFail("Expected the undo save failure to propagate")
        } catch {}

        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))
        let reloaded = try await realStore.load(id: session.id)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed")

        let undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        XCTAssertEqual(undone.speakers.first(where: { $0.id == speakerA })?.displayName, "Speaker A")
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    /// When the inverse's target is gone, undo drops the stale entry, throws
    /// `.noCorrectionToUndo`, and never saves — whatever other mutation produced is left as-is.
    func testUndoWithGoneInverseTargetDropsEntryAndSavesNothing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, speakerB, segmentID) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.reassignSegment(sessionID: session.id, segmentID: segmentID, to: speakerB)
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))

        // Segment vanishes from under the undo stack: save without it, bypassing the coordinator.
        let loaded = try await store.load(id: session.id)
        var mutated = try XCTUnwrap(loaded)
        mutated.transcriptSegments.removeAll { $0.id == segmentID }
        try await store.save(mutated)

        do {
            _ = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
            XCTFail("Expected undo to throw when the inverse target no longer exists")
        } catch let error as MeetingCoordinatorError {
            guard case .noCorrectionToUndo = error else {
                return XCTFail("Expected .noCorrectionToUndo, got \(error)")
            }
        }

        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id), "the stale entry must be dropped")
        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.transcriptSegments.count, mutated.transcriptSegments.count, "undo must never save on a dropped entry")
        XCTAssertFalse(reloaded?.transcriptSegments.contains { $0.id == segmentID } ?? true)
    }

    func testCorrectionRefusedWhileProcessingSameSession() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let processing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: processing, audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let retryTask = Task { try await coordinator.retryProcessing(sessionID: session.id) }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            return XCTFail("retryProcessing did not reach .processing")
        }

        do {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
            XCTFail("Expected correction to throw while processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        do {
            _ = try await coordinator.editTranscriptText(sessionID: session.id, segmentID: session.transcriptSegments[0].id, text: "Correction", expectedRevision: 1)
            XCTFail("Text edit must fail while processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else { return XCTFail("Expected activityInProgress, got \(error)") }
        }
        processing.openGate()
        _ = try await retryTask.value
    }

    func testSecondCorrectionRefusedWhileFirstInFlight() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let firstTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "First") }

        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsSoFar = await recorder.events
        XCTAssertTrue(eventsSoFar.contains("store.save.start"))

        do {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerB, to: "Second")
            XCTFail("Expected the second correction to throw while the first is in flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await firstTask.value
    }

    func testRetryByIDRefusedWhileCorrectionIsParked() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        // Restore first (it saves the reclassified session itself) so closing the gate below
        // only blocks the correction's save, not ensureRestored's own.
        await coordinator.ensureRestored()
        await gatedStore.closeGate()

        let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }

        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsAfterParking = await recorder.events
        XCTAssertTrue(eventsAfterParking.contains("store.save.start"))

        do {
            _ = try await coordinator.retryProcessing(sessionID: session.id)
            XCTFail("Expected retryProcessing to throw while a correction is parked")
        } catch let error as MeetingCoordinatorError {
            // O3: the mutation gate, not real activity, is the blocker here.
            guard case .maintenanceInProgress = error else {
                return XCTFail("Expected .maintenanceInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await correctionTask.value
    }

    func testDeleteSessionRefusedWhileCorrectionInFlightAndCorrectionRefusedWhileDeleting() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        // Part 1: deleteSession refused while a correction is in flight.
        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }
        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsAfterParking = await recorder.events
        XCTAssertTrue(eventsAfterParking.contains("store.save.start"))

        do {
            try await coordinator.deleteSession(id: session.id)
            XCTFail("Expected deleteSession to throw while a correction is in flight")
        } catch let error as MeetingCoordinatorError {
            guard case .maintenanceInProgress = error else {
                return XCTFail("Expected .maintenanceInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await correctionTask.value

        // Part 2: correction refused while a delete is mid-flight (isDeleting).
        let deleteGateStore = GatedDeleteStore(inner: realStore, recorder: recorder)
        let deleteCoordinator = MeetingSessionCoordinator(
            store: deleteGateStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let deleteTask = Task { try await deleteCoordinator.deleteSession(id: session.id) }
        for _ in 0..<40 {
            if await recorder.events.contains("store.delete.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsAfterDeleteStart = await recorder.events
        XCTAssertTrue(eventsAfterDeleteStart.contains("store.delete.start"))

        do {
            _ = try await deleteCoordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "During delete")
            XCTFail("Expected correction to throw while deleteSession is mid-flight")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        await deleteGateStore.openGate()
        try await deleteTask.value
    }

    // MARK: - Regression: correction flushes a queued stale-copy persistence before mutating

    func testCorrectionFlushesQueuedPersistenceBeforeMutating() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        // Dismiss the active offer: enqueues a stale-copy persistence write stamping recoveryResolvedAt.
        try coordinator.resetForNewMeeting()

        let corrected = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertEqual(corrected.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed")

        let reloaded = try await store.load(id: session.id)
        XCTAssertNotNil(reloaded?.recoveryResolvedAt)
        XCTAssertEqual(reloaded?.speakers.first(where: { $0.id == speakerA })?.displayName, "Renamed")
    }

    func testUndoStackClearedByRetryProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))

        _ = try await coordinator.retryProcessing(sessionID: session.id)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testArbiterThrowingRetryLeavesUndoStackIntact() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .interrupted)
        try await store.create(session)

        let arbiter = ThrowOnceArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: arbiter
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Renamed")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))

        do {
            _ = try await coordinator.retryProcessing()
            XCTFail("Expected retryProcessing to throw when the arbiter refuses the lease")
        } catch {}

        XCTAssertTrue(
            coordinator.canUndoCorrection(sessionID: session.id),
            "a lease failure before the undo stack is cleared must leave the prior correction undoable"
        )
    }

    func testUndoStackCapsAt50Entries() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        for index in 0..<51 {
            _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Name \(index)")
        }

        var undoCount = 0
        while coordinator.canUndoCorrection(sessionID: session.id) {
            _ = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
            undoCount += 1
        }
        XCTAssertEqual(undoCount, 50)
    }

    // MARK: - Batched speaker rename (Assign speakers sheet)

    @MainActor
    private final class SpeakerAliasRedactor: TranscriptTextRedacting {
        private(set) var inputs: [String] = []
        func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
            await MainActor.run { self.inputs.append(text) }
            let source = text as NSString
            let range = source.range(of: "Иван Тестов")
            guard range.location != NSNotFound else { return .init(text: text, spans: []) }
            return .init(text: source.replacingCharacters(in: range, with: "[PERSON]"),
                spans: [.init(range: range, replacement: "[PERSON]")])
        }
    }

    func testSpeakerAliasesAreExplicitMetadataWithAndWithoutTranscriptRedaction() async throws {
        for privacyEnabled in [false, true] {
            let dir = self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingSessionStore(rootDirectory: dir)
            let fixture = self.makeCorrectionSession(state: .completed)
            var session = fixture.session
            session.piiRedactionEnabled = privacyEnabled
            session.transcriptSegments[0].text = "Врач Иван Тестов просит инструкцию."
            session.transcriptSegments[0].originalText = "Иван Тестов"
            let redactor = SpeakerAliasRedactor()
            if privacyEnabled {
                session = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: session, using: redactor)
            }
            try await store.create(session)
            let admittedCalls = redactor.inputs.count
            let coordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
                processing: StubProcessingController(), audioArbiter: StubArbiter(),
                redactorProvider: { redactor })

            let renamed = try await coordinator.renameSpeaker(sessionID: session.id,
                speakerID: fixture.speakerA, to: "  Иван Тестов  ")
            XCTAssertEqual(renamed.speakers[0].displayName, "Иван Тестов")
            XCTAssertEqual(renamed.transcriptSegments[0].text,
                privacyEnabled ? "Врач [PERSON] просит инструкцию." : session.transcriptSegments[0].text)
            XCTAssertEqual(renamed.transcriptSegments[0].originalText, privacyEnabled ? nil : "Иван Тестов")
            XCTAssertEqual(renamed.transcriptSegments[0].start, session.transcriptSegments[0].start)
            XCTAssertEqual(renamed.transcriptSegments[0].end, session.transcriptSegments[0].end)
            XCTAssertEqual(renamed.transcriptSegments, session.transcriptSegments)

            let assigned = try await coordinator.renameSpeakers(sessionID: session.id,
                names: [fixture.speakerB: "Иван Тестов"])
            XCTAssertTrue(assigned.speakers.allSatisfy { $0.displayName == "Иван Тестов" })
            let undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
            XCTAssertEqual(undone.speakers[0].displayName, "Иван Тестов")
            XCTAssertEqual(undone.speakers[1].displayName, "Speaker B")

            // A new coordinator must read the durable alias, then preserve it through
            // another whole-session privacy publication and a transcript correction.
            let restoredCoordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
                processing: StubProcessingController(), audioArbiter: StubArbiter(),
                redactorProvider: { redactor })
            let retitled = try await restoredCoordinator.renameSession(sessionID: session.id, to: "Встреча: Иван Тестов")
            XCTAssertEqual(retitled.title, "Встреча: Иван Тестов")
            XCTAssertEqual(retitled.transcriptSegments, session.transcriptSegments)
            XCTAssertEqual(redactor.inputs.count, admittedCalls, "Metadata-only corrections and undo cannot rerun transcript NER")
            let corrected = try await restoredCoordinator.editTranscriptText(sessionID: session.id,
                segmentID: fixture.segmentID, text: "Иван Тестов просит копию.",
                expectedRevision: undone.transcriptSegments[0].revision)
            XCTAssertEqual(corrected.speakers[0].displayName, "Иван Тестов")
            XCTAssertEqual(corrected.transcriptSegments[0].text,
                privacyEnabled ? "[PERSON] просит копию." : "Иван Тестов просит копию.")
            let value = try await store.load(id: session.id)
            let saved = try XCTUnwrap(value)
            XCTAssertEqual(saved.speakers[0].displayName, "Иван Тестов")
            XCTAssertEqual(saved.transcriptSegments, corrected.transcriptSegments)
            XCTAssertTrue(MeetingTranscriptExporter.text(for: saved).contains("Иван Тестов:"))
            XCTAssertEqual(redactor.inputs.count > admittedCalls, privacyEnabled, "Actual transcript edits keep the privacy gate")
        }
    }

    func testParticipantRenameDoesNotRequireAResidentPrivacyModel() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let fixture = self.makeCorrectionSession(state: .completed)
        var session = fixture.session
        session.piiRedactionEnabled = true
        session.transcriptSegments[0].text = "[PERSON] просит копию."
        try await store.create(session)
        let coordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
            processing: StubProcessingController(), audioArbiter: StubArbiter(), redactorProvider: {
                XCTFail("Manual display metadata cannot require a loaded privacy model")
                return nil
            })
        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: fixture.speakerA, to: "Иван Тестов")
        _ = try await coordinator.renameSpeakers(sessionID: session.id, names: [fixture.speakerB: "Анна Тестова"])
        _ = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        _ = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        let retitled = try await coordinator.renameSession(sessionID: session.id, to: "Встреча: Иван Тестов")
        XCTAssertEqual(retitled.title, "Встреча: Иван Тестов")
        XCTAssertEqual(retitled.transcriptSegments, session.transcriptSegments)
    }

    func testRenameSpeakersAppliesEveryChangedNameInOneCall() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let result = try await coordinator.renameSpeakers(
            sessionID: session.id,
            names: [speakerA: "Erik", speakerB: "Maya"]
        )

        let namesByID = Dictionary(uniqueKeysWithValues: result.speakers.map { ($0.id, $0.displayName) })
        XCTAssertEqual(namesByID[speakerA], "Erik")
        XCTAssertEqual(namesByID[speakerB], "Maya")
    }

    func testRenameSpeakersSkipsBlankAndUnchangedAndNoOpsIfAllSkipped() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        // Every entry is either blank or equal to the current name: nothing should change or save.
        _ = try await coordinator.renameSpeakers(
            sessionID: session.id,
            names: [speakerA: "  ", speakerB: "Speaker B"]
        )

        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
        let reloaded = try await store.load(id: session.id)
        let namesByID = Dictionary(uniqueKeysWithValues: reloaded?.speakers.map { ($0.id, $0.displayName) } ?? [])
        XCTAssertEqual(namesByID[speakerA], "Speaker A")
        XCTAssertEqual(namesByID[speakerB], "Speaker B")
    }

    func testRenameSpeakersSkipsBlankPartiallyAndAppliesTheRest() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let result = try await coordinator.renameSpeakers(
            sessionID: session.id,
            names: [speakerA: "Erik", speakerB: ""]
        )

        let namesByID = Dictionary(uniqueKeysWithValues: result.speakers.map { ($0.id, $0.displayName) })
        XCTAssertEqual(namesByID[speakerA], "Erik")
        XCTAssertEqual(namesByID[speakerB], "Speaker B")
        XCTAssertTrue(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testUndoAfterBatchRenameRestoresAllPreviousNames() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeakers(
            sessionID: session.id,
            names: [speakerA: "Erik", speakerB: "Maya"]
        )
        let undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)

        let namesByID = Dictionary(uniqueKeysWithValues: undone.speakers.map { ($0.id, $0.displayName) })
        XCTAssertEqual(namesByID[speakerA], "Speaker A")
        XCTAssertEqual(namesByID[speakerB], "Speaker B")
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testRenameSpeakersIgnoresAMergedSpeakerInTheMap() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.mergeSpeakers(sessionID: session.id, source: speakerB, into: speakerA)

        let result = try await coordinator.renameSpeakers(
            sessionID: session.id,
            names: [speakerA: "Erik", speakerB: "ShouldBeIgnored"]
        )

        let namesByID = Dictionary(uniqueKeysWithValues: result.speakers.map { ($0.id, $0.displayName) })
        XCTAssertEqual(namesByID[speakerA], "Erik")
        XCTAssertEqual(namesByID[speakerB], "Speaker B")
    }

    func testBatchRenameThenSingleRenameThenTwoUndosRestoreInLIFOOrder() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, speakerB, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        _ = try await coordinator.renameSpeakers(
            sessionID: session.id,
            names: [speakerA: "Erik", speakerB: "Maya"]
        )
        _ = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Erik II")

        var undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        var namesByID = Dictionary(uniqueKeysWithValues: undone.speakers.map { ($0.id, $0.displayName) })
        XCTAssertEqual(namesByID[speakerA], "Erik")
        XCTAssertEqual(namesByID[speakerB], "Maya")

        undone = try await coordinator.undoTranscriptCorrection(sessionID: session.id)
        namesByID = Dictionary(uniqueKeysWithValues: undone.speakers.map { ($0.id, $0.displayName) })
        XCTAssertEqual(namesByID[speakerA], "Speaker A")
        XCTAssertEqual(namesByID[speakerB], "Speaker B")
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    // MARK: - MeetingSpeakerPalette.tintIndices

    func testTintIndicesRenamingUnknownMicPlaceholderDoesNotShiftOtherIndices() {
        let speakerA = self.makeSpeaker(name: "Speaker A")
        let placeholder = self.makeSpeaker(name: MeetingSpeakerPalette.unknownMicrophoneSpeakerName)
        let speakerC = self.makeSpeaker(name: "Speaker C")

        let before = MeetingSpeakerPalette.tintIndices(for: [speakerA, placeholder, speakerC])
        XCTAssertEqual(before[speakerA.id], 0)
        XCTAssertNil(before[placeholder.id])
        XCTAssertEqual(before[speakerC.id], 2)
        XCTAssertNil(MeetingSpeakerPalette.tints(for: [speakerA, placeholder, speakerC], isDark: false)[placeholder.id])

        var renamedPlaceholder = placeholder
        renamedPlaceholder.displayName = "Jordan"
        let after = MeetingSpeakerPalette.tintIndices(for: [speakerA, renamedPlaceholder, speakerC])
        XCTAssertEqual(after[speakerA.id], 0)
        XCTAssertEqual(after[renamedPlaceholder.id], 1)
        XCTAssertEqual(after[speakerC.id], 2)
        XCTAssertNotNil(MeetingSpeakerPalette.tints(for: [speakerA, renamedPlaceholder, speakerC], isDark: false)[renamedPlaceholder.id])
    }

    // MARK: - MeetingAssignSpeakersValidation.duplicateName

    func testDuplicateNameIgnoresACollisionTheUserDidNotCreate() {
        let first = self.makeSpeaker(name: "Speaker")
        let second = self.makeSpeaker(name: "Speaker")
        let current = [(id: first.id, displayName: first.displayName), (id: second.id, displayName: second.displayName)]

        XCTAssertNil(MeetingAssignSpeakersValidation.duplicateName(current: current, drafts: [:]))
        XCTAssertNil(
            MeetingAssignSpeakersValidation.duplicateName(
                current: current,
                drafts: [first.id: "Speaker", second.id: "   "]
            ),
            "a blank draft means leave unchanged, so the pre-existing collision must stay savable"
        )
        XCTAssertNil(
            MeetingAssignSpeakersValidation.duplicateName(
                current: current,
                drafts: [first.id: "Erik"]
            ),
            "resolving one half of a pre-existing collision must not be blocked by the other half"
        )
    }

    func testDuplicateNameFlagsACollisionTheUserCreatedRegardlessOfCaseOrPadding() {
        let first = self.makeSpeaker(name: "Erik")
        let second = self.makeSpeaker(name: "Speaker 2")
        let current = [(id: first.id, displayName: first.displayName), (id: second.id, displayName: second.displayName)]

        XCTAssertEqual(
            MeetingAssignSpeakersValidation.duplicateName(current: current, drafts: [second.id: "  erik "]),
            "erik"
        )
    }

    // MARK: - MeetingAssignSpeakersQuoteSource.sampleQuotes

    func testSampleQuotesExcludesEchoAndNonFinalOrdersByStartTimeCapsAtTwo() {
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let speakerID = SessionSpeakerID()

        func segment(
            text: String,
            startSeconds: Int64,
            status: MeetingTranscriptStatus = .final,
            isEcho: Bool = false
        ) -> MeetingTranscriptSegment {
            var segment = self.makeTranscriptSegment(sourceTrackID: track.id, speakerID: speakerID)
            segment.text = text
            segment.start = MeetingMediaTime(value: startSeconds, timescale: 1)
            segment.status = status
            segment.isLikelyEcho = isEcho
            return segment
        }

        let segments = [
            segment(text: "Third, out of order", startSeconds: 30),
            segment(text: "An echoed line", startSeconds: 5, isEcho: true),
            segment(text: "A provisional line", startSeconds: 8, status: .provisional),
            segment(text: "First thing said", startSeconds: 10),
            segment(text: "Second thing said", startSeconds: 20),
        ]

        let quotes = MeetingAssignSpeakersQuoteSource.sampleQuotes(for: speakerID, in: segments)
        XCTAssertEqual(quotes, ["First thing said", "Second thing said"])
    }

    func testSampleQuotesTruncatesLongTextOnAWordBoundary() {
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let speakerID = SessionSpeakerID()
        var segment = self.makeTranscriptSegment(sourceTrackID: track.id, speakerID: speakerID)
        segment.text = Array(repeating: "word", count: 60).joined(separator: " ")

        let quotes = MeetingAssignSpeakersQuoteSource.sampleQuotes(for: speakerID, in: [segment])
        XCTAssertEqual(quotes.count, 1)
        XCTAssertTrue(quotes[0].hasSuffix("…"))
        XCTAssertLessThanOrEqual(quotes[0].count, 181)
        XCTAssertFalse(quotes[0].dropLast().contains(" …"))
    }

    // MARK: - Audio retention & delete audio

    private func withRetentionPolicy<T>(
        _ policy: MeetingAudioRetentionPolicy,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let previous = SettingsStore.shared.meetingAudioRetentionPolicy
        SettingsStore.shared.meetingAudioRetentionPolicy = policy
        // Belt-and-suspenders: a mid-test crash still restores the developer's real setting.
        self.addTeardownBlock { SettingsStore.shared.meetingAudioRetentionPolicy = previous }
        defer { SettingsStore.shared.meetingAudioRetentionPolicy = previous }
        return try await body()
    }

    func testDeleteAudioClearsFilesAndChunksKeepsTranscriptIdempotent() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
        let checkpointURL = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        try Data("{}".utf8).write(to: checkpointURL)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let result = try await coordinator.deleteAudio(sessionID: session.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tracksURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: checkpointURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent("session.json").path))
        XCTAssertNotNil(result.retention.audioDeletedAt)
        XCTAssertTrue(result.audioTracks.allSatisfy { $0.chunks.isEmpty })
        XCTAssertFalse(result.hasRetryableAudio)
        XCTAssertEqual(result.transcriptSegments.count, session.transcriptSegments.count)

        // Idempotent: a second call is a no-op, not a throw. (The reloaded copy round-trips
        // through ISO8601 seconds-precision, so compare with a sub-second tolerance.)
        let second = try await coordinator.deleteAudio(sessionID: session.id)
        let firstDeletedAt = try XCTUnwrap(result.retention.audioDeletedAt)
        let secondDeletedAt = try XCTUnwrap(second.retention.audioDeletedAt)
        XCTAssertEqual(secondDeletedAt.timeIntervalSince1970, firstDeletedAt.timeIntervalSince1970, accuracy: 1.0)
    }

    func testSweepHealsLeftoverAudioAfterManifestFirstCrash() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))

        // Simulate the crash window: the cleared manifest was saved, but file removal never ran —
        // leave an actual leftover file behind (an empty recreated tracks/ is not a leftover).
        var cleared = session
        for index in cleared.audioTracks.indices {
            cleared.audioTracks[index].chunks = []
        }
        cleared.retention.audioDeletedAt = Date()
        try await store.save(cleared)
        try Data("leftover".utf8).write(to: tracksURL.appendingPathComponent("stray.caf", isDirectory: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.sweepExpiredAudio()

        XCTAssertFalse(FileManager.default.fileExists(atPath: tracksURL.path))
    }

    func testSweepHealsDeletedAudioWorkingStateWithoutTrackContent() async throws {
        for missingTracks in [false, true] {
            for residue in [MeetingRetainedProcessingCheckpoint.fileName,
                            MeetingRetainedProcessingCheckpoint.keyFileName,
                            ".processing-resume-\(UUID().uuidString).tmp"] {
                let dir = self.makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = MeetingSessionStore(rootDirectory: dir)
                var session = self.makeSession(state: .interrupted, endedAt: Date(),
                    audioTracks: [self.makeMicrophoneTrack(chunks: [])])
                session.retention.audioDeletedAt = Date()
                try await store.create(session)
                let directory = try await store.sessionDirectory(for: session.id)
                let tracks = directory.appendingPathComponent("tracks", isDirectory: true)
                if missingTracks { try FileManager.default.removeItem(at: tracks) }
                try Data("synthetic interrupted cleanup".utf8).write(to: directory.appendingPathComponent(residue))
                let coordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
                    processing: StubProcessingController(), audioArbiter: StubArbiter())
                await coordinator.sweepExpiredAudio()
                XCTAssertFalse(try MeetingRetainedProcessingCheckpoint.hasWorkingState(in: directory))
                let preserved = try await store.load(id: session.id)
                XCTAssertNotNil(preserved?.retention.audioDeletedAt)
            }
        }
    }

    func testSweepHealsCompletedWorkingStateWithoutDeletingRetainedAudio() async throws {
        try await self.withRetentionPolicy(.never) {
            for complete in [false, true] {
                let dir = self.makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: dir) }
                let store = MeetingSessionStore(rootDirectory: dir)
                var session = self.makeSession(state: .completed, endedAt: Date(),
                    audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])])
                session.transcriptIsComplete = complete
                try await store.create(session)
                let directory = try await store.sessionDirectory(for: session.id)
                let audio = directory.appendingPathComponent("tracks/preserved.caf")
                let audioBytes = Data("synthetic retained audio".utf8)
                try audioBytes.write(to: audio)
                for name in [MeetingRetainedProcessingCheckpoint.fileName,
                             MeetingRetainedProcessingCheckpoint.keyFileName,
                             ".processing-resume-\(UUID().uuidString).tmp"] {
                    try Data("synthetic working state".utf8).write(to: directory.appendingPathComponent(name))
                }
                let coordinator = MeetingSessionCoordinator(store: store, capture: StubCaptureController(),
                    processing: StubProcessingController(), audioArbiter: StubArbiter())
                await coordinator.sweepExpiredAudio()
                XCTAssertEqual(try MeetingRetainedProcessingCheckpoint.hasWorkingState(in: directory), !complete,
                    "An incomplete result must retain progress; a durable complete result must discard it")
                XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
                let preserved = try await store.load(id: session.id)
                XCTAssertNil(preserved?.retention.audioDeletedAt)
            }
        }
    }

    /// O9: a `tracks/` directory recreated empty by `store.save`/`sessionDirectory` is not a
    /// leftover from the manifest-first crash window and must not trigger a heal.
    func testSweepDoesNotHealAnEmptyRecreatedTracksDirectory() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)

        var cleared = session
        for index in cleared.audioTracks.indices {
            cleared.audioTracks[index].chunks = []
        }
        cleared.retention.audioDeletedAt = Date()
        try await store.save(cleared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))
        let contentsBeforeSweep = try FileManager.default.contentsOfDirectory(atPath: tracksURL.path)
        XCTAssertTrue(contentsBeforeSweep.isEmpty)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.sweepExpiredAudio()

        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path), "an empty tracks/ dir is not a leftover to heal")
    }

    func testAudioDeletedAtIsAuthoritativeAcrossLoadAndRecoverable() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .interrupted, endedAt: Date(), audioTracks: [track])
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)

        // Simulate the crash window: the cleared manifest was saved, but tracks/ removal never ran.
        var cleared = session
        for index in cleared.audioTracks.indices {
            cleared.audioTracks[index].chunks = []
        }
        cleared.retention.audioDeletedAt = Date()
        try await store.save(cleared)

        // Recreate the leftover track.json with the OLD (pre-clear) chunks — store.load's
        // reconciliation must not re-import from it once audioDeletedAt is set.
        let trackManifestDirectory = tracksURL.appendingPathComponent("microphone", isDirectory: true)
        try FileManager.default.createDirectory(at: trackManifestDirectory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(track).write(to: trackManifestDirectory.appendingPathComponent("track.json", isDirectory: false))

        let reloaded = try await store.load(id: session.id)
        XCTAssertTrue(
            reloaded?.audioTracks.allSatisfy { $0.chunks.isEmpty } == true,
            "audioDeletedAt must be authoritative: never re-import a leftover manifest's chunks"
        )

        let recoverable = try await store.loadRecoverable()
        XCTAssertFalse(
            recoverable.contains(where: { $0.id == session.id }),
            "a session with audio already deleted must never be offered as recoverable, even though it's otherwise .interrupted"
        )
    }

    func testSweepEligibilityMatrix() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let past = Date().addingTimeInterval(-8 * 24 * 60 * 60)
        let future = Date()

        let completedPast = self.makeSession(
            state: .completed,
            startedAt: past,
            endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let completedFuture = self.makeSession(
            state: .completed,
            startedAt: future,
            endedAt: future,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let interruptedUnresolvedPast = self.makeSession(
            state: .interrupted,
            startedAt: past,
            endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        let failedResolvedPast = self.makeSession(
            state: .failed,
            startedAt: past,
            endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])],
            recoveryResolvedAt: Date()
        )
        let failedUnresolvedPast = self.makeSession(
            state: .failed,
            startedAt: past,
            endedAt: past,
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        for session in [completedPast, completedFuture, interruptedUnresolvedPast, failedResolvedPast, failedUnresolvedPast] {
            try await store.create(session)
        }

        try await self.withRetentionPolicy(.days7) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()

            let reloadedCompletedPast = try await store.load(id: completedPast.id)
            let reloadedCompletedFuture = try await store.load(id: completedFuture.id)
            let reloadedInterrupted = try await store.load(id: interruptedUnresolvedPast.id)
            let reloadedFailedResolved = try await store.load(id: failedResolvedPast.id)
            let reloadedFailedUnresolved = try await store.load(id: failedUnresolvedPast.id)

            XCTAssertNotNil(reloadedCompletedPast?.retention.audioDeletedAt, "completed + past deadline must be swept")
            XCTAssertNil(reloadedCompletedFuture?.retention.audioDeletedAt, "completed + future deadline must be kept")
            XCTAssertNil(reloadedInterrupted?.retention.audioDeletedAt, "unresolved interrupted must never be swept")
            XCTAssertNotNil(reloadedFailedResolved?.retention.audioDeletedAt, "failed + resolved + past deadline must be swept")
            XCTAssertNil(reloadedFailedUnresolved?.retention.audioDeletedAt, "failed + unresolved + past deadline must never be swept")
        }
    }

    func testNeverPolicySweepsNothingAndAfterTranscriptionSweepsImmediately() async throws {
        let dir1 = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir1) }
        let store1 = MeetingSessionStore(rootDirectory: dir1)
        let veryOld = self.makeSession(
            state: .completed,
            startedAt: Date(timeIntervalSinceNow: -365 * 24 * 60 * 60),
            endedAt: Date(timeIntervalSinceNow: -365 * 24 * 60 * 60),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store1.create(veryOld)
        try await self.withRetentionPolicy(.never) {
            let coordinator = MeetingSessionCoordinator(
                store: store1, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            let reloaded = try await store1.load(id: veryOld.id)
            XCTAssertNil(reloaded?.retention.audioDeletedAt)
        }

        let dir2 = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir2) }
        let store2 = MeetingSessionStore(rootDirectory: dir2)
        let justCompleted = self.makeSession(
            state: .completed,
            startedAt: Date(),
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store2.create(justCompleted)
        try await self.withRetentionPolicy(.afterTranscription) {
            let coordinator = MeetingSessionCoordinator(
                store: store2, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            let reloaded = try await store2.load(id: justCompleted.id)
            XCTAssertNotNil(reloaded?.retention.audioDeletedAt)
        }
    }

    func testRetentionIsAppliedRetroactivelyFromCurrentPolicy() async throws {
        // 10 days old: past the 7-day deadline, still under the 30-day one.
        let endedAt = Date().addingTimeInterval(-10 * 24 * 60 * 60)
        for (policy, expectSwept) in [(MeetingAudioRetentionPolicy.days30, false), (.days7, true)] {
            let dir = self.makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let store = MeetingSessionStore(rootDirectory: dir)
            let session = self.makeSession(
                state: .completed,
                startedAt: endedAt,
                endedAt: endedAt,
                audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
            )
            try await store.create(session)

            try await self.withRetentionPolicy(policy) {
                let coordinator = MeetingSessionCoordinator(
                    store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
                )
                await coordinator.sweepExpiredAudio()
                let reloaded = try await store.load(id: session.id)
                if expectSwept {
                    XCTAssertNotNil(reloaded?.retention.audioDeletedAt, "\(policy) should sweep a 10-day-old session")
                } else {
                    XCTAssertNil(reloaded?.retention.audioDeletedAt, "\(policy) should keep a 10-day-old session")
                }
            }
        }
    }

    func testAfterTranscriptionPolicyDeletesAudioThroughRealProcessSuccessPath() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)
        let sessionDirectory = try await store.sessionDirectory(for: session.id)
        let tracksURL = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tracksURL.path))

        try await self.withRetentionPolicy(.afterTranscription) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.ensureRestored()
            let result = try await coordinator.retryProcessing()
            XCTAssertEqual(result.state, .completed)

            // process()'s success path enqueues sweepExpiredAudio as a detached Task; poll for it.
            var reloaded: MeetingSession?
            for _ in 0..<80 {
                reloaded = try await store.load(id: session.id)
                if reloaded?.retention.audioDeletedAt != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(reloaded?.retention.audioDeletedAt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: tracksURL.path))
        }
    }

    func testDeleteAudioRefusedWhileProcessing() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await store.create(session)

        let gatedProcessing = GatedProcessingController()
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: gatedProcessing, audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        let retryTask = Task { try await coordinator.retryProcessing() }

        for _ in 0..<40 {
            if case .processing = coordinator.state { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        guard case .processing = coordinator.state else {
            return XCTFail("retryProcessing did not reach .processing")
        }

        do {
            _ = try await coordinator.deleteAudio(sessionID: session.id)
            XCTFail("Expected deleteAudio to throw while processing")
        } catch let error as MeetingCoordinatorError {
            guard case .activityInProgress = error else {
                return XCTFail("Expected .activityInProgress, got \(error)")
            }
        }

        gatedProcessing.openGate()
        _ = try await retryTask.value
    }

    func testSweepPendingFlagRunsOnceTheMutationGateReleases() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        // Force the session past its retention deadline so a run of the sweep deletes its audio.
        var expired = session
        expired.startedAt = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        expired.endedAt = expired.startedAt
        try await realStore.create(expired)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        try await self.withRetentionPolicy(.days7) {
            let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: expired.id, speakerID: speakerA, to: "Held") }

            for _ in 0..<40 {
                if await recorder.events.contains("store.save.start") { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let hasSaveStarted = await recorder.events.contains("store.save.start")
            XCTAssertTrue(hasSaveStarted)

            await coordinator.sweepExpiredAudio() // gate held: must be a no-op right now, marks pending instead
            let reloadedWhileHeld = try await realStore.load(id: expired.id)
            XCTAssertNil(reloadedWhileHeld?.retention.audioDeletedAt, "the sweep must not run while the gate is held")

            await gatedStore.openGate()
            _ = try await correctionTask.value

            // The correction's gate release reschedules the pending sweep as a detached Task; poll for it.
            var reloadedAfterRelease: MeetingSession?
            for _ in 0..<80 {
                reloadedAfterRelease = try await realStore.load(id: expired.id)
                if reloadedAfterRelease?.retention.audioDeletedAt != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(reloadedAfterRelease?.retention.audioDeletedAt, "a pending sweep must run once the mutation gate is released")
        }
    }

    func testDeleteAudioLeavesSessionFailingTheFreshLoadExportGuard() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        _ = try await coordinator.deleteAudio(sessionID: session.id)

        // Mirrors MeetingTranscriptionView.exportAudio's fresh-load guard: it reloads via
        // store.load and refuses to export when either condition below holds.
        let fresh = try await store.load(id: session.id)
        let hasFinalizedAudio = (fresh?.audioTracks ?? []).flatMap(\.chunks).contains {
            $0.finalizationState == .finalized && $0.byteCount > 0
        }
        XCTAssertNotNil(fresh?.retention.audioDeletedAt)
        XCTAssertFalse(hasFinalizedAudio)
    }

    func testMeetingAudioExportKeepsMainActorAvailableDuringCopy() async throws {
        let preferences = MeetingUIPreferences()
        let source = self.makeTempDirectory()
        let destination = self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let chunk = self.makeFinalizedChunk(path: "fixture.caf")
        let bytes = Data("recorded-audio".utf8)
        let sourceFile = chunk.fileURL(relativeTo: source)
        try bytes.write(to: sourceFile)
        let session = self.makeSession(state: .completed, audioTracks: [self.makeMicrophoneTrack(chunks: [chunk])])
        let started = self.expectation(description: "copy started on worker")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let export = Task {
            try await MeetingTranscriptionView.exportAudioFiles(of: session, from: source, into: destination) { from, to in
                XCTAssertFalse(Thread.isMainThread, "Copying meeting audio must not block the UI thread")
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        await self.fulfillment(of: [started], timeout: 2)
        // Reaching the main actor while the worker is held proves UI actions can still run.
        MainActor.assertIsolated()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Test").path), "Do not publish a partially copied export")
        release.signal()
        try await export.value
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Test/microphone-000.caf")), bytes)
        XCTAssertEqual(try Data(contentsOf: sourceFile), bytes, "Export must not alter the recording")
        XCTAssertEqual(MeetingUIPreferences(), preferences, "Export must not change capture or retention settings")
    }

    func testMeetingAudioExportRemovesStagingAfterCopyFailure() async throws {
        let source = self.makeTempDirectory()
        let destination = self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let chunk = self.makeFinalizedChunk(path: "fixture.caf")
        let session = self.makeSession(state: .completed, audioTracks: [self.makeMicrophoneTrack(chunks: [chunk])])
        do {
            try await MeetingTranscriptionView.exportAudioFiles(of: session, from: source, into: destination) { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("Copy errors must reach the UI caller")
        } catch let error as CocoaError {
            XCTAssertEqual(error.code, .fileWriteNoPermission)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [], "Failed export must not leave partial files")
    }

    func testMeetingAudioExportRepeatedRequestsPreserveExistingExportAndSource() async throws {
        let source = self.makeTempDirectory()
        let destination = self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let chunk = self.makeFinalizedChunk(path: "fixture.caf")
        let sourceFile = chunk.fileURL(relativeTo: source)
        let first = Data("first-recording".utf8)
        let second = Data("second-recording".utf8)
        let session = self.makeSession(state: .completed, audioTracks: [self.makeMicrophoneTrack(chunks: [chunk])])
        try first.write(to: sourceFile)
        try await MeetingTranscriptionView.exportAudioFiles(of: session, from: source, into: destination)
        try second.write(to: sourceFile)
        try await MeetingTranscriptionView.exportAudioFiles(of: session, from: source, into: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Test/microphone-000.caf")), first)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Test 2/microphone-000.caf")), second)
        XCTAssertEqual(try Data(contentsOf: sourceFile), second)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: destination.path)), ["Test", "Test 2"])
    }

    func testMeetingAudioExportConcurrentRequestsPreserveEveryExport() async throws {
        let source = self.makeTempDirectory()
        let destination = self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let chunk = self.makeFinalizedChunk(path: "fixture.caf")
        let sourceFile = chunk.fileURL(relativeTo: source)
        let bytes = Data("recorded-audio".utf8)
        try bytes.write(to: sourceFile)
        let session = self.makeSession(state: .completed, audioTracks: [self.makeMicrophoneTrack(chunks: [chunk])])
        let started = self.expectation(description: "first export copying")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let first = Task {
            try await MeetingTranscriptionView.exportAudioFiles(of: session, from: source, into: destination) { from, to in
                started.fulfill()
                guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        await self.fulfillment(of: [started], timeout: 2)
        let queued = self.expectation(description: "three more exports requested while first is copying")
        queued.expectedFulfillmentCount = 3
        let following = (0..<3).map { _ in
            Task {
                queued.fulfill()
                try await MeetingTranscriptionView.exportAudioFiles(of: session, from: source, into: destination)
            }
        }
        await self.fulfillment(of: [queued], timeout: 2)
        release.signal()
        try await first.value
        for task in following {
            try await task.value
        }
        let names = ["Test", "Test 2", "Test 3", "Test 4"]
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: destination.path)), Set(names))
        for name in names {
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("\(name)/microphone-000.caf")), bytes)
        }
        XCTAssertEqual(try Data(contentsOf: sourceFile), bytes, "Concurrent exports must leave the recording intact")
    }

    func testMeetingAudioExportDeletionDuringCopyRemovesPartialExport() async throws {
        let source = self.makeTempDirectory()
        let destination = self.makeTempDirectory()
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: destination)
        }
        let chunks = [self.makeFinalizedChunk(path: "first.caf"), self.makeFinalizedChunk(sequence: 1, path: "second.caf")]
        for chunk in chunks {
            try Data("recorded-audio".utf8).write(to: chunk.fileURL(relativeTo: source))
        }
        let session = self.makeSession(state: .completed, audioTracks: [self.makeMicrophoneTrack(chunks: chunks)])
        let started = self.expectation(description: "first chunk copied, second chunk waiting")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let export = Task {
            try await MeetingTranscriptionView.exportAudioFiles(of: session, from: source, into: destination) { from, to in
                if from.lastPathComponent == "second.caf" {
                    started.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
                }
                try FileManager.default.copyItem(at: from, to: to)
            }
        }
        await self.fulfillment(of: [started], timeout: 2)
        try FileManager.default.removeItem(at: source)
        release.signal()
        do {
            try await export.value
            XCTFail("A source deleted during export must report failure")
        } catch {
            XCTAssertTrue(error is CocoaError)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [], "The earlier copied chunk must not survive as a partial export")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "Export must not recreate deleted source audio")
    }

    // MARK: - ASR activity arbiter

    func testPermissionPreflightCompletesBeforeMeetingLeaseAcquisition() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let arbiter = StubArbiter()
        var continuation: CheckedContinuation<Void, Never>?
        let preflightReached = self.expectation(description: "preflight suspended")
        capture.onPreflight = {
            await withCheckedContinuation {
                continuation = $0
                preflightReached.fulfill()
            }
        }
        let coordinator = MeetingSessionCoordinator(
            store: MeetingSessionStore(rootDirectory: dir),
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: arbiter
        )

        let start = Task { try await coordinator.startRecording(configuration: self.makeConfiguration()) }
        await self.fulfillment(of: [preflightReached], timeout: 2)
        XCTAssertEqual(arbiter.acquireCount, 0, "permission prompt must not hold the meeting audio lease")

        continuation?.resume()
        _ = try await start.value
        XCTAssertEqual(arbiter.acquireCount, 1)
    }

    func testModelChangedDuringAdmittedDependencyPreparationRollsBackBeforeCapture() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        let previousBackend = settings.meetingTranscriptionBackendID
        defer { settings.selectedSpeechModel = previous; settings.meetingTranscriptionBackendID = previousBackend }
        settings.selectedSpeechModel = .parakeetTDT
        settings.meetingTranscriptionBackendID = .productionDefault
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter,
            prepareRecordingDependencies: { dependencies in
                XCTAssertEqual(dependencies, [.speakerSeparation, .voiceMatching])
                if arbiter.acquireCount > 0 { settings.selectedSpeechModel = .gigaam }
            })
        var configuration = self.makeConfiguration()
        configuration.languageCode = "en"
        do {
            _ = try await coordinator.startRecording(configuration: configuration)
            XCTFail("A changed admitted model must not be published")
        } catch is CancellationError { }
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(arbiter.acquireCount, 1)
        XCTAssertEqual(arbiter.releaseCount, 1)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(coordinator.isQuiescent)
    }

    func testCancellationDuringAdmittedDependencyPreparationJoinsBeforeLeaseRelease() async throws {
        let settings = SettingsStore.shared
        let previous = settings.selectedSpeechModel
        let previousBackend = settings.meetingTranscriptionBackendID
        defer { settings.selectedSpeechModel = previous; settings.meetingTranscriptionBackendID = previousBackend }
        settings.selectedSpeechModel = .parakeetTDT
        settings.meetingTranscriptionBackendID = .productionDefault
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let capture = StubCaptureController()
        let arbiter = StubArbiter()
        let gate = PermissionPreflightGate()
        let reached = self.expectation(description: "admitted preparation waiting")
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter,
            prepareRecordingDependencies: { _ in
                if arbiter.acquireCount > 0 { reached.fulfill(); await gate.wait() }
            })
        var configuration = self.makeConfiguration()
        configuration.languageCode = "en"
        let task = Task { try await coordinator.startRecording(configuration: configuration) }
        await self.fulfillment(of: [reached], timeout: 2)
        task.cancel()
        XCTAssertEqual(arbiter.releaseCount, 0, "Noncooperative dependency work still owns admission")
        await gate.open()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError { }
        XCTAssertEqual(arbiter.releaseCount, 1)
        XCTAssertEqual(capture.startCount, 0)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testModelChangedDuringPermissionPromptIsValidatedBeforeCaptureAllocation() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = originalModel }
        settings.selectedSpeechModel = .parakeetTDT
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let arbiter = StubArbiter()
        let gate = PermissionPreflightGate()
        let preflightReached = self.expectation(description: "permission prompt suspended")
        capture.onPreflight = {
            preflightReached.fulfill()
            await gate.wait()
        }
        let store = MeetingSessionStore(rootDirectory: dir)
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter
        )
        self.addTeardownBlock { @MainActor in
            await gate.open()
            await coordinator.shutdownForTermination()
        }
        var configuration = self.makeConfiguration()
        configuration.languageCode = "en"
        let start = Task { try await coordinator.startRecording(configuration: configuration) }
        await self.fulfillment(of: [preflightReached], timeout: 2)
        XCTAssertEqual(arbiter.acquireCount, 0)
        settings.selectedSpeechModel = .gigaam
        await gate.open()
        do {
            _ = try await start.value
            XCTFail("The prepared model cannot be replaced while its permission prompt is open")
        } catch is CancellationError { }
        XCTAssertEqual(arbiter.acquireCount, 0)
        XCTAssertEqual(arbiter.releaseCount, 0, "Changed preparation must stop before acquiring capture")
        XCTAssertEqual(capture.startCount, 0, "Capture and captions cannot start with the stale preflight model")
        XCTAssertEqual(coordinator.liveTranscript, .empty)
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(coordinator.isQuiescent)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty, "No invalid session may be persisted before final configuration validation")
    }

    func testFrozenHostCapabilitiesRejectModelChangedDuringIntelPermissionPrompt() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = originalModel }
        settings.selectedSpeechModel = .gigaam
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = StubCaptureController()
        capture.startResult = MeetingCaptureStartResult(tracks: [self.makeMicrophoneTrack(chunks: [])], firstPresentationTime: nil)
        let arbiter = StubArbiter()
        let gate = PermissionPreflightGate()
        let preflightReached = self.expectation(description: "Intel permission prompt suspended")
        capture.onPreflight = {
            preflightReached.fulfill()
            await gate.wait()
        }
        let store = MeetingSessionStore(rootDirectory: dir)
        var frozenConfigurations: [MeetingFinalProcessingConfiguration] = []
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter,
            validateFrozenRecordingConfiguration: { configuration in
                frozenConfigurations.append(configuration)
                try PichiMeetingProviderFactory.validateRecordingConfiguration(configuration, isAppleSilicon: false)
            }
        )
        self.addTeardownBlock { @MainActor in
            await gate.open()
            await coordinator.shutdownForTermination()
        }
        var configuration = self.makeConfiguration()
        configuration.languageCode = "ru"
        let start = Task { try await coordinator.startRecording(configuration: configuration) }
        await self.fulfillment(of: [preflightReached], timeout: 2)
        XCTAssertEqual(arbiter.acquireCount, 0)
        settings.selectedSpeechModel = .parakeetTDT
        await gate.open()
        do {
            _ = try await start.value
            XCTFail("The chosen model cannot change between preparation and capture")
        } catch is CancellationError { }
        XCTAssertTrue(frozenConfigurations.isEmpty)
        XCTAssertEqual(arbiter.acquireCount, 0)
        XCTAssertEqual(arbiter.releaseCount, 0)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertEqual(coordinator.liveTranscript, .empty)
        XCTAssertTrue(coordinator.isQuiescent)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testFrozenHostCapabilitiesStillRejectPreparedModelBeforeCapture() async throws {
        let settings = SettingsStore.shared
        let originalModel = settings.selectedSpeechModel
        defer { settings.selectedSpeechModel = originalModel }
        settings.selectedSpeechModel = .parakeetTDT
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = StubCaptureController()
        let arbiter = StubArbiter()
        let store = MeetingSessionStore(rootDirectory: dir)
        let coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: StubProcessingController(), audioArbiter: arbiter,
            validateFrozenRecordingConfiguration: { try PichiMeetingProviderFactory.validateRecordingConfiguration($0, isAppleSilicon: false) })
        var configuration = self.makeConfiguration()
        configuration.languageCode = "ru"
        do { _ = try await coordinator.startRecording(configuration: configuration); XCTFail("Unsupported frozen hardware must reject capture") }
        catch { XCTAssertEqual(error as? MeetingProviderOptionsError, .unsupportedArchitecture) }
        XCTAssertEqual(arbiter.acquireCount, 1)
        XCTAssertEqual(arbiter.releaseCount, 1)
        XCTAssertEqual(capture.startCount, 0)
        let sessions = try await store.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testDeniedPermissionNeverAcquiresMeetingLease() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let capture = StubCaptureController()
        capture.preflightError = MeetingCaptureError.microphonePermissionDenied
        let arbiter = StubArbiter()
        let coordinator = MeetingSessionCoordinator(
            store: MeetingSessionStore(rootDirectory: dir),
            capture: capture,
            processing: StubProcessingController(),
            audioArbiter: arbiter
        )

        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration())
            XCTFail("denied microphone permission must fail before audio ownership")
        } catch {
            guard case MeetingCaptureError.microphonePermissionDenied = error else {
                return XCTFail("Expected microphonePermissionDenied, got \(error)")
            }
        }
        XCTAssertEqual(arbiter.acquireCount, 0)
        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(coordinator.state, .idle)
    }

    func testArbiterDoubleAcquireThrowsRecordingAlreadyActive() async throws {
        let leasing = FakeASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }

        _ = try await arbiter.acquireMeetingCapture()
        do {
            _ = try await arbiter.acquireMeetingCapture()
            XCTFail("Expected .recordingAlreadyActive")
        } catch {
            guard case MeetingCoordinatorError.recordingAlreadyActive = error else {
                return XCTFail("Expected .recordingAlreadyActive, got \(error)")
            }
        }
        XCTAssertEqual(leasing.acquireCount, 1)
        XCTAssertEqual(leasing.prepareCount, 1)
    }

    func testArbiterRejectsSecondAcquireWhileFirstHandoffIsSuspended() async throws {
        let leasing = SuspendedHandoffASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }
        let firstAcquire = Task { try await arbiter.acquireMeetingCapture() }

        while leasing.prepareStarted == false {
            await Task.yield()
        }
        do {
            _ = try await arbiter.acquireMeetingCapture()
            XCTFail("Expected the published preparing lease to reject re-entrant acquisition")
        } catch {
            guard case MeetingCoordinatorError.recordingAlreadyActive = error else {
                return XCTFail("Expected .recordingAlreadyActive, got \(error)")
            }
        }

        leasing.resumePrepare()
        let lease = try await firstAcquire.value
        await arbiter.release(lease)
        XCTAssertEqual(leasing.handbackCount, 1)
    }

    func testCancelledSuspendedHandoffRollsBackBeforeReturningLease() async throws {
        let leasing = SuspendedHandoffASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }
        let acquire = Task { try await arbiter.acquireMeetingCapture() }

        while leasing.prepareStarted == false {
            await Task.yield()
        }
        acquire.cancel()
        leasing.resumePrepare()

        do {
            _ = try await acquire.value
            XCTFail("Canceled handoff must not return a usable meeting lease")
        } catch is CancellationError {}
        XCTAssertEqual(leasing.handbackCount, 1)

        let replacement = try await arbiter.acquireMeetingCapture()
        await arbiter.release(replacement)
    }

    func testArbiterReleaseThenReacquireSucceeds() async throws {
        let leasing = FakeASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }

        let lease = try await arbiter.acquireMeetingCapture()
        await arbiter.release(lease)
        XCTAssertEqual(leasing.releaseCount, 1)
        XCTAssertEqual(leasing.handbackCount, 1)

        let reacquired = try await arbiter.acquireMeetingCapture()
        XCTAssertNotEqual(lease, reacquired)
        XCTAssertEqual(leasing.acquireCount, 2)
    }

    func testConcurrentDuplicateReleaseCoalescesUntilHandbackCompletes() async throws {
        let leasing = SuspendedHandbackASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }
        let lease = try await arbiter.acquireMeetingCapture()

        let firstRelease = Task { await arbiter.release(lease) }
        while leasing.handbackStarted == false {
            await Task.yield()
        }
        let duplicateRelease = Task { await arbiter.release(lease) }
        await Task.yield()

        XCTAssertEqual(leasing.handbackCount, 1, "duplicate release must await the retained handback")
        do {
            _ = try await arbiter.acquireMeetingCapture()
            XCTFail("meeting ownership must remain published until handback finishes")
        } catch {
            guard case MeetingCoordinatorError.recordingAlreadyActive = error else {
                return XCTFail("Expected .recordingAlreadyActive, got \(error)")
            }
        }

        leasing.resumeHandback()
        await firstRelease.value
        await duplicateRelease.value
        XCTAssertEqual(leasing.handbackCount, 1)

        let replacement = try await arbiter.acquireMeetingCapture()
        await arbiter.release(replacement)
    }

    func testArbiterReleaseWithStaleLeaseIsNoOp() async throws {
        let leasing = FakeASRActivityLeasing()
        let arbiter = AudioActivityArbiter { leasing }

        let lease = try await arbiter.acquireMeetingCapture()
        await arbiter.release(MeetingAudioActivityLease(id: UUID())) // stale, not the held lease
        XCTAssertEqual(leasing.releaseCount, 0, "a stale lease must not release the real ASR activity")

        await arbiter.release(lease)
        XCTAssertEqual(leasing.releaseCount, 1)
    }

    func testArbiterProviderThrowingLeavesCoordinatorStateUntouched() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let arbiter = AudioActivityArbiter { throw MeetingCoordinatorError.dictationActive }
        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: arbiter
        )

        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Blocked"))
            XCTFail("Expected startRecording to throw when the ASR provider is unavailable")
        } catch {}

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(coordinator.state, .idle)
    }

    // MARK: - Final-review regressions (O1/O2/O3/O4/O5/O10)

    /// O1: `resetForNewMeeting` enqueues a fire-and-forget save stamping `recoveryResolvedAt`;
    /// a sweep that races it must flush that queued write before reading sessions from disk, or
    /// it sees the pre-stamp copy and skips a session that's actually eligible.
    func testSweepFlushesQueuedPersistenceBeforeReadingSessionsOnDisk() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .interrupted, endedAt: Date(timeIntervalSinceNow: -10), audioTracks: [track])
        try await realStore.create(session)

        try await self.withRetentionPolicy(.afterTranscription) {
            let recorder = EventRecorder()
            let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
            let coordinator = MeetingSessionCoordinator(
                store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.ensureRestored()
            XCTAssertEqual(coordinator.activeSession?.id, session.id)

            await gatedStore.closeGate()
            let saveCountBeforeReset = await recorder.events.filter { $0 == "store.save.start" }.count
            // Enqueues the recoveryResolvedAt stamp (parked at the gate) and schedules a sweep.
            try coordinator.resetForNewMeeting()

            for _ in 0..<40 {
                let count = await recorder.events.filter { $0 == "store.save.start" }.count
                if count > saveCountBeforeReset { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            await gatedStore.openGate()

            var persisted: MeetingSession?
            for _ in 0..<60 {
                persisted = try await realStore.load(id: session.id)
                if persisted?.retention.audioDeletedAt != nil { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            XCTAssertNotNil(persisted?.recoveryResolvedAt, "the queued stamp must have landed")
            XCTAssertNotNil(persisted?.retention.audioDeletedAt, "the sweep must have seen the stamped copy, not a stale one")
            XCTAssertTrue(persisted?.audioTracks.allSatisfy { $0.chunks.isEmpty } ?? false)
        }
    }

    /// O3: when the mutation gate (not real capture/stop/retry activity) is the only blocker,
    /// startRecording must surface the more honest `.maintenanceInProgress`.
    func testStartRecordingThrowsMaintenanceInProgressWhileGateHeld() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let correctionTask = Task { try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }
        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        do {
            _ = try await coordinator.startRecording(configuration: self.makeConfiguration(title: "Blocked"))
            XCTFail("Expected startRecording to throw while the mutation gate is held")
        } catch let error as MeetingCoordinatorError {
            guard case .maintenanceInProgress = error else {
                return XCTFail("Expected .maintenanceInProgress, got \(error)")
            }
        }

        await gatedStore.openGate()
        _ = try await correctionTask.value
    }

    /// O2: termination must not spin forever behind a parked correction/audio-mutation save;
    /// it waits a bounded amount of time and then proceeds regardless.
    func testShutdownForTerminationCompletesWhileCorrectionIsParked() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let correctionTask = Task { try? await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: "Held") }
        for _ in 0..<40 {
            if await recorder.events.contains("store.save.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        // The gate never opens here; returning at all (instead of hanging) is the assertion.
        await coordinator.shutdownForTermination()

        await gatedStore.openGate()
        _ = try? await correctionTask.value
    }

    /// O10: the retention timer is scheduled when a future deadline exists and cleared otherwise.
    func testHasScheduledRetentionSweepReflectsTimerState() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let track = self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])
        let session = self.makeSession(state: .completed, endedAt: Date(), audioTracks: [track])
        try await store.create(session)

        try await self.withRetentionPolicy(.days7) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            XCTAssertTrue(coordinator.hasScheduledRetentionSweep, "a 7-day deadline is in the future and should be scheduled")
        }

        try await self.withRetentionPolicy(.never) {
            let coordinator = MeetingSessionCoordinator(
                store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
            )
            await coordinator.sweepExpiredAudio()
            XCTAssertFalse(coordinator.hasScheduledRetentionSweep, "policy .never has no deadline to schedule against")
        }
    }

    /// A contended past-deadline session must re-arm within 60s instead of being skipped forever.
    /// Caught mid-`retryProcessing`: the sweep reads disk state (`.completed`, eligible) while
    /// `isSafeToSweep` reads in-memory state (`.processing`, contended) — the race the re-arm exists for.
    func testContendedSweepPastDeadlineSessionReArmsWithinSixtySeconds() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        var (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        session.startedAt = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        session.endedAt = session.startedAt
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedThrowingSaveStore(inner: realStore, recorder: recorder)
        await gatedStore.closeGate()
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()

        try await self.withRetentionPolicy(.days7) {
            let retryTask = Task { try await coordinator.retryProcessing(sessionID: session.id) }

            for _ in 0..<40 {
                if await recorder.events.contains("store.save.start") { break }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            let eventsSoFar = await recorder.events
            XCTAssertTrue(eventsSoFar.contains("store.save.start"))
            guard case .processing = coordinator.state else {
                await gatedStore.openGate()
                _ = try? await retryTask.value
                return XCTFail("retryProcessing did not reach .processing before its save landed")
            }

            await coordinator.sweepExpiredAudio()
            let reloaded = try await realStore.load(id: session.id)
            XCTAssertNil(reloaded?.retention.audioDeletedAt, "a contended session must not be swept")
            XCTAssertTrue(coordinator.hasScheduledRetentionSweep, "a contended past-deadline session must re-arm a retry")

            await gatedStore.openGate()
            _ = try await retryTask.value
        }
    }

    /// deleteSession racing shutdownForTermination must never resurrect the session as an
    /// interrupted offer: delete wins, coordinator settles at `.idle`, session gone from disk.
    func testDeleteVersusTerminationLeavesNoResurrectionAndSettlesAtIdle() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let realStore = MeetingSessionStore(rootDirectory: dir)
        let session = self.makeSession(
            state: .interrupted,
            endedAt: Date(),
            audioTracks: [self.makeMicrophoneTrack(chunks: [self.makeFinalizedChunk()])]
        )
        try await realStore.create(session)

        let recorder = EventRecorder()
        let gatedStore = GatedDeleteStore(inner: realStore, recorder: recorder)
        let coordinator = MeetingSessionCoordinator(
            store: gatedStore, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        await coordinator.ensureRestored()
        XCTAssertEqual(coordinator.activeSession?.id, session.id)

        let deleteTask = Task { try await coordinator.deleteSession(id: session.id) }
        for _ in 0..<40 {
            if await recorder.events.contains("store.delete.start") { break }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let eventsSoFar = await recorder.events
        XCTAssertTrue(eventsSoFar.contains("store.delete.start"))

        // Returns promptly mid-delete: it waits on isMutatingSession, not isDeleting.
        await coordinator.shutdownForTermination()

        await gatedStore.openGate()
        try await deleteTask.value

        XCTAssertNil(coordinator.activeSession)
        XCTAssertEqual(coordinator.state, .idle)
        let reloaded = try? await realStore.load(id: session.id)
        XCTAssertNil(reloaded, "deleteSession must have the final say; termination must not resurrect it")
    }

    /// O5: renaming a speaker to its current name must be a true no-op — no save, no undo entry.
    func testNoOpRenameDoesNotPushUndoOrTouchStore() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, speakerA, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let before = try await store.load(id: session.id)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )
        let currentName = try XCTUnwrap(before?.speakers.first(where: { $0.id == speakerA })?.displayName)

        let result = try await coordinator.renameSpeaker(sessionID: session.id, speakerID: speakerA, to: currentName)
        XCTAssertEqual(result, before)
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))

        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded, before)
    }

    // MARK: - Default meeting title

    func testDefaultTitleUsesApplicationName() {
        let title = MeetingTranscriptionSetupDraft.defaultTitle(mode: .onlineCall, applicationDisplayName: "Zoom")
        XCTAssertEqual(title, "Zoom call")
        let meetTitle = MeetingTranscriptionSetupDraft.defaultTitle(mode: .onlineCall, applicationDisplayName: "Google Meet")
        XCTAssertEqual(meetTitle, "Google Meet call")
    }

    func testDefaultTitleForInRoomIgnoresApplicationName() {
        XCTAssertEqual(
            MeetingTranscriptionSetupDraft.defaultTitle(mode: .inRoom, applicationDisplayName: "Zoom"),
            "In-room meeting"
        )
        XCTAssertEqual(
            MeetingTranscriptionSetupDraft.defaultTitle(mode: .inRoom, applicationDisplayName: nil),
            "In-room meeting"
        )
    }

    func testDefaultTitleFallsBackWhenNoApplicationSelected() {
        XCTAssertEqual(MeetingTranscriptionSetupDraft.defaultTitle(mode: .onlineCall, applicationDisplayName: nil), "Meeting")
    }

    func testAutomaticMeetingTitleUsesRecordingStartAndPreservesCustomNames() throws {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 1, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom,
            title: "Meeting",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture"),
            timestampDefaultTitle: true
        )
        let first = MeetingSession(configuration: configuration, startedAt: startedAt, timebase: timebase)
        let later = MeetingSession(configuration: configuration, startedAt: startedAt.addingTimeInterval(3600), timebase: timebase)
        XCTAssertTrue(first.title.hasPrefix("Meeting · "))
        XCTAssertNotEqual(first.title, later.title)
        XCTAssertEqual(first.defaultTitleBase, "Meeting")
        XCTAssertEqual(first.startedAt, startedAt)
        XCTAssertEqual(first.selectedMicrophone, configuration.microphone)
        var custom = configuration
        custom.title = "Weekly planning"
        custom.timestampDefaultTitle = false
        let named = MeetingSession(configuration: custom, startedAt: startedAt, timebase: timebase)
        XCTAssertEqual(named.title, "Weekly planning")
        XCTAssertNil(named.defaultTitleBase)
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(restored.title, first.title)
        XCTAssertEqual(restored.defaultTitleBase, "Meeting")
    }

    func testOldMeetingWithoutAutomaticTitleMetadataKeepsItsTitle() throws {
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        json.removeValue(forKey: "defaultTitleBase")
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.title, session.title)
        XCTAssertNil(restored.defaultTitleBase)
    }

    // MARK: - Rename session

    func testRenameSessionRejectsEmptyOrWhitespaceTitle() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        for invalidTitle in ["", "   ", "\n\t"] {
            await XCTAssertThrowsErrorAsync(
                try await coordinator.renameSession(sessionID: session.id, to: invalidTitle)
            ) { error in
                XCTAssertEqual(error as? MeetingDomainError, .emptyMeetingTitle)
            }
        }

        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.title, session.title)
    }

    func testRenameSessionTrimsAndPersistsWithoutTouchingUndoStack() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        var (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        session.defaultTitleBase = "Meeting"
        try await store.create(session)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let renamed = try await coordinator.renameSession(sessionID: session.id, to: "  Weekly Sync  ")
        XCTAssertEqual(renamed.title, "Weekly Sync")
        XCTAssertNil(renamed.defaultTitleBase)

        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded?.title, "Weekly Sync")
        XCTAssertNil(reloaded?.defaultTitleBase)
        // A title rename must not consume the transcript-correction undo stack.
        XCTAssertFalse(coordinator.canUndoCorrection(sessionID: session.id))
    }

    func testRenameSessionNoOpWhenTitleIsIdentical() async throws {
        let dir = self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MeetingSessionStore(rootDirectory: dir)
        let (session, _, _, _) = self.makeCorrectionSession(state: .completed)
        try await store.create(session)
        let before = try await store.load(id: session.id)

        let coordinator = MeetingSessionCoordinator(
            store: store, capture: StubCaptureController(), processing: StubProcessingController(), audioArbiter: StubArbiter()
        )

        let result = try await coordinator.renameSession(sessionID: session.id, to: session.title)
        XCTAssertEqual(result, before)
        let reloaded = try await store.load(id: session.id)
        XCTAssertEqual(reloaded, before)
    }
}

/// XCTAssertThrowsError has no async overload; this bridges an async throwing expression.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected an error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}

// MARK: - Test doubles

private final class ThrowingDirectoryStore: MeetingSessionStoring, @unchecked Sendable {
    private let wrapped: MeetingSessionStore
    var throwOnSessionDirectory = true

    init(wrapping wrapped: MeetingSessionStore) { self.wrapped = wrapped }

    func create(_ session: MeetingSession) async throws { try await self.wrapped.create(session) }
    func save(_ session: MeetingSession) async throws { try await self.wrapped.save(session) }
    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.wrapped.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.wrapped.loadAll() }
    func loadRecoverable() async throws -> [MeetingSession] { try await self.wrapped.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL {
        if self.throwOnSessionDirectory { throw CocoaError(.fileWriteNoPermission) }
        return try await self.wrapped.sessionDirectory(for: id)
    }

    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.wrapped.existingSessionDirectory(for: id)
    }

    func delete(id: MeetingSessionID) async throws { try await self.wrapped.delete(id: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.wrapped.deleteAudioFiles(for: id) }
}

private actor PermissionPreflightGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
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

private actor EventRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { self.events.append(event) }
}

private final class StubCaptureController: MeetingCaptureControlling, @unchecked Sendable {
    var startResult = MeetingCaptureStartResult(tracks: [], firstPresentationTime: nil)
    var startError: Error?
    var startupEvents: [MeetingCaptureEvent] = []
    var onStart: (@Sendable () async -> Void)?
    var onStop: (@Sendable () async throws -> Void)?
    var stopResult: MeetingCaptureStopResult?
    var stopError: Error?
    var preflightError: Error?
    var onPreflight: (@Sendable () async -> Void)?
    private(set) var preflightCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var eventHandler: (@Sendable (MeetingCaptureEvent) -> Void)?

    func emit(_ event: MeetingCaptureEvent) { self.eventHandler?(event) }

    func preflightPermissions() async throws {
        self.preflightCount += 1
        await self.onPreflight?()
        if let preflightError { throw preflightError }
    }

    func start(
        session: MeetingSession,
        configuration: MeetingCaptureConfiguration,
        sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?
    ) async throws -> MeetingCaptureStartResult {
        self.startCount += 1
        self.eventHandler = eventHandler
        for event in self.startupEvents {
            eventHandler(event)
        }
        await self.onStart?()
        if let startError { throw startError }
        return self.startResult
    }

    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        self.stopCount += 1
        try await self.onStop?()
        if let stopError { throw stopError }
        return self.stopResult ?? MeetingCaptureStopResult(tracks: [], stoppedAt: Date())
    }

    func shutdownForTermination() async {}
}

@MainActor
private final class StubProcessingController: MeetingProcessingControlling {
    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        MeetingProcessingResult(
            speakers: [],
            segments: [],
            attempt: MeetingProcessingAttempt(
                id: UUID(),
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )
    }
}

@MainActor
private final class RestartCheckingProcessingController: MeetingProcessingControlling {
    var sawCleanWorkingState = false
    func process(session: MeetingSession, sessionDirectory: URL,
                 progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingProcessingResult {
        self.sawCleanWorkingState = [MeetingRetainedProcessingCheckpoint.fileName, MeetingRetainedProcessingCheckpoint.keyFileName, "checkpoint.json"]
            .allSatisfy { !FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent($0).path) }
        return try await StubProcessingController().process(session: session, sessionDirectory: sessionDirectory, progress: progress)
    }
}

@MainActor
private final class DiagnosticFailingProcessingController: MeetingProcessingControlling {
    private let error: Error
    private var lastProgress: (@MainActor (MeetingProcessingStage) -> Void)?

    init(error: Error) { self.error = error }

    func emitLateProgress(_ stage: MeetingProcessingStage) { self.lastProgress?(stage) }

    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        self.lastProgress = progress
        progress(.identifyingSpeakers)
        progress(.transcribing)
        throw self.error
    }
}

private struct ProcessingFailure: Error {}

@MainActor
private final class ThrowingProcessingController: MeetingProcessingControlling {
    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        throw ProcessingFailure()
    }
}

@MainActor
private final class SkippedChunkProcessingController: MeetingProcessingControlling {
    private let skippedChunkIDs: [MeetingAudioChunkID]

    init(skippedChunkIDs: [MeetingAudioChunkID]) {
        self.skippedChunkIDs = skippedChunkIDs
    }

    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        MeetingProcessingResult(
            speakers: [],
            segments: [],
            attempt: MeetingProcessingAttempt(
                id: UUID(),
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            ),
            skippedChunkIDs: self.skippedChunkIDs
        )
    }
}

/// Blocks `process(...)` until `openGate()` is called, so tests can inspect mid-flight state.
@MainActor
private final class GatedProcessingController: MeetingProcessingControlling {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func openGate() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func process(
        session: MeetingSession,
        sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingProcessingResult {
        // Mirrors the real pipeline's convention of reusing the still-open attempt's id.
        let attemptID = session.processingAttempts.last(where: { $0.completedAt == nil })?.id ?? UUID()
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        return MeetingProcessingResult(
            speakers: [],
            segments: [],
            attempt: MeetingProcessingAttempt(
                id: attemptID,
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: nil,
                asrModel: nil,
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )
    }
}

@MainActor
private final class StubArbiter: MeetingAudioActivityArbitrating {
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    func acquireMeetingCapture() async throws -> MeetingAudioActivityLease {
        self.acquireCount += 1
        return MeetingAudioActivityLease(id: UUID())
    }

    func release(_ lease: MeetingAudioActivityLease) async { self.releaseCount += 1 }
}

/// Records acquire/release calls without touching a real ASRService.
@MainActor
private final class FakeASRActivityLeasing: ASRActivityLeasing {
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var prepareCount = 0
    private(set) var handbackCount = 0
    private var activeLease: ASRActivityLease?

    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        self.acquireCount += 1
        guard self.activeLease == nil else {
            throw ASRActivityError.activityInProgress(activity)
        }
        let lease = ASRActivityLease(id: UUID(), activity: activity)
        self.activeLease = lease
        return lease
    }

    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        guard self.activeLease == lease else { return }
        self.releaseCount += 1
        self.activeLease = nil
    }

    func prepareMeetingAudioHandoff(_ lease: ASRActivityLease) async throws {
        self.prepareCount += 1
    }

    func completeMeetingAudioHandback(_ lease: ASRActivityLease) async {
        self.handbackCount += 1
        self.releaseExclusiveActivity(lease)
    }
}

@MainActor
private final class SuspendedHandoffASRActivityLeasing: ASRActivityLeasing {
    private(set) var prepareStarted = false
    private(set) var handbackCount = 0
    private var activeLease: ASRActivityLease?
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var prepareInvocationCount = 0

    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        guard self.activeLease == nil else { throw ASRActivityError.activityInProgress(activity) }
        let lease = ASRActivityLease(id: UUID(), activity: activity)
        self.activeLease = lease
        return lease
    }

    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        guard self.activeLease == lease else { return }
        self.activeLease = nil
    }

    func prepareMeetingAudioHandoff(_ lease: ASRActivityLease) async throws {
        self.prepareInvocationCount += 1
        self.prepareStarted = true
        if self.prepareInvocationCount == 1 {
            await withCheckedContinuation { self.prepareContinuation = $0 }
        }
    }

    func resumePrepare() {
        let continuation = self.prepareContinuation
        self.prepareContinuation = nil
        continuation?.resume()
    }

    func completeMeetingAudioHandback(_ lease: ASRActivityLease) async {
        self.handbackCount += 1
        self.releaseExclusiveActivity(lease)
    }
}

@MainActor
private final class SuspendedHandbackASRActivityLeasing: ASRActivityLeasing {
    private(set) var handbackStarted = false
    private(set) var handbackCount = 0
    private var activeLease: ASRActivityLease?
    private var handbackContinuation: CheckedContinuation<Void, Never>?

    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        guard self.activeLease == nil else { throw ASRActivityError.activityInProgress(activity) }
        let lease = ASRActivityLease(id: UUID(), activity: activity)
        self.activeLease = lease
        return lease
    }

    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        guard self.activeLease == lease else { return }
        self.activeLease = nil
    }

    func prepareMeetingAudioHandoff(_ lease: ASRActivityLease) async throws {}

    func completeMeetingAudioHandback(_ lease: ASRActivityLease) async {
        self.handbackCount += 1
        self.handbackStarted = true
        if self.handbackCount == 1 {
            await withCheckedContinuation { self.handbackContinuation = $0 }
        }
        self.releaseExclusiveActivity(lease)
    }

    func resumeHandback() {
        let continuation = self.handbackContinuation
        self.handbackContinuation = nil
        continuation?.resume()
    }
}

/// Throws on the first `acquireMeetingCapture()` call, then succeeds on every subsequent call.
@MainActor
private final class ThrowOnceArbiter: MeetingAudioActivityArbitrating {
    private var hasThrown = false
    func acquireMeetingCapture() async throws -> MeetingAudioActivityLease {
        guard self.hasThrown else {
            self.hasThrown = true
            throw MeetingCoordinatorError.dictationActive
        }
        return MeetingAudioActivityLease(id: UUID())
    }

    func release(_ lease: MeetingAudioActivityLease) async {}
}

/// Wraps a real `MeetingSessionStore`, suspending `delete(id:)` until `openGate()` is called —
/// used to hold `deleteSession` mid-flight so a racing retry can be observed.
private actor GatedDeleteStore: MeetingSessionStoring {
    private let inner: MeetingSessionStore
    private let recorder: EventRecorder
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(inner: MeetingSessionStore, recorder: EventRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func openGate() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func create(_ session: MeetingSession) async throws { try await self.inner.create(session) }
    func save(_ session: MeetingSession) async throws { try await self.inner.save(session) }
    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.inner.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.inner.loadAll() }
    func loadRecoverable() async throws -> [MeetingSession] { try await self.inner.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.inner.existingSessionDirectory(for: id)
    }

    func delete(id: MeetingSessionID) async throws {
        await self.recorder.record("store.delete.start")
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        try await self.inner.delete(id: id)
    }

    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }
}

/// Wraps a real `MeetingSessionStore`, suspending `loadRecoverable()` until `openGate()` is
/// called — used to prove `startRecording` waits for the launch restore barrier.
private actor GatedRecoverableStore: MeetingSessionStoring {
    private let inner: MeetingSessionStore
    private let recorder: EventRecorder
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(inner: MeetingSessionStore, recorder: EventRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func openGate() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func create(_ session: MeetingSession) async throws { try await self.inner.create(session) }
    func save(_ session: MeetingSession) async throws { try await self.inner.save(session) }
    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.inner.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.inner.loadAll() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.inner.existingSessionDirectory(for: id)
    }

    func delete(id: MeetingSessionID) async throws { try await self.inner.delete(id: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }

    func loadRecoverable() async throws -> [MeetingSession] {
        await self.recorder.record("restore.loadRecoverable.start")
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        return try await self.inner.loadRecoverable()
    }
}

/// Holds each real retention `loadAll` until the test releases that exact invocation.
/// Other storage operations remain real, so capture and audio handback can finish while held.
private actor GatedLoadAllStore: MeetingSessionStoring {
    private let inner: MeetingSessionStore
    private let entered: @Sendable (Int) -> Void
    private var nextIndex = 0
    private var openIndices = Set<Int>()
    private var allOpen = false
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]

    init(inner: MeetingSessionStore, entered: @escaping @Sendable (Int) -> Void) {
        self.inner = inner; self.entered = entered
    }

    func openGate(_ index: Int) {
        self.openIndices.insert(index)
        self.continuations.removeValue(forKey: index)?.resume()
    }

    func openAllGates() {
        self.allOpen = true
        let pending = Array(self.continuations.values)
        self.continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }

    func loadAll() async throws -> [MeetingSession] {
        self.nextIndex += 1
        let index = self.nextIndex
        if !self.allOpen, !self.openIndices.contains(index) {
            await withCheckedContinuation { continuation in
                self.continuations[index] = continuation
                self.entered(index)
            }
        }
        return try await self.inner.loadAll()
    }

    func create(_ session: MeetingSession) async throws { try await self.inner.create(session) }
    func save(_ session: MeetingSession) async throws { try await self.inner.save(session) }
    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.inner.load(id: id) }
    func loadRecoverable() async throws -> [MeetingSession] { try await self.inner.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? { try await self.inner.existingSessionDirectory(for: id) }
    func delete(id: MeetingSessionID) async throws { try await self.inner.delete(id: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }
}

/// Wraps a real `MeetingSessionStore`; `save(_:)` records a "store.save.start" event, then either
/// throws a queued failure or (until `openGate()`) suspends — used to test performCorrection's
/// commit-only-on-save discipline and the single-in-flight-correction gate.
private actor GatedThrowingSaveStore: MeetingSessionStoring {
    private let inner: MeetingSessionStore
    private let recorder: EventRecorder
    private var isOpen = true
    private var continuation: CheckedContinuation<Void, Never>?
    private var throwOnNextSaveCount = 0
    private(set) var savedEventCounts: [Int] = []

    init(inner: MeetingSessionStore, recorder: EventRecorder) {
        self.inner = inner
        self.recorder = recorder
    }

    func throwOnNextSave(_ count: Int = 1) { self.throwOnNextSaveCount = count }
    func closeGate() { self.isOpen = false }
    func openGate() {
        self.isOpen = true
        self.continuation?.resume()
        self.continuation = nil
    }

    func create(_ session: MeetingSession) async throws { try await self.inner.create(session) }

    func save(_ session: MeetingSession) async throws {
        await self.recorder.record("store.save.start")
        if self.throwOnNextSaveCount > 0 {
            self.throwOnNextSaveCount -= 1
            throw CocoaError(.fileWriteUnknown)
        }
        if !self.isOpen {
            await withCheckedContinuation { self.continuation = $0 }
        }
        try await self.inner.save(session)
        self.savedEventCounts.append(session.events.count)
    }

    func load(id: MeetingSessionID) async throws -> MeetingSession? { try await self.inner.load(id: id) }
    func loadAll() async throws -> [MeetingSession] { try await self.inner.loadAll() }
    func loadRecoverable() async throws -> [MeetingSession] { try await self.inner.loadRecoverable() }
    func sessionDirectory(for id: MeetingSessionID) async throws -> URL { try await self.inner.sessionDirectory(for: id) }
    func existingSessionDirectory(for id: MeetingSessionID) async throws -> URL? {
        try await self.inner.existingSessionDirectory(for: id)
    }

    func delete(id: MeetingSessionID) async throws { try await self.inner.delete(id: id) }
    func deleteAudioFiles(for id: MeetingSessionID) async throws { try await self.inner.deleteAudioFiles(for: id) }
}

// MARK: - MeetingProcessingSerializationGate (REL-010)

private struct GateTimeoutError: Error {}

final class MeetingProcessingSerializationGateTests: XCTestCase {
    /// Races `gate.acquire()` against a timeout so a regression that re-introduces a deadlock
    /// fails the test instead of hanging the whole suite.
    private func acquireOrTimeout(
        _ gate: MeetingProcessingSerializationGate,
        timeoutNanoseconds: UInt64 = 500_000_000
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await gate.acquire() }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw GateTimeoutError()
            }
            try await group.next()
            group.cancelAll()
        }
    }

    func testSecondAcquireWaitsUntilFirstRelease() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let recorder = EventRecorder()
        let waiter = Task {
            try await gate.acquire()
            await recorder.record("acquired")
        }
        try await Task.sleep(nanoseconds: 20_000_000)
        let eventsBeforeRelease = await recorder.events
        XCTAssertTrue(eventsBeforeRelease.isEmpty, "second acquire must not resume before release")

        await gate.release()
        try await waiter.value
        let eventsAfterRelease = await recorder.events
        XCTAssertEqual(eventsAfterRelease, ["acquired"])
    }

    func testThreeWaitersResumeInFIFOOrder() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let recorder = EventRecorder()
        let waiter1 = Task { try await gate.acquire(); await recorder.record("1") }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter2 = Task { try await gate.acquire(); await recorder.record("2") }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter3 = Task { try await gate.acquire(); await recorder.record("3") }
        try await Task.sleep(nanoseconds: 20_000_000)

        await gate.release()
        try await waiter1.value
        await gate.release()
        try await waiter2.value
        await gate.release()
        try await waiter3.value

        let events = await recorder.events
        XCTAssertEqual(events, ["1", "2", "3"])
    }

    func testCancelledWaiterThrowsAndDoesNotStrandTheLeaseForLaterWaiters() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let cancelledWaiter = Task { try await gate.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelledWaiter.cancel()

        do {
            try await cancelledWaiter.value
            XCTFail("Expected the cancelled waiter to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let laterWaiter = Task { try await gate.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)
        await gate.release() // still holding the original lease; must go to laterWaiter, not the cancelled one
        try await laterWaiter.value // no deadlock: the cancelled waiter didn't strand the lease
    }

    func testReleaseWithNoWaitersResetsForFreshAcquire() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()
        await gate.release()

        try await self.acquireOrTimeout(gate)
    }

    func testPreCancelledAcquireThrowsImmediatelyAndLeavesGateFreeForNextAcquire() async throws {
        let gate = MeetingProcessingSerializationGate()
        let task = Task<Void, Error> { try await gate.acquire() }
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected a pre-cancelled acquire to throw")
        } catch is CancellationError {
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        // The cancelled acquire never took the lease: a fresh acquire must proceed unblocked.
        try await self.acquireOrTimeout(gate)
        await gate.release()
    }

    /// Races a waiter's cancellation against the moment `release()` hands it the lease — the
    /// exact window a stale tombstone could otherwise strand. Kept behavioral (no introspection
    /// of the gate's private tombstone set): a fresh acquire/release cycle afterward must still
    /// make progress within the timeout.
    func testCancelRacingHandoffLeavesGateUsableAfterward() async throws {
        let gate = MeetingProcessingSerializationGate()
        try await gate.acquire()

        let waiter = Task { try? await gate.acquire() }
        try await Task.sleep(nanoseconds: 20_000_000)

        await gate.release()
        waiter.cancel()
        _ = await waiter.value
        await gate.release() // frees the lease regardless of which side of the race the waiter landed on

        try await self.acquireOrTimeout(gate)
        await gate.release()
    }
}

@MainActor
private final class MemoryCheckpointProcessingController: MeetingProcessingControlling {
    private(set) var validatedBackendIDs: [MeetingBackendID] = []
    private(set) var preparedSession: MeetingSession?
    func validateMemoryAudioInput(configuration: MeetingCaptureConfiguration, backendID: MeetingBackendID) throws -> MeetingBackendDescriptor {
        // This explicit synthetic processor implements the memory checkpoint path under test.
        self.validatedBackendIDs.append(backendID)
        guard let descriptor = MeetingTranscriptionBackendRegistry.makeDefault().descriptor(for: backendID) else {
            throw MeetingBackendError.unknownBackend(backendID)
        }
        return descriptor
    }
    private var operation: (@MainActor (MeetingPCMTranscriptBatch) async throws -> Void)?
    private(set) var cancelCount = 0
    func prepareMemoryAudio(session: MeetingSession, sessionDirectory: URL, checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) async throws { preparedSession = session; operation = checkpoint }
    func checkpoint(_ batch: MeetingPCMTranscriptBatch) async throws { try await operation?(batch) }
    func cancelMemoryAudio(sessionID: MeetingSessionID) async { cancelCount += 1; operation = nil }
    func process(session: MeetingSession, sessionDirectory: URL, progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingProcessingResult {
        let attempt = MeetingProcessingAttempt(id: UUID(), startedAt: session.startedAt, completedAt: Date(), stage: .completed,
            pipelineVersion: 13, asrProvider: "synthetic", asrModel: "synthetic", languageCode: session.languageCode,
            diarizationModel: nil, lastCompletedTrackID: nil, errorCode: nil)
        return MeetingProcessingResult(speakers: session.speakers, segments: session.transcriptSegments, attempt: attempt)
    }
}
