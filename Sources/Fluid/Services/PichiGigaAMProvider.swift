import Foundation
import PichiGigaAM

/// Local, hash-verified optimized GigaAM exports. Import copies only model artifacts
/// into our storage; private recordings, dictionaries and training data stay outside it.
final nonisolated class PichiGigaAMModelStore: @unchecked Sendable {
    typealias Download = @Sendable (URL, Int64, @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse)
    static let shared = PichiGigaAMModelStore()
    static var defaultDownloadByteCount: Int64 {
        let descriptor = GigaAMModelCatalog.downloadableModel
        return (descriptor.modelByteCount ?? 0) + (descriptor.vocabularyByteCount ?? 0)
    }
    static var supportsDefaultDownload: Bool { GigaAMModelCatalog.downloadableModel.downloadBaseURL != nil }
    private static let directoryPreferenceKey = "pichiGigaAMModelDirectory"
    private let overriddenDirectory: URL?
    private let downloadDescriptor: GigaAMModelDescriptor
    private let download: Download

    init(directory: URL? = nil, downloadDescriptor: GigaAMModelDescriptor = GigaAMModelCatalog.downloadableModel,
         download: @escaping Download = PichiGigaAMModelStore.downloadArtifact) {
        self.overriddenDirectory = directory
        self.downloadDescriptor = downloadDescriptor
        self.download = download
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let namespace = Bundle.main.bundleIdentifier ?? "ai.pichi.voice"
        return support.appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("Models/GigaAM", isDirectory: true)
    }

    static var configuredModelDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["PICHI_GIGAAM_MODEL_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let path = UserDefaults.standard.string(forKey: self.directoryPreferenceKey), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return self.defaultDirectory
    }

    static func setModelDirectory(_ url: URL) {
        UserDefaults.standard.set(url.standardizedFileURL.path, forKey: self.directoryPreferenceKey)
    }

    var directory: URL { self.overriddenDirectory ?? Self.configuredModelDirectory }

    // Disk scans in the model picker remain cheap. Full digests are verified off the
    // main actor during import and preparation, never on a SwiftUI render.
    func modelsExistOnDisk() -> Bool { GigaAMModelCatalog.discover(in: self.directory) != nil }

    func installedModel() throws -> (descriptor: GigaAMModelDescriptor, directory: URL) {
        guard let model = GigaAMModelCatalog.discover(in: self.directory) else {
            throw GigaAMError.missingModels(self.directory)
        }
        return model
    }

    func installedModelFingerprint() throws -> String {
        try self.installedModel().descriptor.fingerprint
    }

    /// Initial preparation downloads only the registered public export. User-configured
    /// external directories remain read-only; injected destinations are isolated test/owned
    /// stores. Complete local imports keep their priority.
    func ensureInstalled(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws -> (descriptor: GigaAMModelDescriptor, directory: URL) {
        try Task.checkCancellation()
        let destinationRoot = self.directory.standardizedFileURL
        if let installed = GigaAMModelCatalog.discover(in: destinationRoot) { return installed }
        guard self.overriddenDirectory != nil || destinationRoot.path == Self.defaultDirectory.standardizedFileURL.path else {
            throw GigaAMError.missingModels(destinationRoot)
        }
        let descriptor = self.downloadDescriptor
        let relay = ModelPreparationProgressRelay(progressHandler)
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = descriptor.downloadBaseURL, source.scheme == "https",
                  let modelBytes = descriptor.modelByteCount, modelBytes > 0,
                  let vocabularyFile = descriptor.vocabularyFile,
                  let vocabularyBytes = descriptor.vocabularyByteCount, vocabularyBytes > 0 else {
                throw GigaAMError.incompatibleModel
            }
            try Self.validateOwnedDirectory(destinationRoot)
            let manager = FileManager.default
            try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            try Self.validateOwnedDirectory(destinationRoot)
            let stage = destinationRoot.appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false)
            defer { try? manager.removeItem(at: stage) }
            relay.report(.preparingDownload)
            let totalBytes = modelBytes + vocabularyBytes
            var completedBytes: Int64 = 0
            for (filename, byteCount) in [(descriptor.modelFile, modelBytes), (vocabularyFile, vocabularyBytes)] {
                try Task.checkCancellation()
                let base = completedBytes
                let (temporaryURL, response) = try await self.download(source.appendingPathComponent(filename), byteCount) { written, _ in
                    relay.report(.downloading(min(0.999, Double(base + written) / Double(totalBytes))))
                }
                defer { try? manager.removeItem(at: temporaryURL) }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                try Task.checkCancellation()
                let attributes = try manager.attributesOfItem(atPath: temporaryURL.path)
                guard (attributes[.size] as? NSNumber)?.int64Value == byteCount else {
                    throw GigaAMError.checksumMismatch(filename)
                }
                try manager.moveItem(at: temporaryURL, to: stage.appendingPathComponent(filename))
                completedBytes += byteCount
            }
            try descriptor.verify(in: stage)
            try Task.checkCancellation()
            let target = try Self.publish(stage, descriptor: descriptor, destinationRoot: destinationRoot)
            relay.report(.downloading(1))
            return target
        }
        let target = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        return (descriptor, target)
    }

    private static func downloadArtifact(_ source: URL, maximumBytes: Int64,
                                         progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return try await ProgressiveFileDownloader.download(from: source, configuration: configuration,
                                                            maximumBytes: maximumBytes, onProgress: progress)
    }

    private static func validateOwnedDirectory(_ directory: URL) throws {
        // Foundation drops a nonexistent directory's trailing slash when resolving it.
        // Compare filesystem paths so a new catalog target is still a valid destination.
        guard directory.resolvingSymlinksInPath().standardizedFileURL.path == directory.standardizedFileURL.path else {
            throw GigaAMError.incompatibleModel
        }
    }

    /// Shared publication for downloads and local imports. The verified complete folder
    /// replaces only its catalog ID after cancellation checks and rolls back on failure.
    private static func publish(_ stage: URL, descriptor: GigaAMModelDescriptor, destinationRoot: URL) throws -> URL {
        try Self.validateOwnedDirectory(destinationRoot)
        let manager = FileManager.default
        let target = destinationRoot.appendingPathComponent(descriptor.id, isDirectory: true)
        try Self.validateOwnedDirectory(target)
        let backup = destinationRoot.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
        let replacing = manager.fileExists(atPath: target.path)
        if replacing { try manager.moveItem(at: target, to: backup) }
        do {
            try manager.moveItem(at: stage, to: target)
        } catch {
            if replacing { try? manager.moveItem(at: backup, to: target) }
            throw error
        }
        if replacing { try? manager.removeItem(at: backup) }
        return target
    }

    func importModel(from sourceDirectory: URL) async throws {
        let destinationRoot = self.overriddenDirectory ?? Self.defaultDirectory
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = GigaAMModelCatalog.discover(in: sourceDirectory) else {
                throw GigaAMError.missingModels(sourceDirectory)
            }
            try source.descriptor.verify(in: source.directory)
            let manager = FileManager.default
            try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            let target = destinationRoot.appendingPathComponent(source.descriptor.id, isDirectory: true)
            if target.standardizedFileURL == source.directory.standardizedFileURL { return }
            let stage = destinationRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: stage) }
            for name in [source.descriptor.modelFile] + [source.descriptor.vocabularyFile].compactMap({ $0 }) {
                try Task.checkCancellation()
                try manager.copyItem(at: source.directory.appendingPathComponent(name), to: stage.appendingPathComponent(name))
            }
            try source.descriptor.verify(in: stage)
            try Task.checkCancellation()
            _ = try Self.publish(stage, descriptor: source.descriptor, destinationRoot: destinationRoot)
        }
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if self.overriddenDirectory == nil { Self.setModelDirectory(destinationRoot) }
    }

    /// Never remove an externally configured source directory.
    func removeOwnedModels() throws {
        let directory = self.directory.standardizedFileURL
        guard self.overriddenDirectory == nil,
              directory.path == Self.defaultDirectory.standardizedFileURL.path else { return }
        try Self.validateOwnedDirectory(directory)
        for descriptor in GigaAMModelCatalog.models {
            let path = directory.appendingPathComponent(descriptor.id, isDirectory: true)
            if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        }
    }
}

