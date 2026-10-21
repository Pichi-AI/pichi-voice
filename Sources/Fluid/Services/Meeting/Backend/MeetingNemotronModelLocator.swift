import CryptoKit
import Foundation

/// Fixed author-compiled variants of the same runtime. Experimental profiles are selected
/// explicitly by a registered inference adapter, never by package-name guessing or fallback.
/// Keeping this below the composite backend registry avoids another model-specific pipeline.
nonisolated enum MeetingNemotronModelProfile: String, CaseIterable, Sendable {
    case fast32SplitW8A8 = "fast32-split-w8a8"
    case experimentalFast32FP16CPU = "experimental-fast32-fp16-cpu"
    case experimentalFast128FP16CPU = "experimental-fast128-fp16-cpu"

    enum ComputePreference: String, Sendable {
        case devicePreferred
        case cpuOnly
    }

    static let repositoryRevision = "25a90f97f254428d4b30374b76af9c74fdee8327"
    static let runtimeRevision = "82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8"
    static let silenceEmbeddingFileName = "learnable_sil_emb.bin"

    var isExperimental: Bool { self != .fast32SplitW8A8 }
    /// The selected composite profile includes the optional owner verifier only when its
    /// fingerprint and resource preparation include voice matching. The registered continuous
    /// profile's exact recipe fixes whether verification runs live or after model cleanup.
    var supportsOwnerVoiceVerification: Bool { self == .fast32SplitW8A8 || self == .experimentalFast128FP16CPU }
    var computePreference: ComputePreference { self.isExperimental ? .cpuOnly : .devicePreferred }
    var presetName: String {
        switch self {
        case .fast32SplitW8A8: return "fast32-split-w8a8"
        case .experimentalFast32FP16CPU: return "fast32"
        case .experimentalFast128FP16CPU: return "fast128"
        }
    }
    var compiledModelFileName: String {
        switch self {
        case .fast32SplitW8A8: return "Nemotron3Diarizer_s32_split_w8a8.mlmodelc"
        case .experimentalFast32FP16CPU: return "Nemotron3Diarizer_fast32.mlmodelc"
        case .experimentalFast128FP16CPU: return "Nemotron3Diarizer_fast128.mlmodelc"
        }
    }
    var projectionFileName: String? { self == .fast32SplitW8A8 ? "pre_encode_proj_t.bin" : nil }
    var remoteModelPath: String {
        (self == .fast32SplitW8A8 ? "split/" : "monolithic/v2/") + self.compiledModelFileName
    }
    var cacheVersion: String {
        self == .fast32SplitW8A8 ? "v2-fast32-w8a8" : "v3-" + self.rawValue
    }
    var packageFileName: String {
        (self == .fast32SplitW8A8 ? "fast32-w8a8" : self.rawValue) + ".nemotronbundle"
    }
    var hostFileNames: [String] {
        [Self.silenceEmbeddingFileName] + (self.projectionFileName.map { [$0] } ?? [])
    }
    /// Order retains the production download contract. Paths stay under the pinned repo.
    var remoteFilePaths: [String] {
        ["analytics/coremldata.bin", "coremldata.bin", "model.mil", "weights/weight.bin"]
            .map { self.remoteModelPath + "/" + $0 } + self.hostFileNames
    }
    var expectedFiles: [String: String] {
        let modelFiles: [String: String]
        switch self {
        case .fast32SplitW8A8:
            modelFiles = [
                "model.mil": "560f87a4a5124712d51ac7aecfee9a97278cac9087919719b031917a0160b508",
                "coremldata.bin": "b349771fbdb19443fb0af32b6c061fdb183d58e54c0b6376c2fbdca0a9941b70",
                "analytics/coremldata.bin": "3241bd5be194abbf0f625be8bd639b5c2035359594a6a513d70e9159e294ce39",
                "weights/weight.bin": "99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed",
            ]
        case .experimentalFast32FP16CPU:
            modelFiles = [
                "model.mil": "e2f0cbbf88e824385475779b637c36281c5f98f339783840bdf7b3dfcd08c123",
                "coremldata.bin": "fbc2d4dc25147427269e4774a5b8e3dd6b613e8c8458d74c7462a1a377dbae75",
                "analytics/coremldata.bin": "7932ba85d07f09ba8feff996e1278f376a9139e31141d2827021f1c225e590ae",
                "weights/weight.bin": "7353d8e7a5d29a8d15edf86dbf40bed4e82b7b8f456f302d5cdcbf850ed25358",
            ]
        case .experimentalFast128FP16CPU:
            modelFiles = [
                "model.mil": "e7c029a46d9f327bec4c47fc34e5d32ee2cec9ce596950af0c403d05146b4ead",
                "coremldata.bin": "ebcca7245d8d774305752b9f2b79433ad1858f8a06df3b326e0ae6305d981d25",
                "analytics/coremldata.bin": "a71e06616a3ae7bddef06ce5dfc7fe523a286e489f63a8da2fc4f1e940d560a4",
                "weights/weight.bin": "e8c90d2d0e16787a420de6805fd5b7a95c116fac0163208b5bc4d8a9ae459ca4",
            ]
        }
        var files = Dictionary(uniqueKeysWithValues: modelFiles.map { (self.compiledModelFileName + "/" + $0.key, $0.value) })
        files[Self.silenceEmbeddingFileName] = "d4417b3c0eabdf7c47032fac2b5b5a7ee83d819a6ddda8fd8eaf74e2b5cc4ac7"
        if let projectionFileName {
            files[projectionFileName] = "eb15b89e7af9813331a7d8db02e83e30bf97463d272c748e72086bafd4e81c60"
        }
        return files
    }
    var implementationFingerprint: String {
        let weight = self.expectedFiles[self.compiledModelFileName + "/weights/weight.bin"]!
        let config = self == .experimentalFast128FP16CPU ? "128-4-40-264" : "32-4-40-264"
        let base = "Nemotron3-" + (self == .fast32SplitW8A8 ? "fast32-split-w8a8" : self.rawValue)
            + "@\(Self.runtimeRevision);model=\(Self.repositoryRevision);weight=\(weight);config=\(config)"
        // Persisted attempts/checkpoints keep the original default identity.
        return self == .fast32SplitW8A8 ? base : base + ";split=false;compute=\(self.computePreference.rawValue)"
    }

    /// The optional voice-encoder lineage belongs to the composite adapter. Its boundary is
    /// explicit so partial model identities and appended compute overrides cannot match.
    static func matching(implementationFingerprint value: String) -> Self? {
        self.allCases.first {
            value == $0.implementationFingerprint || value.hasPrefix($0.implementationFingerprint + ";voice=")
        }
    }
}

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§5): FluidVoice-side Nemotron model
// readiness. This locator only resolves and validates a local, already-installed model package.
// It never downloads and never accepts a symlink — `MeetingDiarizationModelStore` downloads and
// installs the pinned bundle, and `execute` performs no downloads.
//
// Resolution order: an injected URL (tests), then the development environment override
// `FLUIDVOICE_NEMOTRON_DIARIZATION_MODEL_PATH`, then the versioned FluidVoice cache location.
// `recheck` re-walks the package when it is opened and refuses a missing or changed artifact.

