#if os(macOS)
import PichiCallObservation

nonisolated enum WebexCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(MeetingCommunicationProfiles.descriptor(id: "webex", name: "Cisco Webex",
            native: ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"], hosts: ["webex.com"],
            connected: ["Leave meeting", "End meeting", "Leave call", "Завершить встречу", "Выйти из встречи"],
            muted: ["Unmute microphone", "Unmute my microphone", "Включить микрофон"],
            unmuted: ["Mute microphone", "Mute my microphone", "Отключить микрофон"],
            ringing: ["Answer call", "Ответить"], held: ["Resume call", "Возобновить звонок"], chords: [.init()], allowsSubdomains: true), legacyWindowMatcher: { _ in true })
    }
}
#endif
