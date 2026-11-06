#if os(macOS)
import PichiCallObservation

nonisolated enum TelegramCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(MeetingCommunicationProfiles.descriptor(id: "telegram", name: "Telegram",
            native: ["ru.keepcoder.Telegram"], hosts: ["web.telegram.org"],
            connected: ["End call", "Leave call", "Завершить звонок", "Покинуть звонок"],
            muted: ["Unmute microphone", "Включить микрофон"], unmuted: ["Mute microphone", "Выключить микрофон", "Отключить микрофон"],
            ringing: ["Accept call", "Answer", "Принять звонок", "Ответить"]))
    }
}
#endif
