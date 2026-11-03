#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/sensitive-topics"
mkdir -p "$task_test_dir"
python3 tools/sensitive_topic_classifier.py \
    --cases Tests/Fixtures/SensitiveTopics/synthetic-exploratory-v1.jsonl \
    --output-directory "$task_test_dir/artifact"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    Sources/Fluid/Services/Privacy/TranscriptTextRedacting.swift \
    Sources/Fluid/Services/Privacy/SensitiveTopicClassifier.swift \
    Tests/SensitiveTopicClassifierTests.swift -o "$task_test_dir/native-tests"
"$task_test_dir/native-tests" "$task_test_dir/artifact/sensitive-topics-v1.json" \
    Tests/Fixtures/SensitiveTopics/synthetic-exploratory-v1.jsonl "$task_test_dir/native-results.json"
python3 - "$task_test_dir" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, str(Path('tools').resolve()))
from sensitive_topic_classifier import features
root = Path(sys.argv[1])
native = json.loads((root / 'native-results.json').read_text())
python = json.loads((root / 'artifact/evaluation.json').read_text())
expected = {row['id']: row for split in python['splits'].values() for row in split['predictions']}
count = 0
for probe in native['featureProbes']:
    assert probe['indices'] == features(probe['text'], 16384), probe['text']
for row in native['predictions']:
    if row['id'] not in expected:
        continue
    for topic, value in row['scores'].items():
        assert abs(value - expected[row['id']]['scores'][topic]) < 1e-8, (row['id'], topic, value)
        count += 1
print(f'Native/Python feature and score parity: {count} comparisons')
print('Native timings:', native['nativeMilliseconds'])
PY
