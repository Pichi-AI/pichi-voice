#if os(macOS)
import Foundation
import PichiCallObservation

/// Composition-only registration. Module implementations own platform names and selectors.
nonisolated struct MeetingCommunicationModuleRegistration: Sendable {
    typealias RenderedFactory = @Sendable (MeetingApplicationIdentity?, @escaping MeetingMicrophoneMuteMonitor.Handler) -> any MeetingMicrophoneObservationPolling
    let module: any CommunicationObservationModule
    var renderedFactory: RenderedFactory? = nil
    var renderedBundleIdentifiers: [String] = []
    var allowsLegacyURLDetection = false
    var legacyWindowMatcher: (@Sendable (String?) -> Bool)? = nil
}

nonisolated struct MeetingCommunicationModuleSnapshot: Sendable {
    let registry: CommunicationModuleRegistry
    let registrations: [MeetingCommunicationModuleRegistration]
    func registration(id: String) -> MeetingCommunicationModuleRegistration? {
        self.registrations.first { $0.module.descriptor.id == id }
    }
}

/// A recording pins one immutable snapshot. Adding an adapter changes the composition here,
/// never the recorder, ASR coordinator, gate or scheduler.
nonisolated enum MeetingCommunicationModuleHost {
    static let snapshot: MeetingCommunicationModuleSnapshot = {
        let registrations = [ZoomCommunicationModule.registration, GoogleMeetCommunicationModule.registration,
            TeamsCommunicationModule.registration, WebexCommunicationModule.registration,
            SlackCommunicationModule.registration, TelegramCommunicationModule.registration,
            TelemostCommunicationModule.registration, KonturTalkCommunicationModule.registration,
            MTSLinkCommunicationModule.registration, VKTeamsCommunicationModule.registration,
            TrueConfCommunicationModule.registration, LinphoneCommunicationModule.registration].compactMap { $0 }
        // A malformed built-in profile is a programming error, caught by contract tests.
        // Keep the app available with only valid adapters rather than opening unvalidated rules.
        var registry = CommunicationModuleRegistry()
        var accepted: [MeetingCommunicationModuleRegistration] = []
        for registration in registrations {
            do { try registry.register(registration.module); accepted.append(registration) }
            catch { DebugLogger.shared.warning("Invalid communication module: \(registration.module.descriptor.id)", source: "MeetingCallObservation") }
        }
        return .init(registry: registry, registrations: accepted)
    }()

    static var observedKeyCodes: Set<Int64> {
        Set(self.snapshot.registry.modules.filter { $0.descriptor.validation != .researchOnly }
            .flatMap { $0.descriptor.pushToTalkChords }.prefix(32).map { Int64($0.keyCode) })
    }

    static func makeMicrophoneDriver(application: MeetingApplicationIdentity?,
        handler: @escaping MeetingMicrophoneMuteMonitor.Handler) -> any MeetingMicrophoneObservationPolling {
        let snapshot = self.snapshot
        if let bundle = application?.bundleIdentifier,
           let direct = snapshot.registrations.first(where: { $0.module.descriptor.nativeBundleIdentifiers.contains(bundle) }),
           let factory = direct.renderedFactory { return factory(application, handler) }
        return MeetingModuleMicrophoneObserver(application: application, snapshot: snapshot, handler: handler)
    }

    static func nativeTier(for bundleIdentifier: String) -> Bool? {
        let modules = self.snapshot.registry.candidates(bundleIdentifier: bundleIdentifier)
        if modules.contains(where: { $0.descriptor.nativeBundleIdentifiers.contains(bundleIdentifier) }) { return true }
        if modules.contains(where: { $0.descriptor.matchesBrowserBundleIdentifier(bundleIdentifier) }) { return false }
        return nil
    }

    static func matchesNativeWindow(_ window: WindowSnapshot, bundleIdentifier: String) -> Bool {
        let candidates = self.snapshot.registrations.filter { $0.module.descriptor.nativeBundleIdentifiers.contains(bundleIdentifier) }
        if let state = window.communicationCallState, state != .indeterminate { return state == .inCall || state == .onHold }
        return candidates.contains { $0.legacyWindowMatcher?(window.title) == true }
    }

    static func recognizesCallURL(host: String, path: String) -> Bool {
        self.snapshot.registry.modules.contains { module in
            module.descriptor.validation != .researchOnly && module.descriptor.urlRules.contains { $0.matches("https://" + host + path) }
        }
    }
}

nonisolated enum MeetingCommunicationProfiles {
    static let browsers = ["com.google.Chrome", "com.apple.Safari", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser", "ru.yandex.desktop.yandex-browser"]
    static func button(_ labels: [String], id: String? = nil) -> CommunicationControlSelector {
        .init(identifier: id, labels: labels, allowsShortcutSuffix: true)
    }
    static func registration(_ descriptor: CommunicationModuleDescriptor,
        renderedFactory: MeetingCommunicationModuleRegistration.RenderedFactory? = nil,
        legacyWindowMatcher: (@Sendable (String?) -> Bool)? = nil,
        renderedBundleIdentifiers: [String]? = nil, allowsLegacyURLDetection: Bool = false) -> MeetingCommunicationModuleRegistration? {
        do { return .init(module: try SemanticCommunicationModule(descriptor: descriptor),
                          renderedFactory: renderedFactory, renderedBundleIdentifiers: renderedBundleIdentifiers ?? descriptor.nativeBundleIdentifiers, allowsLegacyURLDetection: allowsLegacyURLDetection, legacyWindowMatcher: legacyWindowMatcher) }
        catch {
            DebugLogger.shared.warning("Invalid communication module: \(descriptor.id)", source: "MeetingCallObservation")
            return nil
        }
    }
    static func descriptor(id: String, name: String, native: [String] = [], hosts: [String] = [],
        connected: [String], muted: [String], unmuted: [String], ringing: [String] = [], held: [String] = [],
        chords: [CommunicationPushToTalkChord] = [], validation: CommunicationModuleValidation = .contractTested, allowsSubdomains: Bool = false) -> CommunicationModuleDescriptor {
        .init(id: id, displayName: name, nativeBundleIdentifiers: native,
            browserBundleIdentifiers: hosts.isEmpty ? [] : self.browsers,
            urlRules: hosts.map { .init(host: $0, allowsSubdomains: allowsSubdomains, excludedPathPrefixes: ["/login", "/signin", "/settings"]) },
            validation: validation,
            callRules: .init(connected: connected.map { self.button([$0]) },
                ended: ["Rejoin", "Вернуться в звонок", "Присоединиться снова"].map { self.button([$0]) },
                ringing: ringing.map { self.button([$0]) }, held: held.map { self.button([$0]) }),
            microphoneRules: .init(muted: muted.map { self.button([$0]) }, unmuted: unmuted.map { self.button([$0]) }),
            pushToTalkChords: chords)
    }
}
#endif
