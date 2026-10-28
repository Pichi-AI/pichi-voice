#!/usr/bin/env python3
"""Run actual capture options and vocabulary preparation with inert inference neighbors."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parent.parent
fluid = (repo / "Sources/Fluid/Services/FluidAudioProvider.swift").read_text()
vocabulary = (repo / "Sources/Fluid/Services/ParakeetVocabularyStore.swift").read_text()
analyzer = (repo / "Sources/Fluid/Services/AppleSpeechAnalyzerProvider.swift").read_text()
gigaam = (repo / "Sources/Fluid/Services/PichiGigaAMProvider.swift").read_text()
experiment = (repo / "Sources/Fluid/Services/DictionaryPronunciationExperiment.swift").read_text()
references = (repo / "Sources/Fluid/Services/DictionaryPronunciationReferences.swift").read_text()
negative = (repo / "Sources/Fluid/Services/DictionaryNegativeExamples.swift").read_text()

def between(source, start, end):
    index = source.index(start)
    return source[index:source.index(end, index)]

def method(source, signature):
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    for position in range(opening + 1, len(source)):
        if source[position] == "{": depth += 1
        elif source[position] == "}": depth -= 1
        if depth == 0: return source[start:position + 1]
    raise AssertionError(signature)

options = between(fluid, "    private struct DictationCaptureOptions", "\n    init(")
getters = between(fluid, "    private var effectiveExperimentalUnifiedFinalEnabled", "    /// Read the actor-owned store")
getters += method(fluid, "    private var effectiveCustomDictionaryEntries")
enhancements = between(fluid, "nonisolated struct FluidAudioProviderEnhancementOptions", "\n#if arch(arm64)")
# Compile the whole actual vocabulary store, including its existing tokenization method.
# The neighboring CTC types below perform no download, loading or inference.
vocabulary = vocabulary.replace("#if arch(arm64)\nimport FluidAudio\n#endif", "")
vocabulary = vocabulary.replace("#if arch(arm64)", "").replace("#endif", "")
evidence_reader = between(negative, "nonisolated final class DictionaryCaptureEvidenceFile", "\nnonisolated struct DictionaryAcousticEvidence")
experiment_core = between(experiment, "nonisolated enum DictionaryPronunciationExperiment", "\n/// Bounded, local-only evidence")
references_core = references.replace("#if arch(arm64)", "").replace("import FluidAudio", "").replace("#endif", "")
projection = enhancements + "\n" + evidence_reader + "\n" + experiment_core + "\n" + references_core + "\n" + vocabulary
projection += "\n@MainActor final class FluidAudioProvider {\n" + options + getters + "\n" + method(fluid, "    static func preparedEdgeProfiles(") + "\n// FLUID_TEST_FIELDS\n}\n"
projection = projection.replace("    private ", "    ")
fields = '''
    let configureWordBoosting: Bool
    var isReady = false
    let modelOverride: SettingsStore.SpeechModel?
    let meetingOptions: MeetingOptions? = nil
    let enhancementOptions: FluidAudioProviderEnhancementOptions?
    let pronunciationStore = PronunciationDictionaryStore.shared
    var pronunciationModelKey = ""
    var modelCacheRootForTesting: URL?
    var automaticPronunciationProfiles: [PronunciationDictionaryProfile] = []
    var hasEligibleExplicitPronunciationProfiles = true
    var temporalWarmRequest: Int?
    var temporalWarmTask: Task<Void, Never>?
    init(model: SettingsStore.SpeechModel? = nil, boosting: Bool = true, enhancements: FluidAudioProviderEnhancementOptions? = nil) {
        modelOverride = model; configureWordBoosting = boosting; enhancementOptions = enhancements
    }
'''
projection = projection.replace("// FLUID_TEST_FIELDS", fields)
# The selected locale getter is the actual analyzer path used by cold preparation.
analyzer_config = between(analyzer, "    private var dictationCaptureLocale:", "\n    /// Thread-safe cache")
analyzer_config += method(analyzer, "    private func selectedSpeechLocale()")
projection += "\n" + method(analyzer, "final nonisolated class AppleSpeechAnalyzerOperation") + "\n"
projection += "\n@MainActor final class AppleSpeechAnalyzerProvider { var preparedLocale: Locale?; let captureLock = NSRecursiveLock()\n" + analyzer_config.replace("    private ", "    ") + "\n}\n"

gigaam_selection = between(gigaam, "    struct Selection: Sendable", "\n    init(")
gigaam_selection += "\n" + method(gigaam, "    var directory: URL")
gigaam_selection += "\n" + method(gigaam, "    private var registeredDescriptors:")
gigaam_selection += "\n" + method(gigaam, "    func selectedArtifact()")
gigaam_selection += "\n" + method(gigaam, "    private static func locate(")
projection += "\nnonisolated final class PichiGigaAMModelStore {\n" + gigaam_selection.replace("    private ", "    ") + "\n// GIGAAM_STORE_FIELDS\n}\n"
projection = projection.replace("// GIGAAM_STORE_FIELDS", """
    static let importedModelPreferenceKey = "pichiGigaAMImportedModelID"
    static let defaultDirectory = AppBrand.modelsDirectory
    let overriddenDirectory: URL? = nil
    let environment: [String: String] = [:]
    let preferences = GigaAMPreferences()
    let downloadDescriptor = GigaAMModelDescriptor(id: "public")
    let importDescriptors = [GigaAMModelDescriptor(id: "private")]
