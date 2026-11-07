#if os(macOS)
import PichiCallObservation

nonisolated enum TrueConfCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(.init(id: "trueconf", displayName: "TrueConf", validation: .researchOnly))
    }
}
#endif
