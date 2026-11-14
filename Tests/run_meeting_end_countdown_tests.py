#!/usr/bin/env python3
"""Run the real countdown, controller, detector and session gate without capture or app defaults."""
import os
from pathlib import Path
import subprocess
import tempfile
from Standalone.ProbeContractDependencies import declaration, communication_metadata

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Full Xcode is required; set DEVELOPER_DIR to an installed Xcode.app.")
    env = dict(os.environ, DEVELOPER_DIR=developer)
    with tempfile.TemporaryDirectory(prefix="fluidvoice-meeting-end-") as directory:
        work = Path(directory)
        signals = (ROOT / "Sources/Fluid/Services/Meeting/MeetingAutoDetectSignals.swift").read_text().split("// MARK: - Live implementations")[0]
        (work / "Signals.swift").write_text(signals)
        fixtures = (ROOT / "Tests/FluidDictationIntegrationTests/MeetingAutoDetectorTests.swift").read_text().split("@MainActor\nfinal class MeetingAutoDetectorTests")[0]
        fixtures = fixtures.replace("@testable import FluidVoice_Debug\n", "").replace("import XCTest\n", "").replace("private final class", "final class")
        (work / "Fixtures.swift").write_text(fixtures)
        ui = (ROOT / "Sources/Fluid/UI/MeetingDetectionPrompt.swift").read_text()
        controller = declaration(ui, "final class MeetingStillRecordingNudgeController")
        layout = declaration(ui, "enum MeetingPromptLayout")
        (work / "Controller.swift").write_text("import AppKit\nimport Combine\nimport SwiftUI\n" + layout + "\n@MainActor\n" + controller)
        services = (ROOT / "Sources/Fluid/Services/AppServices.swift").read_text()
        callback = declaration(services, "detector.onAutomaticTargetChanged =")
        gate = declaration(services, "static func recordingSessionID(") + "\n" + declaration(services, "static func meetingEndWatchApplication(") + "\n" + declaration(services, "static func synchronizeMeetingEndWatch(")
        can_stop = declaration(services, "private func canStopMeetingAfterEndConfirmation(").replace("private func", "func", 1)
        stop = declaration(services, "private func stopMeetingAfterEndConfirmation(").replace("private func", "func", 1)
        (work / "SessionGate.swift").write_text(
            "import Foundation\n@MainActor final class AppServices {\n"
            "var _meetingSessionCoordinator: MeetingSessionCoordinator?\n"
            "var _meetingAutoDetector: MeetingAutoDetector?\n"
            "var meetingAutomaticTarget: MeetingAutoDetector.ResolvedTarget?\n"
            "func wireTarget(_ detector: MeetingAutoDetector) {\n" + callback + "\n}\n" + gate + "\n" + can_stop + "\n" + stop + "\n}\n"
        )
        # Build the actual data-only observation module with swiftc, without SPM.
        observation = work / "PichiCallObservation.o"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-emit-module", "-emit-object",
                        "-module-name", "PichiCallObservation", "-emit-module-path", str(work / "PichiCallObservation.swiftmodule"),
                        str(ROOT / "Vendor/PichiCallObservation/Sources/PichiCallObservation/CommunicationObservation.swift"),
                        "-o", str(observation)], check=True, env=env, timeout=60)
        profile_types = work / "ProfileTypes.swift"
        subprocess.run(["python3", "Tests/Support/write_private_profile_standalone_types.py",
                        str(profile_types), "--synthetic-brand"], cwd=ROOT, env=env, check=True, timeout=15)
        profile_service = (ROOT / "Sources/Fluid/Account/PrivateProfileService.swift").read_text()
        (work / "ProfileService.swift").write_text("import Foundation\n" +
            declaration(profile_service, "@MainActor protocol PrivateProfileTransitionParticipant:") +
            "\n@MainActor final class PrivateProfileService {\nstatic let shared = PrivateProfileService()\n"
            "static let willConceal = Notification.Name(\"ProbePrivateProfileWillConceal\")\n"
            "var isPrivateDataVisible = true\nfunc register(_ participant: any PrivateProfileTransitionParticipant) {}\n}\n")
        tests = (ROOT / "Tests/MeetingEndCountdownTests.swift").read_text()
        models = (ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text()
        tests = tests.replace(declaration(tests, "struct MeetingApplicationIdentity {"), declaration(models, "nonisolated struct MeetingApplicationIdentity:"))
        tests = tests.replace(declaration(tests, "    enum Mode {"), "    typealias Mode = MeetingCaptureMode")
        tests += "\n" + declaration(models, "nonisolated enum MeetingCaptureMode:") + "\n"
        tests += "\n" + declaration(models, "nonisolated enum MeetingApplicationAudioScope:") + "\n"
        session = declaration(models, "nonisolated struct MeetingSession:")
        tests += "\nextension MeetingSession {\n" + declaration(session, "    var effectiveApplicationAudioScope:") + "\n}\n"
        # Fixture convenience initializes the actual production optional consent field.
        tests += "\nextension MeetingApplicationIdentity {\ninit(bundleIdentifier: String, processID: Int32?, displayName: String, capturesAllInstances: Bool) {\nself.init(bundleIdentifier: bundleIdentifier, processID: processID, displayName: displayName)\nself.capturesAllInstances = capturesAllInstances\n}\n}\n"
        tests = tests.replace("@MainActor final class MeetingFloatingCaptionsPanel {", "@MainActor final class MeetingFloatingCaptionsPanel {\n    var contentView: NSView?")
        (work / "Tests.swift").write_text(tests)
        (work / "Modules.swift").write_text(communication_metadata())
        sources = [
            work / "Modules.swift",
            observation, profile_types, work / "ProfileService.swift",
            ROOT / "Sources/Fluid/Account/PrivateProfileStorage.swift",
            ROOT / "Sources/Fluid/Localization/PichiLocalization.swift",
            ROOT / "Sources/Fluid/Services/Meeting/MeetingEndCountdown.swift",
            ROOT / "Sources/Fluid/Services/Meeting/MeetingAutoDetector.swift",
            ROOT / "Sources/Fluid/Services/Meeting/MeetingAppRegistry.swift",
            ROOT / "Sources/Fluid/Services/Meeting/MeetingBrowserCallEvidence.swift",
            work / "Signals.swift", work / "Fixtures.swift", work / "Controller.swift", work / "SessionGate.swift",
            work / "Tests.swift",
        ]
        executable = work / "tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-I", str(work), *map(str, sources), "-o", str(executable)], check=True, env=env)
        subprocess.run([str(executable)], check=True, env=env)


if __name__ == "__main__":
    main()
