import Foundation

/// One delivered utterance can update only its admitted history row. Dictionary
/// persistence and its Undo receipt have separate lifetimes from explicit text edits.
@MainActor
final class DictationHistoryCorrectionSession {
    private let history: TranscriptionHistoryStore
    private let profile: PrivateProfileSnapshot
    private let entryID: UUID
    private let deliveredText: String
    private var expectedSource: String
    private var expectedFinal: String
    private var sourceMap: DictionaryCorrectionTextMap
    private var finalMap: DictionaryCorrectionTextMap?

    init?(history: TranscriptionHistoryStore, entryID: UUID, deliveredText: String,
          profile: PrivateProfileSnapshot) {
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              let entry = history.entries.first(where: { $0.id == entryID }),
              entry.processedText == deliveredText || entry.clipboardText == deliveredText else { return nil }
        self.history = history
        self.profile = profile
        self.entryID = entryID
        self.deliveredText = deliveredText
        self.expectedSource = entry.sourceTranscriptText
        self.expectedFinal = entry.processedText
        self.sourceMap = DictionaryCorrectionTextMap(originalText: entry.sourceTranscriptText)
        self.finalMap = entry.clipboardText == deliveredText ? DictionaryCorrectionTextMap(originalText: deliveredText) : nil
    }

    @discardableResult
    func apply(originalDeliveredRange: NSRange, replacement: String, replacesAllOccurrences: Bool = true) -> Bool {
        guard PrivateProfileStorage.isReadable(self.profile), PrivateProfileStorage.acceptsNewWork,
              let entry = self.history.entries.first(where: { $0.id == self.entryID }),
              entry.sourceTranscriptText == self.expectedSource, entry.processedText == self.expectedFinal else { return false }
        let sourceRange = self.sourceMap.text == self.expectedSource ? DictionaryLearningAlignmentResolver.textRange(in: self.sourceMap.originalText,
            delivered: self.deliveredText, selected: originalDeliveredRange)
            .flatMap { self.sourceMap.currentRange(forOriginal: $0) } : nil
        let finalRange = self.finalMap?.currentRange(forOriginal: originalDeliveredRange)
        let isOriginal = sourceRange != nil
        guard let range = sourceRange ?? finalRange else { return false }
        let before = isOriginal ? entry.sourceTranscriptText : (entry.clipboardText ?? "")
        let protected = isOriginal ? entry.currentDictionaryReplacements.map(\.range) : []
        let plan = replacesAllOccurrences ? DictionaryCorrectionReplacementPlan(sourceText: before, range: range,
            replacement: replacement, protectedRanges: protected) : nil
        guard self.history.applyWordCorrection(entryID: self.entryID, expectedText: before, range: range,
            replacement: replacement, profile: self.profile, isOriginal: isOriginal, replacesAllOccurrences: replacesAllOccurrences),
              let updated = self.history.entries.first(where: { $0.id == self.entryID }) else { return false }
        if isOriginal {
            for edit in (plan?.ranges ?? [range]).reversed() { _ = self.sourceMap.replace(range: edit, replacement: replacement) }
        }
        // Keep final-only mapping only while the persisted formatter projection is
        // exactly the same explicit replacement plan. Never guess after a rewrite.
        let finalProtected = entry.currentDictionaryReplacements.compactMap {
            DictionaryLearningAlignmentResolver.textRange(in: entry.clipboardText ?? "", delivered: entry.sourceTranscriptText, selected: $0.range)
        }
        if var map = self.finalMap, let finalRange,
           let finalPlan = DictionaryCorrectionReplacementPlan(sourceText: map.text, range: finalRange, replacement: replacement, protectedRanges: finalProtected),
           (replacesAllOccurrences ? finalPlan.text : (map.text as NSString).replacingCharacters(in: finalRange, with: replacement)) == updated.clipboardText {
            for edit in (replacesAllOccurrences ? finalPlan.ranges : [finalRange]).reversed() { _ = map.replace(range: edit, replacement: replacement) }
            self.finalMap = map
        } else { self.finalMap = nil }
        self.expectedSource = updated.sourceTranscriptText
        self.expectedFinal = updated.processedText
        return true
    }

    func dictionaryRejection(originalDeliveredRange: NSRange, replacement: String) -> DictionaryHistoryReplacement? {
        guard let entry = self.history.entries.first(where: { $0.id == self.entryID }),
              entry.sourceTranscriptText == self.expectedSource, entry.processedText == self.expectedFinal,
              let original = DictionaryLearningAlignmentResolver.textRange(in: self.sourceMap.originalText,
                delivered: self.deliveredText, selected: originalDeliveredRange),
              let range = self.sourceMap.currentRange(forOriginal: original) else { return nil }
        return entry.currentDictionaryReplacements.first { $0.range == range &&
            DictionaryNegativeEvidenceResolver.normalized($0.label) != DictionaryNegativeEvidenceResolver.normalized(replacement) }
    }

}
