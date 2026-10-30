import Foundation
import PichiGigaAM

/// Corrects already captured, fingerprint-bound learned encoder features. Capture,
/// models, private persistence and admission stay with their existing owners.
nonisolated enum GigaAMEncoderDictionary {
    static let maximumTerms = 128
    static let maximumReferenceBytes = 32 * 1_024 * 1_024
    static let maximumWindowBytes = 128 * 1_024 * 1_024
    static let maximumAbsoluteFrames = 22_500

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
        case protectedContent, acousticRejected, recordedVariantCorroborated, ambiguous, compoundPreferred
        case overlapping, replacementFailed, accepted, invalidWindows, outsideOwnership, unconfirmedCompound
        case sourceTruncation
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
        var frameOffset = 0
        var canonicalSupport: Double = 0
        var additionalComponentSupport = false
        var sourceTruncation = false
        var absoluteFrameRange: Range<Int> {
            (self.frameOffset + self.frameRange.lowerBound)..<(self.frameOffset + self.frameRange.upperBound)
        }
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

    /// Long recordings retain immutable global CTC ordinals. Each bounded feature
    /// window uses the unchanged short-window policy, and only the final global
    /// edit touches the original transcript, including repeated occurrences.
    @concurrent static func correct(
        transcript: GigaAMTranscript, windows: [GigaAMEncoderWindow], modelKey: String,
        words: [PreparedTerm], entries: [SettingsStore.CustomDictionaryEntry]
    ) async throws -> Output {
        try Task.checkCancellation()
        func raw(_ reason: Reason) -> Output { Output(text: transcript.text, accepted: [], diagnostics: [.init(reason)]) }
        guard !modelKey.isEmpty, words.count <= self.maximumTerms,
              words.allSatisfy({ $0.term.modelKey == modelKey && $0.term.extractorVersion == GigaAMEncoderFeatures.extractorVersion }) else {
            return raw(.wrongModel)
        }
        guard !windows.isEmpty, windows.count <= 256 else { return raw(.invalidWindows) }
        guard entries.count <= 4_096 else { return raw(.capacityExceeded) }
        let source = transcript.words
        guard !source.isEmpty, source.count <= 4_096,
              source.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start &&
                  $0.end <= 900.08 && $0.confidence.isFinite && (0...1).contains($0.confidence) }),
              zip(source, source.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }) else {
            return raw(.invalidTranscript)
        }
        var bytes = 0, offsets: [Int] = []
        var previousOffset = -Double.infinity, previousOwnershipEnd = -Double.infinity
        for window in windows {
            try Task.checkCancellation()
            let offset = window.offset / GigaAMEncoderFeatures.frameDuration
            guard offset.isFinite, (0...Double(self.maximumAbsoluteFrames)).contains(offset),
                  abs(offset - offset.rounded()) <= 0.000_01,
                  window.offset >= previousOffset, window.ownership.lowerBound >= previousOwnershipEnd - 0.000_001,
                  window.ownership.lowerBound >= window.offset,
                  window.ownership.upperBound <= 900.000_001 else { return raw(.invalidWindows) }
            let frameOffset = Int(offset.rounded())
            guard frameOffset + window.features.frameCount <= self.maximumAbsoluteFrames else { return raw(.invalidWindows) }
            let size = window.features.values.count * MemoryLayout<Float>.size
            guard size <= self.maximumWindowBytes - bytes else { return raw(.capacityExceeded) }
            bytes += size
            offsets.append(frameOffset)
            previousOffset = window.offset
            previousOwnershipEnd = window.ownership.upperBound
        }
        let globallyClaimed = DictionaryAudioSpan.textClaimed(words: source.map(\.text), entries: entries)
        var candidates: [AcceptedSpan] = [], diagnostics: [Diagnostic] = []
        for (index, window) in windows.enumerated() {
            try Task.checkCancellation()
            let end = window.offset + Double(window.features.frameCount) * GigaAMEncoderFeatures.frameDuration
            let indices = source.indices.filter { source[$0].start >= window.offset - 0.000_001 && source[$0].end <= end + 0.000_001 }
            guard !indices.isEmpty else { continue }
            let localWords = indices.map {
                GigaAMWordTiming(text: source[$0].text, start: max(0, source[$0].start - window.offset),
                    end: source[$0].end - window.offset, confidence: source[$0].confidence)
            }
            let local = GigaAMTranscript(text: localWords.map(\.text).joined(separator: " "), confidence: transcript.confidence,
                words: localWords, endOfUtteranceProbability: nil, processingDuration: 0)
            let output = try await self.correct(transcript: local, features: window.features,
                modelKey: modelKey, words: words, entries: entries)
            try Task.checkCancellation()
            diagnostics += output.diagnostics.filter { $0.reason != .accepted }
            for span in output.accepted {
                guard indices.indices.contains(span.wordRange.lowerBound), indices.indices.contains(span.wordRange.upperBound) else {
                    diagnostics.append(.init(.invalidWordSpan, span.entryID)); continue
                }
                let first = indices[span.wordRange.lowerBound], last = indices[span.wordRange.upperBound]
                guard last - first + 1 == span.wordRange.count else {
                    diagnostics.append(.init(.invalidWordSpan, span.entryID)); continue
                }
                guard (first...last).allSatisfy({ !globallyClaimed.contains($0) }) else {
                    diagnostics.append(.init(.protectedTextRule, span.entryID)); continue
                }
                // Word-span ownership is stable even if overlapping contexts yield
                // slightly different acoustic hit boundaries for this occurrence.
                let center = (source[first].start + source[last].end) / 2
                guard window.ownership.contains(center) else {
                    diagnostics.append(.init(.outsideOwnership, span.entryID)); continue
                }
                candidates.append(AcceptedSpan(entryID: span.entryID, label: span.label,
                    wordRange: first...last, frameRange: span.frameRange, distance: span.distance,
                    acceptanceDistance: span.acceptanceDistance, spellingSupport: span.spellingSupport,
                    frameOffset: offsets[index], canonicalSupport: span.canonicalSupport,
                    additionalComponentSupport: span.additionalComponentSupport, sourceTruncation: span.sourceTruncation))
            }
        }
        // Only connected overlapping word spans can compete. Do not run a
        // quadratic arbitration across unrelated terms in a fifteen-minute text.
        let ordered = candidates.sorted {
            $0.wordRange.lowerBound == $1.wordRange.lowerBound ? $0.wordRange.upperBound < $1.wordRange.upperBound : $0.wordRange.lowerBound < $1.wordRange.lowerBound
        }
        var accepted: [AcceptedSpan] = [], group: [AcceptedSpan] = [], groupEnd = -1
        for candidate in ordered {
            try Task.checkCancellation()
            if !group.isEmpty && candidate.wordRange.lowerBound > groupEnd {
                let resolved = self.arbitrate(group)
                accepted += resolved.accepted; diagnostics += resolved.diagnostics
                group.removeAll(keepingCapacity: true)
                groupEnd = -1
            }
            group.append(candidate); groupEnd = max(groupEnd, candidate.wordRange.upperBound)
        }
        if !group.isEmpty {
            try Task.checkCancellation()
            let resolved = self.arbitrate(group)
            accepted += resolved.accepted; diagnostics += resolved.diagnostics
        }
        let text = DictionaryTranscriptReplacement.apply(to: transcript.text, wordTexts: source.map(\.text),
            replacements: accepted.map { .init(wordRange: $0.wordRange, label: $0.label) })
        guard text != transcript.text || accepted.isEmpty else {
            return Output(text: transcript.text, accepted: [], diagnostics: diagnostics + [.init(.replacementFailed)])
        }
        return Output(text: text, accepted: accepted, diagnostics: diagnostics)
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
                guard let ordinary = try GigaAMAcousticMatcher.matchEncoder(query: cut, references: term.references,
                    calibration: prepared.calibration, negativeReferences: term.negatives) else {
                    diagnostics.append(.init(.acousticRejected, term.entryID)); continue
                }
                let match: GigaAMAcousticMatcher.Match
                let effectiveLimit: Float
                if ordinary.accepted {
                    match = ordinary
                    effectiveLimit = prepared.calibration.acceptanceDistance
                } else if GigaAMDictionaryLexicalEvidence.observedStemSupport(
                    heard: heard, canonical: term.label, observedVariants: term.observedVariants
                ), let limit = prepared.calibration.corroboratedAcceptanceDistance,
                   let corroborated = try GigaAMAcousticMatcher.matchEncoderCorroborated(
                    query: cut, references: term.references, calibration: prepared.calibration,
                    negativeReferences: term.negatives
                   ), corroborated.accepted {
                    // A complete user-recorded stem and a bounded grammatical
                    // ending add independent evidence. Ordinary acoustic limits,
                    // negative vetoes and all word/meaning guards remain intact.
                    match = corroborated
                    effectiveLimit = limit
                    diagnostics.append(.init(.recordedVariantCorroborated, term.entryID))
                } else {
                    diagnostics.append(.init(.acousticRejected, term.entryID)); continue
                }
                candidates.append(AcceptedSpan(entryID: term.entryID, label: term.label, wordRange: range,
                    frameRange: hit.frames, distance: match.distance, acceptanceDistance: effectiveLimit,
                    spellingSupport: lexical.phoneticSimilarity, canonicalSupport: lexical.canonicalSimilarity,
                    additionalComponentSupport: GigaAMDictionaryLexicalEvidence.supportsCanonicalComponents(heard: heard, canonical: term.label),
                    sourceTruncation: GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: heard, canonical: term.label)))
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
            $0.frameOffset >= 0 && $0.frameOffset <= self.maximumAbsoluteFrames &&
            $0.frameOffset + $0.frameRange.upperBound <= self.maximumAbsoluteFrames &&
            $0.spellingSupport.isFinite && (0...1).contains($0.spellingSupport) &&
            $0.canonicalSupport.isFinite && (0...1).contains($0.canonicalSupport) }
        var diagnostics: [Diagnostic] = []
        let confirmed = candidates.filter { full in
            let unconfirmed = candidates.contains { prefix in
                self.compoundRelation(full, prefix: prefix) && self.covers(full, prefix: prefix) &&
                    !self.compound(full, dominates: prefix)
            }
            if unconfirmed { diagnostics.append(.init(.unconfirmedCompound, full.entryID)) }
            return !unconfirmed
        }
        let complete = confirmed.filter { prefix in
            let dominated = confirmed.contains { full in self.compound(full, dominates: prefix) }
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
            // Keep this candidate in compound/ambiguity evidence above. Removing
            // it earlier could admit an unconfirmed expansion by default.
            if candidate.sourceTruncation { diagnostics.append(.init(.sourceTruncation, candidate.entryID)); continue }
            if candidate.wordRange.contains(where: occupied.contains) { diagnostics.append(.init(.overlapping, candidate.entryID)); continue }
            let ambiguous = complete.contains { other in
                other.entryID != candidate.entryID && other.label.caseInsensitiveCompare(candidate.label) != .orderedSame &&
                    other.wordRange.overlaps(candidate.wordRange) &&
                    (!other.absoluteFrameRange.overlaps(candidate.absoluteFrameRange) ||
                        (abs(other.distance - candidate.distance) <= 0.01 && abs(other.quality - candidate.quality) <= 0.05))
            }
            if ambiguous { diagnostics.append(.init(.ambiguous, candidate.entryID)); continue }
            accepted.append(candidate); occupied.formUnion(candidate.wordRange)
            diagnostics.append(.init(.accepted, candidate.entryID))
        }
        return Arbitration(accepted: accepted, diagnostics: diagnostics)
    }

    private static func compound(_ full: AcceptedSpan, dominates prefix: AcceptedSpan) -> Bool {
        guard self.compoundRelation(full, prefix: prefix), self.covers(full, prefix: prefix),
              full.canonicalSupport >= 0.8, full.additionalComponentSupport else { return false }
        let fullComponents = GigaAMDictionaryLexicalEvidence.componentKeys(full.label)?.count ?? Int.max
        let extraWords = (full.wordRange.upperBound > prefix.wordRange.upperBound || full.wordRange.count >= fullComponents) &&
            full.absoluteFrameRange.upperBound >= prefix.absoluteFrameRange.upperBound
        let extraAudio = full.absoluteFrameRange.lowerBound <= prefix.absoluteFrameRange.lowerBound + 1 &&
            full.absoluteFrameRange.upperBound > prefix.absoluteFrameRange.upperBound
        return extraWords || extraAudio
    }

    private static func covers(_ full: AcceptedSpan, prefix: AcceptedSpan) -> Bool {
        full.entryID != prefix.entryID && full.wordRange.lowerBound == prefix.wordRange.lowerBound &&
            full.wordRange.upperBound >= prefix.wordRange.upperBound && full.absoluteFrameRange.overlaps(prefix.absoluteFrameRange)
    }

    private static func compoundRelation(_ full: AcceptedSpan, prefix: AcceptedSpan) -> Bool {
        guard full.entryID != prefix.entryID,
              let fullComponents = GigaAMDictionaryLexicalEvidence.componentKeys(full.label),
              let prefixComponents = GigaAMDictionaryLexicalEvidence.componentKeys(prefix.label),
              !prefixComponents.isEmpty, fullComponents.count > prefixComponents.count else { return false }
        return fullComponents.starts(with: prefixComponents)
    }

    private static func wordRange(frames: Range<Int>, words: [GigaAMWordTiming]) -> ClosedRange<Int>? {
        let start = Double(frames.lowerBound) * GigaAMEncoderFeatures.frameDuration
        let end = Double(frames.upperBound) * GigaAMEncoderFeatures.frameDuration
        let touched = words.indices.filter {
            guard words[$0].text.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return false }
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
