import AppKit
import ApplicationServices
import Combine
import QuartzCore
import SwiftUI


/// Free rectangles around the editor, in AppKit screen coordinates. The whole
/// text field is protected, including when the popup grows or is dragged.
enum DictionaryCorrectionOverlayPlacement {
    static func appKitFrame(accessibilityFrame: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: accessibilityFrame.minX, y: primaryScreenTop - accessibilityFrame.maxY,
               width: accessibilityFrame.width, height: accessibilityFrame.height)
    }

    static func availableRegions(screen: CGRect, editor: CGRect) -> [CGRect] {
        let safe = screen.insetBy(dx: 10, dy: 10)
        let excluded = editor.insetBy(dx: -10, dy: -10).intersection(safe)
        guard !excluded.isNull else { return [safe] }
        return [
            CGRect(x: safe.minX, y: excluded.maxY, width: safe.width, height: max(0, safe.maxY - excluded.maxY)),
            CGRect(x: safe.minX, y: safe.minY, width: safe.width, height: max(0, excluded.minY - safe.minY)),
            CGRect(x: safe.minX, y: safe.minY, width: max(0, excluded.minX - safe.minX), height: safe.height),
            CGRect(x: excluded.maxX, y: safe.minY, width: max(0, safe.maxX - excluded.maxX), height: safe.height),
        ]
    }

    static func region(size: CGSize, screen: CGRect, editor: CGRect, minimumHeight: CGFloat) -> CGRect? {
        let regions = availableRegions(screen: screen, editor: editor).filter { $0.width >= size.width && $0.height >= minimumHeight }
        return regions.first { $0.height >= size.height } ?? regions.max { $0.height < $1.height }
    }

    static func frame(size: CGSize, screen: CGRect, editor: CGRect, manualTopLeft: CGPoint? = nil) -> CGRect? {
        guard size.width > 0, size.height > 0 else { return nil }
        let safe = screen.insetBy(dx: 10, dy: 10)
        guard size.width <= safe.width, size.height <= safe.height else { return nil }
        func clamped(_ point: CGPoint) -> CGRect {
            CGRect(x: min(max(point.x, safe.minX), safe.maxX - size.width),
                   y: min(max(point.y - size.height, safe.minY), safe.maxY - size.height),
                   width: size.width, height: size.height)
        }
        let excluded = editor.insetBy(dx: -10, dy: -10)
        if let manualTopLeft {
            let manual = clamped(manualTopLeft)
            if !manual.intersects(excluded) { return manual }
        }
        guard let region = region(size: size, screen: screen, editor: editor, minimumHeight: size.height) else { return nil }
        let x = min(max(editor.midX - size.width / 2, region.minX), region.maxX - size.width)
        let y: CGFloat
        if region.minY >= editor.maxY { y = region.minY }
        else if region.maxY <= editor.minY { y = region.maxY - size.height }
        else { y = min(max(editor.midY - size.height / 2, region.minY), region.maxY - size.height) }
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}

/// Only geometry is read. No text or selection content is copied into the popup.
@MainActor
private final class DictionaryCorrectionEditorGeometry {
    private var retainedElement: AXUIElement?

    func reset() { self.retainedElement = nil }