/// Narrow adapter onto the upstream provider contract. All inference runs in the
/// package actor, so dictation, file processing and the local API share one backend.
final class PichiGigaAMProvider: TranscriptionProvider {
    let name = "Pichi GigaAM v3"
    let isAvailable = true
    let supportsWordTimings = true
    let shouldClearCacheAfterCancellation = false
    private(set) var isReady = false

    private let modelStore: PichiGigaAMModelStore
    private let expectedModelFingerprint: String?
    private(set) var loadedModelFingerprint: String?
    private var runtime: GigaAMRuntime?
    private var preparationTask: Task<Void, Error>?
    private var lifecycleGeneration = 0

    init(modelStore: PichiGigaAMModelStore = .shared, expectedModelFingerprint: String? = nil) {
        self.modelStore = modelStore
        self.expectedModelFingerprint = expectedModelFingerprint
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        if self.isReady { return }
        if let task = self.preparationTask {
            let generation = self.lifecycleGeneration
            try await task.value
            try Task.checkCancellation()
            guard self.lifecycleGeneration == generation, self.isReady, self.runtime != nil else {
                throw CancellationError()
            }
            return
        }
        let runtime = try GigaAMRuntime()
        self.lifecycleGeneration += 1
        let generation = self.lifecycleGeneration
        self.runtime = runtime
        let task = Task {
            let model = if self.expectedModelFingerprint != nil {
                try self.modelStore.installedModel()
            } else {
                try await self.modelStore.ensureInstalled(progressHandler: progressHandler)
            }
            let fingerprint = model.descriptor.fingerprint
            if let expected = self.expectedModelFingerprint, expected != fingerprint {
                throw NSError(domain: "PichiGigaAMProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "The installed GigaAM export has changed since this meeting was scheduled. Restore that export or start a new processing run."])
            }
            try Task.checkCancellation()
            progressHandler?(.loading)
            try await runtime.load(descriptor: model.descriptor, directory: model.directory)
            try Task.checkCancellation()
            guard self.lifecycleGeneration == generation, self.runtime === runtime else {
                throw CancellationError()
            }
            self.loadedModelFingerprint = fingerprint
            self.isReady = true
        }
        self.preparationTask = task
        defer {
            if self.lifecycleGeneration == generation { self.preparationTask = nil }
        }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            guard self.lifecycleGeneration == generation, self.isReady, self.runtime === runtime else {
                throw CancellationError()
            }
        } catch {
            await runtime.unload()
            if self.lifecycleGeneration == generation {
                self.runtime = nil
                self.loadedModelFingerprint = nil
                self.isReady = false
            }
            throw error
        }
    }

