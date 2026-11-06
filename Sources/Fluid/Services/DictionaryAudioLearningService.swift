#if arch(arm64)
import FluidAudio
#endif
import Foundation
import CryptoKit

/// Existing correction UI owns approval. This service owns only the optional background evidence.
@MainActor
final class DictionaryAudioLearningService {
    static var shared: DictionaryAudioLearningService {
        PrivateProfileObjectCache.value(key: "DictionaryAudioLearningService") { DictionaryAudioLearningService() }
    }
    enum TargetPublication { case rejected, unchanged, created }
    typealias Extractor = @Sendable (DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture

    private struct Request {
        let entry: SettingsStore.CustomDictionaryEntry
        let evidenceID: UUID
        let prepare: @MainActor () async throws -> DictionaryLearningAudioEvidence?
        let isValid: @MainActor () -> Bool
        let isCurrentBeforePreparation: @MainActor () -> Bool
        let publishTarget: (@MainActor () -> TargetPublication)?
        let didPublishTarget: (@MainActor () -> Void)?
        let explicitHistory: Bool
        let expiresAt: Date
        let pronunciationGeneration: String
    }

    private let store: PronunciationDictionaryStore
    private let extract: Extractor
    private let lifetime: TimeInterval
    private let canProcess: @MainActor () -> Bool
    private let canProcessHistory: @MainActor () -> Bool
    private let isCurrent: @MainActor (SettingsStore.CustomDictionaryEntry) -> Bool
    private var queue: [Request] = []
    private var task: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var retired = false
    private var foregroundAdmissions = 0
    private var activeEvidenceID: UUID?
    private let profile = PrivateProfileStorage.current
    var pendingCount: Int { self.queue.count }

    init(
        store: PronunciationDictionaryStore = .shared,
        lifetime: TimeInterval = 120,
        extract: @escaping Extractor = { evidence in
            try await AppServices.shared.asr.originalAudioEnrollment(evidence)
        },
        canProcess: @escaping @MainActor () -> Bool = {
            DictionaryMatcherExperiment.sharedFeaturesEnabled && SettingsStore.shared.automaticDictionaryLearningEnabled && AppServices.shared.asr.activeExclusiveActivity == nil
        },
        canProcessHistory: @escaping @MainActor () -> Bool = {
            DictionaryMatcherExperiment.sharedFeaturesEnabled && AppServices.shared.asr.activeExclusiveActivity == nil
        },
        isCurrent: @escaping @MainActor (SettingsStore.CustomDictionaryEntry) -> Bool = {
            DictionaryMatcherExperiment.sharedFeaturesEnabled && SettingsStore.shared.customDictionaryEntries.contains($0)
        }
    ) {
        self.store = store
        self.lifetime = min(120, max(0, lifetime))
        self.extract = extract
        self.canProcess = canProcess
        self.canProcessHistory = canProcessHistory
        self.isCurrent = isCurrent
    }

    /// Cancel encoder work immediately when audio activity starts. Retry the same bounded request when it ends.
    func cancelForRecording() { self.task?.cancel() }
    func activityDidEnd() { self.drain() }

    /// Block restarts before cancelling, then join the worker including provider retirement.
    func pauseForForegroundAdmission() async {
        self.foregroundAdmissions += 1
        let work = self.task
        work?.cancel()
        await work?.value
    }

    func resumeAfterForegroundAdmission() {
        precondition(self.foregroundAdmissions > 0)
        self.foregroundAdmissions -= 1
        self.drain()
    }

    func prepareForPrivateProfileTransition() async {
        retired = true
        queue.removeAll()
        let work = task, expiry = expiryTask
        work?.cancel(); expiry?.cancel()
        await work?.value; await expiry?.value
        task = nil; expiryTask = nil
    }

    func learn(
        entry: SettingsStore.CustomDictionaryEntry,
        evidenceID: UUID,
        evidence: DictionaryLearningAudioEvidence
    ) {
        guard !evidence.samples.isEmpty, evidence.samples.count <= 238_080 else { return }
        self.enqueue(entry: entry, evidenceID: evidenceID, explicitHistory: false, isValid: { true }, prepare: { evidence })
    }

    /// A completed correction already approves the spelling. Keep original-audio
    /// publication in this worker, including retries, cancellation and profile ownership.
    @discardableResult
    func learnCorrection(
        candidate: AutomaticDictionaryCorrectionCandidate,
        evidenceID: UUID = UUID(),
        isValid: @escaping @MainActor () -> Bool,
        prepare: @escaping @MainActor () async throws -> DictionaryLearningAudioEvidence?
    ) -> Bool {
        let label = candidate.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SettingsStore.shared.automaticDictionaryLearningEnabled,
              DictionaryCorrectionEditPolicy.isTerm(label) else { return false }
        guard let entry = Self.correctionTarget(label: label, entries: SettingsStore.shared.customDictionaryEntries) else { return false }
        let wasNew = !SettingsStore.shared.customDictionaryEntries.contains(entry)
        let eligible: @MainActor () -> Bool = {
            guard SettingsStore.shared.automaticDictionaryLearningEnabled, isValid() else { return false }
            let current = SettingsStore.shared.customDictionaryEntries.filter {
                $0.id == entry.id || $0.replacement.caseInsensitiveCompare(entry.replacement) == .orderedSame
            }
            return current.isEmpty ? wasNew : current.count == 1 && current[0] == entry
        }
        return self.enqueue(entry: entry, evidenceID: evidenceID, explicitHistory: false, isValid: eligible,
            isCurrentBeforePreparation: eligible, publishTarget: {
                guard eligible() else { return .rejected }
                if SettingsStore.shared.customDictionaryEntries.contains(entry) { return .unchanged }
                SettingsStore.shared.customDictionaryEntries.append(entry)
                return .created
            }, didPublishTarget: {
                ASRService.invalidateDictionaryCache()
                DictionaryEntriesChangeNotice.post()
            }, prepare: prepare)
    }

    static func correctionTarget(label: String, entries: [SettingsStore.CustomDictionaryEntry]) -> SettingsStore.CustomDictionaryEntry? {
        guard DictionaryCorrectionEditPolicy.isTerm(label) else { return nil }
        let matches = entries.filter { $0.replacement.caseInsensitiveCompare(label) == .orderedSame }
        guard matches.count <= 1 else { return nil }
        if let existing = matches.first { return existing }
        var bytes = Array(SHA256.hash(data: Data(("history-acoustic-entry:" + label.lowercased()).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let identifier = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return SettingsStore.CustomDictionaryEntry(id: identifier, triggers: [], replacement: label)
    }

    /// History preparation shares the same bounded, joined, profile-owned worker as enrollment.
    @discardableResult
    func enqueue(
        entry: SettingsStore.CustomDictionaryEntry, evidenceID: UUID, explicitHistory: Bool = true,
        isValid: @escaping @MainActor () -> Bool,
        isCurrentBeforePreparation: (@MainActor () -> Bool)? = nil,
        publishTarget: (@MainActor () -> TargetPublication)? = nil,
        didPublishTarget: (@MainActor () -> Void)? = nil,
        prepare: @escaping @MainActor () async throws -> DictionaryLearningAudioEvidence?
    ) -> Bool {
        guard !retired, PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              DictionaryMatcherExperiment.sharedFeaturesEnabled, isValid() else { return false }
        guard !self.queue.contains(where: { $0.evidenceID == evidenceID }) else { return false }
        self.pruneExpired()
        // Four short clips bound queued PCM to less than 4 MB. The text correction is already independent.
        guard self.queue.count < 4 else {
            DebugLogger.shared.warning(
                "Audio learning queue full; text correction retained",
                source: "DictionaryLearning"
            )
            return false
        }
        self.queue.append(Request(
            entry: entry,
            evidenceID: evidenceID,
            prepare: prepare,
            isValid: isValid,
            isCurrentBeforePreparation: isCurrentBeforePreparation ?? { [isCurrent] in isCurrent(entry) },
            publishTarget: publishTarget,
            didPublishTarget: didPublishTarget,
            explicitHistory: explicitHistory,
            expiresAt: Date().addingTimeInterval(self.lifetime),
            pronunciationGeneration: DictionaryMatcherExperiment.generation
        ))
        self.drain()
        self.scheduleExpiry()
        return true
    }

    private func drain() {
        self.pruneExpired()
        guard !retired, self.foregroundAdmissions == 0, PrivateProfileStorage.isReadable(profile), self.task == nil,
              let request = self.queue.first(where: { $0.explicitHistory ? self.canProcessHistory() : self.canProcess() }) else { return }
        self.activeEvidenceID = request.evidenceID
        self.task = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            var retry = false
            var notifyPublication = false
            defer {
                if !retry { self.queue.removeAll { $0.evidenceID == request.evidenceID } }
                self.task = nil
                self.activeEvidenceID = nil
                if notifyPublication { request.didPublishTarget?() }
                self.drain()
                self.scheduleExpiry()
            }
            guard request.isCurrentBeforePreparation(), request.isValid(), request.pronunciationGeneration == DictionaryMatcherExperiment.generation else { return }
            do {
                guard let evidence = try await request.prepare(), !evidence.samples.isEmpty, evidence.samples.count <= 238_080 else { return }
                try Task.checkCancellation()
                guard request.expiresAt > Date(), (request.publishTarget == nil ? self.isCurrent(request.entry) : request.isCurrentBeforePreparation()), request.isValid(), request.pronunciationGeneration == DictionaryMatcherExperiment.generation else { return }
                let revision = await self.store.revision(for: request.entry.id)
                let capture = try await self.extract(evidence)
                try Task.checkCancellation()
                guard request.expiresAt > Date(), (request.publishTarget == nil ? self.isCurrent(request.entry) : request.isCurrentBeforePreparation()), request.isValid(), request.pronunciationGeneration == DictionaryMatcherExperiment.generation else { return }
                let inserted = try await self.store.learnOriginalAudio(
                    entryID: request.entry.id,
                    label: request.entry.replacement,
                    evidenceID: request.evidenceID,
                    evidence: evidence,
                    capture: capture,
                    expectedRevision: revision,
                    canPersist: { DictionaryMatcherExperiment.sharedFeaturesEnabled && request.pronunciationGeneration == DictionaryMatcherExperiment.generation }
                )
                // An edit can happen while awaiting the store actor. Roll back only this event.
                if Task.isCancelled || request.expiresAt <= Date() || !request.isValid() ||
                    request.pronunciationGeneration != DictionaryMatcherExperiment.generation ||
                    !(request.publishTarget == nil ? self.isCurrent(request.entry) : request.isCurrentBeforePreparation()) {
                    if inserted { try await self.store.removeOriginalAudio(evidenceID: request.evidenceID) }
                    retry = Task.isCancelled && request.expiresAt > Date()
                    return
                }
                if let publish = request.publishTarget {
                    switch publish() {
                    case .rejected:
                        if inserted { try await self.store.removeOriginalAudio(evidenceID: request.evidenceID) }
                        return
                    case .unchanged: break
                    case .created: notifyPublication = true
                    }
                }
                DebugLogger.shared.info(
                    inserted ? "Original pronunciation evidence saved" : "Original pronunciation evidence already present",
                    source: "DictionaryLearning"
                )
            } catch is CancellationError {
                retry = Task.isCancelled && request.expiresAt > Date()
            } catch {
                DebugLogger.shared.warning(
                    "Original pronunciation evidence was not saved: \(error.localizedDescription)",
                    source: "DictionaryLearning"
                )
            }
        }
    }

    private func pruneExpired() {
        if self.queue.contains(where: { $0.evidenceID == self.activeEvidenceID && $0.expiresAt <= Date() }) { self.task?.cancel() }
        self.queue.removeAll { $0.expiresAt <= Date() }
    }

    private func scheduleExpiry() {
        self.expiryTask?.cancel()
        guard let expiry = self.queue.map(\.expiresAt).min() else { self.expiryTask = nil; return }
        let delay = max(0, expiry.timeIntervalSinceNow)
        self.expiryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.pruneExpired()
            self?.drain()
            self?.scheduleExpiry()
        }
    }
}

actor OriginalAudioEmbeddingExtractor {
    @concurrent static func extract(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture {
        try Task.checkCancellation()
        #if arch(arm64)
        guard let descriptor = ParakeetSpeechModelCatalog.descriptor(forInstalledPronunciationModelKey: evidence.modelKey) else {
            if ParakeetSpeechModelCatalog.isOutdatedCompactPronunciationModelKey(evidence.modelKey) {
                throw PronunciationDictionaryStoreError.outdatedModelRevision
            }
            throw PronunciationDictionaryStoreError.inconsistentEnrollment
        }
        let version = descriptor.asrModelVersion
        let directory = AppModelPaths.parakeet(for: version)
        guard descriptor.installationRevisionMatches(at: directory),
              descriptor.variant == .v2 || descriptor.variant == .v3 || descriptor.installedArchiveSHA256(at: directory) == descriptor.archiveSHA256
        else {
            throw PronunciationDictionaryStoreError.outdatedModelRevision
        }
        let models = try await AsrModels.loadLocalOnly(
            from: directory,
            version: version
        )
        try Task.checkCancellation()
        guard descriptor.installationRevisionMatches(at: directory) else {
            throw PronunciationDictionaryStoreError.outdatedModelRevision
        }
        try Task.checkCancellation()
        let manager = AsrManager(config: ASRConfig(
            tdtConfig: TdtConfig(blankId: version.blankId),
            encoderHiddenSize: version.encoderHiddenSize
        ))
        do {
            try await manager.initialize(models: models)
            let embedding = try await manager.pronunciationEmbedding(
                audioSamples: evidence.samples,
                focalSampleRange: evidence.focalSampleRange
            )
            await manager.cleanup()
            try Task.checkCancellation()
            return PronunciationEnrollmentCapture(
                values: embedding.values,
                sourceFrameCount: embedding.sourceFrameCount,
                modelKey: evidence.modelKey
            )
        } catch {
            await manager.cleanup()
            throw error
        }
        #else
        throw PronunciationDictionaryStoreError.inconsistentEnrollment
        #endif
    }
}