    func frame() -> CGRect? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.08)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        var element = unsafeBitCast(value, to: AXUIElement.self)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        if pid == ProcessInfo.processInfo.processIdentifier,
           NSApp.keyWindow?.identifier?.rawValue == "DictionaryCorrectionOverlay" {
            guard let retainedElement else { return nil }
            element = retainedElement
        } else {
            self.retainedElement = nil
            var found: AXUIElement?
            for _ in 0..<5 {
                AXUIElementSetMessagingTimeout(element, 0.08)
                var role: CFTypeRef?, subrole: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
                AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
                guard (subrole as? String) != (kAXSecureTextFieldSubrole as String) else { return nil }
                if [kAXTextAreaRole as String, kAXTextFieldRole as String, kAXComboBoxRole as String].contains(role as? String ?? "") {
                    found = element; break
                }
                var parent: CFTypeRef?
                guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                      let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
                element = unsafeBitCast(parent, to: AXUIElement.self)
            }
            guard let found else { return nil }
            element = found; self.retainedElement = found
        }
        var positionValue: CFTypeRef?, sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }
        var position = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(positionValue, to: AXValue.self), .cgPoint, &position),
              AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size),
              position.x.isFinite, position.y.isFinite, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0, let primary = NSScreen.screens.first else { return nil }
        return DictionaryCorrectionOverlayPlacement.appKitFrame(accessibilityFrame: CGRect(origin: position, size: size), primaryScreenTop: primary.frame.maxY)
    }
}

private struct DictionaryCorrectionDragHandle: NSViewRepresentable {
    let began: () -> Void
    let ended: (CGRect) -> Void
    func makeNSView(context: Context) -> Handle { Handle() }
    func updateNSView(_ view: Handle, context: Context) { view.began = self.began; view.ended = self.ended }
    final class Handle: NSView {
        var began: (() -> Void)?
        var ended: ((CGRect) -> Void)?
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            self.began?()
            window.performDrag(with: event)
            self.ended?(window.frame)
        }
        override func resetCursorRects() { self.addCursorRect(self.bounds, cursor: .openHand) }
    }
}

/// SwiftUI observes the collection while each row retains its existing session.
@MainActor
private final class DictionaryCorrectionOverlayState: ObservableObject {
    @Published var sessions: [AutomaticDictionaryTrainingSession] = []
    @Published var progressGeneration: UInt64 = 0
    @Published var maximumListHeight: CGFloat = 420
    var chromeHeight: CGFloat = 120
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
    private let editorGeometry = DictionaryCorrectionEditorGeometry()
    private var geometryTask: Task<Void, Never>?
    private var manualTopLeft: CGPoint?
    private var isDragging = false


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
        self.geometryTask?.cancel(); self.geometryTask = nil; self.editorGeometry.reset()
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
        guard !self.state.sessions.isEmpty else { return }
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

    func setArchiveWarning(_ warning: String?, receiptID: UUID) {
        self.state.sessions.first(where: { $0.savedCorrection?.id == receiptID })?.setArchiveWarning(warning)
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
                + (session.candidate.trainingExample?.recording.samples.count ?? 0) * MemoryLayout<Float>.stride
        }
        var bounded = candidate
        if let audio = bounded.audioEvidence,
           DictionaryAudioLearningService.retainedBytes(audio) > 128 * 1024 * 1024 - retained {
            bounded.audioEvidence = nil
        }
        let audioBytes = bounded.audioEvidence.map(DictionaryAudioLearningService.retainedBytes) ?? 0
        if let example = bounded.trainingExample,
           example.recording.samples.count * MemoryLayout<Float>.stride > 128 * 1024 * 1024 - retained - audioBytes {
            bounded.trainingExample = nil
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
        session.onSuccess = { [weak self, weak session] in
            guard let session else { return }
            self?.outcomes.removeValue(forKey: id)?(.accepted)
            if session.screen == .success && session.archiveWarning == nil && (!session.isSavedCorrection || session.didUndoSavedCorrection) {
                self?.remove(id: id)
            } else {
                self?.rowDidChange()
            }
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
        guard !self.isDragging, let deadline, self.now() >= deadline,
              !self.state.sessions.contains(where: {
                  $0.isUndoingSavedCorrection || $0.capturePhase != .idle || $0.screen == .training || $0.hasError || $0.archiveWarning != nil
              }) else { return }
        for id in Array(self.outcomes.keys) { self.outcomes.removeValue(forKey: id)?(.timedOut) }
        self.hide()
    }

    private func rowDidChange() {
        self.state.objectWillChange.send()
        self.expireIfDue()
        self.resizeAndPositionPanel(animated: true)
    }

    /// Acknowledging a saved row only removes its notice. It never saves again
    /// or revokes the receipt, and leaves the shared deadline unchanged.
    func confirm(id: UUID) {
        guard let session = self.state.sessions.first(where: { $0.candidate.id == id }),
              session.screen == .success, !session.isUndoingSavedCorrection, !session.hasError else { return }
        self.outcomes.removeValue(forKey: id)?(.accepted)
        self.remove(id: id)
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
        self.geometryTask?.cancel(); self.geometryTask = nil; self.editorGeometry.reset()
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
        let profile = PrivateProfileStorage.current
        let view = DictionaryCorrectionOverlayGroupView(state: self.state,
            onDismissAll: { [weak self] in self?.dismiss() },
            onDismissRow: { [weak self] in self?.dismiss(id: $0) },
            onConfirmRow: { [weak self] in self?.confirm(id: $0) },
            onDragBegan: { [weak self] in self?.isDragging = true },
            onDragEnded: { [weak self] frame in
                guard let self else { return }
                self.isDragging = false
                self.manualTopLeft = CGPoint(x: frame.minX, y: frame.maxY)
                self.resizeAndPositionPanel(animated: false)
                self.expireIfDue()
            },
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
        if self.geometryTask == nil {
            self.geometryTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    guard let self, !self.state.sessions.isEmpty else { return }
                    self.resizeAndPositionPanel(animated: false)
                }
            }
        }
    }

