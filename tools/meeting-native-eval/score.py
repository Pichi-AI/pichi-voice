#!/usr/bin/env python3
"""Score frozen native results against explicitly weak automatic meeting references.

No attribution algorithm is implemented here. Native inference and policy choices come only
from the actual Swift executable. One activity-derived label mapping is frozen per recording
and reused by every policy. Output excludes reference/transcript text and participant names.
"""
from __future__ import annotations
from pathlib import Path
import argparse
import collections
import hashlib
import importlib.util
import json
import math
import sys

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('meeting_timeline_evaluator', ROOT / 'tools/meeting_diarization_eval.py')
TIMELINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = TIMELINE
SPEC.loader.exec_module(TIMELINE)
S = TIMELINE.Segment
MIGRATION_SPEC = importlib.util.spec_from_file_location('native_offline_migration', Path(__file__).with_name('migrate_replay_v2.py'))
MIGRATION = importlib.util.module_from_spec(MIGRATION_SPEC)
sys.modules[MIGRATION_SPEC.name] = MIGRATION
MIGRATION_SPEC.loader.exec_module(MIGRATION)

def read(path):
    return json.loads(Path(path).read_text())

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def evidence_lineage_hashes(path, evidence):
    """Accept old replay hashes only for the explicit byte-preserving historical derivative."""
    original_hashes = {sha(path)}
    provenance = evidence.get('offlineReplayMigration')
    if provenance:
        source_path = Path(provenance['originalEvidencePath'])
        source = source_path.read_bytes()
        if hashlib.sha256(source).hexdigest() != provenance['originalEvidenceSHA256']:
            raise ValueError('Historical source evidence changed')
        expected, _ = MIGRATION.derive(source, evidence['nativeProjectionPolicy'], source_path,
                                       provenance['replayBuildManifestSHA256'])
        if expected != Path(path).read_bytes():
            raise ValueError('Derivative does not preserve exact original native arrays/provenance')
        original_hashes.add(provenance['originalEvidenceSHA256'])
    return original_hashes


def union(intervals):
    values = []
    for left, right in sorted(intervals):
        if right <= left:
            continue
        if values and left <= values[-1][1]:
            values[-1] = (values[-1][0], max(values[-1][1], right))
        else:
            values.append((left, right))
    return values

def duration(intervals):
    return math.fsum(right - left for left, right in union(intervals))

def support(activity, start, end):
    values = collections.defaultdict(list)
    for item in activity:
        left, right = max(start, item.start), min(end, item.end)
        if right > left:
            values[item.speaker].append((left, right))
    return {speaker: duration(intervals) for speaker, intervals in values.items()}

def frozen_mapping(reference, activity):
    intervals = TIMELINE.scored_intervals(reference, activity, 0, True)
    refs = TIMELINE.trajectory_order(reference, {s.speaker for s in reference}, TIMELINE.duration_by_speaker(reference))
    hyps = TIMELINE.trajectory_order(activity, {s.speaker for s in activity})
    matrix = TIMELINE.overlap_matrix(intervals, refs, hyps)
    mapping = {hyps[column]: refs[row] for row, column in TIMELINE.best_assignment(matrix) if matrix[row][column] > 0}
    return mapping, {'reference_labels': refs, 'native_labels': hyps, 'overlap_seconds_matrix': matrix,
                     'mapping_method': 'One global maximum-overlap one-to-one mapping from original native activity; unchanged for all policies and collars'}

def metric():
    return {'words': 0, 'assigned_words': 0, 'weak_agree_words': 0, 'weak_disagree_words': 0,
            'unknown_words': 0, 'word_seconds': 0.0, 'assigned_word_seconds': 0.0,
            'weak_agree_word_seconds': 0.0, 'weak_disagree_word_seconds': 0.0, 'unknown_word_seconds': 0.0}

def add_metric(value, seconds, selected, expected, mapping):
    value['words'] += 1
    value['word_seconds'] += seconds
    if selected is None:
        value['unknown_words'] += 1
        value['unknown_word_seconds'] += seconds
    else:
        value['assigned_words'] += 1
        value['assigned_word_seconds'] += seconds
        state = 'weak_agree' if mapping.get(selected) == expected else 'weak_disagree'
        value[state + '_words'] += 1
        value[state + '_word_seconds'] += seconds

