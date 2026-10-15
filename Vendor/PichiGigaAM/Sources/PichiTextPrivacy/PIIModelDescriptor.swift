import Foundation
import CryptoKit

public enum TextPrivacyError: Error, Equatable, Sendable {
    case notPrepared
    case incompatibleModel
    case invalidOutput
    case invalidSpan
    case inputTooLong
    case checksumMismatch(String)
}

public struct PIIModelArtifact: Sendable, Equatable {
    public let filename: String
    public let remotePath: String
    public let byteCount: Int64
    public let sha256: String
}

/// A frozen, public artifact selection. The original Pichi Transcribe tiny-news
/// fallback is used; its private PII fine-tune has no distribution manifest.
public struct PIIModelDescriptor: Sendable, Equatable {
    public let id: String
    public let revision: String
    public let downloadBaseURL: URL
    public let artifacts: [PIIModelArtifact]
    public let license: String
    public var byteCount: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }
    public var fingerprint: String { "text-privacy-wordpiece-v1/\(id)/\(revision)" }

    public static let russianTiny = PIIModelDescriptor(
        id: "rubert-tiny-news-int8", revision: "930eccc0b433dae84126a5837e9a169f0a4639e3",
        downloadBaseURL: URL(string: "https://huggingface.co/onnx-community/ner-rubert-tiny-news-ONNX/resolve/930eccc0b433dae84126a5837e9a169f0a4639e3/")!,
        artifacts: [
            .init(filename: "model_int8.onnx", remotePath: "onnx/model_int8.onnx", byteCount: 29_252_719, sha256: "94cebd8ab912cf48c391530131b31445fdbad9bf85d6549e9573f831acc3e8cf"),
            .init(filename: "vocab.txt", remotePath: "vocab.txt", byteCount: 1_080_667, sha256: "f056a69b097422652053bf87565c35543e5d81540ca4b7dddd28de4157a969e0"),
            .init(filename: "config.json", remotePath: "config.json", byteCount: 1_083, sha256: "a7e67406eca35258f8f566663c38ec5a543d4a467b57af28b83a6ab9c01c46ce"),
        ], license: "MIT"
    )

    public func verify(in directory: URL) throws {
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw TextPrivacyError.incompatibleModel
        }
        for artifact in artifacts {
            try Task.checkCancellation()
            let file = directory.appendingPathComponent(artifact.filename)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  Int64(values.fileSize ?? -1) == artifact.byteCount,
                  try Self.sha256(of: file) == artifact.sha256 else {
                throw TextPrivacyError.checksumMismatch(artifact.filename)
            }
        }
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while try autoreleasepool(invoking: { () throws -> Bool in
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1_048_576), !data.isEmpty else { return false }
            hash.update(data: data)
            return true
        }) {}
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
