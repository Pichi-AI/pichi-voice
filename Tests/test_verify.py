"""Portable regressions for layer selection, red results and the receipt of scripts/dev/verify."""
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
LOADER = importlib.machinery.SourceFileLoader("verify", str(ROOT / "scripts/dev/verify"))
SPEC = importlib.util.spec_from_loader("verify", LOADER)
VERIFY = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(VERIFY)
BUNDLE = "FluidDictationIntegrationTests"
BROKEN = f"{BUNDLE}/AClass/testBroken()"
SKIPPED = f"{BUNDLE}/AClass/testSkipped()"
PASSING = f"{BUNDLE}/AClass/testPassing()"
NOTHING = VERIFY.Quarantine(tests=set(), probes=set())


class FakeReceipt(VERIFY.Receipt):
    """Answers steps from a script of (exit code, test results)."""

    def __init__(self, directory, script):
        super().__init__(directory)
        self.script = list(script)
        self.calls = []
        self.hosts = {}
        self.reports = {}

    def begin(self, name, command, environment=None, hosts=None):
        self.calls.append((name, command, environment))
        self.hosts[name] = hosts
        return {"name": name}

    def wait_for_text(self, entry, text, limit=VERIFY.STEP_LIMIT_SECONDS):
        self.calls.append(("wait", entry["name"], text))

    def join(self, *entries, limit=VERIFY.STEP_LIMIT_SECONDS):
        rows = []
        for entry in entries:
            code, report = self.script.pop(0)
            status = "timed out" if code is None else "passed" if code == 0 else "failed"
            row = {"name": entry["name"], "status": status, "exitCode": code, "seconds": 0, "log": entry["name"]}
            self.reports[entry["name"]] = report
            self.value["steps"].append(row)
            rows.append(row)
        return rows


class LayerTests(unittest.TestCase):
    def test_paths_that_cannot_change_the_app_stay_in_l0(self):
        for path in ("README.md", "docs/development/codex.md", ".github/workflows/pichi-ci.yml", "scripts/dev/macos.sh",
                     "Tests/test_verify.py", "Tests/quarantine.json", "Tests/skip-registry.json"):
            self.assertEqual(VERIFY.choose_layer([path])[0], "L0", path)

    def test_everything_else_takes_l1_even_without_a_rule(self):
        for path in ("Sources/Fluid/ContentView.swift", "Sources/Fluid/Resources/Prompt.md", "Tests/run_ui_contrast_tests.sh",
                     "Tests/FluidDictationIntegrationTests/A.swift", "Fluid.xcodeproj/project.pbxproj", "Package.resolved", "something/new.bin"):
            self.assertEqual(VERIFY.choose_layer([path])[0], "L1", path)

    def test_checks_that_only_the_probe_registry_runs_take_l1(self):
        for path in ("scripts/dev/test-memory-audio-archive.sh", "Tests/test_published_upstream_release.py"):
            self.assertEqual(VERIFY.choose_layer([path])[0], "L1", path)

    def test_a_script_the_project_calls_is_a_build_input(self):
        path = "scripts/dev/stage-sensitive-topic-model.py"
        self.assertEqual(VERIFY.choose_layer([path], "shellScript = \"python3 scripts/dev/stage-sensitive-topic-model.py\";")[0], "L1")
        self.assertEqual(VERIFY.choose_layer(["README.md"], "path = README.md;")[0], "L0")

    def test_the_real_project_names_that_script(self):
        project = (ROOT / "Fluid.xcodeproj/project.pbxproj").read_text()
        self.assertEqual(VERIFY.choose_layer(["scripts/dev/stage-sensitive-topic-model.py"], project)[0], "L1")

    def test_one_app_file_decides_and_the_reason_names_it(self):
        layer, reason = VERIFY.choose_layer(["README.md", "Sources/Fluid/A.swift", "Sources/Fluid/B.swift", "docs/x.md"])
        self.assertEqual(layer, "L1")
        self.assertIn("Sources/Fluid/A.swift and 1 more", reason)

    def test_no_changes_is_still_a_layer(self):
        self.assertEqual(VERIFY.choose_layer([]), ("L0", "no changes against the base"))

    def test_mobile_runs_for_its_own_shared_and_resource_paths(self):
        shared = {"Sources/Fluid/Account/AccountDomain.swift"}
        for path in ("Sources/Mobile/App.swift", "Tests/MobileUITests/A.swift", "Sources/Fluid/Account/AccountDomain.swift",
                     "Vendor/PichiGigaAM/A.swift", "Fluid.xcodeproj/project.pbxproj", "Package.swift",
                     "Sources/Fluid/Localization/Localizable.xcstrings", "Sources/Fluid/Branding/brand-package.json",
                     "scripts/dev/stage-sensitive-topic-model.py", "tools/sensitive_topic_classifier.py",
                     "Sources/MobileActivity/MobileRecordingActivityWidget.swift",
                     "Tests/Fixtures/SensitiveTopics/synthetic-exploratory-v1.jsonl"):
            self.assertTrue(VERIFY.touches_mobile([path], shared), path)
        self.assertFalse(VERIFY.touches_mobile(["Sources/Fluid/ContentView.swift", "docs/a.md"], shared))

    def test_repository_shared_list_has_real_paths(self):
        self.assertIn("Sources/Fluid/Account/AccountDomain.swift", VERIFY.shared_sources())


