#if os(macOS)
import PichiCallObservation

nonisolated enum TeamsCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(MeetingCommunicationProfiles.descriptor(id: "microsoft-teams", name: "Microsoft Teams",
            native: ["com.microsoft.teams2", "com.microsoft.teams"], hosts: ["teams.microsoft.com", "teams.live.com"],
            connected: ["Leave", "Leave call", "Hang up", "Покинуть", "Завершить звонок"],
            muted: ["Unmute mic", "Unmute microphone", "Включить микрофон"],
            unmuted: ["Mute mic", "Mute microphone", "Отключить микрофон", "Выключить микрофон"],
            ringing: ["Accept call", "Answer call", "Ответить"], held: ["Resume", "Resume call", "Возобновить"],
            chords: [.init(modifiers: [.option])]), legacyWindowMatcher: { _ in true }, allowsLegacyURLDetection: true)
    }
}
#endif
