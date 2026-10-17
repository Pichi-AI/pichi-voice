#!/usr/bin/env python3
"""Analytic and metamorphic scorer oracles. Synthetic metadata only, no models or audio."""

import importlib.util
import itertools
import json
import random
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools/meeting_diarization_eval.py"
SPEC = importlib.util.spec_from_file_location("meeting_diarization_eval", SCRIPT)
EVAL = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = EVAL
SPEC.loader.exec_module(EVAL)
S = EVAL.Segment


def without_names(report):
    """Labels may change; their coverage/purity population and all aggregate metrics must not."""
    report = dict(report)
    report["speakerCoverageAndPurity"] = sorted(
        report["speakerCoverageAndPurity"].values(),
        key=lambda value: (value["coverage"] is None, value["coverage"],
                           value["purity"] is None, value["purity"]),
    )
    return report


class TimelineOracles(unittest.TestCase):
    def score(self, reference, hypothesis, collar=0, overlap=True):
        return EVAL.score_timeline(reference, hypothesis, collar, overlap)

    def test_analytic_miss_false_alarm_and_confusion(self):
        # Ref speaker-time=4, missing A=1, false alarm=1, one wrong mapped voice=1.
        report = self.score([S("A", 0, 2), S("B", 2, 4)],
                            [S("X", 0, 1), S("Y", 2, 3), S("X", 3, 5)])
        self.assertEqual(report["referenceSpeakerSeconds"], 4)
        self.assertEqual(report["errorSpeakerSeconds"], {"miss": 1, "falseAlarm": 1, "confusion": 1})
        self.assertEqual(report["der"], .75)

    def test_exact_collar_edges_cut_long_intervals(self):
        report = self.score([S("A", 0, 10)], [S("X", 0, 9)], collar=.25)
        self.assertEqual(report["referenceSpeakerSeconds"], 9.5)
        self.assertEqual(report["errorSpeakerSeconds"]["miss"], .75)
        self.assertAlmostEqual(report["der"], .75 / 9.5)
        self.assertAlmostEqual(report["jer"], .75 / 9.5)
        self.assertAlmostEqual(report["speakerCoverageAndPurity"]["A"]["coverage"], 8.75 / 9.5)
        self.assertEqual(report["speakerCoverageAndPurity"]["A"]["purity"], 1)

    def test_collar_covers_transition_from_both_sides(self):
        report = self.score([S("A", 0, 2), S("B", 2, 4)],
                            [S("X", 0, 2.2), S("Y", 2.2, 4)], collar=.25)
        self.assertEqual(report["referenceSpeakerSeconds"], 3)
        self.assertEqual(report["der"], 0)
        self.assertEqual(report["jer"], 0)

    def test_collar_masks_false_alarm_on_both_sides_of_reference(self):
        report = self.score([S("A", 1, 3)], [S("X", 0, 4)], collar=.25)
        self.assertEqual(report["referenceSpeakerSeconds"], 1.5)
        self.assertEqual(report["errorSpeakerSeconds"]["falseAlarm"], 1.5)
        self.assertEqual(report["der"], 1)
        self.assertEqual(report["jer"], .5)

    def test_overlapping_collars_are_a_union_not_double_subtraction(self):
        # Canonical A activity has two disjoint bouts; only [1.3, 1.7) survives collars.
        report = self.score([S("A", 0, .4), S("A", 1, 2)], [S("X", 0, 2)], collar=.3)
        self.assertAlmostEqual(report["referenceSpeakerSeconds"], .4)
        self.assertAlmostEqual(report["errorSpeakerSeconds"]["falseAlarm"], 0)
        self.assertAlmostEqual(report["der"], 0)

    def test_perfect_scores_use_the_same_domain_for_denominators(self):
        reference = [S("A", 0, 1), S("B", .5, 1.5), S("A", 2, 4)]
        for collar, overlap in itertools.product((0, .1, .25), (False, True)):
            with self.subTest(collar=collar, overlap=overlap):
                report = self.score(reference, reference, collar, overlap)
                self.assertEqual(report["der"], 0)
                self.assertEqual(report["jer"], 0)
                self.assertTrue(all(value in ({"coverage": 1, "purity": 1}, {"coverage": None, "purity": None})
                                    for value in report["speakerCoverageAndPurity"].values()))

    def test_true_overlap_counts_reference_speaker_time(self):
        reference = [S("A", 0, 2), S("B", 1, 3)]
        hypothesis = [S("X", 0, 2)]
        strict = self.score(reference, hypothesis)
        self.assertEqual(strict["referenceSpeakerSeconds"], 4)
        self.assertEqual(strict["errorSpeakerSeconds"]["miss"], 2)
        self.assertEqual(strict["der"], .5)
        excluded = self.score(reference, hypothesis, overlap=False)
        self.assertEqual(excluded["referenceSpeakerSeconds"], 2)
        self.assertEqual(excluded["errorSpeakerSeconds"]["miss"], 1)
        self.assertEqual(excluded["der"], .5)

    def test_half_open_endpoints_do_not_create_overlap(self):
        intervals = EVAL.scored_intervals([S("A", 0, 1), S("B", 1, 2)], [S("X", 0, 2)], 0, True)
        self.assertEqual(intervals, [(1, {"A"}, {"X"}), (1, {"B"}, {"X"})])

    def test_speaker_duration_unions_duplicates_nested_overlap_and_adjacency(self):
        segments = [S("A", 0, 2), S("A", 1, 3), S("A", 0, 2), S("A", .2, .4),
                    S("A", 3, 4), S("B", 2, 5)]
        self.assertEqual(EVAL.duration_by_speaker(segments), {"A": 4, "B": 3})
        self.assertEqual(EVAL.union_segments(segments), [S("A", 0, 4), S("B", 2, 5)])

    def test_duplication_and_fragmentation_do_not_change_collar_or_metrics(self):
        reference = [S("A", 0, 4), S("B", 3, 6)]
        hypothesis = [S("X", 0, 3.5), S("Y", 3.5, 6)]
        ref_fragments = [S("A", 0, 1), S("A", 1, 4), S("A", 2, 3), S("B", 3, 4), S("B", 4, 6)]
        hyp_fragments = [S("X", 0, 2), S("X", 2, 3.5), S("Y", 3.5, 5), S("Y", 5, 6)]
        for collar, overlap in itertools.product((0, .25), (False, True)):
            with self.subTest(collar=collar, overlap=overlap):
                expected = self.score(reference, hypothesis, collar, overlap)
                self.assertEqual(self.score(ref_fragments * 2, hyp_fragments * 3, collar, overlap), expected)

    def test_input_and_slot_permutations_preserve_assignment_tie_metrics(self):
        # Two equal-overlap assignments have different Jaccard scores. Geometry breaks the tie.
        reference = [S("A", 0, 3), S("B", 3, 8)]
        hypothesis = [S("X", 0, 1), S("X", 3, 5), S("Y", 1, 3), S("Y", 5, 8)]
        baseline = without_names(self.score(reference, hypothesis))
        for ref_labels, hyp_labels in itertools.product(itertools.permutations(("a", "z")), repeat=2):
            refs = [S(dict(zip(("A", "B"), ref_labels))[s.speaker], s.start, s.end) for s in reversed(reference)]
            hyps = [S(dict(zip(("X", "Y"), hyp_labels))[s.speaker], s.start, s.end) for s in reversed(hypothesis)]
            self.assertEqual(without_names(self.score(refs, hyps)), baseline)

    def test_excluded_activity_cannot_resolve_assignment_tie(self):
        reference = [S("A", 2, 5), S("B", 5, 10)]
        hypothesis = [S("X", 2, 3), S("X", 5, 7), S("Y", 3, 5), S("Y", 7, 10)]
        masked_change = hypothesis + [S("Y", 2, 2.1)]
        self.assertEqual(EVAL.scored_intervals(reference, hypothesis, .25, True),
                         EVAL.scored_intervals(reference, masked_change, .25, True))
        self.assertEqual(self.score(reference, hypothesis, .25), self.score(reference, masked_change, .25))

    def test_identical_scored_geometry_does_not_bind_duration_bucket_to_label(self):
        reference = [S("A", 0, 1), S("B", 0, .8)]
        hypothesis = [S("X", 0, .8), S("Y", .3, 2)]
        renamed = [S("B" if item.speaker == "A" else "A", item.start, item.end) for item in reference]
        baseline = without_names(self.score(reference, hypothesis, .25))
        self.assertEqual(without_names(self.score(renamed, hypothesis, .25)), baseline)

    def test_nonzero_timeline_translation_preserves_metrics(self):
        reference = [S("A", 0, 3), S("B", 2, 5)]
        hypothesis = [S("X", .25, 3), S("Y", 2.5, 6)]
        shift = lambda values: [S(item.speaker, item.start + 10000, item.end + 10000) for item in values]
        for collar, overlap in itertools.product((0, .25), (False, True)):
            self.assertEqual(self.score(shift(reference), shift(hypothesis), collar, overlap),
                             self.score(reference, hypothesis, collar, overlap))

    def test_exact_assignment_limit_has_no_approximate_fallback(self):
        supported = [S(str(index), index, index + 1) for index in range(12)]
        self.assertEqual(self.score(supported, supported)["der"], 0)
        unsupported = supported + [S("thirteenth", 12, 13)]
        with patch.object(EVAL, "overlap_matrix", side_effect=AssertionError("matrix allocated before limit")):
            with self.assertRaisesRegex(ValueError, "more than 12 speakers is unsupported"):
                self.score(unsupported, unsupported)

    def test_seeded_metamorphic_cases_preserve_complete_report(self):
        generator = random.Random(20261016)
        for case in range(40):
            reference, hypothesis = [], []
            for destination, prefix in ((reference, "r"), (hypothesis, "h")):
                for index in range(8):
                    start = generator.randrange(0, 40) / 4
                    destination.append(S(prefix + str(index % 3), start, start + generator.randrange(1, 12) / 4))
            transformed = []
            for segments in (reference, hypothesis):
                fragments = [part for item in segments for part in (
                    S(item.speaker, item.start, (item.start + item.end) / 2),
                    S(item.speaker, (item.start + item.end) / 2, item.end), item)]
                generator.shuffle(fragments)
                transformed.append(fragments)
            for collar, overlap in itertools.product((0, .25), (False, True)):
                with self.subTest(case=case, collar=collar, overlap=overlap):
                    self.assertEqual(self.score(*transformed, collar, overlap), self.score(reference, hypothesis, collar, overlap))

    def test_undefined_scores_are_not_reported_as_perfect(self):
        for reference, hypothesis, collar in (([], [], 0), ([], [S("X", 0, 2)], 0),
                                              ([S("A", 0, .2)], [S("X", 0, .2)], .25)):
            report = self.score(reference, hypothesis, collar)
            self.assertIsNone(report["der"])
            self.assertIsNone(report["jer"])
            self.assertEqual(report["scoredReferenceSpeakers"], 0)
        self.assertEqual(self.score([], [S("X", 0, 2)])["errorSpeakerSeconds"]["falseAlarm"], 2)

    def test_invalid_intervals_and_collars_fail_closed(self):
        for start, end in ((-1, 2), (1, 1), (2, 1), (float("nan"), 2), (0, float("inf")), (True, 2)):
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                self.score([S("A", start, end)], [])
        for collar in (-1, float("nan"), float("inf"), True):
            with self.subTest(collar=collar), self.assertRaises(ValueError):
                self.score([S("A", 0, 2)], [], collar)


