#!/usr/bin/env python3
"""Summarize paired native classifier results and export a blinded LLM jury.

No training, threshold tuning or jury scores occur here. Inputs must be reports
from the production classifier comparison; authored labels are not human truth.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import random
import statistics

MODELS = ('old', 'new')
TOPICS = ('illicit-remuneration', 'procurement-collusion', 'commercial-metrics')
LABELS = ('positive', 'negative', 'ambiguous')


def utf16_length(text):
    return len(text.encode('utf-16-le')) // 2


def gold_units(text, substrings):
    result = set()
    for substring in substrings:
        if not substring or substring not in text:
            raise ValueError('Gold substring absent from input')
        cursor = 0
        while True:
            index = text.find(substring, cursor)
            if index < 0:
                break
            start = utf16_length(text[:index])
            result.update(range(start, start + utf16_length(substring)))
            cursor = index + len(substring)
    return result


def mask_units(result, text):
    masked = set()
    for span in result['spans']:
        start, length = span['location'], span['length']
        if isinstance(start, bool) or isinstance(length, bool) or not isinstance(start, int) or not isinstance(length, int):
            raise ValueError('Invalid span type')
        if start < 0 or length <= 0 or start + length > utf16_length(text):
            raise ValueError('Invalid UTF-16 span')
        masked.update(range(start, start + length))
    return masked


def ratio(value, denominator):
    return value / denominator if denominator else None


def quantiles(values):
    if not values:
        return None
    ordered = sorted(values)
    return {'count': len(ordered), 'median': statistics.median(ordered),
            'p95': ordered[min(len(ordered) - 1, int((len(ordered) - 1) * .95))],
            'maximum': max(ordered)}


def summarize(rows):
    result = {}
    for model in MODELS:
        n = Counter(); gold_count = covered = unrelated_count = unrelated_masked = 0
        times = []
        for row in rows:
            item = row['input']
            output = next(value for value in row['results'] if value['model'] == model)
            label = item['label']; n['total'] += 1; n[label] += 1
            if output['status'] != 'ok':
                n['errors'] += 1; n['errors_' + label] += 1
                continue
            n['completed_' + label] += 1
            masks = mask_units(output, item['text'])
            times.extend(output['warmMilliseconds'])
            if label == 'ambiguous':
                n['ambiguous_masked'] += int(bool(masks))
                continue
            gold = gold_units(item['text'], item['goldMaskSubstrings'])
            if label == 'positive':
                if not gold:
                    raise ValueError('Positive case requires a gold sensitive span')
                hit = bool(masks & gold)
                n['tp' if hit else 'fn'] += 1
                n['full'] += int(gold <= masks)
                gold_count += len(gold); covered += len(masks & gold)
            else:
                if gold:
                    raise ValueError('Clear negative cannot include gold spans')
                n['fp' if masks else 'tn'] += 1
            unrelated = set(range(utf16_length(item['text']))) - gold
            unrelated_count += len(unrelated); unrelated_masked += len(masks & unrelated)
        result[model] = {
            'cases': n['total'], 'positiveCases': n['positive'], 'negativeCases': n['negative'],
            'ambiguousCases': n['ambiguous'], 'errors': n['errors'],
            'errorsByLabel': {label: n['errors_' + label] for label in LABELS},
            'completedByLabel': {label: n['completed_' + label] for label in LABELS},
            'tp': n['tp'], 'fp': n['fp'], 'fn': n['fn'], 'tn': n['tn'],
            'precision': ratio(n['tp'], n['tp'] + n['fp']),
            'recall': ratio(n['tp'], n['tp'] + n['fn']),
            'falseMaskRate': ratio(n['fp'], n['fp'] + n['tn']),
            'fullSensitiveSentenceCoverage': ratio(n['full'], n['completed_positive']),
            'sensitiveUTF16Coverage': ratio(covered, gold_count),
            'unrelatedUTF16MaskRate': ratio(unrelated_masked, unrelated_count),
            'ambiguousMasked': n['ambiguous_masked'],
            'ambiguousMaskRate': ratio(n['ambiguous_masked'], n['completed_ambiguous']),
            'warmMilliseconds': quantiles(times),
        }
    return result


def verdict(row, output):
    if output['status'] != 'ok':
        return 'error'
    item = row['input']; masks = mask_units(output, item['text'])
    if item['label'] == 'ambiguous':
        return 'masked' if masks else 'clear'
    if item['label'] == 'negative':
        return 'false-mask' if masks else 'correct-clear'
    gold = gold_units(item['text'], item['goldMaskSubstrings'])
    if gold <= masks:
        return 'full'
    if masks & gold:
        return 'partial'
    return 'miss'


def paired(rows):
    matrices = {label: Counter() for label in LABELS}
    output_changed = Counter()
    for row in rows:
        results = {x['model']: x for x in row['results']}
        before, after = results['old'], results['new']
        label = row['input']['label']
        matrices[label][verdict(row, before) + ' -> ' + verdict(row, after)] += 1
        output_changed[label] += int(before.get('output') != after.get('output') or before['status'] != after['status'])
    return {'transitionCounts': {label: dict(sorted(matrix.items())) for label, matrix in matrices.items()},
            'outputChangedByLabel': dict(output_changed)}


def select_balanced(pool, count, rng):
    changed = []
    unchanged = []
    for row in pool:
        results = {x['model']: x for x in row['results']}
        old, new = results['old'], results['new']
        target = changed if (old.get('output'), old['status']) != (new.get('output'), new['status']) else unchanged
        target.append(row)
    rng.shuffle(changed); rng.shuffle(unchanged)
    # Within each outcome bucket favor inputs with multiple annotated edge tags;
    # the preceding deterministic shuffle breaks ties without using expected scores.
    changed.sort(key=lambda row: -len(set(row['input']['tags'])))
    unchanged.sort(key=lambda row: -len(set(row['input']['tags'])))
    # Predeclared selection seeks equal representation of changed/unchanged outputs;
    # take the available remainder when one side has too few cases.
    take_changed = min(len(changed), count // 2)
    take_unchanged = min(len(unchanged), count // 2)
    chosen = changed[:take_changed] + unchanged[:take_unchanged]
    remainder = changed[take_changed:] + unchanged[take_unchanged:]
    rng.shuffle(remainder)
    chosen.extend(remainder[:count - len(chosen)])
    if len(chosen) != count:
        raise ValueError('Insufficient independently authored cases for blind jury')
    return chosen


def jury_export(report):
    rng = random.Random(20261031)
    selected = []
    for topic in TOPICS:
        for label, count in [('positive', 6), ('negative', 4), ('ambiguous', 2)]:
            pool = [row for row in report['rows'] if row['input']['selectedTopicIDs'] == [topic]
                    and row['input']['label'] == label]
            selected.extend(select_balanced(pool, count, rng))
    rng.shuffle(selected)
    blind = []; mapping = []
    for index, row in enumerate(selected, 1):
        case_id = f'case-{index:02d}'
        order = list(MODELS); rng.shuffle(order)
        options = []
        for letter, model in zip('AB', order):
            value = next(x for x in row['results'] if x['model'] == model)
            options.append({'option': letter, 'status': value['status'], 'output': value.get('output')})
            mapping.append({'caseID': case_id, 'option': letter, 'model': model, 'sourceCaseID': row['input']['id']})
        blind.append({'caseID': case_id, 'selectedTopics': row['input']['selectedTopicIDs'],
                      'input': row['input']['text'], 'options': options})
    return ({'schemaVersion': 1, 'policy': report['policyDefinition'],
        'instructions': [
            'Independently assess whether the selected topic is discussed. A denial, quotation or training discussion still mentions a selected topic.',
            'For each option score sensitiveMeaningHidden and unrelatedMeaningPreserved from 1 (poor) to 5 (excellent). Equivalent outputs must receive identical scores.',
            'A correctly unchanged input without the selected topic earns 5/5. Do not invent information absent from the input.',
            'Flag disputedCase when the topic cannot be determined or is ambiguous; briefly say why without assuming any hidden label.',
            'Processing errors are explicit withholding, not successful cleaned output. Do not invent an output.',
            'Return JSON {judge, cases:[{caseID,disputedCase,options:[{option,sensitiveMeaningHidden,unrelatedMeaningPreserved,reason}]}], limitations}.'
        ],
        'limitations': ['Original synthetic text, not human-adjudicated ground truth or physical-device/ASR evaluation.',
            'Model identities, source identifiers and authored labels are concealed; A/B order is independently permuted for each case.'],
        'cases': blind}, mapping)


def build_summary(report, raw_bytes):
    if report['schemaVersion'] != 1 or not report['rows']:
        raise ValueError('Invalid or empty native report')
    for row in report['rows']:
        if set(value['model'] for value in row['results']) != set(MODELS) or len(row['results']) != 2:
            raise ValueError('Missing or duplicate model output')
        if row['input']['label'] not in LABELS:
            raise ValueError('Invalid label')
    topics = {topic: [row for row in report['rows'] if row['input']['selectedTopicIDs'] == [topic]] for topic in TOPICS}
    tags = sorted({tag for row in report['rows'] for tag in row['input']['tags']})
    return {'schemaVersion': 1, 'revision': report['revision'], 'corpusID': report['corpusID'],
        'corpusSHA256': report['corpusSHA256'], 'artifactSHA256': report['artifactSHA256'],
        'nativeReportSHA256': hashlib.sha256(raw_bytes).hexdigest(),
        'scope': 'Actual native classifier-only paired outputs on independently authored synthetic text.',
        'overall': summarize(report['rows']), 'perTopic': {topic: summarize(rows) for topic, rows in topics.items()},
        'perTag': {tag: summarize([row for row in report['rows'] if tag in row['input']['tags']]) for tag in tags},
        'paired': paired(report['rows']), 'controls': report['controls'], 'loadMilliseconds': report['loadMilliseconds'],
        'notes': report['notes'] + [
            'Positive detection requires intersection with the annotated sensitive sentence, not merely a mask elsewhere.',
            'Binary scores exclude ambiguous inputs and explicit processing errors; their counts are reported separately.',
            'LLM jury input excludes authored labels, rationales, model identity and source IDs; per-case A/B order is permuted.',
            'Selection is predeclared, favors tagged edge cases, and includes changed and unchanged outputs where available; results on 36 selected cases are not full-corpus metrics.'
        ]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-report', required=True, type=Path)
    parser.add_argument('--output-directory', required=True, type=Path)
    args = parser.parse_args()
    raw = args.native_report.read_bytes()
    report = json.loads(raw)
    summary = build_summary(report, raw)
    jury, mapping = jury_export(report)
    args.output_directory.mkdir(parents=True, exist_ok=True)
    for name, value in [('comparison-summary.json', summary), ('jury-blind.json', jury), ('jury-mapping-private.json', mapping)]:
        destination = args.output_directory / name
        if destination.exists():
            raise FileExistsError(f'Refusing to overwrite existing result: {destination}')
        destination.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'rows': len(report['rows']), 'juryCases': len(jury['cases']),
                      'outputDirectory': str(args.output_directory)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
