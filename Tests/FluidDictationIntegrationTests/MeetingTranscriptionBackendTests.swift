import AVFoundation
import CoreMedia
import PichiGigaAM
import PichiTextPrivacy
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Milestone A of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the backend contract, the
/// injectable registry, evidence validation, and proof that `MeetingProcessingPipeline.process`
/// really dispatches through a selected backend.
///
/// The dispatch tests deliberately fail the `asrServiceProvider` closure: a fixture backend must be
/// reached without any ASR model readiness work, which is what makes "selection happens before
/// expensive model loading" a checked property rather than a claim.
@MainActor
final class MeetingTranscriptionBackendTests: XCTestCase {
    // MARK: - Fixture backend

    private final class FixtureMeetingBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let makeOutcome: @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        /// Lets a test hand back a plan that contradicts the request it was given.
        private let planOverride: (@MainActor (MeetingBackendRequest) -> MeetingBackendPlan)?
        private(set) var planCallCount = 0
        private(set) var executeCallCount = 0
        private(set) var lastPlan: MeetingBackendPlan?
        private(set) var receivedManifest: MeetingAnalysisManifest??
        private(set) var observedStages: [MeetingProcessingStage] = []

        init(
            descriptor: MeetingBackendDescriptor,
            planOverride: (@MainActor (MeetingBackendRequest) -> MeetingBackendPlan)? = nil,
            makeOutcome: @escaping @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        ) {
            self.descriptor = descriptor
            self.planOverride = planOverride
            self.makeOutcome = makeOutcome
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            self.planCallCount += 1
            let plan = self.planOverride?(request)
                ?? MeetingBackendPlan(request: request, descriptor: self.descriptor)
            self.lastPlan = plan
            return plan
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            self.executeCallCount += 1
            self.receivedManifest = manifest
            progress(.transcribing)
            self.observedStages.append(.transcribing)
            return self.makeOutcome(plan)
        }
    }

    /// Calls the host's legacy executor with whatever request a test wants, to prove the host
    /// refuses anything but the exact request it froze.
    private final class LegacyCallbackBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let executor: MeetingLegacyBackendExecutor
        private let rewriteRequest: @MainActor (MeetingBackendRequest) -> MeetingBackendRequest

        init(
            descriptor: MeetingBackendDescriptor,
            executor: @escaping MeetingLegacyBackendExecutor,
            rewriteRequest: @escaping @MainActor (MeetingBackendRequest) -> MeetingBackendRequest
        ) {
            self.descriptor = descriptor
            self.executor = executor
            self.rewriteRequest = rewriteRequest
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            try .legacyCompatibility(await self.executor(self.rewriteRequest(plan.request), progress))
        }
    }

    /// Parks inside `execute` on a latch that ignores cancellation, then returns successfully —
    /// a backend that does not cooperate with `Task` cancellation.
    private final class BlockingFixtureBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        private let latch: Latch
        private let onEnter: @MainActor () -> Void
        private let makeOutcome: @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        private(set) var executeCallCount = 0
        private(set) var didProduceOutcome = false

        init(
            descriptor: MeetingBackendDescriptor,
            latch: Latch,
            onEnter: @escaping @MainActor () -> Void,
            makeOutcome: @escaping @MainActor (MeetingBackendPlan) -> MeetingBackendOutcome
        ) {
            self.descriptor = descriptor
            self.latch = latch
            self.onEnter = onEnter
            self.makeOutcome = makeOutcome
        }

        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            MeetingBackendPlan(request: request, descriptor: self.descriptor)
        }

        func execute(
            plan: MeetingBackendPlan,
            manifest: MeetingAnalysisManifest?,
            progress: @escaping @MainActor (MeetingProcessingStage) -> Void
        ) async throws -> MeetingBackendOutcome {
            self.executeCallCount += 1
            self.onEnter()
            await self.latch.wait()
            self.didProduceOutcome = true
            return self.makeOutcome(plan)
        }
    }

    /// Deliberately cancellation-deaf: a parked waiter is only resumed by `open()`.
    private actor Latch {
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var isOpen = false

        func wait() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.park($0) }
        }

        func open() {
            self.isOpen = true
            let parked = self.waiters
            self.waiters.removeAll()
            for continuation in parked {
                continuation.resume()
            }
        }

        private func park(_ continuation: CheckedContinuation<Void, Never>) {
            self.waiters.append(continuation)
        }
    }

    private nonisolated static let fixtureBackendID = MeetingBackendID(rawValue: "fixture-test-backend")

    private func makeFixtureDescriptor(
        id: MeetingBackendID = MeetingTranscriptionBackendTests.fixtureBackendID,
        version: String = "test",
        trackKinds: Set<MeetingAudioTrackKind> = Set(MeetingAudioTrackKind.allCases),
        precisions: Set<MeetingTextUnitPrecision> = [.word, .utterance],
        resultContract: MeetingBackendResultContract = .legacyResult
    ) -> MeetingBackendDescriptor {
        MeetingBackendDescriptor(
            id: id,
            version: version,
            execution: .local,
            supportedLanguageCodes: ["en"],
            supportedTrackKinds: trackKinds,
            supportedFinalPrecisions: precisions,
            resultContract: resultContract,
            knownLimits: ["Fixture only; performs no inference."]
        )
    }

    // MARK: - Session fixtures

    private func makeChunk(sequence: Int, path: String) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: UUID(),
            sequence: sequence,
            relativeFilePath: path,
            presentationStart: MeetingMediaTime(value: Int64(sequence) * 1000, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: Int64(sequence + 1) * 1000, timescale: 1000),
            discontinuities: [],
            sha256: "fixture-\(sequence)",
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func makeTrack(kind: MeetingAudioTrackKind, chunks: [MeetingAudioChunk]) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(),
            kind: kind,
            sourceIdentifier: kind.rawValue,
            sourceDisplayName: kind.rawValue,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks
        )
    }

    private func makeSession(
        languageCode: String = "en",
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        tracks: [MeetingAudioTrack]? = nil,
        processingAttempts: [MeetingProcessingAttempt] = []
    ) -> MeetingSession {
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .onlineCall,
                title: "Backend fixture",
                languageCode: languageCode,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        session.audioTracks = tracks ?? [
            self.makeTrack(kind: .microphone, chunks: [self.makeChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")]),
        ]
        session.processingAttempts = processingAttempts
        return session
    }

    private func makeResult(attemptID: UUID, text: String) -> MeetingProcessingResult {
        MeetingProcessingResult(
            speakers: [],
            segments: [
                MeetingTranscriptSegment(
                    id: UUID(),
                    start: MeetingMediaTime(value: 0, timescale: 1000),
                    end: MeetingMediaTime(value: 1000, timescale: 1000),
                    sourceTrackID: UUID(),
                    speakerID: nil,
                    text: text,
                    revision: 1,
                    status: .final,
                    overlap: .none,
                    completeness: .complete
                ),
            ],
            attempt: MeetingProcessingAttempt(
                id: attemptID,
                startedAt: Date(),
                completedAt: Date(),
                stage: .completed,
                pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                asrProvider: "fixture",
                asrModel: "fixture",
                diarizationModel: nil,
                lastCompletedTrackID: nil,
                errorCode: nil
            )
        )
    }

    private func makePipeline(
        registry: MeetingTranscriptionBackendRegistry,
        backendID: MeetingBackendID?,
        gate: MeetingProcessingSerializationGate = MeetingProcessingSerializationGate()
    ) -> MeetingProcessingPipeline {
        MeetingProcessingPipeline(
            asrServiceProvider: {
                XCTFail("Backend dispatch must not reach ASR readiness for a fixture backend")
                return ASRService()
            },
            managesModelResidency: false,
            serializationGate: gate,
            backendRegistry: registry,
            backendID: backendID
        )
    }

    func testRegistryRejectsFactoryIdentityMismatch() throws {
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(id: .legacyCompatibility)) { _ in
                fatalError("Mismatched factory must not execute")
            }
        }
        XCTAssertThrowsError(try registry.makeBackend(
            id: Self.fixtureBackendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingProcessingError.noRecoverableAudio
            })
        )) { error in
            XCTAssertEqual(error as? MeetingBackendError, .backendIdentityMismatch(
                requested: Self.fixtureBackendID, produced: .legacyCompatibility
            ))
        }
    }

    func testPipelineRejectsPlanForDifferentDirectory() async throws {
        let descriptor = self.makeFixtureDescriptor()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { _ in
            FixtureMeetingBackend(descriptor: descriptor, planOverride: { request in
                MeetingBackendPlan(request: MeetingBackendRequest(
                    attemptID: request.attemptID,
                    session: request.session,
                    sessionDirectory: request.sessionDirectory.appendingPathComponent("another-session"),
                    configuration: request.configuration
                ), descriptor: descriptor)
            }) { _ in fatalError("Substituted plan must not execute") }
        }
        do {
            _ = try await self.makePipeline(registry: registry, backendID: nil).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Substituted request must fail before model work")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .planDisagreesWithRequest(backend: Self.fixtureBackendID, defect: .request)
            )
        }
    }

    func testLegacyExecutorRejectsSubstitutedRequest() async throws {
        let descriptor = self.makeFixtureDescriptor()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { context in
            LegacyCallbackBackend(descriptor: descriptor, executor: context.legacyExecutor) { request in
                MeetingBackendRequest(
                    attemptID: UUID(),
                    session: request.session,
                    sessionDirectory: request.sessionDirectory,
                    configuration: request.configuration
                )
            }
        }
        do {
            _ = try await self.makePipeline(registry: registry, backendID: nil).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Substituted executor request must fail")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .legacyExecutorRequestMismatch(backend: Self.fixtureBackendID)
            )
        }
    }

    func testCancelledNonCooperativeBackendDoesNotPublishAndReleasesLease() async throws {
        let gate = MeetingProcessingSerializationGate()
        let entered = Latch()
        let latch = Latch()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        registry.register(Self.fixtureBackendID) { [self] _ in
            BlockingFixtureBackend(
                descriptor: self.makeFixtureDescriptor(),
                latch: latch,
                onEnter: { Task { await entered.open() } }
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "cancelled"))
            }
        }
        let pipeline = self.makePipeline(registry: registry, backendID: nil, gate: gate)
        let task = Task {
            try await pipeline.process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
        }
        await entered.wait()
        task.cancel()
        await latch.open()
        do {
            _ = try await task.value
            XCTFail("Cancelled backend result must not be returned")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }

        registry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "next"))
            }
        }
        let result = try await pipeline.process(
            session: self.makeSession(),
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(result.segments.map(\.text), ["next"])
    }

    func testMeetingPreferencePreservesUnknownIDsAndDoesNotChangeDictation() {
        let defaults = UserDefaults.standard
        let key = "MeetingTranscriptionBackendID"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let settings = SettingsStore.shared
        let dictationModel = settings.selectedSpeechModel
        defaults.removeObject(forKey: key)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, .productionDefault)
        let future = MeetingBackendID(rawValue: "future.unavailable-engine")
        settings.meetingTranscriptionBackendID = future
        XCTAssertEqual(settings.meetingTranscriptionBackendID, future)
        XCTAssertEqual(defaults.string(forKey: key), future.rawValue)
        XCTAssertEqual(settings.selectedSpeechModel, dictationModel)
    }

    func testMeetingPreferenceBackupPreservesUnknownIDAndMigratesMissingToDefault() async throws {
        let defaults = UserDefaults.standard
        let key = "MeetingTranscriptionBackendID"
        let oldValue = defaults.object(forKey: key)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        let settingsStore = SettingsStore.shared
        let future = MeetingBackendID(rawValue: "future.hosted-provider")
        settingsStore.meetingTranscriptionBackendID = future

        let document = try await BackupService.shared.makeBackupDocument()
        XCTAssertEqual(document.settings.meetingTranscriptionBackendID, future.rawValue)

        let encoded = try BackupService.shared.encode(document)
        let decoded = try BackupService.shared.decode(encoded)
        settingsStore.meetingTranscriptionBackendID = .legacyCompatibility
        settingsStore.restore(from: decoded.settings)
        XCTAssertEqual(settingsStore.meetingTranscriptionBackendID, future)

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try XCTUnwrap(root["settings"] as? [String: Any])
        payload.removeValue(forKey: "meetingTranscriptionBackendID")
        root["settings"] = payload
        let legacy = try BackupService.shared.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertNil(legacy.settings.meetingTranscriptionBackendID)

        settingsStore.meetingTranscriptionBackendID = future
        settingsStore.restore(from: legacy.settings)
        XCTAssertEqual(settingsStore.meetingTranscriptionBackendID, .productionDefault)
    }

    func testSelectionIsFrozenDuringExecutionAndRefreshedForNextAttempt() async throws {
        let firstID = Self.fixtureBackendID
        let secondID = MeetingBackendID(rawValue: "fixture-second")
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: firstID)
        let entered = Latch()
        let latch = Latch()
        registry.register(firstID) { [self] _ in
            BlockingFixtureBackend(
                descriptor: self.makeFixtureDescriptor(),
                latch: latch,
                onEnter: { Task { await entered.open() } }
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "first"))
            }
        }
        registry.register(secondID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(id: secondID)) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "second"))
            }
        }
        var selected = firstID
        var selectionReads = 0
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { fatalError("Fixture must not load ASR") },
            managesModelResidency: false,
            serializationGate: MeetingProcessingSerializationGate(),
            backendRegistry: registry,
            backendIDProvider: { selectionReads += 1; return selected }
        )
        let session = self.makeSession()
        let task = Task {
            try await pipeline.process(
                session: session,
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
        }
        await entered.wait()
        selected = secondID
        await latch.open()
        let first = try await task.value
        XCTAssertEqual(first.segments.map(\.text), ["first"])
        XCTAssertEqual(selectionReads, 1)
        let second = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(second.segments.map(\.text), ["second"])
        XCTAssertEqual(selectionReads, 2)
    }

    // MARK: - Registry

    func testDefaultRegistryUsesProductionDefaultAndKeepsLegacyRollback() throws {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        XCTAssertEqual(registry.defaultBackendID, .productionDefault)
        XCTAssertEqual(registry.registeredBackendIDs, [.legacyCompatibility, .parakeetNemotron, .gigaam, .whisperTiny, .parakeetV3])

        let backend = try registry.makeBackend(
            id: registry.defaultBackendID,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                XCTFail("Legacy executor must not run while only resolving the backend")
                throw MeetingProcessingError.noRecoverableAudio
            })
        )
        XCTAssertEqual(backend.descriptor.id, .parakeetNemotron)
        XCTAssertEqual(backend.descriptor.execution, .local)
        XCTAssertEqual(
            backend.descriptor.supportedFinalPrecisions, [.word, .utterance]
        )
    }

    func testRegistryRejectsAnUnknownBackendIdentifier() {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        let unknown = MeetingBackendID(rawValue: "not-registered")
        XCTAssertFalse(registry.contains(unknown))
        XCTAssertThrowsError(
            try registry.makeBackend(
                id: unknown,
                context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                    throw MeetingProcessingError.noRecoverableAudio
                })
            )
        ) { error in
            XCTAssertEqual(error as? MeetingBackendError, .unknownBackend(unknown))
        }
    }

    // MARK: - Pipeline dispatch

    func testPipelineDispatchesToTheInjectedBackendBeforeAnyModelWork() async throws {
        let session = self.makeSession()
        var captured: MeetingProcessingResult?
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        var fixture: FixtureMeetingBackend?
        registry.register(Self.fixtureBackendID) { [self] _ in
            let backend = FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                let result = self.makeResult(attemptID: plan.attemptID, text: "dispatched")
                captured = result
                return .legacyCompatibility(result)
            }
            fixture = backend
            return backend
        }

        let pipeline = self.makePipeline(registry: registry, backendID: nil)
        var stages: [MeetingProcessingStage] = []
        let result = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { stages.append($0) }
        )

        let backend = try XCTUnwrap(fixture)
        XCTAssertEqual(backend.planCallCount, 1)
        XCTAssertEqual(backend.executeCallCount, 1)
        XCTAssertEqual(stages, [.transcribing], "the backend's progress reaches the caller unchanged")
        XCTAssertEqual(result.segments.map(\.text), ["dispatched"])
        XCTAssertEqual(result.attempt.id, captured?.attempt.id)

        let plan = try XCTUnwrap(backend.lastPlan)
        XCTAssertEqual(plan.backendID, Self.fixtureBackendID)
        XCTAssertEqual(plan.trackKindsByID.count, 1)
        XCTAssertEqual(plan.chunkIDsByTrackID.values.first?.count, 1)
    }

    func testPipelineReusesTheOpenAttemptIdentifierForTheRequest() async throws {
        let openAttempt = MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date(timeIntervalSinceNow: -60),
            completedAt: nil,
            stage: .transcribing,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
        let session = self.makeSession(processingAttempts: [openAttempt])
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        var fixture: FixtureMeetingBackend?
        registry.register(Self.fixtureBackendID) { [self] _ in
            let backend = FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "retry"))
            }
            fixture = backend
            return backend
        }

        let pipeline = self.makePipeline(registry: registry, backendID: nil)
        let result = try await pipeline.process(
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            progress: { _ in }
        )
        XCTAssertEqual(fixture?.lastPlan?.attemptID, openAttempt.id)
        XCTAssertEqual(result.attempt.id, openAttempt.id)
    }

    func testPipelineRejectsAnUnknownBackendIdentifierExplicitly() async {
        let registry = MeetingTranscriptionBackendRegistry.makeDefault()
        let unknown = MeetingBackendID(rawValue: "muse-cloud-v0")
        let pipeline = self.makePipeline(registry: registry, backendID: unknown)
        do {
            _ = try await pipeline.process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("An unregistered backend must not silently fall back to legacy")
        } catch {
            XCTAssertEqual(error as? MeetingBackendError, .unknownBackend(unknown))
        }
    }

    func testLegacyPreflightChecksStillRunBeforeBackendSelection() async {
        var factoryCallCount = 0
        func registry() -> MeetingTranscriptionBackendRegistry {
            let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
            registry.register(Self.fixtureBackendID, descriptor: self.makeFixtureDescriptor()) { [self] _ in
                factoryCallCount += 1
                return FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor()) { plan in
                    .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "unused"))
                }
            }
            return registry
        }

        do {
            _ = try await self.makePipeline(registry: registry(), backendID: nil).process(
                session: self.makeSession(languageCode: "zh"),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Unsupported languages must still be rejected")
        } catch {
            guard case MeetingProcessingError.unsupportedLanguage = error else {
                return XCTFail("Expected unsupportedLanguage, got \(error)")
            }
        }

        do {
            _ = try await self.makePipeline(registry: registry(), backendID: nil).process(
                session: self.makeSession(tracks: [self.makeTrack(kind: .microphone, chunks: [])]),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("A session with no chunks must still be rejected")
        } catch {
            guard case MeetingProcessingError.noRecoverableAudio = error else {
                return XCTFail("Expected noRecoverableAudio, got \(error)")
            }
        }

        XCTAssertEqual(factoryCallCount, 0, "preflight failures must not construct a backend")
    }

    func testOwnedSettingsSelectRetryWhileFirstProcessingRetainsRecordingPin() async throws {
        let shared = SettingsStore.shared
        let previousModel = shared.selectedSpeechModel
        let previousBackend = shared.meetingTranscriptionBackendID
        defer { shared.selectedSpeechModel = previousModel; shared.meetingTranscriptionBackendID = previousBackend }
        shared.selectedSpeechModel = .whisperTiny
        shared.meetingTranscriptionBackendID = .whisperTiny
        let suite = "OwnedMeetingRetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .gigaam
        settings.meetingTranscriptionBackendID = .productionDefault
        let marker = CocoaError(.userCancelled)
        var requests: [MeetingBackendRequest] = []
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { XCTFail("Routing test cannot prepare ASR"); return ASRService() },
            managesModelResidency: false, settings: settings,
            chunkObserver: UnreadableFixtureObserver(),
            meetingRuntimeFactory: { request in requests.append(request); throw marker })
        var session = self.makeSession(languageCode: "ru")
        session.speakerLabelsEnabled = false
        session.recordingBackendID = MeetingBackendID.whisperTiny.rawValue
        session.recordingASRArtifactFingerprint = "synthetic-whisper-recording"
        for retry in [false, true] {
            if retry {
                session.processingAttempts = [MeetingProcessingAttempt(id: UUID(), startedAt: Date(), completedAt: Date(),
                    stage: .completed, pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
                    asrProvider: MeetingBackendID.whisperTiny.rawValue, asrModel: PichiMeetingProviderFactory.whisperTinyModelID,
                    diarizationModel: nil, lastCompletedTrackID: nil, errorCode: nil)]
            }
            do {
                _ = try await pipeline.process(session: session, sessionDirectory: FileManager.default.temporaryDirectory,
                    progress: { _ in })
                XCTFail("Expected marker before any runtime/inference")
            } catch { XCTAssertEqual(error as? CocoaError, marker) }
        }
        XCTAssertEqual(requests.map { $0.configuration.asrModel }, [PichiMeetingProviderFactory.whisperTinyModelID,
            PichiMeetingProviderFactory.gigaamModelID])
        XCTAssertEqual(try XCTUnwrap(requests.first).configuration.asrArtifactFingerprint, "synthetic-whisper-recording")
        XCTAssertEqual(shared.meetingTranscriptionBackendID, .whisperTiny)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, .productionDefault)
    }

    func testSavedLegacyBackendUsesProductionForFrenchWithoutChangingPreference() async {
        let settings = SettingsStore.shared
        let defaults = UserDefaults.standard
        let speechModelKey = "SelectedSpeechModel"
        let previousSpeechModel = defaults.object(forKey: speechModelKey)
        let previous = settings.meetingTranscriptionBackendID
        defer {
            settings.meetingTranscriptionBackendID = previous
            if let previousSpeechModel { defaults.set(previousSpeechModel, forKey: speechModelKey) }
            else { defaults.removeObject(forKey: speechModelKey) }
        }
        // Use an unregistered model to isolate the saved legacy backend policy.
        settings.selectedSpeechModel = .whisperSmall
        settings.meetingTranscriptionBackendID = .legacyCompatibility
        let marker = CocoaError(.userCancelled)
        var productionPreparations = 0
        let pipeline = MeetingProcessingPipeline(
            asrServiceProvider: { XCTFail("Routing must happen before ASR loading"); return ASRService() },
            managesModelResidency: false,
            prepareDiarizationModel: { productionPreparations += 1; throw marker }
        )
        do {
            _ = try await pipeline.process(
                session: self.makeSession(languageCode: "fr"),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Expected the production preparation marker")
        } catch {
            XCTAssertEqual(error as? CocoaError, marker)
        }
        XCTAssertEqual(productionPreparations, 1)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, .legacyCompatibility)
    }

    func testExplicitLegacyAndUnknownSavedBackendsDoNotSilentlyFallBack() async {
        let settings = SettingsStore.shared
        let defaults = UserDefaults.standard
        let speechModelKey = "SelectedSpeechModel"
        let previousSpeechModel = defaults.object(forKey: speechModelKey)
        let previous = settings.meetingTranscriptionBackendID
        defer {
            settings.meetingTranscriptionBackendID = previous
            if let previousSpeechModel { defaults.set(previousSpeechModel, forKey: speechModelKey) }
            else { defaults.removeObject(forKey: speechModelKey) }
        }
        settings.selectedSpeechModel = .whisperSmall
        let unknown = MeetingBackendID(rawValue: "unknown-saved-backend")
        for pinned in [true, false] {
            settings.meetingTranscriptionBackendID = pinned ? .legacyCompatibility : unknown
            let pipeline = MeetingProcessingPipeline(
                asrServiceProvider: { XCTFail("Rejected selections must not load models"); return ASRService() },
                managesModelResidency: false,
                backendID: pinned ? .legacyCompatibility : nil,
                prepareDiarizationModel: { XCTFail("Explicit/unknown selections must not use production") }
            )
            do {
                _ = try await pipeline.process(
                    session: self.makeSession(languageCode: "fr"),
                    sessionDirectory: FileManager.default.temporaryDirectory,
                    progress: { _ in }
                )
                XCTFail("The incompatible selection must be rejected")
            } catch {
                XCTAssertEqual(
                    error as? MeetingBackendError,
                    pinned
                        ? .unsupportedLanguage(backend: .legacyCompatibility, languageCode: "fr")
                        : .unknownBackend(unknown)
                )
            }
        }
    }

    func testRegisteredModelRouteKeepsAmbientSavedFallbackWithoutChangingPreferences() {
        let settings = SettingsStore.shared
        let defaults = UserDefaults.standard
        let speechModelKey = "SelectedSpeechModel"
        let previousSpeechModel = defaults.object(forKey: speechModelKey)
        let backendKey = "MeetingTranscriptionBackendID"
        let previousBackend = defaults.object(forKey: backendKey)
        defer {
            if let previousBackend { defaults.set(previousBackend, forKey: backendKey) }
            else { defaults.removeObject(forKey: backendKey) }
            if let previousSpeechModel { defaults.set(previousSpeechModel, forKey: speechModelKey) }
            else { defaults.removeObject(forKey: speechModelKey) }
        }
        let unknown = MeetingBackendID(rawValue: "unknown-saved-backend")
        XCTAssertNotNil(PichiMeetingProviderFactory.registeredBackendDescriptor(for: SettingsStore.SpeechModel.whisperTiny.rawValue))
        XCTAssertNil(PichiMeetingProviderFactory.registeredBackendDescriptor(for: SettingsStore.SpeechModel.whisperSmall.rawValue))
        let selections: [(saved: MeetingBackendID, english: MeetingBackendID, nonEnglish: MeetingBackendID)] = [
            (.legacyCompatibility, .legacyCompatibility, .productionDefault),
            (.productionDefault, .productionDefault, .productionDefault),
            (unknown, unknown, unknown),
        ]
        let models: [(model: SettingsStore.SpeechModel, registeredBackend: MeetingBackendID?)] = [
            (.gigaam, .gigaam), (.whisperTiny, .whisperTiny), (.whisperSmall, nil),
        ]
        for (saved, english, nonEnglish) in selections {
            settings.meetingTranscriptionBackendID = saved
            for (languageCode, fallback) in [("en", english), ("fr", nonEnglish), ("ru", nonEnglish)] {
                for (model, registeredBackend) in models {
                    settings.selectedSpeechModel = model
                    let expected = registeredBackend ?? fallback
                    XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: languageCode), expected)
                    XCTAssertEqual(
                        PichiMeetingProviderFactory.selectedBackendID(languageCode: languageCode, selectedModelID: model.rawValue),
                        expected
                    )
                    XCTAssertEqual(
                        PichiMeetingProviderFactory.selectedBackendID(languageCode: languageCode,
                            selectedModelID: model.rawValue, savedBackendID: saved),
                        expected
                    )
                    XCTAssertEqual(settings.meetingTranscriptionBackendID, saved)
                    XCTAssertEqual(settings.selectedSpeechModel, model)
                }
            }
        }
    }

    /// Every chunk reports unreadable, so a manifest builds to explicit gaps without fixture audio.
    private struct UnreadableFixtureObserver: MeetingChunkAudioObserving {
        func observe(
            chunk: MeetingAudioChunk,
            trackID: MeetingAudioTrackID
        ) -> MeetingChunkObservationResult {
            .failed(.unreadable, detail: "fixture")
        }
    }

    func testPipelineSurfacesMalformedCanonicalEvidenceAsAValidationFailure() async throws {
        let session = self.makeSession()
        let trackID = try XCTUnwrap(session.audioTracks.first?.id)
        let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)

        // A scope defect — text the backend never really produced — still fails validation,
        // now on the canonical path after a real (all-gap) manifest was built and handed over.
        let scopeRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        scopeRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(
                descriptor: self.makeFixtureDescriptor(resultContract: .canonicalEvidence)
            ) { plan in
                .canonicalEvidence(MeetingCanonicalResultBundle(
                    evidence: MeetingFinalTranscriptEvidence(
                        backendID: plan.backendID,
                        attemptID: plan.attemptID,
                        units: [
                            MeetingFinalTextUnit(
                                id: "u-0",
                                trackID: trackID,
                                analysisEpochID: epoch,
                                precision: .utterance,
                                text: "   ",
                                analysisStart: 2,
                                analysisEnd: 4,
                                speaker: .unassigned,
                                analysisSpanIDs: ["span-0"]
                            ),
                        ]
                    ),
                    coverageReceipts: []
                ))
            }
        }

        do {
            _ = try await MeetingProcessingPipeline(
                asrServiceProvider: {
                    XCTFail("Canonical fixture must not load ASR")
                    return ASRService()
                },
                managesModelResidency: false,
                serializationGate: MeetingProcessingSerializationGate(),
                backendRegistry: scopeRegistry,
                backendID: nil,
                chunkObserver: UnreadableFixtureObserver()
            ).process(
                session: session,
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Empty evidence text must not pass through the pipeline")
        } catch {
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .emptyText(unitID: "u-0"))
        }
    }

    func testPipelineRejectsAnOutcomeThatContradictsTheDeclaredResultContract() async throws {
        // Declared canonical, returns the legacy shape: the pipeline must not reinterpret it.
        let canonicalRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        canonicalRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(
                descriptor: self.makeFixtureDescriptor(resultContract: .canonicalEvidence)
            ) { plan in
                .legacyCompatibility(self.makeResult(attemptID: plan.attemptID, text: "wrong shape"))
            }
        }
        do {
            _ = try await MeetingProcessingPipeline(
                asrServiceProvider: {
                    XCTFail("Canonical fixture must not load ASR")
                    return ASRService()
                },
                managesModelResidency: false,
                serializationGate: MeetingProcessingSerializationGate(),
                backendRegistry: canonicalRegistry,
                backendID: nil,
                chunkObserver: UnreadableFixtureObserver()
            ).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("A legacy outcome under a canonical contract must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .outcomeContractMismatch(backend: Self.fixtureBackendID, declared: .canonicalEvidence)
            )
        }

        // Declared legacy, returns canonical evidence: likewise a typed failure.
        let legacyRegistry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.fixtureBackendID)
        legacyRegistry.register(Self.fixtureBackendID) { [self] _ in
            FixtureMeetingBackend(descriptor: self.makeFixtureDescriptor(resultContract: .legacyResult)) { plan in
                .canonicalEvidence(MeetingCanonicalResultBundle(
                    evidence: MeetingFinalTranscriptEvidence(
                        backendID: plan.backendID,
                        attemptID: plan.attemptID,
                        units: []
                    ),
                    coverageReceipts: []
                ))
            }
        }
        do {
            _ = try await self.makePipeline(registry: legacyRegistry, backendID: nil).process(
                session: self.makeSession(),
                sessionDirectory: FileManager.default.temporaryDirectory,
                progress: { _ in }
            )
            XCTFail("Canonical evidence under a legacy contract must be rejected")
        } catch {
            XCTAssertEqual(
                error as? MeetingBackendError,
                .outcomeContractMismatch(backend: Self.fixtureBackendID, declared: .legacyResult)
            )
        }
    }

    // MARK: - Evidence validation

    private struct EvidenceFixture {
        let plan: MeetingBackendPlan
        let trackID: MeetingAudioTrackID
        let otherTrackID: MeetingAudioTrackID
        let epoch: MeetingAnalysisEpochID
    }

    private func makeEvidenceFixture(
        precisions: Set<MeetingTextUnitPrecision> = [.word, .utterance]
    ) throws -> EvidenceFixture {
        let microphone = self.makeTrack(
            kind: .microphone,
            chunks: [self.makeChunk(sequence: 0, path: "tracks/microphone/chunk_0.caf")]
        )
        let application = self.makeTrack(
            kind: .applicationAudio,
            chunks: [self.makeChunk(sequence: 0, path: "tracks/application/chunk_0.caf")]
        )
        let session = self.makeSession(tracks: [microphone, application])
        let request = MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration()
        )
        let plan = MeetingBackendPlan(
            request: request,
            descriptor: self.makeFixtureDescriptor(precisions: precisions)
        )
        return try EvidenceFixture(
            plan: plan,
            trackID: microphone.id,
            otherTrackID: application.id,
            epoch: MeetingAnalysisEpochID(trackID: microphone.id, ordinal: 0)
        )
    }

    private func makeUnit(
        _ fixture: EvidenceFixture,
        id: String = "u-0",
        precision: MeetingTextUnitPrecision = .word,
        text: String = "hello",
        analysisStart: TimeInterval = 1,
        analysisEnd: TimeInterval = 2,
        trackID: MeetingAudioTrackID? = nil,
        epoch: MeetingAnalysisEpochID? = nil,
        speaker: MeetingBackendSpeakerAssignment? = nil,
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        analysisSpanIDs: [String]? = nil,
        confidence: Double? = nil
    ) -> MeetingFinalTextUnit {
        let resolvedEpoch = epoch ?? fixture.epoch
        return MeetingFinalTextUnit(
            id: id,
            trackID: trackID ?? fixture.trackID,
            analysisEpochID: resolvedEpoch,
            precision: precision,
            text: text,
            analysisStart: analysisStart,
            analysisEnd: analysisEnd,
            speaker: speaker ?? .assigned(MeetingBackendSpeakerToken(analysisEpochID: resolvedEpoch, label: "slot-0")),
            analysisSpanIDs: analysisSpanIDs ?? ["span-0"],
            confidence: confidence
        )
    }

    private func evidence(
        _ fixture: EvidenceFixture,
        units: [MeetingFinalTextUnit],
        activity: [MeetingBackendSpeakerActivity] = []
    ) -> MeetingFinalTranscriptEvidence {
        MeetingFinalTranscriptEvidence(
            backendID: fixture.plan.backendID,
            attemptID: fixture.plan.attemptID,
            units: units,
            speakerActivity: activity
        )
    }

    func testEvidenceAcceptsWordAndUtteranceUnitsAndOptionalActivity() throws {
        let fixture = try self.makeEvidenceFixture()
        let payload = self.evidence(
            fixture,
            units: [
                self.makeUnit(fixture, id: "w-0", precision: .word, analysisStart: 1, analysisEnd: 1.4),
                self.makeUnit(
                    fixture,
                    id: "utt-0",
                    precision: .utterance,
                    text: "a whole sentence",
                    analysisStart: 2,
                    analysisEnd: 6,
                    speaker: .unassigned,
                    confidence: 0.75
                ),
                self.makeUnit(
                    fixture,
                    id: "utt-1",
                    precision: .utterance,
                    text: "overlapped",
                    analysisStart: 6,
                    analysisEnd: 7,
                    speaker: .ambiguous([
                        MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                        MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-1"),
                    ])
                ),
            ],
            activity: [
                MeetingBackendSpeakerActivity(
                    token: MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                    start: 1,
                    end: 1.4
                ),
            ]
        )
        XCTAssertEqual(try payload.validated(against: fixture.plan), payload)
    }

    func testEvidenceRejectsUnitsWithoutDeclaredPrecisionSupport() throws {
        let fixture = try self.makeEvidenceFixture(precisions: [.utterance])
        let payload = self.evidence(fixture, units: [self.makeUnit(fixture, id: "w-0", precision: .word)])
        XCTAssertThrowsError(try payload.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .unsupportedPrecision(unitID: "w-0", precision: .word)
            )
        }
    }

    func testEvidenceScopeValidationAdmitsInvalidTimingForQuarantine() throws {
        // Scope validation answers "does this reference something planned?", not "is this timing
        // usable?". Impossible bounds are quarantined per unit at assembly time so every input
        // unit still receives exactly one sidecar disposition.
        let fixture = try self.makeEvidenceFixture()
        let invalidIntervals: [(TimeInterval, TimeInterval)] = [
            (.nan, 2),
            (1, .nan),
            (1, .infinity),
            (-1, 2),
            (2, 2),
            (3, 1),
        ]
        for (start, end) in invalidIntervals {
            let payload = self.evidence(fixture, units: [
                self.makeUnit(fixture, analysisStart: start, analysisEnd: end),
            ])
            XCTAssertNoThrow(
                try payload.validated(against: fixture.plan),
                "start=\(start) end=\(end) is a quarantine matter, not a scope error"
            )
        }
    }

    func testEvidenceRejectsDuplicateAndEmptyUnitIdentifiers() throws {
        let fixture = try self.makeEvidenceFixture()
        let duplicates = self.evidence(fixture, units: [
            self.makeUnit(fixture, id: "same", analysisStart: 1, analysisEnd: 2),
            self.makeUnit(fixture, id: "same", analysisStart: 3, analysisEnd: 4),
        ])
        XCTAssertThrowsError(try duplicates.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .duplicateUnitID("same"))
        }

        let empty = self.evidence(fixture, units: [self.makeUnit(fixture, id: "  ")])
        XCTAssertThrowsError(try empty.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .emptyUnitID)
        }
    }

    func testEvidenceRejectsSourcesOutsideThePlannedScope() throws {
        let fixture = try self.makeEvidenceFixture()

        let unknownTrack = self.evidence(fixture, units: [self.makeUnit(
            fixture, trackID: UUID(), epoch: fixture.epoch
        )])
        XCTAssertThrowsError(try unknownTrack.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .unknownSourceTrack(unitID: "u-0"))
        }

        let noSpans = self.evidence(fixture, units: [self.makeUnit(fixture, analysisSpanIDs: [])])
        XCTAssertThrowsError(try noSpans.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .missingAnalysisSpans(unitID: "u-0"))
        }

        let duplicateSpans = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            analysisSpanIDs: ["span-0", "span-0"]
        )])
        XCTAssertThrowsError(try duplicateSpans.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .duplicateAnalysisSpanID(unitID: "u-0")
            )
        }

        // A microphone unit may not carry an epoch minted for the application track: the epoch is
        // what scopes speaker state, so crossing tracks here would silently merge identities.
        let foreignEpoch = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            epoch: MeetingAnalysisEpochID(trackID: fixture.otherTrackID, ordinal: 0)
        )])
        XCTAssertThrowsError(try foreignEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .analysisEpochOutOfScope(unitID: "u-0"))
        }

        let negativeEpoch = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            epoch: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: -1),
            speaker: .unassigned
        )])
        XCTAssertThrowsError(try negativeEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .invalidAnalysisEpochOrdinal(unitID: "u-0")
            )
        }
    }

    func testEvidenceRejectsSpeakerTokensFromAnotherEpochOrTrack() throws {
        let fixture = try self.makeEvidenceFixture()

        let laterEpochToken = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .assigned(MeetingBackendSpeakerToken(
                analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: 1),
                label: "slot-0"
            ))
        )])
        XCTAssertThrowsError(try laterEpochToken.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .speakerTokenOutOfScope(unitID: "u-0"))
        }

        let crossTrackCandidate = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .ambiguous([
                MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.otherTrackID, ordinal: 0),
                    label: "slot-0"
                ),
            ])
        )])
        XCTAssertThrowsError(try crossTrackCandidate.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .speakerTokenOutOfScope(unitID: "u-0"))
        }

        let singleCandidateAmbiguity = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .ambiguous([MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0")])
        )])
        XCTAssertThrowsError(try singleCandidateAmbiguity.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .invalidAmbiguity(unitID: "u-0"))
        }

        let emptyTokenLabel = self.evidence(fixture, units: [self.makeUnit(
            fixture,
            speaker: .assigned(MeetingBackendSpeakerToken(
                analysisEpochID: fixture.epoch,
                label: "  "
            ))
        )])
        XCTAssertThrowsError(try emptyTokenLabel.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .emptySpeakerTokenLabel(unitID: "u-0")
            )
        }
    }

    func testEvidenceScopeAdmitsOutOfRangeConfidenceForQuarantine() throws {
        // An out-of-range confidence is a value defect, not a scope violation: it quarantines the
        // unit at assembly rather than failing the payload. Absent confidence stays fine.
        let fixture = try self.makeEvidenceFixture()
        for value in [Double.nan, -0.01, 1.01, .infinity] {
            let payload = self.evidence(fixture, units: [self.makeUnit(fixture, confidence: value)])
            XCTAssertNoThrow(try payload.validated(against: fixture.plan), "confidence=\(value)")
        }
        let absent = self.evidence(fixture, units: [self.makeUnit(fixture, confidence: nil)])
        XCTAssertNoThrow(try absent.validated(against: fixture.plan))
    }

    func testEvidenceRejectsMismatchedBackendOrAttemptAndBadActivity() throws {
        let fixture = try self.makeEvidenceFixture()
        let otherBackend = MeetingBackendID(rawValue: "someone-else")

        let wrongBackend = MeetingFinalTranscriptEvidence(
            backendID: otherBackend,
            attemptID: fixture.plan.attemptID,
            units: [self.makeUnit(fixture)]
        )
        XCTAssertThrowsError(try wrongBackend.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .backendMismatch(expected: fixture.plan.backendID, actual: otherBackend)
            )
        }

        let wrongAttempt = MeetingFinalTranscriptEvidence(
            backendID: fixture.plan.backendID,
            attemptID: UUID(),
            units: [self.makeUnit(fixture)]
        )
        XCTAssertThrowsError(try wrongAttempt.validated(against: fixture.plan)) { error in
            guard case .attemptMismatch = (error as? MeetingBackendEvidenceError) else {
                return XCTFail("expected attemptMismatch, got \(error)")
            }
        }

        let badActivity = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(analysisEpochID: fixture.epoch, label: "slot-0"),
                start: 5,
                end: 5
            )]
        )
        XCTAssertThrowsError(try badActivity.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .invalidActivityTiming(index: 0))
        }

        let unplannedActivityTrack = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0),
                    label: "slot-0"
                ),
                start: 1,
                end: 2
            )]
        )
        XCTAssertThrowsError(try unplannedActivityTrack.validated(against: fixture.plan)) { error in
            XCTAssertEqual(error as? MeetingBackendEvidenceError, .activityTokenOutOfScope(index: 0))
        }

        let negativeActivityEpoch = self.evidence(
            fixture,
            units: [self.makeUnit(fixture)],
            activity: [MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(
                    analysisEpochID: MeetingAnalysisEpochID(trackID: fixture.trackID, ordinal: -1),
                    label: "slot-0"
                ),
                start: 1,
                end: 2
            )]
        )
        XCTAssertThrowsError(try negativeActivityEpoch.validated(against: fixture.plan)) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .invalidActivityEpochOrdinal(index: 0)
            )
        }
    }
}

