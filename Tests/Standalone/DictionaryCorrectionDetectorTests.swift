#if DICTIONARY_CORRECTION_STANDALONE
import Foundation

struct DictionaryLearningAudioEvidence {}
struct DictionaryNegativeCorrection {}

@main struct DictionaryCorrectionDetectorTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        self.checks += 1
        precondition(condition, message)
    }

    static func candidate(_ before: String, _ after: String) -> AutomaticDictionaryCorrectionCandidate? {
        let range = NSRange(location: 0, length: (before as NSString).length)
        guard let change = AutomaticDictionaryCorrectionDetector.textChange(before: before, after: after) else { return nil }
        let atEnd = AutomaticDictionaryCorrectionDetector.isWordContinuationAtInsertedRangeEnd(change, after: after, insertedRange: range)
        guard AutomaticDictionaryCorrectionDetector.isChangeInsideInsertedRange(change, insertedRange: range, allowsInsertionAtEnd: atEnd) else { return nil }
        return AutomaticDictionaryCorrectionDetector.candidate(before: before, after: after, insertedRange: range, allowsInsertionAtEnd: true)
    }

    static func main() {
        let rejected = [
            ("cat", "cats"), ("cats", "cat"), ("box", "boxes"), ("party", "parties"),
            ("file", "file's"), ("file", "file’s"), ("walk", "walked"), ("walk", "walking"),
            ("move", "moving"), ("move", "moved"), ("The cat sits", "The cats sits"),
            ("I use tools", "I use better tools"), ("I use tools daily", "I use tools often daily"),
            ("cat", "black cat"), ("cat", "cat today"), ("black cat", "cat"),
            ("hello", "hello"), ("hello", "hello!"), ("hello", ""),
            ("use foo now", "use bar baz now"), ("use foo now", "use bar,baz now"),
            ("use foo now", "use bar.baz now"), ("use foo now", "use bar/baz now"),
            ("I met foo bar today", "I met baz today"),
            ("AI. Enablement", "AI Enablement"),
        ]
        for (before, after) in rejected {
            self.expect(self.candidate(before, after) == nil, "Reject \(before) → \(after)")
        }
        let accepted = [
            ("Jon", "John"), ("Barat", "Barath"), ("Barad", "Barath"),
            ("Dflash", "DFlash"), ("manimekali", "Manimekalai"), ("Jhon", "John"),
            ("O'Neal", "O'Neill"), ("Anne-Mari", "Anne-Marie"), ("Jose", "José"),
            ("Jo", "Jos"), ("東京", "京都"), ("foo", "Kubernetes"), ("helllo", "hello"),
            ("IINblement", "AI Enablement"), ("yoser Experiens", "User Experience"),
        ]
        for (before, after) in accepted {
            let result = self.candidate(before, after)
            self.expect(result?.heardText == before && result?.correctedText == after, "Keep \(before) → \(after)")
        }
        self.expect(!DictionaryCorrectionEditPolicy.isTerm("one two three four five"), "Limit selected terms to four words")
        self.expect(!DictionaryCorrectionEditPolicy.isTerm("first\nsecond"), "Reject multiline selection")
        self.expect(!DictionaryCorrectionEditPolicy.isTerm(String(repeating: "x", count: 81)), "Bound selection length")
        self.expect(DictionaryCorrectionEditPolicy.acousticSpelling("Pch&I.") == "Pch I", "Retain a native fused-letter spelling for acoustic learning")
        self.expect(DictionaryCorrectionEditPolicy.acousticSpelling("  PCEI. ") == "PCEI", "Native sentence punctuation must not drop the pronunciation sample")
        self.expect(DictionaryCorrectionEditPolicy.acousticSpelling("Pici и I,") == "Pici и I", "Keep the actual letter case and source tokens")
        self.expect(DictionaryCorrectionEditPolicy.acousticSpelling("first. second") == nil, "Internal sentence punctuation is not a selected dictionary term")
        self.expect(DictionaryCorrectionEditPolicy.acousticSpelling("first\nsecond") == nil, "Do not join different lines into a learned word")
        self.expect(DictionaryCorrectionEditPolicy.allows(heard: "Home Assistent", corrected: "Home Assistant"), "Allow a selected short term repair")
        self.expect(DictionaryTrainingSpellingPolicy.exactTriggers(accepted: ["BIMCheck"], manuallyConfirmed: [], acousticCorrection: true).isEmpty,
                    "A spoken AI Enablement correction must not globally replace the valid term BIMCheck")
        self.expect(DictionaryTrainingSpellingPolicy.exactTriggers(accepted: ["BIMCheck", "other"], manuallyConfirmed: ["BIMCheck"], acousticCorrection: true) == ["BIMCheck"],
                    "Only explicit fixed text choices become exact triggers")
        self.expect(DictionaryTrainingSpellingPolicy.exactTriggers(accepted: ["BIMCheck"], manuallyConfirmed: [], acousticCorrection: false) == ["BIMCheck"],
                    "Ordinary manual dictionary workflow retains its existing spelling behavior")
        let punctuated = self.candidate("I met Barat.", "I met Barath.")
        self.expect(punctuated?.heardText == "Barat" && punctuated?.correctedText == "Barath", "Sentence punctuation")
        self.expect(punctuated?.sourceUTF16Range == ("I met Barat." as NSString).range(of: "Barat"), "Approval range excludes sentence punctuation")
        let before = "Title: I met Barat"
        self.expect(
            AutomaticDictionaryCorrectionDetector.candidate(before: before, after: "Heading: I met Barat", insertedRange: (before as NSString).range(of: "I met Barat")) == nil,
            "Outside insertion"
        )
        // Evaluate the accumulated edit, as the observer does after rapid keystrokes.
        for intermediate in ["better t", "better to", "better too", "better tool", "better tools"] {
            self.expect(self.candidate("I use tools", "I use " + intermediate) == nil, "Typed phrase never becomes a word correction")
        }
        self.expect(self.candidate("I met Barat", "I met Barath") != nil, "Typed spelling repair")
        self.expect(self.candidate("I met Barat", "I met Barat") == nil, "Undo returns to original")
        self.knownCompoundTerms()
        self.repeatedCorrections()
        print("\(self.checks) correction detector checks passed")
    }

    static func repeatedCorrections() {
        let source = "😀 Ошипка, Ошипка! ошибка Ошипками XОшипка Ошипка-слово"
        let first = (source as NSString).range(of: "Ошипка")
        let plan = DictionaryCorrectionReplacementPlan(sourceText: source, range: first, replacement: "Ошибка")!
        self.expect(plan.text == "😀 Ошибка, Ошибка! ошибка Ошипками XОшипка Ошипка-слово", "Repeat exact complete words with punctuation and UTF16 prefix")
        self.expect(plan.ranges.count == 2, "Case variants, substrings and hyphenated words remain distinct")
        let phrase = "Petch Voice, then Petch Voice."
        let group = DictionaryCorrectionReplacementPlan(sourceText: phrase, range: (phrase as NSString).range(of: "Petch Voice"), replacement: "Pichi Voice Pro")!
        self.expect(group.text == "Pichi Voice Pro, then Pichi Voice Pro.", "Repeat complete selected compounds")
        let last = (phrase as NSString).range(of: "Petch Voice", options: .backwards)
        self.expect(group.mappedRange(last) == (group.text as NSString).range(of: "Pichi Voice Pro", options: .backwards), "Track a selected later occurrence after growing replacements")
        let scoped = DictionaryCorrectionReplacementPlan(sourceText: "bad bad bad", range: NSRange(location: 4, length: 3), replacement: "good", scope: NSRange(location: 4, length: 3))!
        self.expect(scoped.text == "bad good bad", "Live propagation stays within the inserted dictation")
        let shrink = DictionaryCorrectionReplacementPlan(sourceText: "fooo fooo", range: NSRange(location: 0, length: 4), replacement: "foo")!
        self.expect(shrink.text == "foo foo", "Shrinking edits keep every original occurrence")
        self.expect(shrink.mappedRange(NSRange(location: 9, length: 0)) == NSRange(location: 7, length: 0), "Restore caret after repeated shrinking edits")
        self.expect(DictionaryCorrectionReplacementPlan(sourceText: "😀 word", range: NSRange(location: 1, length: 1), replacement: "x") == nil, "Reject broken UTF16 selection")
        let approved = NSRange(location: 0, length: 3)
        self.expect(DictionaryCorrectionReplacementPlan.confirmedRange(approved, text: "foo", replacing: NSRange(location: 3, length: 0), withLength: 1, in: "food") == nil, "Appending a letter revokes queued pronunciation approval")
        self.expect(DictionaryCorrectionReplacementPlan.confirmedRange(approved, text: "foo", replacing: NSRange(location: 0, length: 0), withLength: 1, in: "xfoo") == nil, "Prepending a letter revokes queued pronunciation approval")
        self.expect(DictionaryCorrectionReplacementPlan.confirmedRange(approved, text: "foo", replacing: NSRange(location: 3, length: 0), withLength: 1, in: "foo ") == approved, "Appending a separator preserves approval")
        self.expect(DictionaryCorrectionReplacementPlan.confirmedRange(approved, text: "foo", replacing: NSRange(location: 0, length: 0), withLength: 1, in: " foo") == NSRange(location: 1, length: 3), "Prepending a separator shifts the same approval")
        let compoundBefore = "Pech Pech"
        let compoundPlan = DictionaryCorrectionReplacementPlan(sourceText: compoundBefore, range: NSRange(location: 0, length: 4), replacement: "Pichi")!
        let expanded = AutomaticDictionaryCorrectionDetector.candidate(before: compoundBefore, after: "Pichi Pech", insertedRange: NSRange(location: 0, length: 9), knownCanonicalTerms: ["Pichi Pech"])
        self.expect(AutomaticDictionaryCorrectionDetector.confirmedCandidate(expanded, in: compoundPlan) == nil, "Propagation cannot approve a different expanded canonical group")
        let core = self.candidate(compoundBefore, "Pichi Pech")
        self.expect(AutomaticDictionaryCorrectionDetector.confirmedCandidate(core, in: compoundPlan)?.correctedText == "Pichi", "Keep the explicitly confirmed word after propagation changes its neighbor")

        var map = DictionaryCorrectionTextMap(originalText: "😀 fooo then baad fooo")
        let originalSecond = (map.originalText as NSString).range(of: "baad")
        let originalRepeat = (map.originalText as NSString).range(of: "fooo", options: .backwards)
        self.expect(map.replace(range: NSRange(location: 6, length: 1), replacement: ""), "Record a letter deletion")
        self.expect(map.originalRange(for: (map.text as NSString).range(of: "foo")) == (map.originalText as NSString).range(of: "fooo"), "Deleted terminal letter retains its spoken provenance")
        self.expect(map.originalRange(for: (map.text as NSString).range(of: "baad")) == originalSecond, "Second correction survives preceding length change")
        let repeatPlan = DictionaryCorrectionReplacementPlan(sourceText: map.text, range: (map.text as NSString).range(of: "fooo"), replacement: "foo")!
        for range in repeatPlan.ranges.reversed() { self.expect(map.replace(range: range, replacement: "foo"), "Record propagated edit") }
        self.expect(map.originalRange(for: (map.text as NSString).range(of: "foo", options: .backwards)) == originalRepeat, "Repeated spelling retains its own original occurrence")
        let second = (map.text as NSString).range(of: "baad")
        self.expect(map.replace(range: second, replacement: "better"), "Record second distinct repair")
        self.expect(map.originalRange(for: (map.text as NSString).range(of: "better")) == originalSecond, "A replacement maps to immutable original audio text")
        self.expect(map.originalRange(for: (map.text as NSString).range(of: "ett")) == nil, "Partial replacement cannot guess an original occurrence")
    }

    static func knownCompoundTerms() {
        func detected(_ before: String, _ after: String, terms: [String], insertion: NSRange? = nil) -> AutomaticDictionaryCorrectionCandidate? {
            AutomaticDictionaryCorrectionDetector.candidate(
                before: before, after: after,
                insertedRange: insertion ?? NSRange(location: 0, length: (before as NSString).length),
                allowsInsertionAtEnd: true, knownCanonicalTerms: terms
            )
        }
        let compounds = [
            ("I use Petch Voice.", "I use Pichi Voice.", "Pichi Voice", "Petch Voice"),
            ("I use User Experiens.", "I use User Experience.", "User Experience", "User Experiens"),
            ("I use Petch Voice Pro.", "I use Pichi Voice Pro.", "Pichi Voice Pro", "Petch Voice Pro"),
            ("I use petch Voice.", "I use pichi Voice.", "Pichi Voice", "petch Voice"),
            ("I use \"Petch Voice\".", "I use \"Pichi Voice\".", "Pichi Voice", "Petch Voice"),
            ("I use (Petch Voice).", "I use (Pichi Voice).", "Pichi Voice", "Petch Voice"),
            ("😀 I use Ёжик Голос.", "😀 I use Ёжик Голоса.", "Ёжик Голоса", "Ёжик Голос"),
        ]
        for (before, after, canonical, heard) in compounds {
            let result = detected(before, after, terms: [canonical])
            self.expect(result?.heardText == heard, "Keep complete source compound \(heard)")
            self.expect(result?.correctedText.caseInsensitiveCompare(canonical) == .orderedSame, "Keep complete corrected compound \(canonical)")
            self.expect(result?.sourceUTF16Range == (before as NSString).range(of: heard), "Exact lexical UTF16 range for \(heard)")
        }
        let repeatedBefore = "Pichi Voice then Petch Voice."
        let repeatedAfter = "Pichi Voice then Pichi Voice."
        let repeated = detected(repeatedBefore, repeatedAfter, terms: ["Pichi Voice", "pichi voice", "Pichi Voice"])
        self.expect(repeated?.heardText == "Petch Voice", "Repeated canonical occurrences do not create ambiguity")
        self.expect(repeated?.sourceUTF16Range == (repeatedBefore as NSString).range(of: "Petch Voice"), "Bind only edited physical occurrence")
        let prior = "😀 prior. "
        let inserted = "I use Petch Voice."
        let anchored = detected(prior + inserted + " tail", prior + "I use Pichi Voice." + " tail", terms: ["Pichi Voice"],
            insertion: NSRange(location: (prior as NSString).length, length: (inserted as NSString).length))
        self.expect(anchored?.sourceUTF16Range == (inserted as NSString).range(of: "Petch Voice"), "Focal range remains relative to dictation, including UTF16 prefix")
        self.expect(detected("Petch Voice", "Pichi Voice", terms: ["Pichi Voice", "Pichi"]) == nil, "Reject nested competing canonical terms")
        self.expect(detected("Petch Voice Pro", "Pichi Voice Pro", terms: ["Pichi Voice", "Pichi Voice Pro"]) == nil, "Reject overlapping compound choices")
        self.expect(detected("Petch Voice", "Pichi Voice", terms: ["Pichi Voice"])?.correctedText == "Pichi Voice", "Unique compound is usable")
        self.expect(detected("Petch Voice", "Pichi Voice", terms: [])?.correctedText == "Pichi", "Unknown terms preserve existing minimal correction")
        self.expect(detected("XPetch Voice", "XPichi Voice", terms: ["Pichi Voice"])?.correctedText == "XPichi", "Do not expand from inside a word")
        self.expect(detected("Petch Voice-Pro", "Pichi Voice-Pro", terms: ["Pichi Voice"])?.correctedText == "Pichi", "Hyphen remains inside a compound word")
        self.expect(detected("Petch Voice's", "Pichi Voice's", terms: ["Pichi Voice"])?.correctedText == "Pichi", "Apostrophe remains inside a name")
        self.expect(detected("Petch Voice", "Pichi Voice", terms: ["Pichi Voice"], insertion: NSRange(location: 0, length: 5))?.correctedText == "Pichi", "Never include context outside inserted audio")
        self.expect(detected("Petch Voice", "Pichi Voice", terms: ["Pichi Voice"], insertion: NSRange(location: 6, length: 5)) == nil, "Reject a repair outside inserted audio")
        self.expect(detected("cat voice", "cats voice", terms: ["cats voice"]) == nil, "Known context cannot bypass original inflection guard")
        self.expect(detected("foo voice", "bar baz voice", terms: ["bar baz voice"]) == nil, "Known context cannot bypass original rewrite guard")
        self.expect(detected("Petch Voice", "Pichi Voice", terms: ["Pichi  Voice"])?.correctedText == "Pichi", "Do not fuzzy-match spaces")
        self.expect(detected("Jose Voice", "José Voice", terms: ["Jose Voice"])?.correctedText == "José", "Do not ignore diacritics to attach a different term")
    }
}
#endif
