import Foundation
import PichiGigaAM

/// Corrects already captured, fingerprint-bound learned encoder features. Capture,
/// models, private persistence and admission stay with their existing owners.
nonisolated enum GigaAMEncoderDictionary {
    static let maximumTerms = 128
    static let maximumReferenceBytes = 32 * 1_024 * 1_024

    struct Term: Sendable {
        let entryID: UUID
        let label: String
        let modelKey: String
        let references: [GigaAMEncoderFeatures]
        let observedVariants: [String]
        var negatives: [GigaAMEncoderFeatures] = []
        var extractorVersion = GigaAMEncoderFeatures.extractorVersion
    }

    struct PreparedTerm: Sendable {
        let term: Term
        let calibration: GigaAMAcousticMatcher.EncoderCalibration
    }

    enum Reason: String, Sendable {
        case capacityExceeded, duplicateEntryID, wrongModel, wrongRecipe, invalidTerm
        case invalidReferences, uncalibrated, contrastBudget, invalidTranscript
        case noSearchHits, invalidWordSpan, protectedTextRule, confidentSource
        case protectedContent, acousticRejected, ambiguous, compoundPreferred
        case overlapping, replacementFailed, accepted
    }

    struct Diagnostic: Sendable {
        let reason: Reason
        let entryID: UUID?
        init(_ reason: Reason, _ entryID: UUID? = nil) { self.reason = reason; self.entryID = entryID }
    }

    struct Preparation: Sendable {
        let words: [PreparedTerm]
        let diagnostics: [Diagnostic]
    }

    struct AcceptedSpan: Sendable {
        let entryID: UUID
        let label: String
        let wordRange: ClosedRange<Int>
        let frameRange: Range<Int>
        let distance: Float
        let acceptanceDistance: Float
        let spellingSupport: Double
        var quality: Double {
            let acoustic = 1 - min(1, Double(self.distance / max(0.000_001, self.acceptanceDistance)))
            return (acoustic + self.spellingSupport) / 2
        }
    }

    struct Output: Sendable {
        let text: String
        let accepted: [AcceptedSpan]
        let diagnostics: [Diagnostic]
    }

    struct Arbitration: Sendable {
        let accepted: [AcceptedSpan]
        let diagnostics: [Diagnostic]
    }

    static func prepare(terms: [Term], modelKey: String) throws -> Preparation {
        try Task.checkCancellation()
        guard !modelKey.isEmpty, modelKey.utf8.count <= 1_024, terms.count <= self.maximumTerms else {
            return Preparation(words: [], diagnostics: [.init(.capacityExceeded)])
        }
        guard Set(terms.map(\.entryID)).count == terms.count else {
            return Preparation(words: [], diagnostics: [.init(.duplicateEntryID)])
        }
        var bytes = 0
        for term in terms {
            for features in term.references + term.negatives {
                let size = features.values.count * MemoryLayout<Float>.size
                guard size <= self.maximumReferenceBytes - bytes else {
                    return Preparation(words: [], diagnostics: [.init(.capacityExceeded)])
                }
                bytes += size
            }
        }
        var valid: [Term] = [], diagnostics: [Diagnostic] = []
        for term in terms {
            try Task.checkCancellation()
            if term.modelKey != modelKey { diagnostics.append(.init(.wrongModel, term.entryID)); continue }
            if term.extractorVersion != GigaAMEncoderFeatures.extractorVersion {
                diagnostics.append(.init(.wrongRecipe, term.entryID)); continue
            }
            guard GigaAMDictionaryLexicalEvidence.compare(heard: term.label, canonical: term.label, observedVariants: []) != nil,
                  term.observedVariants.count <= 20, term.observedVariants.allSatisfy({ !$0.isEmpty && $0.count <= 80 }) else {
                diagnostics.append(.init(.invalidTerm, term.entryID)); continue
            }
            guard (3...10).contains(term.references.count), term.negatives.count <= 32 else {
                diagnostics.append(.init(.invalidReferences, term.entryID)); continue
            }
            valid.append(term)
        }
        var result: [PreparedTerm] = []
        for term in valid {
            try Task.checkCancellation()
            // All enrolled contrasts are used where possible. Above the native
            // calibration budget, include every other term before extra versions.
            let others = valid.filter { $0.entryID != term.entryID }
            var contrasts = others.compactMap { $0.references.first }
            contrasts += term.negatives
            contrasts += others.flatMap { Array($0.references.dropFirst()) }
            if contrasts.count > 128 { diagnostics.append(.init(.contrastBudget, term.entryID)) }
            guard let calibration = try GigaAMAcousticMatcher.calibrateEncoder(
                references: term.references, contrastReferences: Array(contrasts.prefix(128))
            ) else { diagnostics.append(.init(.uncalibrated, term.entryID)); continue }
            result.append(PreparedTerm(term: term, calibration: calibration))
        }
        return Preparation(words: result, diagnostics: diagnostics)
    }

    @concurrent static func correct(
        transcript: GigaAMTranscript, features: GigaAMEncoderFeatures, modelKey: String,
        words: [PreparedTerm], entries: [SettingsStore.CustomDictionaryEntry]
    ) async throws -> Output {
        try Task.checkCancellation()
        func raw(_ reason: Reason) -> Output { Output(text: transcript.text, accepted: [], diagnostics: [.init(reason)]) }
        if words.isEmpty { return raw(.noSearchHits) }
        guard entries.count <= 4_096 else { return raw(.capacityExceeded) }
        guard !modelKey.isEmpty, words.count <= self.maximumTerms,
              words.allSatisfy({ $0.term.modelKey == modelKey && $0.term.extractorVersion == GigaAMEncoderFeatures.extractorVersion }) else {
            return raw(.wrongModel)
        }
        let source = transcript.words
        let duration = Double(features.frameCount) * GigaAMEncoderFeatures.frameDuration
        guard !source.isEmpty, source.count <= 128,
              source.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start &&
                  $0.end <= duration + 0.08 && $0.confidence.isFinite && (0...1).contains($0.confidence) }),
              zip(source, source.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }) else {
            return raw(.invalidTranscript)
        }
        let textWords = source.map(\.text)
        let claimed = DictionaryAudioSpan.textClaimed(words: textWords, entries: entries)
        let frameSequence = DictionaryMatchFrames(hiddenSize: GigaAMEncoderFeatures.dimension, values: features.values)
        guard let query = DictionaryStampMatcher.prepare(frameSequence) else { return raw(.invalidTranscript) }
        let references = words.map { $0.term.references.map {
            DictionaryMatchFrames(hiddenSize: GigaAMEncoderFeatures.dimension, values: $0.values)
        } }
        let hits = DictionaryStampMatcher.hits(words: references, in: query, limit: 6, maximumDistance: 1)
        var candidates: [AcceptedSpan] = [], diagnostics: [Diagnostic] = []
        for (index, prepared) in words.enumerated() {
            let term = prepared.term
            if hits[index].isEmpty { diagnostics.append(.init(.noSearchHits, term.entryID)) }
            for hit in hits[index] {
                try Task.checkCancellation()
                guard let range = self.wordRange(frames: hit.frames, words: source),
                      range.allSatisfy({ !claimed.contains($0) }) else {
                    diagnostics.append(.init(.protectedTextRule, term.entryID)); continue
                }
                guard range.count <= 4, !self.crossesSentence(range, words: source) else {
                    diagnostics.append(.init(.invalidWordSpan, term.entryID)); continue
                }
                guard !source[range].contains(where: { $0.confidence >= 0.85 }) else {
                    diagnostics.append(.init(.confidentSource, term.entryID)); continue
                }
                let heard = source[range].map(\.text).joined(separator: " ")
                guard let lexical = GigaAMDictionaryLexicalEvidence.compare(
                    heard: heard, canonical: term.label, observedVariants: term.observedVariants
                ), !lexical.protectsContent else { diagnostics.append(.init(.protectedContent, term.entryID)); continue }
                guard hit.frames.lowerBound >= 0, hit.frames.upperBound <= features.frameCount, !hit.frames.isEmpty else {
                    diagnostics.append(.init(.invalidWordSpan, term.entryID)); continue
                }
                let cut = try GigaAMEncoderFeatures(values: Array(features.values[
                    (hit.frames.lowerBound * GigaAMEncoderFeatures.dimension)..<(hit.frames.upperBound * GigaAMEncoderFeatures.dimension)
                ]))
                guard let match = try GigaAMAcousticMatcher.matchEncoder(query: cut, references: term.references,
                    calibration: prepared.calibration, negativeReferences: term.negatives), match.accepted else {
                    diagnostics.append(.init(.acousticRejected, term.entryID)); continue
                }
                candidates.append(AcceptedSpan(entryID: term.entryID, label: term.label, wordRange: range,
                    frameRange: hit.frames, distance: match.distance, acceptanceDistance: prepared.calibration.acceptanceDistance,
                    spellingSupport: lexical.phoneticSimilarity))
            }
        }
        let arbitration = self.arbitrate(candidates)
        diagnostics += arbitration.diagnostics
        let replacements = arbitration.accepted.map { DictionaryTranscriptReplacement.Replacement(wordRange: $0.wordRange, label: $0.label) }
        let text = DictionaryTranscriptReplacement.apply(to: transcript.text, wordTexts: textWords, replacements: replacements)
        guard text != transcript.text || replacements.isEmpty else {
            return Output(text: transcript.text, accepted: [], diagnostics: diagnostics + [.init(.replacementFailed)])
        }
        return Output(text: text, accepted: arbitration.accepted, diagnostics: diagnostics)
    }

    /// Prefix labels are not competitors when an accepted complete registered term
    /// explains the same spoken span. Unrelated near-equal labels remain ambiguous.
    static func arbitrate(_ input: [AcceptedSpan]) -> Arbitration {
        guard input.count <= self.maximumTerms * 6 else { return Arbitration(accepted: [], diagnostics: [.init(.capacityExceeded)]) }
        let candidates = input.filter { $0.distance.isFinite && $0.acceptanceDistance.isFinite &&
            $0.acceptanceDistance > 0 && (0...$0.acceptanceDistance).contains($0.distance) &&
            $0.wordRange.lowerBound >= 0 && $0.frameRange.lowerBound >= 0 && !$0.frameRange.isEmpty &&
            $0.frameRange.upperBound <= GigaAMEncoderFeatures.maximumFrames &&
            $0.spellingSupport.isFinite && (0...1).contains($0.spellingSupport) }
        var diagnostics: [Diagnostic] = []
        let complete = candidates.filter { prefix in
            let dominated = candidates.contains { full in self.compound(full, dominates: prefix) }
            if dominated { diagnostics.append(.init(.compoundPreferred, prefix.entryID)) }
            return !dominated
        }
        var occupied = Set<Int>(), accepted: [AcceptedSpan] = []
        let sorted = complete.sorted {
            if abs($0.quality - $1.quality) > 0.000_001 { return $0.quality > $1.quality }
            if $0.wordRange.count != $1.wordRange.count { return $0.wordRange.count > $1.wordRange.count }
            return $0.entryID.uuidString < $1.entryID.uuidString
        }
        for candidate in sorted {
            if candidate.wordRange.contains(where: occupied.contains) { diagnostics.append(.init(.overlapping, candidate.entryID)); continue }
            let ambiguous = complete.contains { other in
                other.entryID != candidate.entryID && other.label.caseInsensitiveCompare(candidate.label) != .orderedSame &&
                    other.wordRange.overlaps(candidate.wordRange) &&
                    (!other.frameRange.overlaps(candidate.frameRange) ||
                        (abs(other.distance - candidate.distance) <= 0.01 && abs(other.quality - candidate.quality) <= 0.05))
            }
            if ambiguous { diagnostics.append(.init(.ambiguous, candidate.entryID)); continue }
            accepted.append(candidate); occupied.formUnion(candidate.wordRange)
            diagnostics.append(.init(.accepted, candidate.entryID))
        }
        return Arbitration(accepted: accepted, diagnostics: diagnostics)
    }

    private static func compound(_ full: AcceptedSpan, dominates prefix: AcceptedSpan) -> Bool {
        guard full.entryID != prefix.entryID, full.wordRange.lowerBound <= prefix.wordRange.lowerBound,
              full.wordRange.upperBound >= prefix.wordRange.upperBound, full.frameRange.overlaps(prefix.frameRange) else { return false }
        let fullKey = GigaAMDictionaryLexicalEvidence.phoneticKey(full.label)
        let prefixKey = GigaAMDictionaryLexicalEvidence.phoneticKey(prefix.label)
        return !prefixKey.isEmpty && fullKey.count > prefixKey.count && fullKey.hasPrefix(prefixKey) &&
            (full.spellingSupport >= 0.8 || full.quality > prefix.quality)
    }

    private static func wordRange(frames: Range<Int>, words: [GigaAMWordTiming]) -> ClosedRange<Int>? {
        let start = Double(frames.lowerBound) * GigaAMEncoderFeatures.frameDuration
        let end = Double(frames.upperBound) * GigaAMEncoderFeatures.frameDuration
        let touched = words.indices.filter {
            let overlap = max(0, min(end, words[$0].end) - max(start, words[$0].start))
            return overlap >= min(0.04, (words[$0].end - words[$0].start) * 0.5) &&
                overlap / (words[$0].end - words[$0].start) >= 0.5
        }
        guard let first = touched.first, let last = touched.last, last - first < 4 else { return nil }
        return first...last
    }

    private static func crossesSentence(_ range: ClosedRange<Int>, words: [GigaAMWordTiming]) -> Bool {
        guard range.count > 1 else { return false }
        let punctuation = CharacterSet(charactersIn: ".!?;:\n\r")
        return (range.lowerBound..<range.upperBound).contains { words[$0].text.rangeOfCharacter(from: punctuation) != nil }
    }
}
