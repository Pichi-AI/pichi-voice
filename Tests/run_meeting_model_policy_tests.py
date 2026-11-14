#!/usr/bin/env python3
"""Exercise production meeting model policy without models, capture, or user preferences."""
import os
from pathlib import Path
import subprocess
import tempfile
from Standalone.ProbeContractDependencies import declaration, meeting_metadata, parakeet_metadata, speech_model_cases, brand_text

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    developer = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(["xcode-select", "-p"], text=True).strip()
    if not (Path(developer) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Full Xcode is required; set DEVELOPER_DIR to an installed Xcode.app.")
    env = dict(os.environ, DEVELOPER_DIR=developer)
    provider = (ROOT / "Sources/Fluid/Services/FluidAudioProvider.swift").read_text()
    config = (ROOT / "Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift").read_text()
    pipeline = (ROOT / "Sources/Fluid/Services/Meeting/MeetingProcessingPipeline.swift").read_text()
    swift = '''import CryptoKit
import Foundation
enum SettingsStore {
    SPEECH_MODEL_CASES
}
enum MeetingProcessingCheckpoint { static let currentDiarizationFingerprint = "fixture" }
@MainActor enum SpeechModelInstallationSnapshot {
    struct Probe { enum Kind { case parakeet(ParakeetSpeechModelCatalog.Descriptor) }; let modelID: String; let kind: Kind }
    static var installed: Set<String> = []
    static var observed: [String] = []
    static var failure = false
    static func scan(_ probes: [Probe]) async throws -> Set<String> {
        observed = probes.map(\\.modelID)
        if failure { throw CocoaError(.fileReadUnknown) }
        await Task.yield()
        return installed
    }
}
'''.replace("SPEECH_MODEL_CASES", speech_model_cases())
    checkpoint = declaration((ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text(), "nonisolated struct MeetingProcessingCheckpoint:")
    fingerprint = checkpoint.split("static let currentDiarizationFingerprint =", 1)[1].split("\n\n", 1)[0].strip()
    swift = swift.replace('static let currentDiarizationFingerprint = "fixture"', 'static let currentDiarizationFingerprint = ' + fingerprint)
    swift += (ROOT / "Sources/Fluid/Localization/PichiLocalization.swift").read_text() + brand_text()
    swift += parakeet_metadata() + meeting_metadata()
    models = (ROOT / "Sources/Fluid/Services/Meeting/MeetingModels.swift").read_text()
    for marker in ["nonisolated enum MeetingSpeakerProcessingMode:", "nonisolated enum MeetingRecordingTimePolicy:"]:
        swift += declaration(models, marker) + "\n"
    attribution = (ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift").read_text()
    swift += declaration(attribution, "nonisolated enum MeetingSpeakerAttributionError:") + "\n"
    swift += declaration(attribution, "nonisolated struct MeetingSpeakerAttributionPolicy:") + "\n"

    settings = (ROOT / "Sources/Fluid/Persistence/SettingsStoreMeetingPreferences.swift").read_text()
    swift = swift.replace("enum SettingsStore {", "enum SettingsStore {\n" + declaration(settings, "nonisolated struct CustomDictionaryEntry:"), 1)
    for marker in ["nonisolated enum MeetingProviderOptionsError", "nonisolated struct MeetingProviderOptions"]:
        swift += declaration(provider, marker) + "\n"
    for marker in ["nonisolated struct MeetingFinalProcessingConfiguration", "nonisolated struct MeetingLiveCaptionsConfiguration"]:
        swift += declaration(config, marker) + "\n"
    swift += declaration((ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingCanonicalEvidenceTypes.swift").read_text(), "nonisolated enum MeetingConfigFingerprintEncoding") + "\n"
    version = next(line.strip() for line in pipeline.splitlines() if "nonisolated static let pipelineVersion =" in line)
    swift += "@MainActor enum MeetingProcessingPipeline { " + version + "\n"
    swift += declaration(pipeline, "static func defaultPreferredASRModel()") + "\n}\n"
    swift += '''
@main struct Run {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        let pro = "fluid-parakeet-pro", v3 = "parakeet-tdt"
        for (installed, expected): (Set<String>, SettingsStore.SpeechModel) in [
            ([pro, v3], .fluidParakeetPro), ([pro], .fluidParakeetPro), ([v3], .parakeetTDT),
            ([], .fluidParakeetPro), (["parakeet-tdt-v2", "whisper-tiny"], .fluidParakeetPro)
        ] {
            SpeechModelInstallationSnapshot.installed = installed
            let model = try await MeetingProcessingPipeline.defaultPreferredASRModel()
            check(model == expected, "Installation policy")
            check(SpeechModelInstallationSnapshot.observed == [pro, v3], "Only the two meeting models are scanned")
            for language in VoiceEngineLanguageCatalog.parakeetV3LanguageIDs {
                let config = MeetingFinalProcessingConfiguration(preferredASRModel: model, languageCode: language)
                let options = try MeetingProviderOptions.resolve(config)
                check(options.model == expected && config.languageCode == language, "Selected model and language are pinned")
                check(!options.vocabularyBoostingEnabled && !options.pronunciationMatchingEnabled && !options.customDictionaryRewritingEnabled && !options.experimentalUnifiedFinalEnabled, "No dictation enhancements")
            }
        }
        let frozen = MeetingFinalProcessingConfiguration(preferredASRModel: .parakeetTDT, languageCode: "de")
        SpeechModelInstallationSnapshot.installed = [pro]
        let next = try await MeetingProcessingPipeline.defaultPreferredASRModel()
        check(next == .fluidParakeetPro && frozen.asrModel == v3 && frozen.languageCode == "de", "Installation changes affect only later requests")
        check(frozen.identityFingerprint != MeetingFinalProcessingConfiguration(languageCode: "de").identityFingerprint, "Fallback uses its own resume fingerprint")
        check(MeetingFinalProcessingConfiguration().languageCode == "en", "English remains the initial language")
        check(MeetingFinalProcessingConfiguration().asrModel == MeetingProviderOptions.preferredModel(for: "en", selected: nil).rawValue, "Default model identity follows the actual language policy")
        let legacy = MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v2", preferredASRModel: .fluidParakeetPro)
        check(try MeetingProviderOptions.resolve(legacy).model == .parakeetTDTv2, "Registered English V2 retains the actual saved model")
        do {
            _ = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(asrModel: "unknown-synthetic-model"))
            preconditionFailure("Unregistered models must be rejected")
        } catch MeetingProviderOptionsError.unsupportedASRModel("unknown-synthetic-model") { checks += 1 }
        do {
            _ = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(asrModel: "parakeet-tdt-v2", languageCode: "de"))
            preconditionFailure("V2 cannot accept unsupported languages")
        } catch MeetingProviderOptionsError.unsupportedLanguageCode("de") { checks += 1 }
        for language in VoiceEngineLanguageCatalog.parakeetV3LanguageIDs {
            let redirected = MeetingFinalProcessingConfiguration(preferredASRModel: .parakeetTDTv2, languageCode: language)
            check(try MeetingProviderOptions.resolve(redirected).model == (language == "en" ? .parakeetTDTv2 : .fluidParakeetPro), "V2 preference stays pinned only for its supported language")
        }
        let saved = MeetingBackendID.legacyCompatibility
        check(saved.forNewMeetingAttempt == .productionDefault, "Old rollback settings use current model policy")
        check(saved == .legacyCompatibility, "The old preference is not rewritten")
        let restored = try JSONDecoder().decode(MeetingBackendID.self, from: JSONEncoder().encode(saved))
        check(restored == saved, "Historical backend identifiers still decode")
        check(MeetingBackendID.parakeetNemotron.forNewMeetingAttempt == .parakeetNemotron, "Current backend remains selected")
        let unknown = MeetingBackendID(rawValue: "unknown")
        check(unknown.forNewMeetingAttempt == unknown, "Unknown selections stay fail-closed")
        do {
            _ = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(languageCode: "zh"))
            preconditionFailure("Unsupported language must fail")
        } catch MeetingProviderOptionsError.unsupportedLanguageCode { checks += 1 }
        SpeechModelInstallationSnapshot.failure = true
        do {
            _ = try await MeetingProcessingPipeline.defaultPreferredASRModel()
            preconditionFailure("Discovery failure must not become a default")
        } catch is CocoaError { checks += 1 }
        SpeechModelInstallationSnapshot.failure = false
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MeetingProcessingPipeline.defaultPreferredASRModel()
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancellation must propagate") }
        catch is CancellationError { checks += 1 }
        check(MeetingLiveCaptionsConfiguration().modelRepositoryID == "FluidInference/parakeet-realtime-eou-120m-coreml", "Streaming captions remain separate")
        print("PASS: \\(checks) meeting model policy checks")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="fluidvoice-meeting-model-") as directory:
        path = Path(directory)
        (path / "ModelPolicy.swift").write_text(swift)
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6", str(path / "ModelPolicy.swift"), "-o", str(path / "checks")], env=env, check=True)
        subprocess.run([str(path / "checks")], env=env, check=True)


if __name__ == "__main__":
    main()
