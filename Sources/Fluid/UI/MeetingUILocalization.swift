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
            return PichiLocalization.format(format, String(reason.dropFirst(prefix.count)))
        }
        return PichiLocalization.text(reason)
    }
}
