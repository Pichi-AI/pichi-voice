import Foundation
import PichiGigaAM

/// The GGUF runtime exposes CTC words, but not its encoder states. These versioned
/// cepstral templates use the existing CPU audio frontend and add no model weights.
/// Keeping this adapter outside common orchestration also keeps Parakeet's learned
/// encoder thresholds away from this different acoustic representation.
nonisolated enum GigaAMDictionaryAcoustics {
    static let maximumWordCount = 4_096
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

        init(entryID: UUID, label: String, profileKey: String, references: [GigaAMAcousticFeatures],
             calibration: GigaAMAcousticMatcher.Calibration, negatives: [GigaAMAcousticFeatures]) {
            self.entryID = entryID
            self.label = label
            self.profileKey = profileKey
            self.references = references
            self.calibration = calibration
            self.negatives = negatives
        }
    }

    struct Output: Sendable {
        let text: String
        let evidence: [DictionaryAcousticEvidence]
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

    private static func searchFrames(_ features: GigaAMAcousticFeatures) -> DictionaryMatchFrames {
        let active = (0..<features.frameCount).filter { frame in
            features.values[(frame * GigaAMAcousticFeatures.dimension)..<((frame + 1) * GigaAMAcousticFeatures.dimension)].contains { $0 != 0 }
        }
        guard let first = active.first, let last = active.last else {
            return DictionaryMatchFrames(hiddenSize: GigaAMAcousticFeatures.dimension, values: [])
        }
        return DictionaryMatchFrames(hiddenSize: GigaAMAcousticFeatures.dimension,
            values: Array(features.values[(first * GigaAMAcousticFeatures.dimension)..<((last + 1) * GigaAMAcousticFeatures.dimension)]))
    }

    /// Candidate boundaries come from the immutable original ASR result. Corrections
    /// never consume a neighbouring word already owned by a text rule or another term.
    @concurrent static func correct(
        transcript: GigaAMTranscript, samples: [Float], snapshot: Snapshot, words: [Word]
    ) async throws -> Output {
        let raw = Output(text: transcript.text, evidence: [])
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
        var candidates: [Candidate] = []
        // Reuse the existing accelerated subsequence matcher to locate the spoken
        // term. Native CTC emissions are approximate and can miss its acoustic edges;
        // they select the words to replace, not the crop used to recognize the sound.
        let referenceFrames = words.map { word in word.references.map(Self.searchFrames) }
        let windowCount = (samples.count + 159_999) / 160_000
        for window in 0..<windowCount {
            try Task.checkCancellation()
            let chunkStart = max(0, window * 160_000 - 40_000) / 640 * 640
            let chunkEnd = min(samples.count, chunkStart + GigaAMAcousticFeatures.maximumSamples)
            guard chunkEnd > chunkStart else { continue }
            let chunk: GigaAMAcousticFeatures
            do { chunk = try GigaAMAcousticFeatures.extract(Array(samples[chunkStart..<chunkEnd])) }
            catch is CancellationError { throw CancellationError() }
            catch { continue }
            let frames = DictionaryMatchFrames(hiddenSize: GigaAMAcousticFeatures.dimension, values: chunk.values)
            guard let prepared = DictionaryStampMatcher.prepare(frames) else { continue }
            // This is only a permissive candidate-search threshold in a different
            // representation. Every candidate still passes its calibrated MFCC test.
            let hits = DictionaryStampMatcher.hits(words: referenceFrames, in: prepared, limit: 3, maximumDistance: 0.08)
            let offset = Double(chunkStart) / 16_000
            let nearby = source.indices.filter { source[$0].end >= offset && source[$0].start <= Double(chunkEnd) / 16_000 }
            for (index, matches) in hits.enumerated() {
                let word = words[index]
                for hit in matches {
                    try Task.checkCancellation()
                    let startTime = offset + Double(hit.frames.lowerBound) * GigaAMAcousticFeatures.frameDuration
                    let endTime = offset + Double(hit.frames.upperBound) * GigaAMAcousticFeatures.frameDuration
                    guard Int(((startTime + endTime) / 2) / 10) == window else { continue }
                    let touched = nearby.filter { i in
                        let overlap = max(0, min(endTime, source[i].end) - max(startTime, source[i].start))
                        return overlap >= min(0.04, (source[i].end - source[i].start) * 0.5)
                            && overlap / (source[i].end - source[i].start) >= 0.5
                    }
                    guard let first = touched.first, let last = touched.last,
                          last - first < 5, (first...last).allSatisfy({ !claimed.contains($0) }) else { continue }
                    let range = first...last
                    let knownConfidence = source[range].map(\.confidence).filter { $0.isFinite && $0 > 0 }
                    if !knownConfidence.isEmpty, knownConfidence.allSatisfy({ $0 >= 0.85 }) { continue }
                    let lower = hit.frames.lowerBound * GigaAMAcousticFeatures.dimension
                    let upper = hit.frames.upperBound * GigaAMAcousticFeatures.dimension
                    guard lower >= 0, upper <= chunk.values.count, lower < upper else { continue }
                    let query = try GigaAMAcousticFeatures(values: Array(chunk.values[lower..<upper]))
                    guard let match = try GigaAMAcousticMatcher.match(query: query, references: word.references,
                        calibration: word.calibration, negativeReferences: word.negatives), match.accepted else { continue }
                    guard !knownConfidence.isEmpty || match.distance <= 0.02 else { continue }
                    var ambiguous = false
                    for competitor in words where competitor.entryID != word.entryID {
                        try Task.checkCancellation()
                        if let other = try GigaAMAcousticMatcher.match(query: query,
                            references: competitor.references, calibration: competitor.calibration,
                            negativeReferences: competitor.negatives), other.distance < match.distance + 0.01 {
                            ambiguous = true
                            break
                        }
                    }
                    guard !ambiguous else { continue }
                    candidates.append(Candidate(word: word, range: range, distance: match.distance, features: query))
                }
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
        // Acoustic consistency never grants permission to create a global text
        // trigger. In particular BIMCheck must not silently become AI Enablement.
        return Output(text: text, evidence: evidence)
    }
}
