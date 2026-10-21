import CryptoKit
import Foundation

/// Pinned WeSpeaker artifacts consumed by the existing speaker-matching runtime. The shared
/// diarization store prepares these before capture; inference never downloads a model.
nonisolated enum MeetingSpeakerVoiceModelArtifacts {
    static let revision = "7eab74f3463c736418d0eb10296261ae581146c9"
    static let packageName = "wespeaker_v2.mlmodelc"
    struct FileProof: Sendable {
        let path: String
        let bytes: Int
        let digest: String
        let usesGitBlobSHA1: Bool
    }
    static let files: [FileProof] = [
        .init(path: "analytics/coremldata.bin", bytes: 243, digest: "d2b1fcde6121aea3ff0e14c1dc50d09dacb0314a2e89156353c31804230a422f", usesGitBlobSHA1: false),
        .init(path: "coremldata.bin", bytes: 359, digest: "6feb2472a71fa9d8a84020c85206138a4f6261c565c9884bf518d59dd5838da7", usesGitBlobSHA1: false),
        .init(path: "metadata.json", bytes: 2738, digest: "5cda8cc14897fb37b01552a0fb9fefca31a6c00f", usesGitBlobSHA1: true),
        .init(path: "model.mil", bytes: 706900, digest: "977dcf031d18b18fb5096d3e943ff8aa18754e21", usesGitBlobSHA1: true),
        .init(path: "weights/weight.bin", bytes: 7243904, digest: "34004f6798d35cad7071e2fdc67e63faaa782f53697e1cb49bcb452cf81ae151", usesGitBlobSHA1: false),
    ]
    static func packageURL() -> URL {
        AppBrand.modelsDirectory.appendingPathComponent("speaker-diarization-coreml", isDirectory: true)
            .appendingPathComponent(self.packageName, isDirectory: true)
    }
    static func validateRootContainment() throws {
        let root = AppBrand.modelsDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let package = self.packageURL().resolvingSymlinksInPath().standardizedFileURL.path
        guard package.hasPrefix(root + "/") else { throw MeetingModelResidencyError.unsupportedProvider }
    }
    static func validate() throws {
        try self.validateRootContainment()
        try self.validate(at: self.packageURL())
    }
    static func validatePackageDirectories(at directory: URL) throws {
        for relative in ["", "analytics", "weights"] {
            let url = relative.isEmpty ? directory : directory.appendingPathComponent(relative, isDirectory: true)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw MeetingModelResidencyError.unsupportedProvider }
        }
    }
    static func validate(at directory: URL) throws {
        try self.validatePackageDirectories(at: directory)
        for proof in self.files {
            let url = directory.appendingPathComponent(proof.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == proof.bytes else { throw MeetingModelResidencyError.unsupportedProvider }
            let data = try Data(contentsOf: url)
            let digest: String
            if proof.usesGitBlobSHA1 {
                var blob = Data("blob \(data.count)\0".utf8); blob.append(data)
                digest = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            } else { digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
            guard digest == proof.digest else { throw MeetingModelResidencyError.unsupportedProvider }
        }
    }
    static func ensureInstalled(progress: @escaping @Sendable (Double) -> Void) async throws {
        try self.validateRootContainment()
        try await self.ensureInstalled(at: self.packageURL(), progress: progress)
    }
    /// Explicit trusted destinations let native tests and imports use isolated model storage.
    /// The model revision, integrity checks and installation operation stay unchanged.
    static func ensureInstalled(at destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard destination.isFileURL else { throw MeetingModelResidencyError.unsupportedProvider }
        if (try? self.validate(at: destination)) != nil { return }
        let root = destination.deletingLastPathComponent()
        let stage = root.appendingPathComponent(".wespeaker-\(self.revision).staging", isDirectory: true)
        let downloader = await HuggingFaceModelDownloader(owner: "FluidInference", repo: "speaker-diarization-coreml", revision: self.revision,
                                                     requiredItems: [.init(path: self.packageName, isDirectory: true)])
        try await downloader.ensureModelsPresent(at: stage) { fraction, _ in progress(fraction) }
        let source = stage.appendingPathComponent(self.packageName, isDirectory: true)
        do { try self.validate(at: source) }
        catch {
            // A corrupt resumed stage must not be skipped as complete on every later retry.
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else { try FileManager.default.moveItem(at: source, to: destination) }
        try self.validate(at: destination)
        try? FileManager.default.removeItem(at: stage)
    }
}

// The composite identity includes the optional encoder and bounded streaming evidence policy.
// Base diarizer artifacts/checkpoints retain their original identity.
extension MeetingNemotronModelProfile {
    nonisolated var legacyOwnerStreamingImplementationFingerprint: String {
        self.implementationFingerprint + (self.supportsOwnerVoiceVerification
            ? ";voice=wespeaker@" + MeetingSpeakerVoiceModelArtifacts.revision + ";owner-stream=bounded-two-3s-v1" : "")
    }

    nonisolated var ownerV2StreamingImplementationFingerprint: String {
        self.implementationFingerprint + (self.supportsOwnerVoiceVerification
            ? ";voice=wespeaker@" + MeetingSpeakerVoiceModelArtifacts.revision
                + ";owner-stream=first-latest-3to5s-v2;owner-ref=0.65;owner-self=0.45;owner-margin=0.10;owner-quality-block=0.5s;owner-lookback=16s;owner-horizon=0.36s" : "")
    }

    nonisolated var streamingImplementationFingerprint: String {
        self.ownerV2StreamingImplementationFingerprint + (self.supportsOwnerVoiceVerification
            ? ";owner-live=serial-v3;owner-retry=2s-to10s-then10s" : "")
    }

    /// Only exact compiled recipes are admitted. Anonymous and owner-v1 checkpoints keep
    /// their original evidence selection and decision; no arbitrary suffix can change either.
    nonisolated func acceptsStreamingImplementationFingerprint(_ value: String) -> Bool {
        value == self.implementationFingerprint || value == self.legacyOwnerStreamingImplementationFingerprint
            || value == self.ownerV2StreamingImplementationFingerprint || value == self.streamingImplementationFingerprint
    }

    nonisolated func verifiesStreamingOwner(implementationFingerprint value: String) -> Bool {
        self.supportsOwnerVoiceVerification
            && (value == self.legacyOwnerStreamingImplementationFingerprint
                || value == self.ownerV2StreamingImplementationFingerprint || value == self.streamingImplementationFingerprint)
    }

    nonisolated func usesAdaptiveStreamingOwnerEvidence(implementationFingerprint value: String) -> Bool {
        self.supportsOwnerVoiceVerification
            && (value == self.ownerV2StreamingImplementationFingerprint || value == self.streamingImplementationFingerprint)
    }

    nonisolated func verifiesLiveStreamingOwner(implementationFingerprint value: String) -> Bool {
        self.supportsOwnerVoiceVerification && value == self.streamingImplementationFingerprint
    }
}