/// Strict PCM admission must use the selected registered backend's input operation. No fixture
/// below loads weights or touches capture; the real host/runtime calls are counted and rejected.
@MainActor
final class MeetingPCMBackendAdmissionTests: XCTestCase {
    private nonisolated static let backendID = MeetingBackendID(rawValue: "synthetic-pcm-admission")
    private struct RuntimeReached: Error {}
    private struct BackendReached: Error {}
    private final class Probe {
        var dependencies = 0
        var runtime = 0
        var service = 0
        var pcmExecutor = 0
    }

    private final class PCMBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        let factory: MeetingParakeetNemotronRuntimeFactory
        let rewrite: @MainActor (MeetingBackendRequest) -> MeetingBackendRequest
        let probe: Probe
        let refuseExecutor: Bool
        init(descriptor: MeetingBackendDescriptor, context: MeetingBackendHostContext, probe: Probe,
             refuseExecutor: Bool = false,
             rewrite: @escaping @MainActor (MeetingBackendRequest) -> MeetingBackendRequest = { $0 }) {
            self.descriptor = descriptor; self.factory = context.parakeetNemotronRuntimeFactory
            self.probe = probe; self.refuseExecutor = refuseExecutor; self.rewrite = rewrite
        }
        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
            XCTFail("Strict PCM must not execute the recorded-chunk plan")
            throw BackendReached()
        }
        func execute(plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest?,
                     progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingBackendOutcome {
            XCTFail("Strict PCM must not execute the recorded-chunk executor")
            throw BackendReached()
        }
        func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode) throws {
            try self.descriptor.validatePCMInput(configuration: configuration, mode: mode)
        }
        func makePCMRuntime(_ request: MeetingBackendRequest) throws -> any MeetingParakeetNemotronRunning {
            self.probe.pcmExecutor += 1
            if self.refuseExecutor { throw BackendReached() }
            return try self.factory(self.rewrite(request))
        }
    }

    /// A capability declaration without an implemented PCM operation must also fail closed.
    private final class FileOnlyBackend: MeetingTranscriptionBackend {
        let descriptor: MeetingBackendDescriptor
        init(_ descriptor: MeetingBackendDescriptor) { self.descriptor = descriptor }
        func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan { MeetingBackendPlan(request: request, descriptor: self.descriptor) }
        func execute(plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest?,
                     progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingBackendOutcome { throw BackendReached() }
    }

    private func descriptor(id: MeetingBackendID = backendID, version: String = "1",
                            languages: Set<String> = ["en"], tracks: Set<MeetingAudioTrackKind> = [.microphone],
                            contract: MeetingBackendResultContract = .canonicalEvidence,
                            sampleRate: Double = 16_000,
                            inputs: Set<MeetingBackendInputKind> = [.recordedChunks, .boundedMicrophonePCM],
                            restrictions: [MeetingPCMAdmissionRestriction] = []) -> MeetingBackendDescriptor {
        MeetingBackendDescriptor(id: id, version: version, execution: .local,
            supportedLanguageCodes: languages, supportedTrackKinds: tracks, supportedFinalPrecisions: [.utterance],
            resultContract: contract, knownLimits: [], analysisSampleRate: sampleRate,
            diarizationDependencies: [.speakerSeparation, .voiceMatching], supportedInputs: inputs,
            pcmAdmissionRestrictions: restrictions)
    }

    private func syntheticRestriction() -> MeetingPCMAdmissionRestriction {
        MeetingPCMAdmissionRestriction(physicalDeviceModel: "fixture-tablet-v1", operatingSystemVersion: "99.4.2",
            asrArtifactFingerprint: "fixture-asr-export@sha256:exact-identity", speakerLabelsEnabled: true,
            piiRedactionEnabled: true, modelDisplayName: "Synthetic model", alternativeModelDisplayName: "Synthetic alternative")
    }

    private func session(backendID: MeetingBackendID = backendID, language: String = "en",
                         mode: MeetingCaptureMode = .inRoom) -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(mode: mode, title: "Synthetic", languageCode: language,
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"))
        var session = MeetingSession(configuration: configuration, timebase: .init(startedHostTime: 0,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.audioStorageMode = .memoryOnly
        session.recordingBackendID = backendID.rawValue
        return session
    }

    private func pipeline(_ registry: MeetingTranscriptionBackendRegistry, probe: Probe) -> MeetingProcessingPipeline {
        MeetingProcessingPipeline(asrServiceProvider: {
            probe.service += 1; XCTFail("Rejected input must not reach ASR residency")
            return ASRService()
        }, managesModelResidency: false, backendRegistry: registry, meetingRuntimeFactory: { _ in
            probe.runtime += 1; throw RuntimeReached()
        }, prepareDiarizationDependencies: { _ in probe.dependencies += 1 })
    }

    private func reject(_ pipeline: MeetingProcessingPipeline, session: MeetingSession,
                        expected: MeetingBackendError, probe: Probe) async {
        do {
            try await pipeline.prepareMemoryAudio(session: session, sessionDirectory: sessionDirectory,
                checkpoint: { _ in XCTFail("Rejected input cannot publish") })
            XCTFail("Unsupported/mismatched input must fail before microphone admission")
        } catch { XCTAssertEqual(error as? MeetingBackendError, expected) }
        XCTAssertEqual(probe.dependencies, 0)
        XCTAssertEqual(probe.runtime, 0)
        XCTAssertEqual(probe.service, 0)
        XCTAssertTrue(pipeline.memoryAttempts.isEmpty)
    }

    func testUnknownAndBothDeclaredAndBareLegacyCannotBorrowCanonicalPCM() async {
        let unknown = MeetingBackendID(rawValue: "synthetic-unknown")
        var probe = Probe()
        await self.reject(self.pipeline(.makeDefault(), probe: probe), session: self.session(backendID: unknown),
            expected: .unknownBackend(unknown), probe: probe)
        probe = Probe()
        await self.reject(self.pipeline(.makeDefault(), probe: probe), session: self.session(backendID: .legacyCompatibility),
            expected: .unsupportedInput(backend: .legacyCompatibility, input: .boundedMicrophonePCM), probe: probe)
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(.legacyCompatibility) { MeetingLegacyCompatibilityBackend(legacyExecutor: $0.legacyExecutor) }
        probe = Probe()
        await self.reject(self.pipeline(registry, probe: probe), session: self.session(backendID: .legacyCompatibility),
            expected: .unsupportedInput(backend: .legacyCompatibility, input: .boundedMicrophonePCM), probe: probe)
    }

    func testDeclaredCapabilityMustMatchFactoryLanguageTopologyResultAndInput() async {
        let declared = self.descriptor()
        let alternatives = [self.descriptor(languages: ["ru"]), self.descriptor(tracks: [.applicationAudio]),
            self.descriptor(contract: .legacyResult), self.descriptor(inputs: [.recordedChunks]),
            self.descriptor(sampleRate: 48_000)]
        for actual in alternatives {
            let probe = Probe()
            let registry = MeetingTranscriptionBackendRegistry()
            registry.register(Self.backendID, descriptor: declared) { context in PCMBackend(descriptor: actual, context: context, probe: probe) }
            await self.reject(self.pipeline(registry, probe: probe), session: self.session(),
                expected: .backendDescriptorMismatch(backend: Self.backendID), probe: probe)
        }
    }

    func testBareFactoryUsesItsActualLanguageTopologyAndResultContract() async {
        let invalid: [(MeetingBackendDescriptor, MeetingBackendError)] = [
            (self.descriptor(languages: ["ru"]), .unsupportedLanguage(backend: Self.backendID, languageCode: "en")),
            (self.descriptor(tracks: [.applicationAudio]), .unsupportedTrackTopology(backend: Self.backendID)),
            (self.descriptor(contract: .legacyResult), .outcomeContractMismatch(backend: Self.backendID, declared: .legacyResult)),
            (self.descriptor(sampleRate: 48_000), .unsupportedInput(backend: Self.backendID, input: .boundedMicrophonePCM))]
        for (descriptor, error) in invalid {
            let probe = Probe()
            let registry = MeetingTranscriptionBackendRegistry()
            registry.register(Self.backendID) { context in PCMBackend(descriptor: descriptor, context: context, probe: probe) }
            await self.reject(self.pipeline(registry, probe: probe), session: self.session(), expected: error, probe: probe)
        }
    }

    func testFactoryIdentityAndUnsupportedCaptureTopologyFailBeforePreparation() async {
        let probe = Probe()
        let registry = MeetingTranscriptionBackendRegistry()
        let otherID = MeetingBackendID(rawValue: "synthetic-other")
        let otherDescriptor = self.descriptor(id: otherID)
        registry.register(Self.backendID) { context in PCMBackend(descriptor: otherDescriptor, context: context, probe: probe) }
        await self.reject(self.pipeline(registry, probe: probe), session: self.session(),
            expected: .backendIdentityMismatch(requested: Self.backendID, produced: otherID), probe: probe)
        let descriptor = self.descriptor()
        registry.register(Self.backendID) { context in PCMBackend(descriptor: descriptor, context: context, probe: probe) }
        await self.reject(self.pipeline(registry, probe: probe), session: self.session(mode: .onlineCall),
            expected: .unsupportedTrackTopology(backend: Self.backendID), probe: probe)
    }

    func testClaimedPCMCapabilityWithoutImplementedAdmissionIsRejected() async {
        let descriptor = self.descriptor()
        let probe = Probe()
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(Self.backendID, descriptor: descriptor) { _ in FileOnlyBackend(descriptor) }
        await self.reject(self.pipeline(registry, probe: probe), session: self.session(),
            expected: .unsupportedInput(backend: Self.backendID, input: .boundedMicrophonePCM), probe: probe)
    }

    func testRecordedChunkPathAlsoHonoursItsDeclaredInputCapability() async throws {
        let descriptor = self.descriptor(inputs: [.boundedMicrophonePCM])
        let probe = Probe()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: Self.backendID)
        registry.register(Self.backendID, descriptor: descriptor) { context in PCMBackend(descriptor: descriptor, context: context, probe: probe) }
        // Retained processing authenticates an existing checkpoint before selecting a backend.
        // Use an owned recording directory so invalid-directory validation cannot mask admission.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordedAdmission.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = self.session()
        session.audioStorageMode = .retainedFiles
        session.audioTracks = [MeetingAudioTrack(id: UUID(), kind: .microphone,
            sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic", format: nil, timebase: session.timebase,
            health: .waiting, chunks: [MeetingAudioChunk(id: UUID(), sequence: 0, relativeFilePath: "synthetic.caf",
                presentationStart: .init(value: 0, timescale: 1), presentationEnd: .init(value: 1, timescale: 1),
                discontinuities: [], sha256: "synthetic", byteCount: 1, finalizationState: .finalized)])]
        do {
            _ = try await self.pipeline(registry, probe: probe).process(session: session,
                sessionDirectory: directory, progress: { _ in })
            XCTFail("PCM-only registration cannot be silently treated as a file executor")
        } catch { XCTAssertEqual(error as? MeetingBackendError, .unsupportedInput(backend: Self.backendID, input: .recordedChunks)) }
        XCTAssertEqual(probe.dependencies, 0)
        XCTAssertEqual(probe.runtime, 0)
        XCTAssertEqual(probe.service, 0)
        XCTAssertEqual(probe.pcmExecutor, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            "Unsupported input cannot create inference caches or publish a processing result")
    }

    func testSelectedBackendOwnsPCMExecutorRatherThanSubstitutingHostRuntime() async {
        let descriptor = self.descriptor()
        let probe = Probe()
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(Self.backendID, descriptor: descriptor) { context in PCMBackend(descriptor: descriptor, context: context, probe: probe, refuseExecutor: true) }
        do {
            try await self.pipeline(registry, probe: probe).prepareMemoryAudio(session: self.session(),
                sessionDirectory: sessionDirectory, checkpoint: { _ in })
            XCTFail("The selected backend's refusal must be respected")
        } catch is BackendReached { } catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(probe.pcmExecutor, 1)
        XCTAssertEqual(probe.runtime, 0)
        XCTAssertEqual(probe.service, 0)
    }

    func testPCMHostCapabilityRejectsSubstitutedFrozenRequest() async {
        let descriptor = self.descriptor()
        let probe = Probe()
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(Self.backendID, descriptor: descriptor) { context in
            PCMBackend(descriptor: descriptor, context: context, probe: probe, rewrite: { request in
                MeetingBackendRequest(attemptID: UUID(), session: request.session, sessionDirectory: request.sessionDirectory,
                    configuration: request.configuration)
            })
        }
        do {
            try await self.pipeline(registry, probe: probe).prepareMemoryAudio(session: self.session(),
                sessionDirectory: sessionDirectory, checkpoint: { _ in })
            XCTFail("PCM cannot borrow a runtime for a substituted attempt")
        } catch { XCTAssertEqual(error as? MeetingBackendError, .hostCapabilityRequestMismatch(backend: Self.backendID)) }
        XCTAssertEqual(probe.pcmExecutor, 1)
        XCTAssertEqual(probe.runtime, 0)
        XCTAssertEqual(probe.service, 0)
    }

    func testBareFactoryCannotChangeCapabilitiesBetweenAdmissionAndFrozenExecution() async {
        let probe = Probe()
        let admitted = self.descriptor()
        let changed = self.descriptor(version: "2")
        var constructions = 0
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(Self.backendID) { context in
            constructions += 1
            return PCMBackend(descriptor: constructions == 1 ? admitted : changed, context: context, probe: probe)
        }
        do {
            try await self.pipeline(registry, probe: probe).prepareMemoryAudio(session: self.session(),
                sessionDirectory: sessionDirectory, checkpoint: { _ in })
            XCTFail("Admitted capabilities must survive dependency preparation")
        } catch { XCTAssertEqual(error as? MeetingBackendError, .backendDescriptorMismatch(backend: Self.backendID)) }
        XCTAssertEqual(constructions, 2)
        XCTAssertEqual(probe.dependencies, 1)
        XCTAssertEqual(probe.runtime, 0)
        XCTAssertEqual(probe.service, 0)
        XCTAssertEqual(probe.pcmExecutor, 0)
    }

    func testInputAdmissionConfigurationUsesRegisteredModelWithoutArtifactIO() throws {
        for modelID in ["gigaam-v3-eou", "whisper-tiny", "parakeet-tdt"] {
            let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: modelID))
            let configuration = PichiMeetingProviderFactory.validationConfiguration(backendID: descriptor.id,
                languageCode: modelID == "gigaam-v3-eou" ? "ru" : "auto", diarizationEnabled: true)
            XCTAssertEqual(configuration.asrModel, modelID)
            XCTAssertNil(configuration.asrArtifactDirectory)
            if modelID == PichiMeetingProviderFactory.gigaamModelID {
                // Admission reads catalog identity/file-presence metadata, not weight bytes.
                XCTAssertTrue(configuration.asrArtifactFingerprint?.hasPrefix("gigaam-native-v1/") == true)
            } else { XCTAssertNil(configuration.asrArtifactFingerprint) }
            XCTAssertTrue(configuration.diarizationFingerprint.hasPrefix("unavailable:"))
            XCTAssertNoThrow(try MeetingProviderOptions.resolve(configuration))
        }
    }

    func testPreinstalledArtifactIdentityStaysPinnedAcrossDependencyPreparation() async throws {
        let suite = "PinnedPCMArtifact.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        var source = self.session(backendID: .whisperTiny, language: "en")
        let approvedIdentity = "approved-synthetic-tiny-identity"
        source.recordingASRArtifactFingerprint = approvedIdentity
        var frozenRequest: MeetingBackendRequest?
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { XCTFail("Runtime marker precedes ASR residency"); return ASRService() },
            managesModelResidency: false, settings: settings, backendRegistry: .makeDefault(),
            meetingRuntimeFactory: { request in frozenRequest = request; throw RuntimeReached() },
            prepareDiarizationDependencies: { _ in source.recordingASRArtifactFingerprint = "later-unapproved-identity" })
        do {
            try await pipeline.prepareMemoryAudio(session: source, sessionDirectory: sessionDirectory,
                checkpoint: { _ in XCTFail("The runtime marker cannot publish a checkpoint") })
            XCTFail("Expected the requested runtime marker")
        } catch is RuntimeReached { }
        let request = try XCTUnwrap(frozenRequest)
        XCTAssertEqual(source.recordingASRArtifactFingerprint, "later-unapproved-identity")
        XCTAssertEqual(request.session.recordingASRArtifactFingerprint, approvedIdentity)
        XCTAssertEqual(request.configuration.asrArtifactFingerprint, approvedIdentity)
        XCTAssertEqual(request.configuration.asrModel, PichiMeetingProviderFactory.whisperTinyModelID)
        XCTAssertTrue(pipeline.memoryAttempts.isEmpty)
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
    }

    func testAllProductionPCMRegistrationsDispatchThroughTheirRuntimeOperation() async {
        for backendID in [MeetingBackendID.gigaam, .whisperTiny, .parakeetV3, .parakeetNemotron] {
            let language = backendID == .gigaam ? "ru" : "en"
            let probe = Probe()
            let registry = MeetingTranscriptionBackendRegistry.makeDefault()
            XCTAssertTrue(registry.descriptor(for: backendID)?.supportedInputs.contains(.boundedMicrophonePCM) == true)
            do {
                try await self.pipeline(registry, probe: probe).prepareMemoryAudio(session: self.session(backendID: backendID, language: language),
                    sessionDirectory: sessionDirectory, checkpoint: { _ in })
                XCTFail("Injected runtime marker must be reached through the selected backend")
            } catch is RuntimeReached { } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(probe.dependencies, 1)
            XCTAssertEqual(probe.runtime, 1)
            XCTAssertEqual(probe.service, 0)
        }
    }

    func testRegisteredProviderValidatesPinnedASRModelBeforeDependencyPreparation() async {
        let probe = Probe()
        let descriptor = PichiMeetingProviderFactory.registeredBackendDescriptor(for: "whisper-tiny")!
        let registry = MeetingTranscriptionBackendRegistry()
        registry.register(.whisperTiny, descriptor: descriptor) { context in
            MeetingProviderBackedBackend(descriptor: descriptor, providerModelID: "gigaam-v3-eou", runtimeFactory: context.parakeetNemotronRuntimeFactory)
        }
        do {
            try await self.pipeline(registry, probe: probe).prepareMemoryAudio(session: self.session(backendID: .whisperTiny),
                sessionDirectory: sessionDirectory, checkpoint: { _ in })
            XCTFail("Factory/provider mismatch cannot reach model work")
        } catch { XCTAssertEqual(error as? MeetingProviderOptionsError, .unsupportedASRModel("whisper-tiny")) }
        XCTAssertEqual(probe.dependencies, 0)
        XCTAssertEqual(probe.runtime, 0)
        XCTAssertEqual(probe.service, 0)
    }

    func testDeclaredPCMRestrictionIsExactAcrossConfigurationMatrix() throws {
        // Catalog restrictions change when measured execution routes change. Test the generic
        // restriction contract with fixed synthetic metadata rather than an obsolete device ban.
        let restriction = self.syntheticRestriction()
        let descriptor = self.descriptor(restrictions: [restriction])
        let deviceModels: [String?] = [restriction.physicalDeviceModel, "fixture-tablet-v2", nil]
        let systemVersions = [restriction.operatingSystemVersion, "99.4.1", "100.0.0"]
        let artifacts: [String?] = [restriction.asrArtifactFingerprint, "fixture-other-export", nil]
        var rejected = 0
        for device in deviceModels {
            for systemVersion in systemVersions {
                for artifact in artifacts {
                    for speakers in [false, true] {
                        for pii in [false, true] {
                            let configuration = MeetingFinalProcessingConfiguration(asrModel: "fixture-asr",
                                asrArtifactFingerprint: artifact, languageCode: "en", speakerLabelsEnabled: speakers)
                            let context = MeetingPCMAdmissionContext(physicalDeviceModel: device,
                                operatingSystemVersion: systemVersion, piiRedactionEnabled: pii)
                            let mustReject = device == restriction.physicalDeviceModel
                                && systemVersion == restriction.operatingSystemVersion
                                && artifact == restriction.asrArtifactFingerprint && speakers && pii
                            do {
                                try descriptor.validatePCMInput(configuration: configuration, mode: .inRoom, admissionContext: context)
                                XCTAssertFalse(mustReject, "The exact declared combination must be rejected")
                            } catch {
                                rejected += 1
                                XCTAssertTrue(mustReject, "Neighbor configurations must remain admissible")
                                XCTAssertEqual(error as? MeetingBackendError,
                                    .unsupportedPCMConfiguration(backend: descriptor.id, restriction: restriction))
                                XCTAssertTrue(error.localizedDescription.contains(restriction.modelDisplayName))
                                XCTAssertTrue(error.localizedDescription.contains(restriction.alternativeModelDisplayName))
                            }
                        }
                    }
                }
            }
        }
        XCTAssertEqual(rejected, 1, "Only one of the 108 synthetic combinations is restricted")
        let configuration = MeetingFinalProcessingConfiguration(asrModel: "fixture-asr",
            asrArtifactFingerprint: restriction.asrArtifactFingerprint, languageCode: "en", speakerLabelsEnabled: true)
        let context = MeetingPCMAdmissionContext(physicalDeviceModel: restriction.physicalDeviceModel,
            operatingSystemVersion: restriction.operatingSystemVersion, piiRedactionEnabled: true)
        let unrestricted = self.descriptor()
        XCTAssertNoThrow(try unrestricted.validatePCMInput(configuration: configuration, mode: .inRoom, admissionContext: context))
        var retained = self.session(backendID: descriptor.id)
        retained.audioStorageMode = .retainedFiles
        retained.piiRedactionEnabled = true
        let wrongInput = MeetingBackendRequest(attemptID: UUID(), session: retained,
            sessionDirectory: URL(fileURLWithPath: "/synthetic"), configuration: configuration)
        XCTAssertThrowsError(try descriptor.validatePCMInput(wrongInput, admissionContext: context)) { error in
            XCTAssertEqual(error as? MeetingBackendError, .unsupportedTrackTopology(backend: descriptor.id),
                "A deployment restriction must not reinterpret retained-file input as strict PCM")
        }
    }

    func testFrozenArtifactAndPIIRestrictionRejectBeforeResourcePreparation() async {
        let restriction = self.syntheticRestriction()
        // A synthetic factory at a registered configuration boundary exercises the real frozen
        // artifact override without depending on restrictions in the current production catalog.
        let descriptor = self.descriptor(id: .whisperTiny, restrictions: [restriction])
        let probe = Probe()
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: descriptor.id)
        registry.register(descriptor.id, descriptor: descriptor) { context in
            PCMBackend(descriptor: descriptor, context: context, probe: probe)
        }
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: {
            probe.service += 1; XCTFail("Admission must precede ASR residency"); return ASRService()
        }, managesModelResidency: false, privacyRedactorProvider: {
            XCTFail("Unsupported input must not prepare the privacy model"); return nil
        }, pcmAdmissionContextProvider: { pii in
            .init(physicalDeviceModel: restriction.physicalDeviceModel,
                operatingSystemVersion: restriction.operatingSystemVersion, piiRedactionEnabled: pii)
        }, backendRegistry: registry, meetingRuntimeFactory: { _ in
            probe.runtime += 1; throw RuntimeReached()
        }, prepareDiarizationDependencies: { _ in probe.dependencies += 1 })
        var session = self.session(backendID: descriptor.id)
        session.piiRedactionEnabled = true
        session.speakerLabelsEnabled = true
        session.recordingASRArtifactFingerprint = restriction.asrArtifactFingerprint
        await self.reject(pipeline, session: session,
            expected: .unsupportedPCMConfiguration(backend: descriptor.id, restriction: restriction), probe: probe)
        XCTAssertEqual(probe.pcmExecutor, 0)
    }

    func testFrozenPublicExportAndA1PrivacyAdmissionPreserveTheRegisteredRoute() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        struct UnusedRedactor: TranscriptTextRedacting {
            func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
                XCTFail("Admission cannot transcribe or redact text")
                return .init(text: text, spans: [])
            }
        }
        let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: PichiMeetingProviderFactory.gigaamModelID))
        let fingerprint = GigaAMModelCatalog.downloadableModel.fingerprint
        // The new text-privacy resource is independent of ASR/backend identity. This is
        // admission coverage only; the injected adapter never claims native A1 inference.
        XCTAssertEqual(PichiTranscriptPrivacyModelStore.descriptor, PIIModelDescriptor.russianA1)
        XCTAssertTrue(descriptor.pcmAdmissionRestrictions.isEmpty)
        for privacyAvailable in [false, true] {
            let probe = Probe()
            var frozenRequest: MeetingBackendRequest?
            var privacyLookups = 0
            let pipeline = MeetingProcessingPipeline(asrServiceProvider: {
                probe.service += 1; XCTFail("Admission marker precedes ASR residency"); return ASRService()
            }, managesModelResidency: false, privacyRedactorProvider: {
                privacyLookups += 1
                return privacyAvailable ? UnusedRedactor() : nil
            }, pcmAdmissionContextProvider: { pii in
                .init(physicalDeviceModel: "iPad7,1", operatingSystemVersion: "17.7.10", piiRedactionEnabled: pii)
            }, backendRegistry: .makeDefault(), meetingRuntimeFactory: { request in
                frozenRequest = request
                probe.runtime += 1
                throw RuntimeReached()
            }, prepareDiarizationDependencies: { _ in probe.dependencies += 1 })
            var session = self.session(backendID: .gigaam, language: "ru")
            session.piiRedactionEnabled = true
            session.speakerLabelsEnabled = true
            session.recordingASRArtifactFingerprint = fingerprint
            do {
                try await pipeline.prepareMemoryAudio(session: session,
                    sessionDirectory: sessionDirectory,
                    checkpoint: { _ in XCTFail("Admission cannot publish") })
                XCTFail("An unavailable privacy adapter or runtime marker must stop preparation")
            } catch is RuntimeReached {
                XCTAssertTrue(privacyAvailable)
            } catch {
                XCTAssertFalse(privacyAvailable)
                guard let privacyError = error as? MeetingPrivacyPublicationError,
                      case .redactorUnavailable = privacyError else {
                    XCTFail("Unexpected admission error: \(error)")
                    continue
                }
            }
            XCTAssertEqual(probe.dependencies, 1)
            XCTAssertEqual(privacyLookups, 1)
            XCTAssertEqual(probe.runtime, privacyAvailable ? 1 : 0)
            XCTAssertEqual(probe.service, 0)
            XCTAssertTrue(pipeline.memoryAttempts.isEmpty)
            if privacyAvailable {
                let request = try XCTUnwrap(frozenRequest)
                XCTAssertEqual(request.session, session)
                XCTAssertEqual(request.configuration.asrModel, PichiMeetingProviderFactory.gigaamModelID)
                XCTAssertEqual(request.configuration.asrArtifactFingerprint, fingerprint)
                XCTAssertTrue(request.configuration.speakerLabelsEnabled)
            } else { XCTAssertNil(frozenRequest) }
        }
    }
}

