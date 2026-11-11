#if os(macOS)
import PichiCallObservation

nonisolated enum LinphoneCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(.init(id: "linphone", displayName: "Linphone", validation: .researchOnly))
    }
}
#endif