/// A validated local Nemotron model package plus the facts measured while validating it.
nonisolated struct MeetingNemotronModelArtifact: Equatable, Sendable {
    let packageURL: URL
    let totalByteCount: Int64
    let fileCount: Int
    /// SHA-256 of the package's `Manifest.json` — the package's own descriptor of its contents.
    let manifestSHA256: String
    /// Stable digest of every regular entry's relative path, logical size and modification time.
    /// This makes a same-size weight replacement visible without hashing 190 MB on the main actor.
    let entryMetadataSHA256: String
    let profile: MeetingNemotronModelProfile

    init(packageURL: URL, totalByteCount: Int64, fileCount: Int, manifestSHA256: String,
         entryMetadataSHA256: String, profile: MeetingNemotronModelProfile = .fast32SplitW8A8) {
        self.packageURL = packageURL
        self.totalByteCount = totalByteCount
        self.fileCount = fileCount
        self.manifestSHA256 = manifestSHA256
        self.entryMetadataSHA256 = entryMetadataSHA256
        self.profile = profile
    }

    var implementationFingerprint: String {
        self.compiledModelURL == nil
            ? "Nemotron3-sortformer@eb1e6628998e47022799d305b52c2680d3576801;model=8976c3c40a752cd6468a08f2aa08626770bc048f"
            : self.profile.implementationFingerprint
    }

    /// The new model is author-compiled and must never enter the legacy package compiler.
    var compiledModelURL: URL? {
        guard packageURL.pathExtension == "nemotronbundle" else { return nil }
        return packageURL.appendingPathComponent(self.profile.compiledModelFileName, isDirectory: true)
    }
}

