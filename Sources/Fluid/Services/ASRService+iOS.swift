#if os(iOS)
import Combine
import Foundation

/// iOS composition of the same ASR preparation, execution and model residency owners.
/// Capture belongs to MeetingCaptureControlling; this service does not own a second pipeline.
@MainActor
final class ASRService: ObservableObject {
    @Published private(set) var activeExclusiveActivity: ASRExclusiveActivity?
    @Published private(set) var isAsrReady = false
    @Published private(set) var modelsExistOnDisk = false
    @Published private(set) var downloadingModelId: String?
    @Published private(set) var deletingModelID: String?
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var modelPreparationPhase: ModelPreparationPhase?
    var isRunning: Bool { false }
    var hasActiveModelDownload: Bool { self.downloadingModelId != nil }
    var hasActiveModelPreparation: Bool { self.modelOperation != nil }
    func cancelModelDownload() { self.modelOperation?.cancel() }

    private let residency: MeetingModelResidencyCoordinator
    private let settings: SettingsStore
    private let executor = TranscriptionExecutor()
    private let scope = MeetingASRPreparedScope()
    private var activityLease: ASRActivityLease?
    private var deferredRelease: ASRActivityLease?
    private var isTerminating = false
    private var residentProvider: (any TranscriptionProvider)?
    private var residentModelID: String?
    private var modelOperation: Task<Void, Error>?
    private var operationID: UUID?
    private var residentReleaseTask: Task<Void, Never>?
    #if DEBUG
    var modelProvidersForTesting: [SettingsStore.SpeechModel: any TranscriptionProvider] = [:]
    var meetingASRPreparationOwnerForTesting: MeetingASRPreparationOwner?
    #endif

    private lazy var preparationOwner = MeetingASRPreparationOwner(
        isActiveLease: { [weak self] in self?.activityLease == $0 },
        isUserDownloadInProgress: { [weak self] in self?.modelOperation != nil },
        retireDictationResources: { [weak self] lease in
            guard let self, self.activityLease == lease else { throw CancellationError() }
            await self.executor.cancelAndAwaitPending()
            await self.releaseResidentProvider()
        },
        makeProvider: { try PichiMeetingProviderFactory.make($0) },
        prepareProvider: { provider, _, progress in
            try await SpeechModelPreparationOperation.prepare(provider: provider, progress: progress)
        },
        drainExecutor: { [weak self] _ in await self?.executor.cancelAndAwaitPending() }
    )

    init(meetingModelResidency: MeetingModelResidencyCoordinator? = nil, settings: SettingsStore? = nil) {
        self.residency = meetingModelResidency ?? .shared
        self.settings = settings ?? .shared
    }

    var availableMeetingModels: [SettingsStore.SpeechModel] {
        SettingsStore.SpeechModel.availableModels.filter {
            PichiMeetingProviderFactory.registeredBackendDescriptor(for: $0.rawValue) != nil
        }
    }

    var fileTranscriptionProvider: any TranscriptionProvider {
        guard let residentProvider else { preconditionFailure("ASR must be prepared before provider access") }
        return residentProvider
    }

    func modelIsInstalled(_ model: SettingsStore.SpeechModel) async throws -> Bool { self.installedModelExists(model) }

    private func installedModelExists(_ model: SettingsStore.SpeechModel) -> Bool {
        #if DEBUG
        if let injected = self.modelProvidersForTesting[model] { return injected.modelsExistOnDisk() }
        #endif
        return model.isInstalled
    }

    private func provider(for model: SettingsStore.SpeechModel) throws -> any TranscriptionProvider {
        #if DEBUG
        if let injected = self.modelProvidersForTesting[model] { return injected }
        #endif
        guard let language = PichiMeetingProviderFactory.defaultLanguageCode(for: model.rawValue) else {
            throw MeetingModelResidencyError.unsupportedProvider
        }
        return try PichiMeetingProviderFactory.make(
            PichiMeetingProviderFactory.configuration(asrModel: model.rawValue, languageCode: language)
        )
    }

