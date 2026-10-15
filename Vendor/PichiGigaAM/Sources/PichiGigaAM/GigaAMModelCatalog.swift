import CryptoKit
import Foundation

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

    public init(id: String, modelFile: String, modelSHA256: String, vocabularyFile: String?, vocabularySHA256: String?, endOfUtteranceThreshold: Float?,
                downloadBaseURL: URL? = nil, modelByteCount: Int64? = nil, vocabularyByteCount: Int64? = nil) {
        self.id = id
        self.modelFile = modelFile
        self.modelSHA256 = modelSHA256
        self.vocabularyFile = vocabularyFile
        self.vocabularySHA256 = vocabularySHA256
        self.endOfUtteranceThreshold = endOfUtteranceThreshold
        self.downloadBaseURL = downloadBaseURL
        self.modelByteCount = modelByteCount
        self.vocabularyByteCount = vocabularyByteCount
    }

    /// Stable content identity for resumable jobs, independent of local paths.
    public var fingerprint: String {
        "gigaam-native-v1/\(self.id)/\(self.modelSHA256)/\(self.vocabularySHA256 ?? "russian-characters-v1")"
    }

    public func filesExist(in directory: URL) -> Bool {
        let names = [self.modelFile] + [self.vocabularyFile].compactMap { $0 }
        return names.allSatisfy { name in
            let url = directory.appendingPathComponent(name)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
    }

    public func verify(in directory: URL) throws {
        try Self.verify(directory.appendingPathComponent(self.modelFile), expectedSHA256: self.modelSHA256)
        if let file = self.vocabularyFile, let hash = self.vocabularySHA256 {
            try Self.verify(directory.appendingPathComponent(file), expectedSHA256: hash)
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
    public static let downloadableModel = GigaAMModelDescriptor(
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

    /// Prefer the latest optimized e2e export, then the compatible char exports.
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
