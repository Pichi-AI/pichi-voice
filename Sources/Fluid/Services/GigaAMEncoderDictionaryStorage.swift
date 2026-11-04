import Foundation
import PichiGigaAM

/// Maps the existing private pronunciation store to fingerprint-bound learned features.
/// Missing features never trigger inference or reinterpret an older acoustic recipe.
nonisolated enum GigaAMEncoderDictionaryStorage {
    private static var keyPrefix: String { "gigaam-dictionary/" + GigaAMEncoderFeatures.extractorVersion + "/" }

    static func modelKey(fingerprint: String) -> String { self.keyPrefix + fingerprint }

    private static func validModelKey(_ value: String) -> Bool {
        value.hasPrefix(self.keyPrefix) && value.utf8.count > self.keyPrefix.utf8.count && value.utf8.count <= 1_024 &&
            value.unicodeScalars.allSatisfy { $0.isASCII && !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
    }

    @concurrent static func preparedWords(_ snapshot: GigaAMDictionaryAcoustics.Snapshot) async throws -> GigaAMEncoderDictionary.Preparation {
        try Task.checkCancellation()
        guard snapshot.enabled, let read = snapshot.pronunciation else { return .init(words: [], diagnostics: []) }
        guard self.validModelKey(snapshot.modelKey) else { return .init(words: [], diagnostics: [.init(.wrongModel)]) }
        let profiles = read.profiles
        guard profiles.count <= GigaAMEncoderDictionary.maximumTerms, snapshot.entries.count <= 4_096 else {
            return .init(words: [], diagnostics: [.init(.capacityExceeded)])
        }
        let entries = Dictionary(snapshot.entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var terms: [GigaAMEncoderDictionary.Term] = [], diagnostics: [GigaAMEncoderDictionary.Diagnostic] = []
        var bytes = 0
        for profile in profiles {
            try Task.checkCancellation()
            guard profile.modelKey == snapshot.modelKey, profile.hiddenSize == GigaAMEncoderFeatures.dimension,
                  profile.enrollments.allSatisfy({ self.validCapture($0, modelKey: snapshot.modelKey) }),
                  let entry = entries[profile.dictionaryEntryID], profile.label == entry.replacement else {
                diagnostics.append(.init(.invalidReferences, profile.dictionaryEntryID)); continue
            }
            let captures = self.retainedCaptures(profile.enrollments)
            let pinned = read.matchingEnrollments(for: profile)
            guard (3...10).contains(captures.count), captures.allSatisfy({ pinned.contains($0) }) else {
                diagnostics.append(.init(.invalidReferences, profile.dictionaryEntryID)); continue
            }
            do {
                var references: [GigaAMEncoderFeatures] = []
                for capture in captures {
                    try Task.checkCancellation()
                    guard let id = capture.inspectionID,
                          let features = try self.features(capture: capture, inspection: read.inspection(for: id)) else {
                        throw PronunciationDictionaryStoreError.inconsistentEnrollment
                    }
                    references.append(features)
                }
                let profileKey = DictionaryNegativeEvidenceResolver.profileKey(profile) + ":shared-features-v1"
                var negatives: [GigaAMEncoderFeatures] = []
                for frames in snapshot.negatives?.frames(entryID: profile.dictionaryEntryID,
                    profileKey: profileKey, modelKey: snapshot.modelKey) ?? [] {
                    try Task.checkCancellation()
                    guard frames.hiddenSize == GigaAMEncoderFeatures.dimension else {
                        throw PronunciationDictionaryStoreError.inconsistentEnrollment
                    }
                    negatives.append(try GigaAMEncoderFeatures(values: frames.values))
                }
                for features in references + negatives {
                    let size = features.values.count * MemoryLayout<Float>.size
                    guard size <= GigaAMEncoderDictionary.maximumReferenceBytes - bytes else {
                        return .init(words: [], diagnostics: diagnostics + [.init(.capacityExceeded)])
                    }
                    bytes += size
                }
                terms.append(.init(entryID: entry.id, label: entry.replacement, modelKey: snapshot.modelKey,
                    references: references, observedVariants: profile.enrollments.compactMap(\.observedText).filter { !$0.isEmpty },
                    negatives: negatives))
            } catch is CancellationError { throw CancellationError() }
            catch { diagnostics.append(.init(.invalidReferences, profile.dictionaryEntryID)) }
        }
        let prepared = try GigaAMEncoderDictionary.prepare(terms: terms, modelKey: snapshot.modelKey)
        return .init(words: prepared.words, diagnostics: diagnostics + prepared.diagnostics)
    }

    /// Keep the latest manual set as fallback, followed by recent distinct
    /// contextual recordings. A recording cannot vote twice in one profile.
    static func retainedCaptures(_ captures: [PronunciationEnrollmentCapture]) -> [PronunciationEnrollmentCapture] {
        let manual = Array(captures.filter { $0.originalAudioID == nil }.suffix(3))
        var seen = Set<UUID>()
        let contextual = captures.reversed().filter { capture in
            guard let id = capture.sourceRecordingID, capture.observedText?.isEmpty == false else { return false }
            return seen.insert(id).inserted
        }
        let legacy = captures.reversed().filter { $0.originalAudioID != nil && $0.sourceRecordingID == nil }
        return manual + Array((contextual + legacy).prefix(10 - manual.count))
    }

    @concurrent static func enrollment(
        samples: [Float], modelKey: String, featureFrames: [DictionaryLearningFeatureFrames], words: [ASRWordTiming],
        focalRange: Range<Int>? = nil
    ) async throws -> PronunciationEnrollmentCapture? {
        try Task.checkCancellation()
        guard self.validModelKey(modelKey), !samples.isEmpty, samples.count <= 240_000,
              !featureFrames.isEmpty, featureFrames.count <= 256,
              samples.allSatisfy(\.isFinite), words.count <= 4_096,
              words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < $0.end &&
                  $0.end <= Double(samples.count) / 16_000 + 0.08 }) else { return nil }
        let timedWords = words.map { DictionaryAudioInspection.Word(text: $0.text, start: $0.start, end: $0.end) }
        guard var range = focalRange ?? DictionaryPronunciationExperiment.wordRange(samples, words: timedWords)
            ?? DictionaryPronunciationExperiment.trimmedRange(samples),
              !range.isEmpty, range.lowerBound >= 0, range.upperBound <= samples.count else { return nil }
        if focalRange == nil {
            // A live recording need not end on the encoder's 40 ms clock. Its
            // final incomplete analysis frame can be absent while ASR succeeds.
            // Only an implicit cut may omit that uncovered tail. Original PCM
            // stays intact and explicit corrections retain their exact bounds.
            let coveredEnd = featureFrames.compactMap { window -> Double? in
                let frames = window.frames
                guard frames.offset.isFinite, frames.frameDuration == GigaAMEncoderFeatures.frameDuration,
                      frames.hiddenSize == GigaAMEncoderFeatures.dimension, frames.count > 0 else { return nil }
                return frames.offset + Double(frames.count) * frames.frameDuration
            }.max()
            if let coveredEnd, coveredEnd.isFinite, coveredEnd >= 0,
               coveredEnd < Double(samples.count) / 16_000 {
                let coveredSamples = Int((coveredEnd * 16_000).rounded(.down))
                let shortage = samples.count - coveredSamples
                if (1...640).contains(shortage), range.upperBound > coveredSamples {
                    guard range.lowerBound < coveredSamples else { return nil }
                    range = range.lowerBound..<coveredSamples
                }
            }
        }
        do {
            guard let cut = try self.focalFeatures(featureFrames, sampleCount: samples.count, range: range),
                  let mean = cut.features.meanL2 else { return nil }
            let inspection = DictionaryAudioInspection(samples: samples, recordedSampleCount: samples.count,
                frames: [cut.frames], words: words.map { .init(text: $0.text, start: $0.start, end: $0.end) },
                selectedStart: Double(range.lowerBound) / 16_000, selectedEnd: Double(range.upperBound) / 16_000)
            guard inspection.isValid else { return nil }
            try Task.checkCancellation()
            return .init(values: mean, sourceFrameCount: cut.features.frameCount, modelKey: modelKey,
                extractorVersion: GigaAMEncoderFeatures.extractorVersion, capturedAt: Date(), pendingInspection: inspection)
        } catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    @concurrent static func validate(
        captures: [PronunciationEnrollmentCapture], modelKey: String, store: PronunciationDictionaryStore
    ) async throws -> Bool {
        try Task.checkCancellation()
        guard self.validModelKey(modelKey), captures.count <= 32,
              captures.allSatisfy({ self.validCapture($0, modelKey: modelKey) }) else { return false }
        let active = GigaAMDictionaryAcoustics.activeCaptures(captures)
        guard active.count == 3 else { return false }
        do {
            var references: [GigaAMEncoderFeatures] = []
            for capture in active {
                try Task.checkCancellation()
                let inspection: DictionaryAudioInspection
                if let pending = capture.pendingInspection { inspection = pending }
                else if let id = capture.inspectionID { inspection = try await store.inspection(for: id) }
                else { return false }
                guard let features = try self.features(capture: capture, inspection: inspection) else { return false }
                references.append(features)
            }
            try Task.checkCancellation()
            return try GigaAMAcousticMatcher.calibrateEncoder(references: references) != nil
        } catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    private static func validCapture(_ capture: PronunciationEnrollmentCapture, modelKey: String) -> Bool {
        capture.modelKey == modelKey && capture.extractorVersion == GigaAMEncoderFeatures.extractorVersion &&
            capture.values.count == GigaAMEncoderFeatures.dimension && capture.values.allSatisfy(\.isFinite) &&
            capture.values.contains(where: { abs($0) > 1e-8 }) && (1...GigaAMEncoderFeatures.maximumFrames).contains(capture.sourceFrameCount)
    }

    private static func features(capture: PronunciationEnrollmentCapture, inspection: DictionaryAudioInspection) throws -> GigaAMEncoderFeatures? {
        guard inspection.isValid, inspection.frames.count == 1,
              inspection.selectedEnd <= inspection.duration + 1e-9 else { return nil }
        let start = Int((inspection.selectedStart * 16_000).rounded(.down))
        let end = min(inspection.recordedSampleCount, Int((inspection.selectedEnd * 16_000).rounded(.up)))
        guard let cut = try self.focalFeatures(inspection.frames.map {
            DictionaryLearningFeatureFrames(extractorVersion: capture.extractorVersion ?? "", frames: $0)
        }, sampleCount: inspection.samples.count, range: start..<end), cut.features.frameCount == capture.sourceFrameCount else { return nil }
        return cut.features
    }

    private static func focalFeatures(
        _ windows: [DictionaryLearningFeatureFrames], sampleCount: Int, range: Range<Int>
    ) throws -> (features: GigaAMEncoderFeatures, frames: DictionaryAudioInspection.Frames)? {
        guard !windows.isEmpty, windows.count <= 256, !range.isEmpty, range.lowerBound >= 0, range.upperBound <= sampleCount else { return nil }
        let duration = Double(sampleCount) / 16_000, start = Double(range.lowerBound) / 16_000, end = Double(range.upperBound) / 16_000
        var remainingBytes = DictionaryLearningRecording.maximumFeatureBytes
        var best: (frames: DictionaryAudioInspection.Frames, balanced: Double, total: Double)?
        for window in windows {
            try Task.checkCancellation()
            let frames = window.frames
            guard window.extractorVersion == GigaAMEncoderFeatures.extractorVersion,
                  frames.hiddenSize == GigaAMEncoderFeatures.dimension, frames.frameDuration == GigaAMEncoderFeatures.frameDuration,
                  frames.offset.isFinite, frames.offset >= 0, frames.offset < duration, !frames.values.isEmpty,
                  frames.values.count % GigaAMEncoderFeatures.dimension == 0,
                  frames.values.count <= remainingBytes / MemoryLayout<Float>.size,
                  frames.offset + Double(frames.count - 1) * frames.frameDuration < duration + 1e-9,
                  frames.values.allSatisfy(\.isFinite) else { return nil }
            remainingBytes -= frames.values.count * MemoryLayout<Float>.size
            let frameEnd = frames.offset + Double(frames.count) * frames.frameDuration
            guard frames.offset <= start + 1e-9, frameEnd >= end - 1e-9 else { continue }
            let left = max(0, start - frames.offset), right = max(0, min(frameEnd, duration) - end)
            let balanced = min(left, right), total = left + right
            if let prior = best, balanced < prior.balanced - 1e-9 ||
                (abs(balanced - prior.balanced) <= 1e-9 && total <= prior.total + 1e-9) { continue }
            best = (frames, balanced, total)
        }
        guard let source = best?.frames else { return nil }
        let lower = max(0, Int(floor((start - source.offset) / source.frameDuration + 1e-8)))
        let upper = min(source.count, Int(ceil((end - source.offset) / source.frameDuration - 1e-8)))
        guard lower < upper, upper - lower <= GigaAMEncoderFeatures.maximumFrames else { return nil }
        let features = try GigaAMEncoderFeatures(values: Array(source.values[
            (lower * GigaAMEncoderFeatures.dimension)..<(upper * GigaAMEncoderFeatures.dimension)]))
        return (features, .init(offset: source.offset + Double(lower) * source.frameDuration,
            frameDuration: source.frameDuration, hiddenSize: source.hiddenSize, values: features.values))
    }
}
