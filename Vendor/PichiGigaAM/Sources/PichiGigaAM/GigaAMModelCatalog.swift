import CryptoKit
import Foundation

public struct GigaAMCoreMLConfiguration: Sendable, Equatable {
    public let featureFrameCount: Int
    public let windowFile: String
    public let melFilterbankFile: String
}

public enum GigaAMModelFormat: Sendable, Equatable {
    case onnx
    case coreML(GigaAMCoreMLConfiguration)
}

public struct GigaAMModelArtifact: Sendable, Equatable {
    public let path: String
    public let sha256: String
    public let byteCount: Int64?
    public init(path: String, sha256: String, byteCount: Int64? = nil) {
        self.path = path
        self.sha256 = sha256
        self.byteCount = byteCount
    }
}

/// Checksums identify Pichi's existing optimized exports. Weights remain outside Git.
public struct GigaAMModelDescriptor: Sendable, Equatable {
    public let id: String
    public let modelFile: String
    public let modelSHA256: String
    public let vocabularyFile: String?
    public let vocabularySHA256: String?
    public let endOfUtteranceThreshold: Float?
    public let downloadBaseURL: URL?
    public let modelByteCount: Int64?
    public let vocabularyByteCount: Int64?
    public let format: GigaAMModelFormat
    private let packageArtifacts: [GigaAMModelArtifact]?

    public var artifacts: [GigaAMModelArtifact] {
        if let packageArtifacts { return packageArtifacts }
        var files = [GigaAMModelArtifact(path: self.modelFile, sha256: self.modelSHA256, byteCount: self.modelByteCount)]
        if let path = self.vocabularyFile, let hash = self.vocabularySHA256 {
            files.append(.init(path: path, sha256: hash, byteCount: self.vocabularyByteCount))
        }
        return files
    }

    public init(id: String, modelFile: String, modelSHA256: String, vocabularyFile: String?, vocabularySHA256: String?, endOfUtteranceThreshold: Float?,
                downloadBaseURL: URL? = nil, modelByteCount: Int64? = nil, vocabularyByteCount: Int64? = nil,
                format: GigaAMModelFormat = .onnx, artifacts: [GigaAMModelArtifact]? = nil) {
        self.id = id
        self.modelFile = modelFile
        self.modelSHA256 = modelSHA256
        self.vocabularyFile = vocabularyFile
        self.vocabularySHA256 = vocabularySHA256
        self.endOfUtteranceThreshold = endOfUtteranceThreshold
        self.downloadBaseURL = downloadBaseURL
        self.modelByteCount = modelByteCount
        self.vocabularyByteCount = vocabularyByteCount
        self.format = format
        self.packageArtifacts = artifacts
    }

    /// Stable content identity for resumable jobs, independent of local paths.
    public var fingerprint: String {
        if case .coreML = self.format {
            let identity = self.artifacts.sorted { $0.path < $1.path }.map { "\($0.path):\($0.sha256)" }.joined(separator: "\n")
            let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return "gigaam-coreml-v1/\(self.id)/\(digest)"
        }
        return "gigaam-native-v1/\(self.id)/\(self.modelSHA256)/\(self.vocabularySHA256 ?? "russian-characters-v1")"
    }

    public func filesExist(in directory: URL) -> Bool {
        let names = self.artifacts.map(\.path)
        return names.allSatisfy { name in
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
    }

    public func verify(in directory: URL) throws {
        guard !self.artifacts.isEmpty, self.artifacts.count <= 32,
              Set(self.artifacts.map(\.path)).count == self.artifacts.count else { throw GigaAMError.incompatibleModel }
        for artifact in self.artifacts {
            try Task.checkCancellation()
            let parts = artifact.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !artifact.path.hasPrefix("/"), !parts.isEmpty,
                  parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw GigaAMError.incompatibleModel }
            let url = directory.appendingPathComponent(artifact.path)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  artifact.byteCount == nil || Int64(values.fileSize ?? -1) == artifact.byteCount else {
                throw GigaAMError.checksumMismatch(artifact.path)
            }
            try Self.verify(url, expectedSHA256: artifact.sha256)
        }
    }

    public static func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var digest = SHA256()
        // FileHandle may hand back autoreleased NSData. Bound its lifetime per block,
        // even when repeated model loads share a long-lived concurrency worker.
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            digest.update(data: data)
            return true
        }) {}
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func verify(_ fileURL: URL, expectedSHA256: String) throws {
        guard try Self.sha256(of: fileURL) == expectedSHA256 else {
            throw GigaAMError.checksumMismatch(fileURL.lastPathComponent)
        }
    }
}

public enum GigaAMModelCatalog {
    private static let e2eVocabularyHash = "142de7570b3de5b3035ce111a89c228e80e6085273731d944093ddf24fa539cd"

