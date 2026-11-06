import CryptoKit
import Foundation

/// Converts one explicitly selected retained recording into the existing bounded
/// evidence carrier. The dictionary wizard remains the only pronunciation editor.
@MainActor
final class HistoryDictionaryAudioLearningService {
    static let shared = HistoryDictionaryAudioLearningService()

    func enrich(candidate: AutomaticDictionaryCorrectionCandidate, selection: DictionaryHistoryWordSelection, correctionPlan: DictionaryCorrectionReplacementPlan? = nil) async -> AutomaticDictionaryCorrectionCandidate {
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled,
              PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
              let initial = self.currentEntry(selection: selection, candidate: candidate, correctionPlan: correctionPlan),
              let audio = initial.audio,
              let url = DictationAudioHistoryStore.scoped(to: selection.profile).audioFileURL(for: initial) else { return candidate }
        do {
            let recording = try await AppServices.shared.asr.historyDictionaryRecording(
                fileURL: url, recordingID: Self.recordingID(entryID: initial.id, fileName: audio.fileName), profile: selection.profile
            )
            try Task.checkCancellation()
            guard let current = self.currentEntry(selection: selection, candidate: candidate, correctionPlan: correctionPlan),
                  current.rawText == initial.rawText, current.audio == audio else { return candidate }
            let alignment = Self.alignmentSelection(history: initial, selection: selection, candidate: candidate, plan: correctionPlan)
            let evidence = try DictionaryLearningAlignmentResolver.resolve(
                recording: recording, deliveredTextBeforeEdit: alignment.text,
                selectedUTF16Range: alignment.range, observedText: alignment.observed
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

    /// An inline save approves the selected pronunciation and exact same-text repetitions.
    /// The shared worker owns preparation and persistence, retiring both with the profile.
    @discardableResult
    func enqueueInline(candidate: AutomaticDictionaryCorrectionCandidate, selection: DictionaryHistoryWordSelection, expectedText: String,
                       correctionPlan: DictionaryCorrectionReplacementPlan? = nil) -> Bool {
        guard let plan = correctionPlan ?? DictionaryCorrectionReplacementPlan(sourceText: selection.sourceText,
                  range: selection.range, replacement: candidate.correctedText),
              selection.isOriginal, candidate.sourceUTF16Range == selection.range,
              plan.text == expectedText,
              let confirmedRange = plan.mappedRange(selection.range),
              let history = self.currentEntry(selection: selection, candidate: candidate, correctionPlan: plan),
              history.sourceTranscriptText == expectedText, let audio = history.audio,
              let url = DictationAudioHistoryStore.scoped(to: selection.profile).audioFileURL(for: history),
              FileManager.default.fileExists(atPath: url.path),
              let dictionaryEntry = Self.targetEntry(candidate: candidate, selection: selection,
                  history: history, entries: SettingsStore.shared.customDictionaryEntries) else { return false }
        let wasNew = !SettingsStore.shared.customDictionaryEntries.contains(dictionaryEntry)
        let confirmation = history.sourceFragments.first { $0.range == confirmedRange && $0.text == candidate.correctedText && $0.isValid(in: expectedText) }
        let approvalID = confirmation?.correctionID
        let alignment = Self.alignmentSelection(history: history, selection: selection, candidate: candidate, plan: plan)
        let identity = "\(selection.entryID.uuidString):\(audio.fileName):\(selection.range.location):\(selection.range.length):\(dictionaryEntry.id.uuidString):\(selection.sourceText)"
        let evidenceID = Self.stableID(identity)
        let generation = DictionaryMatcherExperiment.generation
        let isValid: @MainActor () -> Bool = {
            guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
                  DictionaryMatcherExperiment.sharedFeaturesEnabled, generation == DictionaryMatcherExperiment.generation,
                  Self.entryStillEligible(dictionaryEntry, entries: SettingsStore.shared.customDictionaryEntries, allowMissing: wasNew),
                  FileManager.default.fileExists(atPath: url.path),
                  let current = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }) else { return false }
            let approvalStillPresent: Bool
            if let approvalID {
                approvalStillPresent = current.sourceFragments.contains {
                    $0.correctionID == approvalID && $0.text == candidate.correctedText && $0.isValid(in: current.sourceTranscriptText)
                }
            } else {
                // Legacy groups have no durable identity. Keep their conservative
                // snapshot guard until an explicit edit establishes provenance.
                approvalStillPresent = current.sourceTranscriptText == expectedText
            }
            return approvalStillPresent && current.rawText == history.rawText && current.audio == audio &&
                DictationAudioHistoryStore.scoped(to: selection.profile).audioFileURL(for: current) == url
        }
        let publishTarget: (@MainActor () -> DictionaryAudioLearningService.TargetPublication)?
        if wasNew {
            publishTarget = {
                guard isValid() else { return .rejected }
                if SettingsStore.shared.customDictionaryEntries.contains(dictionaryEntry) { return .unchanged }
                guard Self.entryStillEligible(dictionaryEntry, entries: SettingsStore.shared.customDictionaryEntries, allowMissing: true) else { return .rejected }
                SettingsStore.shared.customDictionaryEntries.append(dictionaryEntry)
                return .created
            }
        } else {
            publishTarget = nil
        }
        return DictionaryAudioLearningService.shared.enqueue(entry: dictionaryEntry, evidenceID: evidenceID, isValid: isValid,
            isCurrentBeforePreparation: isValid, publishTarget: publishTarget, didPublishTarget: {
                ASRService.invalidateDictionaryCache()
                DictionaryEntriesChangeNotice.post()
            }) {
            guard isValid() else { return nil }
            let recording = try await AppServices.shared.asr.historyDictionaryRecording(
                fileURL: url, recordingID: Self.recordingID(entryID: history.id, fileName: audio.fileName), profile: selection.profile, ownedByLearningWorker: true
            )
            try Task.checkCancellation()
            guard isValid() else { return nil }
            let evidence = try DictionaryLearningAlignmentResolver.resolve(
                recording: recording, deliveredTextBeforeEdit: alignment.text,
                selectedUTF16Range: alignment.range, observedText: alignment.observed
            )
            // A saved group's displayed spelling is already canonical. Preserve
            // the freshly aligned original ASR spelling as the learned error,
            // rather than teaching the matcher that the canonical label failed.
            let rawObserved = recording.alignment.words[evidence.sourceWordRange].map(\.text).joined(separator: " ")
            guard let observed = DictionaryCorrectionEditPolicy.acousticSpelling(rawObserved), isValid() else { return nil }
            return DictionaryLearningAudioEvidence(recordingID: evidence.recordingID, modelKey: evidence.modelKey,
                observedText: observed, sourceWordRange: evidence.sourceWordRange,
                sourceSampleRange: evidence.sourceSampleRange, focalSampleRange: evidence.focalSampleRange,
                samples: evidence.samples, featureFrames: evidence.featureFrames)
        }
    }

    /// Explicit replay of persisted user-confirmed groups, through the same worker
    /// as inline Save. A caller cannot supply new spellings, intervals or audio paths.
    func enqueueSavedCorrection(entryID: UUID, fragmentIndex: Int, expectedSourceText: String) -> Int {
        let profile = PrivateProfileStorage.current
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              let entry = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == entryID }),
              entry.sourceTranscriptText == expectedSourceText, entry.correctedRawText != nil, entry.audio != nil,
              (0..<128).contains(fragmentIndex), entry.sourceFragments.indices.contains(fragmentIndex) else { return 0 }
        let fragment = entry.sourceFragments[fragmentIndex]
        guard fragment.isValid(in: entry.sourceTranscriptText),
              let selection = DictionaryHistoryWordSelection(entryID: entry.id, sourceText: entry.sourceTranscriptText,
                  range: fragment.range, isOriginal: true) else { return 0 }
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: fragment.text, correctedText: fragment.text,
            sourceUTF16Range: fragment.range)
        return self.enqueueInline(candidate: candidate, selection: selection, expectedText: entry.sourceTranscriptText) ? 1 : 0
    }

    /// Existing spellings remain untouched; a new acoustic term never grants a text replacement.
    static func targetEntry(candidate: AutomaticDictionaryCorrectionCandidate, selection: DictionaryHistoryWordSelection,
                            history: TranscriptionHistoryEntry, entries: [SettingsStore.CustomDictionaryEntry]) -> SettingsStore.CustomDictionaryEntry? {
        let corrected = candidate.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DictionaryCorrectionEditPolicy.isTerm(corrected),
              let selected = DictionaryCorrectionEditPolicy.acousticSpelling(selection.heardText),
              let heard = DictionaryCorrectionEditPolicy.acousticSpelling(candidate.heardText), selected == heard else { return nil }
        if heard == corrected {
            guard history.correctedRawText != nil,
                  history.sourceFragments.contains(where: { $0.range == selection.range && $0.isValid(in: history.sourceTranscriptText) }) else { return nil }
        }
        let matches = entries.filter { $0.replacement.caseInsensitiveCompare(corrected) == .orderedSame }
        guard matches.count <= 1 else { return nil }
        return matches.first ?? SettingsStore.CustomDictionaryEntry(
            id: Self.stableID("history-acoustic-entry:" + corrected.lowercased()), triggers: [], replacement: corrected
        )
    }

    static func entryStillEligible(_ entry: SettingsStore.CustomDictionaryEntry, entries: [SettingsStore.CustomDictionaryEntry], allowMissing: Bool) -> Bool {
        let matches = entries.filter { $0.replacement.caseInsensitiveCompare(entry.replacement) == .orderedSame || $0.id == entry.id }
        return matches.isEmpty ? allowMissing : matches.count == 1 && matches[0] == entry
    }

    nonisolated private static func stableID(_ text: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func currentEntry(selection: DictionaryHistoryWordSelection, candidate: AutomaticDictionaryCorrectionCandidate,
                              correctionPlan: DictionaryCorrectionReplacementPlan? = nil) -> TranscriptionHistoryEntry? {
        guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
              let entry = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }) else { return nil }
        let expected = (correctionPlan ?? DictionaryCorrectionReplacementPlan(sourceText: selection.sourceText,
            range: selection.range, replacement: candidate.correctedText))?.text
        let currentText = selection.isOriginal ? entry.sourceTranscriptText : (entry.clipboardText ?? "")
        return currentText == selection.sourceText || currentText == expected ? entry : nil
    }

    private static func alignmentSelection(history: TranscriptionHistoryEntry, selection: DictionaryHistoryWordSelection,
                                           candidate: AutomaticDictionaryCorrectionCandidate,
                                           plan: DictionaryCorrectionReplacementPlan?) -> (text: String, range: NSRange, observed: String) {
        let currentRange = history.sourceTranscriptText == selection.sourceText ? selection.range :
            (plan ?? DictionaryCorrectionReplacementPlan(sourceText: selection.sourceText, range: selection.range,
                replacement: candidate.correctedText))?.mappedRange(selection.range)
        if let currentRange, let originalRange = history.originalSourceRange(for: currentRange) {
            let original = (history.rawText as NSString).substring(with: originalRange)
            if let observed = DictionaryCorrectionEditPolicy.acousticSpelling(original) {
                return (history.rawText, originalRange, observed)
            }
        }
        return (selection.sourceText, selection.range, candidate.heardText)
    }

    nonisolated static func recordingID(entryID: UUID, fileName: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data((entryID.uuidString + ":" + fileName).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
