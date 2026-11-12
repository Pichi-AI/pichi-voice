#if os(macOS)
import PichiCallObservation

nonisolated enum TelemostCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(MeetingCommunicationProfiles.descriptor(id: "yandex-telemost", name: "Яндекс Телемост",
            hosts: ["telemost.yandex.ru", "telemost.yandex.com"], connected: ["Leave", "Leave meeting", "Выйти", "Покинуть встречу", "Выйти из встречи"],
            muted: ["Turn on microphone", "Включить микрофон"], unmuted: ["Turn off microphone", "Выключить микрофон", "Отключить микрофон"]))
    }
}
#endif
