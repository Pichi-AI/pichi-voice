import CryptoKit
import Foundation

/// Converts one explicitly selected retained recording into the existing bounded
/// evidence carrier. The dictionary wizard remains the only pronunciation editor.
@MainActor
final class HistoryDictionaryAudioLearningService {
    static let shared = HistoryDictionaryAudioLearningService()

    func enrich(candidate: AutomaticDictionaryCorrectionCandidate, selection: DictionaryHistoryWordSelection) async -> AutomaticDictionaryCorrectionCandidate {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
              PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
              let initial = self.currentEntry(selection: selection, candidate: candidate),
              let audio = initial.audio,
              let url = DictationAudioHistoryStore.scoped(to: selection.profile).audioFileURL(for: initial) else { return candidate }
        do {
            let recording = try await AppServices.shared.asr.historyDictionaryRecording(
                fileURL: url, recordingID: Self.recordingID(entryID: initial.id, fileName: audio.fileName), profile: selection.profile
            )
            try Task.checkCancellation()
            guard let current = self.currentEntry(selection: selection, candidate: candidate),
                  current.rawText == initial.rawText, current.audio == audio else { return candidate }
            let evidence = try DictionaryLearningAlignmentResolver.resolve(
                recording: recording, deliveredTextBeforeEdit: selection.sourceText,
                selectedUTF16Range: selection.range, observedText: candidate.heardText
            )
            var enriched = candidate
            enriched.audioEvidence = evidence
            return enriched
        } catch {
            // Missing or ambiguous old alignment falls back to the same wizard;
            // no guessed interval and no unrelated recording are substituted.
            return candidate
        }
    }

    /// An inline save is explicit approval for this occurrence only. Preparation and
    /// persistence are owned by the shared worker and retired with the private profile.
    @discardableResult
    func enqueueInline(candidate: AutomaticDictionaryCorrectionCandidate, selection: DictionaryHistoryWordSelection, expectedText: String) -> Bool {
        let matches = SettingsStore.shared.customDictionaryEntries.filter {
            $0.replacement.caseInsensitiveCompare(candidate.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        }
        guard matches.count == 1, let dictionaryEntry = matches.first,
              let history = self.currentEntry(selection: selection, candidate: candidate),
              history.sourceTranscriptText == expectedText, let audio = history.audio,
              let url = DictationAudioHistoryStore.scoped(to: selection.profile).audioFileURL(for: history) else { return false }
        let source = selection.sourceText
        let identity = "\(selection.entryID.uuidString):\(audio.fileName):\(selection.range.location):\(selection.range.length):\(dictionaryEntry.id.uuidString):\(source)"
        let evidenceID = Self.stableID(identity)
        let generation = DictionaryMatcherExperiment.generation
        let isValid: @MainActor () -> Bool = {
            guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
                  DictionaryMatcherExperiment.sharedFeaturesEnabled, generation == DictionaryMatcherExperiment.generation,
                  SettingsStore.shared.customDictionaryEntries.contains(dictionaryEntry),
                  let current = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }) else { return false }
            return current.sourceTranscriptText == expectedText && current.rawText == history.rawText && current.audio == audio &&
                DictationAudioHistoryStore.scoped(to: selection.profile).audioFileURL(for: current) == url
        }
        return DictionaryAudioLearningService.shared.enqueue(entry: dictionaryEntry, evidenceID: evidenceID, isValid: isValid) {
            guard isValid() else { return nil }
            let recording = try await AppServices.shared.asr.historyDictionaryRecording(
                fileURL: url, recordingID: Self.recordingID(entryID: history.id, fileName: audio.fileName), profile: selection.profile, ownedByLearningWorker: true
            )
            try Task.checkCancellation()
            guard isValid() else { return nil }
            let evidence = try DictionaryLearningAlignmentResolver.resolve(
                recording: recording, deliveredTextBeforeEdit: source,
                selectedUTF16Range: selection.range, observedText: candidate.heardText
            )
            // A saved group's displayed spelling is already canonical. Preserve
            // the freshly aligned original ASR spelling as the learned error,
            // rather than teaching the matcher that the canonical label failed.
            let rawObserved = recording.alignment.words[evidence.sourceWordRange].map(\.text).joined(separator: " ")
            guard let observed = DictionaryCorrectionEditPolicy.acousticSpelling(rawObserved) else { return nil }
            return DictionaryLearningAudioEvidence(recordingID: evidence.recordingID, modelKey: evidence.modelKey,
                observedText: observed, sourceWordRange: evidence.sourceWordRange,
                sourceSampleRange: evidence.sourceSampleRange, focalSampleRange: evidence.focalSampleRange,
                samples: evidence.samples, featureFrames: evidence.featureFrames)
        }
    }

    /// Explicit replay of persisted user-confirmed groups, through the same worker
    /// as inline Save. A caller cannot supply new spellings, intervals or audio paths.
    func enqueueSavedCorrections(entryID: UUID) -> Int {
        let profile = PrivateProfileStorage.current
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              let entry = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == entryID }),
              entry.correctedRawText != nil, entry.audio != nil else { return 0 }
        var queued = 0
        for fragment in entry.sourceFragments.prefix(128) {
            guard fragment.isValid(in: entry.sourceTranscriptText),
                  let selection = DictionaryHistoryWordSelection(entryID: entry.id, sourceText: entry.sourceTranscriptText,
                      range: fragment.range, isOriginal: true) else { continue }
            let candidate = AutomaticDictionaryCorrectionCandidate(heardText: fragment.text, correctedText: fragment.text,
                sourceUTF16Range: fragment.range)
            if self.enqueueInline(candidate: candidate, selection: selection, expectedText: entry.sourceTranscriptText) { queued += 1 }
        }
        return queued
    }

    nonisolated private static func stableID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func currentEntry(selection: DictionaryHistoryWordSelection, candidate: AutomaticDictionaryCorrectionCandidate) -> TranscriptionHistoryEntry? {
        guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
              let entry = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }) else { return nil }
        let expected = (selection.sourceText as NSString).replacingCharacters(in: selection.range, with: candidate.correctedText)
        let currentText = selection.isOriginal ? entry.sourceTranscriptText : (entry.clipboardText ?? "")
        return currentText == selection.sourceText || currentText == expected ? entry : nil
    }

    nonisolated static func recordingID(entryID: UUID, fileName: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((entryID.uuidString + ":" + fileName).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
