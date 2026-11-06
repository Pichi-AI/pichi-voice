import AppKit
import Combine
import QuartzCore
import SwiftUI

/// SwiftUI observes the collection while each row retains its existing session.
@MainActor
private final class DictionaryCorrectionOverlayState: ObservableObject {
    @Published var sessions: [AutomaticDictionaryTrainingSession] = []
    @Published var progressGeneration: UInt64 = 0
    @Published var maximumListHeight: CGFloat = 420
}

@MainActor
final class DictionaryCorrectionOverlayController {
    static let shared = DictionaryCorrectionOverlayController()
    private static let displayDuration: Duration = .seconds(10)
    private let now: () -> ContinuousClock.Instant
    private let audioLearning: DictionaryAudioLearningService?
    private let state = DictionaryCorrectionOverlayState()
    private var deadline: ContinuousClock.Instant?
    private var panel: NSPanel?
    private var hostingView: NSHostingView<PichiLocalizedContent<DictionaryCorrectionOverlayRoot>>?
    private var profileCancellable: AnyCancellable?
    private var languageCancellable: AnyCancellable?
    private var rowCancellables: [UUID: AnyCancellable] = [:]
    private var outcomes: [UUID: (AutomaticDictionarySuggestionOutcome) -> Void] = [:]
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    #if DEBUG
    var presentedCandidateIDs: [UUID] { self.state.sessions.map(\.candidate.id) }
    var presentedSessions: [AutomaticDictionaryTrainingSession] { self.state.sessions }
    var presentedCandidateID: UUID? { self.state.sessions.first?.candidate.id }
    var displayDeadline: ContinuousClock.Instant? { self.deadline }
    var progressGeneration: UInt64 { self.state.progressGeneration }
    var onPresentation: ((AutomaticDictionaryTrainingSession) -> Void)?
    var onDismissal: (() -> Void)?
    #endif

