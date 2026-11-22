import CryptoKit
import Foundation

/// Rebuilds the six-second graph from the pinned public package. The bundled recipe
/// describes protobuf structure and byte ranges; learned tensors stay in the downloaded package.
enum GigaAMShortGraph {
    static let frameCount = 599
    static let specByteCount = 491_354
    static let specSHA256 = "86c4293e860749138794edabb426fa6963d138a46afa42a162e72dbc3fa194bc"

    /// The caller verifies the model catalog descriptor and owns the staging directory.
    static func materialize(from verifiedLongPackage: URL, into destination: URL) throws {
        let spec = "Data/com.apple.CoreML/model.mlmodel"
        let weights = "Data/com.apple.CoreML/weights/weight.bin"
        let original = try Data(contentsOf: verifiedLongPackage.appendingPathComponent(spec))
        guard let url = Bundle.module.url(forResource: "gigaam-599", withExtension: "recipe") else {
            throw GigaAMError.incompatibleModel
        }
        let handle = try FileHandle(forReadingFrom: verifiedLongPackage.appendingPathComponent(weights))
        defer { try? handle.close() }
        let derivative = try reconstruct(recipe: Data(contentsOf: url), original: original, expectedSize: specByteCount) { offset, count in
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count) ?? Data()
        }
        guard SHA256.hash(data: derivative).map({ String(format: "%02x", $0) }).joined() == specSHA256 else {
            throw GigaAMError.checksumMismatch(spec)
        }
        try self.stage(specification: derivative, from: verifiedLongPackage, into: destination)
    }

    static func stage(specification: Data, from package: URL, into destination: URL) throws {
        let manager = FileManager.default
        let spec = "Data/com.apple.CoreML/model.mlmodel"
        let weights = "Data/com.apple.CoreML/weights/weight.bin"
        let toWeights = destination.appendingPathComponent(weights)
        try manager.createDirectory(at: toWeights.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.copyItem(at: package.appendingPathComponent("Manifest.json"),
                             to: destination.appendingPathComponent("Manifest.json"))
        // Foundation uses clonefile where possible; this also works across volumes.
        try manager.copyItem(at: package.appendingPathComponent(weights), to: toWeights)
        try specification.write(to: destination.appendingPathComponent(spec), options: .atomic)
    }

    /// Records are an opcode (copy spec, literal, copy positional table) followed by
    /// unsigned base-128 integers. Nothing in this format names paths or executes code.
    static func reconstruct(recipe: Data, original: Data, expectedSize: Int,
                            readWeights: (Int, Int) throws -> Data) throws -> Data {
        guard (1...specByteCount).contains(expectedSize) else { throw GigaAMError.incompatibleModel }
        var cursor = 0
        func integer() throws -> Int {
            var value = 0
            for shift in stride(from: 0, through: 28, by: 7) {
                guard cursor < recipe.count else { throw GigaAMError.incompatibleModel }
                let byte = recipe[cursor]
                cursor += 1
                value |= Int(byte & 0x7f) << shift
                if byte < 128 { return value }
            }
            throw GigaAMError.incompatibleModel
        }
        var output = Data()
        output.reserveCapacity(expectedSize)
        while cursor < recipe.count {
            let operation = recipe[cursor]
            cursor += 1
            let offset = operation == 1 ? 0 : try integer()
            let size = try integer()
            guard size > 0, size <= expectedSize - output.count else { throw GigaAMError.incompatibleModel }
            switch operation {
            case 0:
                guard offset <= original.count, size <= original.count - offset else { throw GigaAMError.incompatibleModel }
                output.append(original[offset..<(offset + size)])
            case 1:
                guard size <= recipe.count - cursor else { throw GigaAMError.incompatibleModel }
                output.append(recipe[cursor..<(cursor + size)])
                cursor += size
            case 2:
                let table = try readWeights(offset, size)
                guard table.count == size else { throw GigaAMError.incompatibleModel }
                output.append(table)
            default: throw GigaAMError.incompatibleModel
            }
        }
        guard output.count == expectedSize else { throw GigaAMError.incompatibleModel }
        return output
    }
}