    private func createPanel(rootView: DictionaryCorrectionOverlayGroupView) {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("DictionaryCorrectionOverlay")
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
        guard !self.isDragging, let panel, let hostingView else { return }
        guard let editor = self.editorGeometry.frame(),
              let editorScreen = NSScreen.screens.max(by: {
                  let a = $0.frame.intersection(editor), b = $1.frame.intersection(editor)
                  return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
              }), editorScreen.frame.intersects(editor) else {
            // If the editor cannot provide geometry, avoid guessing over its text.
            panel.orderOut(nil); return
        }
        let screen = self.manualTopLeft.flatMap { point in
            NSScreen.screens.first { $0.frame.contains(CGPoint(x: point.x, y: point.y - 1)) }
        } ?? editorScreen
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let size = CGSize(width: ceil(fitting.width), height: ceil(fitting.height))
        guard let region = DictionaryCorrectionOverlayPlacement.region(size: size,
            screen: screen.visibleFrame, editor: editor, minimumHeight: self.state.chromeHeight + 60) else {
            panel.orderOut(nil); return
        }
        let listHeight = min(420, max(60, floor(region.height - self.state.chromeHeight)))
        if self.state.maximumListHeight != listHeight {
            self.state.maximumListHeight = listHeight
        }
        guard let frame = DictionaryCorrectionOverlayPlacement.frame(size: size,
            screen: screen.visibleFrame, editor: editor, manualTopLeft: self.manualTopLeft) else {
            panel.orderOut(nil); return
        }
        hostingView.frame = CGRect(origin: .zero, size: size)
        // A straight animation between safe positions could cross the editor.
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
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

private struct DictionaryCorrectionOverlayGroupView: View {
    @Environment(\.theme) private var theme

    @ObservedObject var state: DictionaryCorrectionOverlayState
    let onDismissAll: () -> Void
    let onDismissRow: (UUID) -> Void
    let onConfirmRow: (UUID) -> Void
    let onDragBegan: () -> Void
    let onDragEnded: (CGRect) -> Void
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
                HStack(spacing: 8) {
                    Image(systemName: "text.book.closed.fill").foregroundStyle(self.theme.palette.accentText)
                    Text("Personal Dictionary").font(self.theme.typography.bodySmallStrong)
                    Spacer()
                    Image(systemName: "hand.draw").font(self.theme.typography.caption)
                }
                .overlay { DictionaryCorrectionDragHandle(began: self.onDragBegan, ended: self.onDragEnded) }
                .help("Drag to move this notification")
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
                            onConfirm: { self.onConfirmRow(session.candidate.id) },
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
        .onGeometryChange(for: CGFloat.self) { $0.size.height - self.contentHeight } action: { height in
            if height > 0, self.state.chromeHeight != height {
                self.state.chromeHeight = height
                self.onLayout()
            }
        }
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
    let onConfirm: () -> Void
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

    private var choiceContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            self.correctionPair
            if self.session.candidate.negativeCorrection != nil {
                Text("Confirm only if you said a different word, not a spelling change.")
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("That Was a Wrong Match", action: self.session.confirmWrongMatch)
                    .font(self.theme.typography.captionStrong)
                    .fluidButton(.accent, size: .small)
                    .disabled(!self.pronunciationEnabled || self.session.capturePhase != .idle)
            } else {
                Text(PichiLocalization.text(self.session.candidate.trainingExample?.recording.archiveAdmission != nil
                    ? "Saves this correction and its complete dictation audio on this Mac."
                    : "Couldn't save this correction automatically."))
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if self.session.candidate.negativeCorrection == nil {
                    Button(PichiLocalization.text("Save correction"), action: self.session.addOnlyCorrection)
                        .buttonStyle(FluidOutlinedButtonStyle(height: 28))
                        .disabled(self.session.capturePhase != .idle)
                }
                Button("Done", action: self.onDismiss)
                    .buttonStyle(FluidOutlinedButtonStyle(height: 28, foreground: self.theme.palette.accentText))
            }
            if self.session.capturePhase == .processing || self.session.hasError {
                Text(PichiLocalization.text(self.session.statusMessage, locale: self.interfaceLocale))
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .transition(.opacity)
    }

    private var moreOptionsMenu: some View {
        Menu {
            if self.pronunciationEnabled {
                Button("Record pronunciation", systemImage: "mic.fill", action: self.session.continueInDictionary)
                Divider()
            }
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
                .frame(width: 28, height: 28)
                .background(self.panelSurface)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More correction options")
        .accessibilityLabel("More correction options")
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
                    Image(systemName: self.session.didUndoSavedCorrection ? "arrow.uturn.backward" :
                        self.session.savedCorrection?.audioWasSaved == false ? "text.book.closed" : "waveform")
                }
                .font(self.theme.typography.captionSmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !self.session.didUndoSavedCorrection {
                    Button(action: self.session.undoSavedCorrection) {
                        Text(PichiLocalization.text(self.session.isUndoingSavedCorrection ? "Undoing..." : "Undo dictionary save", locale: self.interfaceLocale))
                    }
                    .buttonStyle(FluidOutlinedButtonStyle(height: 28))
                    .fixedSize()
                    .disabled(self.session.isUndoingSavedCorrection)
                    .help(PichiLocalization.text(self.session.savedCorrection?.wasAlreadyPresent == true
                        ? "No new sample was added. Undo only dismisses this confirmation."
                        : "Undo removes this dictionary save. Your text stays as edited.", locale: self.interfaceLocale))
                }
                Button("Done", action: self.onConfirm)
                    .buttonStyle(FluidOutlinedButtonStyle(height: 28, foreground: self.theme.palette.accentText))
                    .disabled(self.session.isUndoingSavedCorrection || self.session.hasError)
                    .help("Keep this save and dismiss its notification")
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
            if let warning = self.session.archiveWarning {
                Text(warning)
                    .font(self.theme.typography.captionSmall)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                    .fixedSize(horizontal: false, vertical: true)
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
        if self.session.savedCorrection?.audioWasSaved == false { return "Word saved. Audio clip not saved." }
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
                if let warning = self.session.archiveWarning {
                    Text(warning)
                        .font(.fluidSystem(size: 11))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