    init(now: @escaping () -> ContinuousClock.Instant = { .now }, audioLearning: DictionaryAudioLearningService? = nil) {
        self.now = now
        self.audioLearning = audioLearning
        self.profileCancellable = NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.concealPrivatePresentation() }
            }
    }

    /// The admitted private recorder stays owned by PrivateProfileService's stop
    /// handler. Concealment immediately releases every visible private projection.
    func concealPrivatePresentation() {
        self.generation &+= 1
        self.dismissTask?.cancel(); self.dismissTask = nil; self.deadline = nil
        for session in self.state.sessions {
            session.onInteraction = nil; session.onSuccess = nil; session.onOpenDictionary = nil
            session.concealSavedCorrection()
        }
        self.state.sessions = []
        self.outcomes.removeAll(); self.rowCancellables.removeAll()
        self.languageCancellable?.cancel(); self.languageCancellable = nil
        self.panel?.orderOut(nil); self.panel?.contentView = nil
        self.hostingView = nil; self.panel = nil
    }

    var isPresented: Bool { self.panel?.isVisible == true }

    func transientOverlayLayoutDidChange() {
        guard self.isPresented else { return }
        self.resizeAndPositionPanel(animated: true)
    }

    func hideSuggestion() {
        let ids = self.state.sessions.filter { !$0.isSavedCorrection }.map(\.candidate.id)
        for id in ids { self.remove(id: id) }
    }

    func showSavedCorrection(_ receipt: DictionaryAudioLearningService.SavedCorrection) {
        guard receipt.isCurrent, SettingsStore.shared.customDictionaryEntries.contains(receipt.entry),
              !self.state.sessions.contains(where: { $0.savedCorrection?.id == receipt.id }) else { return }
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: receipt.heardText, correctedText: receipt.correctedText)
        self.append(AutomaticDictionaryTrainingSession(candidate: candidate, asr: AppServices.shared.asr,
            audioLearning: self.audioLearning, savedCorrection: receipt),
            outcome: { _ in })
    }

    func withdrawSavedCorrection(_ id: UUID) {
        guard let session = self.state.sessions.first(where: { $0.savedCorrection?.id == id }) else { return }
        self.remove(id: session.candidate.id)
    }

    func withdrawSuggestion(_ id: UUID) {
        guard self.state.sessions.contains(where: {
            $0.candidate.id == id && !$0.isSavedCorrection && $0.screen != .training && $0.capturePhase == .idle
        }) else { return }
        self.remove(id: id)
    }

    func show(candidate: AutomaticDictionaryCorrectionCandidate,
              onOutcome: @escaping (AutomaticDictionarySuggestionOutcome) -> Void) {
        guard PrivateProfileStorage.isReadable(PrivateProfileStorage.current), PrivateProfileStorage.acceptsNewWork else { return }
        let retained = self.state.sessions.reduce(0) { total, session in
            total + (session.candidate.audioEvidence.map(DictionaryAudioLearningService.retainedBytes) ?? 0)
        }
        var bounded = candidate
        if let audio = bounded.audioEvidence,
           DictionaryAudioLearningService.retainedBytes(audio) > 128 * 1024 * 1024 - retained {
            bounded.audioEvidence = nil
        }
        let next = AutomaticDictionaryTrainingSession(candidate: bounded, asr: AppServices.shared.asr, audioLearning: self.audioLearning)
        if let origin = candidate.observationID,
           let index = self.state.sessions.firstIndex(where: {
               !$0.isSavedCorrection && $0.screen != .training && $0.capturePhase == .idle && $0.candidate.observationID == origin
           }) {
            let previous = self.state.sessions[index]
            self.release(previous)
            self.configure(next, outcome: onOutcome)
            self.state.sessions[index] = next
            self.didAdd(next)
        } else {
            self.append(next, outcome: onOutcome)
        }
    }

    private func append(_ session: AutomaticDictionaryTrainingSession,
                        outcome: @escaping (AutomaticDictionarySuggestionOutcome) -> Void) {
        guard self.state.sessions.count < 32 else { return }
        self.configure(session, outcome: outcome)
        self.state.sessions.append(session)
        self.didAdd(session)
    }

    private func configure(_ session: AutomaticDictionaryTrainingSession,
                           outcome: @escaping (AutomaticDictionarySuggestionOutcome) -> Void) {
        let id = session.candidate.id
        self.outcomes[id] = outcome
        // Opening a row or undoing it never resets the shared countdown.
        session.onInteraction = { }
        session.onSuccess = { [weak self] in
            self?.outcomes.removeValue(forKey: id)?(.accepted)
            self?.rowDidChange()
        }
        session.onOpenDictionary = { [weak self] in self?.remove(id: id) }
        self.rowCancellables[id] = session.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.rowDidChange() }
        }
    }

    private func didAdd(_ session: AutomaticDictionaryTrainingSession) {
        self.generation &+= 1
        self.deadline = self.now().advanced(by: Self.displayDuration)
        self.state.progressGeneration &+= 1
        self.dismissTask?.cancel()
        let admittedGeneration = self.generation
        self.dismissTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: Self.displayDuration) } catch { return }
            guard let self, self.generation == admittedGeneration else { return }
            self.expireIfDue()
        }
        self.presentGroup()
        #if DEBUG
        self.onPresentation?(session)
        #endif
    }

    /// The timer defers closing an active Undo/training operation or its error.
    /// Its next state publication rechecks the same deadline without restarting it.
    func expireIfDue() {
        guard let deadline, self.now() >= deadline,
              !self.state.sessions.contains(where: {
                  $0.isUndoingSavedCorrection || $0.capturePhase != .idle || $0.screen == .training || $0.hasError
              }) else { return }
        for id in Array(self.outcomes.keys) { self.outcomes.removeValue(forKey: id)?(.timedOut) }
        self.hide()
    }

    private func rowDidChange() {
        self.state.objectWillChange.send()
        self.expireIfDue()
        self.resizeAndPositionPanel(animated: true)
    }

    func dismiss(id: UUID) {
        guard let session = self.state.sessions.first(where: { $0.candidate.id == id }), !session.isUndoingSavedCorrection else { return }
        self.outcomes.removeValue(forKey: id)?(.dismissed)
        self.remove(id: id)
    }

    func dismiss() {
        guard !self.state.sessions.contains(where: \.isUndoingSavedCorrection) else { return }
        for id in Array(self.outcomes.keys) { self.outcomes.removeValue(forKey: id)?(.dismissed) }
        self.hide()
    }

    private func remove(id: UUID) {
        guard let session = self.state.sessions.first(where: { $0.candidate.id == id }) else { return }
        self.release(session)
        self.state.sessions.removeAll { $0.candidate.id == id }
        if self.state.sessions.isEmpty { self.hide() }
        else { self.resizeAndPositionPanel(animated: true) }
    }

    private func release(_ session: AutomaticDictionaryTrainingSession) {
        let id = session.candidate.id
        self.outcomes.removeValue(forKey: id)
        self.rowCancellables.removeValue(forKey: id)?.cancel()
        session.onInteraction = nil; session.onSuccess = nil; session.onOpenDictionary = nil
        session.cancel()
    }

    func hide() {
        self.generation &+= 1
        self.dismissTask?.cancel(); self.dismissTask = nil; self.deadline = nil
        for session in self.state.sessions { self.release(session) }
        self.state.sessions = []
        self.panel?.orderOut(nil)
        self.panel?.contentView = nil
        self.hostingView = nil; self.panel = nil
        self.languageCancellable?.cancel(); self.languageCancellable = nil
        #if DEBUG
        self.onDismissal?()
        #endif
    }

    private func presentGroup() {
        if let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main {
            self.state.maximumListHeight = min(420, max(80, screen.visibleFrame.height - 100))
        }
        let profile = PrivateProfileStorage.current
        let view = DictionaryCorrectionOverlayGroupView(state: self.state,
            onDismissAll: { [weak self] in self?.dismiss() },
            onDismissRow: { [weak self] in self?.dismiss(id: $0) },
            onIgnore: { [weak self] id in self?.outcomes.removeValue(forKey: id)?(.ignored); self?.remove(id: id) },
            onFrequencyChange: { frequency in
                guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { return }
                SettingsStore.shared.automaticDictionarySuggestionFrequency = frequency
            },
            onDisableSuggestions: { [weak self] in
                guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { return }
                SettingsStore.shared.automaticDictionaryLearningEnabled = false; self?.hideSuggestion()
            },
            onLayout: { [weak self] in DispatchQueue.main.async { self?.resizeAndPositionPanel(animated: true) } })
        if let hostingView = self.hostingView { hostingView.rootView = PichiLocalizedContent { DictionaryCorrectionOverlayRoot(content: view) } }
        else { self.createPanel(rootView: view) }
        self.resizeAndPositionPanel(animated: true)
        self.panel?.alphaValue = 1
        self.panel?.orderFrontRegardless()
    }

    private func createPanel(rootView: DictionaryCorrectionOverlayGroupView) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false; panel.animationBehavior = .none
        let hostingView = NSHostingView(rootView: PichiLocalizedContent { DictionaryCorrectionOverlayRoot(content: rootView) })
        hostingView.wantsLayer = true; hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        self.panel = panel; self.hostingView = hostingView
        self.languageCancellable = NotificationCenter.default.publisher(for: PichiLocalization.languageChanged).receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.transientOverlayLayoutDidChange() } }
    }
    private func resizeAndPositionPanel(animated: Bool) {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else {
            return
        }

        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)

        let visibleFrame = screen.visibleFrame
        let requestedY = visibleFrame.minY + CGFloat(SettingsStore.shared.overlayBottomOffset)
        let microphoneToastY = MicrophoneChangeOverlayController.shared.topEdge(on: screen).map { $0 + 10 }
        let stackedY = max(requestedY, microphoneToastY ?? requestedY)
        let y = max(visibleFrame.minY + 10, min(stackedY, visibleFrame.maxY - size.height - 40))
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: y,
            width: size.width,
            height: size.height
        )

        guard animated, panel.isVisible else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }
}