    func shutdownForTermination() async {
        self.isTerminating = true
        self.residency.beginTermination()
        let operation = self.modelOperation
        operation?.cancel()
        _ = await operation?.result
        await self.scope.cancelAndWait()
        if let token = self.preparationOwner.currentClaimToken { await self.preparationOwner.release(token) }
        await self.executor.cancelAndAwaitPending()
        await self.releaseResidentProvider()
        self.activityLease = nil
        self.activeExclusiveActivity = nil
        self.deferredRelease = nil
    }

    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
        guard !self.isTerminating else { throw MeetingModelResidencyError.terminating }
        guard self.activityLease == nil else {
            throw ASRActivityError.activityInProgress(self.activeExclusiveActivity ?? activity)
        }
        let lease = ASRActivityLease(id: UUID(), activity: activity)
        self.activityLease = lease
        self.activeExclusiveActivity = activity
        return lease
    }

    func releaseExclusiveActivity(_ lease: ASRActivityLease) {
        guard self.activityLease == lease else { return }
        if self.scope.isActive || self.preparationOwner.isClaimed || self.preparationOwner.isDraining {
            self.deferredRelease = lease
            return
        }
        self.activityLease = nil
        self.activeExclusiveActivity = nil
        self.deferredRelease = nil
    }

    func prepareMeetingAudioHandoff(_ lease: ASRActivityLease) async throws {
        guard self.activityLease == lease, lease.activity == .meeting, self.modelOperation == nil else {
            throw MeetingASRPreparationError.invalidActivityLease
        }
        await self.releaseResidentProvider()
        try Task.checkCancellation()
    }

    func completeMeetingAudioHandback(_ lease: ASRActivityLease) async {
        guard self.activityLease == lease else { return }
        await self.scope.cancelAndWait()
        if let claim = self.preparationOwner.currentClaimToken { await self.preparationOwner.release(claim) }
        await self.executor.cancelAndAwaitPending()
        self.releaseExclusiveActivity(lease)
    }

    func downloadModel(_ model: SettingsStore.SpeechModel, progressHandler: ((Double) -> Void)? = nil) async throws {
        try await self.prepareModel(model, retainingProvider: false, progressHandler: progressHandler)
    }

    /// First recording uses the same installation/preparation owner as the model settings.
    /// Selection is a value snapshot; an intervening change cannot silently start another model.
    func prepareSelectedModelForRecording() async throws {
        try Task.checkCancellation()
        guard !self.isTerminating else { throw MeetingModelResidencyError.terminating }
        let model = self.settings.selectedSpeechModel
        if !self.installedModelExists(model) {
            try await self.downloadModel(model)
        } else {
            try await self.prepareModel(model, retainingProvider: false, expectedSelection: model)
        }
        try Task.checkCancellation()
        guard !self.isTerminating, self.settings.selectedSpeechModel == model else { throw CancellationError() }
        guard self.installedModelExists(model) else { throw MeetingProcessingError.modelUnavailable }
    }

    /// One operation owns installation and readiness, including retirement and joined cleanup.
    /// A restoration can borrow its existing meeting lease only inside the residency owner's
    /// exact grant. Ordinary calls must acquire their own maintenance lease before model work.
    private func prepareModel(_ model: SettingsStore.SpeechModel, retainingProvider: Bool,
                              expectedSelection: SettingsStore.SpeechModel? = nil,
                              progressHandler: ((Double) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        guard !self.isTerminating else { throw MeetingModelResidencyError.terminating }
        guard self.modelOperation == nil, !self.preparationOwner.isClaimed, !self.preparationOwner.isDraining else {
            throw MeetingModelResidencyError.busy
        }
        let lease: ASRActivityLease
        let ownsLease: Bool
        if retainingProvider, let existing = self.activityLease, existing.activity == .meeting,
           MeetingModelContext.grant != nil {
            lease = existing
            ownsLease = false
        } else {
            lease = try self.acquireExclusiveActivity(.modelMaintenance)
            ownsLease = true
        }
        defer { if ownsLease { self.releaseExclusiveActivity(lease) } }
        let admission = try self.residency.beginOperation(owner: "speech", modelID: model.id)
        defer { self.residency.endOperation(admission) }
        let provider = try self.provider(for: model)
        let id = UUID()
        self.operationID = id
        self.downloadingModelId = model.id
        self.downloadProgress = nil
        self.modelPreparationPhase = .preparingDownload
        let task = Task { @MainActor [self] in
            var ownsProvider = true
            do {
                try self.recheckModelOperation(id: id, lease: lease, expectedSelection: expectedSelection)
                await self.executor.cancelAndAwaitPending()
                await self.releaseResidentProvider()
                try self.recheckModelOperation(id: id, lease: lease, expectedSelection: expectedSelection)
                try await SpeechModelPreparationOperation.prepare(provider: provider) { [weak self] update in
                    Task { @MainActor in
                        guard let self, self.operationID == id, !self.isTerminating,
                              self.modelOperation?.isCancelled == false else { return }
                        self.modelPreparationPhase = update.phase
                        self.downloadProgress = update.fractionCompleted
                        if let progress = update.fractionCompleted { progressHandler?(progress) }
                    }
                }
                try self.recheckModelOperation(id: id, lease: lease, expectedSelection: expectedSelection)
                guard provider.isReady, provider.modelsExistOnDisk() else { throw MeetingProcessingError.modelUnavailable }
                ownsProvider = false
                if retainingProvider {
                    self.residentProvider = provider
                    self.residentModelID = model.id
                    self.isAsrReady = true
                } else {
                    await Task { @MainActor in await provider.releaseResidency() }.value
                    try self.recheckModelOperation(id: id, lease: lease, expectedSelection: expectedSelection)
                }
            } catch {
                if ownsProvider { await Task { @MainActor in await provider.releaseResidency() }.value }
                throw error
            }
        }
        self.modelOperation = task
        defer {
            if self.operationID == id {
                self.operationID = nil
                self.modelOperation = nil
                self.downloadingModelId = nil
                self.modelPreparationPhase = nil
                self.downloadProgress = nil
                self.modelsExistOnDisk = self.installedModelExists(self.settings.selectedSpeechModel)
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try self.recheckModelOperation(id: id, lease: lease, expectedSelection: expectedSelection)
        } catch {
            if retainingProvider, self.operationID == id { await self.releaseResidentProvider() }
            throw error
        }
    }

    private func recheckModelOperation(id: UUID, lease: ASRActivityLease,
                                       expectedSelection: SettingsStore.SpeechModel?) throws {
        try Task.checkCancellation()
        guard !self.isTerminating, self.operationID == id, self.activityLease == lease,
              expectedSelection == nil || self.settings.selectedSpeechModel == expectedSelection else { throw CancellationError() }
    }

    /// Clear published references before suspension, with one joined drain for all callers.
    private func releaseResidentProvider() async {
        if let task = self.residentReleaseTask { await task.value; return }
        let provider = self.residentProvider
        self.residentProvider = nil
        self.residentModelID = nil
        self.isAsrReady = false
        guard let provider else { return }
        let task = Task { @MainActor in await provider.releaseResidency() }
        self.residentReleaseTask = task
        await task.value
        self.residentReleaseTask = nil
    }

    func activateModel(_ model: SettingsStore.SpeechModel) async throws {
        guard self.activityLease == nil, self.modelOperation == nil, !self.residency.isExclusive else { throw MeetingModelResidencyError.busy }
        guard self.installedModelExists(model) else { throw MeetingProcessingError.modelUnavailable }
        let lease = try self.acquireExclusiveActivity(.modelMaintenance)
        defer { self.releaseExclusiveActivity(lease) }
        await self.releaseResidentProvider()
        try Task.checkCancellation()
        guard self.activityLease == lease else { throw CancellationError() }
        self.settings.selectedSpeechModel = model
        if let descriptor = PichiMeetingProviderFactory.registeredBackendDescriptor(for: model.rawValue) {
            self.settings.meetingTranscriptionBackendID = descriptor.id
        }
        self.modelsExistOnDisk = true
    }

    func importModel(_ model: SettingsStore.SpeechModel, from directory: URL) async throws {
        let lease = try self.acquireExclusiveActivity(.modelMaintenance)
        defer { self.releaseExclusiveActivity(lease) }
        let admission = try self.residency.beginOperation(owner: "speech", modelID: model.id)
        defer { self.residency.endOperation(admission) }
        let provider = try self.provider(for: model)
        do { try await provider.importModel(from: directory) }
        catch { await provider.releaseResidency(); throw error }
        await provider.releaseResidency()
    }

    func clearModelCache(for model: SettingsStore.SpeechModel) async throws {
        let lease = try self.acquireExclusiveActivity(.modelMaintenance)
        defer { self.releaseExclusiveActivity(lease) }
        let admission = try self.residency.beginOperation(owner: "speech", modelID: model.id)
        defer { self.residency.endOperation(admission) }
        self.deletingModelID = model.id
        defer { self.deletingModelID = nil }
        let provider = self.residentModelID == model.id ? self.residentProvider : nil
        let target = try provider ?? self.provider(for: model)
        await self.executor.cancelAndAwaitPending()
        await target.releaseResidency()
        try await target.clearCache()
        if self.residentModelID == model.id {
            self.residentProvider = nil; self.residentModelID = nil; self.isAsrReady = false
        }
        self.modelsExistOnDisk = self.installedModelExists(self.settings.selectedSpeechModel)
    }

    func ensureAsrReady() async throws {
        try Task.checkCancellation()
        guard !self.isTerminating else { throw MeetingModelResidencyError.terminating }
        let model = self.settings.selectedSpeechModel
        if self.residentModelID == model.id, self.residentProvider?.isReady == true,
           self.modelOperation == nil, !self.residency.isExclusive, self.activityLease == nil { return }
        try await self.prepareModel(model, retainingProvider: true, expectedSelection: model)
    }

    func meetingResidencyParticipant() -> MeetingModelParticipant {
        MeetingModelParticipant(owner: "speech", snapshot: { [weak self] in
            guard let self, self.activeExclusiveActivity == .meeting else { throw MeetingModelResidencyError.busy }
            return self.residentModelID.map { MeetingResidentModel(id: $0, configuration: $0) }
        }, suspend: { [weak self] in
            await self?.executor.cancelAndAwaitPending()
            await self?.releaseResidentProvider()
        }, restore: { [weak self] model in
            guard let self, self.settings.selectedSpeechModel.id == model.id,
                  self.installedModelExists(self.settings.selectedSpeechModel) else { return }
            try await self.ensureAsrReady()
        })
    }

    func withMeetingModelResidency<T>(attemptID: UUID, acceptsCompletedCancellation: (T) -> Bool = { _ in false }, work: () async throws -> T) async throws -> T {
        try await self.residency.withExclusive(attemptID: attemptID, participants: [self.meetingResidencyParticipant()], acceptsCompletedCancellation: acceptsCompletedCancellation, work: work)
    }

    func withPreparedMeetingASR<T>(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration, body: @escaping (any TranscriptionProvider) async throws -> T) async throws -> T {
        guard let lease = self.activityLease, lease.activity == .meeting else { throw MeetingASRPreparationError.invalidActivityLease }
        defer { if let release = self.deferredRelease { self.releaseExclusiveActivity(release) } }
        #if DEBUG
        let owner = self.meetingASRPreparationOwnerForTesting ?? self.preparationOwner
        #else
        let owner = self.preparationOwner
        #endif
        return try await self.scope.run(lease: lease, attemptID: attemptID, configuration: configuration, owner: owner, isActiveLease: { [weak self] in self?.activityLease == $0 }, body: body)
    }

    func transcribeMeetingSamples(_ samples: [Float], provider: any TranscriptionProvider, languageCode: String) async throws -> ASRTranscriptionResult {
        guard self.activeExclusiveActivity == .meeting else { throw MeetingASRPreparationError.invalidActivityLease }
        return try await self.executor.run { try await provider.transcribe(samples) }
    }
    func transcribeMeetingSamplesWithTimings(_ samples: [Float], provider: any TranscriptionProvider) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        guard self.activeExclusiveActivity == .meeting else { throw MeetingASRPreparationError.invalidActivityLease }
        return try await self.executor.run { try await provider.transcribeWithWordTimings(samples) }
    }
    func transcribeMeetingFile(at fileURL: URL, provider: any TranscriptionProvider) async throws -> ASRTranscriptionResult {
        guard self.activeExclusiveActivity == .meeting else { throw MeetingASRPreparationError.invalidActivityLease }
        return try await self.executor.run { try await provider.transcribeFile(at: fileURL) }
    }
}
#endif
