import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, meetingSources, analyticsPrivacy, voiceEngine, changelog }
    enum Preview { case meeting, sources, analytics, dictation }

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
        switch version {
        case "0.3.0":
            return Self(
                release: version,
                title: "More control over meeting audio and privacy",
                subtitle: "Choose the audio for your next meeting and see how usage reporting works on your Mac.",
                features: [
                    Feature(
                        id: "meeting-audio",
                        preview: .sources,
                        eyebrow: "Meetings",
                        title: "Choose what you record",
                        detail: "Record just your microphone, add audio from one app, or include all computer audio. You can save your choice for next time.",
                        action: "Open recording settings",
                        destination: .meetingSources
                    ),
                    Feature(
                        id: "usage-privacy",
                        preview: .analytics,
                        eyebrow: "Privacy",
                        title: "See what usage data is shared",
                        detail: "The public Mac release reports daily activity. Detailed metrics are optional. Audio and transcript text stay out of analytics.",
                        action: "See what is collected",
                        destination: .analyticsPrivacy
                    ),
                ]
            )
        case "0.2.3":
            return self.dictationHighlights(version: version)
        default:
            return Self(
                release: version,
                title: "What’s new",
                subtitle: "Explore changes and installation notes for published versions.",
                features: []
            )
        }
    }

    private static func dictationHighlights(version: String) -> Self {
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
