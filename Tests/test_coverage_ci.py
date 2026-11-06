"""Coverage producer contracts use synthetic tool responses and owned temp roots."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import runpy
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch, Mock

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("coverage_ci", ROOT / "scripts/dev/coverage-ci.py")
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)


def completed(stdout="", status=0):
    return subprocess.CompletedProcess([], status, stdout)


def summary(passed=1, failed=0, skipped=0):
    return dict(totalTestCount=passed + failed + skipped, passedTests=passed,
                failedTests=failed, skippedTests=skipped, expectedFailures=0,
                result="Failed" if failed else "Passed")


def archive(root):
    return {str(root / "Sources/A.swift"): [dict(line=1, isExecutable=True, executionCount=1),
            dict(line=2, isExecutable=True, executionCount=0), dict(line=3, isExecutable=False)]}


class CoverageProducerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.out = self.root / "out"
        self.out.mkdir()

    def test_command_handles_capture_logs_and_failures(self):
        self.assertEqual(CI.command([sys.executable, "-c", "print('fixture')"]).stdout.strip(), "fixture")
        log = self.out / "command.log"
        self.assertEqual(CI.command([sys.executable, "-c", "print('recorded')"], log=log).returncode, 0)
        self.assertEqual(log.read_text().strip(), "recorded")
        self.assertEqual(CI.command([sys.executable, "-c", "raise SystemExit(7)"], tolerate=True).returncode, 7)
        with self.assertRaisesRegex(RuntimeError, "exited 8"):
            CI.command([sys.executable, "-c", "raise SystemExit(8)"])
        with patch.object(CI, "command", return_value=completed(" abc\n")):
            self.assertEqual(CI.git(self.root, "rev-parse", "HEAD"), "abc")

    def test_compiler_lines_and_paths_do_not_include_external_or_test_code(self):
        data = archive(self.root)
        data[str(self.root.parent / "external.swift")] = [dict(line=1, isExecutable=True, executionCount=99)]
        data[str(self.root / "Tests/Fake.swift")] = [dict(line=1, isExecutable=True, executionCount=99)]
        self.assertEqual(CI.xccov_files(data, self.root), {"Sources/A.swift": {"executable_lines": [1, 2], "covered_lines": [1]}})
        self.assertEqual(CI.source_path(self.root, "Sources/A.swift"), "Sources/A.swift")
        self.assertFalse(CI.production("tools/test_hidden.py"))
        for row in [dict(line=True, isExecutable=True, executionCount=1), dict(line=0, isExecutable=False),
                    dict(line=1, isExecutable=1), dict(line=1, isExecutable=True, executionCount=-1),
                    dict(line=1, isExecutable=True, executionCount=True)]:
            with self.subTest(row=row), self.assertRaises(ValueError):
                CI.xccov_files({str(self.root / "Sources/A.swift"): [row]}, self.root)

    def test_archive_aliases_preserve_unexecuted_regions(self):
        data = archive(self.root)
        data["Sources/A.swift"] = [dict(line=4, isExecutable=True, executionCount=0)]
        row = CI.xccov_files(data, self.root)["Sources/A.swift"]
        self.assertEqual(row["executable_lines"], [1, 2, 4])
        self.assertEqual(row["covered_lines"], [1])

    def test_lcov_merges_hits_without_counting_duplicate_lines(self):
        text = f"TN:\nSF:{self.root}/Sources/A.swift\nDA:1,2\nDA:2,0\nDA:1,1\nend_of_record\nSF:/outside/a.swift\nDA:7,1\n"
        files = CI.lcov_files(text, self.root)
        CI.join_files(files, {"Sources/A.swift": {"executable_lines": [2, 3], "covered_lines": [2]}})
        self.assertEqual(files["Sources/A.swift"], dict(executable_lines=[1, 2, 3], covered_lines=[1, 2]))
        for line in ["DA:0,1", "DA:1,-1"]:
            with self.assertRaises(ValueError):
                CI.lcov_files("SF:Sources/A.swift\n" + line, self.root)

    def test_test_accounting_rejects_partial_and_invalid_summaries(self):
        self.assertEqual(CI.test_counts(summary(3, 1, 2)), dict(passed=3, failed=1, skipped=2))
        for invalid in [dict(summary(), totalTestCount=9), dict(summary(), passedTests=True), dict(summary(), skippedTests=-1)]:
            with self.assertRaises(ValueError):
                CI.test_counts(invalid)
        tree = dict(testNodes=[dict(children=[dict(nodeType="Test Case", nodeIdentifier="Smoke/testA()", result="Passed")])])
        CI.require_test_class(tree, "Smoke")
        for missing in [{}, [dict(nodeType="Test Case", nodeIdentifier="Other/testA()", result="Passed")],
                        [dict(nodeType="Test Case", nodeIdentifier="Smoke/testA()", result="Skipped")]]:
            with self.assertRaises(ValueError):
                CI.require_test_class(missing, "Smoke")

    def test_report_requires_stable_source_and_real_execution(self):
        files = CI.xccov_files(archive(self.root), self.root)
        with patch.object(CI, "git", side_effect=["a", ""]):
            self.assertEqual(CI.report(self.root, "macos", self.out, files, dict(passed=1, failed=0, skipped=0), "a"), 0)
        self.assertEqual(CI.read(self.out / "macos.json")["source_sha"], "a")
        for values in [["changed"], ["a", "Sources/A.swift"]]:
            with patch.object(CI, "git", side_effect=values), self.assertRaises(ValueError):
                CI.report(self.root, "macos", self.out, files, dict(passed=1, failed=0, skipped=0), "a")
        for data in [{}, {"Sources/A.swift": dict(executable_lines=[], covered_lines=[])}]:
            with patch.object(CI, "git", side_effect=["a", ""]), self.assertRaises(ValueError):
                CI.report(self.root, "macos", self.out, data, dict(passed=1, failed=0, skipped=0), "a")
        with patch.object(CI, "git", side_effect=["a", ""]):
            self.assertEqual(CI.report(self.root, "macos", self.out, files, dict(passed=0, failed=0, skipped=1), "a"), 1)

    def test_plan_pins_pr_push_and_branch_bases_and_force_all(self):
        for event, env, expected in [({"pull_request": {"base": {"sha": "pr-base"}}}, {}, "pr-base"),
                                     ({"before": "push-base"}, {"GITHUB_REF": "refs/heads/main"}, "push-base"),
                                     ({"before": "0" * 40}, {"GITHUB_REF": "refs/heads/main"}, "merge-base")]:
            event_path = self.out / "event.json"
            CI.save(event_path, event)
            data = dict(base_sha=expected, source_sha="head", required_scopes=["python"])
            with patch.dict(os.environ, {"GITHUB_EVENT_PATH": str(event_path), **env}, clear=True), patch.object(CI, "git", side_effect=["head", "merge-base"]), patch.object(CI, "command", return_value=completed(json.dumps(data))), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(CI.plan(self.root, self.out / "plan.json", True), 0)
            self.assertEqual(CI.read(self.out / "plan.json")["run_scopes"], list(CI.SCOPES))
        with patch.dict(os.environ, {}, clear=True), patch.object(CI, "git", side_effect=["head", "base"]), patch.object(CI, "command", return_value=completed(json.dumps(dict(base_sha="base", source_sha="head", required_scopes=[])))), contextlib.redirect_stdout(io.StringIO()):
            CI.plan(self.root, self.out / "plan.json")
        self.assertEqual(CI.read(self.out / "plan.json")["run_scopes"], [])

    def test_final_job_rejects_missing_failed_and_skipped_required_producers(self):
        plan = self.out / "plan.json"
        needs = self.out / "needs.json"
        CI.save(plan, dict(base_sha="base", source_sha="head", run_scopes=["python"]))
        for state in [None, "failure", "skipped", "cancelled"]:
            states = {"plan": {"result": "success"}, "portable": {"result": "success"}}
            if state:
                states["python"] = {"result": state}
            CI.save(needs, states)
            self.assertEqual(CI.finish(self.root, plan, self.out, needs, self.out / "gate.json"), 1)
        CI.save(needs, {key: {"result": "success"} for key in ["plan", "portable", "python"]})
        with patch.object(CI, "command", return_value=completed(status=1)) as run:
            self.assertEqual(CI.finish(self.root, plan, self.out, needs, self.out / "gate.json"), 1)
        self.assertIn("head", run.call_args.args[0])
        with patch.dict(os.environ, {"PICHI_COVERAGE_PLAN": plan.read_text(), "PICHI_COVERAGE_NEEDS": needs.read_text()}), patch.object(CI, "command", return_value=completed()):
            self.assertEqual(CI.finish(self.root, None, self.out, None, self.out / "gate.json"), 0)

    def test_configured_host_keeps_ui_host_separate_and_exports_actual_temp(self):
        helper = self.root / "scripts/dev/macos-regression.py"
        helper.parent.mkdir(parents=True)
        helper.symlink_to(ROOT / "scripts/dev/macos-regression.py")
        products = self.out / "products"
        products.mkdir()
        value = dict(TestConfigurations=[dict(TestTargets=[
            dict(TestBundlePath="PichiVoiceMobileIntegrationTests.xctest", TestHostPath="__TESTROOT__/App.app"),
            dict(TestBundlePath="PichiVoiceMobileUITests.xctest", TestHostPath="Runner.app", UITargetAppPath="__TESTROOT__/App.app")])])
        (products / "Mobile_1.xctestrun").write_bytes(plistlib.dumps(value))
        with patch.object(CI, "command", return_value=completed("/owned/temp/\n")):
            path, apps = CI.configure_run(self.root, products, "Mobile")
        targets = plistlib.loads(path.read_bytes())["TestConfigurations"][0]["TestTargets"]
        self.assertEqual(apps, {"App.app"})
        self.assertEqual(targets[0]["EnvironmentVariables"]["PICHI_TEST_PYTHON_EXECUTABLE"], sys.executable)
        self.assertEqual(targets[0]["EnvironmentVariables"]["PICHI_MOBILE_HOSTED_FIXTURE"], "1")
        self.assertNotIn("PICHI_MOBILE_HOSTED_FIXTURE", targets[1]["EnvironmentVariables"])
        self.assertEqual(targets[0]["EnvironmentVariables"]["FLUID_EXPORT_TEST_SANDBOX_TEMP"], "/owned/temp/")
        with self.assertRaises(ValueError):
            CI.configure_run(self.root, products, "Missing")
        (products / "Mobile_2.xctestrun").write_bytes(plistlib.dumps(value))
        with self.assertRaises(ValueError):
            CI.configure_run(self.root, products, "Mobile")

    def run_native(self, scope="macos", *, code=0, app_lines=3, ui_pass=True):
        calls = []
        def tool(argv, **kwargs):
            calls.append([str(x) for x in argv])
            if argv[0] == "xcodebuild":
                return completed(status=code if "test-without-building" in argv else 0)
            if argv[:3] == ["xcrun", "simctl", "list"]:
                return completed(json.dumps(dict(devicetypes=[dict(name="iPhone 17", identifier="phone"), dict(name="iPad (A16)", identifier="pad")], runtimes=[dict(name="iOS 27.0", identifier="runtime", isAvailable=True)])))
            if argv[:3] == ["xcrun", "simctl", "create"]:
                return completed("owned-udid\n")
            if argv[:3] == ["xcrun", "simctl", "shutdown"] or argv[:3] == ["xcrun", "simctl", "delete"]:
                return completed()
            if "summary" in argv:
                return completed(json.dumps(summary()))
            if "--report" in argv:
                return completed(json.dumps(dict(targets=[dict(name="App.app", executableLines=app_lines)])))
            if "--archive" in argv:
                return completed(json.dumps(archive(self.root)))
            return completed(json.dumps([dict(nodeType="Test Case", nodeIdentifier="Smoke/testA()", result="Passed" if ui_pass else "Skipped")]))
        with patch.dict(os.environ, {"RUNNER_ENVIRONMENT": "github-hosted"}), patch.object(CI, "git", side_effect=lambda root, *args: "head" if args == ("rev-parse", "HEAD") else ""), patch.object(CI, "configure_run", return_value=(self.out / "coverage.xctestrun", {"App.app"})), patch.object(CI, "command", side_effect=tool):
            status = CI.native(self.root, self.out, scope, "Smoke")
        return status, calls

    def test_native_rejects_personal_macos_data_before_launching_tools(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(CI, "command") as tool, self.assertRaisesRegex(ValueError, "personal app data"):
            CI.native(self.root, self.out, "macos", "Smoke")
        tool.assert_not_called()

    def test_native_enables_app_instrumentation_and_does_not_hide_test_exit(self):
        status, calls = self.run_native()
        self.assertEqual(status, 0)
        self.assertIn("ENABLE_CODE_COVERAGE=YES", calls[0])
        self.assertEqual(self.run_native(code=65)[0], 1)
        with self.assertRaisesRegex(ValueError, "App coverage"):
            self.run_native(app_lines=0)

    def test_mobile_devices_are_joined_and_required_smoke_cannot_skip(self):
        status, calls = self.run_native("ios")
        self.assertEqual(status, 0)
        self.assertEqual(sum(x[:3] == ["xcrun", "simctl", "delete"] for x in calls), 2)
        self.assertEqual(CI.read(self.out / "ios.json")["tests"]["passed"], 2)
        with self.assertRaisesRegex(ValueError, "Required CI UI"):
            self.run_native("ios", ui_pass=False)

    def test_package_accounting_combines_xctest_and_swift_testing(self):
        text = "Test Suite 'All tests' passed at now.\n Executed 7 tests, with 2 tests skipped and 0 failures\n"
        self.assertEqual(CI.swift_counts(text), dict(passed=5, failed=0, skipped=2))
        xml = self.out / "swift.xml"
        xml.write_text('<testsuites><testsuite tests="3"><testcase/><testcase><skipped/></testcase><testcase><failure/></testcase></testsuite></testsuites>')
        self.assertEqual(CI.swift_counts(text, xml), dict(passed=6, failed=1, skipped=3))
        xml.write_text('<testsuites><testsuite tests="0"/></testsuites>')
        with self.assertRaises(ValueError):
            CI.swift_counts("", xml)
        xml.write_text('<testsuites><testsuite tests="1"/></testsuites>')
        with self.assertRaises(ValueError):
            CI.swift_counts(text, xml)
        with self.assertRaises(ValueError):
            CI.swift_counts("Test Suite 'All tests' failed at now.\n Executed 1 test, with 2 failures")

    def test_package_export_includes_every_test_product(self):
        commands = []
        def tool(argv, **kwargs):
            commands.append([str(x) for x in argv])
            if argv[0] == "swift":
                scratch = Path(argv[argv.index("--scratch-path") + 1])
                folder = scratch / "triple/debug"
                folder.mkdir(parents=True)
                first, second = folder / "one", scratch / "out/Products/Debug/Second.xctest/Contents/MacOS/two"
                first.write_bytes(b"fixture object")
                second.parent.mkdir(parents=True)
                second.write_bytes(b"fixture object")
                CI.save(folder / "description.json", dict(builtTestProducts=[dict(binaryPath=str(first))]))
                (folder / "one.profraw").write_bytes(b"fixture")
                Path(kwargs["log"]).write_text("Test Suite 'All tests' passed at now.\n Executed 2 tests, with 0 failures\n")
            return completed(f"SF:{self.root}/Vendor/Sample/Sources/A.swift\nDA:1,1\n")
        with patch.object(CI, "PACKAGES", ("Sample",)), patch.object(CI, "git", side_effect=["head", "head", ""]), patch.object(CI, "command", side_effect=tool):
            self.assertEqual(CI.packages(self.root, self.out), 0)
        export = next(x for x in commands if x[:3] == ["xcrun", "llvm-cov", "export"])
        self.assertIn("-object", export)
        self.assertTrue(any(str(x).endswith("/two") for x in export))

    def test_package_without_profiles_cannot_report_success(self):
        def tool(argv, **kwargs):
            Path(kwargs["log"]).write_text("Test Suite 'All tests' passed at now.\n Executed 2 tests, with 0 failures\n")
            return completed()
        with patch.object(CI, "PACKAGES", ("Missing",)), patch.object(CI, "git", return_value="head"), patch.object(CI, "command", side_effect=tool), self.assertRaisesRegex(ValueError, "Missing package profiles"):
            CI.packages(self.root, self.out)

    def test_executable_entrypoint_rejects_unknown_action(self):
        with patch.object(sys, "argv", ["coverage-ci.py", "unknown", "--output", str(self.out)]), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as exit_result:
            runpy.run_path(str(ROOT / "scripts/dev/coverage-ci.py"), run_name="__main__")
        self.assertEqual(exit_result.exception.code, 2)

    def test_python_loader_and_missing_coverage_files(self):
        test = self.root / "Tests/test_fixture.py"
        test.parent.mkdir()
        test.write_text("import unittest\nclass Fixture(unittest.TestCase):\n def test_value(self): self.assertEqual(2+2,4)\n")
        cov = Mock()
        def export(**kwargs):
            CI.save(kwargs["outfile"], {"files": {"source.py": {"executed_lines": [1], "missing_lines": [2]}}})
        cov.json_report.side_effect = export
        with patch.dict(sys.modules, {"coverage": types.SimpleNamespace(Coverage=Mock(return_value=cov))}), patch.object(CI, "git", side_effect=["head", "source.py\nTests/test_fixture.py", "head", ""]):
            self.assertEqual(CI.python(self.root, self.out), 0)
        cov.get_data.return_value.touch_files.assert_called_once_with([str(self.root / "source.py")])
        self.assertEqual(CI.read(self.out / "python.json")["files"]["source.py"]["executable_lines"], [1, 2])
        test.write_text("raise ValueError('broken fixture import')\n")
        with patch.dict(sys.modules, {"coverage": types.SimpleNamespace(Coverage=Mock(return_value=cov))}), patch.object(CI, "git", side_effect=["head", "Tests/test_fixture.py"]), self.assertRaisesRegex(ValueError, "broken fixture"):
            CI.python(self.root, self.out)
        self.assertEqual(cov.stop.call_count, 2)

    def test_cli_dispatch_and_errors(self):
        for mode, function in [("plan", "plan"), ("finish", "finish"), ("native", "native"), ("packages", "packages"), ("python", "python")]:
            with patch.object(CI, function, return_value=0) as target:
                self.assertEqual(CI.main([mode, "--output", str(self.out)]), 0)
                target.assert_called_once()
        with patch.object(CI, "native", side_effect=ValueError("bad report")), contextlib.redirect_stderr(io.StringIO()) as error:
            self.assertEqual(CI.main(["native", "--output", str(self.out)]), 1)
        self.assertIn("bad report", error.getvalue())


if __name__ == "__main__":
    unittest.main()
