"""Provenance of the vendored ONNX Runtime package that the native evaluation build compiles against."""
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
    """The vendored files whose hashes the build manifest records: the manifest, the record and every bridge header."""
    package = Path(package)
    headers = sorted((package / 'objectivec/include').glob('*.h'))
    inputs = [package / 'Package.swift', package / 'PICHI_VENDORING.md', *headers]
    missing = [str(path) for path in inputs if not path.is_file()]
    if not headers or missing:
        raise ValueError(f'the vendored package is incomplete: headers {len(headers)}, missing {missing}')
    return inputs
