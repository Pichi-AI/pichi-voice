import Foundation
import NaturalLanguage

/// Local language identification for derived title metadata, never interface selection.
/// Each recognizer belongs to one call and one thread. Samples cover the current
/// transcript rather than just its greeting, and never retain a full scalar array.
nonisolated enum MeetingTitleLanguage {
    static let maximumSamples = 16
    static let maximumSampleScalars = 1_024

    struct Analysis: Sendable {
        let languageCode: String
        let sampleCount: Int
        let analyzedScalars: Int
    }

    static func analyze(_ text: String) -> Analysis {
        let scalars = text.unicodeScalars
        let count = scalars.count
        guard count > 0 else { return .init(languageCode: "und", sampleCount: 0, analyzedScalars: 0) }
        let samples = min(self.maximumSamples, max(1, (count + self.maximumSampleScalars - 1) / self.maximumSampleScalars))
        let recognizer = NLLanguageRecognizer()
        var votes: [String: Double] = [:]
        var previousOffset = 0
        var previousIndex = scalars.startIndex
        var analyzed = 0
        var accepted = 0
        for index in 0..<samples {
            let sectionStart = index * count / samples
            let sectionEnd = (index + 1) * count / samples
            let length = min(self.maximumSampleScalars, sectionEnd - sectionStart)
            let offset = sectionStart + (sectionEnd - sectionStart - length) / 2
            let start = scalars.index(previousIndex, offsetBy: offset - previousOffset)
            let end = scalars.index(start, offsetBy: length)
            previousOffset = offset + length
            previousIndex = end
            let slice = scalars[start..<end]
            let letters = slice.reduce(into: 0) { if CharacterSet.letters.contains($1) { $0 += 1 } }
            guard letters > 0 else { continue }
            recognizer.reset()
            recognizer.processString(String(slice))
            let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
            for (language, probability) in hypotheses where language != .undetermined && probability.isFinite && probability > 0 {
                votes[language.rawValue, default: 0] += Double(letters) * probability
            }
            analyzed += length
            accepted += 1
        }
        let winner = votes.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.first?.key ?? "und"
        return .init(languageCode: winner, sampleCount: accepted, analyzedScalars: analyzed)
    }
}