enum MicrophoneChangePresentation: Hashable {
    case startupSelection
    case selectionChange
    case activeChange
}

struct MicrophoneChangeNotice: Hashable {
    let previousName: String?
    let currentName: String?
    let presentation: MicrophoneChangePresentation
}

@MainActor
final class MicrophoneChangeOverlayController {
    static let shared = MicrophoneChangeOverlayController()

    private static let displayDurationNanoseconds: UInt64 = 5_000_000_000
    private nonisolated static let supportedBundleIdentifiers = [
        AppBrand.releaseBundleIdentifier,
        AppBrand.releaseBundleIdentifier + ".debug",
    ]
    private var panel: NSPanel?
    private var hostingView: NSHostingView<PichiLocalizedContent<MicrophoneChangeOverlayView>>?
    private var languageCancellable: AnyCancellable?
    private var dismissTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    private init() {}

    func show(_ notice: MicrophoneChangeNotice) {
        guard Self.supportsAlerts(bundleIdentifier: Bundle.main.bundleIdentifier),
              SettingsStore.shared.showMicrophoneChangeAlerts
        else { return }
        self.generation &+= 1
        let currentGeneration = self.generation
        self.dismissTask?.cancel()

        let rootView = MicrophoneChangeOverlayView(
            notice: notice,
            displayDuration: Double(Self.displayDurationNanoseconds) / 1_000_000_000,
            startedAt: Date(),
            onSettings: { [weak self] in
                self?.hide()
                NotificationCenter.default.post(name: .openMicrophoneSettingsRequested, object: nil)
            },
            onDisable: { [weak self] in
                self?.disableFutureAlerts()
            },
            onDismiss: { [weak self] in self?.hide() }
        )
        if let hostingView = self.hostingView {
            hostingView.rootView = PichiLocalizedContent { rootView }
        } else {
            self.createPanel(rootView: rootView)
        }

        guard let panel = self.panel else { return }
        self.resizeAndPositionPanel()
        DebugLogger.shared.debug(
            "Showing microphone change overlay frame=\(NSStringFromRect(panel.frame))",
            source: "MicrophoneChangeOverlay"
        )
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.animate(duration: 0.12) {
            panel.animator().alphaValue = 1
        }
        DictionaryCorrectionOverlayController.shared.transientOverlayLayoutDidChange()

        self.dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.displayDurationNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.generation == currentGeneration
            else { return }
            self.hide()
        }
    }

    nonisolated static func supportsAlerts(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return self.supportedBundleIdentifiers.contains(bundleIdentifier)
    }

    func disableFutureAlerts() {
        SettingsStore.shared.showMicrophoneChangeAlerts = false
        self.hide()
    }

    func hide() {
        self.generation &+= 1
        let hideGeneration = self.generation
        self.dismissTask?.cancel()
        self.dismissTask = nil
        guard let panel else { return }
        guard panel.isVisible else {
            self.releasePanel()
            return
        }
        self.animate(duration: 0.1) {
            panel.animator().alphaValue = 0
        } completion: { [weak self] in
            MainActor.assumeIsolated {
                self?.finishHide(generation: hideGeneration)
            }
        }
        // AppKit can reach alpha=0 without delivering the animation completion
        // (notably for an inactive nonactivating panel). Bound the hosted timeline.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.finishHide(generation: hideGeneration)
        }
    }

    private func finishHide(generation: UInt64) {
        guard self.generation == generation, self.panel != nil else { return }
        self.releasePanel()
        DictionaryCorrectionOverlayController.shared.transientOverlayLayoutDidChange()
    }

    private func releasePanel() {
        self.languageCancellable?.cancel()
        self.languageCancellable = nil
        self.panel?.orderOut(nil)
        self.panel?.contentView = nil
        self.hostingView = nil
        self.panel = nil
    }

    func topEdge(on screen: NSScreen) -> CGFloat? {
        guard let panel, panel.isVisible, panel.frame.intersects(screen.frame) else { return nil }
        return panel.frame.maxY
    }

    private func createPanel(rootView: MicrophoneChangeOverlayView) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: PichiLocalizedContent { rootView })
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView
        self.panel = panel
        self.hostingView = hostingView
        self.languageCancellable = NotificationCenter.default.publisher(for: PichiLocalization.languageChanged)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.panel?.isVisible == true else { return }
                    self.resizeAndPositionPanel()
                    DictionaryCorrectionOverlayController.shared.transientOverlayLayoutDidChange()
                }
            }
    }

    private func resizeAndPositionPanel() {
        guard let panel, let hostingView,
              let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main
        else { return }
        hostingView.layoutSubtreeIfNeeded()
        let fittingSize = hostingView.fittingSize
        let size = NSSize(width: ceil(fittingSize.width), height: ceil(fittingSize.height))
        guard size.width > 0, size.height > 0 else { return }
        hostingView.frame = NSRect(origin: .zero, size: size)
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: visibleFrame.minY + 10,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
    }

    private func animate(
        duration: TimeInterval,
        changes: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion == false else {
            changes()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            changes()
        } completionHandler: {
            completion?()
        }
    }
}

