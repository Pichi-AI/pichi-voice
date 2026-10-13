#!/usr/bin/env python3
"""Exercise the production meeting backup handlers without hardware or app defaults."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Sources/Fluid/UI/MeetingTranscriptionView.swift"


def declaration(source: str, marker: str) -> str:
    start = source.index(marker)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-ref", help="Optional pre-fix git ref for reproduction checks")
    args = parser.parse_args()
    developer_dir = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(
        ["xcode-select", "-p"], text=True, timeout=10
    ).strip()
    if not ("Xcode" in developer_dir and developer_dir.endswith(".app/Contents/Developer")):
        raise SystemExit("Set DEVELOPER_DIR to a full installed Xcode before running tests.")
    env = {**os.environ, "DEVELOPER_DIR": developer_dir}
    source = SOURCE.read_text()
    baseline = None
    if args.baseline_ref:
        baseline = subprocess.check_output(
            ["git", "show", f"{args.baseline_ref}:Sources/Fluid/UI/MeetingTranscriptionView.swift"],
            cwd=ROOT, text=True, timeout=10,
        )
        assert "settingsBackupDidRestore" not in baseline
    assert "self.appDetailContent\n" in (ROOT / "Sources/Fluid/ContentView.swift").read_text()
    assert ".onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore))" in source
    assert ".onChange(of: self.canRefreshSetupAfterBackupRestore)" in source
    mode_observer = declaration(source, ".onChange(of: self.setupDraft.mode)")
    assert "Task { await self.refreshSources(requestPermissions: false) }" in mode_observer
    for action in ("cancelMeetingSettings", "saveMeetingSettings"):
        body = declaration(source, f"private func {action}()")
        assert body.split("{", 1)[1].strip().startswith(
            "if self.finishRestoredMeetingSettingsIfPending() { return }"
        ), f"{action} must reject stale sheet writes before validation or source refresh"

    draft = declaration(source, "struct MeetingTranscriptionSetupDraft:")
    if baseline is not None:
        assert draft == declaration(baseline, "struct MeetingTranscriptionSetupDraft:")
    members = "\n".join(declaration(source, marker) for marker in (
        "private var canRefreshSetupAfterBackupRestore:",
        "private func applyPendingBackupSetupRefresh()",
        "private func finishRestoredMeetingSettingsIfPending()",
    ))
    # Use the compiled provider's actual metadata/default policy, without importing
    # inference adapters or making model installation queries in this UI probe.
    factory_source = (ROOT / "Sources/Fluid/Services/Meeting/PichiMeetingProviderFactory.swift").read_text()
    factory = factory_source[factory_source.index("enum PichiMeetingProviderFactory {"):
                             factory_source.index("    static func validateRecordingConfiguration(")] + "}\n"
    for field in ("providerFactory", "configurationSnapshot", "modelsExistOnDisk"):
        factory = "\n".join(line for line in factory.splitlines()
                            if not line.strip().startswith(f"let {field}:"))
        clause = declaration(factory, f"{field}: {{")
        factory = factory.replace(clause + ",", "").replace(clause, "")
    factory = factory.replace(declaration(factory, "    nonisolated static func registeredModelsExistOnDisk("), "")
    factory += "\n" + declaration(factory_source, "extension MeetingBackendID {") + "\n"
    backend_source = (ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingTranscriptionBackend.swift").read_text()
    metadata = "\n".join(declaration(backend_source, marker) for marker in (
        "nonisolated struct MeetingBackendID:",
        "nonisolated enum MeetingBackendExecutionLocality:",
        "nonisolated enum MeetingBackendResultContract:",
        "nonisolated struct MeetingBackendDescriptor:",
    ))
    metadata += "\n" + declaration((ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text(),
                                   "nonisolated enum MeetingAudioTrackKind:")
    metadata += "\n" + declaration((ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift").read_text(),
                                   "nonisolated enum MeetingTextUnitPrecision:") + "\n"
    swift = r'''
import Foundation
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    func string(forKey key: String) -> String? { nil }
    func set(_ value: Any?, forKey key: String) { fatalError("Unexpected preference write") }
}

enum MeetingCaptureMode { case onlineCall, inRoom }
struct Defaults { var languageCode: String? = "en"; var mode: MeetingCaptureMode = .onlineCall }
final class SettingsStore {
    static let shared = SettingsStore()
    struct SpeechModel { let rawValue: String }
    var selectedSpeechModel = SpeechModel(rawValue: PichiMeetingProviderFactory.gigaamModelID)
    var meetingRecordingDefaults = Defaults()
    var meetingAutoDetectEnabled = true
    var meetingAutoDetectBrowserEnabled = true
    var meetingAudioRetentionPolicy = 7
}
struct Identity { let id: String }
struct Option { let identity: Identity }
final class Coordinator { var isQuiescent = true; var activeLanguage = "en" }
''' + metadata + factory + draft + r'''
final class Harness {
    let coordinator = Coordinator()
    var setupDraft = MeetingTranscriptionSetupDraft()
    var setupDraftBeforeEditing = MeetingTranscriptionSetupDraft()
    var pendingBackupSetupRefresh = false
    var cachedSystemDefaultMicrophoneUID: String? = "cached-mic"
    var isStarting = false, isStopping = false, isRetrying = false
    var isRefreshingSources = false, isShowingMeetingSettings = false
    var microphones = [Option(identity: Identity(id: "cached-mic"))]
    var applications = [Option(identity: Identity(id: "cached-app"))]
    var draftMeetingAudioRetentionPolicy = 7
    var selectedIdentities = 0
    var persistedWrites = 0
    var hardwareQueries = 0
    func selectPreferredMicrophone(from identities: [Identity], systemDefaultUID: String?) {
        selectedIdentities += 1
        setupDraft.selectedMicrophoneID = identities.first(where: { $0.id == systemDefaultUID })?.id
    }
    func selectPreferredApplication(from identities: [Identity]) {
        selectedIdentities += 1
        setupDraft.selectedApplicationID = identities.first?.id
    }
    func regenerateDefaultTitleIfNeeded() {
        if !setupDraft.titleWasEdited {
            setupDraft.title = MeetingTranscriptionSetupDraft.defaultTitle(mode: setupDraft.mode, applicationDisplayName: nil)
        }
    }
''' + members + r'''
    func notifyRestore() { pendingBackupSetupRefresh = true; applyPendingBackupSetupRefresh() }
    func reachSafePoint() { if canRefreshSetupAfterBackupRestore { applyPendingBackupSetupRefresh() } }
    func closeSheetSaving() {
        if finishRestoredMeetingSettingsIfPending() { return }
        persistedWrites += 1
    }
    func closeSheetCancelling() {
        if finishRestoredMeetingSettingsIfPending() { return }
        hardwareQueries += 1
    }
    func expect(_ ok: Bool, _ message: String) { check(ok, message) }
}
var assertions = 0
func check(_ ok: Bool, _ message: String) {
    assertions += 1
    if !ok { fatalError(message) }
}
func restored(_ language: String = "fr", _ mode: MeetingCaptureMode = .inRoom) {
    SettingsStore.shared.meetingRecordingDefaults = Defaults(languageCode: language, mode: mode)
}
func fresh() -> Harness {
    restored("en", .onlineCall)
    SettingsStore.shared.meetingAutoDetectEnabled = true
    SettingsStore.shared.meetingAutoDetectBrowserEnabled = true
    SettingsStore.shared.meetingAudioRetentionPolicy = 7
    SettingsStore.shared.selectedSpeechModel = .init(rawValue: PichiMeetingProviderFactory.gigaamModelID)
    return Harness()
}
@main enum Tests {
 static func main() {
    // Reproduce pre-fix: real production draft is a value snapshot, not a settings binding.
    let baseline = fresh()
    restored()
    check(baseline.setupDraft.languageCode == "en" && baseline.setupDraft.mode == .onlineCall,
          "baseline hidden page keeps stale language/mode after defaults import")
    print("PASS: setup draft is a snapshot; restore notification must refresh it")
    baseline.notifyRestore()
    check(baseline.setupDraft.languageCode == "fr" && baseline.setupDraft.mode == .inRoom, "idle restore refreshes language/mode")
    check(baseline.setupDraftBeforeEditing == baseline.setupDraft, "cancel snapshot follows restored setup")
    check(baseline.hardwareQueries == 0 && baseline.persistedWrites == 0, "restore handler performs neither synchronous source queries nor persistence")
    check(baseline.setupDraft.selectedMicrophoneID == "cached-mic" && baseline.setupDraft.selectedApplicationID == "cached-app", "cached identities populate restored setup")
    check(baseline.coordinator.activeLanguage == "en", "active capture configuration is never rewritten")

    for blocker in 0..<6 {
        let h = fresh()
        switch blocker {
        case 0: h.coordinator.isQuiescent = false
        case 1: h.isStarting = true
        case 2: h.isStopping = true
        case 3: h.isRetrying = true
        case 4: h.isRefreshingSources = true
        default: h.isShowingMeetingSettings = true
        }
        h.setupDraft.title = "User's meeting"; h.setupDraft.titleWasEdited = true
        restored(); h.notifyRestore()
        check(h.pendingBackupSetupRefresh && h.setupDraft.languageCode == "en", "busy/editing restore defers \(blocker)")
        check(h.selectedIdentities == 0 && h.persistedWrites == 0, "deferral has no effects \(blocker)")
        restored("de", .onlineCall); h.notifyRestore()
        check(h.setupDraft.title == "User's meeting", "repeated restore preserves active edited input \(blocker)")
        h.coordinator.isQuiescent = true; h.isStarting = false; h.isStopping = false
        h.isRetrying = false; h.isRefreshingSources = false; h.isShowingMeetingSettings = false
        h.reachSafePoint()
        check(!h.pendingBackupSetupRefresh && h.setupDraft.languageCode == "de", "success/failure/close uses latest coalesced restore \(blocker)")
        check(h.setupDraft.title == "User's meeting" && h.setupDraft.titleWasEdited, "custom title survives refresh \(blocker)")
        let identityCount = h.selectedIdentities
        h.reachSafePoint()
        check(h.selectedIdentities == identityCount, "safe-point events do not replay completed restore \(blocker)")
    }
    for save in [false, true] {
        let h = fresh(); h.isShowingMeetingSettings = true
        restored(); h.notifyRestore()
        if save { h.closeSheetSaving() } else { h.closeSheetCancelling() }
        check(!h.isShowingMeetingSettings && h.setupDraft.languageCode == "fr", "sheet close consumes deferred restore")
        check(h.persistedWrites == 0 && h.hardwareQueries == 0, "stale Save/Cancel cannot overwrite imported preferences or query sources")
    }
    let busySheet = fresh(); busySheet.isShowingMeetingSettings = true; busySheet.coordinator.isQuiescent = false
    restored(); busySheet.notifyRestore(); busySheet.closeSheetSaving()
    check(busySheet.pendingBackupSetupRefresh && busySheet.setupDraft.languageCode == "en", "closing edited sheet does not change busy capture setup")
    busySheet.coordinator.isQuiescent = true; busySheet.reachSafePoint()
    check(busySheet.setupDraft.languageCode == "fr" && busySheet.persistedWrites == 0, "capture failure/completion later applies pending sheet restore without writes")

    let rapid = fresh()
    restored(); rapid.notifyRestore()
    restored("de", .onlineCall); rapid.notifyRestore()
    check(rapid.setupDraft.languageCode == "de" && rapid.setupDraft.mode == .onlineCall, "rapid change-back restore keeps latest values")
    restored("fr", .inRoom); rapid.notifyRestore(); restored("de", .inRoom); rapid.notifyRestore()
    check(rapid.setupDraft.languageCode == "de" && !rapid.pendingBackupSetupRefresh, "same-mode repeated restores consume latest language without stale pending state")
    let legacy = fresh(); SettingsStore.shared.meetingRecordingDefaults.languageCode = nil
    legacy.notifyRestore()
    check(legacy.setupDraft.languageCode == PichiMeetingProviderFactory.defaultLanguageCode(for: SettingsStore.shared.selectedSpeechModel.rawValue)
          && legacy.hardwareQueries == 0, "legacy language uses selected provider metadata without source discovery")
    SettingsStore.shared.meetingRecordingDefaults.languageCode = "de"
    legacy.notifyRestore()
    check(legacy.setupDraft.languageCode == "de", "explicit restored language takes precedence over selected provider metadata")
    let missing = fresh(); missing.microphones = []; missing.applications = []
    restored(); missing.notifyRestore()
    check(missing.setupDraft.selectedMicrophoneID == nil && missing.setupDraft.selectedApplicationID == nil, "missing cached sources stay unselected")
    check(missing.hardwareQueries == 0 && !missing.pendingBackupSetupRefresh, "missing sources do not create a permanent pending restore")
    print("PASS: \(assertions) production-handler assertions")
 }
}
'''
    with tempfile.TemporaryDirectory(prefix="fluidvoice-meeting-backup-") as directory:
        directory = Path(directory)
        swift_file = directory / "Tests.swift"
        swift_file.write_text(swift)
        executable = directory / "tests"
        subprocess.run(["xcrun", "swiftc", "-parse-as-library",
                        str(ROOT / "Sources/Fluid/Localization/PichiLocalization.swift"),
                        str(swift_file), "-o", str(executable)],
                       env=env, check=True, timeout=60)
        subprocess.run([str(executable)], env=env, check=True, timeout=15)


if __name__ == "__main__":
    main()
