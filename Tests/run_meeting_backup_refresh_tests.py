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


def array_literal(source: str, marker: str) -> str:
    start = source.index("[", source.index(marker) + len(marker))
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "[") - (source[end] == "]")
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
    for field in ("providerFactory", "configurationSnapshot", "modelsExistOnDisk", "admissionArtifactFingerprint"):
        factory = "\n".join(line for line in factory.splitlines()
                            if not line.strip().startswith(f"let {field}:"))
        while f"{field}: {{" in factory:
            clause = declaration(factory, f"{field}: {{")
            factory = factory.replace(clause + ",", "").replace(clause, "")
    factory = factory.replace(declaration(factory, "    static func registeredModelsExistOnDisk("), "")
    # Strict PCM/device admission is not consulted by these backup UI handlers.
    # Omit its stored restriction payload as well as its callbacks, rather than
    # introducing fake artifact identities, display names or admission validators.
    while "pcmAdmissionRestrictions:" in factory:
        clause = "pcmAdmissionRestrictions: " + array_literal(factory, "pcmAdmissionRestrictions:")
        factory = factory.replace(clause + ",", "").replace(clause, "")
    factory += "\n" + declaration(factory_source, "extension MeetingBackendID {") + "\n"
    backend_source = (ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingTranscriptionBackend.swift").read_text()
    metadata = "\n".join(declaration(backend_source, marker) for marker in (
        "nonisolated struct MeetingBackendID:",
        "nonisolated enum MeetingBackendExecutionLocality:",
        "nonisolated enum MeetingBackendResultContract:",
        "nonisolated enum MeetingDiarizationDependency:",
        "nonisolated enum MeetingBackendInputKind:",
        "nonisolated struct MeetingPCMObservationPolicy:",
        "nonisolated struct MeetingBackendDescriptor:",
    ))
    # PCM admission is exercised by the native backend tests, not these UI handlers.
    # Keep UI metadata fields/initializer; omit strict-PCM payload and validators below.
    for marker in ("    func validatePCMInput(configuration:", "    func validatePCMInput(_ request:"):
        while marker in metadata:
            metadata = metadata.replace(declaration(metadata, marker), "")
    metadata = "\n".join(line for line in metadata.splitlines() if not any(
        fragment in line for fragment in (
            "let pcmAdmissionRestrictions:", "pcmAdmissionRestrictions: [MeetingPCMAdmissionRestriction]",
            "self.pcmAdmissionRestrictions =",
        )
    ))
    language_source = (ROOT / "Sources/Fluid/Persistence/VoiceEngineLanguageCatalog.swift").read_text()
    whisper_marker = "    nonisolated static let whisperSupportedLanguageCodes: Set<String> = "
    whisper_languages = array_literal(language_source, whisper_marker)
    parakeet_source = (ROOT / "Sources/Fluid/Services/ParakeetSpeechModelCatalog.swift").read_text()
    parakeet_v3 = parakeet_source[parakeet_source.index("    static let v3 = Descriptor("):]
    parakeet_languages = array_literal(parakeet_v3, "supportedLanguageCodes:")
    # Substitute only the immutable catalog array so the real language policy compiles
    # without unrelated Parakeet artifact-verification/filesystem dependencies.
    parakeet_policy = next(line for line in language_source.splitlines()
                           if "static let parakeetV3LanguageIDs =" in line)
    parakeet_policy = parakeet_policy.replace("ParakeetSpeechModelCatalog.v3.supportedLanguageCodes",
                                             parakeet_languages)
    metadata += "\nenum VoiceEngineLanguageCatalog {\n" + whisper_marker + whisper_languages + "\n"
    metadata += parakeet_policy + "\n}\n"
    metadata += "\n" + declaration((ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text(),
                                   "nonisolated enum MeetingAudioTrackKind:")
    metadata += "\n" + declaration((ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift").read_text(),
                                   "nonisolated enum MeetingTextUnitPrecision:") + "\n"
    models = (ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text()
    model_declarations = "\n".join(declaration(models, marker) for marker in (
        "nonisolated enum MeetingCaptureMode:",
        "nonisolated enum MeetingApplicationAudioScope:",
        "nonisolated enum MeetingMicrophoneRole:",
        "nonisolated struct MeetingRecordingDefaults:",
        "nonisolated struct MeetingApplicationIdentity:",
        "nonisolated struct MeetingMicrophoneIdentity:",
    ))
    application_option = declaration(source, "nonisolated struct MeetingApplicationOption:")
    capture = (ROOT / "Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift").read_text()
    application_resolver = declaration(capture, "static func resolveRecordingApplication(")
    recording_start = declaration(source, "private func startRecording()")
    swift = r'''
import Foundation
nonisolated final class UserDefaults: @unchecked Sendable {
    static let standard = UserDefaults()
    func string(forKey key: String) -> String? { nil }
    func set(_ value: Any?, forKey key: String) { fatalError("Unexpected preference write") }
}

final class SettingsStore {
    static let shared = SettingsStore()
    struct SpeechModel { let rawValue: String }
    var selectedSpeechModel = SpeechModel(rawValue: PichiMeetingProviderFactory.gigaamModelID)
    var meetingRecordingDefaults = MeetingRecordingDefaults.unconfigured
    var meetingAutoDetectEnabled = true
    var meetingAutoDetectBrowserEnabled = true
    var meetingAudioRetentionPolicy = 7
}
struct Identity { let id: String }
struct Option { let identity: Identity }
final class Coordinator { var isQuiescent = true; var activeLanguage = "en" }
''' + metadata + factory + model_declarations + '\n' + application_option + r'''
enum MeetingAutoDetector {
    struct ResolvedTarget { let bundleIdentifier: String; let pid: Int32; let windowID: UInt32? }
}
enum MeetingCaptureError: Error { case applicationNotSelected, applicationUnavailable(String) }
enum MeetingCaptureSourceCatalog {
''' + application_resolver + r'''
}
''' + draft + r'''
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
    var defaults = MeetingRecordingDefaults.unconfigured
    defaults.languageCode = language; defaults.mode = mode
    SettingsStore.shared.meetingRecordingDefaults = defaults
}
func fresh() -> Harness {
    restored("en", .onlineCall)
    SettingsStore.shared.meetingAutoDetectEnabled = true
    SettingsStore.shared.meetingAutoDetectBrowserEnabled = true
    SettingsStore.shared.meetingAudioRetentionPolicy = 7
    SettingsStore.shared.selectedSpeechModel = .init(rawValue: PichiMeetingProviderFactory.gigaamModelID)
    return Harness()
}
@MainActor final class StartCoordinator {
    var calls = 0
    var continuation: CheckedContinuation<Void, Never>?
    func startRecording(configuration: StartConfiguration) async throws {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
struct StartConfiguration { let microphone: MeetingMicrophoneIdentity }
struct StartReadiness {
    let activityReady = true, storageReady = true, microphoneReady = true, meetingAudioReady = true
    let blockingMessage: String? = nil
}
@MainActor final class StartHarness {
    let settings = SettingsStore.shared
    let coordinator = StartCoordinator()
    let readiness = StartReadiness()
    let captureConfiguration: StartConfiguration? = StartConfiguration(microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Mic"))
    let applications = [MeetingApplicationOption(identity: MeetingApplicationIdentity(bundleIdentifier: "manual.app", processID: 42, displayName: "Manual App"))]
    var setupDraft = MeetingTranscriptionSetupDraft()
    var isStarting = false, pendingBackupSetupRefresh = false
    var actionErrorMessage: String?
    init() { setupDraft.chooseApplication(applications[0].identity) }
    func waitForStart() async { while coordinator.continuation == nil { await Task.yield() } }
    func finish() async { coordinator.finish(); while isStarting { await Task.yield() } }
''' + recording_start + r'''
    func start() { startRecording() }
}
@main enum Tests {
 @MainActor static func main() async {
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
    for (modelID, expectedDefault) in [
        (PichiMeetingProviderFactory.gigaamModelID, "ru"),
        (PichiMeetingProviderFactory.whisperTinyModelID, "auto"),
        (PichiMeetingProviderFactory.parakeetV3ModelID, "auto"),
    ] {
        let legacy = fresh()
        SettingsStore.shared.selectedSpeechModel = .init(rawValue: modelID)
        SettingsStore.shared.meetingRecordingDefaults.languageCode = nil
        legacy.notifyRestore()
        check(PichiMeetingProviderFactory.registeredBackendDescriptor(for: modelID) != nil,
              "restored model retains its real registration")
        check(PichiMeetingProviderFactory.registeredLanguageCodes(for: modelID)?.contains(expectedDefault) == true,
              "default language is supported by actual registered metadata")
        check(legacy.setupDraft.languageCode == expectedDefault && legacy.hardwareQueries == 0,
              "legacy language uses selected provider metadata without source discovery")
        SettingsStore.shared.meetingRecordingDefaults.languageCode = "de"
        legacy.notifyRestore()
        check(legacy.setupDraft.languageCode == "de", "explicit restored language takes precedence over selected provider metadata")
    }
    check(PichiMeetingProviderFactory.defaultLanguageCode(for: "unknown-synthetic-model") == nil
          && PichiMeetingProviderFactory.registeredLanguageCodes(for: "unknown-synthetic-model") == nil,
          "unknown models do not acquire fabricated registration metadata")
    let missing = fresh(); missing.microphones = []; missing.applications = []
    restored(); missing.notifyRestore()
    check(missing.setupDraft.selectedMicrophoneID == nil && missing.setupDraft.selectedApplicationID == nil, "missing cached sources stay unselected")
    check(missing.hardwareQueries == 0 && !missing.pendingBackupSetupRefresh, "missing sources do not create a permanent pending restore")

    for superseded in 0..<3 {
        SettingsStore.shared.meetingRecordingDefaults = .unconfigured
        let start = StartHarness()
        start.start(); await start.waitForStart()
        if superseded > 0 { restored("fr", .inRoom) }
        if superseded == 1 { start.pendingBackupSetupRefresh = true }
        await start.finish()
        let saved = SettingsStore.shared.meetingRecordingDefaults
        if superseded == 0 {
            check(saved.mode == .onlineCall && saved.applicationBundleIdentifier == "manual.app", "successful quick Change/Start persists manual source")
        } else {
            check(saved.mode == .inRoom && saved.languageCode == "fr" && saved.applicationBundleIdentifier == nil, "backup or another window's settings during start supersede older frozen defaults")
        }
    }
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