nonisolated enum MeetingNemotronModelReadinessError: LocalizedError, Equatable {
    /// Nothing exists at the resolved location.
    case modelNotInstalled(path: String)
    /// The resolved path fails package-structure validation. The payload is a stable diagnostic
    /// token, never a localized system string.
    case invalidModelPackage(reason: String)
    /// The package validated earlier no longer matches what is on disk now.
    case artifactChanged(path: String)

    var errorDescription: String? {
        switch self {
        case let .modelNotInstalled(path):
            return AppBrand.format("The Nemotron diarization model is not installed at %@. Open FluidMeet settings to download the speaker model.", path)
        case let .invalidModelPackage(reason):
            return "The Nemotron diarization model package is invalid (\(reason))."
        case let .artifactChanged(path):
            return "The Nemotron diarization model at \(path) changed since it was validated."
        }
    }
}

nonisolated protocol MeetingNemotronModelLocating: Sendable {
    var supportsOwnerVoiceVerification: Bool { get }
    func locate() throws -> MeetingNemotronModelArtifact
    /// Re-validates a previously located artifact before opening it. Any drift is a refusal.
    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact
}

extension MeetingNemotronModelLocating {
    /// Existing injected/legacy locators retain the original optional owner stage.
    nonisolated var supportsOwnerVoiceVerification: Bool { true }
}

