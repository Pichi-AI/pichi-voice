import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders, voiceEngine, changelog }
    enum Preview { case meeting, dashboard, ripple, splash, speech, dictation }

    struct Feature: Identifiable {
        let id: String
        let preview: Preview
        let eyebrow: String
        let title: String
        let detail: String
        let action: String
        let destination: Destination
    }

    let release: String
    let title: String
    let subtitle: String
    var officialSiteNotice: String? = nil
    let features: [Feature]

    static func current(version: String) -> Self {
        guard version == "0.2.3" else {
            return Self(
                release: version,
                title: "What’s new",
                subtitle: "Explore changes and installation notes for published versions.",
                features: []
            )
        }
        return Self(
            release: version,
            title: "Dictation and Russian interface updates",
            subtitle: "GigaAM finishes dictation sooner, and more of the Mac interface is available in Russian.",
            features: [
                Feature(
                    id: "gigaam", preview: .dictation, eyebrow: "Dictation",
                    title: "Faster GigaAM dictation",
                    detail: "GigaAM reuses audio it has already processed when you finish dictating.",
                    action: "Open Voice Engine", destination: .voiceEngine
                ),
                Feature(
                    id: "meetings", preview: .meeting, eyebrow: "Meetings",
                    title: "Meeting summaries across languages",
                    detail: "Changing the interface language preserves the meeting data used to create summaries.",
                    action: "Open meetings", destination: .meetings
                ),
            ]
        )
    }
}