private struct MicrophoneChangeOverlayView: View {
    let notice: MicrophoneChangeNotice
    let displayDuration: TimeInterval
    let startedAt: Date
    let onSettings: () -> Void
    let onDisable: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var interfaceLocale
    @State private var isCloseHovered = false
    @State private var isDisableHovered = false
    @State private var isSettingsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: self.notice.currentName == nil ? "mic.slash.fill" : "mic.fill")
                    .font(.fluidSystem(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 24, height: 24)

                Text(PichiLocalization.text(self.title, locale: self.interfaceLocale))
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))

                Spacer(minLength: 8)

                Button(action: self.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(self.isCloseHovered ? 0.95 : 0.68))
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(self.isCloseHovered ? 0.13 : 0.06)))
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .onHover { self.isCloseHovered = $0 }
                .help("Dismiss")
                .accessibilityLabel("Dismiss microphone change")
            }

            Text(self.detailText)
                .font(.fluidSystem(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Text(PichiLocalization.text(self.explanation, locale: self.interfaceLocale))
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button("Do not show again", action: self.onDisable)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isDisableHovered))
                    .onHover { self.isDisableHovered = $0 }
                    .help("Turn off microphone change alerts")

                Button("Settings", action: self.onSettings)
                    .buttonStyle(TransientOverlaySettingsButtonStyle(isHovered: self.isSettingsHovered))
                    .onHover { self.isSettingsHovered = $0 }
                    .help("Open microphone settings")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 540)
        .background(TransientOverlayBackground())
        .overlay(alignment: .bottomLeading) {
            TransientOverlayCountdownBar(
                startedAt: self.startedAt,
                duration: self.displayDuration,
                reduceMotion: self.reduceMotion
            )
        }
        .preferredColorScheme(.dark)
        .id(self.notice)
    }

    private var detailText: String {
        if self.notice.presentation == .startupSelection,
           let currentName = self.notice.currentName
        {
            return currentName
        }
        switch (self.notice.previousName, self.notice.currentName) {
        case let (previous?, current?):
            return "\(previous)  →  \(current)"
        case let (previous?, nil):
            return PichiLocalization.format("%@ is no longer available", language: PichiInterfaceLanguage(rawValue: self.interfaceLocale.identifier) ?? .russian, bundle: .main, arguments: [previous])
        case let (nil, current?):
            return PichiLocalization.format("Now using %@", language: PichiInterfaceLanguage(rawValue: self.interfaceLocale.identifier) ?? .russian, bundle: .main, arguments: [current])
        case (nil, nil):
            return PichiLocalization.text("Connect or restore a microphone in Settings", locale: self.interfaceLocale)
        }
    }

    private var title: String {
        if self.notice.presentation == .startupSelection {
            return "Microphone selected"
        }
        return self.notice.currentName == nil ? "Microphone unavailable" : "Microphone changed"
    }

    private var explanation: String {
        if self.notice.currentName == nil {
            return "Choose an available microphone in Settings."
        }
        if self.notice.presentation == .startupSelection {
            return AppBrand.text("FluidVoice will try this microphone first when you dictate.")
        }
        if self.notice.presentation == .selectionChange {
            return AppBrand.text("FluidVoice selected this microphone for capture.")
        }
        return AppBrand.text("FluidVoice confirmed this microphone is capturing audio.")
    }
}

struct TransientOverlaySettingsButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.fluidSystem(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 1 : 0.9))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.20 : self.isHovered ? 0.14 : 0.09))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(
                                Color.white.opacity(configuration.isPressed ? 0.28 : 0.12),
                                lineWidth: 1
                            )
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct TransientOverlayCountdownBar: View {
    let startedAt: Date
    let duration: TimeInterval
    let reduceMotion: Bool

    /// An animation timeline ticks for as long as the view exists, even in an
    /// ordered-out panel, so stop it once the countdown has run out.
    @State private var isElapsed = false

    var body: some View {
        TimelineView(.animation(minimumInterval: self.reduceMotion ? 1 : 1 / 30, paused: self.isElapsed)) { context in
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(Color.white.opacity(0.82))
                        .frame(width: proxy.size.width * self.remainingProgress(at: context.date))
                }
            }
        }
        .frame(height: 3)
        .padding(.horizontal, 14)
        .padding(.bottom, 3)
        .allowsHitTesting(false)
        .task(id: self.startedAt) {
            self.isElapsed = false
            let remaining = self.startedAt.timeIntervalSinceNow + self.duration
            try? await Task.sleep(for: .seconds(max(0, remaining)))
            guard !Task.isCancelled else { return }
            self.isElapsed = true
        }
    }

    private func remainingProgress(at date: Date) -> CGFloat {
        guard self.duration > 0 else { return 0 }
        return CGFloat(max(0, min(1, 1 - date.timeIntervalSince(self.startedAt) / self.duration)))
    }
}

struct TransientOverlayBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Color.black)
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.15), .white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
    }
}

extension Notification.Name {
    static let openMicrophoneSettingsRequested = Notification.Name("OpenMicrophoneSettingsRequested")
}

/// Independent panels need the same live theme owner as the main window.
private struct DictionaryCorrectionOverlayRoot: View {
    @ObservedObject private var settings = SettingsStore.shared
    let content: DictionaryCorrectionOverlayGroupView

    var body: some View {
        AdaptiveAppTheme(accent: self.settings.accentColor) { self.content }
    }
}

private struct DictionaryCorrectionOverlayGroupView: View {    @Environment(\.theme) private var theme

    @ObservedObject var state: DictionaryCorrectionOverlayState
    let onDismissAll: () -> Void
    let onDismissRow: (UUID) -> Void
    let onIgnore: (UUID) -> Void
    let onFrequencyChange: (SettingsStore.AutomaticDictionarySuggestionFrequency) -> Void
    let onDisableSuggestions: () -> Void
    let onLayout: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var interfaceLocale
    @State private var heights: [UUID: CGFloat] = [:]
    @State private var progress: CGFloat = 1

