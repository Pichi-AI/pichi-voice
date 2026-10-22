import SwiftUI

/// Stable per-speaker tints for the transcript. Colour is decoration on top of the name, never
/// the only way to tell speakers apart, so it stays quiet enough to read a whole meeting in.
nonisolated enum MeetingSpeakerPalette {
    /// Muted in light (pastels wash out on white), lifted in dark. Keep the six
    /// inherited light/dark hue pairs shared across every participant renderer.
    private static let tints: [(light: (Int, Int, Int), dark: (Int, Int, Int))] = [
        (light: (0x33, 0x55, 0x86), dark: (0x84, 0xa9, 0xda)),
        (light: (0x4c, 0x6c, 0x3d), dark: (0x93, 0xbb, 0x82)),
        (light: (0x8c, 0x4c, 0x33), dark: (0xdb, 0x93, 0x74)),
        (light: (0x5f, 0x42, 0x7c), dark: (0xae, 0x92, 0xd2)),
        (light: (0x77, 0x5b, 0x18), dark: (0xc9, 0xad, 0x55)),
        (light: (0x27, 0x62, 0x63), dark: (0x72, 0xb3, 0xb4)),
    ]

    static func rgb(forSpeakerIndex index: Int, isDark: Bool) -> (red: Int, green: Int, blue: Int) {
        let slot = ((index % self.tints.count) + self.tints.count) % self.tints.count
        let entry = self.tints[slot]
        let value = isDark ? entry.dark : entry.light
        return (value.0, value.1, value.2)
    }

    /// Resolve against the actual palette before contrast validation. A dynamic
    /// platform color could otherwise be checked and drawn in different appearances.
    static func tint(forSpeakerIndex index: Int, isDark: Bool) -> Color {
        let value = Self.rgb(forSpeakerIndex: index, isDark: isDark)
        return Color(.sRGB, red: Double(value.red) / 255,
            green: Double(value.green) / 255, blue: Double(value.blue) / 255)
    }

    /// Persisted legacy bucket name. Names never select a participant's colour.
    static let unknownMicrophoneSpeakerName = "Microphone / Unknown"

    /// Shared small-label ink for headers, participant chips and transcript rows.
    /// Nil is unresolved speech, not a participant. Resolve physical surfaces first
    /// so an imported palette cannot check one appearance and draw another.
    @MainActor static func labelColor(forSpeakerIndex index: Int?, theme: AppTheme, colorScheme: ColorScheme) -> Color {
        guard let index else { return theme.palette.secondaryText }
        let scheme = theme.palette.nativeColorScheme(fallback: colorScheme)
        return theme.palette.readableText(self.tint(forSpeakerIndex: index, isDark: scheme == .dark),
            minimumContrast: 4.5)
    }

    /// Use the complete persisted session.speakers admission order. Local, unnamed
    /// and merged records reserve their slots; only the displayed view is filtered
    /// or reordered. The first six admitted identities therefore have distinct
    /// inherited tints, and later identities repeat the finite palette.
    static func tintIndices(for speakers: [MeetingSessionSpeaker]) -> [SessionSpeakerID: Int] {
        Dictionary(uniqueKeysWithValues: speakers.enumerated().map { ($0.element.id, $0.offset) })
    }

    static func tints(for speakers: [MeetingSessionSpeaker], isDark: Bool) -> [SessionSpeakerID: Color] {
        self.tintIndices(for: speakers).mapValues { Self.tint(forSpeakerIndex: $0, isDark: isDark) }
    }
}
