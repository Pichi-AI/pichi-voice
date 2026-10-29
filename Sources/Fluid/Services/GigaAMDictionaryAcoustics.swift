import Foundation
import PichiGigaAM

/// The GGUF runtime exposes CTC words, but not its encoder states. These versioned
/// cepstral templates use the existing CPU audio frontend and add no model weights.
/// Keeping this adapter outside common orchestration also keeps Parakeet's learned
/// encoder thresholds away from this different acoustic representation.
nonisolated enum GigaAMDictionaryAcoustics {
    static let maximumWordCount = 4_096
    static let maximumCandidatesPerWindow = 24
    static let maximumReferencesBytes = 8 * 1_024 * 1_024

    struct Snapshot: Sendable {
        let modelKey: String
        let generation: String
        let enabled: Bool
        let entries: [SettingsStore.CustomDictionaryEntry]
        let pronunciation: PronunciationDictionaryStore.CaptureRead?
        let negatives: DictionaryNegativeExampleStore.CaptureRead?
    }

    struct Word: Sendable {
        let entryID: UUID
        let label: String
        let profileKey: String
        let references: [GigaAMAcousticFeatures]
        let calibration: GigaAMAcousticMatcher.Calibration
        let negatives: [GigaAMAcousticFeatures]
        let summaries: [[Float]]

        init(entryID: UUID, label: String, profileKey: String, references: [GigaAMAcousticFeatures],
             calibration: GigaAMAcousticMatcher.Calibration, negatives: [GigaAMAcousticFeatures]) {
            self.entryID = entryID
            self.label = label
            self.profileKey = profileKey
            self.references = references
            self.calibration = calibration
            self.negatives = negatives
            self.summaries = references.compactMap(\.meanL2)
        }
    }

    struct Output: Sendable {
        let text: String
        let evidence: [DictionaryAcousticEvidence]
        let spellings: [DictionaryVoiceSpelling]
    }

    static func referenceCacheKey(_ snapshot: Snapshot) -> String {
        var parts = [snapshot.modelKey, snapshot.generation,
                     snapshot.pronunciation?.profile.id ?? "", snapshot.pronunciation?.profile.generation.uuidString ?? "",
                     snapshot.negatives?.revision.uuidString ?? ""]
        parts += snapshot.entries.map { $0.id.uuidString + ":" + $0.replacement }
        parts += snapshot.pronunciation?.profiles.map(DictionaryNegativeEvidenceResolver.profileKey) ?? []
        return parts.map { "\($0.utf8.count):" + $0 }.joined()
    }

    static func modelKey(fingerprint: String) -> String {
        "gigaam-dictionary/" + GigaAMAcousticFeatures.extractorVersion + "/" + fingerprint
    }

    /// A manual isolated pronunciation and a selected original occurrence share the
    /// same representation and persistence path. The original PCM remains available
    /// for listening/re-recording; weights are never modified by this operation.
    @concurrent static func enrollment(
        samples: [Float], modelKey: String, words: [ASRWordTiming],
        focalRange: Range<Int>? = nil
    ) async throws -> PronunciationEnrollmentCapture? {
        try Task.checkCancellation()
        guard !modelKey.isEmpty, !samples.isEmpty,
              samples.count <= GigaAMAcousticFeatures.maximumSamples,
              samples.allSatisfy(\.isFinite) else { return nil }
        let range = focalRange ?? DictionaryPronunciationExperiment.trimmedRange(samples)
        guard let range, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count else { return nil }
        let features = try GigaAMAcousticFeatures.extract(Array(samples[range]))
        guard let mean = features.meanL2 else { return nil }
        let start = Double(range.lowerBound) / 16_000
        let end = Double(range.upperBound) / 16_000
        let inspection = DictionaryAudioInspection(
            samples: samples, recordedSampleCount: samples.count,
            frames: [.init(offset: start, frameDuration: GigaAMAcousticFeatures.frameDuration,
                           hiddenSize: GigaAMAcousticFeatures.dimension, values: features.values)],
            words: words.map { .init(text: $0.text, start: $0.start, end: $0.end) },
            selectedStart: start, selectedEnd: end
        )
        guard inspection.isValid else { return nil }
        try Task.checkCancellation()
        return PronunciationEnrollmentCapture(
            values: mean, sourceFrameCount: features.frameCount, modelKey: modelKey,
            extractorVersion: GigaAMAcousticFeatures.extractorVersion,
            pendingInspection: inspection
        )
    }

    @concurrent static func preparedWords(_ snapshot: Snapshot) async throws -> [Word] {
        guard snapshot.enabled, let read = snapshot.pronunciation else { return [] }
        var words: [Word] = []
        var bytes = 0
        let entries = Dictionary(snapshot.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for profile in read.profiles {
            try Task.checkCancellation()
            guard profile.modelKey == snapshot.modelKey,
                  profile.hiddenSize == GigaAMAcousticFeatures.dimension,
                  profile.enrollments.count >= 3,
                  let entry = entries[profile.dictionaryEntryID],
                  profile.label == entry.replacement,
                  profile.enrollments.prefix(3).allSatisfy({
                      $0.modelKey == snapshot.modelKey && $0.extractorVersion == GigaAMAcousticFeatures.extractorVersion
                  }) else { continue }
            var references: [GigaAMAcousticFeatures] = []
            do {
                for capture in profile.enrollments.prefix(3) {
                    try Task.checkCancellation()
                    let features: GigaAMAcousticFeatures
                    if let id = capture.inspectionID {
                        let inspection = try read.inspection(for: id)
                        guard inspection.frames.count == 1, let frames = inspection.frames.first,
                              frames.hiddenSize == GigaAMAcousticFeatures.dimension,
                              frames.frameDuration == GigaAMAcousticFeatures.frameDuration else {
                            throw PronunciationDictionaryStoreError.inconsistentEnrollment
                        }
                        features = try GigaAMAcousticFeatures(values: frames.values)
                    } else {
                        features = try GigaAMAcousticFeatures.extract(
                            read.originalAudioSamples(for: capture, entryID: profile.dictionaryEntryID)
                        )
                    }
                    references.append(features)
                }
                let additional = references.reduce(0) { $0 + $1.values.count * MemoryLayout<Float>.size }
                guard additional <= maximumReferencesBytes - bytes,
                      let calibration = try GigaAMAcousticMatcher.calibrate(references: references) else { continue }
                let profileKey = DictionaryNegativeEvidenceResolver.profileKey(profile) + ":shared-features-v1"
                let negatives = snapshot.negatives?.frames(entryID: profile.dictionaryEntryID,
                    profileKey: profileKey, modelKey: snapshot.modelKey).compactMap {
                        try? GigaAMAcousticFeatures(values: $0.values)
                    } ?? []
                words.append(Word(entryID: entry.id, label: entry.replacement, profileKey: profileKey,
                                  references: references, calibration: calibration, negatives: negatives))
                bytes += additional
            } catch is CancellationError { throw CancellationError() }
            catch {
                // Missing, corrupt, or incompatible optional evidence cannot damage
                // otherwise usable raw recognition or trigger another model load.
                continue
            }
        }
        return words
    }

    /// Candidate boundaries come from the immutable original ASR result. Corrections
    /// never consume a neighbouring word already owned by a text rule or another term.
    @concurrent static func correct(
        transcript: GigaAMTranscript, samples: [Float], snapshot: Snapshot, words: [Word]
    ) async throws -> Output {
        let raw = Output(text: transcript.text, evidence: [], spellings: [])
        guard snapshot.enabled, !words.isEmpty, !transcript.words.isEmpty,
              transcript.words.count <= maximumWordCount,
              samples.count <= DictionaryLearningRecording.maximumSamples else { return raw }
        let source = transcript.words
        let duration = Double(samples.count) / 16_000
        guard source.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.08 }),
              zip(source, source.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }) else { return raw }
        let textWords = source.map(\.text)
        let claimed = DictionaryAudioSpan.textClaimed(words: textWords, entries: snapshot.entries)
        struct Candidate {
            let word: Word
            let range: ClosedRange<Int>
            let distance: Float
            let features: GigaAMAcousticFeatures
        }
        struct CoarseCandidate {
            let word: Word
            let range: ClosedRange<Int>
            let features: GigaAMAcousticFeatures
            let similarity: Float
            let hasConfidence: Bool
        }
        var candidates: [Candidate] = []
        // Rank cheap acoustic summaries in every temporal window before doing DTW.
        // A large vocabulary cannot exhaust a front-only budget and starve later words.
        let windows = Dictionary(grouping: source.indices) { Int(source[$0].start / 10) }
        for window in windows.keys.sorted() {
            try Task.checkCancellation()
            let chunkStart = max(0, window * 160_000 - 40_000) / 640 * 640
            let chunkEnd = min(samples.count, chunkStart + GigaAMAcousticFeatures.maximumSamples)
            guard chunkEnd > chunkStart else { continue }
            let chunk: GigaAMAcousticFeatures
            do { chunk = try GigaAMAcousticFeatures.extract(Array(samples[chunkStart..<chunkEnd])) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            var shortlist: [CoarseCandidate] = []
            for start in windows[window] ?? [] where !claimed.contains(start) {
              for length in 1...min(5, source.count - start) {
                let range = start...(start + length - 1)
                guard range.allSatisfy({ !claimed.contains($0) }) else { break }
                let segment = source[range]
                guard let first = segment.first, let last = segment.last,
                      first.start.isFinite, last.end.isFinite, first.start >= 0,
                      last.end > first.start else { continue }
                // Known confident words need stronger evidence than an uncertain
                // acoustic template. Unknown native confidence (zero) is not "low".
                let knownConfidence = segment.map(\.confidence).filter { $0.isFinite && $0 > 0 }
                if !knownConfidence.isEmpty, knownConfidence.allSatisfy({ $0 >= 0.85 }) { continue }
                let lower = max(0, Int((first.start * 16_000).rounded(.down)) - 640)
                let upper = min(samples.count, Int((last.end * 16_000).rounded(.up)) + 640)
                guard upper > lower, upper - lower <= GigaAMAcousticFeatures.maximumSamples else { continue }
                let duration = Double(upper - lower) / 16_000
                let eligible = words.filter { word in
                    let referenceDuration = word.references.map { Double($0.frameCount) * GigaAMAcousticFeatures.frameDuration }
                    return referenceDuration.contains { duration >= $0 * 0.5 && duration <= $0 * 2 }
                }
                guard !eligible.isEmpty else { continue }
                let query: GigaAMAcousticFeatures
                do {
                    if lower >= chunkStart, upper <= chunkEnd {
                        let firstFrame = max(0, (lower - chunkStart) / 640)
                        let lastFrame = min(chunk.frameCount, (upper - chunkStart + 639) / 640)
                        guard firstFrame < lastFrame else { continue }
                        query = try GigaAMAcousticFeatures(values: Array(chunk.values[
                            (firstFrame * GigaAMAcousticFeatures.dimension)..<(lastFrame * GigaAMAcousticFeatures.dimension)]))
                    } else {
                        // An unusually long term straddling a core-window boundary still
                        // gets one exact bounded cut instead of being silently dropped.
                        query = try GigaAMAcousticFeatures.extract(Array(samples[lower..<upper]))
                    }
                }
                catch is CancellationError { throw CancellationError() }
                catch { continue }
                guard let summary = query.meanL2 else { continue }
                for word in eligible {
                    try Task.checkCancellation()
                    let similarity = word.summaries.map {
                        zip(summary, $0).reduce(Float(0)) { $0 + $1.0 * $1.1 }
                    }.max() ?? -1
                    let candidate = CoarseCandidate(word: word, range: range, features: query,
                        similarity: similarity, hasConfidence: !knownConfidence.isEmpty)
                    shortlist.append(candidate)
                    shortlist.sort {
                        if $0.similarity != $1.similarity { return $0.similarity > $1.similarity }
                        if $0.range.count != $1.range.count { return $0.range.count < $1.range.count }
                        return $0.range.lowerBound < $1.range.lowerBound
                    }
                    if shortlist.count > maximumCandidatesPerWindow { shortlist.removeLast() }
                }
              }
            }
            for candidate in shortlist {
                try Task.checkCancellation()
                let word = candidate.word
                guard let match = try GigaAMAcousticMatcher.match(query: candidate.features, references: word.references,
                    calibration: word.calibration, negativeReferences: word.negatives), match.accepted else { continue }
                // Missing native confidence is not evidence of uncertainty. It needs
                // an especially close acoustic match before changing a word.
                guard candidate.hasConfidence || match.distance <= 0.02 else { continue }
                candidates.append(Candidate(word: word, range: candidate.range, distance: match.distance, features: candidate.features))
            }
        }
        var occupied = claimed
        var accepted: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.distance < $1.distance }) {
            guard candidate.range.allSatisfy({ !occupied.contains($0) }) else { continue }
            let ambiguous = candidates.contains {
                $0.word.entryID != candidate.word.entryID && $0.range.overlaps(candidate.range)
                    && $0.distance < candidate.distance + 0.01
            }
            guard !ambiguous else { continue }
            accepted.append(candidate)
            occupied.formUnion(candidate.range)
        }
        guard !accepted.isEmpty else { return raw }
        let replacements = accepted.map { DictionaryTranscriptReplacement.Replacement(wordRange: $0.range, label: $0.word.label) }
        let text = DictionaryTranscriptReplacement.apply(to: transcript.text, wordTexts: textWords, replacements: replacements)
        guard text != transcript.text else { return raw }
        let evidence = accepted.compactMap { candidate -> DictionaryAcousticEvidence? in
            let frames = DictionaryMatchFrames(hiddenSize: GigaAMAcousticFeatures.dimension, values: candidate.features.values)
            guard frames.isValid else { return nil }
            return DictionaryAcousticEvidence(id: UUID(), entryID: candidate.word.entryID,
                label: candidate.word.label, profileKey: candidate.word.profileKey, modelKey: snapshot.modelKey,
                sourceWordRange: candidate.range.lowerBound..<(candidate.range.upperBound + 1), frames: frames)
        }
        let spellings = accepted.map { candidate in
            DictionaryVoiceSpelling(entryID: candidate.word.entryID, label: candidate.word.label,
                                    spelling: candidate.range.map { source[$0].text }.joined(separator: " "))
        }
        return Output(text: text, evidence: evidence, spellings: spellings)
    }
}
