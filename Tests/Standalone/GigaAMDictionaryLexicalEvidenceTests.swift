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
        print("PASS: comparison keys, changed components, recorded variants, lexical vetoes, protected content, bounds and missing lexicons")
    }
}
#endif
