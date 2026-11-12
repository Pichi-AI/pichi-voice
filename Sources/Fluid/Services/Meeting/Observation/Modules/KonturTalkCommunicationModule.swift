#if os(macOS)
import PichiCallObservation

nonisolated enum KonturTalkCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(MeetingCommunicationProfiles.descriptor(id: "kontur-talk", name: "Контур.Толк",
            hosts: ["ktalk.ru"], connected: ["Leave call", "Leave conference", "Выйти из конференции", "Завершить звонок", "Покинуть конференцию"],
            muted: ["Turn on microphone", "Включить микрофон"], unmuted: ["Turn off microphone", "Выключить микрофон", "Отключить микрофон"], allowsSubdomains: true))
    }
}
#endif
