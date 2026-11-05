import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("macos_regression", ROOT / "scripts/dev/macos-regression.py")
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class RegressionConfigurationTests(unittest.TestCase):
    def target(self, variables=None):
        return {"TestBundlePath": "__TESTROOT__/Debug/Synthetic.xctest",
                "EnvironmentVariables": variables or {}}

    def test_format_one_defaults_and_existing_injection_are_preserved(self):
        target = self.target({"DYLD_INSERT_LIBRARIES": "synthetic-runtime", "EXISTING": "value"})
        self.assertEqual(RUNNER.configure_targets({"SyntheticTests": target}, {}), 1)
        self.assertEqual(target["EnvironmentVariables"], {
            "DYLD_INSERT_LIBRARIES": "synthetic-runtime", "EXISTING": "value",
            "FLUIDVOICE_MIC_PHASE1": "disabled", "PICHI_INTERFACE_LANGUAGE": "en"})

    def test_all_nested_format_two_targets_receive_explicit_fixture_values(self):
        first, second = self.target(), self.target({"PICHI_S1_MINI_MODEL_PATH": "old"})
        del first["EnvironmentVariables"]
        first["TestingEnvironmentVariables"] = {"XCInjectBundleInto": "__TESTROOT__/Synthetic.app"}
        second["UITargetAppEnvironmentVariables"] = {"PICHI_INTERFACE_LANGUAGE": "en"}
        value = {"TestConfigurations": [{"TestTargets": [first]}, {"TestTargets": [second]}],
                 "__xctestrun_metadata__": {"FormatVersion": 2, "EnvironmentVariables": {"untouched": "1"}}}
        environment = {"PICHI_GIGAAM_APP_TEST_AUDIO": "/synthetic fixture/речь.wav",
                       "PICHI_S1_MINI_MODEL_PATH": "/synthetic-model",
                       "FLUIDAUDIO_PARAKEET_MODEL_DIR": "/synthetic-parakeet",
                       "FLUIDVOICE_REPLAY_MEETING_DIRS": "/synthetic-meeting",
                       "FV_EDGE_REPLAY_DIR": "/synthetic-replay", "TEST_CUSTOM_FONTS": "1",
                       "PICHI_INTERFACE_LANGUAGE": "ru", "FLUIDVOICE_MIC_PHASE1": "1",
                       "CI": "true", "GITHUB_ACTIONS": "true", "UNRELATED_SECRET": "never-copy"}
        self.assertEqual(RUNNER.configure_targets(value, environment), 2)
        for target in (first, second):
            for key, variables in target.items():
                if key.endswith("EnvironmentVariables"):
                    self.assertEqual(variables["PICHI_GIGAAM_APP_TEST_AUDIO"], environment["PICHI_GIGAAM_APP_TEST_AUDIO"])
                    self.assertEqual(variables["PICHI_S1_MINI_MODEL_PATH"], "/synthetic-model")
                    self.assertEqual(variables["PICHI_INTERFACE_LANGUAGE"], "ru")
                    self.assertEqual(variables["FLUIDVOICE_MIC_PHASE1"], "disabled")
                    self.assertNotIn("UNRELATED_SECRET", variables)
        self.assertEqual(value["__xctestrun_metadata__"]["EnvironmentVariables"], {"untouched": "1"})
        self.assertEqual(first["TestingEnvironmentVariables"]["XCInjectBundleInto"], "__TESTROOT__/Synthetic.app")

    def test_missing_targets_and_invalid_environment_fail_closed(self):
        for value in ({"TestConfigurations": []}, {"target": {"TestBundlePath": "a", "EnvironmentVariables": []}}):
            with self.assertRaises(ValueError):
                RUNNER.configure_targets(value, {})

    def test_fresh_spec_is_required_and_configured_spec_keeps_testroot(self):
        with tempfile.TemporaryDirectory() as directory:
            products = Path(directory)
            marker = products / "marker"
            source = products / "Fluid_macosx-synthetic.xctestrun"
            source.write_bytes(plistlib.dumps({"SyntheticTests": self.target()}))
            marker.touch()
            os.utime(source, ns=(1, 1))
            with self.assertRaises(ValueError):
                RUNNER.configure(products, marker, "test-run")
            os.utime(source, ns=(marker.stat().st_mtime_ns, marker.stat().st_mtime_ns))
            output = io.StringIO()
            with patch.dict(os.environ, {}, clear=True), contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
                RUNNER.configure(products, marker, "test-run")
            destination = Path(output.getvalue().strip())
            self.assertEqual(destination.parent, source.parent)
            self.assertEqual(plistlib.loads(destination.read_bytes())["SyntheticTests"]["TestBundlePath"],
                             "__TESTROOT__/Debug/Synthetic.xctest")
            (products / "Fluid_second.xctestrun").write_bytes(source.read_bytes())
            with self.assertRaises(ValueError):
                RUNNER.configure(products, marker, "ambiguous")


