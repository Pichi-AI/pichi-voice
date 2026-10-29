#if DICTIONARY_TRAINING_REQUEST_STANDALONE
import Foundation

struct DictionaryLearningAudioEvidence { let samples: [Float] }
struct DictionaryNegativeCorrection {}
struct PrivateProfileSnapshot: Equatable {
    let id: String
    let generation: UUID
}
enum PrivateProfileStorage {
    static var current = PrivateProfileSnapshot(id: "synthetic-one", generation: UUID())
    static var acceptsNewWork = true
    static func isReadable(_ value: PrivateProfileSnapshot) -> Bool { value == current && acceptsNewWork }
}
struct TranscriptionHistoryEntry {
    let id: UUID
    let rawText: String
    let processedText: String
    var clipboardText: String? { processedText }
}

@main struct DictionaryWordTrainingRequestTests {
    static func main() {
        let profile = PrivateProfileStorage.current
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "IINblement", correctedText: "AI Enablement")
        let request = DictionaryWordTrainingRequest(candidate: candidate)!
        precondition(request.isCurrent)
        precondition(DictionaryWordTrainingRequest(candidate: candidate, now: Date().addingTimeInterval(-121))?.isCurrent == false)
        precondition(DictionaryWordTrainingRequest(candidate: .init(heardText: "same", correctedText: "same")) == nil)
        precondition(DictionaryWordTrainingRequest(candidate: .init(heardText: "word", correctedText: "five words in this sentence")) == nil)
        var oversized = candidate
        oversized.audioEvidence = .init(samples: [Float](repeating: 0, count: 238_081))
        precondition(DictionaryWordTrainingRequest(candidate: oversized) == nil)

        let id = UUID(), source = "same first same second"
        let range = (source as NSString).range(of: "same", options: .backwards)
        let selection = DictionaryHistoryWordSelection(entryID: id, sourceText: source, range: range, isOriginal: false)!
        precondition(selection.range.location == 11 && selection.heardText == "same")
        let entry = TranscriptionHistoryEntry(id: id, rawText: "original", processedText: source)
        precondition(selection.matches(entry))
        precondition(!selection.matches(.init(id: id, rawText: "original", processedText: "changed")))
        precondition(!selection.matches(.init(id: UUID(), rawText: "original", processedText: source)))
        precondition(DictionaryHistoryWordSelection(entryID: id, sourceText: source, range: NSRange(location: NSNotFound, length: 2), isOriginal: false) == nil)
        precondition(DictionaryHistoryWordSelection(entryID: id, sourceText: source, range: NSRange(location: 0, length: source.utf16.count + 1), isOriginal: false) == nil)

        PrivateProfileStorage.acceptsNewWork = false
        precondition(!request.isCurrent && !selection.matches(entry))
        precondition(DictionaryWordTrainingRequest(candidate: candidate) == nil)
        PrivateProfileStorage.acceptsNewWork = true
        PrivateProfileStorage.current = .init(id: profile.id, generation: UUID())
        precondition(!request.isCurrent && !selection.matches(entry))
        precondition(DictionaryWordTrainingRequest(candidate: candidate, profile: profile) == nil)
        print("Dictionary request profile, selection, and bounded audio checks passed")
    }
}
#endif
