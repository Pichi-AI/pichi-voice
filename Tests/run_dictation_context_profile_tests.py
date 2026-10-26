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

support = '''
import AppKit
import Foundation
nonisolated enum AppBrand {
    static let storageNamespace = "synthetic.context-profile"
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
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    enum DictationShortcutSlot { case primary, secondary }
    var dictationScreenContextEnabled = true
    var needsDictationFormattingContext = false
}
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
        defer { try? FileManager.default.removeItem(at: root) }
        try await MeetingSessionStoreCheckpointTests.checkPrivateProfileOperationOwner(root: root, check: check)
        try await DictationContextProfileChecks.run(root: root, check: check)
        print("Context/profile lifetime: \\(count) assertions passed")
    }
}
'''
(repo / ".build").mkdir(exist_ok=True)
with tempfile.TemporaryDirectory(prefix="pichi-context-profile-", dir=repo / ".build") as name:
    directory = Path(name)
    support_path = directory / "Support.swift"
    support_path.write_text(support + "\n@MainActor extension ContextProfileViewHarness {\n" + methods + "}\n")
    files = [support_path,
             repo / "Sources/Fluid/Account/AccountDomain.swift",
             repo / "Sources/Fluid/Account/PrivateProfileStorage.swift",
             repo / "Sources/Fluid/Account/PrivateProfileOperationOwner.swift",
             repo / "Sources/Fluid/Services/DictationContextCapture.swift",
             repo / "Tests/PrivateProfileOperationOwnerTests.swift",
             repo / "Tests/DictationContextProfileTests.swift"]
    for mode in ([], ["-default-isolation", "MainActor"]):
        executable = directory / ("checks-actor" if mode else "checks")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", *mode,
                        "-module-cache-path", str(directory / "ModuleCache"), *map(str, files), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True, timeout=15)
print("Actual ContentView context wiring passed; no Accessibility/OCR operations invoked")
