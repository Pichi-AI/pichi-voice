import Foundation

/// One user-approved handoff into the existing dictionary wizard. The view owns
/// this payload only until consumption; audio never enters a global request queue.
struct DictionaryWordTrainingRequest: Identifiable {
    let id = UUID()
    let profile: PrivateProfileSnapshot
    let candidate: AutomaticDictionaryCorrectionCandidate
    private let expiresAt: Date

    init?(candidate: AutomaticDictionaryCorrectionCandidate, profile: PrivateProfileSnapshot = PrivateProfileStorage.current, now: Date = Date()) {
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              DictionaryCorrectionEditPolicy.isTerm(candidate.heardText),
              DictionaryCorrectionEditPolicy.isTerm(candidate.correctedText),
              candidate.heardText != candidate.correctedText,
              candidate.audioEvidence.map({ !$0.samples.isEmpty && $0.samples.count <= 238_080 }) ?? true
        else { return nil }
        self.profile = profile
        self.candidate = candidate
        self.expiresAt = now.addingTimeInterval(120)
    }

    var isCurrent: Bool {
        Date() < self.expiresAt && PrivateProfileStorage.isReadable(self.profile) && PrivateProfileStorage.acceptsNewWork
    }
}

extension Notification.Name {
    static let openDictionaryWordTraining = Notification.Name("OpenDictionaryWordTraining")
}

/// Selection is tied to the complete displayed snapshot and exact UTF-16 range.
/// A repeated word elsewhere in the same transcript cannot become the selected one.
struct DictionaryHistoryWordSelection: Identifiable {
    let id = UUID()
    let entryID: UUID
    let sourceText: String
    let range: NSRange
    let isOriginal: Bool
    let profile: PrivateProfileSnapshot

    init?(entryID: UUID, sourceText: String, range: NSRange, isOriginal: Bool) {
        let text = sourceText as NSString
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.location <= text.length, range.length <= text.length - range.location else { return nil }
        let selected = text.substring(with: range)
        guard DictionaryCorrectionEditPolicy.isTerm(selected) else { return nil }
        self.entryID = entryID
        self.sourceText = sourceText
        self.range = range
        self.isOriginal = isOriginal
        self.profile = PrivateProfileStorage.current
    }

    var heardText: String { (self.sourceText as NSString).substring(with: self.range) }

    func matches(_ entry: TranscriptionHistoryEntry) -> Bool {
        PrivateProfileStorage.isReadable(self.profile) && PrivateProfileStorage.acceptsNewWork &&
            entry.id == self.entryID && (self.isOriginal ? entry.rawText : (entry.clipboardText ?? "")) == self.sourceText
    }
}
