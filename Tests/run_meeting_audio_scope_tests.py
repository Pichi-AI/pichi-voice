#!/usr/bin/env python3
"""Run production source-scope admission and preference/menu contracts without hardware."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
sys.dont_write_bytecode = True
from run_meeting_backup_refresh_tests import declaration

ROOT = Path(__file__).resolve().parents[1]
models = (ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text()
menu = (ROOT / "Sources/Fluid/Services/AppServices+MeetingMenuBar.swift").read_text()
capture = (ROOT / "Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift").read_text()
model_declarations = "\n".join(declaration(models, marker) for marker in (
    "nonisolated enum MeetingLanguageCode",
    "nonisolated enum MeetingAudioStorageMode:",
    "nonisolated enum MeetingSpeakerProcessingMode:",
    "nonisolated enum MeetingCaptureMode:",
    "nonisolated enum MeetingApplicationAudioScope:",
    "nonisolated enum MeetingApplicationAudioSource:",
    "nonisolated enum MeetingMicrophoneRole:",
    "nonisolated struct MeetingRecordingDefaults:",
    "nonisolated struct MeetingApplicationIdentity:",
    "nonisolated struct MeetingMicrophoneIdentity:",
    "nonisolated enum MeetingMicrophonePreselection",
    "nonisolated struct MeetingPlatformProfile:",
    "nonisolated struct MeetingCaptureConfiguration:",
))
validation = (ROOT / "Sources/Fluid/Services/Meeting/MeetingPersistenceValidation.swift").read_text()
configuration_validation = declaration(validation, "nonisolated extension MeetingCaptureConfiguration {")
recording_source = (ROOT / "Sources/Fluid/Services/Meeting/MeetingRecordingSource.swift").read_text()
preferences = (ROOT / "Sources/Fluid/Persistence/SettingsStoreMeetingPreferences.swift").read_text()
view = (ROOT / "Sources/Fluid/UI/MeetingTranscriptionView.swift").read_text()
# The GUI builders are private. Bind this executable actual-source policy probe to each
# actual launch path as a source-consistency check, without manufacturing a SwiftUI run.
for marker in ("private var captureConfiguration:", "private func recordAgainConfiguration("):
    builder = declaration(view, marker)
    assert builder.count("applyingMeetingRecordingPreferences(to: configuration)") == 1
    assert builder.index("MeetingCaptureConfiguration(") < builder.index("applyingMeetingRecordingPreferences(")
    assert builder.rstrip().endswith("return self.settings.applyingMeetingRecordingPreferences(to: configuration)\n    }")
start = declaration(view, "private func startRecording()")
assert start.index("let configuration = self.captureConfiguration") < start.index("Task {")
record_again = declaration(view, "private func recordAgain(_ session:")
assert record_again.index("let configuration = self.recordAgainConfiguration(") < record_again.index("Task {")
menu_start = declaration(menu, "func startMeetingRecordingFromMenuBar()")
assert menu_start.count("applyingMeetingRecordingPreferences(to: configuration)") == 1
assert menu_start.index("Self.menuBarMeetingConfiguration(") < menu_start.index("applyingMeetingRecordingPreferences(") < menu_start.index("self.meetingSessionCoordinator.startRecording(")
preference_operations = "\n".join(declaration(preferences, marker) for marker in (
    "var meetingSaveAudio:", "var meetingSpeakerLabelsEnabled:", "var meetingSpeakerProcessingMode:",
    "func meetingSpeakerProcessingMode(for mode:", "var meetingPIIRedactionEnabled:",
    "func applyingMeetingRecordingPreferences(to configuration:",
))
policy_witnesses = r'''
enum MeetingBackendInputKind { case boundedMicrophonePCM, boundedMultiTrackPCM }
struct BackendDescriptor {
    let supportedSpeakerProcessingModes: Set<MeetingSpeakerProcessingMode>
    let supportedInputs: Set<MeetingBackendInputKind>
}
enum PichiMeetingProviderFactory {
    static func registeredBackendDescriptor(for model: String) -> BackendDescriptor? {
        model == "synthetic-supported" ? .init(supportedSpeakerProcessingModes: [.afterRecording, .streaming],
            supportedInputs: [.boundedMicrophonePCM, .boundedMultiTrackPCM]) : nil
    }
}
final class SettingsStore {
    struct Keys {
        static let meetingSaveAudio = "SaveAudio", meetingSpeakerLabelsEnabled = "Labels"
        static let meetingSpeakerProcessingMode = "SpeakerMode", meetingPIIRedactionEnabled = "Privacy"
    }
    struct ChangeWitness { func send() {} }
    struct SpeechModel { let rawValue: String }
    let objectWillChange = ChangeWitness()
    let defaults: UserDefaults
    var selectedSpeechModel = SpeechModel(rawValue: "synthetic-supported")
    init(defaults: UserDefaults) { self.defaults = defaults }
''' + preference_operations + "\n}\n"
swift = "import Foundation\n" + model_declarations + "\n" + configuration_validation + "\n" + recording_source + "\n" + policy_witnesses + r'''
enum VoiceEngineLanguageCatalog { static let parakeetV3LanguageIDs = ["en", "ru"] }
enum MeetingModelValidationError: Error { case unsupportedLanguage, missingMicrophone, missingOnlineApplication, unexpectedInRoomApplication, unexpectedSystemAudioApplication }
enum MeetingCaptureError: Error { case applicationNotSelected, applicationUnavailable(String), microphoneUnavailable }
enum MeetingAutoDetector {
    struct ResolvedTarget { let bundleIdentifier: String; let pid: Int32; let windowID: UInt32? }
}
struct MeetingMicrophoneCatalogSnapshot { let identities: [MeetingMicrophoneIdentity]; let defaultCoreAudioUID: String? }
enum MeetingTranscriptionSetupDraft {
    static func defaultTitle(mode: MeetingCaptureMode, applicationDisplayName: String?) -> String { "Meeting" }
}
enum MeetingCaptureSourceCatalog {
''' + declaration(capture, "static func resolveRecordingApplication(") + r'''
}
struct AppServices {
''' + declaration(menu, "static func menuBarMeetingConfiguration(") + r'''
}
var assertions = 0
func check(_ value: Bool, _ message: String) {
    assertions += 1
    if !value { fatalError(message) }
}
func rejects(_ body: () throws -> Void) {
    assertions += 1
    do { try body(); fatalError("Expected source admission rejection") } catch {}
}
let microphone = MeetingMicrophoneIdentity(captureDeviceID: "mic", displayName: "Microphone")
let application = MeetingApplicationIdentity(bundleIdentifier: "synthetic.app", processID: 42, displayName: "Synthetic app")
var legacy = MeetingCaptureConfiguration(mode: .onlineCall, title: "Legacy", application: application, microphone: microphone)
let encoded = try JSONEncoder().encode(legacy)
let legacyJSON = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
check(legacyJSON["applicationAudioScope"] == nil, "Legacy JSON must retain its shape")
legacy = try JSONDecoder().decode(MeetingCaptureConfiguration.self, from: encoded)
check(legacy.effectiveApplicationAudioScope == .selectedApplication, "Legacy configuration must stay narrow")
try legacy.validate()
if case .application(let actual)? = legacy.applicationAudioSource { check(actual == application, "Legacy source identity preserved") } else { fatalError("Missing legacy source") }
legacy.application = nil
rejects { try legacy.validate() }
legacy.applicationAudioScope = .systemAudio
try legacy.validate()
if case .systemAudio? = legacy.applicationAudioSource { check(true, "Wide source") } else { fatalError("System source must not require a process") }
let wide = try JSONDecoder().decode(MeetingCaptureConfiguration.self, from: JSONEncoder().encode(legacy))
check(wide.applicationAudioScope == .systemAudio && wide.application == nil, "System source must round-trip truthfully")
legacy.application = application
rejects { try legacy.validate() }
legacy.application = nil
legacy.mode = .inRoom
rejects { try legacy.validate() }
legacy.applicationAudioScope = nil
try legacy.validate()
check(legacy.applicationAudioSource == nil, "In-room mode has no system source")
var defaults = try JSONDecoder().decode(MeetingRecordingDefaults.self, from: JSONEncoder().encode(MeetingRecordingDefaults.unconfigured))
check(defaults.applicationAudioScope == nil && defaults.effectiveApplicationAudioScope == .systemAudio, "Old preferences adopt the new all-source default")
let microphones = MeetingMicrophoneCatalogSnapshot(identities: [microphone], defaultCoreAudioUID: nil)
let menuWide = try AppServices.menuBarMeetingConfiguration(defaults: defaults, target: nil, microphones: microphones, applications: [], preferredInputUID: nil)
try menuWide.validate()
check(menuWide.mode == .systemAudio && menuWide.effectiveApplicationAudioScope == .systemAudio && menuWide.application == nil, "Menu can start all-source capture before any app opens")
defaults.mode = .onlineCall
defaults.applicationAudioScope = .selectedApplication
rejects { _ = try AppServices.menuBarMeetingConfiguration(defaults: defaults, target: nil, microphones: microphones, applications: [application], preferredInputUID: nil) }
defaults.isConfigured = true
defaults.applicationBundleIdentifier = application.bundleIdentifier
let menuNarrow = try AppServices.menuBarMeetingConfiguration(defaults: defaults, target: nil, microphones: microphones, applications: [application], preferredInputUID: nil)
check(menuNarrow.application == application && menuNarrow.applicationAudioScope == .selectedApplication, "Explicit narrow source must be retained")
rejects { _ = try AppServices.menuBarMeetingConfiguration(defaults: defaults, target: nil, microphones: microphones, applications: [], preferredInputUID: nil) }
defaults.applicationAudioScope = .systemAudio
let menuMigrated = try AppServices.menuBarMeetingConfiguration(defaults: defaults, target: nil, microphones: microphones, applications: [], preferredInputUID: nil)
check(menuMigrated.application == nil && menuMigrated.platform == nil, "System scope must not stamp an old manual app as captured")
let policySuite = "SyntheticAudioScopePolicy.\(UUID().uuidString)"
let policyDefaults = UserDefaults(suiteName: policySuite)!
defer { policyDefaults.removePersistentDomain(forName: policySuite) }
let settings = SettingsStore(defaults: policyDefaults)
for mode in MeetingCaptureMode.allCases {
    var selected = mode == .onlineCall ? menuNarrow : menuMigrated
    selected.mode = mode
    if mode == .inRoom { selected.application = nil; selected.applicationAudioScope = nil }
    selected.requiresEncryptedPersistence = true
    selected.transcriptionBackendID = "synthetic-explicit-backend"
    for saveAudio in [false, true] {
        for labels in [false, true] {
            for preference: MeetingSpeakerProcessingMode in [.afterRecording, .streaming] {
                for privacy in [false, true] {
                    settings.meetingSaveAudio = saveAudio
                    settings.meetingSpeakerLabelsEnabled = labels
                    settings.meetingSpeakerProcessingMode = preference
                    settings.meetingPIIRedactionEnabled = privacy
                    let configured = settings.applyingMeetingRecordingPreferences(to: selected)
                    check(configured.audioStorageMode == (saveAudio ? .retainedFiles : .memoryOnly), "Configured retention must reach the resolved source")
                    check(configured.speakerLabelsEnabled == labels, "Configured speaker label policy must reach the resolved source")
                    check(configured.speakerProcessingMode == (labels ? .streaming : nil), "Legacy timing preference cannot defer new recordings; disabled labels stay explicit")
                    check(configured.piiRedactionEnabled == privacy, "Configured privacy policy must reach the resolved source")
                    var identity = configured
                    identity.audioStorageMode = selected.audioStorageMode
                    identity.speakerLabelsEnabled = selected.speakerLabelsEnabled
                    identity.speakerProcessingMode = selected.speakerProcessingMode
                    identity.piiRedactionEnabled = selected.piiRedactionEnabled
                    check(identity == selected, "Sources and trusted explicit security/backend configuration must remain exact")
                    settings.meetingSaveAudio = !saveAudio
                    settings.meetingSpeakerLabelsEnabled = !labels
                    settings.meetingSpeakerProcessingMode = preference == .streaming ? .afterRecording : .streaming
                    settings.meetingPIIRedactionEnabled = !privacy
                    check(configured.audioStorageMode == (saveAudio ? .retainedFiles : .memoryOnly)
                        && configured.speakerLabelsEnabled == labels && configured.piiRedactionEnabled == privacy
                        && configured.speakerProcessingMode == (labels ? .streaming : nil),
                        "A returned capture value cannot follow later preference changes")
                }
            }
        }
    }
    policyDefaults.removeObject(forKey: SettingsStore.Keys.meetingSpeakerProcessingMode)
    settings.meetingSpeakerLabelsEnabled = true
    check(settings.applyingMeetingRecordingPreferences(to: selected).effectiveSpeakerProcessingMode == .streaming,
        "Supported backend metadata defaults must reach either source topology")
    check(policyDefaults.object(forKey: SettingsStore.Keys.meetingSpeakerProcessingMode) == nil,
        "Applying a default must not create a stored preference")
}
print("PASS actual launch-path source consistency: main Record, Record Again and menu")
print("PASS: \(assertions) production source-scope assertions")
'''
build_root = ROOT / ".build"
build_root.mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="audio-scope-", dir=build_root) as folder:
    folder = Path(folder)
    source = folder / "main.swift"
    source.write_text(swift)
    executable = folder / "scope-tests"
    subprocess.run(["xcrun", "swiftc", str(source), "-o", str(executable)], cwd=ROOT, env=os.environ, check=True, timeout=60)
    subprocess.run([str(executable)], cwd=ROOT, check=True, timeout=15)
