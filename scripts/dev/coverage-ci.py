#!/usr/bin/env python3
"""Produce revision-bound compiler coverage and join required CI results."""
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import unittest
import uuid
import xml.etree.ElementTree as ET


PACKAGES = ("NativeTextInference", "PichiGigaAM", "RussianMorphology", "TranscribeCpp")
SCOPES = ("macos", "ios", "packages", "python")


def command(argv, *, log=None, tolerate=False, cwd=None):
    with contextlib.ExitStack() as stack:
        output = stack.enter_context(Path(log).open("w")) if log else subprocess.PIPE
        result = subprocess.run([str(x) for x in argv], cwd=cwd, text=True,
                                stdout=output, stderr=subprocess.STDOUT)
    if result.returncode and not tolerate:
        raise RuntimeError(f"{argv[0]} exited {result.returncode}; see {log or result.stdout}")
    return result


def read(path):
    return json.loads(Path(path).read_text())


def save(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def git(root, *args):
    return command(["git", *args], cwd=root).stdout.strip()


def production(path):
    parts = Path(path).parts
    return (not any(p.lower() in ("tests", ".build", ".git") for p in parts)
            and not Path(path).name.startswith("test_")
            and path.endswith((".swift", ".c", ".cc", ".cpp", ".m", ".mm", ".h", ".hpp", ".py")))


def source_path(root, path):
    try:
        path = Path(path)
        path = path if path.is_absolute() else Path(root) / path
        name = str(path.resolve().relative_to(Path(root).resolve()))
    except ValueError:
        return None
    return name if production(name) else None


def join_files(destination, incoming):
    for path, row in incoming.items():
        target = destination.setdefault(path, {"executable_lines": [], "covered_lines": []})
        for key in target:
            target[key] = sorted(set(target[key]) | set(row[key]))


def xccov_files(archive, root):
    files = {}
    for name, records in archive.items():
        path = source_path(root, name)
        if path is None:
            continue
        executable, covered = set(), set()
        for row in records:
            line = row["line"]
            if type(line) is not int or line < 1 or type(row["isExecutable"]) is not bool:
                raise ValueError("Invalid compiler coverage line")
            if row["isExecutable"]:
                hits = row["executionCount"]
                if type(hits) is not int or hits < 0:
                    raise ValueError("Invalid compiler execution count")
                executable.add(line)
                if hits:
                    covered.add(line)
        files[path] = {"executable_lines": sorted(executable), "covered_lines": sorted(covered)}
    return files


def lcov_files(text, root):
    files, path = {}, None
    for line in text.splitlines():
        if line.startswith("SF:"):
            path = source_path(root, line[3:])
            if path:
                files.setdefault(path, {"executable_lines": [], "covered_lines": []})
        elif line.startswith("DA:") and path:
            number, hits, *_ = line[3:].split(",")
            number, hits = int(number), int(hits)
            if number < 1 or hits < 0:
                raise ValueError("Invalid LCOV line")
            files[path]["executable_lines"].append(number)
            if hits:
                files[path]["covered_lines"].append(number)
    for row in files.values():
        for key in row:
            row[key] = sorted(set(row[key]))
    return files


def test_counts(summary):
    values = [summary[k] for k in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures")]
    if any(type(x) is not int or x < 0 for x in values) or values[0] != sum(values[1:]):
        raise ValueError("Invalid test accounting")
    return {"passed": values[1], "failed": values[2] + values[4], "skipped": values[3]}


def require_test_class(tree, name):
    def visit(node):
        if isinstance(node, dict):
            if node.get("nodeType") == "Test Case" and node.get("nodeIdentifier", "").startswith(name + "/"):
                yield node["result"]
            for child in node.values():
                yield from visit(child)
        elif isinstance(node, list):
            for child in node:
                yield from visit(child)
    results = list(visit(tree))
    if not results or any(value != "Passed" for value in results):
        raise ValueError(f"Required CI UI class did not pass: {name}")


def report(root, scope, output, files, tests, source_sha):
    if git(root, "rev-parse", "HEAD") != source_sha or git(root, "diff", "--name-only", "HEAD"):
        raise ValueError("Source changed during coverage production")
    if not files or not any(row["executable_lines"] for row in files.values()):
        raise ValueError("Missing executable coverage")
    value = {"schema_version": 1, "source_sha": source_sha, "scope": scope, "tests": tests, "files": files}
    save(Path(output) / (scope + ".json"), value)
    return 0 if tests["passed"] > 0 and tests["failed"] == 0 else 1


def plan(root, output, force_all=False):
    event_path = os.environ.get("GITHUB_EVENT_PATH")
    event = read(event_path) if event_path else {}
    head = git(root, "rev-parse", "HEAD")
    if "pull_request" in event:
        base = event["pull_request"]["base"]["sha"]
    elif os.environ.get("GITHUB_REF") == "refs/heads/main" and event.get("before", "0" * 40) != "0" * 40:
        base = event["before"]
    else:
        base = git(root, "merge-base", "origin/main", head)
    value = json.loads(command([sys.executable, "-S", "scripts/dev/coverage-gate.py", "--classify", "--base", base, "--head", head], cwd=root).stdout)
    value["run_scopes"] = list(SCOPES) if force_all else value["required_scopes"]
    save(output, value)
    compact = {key: value[key] for key in ("base_sha", "source_sha", "run_scopes")}
    print("plan=" + json.dumps(compact, separators=(",", ":")))
    for key, item in {"base": base, "head": head, **{s: str(s in value["run_scopes"]).lower() for s in SCOPES}}.items():
        print(f"{key}={item}")
    return 0


def finish(root, plan_path, reports, needs, output):
    value = read(plan_path) if plan_path else json.loads(os.environ["PICHI_COVERAGE_PLAN"])
    states = read(needs) if needs else json.loads(os.environ["PICHI_COVERAGE_NEEDS"])
    required = ["plan", "portable", *value["run_scopes"]]
    failed = [key for key in required if states.get(key, {}).get("result") != "success"]
    if failed:
        save(output, {"result": "failed", "reason": "Missing or failed producer", "jobs": failed})
        return 1
    return command([sys.executable, "-S", "scripts/dev/coverage-gate.py", "--base", value["base_sha"],
                    "--head", value["source_sha"], "--reports-dir", reports, "--output", output], cwd=root, tolerate=True).returncode


def configure_run(root, products, scheme):
    paths = list(products.glob(scheme + "_*.xctestrun"))
    if len(paths) != 1:
        raise ValueError("Expected one current test specification")
    value = plistlib.loads(paths[0].read_bytes())
    spec = importlib.util.spec_from_file_location("coverage_regression", root / "scripts/dev/macos-regression.py")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    helper.configure_targets(value, os.environ)
    temp = command(["getconf", "DARWIN_USER_TEMP_DIR"]).stdout.strip()
    apps = set()
    def visit(node):
        if isinstance(node, dict):
            if "TestBundlePath" in node:
                env = node.setdefault("EnvironmentVariables", {})
                env["FLUID_EXPORT_TEST_SANDBOX_TEMP"] = temp
                if "MobileIntegrationTests" in node["TestBundlePath"]:
                    env["PICHI_MOBILE_HOSTED_FIXTURE"] = "1"
                host = node.get("UITargetAppPath") or node.get("TestHostPath", "")
                if ".app" in host:
                    apps.add(Path(host.split(".app", 1)[0] + ".app").name)
            for child in node.values():
                visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)
    visit(value)
    path = products / "coverage.xctestrun"
    path.write_bytes(plistlib.dumps(value))
    return path, apps


def native(root, output, scope, ui_class):
    source = git(root, "rev-parse", "HEAD")
    work = Path(output) / scope
    work.mkdir(parents=True, exist_ok=True)
    scheme = "Fluid" if scope == "macos" else "PichiVoiceMobile"
    destination = "platform=macOS,arch=arm64" if scope == "macos" else "generic/platform=iOS Simulator"
    signing = ["CODE_SIGN_IDENTITY=", "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO"] if scope == "macos" else ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_ALLOWED=YES", "CODE_SIGNING_REQUIRED=NO"]
    command(["xcodebuild", "-project", "Fluid.xcodeproj", "-scheme", scheme, "-configuration", "Debug", "-destination", destination,
             "-derivedDataPath", work / "DerivedData", "-clonedSourcePackagesDirPath", work / "SourcePackages", "-jobs", "2",
             "-enableCodeCoverage", "YES", "ENABLE_CODE_COVERAGE=YES", *signing, "build-for-testing"], log=work / "build.log", cwd=root)
    specification, apps = configure_run(root, work / "DerivedData/Build/Products", scheme)
    files, totals, failed = {}, {"passed": 0, "failed": 0, "skipped": 0}, False
    devices = [None] if scope == "macos" else ["iPhone 17", "iPad (A16)"]
    for index, kind in enumerate(devices):
        udid = None
        try:
            if kind:
                inventory = json.loads(command(["xcrun", "simctl", "list", "--json"]).stdout)
                device = next(x["identifier"] for x in inventory["devicetypes"] if x["name"] == kind)
                runtime = next(x["identifier"] for x in inventory["runtimes"] if x["name"] == "iOS 27.0" and x["isAvailable"])
                udid = command(["xcrun", "simctl", "create", "coverage-" + uuid.uuid4().hex[:8], device, runtime]).stdout.strip()
                save(work / f"device-{index}.json", {"udid": udid, "type": device, "runtime": runtime})
                destination = "platform=iOS Simulator,id=" + udid
            bundle = work / f"tests-{index}.xcresult"
            selections = (["-skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture"] if scope == "macos" else
                          ["-only-testing:PichiVoiceMobileIntegrationTests", "-only-testing:PichiVoiceMobileUITests/" + ui_class])
            result = command(["xcodebuild", "-xctestrun", specification, "-destination", destination, "-enableCodeCoverage", "YES",
                              "-parallel-testing-enabled", "NO", "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", "120",
                              "-maximum-test-execution-time-allowance", "180", "-resultBundlePath", bundle, *selections, "test-without-building"],
                             log=work / f"tests-{index}.log", cwd=root, tolerate=True)
            summary = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle, "--compact"]).stdout)
            save(work / f"summary-{index}.json", summary)
            counts = test_counts(summary)
            for key in totals:
                totals[key] += counts[key]
            failed |= result.returncode != 0 or summary["result"] != "Passed"
            raw_report = json.loads(command(["xcrun", "xccov", "view", "--report", "--json", bundle]).stdout)
            if not apps or any(not any(t["name"] == app and t["executableLines"] > 0 for t in raw_report["targets"]) for app in apps):
                raise ValueError("App coverage is disabled or missing")
            archive = json.loads(command(["xcrun", "xccov", "view", "--archive", "--json", bundle]).stdout)
            join_files(files, xccov_files(archive, root))
            if scope == "ios":
                tree = json.loads(command(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", bundle, "--compact"]).stdout)
                require_test_class(tree, ui_class)
                command(["xcrun", "xcresulttool", "export", "attachments", "--path", bundle, "--output-path", work / f"screenshots-{index}", "--filter", "*.png"])
        finally:
            if udid:
                command(["xcrun", "simctl", "shutdown", udid], tolerate=True)
                command(["xcrun", "simctl", "delete", udid])
    status = report(root, scope, output, files, totals, source)
    return 1 if failed else status


def swift_counts(text, xml=None):
    matches = re.findall(r"Test Suite 'All tests' (?:passed|failed)[^\n]*\n\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", text)
    counts = {"passed": 0, "failed": 0, "skipped": 0}
    for total, skipped, failed in matches:
        total, skipped, failed = int(total), int(skipped or 0), int(failed)
        if skipped + failed > total:
            raise ValueError("Invalid package test accounting")
        counts["passed"] += total - skipped - failed
        counts["skipped"] += skipped
        counts["failed"] += failed
    if xml is not None and Path(xml).exists():
        tree = ET.parse(xml).getroot()
        cases = list(tree.iter("testcase"))
        declared = sum(int(x.attrib.get("tests", 0)) for x in tree.iter("testsuite"))
        if declared != len(cases):
            raise ValueError("Invalid Swift Testing accounting")
        for case in cases:
            failed = case.find("failure") is not None or case.find("error") is not None
            skipped = case.find("skipped") is not None
            counts["failed" if failed else "skipped" if skipped else "passed"] += 1
    if not matches and not sum(counts.values()):
        raise ValueError("Missing package test accounting")
    return counts


def packages(root, output):
    source = git(root, "rev-parse", "HEAD")
    work = Path(output) / "packages"
    work.mkdir(parents=True, exist_ok=True)
    files, counts, failed = {}, {"passed": 0, "failed": 0, "skipped": 0}, False
    for name in PACKAGES:
        scratch, log = work / name, work / (name + ".log")
        result = command(["swift", "test", "--package-path", root / "Vendor" / name, "--scratch-path", scratch, "--jobs", "2",
                          "--enable-code-coverage", "--xunit-output", work / (name + ".xml")], log=log, cwd=root, tolerate=True)
        failed |= result.returncode != 0
        for key, value in swift_counts(log.read_text(), work / (name + "-swift-testing.xml")).items():
            counts[key] += value
        raw = list(scratch.rglob("*.profraw"))
        objects = []
        for description in scratch.glob("*/debug/description.json"):
            objects.extend(Path(x["binaryPath"]) for x in read(description)["builtTestProducts"])
        # Swift Build uses out/Products/Debug; native SwiftPM uses triple/debug.
        objects.extend(scratch.glob("**/*.xctest/Contents/MacOS/*"))
        objects = list(dict.fromkeys(p.resolve() for p in objects if p.is_file()))
        if not raw or not objects:
            raise ValueError("Missing package profiles or test objects")
        profile = work / (name + ".profdata")
        command(["xcrun", "llvm-profdata", "merge", "-sparse", *raw, "-o", profile])
        args = ["xcrun", "llvm-cov", "export", "-format=lcov", "-instr-profile=" + str(profile)]
        for index, obj in enumerate(objects):
            args.extend((["-object"] if index else []) + [obj])
        data = command(args).stdout
        (work / (name + ".lcov")).write_text(data)
        join_files(files, lcov_files(data, root))
    status = report(root, "packages", output, files, counts, source)
    return 1 if failed else status


def python(root, output):
    import coverage
    source = git(root, "rev-parse", "HEAD")
    work = Path(output) / "python"
    work.mkdir(parents=True, exist_ok=True)
    tracked = git(root, "ls-files", "*.py").splitlines()
    config = work / "coveragerc"
    sources = "\n".join("    " + str(root / p) for p in ("scripts", "tools", ".codex", "Vendor"))
    config.write_text("[run]\nbranch = True\nparallel = True\npatch = subprocess\ndata_file = " + str(work / ".coverage") + "\nsource =\n" + sources + "\n")
    cov = coverage.Coverage(config_file=str(config))
    cov.start()
    suite = unittest.TestSuite()
    try:
        with (work / "tests.log").open("w") as log, contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
            for name in tracked:
                if (name.startswith(("Tests/", "tools/")) and Path(name).name.startswith("test_")) or name == "Tests/run_diarization_repeatability_tests.py":
                    spec = importlib.util.spec_from_file_location("coverage_tests_" + re.sub(r"\W", "_", name), root / name)
                    module = importlib.util.module_from_spec(spec)
                    sys.modules[spec.name] = module
                    sys.path.insert(0, str((root / name).parent))
                    try:
                        spec.loader.exec_module(module)
                        suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
                    finally:
                        sys.path.pop(0)
            result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    finally:
        cov.stop()
        cov.save()
    cov.combine(strict=False)
    cov.load()
    paths = [str(root / p) for p in tracked if production(p)]
    cov.get_data().touch_files(paths)
    cov.save()
    cov.json_report(outfile=str(work / "coverage.json"), include=paths)
    files = {}
    for name, row in read(work / "coverage.json")["files"].items():
        path = source_path(root, root / name)
        files[path] = {"executable_lines": sorted(set(row["executed_lines"]) | set(row["missing_lines"])), "covered_lines": row["executed_lines"]}
    counts = {"passed": result.testsRun - len(result.failures) - len(result.errors) - len(result.skipped) - len(result.expectedFailures) - len(result.unexpectedSuccesses),
              "failed": len(result.failures) + len(result.errors) + len(result.expectedFailures) + len(result.unexpectedSuccesses), "skipped": len(result.skipped)}
    return report(root, "python", output, files, counts, source)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("plan", "finish", "native", "packages", "python"))
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--scope", choices=("macos", "ios"), default="macos")
    parser.add_argument("--ui-class", default="MobileCISmokeUITests")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--reports-dir", type=Path)
    parser.add_argument("--needs", type=Path)
    args = parser.parse_args(argv)
    args.root, args.output = args.root.resolve(), args.output.resolve()
    try:
        if args.mode == "plan":
            return plan(args.root, args.output, args.all)
        if args.mode == "finish":
            return finish(args.root, args.plan, args.reports_dir, args.needs, args.output)
        if args.mode == "native":
            return native(args.root, args.output, args.scope, args.ui_class)
        if args.mode == "packages":
            return packages(args.root, args.output)
        return python(args.root, args.output)
    except (ValueError, RuntimeError, OSError, KeyError, StopIteration, ET.ParseError) as error:
        print(f"Coverage producer failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
