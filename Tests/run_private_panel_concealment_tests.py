#!/usr/bin/env python3
"""Execute actual panel conceal/observer/admission bodies with UI-free recording doubles.

No NSApplication, windows, capture, inference, preferences, credentials or HTTP are used.
Full native compilation and native pixel review remain separate acceptance gates.
"""
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
    parser.add_argument("--baseline-ref", help="Negative control against the unguarded source")
    args = parser.parse_args()
    paths = ["Sources/Fluid/UI/MeetingRecordingPill.swift",
             "Sources/Fluid/UI/MeetingFloatingCaptionsPanel.swift",
             "Sources/Fluid/UI/MeetingDetectionPrompt.swift",
             "Sources/Fluid/Views/DeliveryFailureOverlay.swift"]
    sources = {}
    for path in paths:
        sources[path] = (subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=ROOT, text=True)
                         if args.baseline_ref else (ROOT / path).read_text())
    classes = [declaration(sources[paths[index]], "final class " + name)
               for index, name in [(0, "MeetingRecordingPillController:"), (1, "MeetingFloatingCaptionsController:"),
                                   (2, "MeetingDetectionPromptController:"), (2, "MeetingStillRecordingNudgeController:"),
                                   (3, "DeliveryFailureOverlayController {")]]
    entries = ["private func show(coordinator:", "func show(from sourceFrame:", "func present(_ request:",
               "func present(sessionID:", "func show(kind:"]
    checks = 0

    def require(value, label):
        nonlocal checks
        assert value, label
        checks += 1

    output = ["import Foundation\nimport Combine\n"]
    output.append('''@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    static let willConceal = Notification.Name("SyntheticConceal")
    var isPrivateDataVisible = true
    func register(_ participant: AnyObject) {}
}
struct PromptRequest { let episodeID = UUID(); let cta = "record" }
struct DebugLogger { static let shared = Self(); func log(_ value: String, source: String) {} }
@MainActor final class PanelDouble {
    var contentView: String? = "private pixels"; var isVisible = true
    func orderOut(_ sender: Any?) { isVisible = false }
}
''')
    for index, (source, entry) in enumerate(zip(classes, entries)):
        init = (source[source.index("    init(now:"):source.index("\n    private var canPresentCurrentProfile:", source.index("    init(now:"))]
                if index == 3 else declaration(source, "private init()"))
        conceal = declaration(source, "private func concealPrivatePresentation()")
        require("publisher(for: PrivateProfileService.willConceal)" in init and "MainActor.assumeIsolated" in init,
                f"{index}: observer executes synchronously on the common lifecycle actor")
        require("Task {" not in init and ".receive(on:" not in init, f"{index}: no deferred concealment")
        require("self.panel?.contentView = nil" in conceal and "self.panel = nil" in conceal,
                f"{index}: release old private view tree")
        require(all(token not in conceal for token in ["stopAndTranscribe", "stopRecording", "asr.", "startTask?.cancel"]),
                f"{index}: conceal leaves admitted capture and start ownership intact")
        body = declaration(source, entry)
        require("guard PrivateProfileStorage.acceptsNewWork" in body, f"{index}: concrete entry point admission")
        prefix = body[body.index("guard PrivateProfileStorage.acceptsNewWork"):]
        # Reuse the exact guard statement, including its real concealment side effect.
        guard_end = prefix.index("}") + 1
        guard_body = prefix[:guard_end]
        if index == 4:
            guard_body = "let profile = PrivateProfileStorage.current\n" + guard_body
        output.append(f"@MainActor final class Probe{index} {{\n")
        output.append('''var profileSubscription: AnyCancellable?; var stateSubscription: AnyCancellable?
var panel: PanelDouble? = PanelDouble(); var hostingView: String? = "private"; var generation: UInt64 = 0
var dismissTask: Task<Void, Never>?; var startTask: Task<Void, Never>?; var autoDismissTask: Task<Void, Never>?
var suppressionRetryTask: Task<Void, Never>?; var autoDismissLegStartedAt: Date?; var remainingAutoDismissSeconds: TimeInterval = 10
var isAutoDismissPaused = true; var pendingSuppressedRequest: String? = "private app"
var request: PromptRequest? = PromptRequest(); var appIcon: String? = "private icon"; var appDisplayName = "private app"
var startErrorMessage: String? = "private failure"; var isStarting = true; var hasLoggedCurrentSuppression = true
var presentationProfile: PrivateProfileSnapshot?; var visibleAnchor: Int? = 1; var windowMoveObserver: NSObjectProtocol?
var isPresented = true; var reopens = 0
''')
        if index == 3:
            output.append('''var countdown = MeetingEndCountdown()
var countdownTask: Task<Void, Never>?
var countdownTasks: [UUID: Task<Void, Never>] = [:]
let now: () -> TimeInterval
''')
            output.append(declaration(source, "private var canPresentCurrentProfile:").replace("private ", "", 1))
            output.append(declaration(source, "func prepareForPrivateProfileTransition()"))
        output.append(init.replace("private ", "", 1))
        output.append(conceal.replace("private ", "", 1))
        if index == 2:
            output.append(declaration(source, "private var canPresentCurrentProfile:").replace("private ", "", 1))
            output.append(declaration(source, "private func cancelSuppressionRetry()").replace("private ", "", 1))
            output.append(declaration(source, "private func clearAutoDismiss()").replace("private ", "", 1))
            output.append(declaration(source, "func startTapped()"))
            output.append(declaration(source, "private func hide()").replace("private ", "", 1))
            output.append(declaration(source, "func pauseAutoDismiss()"))
            output.append(declaration(source, "static func remainingAutoDismissSeconds("))
            output.append("""
var onStart: ((UUID) async throws -> Void)?; var onSetup: ((UUID) -> Void)?
enum PrimaryAction { case startRecording }
static func primaryAction(for cta: String) -> PrimaryAction { .startRecording }
static func startErrorMessage(from error: Error, appDisplayName: String) -> String { "private failure" }
func isPointerInsidePanel() -> Bool { false }
func resumeAutoDismiss() {}
""")
        if index in [1, 3]:
            output.append(declaration(source, "func hide()"))
        if index == 0:
            hide = declaration(source, "private func hideOverlay()")
            require("self.panel?.orderOut(nil)" in hide and "MeetingFloatingCaptionsController.shared.hide()" in hide,
                    "pill hides both live surfaces")
            output.append("func hideOverlay() { panel?.orderOut(nil) }")
        output.append("func attemptReopen() {\n" + guard_body + "\nreopens += 1\n}\n}\n")
    prompt = classes[2]
    for marker in ["func startTapped()", "private func scheduleSuppressionRetry()", "private func finishSuppressionEvaluation(",
                   "private func scheduleAutoDismiss(for"]:
        body = declaration(prompt, marker)
        require("let profile = self.presentationProfile" in body and "PrivateProfileStorage.isReadable(profile)" in body,
                marker + ": asynchronous result is bound to the original profile generation")
    for index, marker in [(0, "func activate(coordinator:"), (1, "private func subscribeIfNeeded(coordinator:")]:
        require("coordinator.state" in declaration(classes[index], marker), "queued coordinator event reads current state")
    require("self.hostingView = nil" in declaration(classes[4], "private func concealPrivatePresentation()"),
            "delivery card releases transcript-hosting view")
    copy = declaration(sources[paths[3]], "private func copy()")
    require(copy.index("PrivateProfileStorage.isReadable(self.profile)") < copy.index("ClipboardService.copyToClipboard"),
            "stale delivery card callback cannot copy another profile's transcript")
    output.append((ROOT / "Tests/PrivatePanelConcealmentTests.swift").read_text())
    with tempfile.TemporaryDirectory(prefix="pichi-private-panels-") as directory:
        temporary = Path(directory)
        subprocess.run(["python3", "Tests/Support/write_private_profile_standalone_types.py",
                        str(temporary / "ProfileTypes.swift"), "--synthetic-brand"], cwd=ROOT, check=True)
        generated = temporary / "PanelBodies.swift"
        generated.write_text("\n".join(output))
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-default-isolation", "MainActor",
                        "-module-cache-path", str(temporary / "ModuleCache"), str(temporary / "ProfileTypes.swift"),
                        "Sources/Fluid/Account/PrivateProfileStorage.swift", "Sources/Fluid/Services/Meeting/MeetingEndCountdown.swift",
                        str(generated), "-o", str(temporary / "tests")],
                       cwd=ROOT, check=True)
        subprocess.run([str(temporary / "tests")], cwd=ROOT, check=True)
    if not args.baseline_ref:
        subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", *paths], cwd=ROOT, check=True)
    print(f"Private panel source guards: {checks} checks passed; actual source methods use UI-free doubles")


if __name__ == "__main__":
    main()
