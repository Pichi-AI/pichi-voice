#if GIGAAM_ENCODER_DICTIONARY_STANDALONE
import Foundation
import PichiGigaAM

enum SettingsStore {
    struct CustomDictionaryEntry: Sendable {
        let id: UUID
        let triggers: [String]
        let replacement: String
    }
}
struct DictionaryMatchFrames: Sendable {
    let hiddenSize: Int
    let values: [Float]
    var count: Int { values.count / max(1, hiddenSize) }
}

@main struct GigaAMEncoderDictionaryTests {
    static func features(_ indices: [Int]) throws -> GigaAMEncoderFeatures {
        var values = [Float](repeating: 0, count: indices.count * GigaAMEncoderFeatures.dimension)
        for (row, index) in indices.enumerated() { values[row * GigaAMEncoderFeatures.dimension + index] = 1 }
        return try GigaAMEncoderFeatures(values: values)
    }

    static func transcript(_ text: String, _ words: [(String, Double, Double)], confidence: Float = 0) -> GigaAMTranscript {
        GigaAMTranscript(text: text, confidence: confidence,
            words: words.map { GigaAMWordTiming(text: $0.0, start: $0.1, end: $0.2, confidence: confidence) },
            endOfUtteranceProbability: nil, processingDuration: 0)
    }

