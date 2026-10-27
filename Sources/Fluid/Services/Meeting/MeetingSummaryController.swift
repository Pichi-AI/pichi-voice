import Combine
import Foundation

/// Keeps summary admission separate from ordinary processing, including cloud calls that
/// do not own a local-model residency token. Tokens survive cancellation until work drains.
@MainActor
final class MeetingSummaryActivityCoordinator: ObservableObject {
    static let shared = MeetingSummaryActivityCoordinator()
    private var processing: Set<UUID> = []
    private var optionalProcessing: [UUID: @MainActor () async -> Void] = [:]
    @Published private(set) var isProcessing = false
    private var summary: UUID?
    private var remoteSummary: UUID?
    @Published private(set) var selectionLock: UUID?

    /// Acquired synchronously by the button action, before generation's task starts.
    func lockSelection() -> UUID? {
        guard self.selectionLock == nil else { return nil }
        let token = UUID()
        self.selectionLock = token
        return token
    }

    func unlockSelection(_ token: UUID) {
        guard self.selectionLock == token else { return }
        self.selectionLock = nil
    }

    func beginProcessing() -> UUID? {
        guard self.summary == nil else { return nil }
        let token = UUID()
        self.processing.insert(token)
        self.isProcessing = true
        return token
    }

    func endProcessing(_ token: UUID) {
        self.optionalProcessing.removeValue(forKey: token)
        self.processing.remove(token)
        self.isProcessing = !self.processing.isEmpty
    }

    /// Optional preparation must yield to an explicit summary. Its owner supplies
    /// a joined cancellation, so admission never opens while work still drains.
    func beginOptionalProcessing(cancelAndJoin: @escaping @MainActor () async -> Void) -> UUID? {
        guard let token = self.beginProcessing() else { return nil }
        self.optionalProcessing[token] = cancelAndJoin
        return token
    }

    static func presentBusyError() {
        let asr = AppServices.shared.asr
        asr.errorTitle = "Summary in Progress"
        asr.errorMessage = "Wait for the meeting summary to finish, then try again."
        asr.showError = true
    }

    /// Cloud summaries hold neither the audio lease nor the processing gate that on-device
    /// summaries need, so dictation, Command Mode, and Rewrite keep working while a provider responds.
    func withRemoteSummary<T>(work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard self.remoteSummary == nil, self.summary == nil else { throw MeetingModelResidencyError.busy }
        let token = UUID()
        self.remoteSummary = token
        defer {
            if self.remoteSummary == token {
                self.remoteSummary = nil
            }
        }
        return try await work()
    }

    func withSummary<T>(activity: any ASRActivityLeasing, work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        guard self.summary == nil, self.remoteSummary == nil else { throw MeetingModelResidencyError.busy }
        let token = UUID()
        self.summary = token
        defer { if self.summary == token { self.summary = nil } }
        // Close admission before awaiting cancellation. Ordinary processing is
        // never preempted, and a second summary cannot enter during this drain.
        let optional = self.optionalProcessing
        for (activity, cancelAndJoin) in optional {
            await cancelAndJoin()
            self.endProcessing(activity)
        }
        try Task.checkCancellation()
        guard self.processing.isEmpty else { throw MeetingModelResidencyError.busy }
        let lease = try activity.acquireExclusiveActivity(.meeting)
        do {
            try await activity.prepareMeetingAudioHandoff(lease)
            try Task.checkCancellation()
            let value = try await work()
            await Task { await activity.completeMeetingAudioHandback(lease) }.value
            return value
        } catch {
            await Task { await activity.completeMeetingAudioHandback(lease) }.value
            throw error
        }
    }
}

@MainActor
final class MeetingSummaryController: ObservableObject, PrivateProfileTransitionParticipant {
    private let privateProfile = PrivateProfileStorage.current
    private var profileRefreshOperation: Task<Void, Never>?
    private var profileRefreshID: UUID?

    @Published private(set) var installed = false
    @Published private(set) var checking = true
    @Published private(set) var downloading = false
    @Published private(set) var generating = false
    @Published private(set) var deleting = false
    @Published private(set) var progress: PrivateAIModelDownloadProgress?
    @Published private(set) var output = ""
    @Published private(set) var outputProvenance = ""
    @Published private(set) var outputNotice = ""
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    private let store: any MeetingSessionStoring

    init(store: any MeetingSessionStoring = MeetingSessionStore.shared) {
        self.store = store
        PrivateProfileService.shared.register(self)
    }

    var busy: Bool {
        self.downloading || self.generating || self.deleting
    }

    var model: PrivateAIRegisteredModel? {
        PrivateAIModelRegistry.modelIDs(for: .meetingSummary).first.flatMap { PrivateAIModelRegistry.model(id: $0) }
    }

    typealias SavedSummary = MeetingSavedSummary

