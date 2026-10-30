#!/usr/bin/env python3
"""Reproducible, CPU-only experimental topic classifier. No network or private data.

Weights and individual predictions must be written to ignored local storage.
The authored exploratory split is not an independent quality benchmark.
"""
import argparse
import hashlib
import json
import math
import random
import re
import time
import unicodedata
from pathlib import Path

FEATURE_ID = "unicode-nfc-lower-alnum-fnv1a64-word12-char345-set-l2-v1"
TOPICS = ["illicit-remuneration", "procurement-collusion", "commercial-metrics"]


def features(text, dimensions):
    words = re.findall(r"[^\W_]+", unicodedata.normalize("NFC", text).lower())
    values = set()

    def add(value):
        hashed = 14695981039346656037
        for byte in value.encode("utf8"):
            hashed = ((hashed ^ byte) * 1099511628211) & 0xffffffffffffffff
        values.add(hashed % dimensions)

    for index, word in enumerate(words):
        add("w:" + word)
        if index:
            add("b:" + words[index - 1] + " " + word)
        value = "^" + word + "$"
        for size in range(3, 6):
            for start in range(len(value) - size + 1):
                add("c:" + value[start:start + size])
    return sorted(values)


def probability(weights, bias, ids):
    scale = 1 / math.sqrt(len(ids)) if ids else 0
    value = bias + sum(weights.get(i, 0) for i in ids) * scale
    return 1 / (1 + math.exp(-max(-40, min(40, value))))


def load_cases(path):
    data = path.read_bytes()
    cases = [json.loads(line) for line in data.decode("utf8").splitlines() if line.strip()]
    ids = [row["id"] for row in cases]
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate case id")
    texts = [unicodedata.normalize("NFC", row["text"]).lower().strip() for row in cases]
    if len(set(texts)) != len(texts):
        raise ValueError("duplicate normalized text across splits")
    for row in cases:
        if row["split"] not in {"train", "development", "exploratory"}:
            raise ValueError("invalid split")
        if not set(row["topics"]) <= set(TOPICS):
            raise ValueError("invalid topic")
    return data, cases


def evaluate(artifact, cases):
    rows = []
    counts = {topic: dict(tp=0, fp=0, fn=0, tn=0) for topic in TOPICS}
    start = time.perf_counter()
    for row in cases:
        ids = features(row["text"], artifact["dimensions"])
        scores = {}
        predicted = []
        for topic in artifact["topics"]:
            score = probability({int(k): v for k, v in topic["weights"].items()}, topic["bias"], ids)
            scores[topic["id"]] = score
            detected = score >= topic["threshold"]
            expected = topic["id"] in row["topics"]
            counts[topic["id"]]["tp" if detected and expected else "fp" if detected else "fn" if expected else "tn"] += 1
            if detected:
                predicted.append(topic["id"])
        rows.append(dict(id=row["id"], text=row["text"], expected=row["topics"], predicted=predicted, scores=scores))
    elapsed = time.perf_counter() - start
    for count in counts.values():
        count["precision"] = count["tp"] / max(1, count["tp"] + count["fp"])
        count["recall"] = count["tp"] / max(1, count["tp"] + count["fn"])
    return dict(cases=len(cases), seconds=elapsed, perTopic=counts, predictions=rows)


def train(cases, digest, dimensions=16384):
    rows = [(row, features(row["text"], dimensions)) for row in cases if row["split"] == "train"]
    development = [row for row in cases if row["split"] == "development"]
    topics = []
    for topic_index, topic in enumerate(TOPICS):
        weights = {}
        bias = 0.0
        order = list(range(len(rows)))
        rng = random.Random(20261030 + topic_index)
        for epoch in range(100):
            rng.shuffle(order)
            rate = 0.7 / (1 + epoch * 0.025)
            for index in order:
                row, ids = rows[index]
                label = float(topic in row["topics"])
                prediction = probability(weights, bias, ids)
                gradient = (label - prediction) * (2.0 if label else 1.0)
                bias += rate * gradient * 0.2
                scale = 1 / math.sqrt(len(ids)) if ids else 0
                for feature in ids:
                    current = weights.get(feature, 0.0)
                    weights[feature] = current + rate * (gradient * scale - 0.0002 * current)
        # Threshold selection uses development only, never exploratory or independent input.
        candidates = [0.15, 0.2, 0.25, 0.3, 0.35, 0.4, 0.45, 0.5]
        def loss(threshold):
            fn = fp = 0
            for row in development:
                detected = probability(weights, bias, features(row["text"], dimensions)) >= threshold
                expected = topic in row["topics"]
                fn += expected and not detected
                fp += detected and not expected
            return (3 * fn + fp, fp, -threshold)
        threshold = min(candidates, key=loss)
        topics.append(dict(id=topic, bias=round(bias, 10), threshold=threshold,
                           weights={str(key): round(value, 10) for key, value in sorted(weights.items())}))
    return dict(formatVersion=1, featureIdentity=FEATURE_ID, dimensions=dimensions, trainingDigest=digest, topics=topics)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cases", type=Path, required=True)
    parser.add_argument("--output-directory", type=Path, required=True)
    parser.add_argument("--artifact", type=Path, help="Evaluate an existing artifact without retraining")
    args = parser.parse_args()
    output = args.output_directory.resolve()
    # Refuse likely accidental checked-in artifact locations. Caller owns this directory.
    if not any(part in {".build", "private_assets", "models", "benchmark_reports"} for part in output.parts):
        parser.error("output must be in an ignored artifact directory")
    output.mkdir(parents=True, exist_ok=True)
    raw, cases = load_cases(args.cases)
    start = time.perf_counter()
    digest = hashlib.sha256(raw).hexdigest()
    artifact = json.loads(args.artifact.read_text()) if args.artifact else train(cases, digest)
    training_seconds = time.perf_counter() - start
    encoded = (json.dumps(artifact, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()
    destination = output / "sensitive-topics-v1.json"
    if destination.exists() and destination.read_bytes() != encoded:
        parser.error("refusing to overwrite a different frozen artifact")
    destination.write_bytes(encoded)
    report = dict(artifactSHA256=hashlib.sha256(encoded).hexdigest(), artifactBytes=len(encoded),
                  trainingDigest=digest, trainingSeconds=training_seconds,
                  evaluationScope="synthetic authored exploratory only; not independent or calibrated",
                  splits={split: evaluate(artifact, [row for row in cases if row["split"] == split])
                          for split in ["development", "exploratory"]})
    (output / "evaluation.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in report.items() if key != "splits"}, ensure_ascii=False))
    for split, result in report["splits"].items():
        print(split, json.dumps(result["perTopic"], ensure_ascii=False))


if __name__ == "__main__":
    main()