""")
gigaam_hooks = between(gigaam, "    private var admittedSource:", "    // MARK: - Provider lifecycle")
projection += "\n@MainActor final class PichiGigaAMProvider { let modelStore: PichiGigaAMModelStore; let expectedModelFingerprint: String?; init(store: PichiGigaAMModelStore, expected: String? = nil) { modelStore = store; expectedModelFingerprint = expected }\n" + gigaam_hooks.replace("    private ", "    ") + "\n}\n"
assert "self.modelStore.ensureInstalled(selection: admittedSelection" in method(gigaam, "    func prepare(")
assert "let selection = try admittedSelection ?? self.selectedArtifact()" in method(gigaam, "    func ensureInstalled(")

after_options = fluid[fluid.index("    private var effectiveExperimentalUnifiedFinalEnabled"):]
for signature in ["    private func refreshAutomaticPronunciationProfiles", "    private func pronunciationProfiles()", "    private func warmEdgeProfile", "    private func temporalReferences"]:
    body = method(fluid, signature)
    assert "pronunciationStore." not in body, signature
assert "self.dictationCaptureOptions?.descriptor" in method(fluid, "    func prepare(")
assert "resolvedConfig: resolvedVocabulary" in method(fluid, "    func prepare(")
assert "self.dictationCaptureOptions == nil, installedHash == nil" in method(fluid, "    func prepare(")
assert "self.negativeFrames(" in method(fluid, "    private func refineEdgeMatches(")
assert "self.negativeRevision()" in method(fluid, "    private func refineEdgeMatches(")
assert "let locale = self.selectedSpeechLocale()" in method(analyzer, "    func prepare(")

with tempfile.TemporaryDirectory(prefix="pichi-fluid-capture-options-") as directory:
    directory = Path(directory)
    source = directory / "CaptureTests.swift"
    template = (repo / "Tests/FluidAudioCaptureOptionsTests.swift").read_text()
    source.write_text(template.replace("// ACTUAL_PROVIDER_CAPTURE_SOURCE", projection))
    for isolation in ([], ["-default-isolation", "MainActor"]):
        executable = directory / ("tests-actor" if isolation else "tests-default")
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5", "-strict-concurrency=targeted", "-D", "DEBUG", *isolation, "-module-cache-path", str(directory / "ModuleCache"), str(source), "-o", str(executable)], check=True, cwd=repo)
        subprocess.run([str(executable)], check=True, cwd=repo)
print("FluidAudio capture source paths: 12 checks passed")
