import SwiftUI

/// A native, resumable presentation of the same model, privacy and voice operations as Settings.
/// Desktop onboarding uses AppKit window/permission controls; mobile reuses its service contracts,
/// portable brand mark, text roles, local model metadata and progressive preparation semantics.
struct MobileOnboarding: View {
    @ObservedObject var asr: ASRService
    @ObservedObject var required: MobileRequiredResources
    @ObservedObject var privacy: MobilePrivacyActivation
    let audioArbiter: any MeetingAudioActivityArbitrating
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selected: SettingsStore.SpeechModel?
    @State private var advancing = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    private var step: Int { settings.mobileSetupStep }
    private let titles = ["Welcome", "Choose Voice Engine", "Automatic speaker labels", "Data cleanup", "My voice", "Ready to meet"]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.lg) {
                    HStack {
                        PichiBrandMark(size: 36, color: theme.palette.accent)
                        Text(AppBrand.appName).font(theme.typography.sectionTitle)
                        Spacer()
                        Text("\(step + 1) / 6").font(theme.typography.caption).monospacedDigit()
                    }
                    ProgressView(value: Double(step + 1), total: 6).accessibilityLabel(PichiLocalization.text("Setup progress"))
                    Text(PichiLocalization.text(titles[step])).font(theme.typography.title)
                        .fixedSize(horizontal: false, vertical: true)
                    content
                    if let error {
                        Text(error).font(theme.typography.bodySmall).foregroundStyle(theme.palette.warning)
                            .accessibilityIdentifier("onboarding.error")
                    }
                }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) { footer }
            .background(theme.palette.windowBackground)
            .foregroundStyle(theme.palette.primaryText)
            .accessibilityIdentifier("onboarding.step.\(step)")
        }
        .task { if selected == nil { selected = settings.mobileSetupSelectedModel ?? settings.selectedSpeechModel } }
        .onChange(of: selected) { _, model in settings.mobileSetupSelectedModel = model }
        .onDisappear { operation?.cancel(); asr.cancelModelDownload() }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0:
            Text(PichiLocalization.text("Record conversations, follow the transcript as people speak, and return to any moment later. Everything is processed on this device."))
                .font(theme.typography.body)
            Label(PichiLocalization.text("Live meeting transcripts"), systemImage: "waveform")
            Label(PichiLocalization.text("Automatic speaker labels"), systemImage: "person.2")
            Label(PichiLocalization.text("Optional local data cleanup"), systemImage: "lock.shield")
            Text(PichiLocalization.text("An internet connection is needed once to download your selected voice model and the resources for speaker labels."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
        case 1:
            Text(PichiLocalization.text("Choose a local speech model. You can change it later in Settings. Speed and memory use depend on your device."))
                .font(theme.typography.body)
            ForEach(asr.availableMeetingModels, id: \.id) { model in
                Button { selected = model } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(model.displayName).font(theme.typography.bodyStrong)
                            Spacer()
                            Image(systemName: selected == model ? "checkmark.circle.fill" : "circle")
                        }
                        Text(PichiLocalization.text(model.cardDescription)).font(theme.typography.bodySmall)
                        Text(PichiLocalization.text(model.languageSupport)).font(theme.typography.caption)
                        Text(model.downloadSize).font(theme.typography.caption).monospacedDigit()
                    }.foregroundStyle(theme.palette.primaryText).padding(16)
                        .background(theme.palette.secondaryText.opacity(selected == model ? 0.12 : 0.05),
                                    in: RoundedRectangle(cornerRadius: theme.metrics.corners.md))
                }.buttonStyle(.plain).disabled(advancing)
                    .accessibilityIdentifier("onboarding.model.\(model.id)")
                    .accessibilityAddTraits(selected == model ? .isSelected : [])
            }
            if advancing { MobileASRPreparationStatus(asr: asr) }
        case 2:
            Text(PichiLocalization.text("Speaker labels appear automatically while you record. Short or overlapping speech can be uncertain. You can correct participant names later."))
                .font(theme.typography.body)
            MobileRequiredResourcesStatus(resources: required)
            Text(PichiLocalization.text("Speech detection and speaker resources prepare automatically. This installs files without loading every speech model into memory."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
        case 3:
            MobileAudioPrivacyControls()
            MobilePrivacyActivationControls(activation: privacy)
        case 4:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "waveform").symbolEffect(.variableColor, options: .repeating, isActive: !reduceMotion)
                    .foregroundStyle(theme.palette.accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(PichiLocalization.text("You")).font(theme.typography.captionStrong).foregroundStyle(theme.palette.accent)
                    Text(PichiLocalization.text("Your speech can carry your own label."))
                        .font(theme.typography.body)
                }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.secondaryText.opacity(0.06), in: RoundedRectangle(cornerRadius: theme.metrics.corners.md))
                .accessibilityIdentifier("onboarding.youDemo")
            Text(PichiLocalization.text("Find a quiet place and read the phrase below. The microphone starts only when you choose Set up my voice. You can skip this step."))
                .font(theme.typography.bodySmall)
            MeetingOwnerVoiceSettingsContent(audioArbiter: audioArbiter, microphone: nil)
        default:
            Label(PichiLocalization.text("Your meeting setup is ready"), systemImage: "checkmark.circle.fill")
                .font(theme.typography.sectionTitle).foregroundStyle(theme.palette.success)
            Text(PichiLocalization.text("Start a recording to see text and participant labels. Your choices for audio storage and data cleanup apply to new meetings."))
                .font(theme.typography.body)
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if step > 0 {
                Button(PichiLocalization.text("Back")) { error = nil; settings.mobileSetupStep -= 1 }
                    .disabled(advancing).accessibilityIdentifier("onboarding.back")
            }
            Spacer()
            if step == 4 {
                Button(PichiLocalization.text("Skip")) { settings.mobileSetupStep = 5 }
                    .disabled(advancing).accessibilityIdentifier("onboarding.skip")
            }
            if advancing {
                Button(PichiLocalization.text("Cancel")) { operation?.cancel(); asr.cancelModelDownload() }
                    .accessibilityIdentifier("onboarding.cancel")
            }
            Button(PichiLocalization.text(step == 5 ? "Get started" : "Next")) { next() }
                .buttonStyle(.borderedProminent).disabled(advancing || (step == 3 && privacy.isPreparing))
                .accessibilityIdentifier("onboarding.next")
        }.controlSize(.large).padding(20).frame(maxWidth: 680).frame(maxWidth: .infinity)
            .background(theme.palette.windowBackground)
    }

    private func next() {
        guard !advancing else { return }
        let current = step
        error = nil; advancing = true
        operation = Task { @MainActor in
            defer { advancing = false; operation = nil }
            do {
                switch current {
                case 1:
                    guard let selected else { throw MeetingProcessingError.modelUnavailable }
                    // Provider preparation validates an existing export and skips its download.
                    // The existing service releases the prepared engine before this returns.
                    try await asr.downloadModel(selected)
                    try Task.checkCancellation()
                    try await asr.activateModel(selected)
                case 2: try await required.prepare(modelID: settings.selectedSpeechModel.rawValue)
                case 3: try await privacy.waitUntilReadyIfRequested()
                default: break
                }
                try Task.checkCancellation()
                guard settings.mobileSetupStep == current else { return }
                if current == 5 { settings.mobileSetupCompleted = true }
                else { settings.mobileSetupStep = current + 1 }
            } catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}

struct MobileASRPreparationStatus: View {
    @ObservedObject var asr: ASRService
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(PichiLocalization.text(status))
            if asr.modelPreparationPhase == .downloading, let fraction = asr.downloadProgress {
                ProgressView(value: fraction)
            } else { ProgressView() }
        }.accessibilityIdentifier("model.preparation.progress")
    }
    private var status: String {
        switch asr.modelPreparationPhase {
        case .downloading: return "Downloading model files…"
        case .optimizing: return "Optimizing model files…"
        case .loading: return "Loading speech model…"
        default: return "Checking speech model…"
        }
    }
}

