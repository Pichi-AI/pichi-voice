import Foundation

/// Token pieces may split a scalar. Only complete, valid UTF-8 reaches clients.
struct IncrementalUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func append(_ bytes: [UInt8]) throws -> String {
        let input = self.pending + bytes
        var position = 0
        while position < input.count {
            let first = input[position]
            let length: Int
            switch first {
            case 0x00...0x7F: length = 1
            case 0xC2...0xDF: length = 2
            case 0xE0...0xEF: length = 3
            case 0xF0...0xF4: length = 4
            default: throw NativeTextInferenceError.invalidUTF8
            }
            let available = min(length, input.count - position)
            if available > 1 {
                for offset in 1..<available {
                    guard (0x80...0xBF).contains(input[position + offset]) else {
                        throw NativeTextInferenceError.invalidUTF8
                    }
                }
                let second = input[position + 1]
                guard !(first == 0xE0 && second < 0xA0),
                      !(first == 0xED && second >= 0xA0),
                      !(first == 0xF0 && second < 0x90),
                      !(first == 0xF4 && second >= 0x90) else {
                    throw NativeTextInferenceError.invalidUTF8
                }
            }
            if available < length { break }
            position += length
        }
        self.pending = Array(input[position...])
        guard let text = String(bytes: input.prefix(position), encoding: .utf8) else {
            throw NativeTextInferenceError.invalidUTF8
        }
        return text
    }

    func finish() throws {
        guard self.pending.isEmpty else { throw NativeTextInferenceError.invalidUTF8 }
    }
}