class VendorTests(unittest.TestCase):
    def names(self, layer, paths):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None)] * len(VERIFY.vendor_packages()))
            VERIFY.run_vendor(receipt, layer, paths)
            return [call[0] for call in receipt.calls], len(receipt.value["skipped"])

    def test_only_a_changed_package_runs_in_l1(self):
        others = len(VERIFY.vendor_packages()) - 1
        self.assertEqual(self.names("L1", ["Vendor/PichiGigaAM/Sources/A.swift", "Sources/Fluid/A.swift"]), (["vendor-PichiGigaAM"], others))

    def test_every_package_runs_in_l2(self):
        self.assertEqual(self.names("L2", []), ([f"vendor-{name}" for name in VERIFY.vendor_packages()], 0))

    def test_packages_are_the_vendored_ones_with_tests(self):
        packages = VERIFY.vendor_packages()
        self.assertIn("PichiGigaAM", packages)
        self.assertNotIn("WebRTCAudioProcessing", packages)
        self.assertTrue(all((ROOT / "Vendor" / name / "Tests").is_dir() for name in packages))


class ReportTests(unittest.TestCase):
    def test_report_tree_flattens_to_full_test_names(self):
        tree = {"nodeType": "Test Plan", "children": [{"nodeType": "Unit test bundle", "name": "Bundle", "children": [
            {"nodeType": "Test Suite", "name": "AClass", "children": [
                {"nodeType": "Test Case", "name": "testOne()", "result": "Failed",
                 "children": [{"nodeType": "Failure Message", "name": "Boom"}]},
                {"nodeType": "Test Case", "name": "testTwo()", "result": "Skipped"}]}]}]}
        found = {}
        VERIFY.collect(tree, None, None, found)
        self.assertEqual(found, {"Bundle/AClass/testOne()": "Failed", "Bundle/AClass/testTwo()": "Skipped"})

    def test_unreadable_or_empty_report_never_counts(self):
        with patch.object(VERIFY.subprocess, "check_output", side_effect=OSError("no xcrun")):
            self.assertIsNone(VERIFY.bundle_results("missing"))
        with patch.object(VERIFY.subprocess, "check_output", return_value=b'{"testNodes": []}'):
            self.assertIsNone(VERIFY.bundle_results("empty"))

    def test_a_passed_step_without_a_report_turns_red(self):
        row = {"status": "passed"}
        with patch.object(VERIFY, "bundle_results", return_value=None):
            self.assertEqual(VERIFY.report_results(row, "missing"), {})
        self.assertEqual(row["status"], "failed")
        self.assertIn("report", row["note"])

    def test_a_timed_out_step_keeps_its_status(self):
        row = {"status": "timed out"}
        self.assertEqual(VERIFY.report_results(row, None), {})
        self.assertEqual(row["status"], "timed out")


