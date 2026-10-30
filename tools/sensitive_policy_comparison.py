#!/usr/bin/env python3
"""Summarize actual native outputs and prepare a blinded synthetic-only LLM jury.

Run the compiled native SensitivePolicyEvaluation CLI first, or pass --executable
with --corpus, --artifact, --artifact-sha256 and --revision. No model is trained,
no thresholds are tuned, and no LLM scores are invented by this script.
"""
import argparse
import hashlib
import json
from pathlib import Path
import random
import statistics
import subprocess

METHODS = ('literal', 'wordForms', 'groups', 'groupsAndClassifier')
SUPPORTED = ('illicit-remuneration', 'procurement-collusion', 'commercial-metrics')


def utf16_length(text):
    return len(text.encode('utf-16-le')) // 2


def gold_units(text, substrings):
    units = set()
    for substring in substrings:
        if not substring or substring not in text:
            raise ValueError('Gold substring absent from input')
        cursor = 0
        while True:
            index = text.find(substring, cursor)
            if index < 0:
                break
            start = utf16_length(text[:index])
            units.update(range(start, start + utf16_length(substring)))
            cursor = index + len(substring)
    return units


def masked_units(result, text):
    units = set()
    for span in result['spans']:
        start, length = span['location'], span['length']
        if isinstance(start, bool) or isinstance(length, bool) or not isinstance(start, int) or not isinstance(length, int):
            raise ValueError('Noninteger span')
        if start < 0 or length <= 0 or start + length > utf16_length(text):
            raise ValueError('Invalid span')
        units.update(range(start, start + length))
    return units


def ratio(a, b):
    return None if not b else a / b


def summarize(rows):
    summary = {}
    for method in METHODS:
        tp = fp = fn = tn = errors = positives = negatives = full = 0
        gold_count = covered = benign_count = benign_masked = 0
        preparation, warm = [], []
        for row in rows:
            case = row['input']
            result = next(r for r in row['results'] if r['method'] == method)
            target = gold_units(case['text'], case['goldMaskSubstrings'])
            expected = case['expectedTopicMatch']
            positives += int(expected); negatives += int(not expected)
            gold_count += len(target)
            benign_count += utf16_length(case['text']) - len(target)
            if result['status'] != 'ok':
                errors += 1
                # An explicit processing failure is neither a correct clear output
                # nor successful privacy handling. Keep failures separate from P/R.
                continue
            masked = masked_units(result, case['text'])
            intersection = masked & target
            predicted = bool(intersection) if expected else bool(masked)
            tp += int(expected and predicted); fn += int(expected and not predicted)
            fp += int(not expected and predicted); tn += int(not expected and not predicted)
            covered += len(intersection)
            full += int(expected and bool(target) and target <= masked)
            benign_masked += len(masked - target)
            preparation.append(result['preparationMilliseconds'])
            warm.extend(result['warmMilliseconds'])
        summary[method] = {
            'cases': len(rows), 'positiveCases': positives, 'negativeCases': negatives,
            'errors': errors, 'completedCases': len(rows) - errors,
            'topicMentionDetection': {'tp': tp, 'fp': fp, 'fn': fn, 'tn': tn,
                'precision': ratio(tp, tp + fp), 'recall': ratio(tp, tp + fn),
                'cleanCaseFalseMaskRate': ratio(fp, negatives)},
            'wholeSensitiveSentenceCoverage': ratio(full, positives),
            'sensitiveUTF16Coverage': ratio(covered, gold_count),
            'unrelatedUTF16MaskRate': ratio(benign_masked, benign_count),
            'preparationMilliseconds': distribution(preparation),
            'warmMilliseconds': distribution(warm),
        }
    return summary


def distribution(values):
    if not values:
        return None
    ordered = sorted(values)
    return {'count': len(values), 'median': statistics.median(values),
        'p95': ordered[min(len(ordered) - 1, int((len(ordered) - 1) * .95))],
        'maximum': max(values)}


