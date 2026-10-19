import Foundation
import PichiTextPrivacy

/// One install path for Settings and meeting preparation. This resource is text
/// privacy metadata, never a fourth speech model or an AI-enhancement provider.
actor PichiTranscriptPrivacyModelStore {
    typealias Download = @Sendable (URL, Int64, @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse)
    static let descriptor = PIIModelDescriptor.russianA1
    private let root: URL
    private let download: Download
    private var installation: Task<URL, Error>?

    init(directory: URL? = nil, download: @escaping Download = { source, maximumBytes, progress in
        try await PichiTranscriptPrivacyModelStore.downloadArtifact(source, maximumBytes: maximumBytes, progress: progress)
    }) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let namespace = Bundle.main.bundleIdentifier ?? "ai.pichi.voice"
        self.root = directory ?? support.appendingPathComponent(namespace, isDirectory: true).appendingPathComponent("Models/TextPrivacy", isDirectory: true)
        self.download = download
    }

    var directory: URL { root.appendingPathComponent(Self.descriptor.id, isDirectory: true) }

    /// Cheap UI readiness only. Full validation is mandatory during preparation.
    func isInstalled() -> Bool {
        Self.descriptor.artifacts.allSatisfy { artifact in
            let file = directory.appendingPathComponent(artifact.filename)
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true && Int64(values.fileSize ?? -1) == artifact.byteCount
        }
    }

    func ensureInstalled(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try Task.checkCancellation()
        // Resource operation has one owner. A parallel settings click does not
        // cancel another caller's download or share its mutable progress state.
        guard installation == nil else { throw TextPrivacyResourceError.operationInProgress }
        let root = self.root
        let destination = directory
        let descriptor = Self.descriptor
        let download = self.download
        let task = Task.detached(priority: .utility) {
            let manager = FileManager.default
            try Self.validateOwned(root)
            if manager.fileExists(atPath: destination.path) {
                if (try? descriptor.verify(in: destination)) != nil { progress(1); return destination }
                try Task.checkCancellation()
            }
            try manager.createDirectory(at: root, withIntermediateDirectories: true)
            try Self.validateOwned(root)
            let stage = root.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: stage) }
            var completed: Int64 = 0
            for artifact in descriptor.artifacts {
                try Task.checkCancellation()
                let base = completed
                let (temporary, response) = try await download(descriptor.downloadBaseURL.appendingPathComponent(artifact.remotePath), artifact.byteCount) { bytes, _ in
                    progress(min(0.999, Double(base + bytes) / Double(descriptor.byteCount)))
                }
                defer { try? manager.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { throw URLError(.badServerResponse) }
                try Task.checkCancellation()
                let values = try temporary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == artifact.byteCount else {
                    throw TextPrivacyError.checksumMismatch(artifact.filename)
                }
                try manager.moveItem(at: temporary, to: stage.appendingPathComponent(artifact.filename))
                completed += artifact.byteCount
            }
            try descriptor.verify(in: stage)
            try Task.checkCancellation()
            try Self.validateOwned(destination)
            let backup = root.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
            let replaced = manager.fileExists(atPath: destination.path)
            if replaced { try manager.moveItem(at: destination, to: backup) }
            do { try manager.moveItem(at: stage, to: destination) }
            catch {
                if replaced { try? manager.moveItem(at: backup, to: destination) }
                throw error
            }
            if replaced { try? manager.removeItem(at: backup) }
            progress(1)
            return destination
        }
        installation = task
        defer { installation = nil }
        let installed = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return installed
    }

    func deleteInstalledModel() throws {
        guard installation == nil else { throw TextPrivacyResourceError.operationInProgress }
        try Self.validateOwned(root)
        try Self.validateOwned(directory)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private static func validateOwned(_ directory: URL) throws {
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else { throw TextPrivacyError.incompatibleModel }
    }

    private static func downloadArtifact(_ source: URL, maximumBytes: Int64,
                                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 600
        return try await ProgressiveFileDownloader.download(from: source, configuration: configuration, maximumBytes: maximumBytes, onProgress: progress)
    }
}

enum TextPrivacyResourceError: Error { case operationInProgress }

