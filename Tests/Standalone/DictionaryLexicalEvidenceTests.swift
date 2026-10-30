#if DICTIONARY_LEXICAL_STANDALONE && os(macOS)
import AppKit
import Foundation

@main struct DictionaryLexicalEvidenceTests {
    @MainActor static func main() {
        let available = NSSpellChecker.shared.availableLanguages
        let russianAvailable = available.contains { $0.replacingOccurrences(of: "_", with: "-").split(separator: "-").first?.lowercased() == "ru" }
        FileHandle.standardError.write(Data("Available local spelling lexicons: \(available.count); required lexicon available: \(russianAvailable)\n".utf8))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("syntheticnonsense", requiredLanguages: ["zz-UNAVAILABLE"]))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("syntheticnonsense", requiredLanguages: []))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("123", requiredLanguages: ["ru"]))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("one two three four five", requiredLanguages: ["ru"]))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("first\nsecond", requiredLanguages: ["ru"]))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("печи", requiredLanguages: ["ru"]))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("модель", requiredLanguages: ["ru"]))
        precondition(!DictionaryLexicalEvidence.isUnknownTerm("работа", requiredLanguages: ["ru"]))
        for term in ["user", "experience", "dictionary", "model", "example", "модели", "словарь", "привет"] {
            precondition(!DictionaryLexicalEvidence.isUnknownTerm(term, requiredLanguages: ["ru"]))
        }
        if russianAvailable {
            for term in ["ыфжщцхъыфжщцхъ", "GigM", "Бимчик"] {
                precondition(DictionaryLexicalEvidence.isUnknownTerm(term, requiredLanguages: ["ru"]), "Expected synthetic unknown term to remain unknown")
            }
            precondition(!DictionaryLexicalEvidence.isUnknownTerm("GigM печи", requiredLanguages: ["ru"]))
            precondition(!DictionaryLexicalEvidence.isUnknownTerm("GigM модель", requiredLanguages: ["ru_RU"]))
            precondition(!DictionaryLexicalEvidence.isUnknownTerm("GigM работа", requiredLanguages: ["ru-RU"]))
        } else {
            precondition(!DictionaryLexicalEvidence.isUnknownTerm("ыфжщцхъыфжщцхъ", requiredLanguages: ["ru"]))
        }
        let clock = ContinuousClock()
        let started = clock.now
        for _ in 0..<10 { _ = DictionaryLexicalEvidence.isUnknownTerm("Бимчик", requiredLanguages: ["ru"]) }
        let duration = started.duration(to: clock.now).components
        let milliseconds = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        print("Ten repeated local checks elapsed milliseconds: \(milliseconds)")
        print("Local spelling evidence known-word, phrase, bounds, and fail-closed checks passed")
    }
}
#endif
