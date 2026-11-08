import SwiftUI

/// A native, resumable presentation of the same model, privacy and voice operations as Settings.
/// Desktop onboarding uses AppKit window/permission controls; mobile reuses its service contracts,
/// the shared onboarding light, icon, hero, progress, cards and motion, text roles, local model
/// metadata and progressive preparation semantics.
struct MobileOnboarding: View {
    @ObservedObject var accountSession: AccountSessionService = AppServices.shared.accountSession
    var cloudPublication: PichiCloudPublicationService? = nil
    @ObservedObject private var privateProfile = PrivateProfileService.shared
    @ObservedObject var asr: ASRService
    @ObservedObject var required: MobileRequiredResources
    @ObservedObject var privacy: MobilePrivacyActivation
    let audioArbiter: any MeetingAudioActivityArbitrating
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    // Desktop sizes that still follow the reader's text size.
    @ScaledMetric(relativeTo: .title) private var titleSize: CGFloat = 28
    @ScaledMetric(relativeTo: .subheadline) private var subtitleSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var highlightSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var actionSize = FluidOnboardingLayout.footerButtonFontSize
    @State private var selected: SettingsStore.SpeechModel?
    @State private var advancing = false
    @State private var error: String?
    @State private var operation: Task<Void, Never>?
    @State private var accountActionIsActive = false
    @State private var pageShownAt = -TimeInterval.infinity
    @State private var highlightsHeight: CGFloat = 0
    /// The voice page keeps its actions in the fixed footer, so the footer observes the transaction.
    @StateObject private var voice: MeetingOwnerVoiceEnrollmentModel
    init(accountSession: AccountSessionService = AppServices.shared.accountSession,
         cloudPublication: PichiCloudPublicationService? = nil, asr: ASRService, required: MobileRequiredResources,
         privacy: MobilePrivacyActivation, audioArbiter: any MeetingAudioActivityArbitrating) {
        self.accountSession = accountSession; self.cloudPublication = cloudPublication
        self.asr = asr; self.required = required; self.privacy = privacy; self.audioArbiter = audioArbiter
        self._voice = StateObject(wrappedValue: MeetingOwnerVoiceEnrollmentModel(audioArbiter: audioArbiter))
    }

    private var step: Int { settings.mobileSetupStep }
    private var recordingPresentation: PichiMeetingProviderFactory.RecordingPresentation {
        PichiMeetingProviderFactory.recordingPresentation(for: settings.selectedSpeechModel.rawValue,
            requestedMode: settings.meetingSpeakerProcessingMode)
    }
    /// Phones in either orientation; Plus and Pro Max phones report a regular width in landscape.
    private var isCompact: Bool { horizontalSizeClass == .compact || verticalSizeClass == .compact }
    private let titles = ["Welcome", "Choose Voice Engine", "Automatic speaker labels", "Data cleanup", "My voice", "Recording location", "Ready to record"]

    /// Desktop measures: the step column, the hero widths and the wide first action.
    private enum Metrics {
        static let column: CGFloat = 632
        static let compactHero: CGFloat = 640
        static let highlights: CGFloat = 520
        static let landscapeHighlights: CGFloat = 360
        static let minimumHero: CGFloat = 220
        static let welcomeAction: CGFloat = 236
        /// Large text still fits three Russian actions on a 375 pt phone.
        static let maximumActionFontSize: CGFloat = 20
        /// The large capsule adds about 20 pt on each side of its label.
        static let actionInsets: CGFloat = 40
    }

