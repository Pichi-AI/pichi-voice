#!/usr/bin/env python3
"""Configure Xcode test hosts and account for actual xcresult summary counts."""

import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def configure_targets(value, environment):
    """Handle format-1 targets and nested format-2 TestConfigurations/TestTargets."""
    overrides = {
        key: item for key, item in environment.items()
        if key.startswith(("PICHI_", "FLUIDVOICE_", "FLUIDAUDIO_", "FV_", "TEST_"))
        or key in ("CI", "GITHUB_ACTIONS")
    }
    overrides["FLUIDVOICE_MIC_PHASE1"] = "disabled"
    overrides["PICHI_INTERFACE_LANGUAGE"] = environment.get("PICHI_INTERFACE_LANGUAGE", "en")

    def visit(node):
        count = 0
        if isinstance(node, dict):
            if "TestBundlePath" in node:
                for key in ("EnvironmentVariables", "TestingEnvironmentVariables", "UITargetAppEnvironmentVariables"):
                    if key == "EnvironmentVariables" or key in node:
                        variables = node.setdefault(key, {})
                        if not isinstance(variables, dict):
                            raise ValueError(f"Invalid {key} in test target")
                        variables.update(overrides)
                count = 1
            for child in node.values():
                count += visit(child)
        elif isinstance(node, list):
            count = sum(visit(child) for child in node)
        return count

    count = visit(value)
    if not count:
        raise ValueError("No test targets found in xctestrun")
    return count


def configure(products, marker, run_id):
    # A fresh build must have emitted this scheme's spec. Never select an older run.
    candidates = [path for path in products.glob("Fluid_*.xctestrun")
                  if path.stat().st_mtime_ns >= marker.stat().st_mtime_ns]
    if len(candidates) != 1:
        raise ValueError(f"Expected one fresh Fluid xctestrun, found {len(candidates)}")
    value = plistlib.loads(candidates[0].read_bytes())
    count = configure_targets(value, os.environ)
    # __TESTROOT__ is relative to the plist, so keep the configured spec beside products.
    destination = products / f"regression-{run_id}.xctestrun"
    destination.write_bytes(plistlib.dumps(value))
    print(f"Configured {count} test target(s).", file=sys.stderr)
    print(destination)


# Tests name disposable UserDefaults suites <word><separator><UUID>, a bare UUID, or one of these dotted
# prefixes. Other dotted names stay, because real apps use them too (com.vendor.app.Flags.<UUID>).
DISPOSABLE_PREFERENCES = re.compile(
    r"(?:(?:[A-Za-z][A-Za-z0-9_-]*|ai\.pichi\.fluidserve-fixture|account\.synthetic|synthetic\.[a-z-]+)[.-])?"
    r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}(?:-[AB])?\.plist")
# This run's xcodebuild has exited by the sweep, so a live one belongs to someone else.
TEST_PROCESSES = frozenset({"xcodebuild", "xctest", "Pichi Voice Debug"})
STANDALONE_MARKERS = ("standalone-regression.py", "Tests/run_", "scripts/dev/test-")


def remember_preferences(directory, snapshot):
    names = sorted(path.name for path in directory.glob("*.plist") if DISPOSABLE_PREFERENCES.fullmatch(path.name))
    partial = snapshot.with_name(snapshot.name + ".next")
    partial.write_text("\n".join(names))
    os.replace(partial, snapshot)


def live_test_processes():
    names = subprocess.check_output(["ps", "-axo", "comm="], text=True).splitlines()
    alive = {name.rsplit("/", 1)[-1] for name in names} & TEST_PROCESSES
    # Probes run as interpreters and short-lived binaries, so only their script paths are stable.
    commands = subprocess.check_output(["ps", "-axo", "command="], text=True)
    if any(marker in commands for marker in STANDALONE_MARKERS):
        alive.add("standalone probes")
    return sorted(alive)


def sweep_preferences(directory, snapshot):
    """Remove disposable suites that appeared during this run, unless another test run could own them."""
    alive = live_test_processes()
    if alive:
        print(f"Warning: kept this run's disposable preference domains while {', '.join(alive)} running.",
              file=sys.stderr)
        return
    known = set(snapshot.read_text().split("\n"))
    removed = 0
    for path in directory.glob("*.plist"):
        if path.name in known or not DISPOSABLE_PREFERENCES.fullmatch(path.name):
            continue
        if path.is_symlink() or not path.is_file():
            continue
        path.unlink(missing_ok=True)
        removed += 1
    print(f"Removed {removed} disposable preference domains left by this run.")


def summarize(value, test_status):
    if not isinstance(value, dict):
        raise ValueError("xcresult summary must be an object")
    keys = ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")
    counts = []
    for key in keys:
        count = value.get(key)
        if type(count) is not int or count < 0:
            raise ValueError(f"Missing or invalid xcresult count: {key}")
        counts.append(count)
    total, passed, failed, skipped, expected = counts
    if total != passed + failed + skipped + expected:
        raise ValueError("xcresult test counts do not reconcile")
    result = value.get("result")
    if result not in ("Passed", "Failed", "Skipped", "Expected Failure", "unknown"):
        raise ValueError("Missing or invalid xcresult result")
    print(f"Tests: {total} total, {passed} passed, {failed} failed, {skipped} skipped, {expected} expected failures.")
    print(f"xcresult: {result}; xcodebuild exit: {test_status}.")
    # An empty/entirely skipped or incomplete run cannot prove regression success.
    return 0 if test_status == 0 and result == "Passed" and failed == 0 and passed > 0 else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_subparsers(dest="action", required=True)
    config = actions.add_parser("configure")
    config.add_argument("products", type=Path)
    config.add_argument("marker", type=Path)
    config.add_argument("run_id")
    summary = actions.add_parser("summarize")
    summary.add_argument("summary", type=Path)
    summary.add_argument("test_status", type=int)
    for name in ("remember-preferences", "sweep-preferences"):
        preferences = actions.add_parser(name)
        preferences.add_argument("directory", type=Path)
        preferences.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "configure":
            configure(args.products, args.marker, args.run_id)
            return 0
        if args.action == "remember-preferences":
            remember_preferences(args.directory, args.snapshot)
            return 0
        if args.action == "sweep-preferences":
            sweep_preferences(args.directory, args.snapshot)
            return 0
        return summarize(json.loads(args.summary.read_text()), args.test_status)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        print(f"Regression report error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
