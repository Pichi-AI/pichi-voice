#!/usr/bin/env python3
"""Compare supplied diarizer partitions without running models or exposing content."""

import argparse
import json
import math
from pathlib import Path
import sys


MAX_ARTIFACT_BYTES = 8 * 1024 * 1024
MAX_SEGMENTS = 10_000
MAX_SPEAKER_ID_LENGTH = 256
MAX_TIMESTAMP_SECONDS = 24 * 60 * 60
MAX_TOLERANCE_SECONDS = 60


class ArtifactError(ValueError):
    """Stable diagnostic codes deliberately contain no supplied values or paths."""


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ArtifactError("duplicate_json_key")
        result[key] = value
    return result


def reject_constant(value):
    raise ArtifactError("nonfinite_json_number")


def bounded_number(value, maximum, code):
    if type(value) not in (int, float):
        raise ArtifactError(code)
    try:
        number = float(value)
    except (OverflowError, ValueError):
        raise ArtifactError(code) from None
    if not math.isfinite(number) or not 0 <= number <= maximum:
        raise ArtifactError(code)
    return number


def normalize_segments(artifact):
    if not isinstance(artifact, dict) or not isinstance(artifact.get("segments"), list):
        raise ArtifactError("segments_array_required")
    if len(artifact["segments"]) > MAX_SEGMENTS:
        raise ArtifactError("too_many_segments")
    segments = []
    trajectories = {}
    for item in artifact["segments"]:
        if not isinstance(item, dict):
            raise ArtifactError("segment_object_required")
        label = item.get("speakerID")
        if not isinstance(label, str) or not label.strip() or not label.isprintable() or len(label) > MAX_SPEAKER_ID_LENGTH:
            raise ArtifactError("invalid_speaker_id")
        start = bounded_number(item.get("start"), MAX_TIMESTAMP_SECONDS, "invalid_start")
        end = bounded_number(item.get("end"), MAX_TIMESTAMP_SECONDS, "invalid_end")
        if end <= start:
            raise ArtifactError("nonpositive_segment_duration")
        segments.append((label, start, end))
        trajectories.setdefault(label, []).append((start, end))
    # Number speakers by chronological first appearance. Entire numeric
    # trajectories break simultaneous first-appearance ties without consulting
    # raw IDs or input order; identical trajectories are interchangeable.
    signatures = {label: tuple(sorted(ranges)) for label, ranges in trajectories.items()}
    labels = {label: index for index, label in enumerate(sorted(signatures, key=signatures.get))}
    return sorted(((labels[label], start, end) for label, start, end in segments), key=lambda item: (item[1], item[2], item[0]))


def read_artifact(path):
    try:
        with Path(path).open("rb") as stream:
            data = stream.read(MAX_ARTIFACT_BYTES + 1)
    except (OSError, ValueError):
        raise ArtifactError("unreadable_artifact") from None
    if len(data) > MAX_ARTIFACT_BYTES:
        raise ArtifactError("artifact_too_large")
    try:
        artifact = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object, parse_constant=reject_constant)
    except ArtifactError:
        raise
    except (UnicodeError, ValueError, RecursionError):
        raise ArtifactError("invalid_json") from None
    return normalize_segments(artifact)


def compare_partitions(left, right, tolerance_seconds=0.1):
    tolerance = bounded_number(tolerance_seconds, MAX_TOLERANCE_SECONDS, "invalid_tolerance")
    report = {"status": "PASS", "leftSegments": len(left), "rightSegments": len(right), "toleranceSeconds": tolerance}
    if len(left) != len(right):
        return report | {"status": "FAIL", "reason": "segment_count_changed"}
    for index, (a, b) in enumerate(zip(left, right)):
        if a[0] != b[0]:
            return report | {"status": "FAIL", "reason": "speaker_partition_changed", "firstMismatchIndex": index}
        differences = (abs(a[1] - b[1]), abs(a[2] - b[2]))
        if any(delta > tolerance and not math.isclose(delta, tolerance, rel_tol=1e-12, abs_tol=0) for delta in differences):
            return report | {"status": "FAIL", "reason": "boundary_changed", "firstMismatchIndex": index}
    return report


def emit(report):
    print(json.dumps(report, separators=(",", ":"), sort_keys=True, allow_nan=False))


class CompactParser(argparse.ArgumentParser):
    def error(self, message):
        emit({"status": "ERROR", "reason": "invalid_arguments"})
        raise SystemExit(2)


def main(argv=None):
    parser = CompactParser(description=__doc__)
    parser.add_argument("left", help="First supplied raw diarizer JSON artifact")
    parser.add_argument("right", help="Second supplied raw diarizer JSON artifact")
    parser.add_argument("--tolerance-seconds", type=float, default=0.1, help="Finite boundary tolerance from 0 to 60 seconds (default: 0.1)")
    arguments = parser.parse_args(argv)
    try:
        bounded_number(arguments.tolerance_seconds, MAX_TOLERANCE_SECONDS, "invalid_tolerance")
    except ArtifactError as error:
        emit({"status": "ERROR", "reason": str(error)})
        return 2
    partitions = []
    for name in ("left", "right"):
        try:
            partitions.append(read_artifact(getattr(arguments, name)))
        except ArtifactError as error:
            emit({"status": "ERROR", "input": name, "reason": str(error)})
            return 2
    report = compare_partitions(*partitions, tolerance_seconds=arguments.tolerance_seconds)
    emit(report)
    return 0 if report["status"] == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
