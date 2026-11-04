import Foundation

/// One already-computed feature window. Offsets describe the original recording until resolved.
/// The provider owns the extractor recipe; shared evidence transport never interprets its model.
nonisolated struct DictionaryLearningFeatureFrames: Equatable, Sendable {
    let extractorVersion: String
    let frames: DictionaryAudioInspection.Frames
}

/// Alignment always describes the original ASR output, before dictionary rules or AI rewriting.
nonisolated struct DictionaryLearningAlignment: Sendable {
    let modelKey: String
    let words: [ASRWordTiming]
    var acousticOutput: String? = nil
    var acousticEvidence: [DictionaryAcousticEvidence] = []
    /// New spellings that voice matching replaced in this dictation, learned unless the user undoes them.
    var voiceSpellings: [DictionaryVoiceSpelling] = []
    var featureFrames: [DictionaryLearningFeatureFrames] = []
}

nonisolated struct DictionaryVoiceSpelling: Equatable, Sendable {
    let entryID: UUID
    let label: String
    let spelling: String
}

/// Short-lived ownership of original PCM, independent from the consume-once history snapshot.
nonisolated struct DictionaryLearningRecording: Sendable {
    static let sampleRate = 16_000
    static let maximumSamples = sampleRate * 60 * 15
    static let lifetime: TimeInterval = 120
    static let maximumFeatureBytes = 128 * 1024 * 1024
    static let maximumFeatureChunks = 256

    let id: UUID
    let expiresAt: Date
    let alignment: DictionaryLearningAlignment
    let samples: [Float]

    init?(
        id: UUID = UUID(),
        alignment: DictionaryLearningAlignment,
        samples: [Float],
        retainAudio: Bool = true,
        now: Date = Date()
    ) {
        guard !samples.isEmpty, samples.count <= Self.maximumSamples,
              !alignment.words.isEmpty, !alignment.modelKey.isEmpty
        else { return nil }
        self.id = id
        self.expiresAt = now.addingTimeInterval(Self.lifetime)
        var retainedAlignment = alignment
        retainedAlignment.featureFrames = retainAudio
            ? Self.retainedFeatureFrames(alignment.featureFrames, sampleCount: samples.count)
            : []
        self.alignment = retainedAlignment
        // Negative confirmation needs only accepted-word features, not the full recording PCM.
        self.samples = retainAudio ? samples : []
    }

    /// Invalid optional features never discard a valid correction recording or its negative evidence.
    /// Check the full byte budget before inspecting values, so oversized inputs fail cheaply.
    private static func retainedFeatureFrames(_ features: [DictionaryLearningFeatureFrames], sampleCount: Int) -> [DictionaryLearningFeatureFrames] {
        guard !features.isEmpty, features.count <= Self.maximumFeatureChunks,
              let first = features.first,
              !first.extractorVersion.isEmpty, first.extractorVersion.utf8.count <= 128,
              first.extractorVersion.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
              }), (1...2048).contains(first.frames.hiddenSize),
              DictionaryAudioInspection.Frames.maximumCount(frameDuration: first.frames.frameDuration) != nil
        else { return [] }
        let duration = Double(sampleCount) / Double(Self.sampleRate)
        var remainingBytes = Self.maximumFeatureBytes
        var previousOffset = 0.0
        for feature in features {
            let frames = feature.frames
            guard feature.extractorVersion == first.extractorVersion,
                  frames.hiddenSize == first.frames.hiddenSize, frames.frameDuration == first.frames.frameDuration,
                  frames.offset.isFinite, frames.offset >= 0, frames.offset >= previousOffset,
                  frames.offset < duration, !frames.values.isEmpty,
                  frames.values.count % frames.hiddenSize == 0,
                  frames.values.count <= remainingBytes / MemoryLayout<Float>.size
            else { return [] }
            // An encoder may emit one final partial frame, but not features for arbitrary padding.
            let lastFrameStart = frames.offset + Double(frames.count - 1) * frames.frameDuration
            guard lastFrameStart < duration + 1e-9 else { return [] }
            remainingBytes -= frames.values.count * MemoryLayout<Float>.size
            previousOffset = frames.offset
        }
        guard features.allSatisfy({ $0.frames.values.allSatisfy(\.isFinite) }) else { return [] }
        return features
    }
}

/// Immutable link from an observed text edit to the recording delivered to that field.
nonisolated struct DictionaryLearningCorrectionContext: Sendable {
    let recording: DictionaryLearningRecording
    let deliveredTextBeforeEdit: String
    let selectedUTF16Range: NSRange
}

/// The bounded original context and exact focal occurrence used for one pronunciation example.
nonisolated struct DictionaryLearningAudioEvidence: Sendable {
    let recordingID: UUID
    let modelKey: String
    let observedText: String
    let sourceWordRange: Range<Int>
    let sourceSampleRange: Range<Int>
    let focalSampleRange: Range<Int>
    let samples: [Float]
    /// At most one bounded feature window; its offset is relative to `samples`, not the recording.
    var featureFrames: [DictionaryLearningFeatureFrames] = []
}

