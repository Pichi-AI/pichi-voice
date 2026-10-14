import Foundation
import PichiGigaAM

extension GigaAMModelDescriptor {
    /// The E2E tokenizer identifies formatted exports; older character exports do not
    /// inherit their punctuation claims or the measured v5 CPU speed.
    nonisolated var libraryMetadata: SpeechModelLibraryMetadata {
        if let modelBytes = self.modelByteCount, let vocabularyBytes = self.vocabularyByteCount {
            return SpeechModelLibraryMetadata(
                size: String(format: "~%.1f MiB", Double(modelBytes + vocabularyBytes) / 1_048_576),
                processor: "Apple Silicon / Intel CPU",
                recommendedMemory: "4 GB+ RAM recommended",
                features: "Punctuation, capitalization and text normalization. Compact INT8 model.",
                performanceRatings: .init(speedRating: 4, accuracyRating: 4, speedPercent: 0.90, accuracyPercent: 0.90),
                performanceExplanation: "Relative library ratings for Russian: speed 90%, accuracy 90%. These are product scores, not measured transcription accuracy. This compact INT8 export has not been evaluated for WER or benchmarked for CPU speed."
            )
        }
        let formatted = self.vocabularyFile != nil
        return SpeechModelLibraryMetadata(
            size: formatted ? "~435.2 MiB" : "~428.8 MiB",
            processor: "Apple Silicon / Intel CPU",
            recommendedMemory: "4 GB+ RAM recommended",
            features: formatted
                ? "Punctuation, capitalization and text normalization. FP16 optimization and a trained end-of-utterance head."
                : "Russian recognition with FP16 optimization and a trained end-of-utterance head. This character export does not add punctuation or capitalization.",
            performanceRatings: .init(speedRating: 4, accuracyRating: 4, speedPercent: 0.90, accuracyPercent: 0.90),
            performanceExplanation: self.id == "gigaam-v3-e2e-eou-v5"
                ? "Relative library ratings for Russian: speed 90%, accuracy 90%. These are product scores, not measured transcription accuracy. Reference speed: 8.48 seconds of synthetic Russian speech processed in 0.97 seconds on an Apple M4 Max CPU, excluding model loading. The publisher reports average WER of 12.0% for the base GigaAM v3 E2E CTC across ten datasets. Lower WER is better. The optimized export has not been evaluated on those datasets."
                : "Relative library ratings for Russian: speed 90%, accuracy 90%. These are product scores, not measured transcription accuracy. CPU speed has not been benchmarked for this export. The publisher reports average WER of 9.1% for the base GigaAM v3 CTC across ten datasets. Lower WER is better. The optimized export has not been evaluated on those datasets."
        )
    }
}

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
    static var preferredLibraryMetadata: SpeechModelLibraryMetadata? { GigaAMModelCatalog.downloadableModel.libraryMetadata }
    private static let directoryPreferenceKey = "pichiGigaAMModelDirectory"
    private static let importedModelPreferenceKey = "pichiGigaAMImportedModelID"
    private let overriddenDirectory: URL?
    private let preferences: UserDefaults
    private let environment: [String: String]
    private let downloadDescriptor: GigaAMModelDescriptor
    private let importDescriptors: [GigaAMModelDescriptor]
    private let download: Download

    /// A cheap catalog scan cannot distinguish an old file from an explicitly selected import.
    /// Freeze the chosen descriptor, directory and write ownership before an async operation.
    private struct Selection: Sendable {
        let descriptor: GigaAMModelDescriptor
        let root: URL
        let allowsDownload: Bool
    }

    init(directory: URL? = nil, downloadDescriptor: GigaAMModelDescriptor = GigaAMModelCatalog.downloadableModel,
         importDescriptors: [GigaAMModelDescriptor] = GigaAMModelCatalog.models,
         preferences: UserDefaults = .standard,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         download: @escaping Download = { source, maximumBytes, progress in
             try await PichiGigaAMModelStore.downloadArtifact(source, maximumBytes: maximumBytes, progress: progress)
         }) {
        self.overriddenDirectory = directory
        self.preferences = preferences
        self.environment = environment
        self.downloadDescriptor = downloadDescriptor
        self.importDescriptors = importDescriptors
        self.download = download
    }

    static var defaultDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let namespace = Bundle.main.bundleIdentifier ?? "ai.pichi.voice"
        return support.appendingPathComponent(namespace, isDirectory: true)
            .appendingPathComponent("Models/GigaAM", isDirectory: true)
    }

    static var configuredModelDirectory: URL { self.shared.directory }

    /// Legacy directory preferences alone do not opt an existing installation into private weights.
    var directory: URL {
        if let overriddenDirectory { return overriddenDirectory }
        if let path = self.environment["PICHI_GIGAAM_MODEL_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return Self.defaultDirectory
    }

    var usesImportedModelSource: Bool {
        if self.preferences.string(forKey: Self.importedModelPreferenceKey) != nil { return true }
        guard let selection = try? self.selectedArtifact() else {
            return self.preferences.string(forKey: Self.importedModelPreferenceKey) != nil
        }
        return selection.descriptor.id != self.downloadDescriptor.id
    }

    private var registeredDescriptors: [GigaAMModelDescriptor] {
        [self.downloadDescriptor] + self.importDescriptors.filter { $0.id != self.downloadDescriptor.id }
    }

    private func selectedArtifact() throws -> Selection {
        let root = self.directory.standardizedFileURL
        // Saved meetings pass the exact installed artifact folder. This explicit reference is
        // independent of the user's current source preference and never starts a download.
        if self.overriddenDirectory != nil,
           let descriptor = self.registeredDescriptors.first(where: { $0.id == root.lastPathComponent }) {
            return Selection(descriptor: descriptor, root: root, allowsDownload: false)
        }
        // The developer environment override remains an explicit, read-only source.
        if self.overriddenDirectory == nil,
           let path = self.environment["PICHI_GIGAAM_MODEL_DIR"], !path.isEmpty {
            let descriptor = self.registeredDescriptors.first { Self.locate($0, in: root) != nil } ?? self.downloadDescriptor
            return Selection(descriptor: descriptor, root: root, allowsDownload: false)
        }
        if let importedID = self.preferences.string(forKey: Self.importedModelPreferenceKey) {
            guard let descriptor = self.registeredDescriptors.first(where: { $0.id == importedID }) else {
                throw GigaAMError.incompatibleModel
            }
            return Selection(descriptor: descriptor, root: root, allowsDownload: false)
        }
        return Selection(descriptor: self.downloadDescriptor, root: root, allowsDownload: true)
    }

    private static func locate(_ descriptor: GigaAMModelDescriptor, in root: URL) -> URL? {
        [root.appendingPathComponent(descriptor.id, isDirectory: true), root].first { descriptor.filesExist(in: $0) }
    }

    // Disk scans in the model picker remain cheap. Full digests are verified off the
    // main actor during import and preparation, never on a SwiftUI render.
    func modelsExistOnDisk() -> Bool { (try? self.installedModel()) != nil }

    func installedModel() throws -> (descriptor: GigaAMModelDescriptor, directory: URL) {
        let selection = try self.selectedArtifact()
        guard let directory = Self.locate(selection.descriptor, in: selection.root) else {
            throw GigaAMError.missingModels(selection.root)
        }
        return (selection.descriptor, directory)
    }

    /// A resumable meeting binds content identity and its saved directory, not mutable UI selection.
    func installedModel(matchingFingerprint fingerprint: String) throws -> (descriptor: GigaAMModelDescriptor, directory: URL) {
        let root = self.directory.standardizedFileURL
        guard let descriptor = self.registeredDescriptors.first(where: { $0.fingerprint == fingerprint }),
              let directory = Self.locate(descriptor, in: root) else {
            throw GigaAMError.missingModels(root)
        }
        return (descriptor, directory)
    }

    func installedModelFingerprint() throws -> String {
        try self.installedModel().descriptor.fingerprint
    }

    /// Preparation only downloads the pinned public source unless a verified import was
    /// explicitly selected. Existing private files are preserved, but do not select themselves.
    func ensureInstalled(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws -> (descriptor: GigaAMModelDescriptor, directory: URL) {
        try Task.checkCancellation()
        let selection = try self.selectedArtifact()
        let destinationRoot = selection.root
        let descriptor = selection.descriptor
        if let installed = Self.locate(descriptor, in: destinationRoot) { return (descriptor, installed) }
        guard selection.allowsDownload else { throw GigaAMError.missingModels(destinationRoot) }
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
        try Task.checkCancellation()
        let destinationRoot = (self.overriddenDirectory ?? Self.defaultDirectory).standardizedFileURL
        // Discovery and destination are captured once; preferences cannot change this attempt.
        guard let descriptor = self.importDescriptors.first(where: { Self.locate($0, in: sourceDirectory) != nil }),
              let source = Self.locate(descriptor, in: sourceDirectory) else {
            throw GigaAMError.missingModels(sourceDirectory)
        }
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try descriptor.verify(in: source)
            try Self.validateOwnedDirectory(destinationRoot)
            let manager = FileManager.default
            try manager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
            try Self.validateOwnedDirectory(destinationRoot)
            let target = destinationRoot.appendingPathComponent(descriptor.id, isDirectory: true)
            try Self.validateOwnedDirectory(target)
            if target.standardizedFileURL.path != source.standardizedFileURL.path {
                let stage = destinationRoot.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
                try manager.createDirectory(at: stage, withIntermediateDirectories: false)
                defer { try? manager.removeItem(at: stage) }
                for name in [descriptor.modelFile] + [descriptor.vocabularyFile].compactMap({ $0 }) {
                    try Task.checkCancellation()
                    try manager.copyItem(at: source.appendingPathComponent(name), to: stage.appendingPathComponent(name))
                }
                try descriptor.verify(in: stage)
                try Task.checkCancellation()
                _ = try Self.publish(stage, descriptor: descriptor, destinationRoot: destinationRoot)
            } else {
                try Task.checkCancellation()
            }
            // Publication is the commit point. Persist explicit selection with it, even if the
            // caller cancels while joining native cleanup immediately after successful return.
            self.preferences.set(destinationRoot.path, forKey: Self.directoryPreferenceKey)
            self.preferences.set(descriptor.id, forKey: Self.importedModelPreferenceKey)
        }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Return to the registered public source without deleting any imported artifacts.
    func restoreDefaultModelSource() async throws {
        try Task.checkCancellation()
        self.preferences.removeObject(forKey: Self.importedModelPreferenceKey)
        self.preferences.removeObject(forKey: Self.directoryPreferenceKey)
    }

    /// Remove only the selected owned artifact, retaining other downloaded/imported choices.
    /// Explicit external overrides are read-only even when they reference the owned path.
    func removeOwnedModels() throws {
        let selection = try self.selectedArtifact()
        let directory = selection.root.standardizedFileURL
        guard self.overriddenDirectory == nil,
              self.environment["PICHI_GIGAAM_MODEL_DIR"]?.isEmpty != false,
              directory.path == Self.defaultDirectory.standardizedFileURL.path else { return }
        try Self.validateOwnedDirectory(directory)
        guard let installed = Self.locate(selection.descriptor, in: directory) else { return }
        if installed.path != directory.path {
            try Self.validateOwnedDirectory(installed)
            try FileManager.default.removeItem(at: installed)
        } else {
            for name in [selection.descriptor.modelFile] + [selection.descriptor.vocabularyFile].compactMap({ $0 }) {
                let path = directory.appendingPathComponent(name)
                try Self.validateOwnedDirectory(path)
                try FileManager.default.removeItem(at: path)
            }
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
            let model = if let expected = self.expectedModelFingerprint {
                try self.modelStore.installedModel(matchingFingerprint: expected)
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

    func restoreDefaultModelSource() async throws {
        try await self.modelStore.restoreDefaultModelSource()
    }

    func clearCache() async throws {
        await self.unloadModel()
        try self.modelStore.removeOwnedModels()
    }
}
