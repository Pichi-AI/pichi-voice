#!/usr/bin/env python3
"""Fail closed on uncovered changed executable source lines and incomplete reports."""
from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

SCOPES = {"macos", "ios", "packages", "python"}
STATIC = {".md", ".txt", ".json", ".toml", ".yml", ".yaml", ".png", ".jpg", ".jpeg", ".svg", ".xcstrings", ".plist", ".entitlements", ".xcconfig", ".pbxproj", ".xcscheme", ".xctestplan", ".resolved", ".zip", ".pdf", ".wav", ".m4a", ".mp3", ".lock"}
NATIVE = {".swift", ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm"}
UNSUPPORTED = {".sh", ".bash", ".zsh", ".js", ".mjs", ".ts", ".tsx", ".rs", ".go", ".rb"}


def git(root, *args):
    return subprocess.check_output(["git", "--literal-pathspecs", "-C", str(root), *args], stderr=subprocess.PIPE)


def commit(root, value):
    return git(root, "rev-parse", "--verify", "--end-of-options", value + "^{commit}").decode().strip()


def path_name(value):
    if not isinstance(value, str) or not value or any(c in value for c in "\\\r\n\t\0"):
        raise ValueError("Unsafe coverage source path")
    path = PurePosixPath(value)
    if not path.parts or path.is_absolute() or str(path) != value or ".." in path.parts:
        raise ValueError("Coverage paths must be normalized repository-relative names")
    return value


def object_without_duplicates(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("Duplicate coverage JSON key")
        value[key] = item
    return value


def load(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=object_without_duplicates)


def classify(root, base, head):
    base, head = commit(root, base), commit(root, head)
    if git(root, "merge-base", base, head).decode().strip() != base:
        raise ValueError("Coverage base must be an ancestor of the tested revision")
    try:
        shared = set(git(root, "show", head + ":Sources/Mobile/shared-sources.txt").decode().splitlines())
    except subprocess.CalledProcessError:
        shared = set()
    raw = git(root, "diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--name-status", "-z", base, head).decode().split("\0")
    files, scopes, unsupported = {}, set(), []
    index = 0
    while index < len(raw) and raw[index]:
        status, old = raw[index:index + 2]
        index += 2
        name = raw[index] if status.startswith(("R", "C")) else old
        if status.startswith(("R", "C")):
            index += 1
        path_name(name)
        suffix = PurePosixPath(name).suffix
        parts = PurePosixPath(name).parts
        test = (name.startswith("Tests/") or name.startswith("Vendor/") and len(parts) > 2 and parts[2] == "Tests"
                or name.startswith("tools/") and suffix == ".py" and PurePosixPath(name).name.startswith("test_"))
        if test:
            if name.startswith(("Tests/MobileIntegrationTests/", "Tests/MobileUITests/")):
                scopes.add("ios")
            elif suffix == ".py":
                scopes.add("python")
            elif name.startswith("Vendor/"):
                scopes.add("packages")
            elif suffix in NATIVE:
                scopes.add("macos")
            continue
        if name.startswith(".github/workflows/") or name.startswith(".codex/") and suffix != ".py":
            scopes.add("python")
            continue
        if PurePosixPath(name).name in ("Package.swift", "Package.resolved"):
            scopes.update(("macos", "ios", "packages"))
            continue
        if name == ".gitignore":
            scopes.add("python")
            continue
        if name.startswith("Fluid.xcodeproj/") or name == "Sources/Mobile/shared-sources.txt":
            scopes.update(("macos", "ios"))
            continue
        if suffix in STATIC and name.startswith(("Sources/", "Configuration/", "Vendor/", "tools/")):
            scopes.update(("macos", "ios") if name.startswith(("Sources/", "Configuration/")) else ("packages", "macos", "ios") if name.startswith("Vendor/") else ("python",))
            continue
        if suffix not in NATIVE | {".py"}:
            if status == "D":
                continue
            if suffix in UNSUPPORTED or suffix not in STATIC and PurePosixPath(name).name not in ("LICENSE", "COPYING", "NOTICE", "CODEOWNERS", ".gitkeep"):
                unsupported.append(name)
            continue
        if name in ("scripts/dev/coverage-ci.py", "scripts/dev/coverage-gate.py"):
            scopes.update(SCOPES)
        if name.startswith("Vendor/") and suffix in NATIVE:
            scopes.update(("packages", "macos"))
            if not name.startswith("Vendor/NativeTextInference/"):
                scopes.add("ios")
        elif suffix == ".py":
            scopes.add("python")
        elif name.startswith("Sources/Mobile/"):
            scopes.add("ios")
        else:
            scopes.add("macos")
            if name in shared:
                scopes.add("ios")
        if status == "D":
            continue
        content = git(root, "show", head + ":" + name)
        if b"\0" in content:
            unsupported.append(name)
            continue
        diff = git(root, "diff", "--no-ext-diff", "--no-textconv", "--find-renames", "--unified=0", base, head, "--", old, name).decode()
        added = set()
        for start, size in re.findall(r"^@@ .* \+(\d+)(?:,(\d+))? @@", diff, re.MULTILINE):
            added.update(range(int(start), int(start) + int(size or 1)))
        files[name] = sorted(added)
    return {"schema_version": 1, "base_sha": base, "source_sha": head,
            "required_scopes": sorted(scopes), "changed_files": files, "unsupported": sorted(unsupported)}


def lines(value):
    if not isinstance(value, list) or any(type(x) is not int or x < 1 for x in value):
        raise ValueError("Coverage line numbers must be positive integers")
    return set(value)


def checked_report(path, scope, source_sha, tracked):
    value = load(path)
    if not isinstance(value, dict) or type(value.get("schema_version")) is not int or value.get("schema_version") != 1 or value.get("source_sha") != source_sha or value.get("scope") != scope:
        raise ValueError("Coverage report identity does not match the tested revision/scope")
    tests = value["tests"]
    if not isinstance(tests, dict):
        raise ValueError("Invalid coverage test accounting")
    if any(type(tests.get(k)) is not int or tests[k] < 0 for k in ("passed", "failed", "skipped")):
        raise ValueError("Invalid coverage test accounting")
    if tests["failed"] or not tests["passed"]:
        raise ValueError("Required coverage tests failed or were all skipped")
    if not isinstance(value["files"], dict) or not value["files"]:
        raise ValueError("Empty coverage source inventory")
    files = {}
    for name, row in value["files"].items():
        path_name(name)
        if name not in tracked:
            raise ValueError("Coverage source is not in the tested Git tree: " + name)
        executable, covered = lines(row["executable_lines"]), lines(row["covered_lines"])
        if not covered <= executable:
            raise ValueError("Covered lines are absent from executable mapping")
        files[name] = (executable, covered)
    if not any(row[0] for row in files.values()):
        raise ValueError("No executable compiler coverage")
    return files


def evaluate(root, plan, reports):
    if plan["unsupported"]:
        raise ValueError("Unsupported executable coverage: " + ", ".join(plan["unsupported"]))
    tracked = set(git(root, "ls-tree", "-r", "--name-only", "-z", plan["source_sha"]).decode().split("\0"))
    files = {}
    for scope in plan["required_scopes"]:
        data = checked_report(Path(reports) / (scope + ".json"), scope, plan["source_sha"], tracked)
        for name, row in data.items():
            current = files.setdefault(name, (set(), set()))
            current[0].update(row[0])
            current[1].update(row[1])
    uncovered, total = {}, 0
    for name, added in plan["changed_files"].items():
        if name not in files:
            raise ValueError("Changed production source missing from coverage: " + name)
        executable, covered = files[name]
        changed = set(added) & executable
        total += len(changed)
        if changed - covered:
            uncovered[name] = sorted(changed - covered)
    return {"result": "failed" if uncovered else "passed" if plan["required_scopes"] else "not_applicable",
            "source_sha": plan["source_sha"], "base_sha": plan["base_sha"], "threshold": 100,
            "changed_executable_lines": total, "covered_changed_lines": total - sum(map(len, uncovered.values())),
            "uncovered": uncovered}


def python_scope(plan):
    return {**plan, "required_scopes": [scope for scope in plan["required_scopes"] if scope == "python"],
            "changed_files": {name: added for name, added in plan["changed_files"].items() if name.endswith(".py")}}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--classify", action="store_true")
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", required=True)
    parser.add_argument("--reports-dir", type=Path)
    parser.add_argument("--require-scope", choices=sorted(SCOPES), action="append", default=[])
    parser.add_argument("--python-only", action="store_true", help="Check Python coverage only; report native scopes as pending")
    parser.add_argument("--output", type=Path)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    args = parser.parse_args(argv)
    try:
        plan = classify(args.root, args.base, args.head)
        plan["required_scopes"] = sorted(set(plan["required_scopes"]) | set(args.require_scope))
        deferred = sorted(set(plan["required_scopes"]) - {"python"}) if args.python_only else []
        if args.python_only and set(args.require_scope) - {"python"}:
            raise ValueError("Python-only coverage cannot validate a required native scope")
        selected = python_scope(plan) if args.python_only else plan
        value = selected if args.classify else evaluate(args.root, selected, args.reports_dir)
        value.update(coverage_scope="python" if args.python_only else "all", deferred_scopes=deferred)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
        print(json.dumps(value, sort_keys=True))
        return 1 if value.get("result") == "failed" else 0
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError) as error:
        value = {"result": "failed", "reason": str(error)}
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(json.dumps(value, indent=2) + "\n")
        print(json.dumps(value), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
