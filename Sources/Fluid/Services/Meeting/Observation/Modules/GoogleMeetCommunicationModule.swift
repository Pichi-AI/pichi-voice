#if os(macOS)
import PichiCallObservation

nonisolated enum GoogleMeetCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        let descriptor = MeetingCommunicationProfiles.descriptor(id: "google-meet", name: "Google Meet", hosts: ["meet.google.com"],
            connected: ["Leave call", "Выйти из звонка", "Покинуть звонок"], muted: ["Turn on microphone", "Включить микрофон"],
            unmuted: ["Turn off microphone", "Выключить микрофон", "Отключить микрофон"], chords: [.init()], validation: .nativeValidated)
        return MeetingCommunicationProfiles.registration(descriptor, renderedFactory: { application, handler in
            MeetingMicrophoneMuteMonitor(application: application, controlPlatform: .googleMeet, handler: handler)
        }, renderedBundleIdentifiers: ["com.google.Chrome"], allowsLegacyURLDetection: true)
    }
}
#endif
