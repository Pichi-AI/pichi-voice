import XCTest
@testable import FluidVoice_Debug

/// Issue 197: a speaker model download used to hold ordinary model admission for the whole transfer,
/// so a local summary, processing without speaker labels and the dictation restoration after a meeting
/// were refused with "busy". Only publication, the step that changes installed storage, takes the
/// admission now. No test here uses the network: install steps are synthetic.
@MainActor
final class SpeakerModelPublicationAdmissionTests: XCTestCase {
    private struct Missing: Error {}

    private nonisolated static let artifact = MeetingNemotronModelArtifact(
        packageURL: URL(fileURLWithPath: "/synthetic-unused"), totalByteCount: 1, fileCount: 1,
        manifestSHA256: "synthetic", entryMetadataSHA256: "synthetic", profile: .fast32SplitW8A8)

    private nonisolated static let busyMessage = MeetingModelResidencyError.busy.localizedDescription

    private actor Latch {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters = []
            pending.forEach { $0.resume() }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Bool { self.count > 0 }
        var total: Int { self.lock.lock(); defer { self.lock.unlock() }; return self.count }
        func set() { self.lock.lock(); self.count += 1; self.lock.unlock() }
    }

    private final class IdleProbe: MeetingIdlePreparedResource, @unchecked Sendable {
        let configurationIdentity = "synthetic-idle"
        let cleanups = Flag()
        func cleanup() async { self.cleanups.set() }
    }

