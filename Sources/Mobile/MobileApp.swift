import Combine
import SwiftUI
import UIKit

/// iOS host composition of the same application services. Every domain operation remains in
/// the existing coordinator, pipeline, registry, settings, resource and storage owners.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()
    let asr: ASRService
    let meetingSessionCoordinator: MeetingSessionCoordinator
    let meetingProcessingPipeline: MeetingProcessingPipeline
    let meetingStore: any MeetingSessionStoring
    let meetingAudioActivityArbiter: AudioActivityArbiter
    let transcriptPrivacy: PichiTranscriptPrivacyService
    @Published private(set) var isUIReady = false
    private static var didCleanExportStaging = false
    private let settings: SettingsStore
    private var idlePreparationObservers: Set<AnyCancellable> = []
    private var isSceneActive = false
    private var hasRestoredInitialState = false
    private lazy var idlePrivacyPreparation = PichiPrivacyIdlePreparationController(
        prepare: { [transcriptPrivacy] in try await transcriptPrivacy.prepareInstalledForIdle() },
        release: { [transcriptPrivacy] token in await transcriptPrivacy.releaseIdlePreparation(token) })

    init(store: (any MeetingSessionStoring)? = nil,
         capture injectedCapture: (any MeetingCaptureControlling)? = nil,
         settings: SettingsStore? = nil,
         privacy: PichiTranscriptPrivacyService? = nil,
         privacyRedactor: (any TranscriptTextRedacting)? = nil,
         microphoneResolver: (@MainActor (String?) async throws -> MeetingMicrophoneIdentity)? = nil) {
        // A cold-start operation only. Additional service compositions must not remove
        // files currently being used by an already-open native share sheet.
        if !Self.didCleanExportStaging {
            try? MeetingSharePayload.cleanupAbandonedShares()
            Self.didCleanExportStaging = true
        }
        let settings = settings ?? SettingsStore.shared
        self.settings = settings
        let store = store ?? MeetingSessionStore.shared
        let privacy = privacy ?? PichiTranscriptPrivacyService()
        // A host can decorate the prepared privacy service without replacing its
        // installation/readiness lifecycle or the shared publication contract.
        let meetingRedactor: any TranscriptTextRedacting = privacyRedactor ?? privacy
        let resolveMicrophone = microphoneResolver ?? { try await IOSMeetingCaptureEngine.defaultMicrophone(preferredUID: $0) }
        let asr = ASRService(settings: settings)
        self.asr = asr; self.meetingStore = store; self.transcriptPrivacy = privacy
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { asr }, settings: settings,
            privacyRedactorProvider: { meetingRedactor },
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
            defaultConfigurationResolver: { mode, title in
                // Preferences are one immutable request snapshot. Async discovery/preparation
                // cannot substitute later Settings values into a running meeting.
                let preferences = settings.meetingRecordingDefaults
                let modelID = settings.selectedSpeechModel.rawValue
                let savedBackendID = settings.meetingTranscriptionBackendID
                let storageMode: MeetingAudioStorageMode = settings.meetingSaveAudio ? .retainedFiles : .memoryOnly
                let speakerLabelsEnabled = settings.meetingSpeakerLabelsEnabled
                let speakerProcessingMode = settings.meetingSpeakerProcessingMode(for: mode)
                let piiRedactionEnabled = settings.meetingPIIRedactionEnabled
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
            redactorProvider: { meetingRedactor },
            validateRecordingModels: {
                try await asr.prepareSelectedModelForRecording()
            },
            prepareRecordingDependencies: { try await MeetingDiarizationModelStore.shared.prepare(dependencies: $0) },
            validateFrozenRecordingConfiguration: {
                try PichiMeetingProviderFactory.validateRecordingConfiguration($0, isAppleSilicon: CPUArchitecture.isAppleSilicon)
            }
        )
        for publisher in [settings.objectWillChange, asr.objectWillChange, meetingSessionCoordinator.objectWillChange] {
            publisher.sink { [weak self] in
                Task { @MainActor in
                    // objectWillChange arrives before its new setting/activity is committed.
                    await Task.yield()
                    await self?.updateIdlePrivacyPreparation()
                }
            }.store(in: &idlePreparationObservers)
        }
    }

    func signalUIReady() async {
        guard !isUIReady else { return }
        isUIReady = true
        await meetingSessionCoordinator.ensureRestored()
        await meetingSessionCoordinator.sweepExpiredAudio()
        hasRestoredInitialState = true
        await updateIdlePrivacyPreparation()
    }

    func setSceneActive(_ active: Bool) async {
        isSceneActive = active
        await updateIdlePrivacyPreparation()
    }

    func didReceiveMemoryWarning() async {
        await idlePrivacyPreparation.didReceiveMemoryWarning()
    }

    private func updateIdlePrivacyPreparation() async {
        let coordinator = meetingSessionCoordinator
        let meetingActivity = coordinator.hasPendingStart || coordinator.isRecording || coordinator.isProcessing
            || asr.activeExclusiveActivity == .meeting
        let otherWork = !coordinator.isQuiescent && !meetingActivity
            || (asr.activeExclusiveActivity != nil && asr.activeExclusiveActivity != .meeting)
            || asr.hasActiveModelPreparation
            || (MeetingModelResidencyCoordinator.shared.isExclusive && !meetingActivity)
        let identity = [transcriptPrivacy.checkpointIdentity ?? "", settings.selectedSpeechModel.rawValue,
                        settings.meetingTranscriptionBackendID.rawValue,
                        settings.meetingRecordingDefaults.languageCode ?? ""].joined(separator: "|")
        await idlePrivacyPreparation.update(.init(isSceneActive: isSceneActive, isUIReady: isUIReady && hasRestoredInitialState,
            privacyEnabled: settings.meetingPIIRedactionEnabled, configurationIdentity: identity,
            hasRecordingActivity: meetingActivity, hasOtherModelWork: otherWork))
    }
}

@main
struct PichiVoiceMobileApp: App {
    @StateObject private var services = AppServices.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.scenePhase) private var scenePhase
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
                if ProcessInfo.processInfo.environment["PICHI_UI_CAPTION_REVIEW"] == "1" { return }
                #endif
                await services.signalUIReady()
                await services.setSceneActive(scenePhase == .active)
            }
            .onChange(of: scenePhase) { _, phase in
                Task { await services.setSceneActive(phase == .active) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                Task { await services.didReceiveMemoryWarning() }
            }
        }
    }

    private var meetingRoot: some View {
                MobileMeetingRoot(coordinator: services.meetingSessionCoordinator, asr: services.asr,
                    store: services.meetingStore, privacy: services.transcriptPrivacy,
                    microphones: { await IOSMeetingCaptureEngine.microphoneSnapshot() })
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
