"""Real Git diffs and synthetic compiler reports exercise strict patch coverage."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("coverage_gate", ROOT / "scripts/dev/coverage-gate.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.run_git("init", "-q")
        self.put("README.md", "Fixture\n")
        self.base = self.commit()
        self.reports = self.root / "reports"
        self.reports.mkdir()

    def run_git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.root), *args], stderr=subprocess.PIPE).decode().strip()

    def put(self, name, text):
        p = self.root / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def commit(self):
        self.run_git("add", ".")
        self.run_git("-c", "user.name=Coverage Fixture", "-c", "user.email=coverage@example.test", "commit", "-qm", "fixture", "--allow-empty")
        return self.run_git("rev-parse", "HEAD")

    def plan(self):
        return GATE.classify(self.root, self.base, self.run_git("rev-parse", "HEAD"))

    def report(self, plan, scope="python", files=None, **overrides):
        value = dict(schema_version=1, source_sha=plan["source_sha"], scope=scope,
                     tests=dict(passed=1, failed=0, skipped=0),
                     files=files if files is not None else {"tools/source.py": dict(executable_lines=[1, 2], covered_lines=[1, 2])})
        value.update(overrides)
        path = self.reports / (scope + ".json")
        path.write_text(json.dumps(value))
        return path

    def add_python(self):
        self.put("tools/source.py", "value = 1\nvalue += 2\n")
        self.commit()
        return self.plan()

    def test_docs_only_is_explicit_na_and_modified_lines_use_exact_head(self):
        self.put("README.md", "Updated\n")
        self.commit()
        value = GATE.evaluate(self.root, self.plan(), self.reports)
        self.assertEqual(value["result"], "not_applicable")
        plan = self.add_python()
        self.assertEqual(plan["changed_files"], {"tools/source.py": [1, 2]})
        self.report(plan)
        value = GATE.evaluate(self.root, plan, self.reports)
        self.assertEqual((value["result"], value["covered_changed_lines"], value["changed_executable_lines"]), ("passed", 2, 2))
        self.base = plan["source_sha"]
        self.put("tools/source.py", "value = 1\nvalue += 3\n")
        self.commit()
        self.assertEqual(self.plan()["changed_files"]["tools/source.py"], [2])

    def test_uncovered_line_is_not_rounded_to_pass(self):
        plan = self.add_python()
        self.report(plan, files={"tools/source.py": dict(executable_lines=[1, 2], covered_lines=[1])})
        value = GATE.evaluate(self.root, plan, self.reports)
        self.assertEqual(value["result"], "failed")
        self.assertEqual(value["uncovered"], {"tools/source.py": [2]})

    def test_python_check_defers_native_evidence_without_weakening_full_gate(self):
        plan = self.add_python()
        self.put("Sources/Fluid/Native.swift", "let native = 1\n")
        self.commit()
        plan = self.plan()
        self.report(plan)
        args = ["--root", str(self.root), "--base", self.base, "--head", plan["source_sha"],
                "--reports-dir", str(self.reports)]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(GATE.main([*args, "--python-only", "--require-scope", "python"]), 0)
        value = json.loads(output.getvalue())
        self.assertEqual(value["coverage_scope"], "python")
        self.assertEqual(value["deferred_scopes"], ["macos"])
        self.assertEqual(value["changed_executable_lines"], 2)
        self.assertIn("Sources/Fluid/Native.swift", plan["changed_files"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(GATE.main(args), 1)
            self.assertEqual(GATE.main([*args, "--python-only", "--require-scope", "ios"]), 1)
        self.report(plan, files={"tools/source.py": dict(executable_lines=[1, 2], covered_lines=[1])})
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(GATE.main([*args, "--python-only"]), 1)
        self.assertEqual(json.loads(output.getvalue())["uncovered"], {"tools/source.py": [2]})

    def test_python_check_keeps_unsupported_code_visible(self):
        plan = self.add_python()
        self.put("scripts/tool.sh", "echo fixture\n")
        self.commit()
        plan = self.plan()
        self.report(plan)
        with contextlib.redirect_stderr(io.StringIO()) as output:
            self.assertEqual(GATE.main(["--root", str(self.root), "--base", self.base, "--head", plan["source_sha"],
                "--reports-dir", str(self.reports), "--python-only"]), 1)
        self.assertIn("Unsupported", output.getvalue())

    def test_full_baseline_requires_selected_reports_even_with_no_diff(self):
        self.put("tools/source.py", "value = 1\n")
        self.base = self.commit()
        args = ["--root", str(self.root), "--base", self.base, "--head", self.base,
                "--reports-dir", str(self.reports), "--require-scope", "python"]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(GATE.main(args), 1)
        plan = self.plan()
        self.report(plan, files={"tools/source.py": dict(executable_lines=[1], covered_lines=[1])})
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(GATE.main(args), 0)
        self.assertEqual(json.loads(output.getvalue())["result"], "passed")

    def test_missing_new_file_or_report_and_zero_reports_fail_closed(self):
        plan = self.add_python()
        with self.assertRaises(OSError):
            GATE.evaluate(self.root, plan, self.reports)
        for data in [{}, {"README.md": dict(executable_lines=[1], covered_lines=[1])}]:
            self.report(plan, files=data)
            with self.assertRaises(ValueError):
                GATE.evaluate(self.root, plan, self.reports)
        self.report(plan, files={"tools/source.py": dict(executable_lines=[], covered_lines=[])})
        with self.assertRaisesRegex(ValueError, "No executable"):
            GATE.evaluate(self.root, plan, self.reports)

    def test_identity_test_status_and_invalid_records_are_rejected(self):
        plan = self.add_python()
        for override in [dict(source_sha="wrong"), dict(scope="ios"), dict(schema_version=True),
                         dict(tests=dict(passed=0, failed=0, skipped=3)), dict(tests=dict(passed=1, failed=1, skipped=0)),
                         dict(tests=dict(passed=True, failed=0, skipped=0)), dict(tests=[]), dict(files=[]),
                         dict(files={"tools/source.py": dict(executable_lines=[1], covered_lines=[2])}),
                         dict(files={"tools/source.py": dict(executable_lines=[True], covered_lines=[])}),
                         dict(files={"tools/source.py": dict(executable_lines="1", covered_lines=[])}),
                         dict(files={"missing.py": dict(executable_lines=[1], covered_lines=[1])})]:
            with self.subTest(override=override):
                self.report(plan, **override)
                with self.assertRaises((ValueError, KeyError)):
                    GATE.evaluate(self.root, plan, self.reports)
        (self.reports / "python.json").write_text("[]")
        with self.assertRaises(ValueError):
            GATE.evaluate(self.root, plan, self.reports)
        (self.reports / "python.json").write_text('{"files":{},"files":{}}')
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            GATE.evaluate(self.root, plan, self.reports)

    def test_unsafe_paths_and_line_values_are_rejected(self):
        for value in [None, "", ".", "/absolute.py", "a/../x.py", "a//x.py", "a\\x.py", "a\nx.py"]:
            with self.subTest(path=value), self.assertRaises(ValueError):
                GATE.path_name(value)
        for value in [None, [0], [-1], [True]]:
            with self.assertRaises(ValueError):
                GATE.lines(value)
        self.assertEqual(GATE.path_name("tools/данные [1].py"), "tools/данные [1].py")

    def test_resources_require_their_consumers_without_fake_line_counts(self):
        for name in ["Sources/Brand/logo.png", "Vendor/Adapter/Package.resolved", "tools/config.json"]:
            self.put(name, "fixture\n")
        self.commit()
        plan = self.plan()
        self.assertEqual(set(plan["required_scopes"]), GATE.SCOPES)
        self.assertEqual(plan["changed_files"], {})

    def test_owning_test_and_config_jobs_are_required_without_test_line_denominator(self):
        for name in ["Tests/MobileUITests/Smoke.swift", "Tests/MobileIntegrationTests/Unit.swift", "Tests/test_tool.py",
                     "Tests/FluidDictationIntegrationTests/Unit.swift", "Vendor/Example/Tests/Unit.swift",
                     ".github/workflows/ci.yml", ".codex/config.toml", ".gitignore", "Package.swift",
                     "Fluid.xcodeproj/project.pbxproj", "Sources/Mobile/shared-sources.txt"]:
            self.put(name, "fixture\n")
        self.commit()
        plan = self.plan()
        self.assertEqual(set(plan["required_scopes"]), {"macos", "ios", "python", "packages"})
        self.assertEqual(plan["changed_files"], {})

    def test_collector_changes_validate_every_report_consumer(self):
        self.put("scripts/dev/coverage-ci.py", "value = 1\n")
        self.commit()
        self.assertEqual(set(self.plan()["required_scopes"]), GATE.SCOPES)

    def test_shared_and_package_native_sources_route_to_real_consumers(self):
        self.put("Sources/Mobile/shared-sources.txt", "Sources/Fluid/Shared.swift\n")
        for name in ["Sources/Fluid/Shared.swift", "Sources/Mobile/App.swift", "Vendor/Adapter/Sources/A.swift",
                     "Vendor/NativeTextInference/Sources/A.swift", "Sources/test_production.py"]:
            self.put(name, "value = 1\n")
        self.commit()
        plan = self.plan()
        self.assertEqual(set(plan["required_scopes"]), {"macos", "ios", "packages", "python"})
        self.assertIn("Sources/test_production.py", plan["changed_files"])

    def test_required_scope_union_preserves_every_executable_line(self):
        self.put("Sources/Mobile/shared-sources.txt", "Sources/Fluid/Shared.swift\n")
        self.put("Sources/Fluid/Shared.swift", "let first = 1\nlet second = 2\n")
        self.base = self.commit()
        self.put("Sources/Fluid/Shared.swift", "let first = 3\nlet second = 4\n")
        self.commit()
        plan = self.plan()
        for scope, covered in [("macos", [1]), ("ios", [2])]:
            self.report(plan, scope=scope, files={"Sources/Fluid/Shared.swift": dict(executable_lines=[1, 2], covered_lines=covered)})
        self.assertEqual(GATE.evaluate(self.root, plan, self.reports)["result"], "passed")
        (self.reports / "ios.json").unlink()
        with self.assertRaises(OSError):
            GATE.evaluate(self.root, plan, self.reports)

    def test_renames_deletions_and_literal_pathspec_names(self):
        self.put("tools/part[1].py", "value = 1\n")
        self.base = self.commit()
        self.run_git("mv", "tools/part[1].py", "tools/renamed.py")
        self.commit()
        plan = self.plan()
        self.assertEqual(plan["changed_files"], {"tools/renamed.py": []})
        self.base = plan["source_sha"]
        self.run_git("rm", "tools/renamed.py")
        self.commit()
        self.assertEqual(self.plan()["changed_files"], {})
        self.assertEqual(self.plan()["required_scopes"], ["python"])

    def test_removing_unsupported_code_adds_no_executable_lines(self):
        self.put("scripts/old.sh", "echo old\n")
        self.base = self.commit()
        self.run_git("rm", "scripts/old.sh")
        self.commit()
        self.assertEqual(self.plan()["unsupported"], [])

    def test_unknown_and_binary_executable_source_cannot_get_na(self):
        self.put("scripts/tool.sh", "echo fixture\n")
        self.put("scripts/unknown.lua", "print(1)\n")
        p = self.root / "tools/binary.py"
        p.parent.mkdir()
        p.write_bytes(b"not-source\0")
        self.commit()
        plan = self.plan()
        self.assertEqual(len(plan["unsupported"]), 3)
        with self.assertRaisesRegex(ValueError, "Unsupported"):
            GATE.evaluate(self.root, plan, self.reports)

    def test_non_ancestor_base_and_unresolvable_revision_fail(self):
        other = self.add_python()["source_sha"]
        with self.assertRaises(ValueError):
            GATE.classify(self.root, other, self.base)
        with self.assertRaises(subprocess.CalledProcessError):
            GATE.commit(self.root, "--invalid")

    def test_zero_executable_changed_file_requires_legitimate_inventory(self):
        self.put("tools/source.py", "value = 1\n")
        self.put("Sources/Fluid/Types.swift", "enum Kind {}\n")
        self.commit()
        plan = self.plan()
        data = {"tools/source.py": dict(executable_lines=[1], covered_lines=[1]), "Sources/Fluid/Types.swift": dict(executable_lines=[], covered_lines=[])}
        for scope in plan["required_scopes"]:
            self.report(plan, scope=scope, files=data)
        self.assertEqual(GATE.evaluate(self.root, plan, self.reports)["result"], "passed")

    def test_cli_success_failure_and_entrypoint(self):
        plan = self.add_python()
        output = self.root / "gate.json"
        args = ["--root", str(self.root), "--base", self.base, "--head", plan["source_sha"], "--output", str(output)]
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(GATE.main([*args, "--classify"]), 0)
        self.assertEqual(json.loads(output.read_text())["source_sha"], plan["source_sha"])
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(GATE.main([*args, "--reports-dir", str(self.reports)]), 1)
        self.assertEqual(json.loads(output.read_text())["result"], "failed")
        self.report(plan, files={"tools/source.py": dict(executable_lines=[1, 2], covered_lines=[1])})
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(GATE.main([*args, "--reports-dir", str(self.reports)]), 1)
        self.report(plan)
        with patch.object(sys, "argv", ["coverage-gate.py", *args, "--reports-dir", str(self.reports)]), contextlib.redirect_stdout(io.StringIO()), self.assertRaises(SystemExit) as exit_result:
            runpy.run_path(str(ROOT / "scripts/dev/coverage-gate.py"), run_name="__main__")
        self.assertEqual(exit_result.exception.code, 0)
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(GATE.main(["--root", str(self.root), "--base", "bad", "--head", "bad"]), 1)


if __name__ == "__main__":
    unittest.main()
