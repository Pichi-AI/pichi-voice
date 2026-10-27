import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders, voiceEngine }
    enum Preview { case meeting, dashboard, models, speech }

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

    static func current(hasPrivateAI _: Bool) -> Self {
        Self(
            release: "1.6.13-beta.1",
            title: "New speech models and steadier captions",
            subtitle: "Fluid Speech Pro, Qwen dictation, and smoother live captions.",
            features: [
                Feature(
                    id: "speech-pro", preview: .speech, eyebrow: "NEW SPEECH MODEL",
                    title: "Fluid Speech Pro",
                    detail: "An English speech model for dictation on your Mac.",
                    action: "Open Voice Engine", destination: .voiceEngine
                ),
                Feature(
                    id: "qwen", preview: .speech, eyebrow: "MULTILINGUAL SPEECH",
                    title: "Qwen3 ASR 1.7B",
                    detail: "Automatic detection of 30 languages with on-device transcription.",
                    action: "Open Voice Engine", destination: .voiceEngine
                ),
                Feature(
                    id: "captions", preview: .dashboard, eyebrow: "LIVE TEXT",
                    title: "Steadier live captions",
                    detail: "Read live text with steadier wrapping and Reduce Motion support.",
                    action: "Open dashboard", destination: .dashboard
                ),
            ]
        )
    }
}
