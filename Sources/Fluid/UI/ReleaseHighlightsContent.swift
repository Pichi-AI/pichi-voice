import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders }
    enum Preview { case meeting, dashboard, models }

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

    static func current(hasPrivateAI: Bool) -> Self {
        Self(
            release: "1.6.12",
            title: "Meeting summaries and agent integrations",
            subtitle: "Meeting detection, model compatibility, and read-only agent access.",
            features: [
                Feature(
                    id: "summaries",
                    preview: .meeting,
                    eyebrow: "YOUR MEETINGS, WITH SOURCES",
                    title: "Meeting summaries with sources",
                    detail: "Generate grounded summaries with transcript source references. Existing provider connections share the meeting workspace.",
                    action: "Open meetings",
                    destination: .meetings
                ),
                Feature(
                    id: "integrations",
                    preview: .meeting,
                    eyebrow: "MEET YOUR CODING AGENTS",
                    title: "Connect your coding agents",
                    detail: "Let coding agents read completed transcripts and saved summaries after enabling read-only sharing in meeting settings.",
                    action: "Open meetings",
                    destination: .meetings
                ),
                Feature(
                    id: "compatibility",
                    preview: .models,
                    eyebrow: "YOUR AI, YOUR WAY",
                    title: "AI provider compatibility",
                    detail: "Sampling support follows provider metadata; local and cloud connections keep their existing configuration.",
                    action: "Explore AI providers",
                    destination: .aiProviders
                ),
            ]
        )
    }
}
