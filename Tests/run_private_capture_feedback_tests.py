#!/usr/bin/env python3
"""Run actual capture presentation callbacks and stream buffer with UI-free doubles."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def declaration(source, marker):
    start = source.index(marker)
    brace = source.index("{", start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", help="Run the regression against an older ContentView")
    parser.add_argument("--unguarded-callback", choices=["status", "preview", "final", "immediate"],
                        help="Negative control that removes one source-owner fence from the projected body")
    parser.add_argument("--unguarded-menu", choices=["preview", "meeting", "conceal", "start-error", "queued-start"],
                        help="Negative control that removes one menu source-owner or conceal fence")
    parser.add_argument("--unguarded-discovery", action="store_true", help="Negative control for the actual held discovery/start path")
    parser.add_argument("--unjoined-discovery", action="store_true", help="Negative control for discovery transition registration")
    parser.add_argument("--unguarded-verifier", choices=["post", "presentation"], help="Negative control for retained paste feedback")
    args = parser.parse_args()
    source_path = "Sources/Fluid/ContentView.swift"
    content = (subprocess.check_output(["git", "show", f"{args.baseline_ref}:{source_path}"], cwd=ROOT, text=True)
               if args.baseline_ref else (ROOT / source_path).read_text())
    asr = (ROOT / "Sources/Fluid/Services/ASRService.swift").read_text()
    # Bodies are compiled unchanged. Expose only access control for deterministic observation
    # of whether the real buffer's MainActor publication is still queued before scope changes.
    buffer = declaration(content, "final nonisolated class DictationAIStreamPreviewBuffer:").replace("    private ", "    ")
    schedule_start = asr.index("func scheduleDeferredMainActorOperation(")
    schedule = asr[schedule_start:asr.index("/// Identifies the recording", schedule_start)].strip()
    callbacks = "\n".join(declaration(content, marker).replace("private func", "func", 1) for marker in [
        "    private func makeAIProcessingFeedback(", "    private func prepareOverlayForASRStop("])
    if args.unguarded_callback == "immediate":
        callbacks = callbacks.replace("guard privateOperations.isCurrent else { return (true, nil) }", "", 1)
    elif args.unguarded_callback:
        fence = "guard privateOperations.isCurrent,"
        index = ["status", "preview", "final"].index(args.unguarded_callback)
        parts = callbacks.split(fence)
        assert len(parts) == 4, "Exactly three queued callback fences are projected"
        callbacks = fence.join(parts[:index + 1]) + "guard " + fence.join(parts[index + 1:])
    menu = (ROOT / "Sources/Fluid/Services/MenuBarManager.swift").read_text()
    service = (ROOT / "Sources/Fluid/Services/AppServices+MeetingMenuBar.swift").read_text()
    service_start = declaration(service, "    func startMeetingRecordingFromMenuBar()")
    if args.unguarded_discovery:
        service_start = service_start.replace("guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { throw CancellationError() }", "")
        service_start = service_start.replace("PrivateProfileOperationOwner(registerForTransitions: true)", "UnownedDiscoveryDouble()")
    if args.unjoined_discovery:
        service_start = service_start.replace("PrivateProfileOperationOwner(registerForTransitions: true)", "PrivateProfileOperationOwner(registerForTransitions: false)")
    coordinator = (ROOT / "Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift").read_text()
    partial_start = menu.index("        asrService.$partialTranscription")
    partial_end = menu.index("            .store(in: &self.cancellables)", partial_start) + len("            .store(in: &self.cancellables)")
    partial = menu[partial_start:partial_end]
    assert partial.index(".map {") < partial.index(".receive(on:"), "Profile ownership is captured before preview queue dispatch"
    meeting = declaration(menu, "    func configure(meetingCoordinator:")
    assert meeting.index(".map {") < meeting.index(".receive(on:"), "Profile ownership is captured before meeting queue dispatch"
    observer_start = menu.index("        NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)")
    observer_end = menu.index("        NotificationCenter.default.publisher(for: AppBrand.appearanceChanged)", observer_start)
    observer = menu[observer_start:observer_end]
    assert "MainActor.assumeIsolated" in observer and "Task {" not in observer and ".receive(on:" not in observer
    spoken_send = declaration((ROOT / source_path).read_text(), "    private func handleSpokenSendPartialTranscription(")
    assert spoken_send.index("self.privateOutputOperations.isCurrent") < spoken_send.index("self.spokenSendArming.update")
    typing = (ROOT / "Sources/Fluid/Services/TypingService.swift").read_text()
    verifier = declaration(typing, "    private func verifyPasteLanded(").replace("private func", "func", 1)
    paste_observer_start = menu.index("        NotificationCenter.default.publisher(for: .fluidPasteNotLanded)")
    paste_observer_end = menu.index("        // Subscribe to recording state changes", paste_observer_start)
    paste_observer = menu[paste_observer_start:paste_observer_end]
    paste_presentation = declaration(menu, "    func showPasteNotLandedFailure(")
    delivery_start = typing.index("    func typeOutputPlanInstantly(")
    delivery = typing[delivery_start:typing.index("    func typeOutputPlanInstantly(", delivery_start + 1)]
    assert delivery.index("let profile = PrivateProfileStorage.current") < delivery.index("await ")
    assert "callerIsOutputValid() && PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork" in delivery
    assert "self.verifyPasteLanded(text, before: verificationBefore, profile: profile, isOutputValid: isOutputValid)" in delivery
    if args.unguarded_verifier == "post":
        verifier = verifier.replace("                guard isOutputValid(), PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { return }", "", 1)
    elif args.unguarded_verifier == "presentation":
        paste_presentation = paste_presentation.replace("PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,", "", 1)
    menu_types = "\n".join(declaration(menu, marker).replace("private ", "", 1) for marker in [
        "    private enum MeetingMenuActivity:", "    private struct MeetingMenuPresentation"])
    menu_methods = "\n".join(declaration(menu, marker).replace("@objc private func", "func", 1).replace("private func", "func", 1).replace("private var", "var", 1) for marker in [
        "    private func applyMeetingPresentation(", "    private func concealPrivatePresentation()",
        "    private var canStartMeetingRecording:", "    func startMeetingRecordingInBackground(",
        "    @objc private func startMeetingRecording()", "    @objc private func stopMeetingRecording()"])
    if args.unguarded_menu == "preview":
        partial = partial.replace("PrivateProfileStorage.isReadable(update.profile), PrivateProfileStorage.acceptsNewWork", "true", 1)
    elif args.unguarded_menu == "meeting":
        meeting = meeting.replace("PrivateProfileStorage.isReadable(update.profile), PrivateProfileStorage.acceptsNewWork", "true", 1)
    elif args.unguarded_menu == "conceal":
        observer = ""
    elif args.unguarded_menu == "start-error":
        menu_methods = menu_methods.replace("} catch {\n            guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { return }", "} catch {", 1)
    elif args.unguarded_menu == "queued-start":
        menu_methods = menu_methods.replace("Task { @MainActor in\n            guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork else { return }", "Task { @MainActor in", 1)
    generated = "import Foundation\nimport Combine\n" + buffer + "\n@MainActor\n" + schedule + "\n" + r'''
@MainActor protocol AccountSessionLifecycle: AnyObject {
    var isAccountIsolationReady: Bool { get }
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async throws
}
@MainActor final class PrivateProfileMeetingStore {
    static let shared = PrivateProfileMeetingStore()
    func finishProfileTransition() async {}
}
@MainActor final class MenuBarDouble {
    var flushes = 0, processing = 0, reservations = 0
    func flushDeferredStoppedRecordingState() { flushes += 1 }
    func setProcessing(_ value: Bool) { if value { processing += 1 } }
    func reserveProcessingOverlay() { reservations += 1 }
}
@MainActor final class ASRDouble {
    var isFinalTranscriptionReady = true
    var isRunning = true
}
@MainActor final class NotchOverlayManager {
    struct Event { let profile: PrivateProfileSnapshot; let text: String }
    static let shared = NotchOverlayManager()
    var events: [Event] = []
    var hides = 0
    var shouldShowOrTrackLivePreviewText = true
    func hideImmediately() { hides += 1 }
    func updateTranscriptionText(_ text: String) {
        // Same current-scope-only admission as the production Notch entry point.
        guard PrivateProfileStorage.current.isReadable else { return }
        events.append(.init(profile: PrivateProfileStorage.current, text: text))
    }
}
@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    var information: [String] = []
    func debug(_ text: String, source: String) {}
    func error(_ text: String, source: String) {}
    func info(_ text: String, source: String) { information.append(text) }
}
@MainActor final class ContentFeedbackProbe {
    static let aiProcessingStatusDelayNanoseconds: UInt64 = 1_000_000
    let privateOutputOperations = PrivateProfileOperationOwner()
    let menuBarManager = MenuBarDouble()
    let asr = ASRDouble()
    var overlayLifecycleID: UInt64 = 7
    var cancelledOutputLifecycleID: UInt64?
    var hides = 0
    func hideOverlayAsync(reason: String) { hides += 1 }
    func appBench(_ text: String) {}
''' + callbacks + "\n}\n" + r'''
typealias MeetingSessionID = UUID
enum MeetingProcessingStage: Equatable { case synthetic }
struct MeetingSessionFailure: Equatable { let message: String }
''' + declaration(coordinator, "enum MeetingCoordinatorState:") + r'''
struct MeetingSession {
    struct Application { let displayName: String }
    var capturedApplication: Application?
    var startedAt: Date?
}
@MainActor final class MeetingSessionCoordinator {
    @Published var state: MeetingCoordinatorState = .idle
    @Published var activeSession: MeetingSession?
    @Published var latestCompletedSession: MeetingSession?
    var stops = 0
    var starts = 0
    var configurationOwners: [String] = []
    var captureGate: MenuStartGate?
    var captureWasCancelled = false
    func stopAndTranscribe() async throws { stops += 1 }
    func startRecording(configuration: MeetingCaptureConfiguration) async throws {
        starts += 1; configurationOwners.append(configuration.owner)
        await captureGate?.hold()
        captureWasCancelled = Task.isCancelled
    }
}
@MainActor final class ASRService {
    @Published var partialTranscription = ""
    var isRunning = false
}
@MainActor final class AppServices {
    static let shared = AppServices()
    let meetingSessionCoordinator = MeetingSessionCoordinator()
    var meetingAutomaticTarget: MeetingAutoDetector.ResolvedTarget?
    var starts: Int { meetingSessionCoordinator.starts }
    static func menuBarMeetingConfiguration(defaults: MeetingRecordingDefaults, target: MeetingAutoDetector.ResolvedTarget?,
        microphones: MeetingMicrophoneCatalogSnapshot, applications: [MeetingApplicationIdentity], preferredInputUID: String?) throws -> MeetingCaptureConfiguration {
        MeetingCaptureConfiguration(owner: defaults.owner)
    }
''' + service_start + r'''
}
enum MeetingCaptureMode { case onlineCall, inRoom }
enum MeetingApplicationAudioScope { case selectedApplication, systemAudio }
struct MeetingRecordingDefaults {
    var mode: MeetingCaptureMode = .onlineCall
    var effectiveApplicationAudioScope: MeetingApplicationAudioScope = .selectedApplication
    var usesAutomaticApplication = false
    var owner = "synthetic"
}
struct MeetingCaptureConfiguration: Sendable { let owner: String }
@MainActor final class UnownedDiscoveryDouble {
    func perform<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value { try await operation() }
}
struct MeetingMicrophoneCatalogSnapshot {}
struct MeetingApplicationIdentity {}
enum MeetingAutoDetector { struct ResolvedTarget: Equatable { let bundleIdentifier: String } }
enum MeetingCaptureError: Error { case applicationNotSelected, applicationUnavailable(String) }
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var meetingRecordingDefaults = MeetingRecordingDefaults()
    var preferredInputDeviceUID: String?
}
@MainActor enum MeetingCaptureSourceCatalog {
    static var microphoneGate: MenuStartGate?
    static var applicationGate: MenuStartGate?
    static var microphoneReads = 0, applicationReads = 0
    static func microphoneSnapshot() async -> MeetingMicrophoneCatalogSnapshot {
        microphoneReads += 1
        await microphoneGate?.hold()
        return .init()
    }
    static func availableApplications() async throws -> [MeetingApplicationIdentity] {
        applicationReads += 1
        await applicationGate?.hold()
        return []
    }
}
@MainActor enum NotchContentState {
    static let shared = State()
    final class State {
        var text = ""
        func updateTranscription(_ text: String) { self.text = text }
    }
}
@MainActor enum AccessibilityNotification {
    struct Announcement {
        let text: String
        init(_ text: String) { self.text = text }
        @MainActor func post() { AccessibilityNotification.announcements.append(text) }
    }
    static var announcements: [String] = []
}
@MainActor final class MenuBarFeedbackProbe {
''' + menu_types + r'''
    final class MenuItemDouble { var title = "SECRET cached item title"; var toolTip: String? = "SECRET cached tooltip" }
    var meetingStatusMenuItem: MenuItemDouble? = MenuItemDouble()
    weak var asrService: ASRService?
    weak var meetingCoordinator: MeetingSessionCoordinator?
    var cancellables = Set<AnyCancellable>()
    var meetingCancellables = Set<AnyCancellable>()
    var meetingMenuPresentation = MeetingMenuPresentation()
    var meetingStartRequested = false, meetingStopRequested = false
    var meetingStartError: String?
    var stopMeetingRecordingHandler: (() -> Void)?
    var isProcessingActive = false, overlayVisible = false
    var hasDeferredStopMenuRefresh = false, hasDeferredStoppedRecordingState = false
    var menuUpdates = 0, iconUpdates = 0, pendingCancellations = 0
    var presentations: [MeetingMenuPresentation] = []
    init() {
''' + observer + "\n" + paste_observer + r'''
    }
    func configure(asrService: ASRService) {
        self.asrService = asrService
''' + partial + r'''
    }
''' + meeting + "\n" + menu_methods + "\n" + paste_presentation + r'''
    func cancelPendingProcessingCompletionOperations() { pendingCancellations += 1 }
    func updateMenuBarIcon() { iconUpdates += 1 }
    func updateMenu() { menuUpdates += 1; presentations.append(meetingMenuPresentation) }
    func updateMeetingMenuItemsText() { menuUpdates += 1; presentations.append(meetingMenuPresentation) }
    func announceMeetingActivity(_ presentation: MeetingMenuPresentation) {}
    static func interruptionStatus(for session: MeetingSession?) -> String { "interrupted" }
    static func failureStatus(for session: MeetingSession?, failure: MeetingSessionFailure) -> String { failure.message }
}
@MainActor final class DeliveryFailureOverlayController {
    enum Kind { case pasteNotLanded }
    struct Card { let profile: PrivateProfileSnapshot; let text: String }
    static let shared = DeliveryFailureOverlayController()
    var cards: [Card] = []
    func show(kind: Kind, transcript: String) { cards.append(.init(profile: PrivateProfileStorage.current, text: transcript)) }
}
nonisolated final class NSRunningApplication: @unchecked Sendable {
    let bundleIdentifier: String? = "synthetic.verifier.app"
    init?(processIdentifier: Int32) {}
}
nonisolated enum PasteVerifier {
    struct Snapshot: Sendable { let pid: Int32; let summary: String }
    enum Verdict: Sendable { case notLanded, unknown(reason: String); var logDescription: String { "synthetic verdict" } }
    nonisolated(unsafe) static var gate: PasteVerificationGate?
    static func verify(before: Snapshot, pastedText: String) async -> Verdict {
        await gate?.hold()
        return .notLanded
    }
    static func userActedAfterPaste(secondsSinceLastInput: Double, secondsSincePaste: Double) -> Bool { false }
    static func secondsSinceLastUserInput() -> Double { 10 }
}
extension Notification.Name { static let fluidPasteNotLanded = Notification.Name("SyntheticPasteNotLanded") }
@MainActor final class TypingService {
''' + verifier + r'''
}
''' + (ROOT / "Tests/PrivateCaptureFeedbackTests.swift").read_text()
    with tempfile.TemporaryDirectory(prefix="pichi-private-capture-feedback-") as directory:
        temporary = Path(directory)
        subprocess.run(["python3", "-S", "Tests/Support/write_private_profile_standalone_types.py",
                        str(temporary / "ProfileTypes.swift"), "--synthetic-brand"], cwd=ROOT, check=True)
        (temporary / "FeedbackTests.swift").write_text(generated)
        for label, flags in [("default", []), ("main-actor", ["-default-isolation", "MainActor"])]:
            executable = temporary / label
            subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", *flags,
                            "-module-cache-path", str(temporary / "ModuleCache"),
                            str(temporary / "ProfileTypes.swift"), "Sources/Fluid/Account/PrivateProfileStorage.swift",
                            "Sources/Fluid/Account/PrivateProfileOperationOwner.swift", "Sources/Fluid/Account/PrivateProfileService.swift",
                            str(temporary / "FeedbackTests.swift"),
                            "-o", str(executable)], cwd=ROOT, check=True)
            subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=20,
                           env={**os.environ, "PICHI_FEEDBACK_PROFILE_ROOT": str(temporary / ("profiles-" + label))})
    if not args.baseline_ref:
        subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", source_path,
                        "Sources/Fluid/Services/MenuBarManager.swift",
                        "Sources/Fluid/Services/TypingService.swift",
                        "Sources/Fluid/Services/AppServices+MeetingMenuBar.swift"], cwd=ROOT, check=True)
    print("Private capture feedback and menu: 7 source-guard checks passed; actual-buffer, callback and selector regression passed in both isolation modes")


if __name__ == "__main__":
    main()
