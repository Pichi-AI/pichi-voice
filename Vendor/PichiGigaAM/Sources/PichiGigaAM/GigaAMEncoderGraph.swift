import CryptoKit
import Foundation

/// Exposes the untransposed output of the last encoder layer norm in the pinned
/// Core ML program. Both outputs come from one prediction with the original weights.
enum GigaAMEncoderGraph {
    static let outputName = "layer_norm_95_cast_fp16"
    static let specSHA256 = "58d24a9c366146884d2cc777ad20c505ab11b46971c3db32597c89ef6b201824"

    static func materialize(from package: URL, into destination: URL) throws {
        let path = "Data/com.apple.CoreML/model.mlmodel"
        let original = try Data(contentsOf: package.appendingPathComponent(path))
        guard digest(original) == GigaAMModelCatalog.coreMLModel.modelSHA256 else {
            throw GigaAMError.checksumMismatch(path)
        }

        // The public fixed-shape export left padding visible to self-attention.
        // Restore the key mask used by the variable-length encoder before exposing its features.
        let masked = try GigaAMShortGraph.reconstruct(resource: "gigaam-attention",
            original: original, expectedSize: 472_498) { _, _ in throw GigaAMError.incompatibleModel }
        let exposed = try exposingEncoder(in: masked)
        guard digest(exposed) == specSHA256 else { throw GigaAMError.checksumMismatch(path) }
        try GigaAMShortGraph.stage(specification: exposed, from: package, into: destination)
    }

    static func exposingEncoder(in original: Data) throws -> Data {
        let name = Data(outputName.utf8)
        // FeatureDescription.type.multiArrayType: shape [1,625,768], dataType FLOAT16.
        let shape = [1, 625, GigaAMEncoderFeatures.dimension].reduce(into: Data()) { $0.append(varint($1)) }
        let tensor = field(1, shape) + varint(2 << 3) + varint(65_552)
        let feature = field(1, name) + field(3, field(5, tensor))
        let described = try append(field(10, feature), to: original, at: [2])
        // Model.mlProgram -> functions["main"] -> block_specializations -> block.outputs.
        return try append(field(2, name), to: described, at: [502, 2, 2, 3, 2])
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func varint(_ number: Int) -> Data {
        var value = number
        var result = Data()
        while value >= 128 {
            result.append(UInt8(value & 127) | 128)
            value >>= 7
        }
        result.append(UInt8(value))
        return result
    }

    private static func field(_ tag: Int, _ bytes: Data) -> Data {
        varint(tag << 3 | 2) + varint(bytes.count) + bytes
    }

    /// Edit only enclosing length-delimited fields. All other original bytes,
    /// including map ordering and weight references, keep their exact values.
    private static func append(_ suffix: Data, to message: Data, at path: ArraySlice<Int>) throws -> Data {
        guard let next = path.first else { return message + suffix }
        var cursor = 0
        func integer() throws -> Int {
            var number = 0
            for shift in stride(from: 0, through: 28, by: 7) {
                guard cursor < message.count else { throw GigaAMError.incompatibleModel }
                let byte = message[cursor]
                cursor += 1
                number |= Int(byte & 127) << shift
                if byte < 128 { return number }
            }
            throw GigaAMError.incompatibleModel
        }
        while cursor < message.count {
            let key = try integer()
            let lengthOffset = cursor
            let value = try integer()
            if key & 7 == 0 { continue }
            guard key & 7 == 2, value <= message.count - cursor else { throw GigaAMError.incompatibleModel }
            let end = cursor + value
            if key >> 3 == next {
                let updated = try append(suffix, to: message.subdata(in: cursor..<end), at: path.dropFirst())
                var result = message
                result.replaceSubrange(lengthOffset..<end, with: varint(updated.count) + updated)
                return result
            }
            cursor = end
        }
        throw GigaAMError.incompatibleModel
    }
}
