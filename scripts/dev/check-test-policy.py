#!/usr/bin/env python3
"""Keep test exceptions honest: quarantine entries expire, and every skip names a reason and a layer.

A red result must stay meaningful, so nothing may be silently ignored for long.
"""

import argparse
from datetime import date, timedelta
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]
QUARANTINE = ROOT / "Tests/quarantine.json"
SKIPS = ROOT / "Tests/skip-registry.json"
LAYERS = frozenset({"L1-visual", "L2-needs-runner", "L3-real-model", "L4-hardware-or-manual", "L4-signed-release",
                    "manual-private-data", "diagnostic-tool", "disabled-downstream"})
LONGEST_QUARANTINE = timedelta(days=90)
TEST_ID = re.compile(r"(?:probe:[a-z0-9_-]+|[A-Za-z0-9_]+/[A-Za-z0-9_]+/[A-Za-z0-9_]+(?:\(\))?)")
SKIP_ID = re.compile(r"[A-Za-z0-9_]+/[A-Za-z0-9_]+/[A-Za-z0-9_]+(?:\(\))?")
RESULT_STATUSES = frozenset({"Passed", "Failed", "Skipped", "Expected Failure"})


def canonical(test):
    """The same test is written with or without trailing parentheses, so compare without them."""
    return test.removesuffix("()")


def quarantine_problems(value, today):
    problems = []
    if value.get("version") != 1 or not isinstance(value.get("entries"), list):
        return ["Quarantine must have version 1 and a list of entries"]
    seen = set()
    for entry in value["entries"]:
        test = entry.get("test") if isinstance(entry, dict) else None
        if not isinstance(test, str) or not TEST_ID.fullmatch(test):
            problems.append(f"Quarantine entry has an invalid test: {entry!r}")
            continue
        if test in seen:
            problems.append(f"{test}: duplicate quarantine entry")
        seen.add(test)
        for field in ("owner", "reason"):
            if not isinstance(entry.get(field), str) or not entry[field].strip():
                problems.append(f"{test}: missing {field}")
        try:
            expires = date.fromisoformat(entry.get("expires", ""))
        except (TypeError, ValueError):
            problems.append(f"{test}: expires must be YYYY-MM-DD")
            continue
        if expires < today:
            problems.append(f"{test}: quarantine expired on {expires}. Fix the test or renew it with a reason")
        elif expires > today + LONGEST_QUARANTINE:
            problems.append(f"{test}: expires more than {LONGEST_QUARANTINE.days} days from now")
    return problems


def registry_problems(value):
    problems = []
    if value.get("version") != 1 or not isinstance(value.get("tests"), dict):
        return ["Skip registry must have version 1 and a tests object"]
    seen = {}
    for test, entry in value["tests"].items():
        if not SKIP_ID.fullmatch(test):
            problems.append(f"Skip registry has an invalid test id: {test}")
            continue
        if canonical(test) in seen:
            problems.append(f"{test}: duplicate of {seen[canonical(test)]} in the skip registry")
        seen.setdefault(canonical(test), test)
        if not isinstance(entry, dict) or entry.get("layer") not in LAYERS:
            problems.append(f"{test}: skip needs a known layer")
        elif not isinstance(entry.get("reason"), str) or not entry["reason"].strip():
            problems.append(f"{test}: skip needs a reason")
    return problems


def result_problems(results, registry, complete=False):
    """Compare a finished run with the registry. Only a complete run can show that a registered test is gone."""
    known = {canonical(test) for test in registry["tests"]}
    ran = {canonical(test) for test in results}
    problems = [f"{test}: unknown result status {result!r}"
                for test, result in sorted(results.items()) if result not in RESULT_STATUSES]
    problems += [f"{test}: skipped without a reason and layer in Tests/skip-registry.json"
                 for test, result in sorted(results.items()) if result == "Skipped" and canonical(test) not in known]
    if complete:
        bundles = {test.split("/", 1)[0] for test in ran}
        problems += [f"{test}: registered as skipped, but the run has no such test"
                     for test in sorted(registry["tests"])
                     if test.split("/", 1)[0] in bundles and canonical(test) not in ran]
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--results", type=Path, help="JSON map of test id to result from a finished run")
    parser.add_argument("--complete", action="store_true",
                        help="every bundle present in --results ran completely, so missing registered tests are errors")
    arguments = parser.parse_args()
    if arguments.complete and not arguments.results:
        parser.error("--complete needs --results")
    registry = json.loads(SKIPS.read_text())
    problems = quarantine_problems(json.loads(QUARANTINE.read_text()), date.today()) + registry_problems(registry)
    if arguments.results:
        problems += result_problems(json.loads(arguments.results.read_text()), registry, arguments.complete)
    for problem in problems:
        print(problem, file=sys.stderr)
    if problems:
        return 1
    print("Test policy passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
