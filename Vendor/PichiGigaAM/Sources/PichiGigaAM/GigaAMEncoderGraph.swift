import CryptoKit
import Foundation

/// Exposes the untransposed output of the last encoder layer norm in the pinned
/// Core ML program. Both outputs come from one prediction with the original weights.
enum GigaAMEncoderGraph {
    static let outputName = "layer_norm_95_cast_fp16"
    static let specSHA256 = "8702b052a3d9821b28c7f8cd6732b09da5d1e6741dcb1977016a58ce39324ec1"

    static func materialize(from package: URL, into destination: URL) throws {
        let path = "Data/com.apple.CoreML/model.mlmodel"
        let original = try Data(contentsOf: package.appendingPathComponent(path))
        guard digest(original) == GigaAMModelCatalog.coreMLModel.modelSHA256 else {
            throw GigaAMError.checksumMismatch(path)
        }

        let exposed = try exposingEncoder(in: original)
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
