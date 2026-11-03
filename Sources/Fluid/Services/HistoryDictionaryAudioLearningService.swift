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

    private func currentEntry(selection: DictionaryHistoryWordSelection, candidate: AutomaticDictionaryCorrectionCandidate) -> TranscriptionHistoryEntry? {
        guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
              let entry = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }) else { return nil }
        if selection.isOriginal { return entry.rawText == selection.sourceText ? entry : nil }
        let expected = (selection.sourceText as NSString).replacingCharacters(in: selection.range, with: candidate.correctedText)
        return entry.clipboardText == selection.sourceText || entry.clipboardText == expected ? entry : nil
    }

    nonisolated static func recordingID(entryID: UUID, fileName: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((entryID.uuidString + ":" + fileName).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
