"""Provenance of the vendored packages (ONNX Runtime, PichiGigaAM, TranscribeCpp) that the native evaluation build compiles against."""
from pathlib import Path
import re

REVISION = re.compile(r'`([0-9a-f]{40})`')


def vendored_revision(record):
    """The one upstream Git revision that a vendoring record names in backticks.

    A record without one, or with two different ones, cannot say which upstream tree was imported."""
    revisions = sorted(set(REVISION.findall(record)))
    if len(revisions) != 1:
        raise ValueError(f'the vendoring record must name exactly one 40-character upstream revision, found {revisions}')
    return revisions[0]


def vendored_inputs(package):
    """The vendored files whose hashes the build manifest records: the manifest, the record, every public bridge
    header and the bridge sources (Objective-C++ files and internal headers) that the package build compiles."""
    package = Path(package)
    headers = sorted((package / 'objectivec/include').glob('*.h'))
    bridge = sorted([*(package / 'objectivec').glob('*.h'), *(package / 'objectivec').glob('*.mm')])
    inputs = [package / 'Package.swift', package / 'PICHI_VENDORING.md', *headers, *bridge]
    missing = [str(path) for path in inputs if not path.is_file()]
    if not headers or missing:
        raise ValueError(f'the vendored package is incomplete: headers {len(headers)}, missing {missing}')
    return inputs


def _complete(inputs, what):
    missing = [str(path) for path in inputs if not path.is_file()]
    if missing:
        raise ValueError(f'the {what} is incomplete, missing {missing}')
    return inputs


def gigaam_package_inputs(package):
    """The manifest that selects PichiGigaAM's packages, resources and linked frameworks, and the
    resource files SwiftPM copies into the target's bundle (the GigaAM graph recipes)."""
    package = Path(package)
    resources = sorted(path for path in (package / 'Sources/PichiGigaAM/Resources').glob('*') if path.is_file())
    return _complete([package / 'Package.swift', *resources], 'vendored PichiGigaAM package')


def transcribe_inputs(package):
    """The vendored TranscribeCpp files whose hashes the build manifest records.

    The Swift bindings are compiled by the package build, and the prebuilt native library is only
    the xcframework archive, so its recorded pin (`Artifacts/manifest.json`) and archive bytes
    both belong to the inputs."""
    package = Path(package)
    sources = sorted((package / 'Sources/TranscribeCpp').glob('*.swift'))
    inputs = [package / 'Package.swift', package / 'UPSTREAM.md', package / 'Artifacts/manifest.json',
              package / 'Artifacts/TranscribeCpp.xcframework.zip', *sources]
    if not sources:
        raise ValueError('the vendored TranscribeCpp package has no Swift sources')
    return _complete(inputs, 'vendored TranscribeCpp package')