nonisolated enum DictionaryLearningAlignmentError: Error, Equatable {
    case expired
    case invalidSelection
    case ambiguousSource
    case invalidTiming
}

/// Resolves a selected correction back to the spoken occurrence; never selects a word by spelling alone.
nonisolated enum DictionaryLearningAlignmentResolver {
    private struct Token {
        let text: String
        let range: NSRange
    }

    private static let tokenizer = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
    private static let contextTokenLimit = 8
    private static let maximumContextSamples = 238_080

    static func resolve(
        recording: DictionaryLearningRecording,
        deliveredTextBeforeEdit: String,
        selectedUTF16Range: NSRange,
        observedText: String,
        now: Date = Date()
    ) throws -> DictionaryLearningAudioEvidence {
        guard now < recording.expiresAt else { throw DictionaryLearningAlignmentError.expired }
        let length = (deliveredTextBeforeEdit as NSString).length
        guard selectedUTF16Range.location >= 0, selectedUTF16Range.location <= length,
              selectedUTF16Range.length > 0, selectedUTF16Range.length <= length - selectedUTF16Range.location
        else { throw DictionaryLearningAlignmentError.invalidSelection }
        let delivered = self.tokens(in: deliveredTextBeforeEdit)
        let selected = delivered.indices.filter {
            NSIntersectionRange(delivered[$0].range, selectedUTF16Range).length > 0
        }
        guard let first = selected.first, let last = selected.last,
              selected.map({ delivered[$0].text }) == self.tokens(in: observedText).map(\.text)
        else { throw DictionaryLearningAlignmentError.invalidSelection }

        var rawTokens: [String] = []
        var wordIndices: [Int] = []
        for (index, word) in recording.alignment.words.enumerated() {
            let parts = self.tokens(in: word.text)
            rawTokens.append(contentsOf: parts.map(\.text))
            wordIndices.append(contentsOf: repeatElement(
                index,
                count: parts.count
            ))
        }
        let sourceTokens = try self.sourceRange(
            raw: rawTokens,
            delivered: delivered.map(\.text),
            selected: first..<(last + 1)
        )
        let wordRange = wordIndices[sourceTokens.lowerBound]..<(wordIndices[sourceTokens.upperBound - 1] + 1)
        return try self.makeEvidence(
            recording: recording,
            wordRange: wordRange,
            observedText: observedText
        )
    }

    private static func tokens(in text: String) -> [Token] {
        guard let tokenizer else { return [] }
        let source = text as NSString
        return tokenizer.matches(
            in: text,
            range: NSRange(
                location: 0,
                length: source.length
            )
        ).map {
            Token(
                text: source.substring(with: $0.range).lowercased(),
                range: $0.range
            )
        }
    }

    private static func sourceRange(
        raw: [String],
        delivered: [String],
        selected: Range<Int>
    ) throws -> Range<Int> {
        // Unchanged lexical content gives an exact ordinal mapping, including repeated words.
        if raw == delivered { return selected }
        let target = Array(delivered[selected])
        var best: Range<Int>?
        var bestScore = 0
        var tied = false
        for start in 0..<(max(0, raw.count - target.count + 1)) {
            let range = start..<(start + target.count)
            guard raw[range].elementsEqual(target) else { continue }
            let left = self.contextMatches(
                raw: raw,
                delivered: delivered,
                rawPosition: start - 1,
                deliveredPosition: selected.lowerBound - 1,
                direction: -1
            )
            let right = self.contextMatches(
                raw: raw,
                delivered: delivered,
                rawPosition: range.upperBound,
                deliveredPosition: selected.upperBound,
                direction: 1
            )
            // Rewritten output needs matching anchors around the selected phrase. A lone spelling is insufficient.
            let hasLeftBoundary = selected.lowerBound == 0 && range.lowerBound == 0
            let hasRightBoundary = selected.upperBound == delivered.count && range.upperBound == raw.count
            guard left > 0 || hasLeftBoundary, right > 0 || hasRightBoundary, left + right >= 2 else { continue }
            let score = left + right
            if score > bestScore {
                best = range
                bestScore = score
                tied = false
            } else if score == bestScore {
                tied = true
            }
        }
        guard !tied else { throw DictionaryLearningAlignmentError.ambiguousSource }
        // A new decode can change the selected words. Only use the interval
        // between matching context anchors (or a real utterance boundary). Every
        // qualifying interval must identify the same occurrence; never infer time
        // from text offsets or pick the highest scoring ambiguous interval.
        // Exact spelling is not precedence: another occurrence may have changed
        // spelling during re-decoding while keeping the selected context anchors.
        var anchored: Range<Int>? = best
        guard !raw.isEmpty else { throw DictionaryLearningAlignmentError.ambiguousSource }
        for start in raw.indices {
            let left = self.contextMatches(raw: raw, delivered: delivered, rawPosition: start - 1,
                                           deliveredPosition: selected.lowerBound - 1, direction: -1)
            guard left > 0 || (selected.lowerBound == 0 && start == 0) else { continue }
            for end in (start + 1)...min(raw.count, start + contextTokenLimit) {
                let right = self.contextMatches(raw: raw, delivered: delivered, rawPosition: end,
                                                deliveredPosition: selected.upperBound, direction: 1)
                guard right > 0 || (selected.upperBound == delivered.count && end == raw.count),
                      left + right >= 2 else { continue }
                let candidate = start..<end
                if let anchored, anchored != candidate { throw DictionaryLearningAlignmentError.ambiguousSource }
                anchored = candidate
            }
        }
        guard let anchored else { throw DictionaryLearningAlignmentError.ambiguousSource }
        return anchored
    }

    private static func contextMatches(
        raw: [String],
        delivered: [String],
        rawPosition: Int,
        deliveredPosition: Int,
        direction: Int
    ) -> Int {
        var count = 0
        var source = rawPosition
        var destination = deliveredPosition
        while count < Self.contextTokenLimit, raw.indices.contains(source), delivered.indices.contains(destination),
              raw[source] == delivered[destination]
        {
            count += 1
            source += direction
            destination += direction
        }
        return count
    }

    private static func makeEvidence(
        recording: DictionaryLearningRecording,
        wordRange: Range<Int>,
        observedText: String
    ) throws -> DictionaryLearningAudioEvidence {
        let words = recording.alignment.words
        let selected = words[wordRange]
        let duration = Double(recording.samples.count) / Double(DictionaryLearningRecording.sampleRate)
        guard selected.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }),
              zip(selected, selected.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }),
              let first = selected.first, let last = selected.last,
              first.start < duration, last.end <= duration + 0.08
        else { throw DictionaryLearningAlignmentError.invalidTiming }
        let start = Int((first.start * Double(DictionaryLearningRecording.sampleRate)).rounded(.down))
        let end = min(recording.samples.count, Int((last.end * Double(DictionaryLearningRecording.sampleRate)).rounded(.up)))
        guard end > start else { throw DictionaryLearningAlignmentError.invalidTiming }
        // Preserve the legacy 80 ms PCM context grid; each feature window keeps its own origin.
        let contextStart = max(0, start - 2 * DictionaryLearningRecording.sampleRate) / 1280 * 1280
        let contextEnd = min(recording.samples.count, contextStart + Self.maximumContextSamples)
        guard end <= contextEnd else { throw DictionaryLearningAlignmentError.invalidTiming }
        return DictionaryLearningAudioEvidence(
            recordingID: recording.id,
            modelKey: recording.alignment.modelKey,
            observedText: observedText,
            sourceWordRange: wordRange,
            sourceSampleRange: contextStart..<contextEnd,
            focalSampleRange: (start - contextStart)..<(end - contextStart),
            samples: Array(recording.samples[contextStart..<contextEnd]),
            featureFrames: self.featureFrames(
                recording: recording, focalSamples: start..<end, contextSamples: contextStart..<contextEnd
            )
        )
    }

    private static func featureFrames(
        recording: DictionaryLearningRecording,
        focalSamples: Range<Int>,
        contextSamples: Range<Int>
    ) -> [DictionaryLearningFeatureFrames] {
        let sampleRate = Double(DictionaryLearningRecording.sampleRate)
        let focalStart = Double(focalSamples.lowerBound) / sampleRate
        let focalEnd = Double(focalSamples.upperBound) / sampleRate
        let contextStart = Double(contextSamples.lowerBound) / sampleRate
        let contextEnd = Double(contextSamples.upperBound) / sampleRate
        var best: (feature: DictionaryLearningFeatureFrames, balanced: Double, total: Double)?
        for feature in recording.alignment.featureFrames {
            let frames = feature.frames
            let end = frames.offset + Double(frames.count) * frames.frameDuration
            // Never stitch separately encoded windows or substitute another occurrence by spelling.
            guard frames.offset <= focalStart + 1e-9, end >= focalEnd - 1e-9 else { continue }
            let left = max(0, focalStart - max(frames.offset, contextStart))
            let right = max(0, min(end, contextEnd) - focalEnd)
            let balanced = min(left, right), total = left + right
            if let prior = best {
                if balanced < prior.balanced - 1e-9 { continue }
                if abs(balanced - prior.balanced) <= 1e-9 && total <= prior.total + 1e-9 { continue }
            }
            best = (feature, balanced, total)
        }
        guard let best else { return [] }
        let source = best.feature.frames
        let lower = max(0, Int(floor((focalStart - source.offset) / source.frameDuration + 1e-8)))
        let upper = min(source.count, Int(ceil((focalEnd - source.offset) / source.frameDuration - 1e-8)))
        let offset = source.offset + Double(lower) * source.frameDuration - contextStart
        guard lower < upper, offset >= -1e-9,
              let maximumCount = DictionaryAudioInspection.Frames.maximumCount(frameDuration: source.frameDuration),
              upper - lower <= maximumCount,
              upper - lower <= DictionaryAudioInspection.Frames.maximumValues / source.hiddenSize
        else { return [] }
        return [.init(
            extractorVersion: best.feature.extractorVersion,
            frames: .init(offset: max(0, offset), frameDuration: source.frameDuration, hiddenSize: source.hiddenSize,
                          values: Array(source.values[(lower * source.hiddenSize)..<(upper * source.hiddenSize)]))
        )]
    }
}
