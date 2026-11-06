#if os(macOS)
import PichiCallObservation

nonisolated enum SlackCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(MeetingCommunicationProfiles.descriptor(id: "slack-huddles", name: "Slack huddles",
            native: ["com.tinyspeck.slackmacgap"], hosts: ["app.slack.com"],
            connected: ["Leave huddle", "Покинуть мини-конференцию", "Покинуть конференцию"],
            muted: ["Unmute your microphone", "Unmute microphone", "Включить микрофон"],
            unmuted: ["Mute your microphone", "Mute microphone", "Выключить микрофон", "Отключить микрофон"]))
    }
}
#endif
