import Foundation
import PichiGigaAM

// Application neighbors are inert; the whole actual provider and model store,
// catalog descriptor/filesExist and progress relay compile without projection.
nonisolated enum AppBrand {
    static let storageNamespace = "synthetic.gigaam-artifact-ownership"
    static let keychainService = "synthetic.gigaam-artifact-ownership"
    static var applicationSupportDirectory: URL { modelsDirectory.appendingPathComponent("SyntheticProfile") }
    static var modelsDirectory: URL { URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true) }
}
nonisolated enum PrivateProfileDefaults {
    static var shared: UserDefaults { preconditionFailure("Tests must use explicit in-memory preferences") }
}
final nonisolated class ConcealablePreferences: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var isReadable = true
    private var selectedImport: String?
    override func string(forKey key: String) -> String? {
        self.lock.withLock { self.isReadable && key == "pichiGigaAMImportedModelID" ? self.selectedImport : nil }
    }
    func select(_ id: String?) { self.lock.withLock { self.isReadable = true; self.selectedImport = id } }
    func conceal() { self.lock.withLock { self.isReadable = false } }
}
nonisolated struct SpeechModelPerformanceRatings { let speedRating: Int; let accuracyRating: Int; let speedPercent: Double; let accuracyPercent: Double }
nonisolated struct SpeechModelLibraryMetadata { let size: String; let processor: String; let recommendedMemory: String; let features: String; let performanceRatings: SpeechModelPerformanceRatings; let performanceExplanation: String; let cardDescription: String?; let hardwareLabel: String? }
@MainActor protocol TranscriptionProvider {}
nonisolated final class DebugLogger {
    static let shared = DebugLogger()
    func log(_ message: String, source: String) {}
    func info(_ message: String, source: String) {}
}
nonisolated enum ProgressiveFileDownloader {
    static func download(from: URL, configuration: URLSessionConfiguration, maximumBytes: Int64,
                         onProgress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> (URL, URLResponse) {
        preconditionFailure("Artifact ownership tests must never download")
    }
}

@main struct GigaAMArtifactOwnershipTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: Bool, _ message: String) {
        guard value else {
            print("FAIL: \(message)")
            exit(1)
        }
        self.checks += 1
    }
    @MainActor static func snapshot(_ provider: PichiGigaAMProvider) -> GigaAMDictionaryAcoustics.Snapshot? {
        guard let optional = Mirror(reflecting: provider).children.first(where: { $0.label == "dictionarySnapshot" })?.value
        else { return nil }
        return Mirror(reflecting: optional).children.first?.value as? GigaAMDictionaryAcoustics.Snapshot
    }
    @MainActor static func usesEncoder(_ provider: PichiGigaAMProvider) -> Bool {
        Mirror(reflecting: provider).children.first(where: { $0.label == "dictionaryUsesEncoderFeatures" })?.value as? Bool ?? false
    }
    @MainActor static func main() async throws {
        let root = PichiGigaAMModelStore.defaultDirectory
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root.deletingLastPathComponent()) }
        let publicDescriptor = GigaAMModelCatalog.downloadableModel
        self.expect(publicDescriptor.libraryMetadata.hardwareLabel == "Apple Silicon", "The public model advertises Apple Silicon without changing its Intel compatibility")
        self.expect(publicDescriptor.libraryMetadata.cardDescription?.contains("punctuation") == true, "The public formatted export describes punctuation")
        self.expect(publicDescriptor.libraryMetadata.cardDescription?.contains("Intel") == true, "The summary makes CPU compatibility explicit")
        for descriptor in GigaAMModelCatalog.models where descriptor.format == .onnx && descriptor.vocabularyFile == nil {
            self.expect(descriptor.libraryMetadata.cardDescription?.contains("punctuation") == false, "Character exports do not inherit formatting claims")
        }
        let importedDescriptor = GigaAMModelCatalog.models.first { $0.id != publicDescriptor.id }!
        let publicRoot = root.appendingPathComponent(publicDescriptor.id, isDirectory: true)
        let importedRoot = root.appendingPathComponent(importedDescriptor.id, isDirectory: true)
        let marker = root.appendingPathComponent("unrelated-user-file.txt")
        let markerBytes = Data("preserve unrelated artifact fixture".utf8)
        try markerBytes.write(to: marker)
        func write(_ descriptor: GigaAMModelDescriptor, _ directory: URL) throws {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in descriptor.artifacts.map(\.path) {
                let file = directory.appendingPathComponent(name)
                try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("synthetic artifact: \(descriptor.id)/\(name)".utf8).write(to: file)
            }
        }
        try write(publicDescriptor, publicRoot)
        try write(importedDescriptor, importedRoot)
        let publicArtifactPath = publicDescriptor.artifacts[0].path
        let publicBytes = try Data(contentsOf: publicRoot.appendingPathComponent(publicArtifactPath))
        let preferences = ConcealablePreferences()
        preferences.select(importedDescriptor.id)
        let store = PichiGigaAMModelStore(preferences: preferences, environment: [:]) { _, _, _ in
            preconditionFailure("Installed synthetic fixtures must not download")
        }

        // Freeze the new dictionary recipe from artifact metadata before any
        // runtime load. No dictionary entries means no private read is admitted.
        self.expect(!GigaAMRuntime.encoderFeatureAPIAvailable, "The inert runtime does not advertise features by default")
        self.expect(!store.encoderDictionarySupported(fingerprint: publicDescriptor.fingerprint),
                    "Missing SDK feature support rejects the encoder recipe before prepare")
        GigaAMArtifactTestCapabilities.encoderFeatureAPIAvailable = true
        self.expect(store.encoderDictionarySupported(fingerprint: publicDescriptor.fingerprint),
                    "An exact registered GGUF fingerprint admits encoder features without a model load")
        self.expect(!store.encoderDictionarySupported(fingerprint: publicDescriptor.fingerprint + "-changed"),
                    "A changed artifact fingerprint cannot inherit encoder support")
        if let nonGGUF = GigaAMModelCatalog.models.first(where: { $0.format != .gguf }) {
            self.expect(!store.encoderDictionarySupported(fingerprint: nonGGUF.fingerprint),
                        "Registered non-GGUF exports cannot inherit the native encoder API")
        }
        DictionaryMatcherExperiment.sharedFeaturesEnabled = true
        DictionaryMatcherExperiment.generation = "before-cold-prepare"
        let cold = PichiGigaAMProvider(modelStore: store, expectedModelFingerprint: publicDescriptor.fingerprint)
        let coldLease = UUID()
        try cold.beginAdmittedTranscription(leaseID: coldLease)
        self.expect(!cold.isReady && cold.loadedModelFingerprint == nil,
                    "Metadata admission does not prepare or publish an inference runtime")
        self.expect(self.usesEncoder(cold), "Cold admission freezes the available encoder recipe")
        let admitted = self.snapshot(cold)
        self.expect(admitted?.modelKey == GigaAMEncoderDictionaryStorage.modelKey(fingerprint: publicDescriptor.fingerprint),
                    "The admitted encoder key binds the exact artifact and actual storage recipe")
        self.expect(admitted?.enabled == true && admitted?.generation == "before-cold-prepare",
                    "Admission freezes the dictionary enable flag and generation")
        self.expect(admitted?.pronunciation == nil && admitted?.negatives == nil,
                    "An empty dictionary admits no private evidence handles")
        GigaAMArtifactTestCapabilities.encoderFeatureAPIAvailable = false
        DictionaryMatcherExperiment.sharedFeaturesEnabled = false
        DictionaryMatcherExperiment.generation = "changed-after-admission"
        try cold.beginAdmittedTranscription(leaseID: coldLease)
        self.expect(self.usesEncoder(cold) && self.snapshot(cold)?.modelKey == admitted?.modelKey &&
                    self.snapshot(cold)?.generation == admitted?.generation && self.snapshot(cold)?.enabled == true,
                    "Repeated admission of the same lease preserves recipe and flags after capability changes")
        let otherLease = UUID()
        do { try cold.beginAdmittedTranscription(leaseID: otherLease); preconditionFailure("A second lease must be rejected") }
        catch is CancellationError { self.checks += 1 }
        await cold.endAdmittedTranscription(leaseID: otherLease)
        self.expect(self.snapshot(cold)?.modelKey == admitted?.modelKey && self.usesEncoder(cold),
                    "Another lease cannot release the frozen encoder snapshot")
        await cold.endAdmittedTranscription(leaseID: coldLease)
        self.expect(self.snapshot(cold) == nil && !self.usesEncoder(cold),
                    "The owning lease releases its snapshot and encoder capture state")
        let nextLease = UUID()
        try cold.beginAdmittedTranscription(leaseID: nextLease)
        self.expect(!self.usesEncoder(cold) && self.snapshot(cold)?.enabled == false &&
                    self.snapshot(cold)?.generation == "changed-after-admission" &&
                    self.snapshot(cold)?.modelKey == GigaAMDictionaryAcoustics.modelKey(fingerprint: publicDescriptor.fingerprint),
                    "A later lease captures the changed capability and disabled state using the actual legacy recipe")
        await cold.endAdmittedTranscription(leaseID: nextLease)
        let mismatchedEvidence = DictionaryLearningAudioEvidence(recordingID: UUID(),
            modelKey: GigaAMEncoderDictionaryStorage.modelKey(fingerprint: publicDescriptor.fingerprint + "-changed"),
            observedText: "synthetic", sourceWordRange: 0..<1, sourceSampleRange: 0..<1,
            focalSampleRange: 0..<1, samples: [0])
        self.expect(try await cold.originalAudioEnrollment(mismatchedEvidence) == nil,
                    "Original encoder evidence from a different artifact is rejected before storage or inference")
        let wrong = PichiGigaAMProvider(modelStore: store, expectedModelFingerprint: publicDescriptor.fingerprint + "-changed")
        await GigaAMArtifactTestGate.shared.reset()
        do { try await wrong.prepare(); preconditionFailure("An unregistered fingerprint must not prepare") }
        catch GigaAMError.missingModels { self.checks += 1 }
        self.expect(await GigaAMArtifactTestGate.shared.loadedDirectory == nil,
                    "Fingerprint rejection happens before the runtime load gate")
        self.expect(!wrong.isReady && wrong.loadedModelFingerprint == nil,
                    "Fingerprint rejection cannot publish loaded state")
        await wrong.unloadModel()
        DictionaryMatcherExperiment.generation = "artifact-ownership-inert-dictionary"

        let provider = PichiGigaAMProvider(modelStore: store)
        let lease = UUID()
        try provider.beginAdmittedTranscription(leaseID: lease)
        let selection = try store.selectedArtifact()
        self.expect(selection.descriptor == importedDescriptor, "Admission captures the original imported descriptor")
        await GigaAMArtifactTestGate.shared.reset()
        let preparation = Task { try await provider.prepare() }
        await GigaAMArtifactTestGate.shared.waitUntilStarted()
        let loadedDirectory = await GigaAMArtifactTestGate.shared.loadedDirectory
        self.expect(loadedDirectory == importedRoot, "Held preparation loads the admitted imported directory")
        preferences.conceal()
        self.expect(try store.selectedArtifact().descriptor == publicDescriptor, "Concealed live preferences resolve the public fallback")
        self.expect(try store.installedModel(selection: selection).directory == importedRoot, "Frozen installed lookup remains with the imported root")
        let hiddenRoot = root.appendingPathComponent("held-import")
        try manager.moveItem(at: importedRoot, to: hiddenRoot)
        self.expect(!provider.modelsExistOnDisk(), "Provider existence checks cannot silently report the public fallback")
        self.expect(store.modelsExistOnDisk(), "Unbound lookup still uses the visible default behavior")
        self.expect(!store.modelsExistOnDisk(selection: selection), "Bound store existence checks inspect only the admitted artifact")
        try manager.moveItem(at: hiddenRoot, to: importedRoot)
        await GigaAMArtifactTestGate.shared.open()
        do { try await preparation.value; preconditionFailure("Inert runtime must fail preparation") }
        catch GigaAMError.incompatibleModel { self.checks += 1 }
        try await provider.clearCache()
        self.expect(!manager.fileExists(atPath: importedRoot.path), "Failed preparation recovery retires the exact imported folder")
        self.expect(publicDescriptor.filesExist(in: publicRoot), "Imported recovery preserves the public fallback")
        self.expect(try Data(contentsOf: publicRoot.appendingPathComponent(publicArtifactPath)) == publicBytes,
                    "Public artifact bytes survive imported recovery")
        await provider.endAdmittedTranscription(leaseID: lease)

        // clearCache must capture its selection before unload suspends to join a
        // preparation; releasing the lease during that join cannot redirect it.
        try write(importedDescriptor, importedRoot)
        preferences.select(importedDescriptor.id)
        let secondLease = UUID()
        try provider.beginAdmittedTranscription(leaseID: secondLease)
        await GigaAMArtifactTestGate.shared.reset()
        let secondPreparation = Task { try await provider.prepare() }
        await GigaAMArtifactTestGate.shared.waitUntilStarted()
        let recovery = Task { try await provider.clearCache() }
        await GigaAMArtifactTestGate.shared.waitUntilCancelled()
        preferences.conceal()
        await provider.endAdmittedTranscription(leaseID: secondLease)
        await GigaAMArtifactTestGate.shared.open()
        _ = try? await secondPreparation.value
        try await recovery.value
        self.expect(!manager.fileExists(atPath: importedRoot.path), "Suspended recovery retains the selection after lease release")
        self.expect(publicDescriptor.filesExist(in: publicRoot), "Suspended recovery never switches to the public fallback")
        self.expect(!provider.isReady && provider.loadedModelFingerprint == nil, "Failed joined preparation cannot publish readiness")

        // Symmetric ownership: a public admission must survive a later import selection.
        try write(importedDescriptor, importedRoot)
        preferences.select(nil)
        let publicLease = UUID()
        try provider.beginAdmittedTranscription(leaseID: publicLease)
        preferences.select(importedDescriptor.id)
        try await provider.clearCache()
        self.expect(!manager.fileExists(atPath: publicRoot.path), "Public admission removes its original public artifact")
        self.expect(importedDescriptor.filesExist(in: importedRoot), "Public recovery preserves a later imported selection")
        await provider.endAdmittedTranscription(leaseID: publicLease)

        // Optional selection preserves ordinary visible behavior for model pickers.
        self.expect(store.modelsExistOnDisk(), "Nil selection still follows the current visible import")
        self.expect(try store.installedModel().directory == importedRoot, "Nil installed lookup retains its existing resolver")
        try store.removeOwnedModels()
        self.expect(!manager.fileExists(atPath: importedRoot.path), "Nil removal retains its normal selected artifact behavior")
        try write(publicDescriptor, publicRoot)
        try write(importedDescriptor, importedRoot)
        preferences.select(nil)
        self.expect(provider.modelsExistOnDisk(), "Unadmitted provider retains normal public existence checks")
        try await provider.clearCache()
        self.expect(!manager.fileExists(atPath: publicRoot.path), "Unadmitted visible recovery removes its current public source")
        self.expect(importedDescriptor.filesExist(in: importedRoot), "Unadmitted public recovery preserves imported artifacts")

        let external = PichiGigaAMModelStore(directory: root, preferences: preferences, environment: [:])
        let importedSelection = PichiGigaAMModelStore.Selection(descriptor: importedDescriptor, root: root, allowsDownload: false)
        try external.removeOwnedModels(selection: importedSelection)
        self.expect(importedDescriptor.filesExist(in: importedRoot), "Explicit directory overrides remain read-only with frozen selection")
        let environment = PichiGigaAMModelStore(preferences: preferences, environment: ["PICHI_GIGAAM_MODEL_DIR": root.path])
        try environment.removeOwnedModels(selection: importedSelection)
        self.expect(importedDescriptor.filesExist(in: importedRoot), "Environment overrides remain read-only with frozen selection")
        self.expect(try Data(contentsOf: marker) == markerBytes, "Recovery preserves unrelated files byte for byte")
        print("GigaAM actual provider/store artifact ownership: \(self.checks) assertions passed")
    }
}
