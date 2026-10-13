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
    let features: [Feature]

    static func current(hasPrivateAI: Bool) -> Self {
        Self(
            release: "1.6.11",
            title: "What’s new in this release",
            subtitle: "Dictation controls, smoother meetings, and AI connection fixes.",
            features: [
                Feature(
                    id: "fluidmeet",
                    preview: .meeting,
                    eyebrow: "MEETINGS, WITH LESS WAITING",
                    title: "Meetings without the wait",
                    detail: "Cancel waiting model preparation promptly. Russian transcription and summaries with source references share the meeting workspace.",
                    action: "Open meetings",
                    destination: .meetings
                ),
                Feature(
                    id: "redesign",
                    preview: .dashboard,
                    eyebrow: "DICTATION, ON YOUR TERMS",
                    title: "More control while dictating",
                    detail: "Enable hold-Space mute to skip background speech. Button clicks now match their visible shapes.",
                    action: "Open dashboard",
                    destination: .dashboard
                ),
                Feature(
                    id: "models",
                    preview: .models,
                    eyebrow: "YOUR AI, YOUR WAY",
                    title: "Compatible AI connections",
                    detail: hasPrivateAI
                        ? "Claude 5 requests use supported parameters. Local cleanup and Russian provider connections join your AI setup, with less duplicate diagnostic logging."
                        : "Claude 5 requests use supported parameters. Russian provider connections join your AI setup, with less duplicate diagnostic logging.",
                    action: "Explore AI providers",
                    destination: .aiProviders
                ),
            ]
        )
    }
}
