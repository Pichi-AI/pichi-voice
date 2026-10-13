"""Check reachable summary UI and run its actual selection/action bodies in isolation.

This probe creates only in-memory AppKit views and a private UserDefaults suite.
Controller and route effects are recorded doubles. It does not run inference,
read Keychain, access app meetings, make HTTP requests or establish visual E2E.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VIEW = "Sources/Fluid/UI/MeetingSummaryView.swift"


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
    parser.add_argument("--baseline-ref", help="Run the reachability negative control against an older revision")
    args = parser.parse_args()
    source = (ROOT / VIEW).read_text()
    if args.baseline_ref:
        source = subprocess.check_output(["git", "show", f"{args.baseline_ref}:{VIEW}"], cwd=ROOT, text=True)

    wrapper = declaration(source, "struct MeetingSummaryView: View")
    assert 'Picker("Summary format", selection: self.workflowSelection)' in wrapper, "The original UI must have a reachable user choice"
    assert "switch self.presentedWorkflow" in wrapper
    assert "case .grounded:" in wrapper and "PichiMeetingSummaryView(session:" in wrapper
    assert "case .templates:" in wrapper and "TemplateMeetingSummaryView(session:" in wrapper
    assert '@AppStorage("MeetingSummaryWorkflow") private var workflow = MeetingSummaryWorkflow.grounded' in wrapper
    assert "controller: self.templateController" in wrapper
    template = declaration(source, "struct TemplateMeetingSummaryView: View")
    assert "self.kindPicker" in declaration(template, "private var configurationPanel:")
    assert "self.customPromptEditor" in declaration(template, "private var configurationPanel:")
    assert "ForEach(MeetingSummaryKind.allCases)" in declaration(template, "private var kindPicker:")
    assert "self.$preferences.kind" in declaration(template, "private var kindPicker:")
    assert ".background(DictationTextTarget())" in declaration(template, "private var customPromptEditor:")
    assert ".onDisappear { self.controller.cancel() }" in template
    assert "self.controller.download()" in declaration(template, "private var actions:")
    assert "self.controller.deleteModel(asr: self.asrService ?? AppServices.shared.asr)" in template
    assert "self.$preferences.thinksFirst" in declaration(template, "private var thinkingRow:")
    assert ".font(.system" not in source and ".font(.headline" not in source, "Summary UI must use shared typography"
    catalog = json.loads((ROOT / "Sources/Fluid/Localization/Localizable.xcstrings").read_text())["strings"]
    required_keys = ["Summary format", "Summary with sources", "Templates and custom prompt", "Executive summary",
                     "Detailed summary", "Action items", "Key decisions", "Participants", "Topics discussed", "Custom prompt",
                     "Custom summary prompt", "Summary model", "Summary model actions", "Think before summarizing"]
    for key in required_keys:
        for language in ("en", "ru"):
            assert catalog[key]["localizations"][language]["stringUnit"]["value"], (key, language)

    provider = (ROOT / "Sources/Fluid/Services/Meeting/MeetingSummaryProvider.swift").read_text()
    controller = (ROOT / "Sources/Fluid/Services/Meeting/MeetingSummaryController.swift").read_text()
    repository = (ROOT / "Sources/Fluid/Services/ModelRepository.swift").read_text()
    kind = declaration(controller, "nonisolated enum MeetingSummaryKind:")
    selection = declaration(provider, "nonisolated struct MeetingSummarySelection:")
    preferences = declaration(provider, "final class MeetingSummaryPreferences:")
    workflow = declaration(source, "nonisolated enum MeetingSummaryWorkflow:")
    marker = declaration(source, "struct DictationTextTarget:")
    methods = "\n".join(declaration(template, member).replace("private ", "", 1) for member in (
        "private var refreshID:", "private var providerID:", "private var providerKey:", "private var providers:",
        "private var usesOnDevice:", "private var hasChoices:", "private var needsCustomPrompt:", "private var modelID:",
        "private var modelOptions:", "private var selectedOption:", "private func selectModel(", "private func selectProvider(",
        "private func reloadProviders()", "private func resolveRoute()", "private func generate()",
    ))
    presentation = "\n".join(declaration(wrapper, member).replace("private ", "", 1) for member in (
        "private var presentedWorkflow:", "private var workflowSelection:",
    ))
    metadata = "\n".join(declaration(repository, member) for member in (
        "static var builtInProviderIDs:", "func isBuiltIn(", "func providerKey(",
    ))
    swift = '''import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
enum PrivateFeatures { static let privateAIProvider = false }
struct PrivateAIProviderFeature { static let shared = Self(); let providerID = "private-test" }
enum CloudTextProvider { static let registered: [Descriptor] = []; struct Descriptor { let id: String } }
struct PrivateAIRegisteredModel { let displayName: String }
enum MeetingSummaryOnDevice { static let providerID = "on-device"; static let providerName = "On device - Synthetic" }
enum MeetingSummaryInput {
    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
final class ASRService {}
struct MeetingSession { let id: UUID; var updatedAt: Date }
@MainActor final class AppServices { static let shared = AppServices(); let asr = ASRService() }
@MainActor final class SettingsStore {
    var selectedProviderID = "openai" { didSet { writes += 1 } }
    var selectedModelByProvider = ["openai": "dictation-model"] { didSet { writes += 1 } }
    var writes = 0
    var catalog: [CommandModelOption] = []
    func commandModeModelCatalog() -> [CommandModelOption] { catalog }
}
struct RecordedRequest { let kind: MeetingSummaryKind; let prompt: String; let provider: String; let model: String; let thinking: Bool? }
@MainActor final class MeetingSummaryController {
    var busy = false
    var checking = false
    var model: PrivateAIRegisteredModel?
    var requests: [RecordedRequest] = []
    var receivedASR: ASRService?
    func summarize(session: MeetingSession, kind: MeetingSummaryKind, route: MeetingSummaryRoute, customPrompt: String) {
        requests.append(.init(kind: kind, prompt: customPrompt, provider: route.providerID, model: route.modelID, thinking: nil))
    }
    func summarizeOnDevice(session: MeetingSession, kind: MeetingSummaryKind, customPrompt: String, thinking: Bool, asr: ASRService) {
        receivedASR = asr
        requests.append(.init(kind: kind, prompt: customPrompt, provider: "on-device", model: "synthetic", thinking: thinking))
    }
}
@MainActor struct MeetingSummaryRoute {
    let providerID: String; let modelID: String
    static func resolve(_ selection: MeetingSummarySelection, settings: SettingsStore) throws -> Self {
        let key = ModelRepository.shared.providerKey(for: selection.providerID)
        guard settings.catalog.contains(where: { ModelRepository.shared.providerKey(for: $0.providerID) == key && $0.modelID == selection.modelsByProvider[key] }) else { throw NSError(domain: "Synthetic unavailable route", code: 1) }
        return .init(providerID: selection.providerID, modelID: selection.modelsByProvider[key]!)
    }
}
@MainActor final class GroundedController { var generating = false; var checking = false }
'''
    swift += kind + "\n" + selection + "\n@MainActor\n" + preferences + "\n" + workflow + "\n" + marker
    swift += "\nfinal class ModelRepository { static let shared = ModelRepository()\n" + metadata + "\n}\n"
    swift += "\n@MainActor final class TemplateOwner {\n" + '''
    let preferences: MeetingSummaryPreferences
    let settings: SettingsStore
    let controller = MeetingSummaryController()
    var session: MeetingSession? = .init(id: UUID(), updatedAt: Date(timeIntervalSince1970: 100))
    var isQuiescent = true
    var asrService: ASRService? = ASRService()
    var catalog: [CommandModelOption] = []
    var catalogLoaded = false
    var route: MeetingSummaryRoute?
    var readinessIssue: String?
    var onDeviceModel: PrivateAIRegisteredModel?
    init(_ defaults: UserDefaults, _ settings: SettingsStore) {
        self.preferences = MeetingSummaryPreferences(defaults: defaults)
        self.settings = settings
    }
''' + methods + "\n}\n"
    stored_workflow = next(line.strip().replace("private ", "", 1) for line in wrapper.splitlines()
                           if line.strip().startswith('@AppStorage("MeetingSummaryWorkflow")'))
    # The UI's actual property wrapper/key/default are preserved. Only its storage
    # is explicitly injected to prevent reading/writing application preferences.
    swift += "\n@MainActor final class WorkflowOwner {\n" + stored_workflow + '''
    let templateController = MeetingSummaryController()
    let groundedController = GroundedController()
    init(_ defaults: UserDefaults) {
        self._workflow = AppStorage(wrappedValue: .grounded, "MeetingSummaryWorkflow", store: defaults)
    }
''' + presentation + "\n}\n"
    swift += (ROOT / "Tests/MeetingSummaryUIParityTests.swift").read_text()
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    assert (Path(developer) / "Platforms/MacOSX.platform").is_dir(), "Select full Xcode for this source probe"
    output = ROOT / ".build/summary-ui-parity"
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="run.", dir=output) as work:
        work = Path(work)
        generated = work / "ActualSummaryUI.swift"
        generated.write_text(swift)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                        "-module-cache-path", str(work / "ModuleCache"), str(generated),
                        str(ROOT / "Sources/Fluid/Localization/PichiLocalization.swift"),
                        str(ROOT / "Sources/Fluid/Views/CommandModelCatalog.swift"),
                        "-o", str(work / "tests")], check=True, cwd=ROOT, env={**os.environ, "DEVELOPER_DIR": developer})
        subprocess.run([str(work / "tests")], check=True, cwd=ROOT)
    print("Summary UI reachability/localization: passed (source checks, no visual E2E)")


if __name__ == "__main__":
    main()