class RegressionResultTests(unittest.TestCase):
    @staticmethod
    def report(**overrides):
        return dict(result="Passed", totalTestCount=5, passedTests=2, failedTests=0,
                    skippedTests=2, expectedFailures=1, **overrides)

    def summarize(self, value, status=0):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            status = RUNNER.summarize(value, status)
        return status, output.getvalue()

    def test_expected_failures_are_accounted_for_separately(self):
        status, text = self.summarize(self.report())
        self.assertEqual(status, 0)
        self.assertIn("5 total, 2 passed, 0 failed, 2 skipped, 1 expected failures", text)

    def test_failure_exit_or_incomplete_result_cannot_be_reported_as_passed(self):
        self.assertEqual(self.summarize(self.report(), 65)[0], 1)
        for change in ({"result": "Failed"}, {"result": "unknown"},
                       {"failedTests": 1, "passedTests": 1},
                       {"totalTestCount": 2, "passedTests": 0, "skippedTests": 2, "expectedFailures": 0}):
            self.assertEqual(self.summarize(self.report() | change)[0], 1)

    def test_missing_negative_boolean_or_inconsistent_counts_are_rejected(self):
        for change in ({"passedTests": None}, {"failedTests": -1}, {"skippedTests": True},
                       {"totalTestCount": 6}, {"result": None}):
            with self.assertRaises(ValueError):
                self.summarize(self.report() | change)
        with self.assertRaises(ValueError):
            self.summarize([])


