"""Actual-source dependencies shared only by the nine upstream contract runners.

Projection omits inference construction and filesystem installation operations, never policy.
No runner or application is launched by importing this module.
"""
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]

def declaration(source, marker):
    start = source.index(marker)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def array_literal(source, marker):
    start = source.index('[', source.index(marker) + len(marker))
    depth, end = 1, start + 1
    while depth:
        depth += (source[end] == '[') - (source[end] == ']')
        end += 1
    return source[start:end]

def meeting_metadata():
    # Use the compiled provider's actual metadata/default policy, without importing
    # inference adapters or making model installation queries in this UI probe.
    factory_source = (ROOT / "Sources/Fluid/Services/Meeting/PichiMeetingProviderFactory.swift").read_text()
    factory = factory_source[factory_source.index("enum PichiMeetingProviderFactory {"):
                             factory_source.index("    static func validateRecordingConfiguration(")] + "}\n"
    for field in ("providerFactory", "configurationSnapshot", "modelsExistOnDisk",
                  "admissionArtifactFingerprint", "installedArtifactFingerprint"):
        factory = "\n".join(line for line in factory.splitlines()
                            if not line.strip().startswith((f"let {field}:", f"var {field}:")))
        while f"{field}: {{" in factory:
            clause = declaration(factory, f"{field}: {{")
            factory = factory.replace(clause + ",", "").replace(clause, "")
    factory = factory.replace(declaration(factory, "    static func registeredModelsExistOnDisk("), "")
    factory = factory.replace(declaration(factory, "    private nonisolated static var whisperArtifactDirectory:"), "")
    # Retranscription model choices (not read by setup restoration) pull in the Parakeet
    # provider options and the full model catalogue; omit that one list.
    factory = factory.replace(declaration(factory, "    nonisolated static var retranscriptionModels:"), "")
    # Runtime profile wiring is not read by setup/default-language restoration.
    # Keep descriptor capabilities below, without importing inference model locators.
    factory = "\n".join(line for line in factory.splitlines()
                        if not line.strip().startswith(("let speakerProcessingProfiles:", "speakerProcessingProfiles:")))
    # The shared Parakeet registration builds those profiles in a local before the descriptor (138).
    profiles_marker = "        let profiles: [MeetingSpeakerProcessingMode: MeetingNemotronModelProfile] = ["
    while profiles_marker in factory:
        begin = factory.index(profiles_marker)
        factory = factory[:begin] + factory[factory.index("\n        ]\n", begin) + len("\n        ]\n"):]
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
    for marker in ("    func validatePCMInput(configuration:", "    func validatePCMInput(_ request:",
                   "    func validateSpeakerProcessingMode(configuration:"):
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
    metadata += "\n" + declaration((ROOT / "Sources/Fluid/Services/Meeting/Backend/MeetingCanonicalEvidenceTypes.swift").read_text(),
                                   "nonisolated enum MeetingTextUnitPrecision:") + "\n"
    return metadata + factory

def speech_model_cases():
    settings = (ROOT / 'Sources/Fluid/Persistence/SettingsStore.swift').read_text()
    model = declaration(settings, 'enum SpeechModel:')
    # Preserve all actual enum identities. Computed UI/runtime properties are not read here.
    return 'enum SpeechModel: String, Codable, Sendable {\n' + '\n'.join(
        line for line in model.splitlines() if line.startswith('        case ') and not line.strip().startswith('case .')) + '\n}\n'

def parakeet_metadata():
    catalog = (ROOT / 'Sources/Fluid/Services/ParakeetSpeechModelCatalog.swift').read_text()
    # The actual registry and descriptors compile unchanged except explicit disk operations.
    for marker in ['func artifactsAreComplete(', 'func installedArtifactFingerprint(',
                   'func installationRevisionMatches(', 'func installedArchiveSHA256(',
                   'func installedManifestSHA256(', 'func writeInstallationRevision(',
                   'static func descriptor(forInstalledPronunciationModelKey',
                   'static func isOutdatedCompactPronunciationModelKey']:
        catalog = catalog.replace(declaration(catalog, marker), '')
    return catalog

def communication_metadata():
    """Actual module registry/profiles; omit only uncalled hardware adapter factories."""
    folder = ROOT / 'Sources/Fluid/Services/Meeting/Observation'
    host = (folder / 'MeetingCommunicationModuleHost.swift').read_text()
    host = host.replace(declaration(host, '    func resolve(_ snapshot:'), '')
    host = host.replace(declaration(host, '    static func makeMicrophoneDriver('), '')
    host = '\n'.join(line for line in host.splitlines() if not any(part in line for part in (
        'typealias RenderedFactory', 'var renderedFactory:', 'var nativeCallStatusFactory:',
        'renderedFactory: MeetingCommunicationModuleRegistration.RenderedFactory?',
        'nativeCallStatusFactory: (@Sendable () -> any MeetingRenderedAudioStatusObserving)?',
    )))
    host = host.replace('renderedFactory: renderedFactory, ', '').replace('nativeCallStatusFactory: nativeCallStatusFactory, ', '')
    for path in sorted((folder / 'Modules').glob('*.swift')):
        module = path.read_text()
        for marker in ['renderedFactory: {', 'nativeCallStatusFactory: {']:
            while marker in module:
                clause = declaration(module, marker) + ','
                if clause not in module:
                    raise ValueError(f'Unterminated hardware factory: {path.name} {marker}')
                module = module.replace(clause, '')
        host += '\n' + module
    return host

def brand_text():
    """Production brand text operations with an inert neutral profile and no stores."""
    brand = (ROOT / 'Sources/Fluid/Branding/AppBrand.swift').read_text()
    result = declaration(brand, 'nonisolated struct BrandProfile:')
    result += '\nnonisolated enum AppBrand {\nstatic var profile: BrandProfile { .neutral }\n'
    for marker in ['static func text(_ source: String)', 'static func text(_ source: String, profile:',
                   'static func substitutingProductNames(']:
        result += declaration(brand, marker) + '\n'
    return result + '}\n'
