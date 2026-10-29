import Foundation

/// Translate presentation diagnostics without changing stored capture reasons or transcript data.
nonisolated enum MeetingUILocalization {
    static func captionAvailability(_ reason: String) -> String {
        let prefixes = [
            ("Buffered captions could not start: ", "Buffered captions could not start: %@"),
            ("Buffered captions could not load: ", "Buffered captions could not load: %@"),
            ("Live captions could not load: ", "Live captions could not load: %@"),
        ]
        for (prefix, format) in prefixes where reason.hasPrefix(prefix) {
            // The reason after the prefix is often a model's own message with a catalog translation.
            return PichiLocalization.format(format, PichiLocalization.text(String(reason.dropFirst(prefix.count))))
        }
        return PichiLocalization.text(reason)
    }
}