#if DEBUG
/// The production strict pipeline selects scheduling from the registered descriptor and
/// runtime capability, then applies the same privacy owner to progressive observations.
@MainActor
final class MeetingPCMProgressivePipelineTests: XCTestCase {
    private final nonisolated class Runtime: MeetingParakeetNemotronRunning, @unchecked Sendable {
        let supportsProgressivePCMInput: Bool
        private let lock = NSLock()
        private var sealedCount = 0
        private var progressiveCount = 0
        private var seenConfigurations: [MeetingFinalProcessingConfiguration] = []
        var sealedCalls: Int { lock.withLock { sealedCount } }
        var progressiveCalls: Int { lock.withLock { progressiveCount } }
        var configurations: [MeetingFinalProcessingConfiguration] { lock.withLock { seenConfigurations } }
        let sourceID = UUID()
        init(progressive: Bool) { supportsProgressivePCMInput = progressive }
        nonisolated func preparePCMResources(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws { }
        nonisolated func withPreparedASR(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
            body: nonisolated(nonsending) @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult) async throws -> MeetingParakeetPhaseResult {
            // Preparation's body is empty and must not perform inference.
            return try await body(EmptyASR())
        }
        private nonisolated struct EmptyASR: MeetingParakeetASRSession {
            func transcribeWithTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
                XCTFail("PCM runtime fixture cannot call an independent ASR operation")
                return (ASRTranscriptionResult(text: "", confidence: 0), [])
            }
        }
        nonisolated func withNemotronDiarization(artifact: MeetingNemotronModelArtifact,
            _ body: nonisolated(nonsending) @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult) async throws -> MeetingNemotronPhaseResult {
            XCTFail("Speaker labels are disabled in this scheduling fixture")
            throw MeetingModelResidencyError.unsupportedProvider
        }
        private func record(progressive: Bool, configuration: MeetingFinalProcessingConfiguration) {
            lock.withLock {
                if progressive { progressiveCount += 1 } else { sealedCount += 1 }
                seenConfigurations.append(configuration)
            }
        }
        private nonisolated func batch(frames: Int, offset: Double, track: UUID, provisional: Bool) -> MeetingPCMTranscriptBatch {
            let text = "обсудим документ сегодня. продолжим встречу после перерыва. Иван Тестов просит копию документа после встречи."
            var output = MeetingPCMTranscriptBatch(segments: [.init(id: sourceID,
                start: .init(value: Int64((offset * 16_000).rounded()), timescale: 16_000),
                end: .init(value: Int64((offset * 16_000).rounded()) + Int64(frames), timescale: 16_000),
                sourceTrackID: track, speakerID: nil, text: text, originalText: text, revision: 0,
                status: provisional ? .provisional : .final, overlap: .none, completeness: .complete)],
                isComplete: !provisional)
            output.speechObservationIsFinal = !provisional
            return output
        }
        nonisolated func recognizePCM(samples: [Float], offset: TimeInterval, trackID: UUID,
            attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws -> MeetingPCMTranscriptBatch {
            // Post-Stop replay calls the final operation without a preview callback.
            // The production pipeline reads at most one 20-second archive window.
            guard !samples.isEmpty, samples.count <= 320_000 else {
                throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
            }
            return try await recognizePCM(samples: samples, offset: offset, trackID: trackID,
                attemptID: attemptID, configuration: configuration, preview: nil)
        }
        nonisolated func recognizePCM(samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
            configuration: MeetingFinalProcessingConfiguration,
            preview: (nonisolated(nonsending) @Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch {
            record(progressive: false, configuration: configuration)
            if let preview {
                try await preview(batch(frames: samples.count, offset: offset, track: trackID, provisional: true))
                try await preview(batch(frames: samples.count, offset: offset, track: trackID, provisional: false))
            }
            return batch(frames: samples.count, offset: offset, track: trackID, provisional: false)
        }
        nonisolated func recognizePCM(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
            trackID: UUID, attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
            preview: (nonisolated(nonsending) @Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch {
            record(progressive: true, configuration: configuration)
            var frames = 0
            while let update = try await window.next() {
                frames = update.totalFrames
                if !update.samples.isEmpty, let preview {
                    try await preview(batch(frames: frames, offset: offset, track: trackID, provisional: true))
                }
                if update.isFinal {
                    // Mirror the real runtime: sealing admits the final hypothesis without
                    // waiting for a second inference on an already complete PCM window.
                    if let preview { try await preview(batch(frames: frames, offset: offset, track: trackID, provisional: false)) }
                    return batch(frames: frames, offset: offset, track: trackID, provisional: false)
                }
            }
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
    }
    private struct PersonRedactor: TranscriptTextRedacting {
        let permitsProvisionalDisplay: Bool
        func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
            let source = text as NSString
            let range = source.range(of: "Иван Тестов")
            let ner: [PIINERSpan] = range.location == NSNotFound ? [] : [.init(range: range, label: "PER", score: 1)]
            // Only NER identity is synthetic. Canonical replacements and provisional
            // admission use the same production adapter guard as the real privacy service.
            let output = try PIIRedactor.redact(text, ner: ner)
            return .init(text: output.text,
                spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) },
                provisionalSafeUTF16: permitsProvisionalDisplay
                    ? try PIIRedactor.provisionalSafePrefix(in: text, ner: ner, redactedSpans: output.spans) : nil)
        }
    }
    private struct RefusingRedactor: TranscriptTextRedacting {
        struct Refused: Error {}
        func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction { throw Refused() }
    }
    private final class Observations {
        var previews: [MeetingLivePartial?] = []
        var checkpoints: [MeetingPCMTranscriptBatch] = []
    }
    private func descriptor(policy: Bool) throws -> MeetingBackendDescriptor {
        let original = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: "whisper-tiny"))
        return .init(id: original.id, version: original.version, execution: original.execution,
            supportedLanguageCodes: original.supportedLanguageCodes, supportedTrackKinds: original.supportedTrackKinds,
            supportedFinalPrecisions: original.supportedFinalPrecisions, resultContract: original.resultContract,
            knownLimits: original.knownLimits, analysisSampleRate: original.analysisSampleRate,
            diarizationDependencies: original.diarizationDependencies, supportedInputs: original.supportedInputs,
            pcmObservationPolicy: policy ? original.pcmObservationPolicy : nil)
    }
    private func sample() throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        let data = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<48_000 { data[index] = 0.1 }
        return try MeetingCapturePCMConverter.sampleBuffer(buffer: buffer, presentationTime: .zero)
    }
    private func verifyScheduling(policy: Bool, capability: Bool, privacy: Bool,
                                  refusingPrivacy: Bool = false, permitsProvisionalDisplay: Bool = true,
                                  completesAttempt: Bool = false) async throws {
        let runtime = Runtime(progressive: capability)
        let registered = try descriptor(policy: policy)
        let registry = MeetingTranscriptionBackendRegistry(defaultBackendID: .whisperTiny)
        registry.register(.whisperTiny, descriptor: registered) { context in
            MeetingProviderBackedBackend(descriptor: registered, providerModelID: "whisper-tiny",
                runtimeFactory: context.parakeetNemotronRuntimeFactory)
        }
        let suite = "ProgressivePipeline.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        service.meetingModelParticipantsForTesting = []
        let lease = try service.acquireExclusiveActivity(.meeting)
        addTeardownBlock { await MainActor.run { service.releaseExclusiveActivity(lease) } }
        let observations = Observations()
        let redactor: any TranscriptTextRedacting = refusingPrivacy ? RefusingRedactor() : PersonRedactor(permitsProvisionalDisplay: permitsProvisionalDisplay)
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { service }, settings: settings,
            privacyRedactorProvider: { redactor }, backendRegistry: registry,
            meetingRuntimeFactory: { _ in runtime }, prepareDiarizationDependencies: { _ in
                XCTFail("Disabled speaker labels cannot prepare speaker weights")
            })
        let capture = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic", languageCode: "auto",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"),
            audioStorageMode: .memoryOnly, speakerLabelsEnabled: false, piiRedactionEnabled: privacy)
        var session = MeetingSession(configuration: capture, timebase: .init(startedHostTime: 0,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.recordingBackendID = MeetingBackendID.whisperTiny.rawValue
        session.recordingASRArtifactFingerprint = "synthetic-pinned-artifact"
        let sessionID = session.id
        addTeardownBlock { await pipeline.cancelMemoryAudio(sessionID: sessionID) }
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: session.timebase, health: .waiting, chunks: [])
        try await pipeline.prepareMemoryAudio(session: session, sessionDirectory: URL(fileURLWithPath: "/synthetic-never-created"),
            checkpoint: { observations.checkpoints.append($0) }, preview: { observations.previews.append($0) })
        settings.selectedSpeechModel = .gigaam
        let consumer = try await pipeline.memoryConsumer(for: session.id, track: track, eventHandler: { _ in })
        XCTAssertTrue(consumer.enqueue(try sample()))
        // The archive owns complete RAM audio even if optional live privacy fails.
        // Such a failure is joined here and retried by process after Stop.
        try await consumer.finish()
        let progressiveCalls = runtime.progressiveCalls
        let sealedCalls = runtime.sealedCalls
        XCTAssertEqual(progressiveCalls, policy && capability ? 1 : 0)
        XCTAssertEqual(sealedCalls, policy && capability ? 0 : 1)
        let configurations = runtime.configurations
        XCTAssertEqual(configurations.count, 1)
        XCTAssertEqual(configurations.first?.asrModel, "whisper-tiny")
        XCTAssertEqual(configurations.first?.asrArtifactFingerprint, "synthetic-pinned-artifact")
        if privacy {
            XCTAssertFalse(observations.previews.isEmpty)
            XCTAssertNil(observations.previews.first.flatMap { $0 },
                "The first unconfirmed hypothesis must not bypass the stability guard")
        }
        if refusingPrivacy {
            XCTAssertTrue(observations.previews.compactMap { $0 }.isEmpty,
                "A nil preview clears the UI; no protected or raw text may be published")
            XCTAssertTrue(observations.checkpoints.isEmpty)
            XCTAssertTrue(pipeline.memoryAttempts[session.id]?.recordingConsumer?.requiresSpeechReplay == true)
            session.audioTracks = [track]
            do {
                _ = try await pipeline.process(session: session,
                    sessionDirectory: URL(fileURLWithPath: "/synthetic-never-created"), progress: { _ in })
                XCTFail("A persistent privacy failure must reject the complete post-Stop replay")
            } catch {
                XCTAssertTrue(error is RefusingRedactor.Refused,
                    "Unexpected replay failure type: \(type(of: error))")
            }
            XCTAssertEqual(runtime.sealedCalls, 1, "Post-Stop privacy failure must come from an actual replay")
            XCTAssertTrue(runtime.configurations.allSatisfy {
                $0.asrModel == "whisper-tiny" && $0.asrArtifactFingerprint == "synthetic-pinned-artifact"
            }, "Replay must retain the admitted model after global selection changes")
            XCTAssertTrue(observations.previews.compactMap { $0 }.isEmpty)
            XCTAssertTrue(observations.checkpoints.isEmpty)
        } else if privacy {
            let shown = observations.previews.compactMap { $0?.text }
            if permitsProvisionalDisplay {
                XCTAssertFalse(shown.isEmpty, "An adapter-approved safe prefix reaches the UI")
            } else {
                XCTAssertTrue(shown.isEmpty, "Privacy without adapter approval cannot invent a display prefix")
            }
            XCTAssertTrue(shown.allSatisfy { !$0.contains("Иван") && !$0.contains("Тестов") })
            let saved = observations.checkpoints.flatMap(\.segments)
            XCTAssertEqual(saved.count, 1, "Privacy finalization checkpoints the held tail exactly once")
            XCTAssertTrue(saved.allSatisfy { $0.originalText == nil && !$0.text.contains("Иван") && !$0.text.contains("Тестов") })
            XCTAssertTrue(saved.first?.text.contains("[ИМЯ]") == true)
            XCTAssertEqual(saved.first?.id, runtime.sourceID)
            XCTAssertEqual(saved.first?.start.seconds, 0)
            XCTAssertEqual(saved.first?.end.seconds, 3)
        } else {
            XCTAssertEqual(observations.checkpoints.flatMap(\.segments).count, 1)
        }
        if completesAttempt {
            let frozen = try XCTUnwrap(pipeline.memoryAttempts[session.id]?.request)
            // The coordinator adds an unrelated pending record after Stop. Its nil/stale
            // identity fields must never replace the admitted runtime's provenance.
            let unrelatedID = UUID()
            session.processingAttempts.append(.init(id: unrelatedID, startedAt: Date(),
                completedAt: nil, stage: .pending, pipelineVersion: -1, asrProvider: "stale",
                asrModel: "stale", languageCode: "stale", asrArtifactFingerprint: "stale",
                diarizationModel: nil, lastCompletedTrackID: nil, errorCode: nil))
            session.audioTracks = [track]
            session.transcriptSegments = observations.checkpoints.flatMap(\.segments)
            let result = try await pipeline.process(session: session,
                sessionDirectory: URL(fileURLWithPath: "/synthetic-never-created"), progress: { _ in })
            XCTAssertEqual(result.attempt.id, frozen.attemptID)
            XCTAssertNotEqual(result.attempt.id, unrelatedID)
            XCTAssertEqual(result.attempt.stage, .completed)
            XCTAssertNotNil(result.attempt.completedAt)
            XCTAssertEqual(result.attempt.pipelineVersion, frozen.configuration.pipelineVersion)
            XCTAssertEqual(result.attempt.asrModel, frozen.configuration.asrModel)
            XCTAssertEqual(result.attempt.languageCode, frozen.configuration.languageCode)
            XCTAssertEqual(result.attempt.asrArtifactFingerprint, frozen.configuration.asrArtifactFingerprint)
            XCTAssertEqual(result.attempt.diarizationModel, frozen.configuration.diarizationFingerprint)
            XCTAssertEqual(result.attempt.backendID, registered.id.rawValue)
            XCTAssertEqual(result.attempt.asrProvider, registered.id.rawValue)
            XCTAssertEqual(result.attempt.backendVersion, registered.version)
            XCTAssertFalse(result.segments.isEmpty)
            XCTAssertTrue(result.segments.allSatisfy { $0.originalText == nil && !$0.text.contains("Иван") })
        } else {
            await pipeline.cancelMemoryAudio(sessionID: session.id)
        }
        XCTAssertTrue(pipeline.memoryAttempts.isEmpty)
    }
    func testCompletedStrictAttemptRetainsFrozenRuntimeLineageAndProtectedText() async throws {
        try await verifyScheduling(policy: true, capability: true, privacy: true, completesAttempt: true)
    }
    func testRegisteredPolicyAndRuntimeCapabilitySelectProgressiveInput() async throws {
        try await verifyScheduling(policy: true, capability: true, privacy: false)
    }
    func testRegisteredPreferenceKeepsLegacyRuntimeOnSealedInput() async throws {
        try await verifyScheduling(policy: true, capability: false, privacy: false)
    }
    func testRuntimeCapabilityWithoutRegisteredPolicyKeepsSealedInput() async throws {
        try await verifyScheduling(policy: false, capability: true, privacy: false)
    }
    func testProgressivePreviewAndFinalCheckpointKeepStrictPIIGuards() async throws {
        try await verifyScheduling(policy: true, capability: true, privacy: true)
    }
    func testProgressivePrivacyWithoutAdapterApprovalWithholdsProvisionalDisplay() async throws {
        try await verifyScheduling(policy: true, capability: true, privacy: true, permitsProvisionalDisplay: false)
    }
    func testProgressivePrivacyFailureCannotPublishRawPreviewOrCheckpoint() async throws {
        try await verifyScheduling(policy: true, capability: true, privacy: true, refusingPrivacy: true)
    }
}
#endif
