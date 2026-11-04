import Foundation
import PichiGigaAM

extension GigaAMModelDescriptor {
    /// The E2E tokenizer identifies formatted exports; older character exports do not
    /// inherit their punctuation claims or the measured v5 CPU speed.
    nonisolated var libraryMetadata: SpeechModelLibraryMetadata {
        if case .gguf = self.format {
            return SpeechModelLibraryMetadata(
                size: String(format: "~%.1f MiB", Double(self.modelByteCount ?? 0) / 1_048_576),
                processor: "GPU preferred; CPU fallback",
                recommendedMemory: "4 GB+ RAM recommended",
                features: "Punctuation, capitalization and text normalization. Quantized Q8 model for GPU and CPU.",
                performanceRatings: .init(speedRating: 4, accuracyRating: 4, speedPercent: 0.90, accuracyPercent: 0.90),
                performanceExplanation: "The published quantized GigaAM model uses the same file on every device. GPU is preferred; CPU is used when GPU execution is unavailable, fails or cannot fit the available memory budget. Library percentages are relative product ratings, not measured accuracy.",
                cardDescription: "Compact Russian speech recognition with automatic punctuation and text normalization. Runs locally on Apple Silicon and Intel Macs.",
                hardwareLabel: "Apple Silicon"
            )
        }
        if case .coreML = self.format {
            return SpeechModelLibraryMetadata(
                size: String(format: "~%.1f MiB", Double(self.artifacts.compactMap(\.byteCount).reduce(0, +)) / 1_048_576),
                processor: "GPU preferred; CPU fallback",
                recommendedMemory: "8 GB+ RAM recommended",
                features: "Punctuation, capitalization and text normalization. Published Core ML model.",
                performanceRatings: .init(speedRating: 4, accuracyRating: 4, speedPercent: 0.90, accuracyPercent: 0.90),
                performanceExplanation: "The published GigaAM v3 Core ML export runs on GPU by default. CPU is used only if GPU execution is unavailable or fails. Library percentages are relative product ratings, not measured accuracy.",
                cardDescription: "Russian speech recognition with automatic punctuation and text normalization. Runs locally using Core ML.",
                hardwareLabel: "Apple Silicon"
            )
        }
        if let modelBytes = self.modelByteCount, let vocabularyBytes = self.vocabularyByteCount {
            return SpeechModelLibraryMetadata(
                size: String(format: "~%.1f MiB", Double(modelBytes + vocabularyBytes) / 1_048_576),
                processor: "Apple Silicon / Intel CPU",
                recommendedMemory: "4 GB+ RAM recommended",
                features: "Punctuation, capitalization and text normalization. Compact INT8 model.",
                performanceRatings: .init(speedRating: 4, accuracyRating: 4, speedPercent: 0.90, accuracyPercent: 0.90),
                performanceExplanation: "Relative library ratings for Russian: speed 90%, accuracy 90%. These are product scores, not measured transcription accuracy. This compact INT8 export has not been evaluated for WER or benchmarked for CPU speed.",
                cardDescription: "Compact Russian speech recognition with automatic punctuation and text normalization. Runs locally on Apple Silicon and Intel Macs.",
                hardwareLabel: "Apple Silicon / Intel CPU"
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
                : "Relative library ratings for Russian: speed 90%, accuracy 90%. These are product scores, not measured transcription accuracy. CPU speed has not been benchmarked for this export. The publisher reports average WER of 9.1% for the base GigaAM v3 CTC across ten datasets. Lower WER is better. The optimized export has not been evaluated on those datasets.",
            cardDescription: formatted
                ? "Compact Russian speech recognition with automatic punctuation and text normalization. Runs locally on Apple Silicon and Intel Macs."
                : "Local Russian speech recognition on Apple Silicon and Intel CPUs.",
            hardwareLabel: "Apple Silicon / Intel CPU"
        )
    }
}

/// Local, hash-verified optimized GigaAM exports. Import copies only model artifacts
/// into our storage; private recordings, dictionaries and training data stay outside it.
final nonisolated class PichiGigaAMModelStore: @unchecked Sendable {
    typealias Download = @Sendable (URL, Int64, @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse)
    static let shared = PichiGigaAMModelStore()
    static var defaultDownloadByteCount: Int64 {
        let descriptor = self.shared.downloadDescriptor
        return descriptor.artifacts.compactMap(\.byteCount).reduce(0, +)
    }
    static var supportsDefaultDownload: Bool { self.shared.downloadDescriptor.downloadBaseURL != nil }
    static var preferredLibraryMetadata: SpeechModelLibraryMetadata? { self.shared.downloadDescriptor.libraryMetadata }
    var defaultModelFingerprint: String { self.downloadDescriptor.fingerprint }
    private static let directoryPreferenceKey = "pichiGigaAMModelDirectory"
    private static let importedModelPreferenceKey = "pichiGigaAMImportedModelID"
    private let overriddenDirectory: URL?
    private let preferences: UserDefaults
    private let environment: [String: String]
    private let downloadDescriptor: GigaAMModelDescriptor
    private let defaultCPUReason: GigaAMExecutionStatus.FallbackReason?
    private let importDescriptors: [GigaAMModelDescriptor]
    private let download: Download

    /// A cheap catalog scan cannot distinguish an old file from an explicitly selected import.
    /// Freeze the chosen descriptor, directory and write ownership before an async operation.
    struct Selection: Sendable {
        let descriptor: GigaAMModelDescriptor
        let root: URL
        let allowsDownload: Bool
        let fallbackReason: GigaAMExecutionStatus.FallbackReason?
        init(descriptor: GigaAMModelDescriptor, root: URL, allowsDownload: Bool,
             fallbackReason: GigaAMExecutionStatus.FallbackReason? = nil) {
            self.descriptor = descriptor; self.root = root; self.allowsDownload = allowsDownload
            self.fallbackReason = fallbackReason
        }
    }

    init(directory: URL? = nil, downloadDescriptor: GigaAMModelDescriptor? = nil,
         importDescriptors: [GigaAMModelDescriptor] = GigaAMModelCatalog.models,
         preferences: UserDefaults = PrivateProfileDefaults.shared,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         resourcePolicy: GigaAMResourcePolicy = .current,
         download: @escaping Download = { source, maximumBytes, progress in
             try await PichiGigaAMModelStore.downloadArtifact(source, maximumBytes: maximumBytes, progress: progress)
         }) {
        self.overriddenDirectory = directory
        self.preferences = preferences
        self.environment = environment
        self.downloadDescriptor = downloadDescriptor ?? resourcePolicy.preferredDownload
        self.defaultCPUReason = downloadDescriptor == nil ? resourcePolicy.defaultCPUReason : nil
        self.importDescriptors = importDescriptors
        self.download = download
    }

    // The installation's storage namespace, shared with every other model directory.
    static var defaultDirectory: URL { AppBrand.modelsDirectory.appendingPathComponent("GigaAM", isDirectory: true) }

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

    /// Metadata-only capability used while freezing admission, before model load.
    func encoderDictionarySupported(fingerprint: String) -> Bool {
        GigaAMRuntime.encoderFeatureAPIAvailable &&
            self.registeredDescriptors.first(where: { $0.fingerprint == fingerprint })?.format == .gguf
    }

    func selectedArtifact() throws -> Selection {
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
        return Selection(descriptor: self.downloadDescriptor, root: root, allowsDownload: true,
                         fallbackReason: self.defaultCPUReason)
    }

    private static func locate(_ descriptor: GigaAMModelDescriptor, in root: URL) -> URL? {
        [root.appendingPathComponent(descriptor.id, isDirectory: true), root].first { descriptor.filesExist(in: $0) }
    }

    // Disk scans in the model picker remain cheap. Full digests are verified off the
    // main actor during import and preparation, never on a SwiftUI render.
    func modelsExistOnDisk(selection admittedSelection: Selection? = nil) -> Bool {
        (try? self.installedModel(selection: admittedSelection)) != nil
    }

    func installedModel(selection admittedSelection: Selection? = nil) throws -> (descriptor: GigaAMModelDescriptor, directory: URL) {
        let selection = try admittedSelection ?? self.selectedArtifact()
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

    /// Queued meetings retain a fingerprint and owned directory rather than a
    /// live source preference. Recover only the matching automatic policy reason.
    func automaticCPUReason(forFingerprint fingerprint: String, directory: URL) -> GigaAMExecutionStatus.FallbackReason? {
        let owned = Self.defaultDirectory.appendingPathComponent(self.downloadDescriptor.id, isDirectory: true)
        guard fingerprint == self.downloadDescriptor.fingerprint,
              directory.standardizedFileURL.path == owned.standardizedFileURL.path,
              self.preferences.string(forKey: Self.importedModelPreferenceKey) == nil,
              self.environment["PICHI_GIGAAM_MODEL_DIR"]?.isEmpty ?? true else { return nil }
        return self.defaultCPUReason
    }

    /// Preparation only downloads the pinned public source unless a verified import was
    /// explicitly selected. Existing private files are preserved, but do not select themselves.
    func ensureInstalled(selection admittedSelection: Selection? = nil, progressHandler: ((ModelPreparationProgress) -> Void)? = nil) async throws -> (descriptor: GigaAMModelDescriptor, directory: URL) {
        try Task.checkCancellation()
        let selection = try admittedSelection ?? self.selectedArtifact()
        let destinationRoot = selection.root
        let descriptor = selection.descriptor
        if let installed = Self.locate(descriptor, in: destinationRoot) { return (descriptor, installed) }
        guard selection.allowsDownload else { throw GigaAMError.missingModels(destinationRoot) }
        let relay = ModelPreparationProgressRelay(progressHandler)
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = descriptor.downloadBaseURL, source.scheme == "https",
                  !descriptor.artifacts.isEmpty,
                  descriptor.artifacts.allSatisfy({ ($0.byteCount ?? 0) > 0 }) else {
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
            let totalBytes = descriptor.artifacts.compactMap(\.byteCount).reduce(0, +)
            var completedBytes: Int64 = 0
            for artifact in descriptor.artifacts {
                let filename = artifact.path
                let byteCount = artifact.byteCount!
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
                let targetFile = stage.appendingPathComponent(filename)
                try manager.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.moveItem(at: temporaryURL, to: targetFile)
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
                for name in descriptor.artifacts.map(\.path) {
                    try Task.checkCancellation()
                    let targetFile = stage.appendingPathComponent(name)
                    try manager.createDirectory(at: targetFile.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.copyItem(at: source.appendingPathComponent(name), to: targetFile)
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
    func removeOwnedModels(selection admittedSelection: Selection? = nil) throws {
        let selection = try admittedSelection ?? self.selectedArtifact()
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
            for name in selection.descriptor.artifacts.map(\.path) {
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
    let name = "GigaAM v3"
    let isAvailable = true
    let supportsWordTimings = true
    let shouldClearCacheAfterCancellation = false
    private(set) var isReady = false

    private let modelStore: PichiGigaAMModelStore
    private let expectedModelFingerprint: String?
    private(set) var loadedModelFingerprint: String?
    private(set) var executionStatus: TranscriptionExecutionStatus?
    private var runtime: GigaAMRuntime?
    private var preparationTask: Task<Void, Error>?
    private var lifecycleGeneration = 0
    private var executionAttemptPending = false
    private var preparedDefaultCPUReason: GigaAMExecutionStatus.FallbackReason?
    private let pronunciationStore: PronunciationDictionaryStore
    private var dictionarySnapshot: GigaAMDictionaryAcoustics.Snapshot?
    private var dictionaryReferenceCache: (key: String, words: [GigaAMDictionaryAcoustics.Word])?
    private var encoderReferenceCache: (key: String, preparation: GigaAMEncoderDictionary.Preparation)?
    private var dictionaryUsesEncoderFeatures = false

    var pronunciationProfileModelKey: String? {
        guard self.isReady, let fingerprint = self.loadedModelFingerprint else { return nil }
        return self.dictionaryUsesEncoderFeatures
            ? GigaAMEncoderDictionaryStorage.modelKey(fingerprint: fingerprint)
            : GigaAMDictionaryAcoustics.modelKey(fingerprint: fingerprint)
    }

    // MARK: - Admitted transcription configuration

    private var admittedSource: (leaseID: UUID, selection: PichiGigaAMModelStore.Selection?)?

    func beginAdmittedTranscription(leaseID: UUID) throws {
        if let admitted = self.admittedSource {
            guard admitted.leaseID == leaseID else { throw CancellationError() }
            return
        }
        let selection = self.expectedModelFingerprint == nil ? try self.modelStore.selectedArtifact() : nil
        let fingerprint = self.expectedModelFingerprint ?? selection?.descriptor.fingerprint ?? self.loadedModelFingerprint
        #if os(macOS)
        let dictionaryEnabled = DictionaryMatcherExperiment.sharedFeaturesEnabled
        #else
        let dictionaryEnabled = false
        #endif
        let entries = dictionaryEnabled ? SettingsStore.shared.customDictionaryEntries : []
        self.dictionaryUsesEncoderFeatures = fingerprint.map { self.modelStore.encoderDictionarySupported(fingerprint: $0) } ?? false
        let modelKey = fingerprint.map {
            self.dictionaryUsesEncoderFeatures ? GigaAMEncoderDictionaryStorage.modelKey(fingerprint: $0)
                : GigaAMDictionaryAcoustics.modelKey(fingerprint: $0)
        } ?? ""
        let entryIDs = Set(entries.map(\.id))
        let useEncoderReferences = self.dictionaryUsesEncoderFeatures
        let pronunciation = dictionaryEnabled && !entryIDs.isEmpty
            ? try self.pronunciationStore.admitCaptureRead(leaseID: leaseID, modelKey: modelKey, entryIDs: entryIDs,
                referenceSelection: { profile in
                    useEncoderReferences ? GigaAMEncoderDictionaryStorage.retainedCaptures(profile.enrollments)
                        : GigaAMDictionaryAcoustics.activeCaptures(profile.enrollments) }) : nil
        let negatives: DictionaryNegativeExampleStore.CaptureRead?
        do {
            negatives = dictionaryEnabled && DictionaryMatcherExperiment.compareNegatives && !entryIDs.isEmpty
                ? try DictionaryNegativeExampleStore.shared.admitCaptureRead(leaseID: leaseID, modelKey: modelKey, entryIDs: entryIDs) : nil
        } catch {
            pronunciation?.close(leaseID: leaseID)
            throw error
        }
        self.dictionarySnapshot = .init(modelKey: modelKey, generation: DictionaryMatcherExperiment.generation,
            enabled: dictionaryEnabled, entries: entries, pronunciation: pronunciation, negatives: negatives)
        self.admittedSource = (leaseID, selection)
        self.executionAttemptPending = true
    }

    func endAdmittedTranscription(leaseID: UUID) {
        guard self.admittedSource?.leaseID == leaseID else { return }
        self.dictionarySnapshot?.pronunciation?.close(leaseID: leaseID)
        self.dictionarySnapshot?.negatives?.close(leaseID: leaseID)
        self.dictionarySnapshot = nil
        self.dictionaryUsesEncoderFeatures = false
        self.admittedSource = nil
        self.executionAttemptPending = false
    }

    // MARK: - Provider lifecycle

    init(modelStore: PichiGigaAMModelStore = .shared, expectedModelFingerprint: String? = nil,
         pronunciationStore: PronunciationDictionaryStore = .shared) {
        self.modelStore = modelStore
        self.expectedModelFingerprint = expectedModelFingerprint
        self.pronunciationStore = pronunciationStore
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
        let admittedSelection = try self.admittedSource?.selection
            ?? (self.expectedModelFingerprint == nil ? self.modelStore.selectedArtifact() : nil)
        self.preparedDefaultCPUReason = admittedSelection?.fallbackReason
        let runtime = try GigaAMRuntime()
        self.lifecycleGeneration += 1
        let generation = self.lifecycleGeneration
        self.runtime = runtime
        let task = Task {
            let model = if let expected = self.expectedModelFingerprint {
                try self.modelStore.installedModel(matchingFingerprint: expected)
            } else {
                try await self.modelStore.ensureInstalled(selection: admittedSelection, progressHandler: progressHandler)
            }
            let fingerprint = model.descriptor.fingerprint
            if self.expectedModelFingerprint != nil, self.preparedDefaultCPUReason == nil {
                self.preparedDefaultCPUReason = self.modelStore.automaticCPUReason(forFingerprint: fingerprint, directory: model.directory)
            }
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
            await self.refreshExecutionStatus(from: runtime)
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
                self.executionStatus = nil
            }
            throw error
        }
    }

    func transcribeDetailed(_ samples: [Float], captureEncoderFeatures: Bool = false) async throws -> GigaAMTranscript {
        try Task.checkCancellation()
        guard self.isReady, let runtime = self.runtime else { throw GigaAMError.notPrepared }
        let generation = self.lifecycleGeneration
        let fingerprint = self.loadedModelFingerprint
        do {
            if self.executionAttemptPending || self.admittedSource == nil {
                self.executionAttemptPending = false
                try await runtime.beginAttempt()
                try Task.checkCancellation()
                guard self.runtime === runtime, self.isReady else { throw CancellationError() }
            }
            let result = try await runtime.transcribe(samples, captureEncoderFeatures: captureEncoderFeatures)
            try Task.checkCancellation()
            guard self.lifecycleGeneration == generation, self.runtime === runtime,
                  self.loadedModelFingerprint == fingerprint, self.isReady else { throw CancellationError() }
            await self.refreshExecutionStatus(from: runtime)
            guard self.lifecycleGeneration == generation, self.runtime === runtime,
                  self.loadedModelFingerprint == fingerprint, self.isReady else { throw CancellationError() }
            return result
        } catch {
            await self.refreshExecutionStatus(from: runtime)
            throw error
        }
    }

    private func refreshExecutionStatus(from runtime: GigaAMRuntime) async {
        let value = await runtime.executionStatus
        let ready = await runtime.isReady
        guard self.runtime === runtime else { return }
        guard ready, let value else {
            self.isReady = false
            self.loadedModelFingerprint = nil
            self.executionStatus = nil
            return
        }
        let backend: TranscriptionExecutionStatus.Backend
        switch value.backend {
        case .cpu: backend = .cpu
        case .gpu: backend = .gpu
        case .neuralEngine: backend = .neuralEngine
        }
        let reason: String?
        let reportedReason = backend == .cpu ? (self.preparedDefaultCPUReason ?? value.fallbackReason) : value.fallbackReason
        switch reportedReason {
        case .compatibleExportMissing: reason = "CPU fallback: a compatible GPU export is not installed."
        case .invalidExport: reason = "CPU fallback: the GPU export failed validation."
        case .gpuUnavailable: reason = "CPU fallback: GPU execution is unavailable on this device."
        case .acceleratorLoadFailed: reason = "CPU fallback: the GPU model could not be loaded."
        case .acceleratorInferenceFailed: reason = "CPU fallback: GPU execution failed."
        case .explicitCPU: reason = "CPU was explicitly selected for diagnostics."
        case .unsupportedInputShape: reason = "CPU fallback: the GPU export does not support this input shape."
        case .incompatibleExport: reason = "CPU fallback: this imported export does not support GPU execution."
        case .memoryBudget: reason = "CPU fallback: Not enough available memory to prepare GPU execution."
        case nil: reason = nil
        }
        let next = TranscriptionExecutionStatus(backend: backend, fallbackReason: reason)
        if self.executionStatus != next {
            DebugLogger.shared.log("GigaAM execution backend=\(value.backend.rawValue) fallback=\(value.fallbackReason?.rawValue ?? "none")", source: "GigaAM")
        }
        self.executionStatus = next
    }

    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        let result = try await self.transcribeDetailed(samples)
        return ASRTranscriptionResult(text: result.text, confidence: result.confidence, endOfUtteranceProbability: result.endOfUtteranceProbability)
    }

    func transcribeStreaming(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribe(samples)
    }

    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        guard self.isReady else { throw GigaAMError.notPrepared }
        // Direct callers get the same frozen read scope as executor-admitted dictation.
        let ownedLease = self.admittedSource == nil ? UUID() : nil
        if let ownedLease { try self.beginAdmittedTranscription(leaseID: ownedLease) }
        defer { if let ownedLease { self.endAdmittedTranscription(leaseID: ownedLease) } }
        let generation = self.lifecycleGeneration
        guard let fingerprint = self.loadedModelFingerprint else { throw CancellationError() }
        let usesEncoder = self.dictionaryUsesEncoderFeatures
        let result = try await self.transcribeDetailed(samples,
            captureEncoderFeatures: usesEncoder && DictionaryMatcherExperiment.sharedFeaturesEnabled)
        guard self.lifecycleGeneration == generation, self.loadedModelFingerprint == fingerprint, self.isReady else { throw CancellationError() }
        let key = usesEncoder ? GigaAMEncoderDictionaryStorage.modelKey(fingerprint: fingerprint)
            : GigaAMDictionaryAcoustics.modelKey(fingerprint: fingerprint)
        var alignment = DictionaryLearningAlignment(modelKey: key,
            words: result.words.map { ASRWordTiming(text: $0.text, start: $0.start, end: $0.end) })
        if usesEncoder { alignment.featureFrames = Self.learningFrames(result.encoderWindows) }
        var text = result.text
        if usesEncoder, let snapshot = self.dictionarySnapshot, snapshot.enabled, snapshot.modelKey == key {
            let cacheKey = GigaAMDictionaryAcoustics.referenceCacheKey(snapshot)
            let preparation: GigaAMEncoderDictionary.Preparation
            if let cached = self.encoderReferenceCache, cached.key == cacheKey { preparation = cached.preparation }
            else {
                preparation = try await GigaAMEncoderDictionaryStorage.preparedWords(snapshot)
                try Task.checkCancellation()
                guard self.lifecycleGeneration == generation, self.loadedModelFingerprint == fingerprint else { throw CancellationError() }
                self.encoderReferenceCache = (cacheKey, preparation)
            }
            let corrected = try await GigaAMEncoderDictionary.correct(transcript: result,
                windows: result.encoderWindows, modelKey: key, words: preparation.words, entries: snapshot.entries)
            try Task.checkCancellation()
            guard self.lifecycleGeneration == generation, self.loadedModelFingerprint == fingerprint, self.isReady else { throw CancellationError() }
            if DictionaryMatcherExperiment.sharedFeaturesEnabled, DictionaryMatcherExperiment.generation == snapshot.generation {
                text = corrected.text
                alignment.acousticOutput = text
                alignment.acousticEvidence = Self.encoderEvidence(corrected.accepted, windows: result.encoderWindows, snapshot: snapshot)
            }
        } else if let snapshot = self.dictionarySnapshot, snapshot.enabled, snapshot.modelKey == key {
            let cacheKey = GigaAMDictionaryAcoustics.referenceCacheKey(snapshot)
            let references: [GigaAMDictionaryAcoustics.Word]
            if let cached = self.dictionaryReferenceCache, cached.key == cacheKey {
                references = cached.words
            } else {
                references = try await GigaAMDictionaryAcoustics.preparedWords(snapshot)
                try Task.checkCancellation()
                guard self.lifecycleGeneration == generation, self.loadedModelFingerprint == fingerprint else { throw CancellationError() }
                self.dictionaryReferenceCache = (cacheKey, references)
            }
            let corrected = try await GigaAMDictionaryAcoustics.correct(transcript: result, samples: samples,
                snapshot: snapshot, words: references)
            try Task.checkCancellation()
            guard self.lifecycleGeneration == generation, self.isReady else { throw CancellationError() }
            if DictionaryMatcherExperiment.sharedFeaturesEnabled,
               DictionaryMatcherExperiment.generation == snapshot.generation {
                text = corrected.text
                alignment.acousticOutput = text
                alignment.acousticEvidence = corrected.evidence
            }
        }
        return ASRTranscriptionResult(text: text, confidence: result.confidence,
            endOfUtteranceProbability: result.endOfUtteranceProbability, dictionaryLearningAlignment: alignment)
    }

    nonisolated private static func learningFrames(_ windows: [GigaAMEncoderWindow]) -> [DictionaryLearningFeatureFrames] {
        windows.map { window in
            DictionaryLearningFeatureFrames(extractorVersion: GigaAMEncoderFeatures.extractorVersion,
                frames: .init(offset: window.offset, frameDuration: GigaAMEncoderFeatures.frameDuration,
                              hiddenSize: GigaAMEncoderFeatures.dimension, values: window.features.values))
        }
    }

    nonisolated private static func encoderEvidence(_ accepted: [GigaAMEncoderDictionary.AcceptedSpan],
        windows: [GigaAMEncoderWindow], snapshot: GigaAMDictionaryAcoustics.Snapshot) -> [DictionaryAcousticEvidence] {
        accepted.compactMap { span in
            guard let window = windows.first(where: { Int(($0.offset / 0.04).rounded()) == span.frameOffset }),
                  let profile = snapshot.pronunciation?.profiles.first(where: {
                      $0.dictionaryEntryID == span.entryID && $0.modelKey == snapshot.modelKey
                  }), span.frameRange.lowerBound >= 0, span.frameRange.upperBound <= window.features.frameCount else { return nil }
            let lower = span.frameRange.lowerBound * 768, upper = span.frameRange.upperBound * 768
            let frames = DictionaryMatchFrames(hiddenSize: 768, values: Array(window.features.values[lower..<upper]))
            guard frames.isValid else { return nil }
            return DictionaryAcousticEvidence(id: UUID(), entryID: span.entryID, label: span.label,
                profileKey: DictionaryNegativeEvidenceResolver.profileKey(profile) + ":shared-features-v1",
                modelKey: snapshot.modelKey, sourceWordRange: span.wordRange.lowerBound..<(span.wordRange.upperBound + 1),
                frames: frames, matchFrameRange: span.absoluteFrameRange)
        }
    }

    func transcribeDictionaryTraining(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        try await self.transcribeDictionaryTraining(samples, capturePronunciation: true)
    }

    func transcribeDictionaryTraining(_ samples: [Float], capturePronunciation: Bool) async throws -> ASRTranscriptionResult {
        let generation = self.lifecycleGeneration
        let fingerprint = self.loadedModelFingerprint
        let usesEncoder = fingerprint.map { self.modelStore.encoderDictionarySupported(fingerprint: $0) } ?? false
        let result = try await self.transcribeDetailed(samples,
            captureEncoderFeatures: capturePronunciation && usesEncoder && DictionaryMatcherExperiment.sharedFeaturesEnabled)
        guard self.lifecycleGeneration == generation, self.loadedModelFingerprint == fingerprint, self.isReady else { throw CancellationError() }
        let words = result.words.map { ASRWordTiming(text: $0.text, start: $0.start, end: $0.end) }
        var capture: PronunciationEnrollmentCapture?
        if capturePronunciation, DictionaryMatcherExperiment.sharedFeaturesEnabled,
           let fingerprint = self.loadedModelFingerprint {
            if usesEncoder {
                capture = try await GigaAMEncoderDictionaryStorage.enrollment(samples: samples,
                    modelKey: GigaAMEncoderDictionaryStorage.modelKey(fingerprint: fingerprint),
                    featureFrames: Self.learningFrames(result.encoderWindows), words: words)
            } else {
                capture = try await GigaAMDictionaryAcoustics.enrollment(samples: samples,
                    modelKey: GigaAMDictionaryAcoustics.modelKey(fingerprint: fingerprint), words: words)
            }
            capture?.observedText = result.text
        }
        DebugLogger.shared.info(
            "GigaAM voice enrollment requested=\(capturePronunciation) encoder=\(usesEncoder) " +
                "windows=\(result.encoderWindows.count) samples=\(samples.count) captured=\(capture != nil)",
            source: "PronunciationMatching"
        )
        try Task.checkCancellation()
        guard self.lifecycleGeneration == generation, self.isReady else { throw CancellationError() }
        return ASRTranscriptionResult(text: result.text, confidence: result.confidence,
            endOfUtteranceProbability: result.endOfUtteranceProbability, pronunciationEnrollment: capture)
    }

    func originalAudioEnrollment(_ evidence: DictionaryLearningAudioEvidence) async throws -> PronunciationEnrollmentCapture? {
        // This representation needs no model load. Still bind it to the exact artifact
        // that supplied the original word spans, never a later settings selection.
        let fingerprint = self.loadedModelFingerprint ?? self.expectedModelFingerprint
            ?? (try? self.modelStore.selectedArtifact().descriptor.fingerprint)
        guard let fingerprint else { return nil }
        let generation = self.lifecycleGeneration
        var capture: PronunciationEnrollmentCapture?
        if evidence.modelKey == GigaAMEncoderDictionaryStorage.modelKey(fingerprint: fingerprint) {
            capture = try await GigaAMEncoderDictionaryStorage.enrollment(samples: evidence.samples,
                modelKey: evidence.modelKey, featureFrames: evidence.featureFrames, words: [], focalRange: evidence.focalSampleRange)
            guard capture != nil else { throw PronunciationDictionaryStoreError.inconsistentEnrollment }
        } else if evidence.modelKey == GigaAMDictionaryAcoustics.modelKey(fingerprint: fingerprint) {
            capture = try await GigaAMDictionaryAcoustics.enrollment(samples: evidence.samples,
                modelKey: evidence.modelKey, words: [], focalRange: evidence.focalSampleRange)
        } else { return nil }
        try Task.checkCancellation()
        guard self.lifecycleGeneration == generation else { throw CancellationError() }
        capture?.observedText = evidence.observedText
        capture?.sourceRecordingID = evidence.recordingID
        capture?.sourceFocalRange = (evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.lowerBound)..<(evidence.sourceSampleRange.lowerBound + evidence.focalSampleRange.upperBound)
        return capture
    }

    func validateDictionaryPronunciations(_ captures: [PronunciationEnrollmentCapture]) async throws -> Bool {
        let generation = self.lifecycleGeneration
        let fingerprint = self.loadedModelFingerprint ?? self.expectedModelFingerprint
            ?? (try? self.modelStore.selectedArtifact().descriptor.fingerprint)
        guard let fingerprint, captures.count >= 3 else { return false }
        if self.modelStore.encoderDictionarySupported(fingerprint: fingerprint) {
            let valid = try await GigaAMEncoderDictionaryStorage.validate(captures: captures,
                modelKey: GigaAMEncoderDictionaryStorage.modelKey(fingerprint: fingerprint), store: self.pronunciationStore)
            try Task.checkCancellation()
            guard self.lifecycleGeneration == generation else { throw CancellationError() }
            return valid
        }
        let key = GigaAMDictionaryAcoustics.modelKey(fingerprint: fingerprint)
        var references: [GigaAMAcousticFeatures] = []
        for capture in GigaAMDictionaryAcoustics.activeCaptures(captures) {
            try Task.checkCancellation()
            guard capture.modelKey == key, capture.extractorVersion == GigaAMAcousticFeatures.extractorVersion else { return false }
            let inspection: DictionaryAudioInspection
            if let pending = capture.pendingInspection { inspection = pending }
            else if let id = capture.inspectionID { inspection = try await self.pronunciationStore.inspection(for: id) }
            else { return false }
            guard inspection.isValid, inspection.frames.count == 1,
                  let frames = inspection.frames.first,
                  frames.frameDuration == GigaAMAcousticFeatures.frameDuration,
                  frames.hiddenSize == GigaAMAcousticFeatures.dimension else { return false }
            do { references.append(try GigaAMAcousticFeatures(values: frames.values)) }
            catch { return false }
        }
        let valid = try await Self.calibratesDictionaryReferences(references)
        try Task.checkCancellation()
        guard self.lifecycleGeneration == generation else { throw CancellationError() }
        return valid
    }

    @concurrent private static func calibratesDictionaryReferences(_ references: [GigaAMAcousticFeatures]) async throws -> Bool {
        try GigaAMAcousticMatcher.calibrate(references: references) != nil
    }

    func transcribeWithWordTimings(_ samples: [Float]) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        let result = try await self.transcribeDetailed(samples)
        return (
            ASRTranscriptionResult(text: result.text, confidence: result.confidence, endOfUtteranceProbability: result.endOfUtteranceProbability),
            result.words.map { ASRWordTiming(text: $0.text, start: $0.start, end: $0.end) }
        )
    }

    func modelsExistOnDisk() -> Bool {
        self.modelStore.modelsExistOnDisk(selection: self.admittedSource?.selection)
    }

    func unloadModel() async {
        // Invalidate ownership before suspending. An old prepare completion cannot
        // publish readiness or clear a newer session after this point.
        self.lifecycleGeneration += 1
        self.executionStatus = nil
        self.dictionaryReferenceCache = nil
        self.encoderReferenceCache = nil
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
        // Recovery belongs to the admitted artifact even if preparation or unload
        // suspends while the source profile is concealed or its lease is released.
        let admittedSelection = self.admittedSource?.selection
        await self.unloadModel()
        try self.modelStore.removeOwnedModels(selection: admittedSelection)
    }
}