    func refresh(session: MeetingSession?, kind: MeetingSummaryKind, customPrompt: String = "") async {
        guard PrivateProfileStorage.isReadable(privateProfile) else { return }
        let prior = profileRefreshOperation
        prior?.cancel(); await prior?.value
        let id = UUID()
        let task = Task { await self.refreshBound(session: session, kind: kind, customPrompt: customPrompt) }
        profileRefreshOperation = task
        profileRefreshID = id
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if profileRefreshID == id { profileRefreshOperation = nil; profileRefreshID = nil }
    }

    private func refreshBound(session: MeetingSession?, kind: MeetingSummaryKind, customPrompt: String) async {
        guard PrivateProfileStorage.isReadable(privateProfile), !Task.isCancelled else { return }
        guard !self.busy else { return }
        let generation = UUID()
        self.generation = generation
        self.output = ""
        self.outputProvenance = ""
        self.outputNotice = ""
        self.error = nil
        self.checking = true
        let model = self.model
        let store = self.store
        let promptHash = kind == .custom ? MeetingSummaryInput.fingerprint(customPrompt.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
        let snapshot = await Task.detached(priority: .utility) { () -> (Bool, SavedSummary?) in
            let installed = model.map { PrivateAIIntegrationService.isModelInstalled($0) } ?? false
            guard let session, session.requiresEncryptedPersistence != true,
                  let directory = try? await store.existingSessionDirectory(for: session.id),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")),
                  let saved = try? JSONDecoder().decode(SavedSummary.self, from: data),
                  saved.isCurrent(
                      session: session,
                      promptHash: promptHash
                  )
            else { return (installed, nil) }
            return (installed, saved)
        }.value
        guard self.generation == generation, !Task.isCancelled else { return }
        self.installed = snapshot.0
        self.output = snapshot.1?.text ?? ""
        self.outputProvenance = snapshot.1?.provenance ?? ""
        self.outputNotice = snapshot.1?.notice ?? ""
        self.checking = false
    }

    func download() {
        guard PrivateProfileStorage.isReadable(privateProfile), PrivateProfileStorage.acceptsNewWork else { return }
        guard !self.busy, let model else { return }
        self.downloading = true
        self.error = nil
        self.progress = .init(initialExpectedBytes: model.artifact.byteCount)
        self.operation = Task { [weak self] in
            guard let self else { return }
            defer { self.downloading = false; self.operation = nil }
            do {
                _ = try await PrivateAIIntegrationService.prepareModel(model) { [weak self] progress in
                    await self?.receiveProgress(progress)
                }
                try Task.checkCancellation()
                self.installed = true
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    func deleteModel(asr: ASRService) {
        guard PrivateProfileStorage.isReadable(privateProfile), PrivateProfileStorage.acceptsNewWork else { return }
        guard !self.busy, !self.checking, self.installed, let model else { return }
        self.generation = UUID()
        self.deleting = true
        self.error = nil
        self.operation = Task { [weak self] in
            guard let self else { return }
            defer { self.deleting = false; self.operation = nil }
            do {
                try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: asr) {
                    try await asr.withMeetingModelResidency(attemptID: UUID()) {
                        try Task.checkCancellation()
                        try await Task.detached(priority: .utility) {
                            try PrivateAIIntegrationService.removeInstalledModel(model)
                        }.value
                    }
                }
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
            // Reconcile partial removal too; saved summaries and selections stay untouched.
            self.installed = await Task.detached(priority: .utility) {
                PrivateAIIntegrationService.isModelInstalled(model)
            }.value
        }
    }

    func summarize(session: MeetingSession, kind: MeetingSummaryKind, route: MeetingSummaryRoute, customPrompt: String = "") {
        guard PrivateProfileStorage.isReadable(privateProfile), PrivateProfileStorage.acceptsNewWork else { return }
        guard !self.busy, !self.checking,
              let selectionLock = MeetingSummaryActivityCoordinator.shared.lockSelection() else { return }
        self.generating = true
        self.error = nil
        self.operation = Task {
            defer {
                self.generating = false
                self.operation = nil
                MeetingSummaryActivityCoordinator.shared.unlockSelection(selectionLock)
            }
            do {
                try await MeetingSummaryActivityCoordinator.shared.withRemoteSummary {
                    let (transcript, contentHash) = await Task.detached(priority: .utility) {
                        (MeetingSummaryInput.transcript(for: session), MeetingSummaryInput.contentFingerprint(for: session))
                    }.value
                    guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw MeetingPostProcessingError.invalidOutput
                    }
                    try Task.checkCancellation()
                    let instructions = kind == .custom ? customPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    let text = try await MeetingSummaryRemoteService.shared.generate(
                        transcript: transcript,
                        kind: kind,
                        route: route,
                        customInstructions: instructions,
                        languageCode: session.languageCode
                    )
                    try Task.checkCancellation()
                    let saved = SavedSummary(
                        transcriptHash: contentHash,
                        modelID: route.modelID,
                        text: text,
                        providerID: route.providerID,
                        providerName: route.providerName,
                        configurationHash: route.configurationHash,
                        promptVersion: MeetingSummaryInput.currentPromptVersion,
                        generatedAt: Date(),
                        promptHash: kind == .custom ? MeetingSummaryInput.fingerprint(instructions) : nil,
                        transcriptHashVersion: SavedSummary.currentTranscriptHashVersion
                    )
                    if session.requiresEncryptedPersistence != true {
                        guard let directory = try await self.store.existingSessionDirectory(for: session.id) else {
                            throw MeetingPostProcessingError.checkpointFailed
                        }
                        try await Task.detached(priority: .utility) {
                            try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic)
                        }.value
                    }
                    self.output = text
                    self.outputProvenance = saved.provenance
                    self.outputNotice = saved.notice
                }
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    /// Summarizes with the on-device model. Unlike a cloud summary it takes the meeting model
    /// residency, so dictation and other local models make room while it runs.
    func summarizeOnDevice(
        session: MeetingSession,
        kind: MeetingSummaryKind,
        customPrompt: String = "",
        thinking: Bool,
        asr: ASRService
    ) {
        guard PrivateProfileStorage.isReadable(privateProfile), PrivateProfileStorage.acceptsNewWork else { return }
        guard !self.busy, !self.checking, self.installed, let model,
              let selectionLock = MeetingSummaryActivityCoordinator.shared.lockSelection() else { return }
        self.generating = true
        self.error = nil
        self.operation = Task {
            defer {
                self.generating = false
                self.operation = nil
                MeetingSummaryActivityCoordinator.shared.unlockSelection(selectionLock)
            }
            do {
                try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: asr) {
                    let (transcript, contentHash) = await Task.detached(priority: .utility) {
                        (MeetingSummaryInput.transcript(for: session), MeetingSummaryInput.contentFingerprint(for: session))
                    }.value
                    guard transcript.utf8.count <= MeetingSummaryOnDevice.maximumTranscriptBytes else {
                        throw MeetingPostProcessingError.inputTooLarge
                    }
                    guard session.transcriptSegments.contains(where: { !$0.isEcho && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                        throw MeetingPostProcessingError.invalidOutput
                    }
                    let instructions = kind == .custom ? customPrompt.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                    guard kind != .custom || !instructions.isEmpty else {
                        throw LLMError.invalidRequest("Write a custom prompt before generating.")
                    }
                    try Task.checkCancellation()
                    let text = try await asr.withMeetingModelResidency(attemptID: UUID()) {
                        try MeetingModelResidencyCoordinator.shared.markSummary()
                        return try await PrivateAIIntegrationService.summarizeMeeting(
                            transcript,
                            style: kind.rawValue,
                            instructions: instructions,
                            thinking: thinking
                        )
                    }
                    try Task.checkCancellation()
                    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MeetingPostProcessingError.invalidOutput }
                    let saved = SavedSummary(
                        transcriptHash: contentHash,
                        modelID: model.id,
                        text: text,
                        providerID: MeetingSummaryOnDevice.providerID,
                        providerName: MeetingSummaryOnDevice.providerName,
                        configurationHash: MeetingSummaryInput.fingerprint("\(MeetingSummaryOnDevice.providerID)|\(model.id)|\(thinking)"),
                        promptVersion: MeetingSummaryInput.currentPromptVersion,
                        generatedAt: Date(),
                        promptHash: kind == .custom ? MeetingSummaryInput.fingerprint(instructions) : nil,
                        modelName: model.displayName,
                        transcriptHashVersion: SavedSummary.currentTranscriptHashVersion
                    )
                    if session.requiresEncryptedPersistence != true {
                        guard let directory = try await self.store.existingSessionDirectory(for: session.id) else {
                            throw MeetingPostProcessingError.checkpointFailed
                        }
                        try await Task.detached(priority: .utility) {
                            try JSONEncoder().encode(saved).write(to: directory.appendingPathComponent("manual-summary-\(kind.rawValue).json"), options: .atomic)
                        }.value
                    }
                    self.output = text
                    self.outputProvenance = saved.provenance
                    self.outputNotice = saved.notice
                }
            } catch is CancellationError {
                self.error = nil
            } catch {
                self.error = Task.isCancelled ? nil : error.localizedDescription
            }
        }
    }

    private func receiveProgress(_ progress: PrivateAIModelDownloadProgress) {
        self.progress = progress
    }

    func cancel() {
        self.operation?.cancel()
    }

    func prepareForPrivateProfileTransition() async throws {
        generation = UUID()
        profileRefreshID = nil
        let refresh = profileRefreshOperation; refresh?.cancel()
        let task = operation; task?.cancel()
        await refresh?.value
        await task?.value
        profileRefreshOperation = nil
        operation = nil; output = ""; outputProvenance = ""; error = nil; checking = false
    }
}

extension MeetingSavedSummary {
    var provenance: String {
        "\(self.providerName ?? "Fluid Intelligence") · \(self.modelName ?? self.modelID)"
    }

    var notice: String {
        self.providerID == MeetingSummaryOnDevice.providerID
            ? "Generated by AI on your Mac. May contain mistakes."
            : "Generated by AI. May contain mistakes."
    }
}