class RegressionCommandTests(unittest.TestCase):
    """Exercise shell failure propagation using fake tools, never Xcode or app/audio."""

    def run_command(self, build_status=0, test_status=0, report_status=0, processes="", snapshot_fails=""):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        scripts = root / "scripts/dev"
        scripts.mkdir(parents=True)
        for name in ("macos.sh", "macos-regression.py", "assert-worktree.sh"):
            shutil.copyfile(ROOT / "scripts/dev" / name, scripts / name)
        tools = root / "fake-tools"
        tools.mkdir()
        mocks = {
            "uname": "#!/bin/sh\nprintf '%s\\n' Darwin\n",
            "ps": "#!/bin/sh\nprintf '%s' \"$SYNTHETIC_PROCESSES\"\n",
            "python3": f'''#!/bin/sh
case "$*" in *remember-preferences*) [ -z "$SYNTHETIC_SNAPSHOT_FAILS" ] || exit 1 ;; esac
exec "{sys.executable}" "$@"
''',
            "git": '''#!/bin/sh
case "$*" in
    "rev-parse --show-toplevel") printf '%s\\n' "$SYNTHETIC_ROOT" ;;
    "rev-parse --absolute-git-dir") printf '%s/worktrees/test\\n' "$SYNTHETIC_ROOT" ;;
    "rev-parse --path-format=absolute --git-common-dir") printf '%s/.git\\n' "$SYNTHETIC_ROOT" ;;
    "rev-parse HEAD") printf '%040d\\n' 1 ;;
    "status --porcelain") exit 0 ;;
    *) exit 1 ;;
esac
''',
            "xcodebuild": '''#!/usr/bin/env python3
import os, pathlib, plistlib, sys
root = pathlib.Path(os.environ["SYNTHETIC_ROOT"])
with (root / "calls.txt").open("a") as out: out.write(" ".join(sys.argv[1:]) + "\\n")
if "build-for-testing" in sys.argv:
    if int(os.environ["SYNTHETIC_BUILD_STATUS"]): sys.exit(int(os.environ["SYNTHETIC_BUILD_STATUS"]))
    products = root / ".build/Xcode/Build/Products"
    products.mkdir(parents=True)
    (products / "Fluid_macosx-synthetic.xctestrun").write_bytes(plistlib.dumps({"TestConfigurations": [{"TestTargets": [{"TestBundlePath": "__TESTROOT__/Synthetic.xctest"}]}]}))
else:
    spec = pathlib.Path(sys.argv[sys.argv.index("-xctestrun")+1])
    target = plistlib.loads(spec.read_bytes())["TestConfigurations"][0]["TestTargets"][0]
    assert target["EnvironmentVariables"]["FLUIDVOICE_MIC_PHASE1"] == "disabled"
    assert target["EnvironmentVariables"]["PICHI_GIGAAM_APP_TEST_AUDIO"] == "/synthetic fixture.wav"
    home = pathlib.Path(os.environ["HOME"]) / "Library/Preferences"
    (home / "SyntheticTests.0BB4561E-4CAE-41FD-AC25-D87F13C048C5.plist").write_bytes(b"")
    (home / "ai.synthetic.real-app.plist").write_bytes(b"")
    sys.exit(int(os.environ["SYNTHETIC_TEST_STATUS"]))
''',
            "xcrun": '''#!/usr/bin/env python3
import json, os, sys
if int(os.environ["SYNTHETIC_REPORT_STATUS"]): sys.exit(int(os.environ["SYNTHETIC_REPORT_STATUS"]))
failed = int(os.environ["SYNTHETIC_TEST_STATUS"]) != 0
print(json.dumps(dict(result="Failed" if failed else "Passed", totalTestCount=3, passedTests=1 if failed else 2, failedTests=1 if failed else 0, skippedTests=1, expectedFailures=0)))
'''}
        for name, source in mocks.items():
            path = tools / name
            path.write_text(source)
            path.chmod(0o755)
        environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}", SYNTHETIC_ROOT=str(root),
                           SYNTHETIC_BUILD_STATUS=str(build_status), SYNTHETIC_TEST_STATUS=str(test_status),
                           SYNTHETIC_REPORT_STATUS=str(report_status), SYNTHETIC_PROCESSES=processes,
                           SYNTHETIC_SNAPSHOT_FAILS=snapshot_fails,
                           PICHI_GIGAAM_APP_TEST_AUDIO="/synthetic fixture.wav", HOME=str(root / "home"))
        (root / "home/Library/Preferences").mkdir(parents=True, exist_ok=True)
        environment.pop("PICHI_INTERFACE_LANGUAGE", None)
        result = subprocess.run(["bash", "scripts/dev/macos.sh", "regression", "-only-testing:SyntheticTests"],
                                cwd=root, env=environment, capture_output=True, text=True)
        runs = list((root / ".build/regression").iterdir()) if (root / ".build/regression").exists() else []
        self.assertEqual(len(runs), 1, result.stderr)
        return result, runs[0], (root / "calls.txt").read_text()

    def test_build_failure_does_not_start_tests_and_persists_status(self):
        result, run, calls = self.run_command(build_status=65)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertNotIn("test-without-building", calls)
        self.assertIn("tests were not run", (run / "summary.txt").read_text())

    def test_success_retains_actual_summary_and_upstream_exclusion(self):
        result, run, calls = self.run_command()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("-only-testing:SyntheticTests", calls)
        self.assertIn("-skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture", calls)
        self.assertEqual(json.loads((run / "summary.json").read_text())["skippedTests"], 1)
        self.assertIn("3 total, 2 passed, 0 failed, 1 skipped", (run / "summary.txt").read_text())

    def test_test_run_uses_its_own_identity_and_derived_data(self):
        _, _, calls = self.run_command()
        build, run = calls.splitlines()[:2]
        self.assertIn("PICHI_BUNDLE_IDENTIFIER=ai.pichi.voice.regression", build)
        self.assertIn("test-without-building", run)
        self.assertIn("-derivedDataPath", run)

    def test_test_failure_still_extracts_actual_summary_and_preserves_exit(self):
        result, run, calls = self.run_command(test_status=65)
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertIn("test-without-building", calls)
        self.assertEqual(json.loads((run / "summary.json").read_text())["failedTests"], 1)
        self.assertIn("1 failed", (run / "summary.txt").read_text())

    def test_run_removes_only_its_own_disposable_preferences(self):
        result, run, _ = self.run_command()
        preferences = run.parents[2] / "home/Library/Preferences"
        self.assertEqual(sorted(path.name for path in preferences.iterdir()), ["ai.synthetic.real-app.plist"])
        self.assertIn("Removed 1 disposable", result.stdout)

    def test_failed_record_still_runs_the_tests_and_removes_nothing(self):
        result, run, calls = self.run_command(snapshot_fails="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("test-without-building", calls)
        self.assertIn("removes none", result.stderr)
        preferences = run.parents[2] / "home/Library/Preferences"
        self.assertEqual(len(list(preferences.iterdir())), 2)

    def test_another_live_test_run_keeps_every_file(self):
        host = "/Users/a/Library/Developer/Xcode/DerivedData/Fluid/Pichi Voice Debug.app/Contents/MacOS/Pichi Voice Debug"
        result, run, _ = self.run_command(processes=f"/sbin/launchd\n{host}\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("while Pichi Voice Debug running", result.stderr)
        preferences = run.parents[2] / "home/Library/Preferences"
        self.assertEqual(len(list(preferences.iterdir())), 2)

    def test_live_standalone_probes_keep_every_file(self):
        for command in ("/usr/bin/python3 -S scripts/dev/standalone-regression.py --jobs 8", "/bin/sh Tests/run_account_session_tests.sh",
                        "/bin/bash scripts/dev/test-memory-audio-archive.sh"):
            result, run, _ = self.run_command(processes=command + "\n")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("while standalone probes running", result.stderr)
            self.assertEqual(len(list((run.parents[2] / "home/Library/Preferences").iterdir())), 2)

    def test_only_test_suite_names_count_as_disposable(self):
        uuid = "0BB4561E-4CAE-41FD-AC25-D87F13C048C5"
        for name in (f"{uuid}.plist", f"FillerWordDefaultsTests-{uuid}.plist", f"ProgressivePipeline.{uuid}.plist",
                     f"pichi-test-edit-route-migration-{uuid}.plist", f"account.synthetic.{uuid}.plist",
                     f"ai.pichi.fluidserve-fixture.{uuid}.plist", f"synthetic.file-operation.{uuid}.plist",
                     f"EditModeConsent-{uuid}-A.plist", f"EditModeConsent-{uuid}-B.plist"):
            self.assertTrue(RUNNER.DISPOSABLE_PREFERENCES.fullmatch(name), name)
        for name in (f"com.openai.chat.RemoteFeatureFlags.{uuid}.plist", f"ai.pichi.voice.{uuid}.plist",
                     "ai.pichi.voice.plist", f"Tests.{uuid}.plist.lockfile", f".{uuid}.plist"):
            self.assertFalse(RUNNER.DISPOSABLE_PREFERENCES.fullmatch(name), name)

    def test_record_holds_only_disposable_names(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "Preferences"
            directory.mkdir()
            (directory / "OlderTests.0BB4561E-4CAE-41FD-AC25-D87F13C048C5.plist").write_bytes(b"")
            (directory / "ai.pichi.voice.plist").write_bytes(b"")
            snapshot = Path(temporary) / "before.txt"
            RUNNER.remember_preferences(directory, snapshot)
            self.assertEqual(snapshot.read_text(), "OlderTests.0BB4561E-4CAE-41FD-AC25-D87F13C048C5.plist")
            self.assertEqual(sorted(path.name for path in Path(temporary).iterdir()), ["Preferences", "before.txt"])

    def test_sweep_keeps_older_named_and_linked_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "Preferences"
            directory.mkdir()
            snapshot = Path(temporary) / "before.txt"
            uuid = "0BB4561E-4CAE-41FD-AC25-D87F13C048C5"
            older = directory / f"OlderTests.{uuid}.plist"
            older.write_bytes(b"")
            RUNNER.remember_preferences(directory, snapshot)
            created = directory / f"NewTests.{uuid}.plist"
            created.write_bytes(b"")
            real = directory / "ai.pichi.voice.plist"
            real.write_bytes(b"")
            target = Path(temporary) / "target"
            target.write_bytes(b"")
            link = directory / f"Linked.{uuid}.plist"
            link.symlink_to(target)
            with contextlib.redirect_stdout(io.StringIO()), patch.object(RUNNER, "live_test_processes", return_value=[]):
                RUNNER.sweep_preferences(directory, snapshot)
            self.assertFalse(created.exists())
            self.assertTrue(older.exists() and real.exists() and link.is_symlink())

    def test_unavailable_report_fails_and_cannot_hide_test_failure(self):
        for test_status, expected in ((0, 2), (65, 65)):
            result, run, _ = self.run_command(test_status=test_status, report_status=2)
            self.assertEqual(result.returncode, expected, result.stderr)
            self.assertIn("report unavailable", (run / "summary.txt").read_text())


if __name__ == "__main__":
    unittest.main()
