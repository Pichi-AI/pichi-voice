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
    generated = "import Foundation\n" + buffer + "\n@MainActor\n" + schedule + "\n" + r'''
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
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
    func updateTranscriptionText(_ text: String) {
        // Same current-scope-only admission as the production Notch entry point.
        guard PrivateProfileStorage.current.isReadable else { return }
        events.append(.init(profile: PrivateProfileStorage.current, text: text))
    }
}
@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    func debug(_ text: String, source: String) {}
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
''' + callbacks + "\n}\n" + (ROOT / "Tests/PrivateCaptureFeedbackTests.swift").read_text()
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
        subprocess.run(["xcrun", "swiftc", "-frontend", "-parse", source_path], cwd=ROOT, check=True)
    print("Private capture feedback actual-buffer and callback regression passed in both isolation modes")


if __name__ == "__main__":
    main()