class ManifestGateOracles(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="synthetic-diarization-eval-")
        self.addCleanup(self.directory.cleanup)
        self.base = Path(self.directory.name)
        self.path = self.base / "manifest.json"
        self.manifest = {
            "schemaVersion": 1,
            "dependency": {"revision": EVAL.DEPENDENCY_REVISION,
                           "diarizationFingerprint": EVAL.DIARIZATION_FINGERPRINT},
            "fixtures": [{"id": "development", "split": "development", "status": "inventory"},
                         {"id": "held-out", "split": "heldOut", "status": "inventory"}],
        }
        self.write()

    def write(self):
        self.path.write_text(json.dumps(self.manifest), encoding="utf-8")

    def annotate_held_out(self):
        for name, speaker in (("ref", "A"), ("hyp", "X")):
            (self.base / f"{name}.rttm").write_text(f"SPEAKER synthetic 1 0 2 <NA> <NA> {speaker} <NA> <NA>\n")
        self.manifest["fixtures"][1].update(status="annotated", referenceRTTM="ref.rttm", hypothesisRTTM="hyp.rttm")
        self.write()

    def cli(self, *arguments):
        return subprocess.run([sys.executable, "-S", str(SCRIPT), *arguments],
                              capture_output=True, text=True, timeout=10)

    def test_inventory_is_valid_inventory_but_not_annotated_evaluation(self):
        with self.assertRaisesRegex(ValueError, "annotated heldOut fixture required"):
            EVAL.validate_manifest(self.path)
        EVAL.validate_manifest(self.path, require_annotated_held_out=False)
        report = EVAL.score_manifest(self.path)
        self.assertEqual(report["schemaVersion"], 2)
        self.assertEqual(report["inputManifestSchemaVersion"], 1)
        self.assertEqual(report["metricVersion"], EVAL.METRIC_VERSION)
        self.assertFalse(report["evaluationReadiness"]["annotatedHeldOutAvailable"])
        self.assertFalse(report["evaluationReadiness"]["generalizationEstablished"])
        self.assertTrue(all("strict" not in fixture for fixture in report["fixtures"]))

    def test_cli_inventory_opt_in_and_explicit_gate(self):
        self.assertEqual(self.cli("validate", str(self.path)).returncode, 2)
        inventory = self.cli("validate", str(self.path), "--inventory-only")
        self.assertEqual(inventory.returncode, 0)
        self.assertIn("annotated held-out fixtures: 0", inventory.stdout)
        self.assertEqual(self.cli("score", str(self.path), "--require-annotated-held-out").returncode, 2)
        report = self.cli("score", str(self.path))
        self.assertEqual(report.returncode, 0)
        self.assertFalse(json.loads(report.stdout)["evaluationReadiness"]["annotatedHeldOutAvailable"])

    def test_annotated_files_enable_readiness_but_do_not_prove_quality_or_independence(self):
        self.annotate_held_out()
        EVAL.validate_manifest(self.path)
        report = EVAL.score_manifest(self.path, require_annotated_held_out=True)
        readiness = report["evaluationReadiness"]
        self.assertTrue(readiness["annotatedHeldOutAvailable"])
        self.assertEqual(readiness["annotatedHeldOutFixtures"], 1)
        self.assertFalse(readiness["annotationQualityAndIndependenceVerified"])
        self.assertFalse(readiness["generalizationEstablished"])
        self.assertEqual(report["fixtures"][1]["strict"]["der"], 0)
        self.assertNotIn("SPEAKER synthetic", json.dumps(report))

    def test_missing_annotation_files_do_not_pass_readiness_gate(self):
        self.annotate_held_out()
        (self.base / "ref.rttm").unlink()
        with self.assertRaisesRegex(ValueError, "missing referenceRTTM file"):
            EVAL.validate_manifest(self.path)

    def test_empty_hypothesis_is_scored_as_all_reference_speech_missed(self):
        self.annotate_held_out()
        (self.base / "hyp.rttm").write_text("# no detected voices\n")
        report = EVAL.score_manifest(self.path, require_annotated_held_out=True)
        self.assertEqual(report["fixtures"][1]["strict"]["der"], 1)
        self.assertEqual(report["fixtures"][1]["strict"]["errorSpeakerSeconds"]["miss"], 2)

    def test_empty_reference_does_not_turn_false_alarm_into_zero_der(self):
        self.annotate_held_out()
        (self.base / "ref.rttm").write_text("")
        report = EVAL.score_manifest(self.path, require_annotated_held_out=True)
        strict = report["fixtures"][1]["strict"]
        self.assertIsNone(strict["der"])
        self.assertEqual(strict["errorSpeakerSeconds"]["falseAlarm"], 2)

    def test_multiple_rttm_recording_or_channel_scopes_are_not_conflated(self):
        self.annotate_held_out()
        for recording, channel in (("other", "1"), ("synthetic", "2")):
            with self.subTest(recording=recording, channel=channel):
                (self.base / "hyp.rttm").write_text(
                    "SPEAKER synthetic 1 0 2 <NA> <NA> X <NA> <NA>\n"
                    f"SPEAKER {recording} {channel} 0 2 <NA> <NA> Y <NA> <NA>\n")
                with self.assertRaisesRegex(ValueError, "multiple recording/channel scopes"):
                    EVAL.score_manifest(self.path)

    def test_unknown_status_is_not_silently_inventory(self):
        self.manifest["fixtures"][1]["status"] = "annotated-typo"
        self.write()
        with self.assertRaisesRegex(ValueError, "status must be annotated or inventory"):
            EVAL.score_manifest(self.path)


if __name__ == "__main__":
    unittest.main()
