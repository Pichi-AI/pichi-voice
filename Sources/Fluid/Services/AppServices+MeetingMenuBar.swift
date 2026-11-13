import Foundation

extension AppServices {
    /// Starts the same coordinator used by FluidMeet without posting a navigation request.
    func startMeetingRecordingFromMenuBar() async throws {
        guard SettingsStore.shared.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        let profile = PrivateProfileStorage.current
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { throw CancellationError() }
        let discovery = PrivateProfileOperationOwner(registerForTransitions: true)
        let configuration = try await discovery.perform {
            guard SettingsStore.shared.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
            let defaults = SettingsStore.shared.meetingRecordingDefaults.preferringLastPickedApplication(SettingsStore.shared.meetingRecentApplication)
            let target = defaults.mode == .onlineCall && defaults.effectiveApplicationAudioScope == .selectedApplication && defaults.usesAutomaticApplication ? self.meetingAutomaticTarget : nil
            if defaults.mode == .onlineCall, defaults.effectiveApplicationAudioScope == .selectedApplication, defaults.usesAutomaticApplication, target == nil {
                throw MeetingCaptureError.applicationNotSelected
            }
            let preferredInputUID = SettingsStore.shared.preferredInputDeviceUID
            let microphones = await MeetingCaptureSourceCatalog.microphoneSnapshot()
            try Task.checkCancellation()
            guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { throw CancellationError() }
            let applications = try await defaults.mode == .onlineCall && defaults.effectiveApplicationAudioScope == .selectedApplication ? MeetingCaptureSourceCatalog.availableApplications() : []
            try Task.checkCancellation()
            guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { throw CancellationError() }
            // Never capture a replacement app when detection changed during source discovery.
            if let target, target != self.meetingAutomaticTarget {
                throw MeetingCaptureError.applicationUnavailable(target.bundleIdentifier)
            }
            let configuration = try Self.menuBarMeetingConfiguration(
                defaults: defaults,
                target: target,
                microphones: microphones,
                applications: applications,
                preferredInputUID: preferredInputUID
            )
            return SettingsStore.shared.applyingMeetingRecordingPreferences(to: configuration)
        }
        guard SettingsStore.shared.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        // Capture admission belongs to the coordinator after discovery work has joined.
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { throw CancellationError() }
        _ = try await self.meetingSessionCoordinator.startRecording(configuration: configuration)
    }

    static func menuBarMeetingConfiguration(
        defaults: MeetingRecordingDefaults,
        target: MeetingAutoDetector.ResolvedTarget?,
        microphones: MeetingMicrophoneCatalogSnapshot,
        applications: [MeetingApplicationIdentity],
        preferredInputUID: String?
    ) throws -> MeetingCaptureConfiguration {
        let savedMicrophone = defaults.savedMicrophone(in: microphones.identities)
        let selection = MeetingMicrophonePreselection.select(
            identities: microphones.identities,
            savedDeviceID: savedMicrophone?.captureDeviceID,
            savedRole: defaults.microphoneRole,
            systemDefaultUID: microphones.defaultCoreAudioUID,
            preferredInputUID: preferredInputUID,
            systemDefaultCaptureID: nil
        )
        guard var microphone = microphones.identities.first(where: { $0.captureDeviceID == selection.deviceID }) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        microphone.role = .unknown
        let application = try MeetingRecordingSourceResolver.resolve(
            mode: defaults.mode,
            source: MeetingRecordingSource(defaults: defaults),
            applicationAudioScope: defaults.effectiveApplicationAudioScope,
            target: target,
            applications: applications
        )
        return MeetingCaptureConfiguration(
            mode: defaults.mode,
            title: MeetingTranscriptionSetupDraft.defaultTitle(mode: defaults.mode, applicationDisplayName: application?.displayName),
            languageCode: defaults.languageCode ?? "en",
            platform: application.map { MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName) },
            application: application,
            applicationAudioScope: defaults.mode == .onlineCall ? defaults.effectiveApplicationAudioScope : nil,
            microphone: microphone,
            timestampDefaultTitle: true
        )
    }
}