class SideBySideTests(unittest.TestCase):
    def run_script(self, script, quarantine=NOTHING, layer="L1"):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), script)
            with patch.object(VERIFY, "xctest_results", side_effect=lambda row: VERIFY.report_results(row, "x" if receipt.reports[row["name"]] else None)), \
                    patch.object(VERIFY, "bundle_results", side_effect=lambda _: receipt.reports["xctest"]), \
                    patch.object(VERIFY, "artifact_directory", return_value=None):
                found = VERIFY.run_xctest_and_probes(receipt, quarantine, 8, layer)
            receipt.finish()
            return receipt, found

    def test_probes_start_after_the_build_and_both_are_joined(self):
        receipt, found = self.run_script([(0, {PASSING: "Passed"}), (0, None)])
        self.assertEqual([call[0] for call in receipt.calls], ["xctest", "wait", "probes"])
        self.assertEqual(receipt.calls[1][2], VERIFY.BUILD_FINISHED)
        self.assertEqual(receipt.hosts, {"xctest": f"{VERIFY.ROOT}/.build/XcodeRegression/", "probes": None})
        self.assertEqual(receipt.value["result"], "passed")
        self.assertEqual(found, {PASSING: "Passed"})

    def test_xctest_runs_serially(self):
        receipt, _ = self.run_script([(0, {PASSING: "Passed"}), (0, None)])
        self.assertIsNone(receipt.calls[0][2])
        self.assertFalse(any("parallel" in argument for argument in receipt.calls[0][1]))

    def test_a_red_xctest_stays_red(self):
        receipt, _ = self.run_script([(65, {BROKEN: "Failed"}), (0, None)])
        self.assertEqual(receipt.value["result"], "failed")

    def test_red_probes_stay_red(self):
        receipt, _ = self.run_script([(0, {PASSING: "Passed"}), (1, None)])
        self.assertEqual(receipt.value["result"], "failed")

    def test_a_timed_out_run_stays_red(self):
        receipt, _ = self.run_script([(None, {BROKEN: "Failed"}), (0, None)])
        self.assertEqual(receipt.value["steps"][0]["status"], "timed out")
        self.assertEqual(receipt.value["result"], "failed")

    def test_missing_report_is_red_even_with_exit_zero(self):
        receipt, _ = self.run_script([(0, None), (0, None)])
        self.assertEqual(receipt.value["result"], "failed")

    def test_quarantined_tests_do_not_run(self):
        name, mobile = BROKEN[:-2], f"{VERIFY.MOBILE_BUNDLE}/AClass/testOne"
        receipt, _ = self.run_script([(0, {PASSING: "Passed"}), (0, None)], VERIFY.Quarantine(tests={name, mobile}, probes=set()))
        self.assertIn(f"-skip-testing:{name}", receipt.calls[0][1])
        self.assertNotIn(f"-skip-testing:{mobile}", receipt.calls[0][1])


    def test_l1_leaves_the_soak_tests_to_l2_and_says_so(self):
        receipt, _ = self.run_script([(0, {PASSING: "Passed"}), (0, None)])
        for test in VERIFY.L2_ONLY_TESTS:
            self.assertIn(f"-skip-testing:{test}", receipt.calls[0][1])
        self.assertEqual([item["name"] for item in receipt.value["skipped"]], [test.split("/", 1)[1] for test in VERIFY.L2_ONLY_TESTS])
        self.assertEqual(receipt.value["result"], "passed")

    def test_l2_runs_the_soak_tests(self):
        receipt, _ = self.run_script([(0, {PASSING: "Passed"}), (0, None)], layer="L2")
        self.assertFalse(any(test in argument for test in VERIFY.L2_ONLY_TESTS for argument in receipt.calls[0][1]))
        self.assertEqual(receipt.value["skipped"], [])


class StepLimitTests(unittest.TestCase):
    def test_the_default_is_thirty_minutes(self):
        self.assertEqual(VERIFY.step_limit({}), 1800)
        self.assertEqual(VERIFY.step_limit({VERIFY.STEP_LIMIT_ENVIRONMENT: " "}), 1800)

    def test_a_slower_machine_can_ask_for_more_time(self):
        self.assertEqual(VERIFY.step_limit({VERIFY.STEP_LIMIT_ENVIRONMENT: "5400"}), 5400)

    def test_a_wrong_value_is_an_error_and_not_a_silent_default(self):
        for value in ("0", "-5", "ninety", "1.5"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                VERIFY.step_limit({VERIFY.STEP_LIMIT_ENVIRONMENT: value})


class ProbeTests(unittest.TestCase):
    def test_no_quarantine_runs_the_whole_registry(self):
        command = VERIFY.probe_command(NOTHING, 8)
        self.assertNotIn("--only", command)
        self.assertEqual(command[-2:], ["--jobs", "8"])

    def test_a_quarantined_probe_is_left_out(self):
        name = VERIFY.RUNNER.PROBES[0].name
        command = VERIFY.probe_command(VERIFY.Quarantine(tests=set(), probes={name}), 8)
        self.assertNotIn(name, command)
        self.assertNotIn("update_prompt", command)
        self.assertIn(VERIFY.RUNNER.PROBES[1].name, command)

    def test_failed_probes_are_named(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "summary.json").write_text(json.dumps({"results": [{"name": "a", "status": "FAIL"}, {"name": "b", "status": "PASS"}]}))
            receipt = VERIFY.Receipt(directory)
            with patch.object(VERIFY, "artifact_directory", return_value=directory):
                VERIFY.name_failed_probes(receipt, {"status": "failed"})
            self.assertEqual(receipt.value["probesFailed"], ["a"])


class QuarantineTests(unittest.TestCase):
    def test_entries_split_by_kind(self):
        entries = {"entries": [{"test": f"{BUNDLE}/A/testOne()"}, {"test": "probe:ui_contrast"}]}
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "Tests").mkdir()
            (root / "Tests/quarantine.json").write_text(json.dumps(entries))
            with patch.object(VERIFY, "ROOT", root):
                self.assertEqual(VERIFY.read_quarantine(), VERIFY.Quarantine(tests={f"{BUNDLE}/A/testOne"}, probes={"ui_contrast"}))

    def test_repository_quarantine_reads(self):
        self.assertIsInstance(VERIFY.read_quarantine(), VERIFY.Quarantine)


