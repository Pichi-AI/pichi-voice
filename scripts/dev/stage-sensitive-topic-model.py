#!/usr/bin/env python3
"""Reproduce and stage the frozen local v2 resource without tracking weights."""
import argparse
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
BASELINE_SHA256 = '394bad4607a11a55417148f1b575247e36161980581c09f9bf48fd6bafe2be9b'
ARTIFACT_SHA256 = '9952052146978b266af5d6c68855fc95161db36636711630113a4ac0f0f7c734'


def verified_bytes(path, expected):
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= 2_097_152:
        raise ValueError('Invalid generated topic resource')
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != expected:
        raise ValueError('Generated topic model differs from the frozen release checksum')
    return raw


def stage(output, work_directory):
    if output.is_symlink():
        raise ValueError('Refusing a symbolic-link resource output')
    scratch = work_directory / '.build'
    scratch.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE='1')
    trainer = ROOT / 'tools/sensitive_topic_classifier.py'
    with tempfile.TemporaryDirectory(prefix='topic-resource-', dir=scratch) as temporary:
        temporary = Path(temporary)
        baseline = temporary / 'baseline'
        continued = temporary / 'continued'
        commands = [
            [sys.executable, '-B', '-S', str(trainer), '--cases',
             str(ROOT / 'Tests/Fixtures/SensitiveTopics/synthetic-exploratory-v1.jsonl'),
             '--output-directory', str(baseline)],
            [sys.executable, '-B', '-S', str(trainer), '--cases',
             str(ROOT / 'Tests/Fixtures/SensitiveTopics/conversational-train-development-v2.jsonl'),
             '--initial-artifact', str(baseline / 'sensitive-topics-v1.json'),
             '--initial-sha256', BASELINE_SHA256, '--epochs', '80', '--learning-rate', '0.3',
             '--output-directory', str(continued)],
        ]
        for index, command in enumerate(commands):
            result = subprocess.run(command, cwd=ROOT, env=environment, capture_output=True, text=True)
            if result.returncode:
                raise RuntimeError('Topic resource training failed: ' + result.stderr.strip())
            if index == 0:
                verified_bytes(baseline / 'sensitive-topics-v1.json', BASELINE_SHA256)
        raw = verified_bytes(continued / 'sensitive-topics-v1.json', ARTIFACT_SHA256)
        # The signed product is never admitted until this build phase succeeds.
        # Write only after complete checksum verification; preserve identical output.
        output.parent.mkdir(parents=True, exist_ok=True)
        if not output.is_file() or output.read_bytes() != raw:
            output.write_bytes(raw)
        verified_bytes(output, ARTIFACT_SHA256)
    print(f'Bundled topic model: {len(raw)} bytes; SHA-256 {ARTIFACT_SHA256}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--work-directory', type=Path)
    args = parser.parse_args()
    output = args.output.absolute()
    work = args.work_directory.absolute() if args.work_directory else output.parent / '.build/topic-resource'
    stage(output, work)


if __name__ == '__main__':
    main()
