#!/usr/bin/env python3
"""Build an offline native evaluation CLI from pinned production source files.

The FluidAudio checkout must already exist in this worktree. The native packages PichiGigaAM
needs (ONNX Runtime bridge and framework, TranscribeCpp and its native framework) are built by
`swift build` of the vendored PichiGigaAM package, whose dependencies are all vendored. This
command never downloads a model, opens the app, or changes preferences; SwiftPM fetches a binary
package artifact only when its shared cache lacks it.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess

from provenance import gigaam_package_inputs, transcribe_inputs, vendored_inputs, vendored_revision

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / '.build/meeting-native-eval'
DEPS = BUILD / 'dependencies'
SOURCE = ROOT / 'Sources/Fluid/Services/Meeting'
AUDIO = ROOT / '.build/SourcePackages/checkouts/FluidAudio'
# Microsoft removed the package repository, so the application builds this vendored copy.
ORT = ROOT / 'Vendor/onnxruntime-swift-package-manager'
GIGAAM = ROOT / 'Vendor/PichiGigaAM'
TRANSCRIBE = ROOT / 'Vendor/TranscribeCpp'
PACKAGE_SCRATCH = BUILD / 'giga-package'
BASELINE = '448431f01a7941777349ca9370a2d8bf9dead69e'

def run(args):
    subprocess.run([str(x) for x in args], cwd=ROOT, check=True)

def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()

run(['bash', 'scripts/dev/assert-worktree.sh'])
BUILD.mkdir(parents=True, exist_ok=True)
revision = subprocess.check_output(['git', '-C', str(AUDIO), 'rev-parse', 'HEAD'], text=True).strip()
assert revision == 'eb1e6628998e47022799d305b52c2680d3576801', revision
# The vendored copy has no Git metadata. Its tracked record names the one upstream revision it was
# exported from, and the manifest below also hashes the bridge headers this build compiles against.
ort_revision = vendored_revision((ORT / 'PICHI_VENDORING.md').read_text())
ort_inputs = vendored_inputs(ORT)
# Build the packages PichiGigaAM imports exactly as the application resolves them, then stage their
# products. The bin path is asked from SwiftPM because it differs between build systems.
package_command = ['swift', 'build', '-c', 'release', '--package-path', GIGAAM, '--scratch-path', PACKAGE_SCRATCH]
run([*package_command, '--product', 'PichiGigaAM'])
products = Path(subprocess.check_output([str(x) for x in [*package_command, '--show-bin-path']], cwd=ROOT, text=True).strip())
if DEPS.exists():
    shutil.rmtree(DEPS)
DEPS.mkdir(parents=True)
for name in ['OnnxRuntimeBindings.o', 'TranscribeCpp.o', 'TranscribeCpp.swiftmodule', 'onnxruntime.framework', 'CTranscribe.framework']:
    assert (products / name).exists(), str(products / name)
    # Frameworks keep their Versions symlinks; copying them as plain directories would break loading.
    run(['ditto', products / name, DEPS / name])
(DEPS / 'module.modulemap').write_text('module OnnxRuntimeBindings {\numbrella "' + str(ORT / 'objectivec/include') + '"\nexport *\n}\n')
# Compile exact canonical declarations, without bringing the UI, model registry or session store
# into this offline executable. This is the same boundary used by the core's standalone tests.
contracts = 'import Foundation\ntypealias MeetingAudioTrackID = UUID\n'
runtime = (SOURCE / 'Backend/MeetingParakeetNemotronRuntime.swift').read_text()
contracts += runtime[runtime.index('nonisolated struct MeetingNemotronSpeakerSegment'):runtime.index("/// The attempt's prepared Parakeet ASR session")]
contracts += '\nnonisolated enum MeetingPCMInputError: Error { case unsupportedRuntime }\n'
errors = (SOURCE / 'Backend/MeetingProductionParakeetNemotronRuntime.swift').read_text()
start = errors.index('nonisolated enum MeetingParakeetNemotronRuntimeError')
contracts += errors[start:errors.index('/// Buffered providers', start)]
(BUILD / 'CanonicalContracts.swift').write_text(contracts)
# Retain the old production coverage/handoff baseline verbatim. Neither scorer nor Python
# reimplements speaker rules, and the new core receives only the raw coverage assignment.
legacy_path = 'Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronBackend.swift'
legacy = subprocess.check_output(['git', 'show', BASELINE + ':' + legacy_path], cwd=ROOT, text=True)
start = legacy.index('    private nonisolated static let nemotronCadenceMaximumFloorSeconds')
end = legacy.index('    #if DEBUG\n    /// Structured', start)
(BUILD / 'LegacyAttribution.swift').write_text('import Foundation\nnonisolated enum MeetingAnalysisManifestSchema { static let mappingToleranceSeconds = 0.000_001 }\nnonisolated enum LegacyAttribution {\n' + legacy[start:end] + '\n}\n')
error = (AUDIO / 'Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift').read_text()
(BUILD / 'DiarizerError.swift').write_text('import Foundation\n' + error[error.index('public enum DiarizerError'):])
helpers = [AUDIO / ('Sources/FluidAudio/Shared/' + name + '.swift') for name in ['ANEMemoryOptimizer', 'ANEMemoryUtils', 'AppLogger', 'AudioMelSpectrogram']]
run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-parse-as-library', '-emit-module', '-emit-library', '-module-name', 'FluidAudio', '-module-cache-path', BUILD / 'ModuleCache', '-emit-module-path', BUILD / 'FluidAudio.swiftmodule', '-o', BUILD / 'libFluidAudio.dylib', BUILD / 'DiarizerError.swift', *helpers])
giga_sources = sorted((ROOT / 'Vendor/PichiGigaAM/Sources/PichiGigaAM').glob('*.swift'))
run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-parse-as-library', '-emit-module', '-emit-library', '-module-name', 'PichiGigaAM', '-module-cache-path', BUILD / 'ModuleCache', '-emit-module-path', BUILD / 'PichiGigaAM.swiftmodule', '-I', DEPS, '-F', DEPS, '-profile-generate', '-framework', 'onnxruntime', '-framework', 'CTranscribe', '-lc++', '-lz', '-framework', 'Accelerate', '-framework', 'CoreML', '-framework', 'Metal', '-framework', 'MetalKit', '-Xlinker', '-rpath', '-Xlinker', str(DEPS), DEPS / 'OnnxRuntimeBindings.o', DEPS / 'TranscribeCpp.o', *giga_sources, '-o', BUILD / 'libPichiGigaAM.dylib'])
sources = [BUILD / 'CanonicalContracts.swift', SOURCE / 'Backend/MeetingCanonicalEvidenceTypes.swift', BUILD / 'LegacyAttribution.swift', SOURCE / 'Backend/MeetingResumableNemotronDiarizerSession.swift', *sorted((SOURCE / 'Backend/Nemotron3').glob('*.swift')), SOURCE / 'Backend/MeetingFast32NemotronDiarizer.swift', SOURCE / 'Backend/MeetingSpeakerAttribution.swift', ROOT / 'tools/meeting-native-eval/Runner.swift']
run(['xcrun', 'swiftc', '-O', '-swift-version', '5', '-parse-as-library', '-default-isolation', 'MainActor', '-module-cache-path', BUILD / 'ModuleCache', '-I', BUILD, '-I', DEPS, '-F', DEPS, '-L', BUILD, '-lFluidAudio', '-lPichiGigaAM', '-framework', 'onnxruntime', '-lc++', '-framework', 'Accelerate', '-Xlinker', '-rpath', '-Xlinker', str(BUILD), '-Xlinker', '-rpath', '-Xlinker', str(DEPS), *sources, '-o', BUILD / 'runner'])
manifest = {'schema_version': 1, 'source_revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'baseline_revision': BASELINE, 'fluid_audio_revision': revision, 'onnx_runtime_revision': ort_revision, 'sources': {str(path.relative_to(ROOT)): sha(path) for path in [*sources, *helpers, *giga_sources, *gigaam_package_inputs(GIGAAM), *ort_inputs, *transcribe_inputs(TRANSCRIBE), *sorted((ROOT / 'tools/meeting-native-eval').glob('*.py'))]}, 'baseline_original_source_sha256': hashlib.sha256(legacy.encode()).hexdigest(), 'binary_sha256': sha(BUILD / 'runner'), 'onnx_bridge_sha256': sha(DEPS / 'OnnxRuntimeBindings.o'), 'onnx_runtime_sha256': sha(DEPS / 'onnxruntime.framework/Versions/A/onnxruntime'), 'transcribe_cpp_bridge_sha256': sha(DEPS / 'TranscribeCpp.o'), 'transcribe_cpp_native_sha256': sha(DEPS / 'CTranscribe.framework/Versions/A/CTranscribe')}
(BUILD / 'build-manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
print('Native evaluation runner built; no inference performed.')