class SimulatorTests(unittest.TestCase):
    def test_a_simulator_that_cannot_be_created_is_a_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [])
            with patch.object(VERIFY, "disposable_simulator", side_effect=OSError("no runtime")), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(VERIFY.run_ios(receipt, NOTHING), {})
            receipt.finish()
            self.assertEqual(receipt.value["result"], "failed")

    def test_a_missing_runtime_is_a_gap_and_not_a_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [])
            with patch.object(VERIFY.subprocess, "check_output", return_value=b'{"runtimes": [{"platform": "iOS", "isAvailable": false}]}'):
                self.assertEqual(VERIFY.run_ios(receipt, NOTHING), {})
            receipt.finish()
            self.assertEqual(receipt.value["result"], "incomplete")
            self.assertEqual(receipt.value["steps"], [])
            self.assertIn("no iOS simulator runtime", receipt.value["skipped"][0]["reason"])

    def test_a_red_step_outranks_a_gap(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(1, None)])
            receipt.step("check", ["false"])
            receipt.unavailable("ios", "no runtime")
            receipt.finish()
            self.assertEqual(receipt.value["result"], "failed")

    def test_ios_leaves_out_its_own_quarantined_tests(self):
        mobile = f"{VERIFY.MOBILE_BUNDLE}/AClass/testOne"
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None)])
            with patch.object(VERIFY, "disposable_simulator", return_value="UDID"), \
                    patch.object(VERIFY.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)), \
                    patch.object(VERIFY, "bundle_results", return_value={PASSING: "Passed"}):
                VERIFY.run_ios(receipt, VERIFY.Quarantine(tests={mobile, BROKEN[:-2]}, probes=set()))
            command = receipt.calls[0][1]
            self.assertIn(f"-skip-testing:{mobile}", command)
            self.assertNotIn(f"-skip-testing:{BROKEN[:-2]}", command)

    def test_the_simulator_is_recorded_and_its_deletion_reported(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None)])
            with patch.object(VERIFY, "disposable_simulator", return_value="UDID"), \
                    patch.object(VERIFY.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), \
                    patch.object(VERIFY, "bundle_results", return_value=None):
                VERIFY.run_ios(receipt, NOTHING)
            receipt.finish()
            self.assertEqual(receipt.value["simulator"], {"udid": "UDID", "deleted": False})
            self.assertEqual(receipt.value["result"], "failed")
            self.assertIn("simulator UDID was not deleted", "\n".join(VERIFY.summary_lines(self.filled(receipt.value), Path("/tmp/run"))))

    @staticmethod
    def filled(value):
        return {**value, "layer": "L1", "workingTree": "clean", "revision": "a" * 40, "base": "b" * 40, "reason": "r"}