    var body: some View {
        ZStack {
            FluidOnboardingLight(breathes: step == 0).ignoresSafeArea()
            VStack(spacing: 0) {
                // Laid out on every page, so the page does not shift when the bar appears.
                FluidOnboardingCompactProgress(value: Double(step + 1) / Double(titles.count))
                    .accessibilityRepresentation {
                        ProgressView(value: Double(step + 1), total: Double(titles.count))
                            .accessibilityLabel(PichiLocalization.text("Setup progress"))
                            .accessibilityValue(PichiLocalization.format("Step %lld of %lld", step + 1, titles.count))
                    }
                    .accessibilityHidden(step == 0)
                    .opacity(step == 0 ? 0 : 1)
                    .padding(.top, 12)
                // Only the page moves; the light, progress and actions stay in place.
                ZStack {
                    page.id(step).transition(reduceMotion ? .opacity : FluidOnboardingMotion.stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
        .foregroundStyle(theme.palette.primaryText)
        .tint(theme.palette.accent)
        .animation(reduceMotion ? FluidOnboardingMotion.crossfade : FluidOnboardingMotion.step, value: step)
        .onChange(of: step) { pageShownAt = ProcessInfo.processInfo.systemUptime }
        .sensoryFeedback(.selection, trigger: step)
        .task { if selected == nil { selected = settings.mobileSetupSelectedModel ?? settings.selectedSpeechModel } }
        .onChange(of: selected) { _, model in settings.mobileSetupSelectedModel = model }
        .onDisappear { operation?.cancel(); asr.cancelModelDownload() }
    }

    /// A new page needs a moment to arrive; a quick second tap must not act on it unseen.
    private var isSettling: Bool { ProcessInfo.processInfo.systemUptime - pageShownAt < 0.35 }

    @ViewBuilder private var page: some View {
        if step == 0 {
            welcome
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("onboarding.step.0")
        } else {
            GeometryReader { proxy in
                ScrollViewReader { reader in
                    ScrollView {
                        VStack(spacing: 0) {
                            FluidOnboardingCompactAppIconMark()
                                .padding(.bottom, 22)
                            Text(PichiLocalization.text(titles[step]))
                                .font(.fluidSystem(size: titleSize, weight: .semibold, role: .title))
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("onboarding.step.\(step)")
                            if let subtitle {
                                Text(PichiLocalization.text(subtitle))
                                    .font(.fluidSystem(size: subtitleSize, weight: .medium))
                                    .foregroundStyle(theme.palette.secondaryText)
                                    .multilineTextAlignment(.center)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 14)
                            }
                            VStack(alignment: .leading, spacing: 16) {
                                content
                                if let error {
                                    Text(PichiLocalization.text(error)).font(theme.typography.bodySmall).foregroundStyle(theme.palette.warning)
                                        .accessibilityIdentifier("onboarding.error")
                                }
                            }
                            .padding(.top, 26)
                        }
                        // The desktop column, centered like a desktop step, so cards, text and actions line up.
                        .padding(.horizontal, 24).padding(.vertical, 28)
                        .frame(maxWidth: Metrics.column + 48).frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Preparation shows its progress in the chosen card; keep that card in view.
                    .onChange(of: advancing) { _, isAdvancing in
                        guard isAdvancing, step == 1, let selected else { return }
                        withAnimation(reduceMotion ? nil : FluidOnboardingMotion.step) { reader.scrollTo(selected.id, anchor: .center) }
                    }
                }
            }
        }
    }

    /// The desktop welcome, scaled to the screen like the desktop window. On a narrow screen only
    /// the hero scales; the highlights keep their reading size beside or below it.
    @ViewBuilder private var welcome: some View {
        if isCompact {
            let isLandscape = verticalSizeClass == .compact
            let layout = isLandscape ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 12))
            GeometryReader { proxy in
                // Large text scrolls instead of pushing the highlights under the actions.
                ScrollView {
                    layout {
                        hero(width: Metrics.compactHero) { EmptyView() }
                            .frame(height: isLandscape ? proxy.size.height
                                : max(Metrics.minimumHero, proxy.size.height - highlightsHeight - 12))
                        welcomeHighlights
                            .frame(maxWidth: isLandscape ? Metrics.landscapeHighlights : Metrics.highlights)
                            // Clear of the fade behind the actions.
                            .padding(.horizontal, 20).padding(.bottom, 28)
                            .background { GeometryReader { Color.clear.preference(key: WelcomeHighlightsHeight.self, value: $0.size.height) } }
                    }
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
                .onPreferenceChange(WelcomeHighlightsHeight.self) { highlightsHeight = $0 }
            }
        } else {
            hero(width: theme.metrics.onboardingSurface.landing.contentWidth + 48) { welcomeHighlights }
        }
    }

    private func hero<Actions: View>(width: CGFloat, @ViewBuilder actions: @escaping () -> Actions) -> some View {
        OnboardingFittedContent(width: width) {
            FluidOnboardingLandingHero(
                eyebrow: AppBrand.appName,
                title: "Just speak.",
                accentTitle: "We'll handle the rest.",
                firstDetail: PichiLocalization.text("Record anything. Come back to every word."),
                secondDetail: "Speech is transcribed on this device.",
                actions: actions
            )
            .padding(24)
        }
    }

    private var welcomeHighlights: some View {
        VStack(spacing: 14) {
            Text(PichiLocalization.text("cloud.onboarding.localRecognition"))
                .font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 14) {
                highlight("Live transcripts", systemImage: "waveform")
                highlight("Automatic speaker labels", systemImage: "person.2")
                highlight("Optional local data cleanup", systemImage: "lock.shield")
            }
            .fluidOnboardingStepCard()
            Text(PichiLocalization.text("An internet connection is needed once to download your selected voice model and the resources for speaker labels."))
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: Metrics.highlights)
    }

    private func highlight(_ title: String, systemImage: String) -> some View {
        Label {
            Text(PichiLocalization.text(title)).font(.fluidSystem(size: highlightSize, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(theme.palette.accentText).frame(width: 24)
        }
    }

    private var subtitle: String? {
        switch step {
        case 1: "Choose a local speech model. You can change it later in Settings. Speed and memory use depend on your device."
        case 2: recordingPresentation.speakerLabelsDescription
        case 4: "Set up your voice so matching speech is labelled You in future recordings. The voice profile stays on this device."
        case 6: "Start a recording to see text and participant labels. Your choices for audio storage and data cleanup apply to new recordings."
        default: nil
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 1:
            ForEach(asr.availableMeetingModels, id: \.id) { model in
                let isSelected = selected == model
                VStack(alignment: .leading, spacing: 10) {
                    Button { selected = model } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(model.displayName).font(theme.typography.bodyStrong)
                                Spacer()
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? theme.palette.accentText : theme.palette.secondaryText)
                            }
                            Text(PichiLocalization.text(model.cardDescription)).font(theme.typography.bodySmall)
                            Text(PichiLocalization.text(model.languageSupport)).font(theme.typography.caption)
                                .foregroundStyle(theme.palette.secondaryText)
                            Text(model.downloadSize).font(theme.typography.caption).monospacedDigit()
                                .foregroundStyle(theme.palette.secondaryText)
                        }
                        .foregroundStyle(theme.palette.primaryText)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(advancing)
                        .accessibilityIdentifier("onboarding.model.\(model.id)")
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    MobileModelDetails(modelID: model.id)
                    if advancing && isSelected {
                        MobileASRPreparationStatus(asr: asr).padding(.top, 4)
                    }
                }
                .fluidOnboardingStepCard(isSelected: isSelected)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isSelected)
                .id(model.id)
            }
        case 2:
            VStack(alignment: .leading, spacing: 12) {
                MobileRequiredResourcesStatus(resources: required)
                Text(PichiLocalization.text(recordingPresentation.progressDescription))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                Text(PichiLocalization.text("Speech detection and speaker resources prepare automatically. This installs files without loading every speech model into memory."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
            .fluidOnboardingStepCard()
        case 3:
            MobileAudioPrivacyControls().fluidOnboardingStepCard()
            MobilePrivacyActivationControls(activation: privacy).fluidOnboardingStepCard()
        case 4:
            MeetingOwnerVoiceSettingsContent(model: voice, microphone: nil, layout: .setup).fluidOnboardingStepCard()
        case 5:
            MeetingLocationSettingsContent().fluidOnboardingStepCard()
        default:
            Label(PichiLocalization.text("Your setup is ready"), systemImage: "checkmark.circle.fill")
                .font(theme.typography.sectionTitle).foregroundStyle(theme.palette.success)
                .frame(maxWidth: .infinity)
            if accountSession.isConfigured {
                MobileAccountOnboarding(session: accountSession, continueAsGuest: next,
                    actionChanged: { accountActionIsActive = $0 }, cloudPublication: cloudPublication)
            }
            if advancing && asr.modelPreparationPhase == nil {
                ProgressView(PichiLocalization.text("Checking setup…")).frame(maxWidth: .infinity)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The model page shows its preparation in the chosen card.
            if advancing && step != 1 && asr.modelPreparationPhase != nil {
                MobileASRPreparationStatus(asr: asr)
            }
            HStack(spacing: isCompact ? 8 : 12) {
                if step == 4 { voiceActions } else { backAction; Spacer(minLength: 0); optionalActions; nextAction }
            }
        }
        .padding(.horizontal, isCompact ? 20 : FluidOnboardingLayout.footerHorizontalInset)
        .padding(.top, 16).padding(.bottom, isCompact ? 8 : 24)
        // Content scrolls beneath the actions and fades into the light instead of meeting a bar.
        .background {
            LinearGradient(stops: [.init(color: theme.palette.windowBackground.opacity(0), location: 0),
                                   .init(color: theme.palette.windowBackground, location: 0.3)],
                           startPoint: .top, endPoint: .bottom)
                .padding(.top, -28)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder private var backAction: some View {
        if step > 0 {
            pill("Back", prominent: false) {
                guard !isSettling else { return }
                error = nil; settings.mobileSetupStep -= 1
            }
            .disabled(advancing || accountSession.state == .signingIn || accountActionIsActive
                || !privateProfile.isPrivateDataVisible)
            .accessibilityIdentifier("onboarding.back")
        }
    }

    @ViewBuilder private var optionalActions: some View {
        if step == 4 || step == 5 {
            pill("Skip", prominent: false) {
                guard !isSettling else { return }
                // A replay keeps the location choice made before; a first setup declines the offer.
                if step == 5, !settings.isReplayingMobileSetup { AppServices.shared.meetingLocation.setEnabled(false) }
                settings.mobileSetupStep = step + 1
            }
            .disabled(advancing).accessibilityIdentifier("onboarding.skip")
        }
        if advancing {
            pill("Cancel", prominent: false) { operation?.cancel(); asr.cancelModelDownload() }
                .accessibilityIdentifier("onboarding.cancel")
        }
    }

    /// One place and at most three actions for the voice page: start or skip, then finish or cancel
    /// the recording, then record again or continue. Leaving is unavailable while the sample is taken.
    @ViewBuilder private var voiceActions: some View {
        switch voice.phase {
        case .recording:
            pill("Cancel", prominent: false) { voice.cancel() }.accessibilityIdentifier("ownerVoice.cancel")
            Spacer(minLength: 0)
            let longEnough = voice.seconds >= MeetingOwnerVoiceEnrollmentCapture.recommendedSeconds
            pill(longEnough ? "Done" : "Stop", prominent: longEnough) { voice.finishRecording() }
                .accessibilityIdentifier("ownerVoice.stop")
        case .preparing, .checking, .saving, .ready:
            pill("Cancel", prominent: false) { voice.cancel() }.accessibilityIdentifier("ownerVoice.cancel")
            Spacer(minLength: 0)
        case .idle:
            backAction
            Spacer(minLength: 0)
            if voice.hasProfile {
                pill("Record again", prominent: false) { voice.start(microphone: nil) }
                    .accessibilityIdentifier("ownerVoice.start")
                nextAction
            } else {
                optionalActions
                pill("Record", prominent: true) { voice.start(microphone: nil) }
                    .accessibilityIdentifier("ownerVoice.start")
            }
        }
    }

    private var nextAction: some View {
        // The welcome page keeps the desktop's wide first step.
        pill(step == 6 ? "Get started" : error == nil ? "Next" : "Try again", prominent: true,
             minWidth: step == 0 ? Metrics.welcomeAction : nil) { next() }
            .disabled(advancing || (step == 3 && privacy.isPreparing)
                || accountSession.state == .signingIn || accountActionIsActive
                || !privateProfile.isPrivateDataVisible)
            .accessibilityIdentifier("onboarding.next")
    }

    /// The desktop footer actions: capsules of one size, with the accent only on the way forward.
    @ViewBuilder private func pill(_ title: String, prominent: Bool, minWidth: CGFloat? = nil,
                                   action: @escaping () -> Void) -> some View {
        let label = Text(PichiLocalization.text(title))
            .font(.fluidSystem(size: min(actionSize, Metrics.maximumActionFontSize), weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(minWidth: isCompact ? nil : (minWidth ?? FluidOnboardingLayout.footerButtonWidth) - Metrics.actionInsets)
        if prominent {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .foregroundStyle(theme.palette.accentForeground)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                .tint(theme.palette.primaryText)
        }
    }

    /// The work behind Next on pages that prepare resources. Other pages advance at once,
    /// so no Cancel action flashes into the footer during the page transition.
    private func preparation(for page: Int) -> (@MainActor () async throws -> Void)? {
        switch page {
        case 1:
            return {
                guard let selected else { throw MeetingProcessingError.modelUnavailable }
                // Provider preparation validates an existing export and skips its download.
                // The existing service releases the prepared engine before this returns.
                try await asr.downloadModel(selected)
                try Task.checkCancellation()
                try await asr.activateModel(selected)
            }
        case 2: return { try await required.prepare(modelID: settings.selectedSpeechModel.rawValue) }
        case 3: return { try await privacy.waitUntilReadyIfRequested() }
        case 6:
            return {
                // A restored final page cannot assume cache files survived an interruption.
                let model = settings.selectedSpeechModel
                if !(try await asr.modelIsInstalled(model)) { try await asr.downloadModel(model) }
                try await required.prepare(modelID: model.rawValue)
                try await privacy.waitUntilReadyIfRequested()
            }
        default: return nil
        }
    }

    private func next() {
        guard !advancing, !isSettling, privateProfile.isPrivateDataVisible,
              !privateProfile.isTransitioning else { return }
        let profile = PrivateProfileStorage.current
        let projectionRevision = privateProfile.projectionRevision
        let current = step
        error = nil
        guard let preparation = preparation(for: current) else { settings.mobileSetupStep = current + 1; return }
        advancing = true
        operation = Task { @MainActor in
            defer { advancing = false; operation = nil }
            do {
                try await preparation()
                try Task.checkCancellation()
                guard settings.mobileSetupStep == current,
                      privateProfile.isPrivateDataVisible, !privateProfile.isTransitioning,
                      privateProfile.projectionRevision == projectionRevision,
                      PrivateProfileStorage.current == profile else { return }
                if current == 6 { settings.mobileSetupCompleted = true }
                else { settings.mobileSetupStep = current + 1 }
            } catch is CancellationError { }
            catch {
                guard privateProfile.isPrivateDataVisible,
                      privateProfile.projectionRevision == projectionRevision,
                      PrivateProfileStorage.current == profile else { return }
                self.error = error.localizedDescription
            }
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
                Text(PichiLocalization.text(message))
                Button(PichiLocalization.text("Try again")) {
                    guard let modelID = resources.modelID else { return }
                    Task { try? await resources.prepare(modelID: modelID) }
                }
            default:
                Text(PichiLocalization.text((resources.phase == .speakers || resources.phase == .speakerVoice) ? "Preparing speaker resources…" : "Preparing speech detection…"))
                if let progress = resources.progress { ProgressView(value: progress) }
                else { ProgressView() }
            }
        }.accessibilityIdentifier("recording.requiredResources")
    }
}

/// An onboarding card shows the explanation beside the toggle. As form rows, Settings shows the
/// toggle alone and the same paragraphs in its section footer.
struct MobileAudioPrivacyControls: View {
    var asFormRows = false
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    static var memoryOnlyExplanation: String {
        PichiLocalization.text("When disabled, audio is never written to files, including temporary files. Only the transcript is saved.")
    }
    static var retainedAudioExplanation: String {
        PichiLocalization.text("Audio recordings retain the original voices and sensitive information. Text redaction does not change audio.")
    }

    var body: some View {
        if asFormRows { toggle }
        else {
            VStack(alignment: .leading, spacing: 12) {
                toggle
                Text(Self.memoryOnlyExplanation)
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if settings.meetingSaveAudio {
                    Text(Self.retainedAudioExplanation)
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var toggle: some View {
        Toggle(PichiLocalization.text("Save audio recordings"), isOn: $settings.meetingSaveAudio)
            .accessibilityIdentifier("privacy.saveAudio")
    }
}

/// As form rows, every status and action is its own native row, and `explanation` is the footer.
struct MobilePrivacyActivationControls: View {
    @ObservedObject var activation: MobilePrivacyActivation
    var asFormRows = false
    @Environment(\.theme) private var theme

    static var explanation: String {
        PichiLocalization.text("Locally cleans Russian names, phone numbers, email, card and account numbers, passport details, SNILS, INN, dates of birth, addresses, logins and secrets from text. Detection can miss data. Review before sharing.")
    }

    var body: some View {
        if asFormRows { controls }
        else {
            VStack(alignment: .leading, spacing: 10) {
                controls
                Text(Self.explanation).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
        }
    }

    @ViewBuilder private var controls: some View {
        Toggle(PichiLocalization.text("Redact sensitive data"), isOn: Binding(
            get: { activation.isRequested }, set: { activation.setEnabled($0) }))
            .accessibilityIdentifier("privacy.pii")
        switch activation.state {
        case .enabling:
            VStack(alignment: .leading, spacing: asFormRows ? 8 : 10) {
                Text(PichiLocalization.text(activation.downloadProgress == 1
                    ? "Loading data cleanup model…" : "Enabling data cleanup…"))
                    .font(theme.typography.caption)
                Group {
                    if let progress = activation.downloadProgress, progress < 1 { ProgressView(value: progress) }
                    else { ProgressView() }
                }.accessibilityIdentifier("privacy.pii.progress")
            }
            Button(PichiLocalization.text("Cancel")) { activation.setEnabled(false) }
                .accessibilityIdentifier("privacy.pii.cancel")
        case .active:
            Label(PichiLocalization.text("Data cleanup is active"), systemImage: "checkmark.shield")
                .font(theme.typography.caption).accessibilityIdentifier("privacy.pii.active")
        case .failed(let message):
            VStack(alignment: .leading, spacing: asFormRows ? 4 : 10) {
                Text(PichiLocalization.text("Data cleanup is not active")).font(theme.typography.bodyStrong)
                Text(PichiLocalization.text(message)).font(theme.typography.caption).foregroundStyle(theme.palette.warning)
            }
            Button(PichiLocalization.text("Try again")) { activation.setEnabled(true) }
                .accessibilityIdentifier("privacy.pii.retry")
        case .off: EmptyView()
        }
    }
}

/// The same registered limitations are available at selection time and in model settings.
struct MobileModelDetails: View {
    let modelID: String
    @Environment(\.theme) private var theme
    var body: some View {
        if let descriptor = PichiMeetingProviderFactory.registeredBackendDescriptor(for: modelID) {
            DisclosureGroup(PichiLocalization.text("About the model")) {
                ForEach(descriptor.knownLimits, id: \.self) { limitation in
                    Text(PichiLocalization.text(limitation)).font(theme.typography.caption)
                        .foregroundStyle(theme.palette.secondaryText)
                }
            }.font(theme.typography.captionStrong)
                .accessibilityIdentifier("model.details.\(modelID)")
        }
    }
}

private struct WelcomeHighlightsHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