nonisolated struct MeetingNemotronModelLocator: MeetingNemotronModelLocating {
    static let environmentOverrideKey = "FLUIDVOICE_NEMOTRON_DIARIZATION_MODEL_PATH"
    static let implementationFingerprint = "Nemotron3-fast32-split-w8a8@82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8;model=25a90f97f254428d4b30374b76af9c74fdee8327;weight=99e2ae43ac6a513abf99951b35a75fb6bc51d2287c3c1af48a9657d917e57aed;config=32-4-40-264"
    static let cacheVersion = "v2-fast32-w8a8"
    static let packageFileName = "fast32-w8a8.nemotronbundle"
    static let compiledModelFileName = "Nemotron3Diarizer_s32_split_w8a8.mlmodelc"
    static let remoteModelPath = "split/" + compiledModelFileName
    static let projectionFileName = "pre_encode_proj_t.bin"
    private static let maximumFileCount = 64
    private static let maximumTotalByteCount: Int64 = 1_000_000_000

    let injectedURL: URL?
    let environment: [String: String]
    let profile: MeetingNemotronModelProfile
    private var ownerVoiceVerificationDisabled = false
    var supportsOwnerVoiceVerification: Bool {
        self.profile.supportsOwnerVoiceVerification && !self.ownerVoiceVerificationDisabled
    }

    /// A frozen legacy anonymous recipe shares the exact diarizer artifacts, but must not
    /// acquire owner identity merely because the app now supports that optional stage.
    func withoutOwnerVoiceVerification() -> Self {
        var frozen = self
        frozen.ownerVoiceVerificationDisabled = true
        return frozen
    }

    init(
        injectedURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        profile: MeetingNemotronModelProfile = .fast32SplitW8A8
    ) {
        self.injectedURL = injectedURL
        self.environment = environment
        self.profile = profile
    }

    /// The versioned FluidVoice cache location used when nothing is injected or overridden.
    static func defaultPackageURL(profile: MeetingNemotronModelProfile = .fast32SplitW8A8) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(AppBrand.storageNamespace, isDirectory: true)
            .appendingPathComponent("MeetingModels", isDirectory: true)
            .appendingPathComponent("nemotron-3-diarization", isDirectory: true)
            .appendingPathComponent(profile.cacheVersion, isDirectory: true)
            .appendingPathComponent(profile.packageFileName, isDirectory: true)
    }

    func resolvedPackageURL() -> URL {
        if let injectedURL { return injectedURL }
        if self.profile == .fast32SplitW8A8, let override = self.environment[Self.environmentOverrideKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return Self.defaultPackageURL(profile: self.profile)
    }

    func locate() throws -> MeetingNemotronModelArtifact {
        let url = self.resolvedPackageURL().standardizedFileURL
        return try Self.validatePackage(at: url, profile: self.profile)
    }

    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact {
        let current = try self.locate()
        guard current.packageURL == artifact.packageURL,
              current.totalByteCount == artifact.totalByteCount,
              current.fileCount == artifact.fileCount,
              current.manifestSHA256 == artifact.manifestSHA256,
              current.entryMetadataSHA256 == artifact.entryMetadataSHA256,
              current.profile == artifact.profile
        else {
            throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
        }
        return current
    }

    /// Structural validation of one package: a real directory (not a symlink) containing a real
    /// `Manifest.json` and at least one `model.mlmodel`, with no symlink anywhere inside it. A
    /// symlinked component would make the measured bytes describe a different file than CoreML
    /// later opens.
    static func validatePackage(at url: URL, profile: MeetingNemotronModelProfile = .fast32SplitW8A8) throws -> MeetingNemotronModelArtifact {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType
        else {
            throw MeetingNemotronModelReadinessError.modelNotInstalled(path: url.path)
        }
        guard type == .typeDirectory else {
            if type == .typeSymbolicLink {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageIsSymlink")
            }
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageNotDirectory")
        }
        // URL resolution also restores on-disk capitalization on case-insensitive volumes.
        // A home path such as /Users/Gabriel may legitimately resolve to /Users/gabriel.
        // Allow only case changes in real directory entries, not links whose targets happen
        // to differ only by case. Preserve Foundation's handling of system aliases like /var.
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        if resolved != url {
            let components = url.pathComponents
            let resolvedComponents = resolved.pathComponents
            guard components.count == resolvedComponents.count else {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packagePathContainsSymlink")
            }
            var prefix = URL(fileURLWithPath: "/", isDirectory: true)
            for (component, resolvedComponent) in zip(components.dropFirst(), resolvedComponents.dropFirst()) {
                prefix.appendPathComponent(component, isDirectory: true)
                guard component != resolvedComponent else { continue }
                let attributes = try manager.attributesOfItem(atPath: prefix.path)
                guard component.caseInsensitiveCompare(resolvedComponent) == .orderedSame,
                      attributes[.type] as? FileAttributeType == .typeDirectory
                else {
                    throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packagePathContainsSymlink")
                }
            }
        }

        let isCompiledBundle = url.pathExtension == "nemotronbundle"
        guard isCompiledBundle || profile == .fast32SplitW8A8 else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "profileRequiresCompiledBundle")
        }
        var totalByteCount: Int64 = 0
        var fileCount = 0
        var hasManifest = false
        var hasModel = false
        var manifestSHA256 = ""
        var entryMetadata: [(path: String, size: Int, modified: TimeInterval)] = []

        // Enumerate relative names. URL enumeration can return /private/var children for a
        // /var root, so slicing absolute paths by the root's string length corrupts names.
        guard let enumerator = manager.enumerator(atPath: url.path) else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageUnreadable")
        }
        for case let relativePath as String in enumerator {
            let entry = url.appendingPathComponent(relativePath)
            let values = try resourceValues(entry)
            if values.isSymbolicLink == true {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageContainsSymlink")
            }
            guard values.isRegularFile == true else { continue }
            fileCount += 1
            guard fileCount <= Self.maximumFileCount else {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageHasTooManyFiles")
            }
            let logicalSize = values.fileSize ?? 0
            totalByteCount += Int64(logicalSize)
            guard totalByteCount <= Self.maximumTotalByteCount else {
                throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageTooLarge")
            }
            entryMetadata.append((
                path: relativePath,
                size: logicalSize,
                modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0
            ))
            if (isCompiledBundle && relativePath == profile.compiledModelFileName + "/model.mil")
                || (!isCompiledBundle && entry.lastPathComponent == "Manifest.json") {
                hasManifest = true
                manifestSHA256 = try Self.sha256Hex(contentsOf: entry)
            }
            if (isCompiledBundle && relativePath == profile.compiledModelFileName + "/coremldata.bin")
                || (!isCompiledBundle && entry.lastPathComponent == "model.mlmodel") {
                hasModel = true
            }
        }
        guard hasManifest else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "manifestMissing")
        }
        guard hasModel else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "modelMissing")
        }
        guard fileCount > 0, totalByteCount > 0 else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "packageEmpty")
        }

        let metadataBytes = entryMetadata.sorted { $0.path < $1.path }.map {
            "\($0.path)\u{0}\($0.size)\u{0}\($0.modified.bitPattern)\n"
        }.joined()
        let entryMetadataSHA256 = SHA256.hash(data: Data(metadataBytes.utf8))
            .map { String(format: "%02x", $0) }.joined()

        return MeetingNemotronModelArtifact(
            packageURL: url,
            totalByteCount: totalByteCount,
            fileCount: fileCount,
            manifestSHA256: manifestSHA256,
            entryMetadataSHA256: entryMetadataSHA256,
            profile: profile
        )
    }

    private static func resourceValues(_ url: URL) throws -> URLResourceValues {
        do {
            return try url.resourceValues(forKeys: [
                .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey,
                .contentModificationDateKey,
            ])
        } catch {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "entryUnreadable")
        }
    }

    private static func sha256Hex(contentsOf url: URL) throws -> String {
        guard let data = try? Data(contentsOf: url) else {
            throw MeetingNemotronModelReadinessError.invalidModelPackage(reason: "manifestUnreadable")
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