def finish(value):
    result = dict(value)
    result.update({'assigned_coverage': value['assigned_words'] / value['words'] if value['words'] else None,
                   'weak_selective_disagreement': value['weak_disagree_words'] / value['assigned_words'] if value['assigned_words'] else None,
                   'weak_agreement_all_eligible_words': value['weak_agree_words'] / value['words'] if value['words'] else None,
                   'assigned_duration_coverage': value['assigned_word_seconds'] / value['word_seconds'] if value['word_seconds'] else None,
                   'weak_duration_selective_disagreement': value['weak_disagree_word_seconds'] / value['assigned_word_seconds'] if value['assigned_word_seconds'] else None})
    return result

def merge_metrics(values):
    out = metric()
    for value in values:
        for key in out:
            out[key] += value[key]
    return finish(out)

def eligible_label(start, end, spans):
    labels, covered = set(), 0.0
    for left, right, refs, _ in spans:
        overlap = min(end, right) - max(start, left)
        if overlap > 0:
            if len(refs) != 1:
                return None
            labels.update(refs)
            covered += overlap
    return next(iter(labels)) if len(labels) == 1 and abs(covered - (end - start)) <= 1e-7 else None

def selected_label(assignment):
    return assignment['token']['label'] if assignment['kind'] == 'assigned' else None

def bin_support(value):
    if value == 0: return '0'
    if value < .05: return '(0,0.05)'
    if value < .2: return '[0.05,0.2)'
    if value < .5: return '[0.2,0.5)'
    if value < .9: return '[0.5,0.9)'
    return '[0.9,1]'

def bin_duration(seconds):
    return '<=0.16' if seconds <= .16 else '<=0.5' if seconds <= .5 else '<=1' if seconds <= 1 else '>1'

def phase(start):
    return '0-15s' if start < 15 else '15-60s' if start < 60 else '60s+'

def evaluate_words(units, selections, rules, activity, reference, mapping):
    profiles = {}
    for name, collar in [('strictWeak', 0), ('interior1s', 1), ('interior2s', 2)]:
        spans = TIMELINE.scored_spans(reference, [], collar, False)
        count = metric()
        by_support, by_duration, by_phase, by_rule = {}, {}, {}, {}
        mismatches = []
        for unit, selected, rule in zip(units, selections, rules):
            start, end = unit['analysisStart'], unit['analysisEnd']
            expected = eligible_label(start, end, spans)
            if expected is None:
                continue
            seconds = end - start
            voiced = support(activity, start, end)
            fraction = (voiced.get(selected, 0) if selected is not None else max(voiced.values(), default=0)) / seconds
            add_metric(count, seconds, selected, expected, mapping)
            for group, key in [(by_support, bin_support(fraction)), (by_duration, bin_duration(seconds)),
                               (by_phase, phase(start)), (by_rule, rule)]:
                add_metric(group.setdefault(key, metric()), seconds, selected, expected, mapping)
            if selected is not None and mapping.get(selected) != expected:
                boundaries = [point for item in reference for point in (item.start, item.end)]
                mismatches.append({'unit_id': unit['id'], 'start': start, 'end': end, 'rule': rule,
                    'native_slot': selected, 'mapped_weak_reference_slot': mapping.get(selected), 'weak_reference_slot': expected,
                    'selected_activity_support_seconds': voiced.get(selected, 0), 'selected_activity_fraction_of_word': fraction,
                    'candidate_activity_support_seconds': voiced,
                    'minimum_distance_to_weak_reference_boundary_seconds': min(abs(point - probe) for point in boundaries for probe in (start, end))})
        profiles[name] = {'counts': finish(count), 'eligible_words': count['words'],
            'excluded_words': len(units) - count['words'],
            'by_selected_activity_fraction': {key: finish(value) for key, value in by_support.items()},
            'by_word_duration_seconds': {key: finish(value) for key, value in by_duration.items()},
            'by_clip_time': {key: finish(value) for key, value in by_phase.items()},
            'by_rule': {key: finish(value) for key, value in by_rule.items()},
            'weak_disagreement_geometry': mismatches}
    return profiles

def weak_asr_text_metric(reference_json, units):
    complete = [turn for turn in reference_json['turns'] if not turn.get('clipped_start') and not turn.get('clipped_end')]
    reference_words = [word for turn in complete for word in TIMELINE.words(turn['text'])]
    hypothesis_words = [word for unit in units if any(turn['start'] <= (unit['analysisStart'] + unit['analysisEnd']) / 2 < turn['end'] for turn in complete) for word in TIMELINE.words(unit['text'])]
    distance = TIMELINE.edit_distance(reference_words, hypothesis_words)
    return {'reference_status': 'automatic_weak_not_human_gold', 'edge_clipped_turns_excluded_entirely': True,
            'reference_complete_turn_count': len(complete), 'reference_words': len(reference_words), 'hypothesis_words': len(hypothesis_words),
            'edit_operations': distance, 'weak_automatic_reference_WER': distance / len(reference_words) if reference_words else None,
            'caveat': 'Automatic Fathom text and whole-second turn boundaries are not an audited verbatim transcript. No reference word times manufactured; this diagnostic is independent of speaker policy.'}

