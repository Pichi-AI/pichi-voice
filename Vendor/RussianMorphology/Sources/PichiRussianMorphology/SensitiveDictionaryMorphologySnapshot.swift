import Foundation
import CRussianMorphology

public enum SensitiveDictionaryMorphologyError: Error, Equatable {
    case invalidWord, resourceFailure, paradigmTooLarge
}

/// A stateless view over a fixed, compiled Russian morphological dictionary.
/// It does not guess suffixes for unknown names, retain user words, or load a model.
/// Call at rule admission and retain only the resulting bounded word sets.
public struct SensitiveDictionaryMorphologySnapshot: Sendable {
    public static let resourceIdentity = "libmorph-russian-v1/2d3251b2ccd9f7720888634a4175e9af70e341fff08e1b958dc4e371d55d5357"
    public init() {}

    /// Includes every dictionary interpretation of an ambiguous spelling.
    /// Unknown words return nil, allowing the caller to retain exact matching.
    public func forms(for word: String) throws -> Set<String>? {
        let normalized = Self.normalize(word)
        guard !normalized.isEmpty,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw SensitiveDictionaryMorphologyError.invalidWord }
        // Long terms and other scripts remain valid exact rules. Keep tokens
        // the Russian lexicon cannot expand outside the native CP1251 decoder.
        guard normalized.utf8.count <= 128, normalized.unicodeScalars.allSatisfy({
            (0x0430...0x044F).contains($0.value) || $0.value == 0x0451 || $0.value == 0x2D
        }) else { return nil }
        var output = [CChar](repeating: 0, count: 65_536)
        var written = 0
        var count = 0
        let result = normalized.withCString { input in
            pichi_russian_word_forms(input, normalized.utf8.count, &output, output.count, &written, &count)
        }
        if result == 0 { return nil }
        if result == -2 { throw SensitiveDictionaryMorphologyError.paradigmTooLarge }
        guard result == 1, written > 0, written <= output.count, count > 0, count <= 512,
              output[written - 1] == 0 else { throw SensitiveDictionaryMorphologyError.resourceFailure }
        var forms: Set<String> = []
        var start = 0
        var decodedCount = 0
        for end in 0..<written where output[end] == 0 {
            let bytes = output[start..<end].map { UInt8(bitPattern: $0) }
            guard !bytes.isEmpty, let form = String(bytes: bytes, encoding: .utf8) else {
                throw SensitiveDictionaryMorphologyError.resourceFailure
            }
            forms.insert(Self.normalize(form))
            decodedCount += 1
            start = end + 1
        }
        guard start == written, decodedCount == count else { throw SensitiveDictionaryMorphologyError.resourceFailure }
        // A caller's original spelling remains valid even when the dictionary
        // stores the alternate Russian e/yo spelling.
        forms.insert(normalized)
        return forms
    }

    private static func normalize(_ word: String) -> String {
        word.precomposedStringWithCanonicalMapping
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
