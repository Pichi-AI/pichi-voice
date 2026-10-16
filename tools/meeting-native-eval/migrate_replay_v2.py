#!/usr/bin/env python3
"""Explicit offline v1-policy evidence derivative for v2-core replay, never model inference.

Historical source bytes stay untouched. Only the policy object is replaced in a derivative,
with provenance added. Exact source-array bytes are retained and acoustic projection equality
is checked by the actual current Swift core before this migration can report success.
"""
from pathlib import Path
import argparse
import hashlib
import json
import os
import subprocess

ARRAY_KEYS = ('units', 'activity', 'baselineCoverageAssignments', 'baselineAssignments', 'initialAcousticAssignments')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def top_level_spans(text):
    decoder = json.JSONDecoder()
    def whitespace(index):
        while index < len(text) and text[index].isspace():
            index += 1
        return index
    index = whitespace(0)
    if index >= len(text) or text[index] != '{':
        raise ValueError('Evidence must be one JSON object')
    index = whitespace(index + 1)
    spans = {}
    while index < len(text) and text[index] != '}':
        key, index = decoder.raw_decode(text, index)
        if not isinstance(key, str) or key in spans:
            raise ValueError('Duplicate or invalid top-level evidence key')
        index = whitespace(index)
        if text[index] != ':':
            raise ValueError('Malformed evidence key')
        start = whitespace(index + 1)
        _, end = decoder.raw_decode(text, start)
        spans[key] = (start, end)
        index = whitespace(end)
        if text[index] == ',':
            index = whitespace(index + 1)
        elif text[index] != '}':
            raise ValueError('Malformed evidence object')
    if index >= len(text) or text[index] != '}' or text[index + 1:].strip():
        raise ValueError('Trailing or unterminated evidence object')
    return spans

def derive(source_bytes, new_policy, source_path, build_manifest_sha256):
    text = source_bytes.decode('utf-8')
    source = json.loads(text)
    spans = top_level_spans(text)
    old_policy = source['nativeProjectionPolicy']
    if source['schemaVersion'] != 2 or old_policy['schemaVersion'] != 1 or new_policy['schemaVersion'] != 2:
        raise ValueError('This explicit offline migration supports only evidence2 / policy1 to policy2')
    if 'offlineReplayMigration' in source:
        raise ValueError('Refuse to chain or overwrite an earlier derivative migration')
    if {k:v for k,v in old_policy.items() if k!='schemaVersion'} != {k:v for k,v in new_policy.items() if k!='schemaVersion'}:
        raise ValueError('Numerical policy changed; raw acoustic projection requires a separate explicit experiment')
    original_arrays = {key: text[slice(*spans[key])].encode('utf-8') for key in ARRAY_KEYS}
    provenance = {'kind':'explicitOfflinePolicyV1ToV2ReplayDerivative', 'originalEvidencePath':str(source_path),
        'originalEvidenceSHA256':sha(source_bytes), 'originalNativeProjectionPolicy':old_policy,
        'newNativeProjectionPolicy':new_policy, 'replayBuildManifestSHA256':build_manifest_sha256,
        'noNewModelInference':True, 'originalNativeModelMetadataUnchanged':True,
        'originalNativeArraySHA256':{key:sha(value) for key,value in original_arrays.items()}}
    start,end=spans['nativeProjectionPolicy']
    replaced=text[:start]+json.dumps(new_policy,ensure_ascii=False,sort_keys=True,indent=2)+text[end:]
    opening=replaced.index('{')+1
    replaced=replaced[:opening]+'\n  "offlineReplayMigration": '+json.dumps(provenance,ensure_ascii=False,sort_keys=True,indent=2)+','+replaced[opening:]
    derivative_spans=top_level_spans(replaced)
    for key,original in original_arrays.items():
        if replaced[slice(*derivative_spans[key])].encode('utf-8') != original:
            raise ValueError('Native source array bytes changed')
    if json.loads(replaced)['metadata'] != source['metadata']:
        raise ValueError('Historical native model metadata changed')
    return replaced.encode('utf-8'),provenance

def write_new(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    descriptor=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(descriptor,'wb') as handle:
        handle.write(data)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-evidence',required=True,type=Path)
    parser.add_argument('--derivative-evidence',required=True,type=Path)
    parser.add_argument('--replay-output',required=True,type=Path)
    parser.add_argument('--migration-report',required=True,type=Path)
    parser.add_argument('--runner',required=True,type=Path)
    parser.add_argument('--build-manifest',required=True,type=Path)
    args=parser.parse_args()
    source_path=args.source_evidence.resolve()
    outputs=[args.derivative_evidence.resolve(),args.replay_output.resolve(),args.migration_report.resolve()]
    if source_path in outputs or len(set(outputs)) != 3 or any(path.exists() for path in outputs):
        raise ValueError('Migration outputs must be distinct new paths, never a historical source')
    original=source_path.read_bytes();build=args.build_manifest.read_bytes()
    if sha(args.runner.read_bytes()) != json.loads(build)['binary_sha256']:
        raise ValueError('Current replay runner changed after build')
    policy_path=args.migration_report.with_suffix('.policy.private.json')
    policy_path.parent.mkdir(parents=True,exist_ok=True)
    if policy_path.exists():
        raise ValueError('Policy export path already exists')
    env=dict(os.environ,LLVM_PROFILE_FILE='/dev/null')
    subprocess.run([str(args.runner.resolve()),'write-policy',str(policy_path.resolve())],check=True,env=env,stdout=subprocess.DEVNULL)
    new_policy=json.loads(policy_path.read_text())
    derivative,provenance=derive(original,new_policy,source_path,sha(build))
    write_new(args.derivative_evidence,derivative)
    args.replay_output.parent.mkdir(parents=True,exist_ok=True)
    subprocess.run([str(args.runner.resolve()),'replay',str(args.derivative_evidence.resolve()),str(args.replay_output.resolve())],check=True,env=env,stdout=subprocess.DEVNULL)
    replay=json.loads(args.replay_output.read_text());source=json.loads(original)
    if [replay['projectionAssignments'][unit['id']] for unit in source['units']] != source['initialAcousticAssignments']:
        raise ValueError('Acoustic projection changed; refuse to call this only an algorithm-semantic derivative')
    if not replay['deterministicRepeatEqual'] or source_path.read_bytes()!=original:
        raise ValueError('Replay was not deterministic or historical source changed')
    report={'schema_version':1,'status':'complete','source_evidence_sha256':sha(original),'derivative_evidence_sha256':sha(derivative),
        'replay_output_sha256':sha(args.replay_output.read_bytes()),'new_policy_fingerprint':replay['policyFingerprint'],
        'original_native_arrays_byte_identical':True,'original_native_acoustic_projection_equal':True,
        'original_source_file_byte_unchanged':True,'new_model_inference_executed':False,'provenance':provenance}
    write_new(args.migration_report,(json.dumps(report,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode())
    print(json.dumps({'status':'complete','source_clip_id':source['clipID'],'source_native_words':len(source['units']),
        'original_arrays_byte_identical':True,'acoustic_projection_equal':True,'new_model_inference_executed':False,'new_policy_fingerprint':replay['policyFingerprint']},sort_keys=True))

if __name__=='__main__': main()
