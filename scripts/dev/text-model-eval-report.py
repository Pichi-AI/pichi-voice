#!/usr/bin/env python3
"""Summarize opt-in native evals without treating citation validity as truth."""
from __future__ import annotations

import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path


def summarize(report: dict, judgments: list[dict] | None = None) -> list[dict]:
    reviews = {}
    for review in judgments or []:
        key = (review["modelID"], review["caseID"], review["repetition"])
        if key in reviews:
            raise ValueError("Duplicate independent review")
        scores = review.get("scores", {})
        if set(scores) != {"faithfulness", "coverage", "language", "formatting"}:
            raise ValueError("Every reviewed case needs the four documented dimensions")
        if any(type(value) is not int or not 0 <= value <= 4 for value in scores.values()):
            raise ValueError("Review scores must be integer values from 0 through 4")
        if type(review.get("criticalFailure")) is not bool:
            raise ValueError("Critical failure must be explicitly judged")
        reviews[key] = review
    grouped = defaultdict(list)
    for result in report["results"]:
        grouped[(result["modelID"], result["task"])].append(result)
    rows = []
    used_reviews = set()
    for (model, task), results in sorted(grouped.items()):
        structural = sum(result["structuralStatus"] == "accepted" for result in results)
        gates = sum(bool(result["checks"]) and all(check["passed"] for check in result["checks"]) for result in results)
        completed_reviews = []
        for result in results:
            key = (model, result["caseID"], result["repetition"])
            if key in reviews:
                completed_reviews.append(reviews[key])
                used_reviews.add(key)
        critical = sum(review["criticalFailure"] for review in completed_reviews)
        # An automatic lexical gate can flag a legitimate paraphrase. Its outcome
        # stays visible independently of the human semantic judgment.
        reviewed = len(completed_reviews)
        means = {dimension: statistics.mean(review["scores"][dimension] for review in completed_reviews)
                 for dimension in ("faithfulness", "coverage", "language", "formatting")} if reviewed else {}
        semantic_score = (0.5 * means["faithfulness"] + 0.3 * means["coverage"] +
                          0.1 * means["language"] + 0.1 * means["formatting"]) * 25 if reviewed else None
        expected = {case["id"] for case in report.get("corpusCases", []) if case["task"] == task}
        observed = {result["caseID"] for result in results}
        model_expected = {case["id"] for case in report.get("corpusCases", [])}
        model_observed = {result["caseID"] for result in report["results"] if result["modelID"] == model}
        full_corpus = bool(expected) and observed == expected and model_expected == model_observed
        critical_ids = {case["id"] for case in report.get("corpusCases", [])
                        if case["task"] == task and case["critical"]}
        repeated = (model not in report.get("finalists", []) or
                    all(sum(result["caseID"] == case_id for result in results) >= 2 for case_id in critical_ids))
        clean_run = report.get("completed") is True and report.get("isolationStatus") == "clean"
        rows.append(dict(modelID=model, task=task, cases=len({r["caseID"] for r in results}),
                         attempts=len(results), structuralAccepted=structural, automaticGatePassed=gates,
                         independentReviewed=reviewed, criticalFailures=critical,
                         meanScores=means, semanticScore=semantic_score,
                         fullyReviewed=reviewed == len(results),
                         fullCorpus=full_corpus, finalistRepetitionsComplete=repeated, isolationClean=clean_run,
                         eligibleForRecommendation=(full_corpus and repeated and clean_run and
                                                    reviewed == len(results) and structural == len(results) and critical == 0),
                         medianSeconds=statistics.median(r["elapsedSeconds"] for r in results),
                         completionCalls=sum(len(r["completionCalls"]) for r in results)))
    if set(reviews) != used_reviews:
        raise ValueError("A review refers to an attempt outside this report")
    return rows


def render(report: dict, rows: list[dict]) -> str:
    lines = ["# Local Russian text model evaluation", "",
             f"Source commit: `{report['sourceCommit']}`",
             f"Corpus SHA256: `{report['corpusSHA256']}`",
             f"Cleanup prompt SHA256: `{report['enhancementPromptSHA256']}`", "",
             "The runner executes the production summary generator and configured cleanup request path. "
             "Automatic gates are bounded lexical and state checks. They do not establish semantic correctness. "
             "Citation acceptance proves a literal source exists; it does not prove the paraphrase follows from it.", "",
             "| Model | Task | Cases / attempts | Structure | Auto gates | Reviewed | Critical failures | Semantic score | Median seconds |",
             "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
    for row in rows:
        attempts = row["attempts"]
        score = f"{row['semanticScore']:.1f}/100" if row["fullyReviewed"] else "Pending review"
        lines.append(f"| `{row['modelID']}` | {row['task']} | {row['cases']} / {attempts} | "
                     f"{row['structuralAccepted']}/{attempts} | {row['automaticGatePassed']}/{attempts} | "
                     f"{row['independentReviewed']}/{attempts} | {row['criticalFailures']} | {score} | "
                     f"{row['medianSeconds']:.3f} |")
    lines += ["", "Ranking is provisional until every attempt is independently reviewed, all planned cases are present, "
              "critical cases are repeated for finalists, and model digests/profile and memory samples are verified. "
              "A small selected smoke run must not be presented as the full corpus. "
              "RAM and server timing require the separately collected runtime samples; elapsed request time is not model RAM.", ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--judgments", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = json.loads(args.report.read_text())
    judgments = json.loads(args.judgments.read_text()) if args.judgments else None
    args.output.write_text(render(report, summarize(report, judgments)))
    args.output.chmod(0o600)


if __name__ == "__main__":
    main()
