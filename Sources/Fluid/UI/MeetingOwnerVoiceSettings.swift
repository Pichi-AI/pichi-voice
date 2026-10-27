import Combine
import SwiftUI

/// The two platform Settings screens share this transaction. Only the microphone
/// identity and existing application audio arbiter are supplied by their hosts.
struct MeetingOwnerVoiceSettingsContent: View {
    let microphone: MeetingMicrophoneIdentity?
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: MeetingOwnerVoiceEnrollmentModel

    init(audioArbiter: any MeetingAudioActivityArbitrating, microphone: MeetingMicrophoneIdentity?) {
        self.init(model: MeetingOwnerVoiceEnrollmentModel(audioArbiter: audioArbiter), microphone: microphone)
    }

    /// A restricted host observes the same transaction to keep recording and dismissal
    /// unavailable until microphone cancellation and resource handback have joined.
    init(model: MeetingOwnerVoiceEnrollmentModel, microphone: MeetingMicrophoneIdentity?) {
        self.microphone = microphone
        self._model = StateObject(wrappedValue: model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Label(PichiLocalization.text(self.model.hasProfile ? "Your voice is saved" : "Your voice is not set up"),
                  systemImage: self.model.hasProfile ? "person.crop.circle.badge.checkmark" : "person.wave.2")
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.model.hasProfile ? self.theme.palette.success : self.theme.palette.primaryText)
                .accessibilityIdentifier("ownerVoice.status")
            Text(PichiLocalization.text("Set up your voice so matching speech is labelled You in future meetings. The voice profile stays on this device."))
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
            if self.model.phase == .recording || self.model.phase == .ready || !self.model.hasProfile {
                Text(PichiLocalization.text("Read aloud at a natural pace for 15 to 20 seconds. Audio stays in memory and is discarded after checking. Only Save stores the voice profile."))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text(PichiLocalization.text("Today I am setting up my voice for meeting transcripts. I speak at a natural pace and keep the microphone at a comfortable distance. This sample helps the app distinguish my voice from other people. I can remove my voice profile in Settings at any time."))
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(self.theme.metrics.spacing.md)
                    .background(self.theme.palette.secondaryText.opacity(0.06), in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                    .accessibilityIdentifier("ownerVoice.readingPrompt")
            }
            if self.model.phase == .recording {
                HStack(spacing: self.theme.metrics.spacing.md) {
                    // The same live level as a recording meeting.
                    AudioWaveformBars(color: self.theme.palette.accent, barCount: 7, barWidth: 3, barSpacing: 3,
                        minHeight: 3, maxHeight: 24, level: { CGFloat(min(1, self.model.level * 5)) }, noiseThreshold: 0.02,
                        isAnimating: true, isIdleWaveEnabled: false)
                        .frame(width: 45, height: 26).accessibilityHidden(true)
                    ProgressView(value: self.model.seconds, total: MeetingOwnerVoiceEnrollmentCapture.maximumSeconds)
                        .accessibilityLabel(PichiLocalization.text("Voice sample duration"))
                }
                Text(Duration.seconds(self.model.seconds).formatted(.time(pattern: .minuteSecond)))
                    .font(self.theme.typography.caption).monospacedDigit()
                    .accessibilityIdentifier("ownerVoice.duration")
            } else if self.model.phase == .preparing || self.model.phase == .checking || self.model.phase == .saving {
                ProgressView(PichiLocalization.text(self.model.phase == .checking ? "Checking voice sample…" : self.model.phase == .saving ? "Saving…" : "Preparing microphone…"))
            } else if self.model.phase == .ready {
                Label(PichiLocalization.text("Voice sample is ready. Save to use it in future meetings."), systemImage: "checkmark.circle")
                    .font(self.theme.typography.bodySmall)
            }
            if let error = self.model.error {
                Text(error).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
                    .accessibilityIdentifier("ownerVoice.error")
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: self.theme.metrics.spacing.md) { self.actions }
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) { self.actions }
            }
            .buttonStyle(.bordered)
            #if os(iOS)
            .controlSize(.large)
            #endif
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.ownerVoice")
        .task { await self.model.refresh() }
        .onDisappear { self.model.cancelIfVisible() }
        .onChange(of: self.scenePhase) { _, phase in
            // System permission prompts temporarily make the scene inactive.
            if phase == .background { self.model.cancel() }
        }
    }

    @ViewBuilder private var actions: some View {
        if self.model.phase == .recording {
            // Once the sample is long enough, finishing becomes the clear next step.
            if self.model.seconds >= MeetingOwnerVoiceEnrollmentCapture.recommendedSeconds {
                Button(PichiLocalization.text("Done")) { self.model.finishRecording() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("ownerVoice.stop")
            } else {
                Button(PichiLocalization.text("Stop")) { self.model.finishRecording() }
                    .accessibilityIdentifier("ownerVoice.stop")
            }
            Button(PichiLocalization.text("Cancel")) { self.model.cancel() }
                .accessibilityIdentifier("ownerVoice.cancel")
        } else if self.model.isBusy {
            Button(PichiLocalization.text("Cancel")) { self.model.cancel() }
                .accessibilityIdentifier("ownerVoice.cancel")
        } else {
            Button(PichiLocalization.text(self.model.phase == .ready || self.model.hasProfile ? "Record again" : "Set up my voice")) {
                self.model.start(microphone: self.microphone)
            }.accessibilityIdentifier("ownerVoice.start")
            if self.model.phase == .ready {
                Button(PichiLocalization.text("Save")) { self.model.save() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("ownerVoice.save")
                Button(PichiLocalization.text("Cancel")) { self.model.discardDraft() }
                    .accessibilityIdentifier("ownerVoice.cancel")
            }
            if self.model.hasProfile {
                Button(PichiLocalization.text("Delete voice profile"), role: .destructive) { self.model.showDeleteConfirmation = true }
                    .accessibilityIdentifier("ownerVoice.delete")
                    .confirmationDialog(PichiLocalization.text("Delete your voice profile?"), isPresented: self.$model.showDeleteConfirmation, titleVisibility: .visible) {
                        Button(PichiLocalization.text("Delete"), role: .destructive) { self.model.delete() }
                        Button(PichiLocalization.text("Cancel"), role: .cancel) {}
                    } message: {
                        Text(PichiLocalization.text("Future meetings will use participant labels until you set up your voice again. Existing transcripts are unchanged."))
                    }
            }
        }
    }
}

@MainActor
final class MeetingOwnerVoiceEnrollmentModel: ObservableObject, PrivateProfileTransitionParticipant {
    enum Phase: Equatable { case idle, preparing, recording, checking, ready, saving }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var hasProfile = false
    @Published private(set) var seconds: Double = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var error: String?
    @Published var showDeleteConfirmation = false
    private let profile = PrivateProfileStorage.current
    private var captureStopID: UUID?
    private var isProfileVisible: Bool { PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork }
    private let audioArbiter: any MeetingAudioActivityArbitrating
    private let service: MeetingOwnerVoiceProfileService
    private let modelResidency: MeetingModelResidencyCoordinator
    private let makeCapture: @MainActor () throws -> MeetingOwnerVoiceEnrollmentCapture
    private var draft: MeetingOwnerVoiceProfileDraft?
    private var operation: Task<Void, Never>?
    private var stopRequested = false
    var isBusy: Bool { self.phase != .idle && self.phase != .ready }

    init(audioArbiter: any MeetingAudioActivityArbitrating, service: MeetingOwnerVoiceProfileService = .shared,
         modelResidency: MeetingModelResidencyCoordinator = .shared,
         makeCapture: @escaping @MainActor () throws -> MeetingOwnerVoiceEnrollmentCapture = { try MeetingOwnerVoiceEnrollmentCapture() }) {
        self.audioArbiter = audioArbiter
        self.service = service
        self.modelResidency = modelResidency
        // The factory keeps lease/cancellation regressions from opening audio hardware.
        // Production still constructs the existing capture only after model admission.
        self.makeCapture = makeCapture
        PrivateProfileService.shared.register(self)
    }

    func refresh() async {
        guard isProfileVisible else { return }
        do {
            let exists = try await self.service.metadata() != nil
            if isProfileVisible { self.hasProfile = exists }
        } catch { if isProfileVisible { self.error = Self.message(for: error) } }
    }

    func start(microphone: MeetingMicrophoneIdentity?) {
        guard self.isProfileVisible, self.operation == nil,
              !PrivateProfileService.shared.hasRetainedCaptureStopHandler else { return }
        let captureID = UUID()
        guard PrivateProfileService.shared.installCaptureStopHandler(id: captureID, stop: {
            self.finishRecording()
            await self.operation?.value
        }) else { return }
        self.captureStopID = captureID
        let preferredMicrophoneUID = SettingsStore.shared.meetingRecordingDefaults.microphoneCoreAudioUID
        self.error = nil; self.draft = nil; self.seconds = 0; self.stopRequested = false
        self.phase = .preparing
        self.operation = Task {
            var lease: MeetingAudioActivityLease?
            var modelOperation: UUID?
            var capture: MeetingOwnerVoiceEnrollmentCapture?
            do {
                let acquired = try await self.audioArbiter.acquireMeetingCapture()
                lease = acquired
                try Task.checkCancellation()
                // The audio lease also serves meetings, whose prepared resources are
                // adopted later. Enrollment cannot adopt them. Join an existing idle
                // prime and hold ordinary admission so a queued prime cannot restart.
                modelOperation = try await self.modelResidency.beginOperationRetiringIdle(
                    owner: "voice-enrollment", modelID: "voice-matching")
                try Task.checkCancellation()
                let selected: MeetingMicrophoneIdentity
                if let microphone { selected = microphone }
                else {
                    #if os(iOS)
                    selected = try await IOSMeetingCaptureEngine.defaultMicrophone(preferredUID: preferredMicrophoneUID)
                    #else
                    selected = try await MeetingCaptureSourceCatalog.defaultMicrophone(preferredCoreAudioUID: preferredMicrophoneUID)
                    #endif
                }
                try Task.checkCancellation()
                guard !self.stopRequested else { throw CancellationError() }
                let active = try self.makeCapture()
                capture = active
                try await active.start(microphone: selected)
                if self.isProfileVisible { self.phase = .recording }
                let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                while !self.stopRequested, active.capturedSeconds < MeetingOwnerVoiceEnrollmentCapture.maximumSeconds, ContinuousClock.now < deadline {
                    try active.checkFailure()
                    let captured = active.capturedSeconds
                    if self.isProfileVisible {
                        self.level = captured > self.seconds ? active.recentLevel : self.level / 2
                        self.seconds = captured
                    } else { self.level = 0 }
                    try await Task.sleep(for: .milliseconds(100))
                }
                self.level = 0
                if self.isProfileVisible { self.seconds = active.capturedSeconds; self.phase = .checking }
                var pcm = try await active.stop(discard: false)
                capture = nil
                do {
                    try Task.checkCancellation()
                    self.draft = try await self.service.prepare(samples: pcm, sampleRate: 16_000)
                    pcm = []
                    try Task.checkCancellation()
                } catch { pcm = []; throw error }
            } catch {
                if let capture { _ = try? await capture.stop(discard: true) }
                self.draft = nil
                if self.isProfileVisible, !(error is CancellationError) { self.error = Self.message(for: error) }
            }
            if let modelOperation { self.modelResidency.endOperation(modelOperation) }
            if let lease { await self.audioArbiter.release(lease) }
            if Task.isCancelled || !self.isProfileVisible { self.draft = nil; self.error = nil }
            self.level = 0
            self.phase = self.draft == nil ? .idle : .ready
            self.operation = nil
            if self.captureStopID == captureID { self.captureStopID = nil }
            PrivateProfileService.shared.clearCaptureStopHandler(id: captureID)
        }
    }

    func finishRecording() { self.stopRequested = true }

    /// The operation owns its cleanup and keeps itself alive until microphone,
    /// PCM conversion and embedding are joined, then releases the audio lease.
    func cancelIfVisible() { if isProfileVisible { cancel() } }

    func cancel() {
        self.operation?.cancel()
        if self.operation == nil { self.discardDraft() }
    }

    func prepareForPrivateProfileTransition() async throws {
        self.level = 0
        // Busy logout hides the retained owner; only the root Stop action or the
        // existing capture deadline ends enrollment. It never auto-saves a profile.
        if captureStopID != nil { hasProfile = false; return }
        let task = operation; task?.cancel()
        await task?.value
        operation = nil; discardDraft(); hasProfile = false; seconds = 0
    }

    func discardDraft() { self.draft = nil; self.phase = .idle; self.error = nil }

    func save() {
        guard self.isProfileVisible, self.operation == nil, let draft = self.draft else { return }
        self.phase = .saving
        self.operation = Task {
            do {
                _ = try await self.service.save(draft)
                if self.isProfileVisible { self.hasProfile = true }
                self.draft = nil
            } catch { if self.isProfileVisible, !(error is CancellationError) { self.error = Self.message(for: error) } }
            self.phase = self.draft == nil ? .idle : .ready
            self.operation = nil
        }
    }

    func delete() {
        guard self.isProfileVisible, self.operation == nil else { return }
        self.phase = .saving
        self.operation = Task {
            do { try await self.service.delete(); self.hasProfile = false; self.draft = nil }
            catch { if self.isProfileVisible, !(error is CancellationError) { self.error = Self.message(for: error) } }
            self.phase = .idle
            self.operation = nil
        }
    }

    static func message(for error: Error) -> String {
        if let error = error as? MeetingOwnerVoiceProfileError {
            switch error {
            case .invalidAudio:
                return PichiLocalization.text("The voice sample could not be read. Please record it again.")
            case .insufficientSpeech:
                return PichiLocalization.text("Not enough clear speech. Read the text aloud for 15 to 20 seconds, then try again.")
            case .inconsistentVoice:
                return PichiLocalization.text("The sample contains different voices or too much noise. Record your voice alone in a quiet room.")
            case .invalidProfile:
                return PichiLocalization.text("The saved voice profile could not be read. Please set up your voice again.")
            case .staleDraft:
                return PichiLocalization.text("The voice profile changed while this sample was being checked. Please record it again.")
            case .busy:
                return PichiLocalization.text("Voice setup is already in progress. Wait for it to finish.")
            }
        }
        if error is ASRActivityError || error is MeetingCoordinatorError {
            return PichiLocalization.text("Finish the current recording or transcription before setting up your voice.")
        }
        if let error = error as? MeetingCaptureError {
            switch error {
            case .microphonePermissionDenied:
                return PichiLocalization.text("Allow microphone access in system Settings, then try again.")
            case .microphoneUnavailable:
                return PichiLocalization.text("The selected microphone is unavailable. Choose an available microphone, then try again.")
            default: break
            }
        }
        return PichiLocalization.text("Voice setup could not finish. Check your microphone and connection, then try again.")
    }
}
