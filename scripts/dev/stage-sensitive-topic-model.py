#!/usr/bin/env python3
"""Reproduce and stage the frozen local v2 resource without tracking weights."""
import argparse
import hashlib
import importlib.util
from pathlib import Path

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


def stage(output):
    if output.is_symlink():
        raise ValueError('Refusing a symbolic-link resource output')
    # Reuse the original trainer in memory. Xcode only needs permission to read
    # declared inputs and write its one declared signed-resource output.
    spec = importlib.util.spec_from_file_location('sensitive_topic_trainer', ROOT / 'tools/sensitive_topic_classifier.py')
    trainer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(trainer)
    raw, cases = trainer.load_cases(ROOT / 'Tests/Fixtures/SensitiveTopics/synthetic-exploratory-v1.jsonl')
    _, _, digest = trainer.training_identity(raw)
    baseline = trainer.train(cases, digest)
    encode = lambda artifact: (trainer.json.dumps(artifact, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if hashlib.sha256(encode(baseline)).hexdigest() != BASELINE_SHA256:
        raise ValueError('Baseline topic model differs from the frozen release checksum')
    raw, cases = trainer.load_cases(ROOT / 'Tests/Fixtures/SensitiveTopics/conversational-train-development-v2.jsonl')
    _, _, digest = trainer.training_identity(raw, BASELINE_SHA256, 80, 0.3)
    artifact = trainer.train(cases, digest, initial_artifact=baseline, epochs=80, learning_rate=0.3)
    raw = encode(artifact)
    if hashlib.sha256(raw).hexdigest() != ARTIFACT_SHA256:
        raise ValueError('Generated topic model differs from the frozen release checksum')
    # Existing app resources are created by Xcode. Avoid requesting directory
    # mutations in its sandbox when only the resource file is a declared output.
    if not output.parent.is_dir():
        output.parent.mkdir(parents=True)
    if not output.is_file() or output.read_bytes() != raw:
        output.write_bytes(raw)
    verified_bytes(output, ARTIFACT_SHA256)
    print(f'Bundled topic model: {len(raw)} bytes; SHA-256 {ARTIFACT_SHA256}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    output = args.output.absolute()
    stage(output)


if __name__ == '__main__':
    main()