    private var contentHeight: CGFloat {
        let rows = self.state.sessions.reduce(CGFloat.zero) { total, session in
            total + (self.heights[session.candidate.id] ?? (session.isSavedCorrection ? 52 : 108))
        }
        return min(self.state.maximumListHeight, rows + CGFloat(max(0, self.state.sessions.count - 1)))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "text.book.closed.fill").foregroundStyle(self.theme.palette.accentText)
                Text("Personal Dictionary").font(self.theme.typography.bodySmallStrong)
                Spacer()
                Button(action: self.onDismissAll) {
                    Image(systemName: "xmark").font(.fluidSystem(size: 10, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close notification. Saved words stay in the dictionary.")
                .accessibilityLabel("Close notification")
                .disabled(self.state.sessions.contains(where: \.isUndoingSavedCorrection))
            }
            .foregroundStyle(self.theme.palette.secondaryText)
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(self.state.sessions, id: \.candidate.id) { session in
                        AutomaticDictionaryCorrectionOverlayView(session: session, displayDuration: 10,
                            onDismiss: { self.onDismissRow(session.candidate.id) },
                            onIgnore: { self.onIgnore(session.candidate.id) },
                            onFrequencyChange: self.onFrequencyChange, onDisableSuggestions: self.onDisableSuggestions,
                            grouped: true)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("DictionaryCorrection.Row." + session.candidate.id.uuidString)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if self.state.sessions.contains(where: { $0.candidate.id == session.candidate.id }),
                               self.heights[session.candidate.id] != height {
                                self.heights[session.candidate.id] = height
                                self.onLayout()
                            }
                        }
                        if session.candidate.id != self.state.sessions.last?.candidate.id {
                            Divider().overlay(self.theme.palette.separator).padding(.horizontal, 14)
                        }
                    }
                }
            }
            .frame(height: self.contentHeight)
            VStack(alignment: .leading, spacing: 7) {
                if self.state.sessions.contains(where: { $0.isSavedCorrection && !$0.didUndoSavedCorrection && $0.savedCorrection?.wasAlreadyPresent != true }) {
                    Text("Undo removes this dictionary save. Your text stays as edited.")
                        .font(self.theme.typography.captionSmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Closes automatically")
                    Spacer()
                    Text("New corrections restart the timer")
                }
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(.horizontal, 16).padding(.top, 5).padding(.bottom, 8)
            GeometryReader { proxy in
                Capsule().fill(self.theme.palette.accent)
                    .frame(width: proxy.size.width * self.progress, height: 2)
            }
            .frame(height: 3).padding(.horizontal, 16).padding(.bottom, 12)
            .accessibilityLabel("Time until notification closes")
            .accessibilityValue(Double(self.progress).formatted(.percent.precision(.fractionLength(0)).locale(self.interfaceLocale)))
        }
        .frame(width: 500)
        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(self.theme.palette.cardBorder, lineWidth: 1).allowsHitTesting(false) }

        .onAppear { self.restartProgress() }
        .onChange(of: self.state.progressGeneration) { _, _ in self.restartProgress() }
        .onChange(of: self.state.sessions.map(\.candidate.id)) { _, ids in
            self.heights = self.heights.filter { ids.contains($0.key) }
        }
    }

    private func restartProgress() {
        var transaction = Transaction(); transaction.disablesAnimations = true
        withTransaction(transaction) { self.progress = 1 }
        guard !self.reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: 10)) { self.progress = 0 }
        }
    }
}

private struct AutomaticDictionaryCorrectionOverlayView: View {
    @Environment(\.theme) private var theme
    @AppStorage("DictionarySharedFeatureMatcherEnabled", store: PrivateProfileDefaults.shared) private var pronunciationEnabled = DictionaryMatcherExperiment.defaultEnabled
    @ObservedObject var session: AutomaticDictionaryTrainingSession
    @ObservedObject private var settings = SettingsStore.shared

    let displayDuration: TimeInterval
    let onDismiss: () -> Void
    let onIgnore: () -> Void
    let onFrequencyChange: (SettingsStore.AutomaticDictionarySuggestionFrequency) -> Void
    let onDisableSuggestions: () -> Void
    var grouped = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var interfaceLocale
    @State private var isDismissHovered = false
    @State private var progress: CGFloat = 1

    private var accent: Color { self.theme.palette.accent }
    private var accentText: Color { self.theme.palette.accentText }

    var body: some View {
        Group {
            switch self.session.screen {
            case .choice:
                self.choiceContent
            case .training:
                self.trainingContent
            case .success:
                self.successContent
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: self.grouped ? nil : 460)
        .background { if !self.grouped { RoundedRectangle(cornerRadius: 18, style: .continuous).fill(self.theme.palette.cardBackground) } }
        .overlay(alignment: .bottomLeading) {
            if !self.grouped && (self.session.screen == .choice || (self.session.isSavedCorrection &&
                !self.session.didUndoSavedCorrection && !self.session.isUndoingSavedCorrection && !self.session.hasError)) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(self.theme.palette.accent)
                        .frame(width: proxy.size.width * self.progress, height: 2)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 3)
                .allowsHitTesting(false)
            }
        }

