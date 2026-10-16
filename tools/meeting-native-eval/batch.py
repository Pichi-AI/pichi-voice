#!/usr/bin/env python3
"""Run a frozen private corpus through the offline native executable, without a network.

Audio inference runs once per clip; later passes reuse its immutable original native evidence.
A new policy/source revision gets a new pass directory, never overwritten baseline artifacts.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import wave

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / '.build/meeting-native-eval'

def sha(path):
    digest = hashlib.sha256()
    with Path(path).open('rb') as handle:
        while data := handle.read(1024 * 1024):
            digest.update(data)
    return digest.hexdigest()

def read(path):
    return json.loads(Path(path).read_text())

def write(path, value):
    temporary = path.with_name(path.name + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)

def command(args, directory, name, timeout):
    env = dict(os.environ, LLVM_PROFILE_FILE='/dev/null')
    began = time.monotonic()
    with (directory / (name + '.stdout.log')).open('x') as stdout, (directory / (name + '.stderr.log')).open('x') as stderr:
        result = subprocess.run([str(x) for x in args], cwd=ROOT, env=env, stdout=stdout, stderr=stderr, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'Native {name} failed with exit {result.returncode}; see private logs')
    return time.monotonic() - began

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--selection-lock', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--pass-name', required=True)
    parser.add_argument('--gigaam-directory', required=True, type=Path)
    parser.add_argument('--fast32-directory', required=True, type=Path)
    parser.add_argument('--policy', type=Path)
    parser.add_argument('--compute', choices=['preferred', 'cpuAndGPU', 'cpuAndNeuralEngine', 'cpuOnly'], default='preferred')
    parser.add_argument('--split', choices=['development', 'heldOut', 'all'], default='development')
    parser.add_argument('--clip-timeout', type=int, default=900)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', args.pass_name):
        raise ValueError('Unsafe pass name')
    if not 1 <= args.clip_timeout <= 3600:
        raise ValueError('Invalid timeout')
    manifest_hash = sha(args.manifest)
    manifest, lock = read(args.manifest), read(args.selection_lock)
    if lock.get('status') != 'frozen' or lock.get('corpus_manifest_sha256') != manifest_hash:
        raise ValueError('Corpus selection and whole-meeting holdout split must be frozen before inference')
    clips = manifest['clips']
    if manifest.get('schema_version') != 1 or len(clips) < 20:
        raise ValueError('At least 20 distinct actual audio clips are required')
    ids, audios, meetings, dev_meetings, held_meetings = set(), set(), set(), set(), set()
    split_counts = {'development': 0, 'heldOut': 0}
    for clip in clips:
        name = clip['clip_id']
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,95}', name) or name in ids:
            raise ValueError('Duplicate or unsafe clip ID')
        ids.add(name)
        path = Path(clip['audio_path'])
        if not path.is_absolute() or path.is_symlink() or not path.is_file():
            raise ValueError('A regular absolute private PCM audio path is required')
        if sha(path) != clip['audio_sha256'] or clip['audio_sha256'] in audios:
            raise ValueError('Changed or duplicate audio')
        audios.add(clip['audio_sha256'])
        with wave.open(str(path), 'rb') as audio:
            if (audio.getframerate(), audio.getnchannels(), audio.getsampwidth()) != (16000, 1, 2):
                raise ValueError('Expected mono PCM16 at 16kHz')
            duration = audio.getnframes() / audio.getframerate()
            if abs(duration - clip['duration_seconds']) > 1 / 16000:
                raise ValueError('Audio duration differs from frozen selection')
        split = clip['split']
        if split not in split_counts:
            raise ValueError('Unknown corpus split')
        split_counts[split] += 1
        meetings.add(clip['meeting_id'])
        (dev_meetings if split == 'development' else held_meetings).add(clip['meeting_id'])
        reference = Path(clip['weak_reference_path'])
        if sha(reference) != clip['weak_reference_sha256']:
            raise ValueError('Reference changed after selection was frozen')
    if dev_meetings & held_meetings or split_counts['development'] < 12 or split_counts['heldOut'] < 8:
        raise ValueError('Require at least 12 development and 8 whole-meeting held-out clips without leakage')
    if len(meetings) < 5:
        raise ValueError('Corpus must include different meetings')
    if sum(clip.get('observed_weak_speaker_count') == 2 for clip in clips) < 10:
        raise ValueError('At least half of the clips must cover the common two-speaker case')
    build = read(BUILD / 'build-manifest.json')
    if sha(BUILD / 'runner') != build['binary_sha256']:
        raise ValueError('Native runner differs from build manifest')
    args.output.mkdir(parents=True, exist_ok=True)
    evidence_dir = args.output / 'evidence'
    evidence_dir.mkdir(exist_ok=True)
    pass_dir = args.output / args.pass_name
    pass_dir.mkdir(exist_ok=False)
    run = {'schema_version': 1, 'status': 'running', 'pass_name': args.pass_name, 'split': args.split,
           'corpus_manifest_sha256': manifest_hash, 'selection_lock_sha256': sha(args.selection_lock),
           'build_manifest': build, 'requested_compute': args.compute,
           'policy_sha256': sha(args.policy) if args.policy else None,
           'reference_status': 'automatic_weak_not_human_gold', 'cases': []}
    write(pass_dir / 'run-manifest.json', run)
    try:
        for clip in clips:
            if args.split != 'all' and clip['split'] != args.split:
                continue
            name = clip['clip_id']
            evidence_path = evidence_dir / (name + '.json')
            inference_seconds = None
            if not evidence_path.exists():
                inference_seconds = command([BUILD / 'runner', 'infer', clip['audio_path'], args.gigaam_directory,
                    args.fast32_directory, evidence_path, name, args.compute], pass_dir, name + '-infer', args.clip_timeout)
            evidence = read(evidence_path)
            if evidence['clipID'] != name or evidence['audioSHA256'] != clip['audio_sha256']:
                raise ValueError('Evidence cache does not match this corpus clip')
            result_path = pass_dir / (name + '.json')
            replay = [BUILD / 'runner', 'replay', evidence_path, result_path]
            if args.policy:
                replay.append(args.policy)
            replay_seconds = command(replay, pass_dir, name + '-replay', args.clip_timeout)
            result = read(result_path)
            if not result['deterministicRepeatEqual'] or result['unchangedOriginalUnitCount'] != len(evidence['units']):
                raise ValueError('Core replay changed evidence or failed deterministic repeat')
            run['cases'].append({'clip_id': name, 'meeting_id': clip['meeting_id'], 'split': clip['split'],
                'evidence_path': str(evidence_path), 'evidence_sha256': sha(evidence_path),
                'result_path': str(result_path), 'result_sha256': sha(result_path),
                'native_inference_seconds_this_pass': inference_seconds, 'replay_process_seconds': replay_seconds,
                'word_count': len(evidence['units']), 'activity_interval_count': len(evidence['activity']),
                'policy_fingerprint': result['policyFingerprint']})
            write(pass_dir / 'run-manifest.json', run)
            print(f"PASS {name} native={inference_seconds is not None} units={len(evidence['units'])}", flush=True)
        run['status'] = 'complete'
    except BaseException as error:
        run['status'] = 'failed'
        run['failure_type'] = type(error).__name__
        raise
    finally:
        write(pass_dir / 'run-manifest.json', run)

if __name__ == '__main__':
    main()
