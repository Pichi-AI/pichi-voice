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
    static func validate() throws { try self.validate(at: self.packageURL()) }
    static func validate(at directory: URL) throws {
        let folder = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folder.isDirectory == true, folder.isSymbolicLink != true else { throw MeetingModelResidencyError.unsupportedProvider }
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
        if (try? self.validate()) != nil { return }
        let root = self.packageURL().deletingLastPathComponent()
        let stage = root.appendingPathComponent(".wespeaker-\(self.revision).staging", isDirectory: true)
        let downloader = HuggingFaceModelDownloader(owner: "FluidInference", repo: "speaker-diarization-coreml", revision: self.revision,
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
        let destination = self.packageURL()
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: source)
        } else { try FileManager.default.moveItem(at: source, to: destination) }
        try self.validate()
        try? FileManager.default.removeItem(at: stage)
    }
}