def aggregate(cases, variant, group_key=None):
    groups = collections.defaultdict(list)
    for case in cases:
        groups[str(case.get(group_key)) if group_key else 'all'].append(case)
    output = {}
    for key, items in groups.items():
        profiles = {}
        for profile in ['strictWeak', 'interior1s', 'interior2s']:
            values = [case['variants'][variant]['profiles'][profile] for case in items]
            merged = merge_metrics([v['counts'] for v in values])
            extra = {}
            for category in ['by_selected_activity_fraction', 'by_word_duration_seconds', 'by_clip_time', 'by_rule']:
                keys = set().union(*(v[category] for v in values))
                extra[category] = {subkey: merge_metrics([v[category][subkey] for v in values if subkey in v[category]]) for subkey in sorted(keys)}
            profiles[profile] = {'counts': merged, 'eligible_words': sum(v['eligible_words'] for v in values),
                                 'excluded_words': sum(v['excluded_words'] for v in values), **extra}
        all_native = sum(case['native_words'] for case in items)
        all_unknown = sum(case['variants'][variant]['all_unknown_words'] for case in items)
        for value in profiles.values():
            value['all_native_denominator'] = {'all_native_words': all_native, 'all_assigned_words': all_native-all_unknown, 'all_unknown_words': all_unknown, 'all_assigned_coverage': (all_native-all_unknown)/all_native if all_native else None, 'profile_eligible_fraction': value['eligible_words']/all_native if all_native else None, 'weak_agree_eligible_fraction_of_all_native': value['counts']['weak_agree_words']/all_native if all_native else None, 'weak_disagree_eligible_fraction_of_all_native': value['counts']['weak_disagree_words']/all_native if all_native else None, 'profile_excluded_fraction': value['excluded_words']/all_native if all_native else None}
        output[key] = {'case_count': len(items), 'profiles': profiles,
            'all_native_words': sum(case['native_words'] for case in items),
            'all_unknown_words': sum(case['variants'][variant]['all_unknown_words'] for case in items)}
    return output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', required=True, type=Path)
    parser.add_argument('--native-directory', required=True, type=Path)
    parser.add_argument('--variant', action='append', required=True, help='NAME=pass-directory')
    parser.add_argument('--split', choices=['development', 'heldOut'], default='development')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    variants = dict(value.split('=', 1) for value in args.variant)
    manifest = read(args.manifest)
    cases = []
    for clip in manifest['clips']:
        if clip['split'] != args.split:
            continue
        clip_id = clip['clip_id']
        evidence_path = args.native_directory / 'evidence' / (clip_id + '.json')
        evidence = read(evidence_path)
        lineage_hashes = evidence_lineage_hashes(evidence_path, evidence)
        if evidence['audioSHA256'] != clip['audio_sha256'] or evidence['sampleCount'] != round(clip['duration_seconds']*evidence['sampleRate']):
            raise ValueError('Native evidence differs from frozen corpus')
        if sha(clip['weak_reference_path']) != clip['weak_reference_sha256']:
            raise ValueError('Weak reference changed after selection freeze')
        reference_json = read(clip['weak_reference_path'])
        reference = TIMELINE.union_segments([S(str(t['speaker']), max(0,t['start']), min(clip['duration_seconds'],t['end'])) for t in reference_json['turns'] if min(clip['duration_seconds'],t['end']) > max(0,t['start'])])
        activity = TIMELINE.union_segments([S(item['token']['label'], item['start'], item['end']) for item in evidence['activity']])
        mapping, mapping_proof = frozen_mapping(reference, activity)
        units = evidence['units']
        timeline_profiles = {name: TIMELINE.score_timeline(reference, activity, collar, True) for name,collar in [('strictWeak',0),('interior1s',1)]}
        source_fraction = clip['source_start_seconds'] / clip['source_hls_duration_seconds']
        case = {'clip_id': clip_id, 'meeting_id': clip['meeting_id'], 'split': clip['split'],
                'weak_speaker_count': clip['observed_weak_speaker_count'], 'language_condition': clip['language_condition'],
                'source_start_fraction': source_fraction, 'source_fraction_stratum': 'early' if source_fraction < 1/3 else 'middle' if source_fraction < 2/3 else 'late',
                'evidence_lineage_sha256': sorted(lineage_hashes), 'native_words': len(units), 'native_word_seconds': sum(u['analysisEnd']-u['analysisStart'] for u in units),
                'native_activity_intervals': len(evidence['activity']), 'native_active_slot_count':len({s.speaker for s in activity}),
                'native_model_unvoiced_fraction': 1-duration([(s.start,s.end) for s in activity])/clip['duration_seconds'],
                'frozen_native_to_weak_reference_mapping': mapping, 'mapping_proof':mapping_proof,
                'weak_activity_timeline_diagnostic':timeline_profiles, 'weak_asr_text_diagnostic':weak_asr_text_metric(reference_json,units),
                'native_runtime_metadata':evidence['metadata'], 'variants':{}}
        if len(evidence['baselineAssignments']) != len(units):
            raise ValueError('Baseline omitted native source units')
        baseline = [selected_label(item) for item in evidence['baselineAssignments']]
        selections = {'baseline4484': (baseline, ['historicalCoverageHandoff']*len(units))}
        for name, directory in variants.items():
            run_manifest = read(Path(directory)/'run-manifest.json')
            if run_manifest['status'] != 'complete' or run_manifest['corpus_manifest_sha256'] != sha(args.manifest):
                raise ValueError('Replay run not completed against this frozen corpus')
            replay = read(Path(directory)/(clip_id+'.json'))
            if replay['evidenceSHA256'] not in lineage_hashes or not replay['deterministicRepeatEqual']:
                raise ValueError('Policy replay not pinned to exact native source evidence')
            decisions = {decision['unitID']: decision for decision in replay['resolution']['decisions']}
            if set(decisions) != {unit['id'] for unit in units} or len(decisions) != len(replay['resolution']['decisions']):
                raise ValueError('Original source word IDs changed')
            selections[name] = ([decisions[u['id']]['selectedToken']['label'] if decisions[u['id']].get('selectedToken') else None for u in units],
                                [decisions[u['id']]['rule'] for u in units])
        for name,(selected,rules) in selections.items():
            case['variants'][name] = {'all_unknown_words':sum(item is None for item in selected),
                'rule_counts':dict(collections.Counter(rules)), 'profiles':evaluate_words(units,selected,rules,activity,reference,mapping)}
        cases.append(case)
        print(json.dumps({'clip_id':clip_id,'native_words':len(units),'native_slots':case['native_active_slot_count'],
                          'weak_speaker_count':case['weak_speaker_count'],'language':case['language_condition']},sort_keys=True),flush=True)
    names=['baseline4484',*variants]
    report={'schema_version':1,'reference_status':'automatic_weak_not_human_gold','scope':'Actual pinned native model inference; deterministic native Swift policy replay; fixed per-recording mapping across policies and profiles. No transcript text or participant names in this report.',
            'split':args.split,'corpus_manifest_sha256':sha(args.manifest),'case_count':len(cases),
            'mapping_frozen_before_policy_comparison':True,'recording_disjoint_from_other_split':True,'participant_disjoint':False,
            'profile_definitions':{'strictWeak':'Whole native word lies within one automatic reference speaker interval; no collar; reference-incomplete or crossed-boundary units excluded.', 'interior1s':'Same rule with exact plus/minus1s around every canonical reference speaker-interval start/end, including true speaker TURN changes and clip edges; same-speaker adjacent phrase boundaries unioned first. No guessed word times.', 'interior2s':'Conservative sensitivity: same exact TURN-change and clip-edge exclusion with plus/minus2s collars. All-native denominator and excluded counts reported separately.'},
            'cases':cases,'aggregate':{name:aggregate(cases,name)['all'] for name in names},
            'by_weak_speaker_count':{name:aggregate(cases,name,'weak_speaker_count') for name in names},
            'by_language':{name:aggregate(cases,name,'language_condition') for name in names},
            'by_source_fraction':{name:aggregate(cases,name,'source_fraction_stratum') for name in names},
            'metric_caveats':['Fathom whole-second turn starts and inferred ends contain silence and omit overlap. Weak agreement is not human DER or calibrated identity accuracy.','Unknown is explicit abstention; fewer unknowns alone does not establish improvement.','ASR CTC word emission times are approximate. Full words/IDs/timings remain unchanged by policy.','All English clips are development only; no English held-out claim.','Native-slot/reference merges and splits are weak-reference conflicts, not audited real-person errors.']}
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2,sort_keys=True)+'\n')
    print(json.dumps({'split':args.split,'cases':len(cases),'variants':{name:{profile:report['aggregate'][name]['profiles'][profile]['counts'] for profile in ['strictWeak','interior1s']} for name in names}},sort_keys=True),flush=True)

if __name__=='__main__':
    main()