class ReceiptTests(unittest.TestCase):
    def test_step_records_status_log_and_saves_each_time(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            receipt = VERIFY.Receipt(directory, layer="L0", revision="a" * 40)
            with contextlib.redirect_stdout(io.StringIO()):
                good = receipt.step("good", ["sh", "-c", "echo hello"])
                bad = receipt.step("bad", ["sh", "-c", "exit 3"])
            self.assertEqual((good["status"], bad["status"], bad["exitCode"]), ("passed", "failed", 3))
            self.assertEqual((directory / "good.log").read_text(), "hello\n")
            saved = json.loads((directory / "receipt.json").read_text())
            self.assertEqual([row["name"] for row in saved["steps"]], ["good", "bad"])
            self.assertEqual(saved["revision"], "a" * 40)
            self.assertEqual(sorted(path.name for path in directory.iterdir()), ["bad.log", "good.log", "receipt.json"])

    def test_steps_run_side_by_side_and_keep_their_own_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            receipt = VERIFY.Receipt(directory)
            started = time.monotonic()
            with contextlib.redirect_stdout(io.StringIO()):
                slow = receipt.begin("slow", ["sh", "-c", "sleep 0.4; exit 3"])
                quick = receipt.begin("quick", ["sh", "-c", "sleep 0.4"])
                rows = receipt.join(slow, quick)
            self.assertLess(time.monotonic() - started, 0.75)
            self.assertEqual([(row["name"], row["status"]) for row in rows], [("slow", "failed"), ("quick", "passed")])
            self.assertEqual(receipt.running, [])

    def test_waiting_for_text_ends_on_the_text_or_when_the_step_ends(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = VERIFY.Receipt(Path(temporary))
            with contextlib.redirect_stdout(io.StringIO()), patch.object(VERIFY, "stop_test_hosts"):
                entry = receipt.begin("writer", ["sh", "-c", "echo ready; sleep 0.6"])
                receipt.wait_for_text(entry, b"ready")
                self.assertIsNone(entry["process"].poll())
                receipt.wait_for_text(entry, b"never")
                self.assertIsNotNone(entry["process"].poll())
                receipt.join(entry)

    def test_a_timed_out_step_leaves_its_neighbour_running_to_the_end(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = VERIFY.Receipt(Path(temporary))
            with contextlib.redirect_stdout(io.StringIO()), patch.object(VERIFY, "stop_test_hosts"), \
                    patch.object(VERIFY.RUNNER, "CANCEL_GRACE_SECONDS", 0.3):
                hung = receipt.begin("hung", ["sleep", "30"])
                hung["started"] -= 100
                neighbour = receipt.begin("neighbour", ["sh", "-c", "sleep 0.5"])
                rows = receipt.join(hung, neighbour, limit=50)
            self.assertEqual([row["status"] for row in rows], ["timed out", "passed"])

    def test_a_child_that_ignores_term_still_goes_down(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = VERIFY.Receipt(Path(temporary))
            pids = Path(temporary) / "pid"
            script = f"sh -c 'trap \"\" TERM; echo $$ > {pids}; sleep 30' & wait"
            with contextlib.redirect_stdout(io.StringIO()), patch.object(VERIFY.RUNNER, "CANCEL_GRACE_SECONDS", 0.3), \
                    patch.object(VERIFY, "stop_test_hosts"):
                row = receipt.step("hung", ["sh", "-c", script], limit=0.5)
            self.assertEqual(row["status"], "timed out")
            with self.assertRaises(ProcessLookupError):
                os.kill(int(pids.read_text()), 0)
            receipt.finish()
            self.assertEqual(receipt.value["result"], "failed")

    def test_only_hosts_under_the_given_build_path_are_stopped(self):
        listing = (f" 11 {VERIFY.REGRESSION_PRODUCTS}Build/Products/Debug/Pichi Voice Debug.app/Contents/MacOS/Pichi Voice Debug\n"
                   f" 33 {VERIFY.ROOT}/.build/account-session-tests/tests\n"
                   " 22 /Applications/Pichi Voice.app/Contents/MacOS/Pichi Voice\n")
        with patch.object(VERIFY.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, stdout=listing)), \
                patch.object(VERIFY.os, "kill") as kill:
            VERIFY.stop_test_hosts(VERIFY.REGRESSION_PRODUCTS)
        kill.assert_called_once_with(11, signal.SIGKILL)

    def test_stopping_a_step_reaches_only_its_own_hosts(self):
        with patch.object(VERIFY.RUNNER, "stop_process_group") as stop_group, patch.object(VERIFY, "stop_test_hosts") as stop_hosts:
            VERIFY.Receipt.stop({"process": "probes", "hosts": None})
            stop_hosts.assert_not_called()
            VERIFY.Receipt.stop({"process": "xctest", "hosts": "/build/"})
        stop_hosts.assert_called_once_with("/build/")
        self.assertEqual(stop_group.call_count, 2)

    def test_the_probe_runner_gets_time_to_stop_its_probes(self):
        self.assertEqual(VERIFY.RUNNER.CANCEL_GRACE_SECONDS, VERIFY.STEP_STOP_GRACE_SECONDS)

    def test_a_signal_stops_both_steps_and_finishes_the_receipt(self):
        script = f"""
import importlib.machinery, importlib.util, os, signal, sys, threading, time
from pathlib import Path
sys.dont_write_bytecode = True
loader = importlib.machinery.SourceFileLoader("verify", {str(ROOT / "scripts/dev/verify")!r})
spec = importlib.util.spec_from_loader("verify", loader)
verify = importlib.util.module_from_spec(spec)
loader.exec_module(verify)
verify.RUNNER.CANCEL_GRACE_SECONDS = 0.3
root = Path(sys.argv[1])
receipt = verify.Receipt(root)
def send():
    while not ((root / "a.pid").exists() and (root / "b.pid").exists()):
        time.sleep(0.01)
    os.kill(os.getpid(), int(sys.argv[2]))
threading.Thread(target=send, daemon=True).start()
def work():
    a = receipt.begin("a", ["sh", "-c", f"echo $$ > {{root}}/a.pid; sleep 30"])
    b = receipt.begin("b", ["sh", "-c", f"echo $$ > {{root}}/b.pid; sleep 30"])
    receipt.join(a, b)
verify.run_guarded(receipt, work)
"""
        for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with tempfile.TemporaryDirectory() as temporary:
                completed = subprocess.run([sys.executable, "-B", "-S", "-c", script, temporary, str(int(number))],
                                           capture_output=True, text=True, timeout=30)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(json.loads((Path(temporary) / "receipt.json").read_text())["result"], "interrupted", number)
                for name in ("a", "b"):
                    with self.assertRaises(ProcessLookupError):
                        os.kill(int((Path(temporary) / f"{name}.pid").read_text()), 0)

    def test_cleanup_reaches_every_step_even_when_one_stop_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = VERIFY.Receipt(Path(temporary))
            first = receipt.begin("first", ["sleep", "30"], hosts="/first/")
            second = receipt.begin("second", ["sleep", "30"])
            real_stop = VERIFY.RUNNER.stop_process_group

            def fail_on_first(process):
                real_stop(process)
                if process is first["process"]:
                    raise OSError("synthetic stop failure")

            with patch.object(VERIFY.RUNNER, "stop_process_group", side_effect=fail_on_first), \
                    patch.object(VERIFY, "stop_test_hosts") as hosts, patch.object(VERIFY.RUNNER, "CANCEL_GRACE_SECONDS", 0.2):
                errors = receipt.stop_running()
            self.assertEqual([str(error) for error in errors], ["synthetic stop failure"])
            hosts.assert_called_once_with("/first/")
            self.assertIsNotNone(second["process"].poll())
            self.assertEqual(receipt.running, [])
            self.assertTrue(first["stream"].closed and second["stream"].closed)

    def test_any_error_still_finishes_the_receipt_as_failed(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = VERIFY.Receipt(Path(temporary))

            def work():
                raise KeyError("unexpected shape")

            VERIFY.run_guarded(receipt, work)
            self.assertEqual(receipt.value["result"], "failed")
            self.assertIn("unexpected shape", receipt.value["error"])

    def test_a_step_that_ends_first_keeps_its_own_duration(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = VERIFY.Receipt(Path(temporary))
            with contextlib.redirect_stdout(io.StringIO()):
                quick = receipt.begin("quick", ["true"])
                slow = receipt.begin("slow", ["sleep", "1"])
                rows = receipt.join(quick, slow)
            self.assertLess(rows[0]["seconds"], 0.7)
            self.assertGreaterEqual(rows[1]["seconds"], 0.9)

    def test_l0_says_why_each_heavy_step_did_not_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None), (0, None)])
            with patch.object(VERIFY.shutil, "which", return_value="/usr/bin/swiftlint"):
                self.assertIsNone(VERIFY.execute(receipt, "L0", [], "origin/main", 4))
            self.assertEqual([call[0] for call in receipt.calls], ["check", "lint"])
            self.assertEqual([item["name"] for item in receipt.value["skipped"]], list(VERIFY.HEAVY_STEPS))
            self.assertIsNone(receipt.calls[0][2])

    def test_failed_check_stops_a_heavy_layer(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(1, None)])
            with patch.object(VERIFY.shutil, "which", return_value=None):
                self.assertIsNone(VERIFY.execute(receipt, "L1", ["Sources/A.swift"], "origin/main", 4))
            self.assertEqual([call[0] for call in receipt.calls], ["check"])
            reasons = {item["name"]: item["reason"] for item in receipt.value["skipped"]}
            self.assertIn("swiftlint is not installed", reasons["lint"])
            self.assertIn("repository check failed", reasons["xctest"])

    def test_heavy_layer_without_xcode_is_incomplete_not_green(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None)])
            with patch.object(VERIFY.shutil, "which", return_value=None):
                self.assertEqual(VERIFY.execute(receipt, "L1", ["Sources/A.swift"], "origin/main", 4), "incomplete")

    def test_heavy_layer_refuses_a_full_disk(self):
        class Usage:
            free = 3 * 2**30
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None), (0, None)])
            with patch.object(VERIFY.shutil, "which", return_value="/usr/bin/tool"), \
                    patch.object(VERIFY.shutil, "disk_usage", return_value=Usage):
                self.assertEqual(VERIFY.execute(receipt, "L1", ["Sources/A.swift"], "origin/main", 4), "incomplete")
            self.assertIn("only 3 GB free", {item["name"]: item["reason"] for item in receipt.value["skipped"]}["xctest"])

    def test_a_tree_that_moved_during_the_run_proves_nothing(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None)])
            receipt.step("check", ["true"])
            with patch.object(VERIFY, "tree_fingerprint", return_value="after"):
                VERIFY.finish(receipt, None, "before")
            self.assertEqual(receipt.value["result"], "incomplete")

    def test_a_still_tree_finishes_on_the_step_results(self):
        with tempfile.TemporaryDirectory() as temporary:
            receipt = FakeReceipt(Path(temporary), [(0, None)])
            receipt.step("check", ["true"])
            with patch.object(VERIFY, "tree_fingerprint", return_value="same"):
                VERIFY.finish(receipt, None, "same")
            self.assertEqual(receipt.value["result"], "passed")

    def test_missing_lint_is_a_gap_only_when_swift_changed(self):
        for paths, expected in ((["Sources/A.swift"], "incomplete"), (["docs/a.md"], "passed")):
            with tempfile.TemporaryDirectory() as temporary:
                receipt = FakeReceipt(Path(temporary), [(0, None)])
                with patch.object(VERIFY.shutil, "which", return_value=None):
                    receipt.finish(VERIFY.execute(receipt, "L0", paths, "origin/main", 4))
                self.assertEqual(receipt.value["result"], expected, paths)

    def test_a_failed_build_is_named(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "summary.txt").write_text("Build failed (exit 65); tests were not run.\n")
            row = {"status": "failed"}
            with patch.object(VERIFY, "artifact_directory", return_value=directory), patch.object(VERIFY, "bundle_results", return_value=None):
                self.assertEqual(VERIFY.xctest_results(row), {})
            self.assertEqual(row["note"], "the build failed, so no test ran")

    def test_the_fingerprint_follows_content_and_not_only_status(self):
        def run(*arguments):
            subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@example.invalid", *arguments], cwd=root, check=True, capture_output=True)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run("init", "-q")
            (root / "tracked.txt").write_text("one\n")
            run("add", "tracked.txt")
            run("commit", "-q", "-m", "first")
            clean = VERIFY.tree_fingerprint(root)
            self.assertEqual(VERIFY.tree_fingerprint(root), clean)
            (root / "tracked.txt").write_text("two\n")
            modified = VERIFY.tree_fingerprint(root)
            (root / "tracked.txt").write_text("three\n")
            modified_again = VERIFY.tree_fingerprint(root)
            (root / "new file.txt").write_text("a\n")
            untracked = VERIFY.tree_fingerprint(root)
            (root / "new file.txt").write_text("b\n")
            self.assertEqual(len({clean, modified, modified_again, untracked, VERIFY.tree_fingerprint(root)}), 5)

    def test_summary_names_revision_reason_skips_and_failures(self):
        value = {"layer": "L1", "result": "failed", "seconds": 90.4, "workingTree": "clean", "revision": "a" * 40, "base": "b" * 40,
                 "reason": "Sources/A.swift can change the app", "skipped": [{"name": "ios", "reason": "no mobile"}],
                 "steps": [{"name": "xctest", "status": "failed", "seconds": 61.2, "note": "no readable test report"}],
                 "quarantined": [BROKEN], "testsFailed": [SKIPPED]}
        text = "\n".join(VERIFY.summary_lines(value, Path("/tmp/run")))
        for expected in ("Verify L1: failed in 90 s", "aaaaaaaa (clean)", "bbbbbbbb", "Sources/A.swift can change the app",
                         "failed xctest: 61 s (no readable test report)", "skipped ios: no mobile", BROKEN, SKIPPED, "/tmp/run/receipt.json"):
            self.assertIn(expected, text)