    private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
        for _ in 0..<2_000 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(condition(), "Timed out waiting for \(what)")
    }

    /// A meeting attempt that holds the coordinator exclusively until `release` opens.
    private func startExclusive(_ coordinator: MeetingModelResidencyCoordinator, entered: Latch, release: Latch) -> Task<Void, Error> {
        Task { @MainActor in
            try await coordinator.withExclusive(attemptID: UUID(), participants: []) {
                await entered.open()
                await release.wait()
            }
        }
    }

    private func assertBusy(_ coordinator: MeetingModelResidencyCoordinator, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await coordinator.withExclusive(attemptID: UUID(), participants: []) {}
            XCTFail("An exclusive attempt must be refused while publication holds admission. \(message)", file: file, line: line)
        } catch MeetingModelResidencyError.busy {
        } catch {
            XCTFail("Expected busy, got \(error). \(message)", file: file, line: line)
        }
    }

    // MARK: Separation model

    func testTransferHoldsNoAdmissionAndPublicationHoldsItOnlyForItsStep() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let transferStarted = Latch(), transferRelease = Latch()
        let stepEntered = Flag(), installed = Flag()
        let stepRelease = DispatchSemaphore(value: 0)
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { if installed.value { return Self.artifact }; throw Missing() },
            stagedInstall: { _, publication in
                await transferStarted.open()
                await transferRelease.wait()
                return try await publication.publish {
                    stepEntered.set()
                    stepRelease.wait()
                    installed.set()
                    return Self.artifact
                }
            },
            residency: coordinator)

        let attempt = Task { @MainActor in try await store.ensureInstalled() }
        await transferStarted.wait()
        XCTAssertFalse(coordinator.hasOrdinaryOperations, "the network transfer must not hold ordinary admission")
        let ran = try await coordinator.withExclusive(attemptID: UUID(), participants: []) { "summary ran" }
        XCTAssertEqual(ran, "summary ran", "a local summary must not be refused while the files transfer")
        let ordinary = try coordinator.beginOperation(owner: "synthetic", modelID: "synthetic")
        coordinator.endOperation(ordinary)

        await transferRelease.open()
        try await waitUntil("publication step") { stepEntered.value }
        XCTAssertTrue(coordinator.hasOrdinaryOperations, "publication changes installed storage under admission")
        await self.assertBusy(coordinator, "during publication")
        stepRelease.signal()

        let result = try await attempt.value
        XCTAssertEqual(result, Self.artifact)
        XCTAssertEqual(store.state, .ready(Self.artifact))
        XCTAssertFalse(coordinator.hasOrdinaryOperations, "publication must release admission when it ends")
        _ = try await coordinator.withExclusive(attemptID: UUID(), participants: []) {}
    }

    func testIdlePreloadSurvivesTransferAndIsRetiredByPublication() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let probe = IdleProbe()
        let owner = MeetingIdlePreparedResourceOwner(residency: coordinator)
        let token = try await owner.prepare(identity: probe.configurationIdentity) { probe }
        XCTAssertNotNil(token)

        let transferStarted = Latch(), transferRelease = Latch()
        let installed = Flag()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { if installed.value { return Self.artifact }; throw Missing() },
            stagedInstall: { _, publication in
                await transferStarted.open()
                await transferRelease.wait()
                return try await publication.publish { installed.set(); return Self.artifact }
            },
            residency: coordinator)
        let attempt = Task { @MainActor in try await store.ensureInstalled() }
        await transferStarted.wait()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probe.cleanups.total, 0, "a transfer touches no installed storage and must keep the recording preload")

        await transferRelease.open()
        _ = try await attempt.value
        XCTAssertEqual(probe.cleanups.total, 1, "publication yields the idle preload exactly once before it changes storage")
        XCTAssertFalse(coordinator.hasOrdinaryOperations)
    }

    func testMeetingAttemptStartedDuringTransferRefusesPublicationWithRetriableMessageAndRetryWorks() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let transferStarted = Latch(), transferRelease = Latch()
        let installs = Flag(), installed = Flag()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { if installed.value { return Self.artifact }; throw Missing() },
            stagedInstall: { _, publication in
                installs.set()
                if installs.total == 1 {
                    await transferStarted.open()
                    await transferRelease.wait()
                }
                return try await publication.publish { installed.set(); return Self.artifact }
            },
            residency: coordinator)

        let first = Task { @MainActor in try await store.ensureInstalled() }
        await transferStarted.wait()
        let exclusiveEntered = Latch(), exclusiveRelease = Latch()
        let meeting = self.startExclusive(coordinator, entered: exclusiveEntered, release: exclusiveRelease)
        await exclusiveEntered.wait()
        await transferRelease.open()

        do {
            _ = try await first.value
            XCTFail("Publication must be refused while a meeting attempt owns the models")
        } catch let error as MeetingDiarizationModelStore.DownloadError {
            XCTAssertEqual(error.localizedDescription, Self.busyMessage)
        }
        XCTAssertEqual(store.state, .failed(message: Self.busyMessage))
        XCTAssertFalse(installed.value, "nothing may change installed storage while the attempt runs")

        await exclusiveRelease.open()
        try await meeting.value
        XCTAssertFalse(coordinator.hasOrdinaryOperations)

        let retried = try await store.ensureInstalled()
        XCTAssertEqual(retried, Self.artifact)
        XCTAssertEqual(installs.total, 2)
        XCTAssertEqual(store.state, .ready(Self.artifact))
    }

    func testCancelledTransferLeavesNoAdmissionAndRetryStartsFresh() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let installs = Flag(), installed = Flag()
        let transferStarted = Latch()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { if installed.value { return Self.artifact }; throw Missing() },
            stagedInstall: { _, publication in
                installs.set()
                if installs.total == 1 {
                    await transferStarted.open()
                    // The downloader checks cancellation between files and throws like this.
                    throw CancellationError()
                }
                return try await publication.publish { installed.set(); return Self.artifact }
            },
            residency: coordinator)
        let first = Task { @MainActor in try await store.ensureInstalled() }
        await transferStarted.wait()
        do { _ = try await first.value; XCTFail("A cancelled transfer must fail") } catch {}
        XCTAssertFalse(coordinator.hasOrdinaryOperations, "a cancelled transfer must leave nothing held")
        guard case .failed = store.state else { return XCTFail("expected failed state, got \(store.state)") }

        _ = try await store.ensureInstalled()
        XCTAssertEqual(installs.total, 2)
        XCTAssertFalse(coordinator.hasOrdinaryOperations)
    }

    // MARK: Legacy one-argument install (the upstream shape)

    func testLegacyInstallStillHoldsAdmissionForItsWholeRun() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let started = Latch(), release = Latch()
        let installed = Flag()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { if installed.value { return Self.artifact }; throw Missing() },
            install: { _ in
                await started.open()
                await release.wait()
                installed.set()
                return Self.artifact
            },
            residency: coordinator)

        let attempt = Task { @MainActor in try await store.ensureInstalled() }
        await started.wait()
        XCTAssertTrue(coordinator.hasOrdinaryOperations, "a legacy install is not staged, so it runs under admission")
        await self.assertBusy(coordinator, "during a legacy install")
        await release.open()
        _ = try await attempt.value
        XCTAssertEqual(store.state, .ready(Self.artifact))
        XCTAssertFalse(coordinator.hasOrdinaryOperations, "admission is released when the legacy install ends")
        _ = try await coordinator.withExclusive(attemptID: UUID(), participants: []) {}
    }

    func testLegacyVoiceInstallStillHoldsAdmissionForItsWholeRun() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let started = Latch(), release = Latch()
        let installed = Flag()
        let store = MeetingDiarizationModelStore(
            validate: { Self.artifact },
            validateVoice: { if !installed.value { throw Missing() } },
            installVoice: { _ in
                await started.open()
                await release.wait()
                installed.set()
            },
            residency: coordinator)

        let attempt = Task { @MainActor in try await store.ensureInstalled(includingVoiceEncoder: true) }
        await started.wait()
        XCTAssertTrue(coordinator.hasOrdinaryOperations)
        await self.assertBusy(coordinator, "during a legacy voice install")
        await release.open()
        _ = try await attempt.value
        XCTAssertTrue(store.voiceMatchingReady)
        XCTAssertFalse(coordinator.hasOrdinaryOperations)
    }

    // MARK: Gate

    func testCancelledPublicationJoinsItsStepBeforeReleasingAdmission() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let gate = MeetingModelPublicationGate(owner: "speaker-resources", modelID: "speaker-separation", residency: coordinator)
        let started = Flag(), finished = Flag()
        let task = Task { @MainActor in
            try await gate.publish { () throws -> Int in
                started.set()
                defer { finished.set() }
                while true {
                    try Task.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.002)
                }
            }
        }
        try await waitUntil("publication step") { started.value }
        XCTAssertTrue(coordinator.hasOrdinaryOperations)
        task.cancel()
        let result = await task.result
        XCTAssertTrue(finished.value, "the step must have returned before the caller sees the cancellation")
        XCTAssertFalse(coordinator.hasOrdinaryOperations, "admission is released after the step joined")
        guard case .failure(let error) = result, error is CancellationError else { return XCTFail("Expected cancellation, got \(result)") }
        _ = try await coordinator.withExclusive(attemptID: UUID(), participants: []) {}
    }

    func testFailingPublicationStepReleasesAdmission() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let gate = MeetingModelPublicationGate(owner: "speaker-resources", modelID: "voice-matching", residency: coordinator)
        do {
            try await gate.publish { throw Missing() }
            XCTFail("The step error must reach the caller")
        } catch is Missing {}
        XCTAssertFalse(coordinator.hasOrdinaryOperations)
    }

    // MARK: Staged transfer survives a refused publication

    private func syntheticStaging(profile: MeetingNemotronModelProfile) throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("speaker-admission-\(UUID().uuidString)", isDirectory: true)
        for path in profile.remoteFilePaths {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic-\(path)".utf8).write(to: file)
        }
        return root
    }

    func testRefusedPublicationKeepsStagedFilesSoRetryTransfersNothingAgain() async throws {
        let profile = MeetingNemotronModelProfile.fast32SplitW8A8
        let staging = try self.syntheticStaging(profile: profile)
        let destination = staging.deletingLastPathComponent().appendingPathComponent("destination-\(UUID().uuidString)/\(profile.packageFileName)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let coordinator = MeetingModelResidencyCoordinator()
        let gate = MeetingModelPublicationGate(owner: "speaker-resources", modelID: "speaker-separation", residency: coordinator)
        let entered = Latch(), release = Latch()
        let meeting = self.startExclusive(coordinator, entered: entered, release: release)
        await entered.wait()

        do {
            _ = try await MeetingDiarizationModelStore.publishStaged(from: staging, to: destination, profile: profile, publication: gate)
            XCTFail("Publication must be refused while a meeting attempt runs")
        } catch MeetingModelResidencyError.busy {}

        for path in profile.remoteFilePaths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: staging.appendingPathComponent(path).path), "\(path) must stay staged")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent(profile.packageFileName).path),
                       "the assembled copy is rebuilt from the staged files on retry and must not linger")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "nothing may be installed")
        await release.open()
        try await meeting.value
    }

    func testDamagedStagedDownloadIsStillDiscardedAfterAdmittedPublication() async throws {
        let profile = MeetingNemotronModelProfile.fast32SplitW8A8
        let staging = try self.syntheticStaging(profile: profile)
        let destination = staging.deletingLastPathComponent().appendingPathComponent("destination-\(UUID().uuidString)/\(profile.packageFileName)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let coordinator = MeetingModelResidencyCoordinator()
        let gate = MeetingModelPublicationGate(owner: "speaker-resources", modelID: "speaker-separation", residency: coordinator)

        do {
            _ = try await MeetingDiarizationModelStore.publishStaged(from: staging, to: destination, profile: profile, publication: gate)
            XCTFail("Synthetic files cannot match the pinned checksums")
        } catch MeetingModelInstaller.InstallError.wrongPackage {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path), "a damaged download must not be resumed forever")
        XCTAssertFalse(coordinator.hasOrdinaryOperations)
    }

    // MARK: Voice model

    func testVoiceTransferHoldsNoAdmissionAndLateMeetingAttemptRefusesPublication() async throws {
        let coordinator = MeetingModelResidencyCoordinator()
        let transferStarted = Latch(), transferRelease = Latch()
        let installs = Flag(), installed = Flag()
        let store = MeetingDiarizationModelStore(
            validate: { Self.artifact },
            validateVoice: { if !installed.value { throw Missing() } },
            stagedInstallVoice: { _, publication in
                installs.set()
                if installs.total == 1 {
                    await transferStarted.open()
                    await transferRelease.wait()
                }
                try await publication.publish { installed.set() }
            },
            residency: coordinator)

        let first = Task { @MainActor in try await store.ensureInstalled(includingVoiceEncoder: true) }
        await transferStarted.wait()
        XCTAssertFalse(coordinator.hasOrdinaryOperations, "the voice model transfer must not hold ordinary admission")
        let ran = try await coordinator.withExclusive(attemptID: UUID(), participants: []) { "summary ran" }
        XCTAssertEqual(ran, "summary ran")

        let exclusiveEntered = Latch(), exclusiveRelease = Latch()
        let meeting = self.startExclusive(coordinator, entered: exclusiveEntered, release: exclusiveRelease)
        await exclusiveEntered.wait()
        await transferRelease.open()
        do {
            _ = try await first.value
            XCTFail("Publication must be refused while a meeting attempt owns the models")
        } catch let error as MeetingDiarizationModelStore.DownloadError {
            XCTAssertEqual(error.localizedDescription, Self.busyMessage)
        }
        XCTAssertFalse(store.voiceMatchingReady)
        XCTAssertFalse(installed.value)
        await exclusiveRelease.open()
        try await meeting.value

        _ = try await store.ensureInstalled(includingVoiceEncoder: true)
        XCTAssertTrue(store.voiceMatchingReady)
        XCTAssertEqual(installs.total, 2)
        XCTAssertFalse(coordinator.hasOrdinaryOperations)
    }
}
