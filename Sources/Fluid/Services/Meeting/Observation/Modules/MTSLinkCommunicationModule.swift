#if os(macOS)
import PichiCallObservation

nonisolated enum MTSLinkCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(MeetingCommunicationProfiles.descriptor(id: "mts-link", name: "МТС Линк",
            hosts: ["my.mts-link.ru", "events.mts-link.ru", "events.webinar.ru"], connected: ["Leave meeting", "Покинуть встречу", "Выйти из встречи", "Завершить встречу"],
            muted: ["Turn on microphone", "Включить микрофон"], unmuted: ["Turn off microphone", "Выключить микрофон", "Отключить микрофон"]))
    }
}
#endif
