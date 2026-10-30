#if GIGAAM_LEXICAL_EVIDENCE_STANDALONE
import Foundation

@main struct GigaAMDictionaryLexicalEvidenceTests {
    @MainActor static func main() {
        print("Required local lexicon available: \(DictionaryLexicalEvidence.hasRequiredLexicons(["ru"]))")
        func comparison(_ heard: String, _ canonical: String, _ variants: [String]) -> GigaAMDictionaryLexicalEvidence.Comparison {
            GigaAMDictionaryLexicalEvidence.compare(heard: heard, canonical: canonical, observedVariants: variants)!
        }
        let unchanged = comparison("Xyqra Voice", "XyqroVoice", ["Xyqra Voice"])
        precondition(unchanged.changedSourceComponents == ["Xyqra"])
        precondition(unchanged.changedTargetComponents == ["XyqroVoice"])
        precondition(unchanged.matchesObservedVariant && unchanged.observedSimilarity == 1)
        precondition(comparison("clod", "Claude", ["clod"]).canonicalSimilarity == 1)
        precondition(comparison("клод", "Claude", ["clod"]).canonicalSimilarity == 1)
        precondition(comparison("CatGPT", "ChatGPT", ["Cat GPT"]).canonicalSimilarity >= 0.8)
        precondition(comparison("Pichivoice", "PichiVoice", []).changedSourceComponents.isEmpty)
        precondition(GigaAMDictionaryLexicalEvidence.compare(heard: String(repeating: "x", count: 81), canonical: "Example", observedVariants: []) == nil)
        precondition(GigaAMDictionaryLexicalEvidence.compare(heard: "one two three four five", canonical: "Example", observedVariants: []) == nil)
        func stem(_ heard: String, _ canonical: String, _ variants: [String]) -> Bool {
            GigaAMDictionaryLexicalEvidence.observedStemSupport(heard: heard, canonical: canonical, observedVariants: variants)
        }
        for ending in ["", "е", "а", "у", "ом", "ем"] {
            precondition(stem("Клод" + ending, "Claude", ["Clod"]))
        }
        precondition(stem("альфау", "Alfa", ["альфа"])) // No vowel contraction across the stem/ending boundary.
        precondition(stem("клодкоде", "ClaudeCode", ["клодкод"])) // Fused recorded ASR spelling.
        precondition(stem("Clod Codee", "Claude Code", ["Clod Code"]))
        precondition(!stem("Clod Codeem", "Claude Code", ["Clod Code"])) // Existing compound proof stays conservative.
        for heard in ["кладе", "кледе", "клооде", "клдо", "клодай", "клодAI", "клодкод", "клоджж", "клодами"] {
            precondition(!stem(heard, "Claude", ["клод"]))
        }
        precondition(!stem("код", "Code", ["код"])) // A short ordinary stem is insufficient.
        precondition(!stem("печи", "Pichi", ["пичи"])) // Internal vowel substitution is not an ending.
        precondition(!stem("clud", "Claude", ["clood"])) // No internal vowel deletion or contraction.
        precondition(!stem("Clod", "Claude", [])) // Canonical spelling cannot manufacture observed evidence.
        precondition(!stem("Clod", "Claude AI", ["Clod"]))
        precondition(!stem("Clod", "Claude Code", ["Clod"]))
        precondition(!stem("Clod AI", "Claude AI", ["Clod"]))
        precondition(!stem("Clod A", "Claude", ["Clod"])) // A separate token is never a suffix.
        precondition(!stem("Clod e", "Claude", ["Clod"]))
        precondition(!stem("Clod to", "Claude", ["Clod"]))
        precondition(!stem("не Clod", "Claude", ["не Clod"]))
        precondition(!stem("Clod 5", "Claude 4", ["Clod 5"]))
        precondition(!stem("Clod", "Claude", Array(repeating: "Clod", count: 21)))
        precondition(!stem(String(repeating: "x", count: 81), "Claude", ["Clod"]))
        precondition(!stem("one two three four five", "Claude", ["one two three four five"]))
        for heard in ["Alfadesk", "Alfa Desktop", "AlfaAI", "alfaai", "Alphabet", "клоткот", "Clod a"] {
            let canonical = heard.hasPrefix("Al") || heard.hasPrefix("al") ? "Alpha" : "Claude"
            precondition(GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: heard, canonical: canonical))
        }
        for heard in ["Clod", "клод", "клода", "клоду", "клоде", "клодом", "клодем"] {
            precondition(!GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: heard, canonical: "Claude"))
        }
        precondition(!GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: "Alfa Desk", canonical: "Alpha Desktop"))
        precondition(!GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: "клодкот", canonical: "Claude Code"))
        precondition(GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: "Alfa e", canonical: "Alpha"))
        precondition(GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: "clodx", canonical: "Claude"))
        precondition(GigaAMDictionaryLexicalEvidence.dropsSourceComponents(heard: "chatgptx", canonical: "ChatGPT"))
        for pair in [("не зови", "зови"), ("мне", "тебе"), ("Call model 4", "Call model 5"), ("don't call", "call"),
                     ("you help me", "me help you"), ("couldn't call", "call")] {
            precondition(comparison(pair.0, pair.1, [pair.0]).protectsContent)
        }
        let unknown = GigaAMDictionaryLexicalEvidence.assess(heard: "Xyqra Voice", canonical: "Xyqro Voice", observedVariants: ["Xyqra Voice"], requiredLanguages: ["ru"])
        if DictionaryLexicalEvidence.hasRequiredLexicons(["ru"]) {
            precondition(unknown.allowsWeakCorrection && unknown.reason == .unknownChangedComponents)
            let identifier = GigaAMDictionaryLexicalEvidence.assess(heard: "CatGPT", canonical: "ChatGPT", observedVariants: ["CatGPT"], requiredLanguages: ["ru"])
            precondition(identifier.allowsWeakCorrection && identifier.comparison?.changedSourceComponents == ["CatGPT"])
            let ordinaryToken = GigaAMDictionaryLexicalEvidence.assess(heard: "Cat GPT", canonical: "Chat GPT", observedVariants: ["Cat GPT"], requiredLanguages: ["ru"])
            precondition(!ordinaryToken.allowsWeakCorrection && ordinaryToken.requiresStrictAcousticEvidence)
            for pair in [("Peach Voice", "Pitch Voice"), ("clod", "Claude"), ("печи", "Xyqro")] {
                let known = GigaAMDictionaryLexicalEvidence.assess(heard: pair.0, canonical: pair.1, observedVariants: [pair.0], requiredLanguages: ["ru"])
                precondition(!known.allowsWeakCorrection && known.requiresStrictAcousticEvidence)
            }
        } else { precondition(!unknown.allowsWeakCorrection && unknown.reason == .lexiconUnavailable) }
        let missing = GigaAMDictionaryLexicalEvidence.assess(heard: "Xyqra Voice", canonical: "Xyqro Voice", observedVariants: ["Xyqra Voice"], requiredLanguages: ["zz"])
        precondition(!missing.allowsWeakCorrection && missing.reason == .lexiconUnavailable)
        let noReference = GigaAMDictionaryLexicalEvidence.assess(heard: "Xyqra Voice", canonical: "Xyqro Voice", observedVariants: [], requiredLanguages: ["ru"])
        precondition(!noReference.allowsWeakCorrection && noReference.reason == .noObservedVariant)
        let started = ContinuousClock.now
        for _ in 0..<10 {
            _ = GigaAMDictionaryLexicalEvidence.assess(heard: "Xyqra Voice", canonical: "Xyqro Voice", observedVariants: ["Xyqra Voice"], requiredLanguages: ["ru"])
        }
        let elapsed = started.duration(to: .now).components
        print("Ten uncached lexical assessments milliseconds: \(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)")
        print("PASS: comparison keys, observed stems and bounded endings, changed components, recorded variants, lexical vetoes, protected content, bounds and missing lexicons")
    }
}
#endif
