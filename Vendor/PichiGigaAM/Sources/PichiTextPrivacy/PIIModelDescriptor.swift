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

public enum PIIInferenceFormat: String, Sendable {
    case tokenBIO
    case independentBIO
}

/// A frozen, public artifact selection, including its native inference contract.
public struct PIIModelDescriptor: Sendable, Equatable {
    public let id: String
    public let revision: String
    public let downloadBaseURL: URL
    public let artifacts: [PIIModelArtifact]
    public let license: String
    public let inferenceFormat: PIIInferenceFormat
    public var byteCount: Int64 { artifacts.reduce(0) { $0 + $1.byteCount } }
    public var fingerprint: String { "text-privacy-wordpiece-v2/\(inferenceFormat.rawValue)/\(id)/\(revision)" }

    public static let russianTiny = PIIModelDescriptor(
        id: "rubert-tiny-news-int8", revision: "930eccc0b433dae84126a5837e9a169f0a4639e3",
        downloadBaseURL: URL(string: "https://huggingface.co/onnx-community/ner-rubert-tiny-news-ONNX/resolve/930eccc0b433dae84126a5837e9a169f0a4639e3/")!,
        artifacts: [
            .init(filename: "model_int8.onnx", remotePath: "onnx/model_int8.onnx", byteCount: 29_252_719, sha256: "94cebd8ab912cf48c391530131b31445fdbad9bf85d6549e9573f831acc3e8cf"),
            .init(filename: "vocab.txt", remotePath: "vocab.txt", byteCount: 1_080_667, sha256: "f056a69b097422652053bf87565c35543e5d81540ca4b7dddd28de4157a969e0"),
            .init(filename: "config.json", remotePath: "config.json", byteCount: 1_083, sha256: "a7e67406eca35258f8f566663c38ec5a543d4a467b57af28b83a6ab9c01c46ce"),
        ], license: "MIT", inferenceFormat: .tokenBIO
    )

    // Author release and exact weights evaluated locally. No repository Python is
    // executed; the native adapter consumes only these digest-verified assets.
    public static let russianA1 = PIIModelDescriptor(
        id: "ru-pii-ner-a1-int8", revision: "67a6270bf24661bf62ea0e93582d02edcc8ee517",
        downloadBaseURL: URL(string: "https://huggingface.co/Powpowpow23/ru-pii-ner-a1/resolve/67a6270bf24661bf62ea0e93582d02edcc8ee517/")!,
        artifacts: [
            .init(filename: "model_int8.onnx", remotePath: "onnx/model.int8.onnx", byteCount: 99_291_021, sha256: "0884223eaec3ceb4be4b196df0aafd641e23a728996c885f45820ff799262185"),
            .init(filename: "tokenizer.json", remotePath: "tokenizer.json", byteCount: 386_758, sha256: "faf2155893824596549e4081c7c287e5b7df23479778548ccf9333c6a97ea36a"),
            .init(filename: "model.json", remotePath: "model.json", byteCount: 5_502, sha256: "fcbddcce66276b51cb7590574c8231f47d73a590199a213446c996a51b8e643b"),
            .init(filename: "inference_config.json", remotePath: "inference_config.json", byteCount: 1_165, sha256: "a87282d358803255e9019ac5b9b8fd4a04f8bc09cf44dc56a57a32e93976f3d0"),
        ], license: "Apache-2.0", inferenceFormat: .independentBIO
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
