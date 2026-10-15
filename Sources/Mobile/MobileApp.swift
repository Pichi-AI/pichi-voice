import Combine
import SwiftUI

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

    init(store: (any MeetingSessionStoring)? = nil,
         capture injectedCapture: (any MeetingCaptureControlling)? = nil,
         settings: SettingsStore? = nil,
         privacy: PichiTranscriptPrivacyService? = nil,
         microphoneResolver: (@MainActor (String?) async throws -> MeetingMicrophoneIdentity)? = nil) {
        // A cold-start operation only. Additional service compositions must not remove
        // files currently being used by an already-open native share sheet.
        if !Self.didCleanExportStaging {
            try? MeetingSharePayload.cleanupAbandonedShares()
            Self.didCleanExportStaging = true
        }
        let settings = settings ?? SettingsStore.shared
        let store = store ?? MeetingSessionStore.shared
        let privacy = privacy ?? PichiTranscriptPrivacyService()
        let resolveMicrophone = microphoneResolver ?? { try await IOSMeetingCaptureEngine.defaultMicrophone(preferredUID: $0) }
        let asr = ASRService(settings: settings)
        self.asr = asr; self.meetingStore = store; self.transcriptPrivacy = privacy
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: { asr }, settings: settings,
            privacyRedactorProvider: { privacy },
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
            settings: settings,
            defaultConfigurationResolver: { mode, title in
                // Preferences are one immutable request snapshot. Async discovery/preparation
                // cannot substitute later Settings values into a running meeting.
                let preferences = settings.meetingRecordingDefaults
                let modelID = settings.selectedSpeechModel.rawValue
                let savedBackendID = settings.meetingTranscriptionBackendID
                let storageMode: MeetingAudioStorageMode = settings.meetingSaveAudio ? .retainedFiles : .memoryOnly
                let speakerLabelsEnabled = settings.meetingSpeakerLabelsEnabled
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
                    speakerLabelsEnabled: speakerLabelsEnabled, piiRedactionEnabled: piiRedactionEnabled)
                // Deployment admission uses the frozen privacy request before preparing even
                // the text redactor. Start/capture owners repeat it after asynchronous work.
                if storageMode == .memoryOnly {
                    let backendID = PichiMeetingProviderFactory.selectedBackendID(languageCode: language,
                        selectedModelID: modelID, savedBackendID: savedBackendID)
                    _ = try pipeline.validateMemoryAudioInput(configuration: configuration, backendID: backendID)
                }
                if piiRedactionEnabled, !(await privacy.isReady) { try await privacy.prepare() }
                try Task.checkCancellation()
                guard settings.selectedSpeechModel.rawValue == modelID,
                      settings.meetingTranscriptionBackendID == savedBackendID else { throw CancellationError() }
                return configuration
            },
            redactorProvider: { privacy },
            validateRecordingModels: {
                try await asr.prepareSelectedModelForRecording()
            },
            prepareRecordingDependencies: { try await MeetingDiarizationModelStore.shared.prepare(dependencies: $0) },
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
