#!/usr/bin/env python3
"""Report SwiftLint violations only on lines this change added or edited.

The repository carries a large inherited baseline, so linting whole files would
always fail and teach people to ignore the result. Only crash-prone rules in
Sources/ block a change. Everything else is printed as a note. That includes
Vendor/: it stays linted so a local patch is visible, but imported code keeps
its own style and never blocks.
"""

import argparse
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import unicodedata

HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
BLOCKING_RULES = frozenset({"force_cast", "force_try", "force_unwrapping"})
NO_LINTABLE_FILES = "No lintable files found"


def changed_lines(diff):
    """Map each file in a zero-context unified diff to its added line numbers."""
    lines = {}
    current = None
    in_header = False
    # Only a newline ends a diff line. Source text may hold other line separators.
    for line in diff.split("\n"):
        if line.startswith("diff --git "):
            current = None
            in_header = True
        elif in_header and line.startswith("+++ "):
            # Git ends the path with a tab when it holds spaces. It quotes unusual paths.
            path = line[4:].split("\t", 1)[0]
            if path == "/dev/null":
                continue
            if not path.startswith("b/"):
                raise ValueError(f"Unreadable path in the diff: {line}")
            current = path[2:]
            lines.setdefault(current, set())
        else:
            match = HUNK.match(line)
            if match:
                in_header = False
                if current is not None:
                    start, count = int(match.group(1)), int(match.group(2) or 1)
                    lines[current].update(range(start, start + count))
    return {path: numbers for path, numbers in lines.items() if numbers}


def normalized(path):
    return unicodedata.normalize("NFC", path)


def violations_on_changed_lines(report, changed, root):
    root = str(root).rstrip("/") + "/"
    known = {normalized(path): numbers for path, numbers in changed.items()}
    found = []
    for violation in report:
        path = normalized(violation.get("file") or "")
        relative = path[len(root):] if path.startswith(root) else path
        if relative not in known:
            raise ValueError(f"SwiftLint reported a file outside the diff: {path}")
        if violation.get("line") in known[relative]:
            found.append({**violation, "file": relative})
    return sorted(found, key=lambda item: (item["file"], item["line"], item.get("rule_id", "")))


def blocks_change(violation):
    return violation.get("rule_id") in BLOCKING_RULES and violation["file"].startswith("Sources/")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", default="origin/main", help="Compare against the merge base with this ref")
    parser.add_argument("--swiftlint", default="swiftlint", help="SwiftLint command, split like a shell would")
    arguments = parser.parse_args()
    root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
    base = subprocess.check_output(["git", "merge-base", arguments.base, "HEAD"], cwd=root, text=True).strip()
    # SwiftLint reads the working tree, so line numbers must come from it too.
    diff = subprocess.check_output(
        ["git", "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--src-prefix=a/", "--dst-prefix=b/",
         "--unified=0", "--diff-filter=ACMR", base, "--", "*.swift"],
        cwd=root, encoding="utf-8", errors="replace")
    try:
        changed = changed_lines(diff)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    if not changed:
        print("SwiftLint: no changed Swift lines.")
        return 0
    command = shlex.split(arguments.swiftlint) + [
        "lint", "--strict", "--quiet", "--force-exclude", "--config", ".swiftlint.yml", "--reporter", "json", *sorted(changed)]
    result = subprocess.run(command, cwd=root, capture_output=True, text=True)
    if NO_LINTABLE_FILES in result.stderr + result.stdout:
        print("SwiftLint: the configuration excludes every changed Swift file.")
        return 0
    if result.returncode not in (0, 2):
        print(result.stderr, file=sys.stderr)
        return result.returncode or 1
    try:
        found = violations_on_changed_lines(json.loads(result.stdout or "[]"), changed, root)
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    blocking = [item for item in found if blocks_change(item)]
    for item in found:
        label = "error" if blocks_change(item) else "note"
        print(f"{item['file']}:{item['line']}: {label}: {item['rule_id']}: {item['reason']}")
    print(f"SwiftLint: {len(blocking)} blocking, {len(found) - len(blocking)} notes on {sum(map(len, changed.values()))} changed line(s).")
    return 1 if blocking else 0


if __name__ == "__main__":
    sys.exit(main())
