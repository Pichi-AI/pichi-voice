#!/usr/bin/env python3
"""Port inherited settings doubles to real downstream value types and registry operations.

Only service/feature data and view-model IO are doubled. No model installation,
weights, runtime, preferences domain, app bundle or GUI is created.
"""
from pathlib import Path
import sys
from ProbeContractDependencies import ROOT, declaration, brand_text

source = (ROOT / 'Sources/Fluid/Services/PrivateAIProvider.swift').read_text()
doubles = (ROOT / 'Tests/PrivateAISettingsControllerDoubles.swift').read_text()
for marker in ['struct PrivateAIModelDownloadProgress:', 'struct PrivateAIRegisteredModel:',
               'struct PrivateAIModelUpdateStatus', 'struct PrivateAIModelUpdateToken:',
               'struct PrivateAIStatus', 'enum PrivateAIModelRegistry {']:
    doubles = doubles.replace(declaration(doubles, marker), '')
# Keep the inherited two-model synthetic feature boundary; execute the production registry.
doubles = doubles.replace('struct PrivateAIProviderFeature { static let shared = Self(); let providerID = "fi" }', '''
enum PrivateAIProviderFeature { static let shared = FixturePrivateAIFeature() }
struct FixturePrivateAIFeature {
    let providerID = "fi"
    let defaultModelID = "mini"
    let defaultBackend = SettingsStore.PrivateAIBackendPreference.mlx
    func modelIDs() -> [String] { ["mini", "pico"] }
    func modelIDs(for task: PrivateAIModelTask) -> [String] { task == .dictation ? modelIDs() : [] }
    func canonicalModelID(for id: String) -> String? { modelIDs().contains(id) ? id : nil }
    func model(id: String) -> PrivateAIRegisteredModel? { canonicalModelID(for: id).map { PrivateAIRegisteredModel(id: $0) } }
    func recommendedModelID(for task: PrivateAIModelTask, on hardware: PrivateAIMacHardware) -> String? { nil }
    func localModelURL(for model: PrivateAIRegisteredModel, directoryURL: URL) -> URL { fatalError("Unexpected model filesystem request") }
}
''')
settings = (ROOT / 'Sources/Fluid/Persistence/SettingsStore.swift').read_text()
doubles = doubles.replace('enum PrivateAIBackendPreference { case auto, mlx; var displayName: String { "test" } }', declaration(settings, 'enum PrivateAIBackendPreference:'))
doubles = doubles.replace('final class SettingsStore {', '''final class SettingsStore {
    static let privateProfileWillChange = Notification.Name("ProbePrivateProfileWillChange")
    var defaults: UserDefaults { .standard }
''')
doubles = doubles.replace('    var smartSelectionCount = 0', '    var profileIsCurrent = true\n    var smartSelectionCount = 0')
doubles = doubles.replace('PrivateAIStatus.State', 'PrivateAIRuntimeState')
metadata = '\n'.join(declaration(source, marker) for marker in [
    'struct PrivateAIModelArtifact:', 'struct PrivateAIModelDownloadProgress:',
    'enum PrivateAIModelUpdateState:', 'struct PrivateAIModelUpdateStatus:',
    'struct PrivateAIModelUpdateToken:', 'struct PrivateAIRegisteredModel:',
    'enum PrivateAIModelTask:', 'enum PrivateAIRuntimeState:', 'struct PrivateAIStatus:',
    'enum PrivateAIModelRegistry {', 'extension PrivateAIRegisteredModel {',
])
hardware = (ROOT / 'Sources/Fluid/Services/PrivateAIHardwareRecommendation.swift').read_text()
metadata += '\ntypealias PrivateAIMacHardware = ProbeHardware\n' + declaration(hardware, 'struct Hardware:').replace('struct Hardware:', 'struct ProbeHardware:', 1)
metadata += '''
extension PrivateAIRegisteredModel {
    init(id: String, canDownload: Bool = true) {
        self.init(displayName: id, detail: "Synthetic contract fixture", isEnabled: true,
            parameterCount: "", recommendedMemoryGB: nil,
            artifact: .init(identifier: id, filename: id + ".fixture", downloadURL: canDownload ? URL(string: "https://example.invalid/unused") : nil,
                sha256: canDownload ? String(repeating: "0", count: 64) : nil, byteCount: 10, version: nil))
    }
}
extension PrivateAIModelUpdateToken { init() { self.init(id: UUID()) } }
'''
# Production localization must use Foundation preferences, not the write-counting IO double.
localization = (ROOT / 'Sources/Fluid/Localization/PichiLocalization.swift').read_text().replace('UserDefaults', 'Foundation.UserDefaults')
Path(sys.argv[1]).write_text('import Foundation\n' + metadata + doubles + localization + brand_text())
