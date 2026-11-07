#if os(macOS)
import PichiCallObservation

nonisolated enum TeamsCommunicationModule {
    static var registration: MeetingCommunicationModuleRegistration? {
        let enterprise = MeetingCommunicationProfiles.descriptor(id: "microsoft-teams", name: "Microsoft Teams",
            native: ["com.microsoft.teams2", "com.microsoft.teams"], hosts: ["teams.microsoft.com"],
            connected: ["Leave", "Leave call", "Hang up", "Покинуть", "Завершить звонок"],
            muted: ["Unmute mic", "Unmute microphone", "Включить микрофон"],
            unmuted: ["Mute mic", "Mute microphone", "Отключить микрофон", "Выключить микрофон"],
            ringing: ["Accept call", "Answer call", "Ответить"], held: ["Resume", "Resume call", "Возобновить"],
            chords: [.init(modifiers: [.option])])
        // Observed in a real teams.live.com solo call, 2026-11-06. Consumer prejoin switches
        // are distinct from the in-call buttons; generated prejoin switch IDs are not stable.
        let consumer = CommunicationModuleDescriptor(id: enterprise.id, displayName: enterprise.displayName,
            browserBundleIdentifiers: MeetingCommunicationProfiles.browsers, urlRules: [.init(host: "teams.live.com")],
            callRules: .init(connected: [.init(identifier: "hangup-button", labels: ["Leave"])],
                prejoin: [.init(identifier: "prejoin-join-button", labels: ["Join now"])]),
            microphoneRules: .init(
                muted: [.init(identifier: "microphone-button", labels: ["Unmute mic"], ancestorIdentifier: "horizontalMiddleEnd")],
                unmuted: [.init(identifier: "microphone-button", labels: ["Mute mic"], ancestorIdentifier: "horizontalMiddleEnd")]),
            pushToTalkChords: enterprise.pushToTalkChords)
        do {
            return .init(module: try TeamsSurfaces(enterprise: enterprise, consumer: consumer),
                allowsLegacyURLDetection: true, legacyWindowMatcher: { _ in true })
        } catch { return nil }
    }
}

/// The public consumer site and enterprise/native clients have different observed control
/// contracts. Keep that selection in the platform module, outside the shared probe/coordinator.
private nonisolated struct TeamsSurfaces: CommunicationObservationModule {
    let descriptor: CommunicationModuleDescriptor
    private let enterprise: SemanticCommunicationModule
    private let consumer: SemanticCommunicationModule
    init(enterprise: CommunicationModuleDescriptor, consumer: CommunicationModuleDescriptor) throws {
        self.enterprise = try .init(descriptor: enterprise)
        self.consumer = try .init(descriptor: consumer)
        self.descriptor = .init(id: enterprise.id, displayName: enterprise.displayName,
            nativeBundleIdentifiers: enterprise.nativeBundleIdentifiers,
            browserBundleIdentifiers: enterprise.browserBundleIdentifiers, urlRules: enterprise.urlRules + consumer.urlRules,
            callRules: .init(connected: enterprise.callRules.connected + consumer.callRules.connected,
                ended: enterprise.callRules.ended, ringing: enterprise.callRules.ringing,
                held: enterprise.callRules.held, prejoin: consumer.callRules.prejoin),
            microphoneRules: .init(muted: enterprise.microphoneRules.muted + consumer.microphoneRules.muted,
                unmuted: enterprise.microphoneRules.unmuted + consumer.microphoneRules.unmuted),
            pushToTalkChords: enterprise.pushToTalkChords)
    }
    func matches(bundleIdentifier: String, documentURL: String?) -> Bool {
        self.enterprise.matches(bundleIdentifier: bundleIdentifier, documentURL: documentURL)
            || self.consumer.matches(bundleIdentifier: bundleIdentifier, documentURL: documentURL)
    }
    func evaluate(_ snapshot: CommunicationObservationSnapshot) -> CommunicationModuleEvidence {
        if self.consumer.matches(bundleIdentifier: snapshot.bundleIdentifier, documentURL: snapshot.documentURL) {
            return self.consumer.evaluate(snapshot)
        }
        return self.enterprise.evaluate(snapshot)
    }
}
#endif
