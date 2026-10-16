import CryptoKit
import Foundation

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

    var implementationFingerprint: String {
        self.compiledModelURL == nil
            ? "Nemotron3-sortformer@eb1e6628998e47022799d305b52c2680d3576801;model=8976c3c40a752cd6468a08f2aa08626770bc048f"
            : MeetingNemotronModelLocator.implementationFingerprint
    }

    /// The new model is author-compiled and must never enter the legacy package compiler.
    var compiledModelURL: URL? {
        guard packageURL.pathExtension == "nemotronbundle" else { return nil }
        return packageURL.appendingPathComponent(MeetingNemotronModelLocator.compiledModelFileName, isDirectory: true)
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
    func locate() throws -> MeetingNemotronModelArtifact
    /// Re-validates a previously located artifact before opening it. Any drift is a refusal.
    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact
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

    init(
        injectedURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.injectedURL = injectedURL
        self.environment = environment
    }

    /// The versioned FluidVoice cache location used when nothing is injected or overridden.
    static func defaultPackageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent(AppBrand.storageNamespace, isDirectory: true)
            .appendingPathComponent("MeetingModels", isDirectory: true)
            .appendingPathComponent("nemotron-3-diarization", isDirectory: true)
            .appendingPathComponent(Self.cacheVersion, isDirectory: true)
            .appendingPathComponent(Self.packageFileName, isDirectory: true)
    }

    func resolvedPackageURL() -> URL {
        if let injectedURL { return injectedURL }
        if let override = self.environment[Self.environmentOverrideKey],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        return Self.defaultPackageURL()
    }

    func locate() throws -> MeetingNemotronModelArtifact {
        let url = self.resolvedPackageURL().standardizedFileURL
        return try Self.validatePackage(at: url)
    }

    func recheck(_ artifact: MeetingNemotronModelArtifact) throws -> MeetingNemotronModelArtifact {
        let current = try self.locate()
        guard current.packageURL == artifact.packageURL,
              current.totalByteCount == artifact.totalByteCount,
              current.fileCount == artifact.fileCount,
              current.manifestSHA256 == artifact.manifestSHA256,
              current.entryMetadataSHA256 == artifact.entryMetadataSHA256
        else {
            throw MeetingNemotronModelReadinessError.artifactChanged(path: artifact.packageURL.path)
        }
        return current
    }

    /// Structural validation of one package: a real directory (not a symlink) containing a real
    /// `Manifest.json` and at least one `model.mlmodel`, with no symlink anywhere inside it. A
    /// symlinked component would make the measured bytes describe a different file than CoreML
    /// later opens.
    static func validatePackage(at url: URL) throws -> MeetingNemotronModelArtifact {
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
            if (isCompiledBundle && relativePath == Self.compiledModelFileName + "/model.mil")
                || (!isCompiledBundle && entry.lastPathComponent == "Manifest.json") {
                hasManifest = true
                manifestSHA256 = try Self.sha256Hex(contentsOf: entry)
            }
            if (isCompiledBundle && relativePath == Self.compiledModelFileName + "/coremldata.bin")
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
            entryMetadataSHA256: entryMetadataSHA256
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
