#!/usr/bin/env python3
"""Exercise actual post-commit restoration and summary-entry admission without app effects.

Summary entry prefixes stop at the first mutating statement, replacing only the
downstream effects with counters. This verifies admission, not model execution.
"""
import argparse
import os
from pathlib import Path
import signal
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


def run(argv, *, env=None):
    process = subprocess.Popen(argv, cwd=ROOT, env=env, start_new_session=True)
    try:
        result = process.wait(timeout=60)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        raise
    if result:
        raise subprocess.CalledProcessError(result, argv)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref")
    parser.add_argument("--only", choices=["activation", "summary", "all"], default="all")
    args = parser.parse_args()

    def source(path):
        if args.baseline_ref:
            return subprocess.check_output(["git", "show", f"{args.baseline_ref}:{path}"], cwd=ROOT, text=True)
        return (ROOT / path).read_text()

    app = source("Sources/Fluid/Services/AppServices.swift")
    summary = source("Sources/Fluid/Services/Meeting/MeetingSummaryController.swift")
    restoration = declaration(app, "    func restorePrivateSourcesAfterCommit()")
    profile = next(line for line in summary.splitlines() if line.strip() == "private let privateProfile = PrivateProfileStorage.current") + "\n"
    # Preserve each actual method signature and its admission statements unchanged.
    # The heavy effect is recorded only once the production admission has passed.
    prefixes = []
    for marker, first_effect in [
        ("    func download()", "        self.downloading = true"),
        ("    func deleteModel(asr:", "        self.generation = UUID()"),
        ("    func summarize(session:", "        self.generating = true"),
        ("    func summarizeOnDevice(", "        self.generating = true"),
    ]:
        body = declaration(summary, marker)
        prefix = body[:body.index(first_effect)]
        prefix += "        self.admittedEffects += 1\n"
        if "let selectionLock" in prefix:
            prefix += "        MeetingSummaryActivityCoordinator.shared.unlockSelection(selectionLock)\n"
        prefix += "    }\n"
        prefixes.append(prefix)

    generated = ("import Foundation\n" + r'''
@MainActor final class Gate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { continuation?.resume(); continuation = nil }
}
@MainActor final class CoordinatorDouble {
    var restores = 0
    var gate: Gate?
    func ensureRestored() async { restores += 1; await gate?.hold() }
}
@MainActor final class CloudDouble {
    var activations = 0
    var gate: Gate?
    func activateAfterAccountCommand() async { activations += 1; await gate?.hold() }
}
@MainActor final class LocalAPIServer {
    static let shared = LocalAPIServer()
    var starts = 0
    func start() { starts += 1 }
}
@MainActor final class RestorationProbe {
    var isTerminating = false
    var isUIReady = true
    var featureEnabled = true
    var availabilityReconciliations = 0
    var detectorStarts = 0
    var _meetingSessionCoordinator: CoordinatorDouble? = CoordinatorDouble()
    var _cloudPublicationActivation: CloudDouble? = CloudDouble()
    func refreshFluidMeetAvailability() {
        availabilityReconciliations += 1
        if isUIReady && featureEnabled && PrivateProfileStorage.acceptsNewWork {
            detectorStarts += 1
        }
    }
''' + restoration + r'''
}
struct MeetingSession {}
enum MeetingSummaryKind { case executive }
struct MeetingSummaryRoute {}
struct SyntheticModel {}
@MainActor final class ASRService {}
@MainActor final class MeetingSummaryActivityCoordinator {
    static let shared = MeetingSummaryActivityCoordinator()
    var selectionLocks = 0
    func lockSelection() -> UUID? { selectionLocks += 1; return UUID() }
    func unlockSelection(_ token: UUID) {}
}
@MainActor final class SummaryAdmissionProbe {
''' + profile + r'''
    var busy = false
    var checking = false
    var installed = true
    var model: SyntheticModel? = SyntheticModel()
    var admittedEffects = 0
''' + "\n".join(prefixes) + "}\n" + (ROOT / "Tests/PrivateProfileActivationSummaryTests.swift").read_text())

    with tempfile.TemporaryDirectory(prefix="pichi-profile-activation-summary-") as directory:
        temporary = Path(directory)
        run(["python3", "-S", "Tests/Support/write_private_profile_standalone_types.py",
             str(temporary / "ProfileTypes.swift"), "--synthetic-brand"])
        (temporary / "Tests.swift").write_text(generated)
        for label, flags in [("default", []), ("main-actor", ["-default-isolation", "MainActor"])]:
            executable = temporary / label
            run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", *flags,
                 "-module-cache-path", str(temporary / "ModuleCache"),
                 str(temporary / "ProfileTypes.swift"), "Sources/Fluid/Account/PrivateProfileStorage.swift",
                 str(temporary / "Tests.swift"), "-o", str(executable)])
            run([str(executable)], env={**os.environ, "PICHI_PROFILE_LIFECYCLE_ONLY": args.only,
                                       "PICHI_PROFILE_LIFECYCLE_ROOT": str(temporary / "profiles")})


if __name__ == "__main__":
    main()
