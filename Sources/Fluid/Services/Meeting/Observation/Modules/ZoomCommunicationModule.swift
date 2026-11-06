#if os(macOS)
import PichiCallObservation

nonisolated enum ZoomCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        let descriptor = MeetingCommunicationProfiles.descriptor(id: "zoom", name: "Zoom", native: ["us.zoom.xos"], hosts: ["zoom.us"],
            connected: ["End", "End meeting", "Leave meeting", "Завершить", "Выйти"], muted: ["Unmute my audio", "Включить мой звук"],
            unmuted: ["Mute my audio", "Выключить мой звук"], prejoin: ["Start"], chords: [.init()], validation: .nativeValidated, allowsSubdomains: true,
            nativeWindowIdentifiers: ["zm.meeting.window.main"])
        return MeetingCommunicationProfiles.registration(descriptor, renderedFactory: { application, handler in
            MeetingMicrophoneMuteMonitor(application: application, controlPlatform: .zoom,
                renderedStatus: MeetingZoomMuteStatusObserver(), handler: handler)
        }, nativeCallStatusFactory: { MeetingZoomMuteStatusObserver() },
        legacyWindowMatcher: { MeetingAppRegistry.isZoomMeetingWindowTitle($0 ?? "") }, allowsLegacyURLDetection: true)
    }
}
#endif