class ExecuteTests(unittest.TestCase):
    def run_layer(self, layer, paths, quarantine=NOTHING):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        receipt = FakeReceipt(Path(temporary.name), [(0, None), (0, None), (0, None)])
        ran = []

        class Usage:
            free = 50 * 2**30

        def ios(_, passed_quarantine):
            ran.append(passed_quarantine)
            return {f"{VERIFY.MOBILE_BUNDLE}/AClass/testOne()": "Failed"}

        with patch.object(VERIFY.shutil, "which", return_value="/usr/bin/tool"), patch.object(VERIFY.shutil, "disk_usage", return_value=Usage), \
                patch.object(VERIFY, "read_quarantine", return_value=quarantine), patch.object(VERIFY, "run_ios", side_effect=ios), \
                patch.object(VERIFY, "run_xctest_and_probes", return_value={PASSING: "Passed", BROKEN: "Failed"}) as xctest, \
                patch.object(VERIFY, "run_vendor") as vendor:
            outcome = VERIFY.execute(receipt, layer, paths, "origin/main", 4)
        self.xctest_layers = [call.args[3] for call in xctest.call_args_list]
        return receipt, outcome, ran, vendor

    def test_the_layer_reaches_the_test_selection(self):
        for layer in ("L1", "L2"):
            with self.subTest(layer=layer):
                self.run_layer(layer, ["Sources/Fluid/App.swift"])
                self.assertEqual(self.xctest_layers, [layer])

    def test_a_mobile_change_runs_ios_and_all_results_reach_the_policy_check(self):
        receipt, outcome, ran, vendor = self.run_layer("L1", ["Sources/Mobile/App.swift"])
        self.assertIsNone(outcome)
        self.assertEqual(ran, [NOTHING])
        record = receipt.directory / "results.json"
        self.assertEqual(set(json.loads(record.read_text())), {PASSING, BROKEN, f"{VERIFY.MOBILE_BUNDLE}/AClass/testOne()"})
        self.assertEqual(receipt.value["testsFailed"], [BROKEN, f"{VERIFY.MOBILE_BUNDLE}/AClass/testOne()"])
        self.assertEqual([call[0] for call in receipt.calls], ["check", "lint", "skip-policy"])
        self.assertEqual(receipt.calls[-1][1][-3:], ["--results", str(record), "--complete"])
        vendor.assert_called_once()

    def test_a_desktop_change_skips_ios_and_says_why(self):
        receipt, _, ran, _ = self.run_layer("L1", ["Sources/Fluid/ContentView.swift"])
        self.assertEqual(ran, [])
        self.assertEqual({item["name"]: item["reason"] for item in receipt.value["skipped"]}["ios"], "no mobile or shared source changed")

    def test_l2_runs_ios_whatever_changed(self):
        self.assertEqual(len(self.run_layer("L2", [])[2]), 1)

    def test_quarantined_tests_are_listed_in_the_receipt(self):
        receipt, _, _, _ = self.run_layer("L1", [], VERIFY.Quarantine(tests={"Bundle/AClass/testOld"}, probes={"ui_contrast"}))
        self.assertEqual(receipt.value["quarantined"], ["Bundle/AClass/testOld", "probe:ui_contrast"])


