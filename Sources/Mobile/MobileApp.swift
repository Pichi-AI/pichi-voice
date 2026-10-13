import Combine
import SwiftUI

/// iOS host composition of the same application services. Every domain operation remains in
/// the existing coordinator, pipeline, registry, settings, resource and storage owners.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()
    let asr: ASRService
    let meetingSessionCoordinator: MeetingSessionCoordinator
    let meetingStore: any MeetingSessionStoring
    let transcriptPrivacy: PichiTranscriptPrivacyService
    @Published private(set) var isUIReady = false

    init(store: any MeetingSessionStoring = MeetingSessionStore.shared,
         capture injectedCapture: (any MeetingCaptureControlling)? = nil,
         settings: SettingsStore = .shared,
         privacy: PichiTranscriptPrivacyService = .init()) {
        let asr = ASRService(settings: settings)
        self.asr = asr; self.meetingStore = store; self.transcriptPrivacy = privacy
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { asr },
            privacyRedactorProvider: { privacy },
            prepareDiarizationModel: { _ = try await MeetingDiarizationModelStore.shared.ensureInstalled() })
        let capture = injectedCapture ?? IOSMeetingCaptureEngine(memoryConsumerFactory: { session, _, track, event in
            try await pipeline.memoryConsumer(for: session.id, track: track, eventHandler: event)
        })
        let arbiter = AudioActivityArbiter { asr }
        self.meetingSessionCoordinator = MeetingSessionCoordinator(
            store: store, capture: capture, processing: pipeline, audioArbiter: arbiter,
            preferredMicrophoneUID: { settings.meetingRecordingDefaults.microphoneCoreAudioUID },
            settings: settings,
            defaultConfigurationResolver: { mode, title in
                let microphone = try await IOSMeetingCaptureEngine.defaultMicrophone(
                    preferredUID: settings.meetingRecordingDefaults.microphoneCoreAudioUID)
                let modelID = settings.selectedSpeechModel.rawValue
                let supported = PichiMeetingProviderFactory.registeredLanguageCodes(for: modelID) ?? []
                let language = settings.meetingRecordingDefaults.languageCode.flatMap { supported.contains($0) ? $0 : nil }
                    ?? PichiMeetingProviderFactory.defaultLanguageCode(for: modelID) ?? "auto"
                return MeetingCaptureConfiguration(mode: mode, title: title, languageCode: language,
                    microphone: microphone, timestampDefaultTitle: true)
            },
            redactorProvider: { privacy },
            validateRecordingModels: {
                guard settings.selectedSpeechModel.isInstalled else { throw MeetingProcessingError.modelUnavailable }
                if settings.meetingPIIRedactionEnabled, !(await privacy.isReady) { try await privacy.prepare() }
            },
            validateFrozenRecordingConfiguration: {
                try PichiMeetingProviderFactory.validateRecordingConfiguration($0, isAppleSilicon: CPUArchitecture.isAppleSilicon)
            }
        )
    }

    func signalUIReady() async {
        guard !isUIReady else { return }
        isUIReady = true
        await meetingSessionCoordinator.ensureRestored()
        await meetingSessionCoordinator.sweepExpiredAudio()
    }
}

@main
struct PichiVoiceMobileApp: App {
    @StateObject private var services = AppServices.shared
    @ObservedObject private var settings = SettingsStore.shared
    var body: some Scene {
        WindowGroup {
            AdaptiveAppTheme(accent: settings.accentColor) {
                MobileMeetingRoot(coordinator: services.meetingSessionCoordinator, asr: services.asr,
                    store: services.meetingStore, privacy: services.transcriptPrivacy,
                    microphones: { await IOSMeetingCaptureEngine.microphoneSnapshot() })
            }.task { await services.signalUIReady() }
        }
    }
}
