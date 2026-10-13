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
    private var residentProvider: (any TranscriptionProvider)?
    private var residentModelID: String?
    private var modelOperation: Task<Void, Error>?
    private var operationID: UUID?

    private lazy var preparationOwner = MeetingASRPreparationOwner(
        isActiveLease: { [weak self] in self?.activityLease == $0 },
        isUserDownloadInProgress: { [weak self] in self?.modelOperation != nil },
        retireDictationResources: { [weak self] lease in
            guard let self, self.activityLease == lease else { throw CancellationError() }
            await self.executor.cancelAndAwaitPending()
            await self.residentProvider?.releaseResidency()
            self.residentProvider = nil
            self.residentModelID = nil
            self.isAsrReady = false
        },
        makeProvider: { try PichiMeetingProviderFactory.make($0) },
        prepareProvider: { provider, _, progress in
            try await SpeechModelPreparationOperation.prepare(provider: provider, progress: progress)
        },
        drainExecutor: { [weak self] _ in await self?.executor.cancelAndAwaitPending() }
    )

    init(meetingModelResidency: MeetingModelResidencyCoordinator = .shared, settings: SettingsStore = .shared) {
        self.residency = meetingModelResidency
        self.settings = settings
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

    func modelIsInstalled(_ model: SettingsStore.SpeechModel) async throws -> Bool { model.isInstalled }

    private func provider(for model: SettingsStore.SpeechModel) throws -> any TranscriptionProvider {
        guard let language = PichiMeetingProviderFactory.defaultLanguageCode(for: model.rawValue) else {
            throw MeetingModelResidencyError.unsupportedProvider
        }
        return try PichiMeetingProviderFactory.make(
            PichiMeetingProviderFactory.configuration(asrModel: model.rawValue, languageCode: language)
        )
    }

    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease {
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
        await self.residentProvider?.releaseResidency()
        self.residentProvider = nil
        self.residentModelID = nil
        self.isAsrReady = false
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
        let lease = try self.acquireExclusiveActivity(.modelMaintenance)
        defer { self.releaseExclusiveActivity(lease) }
        let admission = try self.residency.beginOperation(owner: "speech", modelID: model.id)
        defer { self.residency.endOperation(admission) }
        let provider = try self.provider(for: model)
        let id = UUID()
        self.operationID = id
        self.downloadingModelId = model.id
        let task = Task { @MainActor in
            try await SpeechModelPreparationOperation.prepare(provider: provider) { [weak self] update in
                Task { @MainActor in
                    guard let self, self.operationID == id else { return }
                    self.modelPreparationPhase = update.phase
                    self.downloadProgress = update.fractionCompleted
                    if let progress = update.fractionCompleted { progressHandler?(progress) }
                }
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
                self.modelsExistOnDisk = self.settings.selectedSpeechModel.isInstalled
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            await provider.releaseResidency()
        } catch {
            await provider.releaseResidency()
            throw error
        }
    }

    func activateModel(_ model: SettingsStore.SpeechModel) async throws {
        guard self.activityLease == nil, self.modelOperation == nil, !self.residency.isExclusive else { throw MeetingModelResidencyError.busy }
        guard model.isInstalled else { throw MeetingProcessingError.modelUnavailable }
        let lease = try self.acquireExclusiveActivity(.modelMaintenance)
        defer { self.releaseExclusiveActivity(lease) }
        await self.residentProvider?.releaseResidency()
        try Task.checkCancellation()
        guard self.activityLease == lease else { throw CancellationError() }
        self.residentProvider = nil
        self.residentModelID = nil
        self.isAsrReady = false
        self.settings.selectedSpeechModel = model
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
        self.modelsExistOnDisk = self.settings.selectedSpeechModel.isInstalled
    }

    func ensureAsrReady() async throws {
        let model = self.settings.selectedSpeechModel
        if self.residentModelID == model.id, self.residentProvider?.isReady == true { return }
        guard model.isInstalled else { throw MeetingProcessingError.modelUnavailable }
        let provider = try self.provider(for: model)
        do { try await SpeechModelPreparationOperation.prepare(provider: provider, progress: { _ in }) }
        catch { await provider.releaseResidency(); throw error }
        self.residentProvider = provider; self.residentModelID = model.id; self.isAsrReady = true
    }

    func meetingResidencyParticipant() -> MeetingModelParticipant {
        MeetingModelParticipant(owner: "speech", snapshot: { [weak self] in
            guard let self, self.activeExclusiveActivity == .meeting else { throw MeetingModelResidencyError.busy }
            return self.residentModelID.map { MeetingResidentModel(id: $0, configuration: $0) }
        }, suspend: { [weak self] in
            await self?.executor.cancelAndAwaitPending()
            await self?.residentProvider?.releaseResidency()
            self?.residentProvider = nil; self?.residentModelID = nil; self?.isAsrReady = false
        }, restore: { [weak self] model in
            guard let self, self.settings.selectedSpeechModel.id == model.id, self.settings.selectedSpeechModel.isInstalled else { return }
            try await self.ensureAsrReady()
        })
    }

    func withMeetingModelResidency<T>(attemptID: UUID, acceptsCompletedCancellation: (T) -> Bool = { _ in false }, work: () async throws -> T) async throws -> T {
        try await self.residency.withExclusive(attemptID: attemptID, participants: [self.meetingResidencyParticipant()], acceptsCompletedCancellation: acceptsCompletedCancellation, work: work)
    }

    func withPreparedMeetingASR<T>(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration, body: @escaping (any TranscriptionProvider) async throws -> T) async throws -> T {
        guard let lease = self.activityLease, lease.activity == .meeting else { throw MeetingASRPreparationError.invalidActivityLease }
        defer { if let release = self.deferredRelease { self.releaseExclusiveActivity(release) } }
        return try await self.scope.run(lease: lease, attemptID: attemptID, configuration: configuration, owner: self.preparationOwner, isActiveLease: { [weak self] in self?.activityLease == $0 }, body: body)
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