    /// Compact public export of ai-sage/GigaAM-v3, pinned to immutable repository content.
    /// It uses the same native frontend and CTC vocabulary, without the private EOU head.
    public static let compactONNXModel = GigaAMModelDescriptor(
        id: "gigaam-v3-e2e-ctc-int8",
        modelFile: "v3_e2e_ctc.int8.onnx",
        modelSHA256: "2e3fcb7a7b66030336fd10c2fcfb033bd1dc7e1bf238fe5cfd83b1d0cfc9d28e",
        vocabularyFile: "v3_e2e_ctc_vocab.txt",
        vocabularySHA256: e2eVocabularyHash,
        endOfUtteranceThreshold: nil,
        downloadBaseURL: URL(string: "https://huggingface.co/istupakov/gigaam-v3-onnx/resolve/322c3b29492673eb7d0b434bfa9dfb8653e34d02/")!,
        modelByteCount: 224_893_347,
        vocabularyByteCount: 2_007
    )

    /// Ready-made public Core ML package. The app downloads these exact bytes.
    public static let downloadableModel = GigaAMModelDescriptor(
        id: "gigaam-v3-e2e-ctc-coreml",
        modelFile: "gigaam_v3_e2e.mlpackage",
        modelSHA256: "8e0c43329503b3b2fc41f6e594f44d7b35acdd0bd61a91bf5741557d716be957",
        vocabularyFile: "gigaam-vocab.txt",
        vocabularySHA256: "a5aac1a2913150f1e5400cfca1765406c01d0792c5842e3a1deea85bc8dfbc09",
        endOfUtteranceThreshold: nil,
        downloadBaseURL: URL(string: "https://huggingface.co/inhum/gigaam-v3-coreml/resolve/43dc96918bc232deafa7b7d0600fb499806f7ac1/")!,
        modelByteCount: 442_426_545,
        vocabularyByteCount: 1_083,
        format: .coreML(.init(featureFrameCount: 2_499, windowFile: "gigaam-window.f32", melFilterbankFile: "gigaam-melfb.f32")),
        artifacts: [
            .init(path: "gigaam-melfb.f32", sha256: "e87260b36046d4384ea4e7ca82ff7e5a82b4f85381c34b16ccfa79c0803ffba2", byteCount: 41_216),
            .init(path: "gigaam-vocab.txt", sha256: "a5aac1a2913150f1e5400cfca1765406c01d0792c5842e3a1deea85bc8dfbc09", byteCount: 1_083),
            .init(path: "gigaam-window.f32", sha256: "834a6744851a775dbb1831e9e17f0f702599b4d52c1d97d7638b3f170824419f", byteCount: 1_280),
            .init(path: "gigaam_v3_e2e.mlpackage/Data/com.apple.CoreML/model.mlmodel", sha256: "8e0c43329503b3b2fc41f6e594f44d7b35acdd0bd61a91bf5741557d716be957", byteCount: 469_254),
            .init(path: "gigaam_v3_e2e.mlpackage/Data/com.apple.CoreML/weights/weight.bin", sha256: "706153a1e14e2b26f328f394f3eded2689865eaf2d653c021006a4f3ab3a0ec6", byteCount: 441_914_178),
            .init(path: "gigaam_v3_e2e.mlpackage/Manifest.json", sha256: "cd7840db2ffe56befcbb3e324dc661846ac5706c4a8c3725be56ff67b37e2eb2", byteCount: 617),
        ]
    )

    /// Imported and pinned ONNX jobs retain their original content identity.
    public static let models: [GigaAMModelDescriptor] = [
        GigaAMModelDescriptor(
            id: "gigaam-v3-e2e-eou-v5",
            modelFile: "v3_e2e_ctc_eou_v5.fp16.onnx",
            modelSHA256: "631fe5205952b521ec7d95524b0713748fc73a24725ef1c1cf2c97a7ef862c22",
            vocabularyFile: "v3_e2e_ctc_vocab.txt",
            vocabularySHA256: e2eVocabularyHash,
            endOfUtteranceThreshold: 0.48
        ),
        GigaAMModelDescriptor(
            id: "gigaam-v3-ctc-eou-v3",
            modelFile: "v3_ctc_eou_v3.fp16.onnx",
            modelSHA256: "a2e161da259c70b4734a3ac1056cb745199bf138100e51576caf665de6aba761",
            vocabularyFile: nil,
            vocabularySHA256: nil,
            endOfUtteranceThreshold: 0.44
        ),
        GigaAMModelDescriptor(
            id: "gigaam-v3-ctc-eou-v1",
            modelFile: "v3_ctc_eou.fp16.onnx",
            modelSHA256: "ebcb59f83869697686c7d50f795612e5497f43eaf90d47c646e466c3afcc22d8",
            vocabularyFile: nil,
            vocabularySHA256: nil,
            endOfUtteranceThreshold: 0.5
        ),
        compactONNXModel,
        downloadableModel,
    ]

    public static func discover(in directory: URL) -> (descriptor: GigaAMModelDescriptor, directory: URL)? {
        for descriptor in self.models {
            for candidate in [directory, directory.appendingPathComponent(descriptor.id, isDirectory: true)] {
                if descriptor.filesExist(in: candidate) { return (descriptor, candidate) }
            }
        }
        return nil
    }
}