class MobileScriptTests(unittest.TestCase):
    def run_script(self, *arguments):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        (root / "scripts/dev").mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/dev/mobile.sh", root / "scripts/dev/mobile.sh")
        tools = root / "tools"
        tools.mkdir()
        (tools / "git").write_text("#!/bin/sh\nprintf '%s\\n' /synthetic/.git/worktrees/task\n")
        (tools / "xcodebuild").write_text(f"#!/bin/sh\nprintf '%s\\n' \"$*\" > '{root}/call.txt'\n")
        for tool in tools.iterdir():
            tool.chmod(0o755)
        environment = dict(os.environ, PATH=f"{tools}:{os.environ['PATH']}")
        subprocess.run(["bash", str(root / "scripts/dev/mobile.sh"), *arguments], env=environment, check=True, capture_output=True)
        return (root / "call.txt").read_text().rstrip()

    def test_extra_test_arguments_reach_xcodebuild_before_the_action(self):
        call = self.run_script("test", "-only-testing:Bundle", "-resultBundlePath", "/synthetic/result")
        self.assertTrue(call.endswith(" -only-testing:Bundle -resultBundlePath /synthetic/result test"), call)

    def test_plain_actions_are_unchanged(self):
        self.assertTrue(self.run_script("test").endswith('ALLOWED=YES test'))
        self.assertTrue(self.run_script("build").endswith('ALLOWED=YES build'))


if __name__ == "__main__":
    unittest.main()
