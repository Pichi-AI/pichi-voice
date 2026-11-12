import Foundation

nonisolated struct DictionaryMatchFrames: Codable, Equatable, Sendable {
    let hiddenSize: Int
    let values: [Float]
    var count: Int { self.hiddenSize > 0 ? self.values.count / self.hiddenSize : 0 }
    var isValid: Bool {
        (1...1024).contains(self.hiddenSize) && (1...192).contains(self.count)
            && self.values.count == self.count * self.hiddenSize && self.values.allSatisfy(\.isFinite)
    }

    func normalized() -> Self {
        guard self.isValid else { return self }
        var result = self.values
        for f in 0..<self.count {
            let start = f * self.hiddenSize
            let length = sqrt(values[start..<(start + self.hiddenSize)].reduce(Float(0)) { $0 + $1 * $1 })
            for d in 0..<self.hiddenSize {
                result[start + d] /= max(length, 1e-12)
            }
        }
        return Self(hiddenSize: self.hiddenSize, values: result)
    }
}

nonisolated struct DictionaryAcousticEvidence: Codable, Equatable, Sendable {
    let id: UUID
    let entryID: UUID
    let label: String
    let profileKey: String
    let modelKey: String
    let sourceWordRange: Range<Int>
    let frames: DictionaryMatchFrames
    var matchFrameRange: Range<Int>? = nil

    func aligned(to wordRange: Range<Int>, label: String) -> Self {
        Self(id: self.id, entryID: self.entryID, label: label, profileKey: self.profileKey, modelKey: self.modelKey, sourceWordRange: wordRange, frames: self.frames, matchFrameRange: self.matchFrameRange)
    }
}

