import Combine
import SwiftUI
import UIKit

/// iOS host composition of the same application services. Every domain operation remains in
/// the existing coordinator, pipeline, registry, settings, resource and storage owners.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()
    let accountSession: AccountSessionService
    let privateProfiles: PrivateProfileService
    private var cloudPublicationActivation: PichiCloudPublicationActivation?
    var cloudPublication: PichiCloudPublicationService? { cloudPublicationActivation?.service }
    let asr: ASRService
    let meetingSessionCoordinator: MeetingSessionCoordinator
    let meetingProcessingPipeline: MeetingProcessingPipeline
    let meetingStore: any MeetingSessionStoring
    let meetingAudioActivityArbiter: AudioActivityArbiter
    let meetingLocation: MeetingLocationService
    let transcriptPrivacy: PichiTranscriptPrivacyService
    let requiredResources: MobileRequiredResources
    let privacyActivation: MobilePrivacyActivation
    private var requiredPreparationTask: Task<Void, Never>?
    @Published private(set) var isUIReady = false
    @Published private(set) var hasRestoredAccount = false
    private var accountRestorationTask: Task<Void, Never>?
    private static var didCleanExportStaging = false
    private let settings: SettingsStore
    private var idlePreparationObservers: Set<AnyCancellable> = []
    private var idleResourceObservers: Set<AnyCancellable> = []
    private var observedSpeakerStore: MeetingDiarizationModelStore?
    private var idleResourceRevision = UUID()
    private var idleResourceUpdateTask: Task<Void, Never>?
    private var pendingIdleResourceEvent = false
    private var isSceneActive = false
    private var hasRestoredInitialState = false
    private var lastIdleDecision: [String: String]?
    private lazy var idlePreparation = MeetingIdlePreparationController<MeetingIdlePreparationToken>(
        prepare: { [settings, transcriptPrivacy, meetingProcessingPipeline] in
            MeetingTimelineTrace.shared?.record("idle_preparation_request")
            do {
                let token = try await meetingProcessingPipeline.prepareSelectedIdleResources(prepareFirst: {
                    guard await settings.meetingPIIRedactionEnabled,
                          let token = try await transcriptPrivacy.prepareInstalledForIdle() else { return nil }
                    return { await transcriptPrivacy.releaseIdlePreparation(token) }
                })
                MeetingTimelineTrace.shared?.record("idle_preparation_result", fields: ["outcome": token == nil ? "no_resource" : "resource_ready"])
                return token
            } catch {
                MeetingTimelineTrace.shared?.record("idle_preparation_result", fields: [
                    "outcome": error is CancellationError ? "cancelled" : "failed",
                    "errorType": String(reflecting: type(of: error))])
                throw error
            }
        }, release: { [meetingProcessingPipeline] token in await meetingProcessingPipeline.releaseIdleResources(token) })

    init(store: (any MeetingSessionStoring)? = nil,
         capture injectedCapture: (any MeetingCaptureControlling)? = nil,
         settings: SettingsStore? = nil,
         accountSession: AccountSessionService? = nil,
         privateProfiles: PrivateProfileService? = nil,
         publicationHTTP: (any PichiPublicationHTTPPerforming)? = nil,
         privacy: PichiTranscriptPrivacyService? = nil,
         privacyRedactor: (any TranscriptTextRedacting)? = nil,
         microphoneResolver: (@MainActor (String?) async throws -> MeetingMicrophoneIdentity)? = nil) {
        let isProductionComposition = store == nil && settings == nil && accountSession == nil
            && privateProfiles == nil && injectedCapture == nil && privacy == nil && privacyRedactor == nil
            && microphoneResolver == nil && publicationHTTP == nil
        // Only a deliberate facade injection can install an observer in a fixture.
        // A generic test store must never touch the global facade or production HTTP.
        let publicationStore = isProductionComposition ? PrivateProfileMeetingStore.shared
            : store as? PrivateProfileMeetingStore
        // A cold-start operation only. Additional service compositions must not remove
        // files currently being used by an already-open native share sheet.
        if !Self.didCleanExportStaging {
            try? MeetingSharePayload.cleanupAbandonedShares()
            Self.didCleanExportStaging = true
        }
        self.accountSession = accountSession ?? .production()
        self.privateProfiles = privateProfiles ?? (isProductionComposition ? .shared : .init())
        let settings = settings ?? SettingsStore.shared
        self.settings = settings
        self.meetingLocation = MeetingLocationService(settings: settings)
        settings.migrateMobileSetup()
        let store = store ?? MeetingSessionStore.shared
        let asr = ASRService(settings: settings)
        let privacy = privacy ?? PichiTranscriptPrivacyService(beginOrdinaryWork: {
            let residency = await MainActor.run { MeetingModelResidencyCoordinator.shared }
            // An admitted recording joins its matching preparation on the deferred worker.
            // Other privacy operations retire the optional lease before native work begins.
            if await MainActor.run(body: { asr.activeExclusiveActivity == .meeting || residency.isExclusive }) { return nil }
            return try await residency.beginOperationRetiringIdle(owner: "text-privacy", modelID: "selected-text-privacy")
        }, endOrdinaryWork: { token in await MeetingModelResidencyCoordinator.shared.endOperation(token) })
        // A host can decorate the prepared privacy service without replacing its
        // installation/readiness lifecycle or the shared publication contract.
        let meetingRedactor: any TranscriptTextRedacting = privacyRedactor ?? privacy
        let resolveMicrophone = microphoneResolver ?? { try await IOSMeetingCaptureEngine.defaultMicrophone(preferredUID: $0) }
        self.asr = asr; self.meetingStore = store; self.transcriptPrivacy = privacy
        self.requiredResources = MobileRequiredResources()
        self.privacyActivation = MobilePrivacyActivation(settings: settings, canPrepare: {
            asr.activeExclusiveActivity == nil && !asr.hasActiveModelPreparation
                && !MeetingModelResidencyCoordinator.shared.isExclusive
        }, prepare: { progress in
            try await privacy.prepare(progress: progress)
        })
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { asr }, settings: settings,
            privacyRedactorProvider: { try settings.transcriptPrivacyRedactor(wrapping: meetingRedactor) },
            prepareDiarizationModel: { _ = try await MeetingDiarizationModelStore.shared.ensureInstalled(includingVoiceEncoder: true) },
            prepareDiarizationDependencies: { try await MeetingDiarizationModelStore.shared.prepare(dependencies: $0) })
        self.meetingProcessingPipeline = pipeline
        let capture = injectedCapture ?? IOSMeetingCaptureEngine(memoryConsumerFactory: { session, _, track, event in
            try await pipeline.memoryConsumer(for: session.id, track: track, eventHandler: event)
        })
        let arbiter = AudioActivityArbiter { asr }
        self.meetingAudioActivityArbiter = arbiter
        self.meetingSessionCoordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: pipeline, audioArbiter: arbiter,
            preferredMicrophoneUID: { settings.meetingRecordingDefaults.microphoneCoreAudioUID },
            speechActivityModel: MeetingSileroActivityArtifacts.open,
            settings: settings,
            locationResolver: injectedCapture == nil ? self.meetingLocation : nil,
            defaultConfigurationResolver: { mode, title in
                // Preferences are one immutable request snapshot. Async discovery/preparation
                // cannot substitute later Settings values into a running meeting.
                let preferences = settings.meetingRecordingDefaults
                let modelID = settings.selectedSpeechModel.rawValue
                let savedBackendID = settings.meetingTranscriptionBackendID
                let storageMode: MeetingAudioStorageMode = settings.meetingSaveAudio ? .retainedFiles : .memoryOnly
                let speakerLabelsEnabled = settings.meetingSpeakerLabelsEnabled
                let speakerProcessingMode = settings.meetingSpeakerProcessingMode(for: mode)
                let piiRedactionEnabled = settings.meetingPIIRedactionRequested
                let supported = PichiMeetingProviderFactory.registeredLanguageCodes(for: modelID) ?? []
                let language = preferences.languageCode.flatMap { supported.contains($0) ? $0 : nil }
                    ?? PichiMeetingProviderFactory.defaultLanguageCode(for: modelID) ?? "auto"
                let microphone = try await resolveMicrophone(preferences.microphoneCoreAudioUID)
                try Task.checkCancellation()
                guard settings.selectedSpeechModel.rawValue == modelID,
                      settings.meetingTranscriptionBackendID == savedBackendID else { throw CancellationError() }
                let configuration = MeetingCaptureConfiguration(mode: mode, title: title, languageCode: language,
                    microphone: microphone, timestampDefaultTitle: true, audioStorageMode: storageMode,
                    speakerLabelsEnabled: speakerLabelsEnabled, speakerProcessingMode: speakerProcessingMode,
                    piiRedactionEnabled: piiRedactionEnabled)
                // Deployment admission uses the frozen privacy request. The processing owner
                // prepares its pinned text redactor before recognizing or publishing speech.
                if storageMode == .memoryOnly || configuration.effectiveSpeakerProcessingMode == .streaming {
                    let backendID = PichiMeetingProviderFactory.selectedBackendID(languageCode: language,
                        selectedModelID: modelID, savedBackendID: savedBackendID)
                    _ = try pipeline.validateMemoryAudioInput(configuration: configuration, backendID: backendID)
                }
                try Task.checkCancellation()
                guard settings.selectedSpeechModel.rawValue == modelID,
                      settings.meetingTranscriptionBackendID == savedBackendID else { throw CancellationError() }
                return configuration
            },
            redactorProvider: { try settings.transcriptPrivacyRedactor(wrapping: meetingRedactor) },
            validateRecordingModels: {
                try await asr.prepareSelectedModelForRecording()
            },
            prepareRecordingDependencies: { try await MeetingDiarizationModelStore.shared.prepare(dependencies: $0) },
            validateFrozenRecordingConfiguration: {
                try PichiMeetingProviderFactory.validateRecordingConfiguration($0, isAppleSilicon: CPUArchitecture.isAppleSilicon)
            }
        )
        for publisher in [settings.objectWillChange, asr.objectWillChange, meetingSessionCoordinator.objectWillChange, requiredResources.objectWillChange] {
            publisher.sink { [weak self] in
                Task { @MainActor in
                    // objectWillChange arrives before its new setting/activity is committed.
                    await Task.yield()
                    await self?.updateIdlePreparation()
                }
            }.store(in: &idlePreparationObservers)
        }
        MeetingModelResidencyCoordinator.shared.ordinaryOperationEvents.sink { [weak self] in
            Task { @MainActor in await self?.idleResourcesChanged() }
        }.store(in: &idlePreparationObservers)
        observeIdleResourceStores()
        do {
            try self.privateProfiles.configure(isBusy: { [weak self] in
                guard let self else { return true }
                return (publicationStore != nil && self.cloudPublicationActivation?.isInstalled != true)
                    || !self.meetingSessionCoordinator.isQuiescent || !self.asr.canBeginPrivateProfileTransition
                    || self.privateProfiles.hasRetainedCaptureStopHandler
            }, prepare: { [weak self] in
                guard let self else { throw AccountError.isolationRequired }
                self.requiredPreparationTask?.cancel(); await self.requiredPreparationTask?.value
                self.requiredPreparationTask = nil
                await self.updateIdlePreparation()
                try await PrivateProfileSources.prepare(coordinator: self.meetingSessionCoordinator, asr: self.asr)
            }, activate: { [weak self] profile in
                guard let self else { throw AccountError.isolationRequired }
                try await PrivateProfileSources.activate(profile, asr: self.asr)
                self.privacyActivation.restore()
            }, conceal: {
                await PrivateProfileSources.conceal()
            })
            try self.accountSession.installLifecycle(self.privateProfiles)
            if isProductionComposition { PrivateProfileStorage.closeAdmission() }
        } catch {
            DebugLogger.shared.warning("Private profile lifecycle unavailable", source: "MobileAppServices")
        }
        if let publicationStore {
            let http: (any PichiPublicationHTTPPerforming)? = isProductionComposition
                ? self.accountSession.configuration.flatMap { try? PichiPublicationHTTPClient(configuration: $0) }
                : publicationHTTP
            let service = PichiCloudPublicationService(account: self.accountSession, meetings: publicationStore,
                profiles: self.privateProfiles, http: http)
            self.cloudPublicationActivation = PichiCloudPublicationActivation(service: service,
                account: self.accountSession, profiles: self.privateProfiles)
        }
    }

    func signalUIReady() async {
        guard !isUIReady else { return }
        isUIReady = true
        await restoreAccountBeforePrivateUI()
        guard PrivateProfileStorage.acceptsNewWork else { return }
        await meetingSessionCoordinator.ensureRestored()
        await meetingSessionCoordinator.sweepExpiredAudio()
        hasRestoredInitialState = true
        privacyActivation.restore()
        requiredPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Artifact installation only. ASR follows explicit selection; optional privacy
            // has its own requested transaction and is never downloaded here.
            try? await requiredResources.prepare(modelID: settings.selectedSpeechModel.rawValue)
        }
        await updateIdlePreparation()
    }

    func restoreAccountBeforePrivateUI() async {
        if accountRestorationTask == nil {
            accountRestorationTask = Task { @MainActor in
                if let publication = cloudPublicationActivation {
                    do { try await publication.install() }
                    catch {
                        DebugLogger.shared.warning("Cloud publication composition unavailable", source: "MobileAppServices")
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                await accountSession.restore()
                guard !Task.isCancelled else { return }
                let current = PrivateProfileStorage.current
                if current.isReadable { PrivateProfileStorage.select(current) }
                await cloudPublicationActivation?.activateAfterAccountCommand()
                guard !Task.isCancelled else { return }
                hasRestoredAccount = true
            }
        }
        await accountRestorationTask?.value
    }
    func restorePrivateSourcesAfterCommit() async {
        guard PrivateProfileStorage.acceptsNewWork else { return }
        await meetingSessionCoordinator.ensureRestored()
        await cloudPublicationActivation?.activateAfterAccountCommand()
    }

    func setSceneActive(_ active: Bool) async {
        isSceneActive = active
        await updateIdlePreparation()
    }

    func didReceiveMemoryWarning() async {
        await idlePreparation.didReceiveMemoryWarning()
    }

    func shutdownForTermination() async {
        accountRestorationTask?.cancel(); await accountRestorationTask?.value
        accountRestorationTask = nil
        await cloudPublicationActivation?.shutdown()
        await accountSession.shutdown()
        await idlePreparation.shutdown()
        await meetingSessionCoordinator.shutdownForTermination()
        await asr.shutdownForTermination()
    }

    var hasActivePrivateCapture: Bool {
        meetingSessionCoordinator.isRecording || privateProfiles.hasRetainedCaptureStopHandler
    }
    func stopPrivateCaptureAndLogout() async {
        if meetingSessionCoordinator.isRecording { _ = try? await meetingSessionCoordinator.stopAndTranscribe() }
        else { await privateProfiles.requestCaptureStop() }
        await accountSession.logout()
    }
    func retryPrivateProfileCleanupAndLogout() async { await accountSession.logout() }

    private func updateIdlePreparation() async {
        observeIdleResourceStores()
        let coordinator = meetingSessionCoordinator
        let meetingActivity = coordinator.hasPendingStart || coordinator.isRecording || coordinator.isProcessing
            || asr.activeExclusiveActivity == .meeting
        let otherWork = !coordinator.isQuiescent && !meetingActivity
            || (asr.activeExclusiveActivity != nil && asr.activeExclusiveActivity != .meeting)
            || asr.hasActiveModelPreparation
            || (MeetingModelResidencyCoordinator.shared.isExclusive && !meetingActivity)
            || MeetingModelResidencyCoordinator.shared.hasOrdinaryOperations
            || isPreparingIdleResources
        let identity = [transcriptPrivacy.checkpointIdentity ?? "", settings.selectedSpeechModel.rawValue,
                        settings.meetingTranscriptionBackendID.rawValue,
                        settings.meetingRecordingDefaults.languageCode ?? "",
                        String(settings.meetingPIIRedactionEnabled), String(settings.meetingSpeakerLabelsEnabled),
                        settings.meetingSpeakerProcessingMode(for: .inRoom).rawValue, String(settings.meetingSaveAudio)].joined(separator: "|")
        let enabled = settings.meetingPIIRedactionEnabled || settings.meetingSpeakerProcessingMode(for: .inRoom) == .streaming
        if MeetingTimelineTrace.enabled {
            let decision = ["sceneActive": String(isSceneActive), "uiReady": String(isUIReady),
                "restoreComplete": String(hasRestoredInitialState), "quiescent": String(coordinator.isQuiescent),
                "recordingActivity": String(meetingActivity), "otherWork": String(otherWork), "enabled": String(enabled),
                "speakerOrVADResourceWork": String(isPreparingIdleResources),
                "ordinaryResidencyWork": String(MeetingModelResidencyCoordinator.shared.hasOrdinaryOperations),
                "adoptionSupported": String(asr.supportsPreparedProviderAdoption), "hasResidencyOwner": String(asr.idleModelResidency != nil)]
            if decision != lastIdleDecision {
                lastIdleDecision = decision
                MeetingTimelineTrace.shared?.record("idle_preparation_decision", fields: decision)
            }
        }
        await idlePreparation.update(.init(isSceneActive: isSceneActive, isUIReady: isUIReady && hasRestoredInitialState && PrivateProfileStorage.acceptsNewWork,
            preparationEnabled: enabled, configurationIdentity: identity,
            hasRecordingActivity: meetingActivity, hasOtherModelWork: otherWork, resourceRevision: idleResourceRevision))
    }

    private var isPreparingIdleResources: Bool {
        if requiredResources.isPreparing || MeetingSpeechActivityResources.shared.isPreparing { return true }
        switch observedSpeakerStore?.state {
        case .checking?, .downloading?: return true
        default: return false
        }
    }

    private func observeIdleResourceStores() {
        let store = PichiMeetingProviderFactory.speakerModelStore(for: settings.selectedSpeechModel.rawValue,
            speakerProcessingMode: settings.meetingSpeakerProcessingMode(for: .inRoom))
        guard idleResourceObservers.isEmpty || store !== observedSpeakerStore else { return }
        observedSpeakerStore = store
        idleResourceObservers.removeAll()
        let publishers = [store?.objectWillChange, MeetingSpeechActivityResources.shared.objectWillChange,
                          MeetingDiarizationModelStore.shared.objectWillChange].compactMap { $0 }
        for publisher in publishers {
            publisher.sink { [weak self] in
                Task { @MainActor in await Task.yield(); await self?.idleResourcesChanged() }
            }.store(in: &idleResourceObservers)
        }
    }

    private func idleResourcesChanged() async {
        pendingIdleResourceEvent = true
        guard idleResourceUpdateTask == nil else { return }
        idleResourceUpdateTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                pendingIdleResourceEvent = false
                await Task.yield()
                // A recording's readiness checks publish store state too. Preserve its
                // admitted claim; the normal adapter revalidates it before adoption.
                if !meetingSessionCoordinator.hasPendingStart, !meetingSessionCoordinator.isRecording,
                   !meetingSessionCoordinator.isProcessing, asr.activeExclusiveActivity != .meeting {
                    idleResourceRevision = UUID()
                }
                await updateIdlePreparation()
            } while pendingIdleResourceEvent
            idleResourceUpdateTask = nil
        }
    }
}

