import Foundation
import PichiTextPrivacy

/// One install path for Settings and meeting preparation. This resource is text
/// privacy metadata, never a fourth speech model or an AI-enhancement provider.
actor PichiTranscriptPrivacyModelStore {
    typealias Download = @Sendable (URL, Int64, @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse)
    static let descriptor = PIIModelDescriptor.russianTiny
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
/// must complete before the user starts; model errors propagate, never degrade
/// silently to regex-only or raw publication. Public results have no recovery map.
actor PichiTranscriptPrivacyService: TranscriptTextRedacting {
    let modelStore: PichiTranscriptPrivacyModelStore
    private let runtime: PIINERRuntime
    private var preparing = false
    private var inferenceCount = 0

    init(modelStore: PichiTranscriptPrivacyModelStore = .init(), runtime: PIINERRuntime = .init()) {
        self.modelStore = modelStore; self.runtime = runtime
    }

    var isReady: Bool { get async { await runtime.isReady } }

    func prepare(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        try Task.checkCancellation()
        guard !preparing else { throw TextPrivacyResourceError.operationInProgress }
        // Reusing this pinned resource never owns its weights and cannot unload a meeting's
        // ready redactor when a later settings preparation is cancelled.
        if await runtime.isReady {
            try Task.checkCancellation()
            return
        }
        guard !preparing, inferenceCount == 0 else { throw TextPrivacyResourceError.operationInProgress }
        preparing = true
        defer { preparing = false }
        do {
            let directory = try await modelStore.ensureInstalled(progress: progress)
            try Task.checkCancellation()
            try await runtime.load(directory: directory)
            try Task.checkCancellation()
        } catch {
            // A preparation cancelled after native loading must still release
            // its weights. Do not leave a ready session behind a failed UI state.
            await runtime.unload()
            throw error
        }
    }

    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try Task.checkCancellation()
        guard !preparing else { throw TextPrivacyError.notPrepared }
        inferenceCount += 1
        defer { inferenceCount -= 1 }
        let spans = try await runtime.tag(text)
        try Task.checkCancellation()
        let result = try PIIRedactor.redact(text, ner: spans)
        return .init(text: result.text, spans: result.spans.map { .init(range: $0.range, replacement: $0.replacement) },
                     provisionalSafeUTF16: try PIIRedactor.provisionalSafePrefix(in: text, ner: spans,
                                                                                redactedSpans: result.spans))
    }

    func unload() async throws {
        guard !preparing, inferenceCount == 0 else { throw TextPrivacyResourceError.operationInProgress }
        await runtime.unload()
    }

    func deleteModel() async throws {
        try await unload()
        try await modelStore.deleteInstalledModel()
    }
}
