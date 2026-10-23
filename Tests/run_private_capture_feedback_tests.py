#!/usr/bin/env python3
"""Run actual capture presentation callbacks and stream buffer with UI-free doubles."""
import argparse
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
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    static let willConceal = Notification.Name("SyntheticPrivateConceal")
    func register(_ participant: any PrivateProfileTransitionParticipant) {}
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
    func debug(_ text: String, source: String) {}
    func error(_ text: String, source: String) {}
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
    func stopAndTranscribe() async throws { stops += 1 }
}
@MainActor final class ASRService {
    @Published var partialTranscription = ""
}
@MainActor final class AppServices {
    static let shared = AppServices()
    var starts = 0
    func startMeetingRecordingFromMenuBar() async throws { starts += 1 }
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
''' + observer + r'''
    }
    func configure(asrService: ASRService) {
        self.asrService = asrService
''' + partial + r'''
    }
''' + meeting + "\n" + menu_methods + r'''
    func cancelPendingProcessingCompletionOperations() { pendingCancellations += 1 }
    func updateMenuBarIcon() { iconUpdates += 1 }
    func updateMenu() { menuUpdates += 1; presentations.append(meetingMenuPresentation) }
    func updateMeetingMenuItemsText() { menuUpdates += 1; presentations.append(meetingMenuPresentation) }
    func announceMeetingActivity(_ presentation: MeetingMenuPresentation) {}
    static func interruptionStatus(for session: MeetingSession?) -> String { "interrupted" }
    static func failureStatus(for session: MeetingSession?, failure: MeetingSessionFailure) -> String { failure.message }
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
                            "Sources/Fluid/Account/PrivateProfileOperationOwner.swift", str(temporary / "FeedbackTests.swift"),
                            "-o", str(executable)], cwd=ROOT, check=True)
            subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=20)
    if not args.baseline_ref:
        subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", source_path,
                        "Sources/Fluid/Services/MenuBarManager.swift"], cwd=ROOT, check=True)
    print("Private capture feedback and menu: 4 source-guard checks passed; actual-buffer, callback and selector regression passed in both isolation modes")


if __name__ == "__main__":
    main()