@main
struct PichiVoiceMobileApp: App {
    @StateObject private var services = AppServices.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() { FirstMeetingTip.configure() }

    var body: some Scene {
        WindowGroup {
            AdaptiveAppTheme(accent: settings.accentColor) {
                #if DEBUG
                if ProcessInfo.processInfo.environment["PICHI_UI_CAPTION_REVIEW"] == "1" {
                    MobileCaptionScrollReview()
                } else {
                    meetingRoot
                }
                #else
                meetingRoot
                #endif
            }.task {
                #if DEBUG
                // Hosted unit probes own their injected model operations. The ordinary
                // UI-test application runs in another process and retains real startup.
                if NSClassFromString("XCTestCase") != nil { return }
                if ProcessInfo.processInfo.environment["PICHI_UI_CAPTION_REVIEW"] == "1" { return }
                #if targetEnvironment(simulator)
                // Saved-meeting presentation tests use the normal root/store while
                // skipping unrelated launch-time artifact installation and inference.
                if ProcessInfo.processInfo.environment["PICHI_UI_SAVED_MEETING_REVIEW"] == "1" { return }
                #endif
                #endif
                await services.signalUIReady()
            }
            // The initial task may outlive a scene transition while restoration joins.
            // This one source owns both initial and later phase values, so its old
            // captured scene cannot overwrite a newer foreground event after restore.
            .onChange(of: scenePhase, initial: true) { _, phase in
                Task { await services.setSceneActive(phase == .active) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                Task { await services.didReceiveMemoryWarning() }
            }
        }
    }

    @ViewBuilder private var meetingRoot: some View {
        PrivateProfileRoot(services: services, profiles: services.privateProfiles) { privateMeetingContent }
    }

    @ViewBuilder private var privateMeetingContent: some View {
        if !settings.mobileSetupCompleted {
            MobileOnboarding(accountSession: services.accountSession, cloudPublication: services.cloudPublication,
                asr: services.asr, required: services.requiredResources, privacy: services.privacyActivation,
                audioArbiter: services.meetingAudioActivityArbiter)
        } else {
                MobileMeetingRoot(coordinator: services.meetingSessionCoordinator, asr: services.asr,
                    store: services.meetingStore, privacy: services.transcriptPrivacy,
                    required: services.requiredResources, privacyActivation: services.privacyActivation,
                    accountSession: services.accountSession, cloudPublication: services.cloudPublication,
                    microphones: { await IOSMeetingCaptureEngine.microphoneSnapshot() })
        }
    }
}

#if DEBUG
/// Isolated UI automation uses the production caption viewport without a microphone,
/// model or stored meeting. It cannot be selected in a distributed Release app.
private struct MobileCaptionScrollReview: View {
    @State private var rows: [MeetingLiveBubbleComposer.Row] = (0..<100).map { index in
        .init(id: UUID(), speaker: .you,
              text: "Проверка \(index). Русский и English текст продолжаются в одном разговоре.",
              isPartial: false, showsLabel: index == 0)
    }

    var body: some View {
        MeetingLiveBubbleScrollList(rows: rows, documentStyle: true)
            .padding(24)
            .task {
                while !Task.isCancelled, rows.count < 180 {
                    do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
                    rows.append(.init(id: UUID(), speaker: .you, text: "Продолжение \(rows.count). New words keep arriving.",
                                      isPartial: false, showsLabel: false))
                }
            }
    }
}
#endif