/// A meeting freezes this service as its transcript privacy capability. Prepare
/// completes at each processing entry point; model errors propagate, never degrade
/// silently to regex-only or raw publication. Public results have no recovery map.
actor PichiTranscriptPrivacyService: TranscriptTextRedacting {
    nonisolated var checkpointIdentity: String? {
        PIIModelDescriptor.russianA1.fingerprint + "/contact-credentials-rules-v3/speech-boundary-v2"
    }
    let modelStore: PichiTranscriptPrivacyModelStore
    private let runtime: PIINERRuntime
    private let preparation: PichiPrivacyPreparationOwner
    private var inferenceCount = 0

    init(modelStore: PichiTranscriptPrivacyModelStore = .init(), runtime: PIINERRuntime = .init()) {
        self.modelStore = modelStore; self.runtime = runtime
        self.preparation = PichiPrivacyPreparationOwner(isReady: { await runtime.isReady },
            load: { installedOnly, progress in
                let directory: URL
                if installedOnly {
                    guard await modelStore.isInstalled() else { return false }
                    directory = await modelStore.directory
                } else {
                    directory = try await modelStore.ensureInstalled(progress: progress)
                }
                try Task.checkCancellation()
                try await runtime.load(descriptor: PichiTranscriptPrivacyModelStore.descriptor, directory: directory)
                return true
            }, unload: { await runtime.unload() })
    }

    var isReady: Bool { get async { await runtime.isReady } }

    func prepareForMeeting() async throws { try await self.prepare() }

    func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try await preparation.prepare(progress: progress)
    }

    /// Optional startup work only opens an already installed, checksum-verified artifact.
    /// The exact token can retire its resource until a real service operation adopts it.
    func prepareInstalledForIdle() async throws -> PichiPrivacyPreparationOwner.IdleToken? {
        guard inferenceCount == 0 else { return nil }
        return try await preparation.prepareInstalledForIdle()
    }

    func releaseIdlePreparation(_ token: PichiPrivacyPreparationOwner.IdleToken) async {
        await preparation.releaseIdle(token)
    }

    nonisolated var supportsSpeechBoundaryAdmission: Bool { true }

    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await self.evaluate(text, atSpeechBoundary: false)
    }

    func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await self.evaluate(text, atSpeechBoundary: true)
    }

    private func evaluate(_ text: String, atSpeechBoundary: Bool) async throws -> TranscriptTextRedaction {
        try Task.checkCancellation()
        inferenceCount += 1
        defer { inferenceCount -= 1 }
        try await preparation.adoptForInference()
        let spans = try await runtime.tag(text)
        try Task.checkCancellation()
        if atSpeechBoundary {
            let result = try PIIRedactor.redactSpeechBoundary(text, ner: spans)
            return .init(text: result.text,
                spans: result.spans.map { .init(range: $0.range, replacement: $0.replacement) })
        }
        let result = try PIIRedactor.redact(text, ner: spans)
        return .init(text: result.text, spans: result.spans.map { .init(range: $0.range, replacement: $0.replacement) },
                     provisionalSafeUTF16: try PIIRedactor.provisionalSafePrefix(in: text, ner: spans,
                                                                                redactedSpans: result.spans))
    }

    func unload() async throws {
        guard inferenceCount == 0 else { throw TextPrivacyResourceError.operationInProgress }
        try await preparation.unload()
    }

    func deleteModel() async throws {
        try await unload()
        try await modelStore.deleteInstalledModel()
    }
}

