import Foundation

/// Shared by playback admission and the exact owned paragraph's control lookup.
/// These are native accessibility labels, not recording content or a fuzzy fallback.
nonisolated enum PhysicalPlaybackSliderQuery {
    static let labels = ["Audio chunk position", "Позиция в аудиофрагменте"]

    static var predicate: NSPredicate {
        NSPredicate(format: "label IN %@", self.labels)
    }

    static func isUniqueOwnedMatch(paragraphCount: Int, sliderCount: Int) -> Bool {
        paragraphCount == 1 && sliderCount == 1
    }
}
