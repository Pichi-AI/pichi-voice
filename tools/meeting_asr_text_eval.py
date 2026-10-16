#!/usr/bin/env python3
"""Offline weak-reference text disagreement. Never interprets Fathom as gold.

Only complete reference utterances inside a predeclared clip-edge guard are scored.
Consecutive eligible utterances are concatenated before alignment, because their
whole-second boundaries are not word alignments. Actual ASR units are selected by
midpoint in those complete intervals. No reference text is cut or force aligned.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import json
import math
from pathlib import Path
import unicodedata

METRIC_VERSION = "complete-utterance-runs-weak-text-v1"
GUARDS = (0.0, 1.0, 2.0)
NORMALIZATION = {
    "unicode": "NFKC then casefold", "russian": "yo folds to ye (ё to е)",
    "token_boundaries": "all characters except Unicode letters, combining marks in an existing token, and decimal digits",
    "numbers": "decimal digits retained; no numeric verbalization, equivalence, or transliteration",
    "cer": "Levenshtein distance on concatenated normalized tokens; spaces excluded",
    "wer": "Levenshtein distance on normalized tokens; unbounded, denominator reference tokens",
    "tie_break": "equal-cost substitution, deletion, insertion, in that order",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def normalize(text: str) -> list[str]:
    normalized = unicodedata.normalize("NFKC", text).casefold().replace("ё", "е")
    parts: list[str] = []
    current: list[str] = []
    for char in normalized:
        category = unicodedata.category(char)
        if category.startswith("L") or category == "Nd" or (category.startswith("M") and current):
            current.append(char)
        elif current:
            parts.append("".join(current)); current = []
    if current:
        parts.append("".join(current))
    return parts


def word_edits(reference: list[str], hypothesis: list[str]) -> dict:
    """Exact Wagner-Fischer counts, O(hypothesis length) memory, deterministic ties."""
    previous = [(j, 0, 0, j) for j in range(len(hypothesis) + 1)]
    for i, left in enumerate(reference, 1):
        current = [(i, 0, i, 0)]
        for j, right in enumerate(hypothesis, 1):
            if left == right:
                current.append(previous[j - 1]); continue
            diag, up, side = previous[j - 1], previous[j], current[j - 1]
            candidates = [
                (diag[0] + 1, diag[1] + 1, diag[2], diag[3]),
                (up[0] + 1, up[1], up[2] + 1, up[3]),
                (side[0] + 1, side[1], side[2], side[3] + 1),
            ]
            current.append(min(candidates, key=lambda item: item[0]))
        previous = current
    distance, substitutions, deletions, insertions = previous[-1]
    return {"distance": distance, "substitutions": substitutions, "deletions": deletions,
            "insertions": insertions, "reference_tokens": len(reference),
            "hypothesis_tokens": len(hypothesis),
            "weak_wer": distance / len(reference) if reference else None}


def char_distance(reference: str, hypothesis: str) -> int:
    """Exact bit-vector Levenshtein; arbitrary precision Python ints bound the pattern."""
    if not reference:
        return len(hypothesis)
    # Swapping preserves distance and uses the shorter string for the bit pattern.
    if len(reference) > len(hypothesis):
        reference, hypothesis = hypothesis, reference
    if not reference:
        return len(hypothesis)
    equality: dict[str, int] = {}
    for i, char in enumerate(reference):
        equality[char] = equality.get(char, 0) | (1 << i)
    positive, negative, score = ~0, 0, len(reference)
    highest = 1 << (len(reference) - 1)
    for char in hypothesis:
        equal = equality.get(char, 0)
        vertical = equal | negative
        horizontal = (((equal & positive) + positive) ^ positive) | equal
        positive_h = negative | ~(horizontal | positive)
        negative_h = positive & horizontal
        score += bool(positive_h & highest) - bool(negative_h & highest)
        positive_h = (positive_h << 1) | 1
        negative_h <<= 1
        positive = negative_h | ~(vertical | positive_h)
        negative = positive_h & vertical
    return score


def numeric(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def reference_runs(turns: list[dict], duration: float, guard: float) -> tuple[list[dict], Counter]:
    runs: list[dict] = []
    exclusions: Counter = Counter()
    prior_end = -math.inf
    prior_index = -2
    for index, turn in enumerate(turns):
        start, end = turn.get("start"), turn.get("end")
        if not numeric(start) or not numeric(end) or start < 0 or end <= start or end > duration:
            raise ValueError(f"invalid reference turn geometry at index {index}")
        if start < prior_end - 1e-6:
            raise ValueError("overlapping or unsorted reference utterances require a different text scorer")
        prior_end = end
        text = turn.get("text")
        if not isinstance(text, str):
            raise ValueError("reference turn text must be a string")
        reason = ("clip_truncated" if turn.get("clipped_start") or turn.get("clipped_end") else
                  "clip_edge_guard" if start < guard or end > duration - guard else
                  "empty_normalized_text" if not normalize(text) else None)
        if reason:
            exclusions[reason] += 1
            continue
        if runs and prior_index == index - 1 and abs(runs[-1]["end"] - start) <= 1e-6:
            runs[-1]["end"] = end
            runs[-1]["text"] += " " + text
            runs[-1]["turn_indices"].append(index)
        else:
            runs.append({"start": start, "end": end, "text": text, "turn_indices": [index]})
        prior_index = index
    return runs, exclusions


def score_clip(clip: dict, reference: dict, native: dict) -> dict:
    duration = clip["duration_seconds"]
    if not numeric(duration) or duration <= 0:
        raise ValueError("invalid clip duration")
    if native.get("clipID") != clip["clip_id"] or native.get("audioSHA256") != clip["audio_sha256"]:
        raise ValueError("native source identity mismatch")
    turns = reference["turns"]
    units = native["units"]
    valid: list[tuple[float, float, int, dict]] = []
    rejected: Counter = Counter()
    for index, unit in enumerate(units):
        start, end = unit.get("analysisStart"), unit.get("analysisEnd")
        if unit.get("precision") != "word":
            rejected["non_word_precision"] += 1
        elif not numeric(start) or not numeric(end) or start < 0 or end <= start or end > duration + 1e-6:
            rejected["invalid_geometry"] += 1
        elif not isinstance(unit.get("text"), str):
            raise ValueError("native text must be a string")
        else:
            valid.append((start, end, index, unit))
    valid.sort(key=lambda item: (item[0], item[1], item[2]))
    profiles = []
    for guard in GUARDS:
        runs, exclusions = reference_runs(turns, duration, guard)
        counters = Counter()
        window_rows = []
        eligible_native_ids: set[int] = set()
        for run in runs:
            chosen = [row for row in valid if run["start"] <= (row[0] + row[1]) / 2 < run["end"]]
            eligible_native_ids.update(row[2] for row in chosen)
            r = normalize(run["text"])
            h = normalize(" ".join(row[3]["text"] for row in chosen))
            edits = word_edits(r, h)
            rc, hc = "".join(r), "".join(h)
            chars = char_distance(rc, hc)
            for key in ("distance", "substitutions", "deletions", "insertions", "reference_tokens", "hypothesis_tokens"):
                counters[key] += edits[key]
            counters["char_distance"] += chars
            counters["reference_characters"] += len(rc)
            counters["hypothesis_characters"] += len(hc)
            counters["boundary_crossing_native_units_included"] += sum(row[0] < run["start"] or row[1] > run["end"] for row in chosen)
            window_rows.append({"start": run["start"], "end": run["end"], "turn_indices": run["turn_indices"],
                                "native_units": len(chosen), **edits, "char_distance": chars,
                                "reference_characters": len(rc), "weak_cer": chars / len(rc) if rc else None})
        reference_tokens = counters["reference_tokens"]
        reference_chars = counters["reference_characters"]
        profiles.append({"guard_seconds": guard, **dict(counters),
                         "weak_wer": counters["distance"] / reference_tokens if reference_tokens else None,
                         "weak_cer": counters["char_distance"] / reference_chars if reference_chars else None,
                         "eligible_turns": sum(len(run["turn_indices"]) for run in runs),
                         "reference_turns_total": len(turns), "excluded_turns": dict(exclusions),
                         "scored_seconds": sum(run["end"] - run["start"] for run in runs),
                         "native_units_included": len(eligible_native_ids), "native_units_total": len(units),
                         "native_units_excluded": len(units) - len(eligible_native_ids),
                         "reference_tokens_available_including_clipped_text": sum(len(normalize(t["text"])) for t in turns),
                         "windows": window_rows})
    return {"clip_id": clip["clip_id"], "split": clip["split"],
            "speaker_count_stratum": clip["speaker_count_stratum"], "language_condition": clip["language_condition"],
            "duration_seconds": duration, "native_units_rejected": dict(rejected), "profiles": profiles}


def aggregate(clips: list[dict]) -> list[dict]:
    result = []
    for guard in GUARDS:
        profiles = [next(p for p in c["profiles"] if p["guard_seconds"] == guard) for c in clips]
        sums = Counter()
        for profile in profiles:
            for key in ("distance", "substitutions", "deletions", "insertions", "reference_tokens", "hypothesis_tokens",
                        "char_distance", "reference_characters", "hypothesis_characters", "scored_seconds",
                        "eligible_turns", "reference_turns_total", "native_units_included", "native_units_total",
                        "native_units_excluded", "boundary_crossing_native_units_included",
                        "reference_tokens_available_including_clipped_text"):
                sums[key] += profile.get(key, 0)
        wers = [p["weak_wer"] for p in profiles if p["weak_wer"] is not None]
        result.append({"guard_seconds": guard, "clips": len(clips), "clips_with_defined_score": len(wers), **dict(sums),
                       "weak_wer": sums["distance"] / sums["reference_tokens"] if sums["reference_tokens"] else None,
                       "weak_cer": sums["char_distance"] / sums["reference_characters"] if sums["reference_characters"] else None,
                       "macro_weak_wer": sum(wers) / len(wers) if wers else None,
                       "total_clip_seconds": sum(c["duration_seconds"] for c in clips)})
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--split", choices=("development", "heldOut", "all"), default="development")
    parser.add_argument("--allow-held-out", action="store_true", help="Require explicit parent-authorized frozen candidate before reading held-out references")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.split != "development" and not args.allow_held_out:
        parser.error("held-out references are locked until candidate freeze authorization")
    manifest = json.loads(args.manifest.read_text())
    clips = [c for c in manifest["clips"] if args.split == "all" or c["split"] == args.split]
    scored = []
    for clip in clips:
        refpath = Path(clip["weak_reference_path"])
        if sha256(refpath) != clip["weak_reference_sha256"]:
            raise ValueError("reference hash differs from frozen manifest")
        path = args.evidence / (clip["clip_id"] + ".json")
        row = score_clip(clip, json.loads(refpath.read_text()), json.loads(path.read_text()))
        row["reference_sha256"], row["native_evidence_sha256"] = sha256(refpath), sha256(path)
        scored.append(row)
    groups = {"all": scored}
    for key in ("split", "speaker_count_stratum", "language_condition"):
        for value in sorted({str(c[key]) for c in scored}):
            groups[f"{key}:{value}"] = [c for c in scored if str(c[key]) == value]
    report = {"schema_version": 1, "metric_version": METRIC_VERSION,
              "reference_status": "automatic_weak_not_human_gold", "primary_guard_seconds": 1.0,
              "manifest_sha256": sha256(args.manifest), "scorer_sha256": sha256(Path(__file__)),
              "normalization": NORMALIZATION, "split": args.split,
              "interpretation": "Text disagreement between two ASR systems under coarse reference timing; not ASR accuracy, not gold WER/CER, independent of diarization choices.",
              "group_aggregates": {key: aggregate(rows) for key, rows in groups.items()}, "clips": scored}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"output": str(args.output), "clips": len(scored), "profiles": report["group_aggregates"]["all"]}, ensure_ascii=False))


if __name__ == "__main__":
    main()
