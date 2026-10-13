#!/usr/bin/env python3
"""Portable runner regressions execute synthetic scripts, never application probes."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("standalone_regression", ROOT / "scripts/dev/standalone-regression.py")
RUNNER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = RUNNER
SPEC.loader.exec_module(RUNNER)


class StandaloneRunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="standalone root with spaces ")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "Tests").mkdir()

    def probe(self, name, body="exit 0", interpreter="sh", requires_ui=False):
        extension = "py" if interpreter == "python3" else "sh"
        filename = f"Tests/run_{name}_tests.{extension}"
        shebang = {"sh": "#!/bin/sh", "bash": "#!/usr/bin/env bash", "python3": "#!/usr/bin/env python3"}[interpreter]
        (self.root / filename).write_text(f"{shebang}\n{body}\n")
        return RUNNER.Probe(filename, interpreter, requires_ui)

    def run_probes(self, probes, **options):
        with redirect_stdout(io.StringIO()):
            status, report = RUNNER.run_suite(self.root, probes, revision="synthetic-revision", dirty=True, **options)
        directory = Path(report["artifactDirectory"])
        self.assertEqual(json.loads((directory / "summary.json").read_text()), report)
        self.assertTrue((directory / "summary.txt").is_file())
        self.assertEqual(report["workingTree"], "dirty")
        for row in report["results"]:
            self.assertTrue((directory / row["log"]).is_file())
        return status, report, directory

    def test_current_registry_covers_every_standalone_and_only_update_prompt_opts_in(self):
        RUNNER.validate_registry(ROOT)
        self.assertEqual(len(RUNNER.PROBES), 37)
        self.assertEqual(sum(probe.interpreter == "sh" for probe in RUNNER.PROBES), 33)
        self.assertEqual(sum(probe.interpreter == "python3" for probe in RUNNER.PROBES), 4)
        self.assertEqual([probe.name for probe in RUNNER.PROBES if probe.requires_ui], ["update_prompt"])
        self.assertTrue({"file_export", "ui_contrast", "file_transcript_relative_date", "clipboard_backup_reproduction"}
                        .issubset({probe.name for probe in RUNNER.PROBES}))

    def test_failure_is_counted_and_later_probes_still_run(self):
        probes = [self.probe("first", 'echo first; echo stderr >&2'),
                  self.probe("failure", "exit 7"), self.probe("last", "echo last")]
        status, report, directory = self.run_probes(probes)
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["counts"], {"total": 3, "passed": 2, "failed": 1, "skipped": 0})
        self.assertEqual([row["exitCode"] for row in report["results"]], [0, 7, 0])
        self.assertIn("stderr", (directory / "first.log").read_text())
        self.assertEqual((directory / "last.log").read_text(), "last\n")

    def test_optional_ui_is_skipped_without_activation(self):
        probes = [self.probe("normal"), self.probe("ui", "touch activated", requires_ui=True)]
        status, report, directory = self.run_probes(probes)
        self.assertEqual(status, 0)
        self.assertEqual(report["counts"], {"total": 2, "passed": 1, "failed": 0, "skipped": 1})
        self.assertIsNone(report["results"][1]["exitCode"])
        self.assertIn("--include-ui", (directory / "ui.log").read_text())
        self.assertFalse((self.root / "activated").exists())

    def test_ui_requires_explicit_flag_even_when_selected_alone(self):
        probe = self.probe("ui", "touch activated", requires_ui=True)
        status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["counts"]["skipped"], 1)
        self.assertFalse((self.root / "activated").exists())
        status, report, _ = self.run_probes([probe], include_ui=True)
        self.assertEqual(status, 0)
        self.assertEqual(report["counts"]["passed"], 1)
        self.assertTrue((self.root / "activated").exists())

    def test_python_and_bash_are_invoked_with_their_own_interpreters(self):
        python = self.probe("python", 'from pathlib import Path\nprint("python OK")\nassert Path("Tests").is_dir()', interpreter="python3")
        bash = self.probe("bash", 'set -euo pipefail\nvalues=(alpha beta)\n[[ "${values[1]}" == beta ]]\necho "bash OK"', interpreter="bash")
        RUNNER.validate_registry(self.root, [python, bash])
        status, report, directory = self.run_probes([python, bash])
        self.assertEqual(status, 0)
        self.assertEqual(report["results"][0]["command"], [sys.executable, python.script])
        self.assertEqual(report["results"][1]["command"], ["/bin/bash", bash.script])
        self.assertEqual((directory / "python.log").read_text(), "python OK\n")
        self.assertEqual((directory / "bash.log").read_text(), "bash OK\n")

    def test_missing_registered_script_is_not_a_success(self):
        probe = self.probe("missing")
        (self.root / probe.script).unlink()
        status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["counts"]["failed"], 1)
        self.assertEqual(report["results"][0]["reason"], "registered script missing")

    def test_process_launch_failure_is_recorded(self):
        probe = self.probe("launch")
        with patch.object(RUNNER, "run_owned_process", side_effect=FileNotFoundError("synthetic missing interpreter")):
            status, report, directory = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertIsNone(report["results"][0]["exitCode"])
        self.assertIn("missing interpreter", (directory / "launch.log").read_text())

    def test_signal_exit_is_preserved(self):
        probe = self.probe("signal")
        with patch.object(RUNNER, "run_owned_process", return_value=(-15, None)):
            status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["results"][0]["exitCode"], -15)

    def test_interruption_records_failure_and_remaining_skips(self):
        probes = [self.probe("first"), self.probe("interrupted"), self.probe("last")]
        with patch.object(RUNNER, "run_owned_process", side_effect=[(0, None), KeyboardInterrupt()]):
            status, report, _ = self.run_probes(probes)
        self.assertEqual(status, 130)
        self.assertEqual(report["counts"], {"total": 3, "passed": 1, "failed": 1, "skipped": 1})
        self.assertEqual(report["results"][1]["runnerExitCode"], 130)
        self.assertIsNone(report["results"][1]["exitCode"])
        self.assertEqual(report["results"][2]["reason"], "not run after interruption")

    def worker_probe(self, *, wait=True):
        worker = self.root / "worker.py"
        worker.write_text('import signal, time\nfrom pathlib import Path\n'
                          'signal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                          'Path("worker-started").touch()\ntime.sleep(0.5)\nPath("escaped-worker").touch()\n')
        command = f"{shlex.quote(sys.executable)} {shlex.quote(str(worker))} &\n"
        command += 'while [ ! -f worker-started ]; do sleep 0.01; done\n'
        command += "wait" if wait else "exit 0"
        return self.probe("descendant", command)

    def verify_real_signal_cleanup(self, number):
        probe = self.worker_probe()
        signal_sent = threading.Event()

        def interrupt_when_started():
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                if (self.root / "worker-started").exists():
                    signal_sent.set()
                    os.kill(os.getpid(), number)
                    return
                time.sleep(0.01)

        sender = threading.Thread(target=interrupt_when_started, daemon=True)
        sender.start()
        try:
            with patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
                status, report, directory = self.run_probes([probe, self.probe("later", "touch later-executed")])
        finally:
            sender.join(timeout=4)
        self.assertTrue(signal_sent.is_set())
        self.assertEqual(status, 128 + number, (directory / "descendant.log").read_text())
        self.assertEqual(report["runnerExitCode"], 128 + number)
        self.assertIn(report["results"][0]["exitCode"], [-signal.SIGTERM, -signal.SIGKILL])
        self.assertEqual(report["counts"], {"total": 2, "passed": 0, "failed": 1, "skipped": 1})
        self.assertFalse((self.root / "later-executed").exists())
        time.sleep(0.6)
        self.assertFalse((self.root / "escaped-worker").exists(), "Descendant must not write after runner returns")
        with RUNNER.run_lock(self.root):
            pass

    def test_real_interrupt_joins_descendant_that_ignores_term(self):
        self.verify_real_signal_cleanup(signal.SIGINT)

    def test_real_term_joins_descendant_and_preserves_exit_143(self):
        self.verify_real_signal_cleanup(signal.SIGTERM)

    def wait_for_worker(self):
        deadline = time.monotonic() + 3
        while not (self.root / "worker-started").exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue((self.root / "worker-started").exists())

    def test_int_during_popen_creation_is_deferred_until_owner_is_recorded(self):
        probe = self.worker_probe()
        original = RUNNER.subprocess.Popen

        def interrupt_in_constructor(*args, **options):
            process = original(*args, **options)
            if options.get("start_new_session"):
                self.wait_for_worker()
                os.kill(os.getpid(), signal.SIGINT)
            return process

        with patch.object(RUNNER.subprocess, "Popen", side_effect=interrupt_in_constructor), patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
            status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 130)
        self.assertEqual(report["status"], "FAIL")
        time.sleep(0.6)
        self.assertFalse((self.root / "escaped-worker").exists())
        self.assertFalse((self.root / ".build" / RUNNER.PROCESS_MARKER).exists())

    def test_term_during_marker_write_is_deferred_then_joined(self):
        probe = self.worker_probe()
        original = Path.write_text
        delivered = False

        def terminate_in_marker(path, *args, **options):
            nonlocal delivered
            if path.name == RUNNER.PROCESS_MARKER and not delivered:
                self.wait_for_worker()
                delivered = True
                os.kill(os.getpid(), signal.SIGTERM)
            return original(path, *args, **options)

        with patch.object(Path, "write_text", terminate_in_marker), patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
            status, report, _ = self.run_probes([probe])
        self.assertTrue(delivered)
        self.assertEqual(status, 143)
        self.assertEqual(report["runnerExitCode"], 143)
        time.sleep(0.6)
        self.assertFalse((self.root / "escaped-worker").exists())

    def test_creation_deferral_preserves_child_signal_mask(self):
        expected = sorted(int(number) for number in signal.pthread_sigmask(signal.SIG_BLOCK, set()))
        probe = self.probe("mask", 'import json, signal\nprint(json.dumps(sorted(int(n) for n in signal.pthread_sigmask(signal.SIG_BLOCK, set()))))', interpreter="python3")
        status, _, directory = self.run_probes([probe])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads((directory / "mask.log").read_text()), expected)

    def test_background_descendant_is_not_a_success_or_left_running(self):
        probe = self.worker_probe(wait=False)
        with patch.object(RUNNER, "CANCEL_GRACE_SECONDS", 0.05):
            status, report, _ = self.run_probes([probe])
        self.assertEqual(status, 1)
        self.assertEqual(report["results"][0]["exitCode"], 0)
        self.assertIn("unjoined", report["results"][0]["reason"])
        time.sleep(0.6)
        self.assertFalse((self.root / "escaped-worker").exists())

    def test_interrupt_between_probes_still_finalizes_accounting(self):
        def stop_after_first(message, **options):
            if message == "PASS first":
                raise KeyboardInterrupt()
        with patch.object(RUNNER, "print", side_effect=stop_after_first, create=True):
            status, report, _ = self.run_probes([self.probe("first"), self.probe("later")])
        self.assertEqual(status, 130)
        self.assertEqual(report["status"], "FAIL")
        self.assertEqual(report["counts"], {"total": 2, "passed": 1, "failed": 0, "skipped": 1})

    def test_incomplete_cleanup_blocks_remaining_and_following_suites(self):
        marker = self.root / ".build" / RUNNER.PROCESS_MARKER

        def incomplete(*args):
            marker.write_text(json.dumps({"processGroup": 123456}))
            raise OSError("synthetic incomplete cleanup")

        with patch.object(RUNNER, "run_owned_process", side_effect=incomplete):
            status, report, _ = self.run_probes([self.probe("first"), self.probe("later")])
        self.assertEqual(status, 1)
        self.assertEqual(report["counts"]["skipped"], 1)
        with patch.object(RUNNER, "live_process_group", return_value=True):
            with self.assertRaisesRegex(ValueError, "previous probe still owns"):
                with RUNNER.run_lock(self.root):
                    self.fail("A new suite must not compete with an owned process")
        with patch.object(RUNNER, "live_process_group", return_value=False):
            with RUNNER.run_lock(self.root):
                pass
        self.assertFalse(marker.exists())

    def test_registry_drift_or_interpreter_change_requires_review(self):
        probe = self.probe("known")
        RUNNER.validate_registry(self.root, [probe])
        unknown = self.probe("unregistered")
        with self.assertRaisesRegex(ValueError, "registry mismatch"):
            RUNNER.validate_registry(self.root, [probe])
        (self.root / unknown.script).unlink()
        (self.root / probe.script).write_text("#!/usr/bin/env bash\nexit 0\n")
        with self.assertRaisesRegex(ValueError, "changed interpreter"):
            RUNNER.validate_registry(self.root, [probe])

    def test_selection_is_exact_ordered_and_deduplicated(self):
        probes = [self.probe("first"), self.probe("second")]
        self.assertEqual(RUNNER.select_probes(["second", "first", "first"], probes), tuple(probes))
        with self.assertRaisesRegex(ValueError, "Unknown"):
            RUNNER.select_probes(["typo"], probes)

    def test_parallel_runs_in_one_worktree_are_rejected_and_lock_releases(self):
        with RUNNER.run_lock(self.root):
            with self.assertRaisesRegex(ValueError, "already active"):
                with RUNNER.run_lock(self.root):
                    self.fail("Second run must not start")
        with RUNNER.run_lock(self.root):
            pass

    def test_symlinked_build_storage_is_rejected(self):
        outside = self.root / "shared-build"
        outside.mkdir()
        (self.root / ".build").symlink_to(outside, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "belong to this worktree"):
            self.run_probes([self.probe("storage")])


if __name__ == "__main__":
    unittest.main()
