import Foundation
import SwiftUI

struct OnboardingAIEnhancementStepView: View {
    @ObservedObject var setup: OnboardingAISetupController
    @Binding var finalText: String
    let shortcutDisplay: String
    let isRunning: Bool
    let isListening: Bool
    let isRecordingShortcut: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onFinishSetup: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ObservedObject private var settings = SettingsStore.shared
    @StateObject private var carouselAutoplay = OnboardingCarouselAutoplay()
    @State private var hoveredButtonID: String?
    @State private var showPractice = false
    @State private var introductionPlaybackID = UUID()
    @State private var practice = OnboardingPolishPractice()
    @ObservedObject private var contentState = NotchContentState.shared

    private static let overlaySceneOffset: CGFloat = 24

    private static let selectedOverlayImage: NSImage = {
        guard let url = Bundle.main.url(forResource: "OnboardingSmartModeSelected", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return NSImage() }
        return image
    }()

    // Hide only the old title area; the menu begins below 36% of the frame.
    private static let heldFrameMask: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .clear, location: 0.27),
        .init(color: .white, location: 0.35),
        .init(color: .white, location: 0.88),
        .init(color: .clear, location: 1),
    ]
    private static let horizontalFrameMask: [Gradient.Stop] = [
        .init(color: .clear, location: 0),
        .init(color: .white, location: 0.12),
        .init(color: .white, location: 0.88),
        .init(color: .clear, location: 1),
    ]

    private enum ButtonTone { case primary, secondary, destructive }
    private struct PillButtonConfiguration {
        let id: String
        let title: String
        let systemImage: String?
        let tone: ButtonTone
        let width: CGFloat
        let height: CGFloat
        let fontSize: CGFloat
        let isEnabled: Bool
    }

    private var canNavigate: Bool { !self.isRunning && !self.isRecordingShortcut && !self.contentState.isProcessing && !self.isShowingIntroduction }
    private var isShowingIntroduction: Bool { PrivateAIProviderFeature.shared.isAvailable && self.isReady && !self.setup.introductionFinished && !self.reduceMotion }
    private var isReady: Bool { self.setup.phase == .ready }
    var body: some View {
        Group {
            if PrivateAIProviderFeature.shared.isAvailable {
                self.privateContent
            } else {
                self.publicContent
            }
        }
    }

    /// The public downstream does not include upstream's private Fluid-1 runtime.
    /// Offer an optional, truthful setup path without starting an unusable download.
    private var publicContent: some View {
        let canFinish = !self.isRunning && !self.isRecordingShortcut && !self.contentState.isProcessing
        let hasConfiguredCleanup = DictationAIPostProcessingGate.isOnboardingChoiceConfigured()
        return VStack(spacing: 24) {
            Color.clear.frame(height: FluidOnboardingCompactProgress.height + 28)
            Spacer()
            FluidOnboardingCompactAppIconMark()
            Text(AppBrand.text("AI text cleanup with Fluid Intelligence"))
                .font(.fluidSystem(size: 30, weight: .semibold, role: .title))
                .foregroundStyle(self.theme.palette.primaryText)
                .multilineTextAlignment(.center)
            Text("AI cleanup is optional. Dictation already works with your selected speech model.")
                .font(.fluidSystem(size: 17, weight: .medium))
                .foregroundStyle(self.theme.palette.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 660)
            Text("Connect Ollama or LM Studio in AI Providers to process text locally. Meeting summaries have their own local AI settings.")
                .font(.fluidSystem(size: 15))
                .foregroundStyle(self.theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 660)
            if hasConfiguredCleanup {
                Text("A text provider is already configured. This step keeps your settings and does not contact another service.")
                    .font(.fluidSystem(size: 14))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 660)
            }
            Spacer()
            HStack(spacing: 16) {
                self.action(id: "public-back", title: "Back", tone: .secondary, width: 132, action: self.onBack)
                Spacer()
                if hasConfiguredCleanup {
                    self.action(id: "public-use-provider", title: "Use configured provider", tone: .primary, width: 238, action: self.onFinishSetup)
                } else {
                    self.action(id: "public-skip", title: "Set up later", tone: .primary, width: 210, action: self.onSkip)
                }
            }
            .disabled(!canFinish)
            .padding(.horizontal, FluidOnboardingLayout.footerHorizontalInset)
            .padding(.bottom, FluidOnboardingLayout.footerBottomInset)
        }
        .padding(.horizontal, 32)
    }

    private var privateContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: FluidOnboardingCompactProgress.height + 28)
            self.mainContent
            if !self.isReady {
                self.offerStatus
                    .padding(.horizontal, 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 20) {
                self.action(id: "back", title: "Back", tone: .secondary, width: 132) {
                    if self.isReady && self.showPractice {
                        self.showPractice = false
                    } else {
                        self.setup.leavePage()
                        self.onBack()
                    }
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                if self.isReady && self.showPractice {
                    Button("Skip practice", action: self.onFinishSetup)
                        .buttonStyle(.plain)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .disabled(!self.canNavigate)
                    self.action(id: "practice-next", title: self.practice.isLast ? "Continue" : "Next example", tone: .primary, width: 180, isEnabled: self.practice.result != nil) {
                        guard self.canNavigate, self.practice.result != nil else { return }
                        if self.practice.isLast {
                            self.onFinishSetup()
                        } else {
                            self.practice.advance(isBusy: !self.canNavigate)
                        }
                    }
                } else if self.isReady && !self.isShowingIntroduction {
                    if !self.reduceMotion {
                        self.action(id: "intro-replay", title: "Replay", tone: .secondary, width: 132) {
                            self.setup.introductionFinished = false
                            self.introductionPlaybackID = UUID()
                        }
                    }
                    self.action(id: "intro-continue", title: "Continue", tone: .primary, width: 160) {
                        self.setup.introductionFinished = true
                        self.showPractice = true
                    }
                } else if !self.isReady {
                    self.offerNavigation
                }
            }
            .padding(.horizontal, FluidOnboardingLayout.footerHorizontalInset)
            .padding(.bottom, FluidOnboardingLayout.footerBottomInset)
            .padding(.top, 12)
            .fixedSize(horizontal: false, vertical: true)
        }
        .overlay {
            if !self.isReady {
                OnboardingCarouselInteractionTracker(autoplay: self.carouselAutoplay)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .task { self.setup.refresh() }
        .onDisappear {
            self.setup.leavePage()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        if self.isReady {
            OnboardingFittedContent(width: 844, heightAnimation: self.reduceMotion ? nil : .easeInOut(duration: 0.32)) {
                self.introductionScene
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 32)
                    .padding(.top, 36)
                    .padding(.bottom, 24)
            }
        } else {
            // Fit the showcase into the space left above the fixed status and footer.
            OnboardingFittedContent(width: 880) {
                VStack(spacing: 0) {
                    self.hero.padding(.bottom, 16)
                    OnboardingCleanupExampleCarousel(autoplay: self.carouselAutoplay)
                    Text(AppBrand.text("You can choose a different model or turn off Fluid Intelligence anytime in Settings."))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }
                .frame(maxWidth: 880)
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
            FluidOnboardingCompactAppIconMark(size: 56)
                .padding(.bottom, 4)
            Text(AppBrand.text("Meet Fluid Intelligence"))
                .font(.fluidSystem(size: 28, weight: .semibold, role: .title))
                .foregroundStyle(self.theme.palette.primaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("Choose a local AI model to turn spoken words into clear, formatted text on your Mac.")
                .font(.fluidSystem(size: 15, weight: .medium))
                .foregroundStyle(self.theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 540)
            if !self.isReady {
                Text(AppBrand.text("Fluid Intelligence can…"))
                    .font(.fluidSystem(size: 20, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                    .padding(.top, 4)
            }
        }
    }

    private var offerStatus: some View {
        VStack(spacing: 8) {
            if self.setup.phase == .checking, !self.setup.canEnable {
                ProgressView("Finding the right model for your Mac…")
                    .controlSize(.small)
            } else if self.setup.showsPreparationProgress || self.setup.phase == .cancelling {
                self.preparationProgress
                    .transition(.opacity)
            }
            if let error = self.setup.errorMessage {
                Text(error)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.setup.phase == .unavailable {
                Text(AppBrand.text("Fluid Intelligence isn't available right now. You can finish setup and try again later."))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
                Button("Try again") { self.setup.refresh() }
                    .buttonStyle(.plain)
                    .foregroundStyle(self.theme.palette.primaryText)
            }
        }
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.32), value: self.setup.isBusy)
    }

    private var offerNavigation: some View {
        HStack(spacing: 20) {
            if !self.setup.showsPreparationProgress {
                Button("I’ll set it up later") {
                    self.setup.setUpLater()
                    self.onSkip()
                }
                .buttonStyle(.plain)
                .font(.fluidSystem(size: 15, weight: .medium))
                .foregroundStyle(self.canNavigate ? self.theme.palette.primaryText : self.theme.palette.secondaryText)
                .disabled(!self.canNavigate)
            }

            if self.setup.canEnable {
                self.action(id: "enable", title: "Enable", tone: .primary, width: 210) {
                    self.setup.enable { model in
                        guard self.canNavigate else {
                            throw SetupError(message: "Stop dictation, then enable Smart mode again.")
                        }
                        guard let registered = PrivateAIModelRegistry.model(id: model.id) else {
                            throw PrivateAIUnavailableError()
                        }
                        self.persistPrivateAIVerification(registered)
                        self.finalText = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .transition(.opacity)
            } else {
                Color.clear.frame(width: 210, height: 48)
                    .accessibilityHidden(true)
            }
        }
        .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.2), value: self.setup.phase == .offered)
    }

    private var preparationProgress: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                if self.setup.phase == .downloading {
                    HStack(spacing: 12) {
                        if let fraction = self.setup.progress?.fraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        if let bytes = self.setup.progress?.bytes {
                            Text(bytes.replacingOccurrences(of: " downloaded", with: " ready").replacingOccurrences(of: " download", with: ""))
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .monospacedDigit()
                                .fixedSize()
                        }
                    }
                    Text(PichiLocalization.text(self.downloadProgressTitle))
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .monospacedDigit()
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(PichiLocalization.text(self.preparationStatus))
                            .font(self.theme.typography.captionStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if self.setup.phase != .cancelling {
                Button { self.setup.cancel() } label: {
                    Label("Cancel", systemImage: "xmark")
                        .font(self.theme.typography.bodySmallStrong)
                        .frame(minWidth: 80, minHeight: 32)
                }
                .buttonStyle(.plain)
                .foregroundStyle(self.theme.palette.primaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red.opacity(0.18), lineWidth: 1))
            }
        }
        .tint(self.theme.palette.accent)
        .frame(height: 44)
        .padding(16)
        .background(self.theme.palette.primaryText.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(self.theme.palette.cardBorder, lineWidth: 1))
        .frame(maxWidth: 600)
    }

    private var downloadProgressTitle: String {
        guard let fraction = self.setup.progress?.fraction, fraction.isFinite else { return "Preparing…" }
        let percent = min(max(fraction, 0), 1).formatted(.percent.precision(.fractionLength(0)))
        return PichiLocalization.format("Preparing %@", percent)
    }

    private var preparationStatus: String {
        switch self.setup.phase {
        case .loading: "Preparing the model for your Mac. This can take a little while."
        case .cancelling: "Cancelling setup… You can go back or set this up later."
        default: AppBrand.text("Preparing Fluid Intelligence…")
        }
    }

    private var introductionScene: some View {
        ZStack(alignment: .top) {
            if self.reduceMotion || self.setup.introductionFinished {
                Color.clear.aspectRatio(1560.0 / 1096.0, contentMode: .fit)
            } else {
                OnboardingOverlayIntroductionView { self.setup.introductionFinished = true }
                    .id(self.introductionPlaybackID)
                    .offset(y: Self.overlaySceneOffset)
                    .allowsHitTesting(false)
            }
            if !self.isShowingIntroduction && !self.showPractice {
                // The still is a 1560 × 1096 video frame. Use exactly the player's
                // aspect-fit canvas and shared offset; never crop or independently size it.
                Image(nsImage: Self.selectedOverlayImage)
                    .resizable()
                    .aspectRatio(1560.0 / 1096.0, contentMode: .fit)
                    .mask {
                        LinearGradient(stops: Self.heldFrameMask, startPoint: .top, endPoint: .bottom)
                            .mask {
                                LinearGradient(stops: Self.horizontalFrameMask, startPoint: .leading, endPoint: .trailing)
                            }
                    }
                    .offset(y: Self.overlaySceneOffset)
                    .accessibilityLabel("The same tilted overlay frame from the video, with Smart selected.")
            }
            Group {
                if self.showPractice {
                    self.tryout
                } else if !self.isShowingIntroduction {
                    self.introductionSummary
                }
            }
            .frame(maxWidth: self.showPractice ? 680 : 600)
            .padding(.top, 28)
        }
        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.45), value: self.setup.introductionFinished)
    }

    private var introductionSummary: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Change modes with one click")
                .font(.fluidSystem(size: 28, weight: .regular, design: .serif))
                .foregroundStyle(self.theme.palette.primaryText)
            HStack(alignment: .top, spacing: 24) {
                self.modeSummary(
                    name: "Basic",
                    subtitle: AppBrand.text("Without Fluid Intelligence"),
                    detail: "Keeps your words as spoken, including mistakes.",
                    smart: false
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                self.modeSummary(
                    name: SettingsStore.DictationModeLabels.smart,
                    subtitle: AppBrand.text("With Fluid Intelligence"),
                    detail: "Removes rambling, fixes mistakes, and formats your text.",
                    smart: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(28)
    }

    private func modeSummary(name: String, subtitle: String, detail: String, smart: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label(PichiLocalization.text(name), systemImage: smart ? "sparkles" : "bolt.fill")
                    .font(.fluidSystem(size: 18, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(PichiLocalization.text(subtitle))
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Text(PichiLocalization.text(detail))
                .font(.fluidSystem(size: 15))
                .foregroundStyle(self.theme.palette.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var tryout: some View {
        OnboardingPolishPracticeView(
            finalText: self.$finalText,
            practice: self.practice,
            isRunning: self.isListening,
            isProcessing: self.contentState.isProcessing,
            isActive: !self.isShowingIntroduction,
            shortcutDisplay: self.shortcutDisplay
        )
        .onChange(of: self.isRunning) { _, running in
            if running { self.practice.beginAttempt() }
        }
        .onChange(of: self.finalText) { _, text in
            self.practice.receive(text)
        }
    }

    @ViewBuilder
    private func action(id: String, title: String, tone: ButtonTone, width: CGFloat, isEnabled: Bool = true, action: @escaping () -> Void) -> some View {
        let actionEnabled = isEnabled && self.canNavigate
        if #available(macOS 26, *), !self.reduceTransparency {
            Button(action: action) {
                Text(PichiLocalization.text(title))
                    .font(.fluidSystem(size: 16, weight: .semibold))
                    .foregroundStyle(actionEnabled && tone == .primary ? self.theme.palette.accentForeground : self.theme.palette.primaryText)
                    .frame(width: width - 32, height: 40)
            }
            .fluidGlassAction(prominent: actionEnabled && tone == .primary)
            .font(.fluidSystem(size: 17, weight: .semibold))
            .tint(actionEnabled && tone == .primary ? self.theme.palette.accent : nil)
            .disabled(!actionEnabled)
        } else {
            self.pillButton(PillButtonConfiguration(
                id: id,
                title: title,
                systemImage: nil,
                tone: tone,
                width: width,
                height: 48,
                fontSize: 16,
                isEnabled: actionEnabled
            ), action: action)
        }
    }

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { self.message }
    }

    private func pillButton(
        _ configuration: PillButtonConfiguration,
        action: @escaping () -> Void
    ) -> some View {
        let isDisabled = !configuration.isEnabled
        let isHovered = self.hoveredButtonID == configuration.id && !isDisabled
        let shape = Capsule()
        let accentColor = configuration.tone == .destructive ? Color.red : self.theme.palette.accent
        let isPrimary = configuration.tone == .primary
        let isDestructive = configuration.tone == .destructive
        let fillColor: Color = {
            guard !isDisabled else { return self.theme.palette.primaryText.opacity(0.045) }
            if isPrimary {
                return accentColor
            }
            if isDestructive {
                return Color.red.opacity(isHovered ? 0.24 : 0.16)
            }
            return self.theme.palette.primaryText.opacity(isHovered ? 0.11 : 0.07)
        }()
        let borderColor: Color = {
            guard !isDisabled else { return self.theme.palette.cardBorder }
            if isPrimary {
                return Color.white.opacity(isHovered ? 0.30 : 0)
            }
            if isDestructive {
                return Color.red.opacity(isHovered ? 0.48 : 0.24)
            }
            return isHovered ? accentColor.opacity(0.30) : self.theme.palette.cardBorder
        }()
        let foregroundColor = !isDisabled && isPrimary ? self.theme.palette.accentForeground : self.theme.palette.primaryText
        let shadowOpacity = isDisabled ? 0 : (isPrimary ? (isHovered ? 0.56 : 0.26) : (isHovered ? 0.12 : 0))

        return Button(action: action) {
            HStack(spacing: configuration.systemImage == nil ? 0 : 8) {
                if let systemImage = configuration.systemImage {
                    Image(systemName: systemImage)
                        .font(.fluidSystem(size: 12, weight: .bold))
                }

                Text(PichiLocalization.text(configuration.title))
                    .font(.fluidSystem(size: configuration.fontSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(foregroundColor)
            .frame(width: configuration.width, height: configuration.height)
            .background(
                shape
                    .fill(fillColor)
                    .overlay(shape.fill(Color.white.opacity(isPrimary && isHovered ? 0.10 : 0)))
                    .overlay(shape.stroke(borderColor, lineWidth: isHovered ? 1.2 : 1))
                    .overlay(
                        shape
                            .stroke(accentColor.opacity(isHovered ? 0.50 : 0), lineWidth: isHovered ? 1.4 : 1)
                            .padding(-2)
                    )
                    .shadow(color: accentColor.opacity(shadowOpacity), radius: isHovered ? 16 : 9, x: 0, y: isHovered ? 6 : 3)
            )
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .contentShape(shape)
        .disabled(isDisabled)
        .onHover { isHovered in
            self.setHoveredButton(isHovered && !isDisabled ? configuration.id : nil)
        }
    }

    private func setHoveredButton(_ buttonID: String?) {
        guard self.hoveredButtonID != buttonID else { return }
        if self.reduceMotion {
            self.hoveredButtonID = buttonID
        } else {
            withAnimation(.easeOut(duration: 0.14)) {
                self.hoveredButtonID = buttonID
            }
        }
    }

    private func persistPrivateAIVerification(_ model: PrivateAIRegisteredModel) {
        let providerID = PrivateAIProviderFeature.shared.providerID
        let providerKey = DictationAIPostProcessingGate.providerKey(for: providerID)
        let modelIDs = PrivateAIModelRegistry.modelIDs()

        var availableModelsByProvider = self.settings.availableModelsByProvider
        availableModelsByProvider[providerKey] = modelIDs
        self.settings.availableModelsByProvider = availableModelsByProvider

        var selectedModelByProvider = self.settings.selectedModelByProvider
        selectedModelByProvider[providerKey] = model.id
        self.settings.selectedModelByProvider = selectedModelByProvider

        var fingerprints = self.settings.verifiedProviderFingerprints
        let fingerprint = PrivateAIProviderFeature.verificationFingerprint(for: model.id)
        fingerprints[providerKey] = fingerprint
        self.settings.verifiedProviderFingerprints = fingerprints
        self.settings.verifiedPrivateAIModelFingerprints[model.id] = fingerprint

        // Smart dictation selects FI independently of the global Edit/Command provider.
        self.settings.setDictationPromptSelection(.privateAI)
        self.settings.onboardingAISkipped = false
        UserDefaults.standard.set(model.id, forKey: PrivateAIIntegrationService.selectedModelDefaultsKey)
    }
}
