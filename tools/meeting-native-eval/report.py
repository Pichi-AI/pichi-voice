#!/usr/bin/env python3
"""Create an offline private evidence viewer. Never derives or changes speaker decisions."""
import argparse
import array
import base64
import collections
import hashlib
import html
import json
import math
from pathlib import Path
import re
import shutil
import sys
import wave

ASSETS = Path(__file__).with_name('report_assets')


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for block in iter(lambda: f.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def read_verified(path, expected=None):
    path = Path(path)
    actual = digest(path)
    if expected and actual != expected:
        raise ValueError(f'SHA-256 mismatch: {path}')
    return json.loads(path.read_text()), actual


def token_key(token):
    if token is None:
        return None
    epoch = token['analysisEpochID']
    return f"{epoch['trackID']}:{epoch['ordinal']}:{epoch['generation']}:{token['label']}"


def timing(start, end, duration):
    if not all(isinstance(x, (int, float)) and math.isfinite(x) for x in (start, end)):
        raise ValueError('Nonfinite native time')
    if start < 0 or end <= start or end > duration + 0.001:
        raise ValueError(f'Invalid native time {start}..{end}, duration {duration}')


def waveform(path, buckets=2400):
    with wave.open(str(path), 'rb') as f:
        if (f.getnchannels(), f.getsampwidth(), f.getframerate()) != (1, 2, 16000):
            raise ValueError('Viewer expects frozen mono 16 kHz PCM16 WAV')
        samples = array.array('h', f.readframes(f.getnframes()))
    if sys.byteorder != 'little':
        samples.byteswap()
    step = max(1, math.ceil(len(samples) / buckets))
    return [round(max(abs(x) for x in samples[i:i+step]) / 32768, 5)
            for i in range(0, len(samples), step)]


def assignment_token(assignment):
    return assignment.get('token') if assignment.get('kind') == 'assigned' else None


def compact_metrics(metrics, candidate):
    """Keep displayed denominators, not repeated per-word forensic listings."""
    variants = {}
    for name in dict.fromkeys(['baseline4484', candidate]):
        source = metrics['variants'][name]
        profiles = {}
        for profile in ['strictWeak', 'interior1s', 'interior2s']:
            value = source['profiles'][profile]
            profiles[profile] = {k: value[k] for k in ['counts', 'eligible_words', 'excluded_words']}
        variants[name] = {'all_unknown_words': source['all_unknown_words'], 'profiles': profiles,
                          'rule_counts': source.get('rule_counts', {})}
    return {'variants': variants,
            'weak_activity_timeline_diagnostic': metrics.get('weak_activity_timeline_diagnostic', {})}


def make_case(case, candidate, out, copy_audio):
    evidence, evidence_sha = read_verified(case['native_evidence_path'], case.get('native_evidence_sha256'))
    replay_path = case['core_replay_paths'][candidate]
    replay, replay_sha = read_verified(replay_path)
    if replay.get('evidenceSHA256') != evidence_sha:
        raise ValueError(f'Replay/evidence digest mismatch for {case["clip_id"]}')
    if not replay.get('deterministicRepeatEqual'):
        raise ValueError('Nondeterministic replay cannot be labeled verified')
    reference, reference_sha = read_verified(case['weak_reference_path'], case.get('weak_reference_sha256'))
    audio_path = Path(case['audio_path'])
    if digest(audio_path) != case['audio_sha256']:
        raise ValueError('Audio SHA-256 mismatch')
    if evidence['audioSHA256'] != case['audio_sha256']:
        raise ValueError('Evidence/audio SHA-256 mismatch')
    duration = case['duration_seconds']
    if abs(evidence['sampleCount'] / evidence['sampleRate'] - duration) > 1e-9:
        raise ValueError('Native evidence duration mismatch')
    units = evidence['units']
    decisions = {d['unitID']: d for d in replay['resolution']['decisions']}
    if len(decisions) != len(units) or len(set(u['id'] for u in units)) != len(units):
        raise ValueError('Native units and decision IDs must be unique and complete')
    tokens = {}
    for activity in evidence['activity']:
        timing(activity['start'], activity['end'], duration)
        tokens[token_key(activity['token'])] = activity['token']
    labels = reference.get('speaker_labels', {})
    mapping = case['frozen_native_to_weak_reference_mapping']
    display = {}
    for key, token in tokens.items():
        weak = mapping.get(token['label'])
        display[key] = {'nativeLabel': token['label'], 'weakSlot': weak,
                        'name': labels.get(str(weak)) if weak is not None else None,
                        'epoch': token['analysisEpochID']}
    words = []
    baseline = evidence['baselineAssignments']
    if len(baseline) != len(units):
        raise ValueError('Historical baseline length mismatch')
    for unit, old in zip(units, baseline):
        timing(unit['analysisStart'], unit['analysisEnd'], duration)
        decision = decisions[unit['id']]
        if decision['policyFingerprint'] != replay['policyFingerprint']:
            raise ValueError('Mixed policy fingerprints in replay')
        for token in [decision.get('selectedToken'), *decision.get('backgroundTokens', [])]:
            if token and token_key(token) not in display:
                raise ValueError('Decision refers to unknown source token')
        words.append({'id': unit['id'], 'start': unit['analysisStart'], 'end': unit['analysisEnd'],
                      'text': unit['text'], 'precision': unit['precision'],
                      'asrRaw': unit['speaker'], 'baseline': old,
                      'baselineToken': token_key(assignment_token(old)),
                      'selected': token_key(decision.get('selectedToken')),
                      'raw': token_key(assignment_token(decision['rawAssignment'])),
                      'background': [token_key(x) for x in decision.get('backgroundTokens', [])],
                      'decision': decision})
    safe_id = re.sub(r'[^A-Za-z0-9_-]', '_', case['clip_id'])
    if safe_id != case['clip_id']:
        raise ValueError('clip_id must be a safe portable filename')
    if copy_audio:
        relative_audio = f'audio/{safe_id}.wav'
        target = out / relative_audio
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists() or digest(target) != case['audio_sha256']:
            shutil.copy2(audio_path, target)
    else:
        relative_audio = audio_path.as_uri()
    return {'id': case['clip_id'], 'meeting': case['meeting_id'], 'split': case['split'],
            'language': case['language_condition'], 'weakSpeakerCount': case['weak_speaker_count'],
            'nativeSlotCount': case.get('native_anonymous_activity_slots'),
            'duration': duration, 'sourceStart': case['source_start_seconds'],
            'sourceEnd': case['source_end_seconds'], 'audio': relative_audio,
            'waveform': waveform(audio_path), 'tokens': display, 'words': words,
            'activity': [{'start': a['start'], 'end': a['end'], 'token': token_key(a['token'])}
                         for a in evidence['activity']],
            'reference': reference, 'metrics': compact_metrics(case['case_metrics'], candidate),
            'policy': replay['policy'], 'policyFingerprint': replay['policyFingerprint'],
            'metadata': evidence['metadata'],
            'proof': {'evidenceSHA256': evidence_sha, 'replaySHA256': replay_sha,
                      'audioSHA256': case['audio_sha256'], 'referenceSHA256': reference_sha,
                      'mapping': mapping, 'deterministicRepeatEqual': replay['deterministicRepeatEqual']}}


def build(index_path, candidate, output, status, physical_path=None, copy_audio=True, notes_path=None, text_quality_path=None):
    index, index_sha = read_verified(index_path)
    output = Path(output)
    output.mkdir(parents=True, exist_ok=True)
    manifest, manifest_sha = read_verified(index['corpus_manifest_path'], index['corpus_manifest_sha256'])
    frozen = {c['clip_id']: c for c in manifest['clips']}
    ids = [c['clip_id'] for c in index['cases']]
    if len(set(ids)) != len(ids):
        raise ValueError('Duplicate clip IDs in report index')
    for case in index['cases']:
        source = frozen[case['clip_id']]
        for key in ['meeting_id', 'split', 'language_condition', 'duration_seconds', 'source_start_seconds',
                    'source_end_seconds', 'audio_sha256', 'weak_reference_sha256']:
            if source[key] != case[key]:
                raise ValueError(f'Report/frozen corpus mismatch: {case["clip_id"]}/{key}')
    cases = [make_case(c, candidate, output, copy_audio) for c in index['cases']]
    if not cases:
        raise ValueError('Report has no actual cases')
    if len({c['meeting'] for c in cases}) != len(cases):
        raise ValueError('This corpus requires different recordings for every case')
    if status == 'final' and len(cases) < 20:
        raise ValueError('Final report requires at least 20 actual cases')
    if len({c['policyFingerprint'] for c in cases}) != 1:
        raise ValueError('Freeze one candidate policy across the corpus')
    if status == 'final' and set(ids) != set(frozen):
        raise ValueError('Final report must include every frozen corpus case')
    physical = None
    physical_sha = None
    if physical_path:
        physical, physical_sha = read_verified(physical_path)
    text_quality = None
    text_quality_sha = None
    if text_quality_path:
        text_quality, text_quality_sha = read_verified(text_quality_path)
        if text_quality.get('manifest_sha256') != manifest_sha:
            raise ValueError('Text-quality corpus digest mismatch')
        by_id = {c['clip_id']: c for c in text_quality['clips']}
        if len(by_id) != len(cases):
            raise ValueError('Text-quality case coverage mismatch')
        for case in cases:
            q = by_id[case['id']]
            if q['native_evidence_sha256'] != case['proof']['evidenceSHA256'] or q['reference_sha256'] != case['proof']['referenceSHA256']:
                raise ValueError('Text-quality evidence/reference digest mismatch')
    notes = Path(notes_path).read_text() if notes_path else ''
    data = {'schemaVersion': 1, 'status': status, 'candidate': candidate,
            'indexStatus': index.get('status'), 'indexSHA256': index_sha,
            'sourceCommit': index.get('native_source_commit'), 'coreSHA256': index.get('core_source_sha256'),
            'corpusSHA256': manifest_sha, 'corpusCount': len(manifest['clips']),
            'participantDisjoint': manifest.get('participant_disjoint'),
            'cases': cases,
            'host': index.get('host_measurement_summary'), 'physical': physical,
            'physicalSHA256': physical_sha, 'notes': notes, 'textQuality': text_quality, 'textQualitySHA256': text_quality_sha}
    css = (ASSETS / 'report.css').read_text()
    js = (ASSETS / 'report.js').read_text()
    # Keep untrusted transcript text as JSON data, never executable HTML.
    serialized = json.dumps(data, ensure_ascii=False, separators=(',', ':'), allow_nan=False)
    serialized = serialized.replace('<', '\\u003c').replace('>', '\\u003e').replace('&', '\\u0026')
    serialized = serialized.replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')
    sha = lambda text: base64.b64encode(hashlib.sha256(text.encode()).digest()).decode()
    csp = f"default-src 'none'; script-src 'sha256-{sha(js)}' 'sha256-{sha(serialized)}'; style-src 'sha256-{sha(css)}'; img-src data:; media-src 'self' file:; connect-src 'none'; base-uri 'none'; form-action 'none'"
    template = (ASSETS / 'report.html').read_text()
    page = template.replace('@@CSP@@', html.escape(csp, quote=True)).replace('@@CSS@@', css)
    page = page.replace('@@DATA@@', serialized).replace('@@JS@@', js)
    target = output / 'report.html'
    target.write_text(page)
    proof = {'schema_version': 1, 'status': status, 'cases': len(cases), 'candidate': candidate,
             'report_sha256': digest(target), 'index_sha256': index_sha, 'corpus_sha256': manifest_sha,
             'physical_sha256': physical_sha, 'text_quality_sha256': text_quality_sha, 'policy_fingerprint': cases[0]['policyFingerprint'],
             'source_commit': data['sourceCommit'], 'core_sha256': data['coreSHA256'],
             'verification': 'Static generation and hash validation only. No browser rendering or listening claimed.'}
    (output / 'report-proof.private.json').write_text(json.dumps(proof, indent=2) + '\n')
    return proof


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--index', required=True)
    p.add_argument('--candidate', required=True)
    p.add_argument('--output', required=True)
    p.add_argument('--status', choices=['provisional', 'final'], required=True)
    p.add_argument('--physical', help='Parent-supplied actual device summary JSON; absent means pending')
    p.add_argument('--text-quality', help='Authoritative separately guarded weak WER/CER JSON bound to the same native evidence')
    p.add_argument('--notes', help='Plain-text final conclusions and limitations, escaped as text')
    p.add_argument('--reference-audio-in-place', action='store_true', help='Use original absolute file URI instead of copying PCM')
    args = p.parse_args()
    print(json.dumps(build(args.index, args.candidate, args.output, args.status, args.physical,
                           not args.reference_audio_in_place, args.notes, args.text_quality), indent=2))
