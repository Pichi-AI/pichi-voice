#if os(macOS)
import PichiCallObservation

nonisolated enum VKTeamsCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        MeetingCommunicationProfiles.registration(.init(id: "vk-teams", displayName: "VK Teams", validation: .researchOnly))
    }
}
#endif
