import Foundation
#if os(macOS)
import AppKit
#endif

/// Read-only evidence from installed system spelling lexicons. A recognized word
/// is never eligible for the acoustic matcher's weaker unknown-term path.
@MainActor
enum DictionaryLexicalEvidence {
    static func isUnknownTerm(_ text: String, requiredLanguages: [String]) -> Bool {
        #if os(macOS)
        guard !text.isEmpty, text.count <= 80, text.rangeOfCharacter(from: .newlines) == nil,
              !requiredLanguages.isEmpty else { return false }
        let components = text.precomposedStringWithCanonicalMapping.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.nonBaseCharacters).inverted)
            .filter { !$0.isEmpty }
        guard (1...4).contains(components.count), components.allSatisfy({
            $0.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }) else { return false }

        let checker = NSSpellChecker.shared
        let available = checker.availableLanguages
        let bases = Set(available.compactMap(self.languageBase))
        let required = requiredLanguages.compactMap(self.languageBase)
        guard required.count == requiredLanguages.count,
              required.allSatisfy(bases.contains), !available.isEmpty else { return false }

        let document = NSSpellChecker.uniqueSpellDocumentTag()
        defer { checker.closeSpellDocument(withTag: document) }
        for word in components {
            let characters = Array(word)
            let canary = String((0..<24).map { characters[characters.count - 1 - ($0 % characters.count)] })
            let input = word + " " + canary
            let wordLength = word.utf16.count
            var hasUnknownEvidence = false
            for language in available {
                let misspelling = checker.checkSpelling(
                    of: input, startingAt: 0, language: language, wrap: false,
                    inSpellDocumentWithTag: document, wordCount: nil
                )
                // A dictionary may silently ignore a foreign script. A misspelling
                // in the same-script canary proves it actually checked this input;
                // only then does accepting the first word mean lexical recognition.
                guard misspelling.location != NSNotFound, misspelling.length > 0 else { continue }
                if misspelling.location >= wordLength + 1 { return false }
                if misspelling.location < wordLength { hasUnknownEvidence = true }
            }
            guard hasUnknownEvidence else { return false }
        }
        return true
        #else
        return false
        #endif
    }

    private static func languageBase(_ identifier: String) -> String? {
        guard let base = identifier.replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first?.lowercased(), (2...3).contains(base.count),
              base.utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        return base
    }
}
