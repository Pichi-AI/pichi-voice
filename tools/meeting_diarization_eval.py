#!/usr/bin/env python3
"""Local-only, deterministic meeting diarization evaluator.

This tool reads RTTM timelines and optional speaker-attributed transcript JSON. It never uploads,
rewrites, or copies source recordings. Reports contain aggregate metrics and file fingerprints only.

Report schema 2 corrects schema 1 scoring: same-speaker intervals are unioned before collar
construction, collars are cut at their exact edges, and Jaccard/coverage denominators use the same
scored domain as their intersections. Re-score old inputs; do not compare schema 1 and 2 values as
if the metric implementation were unchanged. Input manifest schema 1 remains supported.

The metrics are DER-style speaker-time error and reference-macro Jaccard error under a global
maximum-overlap one-to-one assignment. They are not a claim of compatibility with an external
benchmark scorer. Undefined scores (no scored reference speech) are null. Collars and excluded
reference overlap affect all temporal metrics, while speaker counts describe the full inventory.
Duration buckets use full unioned reference duration, restricted to speakers with scored support.
Assignment ties use scored geometry, then full reference duration for otherwise identical reference
trajectories, so renaming anonymous labels cannot move recovery between duration buckets.
Each RTTM file must contain one recording/channel scope; a blank timeline means no speech.
An annotated held-out entry establishes input availability, not annotation quality, independence,
or model generalization. Inventory-only entries cannot satisfy the annotated evaluation gate.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
REPORT_SCHEMA_VERSION = 2
METRIC_VERSION = "union-exact-collar-v2"
MAX_SPEAKERS = 12
DEPENDENCY_REVISION = "3fd63887eef1dc25edea8263ce4b44aa854d898b"
DIARIZATION_FINGERPRINT = (
    "FluidAudio-offline-v1@3fd63887eef1dc25edea8263ce4b44aa854d898b;"
    "config=community-default-v1"
)


@dataclass(frozen=True)
class Segment:
    speaker: str
    start: float
    end: float


def resolve(base: Path, value: str) -> Path:
    path = Path(os.path.expanduser(value))
    return path if path.is_absolute() else (base / path).resolve()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_rttm(path: Path) -> list[Segment]:
    segments: list[Segment] = []
    scope: tuple[str, str] | None = None
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 8 or fields[0] != "SPEAKER":
            raise ValueError(f"{path}:{line_number}: expected an RTTM SPEAKER row")
        row_scope = (fields[1], fields[2])
        if scope is not None and scope != row_scope:
            raise ValueError(f"{path}:{line_number}: multiple recording/channel scopes need separate fixtures")
        scope = row_scope
        start, duration = float(fields[3]), float(fields[4])
        if start < 0 or duration <= 0 or not math.isfinite(start + duration):
            raise ValueError(f"{path}:{line_number}: invalid start/duration")
        segments.append(Segment(fields[7], start, start + duration))
    return sorted(segments, key=lambda item: (item.start, item.end, item.speaker))


def active(segments: list[Segment], midpoint: float) -> set[str]:
    return {segment.speaker for segment in segments if segment.start <= midpoint < segment.end}


def union_segments(segments: list[Segment]) -> list[Segment]:
    """Canonical half-open activity sets, independent of row order, duplicates and fragmentation."""
    by_speaker: dict[str, list[Segment]] = {}
    for segment in segments:
        if not isinstance(segment.speaker, str) or not segment.speaker.strip():
            raise ValueError("speaker labels must be nonempty strings")
        if (isinstance(segment.start, bool) or isinstance(segment.end, bool)
                or not isinstance(segment.start, (int, float)) or not isinstance(segment.end, (int, float))
                or not math.isfinite(segment.start) or not math.isfinite(segment.end)
                or segment.start < 0 or segment.end <= segment.start):
            raise ValueError("speaker intervals must have finite nonnegative start and later end")
        by_speaker.setdefault(segment.speaker, []).append(segment)
    merged: list[Segment] = []
    for speaker, items in by_speaker.items():
        speaker_union: list[Segment] = []
        for item in sorted(items, key=lambda value: (value.start, value.end)):
            if speaker_union and item.start <= speaker_union[-1].end:
                previous = speaker_union[-1]
                speaker_union[-1] = Segment(speaker, previous.start, max(previous.end, item.end))
            else:
                speaker_union.append(item)
        merged.extend(speaker_union)
    return sorted(merged, key=lambda item: (item.start, item.end, item.speaker))


def trajectory_order(
    segments: list[Segment], speakers: set[str], reference_durations: dict[str, float] | None = None
) -> list[str]:
    """Break assignment ties by activity geometry, never by an arbitrary slot name."""
    trajectories: dict[str, list[tuple[float, float]]] = {speaker: [] for speaker in speakers}
    for segment in segments:
        trajectories.setdefault(segment.speaker, []).append((segment.start, segment.end))
    return sorted(trajectories, key=lambda speaker: (not bool(trajectories[speaker]),
                                                   tuple(sorted(trajectories[speaker])),
                                                   (reference_durations or {}).get(speaker, 0), speaker))


def scored_spans(
    reference: list[Segment], hypothesis: list[Segment], collar: float, score_overlap: bool
) -> list[tuple[float, float, set[str], set[str]]]:
    if isinstance(collar, bool) or not isinstance(collar, (int, float)) or not math.isfinite(collar) or collar < 0:
        raise ValueError("collar must be finite and nonnegative")
    reference, hypothesis = union_segments(reference), union_segments(hypothesis)
    points = {point for segment in reference + hypothesis for point in (segment.start, segment.end)}
    if not points:
        return []
    lower, upper = min(points), max(points)
    # Event sweep avoids scanning every segment at every boundary. Collar edges must be events:
    # a midpoint test on only RTTM boundaries can retain or remove an entire long interval.
    events: dict[float, list[tuple[str, str, int]]] = {point: [] for point in points}
    for name, segments in (("reference", reference), ("hypothesis", hypothesis)):
        for segment in segments:
            events[segment.start].append((name, segment.speaker, 1))
            events[segment.end].append((name, segment.speaker, -1))
    if collar:
        for segment in reference:
            for point in (segment.start, segment.end):
                left, right = max(lower, point - collar), min(upper, point + collar)
                if left < right:
                    events.setdefault(left, []).append(("collar", "", 1))
                    events.setdefault(right, []).append(("collar", "", -1))
    boundaries = sorted(events)
    state: dict[str, dict[str, int]] = {"reference": {}, "hypothesis": {}, "collar": {}}
    intervals: list[tuple[float, float, set[str], set[str]]] = []
    for left, right in zip(boundaries, boundaries[1:]):
        for name, speaker, delta in events[left]:
            state[name][speaker] = state[name].get(speaker, 0) + delta
            if state[name][speaker] == 0:
                del state[name][speaker]
        if right <= left:
            continue
        if state["collar"]:
            continue
        ref_active, hyp_active = set(state["reference"]), set(state["hypothesis"])
        if not score_overlap and len(ref_active) > 1:
            continue
        intervals.append((left, right, ref_active, hyp_active))
    return intervals


def scored_intervals(
    reference: list[Segment], hypothesis: list[Segment], collar: float, score_overlap: bool
) -> list[tuple[float, set[str], set[str]]]:
    return [(right - left, refs, hyps)
            for left, right, refs, hyps in scored_spans(reference, hypothesis, collar, score_overlap)]


def best_assignment(weights: list[list[float]]) -> list[tuple[int, int]]:
    """Maximum-weight one-to-one assignment; corpus speaker counts are intentionally small."""
    rows = len(weights)
    columns = max((len(row) for row in weights), default=0)
    size = max(rows, columns)
    if size > MAX_SPEAKERS:
        raise ValueError("more than 12 speakers is unsupported by the deterministic evaluator")
    padded = [row + [0.0] * (size - len(row)) for row in weights]
    padded += [[0.0] * size for _ in range(size - rows)]
    @lru_cache(maxsize=None)
    def solve(row: int, used_columns: int) -> tuple[float, tuple[int, ...]]:
        if row == size:
            return 0.0, ()
        best: tuple[float, tuple[int, ...]] | None = None
        for column in range(size):
            if used_columns & (1 << column):
                continue
            remaining_score, remaining_columns = solve(row + 1, used_columns | (1 << column))
            candidate = (padded[row][column] + remaining_score, (column,) + remaining_columns)
            if best is None or candidate[0] > best[0]:
                best = candidate
        assert best is not None
        return best

    _, columns_by_row = solve(0, 0)
    return [(row, column) for row, column in enumerate(columns_by_row) if row < rows and column < columns]


def overlap_matrix(
    intervals: list[tuple[float, set[str], set[str]]], references: list[str], hypotheses: list[str]
) -> list[list[float]]:
    return [[math.fsum(duration for duration, refs, hyps in intervals if ref in refs and hyp in hyps)
             for hyp in hypotheses] for ref in references]


def duration_by_speaker(segments: list[Segment]) -> dict[str, float]:
    segments = union_segments(segments)
    return {
        speaker: sum(segment.end - segment.start for segment in segments if segment.speaker == speaker)
        for speaker in sorted({segment.speaker for segment in segments})
    }


def score_timeline(reference: list[Segment], hypothesis: list[Segment], collar: float, score_overlap: bool) -> dict[str, Any]:
    reference, hypothesis = union_segments(reference), union_segments(hypothesis)
    reference_labels = {segment.speaker for segment in reference}
    hypothesis_labels = {segment.speaker for segment in hypothesis}
    if max(len(reference_labels), len(hypothesis_labels)) > MAX_SPEAKERS:
        raise ValueError("more than 12 speakers is unsupported by the deterministic evaluator")
    spans = scored_spans(reference, hypothesis, collar, score_overlap)
    intervals = [(right - left, refs, hyps) for left, right, refs, hyps in spans]
    # Excluded activity cannot resolve a tied assignment or change scored quality metrics.
    scored_reference = union_segments([Segment(speaker, left, right) for left, right, refs, _ in spans for speaker in refs])
    scored_hypothesis = union_segments([Segment(speaker, left, right) for left, right, _, hyps in spans for speaker in hyps])
    full_ref_durations = duration_by_speaker(reference)
    references = trajectory_order(scored_reference, reference_labels, full_ref_durations)
    hypotheses = trajectory_order(scored_hypothesis, hypothesis_labels)
    matrix = overlap_matrix(intervals, references, hypotheses)
    assignment = best_assignment(matrix)
    hyp_to_ref = {hypotheses[column]: references[row] for row, column in assignment}

    reference_time = miss = false_alarm = confusion = 0.0
    for duration, ref_active, hyp_active in intervals:
        reference_time += duration * len(ref_active)
        miss += duration * max(0, len(ref_active) - len(hyp_active))
        false_alarm += duration * max(0, len(hyp_active) - len(ref_active))
        correct = sum(1 for hyp in hyp_active if hyp_to_ref.get(hyp) in ref_active)
        confusion += duration * max(0, min(len(ref_active), len(hyp_active)) - correct)

    ref_durations = {speaker: math.fsum(duration for duration, refs, _ in intervals if speaker in refs)
                     for speaker in references}
    hyp_durations = {speaker: math.fsum(duration for duration, _, hyps in intervals if speaker in hyps)
                     for speaker in hypotheses}
    mapped_column = {row: column for row, column in assignment}
    jaccard_errors, recovered, coverage_and_purity = [], {}, {}
    for row, speaker in enumerate(references):
        column = mapped_column.get(row)
        intersection = matrix[row][column] if column is not None else 0.0
        hyp_duration = hyp_durations.get(hypotheses[column], 0.0) if column is not None else 0.0
        union = ref_durations[speaker] + hyp_duration - intersection
        if ref_durations[speaker]:
            jaccard_errors.append(1.0 - intersection / union)
        coverage = intersection / ref_durations[speaker] if ref_durations[speaker] else None
        purity = intersection / hyp_duration if hyp_duration else None
        coverage_and_purity[speaker] = {"coverage": coverage, "purity": purity}
        recovered[speaker] = coverage is not None and purity is not None and coverage >= 0.5 and purity >= 0.5

    buckets = {"<1s": [0, 0], "1-3s": [0, 0], "3-10s": [0, 0], ">10s": [0, 0]}
    for speaker, duration in full_ref_durations.items():
        if not ref_durations[speaker]:
            continue
        bucket = "<1s" if duration < 1 else "1-3s" if duration < 3 else "3-10s" if duration < 10 else ">10s"
        buckets[bucket][1] += 1
        buckets[bucket][0] += int(recovered[speaker])

    # A meaningful overlap link is at least 250 ms and at least 5% of the shorter speaker.
    links: list[tuple[int, int]] = []
    for row, ref in enumerate(references):
        for column, hyp in enumerate(hypotheses):
            threshold = max(0.25, 0.05 * min(ref_durations[ref], hyp_durations[hyp]))
            if matrix[row][column] >= threshold:
                links.append((row, column))
    merge_count = sum(1 for column in range(len(hypotheses)) if len({r for r, c in links if c == column}) > 1)
    split_count = sum(1 for row in range(len(references)) if len({c for r, c in links if r == row}) > 1)

    return {
        "metricVersion": METRIC_VERSION,
        "collarSeconds": collar,
        "overlapScored": score_overlap,
        "referenceSpeakers": len(references),
        "hypothesisSpeakers": len(hypotheses),
        "speakerCountError": len(hypotheses) - len(references),
        "scoredReferenceSpeakers": sum(duration > 0 for duration in ref_durations.values()),
        "referenceSpeakerSeconds": reference_time,
        "errorSpeakerSeconds": {"miss": miss, "falseAlarm": false_alarm, "confusion": confusion},
        "mergeCount": merge_count,
        "splitCount": split_count,
        "recoveryByDuration": {
            name: {"recovered": values[0], "total": values[1], "recall": values[0] / values[1] if values[1] else None}
            for name, values in buckets.items()
        },
        "der": (miss + false_alarm + confusion) / reference_time if reference_time else None,
        "derComponents": {
            "miss": miss / reference_time if reference_time else None,
            "falseAlarm": false_alarm / reference_time if reference_time else None,
            "confusion": confusion / reference_time if reference_time else None,
        },
        "jer": math.fsum(jaccard_errors) / len(jaccard_errors) if jaccard_errors else None,
        "speakerCoverageAndPurity": coverage_and_purity,
    }


def words(text: str) -> list[str]:
    return ["".join(character.lower() for character in token if character.isalnum() or character == "'")
            for token in text.split() if any(character.isalnum() for character in token)]


def edit_distance(left: list[str], right: list[str]) -> int:
    row = list(range(len(right) + 1))
    for left_index, left_word in enumerate(left, 1):
        next_row = [left_index]
        for right_index, right_word in enumerate(right, 1):
            next_row.append(min(next_row[-1] + 1, row[right_index] + 1, row[right_index - 1] + (left_word != right_word)))
        row = next_row
    return row[-1]


def cpwer(reference_path: Path, hypothesis_path: Path) -> dict[str, Any]:
    reference = json.loads(reference_path.read_text(encoding="utf-8"))
    hypothesis = json.loads(hypothesis_path.read_text(encoding="utf-8"))
    if max(len(reference), len(hypothesis)) > MAX_SPEAKERS:
        raise ValueError("more than 12 speakers is unsupported by the deterministic evaluator")
    ref_texts = [words(value) for _, value in sorted(reference.items())]
    hyp_texts = [words(value) for _, value in sorted(hypothesis.items())]
    size = max(len(ref_texts), len(hyp_texts))
    costs = []
    for ref_index in range(size):
        ref_words = ref_texts[ref_index] if ref_index < len(ref_texts) else []
        costs.append([
            edit_distance(ref_words, hyp_texts[hyp_index] if hyp_index < len(hyp_texts) else [])
            for hyp_index in range(size)
        ])
    # Convert minimum-cost assignment into maximum-weight assignment.
    maximum = max((value for row in costs for value in row), default=0)
    assignment = best_assignment([[maximum - value for value in row] for row in costs])
    errors = sum(costs[row][column] for row, column in assignment)
    count = sum(len(value) for value in ref_texts)
    return {"errors": errors, "referenceWords": count, "cpWER": errors / count if count else 0.0}


def evaluation_readiness(fixtures: list[dict[str, Any]]) -> dict[str, Any]:
    annotated = sum(fixture.get("split") == "heldOut" and fixture.get("status", "annotated") == "annotated"
                    for fixture in fixtures)
    inventory = sum(fixture.get("split") == "heldOut" and fixture.get("status", "annotated") == "inventory"
                    for fixture in fixtures)
    return {
        "annotatedHeldOutFixtures": annotated,
        "inventoryHeldOutFixtures": inventory,
        "annotatedHeldOutAvailable": annotated > 0,
        "annotationQualityAndIndependenceVerified": False,
        "generalizationEstablished": False,
    }


def validate_manifest(
    manifest_path: Path, require_files: bool = True, require_annotated_held_out: bool = True
) -> dict[str, Any]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        raise ValueError(f"schemaVersion must be {SCHEMA_VERSION}")
    dependency = manifest.get("dependency", {})
    if dependency.get("revision") != DEPENDENCY_REVISION:
        raise ValueError("manifest dependency revision does not match the pinned build")
    if dependency.get("diarizationFingerprint") != DIARIZATION_FINGERPRINT:
        raise ValueError("manifest diarization fingerprint does not match the pinned build")
    fixtures = manifest.get("fixtures", [])
    if not fixtures:
        raise ValueError("manifest must contain at least one fixture")
    ids = [fixture.get("id") for fixture in fixtures]
    if any(not value for value in ids) or len(ids) != len(set(ids)):
        raise ValueError("fixture ids must be present and unique")
    if not any(fixture.get("split") == "heldOut" for fixture in fixtures):
        raise ValueError("manifest must define a heldOut fixture before tuning")
    base = manifest_path.parent
    for fixture in fixtures:
        if fixture.get("split") not in ("development", "heldOut"):
            raise ValueError(f"{fixture['id']}: split must be development or heldOut")
        if fixture.get("status", "annotated") not in ("annotated", "inventory"):
            raise ValueError(f"{fixture['id']}: status must be annotated or inventory")
        if fixture.get("status", "annotated") == "annotated":
            for key in ("referenceRTTM", "hypothesisRTTM"):
                if key not in fixture:
                    raise ValueError(f"{fixture['id']}: annotated fixture is missing {key}")
                if require_files and not resolve(base, fixture[key]).is_file():
                    raise ValueError(f"{fixture['id']}: missing {key} file")
    if require_annotated_held_out and not evaluation_readiness(fixtures)["annotatedHeldOutAvailable"]:
        raise ValueError("annotated heldOut fixture required; inventory alone is not evaluation evidence")
    return manifest


def score_manifest(manifest_path: Path, require_annotated_held_out: bool = False) -> dict[str, Any]:
    manifest = validate_manifest(manifest_path, require_annotated_held_out=require_annotated_held_out)
    base, reports = manifest_path.parent, []
    for fixture in manifest["fixtures"]:
        if fixture.get("status", "annotated") != "annotated":
            inventory_report: dict[str, Any] = {
                "id": fixture["id"],
                "split": fixture["split"],
                "status": "inventory",
                "tags": fixture.get("tags", []),
            }
            expected = fixture.get("expectedSpeakerCount")
            observed = fixture.get("observedRemoteSpeakerCount")
            if isinstance(expected, int):
                inventory_report["expectedSpeakerCount"] = expected
            if isinstance(observed, int):
                inventory_report["observedRemoteSpeakerCount"] = observed
            if isinstance(expected, int) and isinstance(observed, int):
                inventory_report["speakerCountError"] = observed - expected
            for manifest_key, report_key in (
                ("hypothesisRTTM", "hypothesisSHA256"),
                ("runReport", "runReportSHA256"),
            ):
                if fixture.get(manifest_key):
                    path = resolve(base, fixture[manifest_key])
                    if path.is_file():
                        inventory_report[report_key] = sha256(path)
            reports.append(inventory_report)
            continue
        reference_path = resolve(base, fixture["referenceRTTM"])
        hypothesis_path = resolve(base, fixture["hypothesisRTTM"])
        reference, hypothesis = read_rttm(reference_path), read_rttm(hypothesis_path)
        report: dict[str, Any] = {
            "id": fixture["id"], "split": fixture["split"], "tags": fixture.get("tags", []),
            "status": "scored", "referenceSHA256": sha256(reference_path),
            "hypothesisSHA256": sha256(hypothesis_path),
            "comparable": score_timeline(reference, hypothesis, 0.25, False),
            "strict": score_timeline(reference, hypothesis, 0.0, True),
        }
        if fixture.get("referenceSpeakerText") and fixture.get("hypothesisSpeakerText"):
            report["cpWER"] = cpwer(resolve(base, fixture["referenceSpeakerText"]), resolve(base, fixture["hypothesisSpeakerText"]))
        reports.append(report)
    return {
        "schemaVersion": REPORT_SCHEMA_VERSION,
        "inputManifestSchemaVersion": SCHEMA_VERSION,
        "metricVersion": METRIC_VERSION,
        "metricScope": "maximum-overlap assignment; exact collars; unioned speaker activity; shared scored domain",
        "evaluationReadiness": evaluation_readiness(manifest["fixtures"]),
        "dependency": manifest["dependency"],
        "normalization": manifest.get("normalization", {}),
        "fixtures": reports,
    }


def self_test() -> None:
    reference = [Segment("A", 0, 2), Segment("B", 2, 4)]
    perfect = score_timeline(reference, reference, 0, True)
    assert perfect["der"] == 0 and perfect["mergeCount"] == 0 and perfect["splitCount"] == 0
    merged = score_timeline(reference, [Segment("X", 0, 4)], 0, True)
    assert merged["mergeCount"] == 1 and merged["speakerCountError"] == -1 and merged["der"] == 0.5
    split = score_timeline([Segment("A", 0, 4)], [Segment("X", 0, 2), Segment("Y", 2, 4)], 0, True)
    assert split["splitCount"] == 1 and split["speakerCountError"] == 1 and split["der"] == 0.5
    print("meeting_diarization_eval: self-test passed")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("self-test")
    validate = subparsers.add_parser("validate")
    validate.add_argument("manifest", type=Path)
    validate.add_argument("--inventory-only", action="store_true",
                          help="validate inventory structure without satisfying the annotated held-out gate")
    score = subparsers.add_parser("score")
    score.add_argument("manifest", type=Path)
    score.add_argument("--output", type=Path)
    score.add_argument("--require-annotated-held-out", action="store_true",
                       help="reject inventory-only held-out inputs instead of reporting incomplete readiness")
    arguments = parser.parse_args()
    if arguments.command == "self-test":
        self_test()
        return 0
    manifest_path = arguments.manifest.resolve()
    if arguments.command == "validate":
        manifest = validate_manifest(manifest_path, require_annotated_held_out=not arguments.inventory_only)
        readiness = evaluation_readiness(manifest["fixtures"])
        print(f"valid manifest: {len(manifest['fixtures'])} fixtures; "
              f"annotated held-out fixtures: {readiness['annotatedHeldOutFixtures']}; "
              "annotation quality and independence not verified")
        return 0
    report = score_manifest(manifest_path, require_annotated_held_out=arguments.require_annotated_held_out)
    encoded = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if arguments.output:
        arguments.output.parent.mkdir(parents=True, exist_ok=True)
        arguments.output.write_text(encoded, encoding="utf-8")
        print(arguments.output)
    else:
        print(encoded, end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
