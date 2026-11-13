import Foundation

/// Edit this definition for each release. The renderer and acknowledgement logic stay unchanged.
struct ReleaseHighlightsContent {
    enum Destination { case meetings, dashboard, aiProviders, voiceEngine }
    enum Preview { case meeting, dashboard, ripple, splash, speech }

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
            release: "1.6.13",
            title: "More flexible meetings and reliable delivery",
            subtitle: "Choose your meeting source, redo saved audio in another language, and recover unread dictation.",
            features: [
                Feature(
                    id: "speech-pro", preview: .speech, eyebrow: "NEW SPEECH MODEL",
                    title: "Fluid Speech Pro",
                    detail: "Transcribe in 25 supported languages using your selected compatible speech model.",
                    action: "Open Voice Engine", destination: .voiceEngine
                ),
                Feature(
                    id: "qwen", preview: .speech, eyebrow: "MULTILINGUAL SPEECH",
                    title: "Qwen3 ASR 1.7B",
                    detail: "Automatic detection of 30 languages with on-device transcription.",
                    action: "Open Voice Engine", destination: .voiceEngine
                ),
                Feature(
                    id: "meetings", preview: .dashboard, eyebrow: "MEETING WORKFLOW",
                    title: "Meeting setup and language redo",
                    detail: "Choose the app and microphone before recording, then redo saved audio in another supported language.",
                    action: "Open dashboard", destination: .dashboard
                ),
            ]
        )
    }
}