    func transcribeDetailed(_ samples: [Float]) async throws -> GigaAMTranscript {
        try Task.checkCancellation()
        guard self.isReady, let runtime = self.runtime else { throw GigaAMError.notPrepared }
        return try await runtime.transcribe(samples)
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let result = try await self.transcribeDetailed(samples)
        return ASRTranscriptionResult(text: result.text, confidence: result.confidence, endOfUtteranceProbability: result.endOfUtteranceProbability)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples)
    }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        let result = try await self.transcribeDetailed(samples)
        return (
            ASRTranscriptionResult(text: result.text, confidence: result.confidence, endOfUtteranceProbability: result.endOfUtteranceProbability),
            result.words.map { ASRWordTiming(text: $0.text, start: $0.start, end: $0.end) }
        )
    }

    func modelsExistOnDisk() -> Bool { self.modelStore.modelsExistOnDisk() }

    func unloadModel() async {
        // Invalidate ownership before suspending. An old prepare completion cannot
        // publish readiness or clear a newer session after this point.
        self.lifecycleGeneration += 1
        let preparationTask = self.preparationTask
        let runtime = self.runtime
        self.preparationTask = nil
        self.runtime = nil
        self.isReady = false
        self.loadedModelFingerprint = nil
        preparationTask?.cancel()
        if let task = preparationTask { _ = try? await task.value }
        await runtime?.unload()
    }

    func releaseResidency() async { await self.unloadModel() }

    func importModel(from directory: URL) async throws {
        try await self.modelStore.importModel(from: directory)
    }

    func clearCache() async throws {
        await self.unloadModel()
        try self.modelStore.removeOwnedModels()
    }
}
