import importlib.util
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("text_model_eval_report", ROOT / "scripts/dev/text-model-eval-report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)


class TextModelEvaluationProtocolTests(unittest.TestCase):
    def test_corpus_has_balanced_synthetic_cases_and_unique_gates(self):
        corpus = json.loads((ROOT / "Tests/Fixtures/TextModelEvals/russian-v1.json").read_text())
        self.assertEqual(corpus["schemaVersion"], 1)
        self.assertEqual(corpus["language"], "ru")
        self.assertEqual(len(corpus["cases"]), 16)
        self.assertEqual({c["task"] for c in corpus["cases"]}, {"summary", "enhancement"})
        self.assertEqual(sum(c["task"] == "summary" for c in corpus["cases"]), 8)
        self.assertEqual(len({c["id"] for c in corpus["cases"]}), 16)
        for case in corpus["cases"]:
            self.assertTrue(case["rubric"])
            self.assertEqual(len({r["id"] for r in case["rules"]}), len(case["rules"]))
            self.assertTrue(case["rules"])
        self.assertGreaterEqual(sum(c["repeatForFinalists"] for c in corpus["cases"]), 4)

    def result(self, structural="accepted", gate=True):
        return dict(modelID="synthetic-model", caseID="fixture", task="summary", repetition=1,
                    structuralStatus=structural, checks=[dict(passed=gate)], elapsedSeconds=1.5, completionCalls=[{}])

    def review(self, critical=False):
        return dict(modelID="synthetic-model", caseID="fixture", repetition=1, criticalFailure=critical,
                    scores=dict(faithfulness=4, coverage=4, language=4, formatting=4))

    def test_valid_structure_and_gates_cannot_replace_independent_review(self):
        row = REPORT.summarize(dict(results=[self.result()]))[0]
        self.assertFalse(row["eligibleForRecommendation"])
        self.assertFalse(row["fullyReviewed"])
        self.assertIsNone(row["semanticScore"])

    def test_critical_semantic_failure_blocks_recommendation_even_with_valid_citations(self):
        row = REPORT.summarize(dict(results=[self.result()]), [self.review(critical=True)])[0]
        self.assertFalse(row["eligibleForRecommendation"])
        self.assertEqual(row["criticalFailures"], 1)

    def test_structural_rejection_is_not_a_semantic_success(self):
        row = REPORT.summarize(dict(results=[self.result(structural="rejected")]), [self.review()])[0]
        self.assertFalse(row["eligibleForRecommendation"])

    def test_partial_reviews_do_not_yield_a_completed_rank(self):
        second = self.result()
        second["repetition"] = 2
        row = REPORT.summarize(dict(results=[self.result(), second]), [self.review()])[0]
        self.assertFalse(row["eligibleForRecommendation"])
        self.assertEqual(row["independentReviewed"], 1)

    def test_duplicate_or_unknown_reviews_are_rejected(self):
        with self.assertRaises(ValueError):
            REPORT.summarize(dict(results=[self.result()]), [self.review(), self.review()])
        review = self.review()
        review["modelID"] = "unrelated"
        with self.assertRaises(ValueError):
            REPORT.summarize(dict(results=[self.result()]), [review])

    def test_a_complete_review_of_a_smoke_slice_or_failed_cleanup_cannot_recommend_a_model(self):
        report = dict(results=[self.result()], completed=True, isolationStatus="clean", finalists=[],
                      corpusCases=[dict(id="fixture", task="summary", critical=False),
                                   dict(id="missing", task="summary", critical=False)])
        self.assertFalse(REPORT.summarize(report, [self.review()])[0]["eligibleForRecommendation"])
        report["corpusCases"].pop()
        self.assertTrue(REPORT.summarize(report, [self.review()])[0]["eligibleForRecommendation"])
        report["isolationStatus"] = "cleanup-failed"
        self.assertFalse(REPORT.summarize(report, [self.review()])[0]["eligibleForRecommendation"])


if __name__ == "__main__":
    unittest.main()