struct MobileRequiredResourcesStatus: View {
    @ObservedObject var resources: MobileRequiredResources
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch resources.phase {
            case .ready:
                Label(PichiLocalization.text("Speech detection and speaker labels are ready"), systemImage: "checkmark.circle.fill")
            case .failed(let message):
                Text(message)
                Button(PichiLocalization.text("Try again")) {
                    guard let modelID = resources.modelID else { return }
                    Task { try? await resources.prepare(modelID: modelID) }
                }
            default:
                Text(PichiLocalization.text(resources.phase == .speakers ? "Preparing speaker resources…" : "Preparing speech detection…"))
                if let progress = resources.progress { ProgressView(value: progress) }
                else { ProgressView() }
            }
        }.accessibilityIdentifier("recording.requiredResources")
    }
}

struct MobileAudioPrivacyControls: View {
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(PichiLocalization.text("Save audio recordings"), isOn: $settings.meetingSaveAudio)
                .accessibilityIdentifier("privacy.saveAudio")
            Text(PichiLocalization.text("When disabled, audio is never written to files, including temporary files. Only the transcript is saved."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
        }
    }
}

struct MobilePrivacyActivationControls: View {
    @ObservedObject var activation: MobilePrivacyActivation
    @Environment(\.theme) private var theme
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(PichiLocalization.text("Redact sensitive data"), isOn: Binding(
                get: { activation.isRequested }, set: { activation.setEnabled($0) }))
                .accessibilityIdentifier("privacy.pii")
            switch activation.state {
            case .enabling:
                Text(PichiLocalization.text(activation.downloadProgress == 1
                    ? "Loading data cleanup model…" : "Enabling data cleanup…"))
                    .font(theme.typography.caption)
                Group {
                    if let progress = activation.downloadProgress, progress < 1 { ProgressView(value: progress) }
                    else { ProgressView() }
                }.accessibilityIdentifier("privacy.pii.progress")
                Button(PichiLocalization.text("Cancel")) { activation.setEnabled(false) }
                    .accessibilityIdentifier("privacy.pii.cancel")
            case .active:
                Label(PichiLocalization.text("Data cleanup is active"), systemImage: "checkmark.shield")
                    .font(theme.typography.caption).accessibilityIdentifier("privacy.pii.active")
            case .failed(let message):
                Text(PichiLocalization.text("Data cleanup is not active")).font(theme.typography.bodyStrong)
                Text(message).font(theme.typography.caption).foregroundStyle(theme.palette.warning)
                Button(PichiLocalization.text("Try again")) { activation.setEnabled(true) }
                    .accessibilityIdentifier("privacy.pii.retry")
            case .off: EmptyView()
            }
            Text(PichiLocalization.text("Locally hides Russian names, phone numbers, email, card and account numbers, passport details, SNILS, INN, dates of birth, addresses, logins and secrets. Detection can miss data. Review before sharing."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
        }.accessibilityIdentifier("privacy.activation")
    }
}
