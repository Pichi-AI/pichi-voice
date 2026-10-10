import Foundation
import PichiGigaAM

/// Local, hash-verified optimized GigaAM exports. Import copies only model artifacts
/// into our storage; private recordings, dictionaries and training data stay outside it.
final nonisolated class PichiGigaAMModelStore: @unchecked Sendable {
    static let shared = PichiGigaAMModelStore()
    private static let directoryPreferenceKey = "pichiGigaAMModelDirectory"
    private let overriddenDirectory: URL?

    init(directory: URL? = nil) { self.overriddenDirectory = directory }

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
        Self.fingerprint(for: try self.installedModel().descriptor)
    }

    private static func fingerprint(for descriptor: GigaAMModelDescriptor) -> String {
        "gigaam-native-v1/\(descriptor.id)/\(descriptor.modelSHA256)/\(descriptor.vocabularySHA256 ?? "russian-characters-v1")"
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
            let backup = destinationRoot.appendingPathComponent(".backup-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: stage) }
            for name in [source.descriptor.modelFile] + [source.descriptor.vocabularyFile].compactMap({ $0 }) {
                try Task.checkCancellation()
                try manager.copyItem(at: source.directory.appendingPathComponent(name), to: stage.appendingPathComponent(name))
            }
            try source.descriptor.verify(in: stage)
            try Task.checkCancellation()
            let replacing = manager.fileExists(atPath: target.path)
            if replacing { try manager.moveItem(at: target, to: backup) }
            do {
                try manager.moveItem(at: stage, to: target)
            } catch {
                if replacing { try? manager.moveItem(at: backup, to: target) }
                throw error
            }
            if replacing { try? manager.removeItem(at: backup) }
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
        guard self.overriddenDirectory == nil,
              self.directory.standardizedFileURL == Self.defaultDirectory.standardizedFileURL else { return }
        for descriptor in GigaAMModelCatalog.models {
            let path = self.directory.appendingPathComponent(descriptor.id, isDirectory: true)
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

    init(modelStore: PichiGigaAMModelStore = .shared, expectedModelFingerprint: String? = nil) {
        self.modelStore = modelStore
        self.expectedModelFingerprint = expectedModelFingerprint
    }

    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws {
        try Task.checkCancellation()
        if self.isReady { return }
        if let task = self.preparationTask {
            try await task.value
            try Task.checkCancellation()
            return
        }
        let model = try self.modelStore.installedModel()
        let fingerprint = try self.modelStore.installedModelFingerprint()
        if let expected = self.expectedModelFingerprint, expected != fingerprint {
            throw NSError(domain: "PichiGigaAMProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "The installed GigaAM export has changed since this meeting was scheduled. Restore that export or start a new processing run."])
        }
        let runtime = try GigaAMRuntime()
        self.runtime = runtime
        progressHandler?(.loading)
        let task = Task {
            try await runtime.load(descriptor: model.descriptor, directory: model.directory)
            try Task.checkCancellation()
            self.loadedModelFingerprint = fingerprint
            self.isReady = true
        }
        self.preparationTask = task
        defer { self.preparationTask = nil }
        do {
            try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            try Task.checkCancellation()
            self.loadedModelFingerprint = fingerprint
            self.isReady = true
        } catch {
            await runtime.unload()
            self.runtime = nil
            self.loadedModelFingerprint = nil
            self.isReady = false
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
        return ASRTranscriptionResult(text: result.text, confidence: result.confidence)
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
            ASRTranscriptionResult(text: result.text, confidence: result.confidence),
            result.words.map { ASRWordTiming(text: $0.text, start: $0.start, end: $0.end) }
        )
    }

    func modelsExistOnDisk() -> Bool { self.modelStore.modelsExistOnDisk() }

    func unloadModel() async {
        self.preparationTask?.cancel()
        if let task = self.preparationTask { _ = try? await task.value }
        self.preparationTask = nil
        self.isReady = false
        self.loadedModelFingerprint = nil
        await self.runtime?.unload()
        self.runtime = nil
    }

    func clearCache() async throws {
        await self.unloadModel()
        try self.modelStore.removeOwnedModels()
    }
}