/// Owns the shared privacy loader and only the optional idle residency it created.
/// Settings and recording adopt the same task; cancelling an obsolete idle request cannot
/// unload adopted weights. The closures are the existing store/runtime operations, also
/// allowing deterministic cancellation tests without loading or downloading model weights.
actor PichiPrivacyPreparationOwner {
    struct IdleToken: Equatable, Sendable { fileprivate let id: UUID }
    typealias Progress = @Sendable (Double) -> Void
    private struct Operation {
        let id: UUID
        let resourceGeneration: UUID
        let task: Task<Bool, Error>
        var idle: IdleToken?
        var waiters: Set<UUID> = []
    }
    private let isReady: @Sendable () async -> Bool
    private let load: @Sendable (Bool, @escaping Progress) async throws -> Bool
    private let release: @Sendable () async -> Void
    private var operation: Operation?
    private var idleReady: IdleToken?
    private var releasing: Task<Void, Never>?
    private var resourceGeneration = UUID()

    init(isReady: @escaping @Sendable () async -> Bool,
         load: @escaping @Sendable (Bool, @escaping Progress) async throws -> Bool,
         unload: @escaping @Sendable () async -> Void) {
        self.isReady = isReady; self.load = load; self.release = unload
    }

    func prepare(progress: @escaping Progress = { _ in }) async throws {
        while true {
            try Task.checkCancellation()
            await releasing?.value
            try Task.checkCancellation()
            if let current = operation, current.task.isCancelled {
                _ = await current.task.result
                await retire(current.id)
                continue
            }
            if operation == nil {
                let generation = resourceGeneration
                let ready = await isReady()
                // A load/unload can fully finish during this actor hop. Absence of a
                // current task alone cannot validate the returned readiness snapshot.
                if resourceGeneration != generation || operation != nil || releasing != nil { continue }
                try Task.checkCancellation()
                if ready { idleReady = nil; return }
            }
            let selected = operation ?? begin(installedOnly: false, idle: nil, progress: progress)
            let waiter = UUID()
            operation?.idle = nil
            operation?.waiters.insert(waiter)
            let result = await withTaskCancellationHandler {
                await selected.task.result
            } onCancel: {
                Task { await self.cancelWaiter(waiter, operationID: selected.id) }
            }
            if operation?.id == selected.id { operation?.waiters.remove(waiter) }
            if Task.isCancelled {
                await cancelWaiter(waiter, operationID: selected.id, alreadyRemoved: true)
                throw CancellationError()
            }
            switch result {
            case .success(true):
                // A different waiter may already have adopted and then explicitly retired
                // this completed task's model before this waiter resumes.
                guard resourceGeneration == selected.resourceGeneration, releasing == nil,
                      operation == nil || operation?.id == selected.id else { continue }
                if operation?.id == selected.id { operation = nil }
                idleReady = nil
                return
            case .success(false):
                // An idle installed-only check found no artifact. The explicit caller still
                // uses its normal installation operation, rather than inheriting that result.
                if operation?.id == selected.id { operation = nil }
                continue
            case .failure(let error):
                await retire(selected.id)
                throw error
            }
        }
    }

    func prepareInstalledForIdle() async throws -> IdleToken? {
        while true {
            try Task.checkCancellation()
            await releasing?.value
            guard operation == nil else { return nil }
            let generation = resourceGeneration
            let ready = await isReady()
            try Task.checkCancellation()
            guard resourceGeneration == generation, operation == nil, releasing == nil else { continue }
            if ready { return nil }
            let token = IdleToken(id: UUID())
            let selected = begin(installedOnly: true, idle: token, progress: { _ in })
            let result = await withTaskCancellationHandler {
                await selected.task.result
            } onCancel: {
                Task { await self.releaseIdle(token) }
            }
            if Task.isCancelled {
                await releaseIdle(token)
                throw CancellationError()
            }
            guard resourceGeneration == selected.resourceGeneration,
                  operation?.id == selected.id, operation?.idle == token else { return nil }
            switch result {
            case .success(true):
                operation = nil
                idleReady = token
                return token
            case .success(false):
                operation = nil
                return nil
            case .failure(let error):
                await retire(selected.id)
                throw error
            }
        }
    }

    func releaseIdle(_ token: IdleToken) async {
        if let selected = operation, selected.idle == token {
            operation?.idle = nil
            selected.task.cancel()
            _ = await selected.task.result
            await retire(selected.id)
        } else if idleReady == token {
            idleReady = nil
            await releaseResource()
        }
    }

    /// Publication adopts a ready idle resource even for callers that already checked
    /// readiness themselves. Native preparation is never accepted as completed early.
    func adoptForInference() async throws {
        guard operation == nil, releasing == nil else { throw TextPrivacyError.notPrepared }
        idleReady = nil
    }

    func unload() async throws {
        guard operation == nil else { throw TextPrivacyResourceError.operationInProgress }
        idleReady = nil
        await releaseResource()
    }

    private func begin(installedOnly: Bool, idle: IdleToken?, progress: @escaping Progress) -> Operation {
        resourceGeneration = UUID()
        let load = self.load, release = self.release
        let task = Task(priority: installedOnly ? .utility : .userInitiated) {
            do {
                let loaded = try await load(installedOnly, progress)
                try Task.checkCancellation()
                return loaded
            } catch {
                await release()
                throw error
            }
        }
        let selected = Operation(id: UUID(), resourceGeneration: resourceGeneration, task: task, idle: idle)
        operation = selected
        return selected
    }

    private func cancelWaiter(_ waiter: UUID, operationID: UUID, alreadyRemoved: Bool = false) async {
        guard operation?.id == operationID,
              alreadyRemoved || operation?.waiters.remove(waiter) != nil else { return }
        guard operation?.waiters.isEmpty == true, operation?.idle == nil else { return }
        operation?.task.cancel()
        if let task = operation?.task { _ = await task.result }
        await retire(operationID)
    }

    private func retire(_ operationID: UUID) async {
        guard let selected = operation, selected.id == operationID else { return }
        let result = await selected.task.result
        guard operation?.id == operationID else { return }
        operation = nil
        // Cancellation may land after a native loader has already returned successfully.
        // Only this still-unadopted operation can release that late ready resource.
        if selected.task.isCancelled, case .success(true) = result { await releaseResource() }
    }

    private func releaseResource() async {
        if let releasing { await releasing.value; return }
        resourceGeneration = UUID()
        let release = self.release
        let task = Task { await release() }
        releasing = task
        await task.value
        releasing = nil
    }
}

