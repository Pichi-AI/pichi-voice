#!/usr/bin/env python3
"""Synthetic tests of the artifact comparator; no diarizer or model inference."""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/dev/check-diarization-repeatability.py"
SPEC = importlib.util.spec_from_file_location("diarization_repeatability", SCRIPT)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def segment(label, start, end):
    return {"speakerID": label, "start": start, "end": end}


def artifact(*segments):
    return {"segments": list(segments)}


class DiarizationRepeatabilityTests(unittest.TestCase):
    def compare(self, left, right, tolerance=0.1):
        return CHECK.compare_partitions(CHECK.normalize_segments(left), CHECK.normalize_segments(right), tolerance)

    def cli(self, left, right, *arguments):
        with tempfile.TemporaryDirectory(prefix="synthetic-diarization-metadata-") as directory:
            left_path = Path(directory) / "PRIVATE_PATH_MARKER-left.json"
            right_path = Path(directory) / "PRIVATE_PATH_MARKER-right.json"
            left_path.write_text(left if isinstance(left, str) else json.dumps(left), encoding="utf-8")
            right_path.write_text(right if isinstance(right, str) else json.dumps(right), encoding="utf-8")
            result = subprocess.run([sys.executable, "-S", str(SCRIPT), str(left_path), str(right_path), *arguments],
                                    capture_output=True, text=True, timeout=10)
            self.assertNotIn(directory, result.stdout + result.stderr)
            self.assertNotIn("PRIVATE_PATH_MARKER", result.stdout + result.stderr)
            self.assertEqual(result.stderr, "")
            return result.returncode, json.loads(result.stdout)

    def test_arbitrary_speaker_id_permutation_passes(self):
        left = artifact(segment("old-a", 0, 3), segment("old-b", 4, 7), segment("old-a", 8, 11))
        right = artifact(segment("new-b", 0, 3), segment("new-a", 4, 7), segment("new-b", 8, 11))
        self.assertEqual(self.compare(left, right)["status"], "PASS")

    def test_input_array_order_is_not_a_partition_change(self):
        left = artifact(segment("a", 0, 3), segment("b", 4, 7), segment("a", 8, 11))
        right = artifact(*reversed(left["segments"]))
        self.assertEqual(self.compare(left, right)["status"], "PASS")

    def test_simultaneous_first_appearance_uses_numeric_trajectory_tie_break(self):
        left = artifact(segment("a", 0, 3), segment("b", 0, 3), segment("a", 4, 6))
        right = artifact(segment("new-b", 0, 3), segment("new-a", 0, 3), segment("new-a", 4, 6))
        self.assertEqual(self.compare(left, right)["status"], "PASS")

    def test_identical_speaker_trajectories_are_interchangeable(self):
        left = artifact(segment("a", 0, 3), segment("b", 0, 3))
        right = artifact(segment("new-b", 0, 3), segment("new-a", 0, 3))
        self.assertEqual(self.compare(left, right)["status"], "PASS")

    def test_two_ids_do_not_hide_changed_speaker_assignment(self):
        left = artifact(segment("a", 0, 3), segment("b", 4, 7), segment("a", 8, 11))
        right = artifact(segment("a", 0, 3), segment("b", 4, 7), segment("b", 8, 11))
        report = self.compare(left, right)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["reason"], "speaker_partition_changed")
        self.assertEqual(report["firstMismatchIndex"], 2)

    def test_meaningful_boundary_shift_fails(self):
        left = artifact(segment("a", 0, 3), segment("b", 4, 7))
        right = artifact(segment("a", 0, 3), segment("b", 4.45, 7))
        self.assertEqual(self.compare(left, right)["reason"], "boundary_changed")

    def test_small_boundary_jitter_and_exact_collar_pass(self):
        left = artifact(segment("a", 1, 3))
        for offset in (0.05, 0.1):
            self.assertEqual(self.compare(left, artifact(segment("b", 1 + offset, 3 + offset)))["status"], "PASS")

    def test_zero_tolerance_does_not_accept_jitter(self):
        left = artifact(segment("a", 0, 3))
        right = artifact(segment("a", 0, 3.000000001))
        self.assertEqual(self.compare(left, right, 0)["status"], "FAIL")

    def test_count_change_or_same_speaker_split_fails(self):
        left = artifact(segment("a", 0, 3))
        right = artifact(segment("a", 0, 1), segment("a", 1, 3))
        self.assertEqual(self.compare(left, right)["reason"], "segment_count_changed")

    def test_empty_outputs_compare_equal_without_proving_quality(self):
        self.assertEqual(self.compare(artifact(), artifact())["status"], "PASS")

    def test_nonzero_timeline_and_overlap_are_valid(self):
        left = artifact(segment("a", 100, 105), segment("b", 102, 108))
        self.assertEqual(self.compare(left, left)["status"], "PASS")

    def test_invalid_root_and_segment_shapes_are_rejected(self):
        for value in ([], None, {}, {"segments": {}}, {"segments": [None]}, {"segments": [1]}):
            with self.subTest(value=value), self.assertRaises(CHECK.ArtifactError):
                CHECK.normalize_segments(value)

    def test_boolean_string_missing_and_nonfinite_times_are_rejected(self):
        for value in (True, False, "1", None, float("nan"), float("inf"), -float("inf"), 10 ** 400):
            for field in ("start", "end"):
                item = segment("a", 1, 3)
                item[field] = value
                with self.subTest(field=field, kind=type(value).__name__), self.assertRaises(CHECK.ArtifactError):
                    CHECK.normalize_segments(artifact(item))

    def test_negative_reversed_zero_length_and_out_of_bound_times_are_rejected(self):
        for start, end in ((-1, 3), (3, 1), (3, 3), (0, CHECK.MAX_TIMESTAMP_SECONDS + 1)):
            with self.subTest(start=start, end=end), self.assertRaises(CHECK.ArtifactError):
                CHECK.normalize_segments(artifact(segment("a", start, end)))

    def test_documented_timestamp_upper_bound_is_inclusive(self):
        value = artifact(segment("a", CHECK.MAX_TIMESTAMP_SECONDS - 1, CHECK.MAX_TIMESTAMP_SECONDS))
        self.assertEqual(self.compare(value, value)["status"], "PASS")

    def test_speaker_ids_are_bounded_and_nonempty_printable_strings(self):
        for label in (None, True, 7, "", "  ", "a\nb", "\ud800", "a" * (CHECK.MAX_SPEAKER_ID_LENGTH + 1)):
            with self.subTest(kind=type(label).__name__), self.assertRaises(CHECK.ArtifactError):
                CHECK.normalize_segments(artifact(segment(label, 0, 3)))

    def test_segment_count_is_bounded(self):
        value = {"segments": [segment("a", 0, 3)] * (CHECK.MAX_SEGMENTS + 1)}
        with self.assertRaisesRegex(CHECK.ArtifactError, "too_many_segments"):
            CHECK.normalize_segments(value)

    def test_cli_success_ignores_transcript_embeddings_and_private_metadata(self):
        left = artifact(segment("SYNTHETIC_SPEAKER_SECRET", 0, 3))
        left["text"] = "SYNTHETIC_TRANSCRIPT_MUST_NOT_PRINT"
        left["modelPath"] = "/SYNTHETIC_PRIVATE_METADATA_PATH"
        left["segments"][0]["embedding"] = [0.1, 0.2]
        status, report = self.cli(left, artifact(segment("different-id", 0, 3)))
        self.assertEqual(status, 0)
        self.assertEqual(report["status"], "PASS")
        self.assertFalse(any("SYNTHETIC" in str(value) for value in report.values()))

    def test_cli_meaningful_failure_returns_nonzero(self):
        status, report = self.cli(artifact(segment("a", 0, 3)), artifact(segment("b", 0, 3.5)))
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "FAIL")

    def test_cli_malformed_json_duplicate_keys_and_nonfinite_constants_return_error(self):
        for text in ("{", '{"segments":[],"segments":[]}', '{"segments":[],"private":NaN}',
                     '{"segments":[],"private":Infinity}', '{"segments":[],"private":-Infinity}',
                     '{"segments":[{"speakerID":"a","start":0,"end":1e999}]}'):
            with self.subTest(text=text):
                status, report = self.cli(text, artifact())
                self.assertEqual(status, 2)
                self.assertEqual(report["status"], "ERROR")
                self.assertEqual(report["input"], "left")

    def test_invalid_utf8_deep_json_and_oversized_artifacts_are_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "metadata.json"
            for data in (b'\xff', b'[' * 2000 + b']' * 2000, b' ' * (CHECK.MAX_ARTIFACT_BYTES + 1)):
                path.write_bytes(data)
                with self.assertRaises(CHECK.ArtifactError):
                    CHECK.read_artifact(path)

    def test_unreadable_path_errors_do_not_expose_path(self):
        result = subprocess.run([sys.executable, "-S", str(SCRIPT), "/SYNTHETIC_PATH_SECRET/no.json", "unused"], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["reason"], "unreadable_artifact")
        self.assertNotIn("SYNTHETIC_PATH_SECRET", result.stdout + result.stderr)
        self.assertEqual(result.stderr, "")

    def test_invalid_tolerance_bounds_are_rejected(self):
        value = artifact(segment("a", 0, 3))
        for tolerance in (True, -1, float("nan"), float("inf"), CHECK.MAX_TOLERANCE_SECONDS + 1):
            with self.subTest(tolerance=tolerance), self.assertRaisesRegex(CHECK.ArtifactError, "invalid_tolerance"):
                self.compare(value, value, tolerance)

    def test_cli_invalid_tolerance_and_unrecognized_private_argument_are_compact(self):
        for value in ("nan", "inf", "-1", "61", "SYNTHETIC_VALUE_SECRET"):
            status, report = self.cli(artifact(), artifact(), "--tolerance-seconds", value)
            self.assertEqual(status, 2)
            self.assertEqual(report["status"], "ERROR")
        status, report = self.cli(artifact(), artifact(), "/SYNTHETIC_EXTRA_PATH_SECRET")
        self.assertEqual(status, 2)
        self.assertEqual(report, {"status": "ERROR", "reason": "invalid_arguments"})


if __name__ == "__main__":
    unittest.main()