    static func main() async throws {
        let reference = try self.features([0, 1, 2, 3, 4, 5])
        let model = "synthetic-encoder-checkpoint-v1"
        let term = GigaAMEncoderDictionary.Term(entryID: UUID(), label: "Alpha", modelKey: model,
            references: [reference, reference, reference], observedVariants: ["Alfa"])
        let prepared = try GigaAMEncoderDictionary.prepare(terms: [term], modelKey: model)
        precondition(prepared.words.count == 1)
        let result = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("🙂 Alfa!", [("Alfa!", 0, 0.24)]),
            features: reference, modelKey: model, words: prepared.words, entries: [])
        precondition(result.text == "🙂 Alpha!" && result.accepted.count == 1, "Actual native encoder search and UTF16 replacement")
        let protected = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)]),
            features: reference, modelKey: model, words: prepared.words,
            entries: [.init(id: UUID(), triggers: ["Alfa"], replacement: "UserChoice")])
        precondition(protected.text == "Alfa" && protected.accepted.isEmpty)
        let confident = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)], confidence: 0.9),
            features: reference, modelKey: model, words: prepared.words, entries: [])
        precondition(confident.accepted.isEmpty)
        let wrong = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)]),
            features: reference, modelKey: "other", words: prepared.words, entries: [])
        precondition(wrong.accepted.isEmpty && wrong.diagnostics.contains { $0.reason == .wrongModel })
        var negative = term; negative.negatives = [reference]
        let rejected = try GigaAMEncoderDictionary.prepare(terms: [negative], modelKey: model)
        precondition(rejected.words.isEmpty, "Contradictory enrolled negatives cannot produce a calibrated model")
        var recipe = term; recipe.extractorVersion = "different-recipe"
        let wrongRecipe = try GigaAMEncoderDictionary.prepare(terms: [recipe], modelKey: model)
        precondition(wrongRecipe.words.isEmpty)
        let duplicate = try GigaAMEncoderDictionary.prepare(terms: [term, term], modelKey: model)
        precondition(duplicate.diagnostics.contains { $0.reason == .duplicateEntryID })
        let excessCount = try GigaAMEncoderDictionary.prepare(terms: Array(repeating: term, count: 129), modelKey: model)
        precondition(excessCount.words.isEmpty && excessCount.diagnostics.contains { $0.reason == .capacityExceeded })
        let long = try self.features(Array(repeating: 0, count: 375))
        let excessBytes = try GigaAMEncoderDictionary.prepare(terms: (0..<3).map {
            GigaAMEncoderDictionary.Term(entryID: UUID(), label: "Synthetic\($0)", modelKey: model,
                references: Array(repeating: long, count: 10), observedVariants: [])
        }, modelKey: model)
        precondition(excessBytes.words.isEmpty && excessBytes.diagnostics.contains { $0.reason == .capacityExceeded })
        let compoundTerm = GigaAMEncoderDictionary.Term(entryID: UUID(), label: "Alpha Desktop", modelKey: model,
            references: [reference, reference, reference], observedVariants: ["Alfa Desk"])
        let compoundPrepared = try GigaAMEncoderDictionary.prepare(terms: [compoundTerm], modelKey: model)
        let sentence = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa. Desk", [("Alfa.", 0, 0.12), ("Desk", 0.12, 0.24)]),
            features: reference, modelKey: model, words: compoundPrepared.words, entries: [])
        precondition(sentence.accepted.isEmpty && sentence.text == "Alfa. Desk", "Never join a compound across sentence punctuation")
        let role = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("to Alfa", [("to", 0, 0.04), ("Alfa", 0.04, 0.24)]),
            features: reference, modelKey: model, words: prepared.words, entries: [])
        precondition(role.accepted.isEmpty && role.text == "to Alfa", "Do not consume an adjacent preposition")
        let prefixID = UUID(), fullID = UUID()
        let prefix = GigaAMEncoderDictionary.AcceptedSpan(entryID: prefixID, label: "Alpha", wordRange: 0...0,
            frameRange: 0..<6, distance: 0.146, acceptanceDistance: 0.3, spellingSupport: 1)
        let full = GigaAMEncoderDictionary.AcceptedSpan(entryID: fullID, label: "Alpha Desktop", wordRange: 0...0,
            frameRange: 0..<10, distance: 0.147, acceptanceDistance: 0.3, spellingSupport: 0.8)
        let compound = GigaAMEncoderDictionary.arbitrate([prefix, full])
        precondition(compound.accepted.count == 1 && compound.accepted[0].entryID == fullID,
            "Complete accepted compound defeats prefix even when prefix quality is slightly better")
        let other = GigaAMEncoderDictionary.AcceptedSpan(entryID: UUID(), label: "Beta", wordRange: 0...0,
            frameRange: 0..<6, distance: 0.147, acceptanceDistance: 0.3, spellingSupport: 1)
        precondition(GigaAMEncoderDictionary.arbitrate([prefix, other]).accepted.isEmpty, "Unrelated near-equal labels stay ambiguous")
        let disjoint = GigaAMEncoderDictionary.AcceptedSpan(entryID: UUID(), label: "Beta", wordRange: 0...0,
            frameRange: 10..<16, distance: 0.01, acceptanceDistance: 0.3, spellingSupport: 1)
        precondition(GigaAMEncoderDictionary.arbitrate([prefix, disjoint]).accepted.isEmpty,
            "One merged ASR word cannot be overwritten by one of two disjoint spoken dictionary terms")
        precondition(GigaAMDictionaryLexicalEvidence.compare(heard: "в Alfa", canonical: "Alpha", observedVariants: [])!.protectsContent)
        precondition(GigaAMDictionaryLexicalEvidence.compare(heard: "Alfa to", canonical: "Alpha", observedVariants: [])!.protectsContent)
        let laterWindow = try GigaAMEncoderWindow(offset: 20, ownership: 20..<20.24, features: reference)
        let repeated = try await GigaAMEncoderDictionary.correct(
            transcript: self.transcript("Alfa Alfa", [("Alfa", 0, 0.24), ("Alfa", 20, 20.24)]),
            windows: [laterWindow], modelKey: model, words: prepared.words, entries: [])
        precondition(repeated.text == "Alfa Alpha" && repeated.accepted.count == 1 && repeated.accepted[0].wordRange == 1...1)
        precondition(repeated.accepted[0].frameOffset == 500 && repeated.accepted[0].absoluteFrameRange.lowerBound >= 500)
        let claimedAcrossWindow = try await GigaAMEncoderDictionary.correct(
            transcript: self.transcript("Do Alfa", [("Do", 19.8, 19.96), ("Alfa", 20, 20.24)]),
            windows: [laterWindow], modelKey: model, words: prepared.words,
            entries: [.init(id: UUID(), triggers: ["Do Alfa"], replacement: "UserChoice")])
        precondition(claimedAcrossWindow.text == "Do Alfa" && claimedAcrossWindow.accepted.isEmpty,
            "Global text rules protect phrases partially outside a feature window")
        let ownershipWindows = try [
            GigaAMEncoderWindow(offset: 0, ownership: 0..<0.12, features: reference),
            GigaAMEncoderWindow(offset: 0, ownership: 0.12..<0.24, features: reference),
        ]
        let deduplicated = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)]),
            windows: ownershipWindows, modelKey: model, words: prepared.words, entries: [])
        precondition(deduplicated.text == "Alpha" && deduplicated.accepted.count == 1, "Half-open ownership assigns boundary occurrence once")
        let window0 = try GigaAMEncoderWindow(offset: 0, ownership: 0..<0.24, features: reference)
        let same = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("🙂 Alfa!", [("Alfa!", 0, 0.24)]),
            windows: [window0], modelKey: model, words: prepared.words, entries: [])
        precondition(same.text == result.text && same.accepted.count == result.accepted.count && same.accepted[0].distance == result.accepted[0].distance)
        let crossPrefix = GigaAMEncoderDictionary.AcceptedSpan(entryID: prefixID, label: "Alpha", wordRange: 5...5,
            frameRange: 250..<260, distance: 0.146, acceptanceDistance: 0.3, spellingSupport: 1)
        let crossFull = GigaAMEncoderDictionary.AcceptedSpan(entryID: fullID, label: "Alpha Desktop", wordRange: 5...5,
            frameRange: 0..<20, distance: 0.147, acceptanceDistance: 0.3, spellingSupport: 0.8, frameOffset: 250)
        precondition(GigaAMEncoderDictionary.arbitrate([crossPrefix, crossFull]).accepted.first?.entryID == fullID,
            "Cross-window compounds compare absolute audio frames")
        let misaligned = try GigaAMEncoderWindow(offset: 0.01, ownership: 0.01..<0.25, features: reference)
        let invalidWindow = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)]),
            windows: [misaligned], modelKey: model, words: prepared.words, entries: [])
        precondition(invalidWindow.accepted.isEmpty && invalidWindow.diagnostics.contains { $0.reason == .invalidWindows })
        let unsorted = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)]),
            windows: [laterWindow, window0], modelKey: model, words: prepared.words, entries: [])
        precondition(unsorted.accepted.isEmpty && unsorted.diagnostics.contains { $0.reason == .invalidWindows })
        let budgetWindows = try (0..<117).map { i in
            try GigaAMEncoderWindow(offset: 0, ownership: (Double(i) * 15 / 117)..<(Double(i + 1) * 15 / 117), features: long)
        }
        let overBudget = try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)]),
            windows: budgetWindows, modelKey: model, words: prepared.words, entries: [])
        precondition(overBudget.accepted.isEmpty && overBudget.diagnostics.contains { $0.reason == .capacityExceeded })
        var overflow = crossPrefix; overflow.frameOffset = Int.max
        precondition(GigaAMEncoderDictionary.arbitrate([overflow]).accepted.isEmpty)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await GigaAMEncoderDictionary.correct(transcript: self.transcript("Alfa", [("Alfa", 0, 0.24)]),
                windows: [window0], modelKey: model, words: prepared.words, entries: [])
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled window work must not return accepted output") }
        catch is CancellationError {}
        print("PASS: native encoder matching, protected UTF16 edits, compounds, repeated-word window ordinals, ownership deduplication, absolute frames, global rules, budgets and joined cancellation")
    }
}
#endif