        .animation(self.reduceMotion ? nil : .easeOut(duration: 0.16), value: self.session.screen)
        .onAppear {
            self.startProgressAnimation()
        }
        .onChange(of: self.session.candidate.id) { _, _ in self.startProgressAnimation() }
        .onChange(of: self.pronunciationEnabled) { _, enabled in
            if !enabled { self.session.disablePronunciationTraining() }
        }
    }

    private var correctionChoiceDescription: String {
        if self.session.candidate.negativeCorrection != nil {
            return "Confirm only if you said a different word, not a spelling change."
        }
        return self.pronunciationEnabled
            ? AppBrand.text("Save only this correction, or teach FluidVoice other pronunciations.")
            : "Save this text correction to your dictionary."
    }

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header(title: self.session.candidate.negativeCorrection == nil ? "Learn this word?" : "Was this a wrong match?", allowsBack: false)

            self.correctionPair

            Text(PichiLocalization.text(self.correctionChoiceDescription, locale: self.interfaceLocale))
                .font(.fluidSystem(size: 11))
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                if self.session.candidate.negativeCorrection != nil {
                    CorrectionOverlayActionButton(title: "That Was a Wrong Match", systemImage: "xmark.circle", style: .accent, accent: self.accent, action: self.session.confirmWrongMatch)
                        .disabled(!self.pronunciationEnabled || self.session.capturePhase != .idle)
                    CorrectionOverlayActionButton(title: "Ignore", systemImage: "minus", style: .secondary, accent: self.accent, action: self.onIgnore)
                } else {
                    if self.pronunciationEnabled {
                        CorrectionOverlayActionButton(
                            title: "Record pronunciation",
                            systemImage: "mic.fill",
                            style: .secondary,
                            accent: self.accent,
                            action: self.session.continueInDictionary
                        )
                    }

                    CorrectionOverlayActionButton(
                        title: "Add This Correction",
                        systemImage: "plus",
                        style: .accent,
                        accent: self.accent,
                        action: self.session.addOnlyCorrection
                    )

                    self.moreOptionsMenu
                }
            }
            if self.session.hasError {
                Text(PichiLocalization.text(self.session.statusMessage, locale: self.interfaceLocale)).font(.fluidSystem(size: 11)).foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }

    private var moreOptionsMenu: some View {
        Menu {
            Button("Ignore This Correction", systemImage: "eye.slash", action: self.onIgnore)

            Menu("Ask after") {
                ForEach(SettingsStore.AutomaticDictionarySuggestionFrequency.allCases) { frequency in
                    Button {
                        self.onFrequencyChange(frequency)
                        self.startProgressAnimation()
                    } label: {
                        if self.settings.automaticDictionarySuggestionFrequency == frequency {
                            Label(PichiLocalization.text(frequency.displayName, locale: self.interfaceLocale), systemImage: "checkmark")
                        } else {
                            Text(PichiLocalization.text(frequency.displayName, locale: self.interfaceLocale))
                        }
                    }
                }
            }

            Divider()

            Button("Stop asking", role: .destructive, action: self.onDisableSuggestions)
        } label: {
            Image(systemName: "ellipsis")
                .font(.fluidSystem(size: 12, weight: .semibold))
                .foregroundStyle(self.theme.palette.secondaryText)
                .frame(width: 36, height: 36)
                .background(self.panelSurface)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More correction options")
    }

    private var trainingContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.header(title: "Train by Voice", allowsBack: true)

            self.correctionPair

            VStack(alignment: .leading, spacing: 9) {
                Text(AppBrand.text("Teach FluidVoice your pronunciation"))
                    .font(.fluidSystem(size: 13, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)

                if self.session.isReady {
                    Label(AppBrand.text("FluidVoice got it right 3 times in a row."), systemImage: "checkmark.circle.fill")
                        .font(.fluidSystem(size: 10.5, weight: .medium))
                        .foregroundStyle(self.accentText)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        self.trainingInstruction(number: 1, text: "Press Start once.")
                        self.trainingInstruction(
                            number: 2,
                            text: AppBrand.text("Say the word, then pause. FluidVoice captures it and listens again.")
                        )
                        self.trainingInstruction(number: 3, text: "Repeat naturally until the circle reaches 3/3.")
                    }
                }

                HStack(spacing: 12) {
                    CorrectionOverlayReadinessRing(
                        progress: self.session.readinessProgress,
                        total: CustomDictionaryTrainingMerge.readyCoveredCount,
                        isReady: self.session.isReady,
                        accent: self.accentText
                    )

                    Text(self.overlayReadinessCaption)
                        .font(.fluidSystem(size: 10.5, weight: .medium))
                        .foregroundStyle(self.session.isReady ? self.accentText : self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    CorrectionOverlayRecordButton(
                        title: self.session.recordButtonTitle,
                        isStop: self.session.recordButtonIsStop,
                        isEnabled: self.session.canUseRecordButton,
                        accent: self.accent,
                        action: self.session.toggleCapture
                    )
                }
            }
            .padding(10)
            .background(self.panelSurface)

            self.finalOutputRow

            if !self.session.variants.isEmpty {
                self.capturedVariantsRow
            }

            if self.session.capturePhase == .idle, self.session.hasError, !self.session.statusMessage.isEmpty {
                Label(
                    PichiLocalization.text(self.session.statusMessage, locale: self.interfaceLocale),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.fluidSystem(size: 10.5, weight: .medium))
                .foregroundStyle(Color.red.opacity(0.9))
                .lineLimit(1)
            }

            CorrectionOverlayActionButton(
                title: "Add Replacement",
                systemImage: self.session.isReady ? "sparkles" : "plus",
                style: .accent,
                accent: self.accent,
                isEnabled: self.session.canSave,
                isReady: self.session.isReady,
                action: self.session.addTrainedReplacement
            )
        }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var overlayReadinessCaption: String {
        if self.session.isReady {
            return PichiLocalization.text("Ready. Add Replacement is unlocked.", locale: self.interfaceLocale)
        }
        let remaining = max(
            0,
            CustomDictionaryTrainingMerge.readyCoveredCount - self.session.readinessProgress
        )
        return PichiLocalization.format(remaining == 1 ? "%lld correct try to unlock Add Replacement." : "%lld correct tries to unlock Add Replacement.", language: PichiInterfaceLanguage(rawValue: self.interfaceLocale.identifier) ?? .russian, bundle: .main, arguments: [remaining])
    }

    private func trainingInstruction(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text("\(number)")
                .font(.fluidSystem(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(self.accentText)
                .frame(width: 14)

            Text(PichiLocalization.text(text, locale: self.interfaceLocale))
                .font(.fluidSystem(size: 10.5))
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var successContent: some View {
        if self.session.isSavedCorrection && self.grouped {
            self.compactSavedContent
        } else if self.session.isSavedCorrection {
            VStack(alignment: .leading, spacing: 10) {
                self.header(title: self.session.successTitle, allowsBack: false)
                self.correctionPair
                if !self.session.didUndoSavedCorrection {
                    Text("Original audio saved.")
                        .font(.fluidSystem(size: 11))
                        .foregroundStyle(self.theme.palette.secondaryText)
                    HStack(spacing: 8) {
                        if self.session.savedCorrection?.wasAlreadyPresent != true {
                            CorrectionOverlayActionButton(
                                title: self.session.isUndoingSavedCorrection ? "Undoing..." : "Undo save",
                                systemImage: "arrow.uturn.backward", style: .accent, accent: self.accent,
                                action: self.session.undoSavedCorrection
                            )
                            .disabled(self.session.isUndoingSavedCorrection)
                        }
                        CorrectionOverlayActionButton(
                            title: "Open Dictionary", systemImage: "text.book.closed", style: .secondary, accent: self.accent,
                            action: self.session.openSavedDictionary
                        )
                        .disabled(self.session.isUndoingSavedCorrection)
                    }
                }
                if self.session.hasError {
                    Text(PichiLocalization.text(self.session.statusMessage, locale: self.interfaceLocale))
                        .font(.fluidSystem(size: 11))
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        } else {
            self.legacySuccessContent
        }
    }

    private var compactSavedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.correctionPair
            HStack(spacing: 10) {
                Label {
                    Text(PichiLocalization.text(self.savedStatus, locale: self.interfaceLocale))
                } icon: {
                    Image(systemName: self.session.didUndoSavedCorrection ? "arrow.uturn.backward" : "waveform.badge.checkmark")
                }
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !self.session.didUndoSavedCorrection && self.session.savedCorrection?.wasAlreadyPresent != true {
                    Button(action: self.session.undoSavedCorrection) {
                        Text(PichiLocalization.text(self.session.isUndoingSavedCorrection ? "Undoing..." : "Undo dictionary save", locale: self.interfaceLocale))
                    }
                    .buttonStyle(FluidOutlinedButtonStyle(height: 28))
                    .fixedSize()
                    .disabled(self.session.isUndoingSavedCorrection)
                    .help("Undo removes this dictionary save. Your text stays as edited.")
                }
                if !self.session.didUndoSavedCorrection {
                    Button(action: self.session.openSavedDictionary) {
                        Image(systemName: "text.book.closed").frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(self.theme.palette.accentText)
                    .help("Listen to or manage this word in the dictionary")
                    .accessibilityLabel("Open Dictionary")
                    .disabled(self.session.isUndoingSavedCorrection)
                }
            }
            if self.session.hasError {
                Text(PichiLocalization.text(self.session.statusMessage, locale: self.interfaceLocale))
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var savedStatus: String {
        if self.session.didUndoSavedCorrection { return self.session.successTitle }
        if self.session.savedCorrection?.wasAlreadyPresent == true { return "Word and audio already saved" }
        return "Word and audio saved"
    }

    private var legacySuccessContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(self.accent.opacity(0.18))
                    .frame(width: 38, height: 38)
                Image(systemName: "checkmark")
                    .font(.fluidSystem(size: 15, weight: .bold))
                    .foregroundStyle(self.accentText)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(PichiLocalization.text(self.session.successTitle, locale: self.interfaceLocale))
                    .font(.fluidSystem(size: 14, weight: .semibold))
                    .foregroundStyle(self.theme.palette.primaryText)
                Text("“\(self.session.candidate.heardText)” will become “\(self.session.candidate.correctedText)”.")
                    .font(.fluidSystem(size: 11))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }

    @ViewBuilder
    private func header(title: String, allowsBack: Bool) -> some View {
        if !self.grouped || self.session.screen != .success {
            HStack(spacing: 7) {
                if allowsBack {
                    Button(action: self.session.returnToChoice) {
                        Image(systemName: "chevron.left")
                            .font(.fluidSystem(size: 10, weight: .semibold))
                            .foregroundStyle(self.theme.palette.secondaryText)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(self.theme.palette.elevatedCardBackground))
                    }
                    .buttonStyle(.plain)
                    .disabled(self.session.capturePhase != .idle)
                    .opacity(self.session.capturePhase == .idle ? 1 : 0.35)
                    .help("Back")
                } else {
                    Image(systemName: self.session.isSavedCorrection ? "checkmark.circle.fill" : "mic.fill")
                        .font(.fluidSystem(size: 11, weight: .semibold))
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(width: 24, height: 24)
                }

                Text(PichiLocalization.text(title, locale: self.interfaceLocale))
                    .font(.fluidSystem(size: 12, weight: .medium))
                    .foregroundStyle(self.theme.palette.secondaryText)

                Spacer(minLength: 8)

                Button(action: self.onDismiss) {
                    Image(systemName: "xmark")
                        .font(.fluidSystem(size: 10, weight: .semibold))
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(
                            Circle()
                                .fill(self.theme.palette.elevatedCardBackground)
                        )
                }
                .buttonStyle(.plain)
                .disabled(self.session.isUndoingSavedCorrection)
                .contentShape(Circle())
                .onHover { self.isDismissHovered = $0 }
                .help("Dismiss")
            }
        }
    }

    private var correctionPair: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Recognized").font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text(verbatim: self.session.candidate.heardText)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .padding(.top, 20)
            VStack(alignment: .leading, spacing: 3) {
                Text("Your correction").font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text(verbatim: self.session.candidate.correctedText)
                    .font(self.theme.typography.bodySmallStrong)
                    .foregroundStyle(self.theme.palette.accentText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var finalOutputRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Final output")
                    .font(.fluidSystem(size: 10, weight: .medium))
                    .foregroundStyle(self.theme.palette.secondaryText)
                Text(self.session.lastOutput.isEmpty ? PichiLocalization.text("Record to check", locale: self.interfaceLocale) : self.session.finalOutputText)
                    .font(.fluidSystem(size: 12, weight: .semibold))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if self.session.isReady {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .font(.fluidSystem(size: 10.5, weight: .semibold))
                    .foregroundStyle(self.accentText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(self.panelSurface)
    }

    private var capturedVariantsRow: some View {
        HStack(spacing: 6) {
            Text("Captured")
                .font(.fluidSystem(size: 10.5, weight: .medium))
                .foregroundStyle(self.theme.palette.secondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(self.session.variants, id: \.self) { variant in
                        CorrectionOverlayVariantChip(variant: variant) {
                            self.session.removeVariant(variant)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }

    private func startProgressAnimation() {
        self.progress = 1
        guard !self.grouped, !self.reduceMotion else { return }
        DispatchQueue.main.async {
            withAnimation(.linear(duration: self.displayDuration)) {
                self.progress = 0
            }
        }
    }

    private var panelSurface: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(self.theme.palette.elevatedCardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
            )
    }
}

private struct CorrectionOverlayReadinessRing: View {
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale
    let progress: Int
    let total: Int
    let isReady: Bool
    let accent: Color

    private var fraction: Double {
        guard self.total > 0 else { return 0 }
        return min(max(Double(self.progress) / Double(self.total), 0), 1)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(self.theme.palette.cardBorder, lineWidth: 7)

            Circle()
                .trim(from: 0, to: self.fraction)
                .stroke(
                    self.accent,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            VStack(spacing: 0) {
                Text("\(self.progress)/\(self.total)")
                    .font(.fluidSystem(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(self.isReady ? self.accent : self.theme.palette.secondaryText)
                    .monospacedDigit()

                Text(PichiLocalization.text(self.isReady ? "Ready" : "correct", locale: self.interfaceLocale))
                    .font(.fluidSystem(size: 8.5, weight: .medium))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
        }
        .frame(width: 76, height: 76)
        .shadow(color: self.isReady ? self.accent.opacity(0.22) : .clear, radius: 9)
        .animation(.easeOut(duration: 0.24), value: self.progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Training progress")
        .accessibilityValue("\(self.progress) of \(self.total) correct")
    }
}

private struct CorrectionOverlayActionButton: View {
    @Environment(\.theme) private var theme
    enum Style {
        case accent
        case secondary
    }

    let title: String
    let systemImage: String
    let style: Style
    let accent: Color
    var isEnabled = true
    var isReady = false
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.locale) private var interfaceLocale
    @State private var isHovered = false
    @State private var isGlowExpanded = false

    private var shouldPulse: Bool {
        self.isReady && self.isEnabled && !self.isHovered && !self.reduceMotion
    }

    var body: some View {
        Button(action: self.action) {
            Label(PichiLocalization.text(self.title, locale: self.interfaceLocale), systemImage: self.systemImage)
                .font(.fluidSystem(size: 12, weight: .semibold))
                .foregroundStyle(self.foreground)
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(self.background)
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .onHover { self.isHovered = $0 }
        .onAppear { self.updateGlow() }
        .onChange(of: self.shouldPulse) { _, _ in
            self.updateGlow()
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(self.fillColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(self.borderColor, lineWidth: self.isReady ? 1.5 : 1)
            )
            .shadow(
                color: self.isReady ? self.accent.opacity(self.isGlowExpanded ? 0.34 : 0.14) : .clear,
                radius: self.isReady ? (self.isGlowExpanded ? 16 : 7) : 0,
                y: 3
            )
    }

    private var fillColor: Color {
        guard self.isEnabled else {
            return self.theme.palette.elevatedCardBackground
        }
        switch self.style {
        case .accent:
            return self.accent
        case .secondary:
            return self.isHovered ? self.accent.opacity(0.12) : self.theme.palette.elevatedCardBackground
        }
    }

    private var foreground: Color {
        guard self.isEnabled else { return self.theme.palette.secondaryText }
        switch self.style {
        case .accent:
            return AppTheme.Palette.contrastingInk(on: self.accent)
        case .secondary:
            return self.theme.palette.primaryText
        }
    }

    private var borderColor: Color {
        guard self.isEnabled else {
            return self.theme.palette.cardBorder
        }
        if self.isReady {
            return self.accent.opacity(0.78)
        }
        switch self.style {
        case .accent:
            return self.theme.palette.cardBorder
        case .secondary:
            return self.isHovered ? self.accent : self.theme.palette.cardBorder
        }
    }

    private func updateGlow() {
        guard self.shouldPulse else {
            withAnimation(.easeOut(duration: 0.16)) {
                self.isGlowExpanded = false
            }
            return
        }

        self.isGlowExpanded = false
        withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
            self.isGlowExpanded = true
        }
    }
}

private struct CorrectionOverlayRecordButton: View {
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let isStop: Bool
    let isEnabled: Bool
    let accent: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.action) {
            Label(PichiLocalization.text(self.title, locale: self.interfaceLocale), systemImage: self.isStop ? "stop.fill" : "mic.fill")
                .font(.fluidSystem(size: 12, weight: .semibold))
                .foregroundStyle(self.isEnabled ? AppTheme.Palette.contrastingInk(on: self.buttonColor) : self.theme.palette.secondaryText)
                .padding(.horizontal, 13)
                .frame(height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(self.isEnabled ? self.buttonColor : self.buttonColor.opacity(0.25))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(self.isHovered ? self.accent : self.theme.palette.cardBorder, lineWidth: 1)
                        }
                )
        }
        .buttonStyle(.plain)
        .disabled(!self.isEnabled)
        .onHover { self.isHovered = $0 }
    }

    private var buttonColor: Color {
        self.isStop ? Color(red: 0.82, green: 0.18, blue: 0.2) : self.accent
    }
}

private struct CorrectionOverlayVariantChip: View {
    @Environment(\.theme) private var theme
    let variant: String
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: self.onRemove) {
            HStack(spacing: 4) {
                Text(self.variant)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "xmark.circle.fill")
                    .font(.fluidSystem(size: 9))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .font(.fluidSystem(size: 10.5, weight: .medium))
            .foregroundStyle(self.theme.palette.secondaryText)
            .padding(.horizontal, 7)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(self.isHovered ? self.theme.palette.accent.opacity(0.12) : self.theme.palette.elevatedCardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 112)
        .onHover { self.isHovered = $0 }
        .help("Remove \(self.variant)")
    }
}
