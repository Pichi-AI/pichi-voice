import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest

import qwen_gigaam_eval as scorer


class PairedASRTests(unittest.TestCase):
    def setUp(self):
        self.manifest = dict(schemaVersion=1, dataset="public synthetic fixture",
                             source="https://example.test/corpus", revision="fixture-v1",
                             license="CC-BY-4.0", split="test", clips=[
                                 dict(id="short", path="audio/short.wav", audioSHA256="a" * 64,
                                      reference="Ёж идёт", durationSeconds=2),
                                 dict(id="long", path="audio/long.wav", audioSHA256="b" * 64,
                                      reference="раз два три четыре пять шесть семь восемь", durationSeconds=8)])
        self.digest = "c" * 64

    def report(self, engine="qwen", hypotheses=None, repeats=1):
        if hypotheses is None:
            hypotheses = [clip["reference"] for clip in self.manifest["clips"]]
        return dict(schemaVersion=1, status="completed", engine=engine,
                    manifestSHA256=self.digest, revision="d" * 40, loadSeconds=1.5,
                    warmupSeconds=0.5, footprint=dict(samplingIntervalSeconds=0.025, peakBytes=1000),
                    runs=[dict(clipID=clip["id"], audioSHA256=clip["audioSHA256"],
                               reference=clip["reference"], hypothesis=hypotheses[index],
                               durationSeconds=clip["durationSeconds"], iteration=iteration,
                               wallSeconds=0.1 * clip["durationSeconds"], phase="warm")
                          for iteration in range(repeats)
                          for index, clip in enumerate(self.manifest["clips"])])

    def test_identical_raw_wording_normalizes_punctuation_case_and_yo(self):
        report = self.report(hypotheses=["ЕЖ, ИДЁТ!", "Раз два три четыре пять шесть семь восемь."])
        result = scorer.score_engine(self.manifest, report, self.digest)
        self.assertEqual(result["quality"]["wer"], 0)
        self.assertEqual(result["quality"]["cer"], 0)
        self.assertEqual(result["quality"]["reference_tokens"], 10)
        self.assertEqual(result["timing"]["first"]["calls"], 0)
        self.assertIsNone(result["timing"]["first"]["rtf"])
        self.assertEqual(result["warmupSeconds"], 0.5)
        self.assertEqual(result["footprint"], report["footprint"])

    def test_error_rates_are_corpus_weighted_not_mean_of_clip_rates(self):
        report = self.report(hypotheses=["", self.manifest["clips"][1]["reference"]])
        result = scorer.score_engine(self.manifest, report, self.digest)
        self.assertEqual(result["quality"]["distance"], 2)
        self.assertEqual(result["quality"]["deletions"], 2)
        self.assertEqual(result["quality"]["wer"], 0.2)
        self.assertNotEqual(result["quality"]["wer"], 0.5)

    def test_repetitions_count_timing_but_not_duplicate_quality_denominator(self):
        report = self.report(repeats=3)
        report["runs"][2]["hypothesis"] = "другая расшифровка"
        result = scorer.score_engine(self.manifest, report, self.digest)
        self.assertEqual(result["iterations"], 3)
        self.assertEqual(result["quality"]["reference_tokens"], 10)
        self.assertEqual(result["quality"]["wer"], 0)
        self.assertEqual(result["quality"]["repeatedClipsWithDifferentHypotheses"], 1)
        self.assertEqual(result["timing"]["all"]["calls"], 6)
        self.assertEqual(result["timing"]["all"]["audioSeconds"], 30)
        self.assertAlmostEqual(result["timing"]["all"]["rtf"], 0.1)

    def test_numbers_are_not_silently_made_semantically_equivalent(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["clips"][0]["reference"] = "два человека"
        report = self.report(hypotheses=["2 человека", self.manifest["clips"][1]["reference"]])
        report["runs"][0]["reference"] = "два человека"
        result = scorer.score_engine(manifest, report, self.digest)
        self.assertEqual(result["quality"]["substitutions"], 1)

    def test_paired_reports_compare_same_revision_and_exact_manifest(self):
        result = scorer.compare(self.manifest, self.report(), self.report("gigaam", hypotheses=[
            "еж", self.manifest["clips"][1]["reference"]]), self.digest)
        self.assertAlmostEqual(result["qwenMinusGigaam"]["werPercentagePoints"], -10)
        self.assertEqual(result["dataset"]["license"], "CC-BY-4.0")
        self.assertEqual(result["manifestSHA256"], self.digest)

    def test_wrong_provenance_and_incomplete_reports_fail(self):
        mutations = [
            lambda r: r.update(status="failed"),
            lambda r: r.update(manifestSHA256="e" * 64),
            lambda r: r.update(revision="main"),
            lambda r: r["runs"][0].update(audioSHA256="e" * 64),
            lambda r: r["runs"][0].update(reference="unverified replacement"),
            lambda r: r["runs"][0].update(durationSeconds=2.1),
            lambda r: r["runs"].pop(),
            lambda r: r["runs"].append(copy.deepcopy(r["runs"][0])),
            lambda r: r["runs"][0].update(clipID="unknown"),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                report = self.report()
                mutate(report)
                with self.assertRaises(ValueError):
                    scorer.score_engine(self.manifest, report, self.digest)

    def test_invalid_numeric_fields_and_missing_runs_fail(self):
        for value in [float("nan"), float("inf"), -1, True, None]:
            with self.subTest(value=value):
                report = self.report()
                report["runs"][0]["wallSeconds"] = value
                with self.assertRaises(ValueError):
                    scorer.score_engine(self.manifest, report, self.digest)
        report = self.report()
        report["footprint"]["peakBytes"] = float("nan")
        with self.assertRaises(ValueError):
            scorer.score_engine(self.manifest, report, self.digest)
        for runs in [[], None, {}, "missing"]:
            report = self.report()
            report["runs"] = runs
            with self.assertRaises(ValueError):
                scorer.score_engine(self.manifest, report, self.digest)

    def test_invalid_or_unequal_repetitions_fail(self):
        mutations = [lambda r: r["runs"][0].update(iteration=1),
                     lambda r: r["runs"][0].update(iteration=True),
                     lambda r: r["runs"][0].update(iteration=3),
                     lambda r: r["runs"][0].update(phase="cold")]
        for mutate in mutations:
            report = self.report()
            mutate(report)
            with self.assertRaises(ValueError):
                scorer.score_engine(self.manifest, report, self.digest)
        report = self.report(repeats=2)
        report["runs"].pop()
        with self.assertRaises(ValueError):
            scorer.score_engine(self.manifest, report, self.digest)
        with self.assertRaises(ValueError):
            scorer.compare(self.manifest, self.report(repeats=2), self.report("gigaam"), self.digest)

    def test_manifest_does_not_accept_unsafe_paths_duplicate_ids_or_empty_references(self):
        for path in ["/tmp/audio.wav", "../audio.wav", "a/../audio.wav", "a//b.wav", "./audio.wav",
                     "~a.wav", "a\\audio.wav", "a\x00.wav"]:
            manifest = copy.deepcopy(self.manifest)
            manifest["clips"][0]["path"] = path
            with self.assertRaises(ValueError):
                scorer.manifest_clips(manifest)
        for field, value in [("reference", "!?"), ("audioSHA256", "invalid"), ("durationSeconds", True)]:
            manifest = copy.deepcopy(self.manifest)
            manifest["clips"][0][field] = value
            with self.assertRaises(ValueError):
                scorer.manifest_clips(manifest)
        manifest = copy.deepcopy(self.manifest)
        manifest["clips"].append(copy.deepcopy(manifest["clips"][0]))
        with self.assertRaises(ValueError):
            scorer.manifest_clips(manifest)

    def test_swapped_engines_and_different_tested_revision_fail(self):
        with self.assertRaises(ValueError):
            scorer.compare(self.manifest, self.report("gigaam"), self.report(), self.digest)
        other = self.report("gigaam")
        other["revision"] = "e" * 40
        with self.assertRaises(ValueError):
            scorer.compare(self.manifest, self.report(), other, self.digest)

    def test_json_loader_rejects_duplicate_keys_and_nonfinite_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.json"
            for raw in ['{"schemaVersion":1,"schemaVersion":1}', '{"value":NaN}', '{"value":Infinity}', '[]']:
                path.write_text(raw)
                with self.assertRaises(ValueError):
                    scorer.read_json(path)
            path.write_text('{"value":1}')
            loaded, digest = scorer.read_json(path)
            self.assertEqual(loaded, {"value": 1})
            self.assertEqual(digest, hashlib.sha256(path.read_bytes()).hexdigest())

    def test_cli_produces_actual_paired_artifact_and_leaves_failure_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest_path, qwen_path, gigaam_path, output = [root / name for name in [
                "manifest.json", "qwen.json", "gigaam.json", "comparison.json"]]
            manifest_path.write_text(json.dumps(self.manifest))
            digest = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
            for path, engine in [(qwen_path, "qwen"), (gigaam_path, "gigaam")]:
                report = self.report(engine)
                report["manifestSHA256"] = digest
                path.write_text(json.dumps(report))
            arguments = ["--manifest", str(manifest_path), "--qwen", str(qwen_path),
                         "--gigaam", str(gigaam_path), "--output", str(output)]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(scorer.main(arguments), 0)
            self.assertEqual(json.loads(output.read_text())["engines"]["qwen"]["quality"]["wer"], 0)
            output.unlink()
            qwen_path.write_text('{"status":"failed"}')
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(scorer.main(arguments), 2)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
