#!/usr/bin/env python3
"""Run actual context/profile lifetime code without reading UI, audio or credentials."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
source = (repo / "Sources/Fluid/ContentView.swift").read_text()

def between(start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

cancel = between("    private func cancelDictationContextCapture()", "    private func attachDictationContext(")
attach = between("    private func attachDictationContext(", "    private func captureDictationStopSnapshot(")
start = between("    private func startDictationContextCaptureIfNeeded(", "    private func cancelDictationContextCapture()")
methods = (start + cancel + attach).replace("private func ", "func ")
assert start.index("owner.admit(") < start.index("DictationContextCapture.start(")
assert start.index("owner.isCurrent") < start.index("owner.admit(")
assert "self.dictationContextProfile = profile" in start
assert cancel.index("await capture.cancelAndWait()") < cancel.index("owner.complete(operationID)")
assert "self.cancelDictationContextCapture()" in between(".onReceive(NotificationCenter.default.publisher(for: PrivateProfileService.willConceal))", ".onChange(of: self.accessibilityEnabled)")
assert "profile: contextProfile" in source
for marker in ["for: .primary", "for: slot"]:
    assert "startDictationContextCaptureIfNeeded(" + marker + ")" in source

rewrite_source = (repo / "Sources/Fluid/Services/RewriteModeService.swift").read_text()
def rewrite_declaration(marker):
    begin = rewrite_source.index(marker)
    return rewrite_source[begin:rewrite_source.index("\n    }\n", begin) + len("\n    }")]
rewrite_fields = "\n".join(line for line in rewrite_source.splitlines() if line.startswith((
    "    private let privateOperations =", "    private var windowCapture:",
    "    private var windowCaptureRevision:", "    private var windowCaptureProfile:",
    "    private var windowCaptureOperationID:", "    private let captureWindow:",
    "    private let screenContextSettings:", "    private var screenContextConsentObservation:"
)))
rewrite_methods = "\n".join(rewrite_declaration(marker) for marker in (
    "    init(settings:", "    func startReadingWindow(", "    func windowContextForRewrite(",
    "    func cancelOutdatedWindowCapture(", "    func stopReadingWindow(",
    "    func prepareForPrivateProfileTransition("
))
assert "await privateOperations.retireAndJoin()" in rewrite_methods
assert rewrite_methods.index("owner.admit(") < rewrite_methods.index("admittedCapture = self.captureWindow(target)")
assert "PrivateProfileStorage.isReadable(profile)" in rewrite_methods
rewrite_harness = "\n@MainActor final class RewriteContextProfileHarness: PrivateProfileTransitionParticipant {\n" + rewrite_fields + "\n" + rewrite_methods + "\n    var isProcessing = false; var isAcceptingRewrite = false\n    func clearState() { self.stopReadingWindow() }\n}\n"

# Reuse the actual preference mutation, bound-store fence and row binding. The
# previous synthetic instance counter concealed root/bound-store revocation bugs.
settings_source = (repo / "Sources/Fluid/Persistence/SettingsStore.swift").read_text()
consent_begin = settings_source.index("    static let editModeScreenContextDidChange =")
consent_end = settings_source.index("    /// Global check if a model is a reasoning model", consent_begin)
consent = settings_source[consent_begin:consent_end]
bound_begin = settings_source.index("    func boundToCurrentPrivateProfile()")
bound_end = settings_source.index("\n    }", bound_begin) + len("\n    }")
bound = settings_source[bound_begin:bound_end]
keys_source = (repo / "Sources/Fluid/Persistence/SettingsStoreKeys.swift").read_text()
consent_keys = "\n".join(line for line in keys_source.splitlines()
                         if "static let editModeReadsScreen =" in line or "static let editModeScreenContextRevision =" in line)
row_source = (repo / "Sources/Fluid/UI/AISettings/EditModeModelSection.swift").read_text()
row_begin = row_source.index("struct EditModeScreenContextSettings:")
row_init_begin = row_source.index("    init(settings:", row_begin)
row_init_end = row_source.index("\n    }", row_init_begin) + len("\n    }")
binding_begin = row_source.index("    var enabledBinding:", row_init_end)
binding_end = row_source.index("\n    }", binding_begin) + len("\n    }")
row = ("\n@MainActor struct EditModeScreenContextSettings {\n"
       "    @ObservedObject var settings: SettingsStore\n"
       "    @StateObject private var permission: DictationScreenPermissionController\n"
       + row_source[row_init_begin:row_init_end] + "\n" + row_source[binding_begin:binding_end] + "\n}\n")
checks_source = (repo / "Tests/FluidDictationIntegrationTests/EditModeRouteTests.swift").read_text()
consent_checks = checks_source[checks_source.index("@MainActor enum EditModeConsentChecks {"):]
backup_begin = settings_source.index("    func makeBackupPayload()")
backup_end = settings_source.index("    func restore(", backup_begin)
assert "editModeScreenContextRevision" not in settings_source[backup_begin:backup_end]
assert "editModeReadsScreen" not in settings_source[backup_begin:backup_end]
backup_schema = (repo / "Sources/Fluid/Persistence/BackupService.swift").read_text()
assert "editModeScreenContextRevision" not in backup_schema
assert "editModeReadsScreen" not in backup_schema
restore_end = settings_source.index("    // MARK:", backup_end)
assert "editModeScreenContextRevision" not in settings_source[backup_end:restore_end]
assert "editModeReadsScreen" not in settings_source[backup_end:restore_end]

support = '''
import AppKit
import Combine
import Foundation
import SwiftUI
nonisolated enum AppBrand {
    static let storageNamespace = "synthetic.context-profile." + UUID().uuidString
    static let keychainService = "synthetic.context-profile.credentials"
    static let applicationSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-unused-context-profile")
}
nonisolated enum BrandDistribution { struct AccountConfiguration: Sendable {} }
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject { func prepareForPrivateProfileTransition() async throws }
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    func register(_ participant: any PrivateProfileTransitionParticipant) {}
}
nonisolated enum TypingService {
    struct RecordingTargetContext {
        let id: UUID
        let pid: pid_t
        let bundleIdentifier: String?
        let window: AXUIElement?
        let element: AXUIElement?
    }
}
@MainActor final class SettingsStore: ObservableObject {
    static let shared = SettingsStore(defaults: UserDefaults(suiteName: AppBrand.storageNamespace + ".legacy-harness")!)
    let defaults: UserDefaults
    init(defaults: UserDefaults = PrivateProfileDefaults.shared, initializeDesktop: Bool = true) { self.defaults = defaults }
    enum DictationShortcutSlot { case primary, secondary }
    var dictationScreenContextEnabled = true
    var needsDictationFormattingContext = false
    /* ACTUAL_CONSENT_DECLARATIONS */
}
typealias RewriteModeService = RewriteContextProfileHarness
@MainActor enum DictationProviderRoute {
    static func resolve(settings: SettingsStore, dictationSlot: SettingsStore.DictationShortcutSlot, appBundleID: String?) -> ContextRoute { ContextRoute() }
}
@MainActor final class NotchContentState {
    static let shared = NotchContentState()
    var recordingTargetContext: TypingService.RecordingTargetContext?
}
@MainActor struct ContextVisibleCapture { var isVisible = true }
nonisolated struct ContextRoute { let usesPrivateAI = true; let model = "synthetic-supported-context" }
nonisolated enum PrivateAIIntegrationService { static func readsDictationContext(model: String) -> Bool { true } }
@MainActor struct DictationStopSnapshot {
    let target: TypingService.RecordingTargetContext?
    let usesAI = true
    let route = ContextRoute()
    var typingContext: DictationTypingContext?
}
@MainActor final class ContextProfileViewHarness {
    let settings = SettingsStore()
    let privateOutputOperations = PrivateProfileOperationOwner()
    var privateCaptureOutput: ContextVisibleCapture? = ContextVisibleCapture()
    var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)?
    var recordingPrecedingText = ""
    var dictationContextCapture: DictationContextCapture?
    var dictationContextProfile: PrivateProfileSnapshot?
    var dictationContextOperationID: UUID?
    var benchmarkCount = 0
    func appBench(_ message: @autoclosure () -> String) { benchmarkCount += 1 }
}
@MainActor enum MeetingSessionStoreCheckpointTests {}
@main @MainActor struct ContextProfileMain {
    static func main() async throws {
        var count = 0
        let check: (Bool, String) -> Void = { value, description in
            precondition(value, description)
            count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("context-profile-" + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: AppBrand.storageNamespace + ".legacy-harness")
        }
        try await MeetingSessionStoreCheckpointTests.checkPrivateProfileOperationOwner(root: root, check: check)
        try await DictationContextProfileChecks.run(root: root, check: check)
        try await EditModeConsentChecks.run(check: check)
        print("Context/profile lifetime: \\(count) assertions passed")
    }
}
'''
support = support.replace("    /* ACTUAL_CONSENT_DECLARATIONS */", "    enum Keys {\n" + consent_keys + "\n    }\n" + consent + bound)
(repo / ".build").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="pichi-context-profile-", dir=repo / ".build") as name:
    directory = Path(name)
    support_path = directory / "Support.swift"
    support_path.write_text(support + rewrite_harness + row + consent_checks + "\n@MainActor extension ContextProfileViewHarness {\n" + methods + "}\n")
    files = [support_path,
             repo / "Sources/Fluid/Account/AccountDomain.swift",
             repo / "Sources/Fluid/Account/PrivateProfileStorage.swift",
             repo / "Sources/Fluid/Account/PrivateProfileDefaults.swift",
             repo / "Sources/Fluid/Account/PrivateProfileOperationOwner.swift",
             repo / "Sources/Fluid/Services/DictationContextCapture.swift",
             repo / "Sources/Fluid/Services/DictationScreenPermissionController.swift",
             repo / "Tests/PrivateProfileOperationOwnerTests.swift",
             repo / "Tests/DictationContextProfileTests.swift"]
    for mode in ([], ["-default-isolation", "MainActor"]):
        executable = directory / ("checks-actor" if mode else "checks")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", *mode,
                        "-module-cache-path", str(directory / "ModuleCache"), *map(str, files), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=15)
print("Actual ContentView context wiring passed; no Accessibility/OCR operations invoked")