/// Foreground lifetime for the optional installed-only privacy preparation. It does not
/// own a recording, microphone, settings installation, or an adopted model. An active
/// recording keeps an already-started preparation available for the normal service join.
@MainActor
final class PichiPrivacyIdlePreparationController {
    struct Input: Equatable {
        let isSceneActive: Bool
        let isUIReady: Bool
        let privacyEnabled: Bool
        let configurationIdentity: String
        let hasRecordingActivity: Bool
        let hasOtherModelWork: Bool
    }
    private let prepare: @Sendable () async throws -> PichiPrivacyPreparationOwner.IdleToken?
    private let release: @Sendable (PichiPrivacyPreparationOwner.IdleToken) async -> Void
    private var input: Input?
    private var generation = UUID()
    private var attemptedIdentity: String?
    private var memoryPressure = false
    private var task: Task<Void, Never>?
    private var token: PichiPrivacyPreparationOwner.IdleToken?
    private var drain: Task<Void, Never>?

    init(prepare: @escaping @Sendable () async throws -> PichiPrivacyPreparationOwner.IdleToken?,
         release: @escaping @Sendable (PichiPrivacyPreparationOwner.IdleToken) async -> Void) {
        self.prepare = prepare; self.release = release
    }

    func update(_ next: Input) async {
        let previous = input
        input = next
        if next.isSceneActive && previous?.isSceneActive != true {
            memoryPressure = false
            attemptedIdentity = nil
        }
        let configurationChanged = previous?.configurationIdentity != next.configurationIdentity
            || previous?.privacyEnabled != next.privacyEnabled
        if configurationChanged { attemptedIdentity = nil }
        if next.hasOtherModelWork { attemptedIdentity = nil }
        let eligible = next.isSceneActive && next.isUIReady && next.privacyEnabled && !memoryPressure
        let keepForRecording = eligible && next.hasRecordingActivity && !configurationChanged
        if keepForRecording { return }
        if !eligible || next.hasRecordingActivity || next.hasOtherModelWork || configurationChanged {
            await stop()
        }
        guard input == next, eligible, !next.hasRecordingActivity, !next.hasOtherModelWork,
              task == nil, attemptedIdentity != next.configurationIdentity else { return }
        if let drain { await drain.value }
        guard input == next, !memoryPressure, task == nil else { return }
        attemptedIdentity = next.configurationIdentity
        let request = UUID()
        generation = request
        let prepare = self.prepare, release = self.release
        task = Task { [weak self] in
            do {
                let token = try await prepare()
                guard let self, self.generation == request, !Task.isCancelled else {
                    if let token { await release(token) }
                    return
                }
                self.token = token
            } catch {
                // Optional preparation failure leaves the normal explicit service path intact.
            }
        }
    }

    func didReceiveMemoryWarning() async {
        memoryPressure = true
        await stop()
    }

    private func stop() async {
        generation = UUID()
        if let drain { await drain.value; return }
        let priorTask = task, priorToken = token
        task = nil; token = nil
        priorTask?.cancel()
        let release = self.release
        let joined = Task {
            await priorTask?.value
            if let priorToken { await release(priorToken) }
        }
        drain = joined
        await joined.value
        drain = nil
    }
}