def jury_export(report):
    rng = random.Random(20261030)
    selected = []
    for topic in SUPPORTED:
        for positive in (True, False):
            pool = [r for r in report['rows'] if r['input']['enabledGroupIDs'] == [topic]
                and r['input']['expectedTopicMatch'] is positive]
            if len(pool) < 4:
                raise ValueError('Need four positive and four negative cases per supported topic')
            # Favor distinct edge tags; deterministic selection is fixed before jury scoring.
            rng.shuffle(pool)
            pool.sort(key=lambda r: -len(r['input']['tags']))
            selected.extend(pool[:4])
    rng.shuffle(selected)
    blind, mapping = [], []
    for index, row in enumerate(selected, 1):
        opaque = f'case-{index:02d}'
        methods = list(METHODS); rng.shuffle(methods)
        options = []
        for letter, method in zip('ABCD', methods):
            result = next(r for r in row['results'] if r['method'] == method)
            options.append({'option': letter, 'status': result['status'], 'output': result['output']})
            mapping.append({'caseID': opaque, 'option': letter, 'method': method, 'sourceCaseID': row['input']['id']})
        blind.append({'caseID': opaque, 'selectedTopics': row['input']['enabledGroupIDs'],
            'input': row['input']['text'], 'options': options})
    return {
        'schemaVersion': 1,
        'policy': report['policyDefinition'],
        'instructions': [
            'Judge the desired topic-hiding outcome, not evidence of misconduct. Topic mentions in negations, quotes and training examples are in scope.',
            'For each option independently score sensitiveMeaningHidden and unrelatedMeaningPreserved from 1 (poor) to 5 (excellent); score equivalent outputs equally.',
            'Do not penalize an output for containing a topic absent from the input. A correctly unchanged unrelated input earns 5/5.',
            'If semantic topic membership is ambiguous, flag disputedCase and explain instead of assuming the annotation is correct.',
            'A processing error is explicit withholding, not a cleaned transcript; assess it separately and do not invent missing output.',
            'Return JSON {judge, cases:[{caseID, disputedCase, options:[{option,sensitiveMeaningHidden,unrelatedMeaningPreserved,reason}]}],limitations}.',
        ],
        'limitations': ['Synthetic text only; no human-adjudicated gold, microphone, iPad runtime or acoustic evaluation.',
            'Methods and expected labels are concealed. Method labels are independently permuted for every case.'],
        'cases': blind,
    }, mapping


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--native-report', required=True, type=Path)
    parser.add_argument('--output-directory', required=True, type=Path)
    parser.add_argument('--executable', type=Path)
    parser.add_argument('--corpus', type=Path)
    parser.add_argument('--artifact', type=Path)
    parser.add_argument('--artifact-sha256')
    parser.add_argument('--revision')
    args = parser.parse_args()
    if args.executable:
        if not all([args.corpus, args.artifact, args.artifact_sha256, args.revision]):
            parser.error('Executable requires corpus, artifact, artifact-sha256 and revision')
        args.native_report.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(args.executable.resolve()), str(args.corpus.resolve()),
            str(args.artifact.resolve()), args.artifact_sha256, str(args.native_report.resolve()), args.revision], check=True)
    data = args.native_report.read_bytes()
    report = json.loads(data)
    if report['schemaVersion'] != 1 or not report['rows']:
        raise ValueError('Invalid/empty native report')
    for row in report['rows']:
        if set(r['method'] for r in row['results']) != set(METHODS) or len(row['results']) != 4:
            raise ValueError('Missing/duplicate native method result')
    supported = [r for r in report['rows'] if all(g in SUPPORTED for g in r['input']['enabledGroupIDs'])]
    unsupported = [r for r in report['rows'] if r not in supported]
    summary = {
        'schemaVersion': 1, 'revision': report['revision'], 'corpusID': report['corpusID'],
        'corpusSHA256': report['corpusSHA256'], 'artifactSHA256': report['artifactSHA256'],
        'nativeReportSHA256': hashlib.sha256(data).hexdigest(),
        'scope': 'Actual native synthetic text results; corpus was authored independently of classifier training.',
        'allTopics': summarize(report['rows']), 'classifierSupportedTopics': summarize(supported),
        'classifierUnsupportedTopics': sorted({g for r in unsupported for g in r['input']['enabledGroupIDs']}),
        'perTopic': {topic: summarize([r for r in report['rows'] if topic in r['input']['enabledGroupIDs']])
            for topic in sorted({g for r in report['rows'] for g in r['input']['enabledGroupIDs']})},
        'notes': report['notes'] + [
            'Topic mention detection counts a positive only if a mask intersects its gold sensitive sentence. Negatives count any mask.',
            'Lexical stages intentionally mask expressions, not whole sentences. Sentence coverage is a distinct maximum-scope measure, not a lexical implementation correctness test.',
            'Errors remain explicit. Precision/recall use completed cases; completedCases and errors must be reported alongside them.',
            'LLM jury exports contain no expected labels, rationale or source IDs that reveal positive/negative labels. No jury scores are produced here.',
        ],
    }
    jury, mapping = jury_export(report)
    args.output_directory.mkdir(parents=True, exist_ok=True)
    for name, value in [('comparison-summary.json', summary), ('jury-blind.json', jury), ('jury-mapping-private.json', mapping)]:
        (args.output_directory / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'rows': len(report['rows']), 'classifierSupportedRows': len(supported),
        'juryCases': len(jury['cases']), 'outputDirectory': str(args.output_directory)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
