#!/usr/bin/env python3
"""Score paired raw ASR runs against pinned, human-reference audio manifests.

This tool does not run models, read audio, normalize numbers semantically, or
interpret process footprint as model allocation. Quality counts each clip once;
timing includes every measured repetition, with load time reported separately.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path, PurePosixPath
import re
import statistics
import sys

from meeting_asr_text_eval import NORMALIZATION, char_distance, normalize, word_edits

METRIC_VERSION = "paired-human-reference-asr-v1"
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
MAX_JSON_BYTES = 32 * 1024 * 1024


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def text(value, name: str, limit: int = 4096) -> str:
    require(isinstance(value, str) and 0 < len(value) <= limit,
            f"{name} must be a bounded nonempty string")
    return value


def number(value, name: str, *, positive: bool = False) -> float:
    require(isinstance(value, (int, float)) and not isinstance(value, bool)
            and math.isfinite(value) and (value > 0 if positive else value >= 0),
            f"{name} must be finite and {'positive' if positive else 'nonnegative'}")
    return float(value)


def integer(value, name: str, minimum: int, maximum: int) -> int:
    require(isinstance(value, int) and not isinstance(value, bool)
            and minimum <= value <= maximum, f"invalid {name}")
    return value


def unique_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key: {key}")
        result[key] = value
    return result


def read_json(path: Path) -> tuple[dict, str]:
    with path.open("rb") as handle:
        raw = handle.read(MAX_JSON_BYTES + 1)
    require(len(raw) <= MAX_JSON_BYTES, "JSON input exceeds size bound")
    value = json.loads(raw, object_pairs_hook=unique_object,
                       parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite JSON")))
    require(isinstance(value, dict), "JSON root must be an object")
    return value, hashlib.sha256(raw).hexdigest()


def manifest_clips(manifest: dict) -> dict[str, dict]:
    require(isinstance(manifest, dict), "manifest must be an object")
    require(type(manifest.get("schemaVersion")) is int and manifest["schemaVersion"] == 1,
            "unsupported manifest schema")
    for field in ("dataset", "source", "revision", "license", "split"):
        text(manifest.get(field), f"manifest {field}")
    clips = manifest.get("clips")
    require(isinstance(clips, list) and 1 <= len(clips) <= 5000,
            "manifest requires 1..5000 clips")
    result = {}
    paths = set()
    for clip in clips:
        require(isinstance(clip, dict), "clip must be an object")
        identifier = text(clip.get("id"), "clip id", 256)
        require(identifier not in result, "duplicate manifest clip id")
        path = text(clip.get("path"), "clip path", 1024)
        relative = PurePosixPath(path)
        require(not relative.is_absolute() and "\\" not in path and "\x00" not in path
                and all(part not in ("", ".", "..") for part in path.split("/"))
                and not path.startswith("~"), "unsafe clip path")
        require(path not in paths, "duplicate manifest clip path")
        paths.add(path)
        require(isinstance(clip.get("audioSHA256"), str)
                and SHA256.fullmatch(clip["audioSHA256"]) is not None,
                "invalid audio SHA256")
        reference = text(clip.get("reference"), "clip reference", 64_000)
        require(bool(normalize(reference)), "reference has no normalized tokens")
        duration = number(clip.get("durationSeconds"), "clip duration", positive=True)
        require(duration <= 600, "clip exceeds 600 second bound")
        result[identifier] = clip
    return result


def timing_summary(runs: list[dict]) -> dict:
    if not runs:
        return {"calls": 0, "wallSeconds": 0.0, "audioSeconds": 0.0,
                "medianWallSeconds": None, "rtf": None}
    wall = sum(run["wallSeconds"] for run in runs)
    audio = sum(run["durationSeconds"] for run in runs)
    return {"calls": len(runs), "wallSeconds": wall, "audioSeconds": audio,
            "medianWallSeconds": statistics.median(run["wallSeconds"] for run in runs),
            "rtf": wall / audio}


def validate_finite_tree(value, depth: int = 0) -> None:
    require(depth <= 12, "report metadata nesting exceeds bound")
    if isinstance(value, float):
        require(math.isfinite(value), "nonfinite report metadata")
    elif isinstance(value, dict):
        require(len(value) <= 1000, "report metadata object exceeds bound")
        for child in value.values():
            validate_finite_tree(child, depth + 1)
    elif isinstance(value, list):
        require(len(value) <= 20_000, "report metadata array exceeds bound")
        for child in value:
            validate_finite_tree(child, depth + 1)


def score_engine(manifest: dict, report: dict, manifest_sha256: str) -> dict:
    clips = manifest_clips(manifest)
    require(SHA256.fullmatch(manifest_sha256) is not None, "invalid manifest SHA256")
    require(isinstance(report, dict), "report must be an object")
    validate_finite_tree(report)
    require(type(report.get("schemaVersion")) is int and report["schemaVersion"] == 1,
            "unsupported report schema")
    require(report.get("status") == "completed", "report is not completed")
    require(report.get("engine") in ("qwen", "gigaam"), "unknown engine")
    require(report.get("manifestSHA256") == manifest_sha256, "manifest SHA256 mismatch")
    revision = report.get("revision")
    require(isinstance(revision, str) and REVISION.fullmatch(revision) is not None,
            "report needs exact tested revision")
    load = number(report.get("loadSeconds"), "loadSeconds")
    require(load <= 86_400, "loadSeconds exceeds bound")
    if "warmupSeconds" in report:
        require(number(report["warmupSeconds"], "warmupSeconds") <= 86_400,
                "warmupSeconds exceeds bound")
    runs = report.get("runs")
    require(isinstance(runs, list) and 1 <= len(runs) <= len(clips) * 3,
            "report run count is outside bounds")
    grouped: dict[str, dict[int, dict]] = {identifier: {} for identifier in clips}
    for run in runs:
        require(isinstance(run, dict), "run must be an object")
        identifier = run.get("clipID")
        require(isinstance(identifier, str) and identifier in clips, "unknown run clip")
        clip = clips[identifier]
        iteration = integer(run.get("iteration"), "iteration", 0, 2)
        require(iteration not in grouped[identifier], "duplicate clip iteration")
        require(run.get("audioSHA256") == clip["audioSHA256"], "run audio SHA256 mismatch")
        require(run.get("reference") == clip["reference"], "run reference mismatch")
        duration = number(run.get("durationSeconds"), "run duration", positive=True)
        require(abs(duration - clip["durationSeconds"]) <= 1.0 / 16_000,
                "run duration mismatch")
        require(number(run.get("wallSeconds"), "run wallSeconds", positive=True) <= 86_400,
                "run wallSeconds exceeds bound")
        require(run.get("phase") in ("first", "warm"), "invalid run phase")
        require(isinstance(run.get("hypothesis"), str) and len(run["hypothesis"]) <= 200_000,
                "invalid hypothesis")
        grouped[identifier][iteration] = run
    coverage = [set(iterations) for iterations in grouped.values()]
    require(all(coverage), "missing clip coverage")
    iterations = coverage[0]
    require(iterations == set(range(len(iterations))) and all(value == iterations for value in coverage),
            "clip repetitions must be complete, equal and contiguous from zero")

    totals: Counter = Counter()
    rows = []
    changed_repeats = 0
    for identifier, clip in clips.items():
        first = grouped[identifier][0]
        reference, hypothesis = normalize(clip["reference"]), normalize(first["hypothesis"])
        edits = word_edits(reference, hypothesis)
        edits.pop("weak_wer")
        characters = char_distance("".join(reference), "".join(hypothesis))
        row = {"clipID": identifier, "audioSHA256": clip["audioSHA256"],
               "reference": clip["reference"], "hypothesis": first["hypothesis"],
               **edits, "characterDistance": characters,
               "referenceCharacters": len("".join(reference)),
               "hypothesisCharacters": len("".join(hypothesis))}
        row["wer"] = edits["distance"] / edits["reference_tokens"]
        row["cer"] = characters / row["referenceCharacters"]
        row["repeatHypothesesDiffer"] = any(
            run["hypothesis"] != first["hypothesis"] for run in grouped[identifier].values())
        changed_repeats += row["repeatHypothesesDiffer"]
        for key in ("distance", "substitutions", "deletions", "insertions", "reference_tokens",
                    "hypothesis_tokens", "characterDistance", "referenceCharacters", "hypothesisCharacters"):
            totals[key] += row[key]
        rows.append(row)

    result = {"engine": report["engine"], "revision": revision, "clips": len(clips),
              "iterations": len(iterations), "loadSeconds": load,
              "quality": {**dict(totals), "wer": totals["distance"] / totals["reference_tokens"],
                          "cer": totals["characterDistance"] / totals["referenceCharacters"],
                          "repeatedClipsWithDifferentHypotheses": changed_repeats},
              "timing": {"all": timing_summary(runs),
                         "first": timing_summary([run for run in runs if run["phase"] == "first"]),
                         "warm": timing_summary([run for run in runs if run["phase"] == "warm"])},
              "perClip": rows}
    for field in ("footprint", "memory", "platform", "host", "modelID", "modelArtifactSHA256",
                  "runtimeBackend", "executionStatus", "warmupSeconds"):
        if field in report:
            result[field] = report[field]
    return result


def compare(manifest: dict, qwen: dict, gigaam: dict, manifest_sha256: str) -> dict:
    left = score_engine(manifest, qwen, manifest_sha256)
    right = score_engine(manifest, gigaam, manifest_sha256)
    require(left["engine"] == "qwen" and right["engine"] == "gigaam", "engine report swapped")
    require(left["iterations"] == right["iterations"], "paired repetition coverage differs")
    require(left["revision"] == right["revision"], "paired tested revisions differ")
    return {"schemaVersion": 1, "metricVersion": METRIC_VERSION,
            "manifestSHA256": manifest_sha256,
            "dataset": {key: manifest[key] for key in ("dataset", "source", "revision", "license", "split")},
            "normalization": NORMALIZATION,
            "limits": ["Quality counts each manifest clip once using iteration zero.",
                       "No numeric equivalence, transcription cleanup or semantic correction is applied.",
                       "Timing excludes decoding, loading and optional warmup; all are separate phases.",
                       "Process footprint includes host/runtime overhead and sampling can miss short peaks.",
                       "This scorer does not verify device parity or training-set overlap."],
            "engines": {"qwen": left, "gigaam": right},
            "qwenMinusGigaam": {"werPercentagePoints": 100 * (left["quality"]["wer"] - right["quality"]["wer"]),
                                "cerPercentagePoints": 100 * (left["quality"]["cer"] - right["quality"]["cer"]),
                                "rtf": left["timing"]["all"]["rtf"] - right["timing"]["all"]["rtf"]}}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--qwen", type=Path, required=True)
    parser.add_argument("--gigaam", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        require(args.output.resolve() not in {path.resolve() for path in (
            args.manifest, args.qwen, args.gigaam)}, "output must not overwrite an input")
        manifest, manifest_sha = read_json(args.manifest)
        qwen, _ = read_json(args.qwen)
        gigaam, _ = read_json(args.gigaam)
        result = compare(manifest, qwen, gigaam, manifest_sha)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False) + "\n")
    except (ValueError, OSError, TypeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(json.dumps({"clips": result["engines"]["qwen"]["clips"],
                      "qwenWER": result["engines"]["qwen"]["quality"]["wer"],
                      "gigaamWER": result["engines"]["gigaam"]["quality"]["wer"]}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
